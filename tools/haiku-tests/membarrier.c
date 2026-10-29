/*
 * membarrier.c — the kernel's team memory barrier (_kern_team_memory_barrier(), wrapped by libroot's private
 * __team_memory_barrier(); what Wine's NtFlushProcessWriteBuffers uses, as Linux Wine uses membarrier with
 * MEMBARRIER_CMD_PRIVATE_EXPEDITED): what it guarantees, with a store-buffering litmus test, and what a call
 * costs.
 *
 *   membarrier [ROUNDS [CALLS]]     (default 100000 litmus rounds per variant, 20000 calls per cost case)
 *
 * Litmus: two threads pinned to CPUs 0 and 1 (pthread_setaffinity_np), fresh cells every round:
 *     A: x = 1; r0 = y;             B: y = 1; <barrier>; r1 = x;
 * r0 == 0 && r1 == 0 (both loads before both stores became visible) is the store-buffering outcome. A never
 * executes a barrier of its own. Variants of B's <barrier>:
 *     none    nothing: the outcome must show up on a weakly ordered CPU, or the harness cannot see a reordering
 *     delay   B spins as long as one team-barrier call takes (timing alone, no barrier)
 *     team    __team_memory_barrier(0): the outcome is forbidden
 *     fence   a full fence on both sides (the symmetric reference)
 * On real hardware a store leaves the store buffer within nanoseconds, so "delay" passes as well: the
 * litmus shows the call works and the harness can see reorderings; the guarantee itself is the kernel's
 * (an interrupt with a full barrier on each CPU running a thread of the team).
 * Prints "MEMBARRIER litmus <variant>: <n> of <rounds> forbidden (r0=0 r1=0)".
 *
 * Cost: microseconds per call with N other threads of this team spinning (pinned to CPUs 1, 2, ..., then
 * sharing CPU 0 with the caller), and with threads of ANOTHER team (a forked child) spinning on every other
 * CPU: only CPUs that run a thread of the caller's team get an interrupt.
 * Prints "MEMBARRIER cost <N> busy (own|other team): <us> us/call".
 *
 * Without the system call (an older Haiku) it says "MEMBARRIER unavailable" and runs only none/fence.
 *
 * Build (cross):
 *   g=sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc
 *   $g --sysroot=artifacts/sysroot-arm64 -O2 -o membarrier tools/haiku-tests/membarrier.c -lgnu
 */
#define _GNU_SOURCE
#include <OS.h>
#include <dlfcn.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

enum { NONE, DELAY, TEAM, FENCE };
static const char* const kVariantNames[] = { "none", "delay", "team", "fence" };

static status_t (*sTeamBarrier)(uint32 flags);
static int sRounds = 100000;
static int sCPUs;
static bigtime_t sDelay;	/* "delay": one call's duration, in microseconds */

static int *sX, *sY, *sR0, *sR1;
static int sVariant;
static int32 sArrive;
static volatile int sStop;


static void
pin(int cpu)
{
	cpuset_t set;
	CPU_ZERO(&set);
	CPU_SET(cpu % sCPUs, &set);
	pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
}


/* both threads arrive before round i starts */
static void
round_barrier(int i)
{
	int32 target = 2 * (i + 1);
	__atomic_add_fetch(&sArrive, 1, __ATOMIC_SEQ_CST);
	while (__atomic_load_n(&sArrive, __ATOMIC_ACQUIRE) < target)
		;
}


static void*
side_a(void* arg)
{
	pin(0);
	for (int i = 0; i < sRounds; i++) {
		round_barrier(i);
		__atomic_store_n(&sX[i], 1, __ATOMIC_RELAXED);
		if (sVariant == FENCE)
			__atomic_thread_fence(__ATOMIC_SEQ_CST);
		else
			__asm__ __volatile__("" : : : "memory");
		sR0[i] = __atomic_load_n(&sY[i], __ATOMIC_RELAXED);
	}
	return arg;
}


static void*
side_b(void* arg)
{
	pin(1);
	for (int i = 0; i < sRounds; i++) {
		round_barrier(i);
		__atomic_store_n(&sY[i], 1, __ATOMIC_RELAXED);
		switch (sVariant) {
			case NONE:
				__asm__ __volatile__("" : : : "memory");
				break;
			case DELAY:
			{
				bigtime_t end = system_time() + sDelay;
				while (system_time() < end)
					__asm__ __volatile__("" : : : "memory");
				break;
			}
			case TEAM:
				sTeamBarrier(0);
				break;
			case FENCE:
				__atomic_thread_fence(__ATOMIC_SEQ_CST);
				break;
		}
		sR1[i] = __atomic_load_n(&sX[i], __ATOMIC_RELAXED);
	}
	return arg;
}


