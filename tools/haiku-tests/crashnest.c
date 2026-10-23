/* crashnest.c — crashes with a known call chain (main -> outer -> middle -> inner, a NULL store), for testing
 * crash reports and stack traces: the report should list inner, middle, outer and main. */
#include <stdio.h>

__attribute__((noinline)) static void inner(volatile int* p) { *p = 42; }
__attribute__((noinline)) static void middle(volatile int* p) { inner(p); printf("not reached\n"); }
__attribute__((noinline)) static void outer(volatile int* p) { middle(p); printf("not reached\n"); }

int main(void)
{
	outer(NULL);
	return 0;
}
