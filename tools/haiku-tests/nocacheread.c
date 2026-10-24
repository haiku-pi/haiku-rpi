/*
 * nocacheread.c — how fast a file opened with O_NOCACHE reads (as packagefs reads package files), by
 * request size and alignment: the file read from start to end in requests of SIZE bytes, at offsets
 * aligned to 4 KiB or shifted by 1000 bytes; each pass over a fresh part of the file, so no pass reads
 * data an earlier one read.
 *
 *   nocacheread FILE [MB]         (MB per pass, default 16)
 *
 * Prints "nocacheread: SIZE KiB aligned|unaligned: N MB/s, M ms per request".
 *
 * Build (cross):
 *   g=sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc
 *   $g --sysroot=artifacts/sysroot-arm64 -O2 -o nocacheread tools/haiku-tests/nocacheread.c
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>


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
	if (argc < 2) {
		fprintf(stderr, "usage: nocacheread FILE [MB]\n");
		return 2;
	}
	off_t passBytes = (argc > 2 ? atoi(argv[2]) : 16) * 1024LL * 1024;

	int fd = open(argv[1], O_RDONLY | O_NOCACHE);
	if (fd < 0) {
		perror(argv[1]);
		return 1;
	}

	static const size_t kSizes[] = { 21 * 1024, 65536, 262144 };
	char* buffer = malloc(262144 + 4096);
	off_t start = 0;
	for (size_t s = 0; s < sizeof(kSizes) / sizeof(kSizes[0]); s++) {
		for (int unaligned = 0; unaligned < 2; unaligned++) {
			size_t size = kSizes[s];
			off_t offset = start + (unaligned ? 1000 : 0);
			int requests = 0;
			double begin = now_ms();
			while (offset + (off_t)size <= start + passBytes) {
				if (pread(fd, buffer, size, offset) != (ssize_t)size) {
					perror("pread");
					return 1;
				}
				offset += size;
				requests++;
			}
			double elapsed = now_ms() - begin;
			printf("nocacheread: %zu KiB %s: %.1f MB/s, %.3f ms per request\n", size / 1024,
				unaligned ? "unaligned" : "aligned", requests * (double)size / elapsed / 1000.0,
				elapsed / requests);
			start += passBytes;
		}
	}
	close(fd);
	return 0;
}
