/*
 * tone — plays a 440 Hz sine through the media kit (BSoundPlayer: the system mixer, then the default
 * audio output) for a few seconds, and reports what the media server uses as its audio output.
 * "TONE " lines; exit status 0 when the player ran and asked for buffers.
 *
 *   tone [-s SECONDS] [-f HZ]
 */

#include <Application.h>
#include <MediaRoster.h>
#include <SoundPlayer.h>

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define SAY(...) do { printf("TONE " __VA_ARGS__); printf("\n"); fflush(stdout); } while (0)

static double sFrequency = 440;
static double sPhase = 0;
static int32 sBuffers = 0;


static void
play_buffer(void* cookie, void* buffer, size_t size, const media_raw_audio_format& format)
{
	// the mixer asks for float or 16-bit samples, interleaved
	const uint32 channels = format.channel_count;
	const double step = 2 * M_PI * sFrequency / format.frame_rate;
	if (format.format == media_raw_audio_format::B_AUDIO_FLOAT) {
		float* samples = (float*)buffer;
		for (size_t frame = 0; frame < size / sizeof(float) / channels; frame++) {
			const float value = 0.25 * sin(sPhase);
			sPhase += step;
			for (uint32 c = 0; c < channels; c++)
				*samples++ = value;
		}
	} else {
		int16* samples = (int16*)buffer;
		for (size_t frame = 0; frame < size / sizeof(int16) / channels; frame++) {
			const int16 value = (int16)(8000 * sin(sPhase));
			sPhase += step;
			for (uint32 c = 0; c < channels; c++)
				*samples++ = value;
		}
	}
	if (sPhase > 2 * M_PI)
		sPhase = fmod(sPhase, 2 * M_PI);
	atomic_add(&sBuffers, 1);
}


int
main(int argc, char** argv)
{
	double seconds = 3;
	int opt;
	while ((opt = getopt(argc, argv, "s:f:")) != -1) {
		if (opt == 's')
			seconds = atof(optarg);
		else if (opt == 'f')
			sFrequency = atof(optarg);
		else {
			fprintf(stderr, "usage: %s [-s seconds] [-f hz]\n", argv[0]);
			return 2;
		}
	}

	BApplication app("application/x-vnd.haiku-rpi-tone");
	status_t status;
	BMediaRoster* roster = BMediaRoster::Roster(&status);
	if (roster == NULL) {
		SAY("no media roster: %s", strerror(status));
		return 1;
	}
	media_node output;
	if (roster->GetAudioOutput(&output) == B_OK) {
		live_node_info info;
		if (roster->GetLiveNodeInfo(output, &info) == B_OK)
			SAY("default audio output: %s (node %" B_PRId32 ")", info.name, output.node);
		roster->ReleaseNode(output);
	} else
		SAY("no default audio output");

	BSoundPlayer player("tone", play_buffer);
	if (player.InitCheck() != B_OK) {
		SAY("sound player: %s", strerror(player.InitCheck()));
		return 1;
	}
	const media_raw_audio_format& format = player.Format();
	SAY("format: %.0f Hz, %" B_PRIu32 " channels, format %#" B_PRIx32 ", %zu-byte buffers",
		format.frame_rate, format.channel_count, format.format, format.buffer_size);
	player.SetHasData(true);
	player.Start();
	snooze((bigtime_t)(seconds * 1000000));
	player.Stop();
	SAY("played %" B_PRId32 " buffers in %.1f s", sBuffers, seconds);
	return sBuffers > 0 ? 0 : 1;
}
