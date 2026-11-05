/*
 * diskwrite.c — raw write speed of a disk device, the same program on Haiku and on Linux (the flash lane), so
 * that both systems issue the same requests: sequential writes of BS bytes (TOTAL bytes in all, starting at
 * OFFSET), or COUNT random aligned writes of BS bytes within SPAN bytes from OFFSET; synced at the end (fsync,
 * timed with the writes). On Linux the device is opened with O_DIRECT (no page cache); Haiku's raw disk
 * devices are not cached. DESTROYS the data in the written range.
 *
 *   diskwrite DEVICE seq OFFSET_MIB BS_KIB TOTAL_MIB
 *   diskwrite DEVICE rand OFFSET_MIB BS_KIB COUNT SPAN_MIB
 *
 * Prints "diskwrite: seq|rand BS KiB: N MiB in T ms, R MB/s[, I writes/s]" (MB = 10^6 bytes).
 * The buffer holds pseudo-random bytes (an SD card does not compress, but this rules it out).
 *
 * Build (cross):
 *   Haiku: sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc \
 *            --sysroot=artifacts/sysroot-arm64 -O2 -o diskwrite tools/haiku-tests/diskwrite.c
 *   Linux: aarch64-linux-gnu-gcc -static -O2 -o diskwrite-linux tools/haiku-tests/diskwrite.c
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#ifndef O_DIRECT
#	define O_DIRECT 0
#endif


static double
now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000.0 + ts.tv_nsec / 1000000.0;
}


int
main(int argc, char** argv)
{
	if (argc < 6 || (strcmp(argv[2], "seq") != 0 && strcmp(argv[2], "rand") != 0)
		|| (strcmp(argv[2], "rand") == 0 && argc < 7)) {
		fprintf(stderr, "usage: diskwrite DEVICE seq OFFSET_MIB BS_KIB TOTAL_MIB\n"
			"       diskwrite DEVICE rand OFFSET_MIB BS_KIB COUNT SPAN_MIB\n");
		return 2;
	}
	const int random_mode = strcmp(argv[2], "rand") == 0;
	const off_t base = (off_t)atoll(argv[3]) << 20;
	const size_t size = (size_t)atol(argv[4]) << 10;
	long long count;
	off_t span = 0;
	if (random_mode) {
		count = atoll(argv[5]);
		span = (off_t)atoll(argv[6]) << 20;
	} else
		count = ((long long)atoll(argv[5]) << 20) / size;
	if (size == 0 || count <= 0 || (random_mode && span < (off_t)size)) {
		fprintf(stderr, "diskwrite: bad sizes\n");
		return 2;
	}

	int fd = open(argv[1], O_WRONLY | O_DIRECT);
	if (fd < 0) {
		perror(argv[1]);
		return 1;
	}

	void* buffer;
	if (posix_memalign(&buffer, 4096, size) != 0) {
		fprintf(stderr, "diskwrite: no memory\n");
		return 1;
	}
	uint32_t x = 2463534242u;
	for (size_t i = 0; i < size / 4; i++) {
		x ^= x << 13;
		x ^= x >> 17;
		x ^= x << 5;
		((uint32_t*)buffer)[i] = x;
	}

	srandom(1);
	const double start = now_ms();
	for (long long i = 0; i < count; i++) {
		off_t offset = base + (off_t)i * size;
		if (random_mode) {
			offset = ((off_t)random() * 4096) % (span - size);
			offset = base + offset - offset % size;
		}
		if (pwrite(fd, buffer, size, offset) != (ssize_t)size) {
			perror("pwrite");
			return 1;
		}
	}
	if (fsync(fd) != 0)
		perror("fsync");
	const double elapsed = now_ms() - start;
	close(fd);

	const double bytes = (double)count * size;
	printf("diskwrite: %s %zu KiB: %.1f MiB in %.0f ms, %.2f MB/s", argv[2], size >> 10,
		bytes / 1048576, elapsed, bytes / elapsed / 1000.0);
	if (random_mode)
		printf(", %.0f writes/s", count / elapsed * 1000.0);
	printf("\n");
	return 0;
}
