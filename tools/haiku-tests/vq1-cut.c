/*
 * vq1-cut.c — VQ1: linked into a variant of Broadcom's vchiq_test (scripts/build-vchiq-test.sh, vchiq_test_cut):
 * its bulk buffers (-b) come from the upper half of one anonymous mapping, and a thread cuts one page out of the
 * lower half every VQ1_CUT_US microseconds (default 2000), each cut a little higher, while the bulk transfers run.
 * Every cut is out of the middle of the area that holds the buffers — what libroot's allocator does when it frees
 * a large chunk in the middle of its heap area. Before the kernel fix (sources/haiku branch vq1-vchiq-unwire)
 * cut_area() unmapped the wired pages of the bulk buffers in flight above the cut, and the VCHIQ driver's unlock
 * at the end of the transfer panicked ("Failed to unwire page", vchiq_haiku_buffer_unlock()); with the fix munmap()
 * waits for the transfer. At the end: "VQ1CUT: N cuts, M waited >= 1 ms" on stderr.
 */
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define REGION (64 << 20)
#define STRIDE (16 << 10)

static char* sRegion;
static size_t sUsed;
static int sCuts, sWaited;

static long long
now_us(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1000000LL + t.tv_nsec / 1000;
}

static void
report(void)
{
	fprintf(stderr, "VQ1CUT: %d cuts, %d waited >= 1 ms\n", sCuts, sWaited);
}

static void*
cutter(void* unused)
{
	(void)unused;
	const char* env = getenv("VQ1_CUT_US");
	int interval = env != NULL ? atoi(env) : 2000;
	for (size_t offset = STRIDE; offset + 4096 < REGION / 2; offset += STRIDE) {
		usleep(interval);
		long long t0 = now_us();
		if (munmap(sRegion + offset, 4096) == 0)
			sCuts++;
		if (now_us() - t0 >= 1000)
			sWaited++;
	}
	report();
	return NULL;
}

void*
vq1_alloc(size_t size)
{
	if (sRegion == NULL) {
		sRegion = mmap(NULL, REGION, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (sRegion == MAP_FAILED)
			return NULL;
		pthread_t thread;
		pthread_create(&thread, NULL, cutter, NULL);
		pthread_detach(thread);
		atexit(report);
	}
	size = (size + 4095) & ~(size_t)4095;
	if (REGION / 2 + sUsed + size > REGION)
		return NULL;
	void* buffer = sRegion + REGION / 2 + sUsed;
	sUsed += size;
	return buffer;
}

void
vq1_free(void* buffer)
{
	(void)buffer;
}
