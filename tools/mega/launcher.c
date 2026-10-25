/*
 * launcher.c — a double-clickable program that runs one shell command: the mega image's "Test Apps"
 * (scripts/build-mega-image.sh) are these, one per test program, because Tracker opens shell scripts
 * in an editor rather than running them. The command's output goes to ~/mega-logs/NAME.log.
 *
 * Build (cross), one binary per entry:
 *   $g -O2 -DNAME='"quakespasm"' -DCOMMAND='"cd ... && exec ./quakespasm"' -o Quake tools/mega/launcher.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

int
main(void)
{
	char log[256];
	const char* home = getenv("HOME");
	snprintf(log, sizeof(log), "%s/mega-logs", home != NULL ? home : "/boot/home");
	mkdir(log, 0755);
	snprintf(log, sizeof(log), "%s/mega-logs/%s.log", home != NULL ? home : "/boot/home", NAME);
	if (freopen(log, "w", stdout) != NULL)
		dup2(STDOUT_FILENO, STDERR_FILENO);
	execl("/bin/sh", "sh", "-c", COMMAND, (char*)NULL);
	perror("launcher: /bin/sh");
	return 1;
}
