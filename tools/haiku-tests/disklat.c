/*
 * disklat.c — what one read from a disk device costs by request size: N reads (default 200) of each size
 * at random aligned offsets within the first 2 GiB of the raw device (not cached by the file cache),
 * timed one by one; prints the mean time per read and the resulting throughput. A per-request cost shows
 * as a time that does not fall in proportion with the size.
 *
 *   disklat DEVICE [N]          (e.g. /dev/disk/mmc/0/raw)
 *
 * Prints "disklat: SIZE KiB: mean M ms, median D ms, T MB/s" per size.
 *
 * Build (cross):
 *   g=sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc
 *   $g --sysroot=artifacts/sysroot-arm64 -O2 -o disklat tools/haiku-tests/disklat.c
 */
#include <fcntl.h>
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


static int
compare(const void* a, const void* b)
{
	double x = *(const double*)a, y = *(const double*)b;
	return x < y ? -1 : x > y;
}


int
main(int argc, char** argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: disklat DEVICE [N]\n");
		return 2;
	}
	int count = argc > 2 ? atoi(argv[2]) : 200;
	if (count < 1)
		count = 1;

	int fd = open(argv[1], O_RDONLY);
	if (fd < 0) {
		perror(argv[1]);
		return 1;
	}

	static const size_t kSizes[] = { 4096, 16384, 32768, 65536, 131072, 1048576 };
	const off_t span = 2LL * 1024 * 1024 * 1024;
	void* buffer = malloc(1048576);
	double* times = malloc(count * sizeof(double));
	srandom(1);

	for (size_t s = 0; s < sizeof(kSizes) / sizeof(kSizes[0]); s++) {
		size_t size = kSizes[s];
		double total = 0;
		for (int i = 0; i < count; i++) {
			off_t offset = ((off_t)random() * 4096) % (span - size);
			offset -= offset % size;
			double start = now_ms();
			if (pread(fd, buffer, size, offset) != (ssize_t)size) {
				perror("pread");
				return 1;
			}
			times[i] = now_ms() - start;
			total += times[i];
		}
		qsort(times, count, sizeof(double), compare);
		double mean = total / count;
		printf("disklat: %zu KiB: mean %.3f ms, median %.3f ms, %.1f MB/s\n", size / 1024, mean,
			times[count / 2], size / mean / 1000.0);
	}
	close(fd);
	return 0;
}
