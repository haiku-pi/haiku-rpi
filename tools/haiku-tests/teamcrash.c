/* teamcrash.c — waits until team argv[1] has ended, then stores through NULL: a crash (and debug_server's alert)
 * at a chosen point of a shutdown, e.g. the moment the registrar has quit Tracker (tools/x86-tests/
 * shutdown-respawn.sh, design/tracker-shutdown-crash.md). Under Haiku a team's id is its main thread's id. */
#include <OS.h>
#include <stdlib.h>

int main(int argc, char** argv)
{
	status_t result;

	if (argc != 2)
		return 2;
	wait_for_thread((thread_id)atoi(argv[1]), &result);
	*(volatile int*)0 = 42;
	return 0;
}
