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


/* One row of interleaved CbCr into two rows */
static void
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
ff_rpivid_sand8_to_planar(uint8_t* y, ptrdiff_t yStride, uint8_t* u,
	ptrdiff_t uStride, uint8_t* v, ptrdiff_t vStride, const uint8_t* luma,
	uint32_t lumaColumnStride, const uint8_t* chroma,
	uint32_t chromaColumnStride, uint32_t width, uint32_t height)
{
	const uint32_t chromaWidth = (width + 1) / 2;
	const uint32_t chromaHeight = (height + 1) / 2;
	uint32_t row, x;

	for (row = 0; row < height; row++) {
		uint8_t* out = y + row * yStride;
		for (x = 0; x < width; x += COLUMN_BYTES) {
			const uint32_t count = width - x < COLUMN_BYTES ? width - x
				: COLUMN_BYTES;
			memcpy(out + x, luma + (x / COLUMN_BYTES) * (size_t)lumaColumnStride
				+ row * COLUMN_BYTES, count);
		}
	}

	/* a column holds 64 CbCr pairs */
	for (row = 0; row < chromaHeight; row++) {
		uint8_t* outU = u + row * uStride;
		uint8_t* outV = v + row * vStride;
		for (x = 0; x < chromaWidth; x += COLUMN_BYTES / 2) {
			const uint32_t pairs = chromaWidth - x < COLUMN_BYTES / 2
				? chromaWidth - x : COLUMN_BYTES / 2;
			split_chroma8(outU + x, outV + x, chroma
				+ (x / (COLUMN_BYTES / 2)) * (size_t)chromaColumnStride
				+ row * COLUMN_BYTES, pairs);
		}
	}
}


/* Up to 96 samples (32 words) of a 10-bit column row (a little-endian CPU) */
static void
unpack10(uint16_t* out, const uint8_t* in, uint32_t count)
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


void
ff_rpivid_sand10_to_planar(uint8_t* y, ptrdiff_t yStride, uint8_t* u,
	ptrdiff_t uStride, uint8_t* v, ptrdiff_t vStride, const uint8_t* luma,
	uint32_t lumaColumnStride, const uint8_t* chroma,
	uint32_t chromaColumnStride, uint32_t width, uint32_t height)
{
	const uint32_t perColumn = 96;
	const uint32_t chromaWidth = (width + 1) / 2;
	const uint32_t chromaHeight = (height + 1) / 2;
	uint16_t samples[96];
	uint32_t row, x, i;

	for (row = 0; row < height; row++) {
		uint16_t* out = (uint16_t*)(y + row * yStride);
		for (x = 0; x < width; x += perColumn) {
			const uint32_t count = width - x < perColumn ? width - x : perColumn;
			unpack10(out + x, luma + (x / perColumn) * (size_t)lumaColumnStride
				+ row * COLUMN_BYTES, count);
		}
	}

	/* a column holds 48 CbCr pairs */
	for (row = 0; row < chromaHeight; row++) {
		uint16_t* outU = (uint16_t*)(u + row * uStride);
		uint16_t* outV = (uint16_t*)(v + row * vStride);
		for (x = 0; x < chromaWidth; x += perColumn / 2) {
			const uint32_t pairs = chromaWidth - x < perColumn / 2
				? chromaWidth - x : perColumn / 2;
			unpack10(samples, chroma + (x / (perColumn / 2))
				* (size_t)chromaColumnStride + row * COLUMN_BYTES, 2 * pairs);
			for (i = 0; i < pairs; i++) {
				outU[x + i] = samples[2 * i];
				outV[x + i] = samples[2 * i + 1];
			}
		}
	}
}
