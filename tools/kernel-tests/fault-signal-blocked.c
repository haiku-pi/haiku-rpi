/*
 * A fault whose signal the thread blocks must end the process, not repeat forever: the thread returns to
 * the faulting instruction, so a blocked SIGSEGV can never be delivered and the instruction faults again
 * at once. Linux unblocks the signal and resets it to the default (force_sig_fault); before haiku-pi's
 * fix, Haiku kept the thread in millions of faults a second (Wine's SIGSEGV handler faulting on a thread
 * Wine did not create: a hung game at full CPU).
 *
 * Each case runs in a child with a SIGSEGV handler installed: a NULL read inside that handler (which runs
 * with SIGSEGV blocked), and a NULL read with SIGSEGV blocked by sigprocmask. Right: the child ends within
 * seconds. It ends by SIGSEGV, or by SIGKILL from debug_server, which otherwise holds a crashed team at its
 * alert until someone clicks: run it with ~/config/settings/system/debug_server/settings saying
 * "default_action kill". Wrong: still faulting when the 10 s alarm (SIGALRM) comes.
 *
 * Build: aarch64-unknown-haiku-gcc -O2 -o fault-signal-blocked fault-signal-blocked.c
 */

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>

static volatile int * volatile null_pointer;

static void fault_again(int signal)
{
	(void)signal;
	(void)*null_pointer;
	_exit(3);	/* the read was skipped: not a fault */
}

static void install_handler(void)
{
	struct sigaction action;
	memset(&action, 0, sizeof(action));
	action.sa_handler = fault_again;
	sigaction(SIGSEGV, &action, NULL);
}

static void in_handler(void)
{
	install_handler();
	(void)*null_pointer;
	_exit(2);	/* the handler returned */
}

static void blocked(void)
{
	sigset_t set;
	install_handler();
	sigemptyset(&set);
	sigaddset(&set, SIGSEGV);
	sigprocmask(SIG_BLOCK, &set, NULL);
	(void)*null_pointer;
	_exit(2);
}

static int run(const char *name, void (*test)(void))
{
	pid_t child = fork();
	int status, waited;

	if (child == 0) {
		alarm(10);	/* still faulting after 10 s: SIGALRM ends it */
		test();
		_exit(1);
	}
	waited = waitpid(child, &status, 0) == child;
	if (waited && WIFSIGNALED(status)
		&& (WTERMSIG(status) == SIGSEGV || WTERMSIG(status) == SIGKILL)) {
		printf("%s: right (ended by %s)\n", name, WTERMSIG(status) == SIGSEGV ? "SIGSEGV" : "SIGKILL");
		return 0;
	}
	if (waited && WIFSIGNALED(status) && WTERMSIG(status) == SIGALRM)
		printf("%s: WRONG (still faulting after 10 s)\n", name);
	else
		printf("%s: WRONG (status %#x)\n", name, waited ? status : -1);
	return 1;
}

int main(void)
{
	int failures = run("fault in the SIGSEGV handler", in_handler)
		+ run("fault with SIGSEGV blocked", blocked);
	printf("fault-signal-blocked: %s\n", failures ? "FAILED" : "passed");
	return failures != 0;
}
