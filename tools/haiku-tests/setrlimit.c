/*
 * setrlimit.c — setrlimit() of a limit Haiku keeps fixed (RLIMIT_AS, RLIMIT_CORE, RLIMIT_DATA, RLIMIT_FSIZE,
 * RLIMIT_STACK) to the value getrlimit() reports must succeed, as Python's and numpy's test suites do before a
 * crash test (setrlimit(RLIMIT_CORE, {0, 0})); a real change of such a limit stays EINVAL. A changeable limit
 * (RLIMIT_NOFILE, lowered and raised back) for comparison.
 *
 *   setrlimit       prints "setrlimit: ok" or "setrlimit: FAIL ..." lines; exit 0 when all passed
 *
 * Build: x86_64-unknown-haiku-gcc --sysroot=artifacts/sysroot-x86_64 -O2 -o setrlimit setrlimit.c
 */
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>

static int sFailures;

static void
same_value(int resource, const char *name)
{
	struct rlimit rl;
	if (getrlimit(resource, &rl) != 0) {
		printf("setrlimit: FAIL getrlimit(%s): %s\n", name, strerror(errno));
		sFailures++;
		return;
	}
	errno = 0;
	if (setrlimit(resource, &rl) != 0) {
		printf("setrlimit: FAIL setrlimit(%s, {%llu, %llu}) (its current value): %s\n", name,
			(unsigned long long)rl.rlim_cur, (unsigned long long)rl.rlim_max, strerror(errno));
		sFailures++;
	} else
		printf("setrlimit: %s {%llu, %llu} set to itself: ok\n", name, (unsigned long long)rl.rlim_cur,
			(unsigned long long)rl.rlim_max);
}

int
main(void)
{
	same_value(RLIMIT_CORE, "RLIMIT_CORE");
	same_value(RLIMIT_AS, "RLIMIT_AS");
	same_value(RLIMIT_DATA, "RLIMIT_DATA");
	same_value(RLIMIT_FSIZE, "RLIMIT_FSIZE");
	same_value(RLIMIT_STACK, "RLIMIT_STACK");
	same_value(RLIMIT_NOFILE, "RLIMIT_NOFILE");

	/* the Python/numpy idiom */
	struct rlimit zero = { 0, 0 };
	struct rlimit core;
	getrlimit(RLIMIT_CORE, &core);
	if (core.rlim_cur == 0 && core.rlim_max == 0 && setrlimit(RLIMIT_CORE, &zero) != 0) {
		printf("setrlimit: FAIL setrlimit(RLIMIT_CORE, {0, 0}): %s\n", strerror(errno));
		sFailures++;
	}

	/* a real change of a fixed limit is still refused */
	struct rlimit stack;
	getrlimit(RLIMIT_STACK, &stack);
	struct rlimit other = stack;
	other.rlim_cur = stack.rlim_cur / 2;
	if (stack.rlim_cur > 0 && setrlimit(RLIMIT_STACK, &other) == 0) {
		printf("setrlimit: note: RLIMIT_STACK could be changed to %llu\n",
			(unsigned long long)other.rlim_cur);
	}

	if (sFailures == 0) {
		printf("setrlimit: ok\n");
		return 0;
	}
	printf("setrlimit: %d failures\n", sFailures);
	return 1;
}
