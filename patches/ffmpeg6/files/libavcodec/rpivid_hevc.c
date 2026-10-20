/*
 * Copyright 2026, Haiku, Inc. All rights reserved.
 * Distributed under the terms of the MIT License.
 */


/*	FFmpeg's HEVC decoder with the rpivid block (see rpivid_hevc.h).

	What the block needs is what V4L2's stateless HEVC controls carry: the
	active SPS and PPS, each slice segment's header fields and data, the
	reference lists, the collocated picture. HEVCContext has all of it; this
	fills the parameters of rpivid_cmd.h from it, and the driver
	(rpivid_device.h) decodes.

	Per picture: picture_ok() takes a picture buffer from the pool for the
	frame's hwaccel private data, where it stays for as long as hevcdec.c
	keeps the frame (as a reference or for output). decode_slice() copies
	each slice segment's NAL unit into the bitstream buffer and adds its
	commands; end_frame() submits the picture to the block.

	The block works while the CPU goes on: a picture is converted into the
	frame hevcdec.c allocated (SAND to planar) in the end_frame() of the
	picture after it, while the block decodes that one - so one picture is
	pending, and its frame must not reach the caller before it is converted.
	end_frame() converts the picture at once when hevcdec.c outputs it in the
	same call (no reordering), ff_rpivid_hevc_drain() before hevcdec.c
	outputs the last pictures, uninit when the hwaccel goes. Both bitstream
	buffers alternate: the block reads one while the CPU fills the other.
	FFMPEG_RPIVID_SYNC=1 decodes each picture before end_frame() returns, as
	a reference for measurements.
*/


#include <inttypes.h>
#include <string.h>

#include "libavutil/mem.h"
#include "libavutil/thread.h"
#include "libavutil/time.h"

#include "avcodec.h"
#include "decode.h"
#include "get_bits.h"
#include "hevcdec.h"
#include "hwaccel_internal.h"
#include "internal.h"
#include "refstruct.h"

#include "rpivid_cmd.h"
#include "rpivid_device.h"
#include "rpivid_hevc.h"
#include "rpivid_sand.h"


#define MIN_BITSTREAM_SIZE	(256 * 1024)
/* SAND to planar in bands of at least this many rows, one per thread */
#define MIN_CONVERT_ROWS	64


/* A picture buffer of the driver. Held by the frame it belongs to and, until
   it is converted, by the pending picture. */
typedef struct RpividBuffer {
	RpividPicture			picture;
	struct RpividBuffer*	next;
	int						references;
	uint64_t				job;	/* the submitted picture that writes it */
} RpividBuffer;

/* The picture buffers of one stream geometry. The hwaccel and every frame
   holding a buffer have a reference: frames may outlive the hwaccel. */
typedef struct RpividPool {
	AVMutex			lock;
	int				references;
	RpividDevice*	device;
	uint32_t		width;
	uint32_t		height;
	uint32_t		bit_depth;
	int				motion_vectors;
	RpividBuffer*	free;
	int				count;
} RpividPool;

/* The hwaccel_picture_private of an HEVCFrame */
typedef struct RpividFrame {
	RpividPool*		pool;
	RpividBuffer*	buffer;
	int				submitted;
		/* the block decodes buffer before any later picture: usable as a
		   reference */
	int				has_mv;		/* and its motion vectors */
} RpividFrame;

/* The picture the block decodes, to be converted into its frame */
typedef struct RpividPending {
	RpividBuffer*	buffer;
	AVFrame*		frame;		/* a reference to the frame's buffers */
	uint64_t		job;
} RpividPending;

typedef struct RpividContext {
	RpividDevice*		device;
	RpividPool*			pool;
	int					level;
	int					sync;
	int					convert_threads;
	RpividBitstream		bitstreams[2];
	uint64_t			bitstream_jobs[2];	/* the last picture reading each */
	int					bitstream_index;
	size_t				bitstream_used;
	RpividPending		pending;
	RpividCommands		commands;
	RpividPictureParams	picture;
	uint8_t				scaling[RPIVID_SCALING_FACTOR_BYTES];

	/* the picture's reference slots, in first-use order over its slices */
	const HEVCFrame*	slots[RPIVID_REFERENCE_SLOTS];
	uint32_t			slot_handles[RPIVID_REFERENCE_SLOTS];
	int					slot_count;
	int					write_mv;
	int					slices;
	int					one_slice_segment;
	const char*			error;
	int					failed;

	uint64_t			pictures;
	uint64_t			phase1_time;	/* microseconds */
	uint64_t			phase2_time;
	uint64_t			wait_time;		/* the CPU waited for the block */
	uint64_t			convert_time;
	uint32_t			missing_references;
	uint32_t			phase1_reruns;
	uint32_t			late_failures;
} RpividContext;


static const FFHWAccel ff_hevc_rpivid_hwaccel;


//	#pragma mark - picture buffers


static RpividPool*
pool_create(RpividDevice* device, const HEVCSPS* sps)
{
	RpividPool* pool = av_mallocz(sizeof(*pool));
	if (pool == NULL)
		return NULL;
	ff_mutex_init(&pool->lock, NULL);
	pool->references = 1;
	pool->device = ff_rpivid_device_ref(device);
	pool->width = sps->width;
	pool->height = sps->height;
	pool->bit_depth = sps->bit_depth;
	pool->motion_vectors = sps->sps_temporal_mvp_enabled_flag;
	return pool;
}


