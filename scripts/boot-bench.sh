#!/usr/bin/env bash
# boot-bench.sh N [IMG] [--label L] — boot reliability: N trials of (flash IMG, boot from SD,
# capture 200 s, enter the kernel debugger at 158 s and dump each CPU's stack, ICIs, threads, timers). A trial passes when
# the desktop came up (app_server picked a mode and desklink was started). Summary at the end; each
# trial's UART log and HDMI frames are kept (artifacts/uart, artifacts/hdmi; label <L>-tN).
# Nothing wakes a frozen boot before the debugger (a key typed earlier would hide the freeze: the
# input's interrupt revives it), so the stacks show the freeze itself. --kdl-first is the default now.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
n="${1:?usage: $0 N [IMG] [--label L]}"; shift
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
	if grep -aq 'app_server: Use' "$log" && grep -aq 'desklink' "$log"; then
		verdict=PASS; pass=$((pass + 1))
	else
		verdict=FAIL
	fi
	# a stuck CPU the kernel's GIC watchdog got going again (arch_int_gicv2.cpp)
	recovered=$(grep -a -c 'after the SGI' "$log" || true)
	echo "boot-bench: trial $t/$n $verdict  $(grep -a -c . "$log") lines  $recovered recovered  $log"
done
echo "boot-bench: $pass/$n reached the desktop ($(basename "$img"))"
