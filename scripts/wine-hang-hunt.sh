#!/usr/bin/env bash
# wine-hang-hunt.sh [--image IMG] [--sessions N] — catch KNOWN-ISSUES W8 (Wine processes that never end) on the
# bench Pi and record what they wait on: up to N (default 12) network sessions of IMG (default the mega image), each
# making one fresh Wine prefix (tools/pi-tests/wineboot-loop.sh, WBL_KEEP=1). On a hang the session stays up and the
# Debugger's command line stops the wineserver (on 10-29 it was the one running: a loop in user space; a debugger
# attach ends the hang, so this comes first), prints its stack and writes a core file; then the kernel debugger is
# entered over the serial line: "threads <team>" for each Wine team, "sc <thread>" for each of their threads,
# "continue". The serial log of that session
# holds the kernel's dump; artifacts/wine-hang/<ts>/ the wineserver's stack, core and the session's ps output.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
img="$root/artifacts/images/haiku-pi4-mega.img" sessions=12
while [ $# -gt 0 ]; do
	case "$1" in
	--image) img="$(realpath "$2")"; shift 2 ;;
	--sessions) sessions="$2"; shift 2 ;;
	*) sed -n '2,6p' "$0" >&2; exit 2 ;;
	esac
done
ssh="$root/scripts/pi-ssh.sh"
for s in $(seq 1 "$sessions"); do
	"$root/scripts/pi-session.sh" start --minutes 60 --image "$img" --label winehunt > /dev/null 2>&1 \
		|| { echo "session $s: did not start"; continue; }
	"$ssh" put "$root/tools/pi-tests/wineboot-loop.sh" /boot/home/ > /dev/null
	r=$(timeout 900 "$ssh" 'WBL_KEEP=1 sh /boot/home/wineboot-loop.sh 1' 2>&1 || true)
	echo "session $s: $(echo "$r" | grep '^WBL [0-9]' | cut -c1-160)"
	if ! echo "$r" | grep -q HANG; then
		"$root/scripts/pi-session.sh" stop > /dev/null 2>&1
		continue
	fi
	teams=$(echo "$r" | sed -n 's/^WBL teams: //p')
	out="$root/artifacts/wine-hang/$(date +%Y%m%d-%H%M%S)"
	mkdir -p "$out"
	"$ssh" 'ps -a > /boot/home/hang-ps.txt; ws=$(ps | grep "lib/wine/../../bin/wineserver" | grep -v grep \
		| awk "{ print \$(NF - 3) }" | head -n 1); echo "wineserver team $ws"; \
		printf "thread $ws\nstop\nbt\nwrite-core /boot/home/wineserver.core\nquit\n" > /tmp/hang-cli; \
		(cat /tmp/hang-cli; sleep 20) | timeout 60 Debugger --cli --team $ws > /boot/home/hang-bt.txt 2>&1; \
		cat /boot/home/hang-bt.txt' | tee "$out/wineserver-bt.txt"
	"$ssh" get /boot/home/hang-ps.txt /boot/home/wineserver.core "$out/" > /dev/null 2>&1 || true
	ulog=$(ls -t "$root"/artifacts/uart/*-winehunt.log | head -n 1)
	echo "hang: teams $teams; serial log $ulog (kernel debugger dump)"
	args=('0:\x1d\x1d\x1dd')
	t=6
	for team in $teams; do args+=("$t:threads $team\r"); t=$((t + 3)); done
	"$root/scripts/uart-send.sh" "${args[@]}"
	sleep $((t + 5))
	# the threads of those teams: the lines "thread id ... team <id>"? take every thread ID the listings printed
	threads=$(sed -n '/kdebug> threads /,/kdebug>/p' "$ulog" | grep -a -o '^\[[ 0-9.]*\] *0x[0-9a-f]* *[0-9]\+' \
		| awk '{ print $NF }' | sort -un | tr '\n' ' ')
	echo "threads: $threads"
	args=() t=0
	for thread in $threads; do args+=("$t:sc $thread\r"); t=$((t + 2)); done
	args+=("$t:continue\r")
	"$root/scripts/uart-send.sh" "${args[@]}"
	sleep $((t + 5))
	echo "dump in $ulog and $out (session left running: scripts/pi-session.sh stop)"
	exit 0
done
echo "no hang in $sessions sessions"