static RpividPool*
pool_ref(RpividPool* pool)
{
	ff_mutex_lock(&pool->lock);
	pool->references++;
	ff_mutex_unlock(&pool->lock);
	return pool;
}


static void
pool_unref(RpividPool* pool)
{
	RpividBuffer* buffer;
	int last;

	if (pool == NULL)
		return;
	ff_mutex_lock(&pool->lock);
	last = --pool->references == 0;
	ff_mutex_unlock(&pool->lock);
	if (!last)
		return;

	/* every buffer is back: each one handed out holds a reference */
	while ((buffer = pool->free) != NULL) {
		pool->free = buffer->next;
		ff_rpivid_device_delete(pool->device, buffer->picture.handle);
		av_free(buffer);
	}
	ff_rpivid_device_unref(pool->device);
	ff_mutex_destroy(&pool->lock);
	av_free(pool);
}


static RpividBuffer*
pool_get(RpividPool* pool)
{
	RpividBuffer* buffer;

	ff_mutex_lock(&pool->lock);
	buffer = pool->free;
	if (buffer != NULL)
		pool->free = buffer->next;
	ff_mutex_unlock(&pool->lock);
	if (buffer != NULL) {
		buffer->next = NULL;
		buffer->references = 1;
		buffer->job = 0;
		return buffer;
	}

	buffer = av_mallocz(sizeof(*buffer));
	if (buffer == NULL)
		return NULL;
	buffer->references = 1;
	if (ff_rpivid_device_create_picture(pool->device, pool->width, pool->height,
			pool->bit_depth, pool->motion_vectors, &buffer->picture) < 0) {
		av_free(buffer);
		return NULL;
	}
	ff_mutex_lock(&pool->lock);
	pool->count++;
	ff_mutex_unlock(&pool->lock);
	return buffer;
}


static void
buffer_ref(RpividPool* pool, RpividBuffer* buffer)
{
	ff_mutex_lock(&pool->lock);
	buffer->references++;
	ff_mutex_unlock(&pool->lock);
}


/* The last reference puts the buffer back into the pool. Pictures still in
   the block may use it: only a later picture can get it from the pool, and
   the block decodes that one after them. */
static void
buffer_unref(RpividPool* pool, RpividBuffer* buffer)
{
	ff_mutex_lock(&pool->lock);
	if (--buffer->references == 0) {
		buffer->next = pool->free;
		pool->free = buffer;
	}
	ff_mutex_unlock(&pool->lock);
}


static void
rpivid_free_frame(FFRefStructOpaque opaque, void* data)
{
	RpividFrame* frame = data;

	if (frame->buffer != NULL)
		buffer_unref(frame->pool, frame->buffer);
	pool_unref(frame->pool);
}


//	#pragma mark - what the block takes


#define REFUSE(...) \
	do { \
		snprintf(why, whySize, __VA_ARGS__); \
		return -1; \
	} while (0)


static int
sps_supported(const HEVCSPS* sps, int level, char* why, size_t whySize)
{
	if (sps->chroma_format_idc != 1 || sps->separate_colour_plane_flag)
		REFUSE("chroma format %d (the block decodes 4:2:0)", sps->chroma_format_idc);
	if (sps->bit_depth != sps->bit_depth_chroma
		|| (sps->bit_depth != 8 && sps->bit_depth != 10)) {
		REFUSE("bit depth %d/%d (the block decodes 8 or 10 bit)", sps->bit_depth,
			sps->bit_depth_chroma);
	}
	if (sps->width < 32 || sps->height < 32 || sps->width > 4096
		|| sps->height > 4096) {
		REFUSE("picture size %dx%d (the block decodes 32 to 4096)", sps->width,
			sps->height);
	}
	if (sps->log2_ctb_size < 4 || sps->log2_ctb_size > 6
		|| sps->log2_max_trafo_size > 5) {
		REFUSE("CTB size %d, transform blocks up to %d", 1 << sps->log2_ctb_size,
			1 << sps->log2_max_trafo_size);
	}
	if (sps->transform_skip_rotation_enabled_flag
		|| sps->transform_skip_context_enabled_flag
		|| sps->implicit_rdpcm_enabled_flag || sps->explicit_rdpcm_enabled_flag
		|| sps->extended_precision_processing_flag
		|| sps->intra_smoothing_disabled_flag
		|| sps->high_precision_offsets_enabled_flag
		|| sps->persistent_rice_adaptation_enabled_flag
		|| sps->cabac_bypass_alignment_enabled_flag) {
		REFUSE("range extension coding tools");
	}
	if (sps->sps_scc_extension_flag || sps->sps_multilayer_extension_flag
		|| sps->sps_3d_extension_flag) {
		REFUSE("screen content, multilayer or 3D extensions");
	}

	/* what the block's programming has, but no test stream proved yet */
	if (level < RPIVID_ALL) {
		if (sps->log2_ctb_size == 4)
			REFUSE("16x16 CTBs (not verified on the block: FFMPEG_RPIVID=2)");
		if (sps->pcm_enabled_flag)
			REFUSE("PCM (not verified on the block: FFMPEG_RPIVID=2)");
		if (sps->long_term_ref_pics_present_flag) {
			REFUSE("long-term reference pictures (not verified on the block: "
				"FFMPEG_RPIVID=2)");
		}
	}
	return 0;
}


