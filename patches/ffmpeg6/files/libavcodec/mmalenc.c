/*
 * MMAL H.264 encoder: the Raspberry Pi's VideoCore (vc.ril.video_encode)
 *
 * This file is part of FFmpeg.
 *
 * FFmpeg is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * FFmpeg is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FFmpeg; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

/**
 * @file
 * "h264_mmal" encoder: yuv420p frames are copied into the VideoCore's input
 * buffers (its I420 layout: width aligned to 32, height to 16), the encoded
 * stream comes back in output buffers; the parts of one picture (flagged
 * FRAME_END on the last) become one packet. The parameter sets (a buffer
 * flagged CONFIG) go in front of the next picture's data (in-band, as the
 * encoder also repeats them at each key frame), and the first ones also as
 * AV_PKT_DATA_NEW_EXTRADATA. No B-frames: dts = pts. MMAL's timestamps are in microseconds: the frames'
 * pts are rescaled to them and back, as the MMAL API defines them (no measured effect on the stream).
 */

#ifndef __HAIKU__
#include <bcm_host.h>
#endif
#include <interface/mmal/mmal.h>
#include <interface/mmal/mmal_parameters_video.h>
#include <interface/mmal/util/mmal_util.h>
#include <interface/mmal/util/mmal_util_params.h>
#include <interface/mmal/util/mmal_default_components.h>
#include <interface/mmal/vc/mmal_vc_api.h>
#include <stdatomic.h>
#include <string.h>

#include "libavutil/common.h"
#include "libavutil/mem.h"
#include "libavutil/opt.h"

#include "avcodec.h"
#include "codec_internal.h"
#include "encode.h"
#include "packet_internal.h"

typedef struct MMALEncodeContext {
    AVClass *av_class;
    int inline_headers;
    int initial_qp;

    MMAL_COMPONENT_T *encoder;
    MMAL_POOL_T *pool_in, *pool_out;
    MMAL_QUEUE_T *queue_out;
    AVFrame *frame;
    atomic_int error;

    int width, height;          /* aligned: the input buffers' layout */
    int eos_sent;
    int starved;                /* the caller had no frame for a free input buffer */
    int stalls;
    int64_t frames_in, packets_out;

    uint8_t *data;              /* the picture being collected */
    size_t size, capacity;
    uint8_t *headers;           /* parameter sets for the next picture */
    size_t headers_size, headers_capacity;
    int headers_exported;
    int vc_initialised;
    int eos_received;
} MMALEncodeContext;

/* waits of 100 ms for output while the encoder has all input buffers */
#define MAX_STALLS 50

static void input_callback(MMAL_PORT_T *port, MMAL_BUFFER_HEADER_T *buffer)
{
    mmal_buffer_header_release(buffer);
}

static void output_callback(MMAL_PORT_T *port, MMAL_BUFFER_HEADER_T *buffer)
{
    AVCodecContext *avctx = (AVCodecContext *)port->userdata;
    MMALEncodeContext *ctx = avctx->priv_data;

    mmal_queue_put(ctx->queue_out, buffer);
}

static void control_callback(MMAL_PORT_T *port, MMAL_BUFFER_HEADER_T *buffer)
{
    AVCodecContext *avctx = (AVCodecContext *)port->userdata;
    MMALEncodeContext *ctx = avctx->priv_data;

    if (buffer->cmd == MMAL_EVENT_ERROR) {
        MMAL_STATUS_T status = *(uint32_t *)buffer->data;
        av_log(avctx, AV_LOG_ERROR, "MMAL error %d on control port\n", (int)status);
        atomic_store(&ctx->error, status ? (int)status : MMAL_EIO);
    }
    mmal_buffer_header_release(buffer);
}

