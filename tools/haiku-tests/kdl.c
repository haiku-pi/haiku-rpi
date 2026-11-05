/*
 * kdl.c — enter the kernel debugger with a message, from a script (root only). For catching a hang's state:
 * a bootscript notices the hang, prints what it knows and runs `kdl MESSAGE`; the host then types KDL commands
 * into the serial port (scripts/kdl-x86.py on x86-64 under KVM).
 *
 *   kdl [MESSAGE]
 *
 * Build (cross): $tp-gcc --sysroot=SYSROOT -O2 -o kdl tools/haiku-tests/kdl.c
 */
#include <stdio.h>
#include <string.h>

#include <OS.h>

extern status_t _kern_kernel_debugger(const char* message);

int
main(int argc, char** argv)
{
	const char* message = argc > 1 ? argv[1] : "kdl";
	status_t status = _kern_kernel_debugger(message);
	if (status != B_OK) {
		fprintf(stderr, "kdl: %s\n", strerror(status));
		return 1;
	}
	return 0;
}
