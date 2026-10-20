/*
 * sandbench — checks and measures the rpivid SAND -> planar conversion (libavcodec/rpivid_sand.c,
 * patches/ffmpeg6; docs/design/hw-video-decode.md) apart from the decoder. "SND " lines.
 *
 *   sandbench [-check] [-quick]
 *
 * Check: random SAND pictures (8 and 10 bit, widths that end mid-column, odd heights), converted
 * whole, in row bands of several sizes and in separate row ranges, compared sample by sample
 * with a direct reading of the layout ("SND check PASS"). Built for arm64 this checks the NEON
 * code; under qemu-aarch64 on the build host too.
 *
 * Measure (not with -check): 1280x720, 1920x1080, 3840x2160, 8 and 10 bit, ms per picture for the
 * first version of the conversion (row by row), the current one with bands of 2, 16 (default) and
 * 64 rows and whole columns, and the default split over 2 and 4 threads. The pictures rotate
 * through more memory than the caches hold, as decoded pictures do.
 */
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "rpivid_sand.h"

#define SAY(...) do { printf("SND " __VA_ARGS__); printf("\n"); fflush(stdout); } while (0)


typedef struct Picture {
	uint32_t	width, height, bitDepth, columns, lumaStride, chromaStride;
	uint8_t*	luma;
	uint8_t*	chroma;
	uint8_t*	planes[3];
	ptrdiff_t	strides[3];
} Picture;


static uint32_t sSeed = 12345;


static void*
allocate(size_t alignment, size_t size)
{
	void* memory = NULL;
	if (posix_memalign(&memory, alignment, size) != 0) {
		fprintf(stderr, "sandbench: out of memory\n");
		exit(1);
	}
	return memory;
}

static uint32_t
random_u32(void)
{
	sSeed = sSeed * 1103515245u + 12345u;
	return sSeed >> 8;
}


static void
picture_init(Picture* p, uint32_t width, uint32_t height, uint32_t bitDepth, int fill)
{
	const uint32_t height16 = (height + 15) & ~15u;
	const uint32_t columnBytes = bitDepth == 8 ? ((width + 127) & ~127u)
		: ((((width + 2) / 3) + 31) & ~31u) * 4;
	const uint32_t bytes = bitDepth == 8 ? 1 : 2;
	const uint32_t chromaWidth = (width + 1) / 2, chromaHeight = (height + 1) / 2;
	size_t i, size;

	p->width = width;
	p->height = height;
	p->bitDepth = bitDepth;
	p->columns = columnBytes / 128;
	p->lumaStride = height16 * 128;
	p->chromaStride = p->lumaStride / 2;
	p->luma = allocate(4096, (size_t)p->lumaStride * p->columns);
	p->chroma = allocate(4096, (size_t)p->chromaStride * p->columns);
	if (fill) {
		for (i = 0; i < (size_t)p->lumaStride * p->columns; i++)
			p->luma[i] = (uint8_t)random_u32();
		for (i = 0; i < (size_t)p->chromaStride * p->columns; i++)
			p->chroma[i] = (uint8_t)random_u32();
	} else {
		memset(p->luma, 0, (size_t)p->lumaStride * p->columns);
		memset(p->chroma, 0, (size_t)p->chromaStride * p->columns);
	}
	/* line sizes as FFmpeg's frames have them: padded */
	p->strides[0] = ((width * bytes + 63) & ~63u) + 64;
	p->strides[1] = p->strides[2] = ((chromaWidth * bytes + 63) & ~63u) + 64;
	size = (size_t)p->strides[0] * height;
	p->planes[0] = allocate(64, size);
	memset(p->planes[0], 0, size);
	for (i = 1; i < 3; i++) {
		size = (size_t)p->strides[i] * chromaHeight;
		p->planes[i] = allocate(64, size);
		memset(p->planes[i], 0, size);
	}
}


static void
picture_free(Picture* p)
{
	int i;
	free(p->luma);
	free(p->chroma);
	for (i = 0; i < 3; i++)
		free(p->planes[i]);
}


