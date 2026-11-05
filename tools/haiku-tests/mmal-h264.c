/*
 * mmal-h264 — H.264 decoding on the VideoCore through MMAL (vc.ril.video_decode) and /dev/vchiq:
 * the H21 step 2 test (docs/design/vchiq.md).
 *
 *   mmal-h264 [-m] [-q] [-i N] [-o N] [-e] [-f FOURCC] [-d N:FILE] [-r N:FILE] FILE.h264
 *
 * FILE: an H.264 Annex-B elementary stream, read into memory first. It is fed to the decoder in buffers of
 * the input port's size (not framed: the decoder finds the access units), then an end-of-stream buffer; the
 * decoded I420 frames come back by VCHIQ bulk transfers (no zero-copy) until the one flagged end of stream.
 * -m: print "MMAL framemd5 N <md5>" for every frame, the MD5 of its visible part (the crop rectangle; the
 *     Y, U and V planes one after the other), what ffmpeg -f framemd5 of yuv420p frames hashes;
 * -f FOURCC: the output encoding (default I420; the hashes and -d need I420), e.g. SAND, YV12, NV12;
 * -r N:FILE: write the whole output buffer of frame N to FILE (any encoding: for working out a layout);
 * -d N:FILE: write the visible part of frame N to FILE (raw yuv420p, as ffmpeg -f rawvideo writes it);
 * -i N / -o N: N input / output buffers (default: the ports' recommended numbers);
 * -e: list the ports' supported encodings;
 * -q: no per-event lines.
 * Settings FFmpeg's h264_mmal decoder uses (to compare): -X N: MMAL_PARAMETER_EXTRA_BUFFERS N on the output port;
 * -C N: MMAL_PARAMETER_VIDEO_MAX_NUM_CALLBACKS N on the input port; -P: the output buffers from a plain pool
 * (mmal_pool_create) instead of the port's; -Z: input buffers without payload pointing into the stream in memory
 * (header-only pool) instead of copies; -A: framed input (MMAL_ES_FORMAT_FLAG_FRAMED), one access unit per buffer
 * (or several buffers, the last flagged FRAME_END) with a pts each; -K: the bytes before the first slice (the
 * parameter sets) first, as a buffer flagged CONFIG.
 * The last lines: frames, wall time, frames/s, the CPU time of this team and of the whole system (all CPUs,
 * busy time: the driver's threads that copy the frames are not this team's) during the decode.
 *
 * Copyright 2026, Haiku-Pi project. Distributed under the terms of the MIT License.
 */
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <unistd.h>

#include <OS.h>

#include "interface/mmal/mmal.h"
#include "interface/mmal/util/mmal_default_components.h"
#include "interface/mmal/util/mmal_util.h"
#include "interface/mmal/util/mmal_util_params.h"
#include "interface/vcos/vcos.h"


/* MD5 (RFC 1321) */
typedef struct {
	uint32_t state[4];
	uint64_t length;
	uint8_t buffer[64];
} md5_context;

static const uint32_t kMD5K[64] = {
	0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
	0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
	0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
	0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
	0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
	0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
	0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
	0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
};
static const uint8_t kMD5Shift[64] = {
	7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
	5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
	4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
	6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
};

static void
md5_block(md5_context* md5, const uint8_t* block)
{
	uint32_t m[16];
	uint32_t a = md5->state[0], b = md5->state[1], c = md5->state[2], d = md5->state[3];
	int i;

	for (i = 0; i < 16; i++) {
		m[i] = (uint32_t)block[i * 4] | (uint32_t)block[i * 4 + 1] << 8
			| (uint32_t)block[i * 4 + 2] << 16 | (uint32_t)block[i * 4 + 3] << 24;
	}
	for (i = 0; i < 64; i++) {
		uint32_t f, g, t;
		if (i < 16) {
			f = (b & c) | (~b & d);
			g = i;
		} else if (i < 32) {
			f = (d & b) | (~d & c);
			g = (5 * i + 1) % 16;
		} else if (i < 48) {
			f = b ^ c ^ d;
			g = (3 * i + 5) % 16;
		} else {
			f = c ^ (b | ~d);
			g = (7 * i) % 16;
		}
		t = d;
		d = c;
		c = b;
		f += a + kMD5K[i] + m[g];
		b += (f << kMD5Shift[i]) | (f >> (32 - kMD5Shift[i]));
		a = t;
	}
	md5->state[0] += a;
	md5->state[1] += b;
	md5->state[2] += c;
	md5->state[3] += d;
}

