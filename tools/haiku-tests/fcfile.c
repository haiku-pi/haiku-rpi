/*
 * fcfile.c — a file written and read through the file cache in requests of one size, timed, with content that
 * depends on the file offset (so a page written to the wrong place, or a stale page read back, is found, not
 * only a wrong whole-file hash). H20 C4b: the file cache's and the page writer's request sizes.
 *
 *   fcfile write FILE MIB BS_KIB [SEED]   create FILE (MIB MiB) in BS_KIB requests, fsync; the time includes the
 *                                         fsync and making the pattern (printed apart)
 *   fcfile read FILE BS_KIB [SEED]        read FILE to its end in BS_KIB requests and check every byte
 *   fcfile check FILE [SEED]              check only (1 MiB requests), no rate
 *
 * Prints "fcfile: write|read BS KiB: N MiB in T ms, R MB/s[, M bad bytes, first at OFFSET]" (MB = 10^6 bytes);
 * the exit status is 1 when a byte differs or the I/O fails. Each 8-byte word at file offset O holds
 * splitmix64(SEED ^ (O / 8)); SEED defaults to 1.
 *
 * Build (cross):
 *   sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc \
 *     --sysroot=artifacts/sysroot-arm64 -O2 -o fcfile tools/haiku-tests/fcfile.c
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>


static double
now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000.0 + ts.tv_nsec / 1000000.0;
}


static inline uint64_t
word_at(uint64_t seed, uint64_t offset)
{
	uint64_t z = (seed ^ (offset >> 3)) + 0x9e3779b97f4a7c15ULL;
	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
	z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
	return z ^ (z >> 31);
}


static void
fill(uint64_t* buffer, size_t size, uint64_t seed, uint64_t offset)
{
	for (size_t i = 0; i < size / 8; i++)
		buffer[i] = word_at(seed, offset + i * 8);
}


/* returns the number of differing bytes in buffer[0, size), the first one's file offset in *first */
static uint64_t
compare(const uint64_t* buffer, size_t size, uint64_t seed, uint64_t offset, int64_t* first)
{
	uint64_t bad = 0;
	for (size_t i = 0; i < size / 8; i++) {
		uint64_t want = word_at(seed, offset + i * 8);
		if (buffer[i] == want)
			continue;
		uint64_t diff = buffer[i] ^ want;
		for (int b = 0; b < 8; b++) {
			if ((diff >> (b * 8)) & 0xff) {
				if (*first < 0)
					*first = offset + i * 8 + b;
				bad++;
			}
		}
	}
	return bad;
}


int
main(int argc, char** argv)
{
	if (argc < 3) {
		fprintf(stderr, "usage: fcfile write FILE MIB BS_KIB [SEED] | read FILE BS_KIB [SEED] | check FILE [SEED]\n");
		return 2;
	}
	const char* mode = argv[1];
	const char* path = argv[2];
	int write_mode = strcmp(mode, "write") == 0;
	int check_mode = strcmp(mode, "check") == 0;
	if (!write_mode && !check_mode && strcmp(mode, "read") != 0) {
		fprintf(stderr, "fcfile: unknown mode %s\n", mode);
		return 2;
	}
	uint64_t total = 0;
	size_t bs;
	uint64_t seed = 1;
	if (write_mode) {
		if (argc < 5)
			return 2;
		total = (uint64_t)atoll(argv[3]) << 20;
		bs = (size_t)atol(argv[4]) << 10;
		if (argc > 5)
			seed = strtoull(argv[5], NULL, 0);
	} else if (check_mode) {
		bs = 1 << 20;
		if (argc > 3)
			seed = strtoull(argv[3], NULL, 0);
	} else {
		if (argc < 4)
			return 2;
		bs = (size_t)atol(argv[3]) << 10;
		if (argc > 4)
			seed = strtoull(argv[4], NULL, 0);
	}
	if (bs == 0 || bs % 8 != 0) {
		fprintf(stderr, "fcfile: bad request size\n");
		return 2;
	}

	uint64_t* buffer = aligned_alloc(4096, bs);
	if (buffer == NULL) {
		perror("fcfile: buffer");
		return 1;
	}
	int fd = write_mode ? open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644) : open(path, O_RDONLY);
	if (fd < 0) {
		perror(path);
		return 1;
	}

	double start = now_ms(), busy = 0;
	uint64_t done = 0, bad = 0;
	int64_t first = -1;
	int failed = 0;
	if (write_mode) {
		while (done < total) {
			size_t n = total - done < bs ? total - done : bs;
			double t = now_ms();
			fill(buffer, n, seed, done);
			busy += now_ms() - t;
			ssize_t w = write(fd, buffer, n);
			if (w != (ssize_t)n) {
				perror("fcfile: write");
				failed = 1;
				break;
			}
			done += n;
		}
		if (fsync(fd) != 0) {
			perror("fcfile: fsync");
			failed = 1;
		}
	} else {
		while (1) {
			ssize_t r = read(fd, buffer, bs);
			if (r < 0) {
				perror("fcfile: read");
				failed = 1;
				break;
			}
			if (r == 0)
				break;
			double t = now_ms();
			bad += compare(buffer, r & ~(size_t)7, seed, done, &first);
			busy += now_ms() - t;
			done += r;
		}
	}
	double elapsed = now_ms() - start;
	if (!write_mode)
		elapsed -= busy;
		// a read waits for its data (the file cache reads no ahead), so the check is left out of its time; the
		// page writer works while the next write's pattern is made, so that stays in, as dd's input does
	close(fd);

	if (check_mode)
		printf("fcfile: check: %.1f MiB", done / 1048576.0);
	else {
		printf("fcfile: %s %zu KiB: %.1f MiB in %.0f ms, %.2f MB/s (%s %.0f ms)", mode, bs >> 10,
			done / 1048576.0, elapsed, elapsed > 0 ? done / elapsed / 1000.0 : 0,
			write_mode ? "pattern" : "check", busy);
	}
	if (!write_mode) {
		if (bad != 0)
			printf(", %llu bad bytes, first at %lld", (unsigned long long)bad, (long long)first);
		else
			printf(", content ok");
	}
	printf("\n");
	return failed || bad != 0;
}
