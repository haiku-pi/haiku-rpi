/*
 * mmal-codec — the VideoCore's other MMAL services than H.264 decoding, measured
 * (docs/design/videocore-services.md): which components the firmware offers, JPEG decoding and encoding
 * (vc.ril.image_decode / vc.ril.image_encode) and H.264 encoding (vc.ril.video_encode).
 *
 *   mmal-codec probe
 *       create each component (image_decode, image_encode, video_encode, video_decode, isp, resize,
 *       camera, camera_info), list its ports' supported encodings; camera_info: the cameras the firmware
 *       found
 *   mmal-codec jpegdec [-n N] [-f FOURCC] [-d FILE] FILE.jpg
 *       decode FILE N times (default 1) with one component; the output (default I420) of the last one,
 *       its visible part, to FILE (-d); per-image and total times
 *   mmal-codec jpegenc [-n N] [-q Q] WxH FILE.yuv OUT.jpg
 *       encode the I420 picture in FILE.yuv (W x H, tightly packed) N times at quality Q (default 85)
 *   mmal-codec h264enc [-n FRAMES] [-b KBIT/S] [-r FPS] [-g GOP] [-p PROFILE] WxH FILE.yuv OUT.h264
 *       encode the I420 frames of FILE.yuv (W x H, tightly packed, looped up to FRAMES; default: the file's)
 *       to an H.264 Annex-B stream (inline SPS/PPS); PROFILE: baseline, main, high (default)
 *
 * Every encode/decode line starts with "MMAL "; the last line "MMAL result: PASS|FAIL". CPU: this team's
 * and the system's busy time (all CPUs: the VCHIQ driver's threads that copy the buffers are not this team's).
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

#define ALIGN_UP(x, a) (((x) + (a) - 1) & ~((a) - 1))

static struct {
	VCOS_SEMAPHORE_T semaphore;
	MMAL_QUEUE_T* queue;
	MMAL_STATUS_T status;
} sContext;


static const char*
fourcc(uint32_t value, char text[5])
{
	for (int i = 0; i < 4; i++) {
		char c = (char)(value >> (8 * i));
		text[i] = c >= 32 && c < 127 ? c : '?';
	}
	text[4] = '\0';
	return text;
}


static bigtime_t
system_busy_time(void)
{
	system_info info;
	cpu_info cpus[64];
	bigtime_t busy = 0;

	get_system_info(&info);
	if (info.cpu_count > 64)
		info.cpu_count = 64;
	get_cpu_info(0, info.cpu_count, cpus);
	for (uint32_t i = 0; i < info.cpu_count; i++)
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


static void
list_encodings(const char* what, MMAL_PORT_T* port)
{
	uint32_t buffer[64];
	MMAL_PARAMETER_HEADER_T* header = (MMAL_PARAMETER_HEADER_T*)buffer;
	char text[5];

	header->id = MMAL_PARAMETER_SUPPORTED_ENCODINGS;
	header->size = sizeof(buffer);
	if (mmal_port_parameter_get(port, header) != MMAL_SUCCESS) {
		printf("MMAL   %s: (no encoding list)\n", what);
		return;
	}
	printf("MMAL   %s:", what);
	for (uint32_t j = 0; j < (header->size - sizeof(*header)) / sizeof(uint32_t); j++)
		printf(" %s", fourcc(buffer[2 + j], text));
	printf("\n");
}


static int
probe(void)
{
	static const char* const kComponents[] = {
		"vc.ril.image_decode", "vc.ril.image_encode", "vc.ril.video_encode", "vc.ril.video_decode",
		"vc.ril.isp", "vc.ril.resize", "vc.ril.camera",
	};
	int failures = 0;

	for (size_t i = 0; i < sizeof(kComponents) / sizeof(kComponents[0]); i++) {
		MMAL_COMPONENT_T* component = NULL;
		MMAL_STATUS_T status = mmal_component_create(kComponents[i], &component);
		if (status != MMAL_SUCCESS) {
			printf("MMAL component %s: not created (%s)\n", kComponents[i], mmal_status_to_string(status));
			failures++;
			continue;
		}
		printf("MMAL component %s: %u inputs, %u outputs\n", component->name, component->input_num,
			component->output_num);
		for (uint32_t p = 0; p < component->input_num; p++) {
			char name[32];
			snprintf(name, sizeof(name), "input %u", p);
			list_encodings(name, component->input[p]);
		}
		for (uint32_t p = 0; p < component->output_num; p++) {
			char name[32];
			snprintf(name, sizeof(name), "output %u", p);
			list_encodings(name, component->output[p]);
		}
		mmal_component_destroy(component);
	}

	{
		MMAL_COMPONENT_T* component = NULL;
		MMAL_STATUS_T status = mmal_component_create(MMAL_COMPONENT_DEFAULT_CAMERA_INFO, &component);
		if (status != MMAL_SUCCESS) {
			printf("MMAL component %s: not created (%s)\n", MMAL_COMPONENT_DEFAULT_CAMERA_INFO,
				mmal_status_to_string(status));
		} else {
			MMAL_PARAMETER_CAMERA_INFO_T info;
			memset(&info, 0, sizeof(info));
			info.hdr.id = MMAL_PARAMETER_CAMERA_INFO;
			info.hdr.size = sizeof(info);
			status = mmal_port_parameter_get(component->control, &info.hdr);
			if (status != MMAL_SUCCESS) {
				printf("MMAL camera_info: %s\n", mmal_status_to_string(status));
			} else {
				printf("MMAL camera_info: %u cameras, %u flashes\n", info.num_cameras, info.num_flashes);
				for (uint32_t c = 0; c < info.num_cameras && c < MMAL_PARAMETER_CAMERA_INFO_MAX_CAMERAS; c++) {
					printf("MMAL   camera %u: %.16s, %ux%u, port %u\n", c, info.cameras[c].camera_name,
						info.cameras[c].max_width, info.cameras[c].max_height, info.cameras[c].port_id);
				}
			}
			mmal_component_destroy(component);
		}
	}
	printf("MMAL probe: %d components not created\n", failures);
	return 0;
}


static void*
read_file(const char* path, size_t* size)
{
	FILE* file = fopen(path, "rb");
	void* data;
	if (file == NULL) {
		fprintf(stderr, "MMAL FAIL: %s: %s\n", path, strerror(errno));
		return NULL;
	}
	fseek(file, 0, SEEK_END);
	*size = ftell(file);
	fseek(file, 0, SEEK_SET);
	data = malloc(*size ? *size : 1);
	if (data == NULL || fread(data, 1, *size, file) != *size) {
		fprintf(stderr, "MMAL FAIL: reading %s\n", path);
		fclose(file);
		free(data);
		return NULL;
	}
	fclose(file);
	return data;
}


/*
 * One component with one input and one output port, run until the output's end of stream:
 * the input is given by next_input() (returns the bytes put into the buffer, 0 at the end, and flags),
 * the output goes to take_output(). A format change on the output (decoders) gets new buffers.
 */
