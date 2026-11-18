/*
 * H.264 on the Raspberry Pi's VideoCore (h264_mmal), falling back to the
 * software decoder (h264)
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
 * "h264_vc": a decoder for callers that pick their H.264 decoder by walking
 * av_codec_iterate() and skip AV_CODEC_CAP_HARDWARE ones (Firefox's FFmpeg
 * decoder module). It decodes with h264_mmal (the VideoCore, through MMAL)
 * in an inner codec context and moves the stream to the software h264 decoder
 * when h264_mmal does not open or fails later: from the start if h264_mmal had
 * not output a frame yet (the packets it was given are kept, at most
 * MAX_RECORDED, and given again), else from the next key frame. The frames are
 * the inner decoder's, yuv420p in system memory.
 *
 * It is listed before "h264" for av_codec_iterate(), but avcodec_find_decoder()
 * skips it (allcodecs.c): FFmpeg's other users keep the software decoder unless
 * they ask for this one by name.
 *
 * h264_mmal is opened with the first packet, not by avcodec_open2(). The
 * VideoCore is not used (the software decoder from the start) when
 * FFMPEG_H264_MMAL=0 is in the environment, for low-delay decoding
 * (AV_CODEC_FLAG_LOW_DELAY: h264_mmal holds 8 packets), for pictures larger
 * than 1920x1088 and for profiles the VideoCore does not decode (High 10,
 * 4:2:2, 4:4:4).
 */

#include <stdlib.h>
#include <string.h>

#include "libavutil/error.h"
#include "libavutil/log.h"
#include "libavutil/mem.h"

#include "avcodec.h"
#include "codec_par.h"
#include "codec_internal.h"
#include "decode.h"

extern const FFCodec ff_h264_decoder;
extern const FFCodec ff_h264_mmal_decoder;

/* packets kept for the software decoder until h264_mmal's first frame */
#define MAX_RECORDED 300
/* the properties of the last packets, found again by a VideoCore frame's pts
 * (h264_mmal passes only the pts through) */
#define MAX_INFO 64
/* the largest picture the VideoCore decodes */
#define VC_MAX_WIDTH 1920
#define VC_MAX_HEIGHT 1088

typedef struct PacketInfo {
    int64_t pts, dts, duration;
    int key;
} PacketInfo;

typedef struct H264VCContext {
    AVCodecContext *dec;        /* the inner decoder (none before the first packet) */
    int use_vc;                 /* h264_mmal is to be tried first */
    int on_vc;                  /* it is h264_mmal */
    int vc_frames;              /* frames from h264_mmal */
    AVCodecParameters *par;     /* the stream, for a new inner decoder */

    AVPacket *pending;          /* the next packet for the inner decoder */
    AVPacket *recorded[MAX_RECORDED];
    int nb_recorded;
    int recording;              /* keep packets for a fallback from the start */
    int replaying;              /* the recorded packets go to h264 again */
    int replay;                 /* the next one */
    int skip_to_key;            /* drop packets up to the next key frame */
    int eof;                    /* the caller started draining */
    int eof_sent;               /* the inner decoder is draining */

    PacketInfo info[MAX_INFO];
    int info_next;
} H264VCContext;

static void forget_recorded(H264VCContext *s)
{
    for (int i = 0; i < s->nb_recorded; i++)
        av_packet_free(&s->recorded[i]);
    s->nb_recorded = s->replay = s->replaying = 0;
}

/* The profile_idc of an "avcC" record or of the first Annex-B SPS, or -1. */
static int extradata_profile(const uint8_t *data, int size)
{
    if (size >= 4 && data[0] == 1)
        return data[1];
    for (int i = 0; i + 4 < size; i++) {
        if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1
                && (data[i + 3] & 0x1f) == 7)
            return data[i + 4];
    }
    return -1;
}

