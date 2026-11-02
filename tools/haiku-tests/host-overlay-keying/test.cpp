/*
 * The keyed front-buffer row copy of app_server (src/servers/app/drawing/OverlayKeying.cpp) on the
 * host: every output pixel of write_keyed_row() against a straightforward reference, for random rows,
 * rectangles (none, one, several, overlapping, partly outside the row) and pixels (key color with
 * any alpha, X = 0 as client bitmaps have, random). docs/design/gpu-stage6.md §3.3.
 */
#include "OverlayKeying.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint32 sKey = 0x005000;

static uint32
reference(uint32 pixel, int32 x, int32 y, const overlay_key_rect* keys, int32 count)
{
	for (int32 i = 0; i < count; i++) {
		const overlay_key_rect& r = keys[i];
		if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom)
			return (pixel & 0xffffff) == (r.key & 0xffffff) ? 0 : pixel | 0xff000000;
	}
	return pixel | 0xff000000;
}

int
main()
{
	srand(1);
	const int32 width = 300;
	uint32 source[width], destination[width + 2];
	long checked = 0, failures = 0;
	for (int round = 0; round < 200000; round++) {
		for (int32 i = 0; i < width; i++) {
			const int kind = rand() % 4;
			source[i] = kind == 0 ? (sKey | ((uint32)(rand() & 0xff) << 24))
				: kind == 1 ? ((uint32)rand() & 0xffffff) : (uint32)rand() * 2654435761u;
		}
		overlay_key_rect keys[6];
		const int32 count = rand() % 7;
		for (int32 i = 0; i < count; i++) {
			int32 a = rand() % (width + 40) - 20, b = rand() % (width + 40) - 20;
			if (a > b) { int32 t = a; a = b; b = t; }
			keys[i] = { a, rand() % 8, b, rand() % 8 + 8, sKey };
		}
		const int32 x = rand() % width;
		const int32 n = 1 + rand() % (width - x);
		const int32 y = rand() % 16;
		destination[n] = 0xdeadbeef;
		write_keyed_row(destination, source + x, x, y, n, keys, count);
		if (destination[n] != 0xdeadbeef) {
			printf("KEY overrun round %d\n", round);
			failures++;
		}
		for (int32 i = 0; i < n; i++) {
			// overlapping rectangles: the leftmost-starting one keys the overlap in
			// write_keyed_row(); with one key color, any order gives the same pixel
			const uint32 want = reference(source[x + i], x + i, y, keys, count);
			checked++;
			if (destination[i] != want && failures++ < 10) {
				printf("KEY mismatch round %d x %d y %d: %08x -> %08x, want %08x\n", round,
					x + i, y, source[x + i], destination[i], want);
			}
		}
	}
	// the unkeyed copy of a whole row
	for (int32 i = 0; i < width; i++)
		source[i] = i * 0x01020304u;
	copy_row_opaque(destination, source, width);
	for (int32 i = 0; i < width; i++) {
		if (destination[i] != (source[i] | 0xff000000))
			failures++;
	}
	printf("KEY %ld pixels checked, %ld failures: %s\n", checked, failures,
		failures == 0 ? "PASS" : "FAIL");
	return failures == 0 ? 0 : 1;
}
