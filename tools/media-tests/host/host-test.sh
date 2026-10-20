#!/usr/bin/env bash
# host-test.sh — the rpivid hwaccel (patches/ffmpeg6) on this host, without a Pi: FFmpeg 6.1.6 with
# the patch, built natively twice - as it is (no device on Linux: hevc_rpivid must decode like hevc)
# and with the driver API replaced by rpivid_device_mock.c, under AddressSanitizer. The mock "decodes"
# by writing the CPU decoder's frames SAND-tiled, and enforces the driver's protocol (see there), so
# the hwaccel's whole output path - DPB, pipelining, SAND to planar, cropping, frame order, fallback -
# is checked frame by frame against the CPU decoder. docs/design/hw-video-decode.md §6.
#
#   tools/media-tests/host/host-test.sh [--rebuild] [CLIP...]
#
# Default clips: the test tree's (tools/media-tests/gen-hevc-clips.sh: artifacts/media-tests/hevc/
# non-packaged/data/hevc-tests) and x265 variants made here (multiple slices, no WPP, CTB 16/32,
# scaling lists, ...), plus fault injections and hevcdec (tools/media-tests/hevcdec.cpp) built
# against the mock. Lines: "HOST <clip> loop=BIT-EXACT|LOOP-DIFF ..." and a final "HOST result".
# ORACLE_FFMPEG=<ffmpeg with an independent implementation of the programming, logging the same
# canonical form>: also compares the command streams (oracle=SAME|DIFF).
#
# Work directory: $RPIVID_HOST_WORK (default /tmp/rpivid-host); the builds go through
# scripts/heavy-build.sh.
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
here="$root/tools/media-tests/host"
work="${RPIVID_HOST_WORK:-/tmp/rpivid-host}"
tarball="$root/sources/haikuports/media-video/ffmpeg/download/ffmpeg-6.1.6.tar.xz"
rebuild=0
[ "${1:-}" = --rebuild ] && { rebuild=1; shift; }
mkdir -p "$work/clips" "$work/out"

config=(--disable-everything "--enable-decoder=hevc,hevc_rpivid" --enable-parser=hevc
	"--enable-demuxer=hevc,mov" "--enable-muxer=framemd5,rawvideo,null" "--enable-protocol=file,pipe"
	"--enable-encoder=rawvideo,wrapped_avframe" "--enable-filter=null,format,scale,crop"
	--disable-doc --disable-x86asm --disable-autodetect --enable-pthreads)

