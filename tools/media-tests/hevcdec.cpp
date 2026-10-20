/*
 * hevcdec — decodes an HEVC stream twice through libavcodec: with the rpivid hardware decoder
 * ("hevc_rpivid", the Raspberry Pi 4's HEVC block; docs/design/hw-video-decode.md) and with
 * FFmpeg's CPU decoder ("hevc"), and compares every frame's MD5. "HEV " lines; exit status 0
 * when both decoded the same frames, the block took the stream, and nothing differed.
 *
 *   hevcdec [-n FRAMES] [-v] [-cpu-only] FILE...
 *
 *   -n FRAMES   decode at most FRAMES frames per pass
 *   -v          a line for every frame (default: the first 3 and every mismatch)
 *   -cpu-only   only the CPU pass (timing reference)
 *
 * The libavcodec messages of the hardware pass that start with "rpivid:" are printed as
 * "HEV log ..." (why the block was or was not used, its timing). FFMPEG_RPIVID=0|1|2 is honoured
 * (0: hevc_rpivid decodes on the CPU too).
 */

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/hash.h>
#include <libavutil/imgutils.h>
#include <libavutil/log.h>
#include <libavutil/time.h>
}

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <algorithm>
#include <string>
#include <vector>

#define SAY(...) do { printf("HEV " __VA_ARGS__); printf("\n"); fflush(stdout); } while (0)


struct Pass {
	std::vector<std::string>	md5;
	std::vector<int64_t>		pts;
	int64_t						time = 0;		// microseconds, decode only
	bool						blockUsed = false;
	bool						failed = false;
	int							width = 0;
	int							height = 0;
	AVPixelFormat				format = AV_PIX_FMT_NONE;
};


static bool sHardwarePass = false;
static Pass* sCurrentPass = NULL;


static void
log_callback(void* object, int level, const char* format, va_list args)
{
	if (level > AV_LOG_INFO || strstr(format, "rpivid") == NULL) {
		if (level <= AV_LOG_ERROR)
			av_log_default_callback(object, level, format, args);
		return;
	}
	char line[512];
	vsnprintf(line, sizeof(line), format, args);
	size_t length = strlen(line);
	while (length > 0 && line[length - 1] == '\n')
		line[--length] = '\0';
	if (sCurrentPass != NULL && strstr(line, "rpivid: hardware HEVC decode") != NULL)
		sCurrentPass->blockUsed = true;
	if (sHardwarePass)
		SAY("log %s", line);
}


static std::string
frame_md5(const AVFrame* frame)
{
	// the visible picture, plane by plane, as framemd5 hashes it
	AVHashContext* hash;
	if (av_hash_alloc(&hash, "md5") < 0)
		return "?";
	av_hash_init(hash);
	const AVPixFmtDescriptor* descriptor = av_pix_fmt_desc_get(
		(AVPixelFormat)frame->format);
	const int bytesPerSample = descriptor->comp[0].depth > 8 ? 2 : 1;
	for (int plane = 0; plane < 3 && frame->data[plane] != NULL; plane++) {
		const int width = plane == 0 ? frame->width
			: AV_CEIL_RSHIFT(frame->width, descriptor->log2_chroma_w);
		const int height = plane == 0 ? frame->height
			: AV_CEIL_RSHIFT(frame->height, descriptor->log2_chroma_h);
		for (int y = 0; y < height; y++) {
			av_hash_update(hash, frame->data[plane] + y * frame->linesize[plane],
				width * bytesPerSample);
		}
	}
	char text[AV_HASH_MAX_SIZE * 2 + 1];
	av_hash_final_hex(hash, (uint8_t*)text, sizeof(text));
	av_hash_freep(&hash);
	return text;
}