static const char *why_not_vc(AVCodecContext *avctx)
{
    const char *setting = getenv("FFMPEG_H264_MMAL");
    int profile = avctx->profile;

    if (setting && !strcmp(setting, "0"))
        return "FFMPEG_H264_MMAL=0";
    if (avctx->flags & AV_CODEC_FLAG_LOW_DELAY)
        return "low delay";
    if (avctx->width > VC_MAX_WIDTH || avctx->height > VC_MAX_HEIGHT)
        return "larger than 1920x1088";
    if (profile == AV_PROFILE_UNKNOWN && avctx->extradata)
        profile = extradata_profile(avctx->extradata, avctx->extradata_size);
    /* High 10, High 4:2:2, High 4:4:4 (Predictive), CAVLC 4:4:4 Intra */
    if (profile == 110 || profile == 122 || profile == 244 || profile == 44)
        return "a profile the VideoCore does not decode";
    return NULL;
}

static int open_inner(AVCodecContext *avctx, const FFCodec *codec)
{
    H264VCContext *s = avctx->priv_data;
    AVCodecContext *dec;
    int ret;

    avcodec_free_context(&s->dec);
    s->on_vc = codec == &ff_h264_mmal_decoder;

    dec = avcodec_alloc_context3(&codec->p);
    if (!dec)
        return AVERROR(ENOMEM);
    if ((ret = avcodec_parameters_to_context(dec, s->par)) < 0) {
        avcodec_free_context(&dec);
        return ret;
    }
    dec->flags                 = avctx->flags;
    dec->flags2                = avctx->flags2;
    dec->pkt_timebase          = avctx->pkt_timebase;
    dec->err_recognition       = avctx->err_recognition;
    dec->error_concealment     = avctx->error_concealment;
    dec->workaround_bugs       = avctx->workaround_bugs;
    dec->strict_std_compliance = avctx->strict_std_compliance;
    dec->skip_frame            = avctx->skip_frame;
    dec->skip_loop_filter      = avctx->skip_loop_filter;
    dec->skip_idct             = avctx->skip_idct;
    dec->export_side_data      = avctx->export_side_data;
    dec->apply_cropping        = avctx->apply_cropping;
    dec->max_pixels            = avctx->max_pixels;
    dec->debug                 = avctx->debug;
    if (!s->on_vc) {
        dec->thread_count = avctx->thread_count;
        dec->thread_type  = avctx->thread_type;
    }

    if ((ret = avcodec_open2(dec, &codec->p, NULL)) < 0) {
        avcodec_free_context(&dec);
        return ret;
    }
    s->dec = dec;
    avctx->pix_fmt = dec->pix_fmt;
    return 0;
}

/*
 * The stream goes to the software decoder: given the recorded packets again
 * (h264_mmal output no frame yet) or from the next key frame on.
 */
static int fall_back(AVCodecContext *avctx, const char *reason, int error)
{
    H264VCContext *s = avctx->priv_data;
    const int from_start = s->recording;
    char text[AV_ERROR_MAX_STRING_SIZE] = "";
    int ret;

    if (error)
        av_strerror(error, text, sizeof(text));
    av_log(avctx, AV_LOG_WARNING, "h264_mmal %s%s%s: h264 continues %s\n",
           reason, error ? ": " : "", text,
           from_start ? "from the start" : "at the next key frame");

    s->recording = 0;
    if (from_start) {
        /* the pending packet is the last one recorded */
        av_packet_unref(s->pending);
        s->replay = 0;
        s->replaying = s->nb_recorded > 0;
    } else {
        forget_recorded(s);
        if (!(s->pending->flags & AV_PKT_FLAG_KEY)) {
            av_packet_unref(s->pending);
            s->skip_to_key = 1;
        }
    }
    s->eof_sent = 0;

    if ((ret = open_inner(avctx, &ff_h264_decoder)) < 0)
        av_log(avctx, AV_LOG_ERROR, "h264 does not open either\n");
    return ret;
}

/* The first inner decoder: h264_mmal if wanted and it opens, else h264. */
static int open_first(AVCodecContext *avctx)
{
    H264VCContext *s = avctx->priv_data;
    int ret;

    if (s->use_vc) {
        ret = open_inner(avctx, &ff_h264_mmal_decoder);
        if (ret >= 0) {
            s->recording = 1;
            av_log(avctx, AV_LOG_VERBOSE, "h264_mmal decodes\n");
            return 0;
        }
        s->use_vc = 0;
        av_log(avctx, AV_LOG_WARNING,
               "h264_mmal does not open (%s): h264 decodes\n", av_err2str(ret));
    }
    return open_inner(avctx, &ff_h264_decoder);
}

