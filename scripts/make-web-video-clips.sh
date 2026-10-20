#!/usr/bin/env bash
# make-web-video-clips.sh — short test clips in the formats web pages use, for the browsers on the Pi
# (tools/pi-tests/firefox-video.sh): 10 s of ffmpeg's moving testsrc2 pattern at 1280x720, 30 fps,
# as H.264 in MP4, VP9 in WebM and AV1 in WebM, and H.264 at 1920x1080; with the HEVC clips of
# artifacts/media-tests/hevc (hd.mp4: HEVC 720p) copied next to them.
#
#   scripts/make-web-video-clips.sh
#
# Output: artifacts/media-tests/web/non-packaged/data/web-video/ (scripts/mkimage-pi4.sh --add-tree
# artifacts/media-tests/web/non-packaged). Needs the host's ffmpeg with libx264, libvpx and libsvtav1.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/artifacts/media-tests/web/non-packaged/data/web-video"
mkdir -p "$out"
src=(-f lavfi -i "testsrc2=size=1280x720:rate=30:duration=10")
ff() { ffmpeg -hide_banner -loglevel error -y "$@"; }
ff "${src[@]}" -c:v libx264 -profile:v high -pix_fmt yuv420p -b:v 3M "$out/h264-720p.mp4"
ff -f lavfi -i "testsrc2=size=1920x1080:rate=30:duration=10" -c:v libx264 -profile:v high \
	-pix_fmt yuv420p -b:v 6M "$out/h264-1080p.mp4"
ff "${src[@]}" -c:v libvpx-vp9 -b:v 2M -deadline realtime -cpu-used 8 -row-mt 1 "$out/vp9-720p.webm"
ff "${src[@]}" -c:v libsvtav1 -preset 10 -b:v 2M "$out/av1-720p.webm"
hevc="$root/artifacts/media-tests/hevc/non-packaged/data/hevc-tests/hd.mp4"
[ -f "$hevc" ] && cp "$hevc" "$out/hevc-720p.mp4"
ls -l "$out"