static av_cold int ffmmal_close_encoder(AVCodecContext *avctx)
{
    MMALEncodeContext *ctx = avctx->priv_data;
    MMAL_BUFFER_HEADER_T *buffer;

    if (ctx->encoder) {
        mmal_port_disable(ctx->encoder->input[0]);
        mmal_port_disable(ctx->encoder->output[0]);
        mmal_port_disable(ctx->encoder->control);
        mmal_component_disable(ctx->encoder);
        av_log(avctx, AV_LOG_INFO, "mmal: %"PRId64" frames encoded into %"PRId64
               " packets\n", ctx->frames_in, ctx->packets_out);
    }
    if (ctx->queue_out) {
        while ((buffer = mmal_queue_get(ctx->queue_out)))
            mmal_buffer_header_release(buffer);
    }
    if (ctx->pool_in)
        mmal_port_pool_destroy(ctx->encoder->input[0], ctx->pool_in);
    if (ctx->pool_out)
        mmal_port_pool_destroy(ctx->encoder->output[0], ctx->pool_out);
    if (ctx->encoder)
        mmal_component_destroy(ctx->encoder);
    ctx->encoder = NULL;
    ctx->pool_in = ctx->pool_out = NULL;
    if (ctx->queue_out)
        mmal_queue_destroy(ctx->queue_out);
    ctx->queue_out = NULL;
    av_frame_free(&ctx->frame);
    av_freep(&ctx->data);
    av_freep(&ctx->headers);
    if (ctx->vc_initialised)
        mmal_vc_deinit();
    ctx->vc_initialised = 0;
    return 0;
}

static MMAL_VIDEO_PROFILE_T ffmmal_profile(AVCodecContext *avctx)
{
    switch (avctx->profile) {
    case AV_PROFILE_H264_BASELINE:
    case AV_PROFILE_H264_CONSTRAINED_BASELINE:
        return MMAL_VIDEO_PROFILE_H264_CONSTRAINED_BASELINE;
    case AV_PROFILE_H264_MAIN:
        return MMAL_VIDEO_PROFILE_H264_MAIN;
    default:
        return MMAL_VIDEO_PROFILE_H264_HIGH;
    }
}

