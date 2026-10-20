#!/usr/bin/env bash
# pi-test.sh — an interactive session with Haiku on the Pi 4, for a person at a desktop (agents: use
# scripts/sd-cycle.sh instead — this one runs until you close the preview window).
#
#   scripts/pi-test.sh [--flash IMG | --regular | --netboot IMG] [--no-preview] [--no-power-off]
#
#   --flash IMG     first write IMG to the Pi's SD card (the flash lane, SHA-256 verified)
#   --regular       first write the regular image, artifacts/images/haiku-pi4-regular.img
#   --netboot IMG   boot IMG from the network instead, no SD card writing (scripts/netboot-server.sh;
#                   what Haiku writes goes to a copy of IMG, made afresh each time)
#   --no-preview    no HDMI window: the UART only, until Ctrl-C (a host without a display)
#   --no-power-off  leave the Pi running at the end
#
# Then: boots the Pi from its SD card (no DHCP server on the Pi LAN meanwhile, or the firmware would
# netboot) or with --netboot from the network, shows the serial console live in this terminal (and logs it to artifacts/uart/), and opens
# a live HDMI window from the capture card (ffplay, or mpv). Type on the Pi's USB keyboard, use its
# mouse; the window shows the screen. Close the window (or Ctrl-C) to end: the Pi is powered off and,
# on a shared bench, the other project's netboot server is restored. The session holds the bench lock
# throughout, so automated Pi cycles wait for it.
#
# Settings (UART, power switch, capture device, ...): local.conf (local.conf.example). The preview is
# YUYV 1920x1080 (USB 3 capture cards do 60 fps) with an MJPEG fallback; PREVIEW_FORMAT=mjpeg forces it.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/scripts/lib/bench.sh"

flash="" netboot="" preview=1 poweroff=1
while [ $# -gt 0 ]; do
	case "$1" in
	--flash) flash="$2"; shift 2 ;;
	--regular) flash="$root/artifacts/images/haiku-pi4-regular.img"; shift ;;
	--netboot) netboot="$(realpath "$2")"; shift 2 ;;
	--no-preview) preview=0; shift ;;
	--no-power-off) poweroff=0; shift ;;
	-h|--help) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "pi-test: unknown option $1 (--help)" >&2; exit 2 ;;
	esac
done

[ -n "$PI_PLUG" ] || { echo "pi-test: set PI_PLUG in local.conf (the Pi's power switch)" >&2; exit 1; }
if [ "$preview" = 1 ]; then
	[ -n "$HDMI_GRABBER" ] && [ -e "$HDMI_GRABBER" ] \
		|| { echo "pi-test: no HDMI_GRABBER (local.conf), or use --no-preview" >&2; exit 1; }
	player=""
	command -v ffplay >/dev/null && player=ffplay
	[ -z "$player" ] && command -v mpv >/dev/null && player=mpv
	[ -n "$player" ] || { echo "pi-test: needs ffplay (ffmpeg) or mpv for the preview" >&2; exit 1; }
fi

[ -n "$flash" ] && [ -n "$netboot" ] && { echo "pi-test: --flash/--regular or --netboot" >&2; exit 2; }
[ -z "$netboot" ] || [ -f "$netboot" ] || { echo "pi-test: no image $netboot" >&2; exit 1; }
if [ -n "$flash" ]; then
	[ -f "$flash" ] || { echo "pi-test: no image $flash" >&2; exit 1; }
	echo "pi-test: writing $(basename "$flash") to the SD card ..."
	"$root/scripts/sd-cycle.sh" --flash "$flash" --no-boot --label pi-test || exit 1
fi

bench_lock
ts="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$root/artifacts/uart"
log="$root/artifacts/uart/$ts-pi-test.log"
cap_pid="" view_pid=""
cleanup() {
	trap - EXIT INT TERM
	[ -n "$view_pid" ] && kill "$view_pid" 2>/dev/null
	[ -n "$cap_pid" ] && kill "$cap_pid" 2>/dev/null
	wait 2>/dev/null
	[ "$poweroff" = 1 ] && pi_power off
	[ -n "$netboot" ] && "$root/scripts/netboot-server.sh" down >/dev/null
	peer_netboot_restore
	echo "pi-test: serial log $log"
}
trap cleanup EXIT INT TERM

if [ -n "$netboot" ]; then
	"$root/scripts/netboot-server.sh" up "$netboot" || exit 1
else
	peer_netboot_down
fi
"$PYTHON" "$root/scripts/uart-capture.py" --dev "$PI_UART" --log "$log" --secs 864000 --echo &
cap_pid=$!
sleep 0.5
pi_power off >/dev/null 2>&1
sleep 2
pi_power on

if [ "$preview" = 1 ]; then
	format="${PREVIEW_FORMAT:-yuyv422}"
	echo "pi-test: HDMI preview from $HDMI_GRABBER ($format) — close the window to end"
	if [ "$player" = ffplay ]; then
		view() {
			ffplay -hide_banner -loglevel error -window_title "Haiku on the Raspberry Pi 4" \
				-f v4l2 -input_format "$1" -video_size 1920x1080 -i "$HDMI_GRABBER" \
				-vf 'scale=in_color_matrix=bt709:in_range=tv' -fflags nobuffer -framedrop
		}
	else
		view() {
			mpv --really-quiet --title="Haiku on the Raspberry Pi 4" --profile=low-latency \
				--demuxer-lavf-format=video4linux2 \
				--demuxer-lavf-o=input_format="$1",video_size=1920x1080 "av://v4l2:$HDMI_GRABBER"
		}
	fi
	started=$(date +%s)
	view "$format" &
	view_pid=$!
	wait "$view_pid"
	# a player that gave up at once: the card does not offer that format
	if [ $(( $(date +%s) - started )) -lt 3 ] && [ "$format" != mjpeg ]; then
		echo "pi-test: $format failed, trying MJPEG"
		view mjpeg &
		view_pid=$!
		wait "$view_pid"
	fi
	view_pid=""
else
	echo "pi-test: serial console only — Ctrl-C to end"
	wait "$cap_pid"
fi
