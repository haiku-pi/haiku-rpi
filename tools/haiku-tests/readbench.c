/*
 * readbench.c — read() throughput from the file cache into a user buffer at offset 0 and at offset 1 (the
 * kernel's copy to user memory with source and destination aligned alike or not), and from file offset 1.
 *
 *   readbench FILE [ROUNDS]       (a file of a few MB, read once first to have it cached; default 20 rounds)
 *
 * Build (cross):
 *   g="sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc --sysroot=artifacts/sysroot-arm64"
 *   $g -O2 -o readbench tools/haiku-tests/readbench.c
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

static double
now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static double
run(int fd, char* buffer, off_t start, size_t chunk, int rounds)
{
	size_t total = 0;
	double begin = now();
	for (int r = 0; r < rounds; r++) {
		lseek(fd, start, SEEK_SET);
		ssize_t n;
		while ((n = read(fd, buffer, chunk)) > 0)
			total += n;
	}
	return total / (now() - begin) / 1e6;
}

int
main(int argc, char** argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: readbench FILE [ROUNDS]\n");
		return 2;
	}
	int rounds = argc > 2 ? atoi(argv[2]) : 20;
	int fd = open(argv[1], O_RDONLY);
	if (fd < 0) {
		perror(argv[1]);
		return 1;
	}
	size_t chunk = 64 * 1024;
	char* buffer = aligned_alloc(4096, chunk + 4096);
	run(fd, buffer, 0, chunk, 1);
	printf("readbench: 64 KiB reads, MB/s: buffer+0 %.0f, buffer+1 %.0f, file offset 1 %.0f\n",
		run(fd, buffer, 0, chunk, rounds), run(fd, buffer + 1, 0, chunk, rounds),
		run(fd, buffer, 1, chunk, rounds));
	return 0;
}
