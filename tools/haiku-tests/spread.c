/*
 * spread.c — does the scheduler spread busy threads of one team over the CPUs? Nothing is pinned.
 *
 *   spread [ROUNDS [WORK]]   (default ROUNDS 200000, WORK 300000000)
 *
 * "pair": two threads meet at a spinning barrier ROUNDS times (an atomic increment, then a load loop with
 * the "yield" hint), as tools/wine-tests/flushwb.c does; the main thread waits in pthread_join(). On two
 * CPUs a round takes well under a microsecond; when both threads share one CPU, each round waits for the
 * other's time slice to end (milliseconds), so the run is cut short after 10 s and the rate printed.
 * "pair (dmb ishst; yield)": the same with the poll loop of arm64 Windows' YieldProcessor() (MSVC and
 * llvm-mingw emit "dmb ishst; yield"), as flushwb-arm64.exe runs it.
 * "busy N": N threads (N = 1..4) each count to WORK; on 4 CPUs the wall time stays that of one thread up
 * to N = 4. "pair after busy 4": the pair again right after the busy threads have exited.
 *
 * Prints "SPREAD pair: <us> us/round (<n> rounds in <s> s)" and "SPREAD busy <N>: <s> s wall, <x> x one".
 *
 * Build (cross):
 *   g=sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc
 *   $g --sysroot=artifacts/sysroot-arm64 -O2 -o spread tools/haiku-tests/spread.c
 */
#include <OS.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

static long sRounds;
static long sWork;
static int32 sArrive;
static volatile int sTimeUp;
static long sDone[2];
static int sDmb;


static void
barrier(long i)
{
	int32 target = 2 * (i + 1);
	__atomic_fetch_add(&sArrive, 1, __ATOMIC_SEQ_CST);
	while (__atomic_load_n(&sArrive, __ATOMIC_ACQUIRE) < target && !sTimeUp) {
		if (sDmb)
			__asm__ volatile("dmb ishst" ::: "memory");
		__asm__ volatile("yield");
	}
}


static void*
side(void* arg)
{
	long i;
	for (i = 0; i < sRounds && !sTimeUp; i++)
		barrier(i);
	sDone[(long)arg] = i;
	return NULL;
}


static void*
timer(void* arg)
{
	bigtime_t end = system_time() + 10000000;
	while (system_time() < end && !*(volatile int*)arg)
		snooze(10000);
	if (!*(volatile int*)arg)
		sTimeUp = 1;
	return NULL;
}


static void*
count(void* arg)
{
	volatile long n = 0;
	for (long i = 0; i < sWork; i++)
		n++;
	return NULL;
}


static void
pair(int dmb, const char* label)
{
	pthread_t a, b, t;
	volatile int finished = 0;
	sDmb = dmb;
	sArrive = 0;
	sTimeUp = 0;
	bigtime_t start = system_time();
	pthread_create(&t, NULL, timer, (void*)&finished);
	pthread_create(&a, NULL, side, (void*)0);
	pthread_create(&b, NULL, side, (void*)1);
	pthread_join(a, NULL);
	pthread_join(b, NULL);
	bigtime_t wall = system_time() - start;
	finished = 1;
	pthread_join(t, NULL);
	long rounds = sDone[0] < sDone[1] ? sDone[0] : sDone[1];
	printf("SPREAD pair%s: %.2f us/round (%ld rounds in %.2f s)%s\n", label,
		rounds ? (double)wall / rounds : 0.0, rounds, wall / 1e6, sTimeUp ? ", cut short" : "");
	fflush(stdout);
}


int
main(int argc, char** argv)
{
	sRounds = argc > 1 ? atol(argv[1]) : 200000;
	sWork = argc > 2 ? atol(argv[2]) : 300000000;

	pair(0, "");
	pair(1, " (dmb ishst; yield)");

	double one = 0;
	for (int n = 1; n <= 4; n++) {
		pthread_t threads[4];
		bigtime_t start = system_time();
		for (int i = 0; i < n; i++)
			pthread_create(&threads[i], NULL, count, NULL);
		for (int i = 0; i < n; i++)
			pthread_join(threads[i], NULL);
		double secs = (system_time() - start) / 1e6;
		if (n == 1)
			one = secs;
		printf("SPREAD busy %d: %.2f s wall, %.2f x one\n", n, secs, secs / one);
		fflush(stdout);
	}
	// again right after the busy threads of the last case have exited (their cores were fully loaded)
	pair(0, " after busy 4");
	pair(0, " after busy 4, again");
	printf("SPREAD end\n");
	return 0;
}