static void
md5_init(md5_context* md5)
{
	md5->state[0] = 0x67452301;
	md5->state[1] = 0xefcdab89;
	md5->state[2] = 0x98badcfe;
	md5->state[3] = 0x10325476;
	md5->length = 0;
}

static void
md5_update(md5_context* md5, const uint8_t* data, size_t size)
{
	size_t used = md5->length % 64;
	md5->length += size;
	if (used > 0) {
		size_t part = 64 - used < size ? 64 - used : size;
		memcpy(md5->buffer + used, data, part);
		data += part;
		size -= part;
		if (used + part < 64)
			return;
		md5_block(md5, md5->buffer);
	}
	for (; size >= 64; data += 64, size -= 64)
		md5_block(md5, data);
	memcpy(md5->buffer, data, size);
}

static void
md5_final(md5_context* md5, char hex[33])
{
	uint64_t bits = md5->length * 8;
	uint8_t pad[72] = { 0x80 };
	size_t padSize = (md5->length % 64 < 56 ? 56 : 120) - md5->length % 64;
	int i;

	for (i = 0; i < 8; i++)
		pad[padSize + i] = (uint8_t)(bits >> (8 * i));
	md5_update(md5, pad, padSize + 8);
	for (i = 0; i < 16; i++)
		sprintf(hex + 2 * i, "%02x", (md5->state[i / 4] >> (8 * (i % 4))) & 0xff);
}


static struct {
	VCOS_SEMAPHORE_T semaphore;
	MMAL_QUEUE_T* queue;
	MMAL_STATUS_T status;
} sContext;

static int sQuiet = 0;


static void
control_callback(MMAL_PORT_T* port, MMAL_BUFFER_HEADER_T* buffer)
{
	if (buffer->cmd == MMAL_EVENT_ERROR)
		sContext.status = *(MMAL_STATUS_T*)buffer->data;
	mmal_buffer_header_release(buffer);
	vcos_semaphore_post(&sContext.semaphore);
}


static void
input_callback(MMAL_PORT_T* port, MMAL_BUFFER_HEADER_T* buffer)
{
	mmal_buffer_header_release(buffer);
	vcos_semaphore_post(&sContext.semaphore);
}


static void
output_callback(MMAL_PORT_T* port, MMAL_BUFFER_HEADER_T* buffer)
{
	mmal_queue_put(sContext.queue, buffer);
	vcos_semaphore_post(&sContext.semaphore);
}


static const char*
fourcc(uint32_t value, char text[5])
{
	int i;
	for (i = 0; i < 4; i++) {
		char c = (char)(value >> (8 * i));
		text[i] = c >= 32 && c < 127 ? c : '?';
	}
	text[4] = '\0';
	return text;
}


static void
log_format(const char* what, MMAL_PORT_T* port)
{
	MMAL_ES_FORMAT_T* format = port->format;
	char text[5];
	printf("MMAL %s: %s %ux%u crop %d,%d %ux%u, buffers %u x %u bytes (min %u x %u, recommended %u x %u)\n",
		what, fourcc(format->encoding, text), format->es->video.width, format->es->video.height,
		format->es->video.crop.x, format->es->video.crop.y, format->es->video.crop.width,
		format->es->video.crop.height, port->buffer_num, port->buffer_size, port->buffer_num_min,
		port->buffer_size_min, port->buffer_num_recommended, port->buffer_size_recommended);
}


/* The visible part of an I420 frame: plane offsets and pitches from the buffer if the decoder gave them,
   else from the port's format (the plane heights are the format's, which the decoder aligns) */