static int
pps_supported(const HEVCPPS* pps, int level, char* why, size_t whySize)
{
	if (pps->cross_component_prediction_enabled_flag
		|| pps->chroma_qp_offset_list_enabled_flag
		|| pps->log2_sao_offset_scale_luma || pps->log2_sao_offset_scale_chroma
		|| pps->log2_max_transform_skip_block_size > 2) {
		REFUSE("range extension coding tools (PPS)");
	}
	if (pps->pps_scc_extension_flag || pps->pps_multilayer_extension_flag
		|| pps->pps_3d_extension_flag) {
		REFUSE("screen content, multilayer or 3D extensions (PPS)");
	}
	if (pps->tiles_enabled_flag
		&& (pps->num_tile_columns > RPIVID_MAX_TILE_COLUMNS
			|| pps->num_tile_rows > RPIVID_MAX_TILE_ROWS
			|| (pps->entropy_coding_sync_enabled_flag
				&& (pps->num_tile_columns > 1 || pps->num_tile_rows > 1)))) {
		REFUSE("%dx%d tiles%s", pps->num_tile_columns, pps->num_tile_rows,
			pps->entropy_coding_sync_enabled_flag ? " with wavefronts" : "");
	}

	if (level < RPIVID_ALL) {
		if (pps->tiles_enabled_flag)
			REFUSE("tiles (not verified on the block: FFMPEG_RPIVID=2)");
		if (pps->dependent_slice_segments_enabled_flag) {
			REFUSE("dependent slice segments (not verified on the block: "
				"FFMPEG_RPIVID=2)");
		}
		if (pps->transquant_bypass_enable_flag) {
			REFUSE("lossless coding units (not verified on the block: "
				"FFMPEG_RPIVID=2)");
		}
		if (pps->constrained_intra_pred_flag) {
			REFUSE("constrained intra prediction (not verified on the block: "
				"FFMPEG_RPIVID=2)");
		}
	}
	return 0;
}


//	#pragma mark - attach


int
ff_rpivid_hevc_active(const AVCodecContext* avctx)
{
	return avctx->hwaccel == &ff_hevc_rpivid_hwaccel.p;
}


int
ff_rpivid_hevc_failed(const AVCodecContext* avctx)
{
	const RpividContext* ctx = avctx->internal->hwaccel_priv_data;
	return ff_rpivid_hevc_active(avctx) && ctx != NULL && ctx->failed;
}


int
ff_rpivid_hevc_attach(AVCodecContext* avctx, int level)
{
	const HEVCContext* s = avctx->priv_data;
	const HEVCSPS* sps = s->ps.sps;
	RpividContext* ctx;
	char why[192];
	int i;

	if (level <= RPIVID_OFF || sps == NULL || avctx->hwaccel != NULL)
		return -1;
	if (sps_supported(sps, level, why, sizeof(why)) < 0)
		goto refuse;
	/* the PPSs of this SPS so far; one that comes later is checked by its
	   first picture */
	for (i = 0; i < HEVC_MAX_PPS_COUNT; i++) {
		const HEVCPPS* pps = s->ps.pps_list[i];
		if (pps != NULL && s->ps.sps_list[pps->sps_id] == sps
			&& pps_supported(pps, level, why, sizeof(why)) < 0) {
			goto refuse;
		}
	}

	ctx = av_mallocz(sizeof(*ctx));
	if (ctx == NULL)
		return AVERROR(ENOMEM);
	if (ff_rpivid_device_open(&ctx->device, why, sizeof(why)) < 0) {
		av_free(ctx);
		goto refuse;
	}
	ctx->pool = pool_create(ctx->device, sps);
	if (ctx->pool == NULL) {
		ff_rpivid_device_unref(ctx->device);
		av_free(ctx);
		return AVERROR(ENOMEM);
	}
	ctx->level = level;
	ctx->sync = getenv("FFMPEG_RPIVID_SYNC") != NULL
		&& !strcmp(getenv("FFMPEG_RPIVID_SYNC"), "1");
	// One conversion thread by default: on the Pi 4 it is as fast as four
	// and costs a third of the CPU time (1080p 20 Mbit/s: 118.9 fps at
	// 3.6 ms CPU per frame vs 110.1 fps at 11.8 ms), as the conversion is
	// bound by memory and runs alongside the block's decode anyway
	ctx->convert_threads = 1;
	if (getenv("FFMPEG_RPIVID_CONVERT_THREADS") != NULL)
		ctx->convert_threads = atoi(getenv("FFMPEG_RPIVID_CONVERT_THREADS"));
	if (!(avctx->active_thread_type & FF_THREAD_SLICE) || ctx->convert_threads < 1
		|| ctx->sync) {
		ctx->convert_threads = 1;
	}
	ff_rpivid_commands_init(&ctx->commands);

	avctx->internal->hwaccel_priv_data = ctx;
	avctx->hwaccel = &ff_hevc_rpivid_hwaccel.p;
	av_log(avctx, AV_LOG_INFO, "rpivid: hardware HEVC decode, %dx%d %d-bit, "
		"clock %" PRIu32 " MHz\n", sps->width, sps->height, sps->bit_depth,
		ff_rpivid_device_clock_rate(ctx->device) / 1000000);
	return 0;

refuse:
	av_log(avctx, AV_LOG_INFO, "rpivid: CPU decode: %s\n", why);
	return -1;
}


static void finish_pending(AVCodecContext* avctx, HEVCContext* s, int threaded);