/* sample x of row y of a SAND plane, as the layout defines it */
static uint32_t
sand_sample(const uint8_t* plane, uint32_t columnStride, uint32_t bitDepth,
	uint32_t x, uint32_t y)
{
	if (bitDepth == 8)
		return plane[(size_t)(x / 128) * columnStride + (size_t)y * 128 + x % 128];
	{
		const uint32_t s = x % 96;
		const uint8_t* w = plane + (size_t)(x / 96) * columnStride + (size_t)y * 128
			+ (s / 3) * 4;
		const uint32_t word = w[0] | (w[1] << 8) | (w[2] << 16) | ((uint32_t)w[3] << 24);
		return (word >> (10 * (s % 3))) & 0x3ff;
	}
}


static uint32_t
planar_sample(const Picture* p, int plane, uint32_t x, uint32_t y)
{
	const uint8_t* row = p->planes[plane] + y * p->strides[plane];
	return p->bitDepth == 8 ? row[x] : ((const uint16_t*)row)[x];
}


static int
verify(const Picture* p, const char* what)
{
	const uint32_t chromaWidth = (p->width + 1) / 2, chromaHeight = (p->height + 1) / 2;
	uint32_t x, y;

	for (y = 0; y < p->height; y++) {
		for (x = 0; x < p->width; x++) {
			if (planar_sample(p, 0, x, y)
					!= sand_sample(p->luma, p->lumaStride, p->bitDepth, x, y)) {
				SAY("check FAIL %s %ux%u %u-bit: luma %u,%u", what, p->width, p->height,
					p->bitDepth, x, y);
				return 0;
			}
		}
	}
	for (y = 0; y < chromaHeight; y++) {
		for (x = 0; x < chromaWidth; x++) {
			if (planar_sample(p, 1, x, y)
					!= sand_sample(p->chroma, p->chromaStride, p->bitDepth, 2 * x, y)
				|| planar_sample(p, 2, x, y)
					!= sand_sample(p->chroma, p->chromaStride, p->bitDepth, 2 * x + 1, y)) {
				SAY("check FAIL %s %ux%u %u-bit: chroma %u,%u", what, p->width, p->height,
					p->bitDepth, x, y);
				return 0;
			}
		}
	}
	return 1;
}


static void
convert(Picture* p, uint32_t y0, uint32_t y1, uint32_t band)
{
	if (band == 0) {
		(p->bitDepth == 8 ? ff_rpivid_sand8_to_planar : ff_rpivid_sand10_to_planar)(
			p->planes[0], p->strides[0], p->planes[1], p->strides[1], p->planes[2],
			p->strides[2], p->luma, p->lumaStride, p->chroma, p->chromaStride, p->width,
			p->height, y0, y1);
	} else {
		(p->bitDepth == 8 ? ff_rpivid_sand8_to_planar_band
			: ff_rpivid_sand10_to_planar_band)(p->planes[0], p->strides[0], p->planes[1],
			p->strides[1], p->planes[2], p->strides[2], p->luma, p->lumaStride, p->chroma,
			p->chromaStride, p->width, p->height, y0, y1, band);
	}
}


static void
clear_planes(Picture* p)
{
	memset(p->planes[0], 0, (size_t)p->strides[0] * p->height);
	memset(p->planes[1], 0, (size_t)p->strides[1] * ((p->height + 1) / 2));
	memset(p->planes[2], 0, (size_t)p->strides[2] * ((p->height + 1) / 2));
}


