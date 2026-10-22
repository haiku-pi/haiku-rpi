/*
 * A MAP_SHARED file mapping must stay coherent with the file, whatever mprotect() and fork() do to
 * other mappings of the same file.
 *
 * Wine's wineserver writes the session's shared objects through a MAP_SHARED mapping of a temp file,
 * and every Wine process maps that file read-only. On Haiku the server's writes stopped reaching the
 * file part-way through starting a prefix, so the clients read zeros ("Session object id doesn't
 * match"). The kernel did it:
 *
 *  1. mprotect() replaced area->protection outright, dropping B_SHARED_AREA from a MAP_SHARED area;
 *  2. fork() then copied that area as a private one, which made the child's cache a consumer of the
 *     file's (vnode) cache;
 *  3. the next mprotect() of any mapping of the file, with the vnode cache having a consumer,
 *     inserted a copy-on-write cache above it and moved every area of the file onto that new
 *     anonymous cache, the server's writable shared mapping included. Its writes went to private
 *     pages from then on.
 *
 * Build: aarch64-unknown-haiku-gcc -O2 -o mmap-shared-mprotect mmap-shared-mprotect.c
 * Prints PASS and exits 0, or names the step that broke coherence and exits 1.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/wait.h>

#define SIZE (4 * 4096)

static int fd;
static volatile unsigned int *writer;	/* the "server": MAP_SHARED, read-write */
static unsigned int counter;

/* write through the shared mapping and check that the file and a fresh read-only mapping see it */
static int coherent(const char *step)
{
	unsigned int disk = 0;
	volatile unsigned int *fresh;
	int ok;

	writer[SIZE / sizeof(*writer) - 1] = ++counter;
	pread(fd, &disk, sizeof(disk), SIZE - sizeof(disk));
	fresh = mmap(NULL, SIZE, PROT_READ, MAP_SHARED, fd, 0);
	ok = disk == counter && fresh != MAP_FAILED && fresh[SIZE / sizeof(*fresh) - 1] == counter;
	printf("%-58s file %u, fresh mapping %u, expected %u: %s\n", step, disk,
		fresh != MAP_FAILED ? fresh[SIZE / sizeof(*fresh) - 1] : 0, counter, ok ? "ok" : "BROKEN");
	if (fresh != MAP_FAILED)
		munmap((void *)fresh, SIZE);
	return ok;
}

int main(void)
{
	char name[] = "/tmp/mmap-shared-mprotect-XXXXXX";
	volatile unsigned int *reader;
	int ok = 1, pipefd[2];
	pid_t child;

	if ((fd = mkstemp(name)) < 0 || ftruncate(fd, SIZE) != 0) {
		perror("temp file");
		return 2;
	}
	unlink(name);

	writer = mmap(NULL, SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	reader = mmap(NULL, SIZE, PROT_READ, MAP_SHARED, fd, 0);
	if (writer == MAP_FAILED || reader == MAP_FAILED) {
		perror("mmap");
		return 2;
	}
	ok &= coherent("two shared mappings");

	/* what Wine's ntdll does to every view after mapping it */
	mprotect((void *)reader, SIZE, PROT_READ);
	ok &= coherent("after mprotect() of the read-only mapping");

	/* a child that holds on to its copy of the address space, as a forking Wine process does */
	fflush(stdout);
	if (pipe(pipefd) != 0 || (child = fork()) < 0) {
		perror("fork");
		return 2;
	}
	if (child == 0) {
		char c;
		close(pipefd[1]);
		read(pipefd[0], &c, 1);
		_exit(reader[0] == 0xdeadbeef);
	}
	close(pipefd[0]);
	ok &= coherent("after fork(), child alive");

	/* another view of the file, mprotect()ed while the child holds its copy */
	{
		volatile unsigned int *view = mmap(NULL, SIZE, PROT_READ, MAP_SHARED, fd, 0);
		mprotect((void *)view, SIZE, PROT_READ);
		ok &= coherent("after mprotect() of a new mapping, child alive");
		munmap((void *)view, SIZE);
	}

	/* the parent's read-only mapping still follows the file */
	ok &= reader[SIZE / sizeof(*reader) - 1] == counter;
	printf("%-58s %s\n", "the mprotect()ed read-only mapping follows the writes", ok ? "ok" : "BROKEN");

	close(pipefd[1]);
	waitpid(child, NULL, 0);
	ok &= coherent("after the child exited");

	printf("%s\n", ok ? "PASS" : "FAIL");
	return ok ? 0 : 1;
}
