/*
 * retrace — measures the display's vertical retrace through BScreen::WaitForRetrace() (the
 * accelerant's retrace semaphore): rate, jitter and the longest gap. "RTR " lines; exit status 0
 * when the rate is 59-61 Hz.
 *
 *   retrace [-s SECONDS]
 */

#include <Application.h>
#include <Screen.h>
#include <OS.h>

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>


int
main(int argc, char** argv)
{
	double seconds = 2;
	int opt;
	while ((opt = getopt(argc, argv, "s:")) != -1) {
		if (opt == 's')
			seconds = atof(optarg);
		else {
			fprintf(stderr, "usage: %s [-s seconds]\n", argv[0]);
			return 2;
		}
	}

	BApplication app("application/x-vnd.haiku-rpi-retrace");
	BScreen screen;
	if (screen.WaitForRetrace(1000000) != B_OK) {
		printf("RTR no retrace (WaitForRetrace failed)\n");
		return 1;
	}

	const bigtime_t start = system_time();
	bigtime_t last = start, longest = 0, shortest = INT64_MAX;
	int count = 0;
	while (system_time() - start < (bigtime_t)(seconds * 1000000)) {
		if (screen.WaitForRetrace(1000000) != B_OK) {
			printf("RTR retrace timed out after %d\n", count);
			return 1;
		}
		const bigtime_t now = system_time();
		const bigtime_t gap = now - last;
		if (gap > longest)
			longest = gap;
		if (gap < shortest)
			shortest = gap;
		last = now;
		count++;
	}
	const double rate = count / ((last - start) / 1000000.0);
	printf("RTR %d retraces in %.3f s = %.2f Hz, gaps %lld..%lld us\n", count,
		(last - start) / 1000000.0, rate, (long long)shortest, (long long)longest);
	return rate >= 59 && rate <= 61 ? 0 : 1;
}