static int
check(void)
{
	static const uint32_t kSizes[][2] = {
		{ 32, 32 }, { 100, 34 }, { 128, 64 }, { 130, 45 }, { 256, 144 }, { 320, 240 },
		{ 416, 240 }, { 721, 401 }, { 1280, 720 }, { 1920, 1080 }, { 97, 33 },
	};
	static const uint32_t kBands[] = { 0, 2, 4, 16, 64, 100000 };
	int ok = 1, bits;
	size_t s, b;

	for (bits = 8; bits <= 10; bits += 2) {
		for (s = 0; s < sizeof(kSizes) / sizeof(kSizes[0]); s++) {
			Picture p;
			uint32_t y0;
			picture_init(&p, kSizes[s][0], kSizes[s][1], bits, 1);
			for (b = 0; b < sizeof(kBands) / sizeof(kBands[0]); b++) {
				char what[32];
				clear_planes(&p);
				convert(&p, 0, p.height, kBands[b]);
				snprintf(what, sizeof(what), "band %u", kBands[b]);
				ok &= verify(&p, what);
			}
			/* separate row ranges, as the slice threads convert them */
			clear_planes(&p);
			for (y0 = 0; y0 < p.height; y0 += 38) {
				const uint32_t y1 = y0 + 38 < p.height ? y0 + 38 : p.height;
				convert(&p, y0, y1, 0);
			}
			ok &= verify(&p, "row ranges");
			picture_free(&p);
		}
	}
	SAY("check %s (8 and 10 bit, 11 sizes, whole, bands, row ranges)", ok ? "PASS" : "FAIL");
	return ok;
}


/*	The first version (2026-10-20): row by row, memcpy per column, scalar 10 bit */
static void
first_sand8(Picture* p)
{
	const uint32_t chromaWidth = (p->width + 1) / 2, chromaHeight = (p->height + 1) / 2;
	uint32_t row, x, i;
	for (row = 0; row < p->height; row++) {
		uint8_t* out = p->planes[0] + row * p->strides[0];
		for (x = 0; x < p->width; x += 128) {
			const uint32_t count = p->width - x < 128 ? p->width - x : 128;
			memcpy(out + x, p->luma + (x / 128) * (size_t)p->lumaStride + row * 128, count);
		}
	}
	for (row = 0; row < chromaHeight; row++) {
		uint8_t* u = p->planes[1] + row * p->strides[1];
		uint8_t* v = p->planes[2] + row * p->strides[2];
		for (x = 0; x < chromaWidth; x += 64) {
			const uint32_t pairs = chromaWidth - x < 64 ? chromaWidth - x : 64;
			const uint8_t* uv = p->chroma + (x / 64) * (size_t)p->chromaStride + row * 128;
			for (i = 0; i < pairs; i++) {
				u[x + i] = uv[2 * i];
				v[x + i] = uv[2 * i + 1];
			}
		}
	}
}


static void
first_unpack10(uint16_t* out, const uint8_t* in, uint32_t count)
{
	uint32_t i = 0, word;
	for (; i + 3 <= count; i += 3, in += 4) {
		memcpy(&word, in, sizeof(word));
		out[i] = word & 0x3ff;
		out[i + 1] = (word >> 10) & 0x3ff;
		out[i + 2] = (word >> 20) & 0x3ff;
	}
	if (i < count) {
		memcpy(&word, in, sizeof(word));
		for (; i < count; i++, word >>= 10)
			out[i] = word & 0x3ff;
	}
}


static void
first_sand10(Picture* p)
{
	const uint32_t chromaWidth = (p->width + 1) / 2, chromaHeight = (p->height + 1) / 2;
	uint16_t samples[96];
	uint32_t row, x, i;
	for (row = 0; row < p->height; row++) {
		uint16_t* out = (uint16_t*)(p->planes[0] + row * p->strides[0]);
		for (x = 0; x < p->width; x += 96) {
			const uint32_t count = p->width - x < 96 ? p->width - x : 96;
			first_unpack10(out + x, p->luma + (x / 96) * (size_t)p->lumaStride + row * 128,
				count);
		}
	}
	for (row = 0; row < chromaHeight; row++) {
		uint16_t* u = (uint16_t*)(p->planes[1] + row * p->strides[1]);
		uint16_t* v = (uint16_t*)(p->planes[2] + row * p->strides[2]);
		for (x = 0; x < chromaWidth; x += 48) {
			const uint32_t pairs = chromaWidth - x < 48 ? chromaWidth - x : 48;
			first_unpack10(samples, p->chroma + (x / 48) * (size_t)p->chromaStride + row * 128,
				2 * pairs);
			for (i = 0; i < pairs; i++) {
				u[x + i] = samples[2 * i];
				v[x + i] = samples[2 * i + 1];
			}
		}
	}
}


