/*
 * usbalign.c DEVICE [OFFSET_MIB] [ROUNDS] — a raw disk read into a buffer that is not cache-line aligned,
 * while another thread keeps writing the bytes right next to it (in the same cache lines). Checks that the
 * read data equals an aligned read of the same 64 KiB, and that the neighbour bytes hold what the other
 * thread last wrote. Catches DMA cache maintenance that works on whole lines over a buffer sharing them
 * (docs/design/usb-storage-integrity.md). Prints "UA ..." lines; exit 0 when every round was right.
 */
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SIZE (64 * 1024)
#define SKEW 16

static volatile uint8_t* sGuardLow;
static volatile uint8_t* sGuardHigh;
static volatile int sStop;
static volatile uint8_t sLast;


static void*
writer(void* unused)
{
	uint8_t value = 0;
	(void)unused;
	while (!sStop) {
		value++;
		for (int i = 0; i < SKEW; i++) {
			sGuardLow[i] = value;
			sGuardHigh[i] = value;
		}
		__atomic_store_n(&sLast, value, __ATOMIC_RELEASE);
	}
	return NULL;
}


int
main(int argc, char** argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: usbalign DEVICE [OFFSET_MIB] [ROUNDS]\n");
		return 2;
	}
	off_t offset = (argc > 2 ? atoll(argv[2]) : 0) << 20;
	int rounds = argc > 3 ? atoi(argv[3]) : 200;
	int fd = open(argv[1], O_RDONLY);
	if (fd < 0) {
		perror("open");
		return 2;
	}

	uint8_t* reference = aligned_alloc(4096, SIZE);
	uint8_t* area = aligned_alloc(4096, SIZE + 4096);
	uint8_t* buffer = area + 64 + SKEW;
		// starts 16 bytes into a cache line; the 16 bytes before it and after it are the guards
	sGuardLow = buffer - SKEW;
	sGuardHigh = buffer + SIZE;

	int bad = 0, guardBad = 0;
	long badBytes = 0, interior = 0, first = SIZE, lastBad = -1;
		// interior: wrong bytes outside the buffer's first and last cache line
	for (int round = 0; round < rounds; round++) {
		off_t at = offset + (off_t)round * SIZE;
		if (pread(fd, reference, SIZE, at) != SIZE) {
			perror("pread reference");
			return 2;
		}
		sStop = 0;
		pthread_t thread;
		pthread_create(&thread, NULL, writer, NULL);
		ssize_t got = pread(fd, buffer, SIZE, at);
		sStop = 1;
		pthread_join(thread, NULL);
		if (got != SIZE) {
			perror("pread");
			return 2;
		}
		uint8_t last = __atomic_load_n(&sLast, __ATOMIC_ACQUIRE);
		if (memcmp(buffer, reference, SIZE) != 0) {
			bad++;
			for (long i = 0; i < SIZE; i++) {
				if (buffer[i] != reference[i]) {
					badBytes++;
					if (i >= 64 - SKEW && i < SIZE - SKEW)
						interior++;
					if (i < first)
						first = i;
					if (i > lastBad)
						lastBad = i;
				}
			}
		}
		for (int i = 0; i < SKEW; i++) {
			if (sGuardLow[i] != last || sGuardHigh[i] != last) {
				guardBad++;
				break;
			}
		}
	}
	printf("UA rounds %d: data wrong %d (%ld bytes, %ld outside the two edge cache lines; offsets %ld..%ld"
		" of %d), neighbour bytes lost %d\n", rounds, bad, badBytes, interior, bad ? first : 0L,
		bad ? lastBad : 0L, SIZE, guardBad);
	return bad == 0 && guardBad == 0 ? 0 : 1;
}