typedef struct pump pump;
struct pump {
	MMAL_COMPONENT_T* component;
	MMAL_POOL_T* inputPool;
	MMAL_POOL_T* outputPool;
	size_t (*next_input)(pump* p, MMAL_BUFFER_HEADER_T* buffer);
	void (*take_output)(pump* p, MMAL_BUFFER_HEADER_T* buffer);
	void* cookie;
	int verbose;
	int formatChanges;
};


#define CHECK(status, what) \
	if ((status) != MMAL_SUCCESS) { \
		fprintf(stderr, "MMAL FAIL: %s: %s\n", what, mmal_status_to_string(status)); \
		return status; \
	}


static MMAL_STATUS_T
pump_create_pools(pump* p)
{
	MMAL_PORT_T* in = p->component->input[0];
	MMAL_PORT_T* out = p->component->output[0];
	in->buffer_num = in->buffer_num_recommended > in->buffer_num_min ? in->buffer_num_recommended
		: in->buffer_num_min;
	in->buffer_size = in->buffer_size_recommended > in->buffer_size_min ? in->buffer_size_recommended
		: in->buffer_size_min;
	out->buffer_num = out->buffer_num_recommended > out->buffer_num_min ? out->buffer_num_recommended
		: out->buffer_num_min;
	out->buffer_size = out->buffer_size_recommended > out->buffer_size_min ? out->buffer_size_recommended
		: out->buffer_size_min;
	p->inputPool = mmal_port_pool_create(in, in->buffer_num, in->buffer_size);
	p->outputPool = mmal_port_pool_create(out, out->buffer_num, out->buffer_size);
	if (p->inputPool == NULL || p->outputPool == NULL)
		return MMAL_ENOMEM;
	if (p->verbose) {
		char a[5], b[5];
		printf("MMAL ports: in %s %u x %u bytes, out %s %u x %u bytes\n", fourcc(in->format->encoding, a),
			in->buffer_num, in->buffer_size, fourcc(out->format->encoding, b), out->buffer_num,
			out->buffer_size);
	}
	return MMAL_SUCCESS;
}


