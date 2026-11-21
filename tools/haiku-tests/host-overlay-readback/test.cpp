/*
 * app_server's overlay read-back (src/servers/app/drawing/OverlayReadBack.cpp) on the host: what a
 * screenshot shows where an overlay is (docs/design/gpu-stage6.md §11).
 *
 * 1. Layout and geometry: random pictures in every color space the read-back knows (B_RGB32, B_RGB16,
 *    B_RGB15, B_YCbCr422, B_YUV420, B_YUV420_SAND128 and _10, the SAND ones also with taller columns, as an
 *    imported decoder picture has), packed here from sample planes by the layouts' definitions
 *    (GraphicsDefs.h), random views, windows (partly outside, offsets, mirrored, scaled up and down), read-back
 *    rectangles and keys (by alpha, by color, none): every pixel against a reference computed from the planes.
 * 2. Colors: 75 % bars and a gray ramp encoded in BT.601/709/2020, limited and full range, 8 and 10 bit,
 *    must come back as the RGB they were made from (within 1).
 */
#include "OverlayReadBack.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <vector>


struct Picture {
	int32 width, height;
	bool rgb;
	int32 bits;
	int32 shiftX, shiftY;	// of the chroma planes
	std::vector<int32> planes[3];

	int32 PlaneWidth(int i) const { return i == 0 ? width : (width + (1 << shiftX) - 1) >> shiftX; }
	int32 PlaneHeight(int i) const { return i == 0 ? height : (height + (1 << shiftY) - 1) >> shiftY; }
	int32 At(int i, int32 x, int32 y) const { return planes[i][(size_t)y * PlaneWidth(i) + x]; }
};


static int32
random_int(int32 from, int32 to)
{
	return from + rand() % (to - from + 1);
}


static int32
expand5(int32 v)
{
	return (v << 3) | (v >> 2);
}


static int32
expand6(int32 v)
{
	return (v << 2) | (v >> 4);
}


/*!	A random picture for \a space; RGB16/15 samples are what their 5/6 bit values expand to. */
static Picture
random_picture(color_space space, int32 width, int32 height)
{
	Picture p;
	p.width = width;
	p.height = height;
	p.rgb = space == B_RGB32 || space == B_RGBA32 || space == B_RGB16 || space == B_RGB15;
	p.bits = space == B_YUV420_SAND128_10 ? 10 : 8;
	p.shiftX = p.rgb ? 0 : 1;
	p.shiftY = space == B_YUV420 || space == B_YUV420_SAND128 || space == B_YUV420_SAND128_10 ? 1 : 0;
	for (int i = 0; i < 3; i++) {
		p.planes[i].resize((size_t)p.PlaneWidth(i) * p.PlaneHeight(i));
		for (int32& v : p.planes[i]) {
			if (space == B_RGB16)
				v = i == 1 ? expand6(rand() & 63) : expand5(rand() & 31);
			else if (space == B_RGB15)
				v = expand5(rand() & 31);
			else
				v = rand() & ((1 << p.bits) - 1);
		}
	}
	return p;
}


static uint32
sample10(const Picture& p, int plane, int32 index, int32 y)
{
	// the index-th sample of a SAND 10 bit row: luma, or Cb and Cr alternating
	if (plane == 0)
		return p.At(0, index, y);
	return p.At(index & 1 ? 2 : 1, index / 2, y);
}


