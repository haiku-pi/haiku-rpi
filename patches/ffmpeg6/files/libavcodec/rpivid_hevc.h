/*
 * Copyright 2026, Haiku, Inc. All rights reserved.
 * Distributed under the terms of the MIT License.
 */
#ifndef AVCODEC_RPIVID_HEVC_H
#define AVCODEC_RPIVID_HEVC_H


/*	FFmpeg's HEVC decoder with the Raspberry Pi 4's rpivid block.

	The block is an hwaccel of hevcdec.c that decodes into the decoder's own
	system-memory frames: hevcdec.c parses the stream and keeps the DPB and
	the output order; each picture is decoded by the block into SAND buffers
	of the rpivid driver (kept as the picture's reference) and converted into
	the frame (yuv420p or yuv420p10le) - while the block decodes the next
	picture. Users see a software decoder. Streams the block cannot take stay
	on the CPU.
*/


#include "avcodec.h"


/* The decoder option "rpivid" and FFMPEG_RPIVID: */
#define RPIVID_OFF		0	/* the CPU decoder */
#define RPIVID_ON		1	/* the block, for the coding tools verified on it */
#define RPIVID_ALL		2	/* the block, for every tool its programming has */

/* The decoder option "rpivid_out" (a caller may change it at any time):
   0 the pictures are converted into the frames (yuv420p, yuv420p10le), as a
   software decoder's; 1 (sand) the block decodes into pictures the display can
   scan out, and each frame it decoded carries its picture in opaque_ref (an
   RpividSandFrame) - and is converted only while the option is 0 again
   (RpividSandFrame.planar says whether it was). The frames decoded on the
   CPU (a picture or stream the block does not take) have no picture. A
   picture is not written again while a frame holding it lives. A caller
   that sets AV_CODEC_FLAG_COPY_OPAQUE must not ask for it. */
#define RPIVID_OUT_PLANAR	0
#define RPIVID_OUT_SAND		1

#define RPIVID_SAND_FRAME_MAGIC	0x52534e44	/* 'RSND' */

typedef struct RpividSandFrame {
	uint32_t		magic;			/* RPIVID_SAND_FRAME_MAGIC */
	uint32_t		size;			/* of this structure */
	int32_t			area;			/* the picture's mapping, in the caller's team */
	uint32_t		offset;			/* of the picture in it */
	uint32_t		picture_size;	/* from offset: luma and chroma */
	uint32_t		width;			/* the picture's (coded) size */
	uint32_t		height;
	uint32_t		bit_depth;		/* 8 or 10 (three samples in 32 bits) */
	uint32_t		column_height;	/* rows of 128 bytes in each column */
	uint32_t		chroma_offset;	/* the chroma's first row in a column, bytes */
	int32_t			planar;			/* the frame's planes hold the picture too */
	uint32_t		_reserved;
	const uint8_t*	address;		/* the picture (read-only, cached) */
} RpividSandFrame;


/* From get_format(), once the software format is chosen and the SPS active:
   attaches the hwaccel if the block takes the stream. 0 if attached, else
   negative (the reason was logged). */
int		ff_rpivid_hevc_attach(AVCodecContext* avctx, int level);

int		ff_rpivid_hevc_active(const AVCodecContext* avctx);

/* Before the first slice of a picture goes to the hwaccel: can the block
   decode it? 0, or negative (the caller decodes on the CPU):
   RPIVID_EARLIER_FAILED when the block failed an earlier picture (the
   caller drops the pictures up to the next IRAP). */
#define RPIVID_EARLIER_FAILED	(-2)
int		ff_rpivid_hevc_picture_ok(AVCodecContext* avctx);

/* After end_frame: the block did not decode the picture, or one before it.
   The frames of a picture it failed after its submit have
   AV_FRAME_FLAG_CORRUPT: the caller drops them. */
int		ff_rpivid_hevc_failed(const AVCodecContext* avctx);

/* Before the last pictures are output (an empty packet): the pending picture
   is converted */
void	ff_rpivid_hevc_drain(AVCodecContext* avctx);


#endif /* AVCODEC_RPIVID_HEVC_H */
