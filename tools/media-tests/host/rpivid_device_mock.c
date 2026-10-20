/*
 * rpivid_device_mock.c — a host stand-in for libavcodec/rpivid_device.c (the rpivid driver's API,
 * docs/design/hw-video-decode.md), for tools/media-tests/host/host-test.sh.
 *
 * It "decodes" by writing a golden picture (MOCK_GOLDEN: the CPU decoder's frames, raw, in display
 * order) SAND-tiled into the output, and logs every job in a canonical form (MOCK_LOG): the command
 * entries (slice data as CRC:length), the phase-2 programming, the reference slots and the
 * collocated picture by POC.
 *
 * It enforces the driver's protocol, as the real block would punish breaking it:
 *  - a picture is decoded only when it is waited for: before that its output holds poison, so a
 *    client that reads (converts) a picture before waiting gets a wrong frame;
 *  - the bitstream a job reads must not change until it is waited for (CRC per slice, checked when
 *    the job runs);
 *  - a buffer a job not yet waited for names must not be deleted;
 *  - at most MOCK_MAX_JOBS (default 2) jobs submitted and not waited for.
 * Breaking a rule prints "MOCK PROTOCOL ..." and aborts.
 *
 * Faults: MOCK_FAIL_AT=n (the n-th submit is refused), MOCK_FAIL_LATE_AT=n (the n-th submitted
 * picture fails when it is waited for), MOCK_NOMEM_AT=n (the n-th picture buffer cannot be
 * created), MOCK_OFF (no device). MOCK_GOP=n: the golden frame of a picture is (k-th IDR) * n + POC.
 */
#include "rpivid_device.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libavutil/error.h"

#define MAX_HANDLES	4096
#define MAX_QUEUE	64

typedef struct Picture {
	uint32_t	width, height, bit_depth, columns, luma_stride, chroma_stride;
	uint8_t*	memory;
	size_t		chroma_offset, size;
	int			motion_vectors;
	int32_t		poc;
	int			used;
} Picture;

typedef struct Job {
	uint64_t	id;
	RpividJob	job;
	uint64_t*	entries;
	uint32_t	crcs[512];
	uint32_t	slices;
	long		index;		/* submit count */
	int			done;
	int			result;
} Job;

struct RpividDevice {
	int	references;
};

static struct RpividDevice sDevice;
static Picture sPictures[MAX_HANDLES];
static uint8_t* sBitstreams[MAX_HANDLES];
static size_t sBitstreamSizes[MAX_HANDLES];
static int sNextHandle = 1;
static Job sQueue[MAX_QUEUE];
static int sQueued;
static uint64_t sNextJob;
static long sSubmits;
static FILE* sLog;
static FILE* sGolden;
static long sPictureNumber;


static FILE*
log_file(void)
{
	if (sLog == NULL) {
		const char* path = getenv("MOCK_LOG");
		const char* golden = getenv("MOCK_GOLDEN");
		sLog = path != NULL ? fopen(path, "w") : stdout;
		if (sLog == NULL)
			sLog = stdout;
		if (golden != NULL)
			sGolden = fopen(golden, "rb");
	}
	return sLog;
}


static void
protocol_error(const char* what, unsigned long long value)
{
	fprintf(stderr, "MOCK PROTOCOL %s (%llu)\n", what, value);
	fprintf(log_file(), "MOCK PROTOCOL %s (%llu)\n", what, value);
	fflush(NULL);
	abort();
}


static long
env_long(const char* name, long fallback)
{
	const char* value = getenv(name);
	return value != NULL ? atol(value) : fallback;
}


int
ff_rpivid_device_open(RpividDevice** device, char* why, size_t whySize)
{
	if (getenv("MOCK_OFF") != NULL) {
		snprintf(why, whySize, "mock off");
		return AVERROR(ENODEV);
	}
	sDevice.references++;
	*device = &sDevice;
	return 0;
}


RpividDevice*
ff_rpivid_device_ref(RpividDevice* device)
{
	device->references++;
	return device;
}


void
ff_rpivid_device_unref(RpividDevice* device)
{
	if (device != NULL)
		device->references--;
}


uint32_t
ff_rpivid_device_clock_rate(const RpividDevice* device)
{
	return 500000000;
}


int
ff_rpivid_device_create_bitstream(RpividDevice* device, size_t size,
	RpividBitstream* bitstream)
{
	int handle = sNextHandle++;
	size = (size + 4095) & ~(size_t)4095;
	sBitstreams[handle] = calloc(1, size);
	sBitstreamSizes[handle] = size;
	bitstream->handle = handle;
	bitstream->data = sBitstreams[handle];
	bitstream->size = size;
	return 0;
}


