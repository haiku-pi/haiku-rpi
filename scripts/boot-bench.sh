#!/usr/bin/env bash
# boot-bench.sh N [IMG] [--label L] [--probe] — boot reliability: N trials of (flash IMG, boot from SD,
# capture 200 s, enter the kernel debugger at 158 s and dump each CPU's stack, ICIs, threads, timers). A trial passes when
# the desktop came up (app_server picked a mode and desklink was started). Summary at the end; each
# trial's UART log and HDMI frames are kept (artifacts/uart, artifacts/hdmi; label <L>-tN).
# --probe: before the debugger, press Ctrl-T three times (150/155/160 s): a kernel with the freeze
# probe makes every CPU print its timer and interrupt state ("freeze probe:" lines).
# --kdl-first: nothing but the debugger keys may wake a frozen boot (no Ctrl-T from sd-cycle.sh), so
# that the CPU stacks show the freeze itself.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
n="${1:?usage: $0 N [IMG] [--label L]}"; shift
img="$root/artifacts/images/haiku-pi4.img"; label=bench
probe=()
cyclearg=()
while [ $# -gt 0 ]; do
	case "$1" in
	--label) label="$2"; shift 2 ;;
	--probe) probe=(--send '150:\x14' --send '155:\x14' --send '160:\x14'); shift ;;
	--kdl-first) cyclearg=(--no-probe); shift ;;
	*) img="$1"; shift ;;
	esac
done
pass=0
for t in $(seq 1 "$n"); do
	"$root/scripts/sd-cycle.sh" --flash "$img" --label "$label-t$t" --secs 200 "${probe[@]}" "${cyclearg[@]}" \
		--send '158:\x1d\x1d\x1dd' --send '161:cpu 0\n' --send '162:bt\n' --send '165:cpu 1\n' \
		--send '166:bt\n' --send '169:cpu 2\n' --send '170:bt\n' --send '173:cpu 3\n' --send '174:bt\n' \
		--send '178:ici\n' --send '181:threads\n' --send '192:\x74imers\n' > /dev/null 2>&1 || true
	log="$(ls -t "$root"/artifacts/uart/*-"$label-t$t".log | head -n 1)"
	if grep -aq 'app_server: Use' "$log" && grep -aq 'desklink' "$log"; then
		verdict=PASS; pass=$((pass + 1))
	else
		verdict=FAIL
	fi
	echo "boot-bench: trial $t/$n $verdict  $(grep -a -c . "$log") lines  $log"
done
echo "boot-bench: $pass/$n reached the desktop ($(basename "$img"))"
