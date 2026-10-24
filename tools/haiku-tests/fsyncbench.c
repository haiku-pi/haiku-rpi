/*
 * fsyncbench.c — what a small synchronous write costs: N times (default 50) write 4 KiB at the end of
 * a file and fsync() it, as a database commit does; prints the mean, the median and the worst fsync.
 *
 *   fsyncbench [FILE [N]]      (default /boot/home/fsyncbench.tmp; the file is removed afterwards)
 *
 * Prints "fsyncbench: FILE: N fsyncs, mean M ms, median D ms, max X ms".
 *
 * Build (cross):
 *   g=sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc
 *   $g --sysroot=artifacts/sysroot-arm64 -O2 -o fsyncbench tools/haiku-tests/fsyncbench.c
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
	const char* path = argc > 1 ? argv[1] : "/boot/home/fsyncbench.tmp";
	int count = argc > 2 ? atoi(argv[2]) : 50;
	if (count < 1)
		count = 1;

	int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) {
		perror(path);
		return 1;
	}

	char block[4096];
	memset(block, 'x', sizeof(block));
	double* times = malloc(count * sizeof(double));
	double total = 0;
	for (int i = 0; i < count; i++) {
		if (write(fd, block, sizeof(block)) != (ssize_t)sizeof(block)) {
			perror("write");
			return 1;
		}
		double start = now_ms();
		if (fsync(fd) != 0) {
			perror("fsync");
			return 1;
		}
		times[i] = now_ms() - start;
		total += times[i];
	}
	close(fd);
	unlink(path);

	qsort(times, count, sizeof(double), compare);
	printf("fsyncbench: %s: %d fsyncs, mean %.1f ms, median %.1f ms, max %.1f ms\n", path, count,
		total / count, times[count / 2], times[count - 1]);
	return 0;
}