static void
hash_frame(MMAL_PORT_T* port, MMAL_BUFFER_HEADER_T* buffer, char hex[33], FILE* dump)
{
	MMAL_VIDEO_FORMAT_T* video = &port->format->es->video;
	const uint8_t* data = buffer->data + buffer->offset;
	uint32_t offset[3], pitch[3];
	md5_context md5;
	int plane;

	if (buffer->type->video.planes == 3) {
		for (plane = 0; plane < 3; plane++) {
			offset[plane] = buffer->type->video.offset[plane];
			pitch[plane] = buffer->type->video.pitch[plane];
		}
	} else {
		pitch[0] = video->width;
		pitch[1] = pitch[2] = video->width / 2;
		offset[0] = 0;
		offset[1] = video->width * video->height;
		offset[2] = offset[1] + pitch[1] * (video->height / 2);
	}

	md5_init(&md5);
	for (plane = 0; plane < 3; plane++) {
		int shift = plane == 0 ? 0 : 1;
		uint32_t x = video->crop.x >> shift, y = video->crop.y >> shift;
		uint32_t width = video->crop.width >> shift, height = video->crop.height >> shift;
		uint32_t row;
		for (row = 0; row < height; row++) {
			const uint8_t* line = data + offset[plane] + (y + row) * pitch[plane] + x;
			md5_update(&md5, line, width);
			if (dump != NULL)
				fwrite(line, 1, width, dump);
		}
	}
	md5_final(&md5, hex);
}


static bigtime_t
system_busy_time(void)
{
	system_info info;
	cpu_info cpus[64];
	bigtime_t busy = 0;
	uint32_t i;

	get_system_info(&info);
	if (info.cpu_count > 64)
		info.cpu_count = 64;
	get_cpu_info(0, info.cpu_count, cpus);
	for (i = 0; i < info.cpu_count; i++)
		busy += cpus[i].active_time;
	return busy;
}


