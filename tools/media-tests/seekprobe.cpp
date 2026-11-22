/*
 * seekprobe — does the media kit seek a video track where it is asked to (WP3,
 * docs/design/webpositive-video-overlay.md §6)? Opens FILE the way WebKit's media player does
 * (BMediaFile(BUrl("file://...")): the http_streamer add-on's BUrlRequest into a BAdapterIO) or as a
 * BFile, asks for B_YUV420 as WebKit does, decodes up to T0 seconds, then seeks to each time given:
 *
 *   seekprobe url|file FILE T0 SEEK...      (seconds; e.g. seekprobe url clip.mp4 12 5 20 40 2)
 *
 * For each seek: "SKP seek <want> -> <landed> (<status>)", the first frame decoded after it
 * ("first <start_time>"), and the frames decoded on to the one that shows <want> ("at <start_time> after
 * <n> frames, <ms> ms"). SKP_DUMP=DIR writes the top-left corner of the luma (where the test clips burn
 * in their time) of each first frame and each frame at the target as PGM files, to read them on the host.
 * T0 past the end: how reading ends ("read failed" / "no more frames" after N frames, the slowest read).
 *
 * Copyright 2026, Haiku-Pi project. Distributed under the terms of the MIT License.
 */

#include <Entry.h>
#include <MediaFile.h>
#include <MediaTrack.h>
#include <OS.h>
#include <Url.h>

#include <algorithm>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>


static void
dump(const char* dir, const char* name, const uint8* bits, uint32 lumaBytesPerRow, uint32 width,
	uint32 height)
{
	if (dir == NULL)
		return;
	char path[B_PATH_NAME_LENGTH];
	snprintf(path, sizeof(path), "%s/%s.pgm", dir, name);
	FILE* file = fopen(path, "wb");
	if (file == NULL)
		return;
	// the time stamp of the clips: the top-left 1/6 x 1/12 of the picture
	const uint32 w = width / 6, h = height / 12;
	fprintf(file, "P5\n%" B_PRIu32 " %" B_PRIu32 "\n255\n", w, h);
	for (uint32 y = 0; y < h; y++)
		fwrite(bits + (size_t)y * lumaBytesPerRow, 1, w, file);
	fclose(file);
}


