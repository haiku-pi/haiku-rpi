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