static MMAL_STATUS_T
pump_enable(pump* p)
{
	MMAL_STATUS_T status;
	p->component->input[0]->userdata = (void*)&sContext;
	p->component->output[0]->userdata = (void*)&sContext;
	status = mmal_port_enable(p->component->input[0], input_callback);
	CHECK(status, "enable the input port");
	status = mmal_port_enable(p->component->output[0], output_callback);
	CHECK(status, "enable the output port");
	if (!p->component->is_enabled) {
		status = mmal_component_enable(p->component);
		CHECK(status, "enable the component");
	}
	return MMAL_SUCCESS;
}


/* one run: input until next_input() returns 0 (then an end-of-stream buffer), output until end of stream */
static MMAL_STATUS_T
pump_run(pump* p)
{
	int eosSent = 0, eosReceived = 0;
	MMAL_STATUS_T status;

	while (!eosReceived) {
		MMAL_BUFFER_HEADER_T* buffer;

		if (vcos_semaphore_wait_timeout(&sContext.semaphore, 10000) != VCOS_SUCCESS) {
			fprintf(stderr, "MMAL FAIL: nothing from the component for 10 s\n");
			return MMAL_EAGAIN;
		}
		if (sContext.status != MMAL_SUCCESS) {
			status = sContext.status;
			sContext.status = MMAL_SUCCESS;
			CHECK(status, "error event");
		}

		while (!eosSent && (buffer = mmal_queue_get(p->inputPool->queue)) != NULL) {
			size_t size;
			buffer->offset = 0;
			buffer->flags = 0;
			buffer->pts = buffer->dts = MMAL_TIME_UNKNOWN;
			size = p->next_input(p, buffer);
			buffer->length = size;
			if (size == 0) {
				buffer->flags = MMAL_BUFFER_HEADER_FLAG_EOS;
				eosSent = 1;
			}
			status = mmal_port_send_buffer(p->component->input[0], buffer);
			CHECK(status, "send an input buffer");
		}

		while ((buffer = mmal_queue_get(sContext.queue)) != NULL) {
			if (buffer->cmd == MMAL_EVENT_FORMAT_CHANGED) {
				MMAL_EVENT_FORMAT_CHANGED_T* event = mmal_event_format_changed_get(buffer);
				MMAL_PORT_T* out = p->component->output[0];
				uint32_t encoding = out->format->encoding;
				p->formatChanges++;
				status = mmal_port_disable(out);
				CHECK(status, "disable the output port");
				mmal_buffer_header_release(buffer);
				while ((buffer = mmal_queue_get(sContext.queue)) != NULL)
					mmal_buffer_header_release(buffer);
				mmal_port_pool_destroy(out, p->outputPool);
				p->outputPool = NULL;
				status = mmal_format_full_copy(out->format, event->format);
				CHECK(status, "copy the new format");
				out->format->encoding = encoding;
				status = mmal_port_format_commit(out);
				CHECK(status, "commit the new format");
				out->buffer_num = event->buffer_num_recommended > out->buffer_num_min
					? event->buffer_num_recommended : out->buffer_num_min;
				out->buffer_size = event->buffer_size_recommended > out->buffer_size_min
					? event->buffer_size_recommended : out->buffer_size_min;
				if (p->verbose) {
					char a[5];
					printf("MMAL output format: %s %ux%u crop %ux%u, %u x %u bytes\n",
						fourcc(out->format->encoding, a), out->format->es->video.width,
						out->format->es->video.height, out->format->es->video.crop.width,
						out->format->es->video.crop.height, out->buffer_num, out->buffer_size);
				}
				p->outputPool = mmal_port_pool_create(out, out->buffer_num, out->buffer_size);
				if (p->outputPool == NULL)
					return MMAL_ENOMEM;
				status = mmal_port_enable(out, output_callback);
				CHECK(status, "enable the output port again");
				break;
			}
			if (buffer->cmd != 0) {
				mmal_buffer_header_release(buffer);
				continue;
			}
			if (buffer->flags & MMAL_BUFFER_HEADER_FLAG_EOS)
				eosReceived = 1;
			if (buffer->length > 0)
				p->take_output(p, buffer);
			mmal_buffer_header_release(buffer);
		}

		while ((buffer = mmal_queue_get(p->outputPool->queue)) != NULL) {
			status = mmal_port_send_buffer(p->component->output[0], buffer);
			CHECK(status, "send an output buffer");
		}
	}
	return MMAL_SUCCESS;
}


