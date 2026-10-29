/*
 * threadstress.c — correctness of thread creation and exit under churn, for changes to how the kernel
 * makes and frees user stacks (e.g. reusing the stack areas of exited threads): every new thread must
 * find its stack, TLS, errno and thread-specific data as a fresh thread would, whatever ran before it.
 *
 *   threadstress [ROUNDS [TEST]]    (default 3000 threads per churn test; TEST: run only that one, e.g.
 *                                   "fork" for fork and fork-busy)
 *
 * Tests (each prints "THREADSTRESS <test> ok" or "THREADSTRESS FAIL <test>: <why>"; the last line is
 * "THREADSTRESS end <failures> failures"):
 *   churn     threads with varied attributes in turn: default, detached, stack sizes from PTHREAD_STACK_MIN
 *             to 4 MiB (page-aligned and not), guard sizes 0 to 64 KiB, user-provided stacks
 *             (pthread_attr_setstack), spawn_thread(); each checks at start that its TLS slot, __thread
 *             variable, pthread key and errno have their initial values, that get_thread_info()'s stack range
 *             holds its stack pointer and has the requested size, writes a pattern three quarters deep into
 *             its stack and reads it back, then dirties all of them for whoever comes next
 *   parallel  the churn from 4 threads at once
 *   areas     the team's area count after 2000 more threads is no larger than before plus a few
 *   guard     a thread that overflows its stack (after reuse) still hits the guard: SIGSEGV (handled on an
 *             alternate stack, which ends the child team with status 42), for the default guard and 64 KiB
 *   fork      fork() 40 times right after a churn (the parent keeps stacks of exited threads); each child
 *             churns threads itself and exits 0
 *   fork-busy the same while 4 threads churn (the child also inherits whatever the other threads were
 *             doing in libroot and the runtime loader at that moment)
 *   exec      a child churns threads, then exec()s this program ("exec-child"), which churns and exits 0
 *   kill      a child with 4 threads creating detached threads is killed (SIGKILL) at a random moment, 40 times
 *
 * Build (cross):
 *   g=sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc
 *   $g --sysroot=artifacts/sysroot-arm64 -O2 -o threadstress tools/haiku-tests/threadstress.c
 */
#include <OS.h>
#include <TLS.h>
#include <errno.h>
#include <image.h>
#include <limits.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#define PARALLEL 4

static int32 sTlsSlot;
static pthread_key_t sKey;
static __thread int sThreadVariable = 42;
static int32 sFailures;
static int32 sDetachedDone;


static void
fail(const char* test, const char* why)
{
	atomic_add(&sFailures, 1);
	printf("THREADSTRESS FAIL %s: %s\n", test, why);
	fflush(stdout);
}


struct variant {
	const char* name;
	size_t stack_size;		/* 0: the default */
	size_t guard_size;		/* (size_t)-1: the default */
	int detached;
	int user_stack;
	int native;				/* spawn_thread() */
};

static const struct variant kVariants[] = {
	{ "default", 0, (size_t)-1, 0, 0, 0 },
	{ "detached", 0, (size_t)-1, 1, 0, 0 },
	{ "min", PTHREAD_STACK_MIN, (size_t)-1, 0, 0, 0 },
	{ "64k", 64 * 1024, (size_t)-1, 0, 0, 0 },
	{ "odd", 200 * 1024 + 123, (size_t)-1, 0, 0, 0 },
	{ "default-size", 256 * 1024, (size_t)-1, 0, 0, 0 },
	{ "1m", 1024 * 1024, (size_t)-1, 0, 0, 0 },
	{ "4m-detached", 4 * 1024 * 1024, (size_t)-1, 1, 0, 0 },
	{ "noguard", 0, 0, 0, 0, 0 },
	{ "guard4k", 0, 4096, 0, 0, 0 },
	{ "guard64k", 0, 64 * 1024, 0, 0, 0 },
	{ "user", 128 * 1024, (size_t)-1, 0, 1, 0 },
	{ "user-detached", 64 * 1024, (size_t)-1, 1, 1, 0 },
	{ "spawn_thread", 0, (size_t)-1, 0, 0, 1 },
	{ "default", 0, (size_t)-1, 0, 0, 0 },
	{ "default", 0, (size_t)-1, 0, 0, 0 },
};
#define VARIANT_COUNT (sizeof(kVariants) / sizeof(kVariants[0]))