static av_cold int ffmmal_init_encoder(AVCodecContext *avctx)
{
    MMALEncodeContext *ctx = avctx->priv_data;
    MMAL_STATUS_T status;
    MMAL_PORT_T *in, *out;
    MMAL_PARAMETER_VIDEO_PROFILE_T profile;
    AVRational rate = avctx->framerate;

#ifndef __HAIKU__
    bcm_host_init();
#endif
    if (mmal_vc_init()) {
        av_log(avctx, AV_LOG_ERROR, "Cannot initialize MMAL VC driver!\n");
        return AVERROR(ENOSYS);
    }
    ctx->vc_initialised = 1;
    if (avctx->width > 1920 || avctx->height > 1088) {
        av_log(avctx, AV_LOG_ERROR, "The VideoCore encodes up to 1920x1088\n");
        return AVERROR(EINVAL);
    }
    if (rate.num <= 0 || rate.den <= 0)
        rate = av_inv_q(avctx->time_base);
    if (rate.num <= 0 || rate.den <= 0 || av_q2d(rate) > 240)
        rate = (AVRational){ 30, 1 };

    ctx->frame = av_frame_alloc();
    ctx->queue_out = mmal_queue_create();
    if (!ctx->frame || !ctx->queue_out)
        return AVERROR(ENOMEM);

    if ((status = mmal_component_create(MMAL_COMPONENT_DEFAULT_VIDEO_ENCODER, &ctx->encoder)))
        goto fail;
    in = ctx->encoder->input[0];
    out = ctx->encoder->output[0];

    ctx->width = FFALIGN(avctx->width, 32);
    ctx->height = FFALIGN(avctx->height, 16);
    in->format->type = MMAL_ES_TYPE_VIDEO;
    in->format->encoding = in->format->encoding_variant = MMAL_ENCODING_I420;
    in->format->es->video.width = ctx->width;
    in->format->es->video.height = ctx->height;
    in->format->es->video.crop.x = 0;
    in->format->es->video.crop.y = 0;
    in->format->es->video.crop.width = avctx->width;
    in->format->es->video.crop.height = avctx->height;
    in->format->es->video.frame_rate.num = rate.num;
    in->format->es->video.frame_rate.den = rate.den;
    in->format->es->video.par.num = avctx->sample_aspect_ratio.num;
    in->format->es->video.par.den = avctx->sample_aspect_ratio.den;
    if ((status = mmal_port_format_commit(in)))
        goto fail;

    mmal_format_copy(out->format, in->format);
    out->format->encoding = MMAL_ENCODING_H264;
    out->format->encoding_variant = 0;
    out->format->bitrate = avctx->bit_rate > 0 ? FFMIN(avctx->bit_rate, 25000000) : 4000000;
    if ((status = mmal_port_format_commit(out)))
        goto fail;

    profile.hdr.id = MMAL_PARAMETER_PROFILE;
    profile.hdr.size = sizeof(profile);
    profile.profile[0].profile = ffmmal_profile(avctx);
    profile.profile[0].level = av_q2d(rate) > 30 && avctx->width * avctx->height > 1280 * 720
                               ? MMAL_VIDEO_LEVEL_H264_42 : MMAL_VIDEO_LEVEL_H264_4;
    if (mmal_port_parameter_set(out, &profile.hdr))
        av_log(avctx, AV_LOG_WARNING, "The VideoCore did not take the profile\n");
    if (avctx->gop_size > 0 &&
        mmal_port_parameter_set_uint32(out, MMAL_PARAMETER_INTRAPERIOD, avctx->gop_size))
        av_log(avctx, AV_LOG_WARNING, "The VideoCore did not take the key frame interval\n");
    /* the VideoCore's own first quantiser is coarse: a flat-shaded 720p key frame came out in under 1 KB,
     * banded, and the rate control needed many frames to recover */
    if (ctx->initial_qp > 0 &&
        mmal_port_parameter_set_uint32(out, MMAL_PARAMETER_VIDEO_ENCODE_INITIAL_QUANT, ctx->initial_qp))
        av_log(avctx, AV_LOG_WARNING, "The VideoCore did not take the initial quantiser\n");
    if (mmal_port_parameter_set_boolean(out, MMAL_PARAMETER_VIDEO_ENCODE_INLINE_HEADER,
                                        ctx->inline_headers))
        av_log(avctx, AV_LOG_WARNING, "The VideoCore did not take the in-band headers setting\n");

    in->buffer_num = FFMAX(in->buffer_num_min, 3);
    in->buffer_size = FFMAX(in->buffer_size_min, (uint32_t)(ctx->width * ctx->height * 3 / 2));
    out->buffer_num = FFMAX(out->buffer_num_min, FFMAX(out->buffer_num_recommended, 4));
    out->buffer_size = FFMAX(out->buffer_size_min, out->buffer_size_recommended);
    ctx->pool_in = mmal_port_pool_create(in, in->buffer_num, in->buffer_size);
    ctx->pool_out = mmal_port_pool_create(out, out->buffer_num, out->buffer_size);
    if (!ctx->pool_in || !ctx->pool_out)
        return AVERROR(ENOMEM);

    in->userdata = out->userdata = ctx->encoder->control->userdata =
        (struct MMAL_PORT_USERDATA_T *)avctx;
    if ((status = mmal_port_enable(ctx->encoder->control, control_callback)))
        goto fail;
    if ((status = mmal_port_enable(in, input_callback)))
        goto fail;
    if ((status = mmal_port_enable(out, output_callback)))
        goto fail;
    if ((status = mmal_component_enable(ctx->encoder)))
        goto fail;

    av_log(avctx, AV_LOG_INFO, "mmal: VideoCore H.264 encode, %dx%d at %d/%d fps, %u bit/s\n",
           avctx->width, avctx->height, rate.num, rate.den, out->format->bitrate);
    return 0;

fail:
    av_log(avctx, AV_LOG_ERROR, "MMAL encoder setup failed: %s\n", mmal_status_to_string(status));
    return AVERROR_EXTERNAL; /* (closed by the caller: FF_CODEC_CAP_INIT_CLEANUP) */
}

static int ffmmal_fill_output_port(AVCodecContext *avctx)
{
    MMALEncodeContext *ctx = avctx->priv_data;
    MMAL_BUFFER_HEADER_T *buffer;

    while ((buffer = mmal_queue_get(ctx->pool_out->queue))) {
        if (mmal_port_send_buffer(ctx->encoder->output[0], buffer)) {
            mmal_buffer_header_release(buffer);
            return AVERROR_EXTERNAL;
        }
    }
    return 0;
}

