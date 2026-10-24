/*
 * membench.c — throughput of libroot's memcpy, memmove, memset, memcmp, strlen and memchr on this machine,
 * for sizes from 16 bytes to 4 MiB, with source and destination aligned alike and misaligned against each
 * other (dst at +0, src at +1/+3).
 *
 *   membench [SECONDS-PER-CASE]        (default 0.2)
 *
 * Prints MB/s per routine and size. Build (cross):
 *   g="sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc --sysroot=artifacts/sysroot-arm64"
 *   $g -O2 -fno-builtin -o membench tools/haiku-tests/membench.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double
now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

enum { MEMCPY, MEMCPY_MISALIGNED, MEMMOVE_OVERLAP, MEMSET, MEMCMP, STRLEN, MEMCHR, ROUTINES };
static const char* kNames[ROUTINES] = { "memcpy", "memcpy+1", "memmove-ovl", "memset", "memcmp",
	"strlen", "memchr" };

static volatile size_t sSink;

int
main(int argc, char** argv)
{
	double seconds = argc > 1 ? atof(argv[1]) : 0.2;
	static const size_t kSizes[] = { 16, 64, 256, 1024, 4096, 65536, 1 << 20, 4 << 20 };
	size_t maxSize = 4 << 20;
	char* a = malloc(maxSize + 64);
	char* b = malloc(maxSize + 64);
	memset(a, 'x', maxSize + 64);
	memset(b, 'x', maxSize + 64);

	printf("%-12s", "MB/s");
	for (size_t s = 0; s < sizeof(kSizes) / sizeof(kSizes[0]); s++)
		printf(" %9zu", kSizes[s]);
	printf("\n");

	for (int routine = 0; routine < ROUTINES; routine++) {
		printf("%-12s", kNames[routine]);
		for (size_t s = 0; s < sizeof(kSizes) / sizeof(kSizes[0]); s++) {
			size_t size = kSizes[s];
			char* dst = b;
			char* src = routine == MEMCPY_MISALIGNED ? a + 1 : a;
			if (routine == MEMCMP)
				memcpy(b, a, size);	/* equal: compares the whole size */
			if (routine == STRLEN || routine == MEMCHR) {
				memset(a, 'x', size);
				a[size - 1] = 0;
			}
			long iterations = 0;
			double start = now(), elapsed;
			do {
				for (int i = 0; i < 64; i++) {
					switch (routine) {
						case MEMCPY:
						case MEMCPY_MISALIGNED:
							memcpy(dst, src, size);
							break;
						case MEMMOVE_OVERLAP:
							memmove(b + 3, b, size);
							break;
						case MEMSET:
							memset(dst, i, size);
							break;
						case MEMCMP:
							sSink += memcmp(a, b, size);
							break;
						case STRLEN:
							sSink += strlen(a);
							break;
						case MEMCHR:
							sSink += (size_t)memchr(a, 0, size);
							break;
					}
				}
				iterations += 64;
				elapsed = now() - start;
			} while (elapsed < seconds);
			if (routine == STRLEN || routine == MEMCHR)
				a[size - 1] = 'x';
			printf(" %9.0f", iterations * (double)size / elapsed / 1e6);
		}
		printf("\n");
	}
	return 0;
}
