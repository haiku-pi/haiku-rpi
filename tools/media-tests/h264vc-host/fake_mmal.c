/* A stand-in for h264_mmal on the host: the software decoder in a nested
 * context, with h264_mmal's output habits (no pkt_dts, no duration, no key
 * flag) and failures on request: FAKE_OPEN_FAIL=1 (open fails),
 * FAKE_FAIL_AT=N (an error from the Nth packet on). */
#include <stdlib.h>
#include <stdio.h>
#include "libavcodec/avcodec.h"
#include "libavcodec/codec_internal.h"
#include "libavcodec/decode.h"
extern const FFCodec ff_h264_decoder;
typedef struct { AVCodecContext *d; AVPacket *pkt; int packets, failed, total, eof; AVFrame *q[32]; int nq; } Fake;
static int fake_init(AVCodecContext *avctx)
{
    Fake *f = avctx->priv_data;
    const char *e = getenv("FAKE_OPEN_FAIL");
    if (e && *e == '1') return AVERROR(ENOSPC);
    f->d = avcodec_alloc_context3(&ff_h264_decoder.p);
    f->pkt = av_packet_alloc();
    { AVCodecParameters *par = avcodec_parameters_alloc();
      avcodec_parameters_from_context(par, avctx); avcodec_parameters_to_context(f->d, par);
      avcodec_parameters_free(&par); }
    f->d->thread_count = 1;
    avctx->pix_fmt = AV_PIX_FMT_YUV420P;
    return avcodec_open2(f->d, &ff_h264_decoder.p, NULL);
}
static int fake_close(AVCodecContext *avctx)
{
    Fake *f = avctx->priv_data;
    avcodec_free_context(&f->d); av_packet_free(&f->pkt); return 0;
}
static void fake_flush(AVCodecContext *avctx) { Fake *f = avctx->priv_data; avcodec_flush_buffers(f->d); while (f->nq) av_frame_free(&f->q[--f->nq]); f->total = f->eof = 0; }
static void strip(AVFrame *q) { q->pkt_dts = AV_NOPTS_VALUE; q->duration = 0; q->flags &= ~AV_FRAME_FLAG_KEY; }
/* frames are held back until 8 packets were taken (as h264_mmal does) */
static int fake_receive(AVCodecContext *avctx, AVFrame *frame)
{
    Fake *f = avctx->priv_data;
    const char *e = getenv("FAKE_FAIL_AT");
    int ret;
    if (f->failed) return AVERROR_EXTERNAL;
    for (;;) {
        if (f->nq && (f->total >= 8 || f->eof)) {
            av_frame_move_ref(frame, f->q[0]); av_frame_free(&f->q[0]);
            memmove(f->q, f->q + 1, --f->nq * sizeof(f->q[0]));
            return 0;
        }
        ret = avcodec_receive_frame(f->d, frame);
        if (ret == 0) {
            strip(frame);
            if (f->total >= 8 || f->eof) { if (!f->nq) return 0; }
            f->q[f->nq] = av_frame_alloc(); av_frame_move_ref(f->q[f->nq++], frame);
            continue;
        }
        if (ret == AVERROR_EOF) { if (f->nq) continue; return ret; }
        if (ret != AVERROR(EAGAIN)) return ret;
        ret = ff_decode_get_packet(avctx, f->pkt);
        if (ret == AVERROR_EOF) { f->eof = 1; avcodec_send_packet(f->d, NULL); continue; }
        if (ret < 0) return ret;
        f->total++; if (getenv("FAKE_DEBUG")) fprintf(stderr, "fake pkt pts %lld size %d flags %d\n", (long long)f->pkt->pts, f->pkt->size, f->pkt->flags);
        if (e && ++f->packets >= atoi(e)) { f->failed = 1; av_packet_unref(f->pkt); return AVERROR_EXTERNAL; }
        ret = avcodec_send_packet(f->d, f->pkt);
        av_packet_unref(f->pkt);
        if (ret < 0) return ret;
    }
}
const FFCodec ff_h264_mmal_decoder = {
    .p.name = "h264_mmal", .p.type = AVMEDIA_TYPE_VIDEO, .p.id = AV_CODEC_ID_H264,
    .priv_data_size = sizeof(Fake), .init = fake_init, .close = fake_close,
    FF_CODEC_RECEIVE_FRAME_CB(fake_receive), .flush = fake_flush,
    .p.capabilities = AV_CODEC_CAP_DELAY | AV_CODEC_CAP_HARDWARE,
    .caps_internal = FF_CODEC_CAP_NOT_INIT_THREADSAFE,
};
