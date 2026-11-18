/*
 * venc — video encoding through the media kit (BMediaFile + an encoder of the ffmpeg plugin), as MediaConverter
 * does it (docs/design/videocore-services.md §3):
 *
 *   venc [-n FRAMES] [-s WxH] [-r FPS] [-q QUALITY] [-c CODEC] [-f FORMAT] OUT
 *
 * FRAMES (default 300) B_RGB32 frames of WxH (default 1280x720) of a moving pattern, encoded with the encoder whose
 * short name is CODEC (default h264) into a FORMAT file (default mp4: the muxer's short name), at QUALITY 0..1
 * (default 0.5, the encode parameters' quality). Lines "VENC ...": the encoders the file format offers, the time and
 * this team's CPU.
 *
 * Copyright 2026, Haiku-Pi project. Distributed under the terms of the MIT License.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <unistd.h>

#include <Entry.h>
#include <MediaFile.h>
#include <MediaFormats.h>
#include <MediaTrack.h>
#include <OS.h>


static bigtime_t
team_cpu_time()
{
	struct rusage usage;
	getrusage(RUSAGE_SELF, &usage);
	return (bigtime_t)(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000000
		+ usage.ru_utime.tv_usec + usage.ru_stime.tv_usec;
}


int
main(int argc, char** argv)
{
	int frames = 300, opt;
	unsigned width = 1280, height = 720;
	float fps = 30, quality = 0.5f;
	const char* codecName = "h264";
	const char* formatName = "mp4";
	while ((opt = getopt(argc, argv, "n:s:r:q:c:f:")) != -1) {
		switch (opt) {
			case 'n': frames = atoi(optarg); break;
			case 's': sscanf(optarg, "%ux%u", &width, &height); break;
			case 'r': fps = atof(optarg); break;
			case 'q': quality = atof(optarg); break;
			case 'c': codecName = optarg; break;
			case 'f': formatName = optarg; break;
			default: return 2;
		}
	}
	if (optind != argc - 1) {
		fprintf(stderr, "usage: venc [-n FRAMES] [-s WxH] [-r FPS] [-q QUALITY] [-c CODEC] [-f FORMAT] OUT\n");
		return 2;
	}

	media_file_format fileFormat;
	int32 cookie = 0;
	bool found = false;
	while (get_next_file_format(&cookie, &fileFormat) == B_OK) {
		if (strcmp(fileFormat.short_name, formatName) == 0) {
			found = true;
			break;
		}
	}
	if (!found) {
		printf("VENC FAIL: no file format %s\n", formatName);
		return 1;
	}

	media_format input;
	input.Clear();
	input.type = B_MEDIA_RAW_VIDEO;
	input.u.raw_video.display.format = B_RGB32;
	input.u.raw_video.display.line_width = width;
	input.u.raw_video.display.line_count = height;
	input.u.raw_video.display.bytes_per_row = width * 4;
	input.u.raw_video.field_rate = fps;
	input.u.raw_video.interlace = 1;
	input.u.raw_video.first_active = 0;
	input.u.raw_video.last_active = height - 1;
	input.u.raw_video.orientation = B_VIDEO_TOP_LEFT_RIGHT;
	input.u.raw_video.pixel_width_aspect = 1;
	input.u.raw_video.pixel_height_aspect = 1;

	media_codec_info codec, info;
	media_format output;
	found = false;
	cookie = 0;
	while (get_next_encoder(&cookie, &fileFormat, &input, &output, &info) == B_OK) {
		printf("VENC encoder for %s: %s (%s)\n", formatName, info.short_name, info.pretty_name);
		if (!found && strcmp(info.short_name, codecName) == 0) {
			codec = info;
			found = true;
		}
	}
	if (!found) {
		printf("VENC FAIL: no encoder %s for %s\n", codecName, formatName);
		return 1;
	}

	entry_ref ref;
	if (get_ref_for_path(argv[optind], &ref) != B_OK) {
		printf("VENC FAIL: %s\n", argv[optind]);
		return 1;
	}
	BMediaFile file(&ref, &fileFormat);
	if (file.InitCheck() != B_OK) {
		printf("VENC FAIL: BMediaFile: %s\n", strerror(file.InitCheck()));
		return 1;
	}
	BMediaTrack* track = file.CreateTrack(&input, &codec);
	if (track == NULL) {
		printf("VENC FAIL: CreateTrack\n");
		return 1;
	}
	media_encode_info encodeInfo;
	encode_parameters parameters;
	if (track->GetEncodeParameters(&parameters) == B_OK) {
		parameters.quality = quality;
		track->SetEncodeParameters(&parameters);
	}
	status_t status = file.CommitHeader();
	if (status != B_OK) {
		printf("VENC FAIL: CommitHeader: %s\n", strerror(status));
		return 1;
	}

	uint32* pixels = new uint32[width * height];
	bigtime_t start = system_time(), teamStart = team_cpu_time();
	for (int i = 0; i < frames; i++) {
		// diagonal bands moving right, a block moving down
		for (unsigned y = 0; y < height; y++) {
			uint32* row = pixels + y * width;
			for (unsigned x = 0; x < width; x++) {
				uint8 v = (uint8)((x + y + i * 4) & 0xff);
				row[x] = 0xff000000 | (v << 16) | ((uint8)(x * 255 / width) << 8) | (uint8)(255 - v);
			}
		}
		unsigned top = (i * 4) % (height - 64);
		for (unsigned y = top; y < top + 64; y++)
			for (unsigned x = width / 2 - 32; x < width / 2 + 32; x++)
				pixels[y * width + x] = 0xffffffff;
		encodeInfo = media_encode_info();
		encodeInfo.flags = i == 0 ? B_MEDIA_KEY_FRAME : 0;
		encodeInfo.start_time = (bigtime_t)(i * 1000000LL / fps);
		status = track->WriteFrames(pixels, 1, &encodeInfo);
		if (status != B_OK) {
			printf("VENC FAIL: WriteFrames %d: %s\n", i, strerror(status));
			return 1;
		}
	}
	bigtime_t wall = system_time() - start, team = team_cpu_time() - teamStart;
	status = file.CloseFile();
	printf("VENC %s %ux%u: %d frames in %.2f s (%.1f frames/s), this team's cpu %.2f s (%.0f %% of one CPU);"
		" close %s\n", codec.short_name, width, height, frames, wall / 1e6, frames / (wall / 1e6), team / 1e6,
		100.0 * team / wall, strerror(status));
	printf("VENC result: %s\n", status == B_OK ? "PASS" : "FAIL");
	return status == B_OK ? 0 : 1;
}