static int
rpivid_uninit(AVCodecContext* avctx)
{
	RpividContext* ctx = avctx->internal->hwaccel_priv_data;
	int i;

	if (ctx == NULL)
		return 0;
	/* hevcdec.c may output the pending picture later (it leaves the block
	   for the CPU decoder), or not (it is closing: its threads are gone) */
	finish_pending(avctx, avctx->priv_data, 0);
	if (ctx->pictures > 0) {
		av_log(avctx, AV_LOG_INFO, "rpivid: %" PRIu64 " pictures on the block, "
			"phase 1 %.2f ms, phase 2 %.2f ms, the CPU waited %.2f ms, SAND to "
			"planar %.2f ms (%d threads), %s; %" PRIu32 " phase-1 reruns, %" PRIu32
			" missing references, %d picture buffers\n", ctx->pictures,
			ctx->phase1_time / 1000.0 / ctx->pictures,
			ctx->phase2_time / 1000.0 / ctx->pictures,
			ctx->wait_time / 1000.0 / ctx->pictures,
			ctx->convert_time / 1000.0 / ctx->pictures, ctx->convert_threads,
			ctx->sync ? "synchronous" : "pipelined", ctx->phase1_reruns,
			ctx->missing_references, ctx->pool != NULL ? ctx->pool->count : 0);
	}
	ff_rpivid_commands_free(&ctx->commands);
	for (i = 0; i < 2; i++) {
		if (ctx->bitstreams[i].handle != 0)
			ff_rpivid_device_delete(ctx->device, ctx->bitstreams[i].handle);
	}
	pool_unref(ctx->pool);
	ff_rpivid_device_unref(ctx->device);
	ctx->pool = NULL;
	ctx->device = NULL;
	return 0;
}


//	#pragma mark - converting


typedef struct RpividConvert {
	const RpividPicture*	picture;
	AVFrame*				frame;
	uint32_t				width;
	uint32_t				height;
	uint32_t				bit_depth;
	uint32_t				band_rows;
} RpividConvert;


static int
convert_band(AVCodecContext* avctx, void* data, int band, int thread)
{
	const RpividConvert* job = data;
	const RpividPicture* picture = job->picture;
	AVFrame* out = job->frame;
	const uint32_t y0 = band * job->band_rows;
	const uint32_t y1 = FFMIN(y0 + job->band_rows, job->height);

	if (y0 >= y1)
		return 0;
	if (job->bit_depth == 8) {
		ff_rpivid_sand8_to_planar(out->data[0], out->linesize[0], out->data[1],
			out->linesize[1], out->data[2], out->linesize[2], picture->luma,
			picture->luma_column_stride, picture->chroma,
			picture->chroma_column_stride, job->width, job->height, y0, y1);
	} else {
		ff_rpivid_sand10_to_planar(out->data[0], out->linesize[0], out->data[1],
			out->linesize[1], out->data[2], out->linesize[2], picture->luma,
			picture->luma_column_stride, picture->chroma,
			picture->chroma_column_stride, job->width, job->height, y0, y1);
	}
	return 0;
}


/* SAND to planar, in row bands on the decoder's slice threads (which the
   block leaves idle) */
static void
convert(AVCodecContext* avctx, RpividContext* ctx, const RpividBuffer* buffer,
	AVFrame* frame, int threaded)
{
	RpividConvert job;
	int bands = threaded ? ctx->convert_threads : 1;

	job.picture = &buffer->picture;
	job.frame = frame;
	job.width = ctx->pool->width;
	job.height = ctx->pool->height;
	job.bit_depth = ctx->pool->bit_depth;
	bands = FFMAX(1, FFMIN(bands, (int)(job.height / MIN_CONVERT_ROWS)));
	job.band_rows = FFALIGN((job.height + bands - 1) / bands, 2);
	if (bands > 1)
		avctx->execute2(avctx, convert_band, &job, NULL, bands);
	else
		convert_band(avctx, &job, 0, 0);
}


/* The block failed a picture after its submit: it and every frame showing it
   are marked, and hevcdec.c drops them (rpivid_leave()) */
static void
mark_failed(HEVCContext* s, const AVFrame* frame)
{
	int i;

	if (s == NULL)
		return;
	for (i = 0; i < FF_ARRAY_ELEMS(s->DPB); i++) {
		AVFrame* other = s->DPB[i].frame;
		if (other != NULL && other->buf[0] != NULL
			&& other->buf[0]->buffer == frame->buf[0]->buffer) {
			other->flags |= AV_FRAME_FLAG_CORRUPT;
			other->decode_error_flags |= FF_DECODE_ERROR_INVALID_BITSTREAM;
		}
	}
	if (s->output_frame != NULL && s->output_frame->buf[0] != NULL
		&& s->output_frame->buf[0]->buffer == frame->buf[0]->buffer) {
		s->output_frame->flags |= AV_FRAME_FLAG_CORRUPT;
		s->output_frame->decode_error_flags |= FF_DECODE_ERROR_INVALID_BITSTREAM;
	}
}


/* Waits for the pending picture and converts it into its frame. A picture
   the block failed sets ctx->failed. */