/* after an end of stream: the ports flushed and enabled again, for the next run */
static MMAL_STATUS_T
pump_restart(pump* p)
{
	MMAL_STATUS_T status;
	MMAL_BUFFER_HEADER_T* buffer;
	status = mmal_port_disable(p->component->input[0]);
	CHECK(status, "disable the input port");
	status = mmal_port_disable(p->component->output[0]);
	CHECK(status, "disable the output port");
	while ((buffer = mmal_queue_get(sContext.queue)) != NULL)
		mmal_buffer_header_release(buffer);
	while (vcos_semaphore_trywait(&sContext.semaphore) == VCOS_SUCCESS)
		;
	vcos_semaphore_post(&sContext.semaphore);
	return pump_enable(p);
}


static void
pump_destroy(pump* p)
{
	if (p->component == NULL)
		return;
	mmal_port_disable(p->component->input[0]);
	mmal_port_disable(p->component->output[0]);
	mmal_component_disable(p->component);
	if (p->inputPool != NULL)
		mmal_port_pool_destroy(p->component->input[0], p->inputPool);
	if (p->outputPool != NULL)
		mmal_port_pool_destroy(p->component->output[0], p->outputPool);
	mmal_component_destroy(p->component);
	p->component = NULL;
}


static MMAL_STATUS_T
pump_create(pump* p, const char* name)
{
	MMAL_STATUS_T status = mmal_component_create(name, &p->component);
	CHECK(status, name);
	p->component->control->userdata = (void*)&sContext;
	status = mmal_port_enable(p->component->control, control_callback);
	CHECK(status, "enable the control port");
	return MMAL_SUCCESS;
}


/* the input: a blob in buffer-sized pieces, the last flagged FRAME_END */
typedef struct {
	const uint8_t* data;
	size_t size, fed;
} blob_input;

static size_t
blob_next(pump* p, MMAL_BUFFER_HEADER_T* buffer)
{
	blob_input* in = p->cookie;
	size_t size = in->size - in->fed;
	if (size > buffer->alloc_size)
		size = buffer->alloc_size;
	memcpy(buffer->data, in->data + in->fed, size);
	in->fed += size;
	if (size > 0 && in->fed == in->size)
		buffer->flags |= MMAL_BUFFER_HEADER_FLAG_FRAME_END;
	return size;
}


/* the output: collected into memory */
typedef struct {
	blob_input input;
	uint8_t* data;
	size_t size, capacity;
	int buffers, frames;
	bigtime_t firstOutput;
} collector;

static void
collect(pump* p, MMAL_BUFFER_HEADER_T* buffer)
{
	collector* c = p->cookie;
	if (c->buffers++ == 0)
		c->firstOutput = system_time();
	if (buffer->flags & MMAL_BUFFER_HEADER_FLAG_FRAME_END)
		c->frames++;
	if (c->size + buffer->length > c->capacity) {
		size_t capacity = (c->size + buffer->length) * 2;
		uint8_t* data = realloc(c->data, capacity);
		if (data == NULL)
			return;
		c->data = data;
		c->capacity = capacity;
	}
	memcpy(c->data + c->size, buffer->data + buffer->offset, buffer->length);
	c->size += buffer->length;
}