struct job {
	const struct variant* variant;
	const char* test;
	void* user_stack;
	size_t user_stack_size;
	volatile thread_id thread;
	int ok;
};


static void
check_thread(struct job* job)
{
	const struct variant* v = job->variant;
	char why[160];
	int local;

	job->thread = find_thread(NULL);
	/* initial values, as a fresh thread has them */
	if (errno != 0) {
		snprintf(why, sizeof(why), "%s: errno %d at start", v->name, errno);
		fail(job->test, why);
	}
	if (tls_get(sTlsSlot) != NULL) {
		snprintf(why, sizeof(why), "%s: TLS slot %p at start", v->name, tls_get(sTlsSlot));
		fail(job->test, why);
	}
	if (sThreadVariable != 42) {
		snprintf(why, sizeof(why), "%s: __thread variable %d at start", v->name, sThreadVariable);
		fail(job->test, why);
	}
	if (pthread_getspecific(sKey) != NULL) {
		snprintf(why, sizeof(why), "%s: pthread key %p at start", v->name, pthread_getspecific(sKey));
		fail(job->test, why);
	}

	/* the stack range the kernel reports */
	thread_info info;
	get_thread_info(find_thread(NULL), &info);
	addr_t base = (addr_t)info.stack_base, end = (addr_t)info.stack_end;
	if ((addr_t)&local < base || (addr_t)&local >= end) {
		snprintf(why, sizeof(why), "%s: sp %p outside stack %p-%p", v->name, &local, info.stack_base,
			info.stack_end);
		fail(job->test, why);
	}
	size_t size = end - base;
	size_t expected = v->user_stack ? 0 : v->stack_size == 0 ? 256 * 1024
		: (v->stack_size + B_PAGE_SIZE - 1) & ~(size_t)(B_PAGE_SIZE - 1);
	if (v->user_stack) {
		if (base < (addr_t)job->user_stack || end > (addr_t)job->user_stack + job->user_stack_size) {
			snprintf(why, sizeof(why), "%s: stack %p-%p not in the user's %p+%zu", v->name,
				info.stack_base, info.stack_end, job->user_stack, job->user_stack_size);
			fail(job->test, why);
		}
	} else if (size != expected) {
		snprintf(why, sizeof(why), "%s: stack size %zu, expected %zu", v->name, size, expected);
		fail(job->test, why);
	}

	/* write a pattern deep into the stack, read it back */
	size_t depth = (addr_t)&local - base;
	depth = depth / 4 * 3;
	if (depth > 8 * 1024) {
		depth -= 4 * 1024;
		volatile unsigned char* p = __builtin_alloca(depth);
		uintptr_t seed = (uintptr_t)job;
		for (size_t i = 0; i < depth; i += 512)
			p[i] = (unsigned char)(seed + i / 512);
		for (size_t i = 0; i < depth; i += 512) {
			if (p[i] != (unsigned char)(seed + i / 512)) {
				snprintf(why, sizeof(why), "%s: stack pattern lost at %zu", v->name, i);
				fail(job->test, why);
				break;
			}
		}
	}

	/* leave everything dirty for whoever gets this stack next */
	errno = 1234;
	tls_set(sTlsSlot, (void*)job);
	sThreadVariable = 7;
	pthread_setspecific(sKey, job);
	job->ok = 1;
}


static void*
pthread_entry(void* data)
{
	struct job* job = data;
	check_thread(job);
	if (job->variant->detached && !job->variant->user_stack) {
		free(job);
		atomic_add(&sDetachedDone, 1);
	}
		/* (a detached thread on a user stack cannot free it: its creator waits for it) */
	return (void*)0x5a5a;
}


static status_t
native_entry(void* data)
{
	check_thread(data);
	return 0x5a5a;
}


