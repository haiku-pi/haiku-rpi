/* exitthread.c MODE — does _Exit() from a secondary thread end the team while the main thread waits?
 * MODE sem: the main thread waits on a semaphore; MODE spin: it spins; MODE sig: a SIGTERM handler on the
 * secondary thread calls _Exit(). Prints "main alive" every second while it lives. */
#include <OS.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static sem_id sSem;

static void handler(int sig) { _Exit(1); }

static status_t secondary(void *data)
{
	const char *mode = data;
	if (strcmp(mode, "sig") == 0) {
		acquire_sem(create_sem(0, "never"));	/* the SIGTERM sent to it interrupts this */
		return 0;
	}
	snooze(500000);
	_Exit(1);
	return 0;
}

int main(int argc, char **argv)
{
	const char *mode = argc > 1 ? argv[1] : "sem";
	sSem = create_sem(0, "main waits");
	thread_id t = spawn_thread(secondary, "secondary", B_NORMAL_PRIORITY, (void *)mode);
	resume_thread(t);
	if (strcmp(mode, "sig") == 0) {
		struct sigaction sa;
		memset(&sa, 0, sizeof(sa));
		sa.sa_handler = handler;
		sigaction(SIGTERM, &sa, NULL);
		/* only the secondary thread may take SIGTERM */
		sigset_t set;
		sigemptyset(&set);
		sigaddset(&set, SIGTERM);
		sigprocmask(SIG_BLOCK, &set, NULL);
		snooze(300000);
		send_signal(t, SIGTERM);
	}
	for (int i = 0; i < 10; i++) {
		if (strcmp(mode, "spin") == 0) {
			bigtime_t end = system_time() + 1000000;
			while (system_time() < end)
				;
		} else
			acquire_sem_etc(sSem, 1, B_RELATIVE_TIMEOUT, 1000000);
		printf("main alive %d\n", i);
		fflush(stdout);
	}
	printf("main: the team survived the secondary thread's _Exit\n");
	return 0;
}
