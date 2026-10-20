#!/usr/bin/env bash
# build.sh — cross-build the HEVC decoder test (hevcdec.cpp) against the ffmpeg6 port in the sysroot
# (scripts/build-ffmpeg.sh), into the tree tools/media-tests/gen-hevc-clips.sh fills, for
# scripts/mkimage-pi4.sh --add-tree:
#
#   tools/media-tests/build.sh [OUT]     (default artifacts/media-tests/hevc/non-packaged: bin/hevcdec)
#
# Also copies FFmpeg's libraries (stripped) into OUT/lib: /boot/system/non-packaged/lib comes before the
# packages' libraries, so an image whose ffmpeg6 package predates hevc_rpivid uses them - hevcdec and
# the media kit's ffmpeg plugin (MediaPlayer) alike. And the rpivid kernel driver, if jam built it
# (scripts/build.sh rpivid), into OUT/add-ons/kernel/drivers/video: for an image without it.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="${1:-$root/artifacts/media-tests/hevc/non-packaged}"
sysroot="$root/artifacts/sysroot-arm64"
cross="$root/sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-"
lib="$sysroot/boot/system/non-packaged/lib"
[ -f "$lib/libavcodec.so" ] || { echo "media-tests: build ffmpeg first (scripts/build-ffmpeg.sh)" >&2; exit 1; }
mkdir -p "$out/bin"
"${cross}g++" --sysroot="$sysroot" -O2 -Wall -Wextra -I"$sysroot/boot/system/non-packaged/include" \
	"$root/tools/media-tests/hevcdec.cpp" -L"$lib" -Wl,-rpath-link,"$lib" \
	-lavformat -lavcodec -lavutil -o "$out/bin/hevcdec"
mkdir -p "$out/lib"
for l in "$root"/artifacts/cross-ports/ffmpeg6-6.1.6/install/boot/system/non-packaged/lib/lib*.so.[0-9]*; do
	case "$l" in *.so.[0-9]*.*) continue ;; esac
	"${cross}strip" -o "$out/lib/$(basename "$l")" "$(realpath "$l")"
done
driver="$root/sources/haiku/generated.arm64/objects/haiku/arm64/release/add-ons/kernel/drivers/video/rpivid/rpivid"
if [ -f "$driver" ]; then
	mkdir -p "$out/add-ons/kernel/drivers/video"
	cp "$driver" "$out/add-ons/kernel/drivers/video/rpivid"
fi
echo "media-tests: $out/bin/hevcdec, $(ls "$out/lib" | wc -l) FFmpeg libraries in $out/lib$([ -f "$driver" ] && echo ", the rpivid driver")"
