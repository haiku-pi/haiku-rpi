/* ramp.c — after an idle pause, busy-loop and print the work done per 20 ms window: how long the CPU clock
 * takes to reach its maximum when a burst starts. */
#include <OS.h>
#include <stdio.h>
int main(void)
{
	snooze(2000000);
	volatile unsigned long x = 0;
	bigtime_t start = system_time();
	unsigned long counts[60];
	for (int w = 0; w < 60; w++) {
		bigtime_t end = start + (w + 1) * 20000;
		unsigned long n = 0;
		while (system_time() < end) {
			for (int i = 0; i < 1000; i++) x += i;
			n++;
		}
		counts[w] = n;
	}
	unsigned long max = 0;
	for (int w = 0; w < 60; w++) if (counts[w] > max) max = counts[w];
	for (int w = 0; w < 60; w += 2) printf("%4d ms %3lu%%\n", w * 20, counts[w] * 100 / max);
	return 0;
}