/*!	Packs \a p into a buffer of \a space as GraphicsDefs.h and the accelerants define it;
	\a extraRows: SAND columns that many rows taller than needed.
*/
static std::vector<uint8>
pack(color_space space, const Picture& p, int32 extraRows, overlay_buffer& buffer)
{
	std::vector<uint8> bytes;
	const int32 w = p.width, h = p.height;
	buffer.space = space;
	buffer.width = w;
	buffer.height = h;
	switch (space) {
		case B_RGB32:
		case B_RGBA32:
		{
			const int32 bpr = w * 4 + 4 * random_int(0, 16);
			bytes.resize((size_t)bpr * h);
			for (int32 y = 0; y < h; y++) {
				for (int32 x = 0; x < w; x++) {
					uint8* d = &bytes[(size_t)y * bpr + x * 4];
					d[0] = p.At(2, x, y);
					d[1] = p.At(1, x, y);
					d[2] = p.At(0, x, y);
					d[3] = rand();
				}
			}
			buffer.bytes_per_row = bpr;
			break;
		}
		case B_RGB16:
		case B_RGB15:
		{
			const int32 bpr = w * 2 + 2 * random_int(0, 16);
			bytes.resize((size_t)bpr * h);
			for (int32 y = 0; y < h; y++) {
				for (int32 x = 0; x < w; x++) {
					uint32 v;
					if (space == B_RGB16)
						v = (p.At(0, x, y) >> 3) << 11 | (p.At(1, x, y) >> 2) << 5 | p.At(2, x, y) >> 3;
					else {
						v = (p.At(0, x, y) >> 3) << 10 | (p.At(1, x, y) >> 3) << 5 | p.At(2, x, y) >> 3
							| (rand() & 1) << 15;
					}
					bytes[(size_t)y * bpr + x * 2] = v & 0xff;
					bytes[(size_t)y * bpr + x * 2 + 1] = v >> 8;
				}
			}
			buffer.bytes_per_row = bpr;
			break;
		}
		case B_YCbCr422:
		{
			const int32 bpr = w * 2 + 2 * random_int(0, 16);
			bytes.resize((size_t)bpr * h);
			for (int32 y = 0; y < h; y++) {
				for (int32 x = 0; x < w; x += 2) {
					uint8* d = &bytes[(size_t)y * bpr + x * 2];
					d[0] = p.At(0, x, y);
					d[1] = p.At(1, x / 2, y);
					d[2] = p.At(0, x + 1, y);
					d[3] = p.At(2, x / 2, y);
				}
			}
			buffer.bytes_per_row = bpr;
			break;
		}
		case B_YUV420:
		{
			const int32 pitch = (w + 63) & ~63;
			bytes.resize((size_t)pitch * h * 3 / 2);
			for (int32 y = 0; y < h; y++)
				for (int32 x = 0; x < w; x++)
					bytes[(size_t)y * pitch + x] = p.At(0, x, y);
			for (int32 y = 0; y < h / 2; y++) {
				for (int32 x = 0; x < w / 2; x++) {
					bytes[(size_t)pitch * h + (size_t)y * (pitch / 2) + x] = p.At(1, x, y);
					bytes[(size_t)pitch * h + (size_t)(pitch / 2) * (h / 2) + (size_t)y * (pitch / 2) + x]
						= p.At(2, x, y);
				}
			}
			buffer.bytes_per_row = pitch * 3 / 2;
			break;
		}
		case B_YUV420_SAND128:
		case B_YUV420_SAND128_10:
		{
			const bool ten = space == B_YUV420_SAND128_10;
			const int32 height16 = (h + 15) & ~15;
			const int32 columnHeight = height16 * 3 / 2 + extraRows;
			const int32 perColumn = ten ? 96 : 128;
			const int32 columns = (w + perColumn - 1) / perColumn;
			const size_t stride = (size_t)columnHeight * 128;
			bytes.resize(stride * columns);
			for (uint8& b : bytes)
				b = rand();
			for (int part = 0; part < 2; part++) {
				const size_t base = part == 0 ? 0 : (size_t)height16 * 128;
				for (int32 y = 0; y < (part == 0 ? h : h / 2); y++) {
					for (int32 x = 0; x < w; x++) {
						uint8* row = &bytes[base + x / perColumn * stride + (size_t)y * 128];
						if (!ten) {
							row[x % 128] = part == 0 ? p.At(0, x, y) : p.At(x & 1 ? 2 : 1, x / 2, y);
							continue;
						}
						const int32 k = x % 96;
						uint8* word = row + k / 3 * 4;
						uint32 v = word[0] | word[1] << 8 | word[2] << 16 | (uint32)word[3] << 24;
						v &= ~(0x3ffu << (k % 3 * 10));
						v |= sample10(p, part, x, y) << (k % 3 * 10);
						word[0] = v;
						word[1] = v >> 8;
						word[2] = v >> 16;
						word[3] = v >> 24;
					}
				}
			}
			buffer.bytes_per_row = columnHeight;
			break;
		}
		default:
			abort();
	}
	buffer.buffer = bytes.data();
	buffer.buffer_dma = NULL;
	return bytes;
}


