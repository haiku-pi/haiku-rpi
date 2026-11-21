/*
 * screenread.cpp — read the screen back as BScreen::GetBitmap() does for the Screenshot app (app_server's
 * AS_READ_BITMAP), optionally only a rectangle of it, into a binary PPM, and say how long it took. For the
 * overlay read-back (docs/design/gpu-stage6.md §11): a screenshot shows what overlays show.
 *
 *   screenread [-p X Y] [-c] [-r X Y W H] [OUT.ppm]
 *       -p: first put the mouse pointer at X,Y (out of the way: the HDMI snapshot shows it, a screenshot
 *       without -c not); -c: with the mouse pointer; -r: only that rectangle; without OUT.ppm only -p
 *
 * Prints "SCR WxH at X,Y: N ms".
 *
 * Build (cross):
 *   g=sources/haiku/generated.arm64
 *   $g/cross-tools-arm64/bin/aarch64-unknown-haiku-g++ --sysroot=artifacts/sysroot-arm64 -O2 \
 *     -o screenread tools/haiku-tests/screenread.cpp -lbe -lgame
 */
#include <Application.h>
#include <Bitmap.h>
#include <Screen.h>
#include <WindowScreen.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>


int
main(int argc, char** argv)
{
	bool cursor = false;
	bool part = false;
	BRect rect;
	int i = 1;
	bool pointer = false;
	int32 pointerX = 0, pointerY = 0;
	for (; i < argc; i++) {
		if (strcmp(argv[i], "-p") == 0 && i + 2 < argc) {
			pointer = true;
			pointerX = atoi(argv[i + 1]);
			pointerY = atoi(argv[i + 2]);
			i += 2;
		} else if (strcmp(argv[i], "-c") == 0)
			cursor = true;
		else if (strcmp(argv[i], "-r") == 0 && i + 4 < argc) {
			const float x = atof(argv[i + 1]), y = atof(argv[i + 2]);
			rect.Set(x, y, x + atof(argv[i + 3]) - 1, y + atof(argv[i + 4]) - 1);
			part = true;
			i += 4;
		} else
			break;
	}
	if (i < argc - 1 || (i == argc && !pointer)) {
		fprintf(stderr, "usage: screenread [-p X Y] [-c] [-r X Y W H] [OUT.ppm]\n");
		return 2;
	}

	BApplication app("application/x-vnd.haiku-rpi-screenread");
	if (pointer) {
		set_mouse_position(pointerX, pointerY);
		if (i == argc)
			return 0;
		snooze(100000);
	}
	BScreen screen;
	if (!part)
		rect = screen.Frame();
	BBitmap* bitmap = NULL;
	const bigtime_t start = system_time();
	status_t status = screen.GetBitmap(&bitmap, cursor, &rect);
	const bigtime_t took = system_time() - start;
	if (status != B_OK || bitmap == NULL) {
		fprintf(stderr, "screenread: GetBitmap: %s\n", strerror(status));
		return 1;
	}

	const int32 width = bitmap->Bounds().IntegerWidth() + 1;
	const int32 height = bitmap->Bounds().IntegerHeight() + 1;
	if (bitmap->ColorSpace() != B_RGB32 && bitmap->ColorSpace() != B_RGBA32) {
		fprintf(stderr, "screenread: color space %#x, not B_RGB32\n", bitmap->ColorSpace());
		return 1;
	}
	FILE* file = fopen(argv[argc - 1], "wb");
	if (file == NULL) {
		perror(argv[argc - 1]);
		return 1;
	}
	fprintf(file, "P6\n%d %d\n255\n", (int)width, (int)height);
	uint8* row = new uint8[width * 3];
	for (int32 y = 0; y < height; y++) {
		const uint8* bits = (const uint8*)bitmap->Bits() + y * bitmap->BytesPerRow();
		for (int32 x = 0; x < width; x++) {
			row[x * 3] = bits[x * 4 + 2];
			row[x * 3 + 1] = bits[x * 4 + 1];
			row[x * 3 + 2] = bits[x * 4];
		}
		fwrite(row, 3, width, file);
	}
	fclose(file);
	delete[] row;
	printf("SCR %dx%d at %d,%d: %.1f ms\n", (int)width, (int)height, (int)rect.left, (int)rect.top,
		took / 1000.0);
	delete bitmap;
	return 0;
}
