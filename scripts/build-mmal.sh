#!/usr/bin/env bash
# build-mmal.sh — Broadcom's MMAL, libvchiq and VCOS (raspberrypi/userland, BSD-3-Clause) for arm64 Haiku, and the
# H.264 decode test on them (H21 step 2, docs/design/vchiq.md §7):
#
#   scripts/build-mmal.sh [--package] [--clips]
#
# 1. the recipe tools/recipes/media-libs/raspberrypi_userland (its patchset: Haiku support, two pthread objects used
#    zeroed, the VideoCore's 32-bit message layout on a 64-bit host, a Makefile for the libraries only), cross-built
#    by scripts/cross-port.sh -> artifacts/cross-ports/raspberrypi_userland-20241223/install, and into the sysroot's
#    non-packaged/ (where later builds find the headers and libraries);
# 2. tools/haiku-tests/mmal-abi-check.py: every message structure of the patched build, for arm64 and for 32-bit ARM,
#    against the unpatched source's 32-bit layout (external/userland at the recipe's commit);
# 3. tools/haiku-tests/mmal-h264.c -> artifacts/mmal/mmal-h264, with the libraries in artifacts/mmal/lib for a test
#    session (tools/pi-tests/mmal.sh copies and runs them: LIBRARY_PATH);
# --package: scripts/package-port.py -> artifacts/packages/raspberrypi_userland{,_devel}-20241223-1-arm64.hpkg;
# --clips: the test streams artifacts/mmal/clips/<name>.h264 (the host's ffmpeg + libx264: synthetic pictures with
#    noise, High profile, B-frames, Annex-B; one of them without samples outside the video range), ffmpeg's software
#    decode of each as <name>.framemd5 (yuv420p), the reference of the bit-exactness check, and <name>.below16.md5:
#    the same frames with the samples below 16 lowered by one (what the VideoCore makes of them). Not in git.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
recipe="$root/tools/recipes/media-libs/raspberrypi_userland/raspberrypi_userland-20241223.recipe"
work="$root/artifacts/cross-ports/raspberrypi_userland-20241223"
out="$root/artifacts/mmal"
sysroot="$root/artifacts/sysroot-arm64"
package=false
clips=false
while [ $# -gt 0 ]; do
	case "$1" in
	--package) package=true; shift ;;
	--clips) clips=true; shift ;;
	*) echo "build-mmal: unknown option $1" >&2; exit 2 ;;
	esac
done

"$root/scripts/cross-port.sh" "$recipe" script '
make -f makefiles/haiku/Makefile -j"$(nproc)" CC="$CC"
make -f makefiles/haiku/Makefile install CC="$CC" DESTDIR="${DEST%/boot/system/non-packaged}" \
	prefix=/boot/system/non-packaged'
# no warnings but upstream's two declarations of libvchiq's (VCHIQ_STATUS_T vs int32_t)
if grep -E "^interface/[^:]*:[0-9]+:[0-9]+: warning" "$work/build.log" \
		| grep -v "conflicting types for 'vchiq_\(use\|release\)_service' due to enum/integer mismatch"; then
	echo "build-mmal: warnings (above)" >&2
	exit 1
fi

u="$root/external/userland"
rev="$(sed -n 's/^srcGitRev="\(.*\)"$/\1/p' "$recipe")"
[ "$(git -C "$u" rev-parse HEAD)" = "$rev" ] \
	|| { echo "build-mmal: external/userland is not at $rev (the unpatched reference)" >&2; exit 1; }
python3 "$root/tools/haiku-tests/mmal-abi-check.py" "$u" "$work/source" "$sysroot"

mkdir -p "$out/lib"
lib="$work/install/boot/system/non-packaged/lib"
cp "$lib"/lib{vcos,vchiq_arm,mmal,mmal_core,mmal_util,mmal_vc_client}.so "$out/lib/"
inc="$work/install/boot/system/non-packaged/develop/headers/raspberrypi_userland"
"$root/sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc" "--sysroot=$sysroot" \
	-O2 -Wall -Werror -std=gnu11 -I "$inc" -I "$inc/interface/vcos/pthreads" -I "$inc/interface/mmal" \
	-o "$out/mmal-h264" "$root/tools/haiku-tests/mmal-h264.c" -L "$lib" \
	-lmmal -lmmal_core -lmmal_util -lmmal_vc_client -lvchiq_arm -lvcos
echo "build-mmal: $out/mmal-h264, $out/lib/ (userland $(echo "$rev" | cut -c1-12) + patchset)"

if $package; then
	"$root/scripts/package-port.py" "$recipe" --revision 1
fi

if $clips; then
	mkdir -p "$out/clips"
	clip() {	# NAME SIZE FRAMES BITRATE [FILTER (default: noise)]
		local f="$out/clips/$1"
		ffmpeg -loglevel error -y -f lavfi -i "testsrc2=size=$2:rate=30,${5:-noise=alls=12:allf=t+u}" \
			-frames:v "$3" -c:v libx264 -preset medium -profile:v high -pix_fmt yuv420p -bf 3 -b:v "$4" \
			-maxrate "$4" -bufsize "$4" -f h264 "$f.h264"
		ffmpeg -loglevel error -y -i "$f.h264" -f framemd5 -pix_fmt yuv420p "$f.framemd5"
		# the same frames with every sample below 16 lowered by one: what the VideoCore outputs for those
		# (docs/design/vchiq.md §7.4)
		ffmpeg -loglevel error -i "$f.h264" -f rawvideo -pix_fmt yuv420p - | python3 -c '
import hashlib, sys
width, height = map(int, sys.argv[1].split("x"))
size = width * height * 3 // 2
table = bytes(v - 1 if 0 < v < 16 else v for v in range(256))
while True:
    frame = sys.stdin.buffer.read(size)
    if len(frame) < size:
        break
    print(hashlib.md5(frame.translate(table)).hexdigest())' "$2" > "$f.below16.md5"
		echo "build-mmal: $f.h264 ($(stat -c %s "$f.h264") bytes, $(grep -vc '^#' "$f.framemd5") frames)"
	}
	clip h264-720p 1280x720 300 6M
	clip h264-1080p 1920x1080 300 12M
	# no noise, no sample of the source below 32: the decoded frames have no sample below 16
	clip h264-1080p-inrange 1920x1080 300 12M "lutyuv=y=clip(val\\,32\\,224):u=clip(val\\,32\\,224):v=clip(val\\,32\\,224)"
fi
