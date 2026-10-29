/*
 * threadbench.c — what creating a thread costs: pthread_create()+pthread_join() of a thread that does
 * nothing, of one that uses STACK_KB of its stack, and spawn_thread()+wait_for_thread(); wall time and CPU
 * time (the team's user + kernel time, dead threads included) per thread.
 *
 *   threadbench [N] [STACK_KB] [only]   (default N 2000, STACK_KB 64; "only": just the first case, for
 *                                       profiling it)
 *
 * Prints "THREADBENCH <case> <wall> us/op <cpu> us cpu/op (user <u> kernel <k>)".
 *
 * Build (cross):
 *   g=sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc
 *   $g --sysroot=artifacts/sysroot-arm64 -O2 -o threadbench tools/haiku-tests/threadbench.c
 */
#include <OS.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int sStackKB;


static void*
nothing(void* arg)
{
	return arg;
}


static void*
use_stack(void* arg)
{
	volatile char buffer[sStackKB * 1024];
	for (int i = 0; i < sStackKB * 1024; i += 4096)
		buffer[i] = 1;
	return (void*)(long)buffer[0];
}


static status_t
native_nothing(void* arg)
{
	return 0;
}


static team_usage_info
usage(void)
{
	team_usage_info usage = { 0, 0 };
	get_team_usage_info(B_CURRENT_TEAM, B_TEAM_USAGE_SELF, &usage);
	return usage;
}


static void
report(const char* name, int n, bigtime_t wall, team_usage_info start)
{
	team_usage_info end = usage();
	bigtime_t user = end.user_time - start.user_time, kernel = end.kernel_time - start.kernel_time;
	printf("THREADBENCH %s %.1f us/op %.1f us cpu/op (user %.1f kernel %.1f)\n", name,
		(double)(system_time() - wall) / n, (double)(user + kernel) / n, (double)user / n,
		(double)kernel / n);
}


static void
bench_pthread(const char* name, int n, void* (*function)(void*))
{
	bigtime_t wall = system_time();
	team_usage_info start = usage();
	for (int i = 0; i < n; i++) {
		pthread_t thread;
		if (pthread_create(&thread, NULL, function, NULL) != 0) {
			printf("THREADBENCH %s: pthread_create failed\n", name);
			return;
		}
		pthread_join(thread, NULL);
	}
	report(name, n, wall, start);
}


int
main(int argc, char** argv)
{
	int n = argc > 1 ? atoi(argv[1]) : 2000;
	sStackKB = argc > 2 ? atoi(argv[2]) : 64;
	char name[32];

	bench_pthread("pthread", n, nothing);
	if (argc > 3 && strcmp(argv[3], "only") == 0)
		return 0;

	snprintf(name, sizeof(name), "pthread-stack%dk", sStackKB);
	bench_pthread(name, n, use_stack);

	bigtime_t wall = system_time();
	team_usage_info start = usage();
	for (int i = 0; i < n; i++) {
		status_t result;
		thread_id thread = spawn_thread(native_nothing, "bench", B_NORMAL_PRIORITY, NULL);
		resume_thread(thread);
		wait_for_thread(thread, &result);
	}
	report("spawn_thread", n, wall, start);
	return 0;
}
