/*
 * memhog.c — memory bandwidth load without the GPU: N threads (default 4) each copy a 32 MiB buffer to another
 * with memcpy() for SECONDS (default 30), then print the total MB/s. For KNOWN-ISSUES G1: whether HDMI
 * "speckles" come with memory load alone (an HVS underrun a monitor would show too) or only with GL.
 *
 *   memhog [SECONDS [THREADS]]
 *
 * Build (cross):
 *   g=sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc
 *   $g --sysroot=artifacts/sysroot-arm64 -O2 -o memhog tools/haiku-tests/memhog.c
 */
#include <OS.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const size_t kSize = 32 << 20;
static bigtime_t sEnd;


static void*
hog(void* arg)
{
	char* a = malloc(kSize);
	char* b = malloc(kSize);
	memset(a, 1, kSize);
	memset(b, 2, kSize);
	long copies = 0;
	while (system_time() < sEnd) {
		memcpy(b, a, kSize);
		memcpy(a, b, kSize);
		copies += 2;
	}
	free(a);
	free(b);
	return (void*)copies;
}


int
main(int argc, char** argv)
{
	int seconds = argc > 1 ? atoi(argv[1]) : 30;
	int threads = argc > 2 ? atoi(argv[2]) : 4;
	pthread_t t[64];
	if (threads > 64)
		threads = 64;
	sEnd = system_time() + seconds * 1000000LL;
	for (int i = 0; i < threads; i++)
		pthread_create(&t[i], NULL, hog, NULL);
	long copies = 0;
	for (int i = 0; i < threads; i++) {
		void* r;
		pthread_join(t[i], &r);
		copies += (long)r;
	}
	// each copy reads and writes kSize
	printf("MEMHOG %d threads, %d s: %.0f MB/s copied (read + write %.0f MB/s)\n", threads, seconds,
		copies * (double)kSize / seconds / 1e6, 2 * copies * (double)kSize / seconds / 1e6);
	return 0;
}
