/*
 * tlsunload.c — thread-local storage of shared libraries across dlclose()/dlopen(): a library's TLS
 * module ID is reused by the next library loaded, and every thread must then see that library's initial
 * values, not the blocks of the unloaded one. Checks the main thread and a thread that already used the
 * first library, and per-thread separation.
 *
 *   tlsunload [ROUNDS]        prints "tlsunload: PASS" or the first mismatch and exits 1
 *
 * Build (cross): the same file is the two libraries and the program:
 *   g="sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc --sysroot=artifacts/sysroot-arm64"
 *   $g -O2 -fPIC -shared -DTLSUNLOAD_LIB=11 -o libtlsa.so tools/haiku-tests/tlsunload.c
 *   $g -O2 -fPIC -shared -DTLSUNLOAD_LIB=22 -o libtlsb.so tools/haiku-tests/tlsunload.c
 *   $g -O2 -o tlsunload tools/haiku-tests/tlsunload.c
 * Run it from the directory holding the two libraries.
 */
#ifdef TLSUNLOAD_LIB

static __thread long sValue = TLSUNLOAD_LIB;
static __thread char sBig[4096] = { TLSUNLOAD_LIB };

long*
tls_value(void)
{
	return &sValue;
}

char*
tls_big(void)
{
	return sBig;
}

#else

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

typedef long* (*value_function)(void);
typedef char* (*big_function)(void);

static int sFailures;


static void
check(const char* what, long got, long expected)
{
	if (got != expected && sFailures++ == 0)
		printf("tlsunload: FAIL: %s: %ld, expected %ld\n", what, got, expected);
}


struct library {
	void* handle;
	value_function value;
	big_function big;
};


static void
load(struct library* library, const char* path)
{
	library->handle = dlopen(path, RTLD_NOW);
	if (library->handle == NULL) {
		printf("tlsunload: FAIL: dlopen %s: %s\n", path, dlerror());
		exit(1);
	}
	library->value = (value_function)dlsym(library->handle, "tls_value");
	library->big = (big_function)dlsym(library->handle, "tls_big");
}


// a thread of its own: uses whichever library is loaded at each step it is told to take
static pthread_mutex_t sLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t sCondition = PTHREAD_COND_INITIALIZER;
static int sStep, sDone;
static struct library* sLibrary;
static long sExpected;


static void*
worker(void* unused)
{
	(void)unused;
	pthread_mutex_lock(&sLock);
	for (int step = 1;; step++) {
		while (sStep < step)
			pthread_cond_wait(&sCondition, &sLock);
		if (sLibrary == NULL)
			break;
		check("worker: initial value", *sLibrary->value(), sExpected);
		check("worker: initial array", sLibrary->big()[0], sExpected);
		*sLibrary->value() = 1000 + step;
		sLibrary->big()[0] = 5;
		check("worker: own value", *sLibrary->value(), 1000 + step);
		sDone = step;
		pthread_cond_broadcast(&sCondition);
	}
	pthread_mutex_unlock(&sLock);
	return NULL;
}


static void
run_worker_step(struct library* library, long expected)
{
	pthread_mutex_lock(&sLock);
	sLibrary = library;
	sExpected = expected;
	int step = ++sStep;
	pthread_cond_broadcast(&sCondition);
	while (library != NULL && sDone < step)
		pthread_cond_wait(&sCondition, &sLock);
	pthread_mutex_unlock(&sLock);
}


int
main(int argc, char** argv)
{
	int rounds = argc > 1 ? atoi(argv[1]) : 100;
	pthread_t thread;
	pthread_create(&thread, NULL, worker, NULL);

	for (int round = 0; round < rounds && sFailures == 0; round++) {
		const char* paths[2] = { "./libtlsa.so", "./libtlsb.so" };
		long initial[2] = { 11, 22 };
		for (int i = 0; i < 2; i++) {
			struct library library;
			load(&library, paths[i]);
			check("main: initial value", *library.value(), initial[i]);
			check("main: initial array", library.big()[0], initial[i]);
			*library.value() = 99;
			library.big()[0] = 7;
			run_worker_step(&library, initial[i]);
			check("main: own value after the worker's", *library.value(), 99);
			check("main: own array after the worker's", library.big()[0], 7);
			dlclose(library.handle);
		}
	}

	run_worker_step(NULL, 0);
	pthread_join(thread, NULL);
	if (sFailures == 0)
		printf("tlsunload: PASS (%d rounds)\n", rounds);
	return sFailures != 0;
}

#endif
