/*
 * trackeropen.cpp — open an entry the way a double-click in Tracker (or a Deskbar menu item, which
 * sends the same message to Tracker) does: a B_REFS_RECEIVED with the entry's ref (a link is not
 * resolved here; Tracker does that) to Tracker, which launches it with its own environment, working
 * directory and file descriptors. Then waits for a shown window in any team that appeared since.
 *
 *   trackeropen [-q|-w] [-h HOLD-S] PATH [TIMEOUT-S]      (default timeout 60 s, hold 0)
 *
 * Prints "trackeropen: PATH: window after N ms (team T NAME)" or "no window after N ms (new teams: ...)".
 * With -h, then waits HOLD-S s and says whether that team still runs and still shows a window (a program
 * can open a window and die seconds later). With -q, then sends the team B_QUIT_REQUESTED (2 s later; the
 * send's status is printed: a B_ARGV_ONLY application takes no messages) and reports whether it ended
 * within 60 s; -w instead closes its shown windows (B_QUIT_REQUESTED to each, as the close button does).
 * Exit 0 on a window (and, with -h, still shown; with -q, a quit), 1 otherwise.
 *
 * Build (cross):
 *   g=sources/haiku/generated.arm64
 *   $g/cross-tools-arm64/bin/aarch64-unknown-haiku-g++ --sysroot=artifacts/sysroot-arm64 -O2 \
 *     -I sources/haiku/headers/private/interface \
 *     -I sources/haiku/headers/private/app -o trackeropen tools/haiku-tests/trackeropen.cpp -lbe
 */
#include <Application.h>
#include <Entry.h>
#include <Messenger.h>
#include <MessengerPrivate.h>
#include <OS.h>
#include <Roster.h>
#include <WindowInfo.h>

#include <set>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>


static std::set<team_id>
teams()
{
	std::set<team_id> result;
	team_info info;
	int32 cookie = 0;
	while (get_next_team_info(&cookie, &info) == B_OK)
		result.insert(info.team);
	return result;
}


// teams the system starts on its own (servers on demand, the screen saver): not the opened program's
static bool
is_system_team(team_id team)
{
	team_info info;
	if (get_team_info(team, &info) != B_OK)
		return false;
	return strncmp(info.args, "/boot/system/servers/", 21) == 0
		|| strncmp(info.args, "/boot/system/bin/screen_blanker", 31) == 0;
}


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
		if (info->show_hide_level <= 0 && !info->is_mini
			&& info->window_right > info->window_left
			&& info->window_bottom > info->window_top)
			shown = true;
		free(info);
	}
	free(tokens);
	return shown;
}


// B_QUIT_REQUESTED to each shown window of the team, as its close button sends it (works for a
// B_ARGV_ONLY application too, which the roster gives no application messenger); returns how many
static int32
close_windows(team_id team)
{
	int32 count = 0, closed = 0;
	int32* tokens = get_token_list(team, &count);
	for (int32 i = 0; i < count; i++) {
		client_window_info* info = get_window_info(tokens[i]);
		if (info == NULL)
			continue;
		if (info->show_hide_level <= 0 && !info->is_mini) {
			BMessenger window;
			BMessenger::Private(window).SetTo(team, info->client_port, info->client_token);
			if (window.SendMessage(B_QUIT_REQUESTED) == B_OK)
				closed++;
		}
		free(info);
	}
	free(tokens);
	return closed;
}


static const char*
team_name(team_id team)
{
	static team_info info;
	if (get_team_info(team, &info) != B_OK)
		return "(gone)";
	return info.args;
}


int
main(int argc, char** argv)
{
	bool quit = false;
	bool closeWindows = false;
	int hold = 0;
	int arg = 1;
	while (arg < argc && argv[arg][0] == '-') {
		if (strcmp(argv[arg], "-q") == 0 || strcmp(argv[arg], "-w") == 0) {
			quit = true;
			closeWindows = argv[arg][1] == 'w';
			arg++;
		} else if (strcmp(argv[arg], "-h") == 0 && arg + 1 < argc) {
			hold = atoi(argv[arg + 1]);
			arg += 2;
		} else
			break;
	}
	if (arg >= argc) {
		fprintf(stderr, "usage: trackeropen [-q|-w] [-h HOLD-S] PATH [TIMEOUT-S]\n");
		return 2;
	}
	const char* path = argv[arg];
	bigtime_t timeout = (arg + 1 < argc ? atoi(argv[arg + 1]) : 60) * 1000000LL;

	BApplication app("application/x-vnd.haiku-pi-trackeropen");

	entry_ref ref;
	if (get_ref_for_path(path, &ref) != B_OK) {
		fprintf(stderr, "trackeropen: %s: no such entry\n", path);
		return 1;
	}
	BMessenger tracker("application/x-vnd.Be-TRAK");
	if (!tracker.IsValid()) {
		fprintf(stderr, "trackeropen: Tracker is not running\n");
		return 1;
	}

	std::set<team_id> before = teams();
	before.insert(app.Team());
	BMessage message(B_REFS_RECEIVED);
	message.AddRef("refs", &ref);
	bigtime_t start = system_time();
	status_t status = tracker.SendMessage(&message, (BHandler*)NULL);
	if (status != B_OK) {
		fprintf(stderr, "trackeropen: sending to Tracker: %s\n", strerror(status));
		return 1;
	}

	team_id found = -1;
	while (found < 0) {
		std::set<team_id> now = teams();
		for (team_id team : now) {
			if (before.count(team) == 0 && !is_system_team(team) && has_shown_window(team)) {
				found = team;
				break;
			}
		}
		if (found >= 0)
			break;
		if (system_time() - start > timeout) {
			printf("trackeropen: %s: no window after %lld ms (new teams:", path,
				(long long)((system_time() - start) / 1000));
			for (team_id team : now) {
				if (before.count(team) == 0)
					printf(" %d %s;", (int)team, team_name(team));
			}
			printf(")\n");
			return 1;
		}
		snooze(20000);
	}
	printf("trackeropen: %s: window after %lld ms (team %d %s)\n", path,
		(long long)((system_time() - start) / 1000), (int)found, team_name(found));

	if (hold > 0) {
		snooze(hold * 1000000LL);
		team_info info;
		bool alive = get_team_info(found, &info) == B_OK;
		bool shown = alive && has_shown_window(found);
		printf("trackeropen: %s: after %d s more: %s\n", path, hold,
			!alive ? "team gone" : shown ? "running, window shown" : "running, no window shown");
		if (!shown)
			return 1;
	}

	if (quit) {
		snooze(2000000);
		if (closeWindows) {
			printf("trackeropen: %s: B_QUIT_REQUESTED sent to %d window(s)\n", path,
				(int)close_windows(found));
		} else {
			BMessenger messenger(NULL, found);
			status = messenger.IsValid() ? messenger.SendMessage(B_QUIT_REQUESTED) : B_BAD_TEAM_ID;
			printf("trackeropen: %s: B_QUIT_REQUESTED sent: %s\n", path, strerror(status));
		}
		bigtime_t quitTime = system_time();
		team_info info;
		while (get_team_info(found, &info) == B_OK && system_time() - quitTime < 60000000)
			snooze(20000);
		bool gone = get_team_info(found, &info) != B_OK;
		printf("trackeropen: %s: %s after %lld ms\n", path, gone ? "gone" : "still running",
			(long long)((system_time() - quitTime) / 1000));
		return gone ? 0 : 1;
	}
	return 0;
}