int
main(int argc, char** argv)
{
	if (argc < 5 || (strcmp(argv[1], "url") != 0 && strcmp(argv[1], "file") != 0)) {
		fprintf(stderr, "usage: %s url|file FILE T0 SEEK...\n", argv[0]);
		return 2;
	}
	const bool url = strcmp(argv[1], "url") == 0;
	BMediaFile* file;
	if (url) {
		BString spec("file://");
		spec << argv[2];
		file = new BMediaFile(BUrl(spec.String(), false));
	} else {
		entry_ref ref;
		if (get_ref_for_path(argv[2], &ref) != B_OK) {
			printf("SKP no such file: %s\n", argv[2]);
			return 1;
		}
		file = new BMediaFile(&ref);
	}
	if (file->InitCheck() != B_OK) {
		printf("SKP cannot open %s: %s\n", argv[2], strerror(file->InitCheck()));
		return 1;
	}

	BMediaTrack* track = NULL;
	for (int32 i = 0; i < file->CountTracks(); i++) {
		BMediaTrack* candidate = file->TrackAt(i);
		media_format encoded;
		if (candidate != NULL && candidate->EncodedFormat(&encoded) == B_OK
			&& encoded.type == B_MEDIA_ENCODED_VIDEO) {
			track = candidate;
			break;
		}
		file->ReleaseTrack(candidate);
	}
	if (track == NULL) {
		printf("SKP no video track\n");
		return 1;
	}

	// as WebKit's media player asks (MediaPlayerPrivateHaiku.cpp IdentifyTracks())
	media_format format;
	format.Clear();
	track->DecodedFormat(&format);
	const uint32 width = format.Width(), height = format.Height();
	format.Clear();
	format.u.raw_video.display.format = B_YUV420;
	format.u.raw_video.display.line_width = width;
	format.u.raw_video.display.line_count = height;
	format.u.raw_video.display.bytes_per_row = (width + 3) / 4 * 6;
	if (track->DecodedFormat(&format) != B_OK || format.u.raw_video.display.format != B_YUV420) {
		printf("SKP no B_YUV420\n");
		return 1;
	}
	const uint32 lumaBytesPerRow = format.u.raw_video.display.bytes_per_row / 3 * 2;
	media_codec_info codec;
	if (track->GetCodecInfo(&codec) != B_OK)
		strcpy(codec.short_name, "?");
	printf("SKP %s %s: %s %" B_PRIu32 "x%" B_PRIu32 ", duration %.3f s\n", argv[1], argv[2],
		codec.short_name, width, height, track->Duration() / 1e6);

	uint8* buffer = (uint8*)malloc((size_t)format.u.raw_video.display.bytes_per_row * height + 65536);
	const char* dumpDir = getenv("SKP_DUMP");
	media_header header;
	int64 count;

	const bigtime_t t0 = (bigtime_t)(atof(argv[3]) * 1e6);
	int64 frames = 0;
	bigtime_t start = system_time(), slowest = 0;
	while (track->CurrentTime() < t0) {
		const bigtime_t readStart = system_time();
		status_t status = track->ReadFrames(buffer, &count, &header);
		slowest = std::max(slowest, system_time() - readStart);
		if (status != B_OK || count == 0) {
			// T0 past the end: how the end comes (the last frame, an error, the time it took)
			printf("SKP %s after %" B_PRId64 " frames at %.3f s, %.2f s in; the slowest read %.0f ms\n",
				status != B_OK ? "read failed" : "no more frames", frames, track->CurrentTime() / 1e6,
				(system_time() - start) / 1e6, slowest / 1e3);
			file->ReleaseTrack(track);
			delete file;
			return 1;
		}
		frames++;
		// the end: what each read gives
		if (track->CurrentTime() > track->Duration() - 300000 && frames < 100000) {
			printf("SKP   read %" B_PRId64 ": %s, %" B_PRId64 " frames, start_time %.3f, CurrentTime %.3f, %.0f ms\n",
				frames, strerror(status), count, header.start_time / 1e6, track->CurrentTime() / 1e6,
				(system_time() - readStart) / 1e3);
			if (track->CurrentTime() > track->Duration() + 2000000) {
				printf("SKP no end: reads go on past the duration\n");
				return 1;
			}
		}
	}
	printf("SKP decoded %" B_PRId64 " frames to %.3f s (last start_time %.3f) in %.2f s; the slowest read %.0f ms\n",
		frames, track->CurrentTime() / 1e6, header.start_time / 1e6, (system_time() - start) / 1e6, slowest / 1e3);

	int failures = 0;
	for (int i = 4; i < argc; i++) {
		const bigtime_t want = (bigtime_t)(atof(argv[i]) * 1e6);
		bigtime_t landed = want;
		start = system_time();
		status_t status = track->SeekToTime(&landed);
		printf("SKP seek %.3f -> %.3f (%s) in %.1f ms, CurrentTime %.3f\n", want / 1e6, landed / 1e6,
			strerror(status), (system_time() - start) / 1e3, track->CurrentTime() / 1e6);
		if (track->ReadFrames(buffer, &count, &header) != B_OK) {
			printf("SKP   no frame after the seek\n");
			failures++;
			continue;
		}
		char name[64];
		snprintf(name, sizeof(name), "seek%d-%s-first", i - 3, argv[i]);
		dump(dumpDir, name, buffer, lumaBytesPerRow, width, height);
		printf("SKP   first %.3f, CurrentTime %.3f\n", header.start_time / 1e6, track->CurrentTime() / 1e6);
		// on to the frame that shows the time asked for
		frames = 1;
		start = system_time();
		bool ok = true;
		while (track->CurrentTime() <= want) {
			if (track->ReadFrames(buffer, &count, &header) != B_OK) {
				ok = false;
				break;
			}
			frames++;
		}
		snprintf(name, sizeof(name), "seek%d-%s-at", i - 3, argv[i]);
		dump(dumpDir, name, buffer, lumaBytesPerRow, width, height);
		printf("SKP   at %.3f after %" B_PRId64 " frames, %.1f ms%s\n", header.start_time / 1e6, frames,
			(system_time() - start) / 1e3, ok ? "" : " (read failed)");
		// a landing more than one key frame interval (2 s here) before the target is wrong
		if (status != B_OK || want - landed > 2100000 || landed > want + 50000)
			failures++;
	}
	printf("SKP result: %d bad seeks of %d\n", failures, argc - 4);
	free(buffer);
	file->ReleaseTrack(track);
	delete file;
	return failures ? 1 : 0;
}
