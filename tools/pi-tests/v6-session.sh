#!/usr/bin/env bash
# v6-session.sh — a bench session (scripts/pi-session.sh) on an image with the v6 test binaries
# (docs/design/video-overlay.md §7, hw-video-decode.md §9) in place of the packaged ones, without an image build:
#
#   tools/pi-tests/v6-session.sh stage            collect them into artifacts/v6-video/stage/
#   tools/pi-tests/v6-session.sh start LABEL [MINUTES] [BASE.img]
#
# In the image (scripts/pi-session.sh --add): the display driver, its accelerant and the rpivid driver in
# system/non-packaged with the packaged ones blocked (BlockedEntries), app_server started from non-packaged (a
# user_launch override), libbe.so in system/non-packaged/lib (found before the system's), the ffmpeg media
# plugin in ~/config/non-packaged (found before the system's); MediaPlayer, the tests and the clips in
# /boot/home/v6. The kernel and everything else are BASE's (default artifacts/v6-video/v6-base.img: rpi4 at the
# branch point). V6_SAND=1 stage: also libbe.so and the rpivid driver (the SAND scan-out, §9 there).
# HAIKU_GEN: the build directory (default sources/haiku-v6/generated.arm64).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
st="$root/artifacts/v6-video/stage"
gen="${HAIKU_GEN:-$root/sources/haiku-v6/generated.arm64}"
obj="$gen/objects/haiku/arm64/release"
tools="$root/sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku"

case "${1:-}" in
stage)
	rm -rf "$st"
	mkdir -p "$st"
	cp "$obj/add-ons/kernel/drivers/graphics/bcm2711_display/bcm2711_display" "$st/"
	cp "$obj/add-ons/accelerants/bcm2711_display/bcm2711_display.accelerant" "$st/"
	cp "$obj/servers/app/app_server" "$st/"
	cp "$obj/add-ons/media/plugins/ffmpeg/ffmpeg" "$st/"
	cp "$obj/apps/mediaplayer/MediaPlayer" "$st/"
	if [ "${V6_SAND:-0}" = 1 ]; then
		cp "$obj/kits/libbe.so" "$st/"
		cp "$obj/add-ons/kernel/drivers/video/rpivid/rpivid" "$st/"
	fi
	for f in app_server ffmpeg MediaPlayer libbe.so; do
		[ -f "$st/$f" ] && "$tools-strip" --strip-unneeded "$st/$f"
	done
	blocked="\t\tadd-ons/kernel/drivers/dev/graphics/bcm2711_display\n\t\tadd-ons/kernel/drivers/bin/bcm2711_display\n\t\tadd-ons/accelerants/bcm2711_display.accelerant\n"
	[ -f "$st/rpivid" ] && blocked="$blocked\t\tadd-ons/kernel/drivers/video/rpivid\n"
	printf "Package haiku {\n\tBlockedEntries {\n$blocked\t}\n}\n" > "$st/packages"
	printf 'service x-vnd.Haiku-app_server {\n\tlaunch /boot/system/non-packaged/servers/app_server\n}\n' > "$st/app_server.launch"
	echo "# staged $(date '+%Y-%m-%d %H:%M') from $(git -C "$gen/.." describe --always --dirty --all --long)" > "$st/versions.txt"
	ls -l "$st"
	;;
start)
	label=${2:?start LABEL [MINUTES] [BASE.img]}
	minutes=${3:-30}
	base=${4:-$root/artifacts/v6-video/v6-base.img}
	np=/boot/system/non-packaged
	h=/boot/home/v6
	adds=(
		"$st/bcm2711_display:$np/add-ons/kernel/drivers/dev/graphics/bcm2711_display"
		"$st/bcm2711_display.accelerant:$np/add-ons/accelerants/bcm2711_display.accelerant"
		"$st/app_server:$np/servers/app_server"
		"$st/app_server.launch:/boot/system/settings/user_launch/app_server"
		"$st/packages:/boot/system/settings/packages"
		"$st/ffmpeg:/boot/home/config/non-packaged/add-ons/media/plugins/ffmpeg"
		"$st/MediaPlayer:$h/new/MediaPlayer"
		"$st/versions.txt:$h/versions.txt"
	)
	[ -f "$st/libbe.so" ] && adds+=("$st/libbe.so:$np/lib/libbe.so")
	[ -f "$st/rpivid" ] && adds+=("$st/rpivid:$np/add-ons/kernel/drivers/video/rpivid")
	for f in "$root"/artifacts/v6-video/bin/*; do adds+=("$f:$h/$(basename "$f")"); done
	args=()
	for a in "${adds[@]}"; do args+=(--add "$a"); done
	exec "$root/scripts/pi-session.sh" start --image "$base" --minutes "$minutes" --label "$label" "${args[@]}"
	;;
*) sed -n 2,14p "$0" >&2; exit 2 ;;
esac
