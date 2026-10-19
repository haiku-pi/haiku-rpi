#!/usr/bin/env bash
# boot-bench.sh N [IMG] [--label L] — boot reliability: N trials of (flash IMG, boot from SD,
# capture 200 s, enter the kernel debugger at 158 s and dump each CPU's stack, ICIs, threads, timers).
# A trial passes when the desktop came up: app_server set its mode, and the debugger's thread list has
# Deskbar's and Tracker's desktop window threads ("w>Deskbar", "w>Desktop"). Summary at the end; each
# trial's UART log and HDMI frames are kept (artifacts/uart, artifacts/hdmi; label <L>-tN).
# Nothing wakes a frozen boot before the debugger (a key typed earlier would hide the freeze: the
# input's interrupt revives it), so the stacks show the freeze itself. --kdl-first is the default now.
#
#   scripts/boot-bench.sh --grade LOG...   grade existing trial logs with the same test
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
n="${1:?usage: $0 N [IMG] [--label L]}"; shift
# app_server is up when it set its mode (the generic framebuffer driver's fallback message, or the
# Raspberry Pi display driver's hardware cursor coming on); the desktop when Deskbar and Tracker made
# their windows. (Until 2026-10-19 this looked for "desklink", which the minimum image logged only
# because desklink failed to load there.)
desktop_up() {
	grep -aq -E 'app_server: Use|bcm2711_display: hardware cursor shown' "$1" \
		&& grep -aq 'w>Deskbar' "$1" && grep -aq 'w>Desktop' "$1"
}
if [ "$n" = --grade ]; then
	for log in "$@"; do
		if desktop_up "$log"; then echo "boot-bench: PASS $log"; else echo "boot-bench: FAIL $log"; fi
	done
	exit 0
fi

img="$root/artifacts/images/haiku-pi4.img"; label=bench
while [ $# -gt 0 ]; do
	case "$1" in
	--label) label="$2"; shift 2 ;;
	--kdl-first) shift ;;
	*) img="$1"; shift ;;
	esac
done
pass=0
for t in $(seq 1 "$n"); do
	"$root/scripts/sd-cycle.sh" --flash "$img" --label "$label-t$t" --secs 200 \
		--send '158:\x1d\x1d\x1dd' --send '161:cpu 0\n' --send '162:bt\n' --send '165:cpu 1\n' \
		--send '166:bt\n' --send '169:cpu 2\n' --send '170:bt\n' --send '173:cpu 3\n' --send '174:bt\n' \
		--send '178:ici\n' --send '181:threads\n' --send '192:\x74imers\n' > /dev/null 2>&1 || true
	log="$(ls -t "$root"/artifacts/uart/*-"$label-t$t".log | head -n 1)"
	if desktop_up "$log"; then
		verdict=PASS; pass=$((pass + 1))
	else
		verdict=FAIL
	fi
	echo "boot-bench: trial $t/$n $verdict  $(grep -a -c . "$log") lines  $log"
done
echo "boot-bench: $pass/$n reached the desktop ($(basename "$img"))"
