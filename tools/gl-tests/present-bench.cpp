/*
 * present-bench — what each step of presenting a GL frame costs on this machine
 * (docs/design/gpu-present.md): the CPU copies app_server makes of a window's bitmap, the cache
 * maintenance of a bitmap the GPU writes (the v3d driver's SYNC_BO), and app_server's whole
 * DrawBitmap() of a frame. "PRB " lines, one per measurement, in ms per frame of the given size and
 * the bandwidth.
 *
 *   present-bench [-W width] [-H height] [-n reps] [-s steps]
 *
 * steps (default all): c = CPU copies (RAM->RAM, RAM->write-combining, WC->RAM, one fused pass to
 * both), s = SYNC_BO on an imported BBitmap (lines absent, clean, dirty; needs /dev/dri/renderD128),
 * d = DrawBitmap()+Sync() of a frame-sized bitmap in a borderless window at the screen's top left.
 */

#include <Application.h>
#include <Bitmap.h>
#include <Screen.h>
#include <View.h>
#include <Window.h>

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <xf86drm.h>


// the v3d driver's ioctls (Mesa's drm-uapi/v3d_drm.h, Haiku's private v3d_drm.h)
struct v3d_create_bo {
	uint32_t size;
	uint32_t flags;
	uint32_t handle;
	uint32_t offset;
};

struct v3d_mmap_bo {
	uint32_t handle;
	uint32_t flags;
	uint64_t offset;
		// on Haiku: the address of the BO's (write-combining) mapping
};

struct v3d_import_memory {
	uint64_t address;
	uint64_t size;
	uint32_t handle;
	uint32_t offset;
};

struct v3d_sync_bo {
	uint32_t handle;
	uint32_t pad;
};

#define V3D_CREATE_BO		DRM_IOWR(DRM_COMMAND_BASE + 0x02, struct v3d_create_bo)
#define V3D_MMAP_BO			DRM_IOWR(DRM_COMMAND_BASE + 0x03, struct v3d_mmap_bo)
#define V3D_IMPORT_MEMORY	DRM_IOWR(DRM_COMMAND_BASE + 0x30, struct v3d_import_memory)
#define V3D_SYNC_BO			DRM_IOWR(DRM_COMMAND_BASE + 0x31, struct v3d_sync_bo)


static uint32_t sWidth = 1920;
static uint32_t sHeight = 1080;
static int sReps = 20;


static void
report(const char* what, bigtime_t total, int reps, size_t bytes)
{
	const double ms = total / 1000.0 / reps;
	printf("PRB %ux%u %-34s %7.2f ms/frame %7.0f MB/s\n", sWidth, sHeight, what, ms,
		bytes / (ms * 1000.0));
	fflush(stdout);
}


/*!	Copies rows of width * 4 bytes, as app_server's Painter and HWInterface
	do (memcpy per row).
*/
static void
copy_rows(uint8_t* dst, const uint8_t* src, uint32_t stride)
{
	for (uint32_t y = 0; y < sHeight; y++)
		memcpy(dst + y * stride, src + y * stride, sWidth * 4);
}


static void
copy_rows_fused(uint8_t* back, uint8_t* front, const uint8_t* src, uint32_t stride)
{
	for (uint32_t y = 0; y < sHeight; y++) {
		memcpy(back + y * stride, src + y * stride, sWidth * 4);
		memcpy(front + y * stride, src + y * stride, sWidth * 4);
	}
}


static int
open_gpu()
{
	int fd = open("/dev/dri/renderD128", O_RDWR | O_CLOEXEC);
	if (fd < 0)
		printf("PRB no /dev/dri/renderD128\n");
	return fd;
}


static void
bench_copies()
{
	const uint32_t stride = sWidth * 4;
	const size_t size = (size_t)stride * sHeight;
	uint8_t* a = (uint8_t*)malloc(size);
	uint8_t* b = (uint8_t*)malloc(size);
	memset(a, 0x5a, size);
	memset(b, 0xa5, size);

	copy_rows(b, a, stride);
	bigtime_t start = system_time();
	for (int i = 0; i < sReps; i++)
		copy_rows(i & 1 ? a : b, i & 1 ? b : a, stride);
	report("copy RAM->RAM", system_time() - start, sReps, size);

	int fd = open_gpu();
	if (fd >= 0) {
		v3d_create_bo create = { (uint32_t)size, 0, 0, 0 };
		v3d_mmap_bo map = {};
		if (drmIoctl(fd, V3D_CREATE_BO, &create) == 0) {
			map.handle = create.handle;
			if (drmIoctl(fd, V3D_MMAP_BO, &map) != 0)
				map.offset = 0;
		}
		uint8_t* wc = (uint8_t*)(addr_t)map.offset;
		if (wc == NULL) {
			printf("PRB no write-combining buffer (v3d CREATE_BO/MMAP_BO)\n");
		} else {
			copy_rows(wc, a, stride);
			start = system_time();
			for (int i = 0; i < sReps; i++)
				copy_rows(wc, i & 1 ? a : b, stride);
			report("copy RAM->WC (app_server to screen)", system_time() - start, sReps,
				size);

			start = system_time();
			for (int i = 0; i < sReps; i++)
				copy_rows_fused(b, wc, a, stride);
			report("fused RAM->RAM+WC (one source read)", system_time() - start, sReps,
				size);

			const int readReps = sReps > 4 ? 4 : sReps;
			start = system_time();
			for (int i = 0; i < readReps; i++)
				copy_rows(b, wc, stride);
			report("copy WC->RAM (CPU readback)", system_time() - start, readReps, size);
		}
		close(fd);
			// the BO goes with the file
	}
	free(a);
	free(b);
}


