/*
 * systime.c — prints system_time() (microseconds since the kernel started) and real time, for boot-time
 * measurements from a bootscript (tools/x86-tests/perf.sh): "SYSTIME <us> <unix seconds>".
 *
 * Build: x86_64-unknown-haiku-gcc --sysroot=artifacts/sysroot-x86_64 -O2 -o systime systime.c
 */
#include <OS.h>
#include <stdio.h>
#include <time.h>

int
main(void)
{
	printf("SYSTIME %lld %lld\n", (long long)system_time(), (long long)time(NULL));
	return 0;
}