static void
key_destructor(void* value)
{
	/* nothing: the value is a job */
}


/* one thread of the given variant, joined unless detached; returns 0 when it could not be created */
static int
run_one(const struct variant* v, const char* test)
{
	struct job* job = calloc(1, sizeof(*job));
	job->variant = v;
	job->test = test;

	if (v->native) {
		thread_id thread = spawn_thread(native_entry, "threadstress", B_NORMAL_PRIORITY, job);
		if (thread < 0) {
			fail(test, "spawn_thread failed");
			free(job);
			return 0;
		}
		resume_thread(thread);
		status_t result;
		if (wait_for_thread(thread, &result) != B_OK || result != 0x5a5a || !job->ok)
			fail(test, "spawn_thread: bad exit");
		free(job);
		return 1;
	}

	pthread_attr_t attr;
	pthread_attr_init(&attr);
	if (v->stack_size != 0 && !v->user_stack)
		pthread_attr_setstacksize(&attr, v->stack_size);
	if (v->guard_size != (size_t)-1)
		pthread_attr_setguardsize(&attr, v->guard_size);
	if (v->detached)
		pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
	if (v->user_stack) {
		job->user_stack_size = v->stack_size;
		job->user_stack = malloc(v->stack_size);
		memset(job->user_stack, 0xa5, v->stack_size);
			/* as a reused stack would be: its TLS slots are not zero */
		pthread_attr_setstack(&attr, job->user_stack, v->stack_size);
	}

	pthread_t thread;
	int status = pthread_create(&thread, &attr, pthread_entry, job);
	pthread_attr_destroy(&attr);
	if (status != 0) {
		char why[64];
		snprintf(why, sizeof(why), "%s: pthread_create: %s", v->name, strerror(status));
		fail(test, why);
		free(job->user_stack);
		free(job);
		return 0;
	}
	if (v->detached && !v->user_stack)
		return 1;
	if (v->detached) {
		/* wait for the kernel thread to be gone before the stack is freed */
		while (job->thread == 0)
			snooze(100);
		status_t result;
		wait_for_thread(job->thread, &result);
		if (!job->ok)
			fail(test, "user-detached: not run");
		free(job->user_stack);
		free(job);
		return 0;
	}

	void* result = NULL;
	status = pthread_join(thread, &result);
	if (status != 0 || result != (void*)0x5a5a || !job->ok) {
		char why[128];
		snprintf(why, sizeof(why), "%s: join %d, result %p, %s (stack %p)", v->name, status, result,
			job->ok ? "ran" : "did not run", job->user_stack);
		fail(test, why);
	}
	free(job->user_stack);
	free(job);
	return 1;
}


static void
churn(int rounds, unsigned seed, const char* test)
{
	int detached = 0;
	for (int i = 0; i < rounds; i++) {
		const struct variant* v = &kVariants[rand_r(&seed) % VARIANT_COUNT];
		if (run_one(v, test) && v->detached)
			detached++;
	}
	(void)detached;
}


static void
wait_detached(int32 expected)
{
	bigtime_t deadline = system_time() + 30000000;
	while (atomic_get(&sDetachedDone) < expected && system_time() < deadline)
		snooze(1000);
	snooze(20000);
		/* the last detached threads may still be on their way out of the kernel */
}


static int
count_areas(void)
{
	area_info info;
	ssize_t cookie = 0;
	int count = 0;
	while (get_next_area_info(B_CURRENT_TEAM, &cookie, &info) == B_OK)
		count++;
	return count;
}


struct churner {
	int rounds;
	unsigned seed;
	volatile int* stop;
	const char* test;
};


static void*
churner_entry(void* data)
{
	struct churner* c = data;
	if (c->stop == NULL) {
		churn(c->rounds, c->seed, c->test);
		return NULL;
	}
	while (!*c->stop)
		churn(20, c->seed++, c->test);
	return NULL;
}


static void
report(const char* test, int32 failuresBefore)
{
	if (atomic_get(&sFailures) == failuresBefore)
		printf("THREADSTRESS %s ok\n", test);
	fflush(stdout);
}


