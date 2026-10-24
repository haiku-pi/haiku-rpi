/*
 * hmultitone — plays a sine straight through a multi_audio (hmulti) driver, without the media server:
 * B_MULTI_GET_BUFFERS, then B_MULTI_BUFFER_EXCHANGE in a loop, filling the buffer that is not playing.
 * Tests a driver on its own (the media server picks one output; this takes any).
 *
 *   hmultitone DEVICE [SECONDS] [HZ]     e.g. hmultitone /dev/audio/hmulti/bcm2711_hdmi_audio/1 5 1000
 *
 * "HMT " lines: the driver's name and rate, the buffers, exchanges per second, played frames.
 *
 * Build (cross):
 *   g=sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-g++
 *   $g --sysroot=artifacts/sysroot-arm64 -O2 -I sources/haiku/headers/private/audio \
 *     -o hmultitone tools/media-tests/hmultitone.cpp
 */
#include <OS.h>

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <hmulti_audio.h>


#define SAY(...) do { printf("HMT " __VA_ARGS__); printf("\n"); fflush(stdout); } while (0)


static uint32
rate_of(uint32 bits)
{
	static const struct { uint32 bit, rate; } kRates[] = {
		{ B_SR_44100, 44100 }, { B_SR_48000, 48000 }, { B_SR_96000, 96000 },
		{ B_SR_32000, 32000 }, { B_SR_22050, 22050 }, { B_SR_88200, 88200 },
	};
	for (auto& r : kRates)
		if (bits & r.bit)
			return r.rate;
	return 0;
}


int
main(int argc, char** argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: hmultitone DEVICE [SECONDS] [HZ]\n");
		return 2;
	}
	double seconds = argc > 2 ? atof(argv[2]) : 5;
	double frequency = argc > 3 ? atof(argv[3]) : 1000;

	int fd = open(argv[1], O_RDWR);
	if (fd < 0) {
		SAY("cannot open %s: %s", argv[1], strerror(errno));
		return 1;
	}

	multi_channel_info channels[16];
	multi_description description;
	memset(&description, 0, sizeof(description));
	description.info_size = sizeof(description);
	description.request_channel_count = 16;
	description.channels = channels;
	if (ioctl(fd, B_MULTI_GET_DESCRIPTION, &description, sizeof(description)) < 0) {
		SAY("B_MULTI_GET_DESCRIPTION: %s", strerror(errno));
		return 1;
	}
	uint32 rate = rate_of(description.output_rates);
	SAY("device \"%s\", %d output channels, %u Hz", description.friendly_name,
		(int)description.output_channel_count, (unsigned)rate);

	enum { kMaxBuffers = 8, kMaxChannels = 8 };
	buffer_desc rows[kMaxBuffers][kMaxChannels];
	buffer_desc* rowPointers[kMaxBuffers];
	for (int i = 0; i < kMaxBuffers; i++)
		rowPointers[i] = rows[i];
	multi_buffer_list list;
	memset(&list, 0, sizeof(list));
	list.request_playback_buffers = kMaxBuffers;
	list.request_playback_channels = kMaxChannels;
	list.playback_buffers = rowPointers;
	if (ioctl(fd, B_MULTI_GET_BUFFERS, &list, sizeof(list)) < 0) {
		SAY("B_MULTI_GET_BUFFERS: %s", strerror(errno));
		return 1;
	}
	const int buffers = list.return_playback_buffers;
	const int channelCount = list.return_playback_channels;
	const int frames = list.return_playback_buffer_size;
	SAY("%d buffers of %d frames, %d channels", buffers, frames, channelCount);

	double phase = 0;
	const double step = 2 * M_PI * frequency / rate;
	auto fill = [&](int buffer) {
		for (int frame = 0; frame < frames; frame++) {
			int16 value = (int16)(8000 * sin(phase));
			phase += step;
			for (int c = 0; c < channelCount; c++) {
				*(int16*)(rows[buffer][c].base + frame * rows[buffer][c].stride) = value;
			}
		}
	};
	for (int i = 0; i < buffers; i++)
		fill(i);

	multi_buffer_info info;
	memset(&info, 0, sizeof(info));
	info.info_size = sizeof(info);
	bigtime_t start = system_time();
	int exchanges = 0, failures = 0;
	int64 firstFrames = -1;
	while (system_time() - start < seconds * 1000000) {
		if (ioctl(fd, B_MULTI_BUFFER_EXCHANGE, &info, sizeof(info)) < 0) {
			if (failures++ < 3)
				SAY("B_MULTI_BUFFER_EXCHANGE: %s", strerror(errno));
			continue;
		}
		if (firstFrames < 0)
			firstFrames = info.played_frames_count;
		exchanges++;
		fill((info.playback_buffer_cycle + 1) % buffers);
	}
	double elapsed = (system_time() - start) / 1e6;
	SAY("%d exchanges in %.2f s (%.1f/s), played %lld frames (%.0f frames/s), %d failures",
		exchanges, elapsed, exchanges / elapsed,
		(long long)(info.played_frames_count - firstFrames),
		(info.played_frames_count - firstFrames) / elapsed, failures);
	ioctl(fd, B_MULTI_BUFFER_FORCE_STOP, NULL, 0);
	close(fd);
	return failures != 0;
}
