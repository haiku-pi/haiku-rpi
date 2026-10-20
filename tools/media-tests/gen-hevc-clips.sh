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
#
# Heavy streams, for the measurements (hevcdec's bench lines): a test pattern under temporal noise, so
# that x265 has to spend the bit rate (noise is what a bit-rate-bound encode of real footage spends its
# bits on), 1 s GOPs, VBV-capped:
#
#   data/hevc-tests/fhd.mp4       1920x1080 Main,    3 s, 20 Mbit/s
#   data/hevc-tests/fhd10.mp4     1920x1080 Main 10, 2 s, 20 Mbit/s
#   data/hevc-tests/uhd.mp4       3840x2160 Main,    2 s, 30 Mbit/s
#   data/hevc-tests/uhd10.mp4     3840x2160 Main 10, 2 s, 30 Mbit/s
#
# HEAVY=0 in the environment: not these (about 28 MB).
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

heavy() {	# name size seconds pix_fmt kbit/s
	"${ff[@]}" -f lavfi -i "testsrc2=size=$2:rate=30,noise=alls=10:allf=t+u" -t "$3" -c:v libx265 \
		-x265-params "log-level=error:keyint=30:vbv-maxrate=$5:vbv-bufsize=$(($5 * 2))" -b:v "$5k" \
		-pix_fmt "$4" -tag:v hvc1 "$out/$1.mp4"
}
if [ "${HEAVY:-1}" != 0 ]; then
	heavy fhd 1920x1080 3 yuv420p 20000
	heavy fhd10 1920x1080 2 yuv420p10le 20000
	heavy uhd 3840x2160 2 yuv420p 30000
	heavy uhd10 3840x2160 2 yuv420p10le 30000
fi
ls -l "$out"