static void
bench_sync()
{
	int fd = open_gpu();
	if (fd < 0)
		return;

	// a bitmap as Mesa's EGL driver presents with: B_RGB32, the window's size
	BBitmap bitmap(BRect(0, 0, sWidth - 1, sHeight - 1), B_RGB32);
	const size_t size = (size_t)bitmap.BytesPerRow() * sHeight;
	v3d_import_memory import = { (uint64_t)(addr_t)bitmap.Bits(), size, 0, 0 };
	if (bitmap.InitCheck() != B_OK || drmIoctl(fd, V3D_IMPORT_MEMORY, &import) != 0) {
		printf("PRB cannot import a bitmap (v3d IMPORT_MEMORY)\n");
		close(fd);
		return;
	}
	v3d_sync_bo sync = { import.handle, 0 };
	uint8_t* bits = (uint8_t*)bitmap.Bits();
	volatile uint64_t sum = 0;

	drmIoctl(fd, V3D_SYNC_BO, &sync);
	bigtime_t total = 0;
	for (int i = 0; i < sReps; i++) {
		const bigtime_t start = system_time();
		drmIoctl(fd, V3D_SYNC_BO, &sync);
		total += system_time() - start;
	}
	report("SYNC_BO, lines not cached", total, sReps, size);

	total = 0;
	for (int i = 0; i < sReps; i++) {
		// app_server's read of the frame leaves clean lines (the last ~1 MB)
		for (size_t offset = 0; offset < size; offset += 64)
			sum += bits[offset];
		const bigtime_t start = system_time();
		drmIoctl(fd, V3D_SYNC_BO, &sync);
		total += system_time() - start;
	}
	report("SYNC_BO after a CPU read", total, sReps, size);

	total = 0;
	for (int i = 0; i < sReps; i++) {
		memset(bits, i, size);
		const bigtime_t start = system_time();
		drmIoctl(fd, V3D_SYNC_BO, &sync);
		total += system_time() - start;
	}
	report("SYNC_BO after a CPU write (dirty)", total, sReps, size);

	close(fd);
		// the import goes with the file, before the bitmap
}


class BenchView : public BView {
public:
	BenchView(BRect frame)
		:
		BView(frame, "bench", B_FOLLOW_ALL, 0)
	{
		SetViewColor(B_TRANSPARENT_COLOR);
	}
};


static void
bench_draw()
{
	BRect screen = BScreen().Frame();
	BRect frame(0, 0, sWidth - 1, sHeight - 1);
	if (frame.Width() > screen.Width() || frame.Height() > screen.Height()) {
		printf("PRB %ux%u is larger than the screen (%.0fx%.0f)\n", sWidth, sHeight,
			screen.Width() + 1, screen.Height() + 1);
		return;
	}

	BBitmap bitmap(frame, B_RGB32);
	uint32_t* bits = (uint32_t*)bitmap.Bits();
	for (uint32_t y = 0; y < sHeight; y++) {
		for (uint32_t x = 0; x < sWidth; x++)
			bits[y * bitmap.BytesPerRow() / 4 + x] = 0xff000000 | (x * 255 / sWidth) << 16
				| (y * 255 / sHeight) << 8;
	}

	BWindow* window = new BWindow(frame, "present-bench", B_NO_BORDER_WINDOW_LOOK,
		B_FLOATING_ALL_WINDOW_FEEL, B_NOT_MOVABLE | B_NOT_RESIZABLE | B_AVOID_FOCUS);
	BenchView* view = new BenchView(frame.OffsetToCopy(B_ORIGIN));
	window->AddChild(view);
	window->Show();
	snooze(500000);

	const size_t size = (size_t)sWidth * 4 * sHeight;
	const int reps = sReps * 3;
	window->Lock();
	view->SetDrawingMode(B_OP_COPY);
	view->DrawBitmap(&bitmap, B_ORIGIN);
	view->Sync();
	bigtime_t start = system_time();
	for (int i = 0; i < reps; i++) {
		view->DrawBitmap(&bitmap, B_ORIGIN);
		view->Sync();
	}
	window->Unlock();
	report("app_server DrawBitmap+Sync", system_time() - start, reps, size);

	window->Lock();
	window->Quit();
}


int
main(int argc, char** argv)
{
	const char* steps = "csd";
	int opt;
	while ((opt = getopt(argc, argv, "W:H:n:s:")) != -1) {
		switch (opt) {
			case 'W':
				sWidth = atoi(optarg);
				break;
			case 'H':
				sHeight = atoi(optarg);
				break;
			case 'n':
				sReps = atoi(optarg);
				break;
			case 's':
				steps = optarg;
				break;
			default:
				fprintf(stderr, "usage: %s [-W width] [-H height] [-n reps] [-s csd]\n",
					argv[0]);
				return 2;
		}
	}
	if (sWidth == 0 || sHeight == 0 || sReps <= 0)
		return 2;

	BApplication app("application/x-vnd.haiku-rpi-present-bench");
	if (strchr(steps, 'c') != NULL)
		bench_copies();
	if (strchr(steps, 's') != NULL)
		bench_sync();
	if (strchr(steps, 'd') != NULL)
		bench_draw();
	printf("PRB done\n");
	return 0;
}
