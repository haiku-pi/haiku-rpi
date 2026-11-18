/*
 * vdecode — decodes a media file's first video track as fast as it goes through the media kit (BMediaFile,
 * BMediaTrack::ReadFrames: on this port the ffmpeg plugin, with h264_mmal for H.264 on the VideoCore), into
 * B_RGB32 frames as MediaPlayer asks for them, and measures it (H21 step 3, docs/design/vchiq.md §8):
 *
 *   vdecode [-n FRAMES] FILE
 *
 * VDEC_SPACE=yuv420 asks for B_YUV420 instead (planar; the ffmpeg plugin copies the decoder's planes,
 * docs/design/video-overlay.md). VDEC_SWITCH=N asks for the other space (and nothing else changed) after N
 * frames. VDEC_DUMP=FILE writes each frame's visible pixels to FILE: B_YUV420 as packed yuv420p (Y, Cb, Cr
 * without row padding: its md5 is ffmpeg's framemd5), B_RGB32 as bgra rows; "VDEC frame <n> <space>" says which.
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
	const char* space = getenv("VDEC_SPACE");
	format.u.raw_video.display.format
		= space != NULL && strcmp(space, "yuv420") == 0 ? B_YUV420 : B_RGB32;
	if (track->DecodedFormat(&format) != B_OK) {
		printf("VDEC no decoded format\n");
		return 1;
	}
	media_codec_info codec;
	if (track->GetCodecInfo(&codec) == B_OK)
		printf("VDEC codec %s (%s)\n", codec.short_name, codec.pretty_name);
	const media_raw_video_format& video = format.u.raw_video;
	size_t size = video.display.bytes_per_row * video.display.line_count;
	printf("VDEC %" B_PRIu32 "x%" B_PRIu32 ", %s, %" B_PRIu32 " bytes per row, %.2f frames/s\n",
		video.display.line_width, video.display.line_count,
		video.display.format == B_YUV420 ? "B_YUV420" : "B_RGB32", video.display.bytes_per_row,
		video.field_rate);
	const char* dumpPath = getenv("VDEC_DUMP");
	FILE* dump = dumpPath != NULL ? fopen(dumpPath, "wb") : NULL;
	const char* switchSetting = getenv("VDEC_SWITCH");
	const int64 switchAt = switchSetting != NULL ? atoll(switchSetting) : -1;
	// room for either space (the switch may need more)
	size = video.display.line_width * 4 * video.display.line_count + 65536;
	void* buffer = malloc(size);

	int64 frames = 0, slow = 0;
	bigtime_t firstFrame = 0, last = 0, worst = 0;
	while (maxFrames < 0 || frames < maxFrames) {
		int64 count = 0;
		media_header header;
		status_t status = track->ReadFrames(buffer, &count, &header);
		if (status != B_OK || count == 0)
			break;
		if (dump != NULL) {
			const media_raw_video_format& v = format.u.raw_video;
			const uint8* bits = (const uint8*)buffer;
			const uint32 w = v.display.line_width, hgt = v.display.line_count;
			const uint32 bpr = v.display.bytes_per_row;
			if (v.display.format == B_YUV420) {
				const uint32 luma = bpr / 3 * 2;
				for (uint32 y = 0; y < hgt; y++)
					fwrite(bits + y * luma, 1, w, dump);
				const uint8* cb = bits + luma * hgt;
				const uint8* cr = cb + luma / 2 * (hgt / 2);
				for (uint32 y = 0; y < hgt / 2; y++)
					fwrite(cb + y * (luma / 2), 1, w / 2, dump);
				for (uint32 y = 0; y < hgt / 2; y++)
					fwrite(cr + y * (luma / 2), 1, w / 2, dump);
			} else {
				for (uint32 y = 0; y < hgt; y++)
					fwrite(bits + y * bpr, 1, w * 4, dump);
			}
			printf("VDEC frame %" B_PRId64 " %s\n", frames,
				v.display.format == B_YUV420 ? "yuv420" : "rgb32");
		}
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
		if (frames == switchAt) {
			// only the output space changes: the decoder must go on where it is
			format.u.raw_video.display.format
				= format.u.raw_video.display.format == B_YUV420 ? B_RGB32 : B_YUV420;
			format.u.raw_video.display.bytes_per_row = 0;
			status_t status = track->DecodedFormat(&format);
			printf("VDEC switched after %" B_PRId64 " frames: %s, %s, %" B_PRIu32 " bytes per row\n",
				frames, strerror(status),
				format.u.raw_video.display.format == B_YUV420 ? "B_YUV420" : "B_RGB32",
				format.u.raw_video.display.bytes_per_row);
		}
	}
	bigtime_t end = system_time();
	bigtime_t cpu = team_cpu() - cpuStart;
	printf("VDEC %" B_PRId64 " frames came more than 40 ms after the one before\n", slow);
	printf("VDEC frames %" B_PRId64 " in %.3f s = %.1f frames/s; per frame %.1f ms mean, %.1f ms max (after the"
		" first, %.0f ms in); team CPU %.3f s = %.1f %% of one CPU\n", frames, (end - start) / 1e6,
		frames / ((end - start) / 1e6), frames > 1 ? (end - firstFrame) / 1e3 / (frames - 1) : 0.0,
		worst / 1e3, (firstFrame - start) / 1e3, cpu / 1e6, 100.0 * cpu / (end - start));
	free(buffer);
	if (dump != NULL)
		fclose(dump);
	file.ReleaseTrack(track);
	return frames > 0 ? 0 : 1;
}