static size_t
collect_input(pump* p, MMAL_BUFFER_HEADER_T* buffer)
{
	collector* c = p->cookie;
	p->cookie = &c->input;
	size_t size = blob_next(p, buffer);
	p->cookie = c;
	return size;
}


static void
print_times(const char* what, int count, bigtime_t wall, bigtime_t team, bigtime_t busy)
{
	system_info info;
	get_system_info(&info);
	printf("MMAL %s: %d in %.3f s, %.2f ms each, %.1f/s; cpu: this team %.3f s, system %.3f s busy of %u"
		" CPUs (%.1f %% of all)\n", what, count, wall / 1e6, wall / 1e3 / count, count / (wall / 1e6),
		team / 1e6, busy / 1e6, info.cpu_count, 100.0 * busy / (wall * (double)info.cpu_count));
}


static int
jpegdec(int argc, char** argv)
{
	int count = 1, opt;
	uint32_t encoding = MMAL_ENCODING_I420;
	const char* dumpFile = NULL;
	pump p;
	collector c;
	MMAL_STATUS_T status;
	bigtime_t start, teamStart, busyStart, first = 0;

	while ((opt = getopt(argc, argv, "n:f:d:")) != -1) {
		switch (opt) {
			case 'n': count = atoi(optarg); break;
			case 'f': encoding = MMAL_FOURCC(optarg[0], optarg[1], optarg[2], optarg[3]); break;
			case 'd': dumpFile = optarg; break;
			default: return 2;
		}
	}
	if (optind != argc - 1)
		return 2;

	memset(&p, 0, sizeof(p));
	memset(&c, 0, sizeof(c));
	c.input.data = read_file(argv[optind], &c.input.size);
	if (c.input.data == NULL)
		return 1;
	p.cookie = &c;
	p.next_input = collect_input;
	p.take_output = collect;
	p.verbose = 1;

	start = system_time();
	if ((status = pump_create(&p, MMAL_COMPONENT_DEFAULT_IMAGE_DECODER)) != MMAL_SUCCESS)
		goto out;
	{
		MMAL_PORT_T* in = p.component->input[0];
		MMAL_PORT_T* out = p.component->output[0];
		in->format->type = MMAL_ES_TYPE_VIDEO;
		in->format->encoding = MMAL_ENCODING_JPEG;
		in->format->es->video.width = 0;
		in->format->es->video.height = 0;
		if ((status = mmal_port_format_commit(in)) != MMAL_SUCCESS) {
			fprintf(stderr, "MMAL FAIL: input format: %s\n", mmal_status_to_string(status));
			goto out;
		}
		out->format->encoding = encoding;
		if ((status = mmal_port_format_commit(out)) != MMAL_SUCCESS) {
			fprintf(stderr, "MMAL FAIL: output format: %s\n", mmal_status_to_string(status));
			goto out;
		}
	}
	if ((status = pump_create_pools(&p)) != MMAL_SUCCESS || (status = pump_enable(&p)) != MMAL_SUCCESS)
		goto out;
	printf("MMAL setup: %.2f ms\n", (system_time() - start) / 1e3);

	teamStart = team_cpu_time();
	busyStart = system_busy_time();
	start = system_time();
	for (int i = 0; i < count; i++) {
		bigtime_t t = system_time();
		c.input.fed = 0;
		c.size = 0;
		if (i > 0 && (status = pump_restart(&p)) != MMAL_SUCCESS)
			goto out;
		if ((status = pump_run(&p)) != MMAL_SUCCESS)
			goto out;
		if (i == 0) {
			first = system_time() - t;
			MMAL_VIDEO_FORMAT_T* video = &p.component->output[0]->format->es->video;
			char a[5];
			printf("MMAL first image: %.2f ms, %s %ux%u (crop %ux%u), %zu bytes out, %d format changes\n",
				first / 1e3, fourcc(p.component->output[0]->format->encoding, a), video->width, video->height,
				video->crop.width, video->crop.height, c.size, p.formatChanges);
		}
	}
	print_times("jpeg decodes", count, system_time() - start, team_cpu_time() - teamStart,
		system_busy_time() - busyStart);

	if (dumpFile != NULL && c.size > 0) {
		/* the visible part of the planes (I420; other encodings: the buffer as it came) */
		MMAL_VIDEO_FORMAT_T* video = &p.component->output[0]->format->es->video;
		FILE* file = fopen(dumpFile, "wb");
		if (file != NULL && p.component->output[0]->format->encoding == MMAL_ENCODING_I420) {
			uint32_t w = video->width, h = video->height;
			const uint8_t* planes[3] = { c.data, c.data + w * h, c.data + w * h + (w / 2) * (h / 2) };
			for (int plane = 0; plane < 3; plane++) {
				uint32_t shift = plane ? 1 : 0, pitch = w >> shift;
				for (uint32_t y = 0; y < (video->crop.height + shift) >> shift; y++)
					fwrite(planes[plane] + y * pitch, 1, (video->crop.width + shift) >> shift, file);
			}
		} else if (file != NULL) {
			fwrite(c.data, 1, c.size, file);
		}
		if (file != NULL)
			fclose(file);
		printf("MMAL wrote %s\n", dumpFile);
	}
	status = MMAL_SUCCESS;

out:
	pump_destroy(&p);
	printf("MMAL result: %s\n", status == MMAL_SUCCESS ? "PASS" : "FAIL");
	return status == MMAL_SUCCESS ? 0 : 1;
}


