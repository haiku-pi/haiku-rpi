/*
 * Copyright 2026, Haiku, Inc. All rights reserved.
 * Distributed under the terms of the MIT License.
 */


#include "rpivid_sand.h"

#include <string.h>

#if defined(__ARM_NEON) || defined(__aarch64__)
#	include <arm_neon.h>
#	define RPIVID_NEON 1
#endif


#define COLUMN_BYTES	128


/* The rows are converted in bands of this many luma rows; within a band,
   column by column. A band of one row reads every column at once (and
   writes the output rows in order); a band of the whole picture reads each
   column in order (and writes the output in 128-byte pieces of every row).
   In between, a band's output stays in the cache while its columns are
   read. */
#ifndef RPIVID_SAND_BAND
#	define RPIVID_SAND_BAND	16
#endif


static inline uint32_t
min_u32(uint32_t a, uint32_t b)
{
	return a < b ? a : b;
}


/* 128 bytes */
static inline void
copy_column_row(uint8_t* out, const uint8_t* in)
{
#ifdef RPIVID_NEON
	const uint8x16x4_t a = vld1q_u8_x4(in);
	const uint8x16x4_t b = vld1q_u8_x4(in + 64);
	vst1q_u8_x4(out, a);
	vst1q_u8_x4(out + 64, b);
#else
	memcpy(out, in, COLUMN_BYTES);
#endif
}


/* One row of interleaved CbCr into two rows */
static inline void
split_chroma8(uint8_t* u, uint8_t* v, const uint8_t* uv, uint32_t pairs)
{
	uint32_t i = 0;
#ifdef RPIVID_NEON
	for (; i + 16 <= pairs; i += 16) {
		const uint8x16x2_t both = vld2q_u8(uv + 2 * i);
		vst1q_u8(u + i, both.val[0]);
		vst1q_u8(v + i, both.val[1]);
	}
#endif
	for (; i < pairs; i++) {
		u[i] = uv[2 * i];
		v[i] = uv[2 * i + 1];
	}
}


void
ff_rpivid_sand8_to_planar_band(uint8_t* y, ptrdiff_t yStride, uint8_t* u,
	ptrdiff_t uStride, uint8_t* v, ptrdiff_t vStride, const uint8_t* luma,
	uint32_t lumaColumnStride, const uint8_t* chroma,
	uint32_t chromaColumnStride, uint32_t width, uint32_t height, uint32_t y0,
	uint32_t y1, uint32_t band)
{
	const uint32_t chromaWidth = (width + 1) / 2;
	uint32_t top, x, row;

	(void)height;
	for (top = y0; top < y1; top += band) {
		const uint32_t bottom = min_u32(top + band, y1);
		const uint32_t chromaTop = top / 2, chromaBottom = (bottom + 1) / 2;

		for (x = 0; x < width; x += COLUMN_BYTES) {
			const uint32_t count = min_u32(width - x, COLUMN_BYTES);
			const uint8_t* in = luma
				+ (x / COLUMN_BYTES) * (size_t)lumaColumnStride
				+ (size_t)top * COLUMN_BYTES;
			uint8_t* out = y + top * yStride + x;
			for (row = top; row < bottom; row++) {
				if (count == COLUMN_BYTES)
					copy_column_row(out, in);
				else
					memcpy(out, in, count);
				in += COLUMN_BYTES;
				out += yStride;
			}
		}

		/* a column holds 64 CbCr pairs */
		for (x = 0; x < chromaWidth; x += COLUMN_BYTES / 2) {
			const uint32_t pairs = min_u32(chromaWidth - x, COLUMN_BYTES / 2);
			const uint8_t* in = chroma
				+ (x / (COLUMN_BYTES / 2)) * (size_t)chromaColumnStride
				+ (size_t)chromaTop * COLUMN_BYTES;
			for (row = chromaTop; row < chromaBottom; row++) {
				split_chroma8(u + row * uStride + x, v + row * vStride + x, in,
					pairs);
				in += COLUMN_BYTES;
			}
		}
	}
}


