/*
 * teamstat — CPU time and memory of teams, and the system's CPU use, over an interval (H21 step 3: MediaPlayer
 * decoding H.264 on the VideoCore or on the CPU, docs/design/vchiq.md §8).
 *
 *   teamstat [-i SECS] TEAM...     (default 10 s)
 *
 * For each team: "TEAMSTAT team <id> <name>: cpu <s> s = <p> % of one CPU over <s> s; <n> areas, <MB> MB, <MB> MB
 * in RAM" (the areas when the interval ends), then "TEAMSTAT system: busy <p> % of <n> CPUs, <MB> MB used". A team
 * that is gone at the end prints "gone".
 *
 * Copyright 2026, Haiku-Pi project. Distributed under the terms of the MIT License.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <OS.h>


static bigtime_t
team_cpu(team_id team)
{
	team_usage_info usage;
	if (get_team_usage_info(team, B_TEAM_USAGE_SELF, &usage) != B_OK)
		return -1;
	return usage.user_time + usage.kernel_time;
}


static bigtime_t
system_busy(uint32* _count)
{
	system_info info;
	cpu_info cpus[64];
	bigtime_t busy = 0;
	uint32 i;

	get_system_info(&info);
	if (info.cpu_count > 64)
		info.cpu_count = 64;
	get_cpu_info(0, info.cpu_count, cpus);
	for (i = 0; i < info.cpu_count; i++)
		busy += cpus[i].active_time;
	*_count = info.cpu_count;
	return busy;
}


int
main(int argc, char** argv)
{
	double seconds = 10;
	int first = 1, count, i;
	bigtime_t* before;
	bigtime_t start, end, busyBefore, busyAfter;
	uint32 cpus;
	system_info info;

	if (argc > 2 && strcmp(argv[1], "-i") == 0) {
		seconds = atof(argv[2]);
		first = 3;
	}
	count = argc - first;
	if (count < 1) {
		fprintf(stderr, "usage: %s [-i SECS] TEAM...\n", argv[0]);
		return 2;
	}

	before = calloc(count, sizeof(bigtime_t));
	for (i = 0; i < count; i++)
		before[i] = team_cpu(atoi(argv[first + i]));
	busyBefore = system_busy(&cpus);
	start = system_time();
	snooze((bigtime_t)(seconds * 1000000));
	end = system_time();
	busyAfter = system_busy(&cpus);

	for (i = 0; i < count; i++) {
		team_id team = atoi(argv[first + i]);
		bigtime_t after = team_cpu(team);
		team_info teamInfo;
		area_info area;
		ssize_t cookie = 0;
		uint64 size = 0, ram = 0;
		int areas = 0;

		if (after < 0 || before[i] < 0 || get_team_info(team, &teamInfo) != B_OK) {
			printf("TEAMSTAT team %d: gone\n", (int)team);
			continue;
		}
		while (get_next_area_info(team, &cookie, &area) == B_OK) {
			areas++;
			size += area.size;
			ram += area.ram_size;
		}
		printf("TEAMSTAT team %d %s: cpu %.3f s = %.1f %% of one CPU over %.1f s; %d areas, %.1f MB, %.1f MB in"
			" RAM\n", (int)team, teamInfo.args, (after - before[i]) / 1e6,
			100.0 * (after - before[i]) / (end - start), (end - start) / 1e6, areas, size / 1048576.0,
			ram / 1048576.0);
	}
	get_system_info(&info);
	printf("TEAMSTAT system: busy %.1f %% of %u CPUs, %.1f MB used\n",
		100.0 * (busyAfter - busyBefore) / ((double)(end - start) * cpus), cpus,
		info.used_pages * (double)B_PAGE_SIZE / 1048576.0);
	return 0;
}
