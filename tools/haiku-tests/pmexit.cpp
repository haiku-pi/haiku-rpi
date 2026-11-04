/*
 * pmexit.cpp — a program that exits while BPathMonitor's looper is busy (design/tracker-shutdown-crash.md).
 * It watches a path whose ancestors another process creates and removes all the time
 * (tools/pi-tests/pmexit-loop.sh), so the "PathMonitor looper" thread, which nobody quits, handles node
 * monitor messages while exit() runs libbe's terminate_after(). Before haiku cc4746af7f (branch c15-tracker) that
 * deleted BMessage's block cache, and the looper faulted (read 0x34, BBlockCache::Save()/Get() on NULL) in
 * about 1 of 100 runs.
 *
 *   pmexit [MICROSECONDS]   watch for that long (default 20000), then return from main()
 *
 * Cross build: aarch64-unknown-haiku-g++ --sysroot=artifacts/sysroot-arm64
 *     -Isources/haiku/headers/private/storage -O2 -o pmexit pmexit.cpp -lbe
 */
#include <Looper.h>
#include <Messenger.h>
#include <PathMonitor.h>
#include <OS.h>
#include <stdlib.h>

using BPrivate::BPathMonitor;


int
main(int argc, char** argv)
{
	BLooper* looper = new BLooper("target");
	looper->Run();
	BPathMonitor::StartWatching("/boot/home/pmx/a/b/settings_file",
		B_WATCH_STAT | B_WATCH_FILES_ONLY, BMessenger(looper));
	snooze(argc > 1 ? atoi(argv[1]) : 20000);
	looper->Lock();
	looper->Quit();
	return 0;
}
