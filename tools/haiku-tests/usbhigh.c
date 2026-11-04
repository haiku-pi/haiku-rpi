/*
 * usbhigh.c DEVICE [OFFSET_MIB] [KEEP_FREE_MIB] — raw disk reads into memory that is likely to lie above
 * the first 3 GiB, which the Raspberry Pi 4's PCIe (and so its xHCI controller) cannot reach
 * (docs/design/usb-storage-integrity.md, "Follow-ups"). Takes all but KEEP_FREE_MIB (default 320) of the
 * free memory in 64 MiB chunks and touches it, so the system has to hand out its last free pages, then
 * reads the 64 MiB at OFFSET_MIB (default 20000) into every chunk, one 1 MiB request per slice. Expects
 * the region to hold the pattern of tools/flashlane/usb-pattern.py (each 512-byte sector starts with
 * "USBCHK" + its LBA); each slice is filled with 0x5a first, so a transfer that did not reach the buffer
 * shows. Also compares each slice with the same MiB read into the first chunk (FNV-1a hash).
 * Prints "UH ..." lines; exit 0 when every slice was right.
 */
#include <OS.h>

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MIB (1024 * 1024)
#define CHUNK (64 * MIB)
#define SLICES (CHUNK / MIB)
#define MAX_CHUNKS 256
#define SECTOR 512


static uint64_t
hash(const uint8_t* data, size_t size)
{
	uint64_t h = 0xcbf29ce484222325ULL;
	for (size_t i = 0; i < size; i++)
		h = (h ^ data[i]) * 0x100000001b3ULL;
	return h;
}


/* the number of sectors in the slice without the pattern's tag for their LBA */
static int
bad_sectors(const uint8_t* data, uint64_t lba)
{
	int bad = 0;
	for (int i = 0; i < MIB / SECTOR; i++, lba++) {
		const uint8_t* sector = data + i * SECTOR;
		uint64_t tagged;
		memcpy(&tagged, sector + 6, sizeof(tagged));
		if (memcmp(sector, "USBCHK", 6) != 0 || tagged != lba)
			bad++;
	}
	return bad;
}


int
main(int argc, char** argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: %s DEVICE [OFFSET_MIB] [KEEP_FREE_MIB]\n", argv[0]);
		return 2;
	}
	off_t offsetMiB = argc > 2 ? atoll(argv[2]) : 20000;
	uint64_t keepFree = (argc > 3 ? atoll(argv[3]) : 320) * (uint64_t)MIB;

	int fd = open(argv[1], O_RDONLY);
	if (fd < 0) {
		perror("UH open");
		return 2;
	}

	system_info info;
	get_system_info(&info);
	uint64_t freeMemory = info.free_memory;
	printf("UH memory: %llu MiB in all, %llu MiB free\n",
		(unsigned long long)(info.max_pages * B_PAGE_SIZE / MIB),
		(unsigned long long)(freeMemory / MIB));

	static uint8_t* chunks[MAX_CHUNKS];
	int count = 0;
	while (count < MAX_CHUNKS && freeMemory > keepFree + CHUNK) {
		chunks[count] = malloc(CHUNK);
		if (chunks[count] == NULL)
			break;
		memset(chunks[count], 0xa5, CHUNK);
		count++;
		freeMemory -= CHUNK;
	}
	get_system_info(&info);
	printf("UH took %d chunks of 64 MiB (%d MiB); now %llu MiB free\n", count, count * 64,
		(unsigned long long)(info.free_memory / MIB));
	if (count == 0)
		return 2;

	uint64_t reference[SLICES];
	uint64_t lba0 = (uint64_t)offsetMiB * MIB / SECTOR;
	int badSlices = 0, errors = 0, mismatches = 0, badChunks = 0;
	bigtime_t start = system_time();
	for (int c = 0; c < count; c++) {
		int chunkBad = 0;
		for (int s = 0; s < SLICES; s++) {
			uint8_t* slice = chunks[c] + (size_t)s * MIB;
			memset(slice, 0x5a, MIB);
			ssize_t bytes = pread(fd, slice, MIB, (offsetMiB + s) * (off_t)MIB);
			if (bytes != MIB) {
				if (errors++ < 10) {
					printf("UH chunk %d slice %d: read returned %zd (%s)\n", c, s, bytes,
						bytes < 0 ? strerror(errno) : "short");
				}
				chunkBad++;
				continue;
			}
			int bad = bad_sectors(slice, lba0 + (uint64_t)s * (MIB / SECTOR));
			uint64_t h = hash(slice, MIB);
			if (c == 0)
				reference[s] = h;
			else if (h != reference[s])
				mismatches++;
			if (bad != 0 || (c != 0 && h != reference[s])) {
				if (badSlices++ < 20) {
					printf("UH chunk %d slice %d: %d of %d sectors without their tag, hash %s\n", c,
						s, bad, MIB / SECTOR, c == 0 ? "(reference)" : h == reference[s]
							? "same" : "DIFFERENT");
				}
				chunkBad++;
			}
		}
		if (chunkBad != 0)
			badChunks++;
		printf("UH chunk %d (%p): %d of %d slices wrong\n", c, chunks[c], chunkBad, SLICES);
	}
	double secs = (system_time() - start) / 1e6;
	printf("UH result: %d slices of 1 MiB in %d chunks, %.1f s (%.1f MB/s): %d wrong (%d read errors,"
		" %d hash mismatches), %d chunks with wrong slices\n", count * SLICES, count, secs,
		count * SLICES * (double)MIB / 1e6 / secs, badSlices + errors, errors, mismatches, badChunks);
	return badSlices + errors == 0 ? 0 : 1;
}
