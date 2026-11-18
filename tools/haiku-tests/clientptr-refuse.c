/*
 * clientptr-refuse — the kernel side of GL_MESA_map_buffer_client_pointer (docs/design/gl-client-pointer.md §3.3):
 * DRM_IOCTL_V3D_MMAP_BO with DRM_V3D_HAIKU_MMAP_BO_PLACED, which clones a BO at an address the client chooses,
 * replacing what is mapped there (vm_clone_area_etc() with CREATE_AREA_UNMAP_ADDRESS_RANGE). Checks what it must
 * refuse and that the good case leaves the range as the client expects:
 *
 *   a  an unaligned address is refused (the driver: B_BAD_ADDRESS), the memory there untouched
 *   b  a range holding a kernel-protected area of the team (B_KERNEL_AREA: the "commpage" and the "user area",
 *      found by name with get_next_area_info) is refused (B_NOT_ALLOWED) — run in a child team, since a kernel
 *      that wrongly replaced them would kill the caller; a kernel address is refused too
 *   c  wired memory: userland cannot keep a range of its own areas wired (mlock() wires only for the duration of
 *      the syscall, user_set_memory_swappable(); lock_memory() is kernel-only; the v3d driver's IMPORT_MEMORY
 *      wires a kernel clone, not the client's area), so the B_BUSY refusal cannot be reached from here. Checked
 *      instead: placing over memory imported as a BO (wired through that kernel clone) works, and the imported BO
 *      outlives the replaced range (its handle closes cleanly, nothing is left mapped there but the placed BO)
 *   d  the BO's own (unplaced) mapping as the target: replaced by a new mapping of the same BO in place (the source
 *      of a clone is the BO's kernel area, never in a user range): the data written through the old mapping is
 *      read through the new one
 *   e  over a PROT_NONE reservation (Wine's): the placed map succeeds, the area is the BO's ("v3d bo map"), the
 *      BO's data is there (as seen through a second, ordinary mapping of the BO); then mmap(MAP_FIXED, PROT_NONE,
 *      MAP_NORESERVE) over it (what Wine's MEM_RELEASE and a "reserve" unmap do) leaves the range reserved, not
 *      free, and the rest of the reservation as it was
 *
 * Needs a kernel with DRM_V3D_PARAM_HAIKU_MMAP_BO_PLACED (else "param FAIL"). Lines "CPREF <case> ok|FAIL ...";
 * the last one "CPREF result: N problems" (exit status 0 when N is 0).
 *
 *   clientptr-refuse
 */

#include <OS.h>

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

#include <xf86drm.h>

/* the v3d uAPI (headers/private/drivers/drm/v3d_drm.h in Haiku's tree), the parts used here */
struct v3d_create_bo { uint32_t size, flags, handle, offset; };
struct v3d_mmap_bo { uint32_t handle, flags; uint64_t offset; };
struct v3d_get_param { uint32_t param, pad; uint64_t value; };
struct v3d_import_memory { uint64_t address, size; uint32_t handle, offset; };
struct v3d_gem_close { uint32_t handle, pad; };

#define V3D_CREATE_BO		0x02
#define V3D_MMAP_BO			0x03
#define V3D_GET_PARAM		0x04
#define V3D_IMPORT_MEMORY	0x30
#define IOCTL_CREATE_BO		DRM_IOWR(DRM_COMMAND_BASE + V3D_CREATE_BO, struct v3d_create_bo)
#define IOCTL_MMAP_BO		DRM_IOWR(DRM_COMMAND_BASE + V3D_MMAP_BO, struct v3d_mmap_bo)
#define IOCTL_GET_PARAM		DRM_IOWR(DRM_COMMAND_BASE + V3D_GET_PARAM, struct v3d_get_param)
#define IOCTL_IMPORT_MEMORY	DRM_IOWR(DRM_COMMAND_BASE + V3D_IMPORT_MEMORY, struct v3d_import_memory)
#define IOCTL_GEM_CLOSE		DRM_IOW(0x09, struct v3d_gem_close)
#define MMAP_BO_PLACED		(1u << 31)
#define PARAM_MMAP_BO_PLACED	0x1000

