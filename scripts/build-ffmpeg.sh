#!/usr/bin/env bash
# build-ffmpeg.sh — cross-build the ffmpeg6 port (the media kit's ffmpeg plugin, MediaPlayer) and package it
# (scripts/cross-port.sh + scripts/package-port.py): FFmpeg's own decoders + libvorbis (the recipe's other
# external libraries - lame, opus, speex, theora, openssl, ... - are not ported yet), with patches/ffmpeg6:
# "hevc_rpivid", HEVC on the Raspberry Pi 4's decoder block (docs/design/hw-video-decode.md), and FFmpeg's
# "h264_mmal", H.264 on the VideoCore through MMAL (docs/design/vchiq.md, step 3: libavcodec then needs
# raspberrypi_userland, scripts/build-mmal.sh --package, whose headers it is built with).
# Revision 2 = with patches/ffmpeg6; 3 = the pipelined hwaccel (rpivid driver interface 2); 4 = h264_mmal.
# Called by scripts/build-packages.sh; runs on its own too.
#
#   scripts/build-ffmpeg.sh [--publish]
#
# The packages go to artifacts/mmal/packages/, not the published artifacts/packages/: revision 4 needs
# raspberrypi_userland, which stays unpublished while the vchiq driver is on an unmerged branch (Haiku's
# h264-mmal). --publish: to artifacts/packages/ (once that is merged and raspberrypi_userland published).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
recipe="$root/sources/haikuports/media-video/ffmpeg/ffmpeg6-6.1.6.recipe"
revision=4
unpublished=true
[ "${1:-}" = --publish ] && unpublished=false
mmal="/boot/system/develop/headers/raspberrypi_userland"
[ -f "$root/artifacts/sysroot-arm64$mmal/interface/mmal/mmal.h" ] \
	|| { echo "build-ffmpeg: no MMAL headers in the sysroot (scripts/build-mmal.sh --package)" >&2; exit 1; }
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
make -j"$(nproc)"
make install DESTDIR="${DEST%/boot/system/non-packaged}"'
work="$root/artifacts/cross-ports/ffmpeg6-6.1.6"
if grep -E "(rpivid[a-z_]*|mmaldec)\.c:[0-9]+:[0-9]+: warning" "$work/build.log"; then
	echo "build-ffmpeg: warnings in the rpivid or MMAL sources (above)" >&2
fi
"$root/scripts/package-port.py" "$recipe" --revision $revision
if $unpublished; then
	mkdir -p "$root/artifacts/mmal/packages"
	mv "$root"/artifacts/packages/ffmpeg6{,_devel}-6.1.6-$revision-arm64.hpkg "$root/artifacts/mmal/packages/"
	echo "build-ffmpeg: packages in artifacts/mmal/packages/"
fi
