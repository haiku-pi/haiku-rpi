/*
 * dlopentime.c — how long the runtime loader takes to load a library and its dependencies (mapping,
 * relocating, running initialisers): dlopen() with RTLD_NOW, timed, then dlclose().
 *
 *   dlopentime LIBRARY [ROUNDS]
 *
 * Not for libxul.so: its initialisers expect to run inside Firefox and wait for ever.
 *
 * Build (cross):
 *   g="sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc --sysroot=artifacts/sysroot-arm64"
 *   $g -O2 -o dlopentime tools/haiku-tests/dlopentime.c
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static double
now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

int
main(int argc, char** argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: dlopentime LIBRARY [ROUNDS]\n");
		return 2;
	}
	int rounds = argc > 2 ? atoi(argv[2]) : 1;
	for (int i = 0; i < rounds; i++) {
		double start = now();
		void* handle = dlopen(argv[1], RTLD_NOW);
		double loaded = now();
		if (handle == NULL) {
			printf("dlopentime: %s\n", dlerror());
			return 1;
		}
		dlclose(handle);
		printf("dlopentime: %s: dlopen %.0f ms, dlclose %.0f ms\n", argv[1], (loaded - start) * 1e3,
			(now() - loaded) * 1e3);
	}
	return 0;
}
