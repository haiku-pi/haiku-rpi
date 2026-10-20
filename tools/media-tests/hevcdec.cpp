/*
 * hevcdec — decodes an HEVC stream twice through libavcodec: with the rpivid hardware decoder
 * ("hevc_rpivid", the Raspberry Pi 4's HEVC block; docs/design/hw-video-decode.md) and with
 * FFmpeg's CPU decoder ("hevc"), and compares every frame's MD5. Then measures both: the stream
 * read into memory first, decoded without looking at the frames, wall time and the CPU time the
 * process used (getrusage: every thread, user + kernel) per frame. "HEV " lines; exit status 0
 * when both decoded the same frames, every one of them on the block, and nothing differed.
 *
 *   hevcdec [-n FRAMES] [-v] [-cpu-only] [-no-bench] [-bench-only] [-hw-only] FILE...
 *
 *   -n FRAMES    decode at most FRAMES frames per pass
 *   -v           a line for every frame (default: the first 3 and every mismatch)
 *   -cpu-only    only the CPU pass (timing reference)
 *   -no-bench    no measurement passes
 *   -bench-only  only the measurement passes
 *   -hw-only     no CPU measurement pass (e.g. FFMPEG_RPIVID_UNCACHED=1 hevcdec -bench-only -hw-only:
 *                the pictures mapped write-combining, no cache maintenance, slower to read)
 *
 * Measurement passes: "cpu" (hevc, 4 frame threads, as the media kit's plugin opens it on the
 * Pi), "hw" (hevc_rpivid: the block, pipelined, SAND to planar on the slice threads), "hw-1t" (one
 * conversion thread), "hw-sync" (FFMPEG_RPIVID_SYNC=1: every picture decoded and converted
 * before the next, the first version). The CPU time of the driver's decode thread (a kernel
 * thread, a few register writes per phase) is not the process's and is not counted.
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
#include <sys/resource.h>

#include <algorithm>
#include <string>
#include <vector>

#define SAY(...) do { printf("HEV " __VA_ARGS__); printf("\n"); fflush(stdout); } while (0)


struct Pass {
	std::vector<std::string>	md5;
	std::vector<int64_t>		pts;
	int64_t						time = 0;		// microseconds, decode only
	int64_t						cpuTime = 0;	// microseconds, getrusage
	size_t						frames = 0;
	int							blockPictures = -1;
		// "rpivid: N pictures on the block" (when the decoder closed)
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
	const char* pictures = strstr(line, "rpivid: ");
	int count;
	if (sCurrentPass != NULL && pictures != NULL
		&& sscanf(pictures, "rpivid: %d pictures on the block", &count) == 1) {
		sCurrentPass->blockPictures = count;
	}
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
	av_frame_free(&frame);
	av_packet_free(&packet);
	// the hwaccel says how many pictures the block decoded when it goes
	avcodec_free_context(&context);
	sCurrentPass = NULL;
	avformat_close_input(&format);
	return true;
}


static int64_t
cpu_time()
{
	struct rusage usage;
	getrusage(RUSAGE_SELF, &usage);
	return (int64_t)(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000000
		+ usage.ru_utime.tv_usec + usage.ru_stime.tv_usec;
}


/*!	The measurement: the stream's packets read first, then decoded, the frames
	dropped as they come.
*/
static bool
bench(const char* path, const char* decoderName, int maxFrames, Pass& pass)
{
	AVFormatContext* format = NULL;
	if (avformat_open_input(&format, path, NULL, NULL) < 0
		|| avformat_find_stream_info(format, NULL) < 0) {
		avformat_close_input(&format);
		return false;
	}
	const int stream = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1,
		NULL, 0);
	const AVCodec* codec = avcodec_find_decoder_by_name(decoderName);
	if (stream < 0 || codec == NULL) {
		avformat_close_input(&format);
		return false;
	}
	std::vector<AVPacket*> packets;
	AVPacket* packet = av_packet_alloc();
	while (av_read_frame(format, packet) >= 0) {
		if (packet->stream_index == stream)
			packets.push_back(av_packet_clone(packet));
		av_packet_unref(packet);
	}
	av_packet_free(&packet);

	AVCodecContext* context = avcodec_alloc_context3(codec);
	avcodec_parameters_to_context(context, format->streams[stream]->codecpar);
	context->thread_count = 4;
	context->err_recognition = AV_EF_CAREFUL;
	if (avcodec_open2(context, codec, NULL) < 0) {
		avcodec_free_context(&context);
		avformat_close_input(&format);
		return false;
	}

	sCurrentPass = &pass;
	AVFrame* frame = av_frame_alloc();
	const int64_t start = av_gettime_relative();
	const int64_t cpuStart = cpu_time();
	size_t next = 0;
	bool done = false;
	while (!done) {
		if (next <= packets.size()) {
			const int status = avcodec_send_packet(context,
				next < packets.size() ? packets[next] : NULL);
			if (status != AVERROR(EAGAIN))
				next++;
		}
		for (;;) {
			const int status = avcodec_receive_frame(context, frame);
			if (status == AVERROR_EOF) {
				done = true;
				break;
			}
			if (status < 0)
				break;
			av_frame_unref(frame);
			pass.frames++;
			if (maxFrames > 0 && (int)pass.frames >= maxFrames) {
				done = true;
				break;
			}
		}
	}
	pass.time = av_gettime_relative() - start;
	pass.cpuTime = cpu_time() - cpuStart;

	av_frame_free(&frame);
	avcodec_free_context(&context);
	sCurrentPass = NULL;
	for (AVPacket*& p : packets)
		av_packet_free(&p);
	avformat_close_input(&format);
	return true;
}


