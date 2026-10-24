/*
 * forkbench.c — what creating a process costs, in parts: fork()+_exit()+wait, fork()+exec+wait of a
 * program, posix_spawn()+wait, load_image() style via posix_spawn, and a thread create+join for scale.
 *
 *   forkbench [N] [PROGRAM]      (default N 200, PROGRAM /bin/true)
 *
 * Prints "FORKBENCH <case> <us> us/op".
 *
 * Build (cross):
 *   g=sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc
 *   $g --sysroot=artifacts/sysroot-arm64 -O2 -o forkbench tools/haiku-tests/forkbench.c
 */
#include <pthread.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

extern char** environ;


static double
now_us(void)
{
	struct timeval tv;
	gettimeofday(&tv, NULL);
	return tv.tv_sec * 1e6 + tv.tv_usec;
}


static void*
nothing(void* arg)
{
	return arg;
}


int
main(int argc, char** argv)
{
	int n = argc > 1 ? atoi(argv[1]) : 200;
	const char* program = argc > 2 ? argv[2] : "/bin/true";
	char* args[] = { (char*)program, NULL };
	double start;
	int i, status;

	start = now_us();
	for (i = 0; i < n; i++) {
		pthread_t thread;
		pthread_create(&thread, NULL, nothing, NULL);
		pthread_join(thread, NULL);
	}
	printf("FORKBENCH thread %.0f us/op\n", (now_us() - start) / n);

	start = now_us();
	for (i = 0; i < n; i++) {
		pid_t pid = fork();
		if (pid == 0)
			_exit(0);
		waitpid(pid, &status, 0);
	}
	printf("FORKBENCH fork+exit %.0f us/op\n", (now_us() - start) / n);

	start = now_us();
	for (i = 0; i < n; i++) {
		pid_t pid = fork();
		if (pid == 0) {
			execv(program, args);
			_exit(127);
		}
		waitpid(pid, &status, 0);
	}
	printf("FORKBENCH fork+exec %.0f us/op\n", (now_us() - start) / n);

	start = now_us();
	for (i = 0; i < n; i++) {
		pid_t pid;
		if (posix_spawn(&pid, program, NULL, NULL, args, environ) != 0) {
			printf("FORKBENCH posix_spawn failed\n");
			break;
		}
		waitpid(pid, &status, 0);
	}
	printf("FORKBENCH posix_spawn %.0f us/op\n", (now_us() - start) / n);
	return 0;
}