static void
litmus(int variant)
{
	size_t size = sizeof(int) * (size_t)sRounds;
	sX = calloc(1, size); sY = calloc(1, size); sR0 = calloc(1, size); sR1 = calloc(1, size);
	sVariant = variant;
	sArrive = 0;
	pthread_t a, b;
	pthread_create(&a, NULL, side_a, NULL);
	pthread_create(&b, NULL, side_b, NULL);
	pthread_join(a, NULL);
	pthread_join(b, NULL);
	int forbidden = 0;
	for (int i = 0; i < sRounds; i++)
		forbidden += sR0[i] == 0 && sR1[i] == 0;
	printf("MEMBARRIER litmus %s: %d of %d forbidden (r0=0 r1=0)\n", kVariantNames[variant], forbidden,
		sRounds);
	fflush(stdout);
	free(sX); free(sY); free(sR0); free(sR1);
}


static void*
spin(void* arg)
{
	pin((int)(intptr_t)arg);
	while (!sStop)
		__asm__ __volatile__("" : : : "memory");
	return NULL;
}


/* microseconds per call, from CPU 0 */
static double
time_calls(int calls)
{
	pin(0);
	snooze(20000);	/* let the spinners reach their CPUs */
	bigtime_t start = system_time();
	for (int i = 0; i < calls; i++)
		sTeamBarrier(0);
	return (double)(system_time() - start) / calls;
}


static void
cost(int busy, int calls)
{
	pthread_t threads[64];
	sStop = 0;
	for (int i = 0; i < busy; i++)
		pthread_create(&threads[i], NULL, spin, (void*)(intptr_t)(1 + i));
	double us = time_calls(calls);
	sStop = 1;
	for (int i = 0; i < busy; i++)
		pthread_join(threads[i], NULL);
	printf("MEMBARRIER cost %d busy (own team): %.2f us/call\n", busy, us);
	fflush(stdout);
}


/* a child team spinning on CPUs 1..n-1 while this team (one thread) calls */
static void
cost_other_team(int calls)
{
	pid_t child = fork();
	if (child == 0) {
		pthread_t threads[64];
		for (int i = 1; i < sCPUs; i++)
			pthread_create(&threads[i], NULL, spin, (void*)(intptr_t)i);
		for (;;)
			snooze(1000000);
	}
	double us = time_calls(calls);
	kill(child, SIGKILL);
	waitpid(child, NULL, 0);
	printf("MEMBARRIER cost %d busy (other team): %.2f us/call\n", sCPUs - 1, us);
	fflush(stdout);
}


int
main(int argc, char** argv)
{
	int calls = 20000;
	if (argc > 1)
		sRounds = atoi(argv[1]);
	if (argc > 2)
		calls = atoi(argv[2]);
	system_info info;
	get_system_info(&info);
	sCPUs = info.cpu_count;
	if (sCPUs > 64)
		sCPUs = 64;

	sTeamBarrier = (status_t (*)(uint32))dlsym(RTLD_DEFAULT, "__team_memory_barrier");
	if (sTeamBarrier != NULL && sTeamBarrier(0) != B_OK)
		sTeamBarrier = NULL;
	if (sTeamBarrier != NULL && sTeamBarrier(1) != B_BAD_VALUE)
		printf("MEMBARRIER flags 1 not rejected\n");
	printf("MEMBARRIER %s, %d CPUs\n", sTeamBarrier != NULL ? "available" : "unavailable", sCPUs);
	fflush(stdout);

	if (sTeamBarrier != NULL) {
		for (int busy = 0; busy <= sCPUs; busy++)
			cost(busy, calls);
		if (sCPUs > 1)
			cost_other_team(calls);
		/* "delay" spins as long as a call takes */
		pin(0);
		bigtime_t start = system_time();
		for (int i = 0; i < 1000; i++)
			sTeamBarrier(0);
		sDelay = (system_time() - start) / 1000;
		if (sDelay < 1)
			sDelay = 1;
	}

	if (sCPUs < 2) {
		printf("MEMBARRIER litmus needs 2 CPUs\n");
		return 0;
	}
	litmus(NONE);
	if (sTeamBarrier != NULL) {
		litmus(DELAY);
		litmus(TEAM);
	}
	litmus(FENCE);
	printf("MEMBARRIER end\n");
	return 0;
}