static void
say_bench(const char* path, const char* label, const Pass& pass, const char* what)
{
	const double frames = pass.frames > 0 ? pass.frames : 1;
	SAY("bench %s %s: %zu frames, %.2f ms per frame (%.1f fps), CPU %.2f ms per frame "
		"(%.2f cores) [%s]", path, label, pass.frames, pass.time / 1000.0 / frames,
		pass.time > 0 ? pass.frames * 1000000.0 / pass.time : 0.0,
		pass.cpuTime / 1000.0 / frames,
		pass.time > 0 ? (double)pass.cpuTime / pass.time : 0.0, what);
}


static void
run_bench(const char* path, int maxFrames, bool hwOnly)
{
	struct Variant {
		const char*	label;
		const char*	decoder;
		const char*	sync;
		const char*	threads;
	};
	static const Variant kVariants[] = {
		{ "cpu", "hevc", NULL, NULL },
		{ "hw", "hevc_rpivid", NULL, NULL },
		{ "hw-1t", "hevc_rpivid", NULL, "1" },
		{ "hw-sync", "hevc_rpivid", "1", "1" },
	};
	Pass passes[4];
	for (int i = hwOnly ? 1 : 0; i < 4; i++) {
		const Variant& variant = kVariants[i];
		if (variant.sync != NULL)
			setenv("FFMPEG_RPIVID_SYNC", variant.sync, 1);
		if (variant.threads != NULL)
			setenv("FFMPEG_RPIVID_CONVERT_THREADS", variant.threads, 1);
		const bool ok = bench(path, variant.decoder, maxFrames, passes[i]);
		unsetenv("FFMPEG_RPIVID_SYNC");
		unsetenv("FFMPEG_RPIVID_CONVERT_THREADS");
		if (!ok) {
			SAY("bench %s %s: cannot decode", path, variant.label);
			return;
		}
		char what[160];
		if (i == 0)
			snprintf(what, sizeof(what), "hevc, 4 frame threads");
		else {
			snprintf(what, sizeof(what), "hevc_rpivid %s, %s, %d/%zu pictures on the block",
				variant.sync != NULL ? "synchronous" : "pipelined",
				variant.threads != NULL ? "1 conversion thread" : "default conversion threads",
				passes[i].blockPictures, passes[i].frames);
		}
		say_bench(path, variant.label, passes[i], what);
	}

	const Pass& cpu = passes[0];
	const Pass& hw = passes[1];
	if (hwOnly || cpu.frames == 0 || hw.frames == 0 || cpu.time == 0 || hw.time == 0)
		return;
	const double cpuFps = cpu.frames * 1000000.0 / cpu.time;
	const double hwFps = hw.frames * 1000000.0 / hw.time;
	const double cpuPerFrame = cpu.cpuTime / 1000.0 / cpu.frames;
	const double hwPerFrame = hw.cpuTime / 1000.0 / hw.frames;
	SAY("speed %s: hw %.1f fps vs CPU %.1f fps (%.2fx); CPU time per frame hw %.2f ms vs "
		"CPU %.2f ms (%.1fx less)%s", path, hwFps, cpuFps, hwFps / cpuFps, hwPerFrame,
		cpuPerFrame, hwPerFrame > 0 ? cpuPerFrame / hwPerFrame : 0.0,
		hw.blockPictures == (int)hw.frames ? "" : " - NOT ALL PICTURES ON THE BLOCK");
}


int
main(int argc, char** argv)
{
	int maxFrames = 0;
	bool verbose = false, cpuOnly = false, doBench = true, benchOnly = false;
	bool hwOnly = false;
	int first = 1;
	for (; first < argc && argv[first][0] == '-'; first++) {
		if (strcmp(argv[first], "-n") == 0 && first + 1 < argc)
			maxFrames = atoi(argv[++first]);
		else if (strcmp(argv[first], "-v") == 0)
			verbose = true;
		else if (strcmp(argv[first], "-cpu-only") == 0)
			cpuOnly = true;
		else if (strcmp(argv[first], "-no-bench") == 0)
			doBench = false;
		else if (strcmp(argv[first], "-bench-only") == 0)
			benchOnly = true;
		else if (strcmp(argv[first], "-hw-only") == 0)
			hwOnly = true;
		else
			break;
	}
	if (first >= argc) {
		fprintf(stderr, "usage: %s [-n FRAMES] [-v] [-cpu-only] [-no-bench] "
			"[-bench-only] [-hw-only] FILE...\n", argv[0]);
		return 2;
	}
	av_log_set_callback(log_callback);

	int failures = 0;
	for (int i = first; i < argc; i++) {
		const char* path = argv[i];
		if (benchOnly) {
			run_bench(path, maxFrames, hwOnly);
			continue;
		}
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
		// every frame from the block: a fallback to the CPU decoder (no memory
		// for the pictures, say) must not pass for the block
		const bool pass = mismatches == 0 && hardware.blockUsed
			&& !hardware.md5.empty()
			&& hardware.blockPictures == (int)hardware.md5.size();
		SAY("result %s %s: frames=%zu/%zu mismatches=%zu block=%d/%zu pictures, hw %.2f ms "
			"per frame, CPU %.2f (with MD5s)", pass ? "PASS" : "FAIL", path,
			hardware.md5.size(), software.md5.size(), mismatches, hardware.blockPictures,
			hardware.md5.size(),
			hardware.md5.empty() ? 0.0 : hardware.time / 1000.0 / hardware.md5.size(),
			software.md5.empty() ? 0.0 : software.time / 1000.0 / software.md5.size());
		if (!pass)
			failures++;
		if (doBench)
			run_bench(path, maxFrames, hwOnly);
	}
	return failures == 0 ? 0 : 1;
}