static double
plane_sample(const Picture& p, int i, double x, double y, int32 minX, int32 maxX, int32 minY, int32 maxY)
{
	x = x < minX ? minX : x > maxX ? maxX : x;
	y = y < minY ? minY : y > maxY ? maxY : y;
	const int32 x0 = (int32)floor(x), y0 = (int32)floor(y);
	const int32 x1 = x0 < maxX ? x0 + 1 : x0, y1 = y0 < maxY ? y0 + 1 : y0;
	const double fx = x - x0, fy = y - y0;
	return (1 - fy) * ((1 - fx) * p.At(i, x0, y0) + fx * p.At(i, x1, y0))
		+ fy * ((1 - fx) * p.At(i, x0, y1) + fx * p.At(i, x1, y1));
}


static void
ycbcr_to_rgb(uint32 flags, int32 height, int32 bits, const double ycc[3], double rgb[3])
{
	uint32 matrix = flags & B_OVERLAY_COLOR_MATRIX_MASK;
	if (matrix == 0)
		matrix = height >= 720 ? B_OVERLAY_COLOR_BT709 : B_OVERLAY_COLOR_BT601;
	const double kr = matrix == B_OVERLAY_COLOR_BT709 ? 0.2126 : matrix == B_OVERLAY_COLOR_BT2020 ? 0.2627 : 0.299;
	const double kb = matrix == B_OVERLAY_COLOR_BT709 ? 0.0722 : matrix == B_OVERLAY_COLOR_BT2020 ? 0.0593 : 0.114;
	const double unit = 1 << (bits - 8), maximum = (1 << bits) - 1;
	double y, cb, cr;
	if (flags & B_OVERLAY_COLOR_FULL_RANGE) {
		y = ycc[0] / maximum;
		cb = (ycc[1] - 128 * unit) / maximum;
		cr = (ycc[2] - 128 * unit) / maximum;
	} else {
		y = (ycc[0] - 16 * unit) / (219 * unit);
		cb = (ycc[1] - 128 * unit) / (224 * unit);
		cr = (ycc[2] - 128 * unit) / (224 * unit);
	}
	rgb[0] = y + 2 * (1 - kr) * cr;
	rgb[2] = y + 2 * (1 - kb) * cb;
	rgb[1] = (y - kr * rgb[0] - kb * rgb[2]) / (1 - kr - kb);
}


static uint32
to8(double v)
{
	v = v * 255 + 0.5;
	return v <= 0 ? 0 : v >= 255 ? 255 : (uint32)v;
}


/*!	What the screen shows at each pixel of the rectangle, from the planes. */
static void
reference(const Picture& p, const overlay_read_back& o, uint32* pixels, int32 left, int32 top, int32 width,
	int32 height)
{
	const overlay_view& v = o.view;
	const overlay_window& w = o.window;
	const uint32 mask = w.red.mask << 16 | w.green.mask << 8 | w.blue.mask;
	const uint32 key = (w.red.value << 16 | w.green.value << 8 | w.blue.value) & mask;
	for (int32 y = top; y < top + height; y++) {
		for (int32 x = left; x < left + width; x++) {
			if (x < w.h_start + w.offset_left || x >= w.h_start + w.width - w.offset_right
				|| y < w.v_start + w.offset_top || y >= w.v_start + w.height - w.offset_bottom)
				continue;
			uint32& pixel = pixels[(y - top) * width + x - left];
			if (o.keyed_by_alpha ? (pixel >> 24) != 0
					: (w.flags & B_OVERLAY_COLOR_KEY) && (pixel & mask) != key)
				continue;
			int32 column = x - w.h_start;
			if (w.flags & B_OVERLAY_HORIZONTAL_MIRRORING)
				column = w.width - 1 - column;
			const double sx = v.h_start + (column + 0.5) * v.width / w.width - 0.5;
			const double sy = v.v_start + (y - w.v_start + 0.5) * v.height / w.height - 0.5;
			double values[3];
			for (int i = 0; i < 3; i++) {
				const int32 shiftX = i == 0 ? 0 : p.shiftX, shiftY = i == 0 ? 0 : p.shiftY;
				values[i] = plane_sample(p, i, shiftX ? sx / 2 : sx, shiftY ? (sy - 0.5) / 2 : sy,
					v.h_start >> shiftX, (v.h_start + v.width - 1) >> shiftX,
					v.v_start >> shiftY, (v.v_start + v.height - 1) >> shiftY);
			}
			double rgb[3];
			if (p.rgb) {
				for (int i = 0; i < 3; i++)
					rgb[i] = values[i] / 255;
			} else
				ycbcr_to_rgb(w.flags, p.height, p.bits, values, rgb);
			pixel = 0xff000000 | to8(rgb[0]) << 16 | to8(rgb[1]) << 8 | to8(rgb[2]);
		}
	}
}