static bigtime_t
team_cpu_time(void)
{
	struct rusage usage;
	getrusage(RUSAGE_SELF, &usage);
	return (bigtime_t)(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000000
		+ usage.ru_utime.tv_usec + usage.ru_stime.tv_usec;
}


/* Where the access unit that starts at FROM ends: at the next access unit delimiter, SPS, PPS or SEI after a
   slice, or at the next slice whose first_mb_in_slice is 0 */
static size_t
access_unit_end(const uint8_t* s, size_t n, size_t from)
{
	int haveSlice = 0;
	size_t i = from;
	for (;;) {
		size_t sc = i, nal, begin;
		int type;
		while (sc + 3 <= n && !(s[sc] == 0 && s[sc + 1] == 0 && s[sc + 2] == 1))
			sc++;
		if (sc + 4 > n)
			return n;
		nal = sc + 3;
		type = s[nal] & 0x1f;
		begin = sc > from && s[sc - 1] == 0 ? sc - 1 : sc;
		if (haveSlice && begin > from) {
			if (type == 9 || type == 7 || type == 8 || type == 6)
				return begin;
			if ((type == 1 || type == 5) && nal + 1 < n && (s[nal + 1] & 0x80) != 0)
				return begin;
		}
		if (type == 1 || type == 5)
			haveSlice = 1;
		i = nal;
	}
}


/* the bytes before the first slice NAL unit */
static size_t
parameter_sets_end(const uint8_t* s, size_t n)
{
	size_t i;
	for (i = 0; i + 4 <= n; i++) {
		if (s[i] == 0 && s[i + 1] == 0 && s[i + 2] == 1
			&& ((s[i + 3] & 0x1f) == 1 || (s[i + 3] & 0x1f) == 5))
			return i > 0 && s[i - 1] == 0 ? i - 1 : i;
	}
	return 0;
}


#define CHECK(status, what) \
	if ((status) != MMAL_SUCCESS) { \
		fprintf(stderr, "MMAL FAIL: %s: %s\n", what, mmal_status_to_string(status)); \
		goto out; \
	}

int
main(int argc, char** argv)
{
	int hashFrames = 0, listEncodings = 0, inputBuffers = 0, outputBuffers = 0, dumpFrame = -1;
	const char* dumpFile = NULL;
	const char* rawFile = NULL;
	int rawFrame = -1;
	uint32_t outputEncoding = MMAL_ENCODING_I420;
	MMAL_COMPONENT_T* decoder = NULL;
	MMAL_POOL_T* inputPool = NULL;
	MMAL_POOL_T* outputPool = NULL;
	MMAL_STATUS_T status = MMAL_EINVAL;
	uint8_t* stream;
	size_t streamSize, fed = 0;
	int eosSent = 0, eosReceived = 0, frames = 0, formatChanges = 0, opt;
	int extraBuffers = -1, plainOutputPool = 0, zeroCopyInput = 0, framed = 0, config = 0;
	size_t auEnd = 0, configEnd = 0;
	int64_t accessUnits = 0;
	int64_t maxCallbacks = 0;
	bigtime_t start = 0, firstFrame = 0, end, teamStart = 0, busyStart = 0;
	uint64_t frameBytes = 0;
	system_info systemInfo;
	FILE* file;

	while ((opt = getopt(argc, argv, "mqei:o:d:f:r:X:C:PZAK")) != -1) {
		switch (opt) {
			case 'm': hashFrames = 1; break;
			case 'q': sQuiet = 1; break;
			case 'e': listEncodings = 1; break;
			case 'i': inputBuffers = atoi(optarg); break;
			case 'X': extraBuffers = atoi(optarg); break;
			case 'C': maxCallbacks = atoi(optarg); break;
			case 'P': plainOutputPool = 1; break;
			case 'Z': zeroCopyInput = 1; break;
			case 'A': framed = 1; break;
			case 'K': config = 1; break;
			case 'o': outputBuffers = atoi(optarg); break;
			case 'f':
				if (strlen(optarg) != 4) {
					fprintf(stderr, "-f: a four-character code\n");
					return 2;
				}
				outputEncoding = MMAL_FOURCC(optarg[0], optarg[1], optarg[2], optarg[3]);
				break;
			case 'r':
				rawFrame = atoi(optarg);
				rawFile = strchr(optarg, ':') != NULL ? strchr(optarg, ':') + 1 : NULL;
				break;
			case 'd':
				dumpFrame = atoi(optarg);
				dumpFile = strchr(optarg, ':') != NULL ? strchr(optarg, ':') + 1 : NULL;
				break;
			default:
				fprintf(stderr, "usage: %s [-m] [-q] [-e] [-i N] [-o N] [-f FOURCC] [-d N:FILE] [-r N:FILE] FILE.h264\n", argv[0]);
				return 2;
		}
	}
	if (optind != argc - 1) {
		fprintf(stderr, "usage: %s [-m] [-q] [-e] [-i N] [-o N] [-f FOURCC] [-d N:FILE] [-r N:FILE] FILE.h264\n", argv[0]);
		return 2;
	}

	file = fopen(argv[optind], "rb");
	if (file == NULL) {
		fprintf(stderr, "MMAL FAIL: %s: %s\n", argv[optind], strerror(errno));
		return 1;
	}
	fseek(file, 0, SEEK_END);
	streamSize = ftell(file);
	fseek(file, 0, SEEK_SET);
	stream = malloc(streamSize);
	if (stream == NULL || fread(stream, 1, streamSize, file) != streamSize) {
		fprintf(stderr, "MMAL FAIL: reading %s\n", argv[optind]);
		return 1;
	}
	fclose(file);

	vcos_semaphore_create(&sContext.semaphore, "mmal-h264", 1);
	sContext.queue = mmal_queue_create();

	status = mmal_component_create(MMAL_COMPONENT_DEFAULT_VIDEO_DECODER, &decoder);
	CHECK(status, "create " MMAL_COMPONENT_DEFAULT_VIDEO_DECODER);
	printf("MMAL component %s: %u inputs, %u outputs\n", decoder->name, decoder->input_num,
		decoder->output_num);

	decoder->control->userdata = (void*)&sContext;
	status = mmal_port_enable(decoder->control, control_callback);
	CHECK(status, "enable the control port");

	for (int i = 0; listEncodings && i < 2; i++) {
		MMAL_PORT_T* port = i == 0 ? decoder->input[0] : decoder->output[0];
		uint32_t buffer[64];
		MMAL_PARAMETER_HEADER_T* header = (MMAL_PARAMETER_HEADER_T*)buffer;
		header->id = MMAL_PARAMETER_SUPPORTED_ENCODINGS;
		header->size = sizeof(buffer);
		if (mmal_port_parameter_get(port, header) == MMAL_SUCCESS) {
			uint32_t count = (header->size - sizeof(*header)) / sizeof(uint32_t), j;
			char text[5];
			printf("MMAL %s encodings:", i == 0 ? "input" : "output");
			for (j = 0; j < count; j++)
				printf(" %s", fourcc(buffer[2 + j], text));
			printf("\n");
		}
	}

	/* H.264, size unknown: the stream's parameter sets give it (a format change event follows) */
	MMAL_ES_FORMAT_T* format = decoder->input[0]->format;
	format->type = MMAL_ES_TYPE_VIDEO;
	format->encoding = MMAL_ENCODING_H264;
	format->es->video.width = 0;
	format->es->video.height = 0;
	format->es->video.frame_rate.num = 0;
	format->es->video.frame_rate.den = 1;
	if (framed)
		format->flags |= MMAL_ES_FORMAT_FLAG_FRAMED;
	if (maxCallbacks != 0) {
		status = mmal_port_parameter_set_uint32(decoder->input[0], MMAL_PARAMETER_VIDEO_MAX_NUM_CALLBACKS,
			(uint32_t)maxCallbacks);
		printf("MMAL input MAX_NUM_CALLBACKS %d: %s\n", (int)maxCallbacks, mmal_status_to_string(status));
	}
	status = mmal_port_format_commit(decoder->input[0]);
	CHECK(status, "input format");
	if (extraBuffers >= 0) {
		status = mmal_port_parameter_set_uint32(decoder->output[0], MMAL_PARAMETER_EXTRA_BUFFERS,
			extraBuffers);
		printf("MMAL output EXTRA_BUFFERS %d: %s\n", extraBuffers, mmal_status_to_string(status));
	}

	decoder->output[0]->format->encoding = outputEncoding;
	status = mmal_port_format_commit(decoder->output[0]);
	CHECK(status, "output format");

	decoder->input[0]->buffer_num = inputBuffers > 0 ? (uint32_t)inputBuffers
		: decoder->input[0]->buffer_num_recommended;
	decoder->input[0]->buffer_size = decoder->input[0]->buffer_size_recommended;
	decoder->output[0]->buffer_num = outputBuffers > 0 ? (uint32_t)outputBuffers
		: decoder->output[0]->buffer_num_recommended;
	decoder->output[0]->buffer_size = decoder->output[0]->buffer_size_recommended;
	log_format("input", decoder->input[0]);
	log_format("output", decoder->output[0]);

	inputPool = zeroCopyInput ? mmal_pool_create(decoder->input[0]->buffer_num, 0)
		: mmal_port_pool_create(decoder->input[0], decoder->input[0]->buffer_num,
			decoder->input[0]->buffer_size);
	outputPool = plainOutputPool ? mmal_pool_create(decoder->output[0]->buffer_num,
			decoder->output[0]->buffer_size)
		: mmal_port_pool_create(decoder->output[0], decoder->output[0]->buffer_num,
			decoder->output[0]->buffer_size);
	if (inputPool == NULL || outputPool == NULL) {
		fprintf(stderr, "MMAL FAIL: buffer pools\n");
		goto out;
	}

	decoder->input[0]->userdata = (void*)&sContext;
	decoder->output[0]->userdata = (void*)&sContext;
	status = mmal_port_enable(decoder->input[0], input_callback);
	CHECK(status, "enable the input port");
	status = mmal_port_enable(decoder->output[0], output_callback);
	CHECK(status, "enable the output port");
	status = mmal_component_enable(decoder);
	CHECK(status, "enable the component");

	get_system_info(&systemInfo);
	start = system_time();
	teamStart = team_cpu_time();
	busyStart = system_busy_time();

	while (!eosReceived) {
		MMAL_BUFFER_HEADER_T* buffer;

		if (vcos_semaphore_wait_timeout(&sContext.semaphore, 10000) != VCOS_SUCCESS) {
			fprintf(stderr, "MMAL FAIL: nothing from the decoder for 10 s (%d frames, %zu of %zu bytes"
				" sent)\n", frames, fed, streamSize);
			status = MMAL_EAGAIN;
			goto out;
		}
		if (sContext.status != MMAL_SUCCESS) {
			status = sContext.status;
			CHECK(status, "error event from the decoder");
		}

		while (!eosSent && (buffer = mmal_queue_get(inputPool->queue)) != NULL) {
			size_t size = streamSize - fed;
			uint32_t flags = 0;
			int64_t pts = MMAL_TIME_UNKNOWN;
			if (config && fed == 0 && configEnd == 0) {
				configEnd = parameter_sets_end(stream, streamSize);
				size = configEnd;
				flags = MMAL_BUFFER_HEADER_FLAG_CONFIG;
			} else if (framed) {
				if (fed >= auEnd) {
					auEnd = access_unit_end(stream, streamSize, fed);
					pts = accessUnits++ * 33333;
				}
				size = auEnd - fed;
			}
			if (zeroCopyInput) {
				mmal_buffer_header_reset(buffer);
				buffer->cmd = 0;
				buffer->alloc_size = decoder->input[0]->buffer_size;
				buffer->data = stream + fed;
			}
			if (size > buffer->alloc_size)
				size = buffer->alloc_size;
			if (!zeroCopyInput)
				memcpy(buffer->data, stream + fed, size);
			buffer->offset = 0;
			buffer->length = size;
			buffer->flags = size == 0 ? MMAL_BUFFER_HEADER_FLAG_EOS : flags;
			if (framed && size > 0 && fed + size == auEnd)
				buffer->flags |= MMAL_BUFFER_HEADER_FLAG_FRAME_END;
			buffer->pts = pts;
			buffer->dts = MMAL_TIME_UNKNOWN;
			fed += size;
			eosSent = size == 0;
			status = mmal_port_send_buffer(decoder->input[0], buffer);
			CHECK(status, "send an input buffer");
		}

		while ((buffer = mmal_queue_get(sContext.queue)) != NULL) {
			if (buffer->cmd == MMAL_EVENT_FORMAT_CHANGED) {
				MMAL_EVENT_FORMAT_CHANGED_T* event = mmal_event_format_changed_get(buffer);
				formatChanges++;
				if (event == NULL) {
					fprintf(stderr, "MMAL FAIL: malformed format change event (%u bytes)\n",
						buffer->length);
					status = MMAL_EINVAL;
					goto out;
				}
				/* new buffers: drop the old ones once they are all back */
				status = mmal_port_disable(decoder->output[0]);
				CHECK(status, "disable the output port");
				mmal_buffer_header_release(buffer);
				while ((buffer = mmal_queue_get(sContext.queue)) != NULL)
					mmal_buffer_header_release(buffer);
				if (mmal_queue_length(outputPool->queue) != outputPool->headers_num) {
					fprintf(stderr, "MMAL FAIL: %u of %u output buffers back after the port's disable\n",
						mmal_queue_length(outputPool->queue), outputPool->headers_num);
					status = MMAL_EIO;
					goto out;
				}
				if (plainOutputPool)
					mmal_pool_destroy(outputPool);
				else
					mmal_port_pool_destroy(decoder->output[0], outputPool);
				outputPool = NULL;
				status = mmal_format_full_copy(decoder->output[0]->format, event->format);
				decoder->output[0]->format->encoding = outputEncoding;
				CHECK(status, "copy the new format");
				status = mmal_port_format_commit(decoder->output[0]);
				CHECK(status, "commit the new format");
				decoder->output[0]->buffer_num = outputBuffers > 0 ? (uint32_t)outputBuffers
					: event->buffer_num_recommended;
				if (decoder->output[0]->buffer_num < decoder->output[0]->buffer_num_min)
					decoder->output[0]->buffer_num = decoder->output[0]->buffer_num_min;
				decoder->output[0]->buffer_size = event->buffer_size_recommended;
				if (decoder->output[0]->buffer_size < decoder->output[0]->buffer_size_min)
					decoder->output[0]->buffer_size = decoder->output[0]->buffer_size_min;
				if (!sQuiet)
					log_format("output after the format change", decoder->output[0]);
				outputPool = plainOutputPool ? mmal_pool_create(decoder->output[0]->buffer_num,
						decoder->output[0]->buffer_size)
					: mmal_port_pool_create(decoder->output[0], decoder->output[0]->buffer_num,
						decoder->output[0]->buffer_size);
				if (outputPool == NULL) {
					fprintf(stderr, "MMAL FAIL: output pool\n");
					status = MMAL_ENOMEM;
					goto out;
				}
				status = mmal_port_enable(decoder->output[0], output_callback);
				CHECK(status, "enable the output port again");
				break;
			}
			if (buffer->cmd != 0) {
				char text[5];
				if (!sQuiet)
					printf("MMAL event %s\n", fourcc(buffer->cmd, text));
				mmal_buffer_header_release(buffer);
				continue;
			}
			if (buffer->flags & MMAL_BUFFER_HEADER_FLAG_EOS)
				eosReceived = 1;
			if (buffer->length > 0) {
				if (frames == 0) {
					firstFrame = system_time();
					if (!sQuiet) {
						printf("MMAL first frame: %u bytes, %u planes, pitch %u/%u/%u, offset %u/%u/%u,"
							" after %.1f ms\n", buffer->length, buffer->type->video.planes,
							buffer->type->video.pitch[0], buffer->type->video.pitch[1],
							buffer->type->video.pitch[2], buffer->type->video.offset[0],
							buffer->type->video.offset[1], buffer->type->video.offset[2],
							(firstFrame - start) / 1000.0);
					}
				}
				if (frames == rawFrame && rawFile != NULL) {
					FILE* raw = fopen(rawFile, "wb");
					if (raw != NULL) {
						fwrite(buffer->data + buffer->offset, 1, buffer->length, raw);
						fclose(raw);
					}
				}
				if (outputEncoding == MMAL_ENCODING_I420
					&& (hashFrames || (frames == dumpFrame && dumpFile != NULL))) {
					char hex[33];
					FILE* dump = frames == dumpFrame && dumpFile != NULL ? fopen(dumpFile, "wb") : NULL;
					hash_frame(decoder->output[0], buffer, hex, dump);
					if (dump != NULL)
						fclose(dump);
					if (hashFrames)
						printf("MMAL framemd5 %d %s\n", frames, hex);
				}
				frameBytes += buffer->length;
				frames++;
			}
			mmal_buffer_header_release(buffer);
		}

		while ((buffer = mmal_queue_get(outputPool->queue)) != NULL) {
			status = mmal_port_send_buffer(decoder->output[0], buffer);
			CHECK(status, "send an output buffer");
		}
	}

	end = system_time();
	{
		bigtime_t wall = end - start;
		bigtime_t team = team_cpu_time() - teamStart;
		bigtime_t busy = system_busy_time() - busyStart;
		printf("MMAL decoded: %d frames, %d format changes, %.1f MB of frames, %zu bytes of stream\n",
			frames, formatChanges, frameBytes / 1e6, streamSize);
		printf("MMAL time: %.3f s, %.1f frames/s (%.1f frames/s after the first frame, %.1f MB/s of"
			" frames)\n", wall / 1e6, frames / (wall / 1e6),
			frames > 1 ? (frames - 1) / ((end - firstFrame) / 1e6) : 0.0, frameBytes / (double)wall);
		printf("MMAL cpu: this team %.3f s (%.1f %% of one CPU), system %.3f s busy of %u CPUs"
			" (%.1f %% of all)\n", team / 1e6, 100.0 * team / wall, busy / 1e6, systemInfo.cpu_count,
			100.0 * busy / (wall * (double)systemInfo.cpu_count));
	}
	status = MMAL_SUCCESS;

out:
	if (decoder != NULL) {
		mmal_port_disable(decoder->input[0]);
		mmal_port_disable(decoder->output[0]);
		mmal_component_disable(decoder);
	}
	if (inputPool != NULL) {
		if (zeroCopyInput)
			mmal_pool_destroy(inputPool);
		else
			mmal_port_pool_destroy(decoder->input[0], inputPool);
	}
	if (outputPool != NULL) {
		if (plainOutputPool)
			mmal_pool_destroy(outputPool);
		else
			mmal_port_pool_destroy(decoder->output[0], outputPool);
	}
	if (decoder != NULL)
		mmal_component_destroy(decoder);
	if (sContext.queue != NULL)
		mmal_queue_destroy(sContext.queue);
	vcos_semaphore_delete(&sContext.semaphore);
	printf("MMAL result: %s\n", status == MMAL_SUCCESS ? "PASS" : "FAIL");
	return status == MMAL_SUCCESS ? 0 : 1;
}
