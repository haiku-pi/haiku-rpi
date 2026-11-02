/*
 * sandprobe.cpp — can the Raspberry Pi's firmware scan out the HEVC decoder's SAND128 NV12 pictures
 * on a plane (docs/design/gpu-stage6.md §5)? Talks to the display driver directly (no app_server):
 * a buffer from it, filled with color bars in SAND128 (columns of 128 bytes), shown on plane 6 at
 * the top left, half the screen, 5 s per layout:
 *   L1 NV12_COL128 as DRM has it: one column height C = H16 * 3/2 lines, the chroma after the luma in
 *      each column (pitch = C, chroma at H16 * 128) — what Linux sends; expected to work;
 *   L2 our rpivid driver's layout: luma columns of H16 lines, chroma in a plane of its own with
 *      columns of H16/2 lines (pitch = H16, vpitch = the height);
 *   L3 as L2 with vpitch = H16/2 (is vpitch the chroma's column height?).
 * Grade the HDMI capture: bars in order (white, yellow, cyan, green, magenta, red, blue, black).
 * Run it with overlays above the desktop (driver setting overlay_above_desktop: image C): keyed
 * overlays lie under the desktop, and no app_server keys this one. Prints "SND " lines.
 *
 * Build (cross; the driver's private header from the stage6 tree):
 *   h=sources/haiku-stage6/headers/private
 *   sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-g++ \
 *     --sysroot=artifacts/sysroot-arm64 -O2 -I$h/graphics/bcm2711_display -I$h/graphics/common \
 *     -o sandprobe tools/haiku-tests/sandprobe.cpp
 */
#include <bcm2711_display.h>

#include <OS.h>

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define SAY(...) do { printf("SND " __VA_ARGS__); printf("\n"); fflush(stdout); } while (0)

static const int kWidth = 1280;
static const int kHeight = 720;
static const int kHeight16 = (kHeight + 15) & ~15;
static const int kColumns = (kWidth + 127) / 128;
static const uint8 kBars[8][3] = {
	{ 191, 191, 191 }, { 191, 191, 0 }, { 0, 191, 191 }, { 0, 191, 0 },
	{ 191, 0, 191 }, { 191, 0, 0 }, { 0, 0, 191 }, { 0, 0, 0 }
};


// BT.709, limited range (the accelerant's choice from 720 lines on)
static void
bar_ycbcr(int x, uint8& y, uint8& cb, uint8& cr)
{
	const uint8* bar = kBars[x * 8 / kWidth];
	const double r = bar[0], g = bar[1], b = bar[2];
	y = (uint8)(16 + (46.742 * r + 157.243 * g + 15.874 * b) / 256);
	cb = (uint8)(128 + (-25.765 * r - 86.674 * g + 112.439 * b) / 256);
	cr = (uint8)(128 + (112.439 * r - 102.129 * g - 10.310 * b) / 256);
}


/*!	Writes the bars: luma column stride lumaStride, chroma at chromaOffset
	with column stride chromaStride (bytes).
*/
static void
fill(uint8* base, uint32 lumaStride, uint32 chromaOffset, uint32 chromaStride)
{
	for (int y = 0; y < kHeight; y++) {
		for (int x = 0; x < kWidth; x++) {
			uint8 luma, cb, cr;
			bar_ycbcr(x, luma, cb, cr);
			base[(x / 128) * lumaStride + y * 128 + x % 128] = luma;
			if ((y & 1) == 0 && (x & 1) == 0) {
				uint8* chroma = base + chromaOffset + (x / 128) * chromaStride
					+ (y / 2) * 128 + x % 128;
				chroma[0] = cb;
				chroma[1] = cr;
			}
		}
	}
}


static bool
show(int fd, const bcm2711_display_overlay_buffer& buffer, const char* name,
	uint32 pitch, uint32 vpitch, uint32 chromaOffset)
{
	bcm2711_display_overlay request = {};
	request.plane = BCM2711_DISPLAY_FIRST_OVERLAY_PLANE + BCM2711_DISPLAY_OVERLAY_PLANES - 1;
	request.image_type = BCM2711_DISPLAY_IMAGE_YUV_UV;
	request.color_encoding = BCM2711_DISPLAY_ENCODING_BT709;
	request.physical = buffer.physical;
	request.width = kWidth;
	request.height = kHeight;
	request.bytes_per_row = pitch;
	request.chroma_offset = chromaOffset;
	request.vpitch = vpitch;
	request.source_width = kWidth << 16;
	request.source_height = kHeight << 16;
	request.x = 0;
	request.y = 0;
	request.destination_width = kWidth * 3 / 4;
	request.destination_height = kHeight * 3 / 4;
	const bool ok = ioctl(fd, BCM2711_DISPLAY_SET_OVERLAY, &request, sizeof(request)) == 0;
	SAY("%s: pitch %u vpitch %u chroma at %u: %s (HDMI now: bars at the top left?)", name,
		(unsigned)pitch, (unsigned)vpitch, (unsigned)chromaOffset, ok ? "shown" : strerror(errno));
	snooze(5000000);
	return ok;
}


int
main()
{
	int fd = open("/dev/graphics/bcm2711_display", O_RDWR);
	if (fd < 0) {
		SAY("no display driver: %s", strerror(errno));
		return 1;
	}

	const uint32 columnHeight = kHeight16 * 3 / 2;
	const uint32 lumaSize = kColumns * 128 * kHeight16;
	const uint32 chromaOffset = (lumaSize + B_PAGE_SIZE - 1) & ~(B_PAGE_SIZE - 1);
	bcm2711_display_overlay_buffer buffer = {};
	buffer.size = kColumns * 128 * columnHeight + B_PAGE_SIZE;
	if (ioctl(fd, BCM2711_DISPLAY_ALLOCATE_OVERLAY_BUFFER, &buffer, sizeof(buffer)) != 0) {
		SAY("no overlay buffer: %s", strerror(errno));
		return 1;
	}
	uint8* base = (uint8*)buffer.address;
	SAY("buffer %u bytes at %#x, %dx%d in %d columns", (unsigned)buffer.size,
		(unsigned)buffer.physical, kWidth, kHeight, kColumns);

	int shown = 0;
	memset(base, 0, buffer.size);
	fill(base, columnHeight * 128, kHeight16 * 128, columnHeight * 128);
	shown += show(fd, buffer, "L1 NV12_COL128", columnHeight, 0, kHeight16 * 128);

	memset(base, 0, buffer.size);
	fill(base, kHeight16 * 128, chromaOffset, kHeight16 / 2 * 128);
	shown += show(fd, buffer, "L2 rpivid", kHeight16, 0, chromaOffset);
	shown += show(fd, buffer, "L3 rpivid, vpitch = chroma", kHeight16, kHeight16 / 2,
		chromaOffset);

	uint32 plane = BCM2711_DISPLAY_FIRST_OVERLAY_PLANE + BCM2711_DISPLAY_OVERLAY_PLANES - 1;
	ioctl(fd, BCM2711_DISPLAY_HIDE_OVERLAY, &plane, sizeof(plane));
	ioctl(fd, BCM2711_DISPLAY_FREE_OVERLAY_BUFFER, &buffer.area, sizeof(buffer.area));
	close(fd);
	SAY("end: %d of 3 layouts accepted by the firmware call (grade the pictures on HDMI)", shown);
	return 0;
}