static int
channel_diff(uint32 a, uint32 b)
{
	int worst = 0;
	for (int shift = 0; shift < 32; shift += 8) {
		const int d = abs((int)((a >> shift) & 0xff) - (int)((b >> shift) & 0xff));
		if (d > worst)
			worst = d;
	}
	return worst;
}


static const color_space kSpaces[] = {
	B_RGB32, B_RGBA32, B_RGB16, B_RGB15, B_YCbCr422, B_YUV420, B_YUV420_SAND128, B_YUV420_SAND128_10
};

static const char*
space_name(color_space space)
{
	switch (space) {
		case B_RGB32: return "B_RGB32";
		case B_RGBA32: return "B_RGBA32";
		case B_RGB16: return "B_RGB16";
		case B_RGB15: return "B_RGB15";
		case B_YCbCr422: return "B_YCbCr422";
		case B_YUV420: return "B_YUV420";
		case B_YUV420_SAND128: return "B_YUV420_SAND128";
		case B_YUV420_SAND128_10: return "B_YUV420_SAND128_10";
		default: return "?";
	}
}


static long sChecked, sFailures;


static void
geometry_case(color_space space, int round)
{
	const bool yuv = space == B_YCbCr422 || space == B_YUV420 || space == B_YUV420_SAND128
		|| space == B_YUV420_SAND128_10;
	const bool sand = space == B_YUV420_SAND128 || space == B_YUV420_SAND128_10;
	int32 width = random_int(2, sand ? 420 : 260);
	int32 height = random_int(2, 140);
	if (yuv) {
		width &= ~1;
		height &= ~1;
		if (round % 7 == 0)
			height = 720 + 2 * random_int(0, 8);	// the default matrix changes at 720 lines
	}
	Picture p = random_picture(space, width, height);
	overlay_buffer buffer;
	std::vector<uint8> bytes = pack(space, p, sand && rand() % 2 ? 16 * random_int(1, 4) : 0, buffer);

	overlay_read_back o;
	memset(&o, 0, sizeof(o));
	o.buffer = &buffer;
	overlay_view& v = o.view;
	v.h_start = random_int(0, width - 2);
	v.v_start = random_int(0, height - 2);
	if (yuv) {
		v.h_start &= ~1;
		v.v_start &= ~1;
	}
	v.width = random_int(2, width - v.h_start);
	v.height = random_int(2, height - v.v_start);
	overlay_window& w = o.window;
	const int scale = rand() % 4;
	w.width = scale == 0 ? v.width : scale == 1 ? v.width * 2 : scale == 2 ? (v.width + 1) / 2 + 1
		: random_int(2, 400);
	w.height = scale == 0 ? v.height : scale == 1 ? v.height * 2 : scale == 2 ? (v.height + 1) / 2 + 1
		: random_int(2, 300);
	w.h_start = random_int(-w.width + 1, 300);
	w.v_start = random_int(-w.height + 1, 200);
	if (rand() % 4 == 0) {
		w.offset_left = random_int(0, w.width / 3);
		w.offset_right = random_int(0, w.width / 3);
		w.offset_top = random_int(0, w.height / 3);
		w.offset_bottom = random_int(0, w.height / 3);
	}
	w.red.value = 0;
	w.green.value = 80;
	w.blue.value = 0;
	w.red.mask = w.green.mask = w.blue.mask = w.alpha.mask = 0xff;
	const uint32 matrices[] = { 0, B_OVERLAY_COLOR_BT601, B_OVERLAY_COLOR_BT709, B_OVERLAY_COLOR_BT2020 };
	w.flags = matrices[rand() % 4] | (rand() % 2 ? B_OVERLAY_COLOR_FULL_RANGE : 0)
		| (rand() % 4 == 0 ? B_OVERLAY_HORIZONTAL_MIRRORING : 0)
		| (rand() % 3 ? B_OVERLAY_COLOR_KEY : 0);
	o.keyed_by_alpha = rand() % 2;

	// the read-back rectangle (screen coordinates; the screen starts at 0, 0)
	const int32 left = random_int(0, 120), top = random_int(0, 80);
	const int32 rw = random_int(1, 360), rh = random_int(1, 260);
	std::vector<uint32> front((size_t)rw * rh);
	for (uint32& pixel : front) {
		const int kind = rand() % 4;
		pixel = kind == 0 ? 0x00005000 | (uint32)(rand() & 0xff) << 24 : kind == 1 ? 0
			: kind == 2 ? 0xff005000 : (uint32)rand() * 2654435761u;
	}
	std::vector<uint32> expected = front, got = front;
	reference(p, o, expected.data(), left, top, rw, rh);
	const int32 bpr = rw * 4;
	const status_t status = read_back_overlay(o, got.data(), bpr, left, top, rw, rh);
	if (status != B_OK) {
		printf("FAIL %s round %d: status %d\n", space_name(space), round, (int)status);
		sFailures++;
		return;
	}
	int reported = 0;
	for (size_t i = 0; i < front.size(); i++) {
		sChecked++;
		if (channel_diff(expected[i], got[i]) > 1) {
			sFailures++;
			if (reported++ < 3) {
				printf("FAIL %s round %d: %dx%d view %d,%d %dx%d window %d,%d %dx%d flags %#x alpha %d, "
					"pixel %d,%d: expected %08x got %08x (front %08x)\n", space_name(space), round,
					(int)width, (int)height, v.h_start, v.v_start, v.width, v.height, w.h_start,
					w.v_start, w.width, w.height, (unsigned)w.flags, o.keyed_by_alpha,
					(int)(left + i % rw), (int)(top + i / rw), (unsigned)expected[i], (unsigned)got[i],
					(unsigned)front[i]);
			}
		}
	}
}