static av_cold int h264_vc_init(AVCodecContext *avctx)
{
    H264VCContext *s = avctx->priv_data;
    const char *why_not;
    int ret;

    s->pending = av_packet_alloc();
    s->par = avcodec_parameters_alloc();
    if (!s->pending || !s->par)
        return AVERROR(ENOMEM);
    if ((ret = avcodec_parameters_from_context(s->par, avctx)) < 0)
        return ret;

    why_not = why_not_vc(avctx);
    if (why_not) {
        av_log(avctx, AV_LOG_VERBOSE, "h264 decodes (%s)\n", why_not);
        return open_inner(avctx, &ff_h264_decoder);
    }
    /* The VideoCore's decoder is opened with the first packet: callers
     * (Firefox) open decoders that never decode, and the VideoCore's memory
     * holds one 1080p decoder. */
    s->use_vc = 1;
    return 0;
}

static av_cold int h264_vc_close(AVCodecContext *avctx)
{
    H264VCContext *s = avctx->priv_data;

    avcodec_free_context(&s->dec);
    forget_recorded(s);
    av_packet_free(&s->pending);
    avcodec_parameters_free(&s->par);
    return 0;
}

static void h264_vc_flush(AVCodecContext *avctx)
{
    H264VCContext *s = avctx->priv_data;

    if (s->dec)
        avcodec_flush_buffers(s->dec);
    av_packet_unref(s->pending);
    forget_recorded(s);
    /* what h264_mmal is given from here on is what a fallback needs */
    s->recording = s->on_vc;
    s->vc_frames = 0;
    s->skip_to_key = s->eof = s->eof_sent = 0;
    memset(s->info, 0, sizeof(s->info));
    s->info_next = 0;
}

static void remember_packet(H264VCContext *s, const AVPacket *pkt)
{
    PacketInfo *info = &s->info[s->info_next];

    info->pts      = pkt->pts;
    info->dts      = pkt->dts;
    info->duration = pkt->duration;
    info->key      = !!(pkt->flags & AV_PKT_FLAG_KEY);
    s->info_next = (s->info_next + 1) % MAX_INFO;
}

/* The next packet for the inner decoder into s->pending: 0, EAGAIN, or EOF. */
static int next_packet(AVCodecContext *avctx)
{
    H264VCContext *s = avctx->priv_data;
    int ret;

    if (s->replaying) {
        av_packet_move_ref(s->pending, s->recorded[s->replay]);
        av_packet_free(&s->recorded[s->replay++]);
        if (s->replay == s->nb_recorded)
            s->nb_recorded = s->replay = s->replaying = 0;
        return 0;
    }
    if (s->eof)
        return AVERROR_EOF;

    for (;;) {
        ret = ff_decode_get_packet(avctx, s->pending);
        if (ret == AVERROR_EOF)
            s->eof = 1;
        if (ret < 0)
            return ret;
        remember_packet(s, s->pending);
        if (s->skip_to_key && !(s->pending->flags & AV_PKT_FLAG_KEY)) {
            av_packet_unref(s->pending);
            continue;
        }
        s->skip_to_key = 0;
        break;
    }

    if (s->recording) {
        AVPacket *copy;

        if (s->nb_recorded == MAX_RECORDED) {
            forget_recorded(s);
            s->recording = 0;
        } else if ((copy = av_packet_clone(s->pending))) {
            s->recorded[s->nb_recorded++] = copy;
        } else {
            return AVERROR(ENOMEM);
        }
    }
    return 0;
}

