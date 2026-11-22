/*
 * wiredcut.c — VQ1: a cut out of the middle of an area while a device transfers into the area's part above
 * the cut. One thread reads SIZE bytes from a raw disk device into the upper half of a 2 x SIZE anonymous
 * mapping (the I/O scheduler wires that buffer: lock_memory_etc()); meanwhile the main thread munmap()s one page
 * near the mapping's start, after a random delay of 0..DELAY us. That cut splits the area in two, and the
 * kernel's cut_area() unmaps everything above the cut, so before the fix (sources/haiku branch
 * vq1-vchiq-unwire) the read's unlock_memory_etc() found the buffer's pages unmapped and panicked "Failed to
 * unwire page"; with the fix munmap() waits for the read. Libroot's allocator makes the same cut when it frees
 * a large chunk in the middle of its heap area — the VCHIQ bulk-transfer panic on the Pi (KNOWN-ISSUES C17).
 *
 *   wiredcut DEVICE [N] [SIZE_MB] [DELAY_US]     (e.g. /dev/disk/virtual/virtio_block/0/raw; 200, 8, 3000)
 *
 * Prints "wiredcut: N rounds, R reads complete, M munmaps waited >= 1 ms" (a waiting munmap = the fix at work;
 * the kernel's own diagnostic lines, if built in, say which rounds hit). A panic stops the system instead.
 *
 * Build (cross):
 *   g=sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc
 *   $g --sysroot=artifacts/sysroot-arm64 -O2 -o wiredcut tools/haiku-tests/wiredcut.c
 */
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static int sFd;
static char* sBuffer;
static size_t sSize;
static ssize_t sRead;

static long long
now_us(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1000000LL + t.tv_nsec / 1000;
}

static void*
reader(void* unused)
{
	(void)unused;
	sRead = pread(sFd, sBuffer, sSize, 0);
	return NULL;
}

int
main(int argc, char** argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: wiredcut DEVICE [N] [SIZE_MB] [DELAY_US]\n");
		return 2;
	}
	int rounds = argc > 2 ? atoi(argv[2]) : 200;
	sSize = (size_t)(argc > 3 ? atoi(argv[3]) : 8) << 20;
	int delay = argc > 4 ? atoi(argv[4]) : 3000;
	sFd = open(argv[1], O_RDONLY);
	if (sFd < 0) {
		perror(argv[1]);
		return 1;
	}
	srand(1);
	int complete = 0, waited = 0;
	for (int i = 0; i < rounds; i++) {
		char* base = mmap(NULL, 2 * sSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (base == MAP_FAILED) {
			perror("mmap");
			return 1;
		}
		memset(base, 1, 2 * sSize);
		sBuffer = base + sSize;
		pthread_t thread;
		pthread_create(&thread, NULL, reader, NULL);
		usleep(rand() % (delay + 1));
		long long t0 = now_us();
		if (munmap(base + 65536, 4096) != 0)
			perror("munmap (cut)");
		if (now_us() - t0 >= 1000)
			waited++;
		pthread_join(thread, NULL);
		if (sRead == (ssize_t)sSize)
			complete++;
		munmap(base, 65536);
		munmap(base + 65536 + 4096, 2 * sSize - 65536 - 4096);
	}
	printf("wiredcut: %d rounds, %d reads complete, %d munmaps waited >= 1 ms\n", rounds, complete, waited);
	return 0;
}