/*!	RGB (0...1) to YCbCr samples, the inverse of the encodings. */
static void
encode(uint32 flags, int32 bits, const double rgb[3], int32 ycc[3])
{
	const uint32 matrix = flags & B_OVERLAY_COLOR_MATRIX_MASK;
	const double kr = matrix == B_OVERLAY_COLOR_BT709 ? 0.2126 : matrix == B_OVERLAY_COLOR_BT2020 ? 0.2627 : 0.299;
	const double kb = matrix == B_OVERLAY_COLOR_BT709 ? 0.0722 : matrix == B_OVERLAY_COLOR_BT2020 ? 0.0593 : 0.114;
	const double y = kr * rgb[0] + (1 - kr - kb) * rgb[1] + kb * rgb[2];
	const double cb = (rgb[2] - y) / (2 * (1 - kb)), cr = (rgb[0] - y) / (2 * (1 - kr));
	const double unit = 1 << (bits - 8);
	if (flags & B_OVERLAY_COLOR_FULL_RANGE) {
		const double maximum = (1 << bits) - 1;
		ycc[0] = lround(y * maximum);
		ycc[1] = lround(128 * unit + cb * maximum);
		ycc[2] = lround(128 * unit + cr * maximum);
	} else {
		ycc[0] = lround((16 + 219 * y) * unit);
		ycc[1] = lround((128 + 224 * cb) * unit);
		ycc[2] = lround((128 + 224 * cr) * unit);
	}
}