/* The frames the encoder can take now: copied into free input buffers */
static int ffmmal_send_frames(AVCodecContext *avctx)
{
    MMALEncodeContext *ctx = avctx->priv_data;
    MMAL_BUFFER_HEADER_T *buffer;
    int ret;

    ctx->starved = 0;
    while (!ctx->eos_sent && (buffer = mmal_queue_get(ctx->pool_in->queue))) {
        AVFrame *frame = ctx->frame;

        ret = ff_encode_get_frame(avctx, frame);
        if (ret == AVERROR(EAGAIN)) {
            mmal_buffer_header_release(buffer);
            ctx->starved = 1;
            return 0;
        }
        if (ret < 0 && ret != AVERROR_EOF) {
            mmal_buffer_header_release(buffer);
            return ret;
        }

        buffer->offset = 0;
        buffer->pts = buffer->dts = MMAL_TIME_UNKNOWN;
        if (ret == AVERROR_EOF) {
            buffer->length = 0;
            buffer->flags = MMAL_BUFFER_HEADER_FLAG_EOS;
            ctx->eos_sent = 1;
        } else {
            uint8_t *dst = buffer->data;
            int w = avctx->width, h = avctx->height;

            for (int plane = 0; plane < 3; plane++) {
                int shift = plane ? 1 : 0;
                int pitch = ctx->width >> shift;
                uint8_t *d = dst + (plane == 0 ? 0 : ctx->width * ctx->height +
                                    (plane - 1) * (ctx->width / 2) * (ctx->height / 2));
                for (int y = 0; y < (h + shift) >> shift; y++)
                    memcpy(d + y * pitch, frame->data[plane] + y * frame->linesize[plane],
                           (w + shift) >> shift);
            }
            buffer->length = ctx->width * ctx->height * 3 / 2;
            buffer->flags = MMAL_BUFFER_HEADER_FLAG_FRAME_END;
            if (frame->pts != AV_NOPTS_VALUE)
                buffer->pts = av_rescale_q(frame->pts, avctx->time_base, (AVRational){ 1, 1000000 });
            ctx->frames_in++;
            av_frame_unref(frame);
        }
        if (mmal_port_send_buffer(ctx->encoder->input[0], buffer)) {
            mmal_buffer_header_release(buffer);
            return AVERROR_EXTERNAL;
        }
    }
    return 0;
}

static int ffmmal_append(void **data, size_t *size, size_t *capacity,
                         const uint8_t *src, size_t length)
{
    if (*size + length > *capacity) {
        size_t capacity_new = FFMAX(*size + length, *capacity * 2);
        if (av_reallocp(data, capacity_new) < 0)
            return AVERROR(ENOMEM);
        *capacity = capacity_new;
    }
    memcpy((uint8_t *)*data + *size, src, length);
    *size += length;
    return 0;
}

