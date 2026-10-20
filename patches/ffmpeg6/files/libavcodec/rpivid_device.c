/*
 * Copyright 2026, Haiku, Inc. All rights reserved.
 * Distributed under the terms of the MIT License.
 */


#include "rpivid_device.h"

#include <errno.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libavutil/error.h"


#ifdef __HAIKU__

#include <fcntl.h>
#include <unistd.h>

#include "rpivid_haiku.h"


struct RpividDevice {
	atomic_int	references;
	int			fd;
	rpivid_info	info;
};


static int
control(RpividDevice* device, uint32_t op, void* data, size_t size)
{
	if (ioctl(device->fd, op, data, size) != 0)
		return AVERROR(errno);
	return 0;
}


int
ff_rpivid_device_open(RpividDevice** _device, char* why, size_t whySize)
{
	RpividDevice* device;
	int ret;

	*_device = NULL;
	device = calloc(1, sizeof(*device));
	if (device == NULL) {
		snprintf(why, whySize, "out of memory");
		return AVERROR(ENOMEM);
	}
	atomic_init(&device->references, 1);
	device->fd = open(RPIVID_DEVICE_PATH, O_RDWR | O_CLOEXEC);
	if (device->fd < 0) {
		ret = AVERROR(errno);
		snprintf(why, whySize, "%s: %s", RPIVID_DEVICE_PATH, strerror(errno));
		free(device);
		return ret;
	}
	ret = control(device, RPIVID_GET_INFO, &device->info, sizeof(device->info));
	if (ret < 0 || device->info.api_version != RPIVID_API_VERSION
		|| (device->info.flags & RPIVID_INFO_BROKEN) != 0) {
		if (ret < 0)
			snprintf(why, whySize, "%s: %s", RPIVID_DEVICE_PATH, av_err2str(ret));
		else if ((device->info.flags & RPIVID_INFO_BROKEN) != 0)
			snprintf(why, whySize, "the block stopped responding earlier");
		else {
			snprintf(why, whySize, "driver interface %u, want %u",
				(unsigned)device->info.api_version, RPIVID_API_VERSION);
		}
		close(device->fd);
		free(device);
		return ret < 0 ? ret : AVERROR(ENODEV);
	}

	*_device = device;
	return 0;
}


RpividDevice*
ff_rpivid_device_ref(RpividDevice* device)
{
	atomic_fetch_add(&device->references, 1);
	return device;
}


void
ff_rpivid_device_unref(RpividDevice* device)
{
	if (device == NULL || atomic_fetch_sub(&device->references, 1) != 1)
		return;
	/* the driver frees the buffers still open with the file */
	close(device->fd);
	free(device);
}


uint32_t
ff_rpivid_device_clock_rate(const RpividDevice* device)
{
	return device->info.clock_rate;
}


int
ff_rpivid_device_create_bitstream(RpividDevice* device, size_t size,
	RpividBitstream* bitstream)
{
	rpivid_create_buffer args;
	int ret;

	memset(&args, 0, sizeof(args));
	args.size = size;
	ret = control(device, RPIVID_CREATE_BUFFER, &args, sizeof(args));
	if (ret < 0)
		return ret;
	bitstream->handle = args.handle;
	bitstream->data = (uint8_t*)(uintptr_t)args.address;
	bitstream->size = size;
	return 0;
}


int
ff_rpivid_device_create_picture(RpividDevice* device, uint32_t width,
	uint32_t height, uint32_t bit_depth, int motion_vectors,
	RpividPicture* picture)
{
	rpivid_create_picture args;
	const char* uncached = getenv("FFMPEG_RPIVID_UNCACHED");
	int ret;

	memset(&args, 0, sizeof(args));
	args.width = width;
	args.height = height;
	args.bit_depth = bit_depth;
	args.flags = motion_vectors ? RPIVID_PICTURE_MOTION_VECTORS : 0;
	if (uncached != NULL && uncached[0] == '1')
		args.flags |= RPIVID_PICTURE_UNCACHED;
	ret = control(device, RPIVID_CREATE_PICTURE, &args, sizeof(args));
	if (ret < 0)
		return ret;
	picture->handle = args.handle;
	picture->luma = (const uint8_t*)(uintptr_t)(args.address
		+ args.luma_offset);
	picture->chroma = (const uint8_t*)(uintptr_t)(args.address
		+ args.chroma_offset);
	picture->luma_column_stride = args.luma_column_stride;
	picture->chroma_column_stride = args.chroma_column_stride;
	return 0;
}


