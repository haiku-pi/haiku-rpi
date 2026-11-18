/*
 * schedmode: print or set the kernel scheduler mode (0 low latency, 1 power saving).
 *
 *   schedmode            print the mode
 *   schedmode MODE       set it, then print it
 *
 * Used by tools/pi-tests to check the power-saving mode under load (the IRQ packing loop that could spin with the
 * scheduler lock held, RenkuOS 5de6fe7/f883abc). Build: aarch64-unknown-haiku-gcc -O2 -o schedmode schedmode.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <scheduler.h>

int
main(int argc, char** argv)
{
	if (argc > 1) {
		status_t status = set_scheduler_mode(atoi(argv[1]));
		if (status != B_OK) {
			fprintf(stderr, "schedmode: set_scheduler_mode(%s): %s\n", argv[1], strerror(status));
			return 1;
		}
	}
	printf("scheduler mode %d\n", (int)get_scheduler_mode());
	return 0;
}
