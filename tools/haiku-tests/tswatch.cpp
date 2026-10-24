/*
 * tswatch.cpp — watches the media kit's preferred time source (the audio output's, which drives the
 * mixer and every media player): every 100 ms it reads the time last published (BTimeSource::GetTime)
 * and reports when that is more than a threshold old — the time source stalled, so sound and the
 * media players' clocks stopped. Prints a summary line every minute.
 *
 *   tswatch [SECONDS] [THRESHOLD-MS]      (default: run for ever, 500 ms)
 *
 * Lines: "TSW stall N ms at T s" for each stall (when it ends), "TSW minute M: max age X ms, stalls S",
 * "TSW end: max age X ms, stalls S".
 *
 * Build (cross):
 *   g=sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-g++
 *   $g --sysroot=artifacts/sysroot-arm64 -O2 -o tswatch tools/haiku-tests/tswatch.cpp -lmedia -lbe
 */
#include <MediaRoster.h>
#include <TimeSource.h>

#include <stdio.h>
#include <stdlib.h>


int
main(int argc, char** argv)
{
	bigtime_t duration = argc > 1 ? atoll(argv[1]) * 1000000LL : 0;
	bigtime_t threshold = (argc > 2 ? atoll(argv[2]) : 500) * 1000;

	status_t status;
	BMediaRoster* roster = BMediaRoster::Roster(&status);
	if (roster == NULL) {
		printf("TSW no media roster: %s\n", strerror(status));
		return 1;
	}
	media_node node;
	status = roster->GetTimeSource(&node);
	if (status != B_OK) {
		printf("TSW no time source: %s\n", strerror(status));
		return 1;
	}
	BTimeSource* source = roster->MakeTimeSourceFor(node);
	if (source == NULL) {
		printf("TSW cannot use the time source\n");
		return 1;
	}
	printf("TSW watching time source %d (%s)\n", (int)node.node, source->Name());
	fflush(stdout);

	bigtime_t start = system_time(), minuteStart = start;
	bigtime_t maxAge = 0, minuteMax = 0, stallStart = -1;
	int stalls = 0, minuteStalls = 0, minute = 0;
	while (duration == 0 || system_time() - start < duration) {
		snooze(100000);
		bigtime_t performance, real;
		float drift;
		if (source->GetTime(&performance, &real, &drift) != B_OK)
			continue;
		bigtime_t now = system_time();
		bigtime_t age = now - real;
		if (age > maxAge)
			maxAge = age;
		if (age > minuteMax)
			minuteMax = age;
		if (age > threshold) {
			if (stallStart < 0)
				stallStart = real;
		} else if (stallStart >= 0) {
			printf("TSW stall %lld ms at %.1f s\n", (long long)((real - stallStart) / 1000),
				(stallStart - start) / 1e6);
			fflush(stdout);
			stallStart = -1;
			stalls++;
			minuteStalls++;
		}
		if (now - minuteStart >= 60000000) {
			printf("TSW minute %d: max age %lld ms, stalls %d\n", ++minute,
				(long long)(minuteMax / 1000), minuteStalls);
			fflush(stdout);
			minuteStart = now;
			minuteMax = 0;
			minuteStalls = 0;
		}
	}
	printf("TSW end: max age %lld ms, stalls %d\n", (long long)(maxAge / 1000), stalls);
	source->Release();
	return 0;
}
