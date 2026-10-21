/* crash.c — a program that faults on purpose, to check the crash instruments (Wine's debugger on an unhandled
 * exception, minidumps, Box64's SIGSEGV report): a known fault in a known place, three calls deep, so a backtrace
 * that names main → outer → inner is right and one that does not is not.
 *   crash.exe [read|write|jump]    (default write: a store to 0x10)
 * Prints "CRASH" lines before the fault. */
#include <stdio.h>
#include <string.h>

static volatile int sink;

__declspec(noinline) static void inner(const char *how)
{
	printf("CRASH inner: %s\n", how);
	fflush(stdout);
	if (!strcmp(how, "read"))
		sink = *(volatile int *)0x10;
	else if (!strcmp(how, "jump"))
		((void (*)(void))0x10)();
	else
		*(volatile int *)0x10 = 42;
}

__declspec(noinline) static void outer(const char *how)
{
	inner(how);
	sink++;
}

int main(int argc, char **argv)
{
	printf("CRASH start\n");
	fflush(stdout);
	outer(argc > 1 ? argv[1] : "write");
	printf("CRASH not reached\n");
	return 0;
}
