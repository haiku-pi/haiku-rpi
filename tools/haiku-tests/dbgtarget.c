/* dbgtarget.c — a target for Haiku's Debugger (tools/pi-tests/armdbg.sh drives its command line interface):
 * main() calls add3() twice through twice(), printing the results ("dbgtarget: 13 16 (3 calls)"). Build it with -g -O0
 * so that every statement has its own instructions. */
#include <stdio.h>

int gCalls;

int
add3(int value)
{
	int result = value;
	result += 1;
	result += 2;
	gCalls++;
	return result;
}

int
twice(int value)
{
	int first = add3(value);
	int second = add3(first);
	return second;
}

int
main(void)
{
	int a = add3(10);
	int b = twice(10);
	printf("dbgtarget: %d %d (%d calls)\n", a, b, gCalls);
	return 0;
}
