/*
 * castest.c — does a compare-and-swap that fails spuriously look like success? (RenkuOS #189,
 * design/renkuos-fixes.md). atomic_test_and_set() returns the value it found; up to 2026-11-04 Haiku's
 * SupportDefs.h built it on a *weak* __atomic_compare_exchange_n(), which may fail although the value
 * matched (a store-exclusive that lost its reservation) and then also returns the expected value: the
 * caller believes it stored. Whether that can happen depends on the code the compiler makes:
 *
 *   weak     the old body, as an LL/SC sequence only without outline atomics (-mno-outline-atomics):
 *            no retry after a failed store-exclusive
 *   strong   the new body under the same flags: the store-exclusive is retried
 *   header   atomic_test_and_set() from the SupportDefs.h this was compiled with, under the build's
 *            default flags (GCC 16: -moutline-atomics, libgcc's __aarch64_cas4_acq_rel, which retries)
 *
 * Each variant: for SECS seconds THREADS threads take a test-and-set lock built on it and increment a
 * plain counter inside it, while NOISE threads now and then store to another word on the lock's cache line
 * (such a store clears the other CPUs' exclusive reservations, so store-exclusives fail). Reports the
 * acquisitions, the counter's shortfall (lost increments: two owners at once) and "false" acquisitions
 * (the lock word still 0 right after acquiring it). A correct CAS has both at 0. (The other workers' own
 * stores make a store-exclusive fail too: a weak CAS that loaded 0 then returns 0 although the lock was
 * just taken.)
 *
 *   castest [SECS [THREADS [NOISE]]]         default 3 4 1 (a Pi 4 has 4 CPUs)
 *
 * Output: "CASTEST <variant> acquired=.. lost=.. false=.." per variant, then "CASTEST end".
 * Build (cross; the weak/strong variants need -mno-outline-atomics, which the Makefile-less build below
 * applies to this whole file, so the "header" variant comes from castest-header.o built without it):
 *   g=sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc
 *   $g --sysroot=artifacts/sysroot-arm64 -O2 -DCASTEST_HEADER_ONLY -c -o castest-header.o tools/haiku-tests/castest.c
 *   $g --sysroot=artifacts/sysroot-arm64 -O2 -mno-outline-atomics -o castest tools/haiku-tests/castest.c castest-header.o
 */
#include <OS.h>
#include <SupportDefs.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>


#ifdef CASTEST_HEADER_ONLY

int32
castest_header_test_and_set(int32* value, int32 newValue, int32 testAgainst)
{
	return atomic_test_and_set(value, newValue, testAgainst);
}

#else

typedef int32 (*test_and_set_fn)(int32* value, int32 newValue, int32 testAgainst);

extern int32 castest_header_test_and_set(int32* value, int32 newValue, int32 testAgainst);


static int32
weak_test_and_set(int32* value, int32 newValue, int32 testAgainst)
{
	__atomic_compare_exchange_n(value, &testAgainst, newValue, 1,
		__ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
	return testAgainst;
}


static int32
strong_test_and_set(int32* value, int32 newValue, int32 testAgainst)
{
	__atomic_compare_exchange_n(value, &testAgainst, newValue, 0,
		__ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
	return testAgainst;
}


// the lock and the noise share one 64-byte line; the counter has its own
static struct {
	int32 lock;
	int32 noise[15];
} sLine __attribute__((aligned(64)));
static volatile int64 sCounter __attribute__((aligned(64)));
static int64 sFalse;
static int64 sAcquired;
static volatile int sStop;
static volatile int sStopWorkers;
static test_and_set_fn sTestAndSet;


static void*
worker(void* arg)
{
	int64 falseAcquisitions = 0, acquired = 0;
	while (!sStopWorkers) {
		while (sTestAndSet(&sLine.lock, 1, 0) != 0)
			;
		acquired++;
		if (__atomic_load_n(&sLine.lock, __ATOMIC_RELAXED) == 0)
			falseAcquisitions++;
		sCounter = sCounter + 1;
		__atomic_store_n(&sLine.lock, 0, __ATOMIC_RELEASE);
	}
	__atomic_fetch_add(&sFalse, falseAcquisitions, __ATOMIC_RELAXED);
	__atomic_fetch_add(&sAcquired, acquired, __ATOMIC_RELAXED);
	return NULL;
}


static void*
noise(void* arg)
{
	int32* word = &sLine.noise[(intptr_t)arg % 15];
	while (!sStop) {
		__atomic_store_n(word, *word + 1, __ATOMIC_RELAXED);
		for (volatile int i = 0; i < 100; i++)
			;
	}
	return NULL;
}


static void
run(const char* name, test_and_set_fn function, int seconds, int threads, int noiseThreads)
{
	pthread_t worker_threads[64], noise_threads[64];
	sTestAndSet = function;
	sCounter = 0;
	sFalse = 0;
	sAcquired = 0;
	sStop = 0;
	sStopWorkers = 0;
	sLine.lock = 0;

	for (int i = 0; i < noiseThreads; i++)
		pthread_create(&noise_threads[i], NULL, noise, (void*)(intptr_t)i);
	for (int i = 0; i < threads; i++)
		pthread_create(&worker_threads[i], NULL, worker, NULL);
	snooze((bigtime_t)seconds * 1000000);
	sStopWorkers = 1;
	for (int i = 0; i < threads; i++)
		pthread_join(worker_threads[i], NULL);
	sStop = 1;
	for (int i = 0; i < noiseThreads; i++)
		pthread_join(noise_threads[i], NULL);

	printf("CASTEST %s acquired=%" B_PRId64 " lost=%" B_PRId64 " false=%" B_PRId64 "\n",
		name, sAcquired, sAcquired - sCounter, sFalse);
	fflush(stdout);
}


int
main(int argc, char** argv)
{
	int seconds = argc > 1 ? atoi(argv[1]) : 3;
	int threads = argc > 2 ? atoi(argv[2]) : 4;
	int noiseThreads = argc > 3 ? atoi(argv[3]) : 1;
	if (threads > 64)
		threads = 64;
	if (noiseThreads > 64)
		noiseThreads = 64;

	run("weak", weak_test_and_set, seconds, threads, noiseThreads);
	run("strong", strong_test_and_set, seconds, threads, noiseThreads);
	run("header", castest_header_test_and_set, seconds, threads, noiseThreads);
	printf("CASTEST end\n");
	return 0;
}

#endif
