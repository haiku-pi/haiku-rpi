/*
 * Copyright 2026, Haiku, Inc. All rights reserved.
 * Distributed under the terms of the MIT License.
 */
#ifndef AVCODEC_RPIVID_DEVICE_H
#define AVCODEC_RPIVID_DEVICE_H


/*	The rpivid driver (/dev/video/rpivid/0, Haiku): its buffers and decode
	call. Built for any other system, opening the device fails, so the
	decoder stays on the CPU.
*/


#include <stddef.h>
#include <stdint.h>


#define RPIVID_REFERENCE_SLOTS	16

typedef struct RpividDevice RpividDevice;

/* A bitstream buffer: the CPU writes it */
typedef struct RpividBitstream {
	uint32_t	handle;
	uint8_t*	data;
	size_t		size;
} RpividBitstream;

/* A picture in the block's SAND layout: the CPU reads it */
typedef struct RpividPicture {
	uint32_t		handle;
	const uint8_t*	luma;
	const uint8_t*	chroma;
	uint32_t		luma_column_stride;
	uint32_t		chroma_column_stride;
} RpividPicture;

/* A picture for the block */
typedef struct RpividJob {
	const uint64_t*	commands;		/* copied by the submit */
	uint32_t		command_count;
	uint32_t		bitstream;		/* read until the picture is done */
	uint32_t		output;
	uint32_t		collocated;		/* 0: none */
	uint32_t		references[RPIVID_REFERENCE_SLOTS];	/* 0: the output */
	uint32_t		log2_ctb_size;
	uint32_t		config2;
	int32_t			current_poc;
} RpividJob;

/* What became of a submitted picture */
typedef struct RpividResult {
	int				result;			/* 0: decoded, else a negative AVERROR */
	uint32_t		status;
	uint32_t		command_status;
	uint32_t		phase1_runs;
	uint64_t		queue_time;		/* microseconds */
	uint64_t		phase1_time;
	uint64_t		phase2_time;
} RpividResult;


/* 0, or a negative AVERROR with the reason in why */
int				ff_rpivid_device_open(RpividDevice** _device, char* why,
					size_t whySize);
RpividDevice*	ff_rpivid_device_ref(RpividDevice* device);
void			ff_rpivid_device_unref(RpividDevice* device);
uint32_t		ff_rpivid_device_clock_rate(const RpividDevice* device);

int				ff_rpivid_device_create_bitstream(RpividDevice* device,
					size_t size, RpividBitstream* bitstream);
/* motion_vectors: the picture can keep its motion vectors (TMVP) */
int				ff_rpivid_device_create_picture(RpividDevice* device,
					uint32_t width, uint32_t height, uint32_t bit_depth,
					int motion_vectors, RpividPicture* picture);
void			ff_rpivid_device_delete(RpividDevice* device, uint32_t handle);

/* Queues a picture: 0 and its id, or a negative AVERROR (the picture was
   refused). The block decodes the pictures in the order they are submitted;
   the output is read, and the bitstream buffer written again, only after
   ff_rpivid_device_wait() returned the picture. At most RPIVID_MAX_JOBS
   (4) pictures are submitted and not waited for. */
int				ff_rpivid_device_submit(RpividDevice* device,
					const RpividJob* job, uint64_t* _id);

/* timeout: microseconds, < 0 no limit. 0 and the result once the picture is
   done (it is then forgotten), AVERROR(EAGAIN) while it is not. */
int				ff_rpivid_device_wait(RpividDevice* device, uint64_t id,
					int64_t timeout, RpividResult* result);


#endif /* AVCODEC_RPIVID_DEVICE_H */
