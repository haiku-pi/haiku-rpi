/* vctwo FILE : the VideoCore slot of h264_vc (one stream per process): two h264_vc contexts decode FILE at once
 * (the first takes h264_mmal, the second must go to h264), then the first is closed and a third opened (it must
 * get h264_mmal again). Prints which inner decoder each used and the frames each gave; exit 0 when as expected. */
#include <stdio.h>
#include <string.h>
#include "libavformat/avformat.h"
#include "libavcodec/avcodec.h"
#include "libavcodec/codec_internal.h"
extern const FFCodec ff_h264_vc_decoder;
static char lastlog[256];
static void logcb(void *p, int level, const char *fmt, va_list vl)
{
    char line[256];
    vsnprintf(line, sizeof(line), fmt, vl);
    if (strstr(line, "VideoCore decodes another") || strstr(line, "h264_mmal decodes"))
        snprintf(lastlog, sizeof(lastlog), "%s", line);
    if (level <= AV_LOG_INFO)
        fputs(line, stderr);
}
static AVCodecContext *open_vc(AVFormatContext *fmt, int vs)
{
    AVCodecContext *c = avcodec_alloc_context3(&ff_h264_vc_decoder.p);
    avcodec_parameters_to_context(c, fmt->streams[vs]->codecpar);
    c->pkt_timebase = fmt->streams[vs]->time_base;
    c->thread_count = 1;
    if (avcodec_open2(c, &ff_h264_vc_decoder.p, NULL) < 0)
        return NULL;
    return c;
}
/* frames from N packets; *used: 1 if the first packet made it take the VideoCore */
static int decode(AVFormatContext *fmt, int vs, AVCodecContext *c, int n, int *used)
{
    AVPacket *pkt = av_packet_alloc(); AVFrame *fr = av_frame_alloc(); int frames = 0, sent = 0;
    av_seek_frame(fmt, vs, 0, AVSEEK_FLAG_BACKWARD);
    lastlog[0] = 0;
    while (sent < n && av_read_frame(fmt, pkt) >= 0) {
        if (pkt->stream_index != vs) { av_packet_unref(pkt); continue; }
        avcodec_send_packet(c, pkt); av_packet_unref(pkt); sent++;
        while (avcodec_receive_frame(c, fr) == 0) { frames++; av_frame_unref(fr); }
        if (sent == 1) *used = strstr(lastlog, "h264_mmal decodes") != NULL;
    }
    av_packet_free(&pkt); av_frame_free(&fr);
    return frames;
}
int main(int argc, char **argv)
{
    AVFormatContext *fmt = NULL; int vs, u1 = -1, u2 = -1, u3 = -1, f1, f2, f3;
    av_log_set_callback(logcb);
    av_log_set_level(AV_LOG_VERBOSE);
    if (argc < 2 || avformat_open_input(&fmt, argv[1], NULL, NULL) < 0 || avformat_find_stream_info(fmt, NULL) < 0)
        return 2;
    vs = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    AVCodecContext *c1 = open_vc(fmt, vs), *c2 = open_vc(fmt, vs), *c3;
    f1 = decode(fmt, vs, c1, 30, &u1);
    f2 = decode(fmt, vs, c2, 30, &u2);
    avcodec_free_context(&c1);
    c3 = open_vc(fmt, vs);
    f3 = decode(fmt, vs, c3, 30, &u3);
    printf("vctwo: first VideoCore %d (%d frames), second %d (%d frames), third after the first closed %d (%d frames)\n",
           u1, f1, u2, f2, u3, f3);
    avcodec_free_context(&c2); avcodec_free_context(&c3); avformat_close_input(&fmt);
    return u1 == 1 && u2 == 0 && u3 == 1 && f1 > 0 && f2 > 0 && f3 > 0 ? 0 : 1;
}
