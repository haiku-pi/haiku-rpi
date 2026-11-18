#!/usr/bin/env bash
# build.sh WORKDIR — the h264_vc host harness (docs/design/videocore-services.md §1.3): FFmpeg 6.1.6 for the
# host (static, the h264 decoder, mov/h264 demuxers, from the recipe's source as scripts/cross-port.sh unpacked it
# into artifacts/cross-ports/ffmpeg6-6.1.6/source), then t/vctest = vctest.c + fake_mmal.c (a stand-in h264_mmal)
# + patches/ffmpeg6/files/libavcodec/h264_vcdec.c. Then: H264VC_WORK=WORKDIR run.sh CLIP.mp4
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
work=${1:?usage: build.sh WORKDIR}
mkdir -p "$work/t"
if [ ! -f "$work/ffmpeg/libavcodec/libavcodec.a" ]; then
	rm -rf "$work/ffmpeg"
	cp -a "$root/artifacts/cross-ports/ffmpeg6-6.1.6/source" "$work/ffmpeg"
	(cd "$work/ffmpeg" && ./configure --disable-everything --disable-programs --disable-doc --enable-static \
		--disable-shared --enable-decoder=h264 --enable-demuxer=mov,h264 --enable-parser=h264 \
		--enable-protocol=file --enable-bsf=h264_mp4toannexb,null --disable-x86asm > ../configure.log 2>&1 \
		&& make -j"$(nproc)" > ../make.log 2>&1)
fi
F="$work/ffmpeg"
gcc -O1 -g -Wall -I"$F" -I"$F/libavcodec" -o "$work/t/vctest" "$here/vctest.c" "$here/fake_mmal.c" \
	"$root/patches/ffmpeg6/files/libavcodec/h264_vcdec.c" "$F/libavformat/libavformat.a" \
	"$F/libavcodec/libavcodec.a" "$F/libavutil/libavutil.a" -lm -lpthread -lz
echo "build.sh: $work/t/vctest"
