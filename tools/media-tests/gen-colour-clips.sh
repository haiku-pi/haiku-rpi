#!/usr/bin/env bash
# gen-colour-clips.sh — colour bar clips with a known YCbCr encoding, for the overlay's colour check
# (docs/design/video-overlay.md §7): 75 % bars (pal75bars: white yellow cyan green magenta red blue black,
# 191 = 75 %), converted from RGB with the matrix and range named, tagged with them (container and stream)
# unless "untagged"; 10 s, 30 fps, keyint 30.
#
#   tools/media-tests/gen-colour-clips.sh [OUT]     (default artifacts/v6-video/clips)
#
#   col-601-sd.mp4          H.264 720x480, BT.601 limited          (SD: the usual case)
#   col-709-hd.mp4          H.264 1920x1080, BT.709 limited        (HD: the usual case)
#   col-601-hd.mp4          H.264 1920x1080, BT.601 limited        (601-tagged HD)
#   col-601u-hd.mp4         H.264 1920x1080, BT.601 limited, untagged (as the older test clips)
#   col-601full-hd.mp4      H.264 1920x1080, BT.601 full range     (JPEG-style full range)
#   col-709full-hd.mp4      H.264 1920x1080, BT.709 full range     (no such plane encoding: converted)
#   col-601full-sd.mp4      H.264 720x480, BT.601 full range, yuvj420p (the software decoder's full range format)
#   col-709-hevc.mp4        HEVC 1920x1080, BT.709 limited (rpivid)
#   col-601-hevc.mp4        HEVC 1280x720, BT.601 limited (601-tagged HD on rpivid)
#   col-709-hevc10.mp4      HEVC Main 10 1920x1080, BT.709 limited (rpivid, 10 bit)
#   col-601full-hevc.mp4    HEVC 1920x1080, BT.601 full range (rpivid: on the SAND plane as encoding 3)
# For Firefox (V7: its overlay passes the encoding Firefox decided on; VP9 is decoded in software there):
#   col-2020-hd.mp4         H.264 1920x1080, BT.2020 limited      (plane encoding 9)
#   col-601-vp9.webm        VP9 1280x720, BT.601 limited           (601-tagged HD)
#   col-709full-vp9.webm    VP9 1280x720, BT.709 full range        (no such plane encoding: software)
#   col-u-vp9-436.webm      VP9 1024x436, BT.601 limited, untagged (as the Sintel MSE stream of
#                           firefox-video-overlay.md §9.7: Firefox's default applies)
#   col-2020-vp9.webm       VP9 1280x720, BT.2020 limited
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="${1:-$root/artifacts/v6-video/clips}"
mkdir -p "$out"
ff() { ffmpeg -hide_banner -loglevel error -y "$@"; }

# clip NAME SIZE MATRIX(bt601|bt709|bt2020) RANGE(tv|pc) TAG(tagged|untagged) CODEC(h264|hevc|hevc10|vp9) [PIXFMT]
clip() {
	local name=$1 size=$2 matrix=$3 range=$4 tag=$5 codec=$6 pixfmt=${7:-}
	local space primaries trc
	case $matrix in
	bt709) space=bt709 primaries=bt709 trc=bt709 ;;
	bt2020) space=bt2020nc primaries=bt2020 trc=bt2020-10 ;;
	*) space=smpte170m primaries=smpte170m trc=smpte170m ;;
	esac
	local tags=()
	[ "$tag" = tagged ] && tags=(-colorspace "$space" -color_range "$range" -color_primaries "$primaries" -color_trc "$trc")
	local enc
	case $codec in
	h264) enc=(-c:v libx264 -preset medium -profile:v high -g 30 -b:v 2M); pixfmt=${pixfmt:-yuv420p} ;;
	hevc) enc=(-c:v libx265 -preset fast -x265-params "keyint=30:log-level=error"); pixfmt=${pixfmt:-yuv420p} ;;
	hevc10) enc=(-c:v libx265 -preset fast -profile:v main10 -x265-params "keyint=30:log-level=error"); pixfmt=yuv420p10le ;;
	vp9) enc=(-c:v libvpx-vp9 -b:v 1M -g 30 -deadline good -cpu-used 4); pixfmt=${pixfmt:-yuv420p} ;;
	esac
	# untagged x264/x265 still write VUI from the frames' tags: the frames carry none (setparams unknown)
	ff -f lavfi -i "pal75bars=size=$size:rate=30" -t 10 \
		-vf "scale=out_color_matrix=$matrix:out_range=$range,format=$pixfmt,setparams=colorspace=$([ "$tag" = tagged ] && echo "$space" || echo unknown):range=$([ "$tag" = tagged ] && echo "$range" || echo unknown)" \
		"${enc[@]}" "${tags[@]}" "$out/$name"
	printf '%s: %s\n' "$name" "$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height,pix_fmt,color_space,color_range -of csv=p=0 "$out/$name")"
}

clip col-601-sd.mp4 720x480 bt601 tv tagged h264
clip col-709-hd.mp4 1920x1080 bt709 tv tagged h264
clip col-601-hd.mp4 1920x1080 bt601 tv tagged h264
clip col-601u-hd.mp4 1920x1080 bt601 tv untagged h264
clip col-601full-hd.mp4 1920x1080 bt601 pc tagged h264
clip col-709full-hd.mp4 1920x1080 bt709 pc tagged h264
clip col-601full-sd.mp4 720x480 bt601 pc tagged h264 yuvj420p
clip col-709-hevc.mp4 1920x1080 bt709 tv tagged hevc
clip col-601-hevc.mp4 1280x720 bt601 tv tagged hevc
clip col-709-hevc10.mp4 1920x1080 bt709 tv tagged hevc10
clip col-601full-hevc.mp4 1920x1080 bt601 pc tagged hevc
clip col-2020-hd.mp4 1920x1080 bt2020 tv tagged h264
clip col-601-vp9.webm 1280x720 bt601 tv tagged vp9
clip col-709full-vp9.webm 1280x720 bt709 pc tagged vp9
clip col-u-vp9-436.webm 1024x436 bt601 tv untagged vp9
clip col-2020-vp9.webm 1280x720 bt2020 tv tagged vp9