void
ff_rpivid_device_delete(RpividDevice* device, uint32_t handle)
{
	rpivid_delete_buffer args;

	memset(&args, 0, sizeof(args));
	args.handle = handle;
	control(device, RPIVID_DELETE_BUFFER, &args, sizeof(args));
}


int
ff_rpivid_device_submit(RpividDevice* device, const RpividJob* job,
	uint64_t* _id)
{
	rpivid_decode args;
	int ret, i;

	memset(&args, 0, sizeof(args));
	args.commands = (uint64_t)(uintptr_t)job->commands;
	args.command_count = job->command_count;
	args.bitstream = job->bitstream;
	args.output = job->output;
	args.collocated = job->collocated;
	for (i = 0; i < RPIVID_REFERENCE_SLOTS; i++)
		args.references[i] = job->references[i];
	args.log2_ctb_size = job->log2_ctb_size;
	args.config2 = job->config2;
	args.current_poc = (uint32_t)job->current_poc;

#ifdef __aarch64__
	/* the bitstream buffer is write-combining and the block a non-coherent
	   bus master: the slices reach memory before the driver starts it, on
	   whichever CPU it runs */
	__asm__ volatile("dsb sy" ::: "memory");
#endif
	ret = control(device, RPIVID_SUBMIT, &args, sizeof(args));
	*_id = args.job;
	return ret;
}


int
ff_rpivid_device_wait(RpividDevice* device, uint64_t id, int64_t timeout,
	RpividResult* result)
{
	rpivid_wait args;
	int ret;

	memset(&args, 0, sizeof(args));
	args.job = id;
	args.timeout = timeout;
	ret = control(device, RPIVID_WAIT, &args, sizeof(args));
	if (ret == AVERROR(B_WOULD_BLOCK) || ret == AVERROR(B_TIMED_OUT))
		return AVERROR(EAGAIN);
	if (ret < 0)
		return ret;
	/* status_t values are negative errno values on Haiku */
	result->result = args.result == B_OK ? 0 : AVERROR(args.result);
	result->status = args.status;
	result->command_status = args.command_status;
	result->phase1_runs = args.phase1_runs;
	result->queue_time = args.queue_time;
	result->phase1_time = args.phase1_time;
	result->phase2_time = args.phase2_time;
	return 0;
}


#else /* !__HAIKU__ */


int
ff_rpivid_device_open(RpividDevice** _device, char* why, size_t whySize)
{
	*_device = NULL;
	snprintf(why, whySize, "the rpivid block is driven on Haiku only");
	return AVERROR(ENOSYS);
}


RpividDevice*
ff_rpivid_device_ref(RpividDevice* device)
{
	return device;
}


void
ff_rpivid_device_unref(RpividDevice* device)
{
}


uint32_t
ff_rpivid_device_clock_rate(const RpividDevice* device)
{
	return 0;
}


int
ff_rpivid_device_create_bitstream(RpividDevice* device, size_t size,
	RpividBitstream* bitstream)
{
	return AVERROR(ENOSYS);
}


int
ff_rpivid_device_create_picture(RpividDevice* device, uint32_t width,
	uint32_t height, uint32_t bit_depth, int motion_vectors,
	RpividPicture* picture)
{
	return AVERROR(ENOSYS);
}


void
ff_rpivid_device_delete(RpividDevice* device, uint32_t handle)
{
}


int
ff_rpivid_device_submit(RpividDevice* device, const RpividJob* job,
	uint64_t* _id)
{
	return AVERROR(ENOSYS);
}


int
ff_rpivid_device_wait(RpividDevice* device, uint64_t id, int64_t timeout,
	RpividResult* result)
{
	return AVERROR(ENOSYS);
}


#endif /* __HAIKU__ */
