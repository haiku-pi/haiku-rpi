/*
 * argcount.cpp — does an application started through a wrapper that exec()s it get its arguments once?
 * (R4, the libbe fix for programs the roster launched that exec another program: docs/design/tracker-launch.md.)
 *
 *   argcount launch WRAPPER [ARGS...]        BRoster::Launch(ref, argc, argv) of WRAPPER (a script that
 *                                            ends in `exec argcount "$@"`)
 *   argcount launch-refs WRAPPER FILE...     BRoster::Launch(ref, B_REFS_RECEIVED with FILE's refs), as
 *                                            Tracker does for files dropped onto the wrapper
 *   argcount [ARGS...]                       the application: appends to /tmp/argcount.log its argv, every
 *                                            ArgvReceived() and RefsReceived() and ReadyToRun(), then quits
 *                                            3 s after ReadyToRun()
 *
 * Build (cross):
 *   g=sources/haiku/generated.arm64
 *   $g/cross-tools-arm64/bin/aarch64-unknown-haiku-g++ --sysroot=artifacts/sysroot-arm64 -O2 \
 *     -o argcount tools/haiku-tests/argcount.cpp -lbe
 */
#include <Application.h>
#include <Entry.h>
#include <MessageRunner.h>
#include <OS.h>
#include <Path.h>
#include <Roster.h>

#include <stdio.h>
#include <string.h>


static void
logLine(const char* format, const char* text, int number)
{
	FILE* file = fopen("/tmp/argcount.log", "a");
	if (file == NULL)
		return;
	fprintf(file, "team %" B_PRId32 ": ", getpid());
	fprintf(file, format, text, number);
	fputc('\n', file);
	fclose(file);
}


class ArgCount : public BApplication {
public:
	ArgCount()
		:
		BApplication("application/x-vnd.haiku-pi-argcount")
	{
	}

	virtual void ArgvReceived(int32 argc, char** argv)
	{
		BString all;
		for (int32 i = 0; i < argc; i++)
			all << (i > 0 ? " " : "") << argv[i];
		logLine("ArgvReceived: %s (argc %d)", all.String(), argc);
	}

	virtual void RefsReceived(BMessage* message)
	{
		entry_ref ref;
		for (int32 i = 0; message->FindRef("refs", i, &ref) == B_OK; i++)
			logLine("RefsReceived: %s (#%d)", ref.name, i);
	}

	virtual void ReadyToRun()
	{
		logLine("ReadyToRun%s%d", "", 0);
		BMessageRunner::StartSending(this, new BMessage(B_QUIT_REQUESTED), 3000000, 1);
	}
};


int
main(int argc, char** argv)
{
	if (argc >= 3 && (strcmp(argv[1], "launch") == 0 || strcmp(argv[1], "launch-refs") == 0)) {
		BApplication app("application/x-vnd.haiku-pi-argcount-launcher");
		entry_ref ref;
		if (get_ref_for_path(argv[2], &ref) != B_OK)
			return 1;
		team_id team = -1;
		status_t status;
		if (strcmp(argv[1], "launch") == 0) {
			status = be_roster->Launch(&ref, argc - 3, argv + 3, &team);
		} else {
			BMessage refs(B_REFS_RECEIVED);
			for (int i = 3; i < argc; i++) {
				entry_ref file;
				if (get_ref_for_path(argv[i], &file) == B_OK)
					refs.AddRef("refs", &file);
			}
			status = be_roster->Launch(&ref, &refs, &team);
		}
		printf("argcount: %s %s: %s (team %" B_PRId32 ")\n", argv[1], argv[2], strerror(status), team);
		return status == B_OK ? 0 : 1;
	}

	BString all;
	for (int i = 0; i < argc; i++)
		all << (i > 0 ? " " : "") << argv[i];
	logLine("main argv: %s (argc %d)", all.String(), argc);
	ArgCount app;
	app.Run();
	return 0;
}
