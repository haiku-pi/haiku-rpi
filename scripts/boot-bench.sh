#!/usr/bin/env bash
# boot-bench.sh N [IMG] [--label L] — boot reliability: N trials of (flash IMG, boot from SD,
# capture 200 s, enter the kernel debugger at 170 s and dump teams + threads). A trial passes when
# the desktop came up (app_server picked a mode and desklink was started). Summary at the end; each
# trial's UART log and HDMI frames are kept (artifacts/uart, artifacts/hdmi; label <L>-tN).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
n="${1:?usage: $0 N [IMG] [--label L]}"; shift
img="$root/artifacts/images/haiku-pi4.img"; label=bench
while [ $# -gt 0 ]; do
	case "$1" in
	--label) label="$2"; shift 2 ;;
	*) img="$1"; shift ;;
	esac
done
pass=0
for t in $(seq 1 "$n"); do
	"$root/scripts/sd-cycle.sh" --flash "$img" --label "$label-t$t" --secs 200 \
		--send '170:\x1d\x1d\x1dd' --send '174:teams\n' --send '178:threads\n' > /dev/null 2>&1 || true
	log="$(ls -t "$root"/artifacts/uart/*-"$label-t$t".log | head -n 1)"
	if grep -aq 'app_server: Use' "$log" && grep -aq 'desklink' "$log"; then
		verdict=PASS; pass=$((pass + 1))
	else
		verdict=FAIL
	fi
	echo "boot-bench: trial $t/$n $verdict  $(grep -a -c . "$log") lines  $log"
done
echo "boot-bench: $pass/$n reached the desktop ($(basename "$img"))"
