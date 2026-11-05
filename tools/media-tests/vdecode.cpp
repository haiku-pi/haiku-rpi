/*
 * vdecode — decodes a media file's first video track as fast as it goes through the media kit (BMediaFile,
 * BMediaTrack::ReadFrames: on this port the ffmpeg plugin, with h264_mmal for H.264 on the VideoCore), into
 * B_RGB32 frames as MediaPlayer asks for them, and measures it (H21 step 3, docs/design/vchiq.md §8):
 *
 *   vdecode [-n FRAMES] FILE
 *
 * "VDEC frames <n> in <s> s = <fps> frames/s; per frame <ms> ms mean, <ms> ms max (after the first); team CPU <s> s
 * = <p> % of one CPU", and the frames that came more than 40 ms after the one before. FFMPEG_H264_MMAL=0: the
 * software decoder.
 *
 * Copyright 2026, Haiku-Pi project. Distributed under the terms of the MIT License.
 */

#include <MediaFile.h>
#include <MediaTrack.h>
#include <OS.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>


static bigtime_t
team_cpu()
{
	team_usage_info usage;
	get_team_usage_info(B_CURRENT_TEAM, B_TEAM_USAGE_SELF, &usage);
	return usage.user_time + usage.kernel_time;
}


int
main(int argc, char** argv)
{
	int64 maxFrames = -1;
	int first = 1;
	if (argc > 3 && strcmp(argv[1], "-n") == 0) {
		maxFrames = atoll(argv[2]);
		first = 3;
	}
	if (argc != first + 1) {
		fprintf(stderr, "usage: %s [-n FRAMES] FILE\n", argv[0]);
		return 2;
	}
	entry_ref ref;
	if (get_ref_for_path(argv[first], &ref) != B_OK) {
		printf("VDEC no such file: %s\n", argv[first]);
		return 1;
	}
	BMediaFile file(&ref);
	if (file.InitCheck() != B_OK) {
		printf("VDEC cannot open %s: %s\n", argv[first], strerror(file.InitCheck()));
		return 1;
	}

	BMediaTrack* track = NULL;
	media_format format;
	for (int32 i = 0; i < file.CountTracks(); i++) {
		BMediaTrack* candidate = file.TrackAt(i);
		media_format encoded;
		if (candidate != NULL && candidate->EncodedFormat(&encoded) == B_OK
			&& encoded.type == B_MEDIA_ENCODED_VIDEO) {
			track = candidate;
			break;
		}
		file.ReleaseTrack(candidate);
	}
	if (track == NULL) {
		printf("VDEC no video track\n");
		return 1;
	}

	bigtime_t start = system_time();
	bigtime_t cpuStart = team_cpu();
	format.Clear();
	format.type = B_MEDIA_RAW_VIDEO;
	format.u.raw_video.display.format = B_RGB32;
	if (track->DecodedFormat(&format) != B_OK) {
		printf("VDEC no decoded format\n");
		return 1;
	}
	media_codec_info codec;
	if (track->GetCodecInfo(&codec) == B_OK)
		printf("VDEC codec %s (%s)\n", codec.short_name, codec.pretty_name);
	const media_raw_video_format& video = format.u.raw_video;
	size_t size = video.display.bytes_per_row * video.display.line_count;
	printf("VDEC %" B_PRIu32 "x%" B_PRIu32 ", %" B_PRIu32 " bytes per row, %.2f frames/s\n",
		video.display.line_width, video.display.line_count, video.display.bytes_per_row, video.field_rate);
	void* buffer = malloc(size);

	int64 frames = 0, slow = 0;
	bigtime_t firstFrame = 0, last = 0, worst = 0;
	while (maxFrames < 0 || frames < maxFrames) {
		int64 count = 0;
		media_header header;
		status_t status = track->ReadFrames(buffer, &count, &header);
		if (status != B_OK || count == 0)
			break;
		bigtime_t now = system_time();
		if (frames == 0)
			firstFrame = now;
		else {
			if (now - last > worst)
				worst = now - last;
			if (now - last > 40000 && slow++ < 12) {
				printf("VDEC slow: frame %" B_PRId64 " after %.1f ms\n", frames,
					(now - last) / 1e3);
			}
		}
		last = now;
		frames += count;
	}
	bigtime_t end = system_time();
	bigtime_t cpu = team_cpu() - cpuStart;
	printf("VDEC %" B_PRId64 " frames came more than 40 ms after the one before\n", slow);
	printf("VDEC frames %" B_PRId64 " in %.3f s = %.1f frames/s; per frame %.1f ms mean, %.1f ms max (after the"
		" first, %.0f ms in); team CPU %.3f s = %.1f %% of one CPU\n", frames, (end - start) / 1e6,
		frames / ((end - start) / 1e6), frames > 1 ? (end - firstFrame) / 1e3 / (frames - 1) : 0.0,
		worst / 1e3, (firstFrame - start) / 1e3, cpu / 1e6, 100.0 * cpu / (end - start));
	free(buffer);
	file.ReleaseTrack(track);
	return frames > 0 ? 0 : 1;
}