int
ff_rpivid_device_create_picture(RpividDevice* device, uint32_t width,
	uint32_t height, uint32_t bitDepth, int motionVectors, RpividPicture* out)
{
	static long creates;
	const long failAt = env_long("MOCK_NOMEM_AT", -1);
	const uint32_t height16 = (height + 15) & ~15u;
	const uint32_t columnBytes = bitDepth == 8 ? ((width + 127) & ~127u)
		: ((((width + 2) / 3) + 31) & ~31u) * 4;
	Picture* picture;
	int handle;

	if (creates++ == failAt)
		return AVERROR(ENOMEM);
	handle = sNextHandle++;
	picture = &sPictures[handle];
	picture->width = width;
	picture->height = height;
	picture->bit_depth = bitDepth;
	picture->columns = columnBytes / 128;
	picture->luma_stride = height16 * 128;
	picture->chroma_stride = picture->luma_stride / 2;
	picture->motion_vectors = motionVectors;
	picture->chroma_offset = ((size_t)picture->luma_stride * picture->columns
		+ 4095) & ~(size_t)4095;
	picture->size = picture->chroma_offset
		+ (size_t)picture->chroma_stride * picture->columns;
	picture->memory = calloc(1, picture->size + 4096);
	picture->used = 1;
	picture->poc = -999;

	out->handle = handle;
	out->luma = picture->memory;
	out->chroma = picture->memory + picture->chroma_offset;
	out->luma_column_stride = picture->luma_stride;
	out->chroma_column_stride = picture->chroma_stride;
	return 0;
}


static int
job_names(const Job* job, uint32_t handle)
{
	int i;
	if (job->job.bitstream == handle || job->job.output == handle
		|| job->job.collocated == handle) {
		return 1;
	}
	for (i = 0; i < RPIVID_REFERENCE_SLOTS; i++) {
		if (job->job.references[i] == handle)
			return 1;
	}
	return 0;
}


void
ff_rpivid_device_delete(RpividDevice* device, uint32_t handle)
{
	int i;
	if (handle >= MAX_HANDLES)
		return;
	for (i = 0; i < sQueued; i++) {
		if (job_names(&sQueue[i], handle))
			protocol_error("delete of a buffer a queued picture names", handle);
	}
	if (sPictures[handle].used) {
		free(sPictures[handle].memory);
		sPictures[handle].used = 0;
	} else if (sBitstreams[handle] != NULL) {
		free(sBitstreams[handle]);
		sBitstreams[handle] = NULL;
	}
}


static uint32_t
crc32(const uint8_t* data, size_t size)
{
	uint32_t crc = 0xffffffffu;
	size_t i;
	int bit;
	for (i = 0; i < size; i++) {
		crc ^= data[i];
		for (bit = 0; bit < 8; bit++)
			crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1u)));
	}
	return ~crc;
}


/* Entry i starts a slice's data: BFBASE, BFNUM, BFCONTROL */
static int
is_slice(const uint64_t* entries, uint32_t count, uint32_t i)
{
	return (uint32_t)entries[i] == 64 && i + 2 < count
		&& (uint32_t)entries[i + 1] == 68 && (uint32_t)entries[i + 2] == 72;
}


static uint32_t
slice_crc(const Job* job, uint32_t i, uint32_t* length)
{
	const uint64_t* entries = job->entries;
	const uint32_t base = (uint32_t)(entries[i] >> 32);
	const uint32_t low = (uint32_t)(entries[i + 2] >> 32) & 63u;
	*length = (uint32_t)(entries[i + 1] >> 32);
	return crc32(sBitstreams[job->job.bitstream] + ((size_t)base << 6) + low,
		*length);
}


static size_t
round_up_size(size_t size)
{
	unsigned log2 = 8;
	if (size >= 256) {
		log2 = 0;
		while ((size >> (log2 + 1)) != 0)
			log2++;
	}
	return size >= ((size_t)3 << log2) ? (size_t)4 << log2 : (size_t)3 << log2;
}


static void
put_sample(uint8_t* plane, uint32_t stride, unsigned bitDepth, uint32_t x,
	uint32_t row, uint32_t value)
{
	if (bitDepth == 8) {
		plane[(size_t)(x / 128) * stride + (size_t)row * 128 + x % 128]
			= (uint8_t)value;
	} else {
		const uint32_t sample = x % 96;
		uint32_t* word = (uint32_t*)(plane + (size_t)(x / 96) * stride
			+ (size_t)row * 128 + (sample / 3) * 4);
		*word = (*word & ~(0x3ffu << (10 * (sample % 3))))
			| (value << (10 * (sample % 3)));
	}
}