static void
finish_pending(AVCodecContext* avctx, HEVCContext* s, int threaded)
{
	RpividContext* ctx = avctx->internal->hwaccel_priv_data;
	RpividPending* pending = &ctx->pending;
	RpividResult result;
	int64_t start;
	int ret;

	if (pending->buffer == NULL)
		return;

	start = av_gettime_relative();
	ret = ff_rpivid_device_wait(ctx->device, pending->job, -1, &result);
	ctx->wait_time += av_gettime_relative() - start;
	if (ret == 0)
		ret = result.result;
	if (ret == 0) {
		start = av_gettime_relative();
		convert(avctx, ctx, pending->buffer, pending->frame, threaded);
		ctx->convert_time += av_gettime_relative() - start;
		ctx->pictures++;
		ctx->phase1_time += result.phase1_time;
		ctx->phase2_time += result.phase2_time;
		if (result.phase1_runs > 1)
			ctx->phase1_reruns += result.phase1_runs - 1;
		if (ctx->pictures == 1) {
			av_log(avctx, AV_LOG_INFO, "rpivid: first picture on the block: %"
				PRIu64 " us (queued %" PRIu64 ", phase 1 %" PRIu64 ", phase 2 %"
				PRIu64 ")\n", result.queue_time + result.phase1_time
					+ result.phase2_time, result.queue_time, result.phase1_time,
				result.phase2_time);
		}
	} else {
		av_log(avctx, AV_LOG_ERROR, "rpivid: the block failed a picture: %s "
			"(CFSTATUS %" PRIu32 ", STATUS %#" PRIx32 ", %" PRIu32 " phase-1 "
			"runs)\n", av_err2str(ret), result.command_status, result.status,
			result.phase1_runs);
		mark_failed(s, pending->frame);
		ctx->late_failures++;
		ctx->failed = 1;
	}

	buffer_unref(ctx->pool, pending->buffer);
	av_frame_free(&pending->frame);
	memset(pending, 0, sizeof(*pending));
}


void
ff_rpivid_hevc_drain(AVCodecContext* avctx)
{
	if (ff_rpivid_hevc_active(avctx))
		finish_pending(avctx, avctx->priv_data, 1);
}


//	#pragma mark - per picture


static void
fill_picture_params(RpividContext* ctx, const HEVCContext* s)
{
	const HEVCSPS* sps = s->ps.sps;
	const HEVCPPS* pps = s->ps.pps;
	RpividPictureParams* picture = &ctx->picture;
	unsigned i;

	memset(picture, 0, sizeof(*picture));
	picture->width = sps->width;
	picture->height = sps->height;
	picture->bit_depth = sps->bit_depth;
	picture->chroma_format_idc = sps->chroma_format_idc;
	picture->log2_min_cb_size = sps->log2_min_cb_size;
	picture->log2_ctb_size = sps->log2_ctb_size;
	picture->log2_min_tb_size = sps->log2_min_tb_size;
	picture->log2_max_tb_size = sps->log2_max_trafo_size;
	picture->max_transform_depth_intra = sps->max_transform_hierarchy_depth_intra;
	picture->max_transform_depth_inter = sps->max_transform_hierarchy_depth_inter;
	picture->amp = sps->amp_enabled_flag;
	picture->strong_intra_smoothing = sps->sps_strong_intra_smoothing_enable_flag;
	picture->pcm = sps->pcm_enabled_flag;
	if (picture->pcm) {
		picture->pcm_bit_depth = sps->pcm.bit_depth;
		picture->pcm_bit_depth_chroma = sps->pcm.bit_depth_chroma;
		picture->log2_min_pcm_cb_size = sps->pcm.log2_min_pcm_cb_size;
		picture->log2_max_pcm_cb_size = sps->pcm.log2_max_pcm_cb_size;
		picture->pcm_loop_filter_disabled = sps->pcm.loop_filter_disable_flag;
	}

	picture->scaling_list = sps->scaling_list_enable_flag;
	if (picture->scaling_list) {
		/* FFmpeg's lists are in raster order; the 32x32 ones are matrices 0
		   and 3 (intra and inter luma) */
		const ScalingList* list = pps->scaling_list_data_present_flag
			? &pps->scaling_list : &sps->scaling_list;
		uint8_t list4x4[6][16], list8x8[6][64], list16x16[6][64], dc16x16[6];
		uint8_t list32x32[2][64], dc32x32[2];

		for (i = 0; i < 6; i++) {
			memcpy(list4x4[i], list->sl[0][i], 16);
			memcpy(list8x8[i], list->sl[1][i], 64);
			memcpy(list16x16[i], list->sl[2][i], 64);
			dc16x16[i] = list->sl_dc[0][i];
		}
		memcpy(list32x32[0], list->sl[3][0], 64);
		memcpy(list32x32[1], list->sl[3][3], 64);
		dc32x32[0] = list->sl_dc[1][0];
		dc32x32[1] = list->sl_dc[1][3];
		ff_rpivid_scaling_factors(ctx->scaling, list4x4, list8x8, list16x16,
			dc16x16, list32x32, dc32x32);
		picture->scaling_factors = ctx->scaling;
	}

	picture->cu_qp_delta = pps->cu_qp_delta_enabled_flag;
	picture->diff_cu_qp_delta_depth = pps->diff_cu_qp_delta_depth;
	picture->transquant_bypass = pps->transquant_bypass_enable_flag;
	picture->transform_skip = pps->transform_skip_enabled_flag;
	picture->sign_data_hiding = pps->sign_data_hiding_flag;
	picture->constrained_intra_pred = pps->constrained_intra_pred_flag;
	picture->cb_qp_offset = pps->cb_qp_offset;
	picture->cr_qp_offset = pps->cr_qp_offset;
	picture->weighted_pred = pps->weighted_pred_flag;
	picture->weighted_bipred = pps->weighted_bipred_flag;
	picture->entropy_coding_sync = pps->entropy_coding_sync_enabled_flag;
	picture->tiles = pps->tiles_enabled_flag;
	picture->loop_filter_across_tiles = pps->loop_filter_across_tiles_enabled_flag;
	picture->log2_parallel_merge_level = pps->log2_parallel_merge_level;
	if (picture->tiles) {
		picture->tile_columns = pps->num_tile_columns;
		picture->tile_rows = pps->num_tile_rows;
		for (i = 0; i <= picture->tile_columns; i++)
			picture->column_bd[i] = pps->col_bd[i];
		for (i = 0; i <= picture->tile_rows; i++)
			picture->row_bd[i] = pps->row_bd[i];
		picture->ctb_addr_rs_to_ts = pps->ctb_addr_rs_to_ts;
		picture->ctb_addr_ts_to_rs = pps->ctb_addr_ts_to_rs;
	} else {
		picture->tile_columns = picture->tile_rows = 1;
		picture->column_bd[1] = sps->ctb_width;
		picture->row_bd[1] = sps->ctb_height;
	}
	picture->slice_temporal_mvp = s->sh.slice_temporal_mvp_enabled_flag;
	picture->one_slice_segment = ctx->one_slice_segment;
}