/*!	Bars of 16 x 16 pixels (white 100 %, then 75 %: yellow, cyan, green, magenta, red, blue, black) and a gray
	ramp, encoded with \a flags, read back 1:1: the RGB they were made from, within 1.
*/
static void
color_case(color_space space, uint32 flags)
{
	static const double kColors[][3] = {
		{1, 1, 1}, {.75, .75, 0}, {0, .75, .75}, {0, .75, 0}, {.75, 0, .75}, {.75, 0, 0}, {0, 0, .75},
		{0, 0, 0}, {.1, .1, .1}, {.3, .3, .3}, {.5, .5, .5}, {.9, .9, .9}
	};
	const int32 count = sizeof(kColors) / sizeof(kColors[0]);
	const int32 width = 16 * count, height = 16;
	Picture p = random_picture(space, width, height);
	const int32 bits = p.bits;
	for (int32 c = 0; c < count; c++) {
		int32 ycc[3];
		encode(flags, bits, kColors[c], ycc);
		for (int32 y = 0; y < height; y++) {
			for (int32 x = c * 16; x < c * 16 + 16; x++) {
				p.planes[0][(size_t)y * width + x] = ycc[0];
				if ((y & 1) == 0 || p.shiftY == 0) {
					p.planes[1][(size_t)(y >> p.shiftY) * (width / 2) + x / 2] = ycc[1];
					p.planes[2][(size_t)(y >> p.shiftY) * (width / 2) + x / 2] = ycc[2];
				}
			}
		}
	}
	overlay_buffer buffer;
	std::vector<uint8> bytes = pack(space, p, 0, buffer);
	overlay_read_back o;
	memset(&o, 0, sizeof(o));
	o.buffer = &buffer;
	o.view.width = width;
	o.view.height = height;
	o.window.width = width;
	o.window.height = height;
	o.window.flags = flags;
	std::vector<uint32> pixels((size_t)width * height, 0);
	read_back_overlay(o, pixels.data(), width * 4, 0, 0, width, height);
	for (int32 c = 0; c < count; c++) {
		// the bar's middle (its edges mix with the next bar's chroma)
		for (int32 y = 0; y < height; y++) {
			for (int32 x = c * 16 + 4; x < c * 16 + 12; x++) {
				const uint32 want = 0xff000000 | to8(kColors[c][0]) << 16 | to8(kColors[c][1]) << 8
					| to8(kColors[c][2]);
				sChecked++;
				if (channel_diff(want, pixels[(size_t)y * width + x]) > 1) {
					if (sFailures++ < 20) {
						printf("FAIL color %s flags %#x bar %d: want %08x got %08x\n", space_name(space),
							(unsigned)flags, (int)c, (unsigned)want, (unsigned)pixels[(size_t)y * width + x]);
					}
				}
			}
		}
	}
}


int
main()
{
	srand(1);
	for (color_space space : kSpaces)
		for (int round = 0; round < 400; round++)
			geometry_case(space, round);
	const long geometry = sChecked;

	const uint32 encodings[] = {
		B_OVERLAY_COLOR_BT601, B_OVERLAY_COLOR_BT709, B_OVERLAY_COLOR_BT2020,
		B_OVERLAY_COLOR_BT601 | B_OVERLAY_COLOR_FULL_RANGE, B_OVERLAY_COLOR_BT709 | B_OVERLAY_COLOR_FULL_RANGE
	};
	for (color_space space : { B_YCbCr422, B_YUV420, B_YUV420_SAND128, B_YUV420_SAND128_10 })
		for (uint32 flags : encodings)
			color_case(space, flags);

	printf("READBACK %ld geometry and %ld color pixels checked, %ld failures: %s\n", geometry,
		sChecked - geometry, sFailures, sFailures == 0 ? "PASS" : "FAIL");
	return sFailures == 0 ? 0 : 1;
}