static void
golden_picture(Picture* picture, int32_t index)
{
	uint32_t width = picture->width, height = picture->height;
	const uint32_t bytes = picture->bit_depth == 8 ? 1 : 2;
	const char* size = getenv("MOCK_GOLDEN_SIZE");
	uint32_t chromaWidth, chromaHeight, x, y;
	uint8_t *frame, *u, *v;
	size_t frameSize;

	if (size != NULL)
		sscanf(size, "%ux%u", &width, &height);
	chromaWidth = (width + 1) / 2;
	chromaHeight = (height + 1) / 2;
	frameSize = ((size_t)width * height + 2 * (size_t)chromaWidth
		* chromaHeight) * bytes;
	frame = malloc(frameSize);
	if (frame == NULL || index < 0
		|| fseek(sGolden, (long)frameSize * index, SEEK_SET) != 0
		|| fread(frame, 1, frameSize, sGolden) != frameSize) {
		fprintf(log_file(), "MOCK no golden frame %d\n", index);
		free(frame);
		return;
	}
	u = frame + (size_t)width * height * bytes;
	v = u + (size_t)chromaWidth * chromaHeight * bytes;
#define SAMPLE(p, i) (bytes == 1 ? (uint32_t)(p)[i] \
	: ((uint32_t)(p)[2 * (i)] | ((uint32_t)(p)[2 * (i) + 1] << 8)))
	for (y = 0; y < height; y++) {
		for (x = 0; x < width; x++) {
			put_sample(picture->memory, picture->luma_stride,
				picture->bit_depth, x, y, SAMPLE(frame, (size_t)y * width + x));
		}
	}
	for (y = 0; y < chromaHeight; y++) {
		for (x = 0; x < chromaWidth; x++) {
			put_sample(picture->memory + picture->chroma_offset,
				picture->chroma_stride, picture->bit_depth, 2 * x, y,
				SAMPLE(u, (size_t)y * chromaWidth + x));
			put_sample(picture->memory + picture->chroma_offset,
				picture->chroma_stride, picture->bit_depth, 2 * x + 1, y,
				SAMPLE(v, (size_t)y * chromaWidth + x));
		}
	}
#undef SAMPLE
	free(frame);
}


static void
symbol(char* out, size_t size, uint32_t handle, uint32_t current)
{
	if (handle == 0 || handle == current)
		snprintf(out, size, "CUR");
	else
		snprintf(out, size, "P%d", sPictures[handle].poc);
}


int
ff_rpivid_device_submit(RpividDevice* device, const RpividJob* in,
	uint64_t* _id)
{
	const long failAt = env_long("MOCK_FAIL_AT", -1);
	const long maxJobs = env_long("MOCK_MAX_JOBS", 2);
	const long index = sSubmits++;
	Job* job;
	uint32_t i, length;

	if (index == failAt) {
		fprintf(log_file(), "MOCK submit %ld refused\n", index);
		return AVERROR(EINVAL);
	}
	if (sQueued >= maxJobs)
		protocol_error("more pictures submitted and not waited for", sQueued);
	if (in->bitstream >= MAX_HANDLES || sBitstreams[in->bitstream] == NULL
		|| in->output >= MAX_HANDLES || !sPictures[in->output].used) {
		protocol_error("submit names a buffer that does not exist", in->output);
	}

	job = &sQueue[sQueued++];
	memset(job, 0, sizeof(*job));
	job->id = ++sNextJob;
	job->job = *in;
	job->index = index;
	job->entries = malloc((size_t)in->command_count * sizeof(uint64_t));
	memcpy(job->entries, in->commands, (size_t)in->command_count
		* sizeof(uint64_t));
	job->job.commands = job->entries;
	for (i = 0; i < in->command_count && job->slices < 512; i++) {
		if (is_slice(job->entries, in->command_count, i))
			job->crcs[job->slices++] = slice_crc(job, i, &length);
	}

	/* not decoded yet: whoever reads it before waiting gets this */
	memset(sPictures[in->output].memory, 0x5a, sPictures[in->output].size);
	*_id = job->id;
	return 0;
}