int
ff_rpivid_hevc_picture_ok(AVCodecContext* avctx)
{
	HEVCContext* s = avctx->priv_data;
	RpividContext* ctx = avctx->internal->hwaccel_priv_data;
	RpividFrame* frame = s->ref->hwaccel_picture_private;
	RpividBitstream* bitstream;
	size_t needed = 64;
	char why[192];
	int i, segments = 0, pictures = 0;

	if (pps_supported(s->ps.pps, ctx->level, why, sizeof(why)) < 0) {
		av_log(avctx, AV_LOG_WARNING, "rpivid: picture POC %d: %s\n", s->poc, why);
		return -1;
	}
	if (frame == NULL || frame->pool != NULL) {
		av_log(avctx, AV_LOG_WARNING, "rpivid: picture POC %d has no fresh "
			"frame data\n", s->poc);
		return -1;
	}

	/* the access unit's slice segments: their NAL units go to the bitstream
	   buffer, each at a 64-byte boundary */
	for (i = 0; i < s->pkt.nb_nals; i++) {
		const H2645NAL* nal = &s->pkt.nals[i];
		if (nal->nuh_layer_id != 0 || nal->type > HEVC_NAL_RSV_VCL31)
			continue;
		segments++;
		needed += nal->raw_size + 64;
		/* first_slice_segment_in_pic_flag, after the NAL unit header */
		if (nal->size > 2 && (nal->data[2] & 0x80) != 0)
			pictures++;
	}
	ctx->one_slice_segment = segments <= (pictures > 0 ? pictures : 1);

	/* the other bitstream buffer: the block may still read the last one; this
	   one's picture is done unless it is the pending one */
	ctx->bitstream_index ^= 1;
	bitstream = &ctx->bitstreams[ctx->bitstream_index];
	if (ctx->pending.buffer != NULL
		&& ctx->pending.job == ctx->bitstream_jobs[ctx->bitstream_index]) {
		finish_pending(avctx, s, 1);
		if (ctx->failed)
			return RPIVID_EARLIER_FAILED;
	}
	if (bitstream->size < needed) {
		if (bitstream->handle != 0)
			ff_rpivid_device_delete(ctx->device, bitstream->handle);
		memset(bitstream, 0, sizeof(*bitstream));
		if (ff_rpivid_device_create_bitstream(ctx->device,
				FFMAX(needed + needed / 2, MIN_BITSTREAM_SIZE), bitstream) < 0) {
			memset(bitstream, 0, sizeof(*bitstream));
			av_log(avctx, AV_LOG_WARNING, "rpivid: no bitstream buffer of %zu "
				"bytes\n", needed);
			return -1;
		}
	}

	frame->buffer = pool_get(ctx->pool);
	if (frame->buffer == NULL) {
		av_log(avctx, AV_LOG_WARNING, "rpivid: no memory for another picture "
			"(%d held)\n", ctx->pool->count);
		return -1;
	}
	frame->pool = pool_ref(ctx->pool);
	return 0;
}


static int
rpivid_start_frame(AVCodecContext* avctx, const uint8_t* buffer, uint32_t size)
{
	const HEVCContext* s = avctx->priv_data;
	const HEVCSPS* sps = s->ps.sps;
	RpividContext* ctx = avctx->internal->hwaccel_priv_data;
	const unsigned type = s->nal_unit_type;

	fill_picture_params(ctx, s);
	ff_rpivid_commands_begin(&ctx->commands, &ctx->picture);
	ctx->bitstream_used = 0;
	ctx->slot_count = 0;
	ctx->slices = 0;
	ctx->error = NULL;
	ctx->failed = 0;
	/* keep the picture's motion vectors if a later picture may take it as
	   its collocated one: a reference picture's NAL unit type, or a sub-layer
	   below the highest */
	ctx->write_mv = sps->sps_temporal_mvp_enabled_flag
		&& ((type & ~0xeu) != 0 || sps->max_sub_layers - 1 >= s->temporal_id + 1);
	return 0;
}


/* The position in the raw NAL unit (emulation prevention bytes counted) of a
   position in its RBSP */
