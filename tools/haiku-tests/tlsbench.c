/*
 * tlsbench.c — the cost of a thread-local variable in a shared library (general-dynamic TLS, i.e. a call
 * to __tls_get_addr per access, as -fPIC code such as libpython does), next to a plain global.
 *
 *   tlsbench [MILLIONS [COPY]]   (default 50 million accesses each)
 *
 * COPY: a copy of libtlsbench.so under another name (e.g. ./libtlsbench2.so), dlopen()ed: its thread-local
 * variable is then measured too. Since haiku n5-tls the library the program links is in the static TLS
 * block (no generation check), a dlopen()ed one still in the dynamic thread vector.
 *
 * Build (cross): the same file is the library (-DTLSBENCH_LIB) and the program:
 *   g=sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc --sysroot=artifacts/sysroot-arm64
 *   $g -O2 -fPIC -shared -DTLSBENCH_LIB -o libtlsbench.so tools/haiku-tests/tlsbench.c
 *   $g -O2 -o tlsbench tools/haiku-tests/tlsbench.c -L. -ltlsbench
 * Put libtlsbench.so next to the program in a lib/ directory, or into ~/config/non-packaged/lib.
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#ifdef TLSBENCH_LIB

static __thread long sThreadCounter;
static long sCounter;

long
tlsbench_thread_add(long value)
{
	return sThreadCounter += value;
}

long
tlsbench_global_add(long value)
{
	return sCounter += value;
}

#else

long tlsbench_thread_add(long value);
long tlsbench_global_add(long value);


static double
now()
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}


int
main(int argc, char** argv)
{
	long count = (argc > 1 ? atol(argv[1]) : 50) * 1000000L;
	long sum = 0;

	double start = now();
	for (long i = 0; i < count; i++)
		sum += tlsbench_global_add(1);
	double global = now() - start;

	start = now();
	for (long i = 0; i < count; i++)
		sum += tlsbench_thread_add(1);
	double thread = now() - start;

	printf("tlsbench: global %.2f ns, thread-local %.2f ns per call (%ld million; %ld)\n",
		global * 1e9 / count, thread * 1e9 / count, count / 1000000, sum & 1);

	if (argc > 2) {
		void* library = dlopen(argv[2], RTLD_NOW | RTLD_LOCAL);
		long (*add)(long) = library != NULL
			? (long (*)(long))dlsym(library, "tlsbench_thread_add") : NULL;
		if (add == NULL) {
			printf("tlsbench: cannot use %s: %s\n", argv[2], dlerror());
			return 1;
		}
		start = now();
		for (long i = 0; i < count; i++)
			sum += add(1);
		double dynamic = now() - start;
		printf("tlsbench: dlopened thread-local %.2f ns per call (%ld)\n",
			dynamic * 1e9 / count, sum & 1);
	}
	return 0;
}

#endif