/* I420 frames of WxH tightly packed in memory, given to an encoder in its aligned layout */
typedef struct {
	collector c;
	const uint8_t* frames;
	size_t frameSize, frameCount;
	uint32_t width, height, alignedWidth, alignedHeight;
	int total, sent;
	int64_t frameDuration;
	size_t inFrame;         /* bytes of the current frame given (frames larger than a buffer) */
} frame_input;

static size_t
frame_next(pump* p, MMAL_BUFFER_HEADER_T* buffer)
{
	frame_input* in = p->cookie;
	const uint8_t* src;
	uint8_t* dst = buffer->data;
	uint32_t w = in->width, h = in->height, aw = in->alignedWidth, ah = in->alignedHeight;
	size_t size = aw * ah * 3 / 2;

	if (in->sent == in->total)
		return 0;
	if (size > buffer->alloc_size) {
		fprintf(stderr, "MMAL FAIL: an input buffer (%u bytes) smaller than a frame (%zu)\n",
			buffer->alloc_size, size);
		exit(1);
	}
	src = in->frames + (in->sent % in->frameCount) * in->frameSize;
	for (uint32_t y = 0; y < h; y++)
		memcpy(dst + y * aw, src + y * w, w);
	for (int plane = 1; plane < 3; plane++) {
		const uint8_t* s = src + w * h + (plane - 1) * (w / 2) * (h / 2);
		uint8_t* d = dst + aw * ah + (plane - 1) * (aw / 2) * (ah / 2);
		for (uint32_t y = 0; y < h / 2; y++)
			memcpy(d + y * (aw / 2), s + y * (w / 2), w / 2);
	}
	buffer->flags |= MMAL_BUFFER_HEADER_FLAG_FRAME_END;
	buffer->pts = in->sent * in->frameDuration;
	in->sent++;
	return size;
}

static void
frame_collect(pump* p, MMAL_BUFFER_HEADER_T* buffer)
{
	frame_input* in = p->cookie;
	p->cookie = &in->c;
	collect(p, buffer);
	p->cookie = in;
}


static int
parse_size(const char* text, uint32_t* width, uint32_t* height)
{
	return sscanf(text, "%ux%u", width, height) == 2 && *width > 0 && *height > 0
		&& (*width % 2) == 0 && (*height % 2) == 0;
}


static int
write_file(const char* path, const void* data, size_t size)
{
	FILE* file = fopen(path, "wb");
	if (file == NULL || fwrite(data, 1, size, file) != size) {
		fprintf(stderr, "MMAL FAIL: writing %s\n", path);
		if (file != NULL)
			fclose(file);
		return -1;
	}
	fclose(file);
	return 0;
}


