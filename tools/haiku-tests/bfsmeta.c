/*
 * bfsmeta.c — a metadata-heavy write load on a BFS volume, as a browser's new profile makes it: many small
 * files in one directory, each created, written in a few small appends and given a few attributes. Every
 * one of those calls is a BFS transaction; the journal batches them into one combined transaction (up to
 * half its log), so the cost of a transaction start that walks the combined transaction shows here as a
 * per-file time that grows within each batch (perf-round-h20.md N6).
 *
 *   bfsmeta DIR [N [WRITES [ATTRS]]]   N files (default 4000), WRITES appends of 512 bytes (default 4),
 *                                      ATTRS attributes of 40 bytes (default 2); DIR is created, must be new
 *   bfsmeta --loop DIR [KEEP]          endless: create files as above, removing the oldest once KEEP
 *                                      (default 3000) exist; a progress line every 1000 files (power-cut test)
 *
 * Prints "bfsmeta: batch B: files F..G: U us/file" every 250 files and
 * "bfsmeta: N files, W writes, A attrs: T ms, U us/file, sys S ms, user R ms".
 *
 * Build (cross):
 *   g=sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc
 *   $g --sysroot=artifacts/sysroot-arm64 -O2 -o bfsmeta tools/haiku-tests/bfsmeta.c
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <fs_attr.h>
#include <TypeConstants.h>


static long long
now_us(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000000LL + ts.tv_nsec / 1000;
}


static long long
tv_ms(struct timeval tv)
{
	return tv.tv_sec * 1000LL + tv.tv_usec / 1000;
}


static void
make_file(const char* dir, long index, int writes, int attrs)
{
	char path[1024], data[512], value[40], name[32];
	memset(data, 'a' + index % 26, sizeof(data));
	memset(value, 'v', sizeof(value));
	snprintf(path, sizeof(path), "%s/f%07ld", dir, index);

	int fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0644);
	if (fd < 0) {
		fprintf(stderr, "bfsmeta: %s: %s\n", path, strerror(errno));
		exit(1);
	}
	for (int i = 0; i < writes; i++) {
		if (write(fd, data, sizeof(data)) != (ssize_t)sizeof(data)) {
			fprintf(stderr, "bfsmeta: write %s: %s\n", path, strerror(errno));
			exit(1);
		}
	}
	for (int i = 0; i < attrs; i++) {
		snprintf(name, sizeof(name), "bfsmeta:attr%d", i);
		if (fs_write_attr(fd, name, B_STRING_TYPE, 0, value, sizeof(value)) != (ssize_t)sizeof(value)) {
			fprintf(stderr, "bfsmeta: attr %s: %s\n", path, strerror(errno));
			exit(1);
		}
	}
	close(fd);
}


static int
loop(const char* dir, long keep)
{
	char path[1024];
	long long start = now_us();
	for (long i = 0;; i++) {
		make_file(dir, i, 4, 2);
		if (i >= keep) {
			snprintf(path, sizeof(path), "%s/f%07ld", dir, i - keep);
			if (unlink(path) != 0) {
				fprintf(stderr, "bfsmeta: unlink %s: %s\n", path, strerror(errno));
				return 1;
			}
		}
		if ((i + 1) % 1000 == 0) {
			printf("bfsmeta: loop: %ld files, %lld ms\n", i + 1, (now_us() - start) / 1000);
			fflush(stdout);
		}
	}
}


int
main(int argc, char** argv)
{
	if (argc >= 3 && strcmp(argv[1], "--loop") == 0) {
		if (mkdir(argv[2], 0755) != 0 && errno != EEXIST) {
			fprintf(stderr, "bfsmeta: %s: %s\n", argv[2], strerror(errno));
			return 1;
		}
		return loop(argv[2], argc > 3 ? atol(argv[3]) : 3000);
	}
	if (argc < 2) {
		fprintf(stderr, "usage: bfsmeta DIR [N [WRITES [ATTRS]]] | bfsmeta --loop DIR [KEEP]\n");
		return 2;
	}
	const char* dir = argv[1];
	long count = argc > 2 ? atol(argv[2]) : 4000;
	int writes = argc > 3 ? atoi(argv[3]) : 4;
	int attrs = argc > 4 ? atoi(argv[4]) : 2;
	if (mkdir(dir, 0755) != 0) {
		fprintf(stderr, "bfsmeta: %s: %s\n", dir, strerror(errno));
		return 1;
	}

	long long start = now_us(), batchStart = start;
	for (long i = 0; i < count; i++) {
		make_file(dir, i, writes, attrs);
		if ((i + 1) % 250 == 0) {
			long long t = now_us();
			printf("bfsmeta: batch %ld: files %ld..%ld: %lld us/file\n", (i + 1) / 250, i - 249, i,
				(t - batchStart) / 250);
			batchStart = t;
		}
	}
	long long total = now_us() - start;

	struct rusage usage;
	getrusage(RUSAGE_SELF, &usage);
	printf("bfsmeta: %ld files, %d writes, %d attrs: %lld ms, %lld us/file, sys %lld ms, user %lld ms\n",
		count, writes, attrs, total / 1000, total / count, tv_ms(usage.ru_stime), tv_ms(usage.ru_utime));
	return 0;
}
