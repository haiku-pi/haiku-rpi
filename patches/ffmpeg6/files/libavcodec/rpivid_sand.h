/*
 * Copyright 2026, Haiku, Inc. All rights reserved.
 * Distributed under the terms of the MIT License.
 */
#ifndef AVCODEC_RPIVID_SAND_H
#define AVCODEC_RPIVID_SAND_H


/*	The rpivid block's output, SAND (column 128) NV12, to planar YUV 4:2:0.

	Each plane is a sequence of 128-byte wide columns: byte b of row y of
	column c is at plane + c * column_stride + y * 128 + b. 8 bit: a sample
	per byte; 10 bit: three samples in each little-endian 32-bit word, lowest
	bits first (96 per column). The chroma plane holds Cb and Cr interleaved,
	half the rows.
*/


#include <stddef.h>
#include <stdint.h>


/* yuv420p; line sizes in bytes */
void	ff_rpivid_sand8_to_planar(uint8_t* y, ptrdiff_t yStride, uint8_t* u,
			ptrdiff_t uStride, uint8_t* v, ptrdiff_t vStride,
			const uint8_t* luma, uint32_t lumaColumnStride, const uint8_t* chroma,
			uint32_t chromaColumnStride, uint32_t width, uint32_t height);

/* yuv420p10le (16-bit samples) */
void	ff_rpivid_sand10_to_planar(uint8_t* y, ptrdiff_t yStride, uint8_t* u,
			ptrdiff_t uStride, uint8_t* v, ptrdiff_t vStride,
			const uint8_t* luma, uint32_t lumaColumnStride, const uint8_t* chroma,
			uint32_t chromaColumnStride, uint32_t width, uint32_t height);


#endif /* AVCODEC_RPIVID_SAND_H */