static uint32_t
raw_offset(const uint8_t* raw, uint32_t size, uint32_t rbspOffset)
{
	uint32_t position = 0, rbsp = 0, zeros = 0;

	while (rbsp < rbspOffset && position < size) {
		if (zeros >= 2 && raw[position] == 3) {
			zeros = 0;
			position++;
			continue;
		}
		zeros = raw[position] == 0 ? zeros + 1 : 0;
		position++;
		rbsp++;
	}
	return position;
}


/* The phase-2 slot of a reference picture */
static int
reference_slot(RpividContext* ctx, const HEVCFrame* reference)
{
	const RpividFrame* frame;
	int slot;

	for (slot = 0; slot < ctx->slot_count; slot++) {
		if (ctx->slots[slot] == reference)
			return slot;
	}
	if (ctx->slot_count == RPIVID_REFERENCE_SLOTS)
		return -1;

	slot = ctx->slot_count++;
	ctx->slots[slot] = reference;
	frame = reference != NULL ? reference->hwaccel_picture_private : NULL;
	if (frame != NULL && frame->buffer != NULL && frame->submitted)
		ctx->slot_handles[slot] = frame->buffer->picture.handle;
	else {
		/* a picture the stream lost (hevcdec.c made it up) or the block does
		   not decode: the output picture, as Linux does */
		ctx->slot_handles[slot] = 0;
		ctx->missing_references++;
	}
	return slot;
}


static int
rpivid_decode_slice(AVCodecContext* avctx, const uint8_t* buffer,
	uint32_t size)
{
	const HEVCContext* s = avctx->priv_data;
	const SliceHeader* sh = &s->sh;
	const HEVCPPS* pps = s->ps.pps;
	RpividContext* ctx = avctx->internal->hwaccel_priv_data;
	const RpividBitstream* bitstream = &ctx->bitstreams[ctx->bitstream_index];
	RpividSliceParams slice;
	uint32_t dataOffset, length, offset;
	unsigned list, i;

	if (ctx->error != NULL)
		return 0;

	/* slice_segment_data() follows the header's byte_alignment(): the RBSP
	   position after the header, its stop bit, rounded up - in the raw NAL
	   unit, as the block removes the emulation prevention bytes itself */
	dataOffset = raw_offset(buffer, size,
		(get_bits_count(&s->HEVClc->gb) + 1 + 7) / 8);
	length = size;
	while (length > dataOffset && buffer[length - 1] == 0)
		length--;
	offset = FFALIGN(ctx->bitstream_used, 64);
	if (dataOffset >= length || offset + length > bitstream->size) {
		ctx->error = "slice data out of range";
		return 0;
	}
	memcpy(bitstream->data + offset, buffer, length);
	ctx->bitstream_used = offset + length;

	memset(&slice, 0, sizeof(slice));
	slice.data_offset = offset + dataOffset;
	slice.data_size = length - dataOffset;
	slice.segment_address = sh->slice_segment_addr;
	slice.dependent = sh->dependent_slice_segment_flag;
	slice.type = sh->slice_type;
	slice.qp = sh->slice_qp;
	slice.cb_qp_offset = sh->slice_cb_qp_offset;
	slice.cr_qp_offset = sh->slice_cr_qp_offset;
	slice.sao_luma = sh->slice_sample_adaptive_offset_flag[0];
	slice.sao_chroma = sh->slice_sample_adaptive_offset_flag[1];
	slice.mvd_l1_zero = sh->mvd_l1_zero_flag;
	slice.cabac_init = sh->cabac_init_flag;
	slice.collocated_from_l0 = sh->collocated_list == L0;
	slice.poc = s->poc;
	slice.beta_offset_div2 = sh->beta_offset / 2;
	slice.tc_offset_div2 = sh->tc_offset / 2;
	slice.deblocking_disabled = sh->disable_deblocking_filter_flag;
	slice.loop_filter_across_slices
		= sh->slice_loop_filter_across_slices_enabled_flag;

	if (sh->slice_type != HEVC_SLICE_I) {
		const RefPicList* lists = s->ref->refPicList;

		slice.max_num_merge_cand = sh->max_num_merge_cand;
		slice.num_refs[0] = sh->nb_refs[L0];
		slice.num_refs[1] = sh->slice_type == HEVC_SLICE_B ? sh->nb_refs[L1] : 0;
		for (list = 0; list < 2; list++) {
			if (slice.num_refs[list] > 16 || (slice.num_refs[list] != 0
					&& (lists == NULL
						|| lists[list].nb_refs < slice.num_refs[list]))) {
				ctx->error = "reference lists shorter than the slice header's";
				return 0;
			}
			for (i = 0; i < slice.num_refs[list]; i++) {
				const int slot = reference_slot(ctx, lists[list].ref[i]);
				if (slot < 0) {
					ctx->error = "more than 16 reference pictures";
					return 0;
				}
				slice.ref_slot[list][i] = slot;
				slice.ref_poc[list][i] = lists[list].list[i];
				slice.ref_long_term[list][i] = lists[list].isLongTerm[i] != 0;
			}
		}
		if ((sh->slice_type == HEVC_SLICE_P && pps->weighted_pred_flag)
			|| (sh->slice_type == HEVC_SLICE_B && pps->weighted_bipred_flag)) {
			/* FFmpeg keeps the weights and the chroma offsets derived */
			slice.weighted = 1;
			slice.luma_log2_weight_denom = sh->luma_log2_weight_denom;
			slice.chroma_log2_weight_denom = sh->chroma_log2_weight_denom;
			for (i = 0; i < 16; i++) {
				slice.luma_weight[0][i] = sh->luma_weight_l0[i];
				slice.luma_offset[0][i] = sh->luma_offset_l0[i];
				slice.luma_weight[1][i] = sh->luma_weight_l1[i];
				slice.luma_offset[1][i] = sh->luma_offset_l1[i];
				for (list = 0; list < 2; list++) {
					slice.chroma_weight[0][i][list] = sh->chroma_weight_l0[i][list];
					slice.chroma_offset[0][i][list] = sh->chroma_offset_l0[i][list];
					slice.chroma_weight[1][i][list] = sh->chroma_weight_l1[i][list];
					slice.chroma_offset[1][i][list] = sh->chroma_offset_l1[i][list];
				}
			}
		}
	}

	if (ff_rpivid_commands_add_slice(&ctx->commands, &slice) < 0) {
		ctx->error = "slice commands";
		return 0;
	}
	ctx->slices++;
	return 0;
}