static int
overflow(volatile char* previous, int depth)
{
	volatile char frame[1024];
	frame[0] = previous != NULL ? previous[0] + 1 : 0;
	if (depth == INT_MAX)
		return frame[0];
	return overflow(frame, depth + 1) + frame[1];
}


static void
segv_handler(int signal)
{
	_exit(42);
}


static void*
overflow_entry(void* data)
{
	/* SIGSEGV on an alternate stack ends the team with status 42 (a crash would wait for the
	   debug server's alert) */
	stack_t signalStack;
	signalStack.ss_sp = malloc(SIGSTKSZ * 4);
	signalStack.ss_size = SIGSTKSZ * 4;
	signalStack.ss_flags = 0;
	sigaltstack(&signalStack, NULL);
	struct sigaction action;
	memset(&action, 0, sizeof(action));
	action.sa_handler = segv_handler;
	action.sa_flags = SA_ONSTACK;
	sigaction(SIGSEGV, &action, NULL);
	return (void*)(long)overflow(NULL, 0);
}


static void
test_guard(size_t guard)
{
	pid_t child = fork();
	if (child == 0) {
		churn(200, 7, "guard");
		pthread_attr_t attr;
		pthread_attr_init(&attr);
		if (guard != 0)
			pthread_attr_setguardsize(&attr, guard);
		pthread_t thread;
		pthread_create(&thread, &attr, overflow_entry, NULL);
		pthread_join(thread, NULL);
		_exit(0);
	}
	int status;
	waitpid(child, &status, 0);
	if (!WIFEXITED(status) || WEXITSTATUS(status) != 42) {
		char why[96];
		snprintf(why, sizeof(why), "guard %zu: child status %#x, not a SIGSEGV", guard, status);
		fail("guard", why);
	}
}


static void
test_fork(int busy)
{
	const char* test = busy ? "fork-busy" : "fork";
	volatile int stop = 0;
	pthread_t threads[PARALLEL];
	struct churner churners[PARALLEL];
	for (int i = 0; busy && i < PARALLEL; i++) {
		churners[i] = (struct churner){ 0, 2000 + i * 100, &stop, test };
		pthread_create(&threads[i], NULL, churner_entry, &churners[i]);
	}
	for (int i = 0; i < 40; i++) {
		pid_t child = fork();
		if (child == 0) {
			int32 failures = atomic_get(&sFailures);
			churn(200, 3000 + i, test);
			int areas = count_areas();
			churn(200, 4000 + i, test);
			if (count_areas() > areas + 8)
				fail(test, "areas grow in the child");
			_exit(atomic_get(&sFailures) == failures ? 0 : 1);
		}
		int status;
		waitpid(child, &status, 0);
		if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
			char why[64];
			snprintf(why, sizeof(why), "child %d status %#x", i, status);
			fail(test, why);
		}
	}
	stop = 1;
	for (int i = 0; busy && i < PARALLEL; i++)
		pthread_join(threads[i], NULL);
	snooze(200000);
}


static int
want(const char* only, const char* test)
{
	return only == NULL || strcmp(only, test) == 0;
}


static const char*
self_path(void)
{
	static image_info info;
	int32 cookie = 0;
	while (get_next_image_info(B_CURRENT_TEAM, &cookie, &info) == B_OK) {
		if (info.type == B_APP_IMAGE)
			return info.name;
	}
	return NULL;
}


