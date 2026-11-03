/*
 * present-bench's copies of app_server's front buffer row writers for overlays keyed by alpha
 * (src/servers/app/drawing/OverlayKeying.cpp, docs/design/gpu-stage6.md §3.3), in a file of their
 * own: meson builds it with app_server's -O2 (present-bench itself is -O3, which turned the old loop
 * into a 64-byte one: not what app_server ran). Check the loops with objdump against app_server's
 * OverlayKeying.o after a change.
 */

#include <stdint.h>
#include <string.h>

#include "present-bench-keying.h"


static const uint32_t kAlpha = 0xff000000;


/*!	copy_row_opaque() of stage6-rpi4b (0c7a4d1256): GCC makes one 16-byte vector per iteration. */
void
copy_row_opaque_16(uint32_t* destination, const uint32_t* source, int32_t count)
{
	int32_t i = 0;
	for (; i + 4 <= count; i += 4) {
		const uint32_t a = source[i];
		const uint32_t b = source[i + 1];
		const uint32_t c = source[i + 2];
		const uint32_t d = source[i + 3];
		destination[i] = a | kAlpha;
		destination[i + 1] = b | kAlpha;
		destination[i + 2] = c | kAlpha;
		destination[i + 3] = d | kAlpha;
	}
	for (; i < count; i++)
		destination[i] = source[i] | kAlpha;
}


/*!	copy_row_opaque() of stage6-keying: 64 bytes per iteration (ldp/stp of q registers), as memcpy. */
void
copy_row_opaque_64(uint32_t* destination, const uint32_t* source, int32_t count)
{
	typedef uint32_t pixels __attribute__((vector_size(16)));

	int32_t i = 0;
	for (; i + 16 <= count; i += 16) {
		pixels a, b, c, d;
		memcpy(&a, source + i, sizeof(a));
		memcpy(&b, source + i + 4, sizeof(b));
		memcpy(&c, source + i + 8, sizeof(c));
		memcpy(&d, source + i + 12, sizeof(d));
		a |= kAlpha;
		b |= kAlpha;
		c |= kAlpha;
		d |= kAlpha;
		memcpy(destination + i, &a, sizeof(a));
		memcpy(destination + i + 4, &b, sizeof(b));
		memcpy(destination + i + 8, &c, sizeof(c));
		memcpy(destination + i + 12, &d, sizeof(d));
	}
	for (; i < count; i++)
		destination[i] = source[i] | kAlpha;
}
