#!/usr/bin/env bash
# gen-h264-clips.sh — H.264 test files for h264_mmal, the VideoCore's decoder in the media kit (H21 step 3,
# docs/design/vchiq.md §8), made with the host's ffmpeg + libx264 (High profile, 3 B-frames, CABAC):
#
#   tools/media-tests/gen-h264-clips.sh [OUT]     (default artifacts/media-tests/h264)
#
#   h264-720p.mp4, h264-1080p.mp4   step 2's streams (scripts/build-mmal.sh --clips: 300 frames under temporal
#                                   noise, 6 / 12 Mbit/s) encoded into MP4, i.e. as an "avcC" record and
#                                   length-prefixed NAL units (a remux of the Annex-B files would lose the B-frames'
#                                   timestamps); with their .framemd5 and .below16.md5 (ffmpeg's frames, and the
#                                   same with the samples below 16 lowered by one: what the VideoCore outputs) for a
#                                   check of every frame
#   play-720p30.mp4                 60 s, 1280x720, 30 fps, light noise, 4 Mbit/s (MediaPlayer)
#   play-1080p30.mp4                60 s, 1920x1080, 30 fps, light noise, 8 Mbit/s
#   play-1080p60.mp4                30 s, 1920x1080, 60 fps, light noise, 12 Mbit/s (above the VideoCore's rate
#                                   at its minimum clock)
#   long-720p30.mp4                 330 s, 1280x720, 30 fps, 2 Mbit/s (the 5-minute play)
#   video.html                      a page with a <video> of play-720p30.mp4 (WebPositive)
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="${1:-$root/artifacts/media-tests/h264}"
mkdir -p "$out"
ff() { ffmpeg -hide_banner -loglevel error -y "$@"; }

checked() {	# NAME SIZE BITRATE: as scripts/build-mmal.sh --clips, in MP4
	local f="$out/$1"
	ff -f lavfi -i "testsrc2=size=$2:rate=30,noise=alls=12:allf=t+u" -frames:v 300 -c:v libx264 -preset medium \
		-profile:v high -pix_fmt yuv420p -bf 3 -b:v "$3" -maxrate "$3" -bufsize "$3" "$f.mp4"
	ff -i "$f.mp4" -fps_mode passthrough -f framemd5 -pix_fmt yuv420p "$f.framemd5"
	ffmpeg -loglevel error -i "$f.mp4" -fps_mode passthrough -f rawvideo -pix_fmt yuv420p - | python3 -c '
import hashlib, sys
width, height = map(int, sys.argv[1].split("x"))
size = width * height * 3 // 2
table = bytes(v - 1 if 0 < v < 16 else v for v in range(256))
while True:
    frame = sys.stdin.buffer.read(size)
    if len(frame) < size:
        break
    print(hashlib.md5(frame.translate(table)).hexdigest())' "$2" > "$f.below16.md5"
}
checked h264-720p 1280x720 6M
checked h264-1080p 1920x1080 12M

play() {	# NAME SIZE RATE SECONDS BITRATE
	ff -f lavfi -i "testsrc2=size=$2:rate=$3:duration=$4,noise=alls=4:allf=t+u" -c:v libx264 -preset medium \
		-profile:v high -pix_fmt yuv420p -bf 3 -g $(($3 * 2)) -b:v "$5" -maxrate "$5" -bufsize "$5" \
		-movflags +faststart "$out/$1.mp4"
}
play play-720p30 1280x720 30 60 4M
play play-1080p30 1920x1080 30 60 8M
play play-1080p60 1920x1080 60 30 12M
play long-720p30 1280x720 30 330 2M

cat > "$out/video.html" << 'EOF'
<!DOCTYPE html>
<html><head><title>H.264 video</title></head>
<body style="background: #222; color: #ddd">
<p>play-720p30.mp4 (H.264, 1280x720, 30 fps)</p>
<video src="play-720p30.mp4" width="960" autoplay controls></video>
</body></html>
EOF
ls -l "$out"
