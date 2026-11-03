/*
 * killrace — a thread that takes a team-killing signal must not take its
 * stack away from the threads that still run (docs/design/firefox-contentproc-crash.md;
 * tools/pi-tests/kill-race-loop.sh runs it, as /boot/home/kill_race2). Build:
 *   aarch64-unknown-haiku-g++ --sysroot=artifacts/sysroot-arm64 -O2 -o kill_race2 killrace.cpp
 *
 * The "victim" thread links a node on its own stack into a list (as Firefox's
 * nsThreadPool does with each idle thread's MRUIdleEntry) and waits; it is the
 * only thread that does not block SIGTERM. "Walker" threads read the list in a
 * loop without entering the kernel. Four threads have been joined before, so
 * that the team's stack cache is full. The main thread spends its time in
 * long reads of /dev/zero, so that it gets around to shutting the team down
 * only after a while. On SIGTERM (default action: end the team) the victim
 * handles the signal and exits; if its stack area is deleted while the walkers
 * still run, a walker faults:
 * "debug_server: Thread N entered the debugger: Segment violation".
 *
 * kill_race2 [WALKERS]   (default 3); prints "KR ready <team>"
 */
#include <OS.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>


struct node {
	node* volatile	next;
	volatile long	value;
};

static node* volatile sList;
static sem_id sNever;


static void*
victim(void*)
{
	sigset_t set;
	sigemptyset(&set);
	sigaddset(&set, SIGTERM);
	pthread_sigmask(SIG_UNBLOCK, &set, NULL);

	node self;
	self.value = 1;
	self.next = NULL;
	sList = &self;
	while (true)
		acquire_sem(sNever);
	return NULL;
}


static void*
walker(void*)
{
	long sum = 0;
	for (;;) {
		for (node* n = sList; n != NULL; n = n->next)
			sum += n->value;
	}
	return (void*)sum;
}


static void*
nothing(void*)
{
	return NULL;
}


int
main(int argc, char** argv)
{
	int walkers = argc > 1 ? atoi(argv[1]) : 3;

	// only the victim takes SIGTERM
	sigset_t set;
	sigemptyset(&set);
	sigaddset(&set, SIGTERM);
	sigprocmask(SIG_BLOCK, &set, NULL);

	sNever = create_sem(0, "never");
	pthread_t thread;
	pthread_create(&thread, NULL, victim, NULL);
	while (sList == NULL)
		snooze(1000);
	for (int i = 0; i < walkers; i++)
		pthread_create(&thread, NULL, walker, NULL);

	// fill the team's cache of exited threads' stacks
	for (int i = 0; i < 4; i++) {
		pthread_t threads[4];
		for (int j = 0; j < 4; j++)
			pthread_create(&threads[j], NULL, nothing, NULL);
		for (int j = 0; j < 4; j++)
			pthread_join(threads[j], NULL);
	}

	printf("KR ready %d\n", (int)getpid());
	fflush(stdout);

	int fd = open("/dev/zero", O_RDONLY);
	size_t size = 64 * 1024 * 1024;
	char* buffer = (char*)malloc(size);
	for (;;) {
		if (fd < 0 || buffer == NULL || read(fd, buffer, size) < 0)
			snooze(100000);
	}
	return 0;
}
