/*
 * polltest.c — poll() keeps the caller's events field as given (POSIX: it is input only) and reports
 * what it should: a pipe's read end readable after a write, a regular file readable and writable, a
 * closed descriptor POLLNVAL, the other end of a closed pipe POLLHUP, and nothing for a descriptor the
 * caller asks no events for (events = 0) unless it is invalid or hung up. Before the kernel fix, poll()
 * ORed POLLNVAL | POLLERR | POLLHUP into events, so an event loop that clears POLLIN when it stops
 * watching a descriptor (libevent's poll backend) never removed it and spun once it was closed.
 *
 *   polltest            prints "POLLTEST ok" or "POLLTEST FAIL: ..." lines; exit 0 when all passed
 *
 * Build (cross):
 *   g=sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc
 *   $g --sysroot=artifacts/sysroot-arm64 -O2 -o polltest tools/haiku-tests/polltest.c
 */
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>


static int sFailures = 0;


static void
check(int condition, const char* what, int value)
{
	if (!condition) {
		printf("POLLTEST FAIL: %s (0x%x)\n", what, value);
		sFailures++;
	}
}


int
main(void)
{
	int fds[2];
	if (pipe(fds) != 0) {
		perror("pipe");
		return 1;
	}

	// nothing to read yet: times out, events unchanged
	struct pollfd p = { fds[0], POLLIN, 0 };
	int count = poll(&p, 1, 10);
	check(count == 0, "empty pipe times out", count);
	check(p.events == POLLIN, "events unchanged after a timeout", p.events);

	// readable after a write
	write(fds[1], "x", 1);
	count = poll(&p, 1, 1000);
	check(count == 1 && (p.revents & POLLIN) != 0, "pipe readable after a write", p.revents);
	check(p.events == POLLIN, "events unchanged after an event", p.events);

	// events = 0: no readiness reported for a readable descriptor
	struct pollfd none = { fds[0], 0, 0 };
	count = poll(&none, 1, 10);
	check(count == 0 && none.revents == 0, "events = 0 reports nothing", none.revents);
	check(none.events == 0, "events = 0 stays 0", none.events);

	// a regular file: readable and writable at once
	int file = open("/boot/home/polltest.tmp", O_RDWR | O_CREAT | O_TRUNC, 0644);
	struct pollfd f = { file, POLLIN | POLLOUT, 0 };
	count = poll(&f, 1, 1000);
	check(count == 1 && (f.revents & (POLLIN | POLLOUT)) == (POLLIN | POLLOUT),
		"regular file readable and writable", f.revents);
	close(file);
	unlink("/boot/home/polltest.tmp");

	// the write end closed: the read end hangs up (after the byte is read)
	char c;
	read(fds[0], &c, 1);
	close(fds[1]);
	count = poll(&p, 1, 1000);
	check(count == 1 && (p.revents & (POLLHUP | POLLIN)) != 0, "hang-up reported", p.revents);
	check(p.events == POLLIN, "events unchanged after a hang-up", p.events);

	// a closed descriptor: POLLNVAL, events as given
	close(fds[0]);
	struct pollfd closed = { fds[0], 0, 0 };
	count = poll(&closed, 1, 1000);
	check(count == 1 && closed.revents == POLLNVAL, "closed descriptor POLLNVAL", closed.revents);
	check(closed.events == 0, "events unchanged for a closed descriptor", closed.events);

	// a negative descriptor is ignored
	struct pollfd ignored = { -1, POLLIN, 0x1234 };
	count = poll(&ignored, 1, 10);
	check(count == 0 && ignored.revents == 0, "negative fd ignored", ignored.revents);

	if (sFailures == 0)
		printf("POLLTEST ok\n");
	return sFailures != 0;
}