static int
rpivid_end_frame(AVCodecContext* avctx)
{
	HEVCContext* s = avctx->priv_data;
	const HEVCSPS* sps = s->ps.sps;
	RpividContext* ctx = avctx->internal->hwaccel_priv_data;
	RpividFrame* frame = s->ref->hwaccel_picture_private;
	AVFrame* out = s->ref->frame;
	RpividJob job;
	uint64_t id;
	int count = 0, i, ret;

	if (ctx->error == NULL && ctx->slices == 0)
		ctx->error = "no slices";
	if (ctx->error == NULL && (count = ff_rpivid_commands_end(&ctx->commands)) < 0)
		ctx->error = "slice commands";
	if (ctx->error == NULL && (frame == NULL || frame->buffer == NULL))
		ctx->error = "no picture buffer";
	if (ctx->error != NULL)
		goto fail;

	memset(&job, 0, sizeof(job));
	job.commands = ctx->commands.entries;
	job.command_count = count;
	job.bitstream = ctx->bitstreams[ctx->bitstream_index].handle;
	job.output = frame->buffer->picture.handle;
	for (i = 0; i < ctx->slot_count; i++)
		job.references[i] = ctx->slot_handles[i];
	if (ctx->picture.slice_temporal_mvp) {
		const RpividFrame* collocated = s->collocated_ref != NULL
			? s->collocated_ref->hwaccel_picture_private : NULL;
		if (collocated != NULL && collocated->buffer != NULL
			&& collocated->submitted && collocated->has_mv) {
			job.collocated = collocated->buffer->picture.handle;
		} else {
			/* the driver reads zero motion instead */
			ctx->missing_references++;
		}
	}
	job.log2_ctb_size = sps->log2_ctb_size;
	job.config2 = ff_rpivid_config2(&ctx->picture, ctx->write_mv);
	job.current_poc = s->poc;

	ret = ff_rpivid_device_submit(ctx->device, &job, &id);
	if (ret < 0) {
		av_log(avctx, AV_LOG_ERROR, "rpivid: the block refused picture POC %d: "
			"%s\n", s->poc, av_err2str(ret));
		ctx->error = "hardware";
		goto fail;
	}
	frame->buffer->job = id;
	frame->submitted = 1;
	frame->has_mv = ctx->write_mv;
	ctx->bitstream_jobs[ctx->bitstream_index] = id;

	/* the picture before this one, while the block decodes this one */
	finish_pending(avctx, s, 1);

	ctx->pending.frame = av_frame_alloc();
	if (ctx->pending.frame == NULL || av_frame_ref(ctx->pending.frame, out) < 0) {
		/* it cannot be converted later: now */
		RpividResult result;

		av_frame_free(&ctx->pending.frame);
		ret = ff_rpivid_device_wait(ctx->device, id, -1, &result);
		if (ret == 0 && result.result == 0)
			convert(avctx, ctx, frame->buffer, out, 1);
		else
			ctx->failed = 1;
		return 0;
	}
	buffer_ref(ctx->pool, frame->buffer);
	ctx->pending.buffer = frame->buffer;
	ctx->pending.job = id;

	/* hevcdec.c outputs this picture when this call returns (no reordering) */
	if (ctx->sync || (s->output_frame->buf[0] != NULL
			&& s->output_frame->buf[0]->buffer == out->buf[0]->buffer)) {
		finish_pending(avctx, s, !ctx->sync);
	}
	return 0;

fail:
	finish_pending(avctx, s, 1);
	av_log(avctx, AV_LOG_WARNING, "rpivid: picture POC %d not decoded on the "
		"block (%s)\n", s->poc, ctx->error);
	out->decode_error_flags |= FF_DECODE_ERROR_INVALID_BITSTREAM;
	ctx->failed = 1;
	return 0;
}


static const FFHWAccel ff_hevc_rpivid_hwaccel = {
	.p.name					= "hevc_rpivid",
	.p.type					= AVMEDIA_TYPE_VIDEO,
	.p.id					= AV_CODEC_ID_HEVC,
	.p.pix_fmt				= AV_PIX_FMT_YUV420P,
	.start_frame			= rpivid_start_frame,
	.decode_slice			= rpivid_decode_slice,
	.end_frame				= rpivid_end_frame,
	.frame_priv_data_size	= sizeof(RpividFrame),
	.free_frame_priv		= rpivid_free_frame,
	.priv_data_size			= sizeof(RpividContext),
	.uninit					= rpivid_uninit,
};