typedef struct Band {
	Picture*	picture;
	uint32_t	y0, y1;
} Band;


static void*
band_thread(void* data)
{
	Band* band = data;
	convert(band->picture, band->y0, band->y1, 0);
	return NULL;
}


static void
convert_threads(Picture* p, int threads)
{
	pthread_t ids[8];
	Band bands[8];
	const uint32_t rows = (((p->height + threads - 1) / threads) + 1) & ~1u;
	int i;
	for (i = 0; i < threads; i++) {
		bands[i].picture = p;
		bands[i].y0 = i * rows < p->height ? i * rows : p->height;
		bands[i].y1 = (i + 1) * rows < p->height ? (i + 1) * rows : p->height;
		if (i > 0)
			pthread_create(&ids[i], NULL, band_thread, &bands[i]);
	}
	band_thread(&bands[0]);
	for (i = 1; i < threads; i++)
		pthread_join(ids[i], NULL);
}


static double
now_ms(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1000.0 + t.tv_nsec / 1000000.0;
}


static void
measure(uint32_t width, uint32_t height, uint32_t bits, int quick)
{
	/* more than the 1 MB L2 cache, as a decoder's pictures are */
	enum { kPictures = 4 };
	Picture pictures[kPictures];
	const int rounds = quick ? 3 : (width >= 3840 ? 8 : 24);
	const char* names[] = { "first", "band2", "band16", "band64", "columns", "2threads",
		"4threads" };
	double results[7];
	int v, r, i;

	for (i = 0; i < kPictures; i++)
		picture_init(&pictures[i], width, height, bits, 1);
	for (v = 0; v < 7; v++) {
		double start = 0;
		for (r = -1; r < rounds; r++) {
			if (r == 0)
				start = now_ms();
			for (i = 0; i < kPictures; i++) {
				Picture* p = &pictures[i];
				switch (v) {
					case 0:
						(bits == 8 ? first_sand8 : first_sand10)(p);
						break;
					case 1:
						convert(p, 0, height, 2);
						break;
					case 2:
						convert(p, 0, height, 16);
						break;
					case 3:
						convert(p, 0, height, 64);
						break;
					case 4:
						convert(p, 0, height, (height + 1) & ~1u);
						break;
					case 5:
						convert_threads(p, 2);
						break;
					case 6:
						convert_threads(p, 4);
						break;
				}
			}
		}
		results[v] = (now_ms() - start) / (rounds * kPictures);
	}
	SAY("%ux%u %u-bit ms per picture: %s %.2f, %s %.2f, %s %.2f, %s %.2f, %s %.2f, %s %.2f, "
		"%s %.2f", width, height, bits, names[0], results[0], names[1], results[1], names[2],
		results[2], names[3], results[3], names[4], results[4], names[5], results[5],
		names[6], results[6]);
	for (i = 0; i < kPictures; i++)
		picture_free(&pictures[i]);
}


int
main(int argc, char** argv)
{
	int checkOnly = 0, quick = 0, i;
	for (i = 1; i < argc; i++) {
		if (strcmp(argv[i], "-check") == 0)
			checkOnly = 1;
		else if (strcmp(argv[i], "-quick") == 0)
			quick = 1;
	}
#if defined(__ARM_NEON) || defined(__aarch64__)
	SAY("NEON");
#endif
	if (!check())
		return 1;
	if (checkOnly)
		return 0;
	measure(1280, 720, 8, quick);
	measure(1920, 1080, 8, quick);
	measure(1920, 1080, 10, quick);
	measure(3840, 2160, 8, quick);
	measure(3840, 2160, 10, quick);
	return 0;
}