static int
encode(int argc, char** argv, int video)
{
	int count = 0, opt, quality = 85, kbps = 4000, fps = 30, gop = 60;
	MMAL_VIDEO_PROFILE_T profile = MMAL_VIDEO_PROFILE_H264_HIGH;
	frame_input in;
	pump p;
	MMAL_STATUS_T status = MMAL_EINVAL;
	size_t size;
	bigtime_t start, teamStart, busyStart;

	while ((opt = getopt(argc, argv, "n:q:b:r:g:p:")) != -1) {
		switch (opt) {
			case 'n': count = atoi(optarg); break;
			case 'q': quality = atoi(optarg); break;
			case 'b': kbps = atoi(optarg); break;
			case 'r': fps = atoi(optarg); break;
			case 'g': gop = atoi(optarg); break;
			case 'p':
				profile = !strcmp(optarg, "baseline") ? MMAL_VIDEO_PROFILE_H264_BASELINE
					: !strcmp(optarg, "main") ? MMAL_VIDEO_PROFILE_H264_MAIN : MMAL_VIDEO_PROFILE_H264_HIGH;
				break;
			default: return 2;
		}
	}
	memset(&in, 0, sizeof(in));
	memset(&p, 0, sizeof(p));
	if (optind != argc - 3 || !parse_size(argv[optind], &in.width, &in.height))
		return 2;
	in.frames = read_file(argv[optind + 1], &size);
	if (in.frames == NULL)
		return 1;
	in.frameSize = (size_t)in.width * in.height * 3 / 2;
	in.frameCount = size / in.frameSize;
	if (in.frameCount == 0) {
		fprintf(stderr, "MMAL FAIL: %s holds no %ux%u frame\n", argv[optind + 1], in.width, in.height);
		return 1;
	}
	in.total = video ? (count > 0 ? count : (int)in.frameCount) : 1;
	in.alignedWidth = ALIGN_UP(in.width, 32);
	in.alignedHeight = ALIGN_UP(in.height, 16);
	in.frameDuration = 1000000 / fps;
	p.cookie = &in;
	p.next_input = frame_next;
	p.take_output = frame_collect;
	p.verbose = 1;

	start = system_time();
	if (pump_create(&p, video ? MMAL_COMPONENT_DEFAULT_VIDEO_ENCODER : MMAL_COMPONENT_DEFAULT_IMAGE_ENCODER)
			!= MMAL_SUCCESS)
		goto out;
	{
		MMAL_PORT_T* ip = p.component->input[0];
		MMAL_PORT_T* op = p.component->output[0];
		ip->format->type = MMAL_ES_TYPE_VIDEO;
		ip->format->encoding = ip->format->encoding_variant = MMAL_ENCODING_I420;
		ip->format->es->video.width = in.alignedWidth;
		ip->format->es->video.height = in.alignedHeight;
		ip->format->es->video.crop.x = ip->format->es->video.crop.y = 0;
		ip->format->es->video.crop.width = in.width;
		ip->format->es->video.crop.height = in.height;
		ip->format->es->video.frame_rate.num = fps;
		ip->format->es->video.frame_rate.den = 1;
		if ((status = mmal_port_format_commit(ip)) != MMAL_SUCCESS) {
			fprintf(stderr, "MMAL FAIL: input format: %s\n", mmal_status_to_string(status));
			goto out;
		}
		mmal_format_copy(op->format, ip->format);
		op->format->encoding = video ? MMAL_ENCODING_H264 : MMAL_ENCODING_JPEG;
		op->format->encoding_variant = 0;
		if (video) {
			op->format->bitrate = kbps * 1000;
			op->format->es->video.frame_rate.num = fps;
			op->format->es->video.frame_rate.den = 1;
		}
		if ((status = mmal_port_format_commit(op)) != MMAL_SUCCESS) {
			fprintf(stderr, "MMAL FAIL: output format: %s\n", mmal_status_to_string(status));
			goto out;
		}
		if (video) {
			MMAL_PARAMETER_VIDEO_PROFILE_T param;
			param.hdr.id = MMAL_PARAMETER_PROFILE;
			param.hdr.size = sizeof(param);
			param.profile[0].profile = profile;
			param.profile[0].level = MMAL_VIDEO_LEVEL_H264_4;
			status = mmal_port_parameter_set(op, &param.hdr);
			if (status != MMAL_SUCCESS)
				printf("MMAL profile: %s\n", mmal_status_to_string(status));
			status = mmal_port_parameter_set_uint32(op, MMAL_PARAMETER_INTRAPERIOD, gop);
			if (status != MMAL_SUCCESS)
				printf("MMAL intra period: %s\n", mmal_status_to_string(status));
			status = mmal_port_parameter_set_boolean(op, MMAL_PARAMETER_VIDEO_ENCODE_INLINE_HEADER, 1);
			if (status != MMAL_SUCCESS)
				printf("MMAL inline header: %s\n", mmal_status_to_string(status));
		} else {
			status = mmal_port_parameter_set_uint32(op, MMAL_PARAMETER_JPEG_Q_FACTOR, quality);
			if (status != MMAL_SUCCESS)
				printf("MMAL quality: %s\n", mmal_status_to_string(status));
		}
	}
	if ((status = pump_create_pools(&p)) != MMAL_SUCCESS || (status = pump_enable(&p)) != MMAL_SUCCESS)
		goto out;
	printf("MMAL setup: %.2f ms\n", (system_time() - start) / 1e3);

	teamStart = team_cpu_time();
	busyStart = system_busy_time();
	start = system_time();
	if (video) {
		if ((status = pump_run(&p)) != MMAL_SUCCESS)
			goto out;
		print_times("h264 frames encoded", in.total, system_time() - start, team_cpu_time() - teamStart,
			system_busy_time() - busyStart);
		printf("MMAL stream: %zu bytes, %d output buffers, %d frame ends, %.0f kbit/s at %d fps; first output"
			" after %.1f ms\n", in.c.size, in.c.buffers, in.c.frames,
			in.c.size * 8.0 / 1000 / (in.total / (double)fps), fps, (in.c.firstOutput - start) / 1e3);
	} else {
		int images = count > 0 ? count : 1;
		for (int i = 0; i < images; i++) {
			in.sent = 0;
			in.c.size = 0;
			if (i > 0 && (status = pump_restart(&p)) != MMAL_SUCCESS)
				goto out;
			if ((status = pump_run(&p)) != MMAL_SUCCESS)
				goto out;
		}
		print_times("jpeg encodes", images, system_time() - start, team_cpu_time() - teamStart,
			system_busy_time() - busyStart);
		printf("MMAL jpeg: %zu bytes at quality %d\n", in.c.size, quality);
	}
	if (write_file(argv[optind + 2], in.c.data, in.c.size) != 0) {
		status = MMAL_EIO;
		goto out;
	}
	status = MMAL_SUCCESS;

out:
	pump_destroy(&p);
	printf("MMAL result: %s\n", status == MMAL_SUCCESS ? "PASS" : "FAIL");
	return status == MMAL_SUCCESS ? 0 : 1;
}


