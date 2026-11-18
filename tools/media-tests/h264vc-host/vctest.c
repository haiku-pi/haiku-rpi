/* vctest FILE ref|vc [SEEK_AFTER_FRAMES] : one line per frame: pts dts duration key md5 */
#include <stdio.h>
#include <stdlib.h>
#include "libavformat/avformat.h"
#include "libavcodec/avcodec.h"
#include "libavcodec/codec_internal.h"
#include "libavutil/md5.h"
#include "libavutil/pixdesc.h"
extern const FFCodec ff_h264_decoder, ff_h264_vc_decoder;
static int nframes;
static void out(AVCodecContext *c, AVFrame *f)
{
    uint8_t d[16]; struct AVMD5 *m = av_md5_alloc(); av_md5_init(m);
    for (int p = 0; p < 3; p++) {
        int w = p ? f->width / 2 : f->width, h = p ? f->height / 2 : f->height;
        for (int y = 0; y < h; y++) av_md5_update(m, f->data[p] + y * f->linesize[p], w);
    }
    av_md5_final(m, d); av_free(m);
    printf("%lld %lld %lld %d %s ", (long long)f->pts, (long long)f->pkt_dts, (long long)f->duration,
           !!(f->flags & AV_FRAME_FLAG_KEY), av_get_pix_fmt_name(c->pix_fmt));
    for (int i = 0; i < 16; i++) printf("%02x", d[i]);
    printf("\n"); nframes++;
}
int main(int argc, char **argv)
{
    AVFormatContext *fmt = NULL; AVPacket *pkt = av_packet_alloc(); AVFrame *fr = av_frame_alloc();
    int seek_after = argc > 3 ? atoi(argv[3]) : -1, seeked = 0, vs, ret;
    extern const FFCodec ff_h264_mmal_decoder; const AVCodec *codec = !strcmp(argv[2], "vc") ? &ff_h264_vc_decoder.p : !strcmp(argv[2], "fake") ? &ff_h264_mmal_decoder.p : &ff_h264_decoder.p;
    if (avformat_open_input(&fmt, argv[1], NULL, NULL) < 0 || avformat_find_stream_info(fmt, NULL) < 0) return 1;
    vs = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    AVCodecContext *c = avcodec_alloc_context3(codec);
    avcodec_parameters_to_context(c, fmt->streams[vs]->codecpar);
    c->pkt_timebase = fmt->streams[vs]->time_base;
    c->thread_count = getenv("THREADS") ? atoi(getenv("THREADS")) : 3; c->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;
    if ((ret = avcodec_open2(c, codec, NULL)) < 0) { fprintf(stderr, "open %d\n", ret); return 1; }
    fprintf(stderr, "opened %s pix_fmt %s\n", codec->name, av_get_pix_fmt_name(c->pix_fmt));
    while (av_read_frame(fmt, pkt) >= 0) {
        if (pkt->stream_index != vs) { av_packet_unref(pkt); continue; }
        if ((ret = avcodec_send_packet(c, pkt)) < 0) { fprintf(stderr, "send %d\n", ret); return 1; }
        av_packet_unref(pkt);
        while ((ret = avcodec_receive_frame(c, fr)) == 0) {
            out(c, fr); av_frame_unref(fr);
            if (!seeked && seek_after >= 0 && nframes == seek_after) {
                seeked = 1; printf("SEEK\n");
                av_seek_frame(fmt, vs, 0, AVSEEK_FLAG_BACKWARD); avcodec_flush_buffers(c);
                break;
            }
        }
        if (ret != AVERROR(EAGAIN) && ret != 0) { fprintf(stderr, "receive %d\n", ret); return 1; }
    }
    avcodec_send_packet(c, NULL);
    while ((ret = avcodec_receive_frame(c, fr)) == 0) { out(c, fr); av_frame_unref(fr); }
    fprintf(stderr, "end %d after %d frames\n", ret, nframes);
    avcodec_free_context(&c); avformat_close_input(&fmt);
    return ret == AVERROR_EOF ? 0 : 1;
}
