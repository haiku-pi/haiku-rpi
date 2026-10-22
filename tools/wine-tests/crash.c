/* crash.c — a program that faults on purpose, to check the crash instruments (Wine's debugger on an unhandled
 * exception, minidumps, Box64's SIGSEGV report): a known fault in a known place, three calls deep, so a backtrace
 * that names main → outer → inner is right and one that does not is not.
 *   crash.exe [read|write|jump|readonly|smc]    (default write: a store to 0x10; readonly: a store to a page
 *                                            made read-only, which must be reported with that page's address;
 *                                            smc: code that is run, changed and run again — no fault at all,
 *                                            an x86 emulator must notice the change; smc-image: the same in
 *                                            the program's own code section, made writable by VirtualProtect
 *                                            (an image page: copy-on-write); x86 and x86-64 only)
 * Prints "CRASH" lines before the fault. */
#include <windows.h>
#include <stdio.h>
#include <string.h>

static volatile int sink;

#if defined(__i386__) || defined(__x86_64__)
#define X86 1
/* mov eax, 1; ret — in the code section, for smc-image (i386 symbols have a leading underscore) */
int smc_image_fn(void);
#ifdef __i386__
__asm__(".text\n.globl _smc_image_fn\n_smc_image_fn:\n\tmovl $1, %eax\n\tret\n");
#else
__asm__(".text\n.globl smc_image_fn\nsmc_image_fn:\n\tmovl $1, %eax\n\tret\n");
#endif
#endif

__declspec(noinline) static void inner(const char *how)
{
	printf("CRASH inner: %s\n", how);
	fflush(stdout);
	if (!strcmp(how, "read"))
		sink = *(volatile int *)0x10;
	else if (!strcmp(how, "readonly")) {
		static volatile int page[2048] __attribute__((aligned(4096)));
		DWORD old;
		page[0] = 1;
		VirtualProtect((void *)page, 4096, PAGE_READONLY, &old);
		printf("CRASH writing to read-only %p\n", (void *)page);
		fflush(stdout);
		page[1] = 42;
	} else if (!strcmp(how, "smc")) {
#ifdef X86
		/* mov eax, imm32; ret — run, then patched to return another value (as Quake's renderer patches itself) */
		unsigned char *code = VirtualAlloc(NULL, 4096, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
		int (*fn)(void) = (int (*)(void))code;
		int a, b;
		memcpy(code, "\xb8\x01\x00\x00\x00\xc3", 6);
		a = fn();
		*(volatile int *)(code + 1) = 2;
		b = fn();
		printf("CRASH smc: %d then %d (%s)\n", a, b, a == 1 && b == 2 ? "ok" : "WRONG");
#else
		printf("CRASH smc: x86 only\n");
#endif
	} else if (!strcmp(how, "smc-image")) {
#ifdef X86
		DWORD old;
		int a, b;
		a = smc_image_fn();
		VirtualProtect((void *)smc_image_fn, 8, PAGE_EXECUTE_READWRITE, &old);
		printf("CRASH smc-image: patching %p (protection was %#lx)\n", (void *)smc_image_fn, old);
		fflush(stdout);
		*(volatile int *)((char *)smc_image_fn + 1) = 2;
		b = smc_image_fn();
		printf("CRASH smc-image: %d then %d (%s)\n", a, b, a == 1 && b == 2 ? "ok" : "WRONG");
#else
		printf("CRASH smc-image: x86 only\n");
#endif
	} else if (!strcmp(how, "jump"))
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