int
main(int argc, char** argv)
{
	int result;
	const char* usage = "usage: mmal-codec probe | jpegdec [-n N] [-f FOURCC] [-d FILE] FILE.jpg\n"
		"  | jpegenc [-n N] [-q Q] WxH FILE.yuv OUT.jpg\n"
		"  | h264enc [-n FRAMES] [-b KBIT/S] [-r FPS] [-g GOP] [-p baseline|main|high] WxH FILE.yuv OUT.h264\n";

	if (argc < 2) {
		fputs(usage, stderr);
		return 2;
	}
	vcos_semaphore_create(&sContext.semaphore, "mmal-codec", 1);
	sContext.queue = mmal_queue_create();
	optind = 2;
	if (!strcmp(argv[1], "probe"))
		result = probe();
	else if (!strcmp(argv[1], "jpegdec"))
		result = jpegdec(argc, argv);
	else if (!strcmp(argv[1], "jpegenc"))
		result = encode(argc, argv, 0);
	else if (!strcmp(argv[1], "h264enc"))
		result = encode(argc, argv, 1);
	else
		result = 2;
	if (result == 2)
		fputs(usage, stderr);
	mmal_queue_destroy(sContext.queue);
	vcos_semaphore_delete(&sContext.semaphore);
	return result;
}
