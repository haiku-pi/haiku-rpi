#!/usr/bin/env bash
# gen-hevc-clips.sh — small HEVC test streams for the rpivid decoder (docs/design/hw-video-decode.md),
# made with the host's ffmpeg + libx265 (x265's default tools: CTB 64, WPP, SAO, TMVP, weighted P
# prediction off, B pyramids), into a tree for scripts/mkimage-pi4.sh --add-tree:
#
#   tools/media-tests/gen-hevc-clips.sh [OUT]     (default artifacts/media-tests/hevc/non-packaged)
#
#   data/hevc-tests/intra.265     256x256, 1 I picture                         (stage 2)
#   data/hevc-tests/ipb.265       320x240, 24 pictures I/P/B, partial CTB row   (stage 3)
#   data/hevc-tests/weighted.265  256x144, 24 pictures, a fade, weighted P prediction
#   data/hevc-tests/main10.265    256x256, 16 pictures, Main 10
#   data/hevc-tests/hd.mp4        1280x720, 5 s, HEVC + AAC (MediaPlayer)
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="${1:-$root/artifacts/media-tests/hevc/non-packaged}/data/hevc-tests"
mkdir -p "$out"
ff=(ffmpeg -hide_banner -loglevel error -y)
x265=(-c:v libx265 -x265-params log-level=error)

"${ff[@]}" -f lavfi -i testsrc2=size=256x256:rate=25 -frames:v 1 "${x265[@]}" -pix_fmt yuv420p \
	"$out/intra.265"
"${ff[@]}" -f lavfi -i testsrc2=size=320x240:rate=25 -frames:v 24 "${x265[@]}" -pix_fmt yuv420p \
	"$out/ipb.265"
"${ff[@]}" -f lavfi -i "testsrc2=size=256x144:rate=25,fade=t=in:st=0:d=0.9" -frames:v 24 \
	-c:v libx265 -x265-params log-level=error:weightp=1 -pix_fmt yuv420p "$out/weighted.265"
"${ff[@]}" -f lavfi -i testsrc2=size=256x256:rate=25 -frames:v 16 "${x265[@]}" \
	-pix_fmt yuv420p10le "$out/main10.265"
"${ff[@]}" -f lavfi -i testsrc2=size=1280x720:rate=30 -f lavfi -i sine=frequency=440:sample_rate=44100 \
	-t 5 "${x265[@]}" -pix_fmt yuv420p -tag:v hvc1 -c:a aac -b:a 96k "$out/hd.mp4"
ls -l "$out"
