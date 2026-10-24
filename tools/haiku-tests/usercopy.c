/*
 * usercopy.c — the kernel's copies to and from user memory fail cleanly on bad user addresses: read() and
 * write() with a NULL or kernel pointer, and with a buffer that runs into an inaccessible page at every
 * offset 0..63 before it, must return an error (EFAULT/B_BAD_ADDRESS), never crash or hang, and must
 * copy correctly when the buffer fits.
 *
 *   usercopy FILE            (any readable file of 64 KiB or more)
 *
 * Build (cross):
 *   g="sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc --sysroot=artifacts/sysroot-arm64"
 *   $g -O2 -o usercopy tools/haiku-tests/usercopy.c
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

int
main(int argc, char** argv)
{
	if (argc < 2)
		return 2;
	int fd = open(argv[1], O_RDONLY);
	if (fd < 0)
		return 2;
	int failures = 0;
	long page = sysconf(_SC_PAGESIZE);
	char* area = mmap(NULL, 3 * page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	mprotect(area + 2 * page, page, PROT_NONE);
	char reference[8192];
	pread(fd, reference, sizeof(reference), 0);

	if (pread(fd, NULL, 100, 0) != -1 || errno != EFAULT) {
		printf("usercopy: FAIL read into NULL\n");
		failures++;
	}
	if (pread(fd, (void*)0xffff000000100000UL, 100, 0) != -1) {
		printf("usercopy: FAIL read into a kernel address\n");
		failures++;
	}
	for (int before = 0; before < 64; before++) {
		char* buffer = area + 2 * page - before;
		ssize_t n = pread(fd, buffer, 200, 3);
		if (n != -1 && n != before) {
			printf("usercopy: FAIL read across the guard page, %d bytes before it: %zd\n", before, n);
			failures++;
		}
		n = pread(fd, buffer - 100, 100, before);
		if (n != 100 || memcmp(buffer - 100, reference + before, 100) != 0) {
			printf("usercopy: FAIL read that fits, offset %d\n", before);
			failures++;
		}
		int pipes[2];
		pipe(pipes);
		n = write(pipes[1], buffer, 200);
		if (n != -1 && n != before) {
			printf("usercopy: FAIL write from across the guard page: %zd\n", n);
			failures++;
		}
		close(pipes[0]);
		close(pipes[1]);
	}
	printf("usercopy: %s\n", failures == 0 ? "PASS" : "FAIL");
	return failures != 0;
}