static bool
decode(const char* path, const char* decoderName, int maxFrames, Pass& pass)
{
	AVFormatContext* format = NULL;
	if (avformat_open_input(&format, path, NULL, NULL) < 0
		|| avformat_find_stream_info(format, NULL) < 0) {
		SAY("%s: cannot open", path);
		avformat_close_input(&format);
		return false;
	}
	const int stream = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1,
		NULL, 0);
	const AVCodec* codec = avcodec_find_decoder_by_name(decoderName);
	if (stream < 0 || codec == NULL
		|| format->streams[stream]->codecpar->codec_id != AV_CODEC_ID_HEVC) {
		SAY("%s: no HEVC video stream, or no decoder %s", path, decoderName);
		avformat_close_input(&format);
		return false;
	}

	AVCodecContext* context = avcodec_alloc_context3(codec);
	avcodec_parameters_to_context(context, format->streams[stream]->codecpar);
	// as the media kit's ffmpeg plugin opens decoders
	context->thread_count = 4;
	context->err_recognition = AV_EF_CAREFUL;
	if (avcodec_open2(context, codec, NULL) < 0) {
		SAY("%s: cannot open decoder %s", path, decoderName);
		avcodec_free_context(&context);
		avformat_close_input(&format);
		return false;
	}

	sCurrentPass = &pass;
	AVPacket* packet = av_packet_alloc();
	AVFrame* frame = av_frame_alloc();
	bool done = false, flushing = false;
	while (!done) {
		if (!flushing) {
			int status = av_read_frame(format, packet);
			if (status < 0) {
				flushing = true;
				avcodec_send_packet(context, NULL);
			} else {
				if (packet->stream_index == stream) {
					const int64_t start = av_gettime_relative();
					status = avcodec_send_packet(context, packet);
					pass.time += av_gettime_relative() - start;
					if (status < 0 && status != AVERROR(EAGAIN))
						pass.failed = true;
				}
				av_packet_unref(packet);
			}
		}
		for (;;) {
			const int64_t start = av_gettime_relative();
			const int status = avcodec_receive_frame(context, frame);
			pass.time += av_gettime_relative() - start;
			if (status == AVERROR_EOF) {
				done = true;
				break;
			}
			if (status < 0)
				break;
			pass.md5.push_back(frame_md5(frame));
			pass.pts.push_back(frame->pts);
			pass.width = frame->width;
			pass.height = frame->height;
			pass.format = (AVPixelFormat)frame->format;
			av_frame_unref(frame);
			if (maxFrames > 0 && (int)pass.md5.size() >= maxFrames) {
				done = true;
				break;
			}
		}
	}
	sCurrentPass = NULL;

	av_frame_free(&frame);
	av_packet_free(&packet);
	avcodec_free_context(&context);
	avformat_close_input(&format);
	return true;
}


int
main(int argc, char** argv)
{
	int maxFrames = 0;
	bool verbose = false, cpuOnly = false;
	int first = 1;
	for (; first < argc && argv[first][0] == '-'; first++) {
		if (strcmp(argv[first], "-n") == 0 && first + 1 < argc)
			maxFrames = atoi(argv[++first]);
		else if (strcmp(argv[first], "-v") == 0)
			verbose = true;
		else if (strcmp(argv[first], "-cpu-only") == 0)
			cpuOnly = true;
		else
			break;
	}
	if (first >= argc) {
		fprintf(stderr, "usage: %s [-n FRAMES] [-v] [-cpu-only] FILE...\n",
			argv[0]);
		return 2;
	}
	av_log_set_callback(log_callback);

	int failures = 0;
	for (int i = first; i < argc; i++) {
		const char* path = argv[i];
		Pass software, hardware;
		if (!decode(path, "hevc", maxFrames, software)) {
			failures++;
			continue;
		}
		SAY("file %s: %dx%d %s, %zu frames, CPU %.2f ms per frame", path,
			software.width, software.height, av_get_pix_fmt_name(software.format),
			software.md5.size(),
			software.md5.empty() ? 0.0 : software.time / 1000.0 / software.md5.size());
		if (cpuOnly)
			continue;

		sHardwarePass = true;
		const bool opened = decode(path, "hevc_rpivid", maxFrames, hardware);
		sHardwarePass = false;
		if (!opened) {
			failures++;
			continue;
		}

		size_t mismatches = 0, shown = 0;
		const size_t count = std::max(software.md5.size(), hardware.md5.size());
		for (size_t frame = 0; frame < count; frame++) {
			const char* hw = frame < hardware.md5.size()
				? hardware.md5[frame].c_str() : "-";
			const char* sw = frame < software.md5.size()
				? software.md5[frame].c_str() : "-";
			const bool same = strcmp(hw, sw) == 0;
			if (!same)
				mismatches++;
			if (verbose || frame < 3 || (!same && shown++ < 10)) {
				SAY("frame %zu %s hw=%s cpu=%s", frame, same ? "match" : "MISMATCH",
					hw, sw);
			}
		}
		const bool pass = mismatches == 0 && hardware.blockUsed
			&& !hardware.md5.empty();
		SAY("result %s %s: frames=%zu/%zu mismatches=%zu block=%d hw %.2f ms per "
			"frame, CPU %.2f", pass ? "PASS" : "FAIL", path, hardware.md5.size(),
			software.md5.size(), mismatches, hardware.blockUsed ? 1 : 0,
			hardware.md5.empty() ? 0.0 : hardware.time / 1000.0 / hardware.md5.size(),
			software.md5.empty() ? 0.0 : software.time / 1000.0 / software.md5.size());
		if (!pass)
			failures++;
	}
	return failures == 0 ? 0 : 1;
}
