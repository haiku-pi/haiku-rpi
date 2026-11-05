/*
 * mmapcat.c — a file's contents as a program's page faults read them: FILE is mapped read-only, its
 * pages are touched in ORDER to fault them in (timed), then the mapping is written to stdout in file
 * order, so that `mmapcat ORDER FILE | md5sum` can be compared with the file's sum taken elsewhere
 * (on the host: what the page fault path put into the cache must be the file, whatever pages it read
 * around the faulting one).
 *
 *   mmapcat forward|reverse|stride|random FILE
 *
 * ORDER: forward = page 0, 1, 2 ...; reverse = the last page first; stride = every 7th page, then the
 * ones skipped (7 passes); random = a fixed permutation (seeded by the page count).
 * Prints "mmapcat: ORDER PAGES pages, T ms, R MB/s" on stderr.
 *
 * Build (cross):
 *   g=sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc
 *   $g --sysroot=artifacts/sysroot-arm64 -O2 -o mmapcat tools/haiku-tests/mmapcat.c
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
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
	if (argc != 3) {
		fprintf(stderr, "usage: mmapcat forward|reverse|stride|random FILE\n");
		return 2;
	}
	const char* order = argv[1];
	int fd = open(argv[2], O_RDONLY);
	struct stat st;
	if (fd < 0 || fstat(fd, &st) != 0) {
		perror(argv[2]);
		return 1;
	}
	if (st.st_size == 0)
		return 0;

	size_t size = st.st_size;
	size_t pageSize = sysconf(_SC_PAGESIZE);
	size_t pages = (size + pageSize - 1) / pageSize;
	const unsigned char* map = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
	if (map == MAP_FAILED) {
		perror("mmap");
		return 1;
	}

	size_t* sequence = malloc(pages * sizeof(size_t));
	if (sequence == NULL)
		return 1;
	size_t n = 0;
	if (strcmp(order, "forward") == 0) {
		for (size_t i = 0; i < pages; i++)
			sequence[n++] = i;
	} else if (strcmp(order, "reverse") == 0) {
		for (size_t i = pages; i-- > 0;)
			sequence[n++] = i;
	} else if (strcmp(order, "stride") == 0) {
		for (size_t start = 0; start < 7; start++) {
			for (size_t i = start; i < pages; i += 7)
				sequence[n++] = i;
		}
	} else if (strcmp(order, "random") == 0) {
		for (size_t i = 0; i < pages; i++)
			sequence[n++] = i;
		srand((unsigned)pages);
		for (size_t i = pages - 1; i > 0; i--) {
			size_t j = (size_t)rand() % (i + 1);
			size_t t = sequence[i];
			sequence[i] = sequence[j];
			sequence[j] = t;
		}
	} else {
		fprintf(stderr, "mmapcat: unknown order %s\n", order);
		return 2;
	}

	volatile unsigned sum = 0;
	double start = now_ms();
	for (size_t i = 0; i < n; i++)
		sum += map[sequence[i] * pageSize];
	(void)sum;
	double elapsed = now_ms() - start;
	fprintf(stderr, "mmapcat: %s %zu pages, %.1f ms, %.1f MB/s\n", order, pages, elapsed,
		elapsed > 0 ? size / 1000.0 / elapsed : 0.0);

	for (size_t done = 0; done < size;) {
		ssize_t written = write(1, map + done, size - done);
		if (written <= 0) {
			perror("write");
			return 1;
		}
		done += written;
	}
	return 0;
}
