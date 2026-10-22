/*
 * A store to a write-protected page whose SIGSEGV handler makes the page writable again must succeed
 * when retried: this is how x86 emulators (FEX, Box64) notice self-modifying code — they write-protect
 * the pages they translated, and on the fault invalidate the translation and unprotect the page.
 *
 * Each case write-protects a page of an executable mapping (PROT_READ|PROT_EXEC), stores to it, and
 * counts the faults; the handler gives the page PROT_READ|PROT_WRITE|PROT_EXEC back. One fault is
 * right; more than a few is the retry faulting again (FEX on Haiku: an endless loop).
 *
 * Build: aarch64-unknown-haiku-gcc -O2 -o mprotect-unprotect-retry mprotect-unprotect-retry.c
 */

#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <OS.h>

#define PAGE 4096

static volatile int faults;
static char *fault_page;

static void handler(int sig, siginfo_t *info, void *context)
{
	(void)sig;
	(void)context;
	if (++faults > 5 || (char *)info->si_addr < fault_page || (char *)info->si_addr >= fault_page + PAGE) {
		/* give up: make the page writable whatever happens next, and report */
		mprotect(fault_page, PAGE, PROT_READ | PROT_WRITE);
		return;
	}
	mprotect(fault_page, PAGE, PROT_READ | PROT_WRITE | PROT_EXEC);
}

static int run(const char *name, size_t pages, size_t index, int rwx)
{
	int prot = PROT_READ | PROT_WRITE | (rwx ? PROT_EXEC : 0);
	char *base = mmap(NULL, pages * PAGE, prot, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	int ok;

	if (base == MAP_FAILED) {
		perror("mmap");
		return 0;
	}
	fault_page = base + index * PAGE;
	memset(base, 0xc3, pages * PAGE);
	{
		area_info info;
		int before, r;
		get_area_info(area_for(fault_page), &info);
		before = (int)info.protection;
		r = mprotect(fault_page, PAGE, PROT_READ | (rwx ? PROT_EXEC : 0));
		get_area_info(area_for(fault_page), &info);
		printf("  mprotect -> %d, area %d protection %#x -> %#x\n", r, (int)info.area, before, (int)info.protection);
	}
	faults = 0;
	*(volatile char *)(fault_page + 1) = 42;
	ok = faults == 1 && fault_page[1] == 42;
	printf("%-48s %d fault(s): %s\n", name, faults, ok ? "ok" : "BROKEN");
	munmap(base, pages * PAGE);
	return ok;
}

int main(void)
{
	struct sigaction sa;
	int ok = 1;

	memset(&sa, 0, sizeof(sa));
	sa.sa_sigaction = handler;
	sa.sa_flags = SA_SIGINFO;
	sigemptyset(&sa.sa_mask);
	sigaction(SIGSEGV, &sa, NULL);
	sigaction(SIGBUS, &sa, NULL);

	ok &= run("one-page mapping, rw-", 1, 0, 0);
	ok &= run("one-page mapping, rwx", 1, 0, 1);
	ok &= run("page 3 of a 16-page mapping, rw-", 16, 3, 0);
	ok &= run("page 3 of a 16-page mapping, rwx", 16, 3, 1);
	printf("%s\n", ok ? "PASS" : "FAIL");
	return ok ? 0 : 1;
}