/* Up to 96 samples (32 words) of a 10-bit column row (a little-endian CPU) */
static inline void
unpack10(uint16_t* out, const uint8_t* in, uint32_t count)
{
	uint32_t i = 0, word;
#ifdef RPIVID_NEON
	const uint32x4_t mask = vdupq_n_u32(0x3ff);
	for (; i + 12 <= count; i += 12, in += 16) {
		const uint32x4_t words = vld1q_u32((const uint32_t*)in);
		uint16x4x3_t samples;
		samples.val[0] = vmovn_u32(vandq_u32(words, mask));
		samples.val[1] = vmovn_u32(vandq_u32(vshrq_n_u32(words, 10), mask));
		samples.val[2] = vmovn_u32(vandq_u32(vshrq_n_u32(words, 20), mask));
		/* interleaved: the three samples of each word in order */
		vst3_u16(out + i, samples);
	}
#endif
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


static inline void
split_chroma16(uint16_t* u, uint16_t* v, const uint16_t* uv, uint32_t pairs)
{
	uint32_t i = 0;
#ifdef RPIVID_NEON
	for (; i + 8 <= pairs; i += 8) {
		const uint16x8x2_t both = vld2q_u16(uv + 2 * i);
		vst1q_u16(u + i, both.val[0]);
		vst1q_u16(v + i, both.val[1]);
	}
#endif
	for (; i < pairs; i++) {
		u[i] = uv[2 * i];
		v[i] = uv[2 * i + 1];
	}
}


void
ff_rpivid_sand10_to_planar_band(uint8_t* y, ptrdiff_t yStride, uint8_t* u,
	ptrdiff_t uStride, uint8_t* v, ptrdiff_t vStride, const uint8_t* luma,
	uint32_t lumaColumnStride, const uint8_t* chroma,
	uint32_t chromaColumnStride, uint32_t width, uint32_t height, uint32_t y0,
	uint32_t y1, uint32_t band)
{
	const uint32_t perColumn = 96;
	const uint32_t chromaWidth = (width + 1) / 2;
	uint16_t samples[96];
	uint32_t top, x, row;

	(void)height;
	for (top = y0; top < y1; top += band) {
		const uint32_t bottom = min_u32(top + band, y1);
		const uint32_t chromaTop = top / 2, chromaBottom = (bottom + 1) / 2;

		for (x = 0; x < width; x += perColumn) {
			const uint32_t count = min_u32(width - x, perColumn);
			const uint8_t* in = luma + (x / perColumn) * (size_t)lumaColumnStride
				+ (size_t)top * COLUMN_BYTES;
			for (row = top; row < bottom; row++) {
				unpack10((uint16_t*)(y + row * yStride) + x, in, count);
				in += COLUMN_BYTES;
			}
		}

		/* a column holds 48 CbCr pairs */
		for (x = 0; x < chromaWidth; x += perColumn / 2) {
			const uint32_t pairs = min_u32(chromaWidth - x, perColumn / 2);
			const uint8_t* in = chroma
				+ (x / (perColumn / 2)) * (size_t)chromaColumnStride
				+ (size_t)chromaTop * COLUMN_BYTES;
			for (row = chromaTop; row < chromaBottom; row++) {
				unpack10(samples, in, 2 * pairs);
				split_chroma16((uint16_t*)(u + row * uStride) + x,
					(uint16_t*)(v + row * vStride) + x, samples, pairs);
				in += COLUMN_BYTES;
			}
		}
	}
}


void
ff_rpivid_sand8_to_planar(uint8_t* y, ptrdiff_t yStride, uint8_t* u,
	ptrdiff_t uStride, uint8_t* v, ptrdiff_t vStride, const uint8_t* luma,
	uint32_t lumaColumnStride, const uint8_t* chroma,
	uint32_t chromaColumnStride, uint32_t width, uint32_t height, uint32_t y0,
	uint32_t y1)
{
	ff_rpivid_sand8_to_planar_band(y, yStride, u, uStride, v, vStride, luma,
		lumaColumnStride, chroma, chromaColumnStride, width, height, y0, y1,
		RPIVID_SAND_BAND);
}


void
ff_rpivid_sand10_to_planar(uint8_t* y, ptrdiff_t yStride, uint8_t* u,
	ptrdiff_t uStride, uint8_t* v, ptrdiff_t vStride, const uint8_t* luma,
	uint32_t lumaColumnStride, const uint8_t* chroma,
	uint32_t chromaColumnStride, uint32_t width, uint32_t height, uint32_t y0,
	uint32_t y1)
{
	ff_rpivid_sand10_to_planar_band(y, yStride, u, uStride, v, vStride, luma,
		lumaColumnStride, chroma, chromaColumnStride, width, height, y0, y1,
		RPIVID_SAND_BAND);
}
