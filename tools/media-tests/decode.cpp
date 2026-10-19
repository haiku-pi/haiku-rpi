/*
 * decode — decodes a media file's first audio track to raw samples through the media kit's codec
 * plugins (BMediaFile/BMediaTrack: on this port, the ffmpeg plugin) and reports the format and how
 * many frames came out. "DEC " lines; exit status 0 when frames were decoded.
 *
 *   decode FILE
 */

#include <MediaFile.h>
#include <MediaTrack.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SAY(...) do { printf("DEC " __VA_ARGS__); printf("\n"); fflush(stdout); } while (0)


int
main(int argc, char** argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: %s file\n", argv[0]);
		return 2;
	}
	entry_ref ref;
	if (get_ref_for_path(argv[1], &ref) != B_OK) {
		SAY("no such file: %s", argv[1]);
		return 1;
	}
	BMediaFile file(&ref);
	if (file.InitCheck() != B_OK) {
		SAY("cannot open %s: %s", argv[1], strerror(file.InitCheck()));
		return 1;
	}
	media_file_format fileFormat;
	if (file.GetFileFormatInfo(&fileFormat) == B_OK)
		SAY("container: %s, %" B_PRId32 " tracks", fileFormat.pretty_name, file.CountTracks());

	for (int32 i = 0; i < file.CountTracks(); i++) {
		BMediaTrack* track = file.TrackAt(i);
		media_format format;
		format.type = B_MEDIA_RAW_AUDIO;
		if (track == NULL || track->DecodedFormat(&format) != B_OK
			|| format.type != B_MEDIA_RAW_AUDIO) {
			if (track != NULL)
				file.ReleaseTrack(track);
			continue;
		}
		media_codec_info codec;
		if (track->GetCodecInfo(&codec) == B_OK)
			SAY("track %" B_PRId32 ": codec %s", i, codec.pretty_name);
		const media_raw_audio_format& raw = format.u.raw_audio;
		SAY("decoding to %.0f Hz, %" B_PRIu32 " channels, format %#" B_PRIx32, raw.frame_rate,
			raw.channel_count, raw.format);
		char* buffer = (char*)malloc(raw.buffer_size > 0 ? raw.buffer_size : 65536);
		int64 total = 0, frames;
		while (track->ReadFrames(buffer, &frames) == B_OK)
			total += frames;
		free(buffer);
		SAY("decoded %" B_PRId64 " frames (%.2f s)", total, total / raw.frame_rate);
		file.ReleaseTrack(track);
		return total > 0 ? 0 : 1;
	}
	SAY("no audio track");
	return 1;
}