int
main(int argc, char** argv)
{
	int rounds = argc > 1 ? atoi(argv[1]) : 3000;
	const char* only = argc > 2 ? argv[2] : NULL;
	int32 before;

	sTlsSlot = tls_allocate();
	pthread_key_create(&sKey, key_destructor);
	int32 detachedExpected = 0;

	if (argc > 1 && strcmp(argv[1], "exec-child") == 0) {
		churn(300, 99, "exec");
		return atomic_get(&sFailures) == 0 ? 0 : 1;
	}

	/* churn: one thread after the other */
	if (want(only, "churn")) {
		before = sFailures;
		for (int i = 0; i < rounds; i++) {
			const struct variant* v = &kVariants[i % VARIANT_COUNT];
			if (run_one(v, "churn") && v->detached)
				detachedExpected++;
		}
		wait_detached(detachedExpected);
		report("churn", before);
	}

	/* parallel: the same from 4 threads */
	if (want(only, "parallel")) {
		before = sFailures;
		{
			pthread_t threads[PARALLEL];
			struct churner churners[PARALLEL];
			for (int i = 0; i < PARALLEL; i++) {
				churners[i] = (struct churner){ rounds / PARALLEL, 1000 + i, NULL, "parallel" };
				pthread_create(&threads[i], NULL, churner_entry, &churners[i]);
			}
			for (int i = 0; i < PARALLEL; i++)
				pthread_join(threads[i], NULL);
		}
		snooze(200000);
		report("parallel", before);
	}

	/* areas: no area left behind */
	if (want(only, "areas")) {
		before = sFailures;
		{
			int detachedBefore = atomic_get(&sDetachedDone);
			int areasBefore = count_areas();
			int detached = 0;
			for (int i = 0; i < 2000; i++) {
				const struct variant* v = &kVariants[i % VARIANT_COUNT];
				if (run_one(v, "areas") && v->detached)
					detached++;
			}
			wait_detached(detachedBefore + detached);
			int areasAfter = count_areas();
			if (areasAfter > areasBefore + 8) {
				char why[64];
				snprintf(why, sizeof(why), "%d areas before, %d after", areasBefore, areasAfter);
				fail("areas", why);
			}
			printf("THREADSTRESS areas: %d before, %d after\n", areasBefore, areasAfter);
		}
		report("areas", before);
	}

	/* guard: the guard area still stops an overflow */
	if (want(only, "guard")) {
		before = sFailures;
		test_guard(0);
		test_guard(64 * 1024);
		report("guard", before);
	}

	/* fork: from a team that has just made threads (its kept stacks), and while 4 threads make them */
	if (want(only, "fork")) {
		before = sFailures;
		churn(100, 2500, "fork");
		test_fork(0);
		report("fork", before);
		before = sFailures;
		test_fork(1);
		report("fork-busy", before);
	}

	/* exec after threads */
	if (want(only, "exec")) {
		before = sFailures;
		{
			const char* path = self_path();
			for (int i = 0; i < 20 && path != NULL; i++) {
				pid_t child = fork();
				if (child == 0) {
					churn(100, 5000 + i, "exec");
					execl(path, path, "exec-child", (char*)NULL);
					_exit(127);
				}
				int status;
				waitpid(child, &status, 0);
				if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
					char why[64];
					snprintf(why, sizeof(why), "exec child %d status %#x", i, status);
					fail("exec", why);
				}
			}
			if (path == NULL)
				fail("exec", "no path to this program");
		}
		report("exec", before);
	}

	/* kill a team while its threads come and go */
	if (want(only, "kill")) {
		before = sFailures;
		{
			unsigned seed = 77;
			for (int i = 0; i < 40; i++) {
				pid_t child = fork();
				if (child == 0) {
					volatile int stop = 0;
					pthread_t threads[PARALLEL];
					struct churner churners[PARALLEL];
					for (int j = 0; j < PARALLEL; j++) {
						churners[j] = (struct churner){ 0, 6000 + j, &stop, "kill-child" };
						pthread_create(&threads[j], NULL, churner_entry, &churners[j]);
					}
					for (;;)
						snooze(1000000);
				}
				snooze(1000 + rand_r(&seed) % 50000);
				kill(child, SIGKILL);
				int status;
				waitpid(child, &status, 0);
				if (!WIFSIGNALED(status) || WTERMSIG(status) != SIGKILL) {
					char why[64];
					snprintf(why, sizeof(why), "child %d status %#x", i, status);
					fail("kill", why);
				}
			}
		}
		report("kill", before);
	}

	printf("THREADSTRESS end %d failures\n", (int)sFailures);
	return sFailures == 0 ? 0 : 1;
}