# The source trees: the release, the patch, our files; the mock replaces rpivid_device.c
prepare() {
	local tree="$1"
	rm -rf "$tree"
	mkdir -p "$tree"
	tar -xf "$tarball" -C "$tree" --strip-components=1
	(cd "$tree" && patch -s -p1 < "$root/patches/ffmpeg6/0001-hevc-rpivid.patch")
	cp "$root"/patches/ffmpeg6/files/libavcodec/* "$tree/libavcodec/"
}
build() {
	local name="$1"; shift
	prepare "$work/src-$name"
	[ "$name" = mock ] && cp "$here/rpivid_device_mock.c" "$work/src-$name/libavcodec/rpivid_device.c"
	rm -rf "$work/build-$name"
	mkdir -p "$work/build-$name"
	(cd "$work/build-$name" && "$work/src-$name/configure" "${config[@]}" "$@" > configure.out 2>&1 &&
		"$root/scripts/heavy-build.sh" --mem-per-job 1 -- make "-j{JOBS}" > build.log 2>&1) ||
		{ echo "HOST build $name failed: $work/build-$name" >&2; exit 1; }
	if grep -E "rpivid[a-z_]*\.c:[0-9]+:[0-9]+: warning" "$work/build-$name/build.log"; then
		echo "HOST warnings in the rpivid sources ($name, above)"
	fi
}
stale() {	# a build older than one of its inputs
	local stamp="$work/build-$1/ffmpeg"
	[ "$rebuild" = 1 ] || [ ! -f "$stamp" ] && return 0
	[ -n "$(find "$root/patches/ffmpeg6" "$here/rpivid_device_mock.c" -newer "$stamp" -type f)" ]
}
if stale plain; then build plain; fi
if stale mock; then
	build mock --extra-cflags="-g -fsanitize=address -fno-omit-frame-pointer" --extra-ldflags="-fsanitize=address"
fi
plain="$work/build-plain/ffmpeg"
mock="$work/build-mock/ffmpeg"

# hevcdec against the mock build (static libraries)
m="$work/build-mock"
g++ -O1 -g -fsanitize=address -Wall -Wextra -I"$m" -I"$work/src-mock" "$root/tools/media-tests/hevcdec.cpp" \
	"$m/libavformat/libavformat.a" "$m/libavcodec/libavcodec.a" "$m/libswscale/libswscale.a" \
	"$m/libavutil/libavutil.a" -lpthread -lm -o "$work/hevcdec-mock"

# The clips: the test tree's, and x265 variants of the coding tools
x265() {	# name size frames pix_fmt x265-params
	local f="$work/clips/$1.265"
	[ -s "$f" ] || ffmpeg -nostdin -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=$2:rate=25" \
		-frames:v "$3" -c:v libx265 -pix_fmt "$4" -x265-params "log-level=error:$5" "$f"
}
x265 amp 416x240 12 yuv420p "amp=1:rect=1"
x265 cabacinit 416x240 12 yuv420p "rd=6:rdoq-level=2"
x265 constrained 416x240 12 yuv420p "constrained-intra=1"
x265 cra10 320x240 40 yuv420p "keyint=10:min-keyint=10"
x265 ctu16 416x240 12 yuv420p "ctu=16:max-tu-size=16:qg-size=16"
x265 ctu32 416x240 12 yuv420p "ctu=32"
x265 deblock 416x240 12 yuv420p "deblock=-2,1"
x265 gop10 320x240 40 yuv420p "keyint=10:min-keyint=10:open-gop=0"
x265 lossless 416x240 12 yuv420p "lossless=1"
x265 m10wpp 416x240 12 yuv420p10le "slices=2"
x265 merge 416x240 12 yuv420p "max-merge=2"
x265 nodeblock 416x240 12 yuv420p "no-deblock=1"
x265 nosao 416x240 12 yuv420p "no-sao=1"
x265 nowpp 416x240 12 yuv420p "no-wpp=1:frame-threads=2"
x265 qpoffs 416x240 12 yuv420p "cbqpoffs=3:crqpoffs=-2"
x265 ref4 416x240 12 yuv420p "ref=4"
x265 scaling 416x240 12 yuv420p "scaling-list=default"
x265 signhide0 416x240 12 yuv420p "no-signhide=1"
x265 slices4 416x240 12 yuv420p "slices=4"
x265 strongintra0 416x240 12 yuv420p "no-strong-intra-smoothing=1"
x265 tmvp0 416x240 12 yuv420p "no-temporal-mvp=1"
x265 tskip 416x240 12 yuv420p "tskip=1"
x265 tudepth 416x240 12 yuv420p "tu-inter-depth=3:tu-intra-depth=3"
x265 weightb 416x240 12 yuv420p "weightb=1"
x265 yuv720 1280x720 8 yuv420p "lookahead-slices=4"

tree="$root/artifacts/media-tests/hevc/non-packaged/data/hevc-tests"
if [ $# -eq 0 ]; then
	set -- "$work"/clips/*.265
	[ -d "$tree" ] && set -- "$@" "$tree"/*.265 "$tree"/*.mp4
fi

export ASAN_OPTIONS=detect_leaks=0
failures=0
golden() {	# the CPU decoder's frames, raw, in display order
	local pf
	pf=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of csv=p=0 "$1")
	"$plain" -nostdin -v error -y -c:v hevc -i "$1" -an -f rawvideo -pix_fmt "$pf" "$2"
}
md5s() { grep -v "^#" | cut -d, -f6 | tr -d ' '; }
for clip in "$@"; do
	b=$(basename "$clip"); b=${b%.*}
	o="$work/out/$b"
	golden "$clip" "$o.golden"
	# a closed GOP restarts the POCs: the golden frame is GOP * length + POC
	gop=0
	case "$b" in gop10) gop=10 ;; esac
	"$plain" -nostdin -v error -c:v hevc -i "$clip" -an -f framemd5 - | md5s > "$o.sw"
	# no device: hevc_rpivid is the CPU decoder (one thread: FFmpeg's slice-threaded WPP decoding
	# is not deterministic with 16x16 CTBs, about 1 run in 30, hevc as hevc_rpivid)
	"$plain" -nostdin -v error -threads 1 -c:v hevc_rpivid -i "$clip" -an -f framemd5 - | md5s > "$o.nodev"
	FFMPEG_RPIVID=2 MOCK_GOP=$gop MOCK_GOLDEN="$o.golden" MOCK_LOG="$o.log" "$mock" -nostdin -hide_banner \
		-loglevel info -c:v hevc_rpivid -i "$clip" -an -f framemd5 - 2> "$o.err" | md5s > "$o.hw" || true
	FFMPEG_RPIVID=2 FFMPEG_RPIVID_SYNC=1 MOCK_GOP=$gop MOCK_GOLDEN="$o.golden" MOCK_LOG="$o.sync.log" \
		"$mock" -nostdin -hide_banner -loglevel info -c:v hevc_rpivid -i "$clip" -an -f framemd5 - \
		2> "$o.sync.err" | md5s > "$o.sync" || true
	loop=$(cmp -s "$o.hw" "$o.sw" && [ -s "$o.sw" ] && echo BIT-EXACT || echo LOOP-DIFF)
	sync=$(cmp -s "$o.sync" "$o.sw" && echo BIT-EXACT || echo LOOP-DIFF)
	nodev=$(cmp -s "$o.nodev" "$o.sw" && echo SAME || echo DIFF)
	logs=$(cmp -s <(grep -v "^PIC" "$o.log") <(grep -v "^PIC" "$o.sync.log") && echo SAME || echo DIFF)
	flags=$(grep -l -E "AddressSanitizer|MOCK PROTOCOL" "$o.err" "$o.sync.err" > /dev/null && echo "ASAN/PROTOCOL" || true)
	oracle=""
	if [ -n "${ORACLE_FFMPEG:-}" ]; then
		rm -f "${MOCK_DEAD_PATH:-/nonexistent}"
		FFMPEG_RPIVID_TOOLS=all FFMPEG_RPIVID=2 MOCK_LOG="$o.ref.log" "$ORACLE_FFMPEG" -nostdin -hide_banner \
			-loglevel info -c:v hevc_rpivid -i "$clip" -f null - > "$o.ref.err" 2>&1 || true
		oracle=" oracle=$(cmp -s <(grep -v "^PIC" "$o.ref.log") <(grep -v "^PIC" "$o.log") && echo SAME || echo DIFF)"
	fi
	# (ffmpeg's stream probe decodes the first picture too)
	pictures=$(grep -c "^PIC" "$o.log" || true)
	cpu=$(grep -o "rpivid: CPU decode: .*" "$o.err" | head -n 1 || true)
	printf "HOST %-14s loop=%-9s sync=%-9s nodevice=%s logs=%s%s frames=%s pictures=%s %s %s\n" "$b" \
		"$loop" "$sync" "$nodev" "$logs" "$oracle" "$(wc -l < "$o.sw")" "$pictures" "$flags" "$cpu"
	if [ "$loop" != BIT-EXACT ] || [ "$sync" != BIT-EXACT ] || [ "$nodev" != SAME ] ||
		[ "$logs" != SAME ] || [ -n "$flags" ] || { [ -n "$oracle" ] && [ "$oracle" != " oracle=SAME" ]; }; then
		failures=$((failures + 1))
	fi
done

# Faults: every frame that comes out equals the CPU decoder's (a subsequence of its frames)
fault() {	# name clip env...
	local name="$1" clip="$2"; shift 2
	local o="$work/out/fault-$name" b; b=$(basename "$clip"); b=${b%.*}
	env "$@" FFMPEG_RPIVID=2 MOCK_GOLDEN="$work/out/$b.golden" MOCK_LOG="$o.log" "$mock" -nostdin \
		-hide_banner -loglevel info -c:v hevc_rpivid -i "$clip" -an -f framemd5 - 2> "$o.err" | md5s > "$o.hw" || true
	local verdict
	verdict=$(python3 -I - "$work/out/$b.sw" "$o.hw" <<-'EOF'
		import sys
		sw = open(sys.argv[1]).read().split(); hw = open(sys.argv[2]).read().split()
		i = 0
		for h in hw:
		    while i < len(sw) and sw[i] != h: i += 1
		    if i == len(sw): print("NOT-A-SUBSEQUENCE"); sys.exit()
		    i += 1
		print("SUBSEQUENCE %d/%d" % (len(hw), len(sw)))
	EOF
	)
	local back; back=$(grep -c "back on the block" "$o.err" || true)
	local flags; flags=$(grep -l -E "AddressSanitizer|MOCK PROTOCOL" "$o.err" > /dev/null && echo "ASAN/PROTOCOL" || true)
	printf "HOST fault %-22s %s, back on the block %s times %s\n" "$name" "$verdict" "$back" "$flags"
	case "$verdict" in SUBSEQUENCE*) [ -z "$flags" ] || failures=$((failures + 1)) ;; *) failures=$((failures + 1)) ;; esac
}
gop="$work/clips/gop10.265"
fault submit-refused "$gop" MOCK_FAIL_AT=13 MOCK_GOP=10
fault fails-in-block "$gop" MOCK_FAIL_LATE_AT=13 MOCK_GOP=10
fault fails-last "$gop" MOCK_FAIL_LATE_AT=39 MOCK_GOP=10
fault no-memory "$gop" MOCK_NOMEM_AT=5 MOCK_GOP=10

# hevcdec on the mock: the comparison, the block's picture count, the bench lines
hd="$work/clips/yuv720.265"
MOCK_GOLDEN="$work/out/yuv720.golden" MOCK_LOG=/dev/null "$work/hevcdec-mock" "$hd" > "$work/out/hevcdec.txt" 2>&1 || true
grep -E "^HEV (result|bench|speed)" "$work/out/hevcdec.txt" || true
grep -q "^HEV result PASS" "$work/out/hevcdec.txt" && ! grep -q -E "AddressSanitizer|MOCK PROTOCOL" "$work/out/hevcdec.txt" ||
	{ echo "HOST hevcdec FAIL: $work/out/hevcdec.txt"; failures=$((failures + 1)); }

echo "HOST result $([ "$failures" = 0 ] && echo PASS || echo "FAIL ($failures)")"
[ "$failures" = 0 ]
