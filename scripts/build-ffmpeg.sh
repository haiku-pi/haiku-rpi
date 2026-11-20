#!/usr/bin/env bash
# build-ffmpeg.sh — cross-build the ffmpeg6 port (the media kit's ffmpeg plugin, MediaPlayer) and package it
# (scripts/cross-port.sh + scripts/package-port.py): FFmpeg's own decoders + libvorbis (the recipe's other
# external libraries - lame, opus, speex, theora, openssl, ... - are not ported yet), with patches/ffmpeg6:
# "hevc_rpivid", HEVC on the Raspberry Pi 4's decoder block (docs/design/hw-video-decode.md), and FFmpeg's
# "h264_mmal", H.264 on the VideoCore through MMAL (docs/design/vchiq.md, step 3: libavcodec then needs
# raspberrypi_userland, scripts/build-mmal.sh --package, whose headers it is built with).
# Revision 2 = with patches/ffmpeg6; 3 = the pipelined hwaccel (rpivid driver interface 2); 4 = h264_mmal;
# 5 = h264_vc (H.264 on the VideoCore for Firefox, with fallback) and the h264_mmal encoder
# (docs/design/videocore-services.md); 6 = h264_mmal's first-frame quantiser (option initial_qp, default 25:
# the VideoCore's own made a flat 720p key frame of 981 bytes, banded) and its timestamps in microseconds, as
# MMAL counts them (API correctness; no measured effect on the output); 6b: initial_qp off by default (0: it
# disabled the firmware's rate control, W47 11-19 14:45); 7 = 6b + h264_vc decodes one stream per process
# on the VideoCore (FFMPEG_H264_VC_STREAMS), the others in software: a second one failed there with ENOSPC, and the
# failed decoder's teardown aborted Firefox's decoder process (docs/design/firefox-video-overlay.md §9.6).
# Called by scripts/build-packages.sh; runs on its own too.
#
#   scripts/build-ffmpeg.sh [--publish | --out DIR]
#   (--out DIR: the packages to DIR, a test revision not to be published yet, e.g. artifacts/packages-test/ffmpeg6-6)
#
# The packages go to artifacts/mmal/packages/, not the published artifacts/packages/: revision 4 needs
# raspberrypi_userland, which stays unpublished while the vchiq driver is on an unmerged branch (Haiku's
# h264-mmal). --publish: to artifacts/packages/ (once that is merged and raspberrypi_userland published).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
recipe="$root/sources/haikuports/media-video/ffmpeg/ffmpeg6-6.1.6.recipe"
revision=7
unpublished=true out=""
[ "${1:-}" = --publish ] && unpublished=false
[ "${1:-}" = --out ] && { out="$(realpath -m "$2")"; unpublished=false; }
mmal="/boot/system/develop/headers/raspberrypi_userland"
# (a recreated sysroot has none: build-mmal.sh --package puts them there)
[ -f "$root/artifacts/sysroot-arm64$mmal/interface/mmal/mmal.h" ] || "$root/scripts/build-mmal.sh" --package
"$root/scripts/cross-port.sh" --patches "$root/patches/ffmpeg6" "$recipe" script '
./configure --enable-cross-compile --target-os=haiku --arch=aarch64 \
	--cc="$CC" --cxx="$CXX" --ar="$AR" --ranlib="$RANLIB" --strip="$STRIP" --pkg-config=pkg-config \
	--prefix=/boot/system/non-packaged --disable-debug --disable-stripping --disable-static \
	--enable-shared --enable-version3 --enable-pic --enable-libvorbis --enable-mmal --disable-ffplay \
	--disable-doc --extra-cflags="-I$SYSROOT/boot/system/non-packaged/include -isystem $SYSROOT'"$mmal"' \
		-isystem $SYSROOT'"$mmal"'/interface/vcos/pthreads -isystem $SYSROOT'"$mmal"'/interface/mmal" \
	--extra-ldflags="-L$SYSROOT/boot/system/non-packaged/lib"
grep -q "^#define CONFIG_HEVC_RPIVID_DECODER 1$" config_components.h
grep -q "^#define CONFIG_H264_MMAL_DECODER 1$" config_components.h
grep -q "^#define CONFIG_H264_VC_DECODER 1$" config_components.h
grep -q "^#define CONFIG_H264_MMAL_ENCODER 1$" config_components.h
make -j"$(nproc)"
make install DESTDIR="${DEST%/boot/system/non-packaged}"'
work="$root/artifacts/cross-ports/ffmpeg6-6.1.6"
if grep -E "(rpivid[a-z_]*|mmaldec|mmalenc|h264_vcdec)\.c:[0-9]+:[0-9]+: warning" "$work/build.log"; then
	echo "build-ffmpeg: warnings in the rpivid or MMAL sources (above)" >&2
fi
"$root/scripts/package-port.py" "$recipe" --revision $revision ${out:+--out "$out"}
if $unpublished; then
	mkdir -p "$root/artifacts/mmal/packages"
	mv "$root"/artifacts/packages/ffmpeg6{,_devel}-6.1.6-$revision-arm64.hpkg "$root/artifacts/mmal/packages/"
	echo "build-ffmpeg: packages in artifacts/mmal/packages/"
fi
