#!/usr/bin/env bash
# build-ffmpeg.sh — cross-build the ffmpeg6 port (the media kit's ffmpeg plugin, MediaPlayer) and package it
# (scripts/cross-port.sh + scripts/package-port.py): FFmpeg's own decoders + libvorbis (the recipe's other
# external libraries - lame, opus, speex, theora, openssl, ... - are not ported yet), with patches/ffmpeg6:
# "hevc_rpivid", HEVC on the Raspberry Pi 4's decoder block (docs/design/hw-video-decode.md).
# Revision 2 = with patches/ffmpeg6; 3 = the pipelined hwaccel (rpivid driver interface 2). Called by
# scripts/build-packages.sh; runs on its own too.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
recipe="$root/sources/haikuports/media-video/ffmpeg/ffmpeg6-6.1.6.recipe"
"$root/scripts/cross-port.sh" --patches "$root/patches/ffmpeg6" "$recipe" script '
./configure --enable-cross-compile --target-os=haiku --arch=aarch64 \
	--cc="$CC" --cxx="$CXX" --ar="$AR" --ranlib="$RANLIB" --strip="$STRIP" --pkg-config=pkg-config \
	--prefix=/boot/system/non-packaged --disable-debug --disable-stripping --disable-static \
	--enable-shared --enable-version3 --enable-pic --enable-libvorbis --disable-ffplay \
	--disable-doc --extra-cflags="-I$SYSROOT/boot/system/non-packaged/include" \
	--extra-ldflags="-L$SYSROOT/boot/system/non-packaged/lib"
grep -q "^#define CONFIG_HEVC_RPIVID_DECODER 1$" config_components.h
make -j"$(nproc)"
make install DESTDIR="${DEST%/boot/system/non-packaged}"'
work="$root/artifacts/cross-ports/ffmpeg6-6.1.6"
if grep -E "rpivid[a-z_]*\.c:[0-9]+:[0-9]+: warning" "$work/build.log"; then
	echo "build-ffmpeg: warnings in the rpivid sources (above)" >&2
fi
"$root/scripts/package-port.py" "$recipe" --revision 3