static void
run(Job* job)
{
	FILE* log = log_file();
	const RpividJob* j = &job->job;
	Picture* out = &sPictures[j->output];
	const uint64_t* e = job->entries;
	const uint32_t n = j->command_count;
	const uint32_t ctb = 1u << j->log2_ctb_size;
	const uint32_t rows = (out->height + ctb - 1) / ctb;
	const size_t pu = round_up_size((size_t)out->width * out->height / 4);
	const size_t coeff = round_up_size((size_t)out->width * out->height);
	const uint32_t puStride = (uint32_t)((pu / rows) & ~(size_t)63);
	const uint32_t coeffStride = (uint32_t)((coeff / rows) & ~(size_t)63);
	const int writeMv = (j->config2 >> 15) & 1, readMv = (j->config2 >> 19) & 1;
	const uint32_t mvStride = out->motion_vectors
		? (((out->width + 63) & ~63u) + 63) >> 6 : 0;
	char a[32], b[32];
	uint32_t i, slice = 0, length;

	for (i = 0; i < n; i++) {
		if (is_slice(e, n, i) && slice < job->slices
			&& slice_crc(job, i, &length) != job->crcs[slice++]) {
			protocol_error("the bitstream changed before its picture was "
				"waited for", job->id);
		}
	}

	fprintf(log, "PIC %ld\n", sPictureNumber);
	fprintf(log, "K1 PUWSTRIDE=%u COEFFWSTRIDE=%u CFNUM=%u\n",
		(puStride + 63) >> 6, (coeffStride + 63) >> 6, n);
	for (i = 0; i < n; i++) {
		const uint32_t offset = (uint32_t)e[i], value = (uint32_t)(e[i] >> 32);
		if (is_slice(e, n, i)) {
			uint32_t crc = slice_crc(job, i, &length);
			fprintf(log, "C %u BS:%08x:%u\n", offset, crc, length);
		} else
			fprintf(log, "C %u %08x\n", offset, value);
	}
	fprintf(log, "K2 PURSTRIDE=%u COEFFRSTRIDE=%u OUTYSTRIDE=%u OUTCSTRIDE=%u "
		"CONFIG2=%08x FRAMESIZE=%08x CURRPOC=%d COLSTRIDE=%u MVSTRIDE=%u "
		"NUMROWS=%u\n", (puStride + 63) >> 6, (coeffStride + 63) >> 6,
		out->luma_stride >> 6, out->chroma_stride >> 6, j->config2,
		(out->height << 16) | out->width, j->current_poc, mvStride, mvStride,
		rows);
	if (!readMv)
		snprintf(b, sizeof(b), "0");
	else if (j->collocated != 0)
		snprintf(b, sizeof(b), "P%d", sPictures[j->collocated].poc);
	else
		snprintf(b, sizeof(b), "?");
	fprintf(log, "K2 MV=%s COL=%s\n", writeMv ? "CUR" : "0", b);
	fprintf(log, "K2 REF");
	for (i = 0; i < 16; i++) {
		symbol(a, sizeof(a), j->references[i], j->output);
		fprintf(log, " %s/%s", a, a);
	}
	fprintf(log, "\n");
	fflush(log);

	job->done = 1;
	if (job->index == env_long("MOCK_FAIL_LATE_AT", -1)) {
		fprintf(log, "MOCK picture %ld fails in the block\n", job->index);
		job->result = AVERROR(EIO);
	} else if (sGolden != NULL) {
		/* the GOP: the k-th distinct POC-0 picture of the stream (by its first
		   slice's CRC) */
		static uint32_t idrCrcs[256];
		static int idrs;
		static long gop;
		const long gopLength = env_long("MOCK_GOP", 0);
		if (j->current_poc == 0) {
			uint32_t crc = 0;
			int k;
			for (i = 0; i + 2 < n; i++) {
				if (is_slice(e, n, i)) {
					crc = slice_crc(job, i, &length);
					break;
				}
			}
			for (k = 0; k < idrs && idrCrcs[k] != crc; k++)
				;
			if (k == idrs && idrs < 256)
				idrCrcs[idrs++] = crc;
			gop = k;
		}
		golden_picture(out, (int32_t)(gop * gopLength + j->current_poc));
	}
	out->poc = j->current_poc;
	sPictureNumber++;
}


int
ff_rpivid_device_wait(RpividDevice* device, uint64_t id, int64_t timeout,
	RpividResult* result)
{
	int i, found = -1;

	for (i = 0; i < sQueued; i++) {
		if (sQueue[i].id == id)
			found = i;
	}
	if (found < 0)
		protocol_error("wait for a picture not submitted or already waited for",
			id);

	/* the block decodes in submission order */
	for (i = 0; i <= found; i++) {
		if (!sQueue[i].done)
			run(&sQueue[i]);
	}

	memset(result, 0, sizeof(*result));
	result->result = sQueue[found].result;
	result->command_status = sQueue[found].job.command_count;
	result->phase1_runs = 1;
	result->phase1_time = 100;
	result->phase2_time = 100;
	free(sQueue[found].entries);
	memmove(&sQueue[found], &sQueue[found + 1],
		(size_t)(sQueued - found - 1) * sizeof(Job));
	sQueued--;
	return 0;
}
