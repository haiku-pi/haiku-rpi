/*
 * launchtime.cpp — how long an application takes from launch to its first shown window: launches it
 * through the roster (as the Deskbar or Tracker would) and polls the app_server's window list.
 *
 *   launchtime [-q] APP-PATH-OR-SIGNATURE [TIMEOUT-S]     (default timeout 60 s)
 *
 * Prints "launchtime: NAME: window after N ms (team T)" and, with -q, quits the application afterwards
 * (B_QUIT_REQUESTED), so that a loop can measure cold and warm starts in turn, and waits for its team
 * to end ("gone after N ms"). The quit comes 2 s after the window: Firefox sent a quit within
 * ~100 ms of its first window stalls in shutdown until its 50-s watchdog aborts it, and the next launch
 * then ran beside the dying one. Exit 0 on a window, 1 on a timeout or a failed launch.
 *
 * Build (cross):
 *   g=sources/haiku/generated.arm64
 *   $g/cross-tools-arm64/bin/aarch64-unknown-haiku-g++ --sysroot=artifacts/sysroot-arm64 -O2 \
 *     -I sources/haiku/headers/private/interface -o launchtime tools/haiku-tests/launchtime.cpp -lbe
 */
#include <Application.h>
#include <Entry.h>
#include <Messenger.h>
#include <OS.h>
#include <Roster.h>
#include <WindowInfo.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>


static bool
has_shown_window(team_id team)
{
	int32 count = 0;
	int32* tokens = get_token_list(team, &count);
	bool shown = false;
	for (int32 i = 0; i < count && !shown; i++) {
		client_window_info* info = get_window_info(tokens[i]);
		if (info == NULL)
			continue;
		// show_hide_level <= 0: shown; skip the minimized and the zero-sized (hidden helper windows)
		if (info->show_hide_level <= 0 && !info->is_mini
			&& info->window_right > info->window_left
			&& info->window_bottom > info->window_top)
			shown = true;
		free(info);
	}
	free(tokens);
	return shown;
}


int
main(int argc, char** argv)
{
	bool quit = false;
	int arg = 1;
	if (arg < argc && strcmp(argv[arg], "-q") == 0) {
		quit = true;
		arg++;
	}
	if (arg >= argc) {
		fprintf(stderr, "usage: launchtime [-q] APP-PATH-OR-SIGNATURE [TIMEOUT-S]\n");
		return 2;
	}
	const char* target = argv[arg];
	bigtime_t timeout = (arg + 1 < argc ? atoi(argv[arg + 1]) : 60) * 1000000LL;

	BApplication app("application/x-vnd.haiku-pi-launchtime");

	team_id team = -1;
	bigtime_t start = system_time();
	status_t status;
	if (strchr(target, '/') != NULL) {
		entry_ref ref;
		status = get_ref_for_path(target, &ref);
		if (status == B_OK)
			status = be_roster->Launch(&ref, (BMessage*)NULL, &team);
	} else
		status = be_roster->Launch(target, (BMessage*)NULL, &team);
	if (status != B_OK && status != B_ALREADY_RUNNING) {
		fprintf(stderr, "launchtime: %s: launch failed: %s\n", target, strerror(status));
		return 1;
	}

	while (!has_shown_window(team)) {
		if (system_time() - start > timeout) {
			printf("launchtime: %s: no window after %lld ms (team %d)\n", target,
				(long long)((system_time() - start) / 1000), (int)team);
			return 1;
		}
		snooze(5000);
	}
	printf("launchtime: %s: window after %lld ms (team %d)\n", target,
		(long long)((system_time() - start) / 1000), (int)team);

	if (quit) {
		snooze(2000000);
		BMessenger messenger(NULL, team);
		messenger.SendMessage(B_QUIT_REQUESTED);
		bigtime_t quitTime = system_time();
		team_info info;
		while (get_team_info(team, &info) == B_OK && system_time() - quitTime < 90000000)
			snooze(20000);
		printf("launchtime: %s: %s after %lld ms\n", target,
			get_team_info(team, &info) == B_OK ? "still running" : "gone",
			(long long)((system_time() - quitTime) / 1000));
	}
	return 0;
}