static int ffmmal_receive_packet(AVCodecContext *avctx, AVPacket *pkt)
{
    MMALEncodeContext *ctx = avctx->priv_data;
    MMAL_BUFFER_HEADER_T *buffer;
    int ret;

    for (;;) {
        int wait;

        if (ctx->eos_received)
            return AVERROR_EOF;
        if (atomic_load(&ctx->error))
            return AVERROR_EXTERNAL;
        if ((ret = ffmmal_fill_output_port(avctx)) < 0)
            return ret;
        if ((ret = ffmmal_send_frames(avctx)) < 0)
            return ret;

        /* EAGAIN only when the caller's frames are all taken (it must send
         * one before it asks again); else wait for output or for an input
         * buffer to come back */
        wait = ctx->eos_sent || !ctx->starved;
        buffer = wait ? mmal_queue_timedwait(ctx->queue_out, 100)
                      : mmal_queue_get(ctx->queue_out);
        if (!buffer) {
            if (!wait)
                return AVERROR(EAGAIN);
            if (!ctx->eos_sent && mmal_queue_length(ctx->pool_in->queue))
                continue; /* an input buffer is back: take the next frame */
            if (++ctx->stalls >= MAX_STALLS) {
                av_log(avctx, AV_LOG_ERROR, "No output from the VideoCore's encoder\n");
                atomic_store(&ctx->error, MMAL_EIO);
                return AVERROR_EXTERNAL;
            }
            continue;
        }
        ctx->stalls = 0;

        if (buffer->cmd) {
            mmal_buffer_header_release(buffer);
            continue;
        }

        if (buffer->flags & MMAL_BUFFER_HEADER_FLAG_CONFIG) {
            ret = ffmmal_append((void **)&ctx->headers, &ctx->headers_size,
                                &ctx->headers_capacity, buffer->data + buffer->offset,
                                buffer->length);
            mmal_buffer_header_release(buffer);
            if (ret < 0)
                return ret;
            continue;
        }

        if (buffer->length) {
            if (!ctx->size && ctx->headers_size &&
                (ret = ffmmal_append((void **)&ctx->data, &ctx->size, &ctx->capacity,
                                     ctx->headers, ctx->headers_size)) < 0) {
                mmal_buffer_header_release(buffer);
                return ret;
            }
            if ((ret = ffmmal_append((void **)&ctx->data, &ctx->size, &ctx->capacity,
                                     buffer->data + buffer->offset, buffer->length)) < 0) {
                mmal_buffer_header_release(buffer);
                return ret;
            }
        }

        if (ctx->size && (buffer->flags & (MMAL_BUFFER_HEADER_FLAG_FRAME_END |
                                           MMAL_BUFFER_HEADER_FLAG_EOS))) {
            int key = !!(buffer->flags & MMAL_BUFFER_HEADER_FLAG_KEYFRAME);
            int64_t pts = buffer->pts == MMAL_TIME_UNKNOWN ? AV_NOPTS_VALUE
                : av_rescale_q(buffer->pts, (AVRational){ 1, 1000000 }, avctx->time_base);
            int eos = !!(buffer->flags & MMAL_BUFFER_HEADER_FLAG_EOS);

            mmal_buffer_header_release(buffer);
            if ((ret = ff_get_encode_buffer(avctx, pkt, ctx->size, 0)) < 0)
                return ret;
            memcpy(pkt->data, ctx->data, ctx->size);
            ctx->size = 0;
            if (ctx->headers_size && !ctx->headers_exported) {
                uint8_t *side = av_packet_new_side_data(pkt, AV_PKT_DATA_NEW_EXTRADATA,
                                                        ctx->headers_size);
                if (side)
                    memcpy(side, ctx->headers, ctx->headers_size);
                ctx->headers_exported = 1;
            }
            ctx->headers_size = 0;
            pkt->pts = pkt->dts = pts;
            if (key)
                pkt->flags |= AV_PKT_FLAG_KEY;
            ctx->packets_out++;
            ctx->eos_received = eos;
            return 0;
        }

        if (buffer->flags & MMAL_BUFFER_HEADER_FLAG_EOS) {
            mmal_buffer_header_release(buffer);
            ctx->eos_received = 1;
            return AVERROR_EOF;
        }
        mmal_buffer_header_release(buffer);
    }
}

#define OFFSET(x) offsetof(MMALEncodeContext, x)
#define VE AV_OPT_FLAG_VIDEO_PARAM | AV_OPT_FLAG_ENCODING_PARAM
static const AVOption options[] = {
    { "inline_headers", "parameter sets in front of every key frame", OFFSET(inline_headers),
      AV_OPT_TYPE_BOOL, { .i64 = 1 }, 0, 1, VE },
    { "initial_qp", "quantiser of the first frame (0: the VideoCore's own choice)", OFFSET(initial_qp),
      AV_OPT_TYPE_INT, { .i64 = 25 }, 0, 51, VE },
    { NULL },
};

static const AVClass ffmmal_enc_class = {
    .class_name = "h264_mmal encoder",
    .item_name  = av_default_item_name,
    .option     = options,
    .version    = LIBAVUTIL_VERSION_INT,
};

static const FFCodecDefault ffmmal_enc_defaults[] = {
    { "b", "4M" },
    { "g", "60" },
    { NULL },
};

const FFCodec ff_h264_mmal_encoder = {
    .p.name         = "h264_mmal",
    CODEC_LONG_NAME("H.264 (mmal: the Raspberry Pi's VideoCore)"),
    .p.type         = AVMEDIA_TYPE_VIDEO,
    .p.id           = AV_CODEC_ID_H264,
    .priv_data_size = sizeof(MMALEncodeContext),
    .p.priv_class   = &ffmmal_enc_class,
    .init           = ffmmal_init_encoder,
    FF_CODEC_RECEIVE_PACKET_CB(ffmmal_receive_packet),
    .close          = ffmmal_close_encoder,
    .defaults       = ffmmal_enc_defaults,
    .p.capabilities = AV_CODEC_CAP_HARDWARE | AV_CODEC_CAP_DELAY,
    .caps_internal  = FF_CODEC_CAP_NOT_INIT_THREADSAFE | FF_CODEC_CAP_INIT_CLEANUP,
    .p.pix_fmts     = (const enum AVPixelFormat[]) { AV_PIX_FMT_YUV420P, AV_PIX_FMT_NONE },
    .p.wrapper_name = "mmal",
};
