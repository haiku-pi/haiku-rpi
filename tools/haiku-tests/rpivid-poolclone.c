/*
 * rpivid-poolclone — the rpivid scan-out pool must not hand out memory that a clone of a released picture still
 * maps (docs/design/hw-video-decode.md §10.5). A client can clone its own picture (the mapping is cloneable for
 * app_server) and keep the clone after deleting the picture; the display can be showing a picture it imported.
 *
 *   rpivid-poolclone          prints PASS or FAIL lines, exit status 0 = PASS
 *
 * 1. picture A (1920x1080, scan-out), clone of its mapping; A deleted (the clone stays)
 * 2. the device report must say "1 gone but still cloned"; picture B then makes it "in 2 pictures": B got a part of
 *    the pool of its own, not A's, which the clone still maps
 * 3. the clone deleted; picture C: the pool may hand out A's place again ("0 gone but still cloned")
 *
 * Build (cross):
 *   h=sources/haiku-v7/headers/private
 *   sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc --sysroot=artifacts/sysroot-arm64 \
 *     -O2 -I$h/drivers -o rpivid-poolclone tools/haiku-tests/rpivid-poolclone.c
 */
#include <OS.h>

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <rpivid.h>


static int sFailures;


static void
check(int ok, const char* what)
{
	printf("%s %s\n", ok ? "PASS" : "FAIL", what);
	if (!ok)
		sFailures++;
}


static int
create(int fd, rpivid_create_picture* picture)
{
	memset(picture, 0, sizeof(*picture));
	picture->width = 1920;
	picture->height = 1080;
	picture->bit_depth = 8;
	picture->flags = RPIVID_PICTURE_SCAN_OUT;
	return ioctl(fd, RPIVID_CREATE_PICTURE, picture, sizeof(*picture));
}


static void
delete_picture(int fd, uint32_t handle)
{
	rpivid_delete_buffer args = { handle, 0 };
	ioctl(fd, RPIVID_DELETE_BUFFER, &args, sizeof(args));
}


/* the device report's pool line */
static void
pool_line(char* line, size_t size)
{
	char report[16384];
	line[0] = '\0';
	int fd = open(RPIVID_DEVICE_PATH, O_RDONLY);
	if (fd < 0)
		return;
	ssize_t length = read(fd, report, sizeof(report) - 1);
	close(fd);
	if (length <= 0)
		return;
	report[length] = '\0';
	char* start = strstr(report, "scan-out pool:");
	if (start == NULL)
		return;
	char* end = strchr(start, '\n');
	if (end != NULL)
		*end = '\0';
	strlcpy(line, start, size);
}


int
main()
{
	int fd = open(RPIVID_DEVICE_PATH, O_RDWR);
	if (fd < 0) {
		printf("FAIL no %s\n", RPIVID_DEVICE_PATH);
		return 1;
	}
	char line[256];

	rpivid_create_picture a;
	if (create(fd, &a) != 0) {
		printf("FAIL picture A: %s\n", strerror(errno));
		return 1;
	}
	area_id source = area_for((void*)(addr_t)a.address);
	void* cloneAddress;
	area_id clone = clone_area("rpivid-poolclone", &cloneAddress, B_ANY_ADDRESS, B_READ_AREA, source);
	check(clone >= 0, "a clone of picture A's mapping");
	delete_picture(fd, a.handle);
	pool_line(line, sizeof(line));
	printf("after A deleted: %s\n", line);
	check(strstr(line, " 1 gone but still cloned") != NULL, "A waits for its clone");

	rpivid_create_picture b;
	check(create(fd, &b) == 0, "picture B");
	pool_line(line, sizeof(line));
	printf("after B made: %s\n", line);
	check(strstr(line, " in 2 pictures") != NULL && strstr(line, " 1 gone but still cloned") != NULL,
		"B has a part of its own, A's is kept for the clone");

	delete_area(clone);
	delete_picture(fd, b.handle);
	rpivid_create_picture c;
	check(create(fd, &c) == 0, "picture C");
	pool_line(line, sizeof(line));
	printf("after the clone and B went, C made: %s\n", line);
	check(strstr(line, " 0 gone but still cloned") != NULL, "nothing waits any more");
	delete_picture(fd, c.handle);
	close(fd);

	printf("%s (%d failures)\n", sFailures == 0 ? "PASS" : "FAIL", sFailures);
	return sFailures == 0 ? 0 : 1;
}