/* The caller's codec context and the frame, as the inner decoder left them */
static void finish_frame(AVCodecContext *avctx, AVFrame *frame)
{
    H264VCContext *s = avctx->priv_data;
    AVCodecContext *dec = s->dec;

    avctx->pix_fmt             = dec->pix_fmt;
    avctx->width               = dec->width;
    avctx->height              = dec->height;
    avctx->coded_width         = dec->coded_width;
    avctx->coded_height        = dec->coded_height;
    avctx->sample_aspect_ratio = dec->sample_aspect_ratio;
    avctx->colorspace          = dec->colorspace;
    avctx->color_range         = dec->color_range;
    avctx->color_primaries     = dec->color_primaries;
    avctx->color_trc           = dec->color_trc;
    avctx->chroma_sample_location = dec->chroma_sample_location;
    avctx->profile             = dec->profile;
    avctx->level               = dec->level;
    avctx->has_b_frames        = dec->has_b_frames;
    /* not the frame rate: h264_mmal reports the 24000/1001 it told the
     * VideoCore, whatever the stream's */

    if (!s->on_vc)
        return;

    s->vc_frames++;
    if (s->recording) {
        forget_recorded(s);
        s->recording = 0;
    }

    /* h264_mmal passes the pts through, nothing else */
    frame->pkt_dts = frame->pts;
    if (frame->pts != AV_NOPTS_VALUE) {
        for (int i = 0; i < MAX_INFO; i++) {
            const PacketInfo *info = &s->info[i];

            if (info->pts != frame->pts)
                continue;
            frame->pkt_dts = info->dts;
            if (!frame->duration)
                frame->duration = info->duration;
            if (info->key)
                frame->flags |= AV_FRAME_FLAG_KEY;
            break;
        }
    }
}

static int h264_vc_receive_frame(AVCodecContext *avctx, AVFrame *frame)
{
    H264VCContext *s = avctx->priv_data;
    int ret;

    if (!s->dec && (ret = open_first(avctx)) < 0)
        return ret;

    for (;;) {
        ret = avcodec_receive_frame(s->dec, frame);
        if (ret >= 0) {
            finish_frame(avctx, frame);
            return 0;
        }
        if (ret == AVERROR_EOF)
            return ret;
        if (ret != AVERROR(EAGAIN)) {
            if (s->on_vc && fall_back(avctx, "failed", ret) >= 0)
                continue;
            return ret;
        }

        /* the inner decoder wants a packet */
        if (s->eof_sent)
            return AVERROR_EOF; /* (it should not while draining) */
        if (!s->pending->data && !s->pending->side_data_elems) {
            ret = next_packet(avctx);
            if (ret == AVERROR_EOF) {
                s->eof_sent = 1;
                ret = avcodec_send_packet(s->dec, NULL);
                if (ret < 0 && ret != AVERROR_EOF) {
                    if (s->on_vc && fall_back(avctx, "failed", ret) >= 0)
                        continue;
                    return ret;
                }
                continue;
            }
            if (ret < 0)
                return ret;
        }

        ret = avcodec_send_packet(s->dec, s->pending);
        if (ret == AVERROR(EAGAIN))
            return AVERROR_BUG; /* it just asked for a packet */
        if (ret < 0) {
            if (s->on_vc && fall_back(avctx, "failed", ret) >= 0)
                continue;
            return ret;
        }
        av_packet_unref(s->pending);
    }
}

const FFCodec ff_h264_vc_decoder = {
    .p.name         = "h264_vc",
    CODEC_LONG_NAME("H.264 on the VideoCore (MMAL), h264 as the fallback"),
    .p.type         = AVMEDIA_TYPE_VIDEO,
    .p.id           = AV_CODEC_ID_H264,
    .priv_data_size = sizeof(H264VCContext),
    .init           = h264_vc_init,
    .close          = h264_vc_close,
    FF_CODEC_RECEIVE_FRAME_CB(h264_vc_receive_frame),
    .flush          = h264_vc_flush,
    /* no AV_CODEC_CAP_HARDWARE: the caller sees a software decoder (the
     * frames are in system memory) */
    .p.capabilities = AV_CODEC_CAP_DELAY | AV_CODEC_CAP_AVOID_PROBING,
    /* the thread count goes to the software decoder; the inner open takes
     * h264_mmal's init lock itself */
    .caps_internal  = FF_CODEC_CAP_AUTO_THREADS | FF_CODEC_CAP_INIT_CLEANUP |
                      FF_CODEC_CAP_SETS_FRAME_PROPS,
};
