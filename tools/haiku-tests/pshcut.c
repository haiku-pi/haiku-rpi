/*
 * pshcut.c — VQ1: a cut out of the middle of an area below a page that a thread waiting on a process-shared
 * mutex keeps wired (vm_wire_page(), B_USER_MUTEX_SHARED, for as long as it waits). The mutex lives in the upper
 * half of a 16 MB anonymous mapping (as one in malloc()ed memory would live in the heap area); the main thread
 * holds it, a second thread blocks on it, and a third munmap()s one page near the mapping's start. That munmap()
 * must return at once: a kernel that waits for every wired range above a cut (branch vq1-vchiq-unwire before its
 * third commit) blocks it until the mutex is released — here never, as the main thread only unlocks after the
 * munmap(). After LIMIT_MS (default 3000) the main thread gives up waiting, unlocks the mutex and reports.
 *
 *   pshcut [ROUNDS] [LIMIT_MS]        (default 20 3000)
 *
 * Prints "pshcut: N rounds, M munmaps returned at once (< 100 ms), K blocked until the mutex was released" and
 * exits 0 if every munmap() returned at once.
 *
 * Build (cross):
 *   g=sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc
 *   $g --sysroot=artifacts/sysroot-arm64 -O2 -o pshcut tools/haiku-tests/pshcut.c
 */
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define SIZE (16 << 20)

static pthread_mutex_t* sMutex;
static char* sBase;
static volatile int sUnmapped;

static long long
now_ms(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1000LL + t.tv_nsec / 1000000;
}

static void*
waiter(void* unused)
{
	(void)unused;
	pthread_mutex_lock(sMutex);
	pthread_mutex_unlock(sMutex);
	return NULL;
}

static void*
cutter(void* unused)
{
	(void)unused;
	munmap(sBase + 65536, 4096);
	sUnmapped = 1;
	return NULL;
}

int
main(int argc, char** argv)
{
	int rounds = argc > 1 ? atoi(argv[1]) : 20;
	int limit = argc > 2 ? atoi(argv[2]) : 3000;
	int quick = 0, blocked = 0;
	setvbuf(stdout, NULL, _IOLBF, 0);
	for (int i = 0; i < rounds; i++) {
		sBase = mmap(NULL, SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (sBase == MAP_FAILED) {
			perror("mmap");
			return 1;
		}
		sMutex = (pthread_mutex_t*)(sBase + 3 * (SIZE / 4));
		pthread_mutexattr_t attr;
		pthread_mutexattr_init(&attr);
		pthread_mutexattr_setpshared(&attr, PTHREAD_PROCESS_SHARED);
		pthread_mutex_init(sMutex, &attr);
		pthread_mutexattr_destroy(&attr);

		pthread_mutex_lock(sMutex);
		pthread_t waitThread, cutThread;
		pthread_create(&waitThread, NULL, waiter, NULL);
		usleep(200000);
			// the waiter is blocked in the kernel by now, its page wired
		sUnmapped = 0;
		long long t0 = now_ms();
		pthread_create(&cutThread, NULL, cutter, NULL);
		while (!sUnmapped && now_ms() - t0 < limit)
			usleep(1000);
		long long took = now_ms() - t0;
		if (!sUnmapped)
			printf("pshcut: round %d: munmap() still blocked after %lld ms, unlocking the mutex\n", i + 1, took);
		pthread_mutex_unlock(sMutex);
		pthread_join(cutThread, NULL);
		pthread_join(waitThread, NULL);
		if (took < 100)
			quick++;
		else if (!sUnmapped || took >= limit)
			blocked++;
		printf("pshcut: round %d: munmap() returned after %lld ms%s\n", i + 1, now_ms() - t0,
			took >= limit ? " (once the mutex was released)" : "");
		munmap(sBase, 65536);
		munmap(sBase + 65536 + 4096, SIZE - 65536 - 4096);
	}
	printf("pshcut: %d rounds, %d munmaps returned at once (< 100 ms), %d blocked until the mutex was released\n",
		rounds, quick, blocked);
	return quick == rounds ? 0 : 1;
}