#define PAGE B_PAGE_SIZE

static int sFd = -1;
static int sProblems = 0;

#define SAY(...) do { printf("CPREF " __VA_ARGS__); printf("\n"); fflush(stdout); } while (0)
#define RESULT(name, cond, fmt, ...) do { \
		if (cond) \
			SAY("%s ok: " fmt, name, ##__VA_ARGS__); \
		else { \
			SAY("%s FAIL: " fmt, name, ##__VA_ARGS__); \
			sProblems++; \
		} \
	} while (0)

static uint32_t
create_bo(size_t size)
{
	struct v3d_create_bo create = { .size = size };
	if (drmIoctl(sFd, IOCTL_CREATE_BO, &create) != 0) {
		SAY("setup FAIL: CREATE_BO %zu: %s", size, strerror(errno));
		exit(1);
	}
	return create.handle;
}

static void
close_bo(uint32_t handle)
{
	struct v3d_gem_close c = { .handle = handle };
	drmIoctl(sFd, IOCTL_GEM_CLOSE, &c);
}

/* an ordinary mapping of the BO, at an address of the kernel's choice */
static uint8_t *
map_bo(uint32_t handle)
{
	struct v3d_mmap_bo map = { .handle = handle };
	if (drmIoctl(sFd, IOCTL_MMAP_BO, &map) != 0) {
		SAY("setup FAIL: MMAP_BO: %s", strerror(errno));
		exit(1);
	}
	return (uint8_t *)(uintptr_t)map.offset;
}

/* the placed map: 0 or the error (errno, a Haiku status) */
static int
map_placed(uint32_t handle, const void *address)
{
	struct v3d_mmap_bo map = { .handle = handle, .flags = MMAP_BO_PLACED, .offset = (uintptr_t)address };
	return drmIoctl(sFd, IOCTL_MMAP_BO, &map) == 0 ? 0 : errno;
}

static bool
area_at(const void *address, area_info *info)
{
	area_id area = area_for((void *)address);
	return area >= 0 && get_area_info(area, info) == B_OK;
}

static uint8_t *
find_team_area(const char *name, size_t *size)
{
	ssize_t cookie = 0;
	area_info info;
	while (get_next_area_info(B_CURRENT_TEAM, &cookie, &info) == B_OK) {
		if (strcmp(info.name, name) == 0) {
			*size = info.size;
			return info.address;
		}
	}
	return NULL;
}

static uint8_t *
reserve(size_t size)
{
	void *p = mmap(NULL, size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
	if (p == MAP_FAILED) {
		SAY("setup FAIL: reserve %zu: %s", size, strerror(errno));
		exit(1);
	}
	return p;
}

static uint8_t *
commit(uint8_t *at, size_t size, uint8_t fill)
{
	if (mmap(at, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0) != at) {
		SAY("setup FAIL: commit %p: %s", (void *)at, strerror(errno));
		exit(1);
	}
	memset(at, fill, size);
	return at;
}

static bool
all_bytes(const uint8_t *p, size_t size, uint8_t value)
{
	for (size_t i = 0; i < size; i++) {
		if (p[i] != value)
			return false;
	}
	return true;
}

static void
case_a(void)
{
	uint32_t bo = create_bo(PAGE);
	uint8_t *range = commit(reserve(4 * PAGE), 2 * PAGE, 0x11);
	int error = map_placed(bo, range + 16);
	area_info info;
	bool untouched = area_at(range, &info) && strstr(info.name, "v3d bo map") == NULL
		&& all_bytes(range, 2 * PAGE, 0x11);
	RESULT("a", error != 0 && untouched, "unaligned %p refused (%s), memory untouched: %s", (void *)(range + 16),
		error ? strerror(error) : "accepted!", untouched ? "yes" : "NO");
	error = map_placed(bo, range + PAGE / 2);
	RESULT("a", error != 0, "half-page offset refused (%s)", error ? strerror(error) : "accepted!");
	close_bo(bo);
}

/* in a child team: placing a BO over a kernel-protected area of its own; exit status 0 = refused */
static void
case_b_one(const char *name)
{
	size_t size = 0;
	uint8_t *area = find_team_area(name, &size);
	if (area == NULL) {
		SAY("b FAIL: no area \"%s\" in the team", name);
		sProblems++;
		return;
	}
	fflush(stdout);
	pid_t child = fork();
	if (child == 0) {
		uint32_t bo = create_bo(PAGE);
		/* the child team's own area of that name */
		area = find_team_area(name, &size);
		if (area == NULL) {
			printf("CPREF b   child: no \"%s\"\n", name);
			_exit(2);
		}
		int error = map_placed(bo, area);
		area_info info;
		bool kept = area_at(area, &info) && strcmp(info.name, name) == 0;
		printf("CPREF b   child: \"%s\" at %p: %s, still \"%s\": %s\n", name, (void *)area,
			error ? strerror(error) : "accepted!", name, kept ? "yes" : "NO");
		fflush(stdout);
		_exit(error == B_NOT_ALLOWED && kept ? 0 : 1);
	}
	int status = 0;
	waitpid(child, &status, 0);
	RESULT("b", WIFEXITED(status) && WEXITSTATUS(status) == 0,
		"kernel-protected \"%s\" (%p, %zu bytes) not replaceable (child %s %d)", name, (void *)area, size,
		WIFEXITED(status) ? "exit" : "signal", WIFEXITED(status) ? WEXITSTATUS(status) : WTERMSIG(status));
}

static void
case_b(void)
{
	case_b_one("commpage");
	case_b_one("user area");
	uint32_t bo = create_bo(PAGE);
	int error = map_placed(bo, (void *)(uintptr_t)0xffff000000100000ull);
	RESULT("b", error != 0, "kernel address refused (%s)", error ? strerror(error) : "accepted!");
	close_bo(bo);
}

static void
case_c(void)
{
	/* mlock: wired only during the call */
	uint32_t bo = create_bo(PAGE);
	uint8_t *range = commit(reserve(2 * PAGE), PAGE, 0x22);
	int locked = mlock(range, PAGE);
	int error = map_placed(bo, range);
	area_info info;
	bool placed = area_at(range, &info) && strstr(info.name, "v3d bo map") != NULL;
	RESULT("c", error == 0 && placed, "after mlock() (%s): placed (%s; mlock keeps nothing wired, so the B_BUSY "
		"refusal is unreachable from userland)", locked == 0 ? "ok" : strerror(errno),
		error ? strerror(error) : "ok");
	close_bo(bo);

	/* memory imported as a BO: wired in the kernel's clone of the area */
	uint8_t *imported = commit(reserve(2 * PAGE), PAGE, 0x33);
	struct v3d_import_memory import = { .address = (uintptr_t)imported, .size = PAGE };
	if (drmIoctl(sFd, IOCTL_IMPORT_MEMORY, &import) != 0) {
		SAY("c FAIL: IMPORT_MEMORY: %s", strerror(errno));
		sProblems++;
		return;
	}
	bo = create_bo(PAGE);
	uint8_t *plain = map_bo(bo);
	memset(plain, 0x44, PAGE);
	error = map_placed(bo, imported);
	placed = area_at(imported, &info) && strstr(info.name, "v3d bo map") != NULL;
	bool bosData = placed && all_bytes(imported, PAGE, 0x44);
	close_bo(import.handle);
	bool still = area_at(imported, &info) && strstr(info.name, "v3d bo map") != NULL
		&& all_bytes(imported, PAGE, 0x44);
	RESULT("c", error == 0 && bosData && still, "over memory imported as a BO: placed (%s), the BO's data there: "
		"%s, after closing the import: %s", error ? strerror(error) : "ok", bosData ? "yes" : "NO",
		still ? "unchanged" : "CHANGED");
	munmap(plain, PAGE);
	close_bo(bo);
}

static void
case_d(void)
{
	uint32_t bo = create_bo(2 * PAGE);
	uint8_t *own = map_bo(bo);
	memset(own, 0x55, 2 * PAGE);
	int error = map_placed(bo, own);
	area_info info;
	int32 areas = 0;
	ssize_t cookie = 0;
	area_info each;
	while (get_next_area_info(B_CURRENT_TEAM, &cookie, &each) == B_OK) {
		if ((uint8_t *)each.address <= own && own < (uint8_t *)each.address + each.size)
			areas++;
	}
	bool same = error == 0 && area_at(own, &info) && strstr(info.name, "v3d bo map") != NULL
		&& info.size == 2 * PAGE && all_bytes(own, 2 * PAGE, 0x55) && areas == 1;
	RESULT("d", same, "over its own mapping %p: %s; one mapping of the same BO there, its data intact: %s",
		(void *)own, error ? strerror(error) : "replaced in place", same ? "yes" : "NO");
	munmap(own, 2 * PAGE);
	close_bo(bo);
}

static void
case_e(void)
{
	const size_t size = 4 * PAGE;
	uint8_t *reservation = reserve(16 * PAGE);
	uint8_t *range = reservation + 4 * PAGE;
	uint32_t bo = create_bo(size);
	uint8_t *plain = map_bo(bo);
	for (size_t i = 0; i < size; i++)
		plain[i] = (uint8_t)(i * 7);

	int error = map_placed(bo, range);
	area_info info;
	bool placed = error == 0 && area_at(range, &info) && strstr(info.name, "v3d bo map") != NULL
		&& info.address == range && info.size == size;
	bool data = placed && memcmp(range, plain, size) == 0;
	if (placed)
		range[100] = 0xee;
	bool shared = placed && plain[100] == 0xee;
	RESULT("e", placed && data && shared, "over a PROT_NONE reservation: %s; the BO's data there: %s, writes "
		"reach the BO: %s", error ? strerror(error) : "placed", data ? "yes" : "NO", shared ? "yes" : "NO");

	/* unmap with "reserve": the range stays taken */
	void *again = mmap(range, size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED | MAP_NORESERVE, -1, 0);
	bool reserved = again == range && area_at(range, &info) && strstr(info.name, "v3d bo map") == NULL
		&& (info.protection & (B_READ_AREA | B_WRITE_AREA)) == 0;
	area_info before, after;
	bool rest = area_at(reservation, &before) && area_at(reservation + 15 * PAGE, &after)
		&& (before.protection & (B_READ_AREA | B_WRITE_AREA)) == 0
		&& (after.protection & (B_READ_AREA | B_WRITE_AREA)) == 0;
	/* nobody else may get it: a mapping asked for exactly there lands elsewhere */
	void *probe = mmap(range, PAGE, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	bool notFree = probe != MAP_FAILED && probe != range;
	if (probe != MAP_FAILED)
		munmap(probe, PAGE);
	RESULT("e", reserved && rest && notFree, "after the reserving unmap: range reserved (%s), not free (%s), the "
		"rest of the reservation as before (%s)", reserved ? "yes" : "NO", notFree ? "yes" : "NO",
		rest ? "yes" : "NO");
	RESULT("e", plain[100] == 0xee, "the BO keeps its data after the placed mapping went");
	munmap(plain, size);
	close_bo(bo);
}

int
main(void)
{
	sFd = open("/dev/dri/renderD128", O_RDWR);
	if (sFd < 0) {
		SAY("setup FAIL: /dev/dri/renderD128: %s", strerror(errno));
		SAY("result: 1 problems");
		return 1;
	}
	struct v3d_get_param param = { .param = PARAM_MMAP_BO_PLACED };
	if (drmIoctl(sFd, IOCTL_GET_PARAM, &param) != 0 || param.value != 1) {
		SAY("param FAIL: the kernel has no placed maps (DRM_V3D_PARAM_HAIKU_MMAP_BO_PLACED)");
		SAY("result: 1 problems");
		return 1;
	}
	SAY("param ok: placed maps supported");

	case_a();
	case_b();
	case_c();
	case_d();
	case_e();

	SAY("result: %d problems", sProblems);
	return sProblems == 0 ? 0 : 1;
}
