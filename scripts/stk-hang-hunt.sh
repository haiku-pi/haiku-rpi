#!/usr/bin/env bash
# stk-hang-hunt.sh [--image IMG] [--starts N] [--profile SECS] [--warm] [--pre-oa SECS] [--add FILE:PATH]...
#     [--first CMD]
# — catch SuperTuxKart's start hang (11-02/03 games benches, GCC 16.2 images: the white "Untitled" window, never a
# frame) on the bench Pi and record what it waits on: one network session of IMG (default
# artifacts/images/gb-stage6-a.img; the session's bootscript replaces the image's games bench), STK started up to
# N times (default 25) by tools/pi-tests/stk-start-loop.sh (the bench's arguments, a SECS race (default 20), a cold
# shader cache unless --warm). --pre-oa: OpenArena full screen for SECS s before each start (the bench runs it
# before STK); --add: files onto the session's disk (a fixed library in /boot/system/non-packaged/lib, say; the
# loop prints the libroot.so its first start loaded); --first: a command run on the Pi before the loop (a test of
# what was added; its output goes into loop.txt).
# On a hang, before anything that could end it: ps -a of all teams twice 10 s apart (which thread runs), listimage
# of the game, an HDMI frame; then the kernel debugger over the serial line ("threads" of the game; "thread" (what
# it waits on) and "sc" of each of the game's threads and of app_server's threads for it, each CPU's "bt";
# "continue"); last the Debugger's command line on the game (each thread stopped, its user stack; then resumed)
# and whether it went on.
# Output: artifacts/stk-hang/<ts>/ (loop.txt, ps-1/2.txt, images.txt, hdmi.png, debugger.txt, stk-out.txt,
# after.txt); the kernel's dump is in the session's serial log (path in kdl.txt). The session is left running
# after a hang (scripts/pi-session.sh stop), ended when there was none.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/scripts/lib/bench.sh"
img="$root/artifacts/images/gb-stage6-a.img" starts=25 profile=20 warm=0 preoa=0 adds=() first=""
while [ $# -gt 0 ]; do
	case "$1" in
	--image) img="$(realpath "$2")"; shift 2 ;;
	--starts) starts="$2"; shift 2 ;;
	--profile) profile="$2"; shift 2 ;;
	--warm) warm=1; shift ;;
	--pre-oa) preoa="$2"; shift 2 ;;
	--add) adds+=(--add "$2"); shift 2 ;;
	--first) first="$2"; shift 2 ;;
	*) sed -n '2,19p' "$0" >&2; exit 2 ;;
	esac
done
ssh="$root/scripts/pi-ssh.sh"
"$root/scripts/pi-session.sh" start --minutes 180 --image "$img" --label stkhunt "${adds[@]}"
"$ssh" put "$root/tools/pi-tests/stk-start-loop.sh" /boot/home/ > /dev/null
out="$root/artifacts/stk-hang/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"
echo "image $img, starts $starts, profile $profile s, warm $warm, pre-oa $preoa, ${adds[*]}" > "$out/loop.txt"
[ -z "$first" ] || { echo "first: $first"; timeout 900 "$ssh" "$first" 2>&1 || true; } | tee -a "$out/loop.txt"
r=$(timeout $((starts * (160 + profile + preoa) + 60)) "$ssh" "STK_WARM=$warm STK_PRE_OA=$preoa sh /boot/home/stk-start-loop.sh $starts $profile" \
	2>&1 || true)
echo "$r" | tee -a "$out/loop.txt" | grep '^SSL' | cut -c1-200
if ! echo "$r" | grep -q 'HANG team'; then
	"$root/scripts/pi-session.sh" stop > /dev/null 2>&1
	echo "no hang in $starts starts ($out)"
	exit 0
fi
team=$(echo "$r" | sed -n 's/^SSL \([0-9]*\): HANG team \([0-9]*\).*/\2/p' | tail -n 1)
run=$(echo "$r" | sed -n 's/^SSL \([0-9]*\): HANG team .*/\1/p' | tail -n 1)
echo "hang: run $run, team $team"
# what runs: two samples of every thread's state and times
"$ssh" "ps -as > /tmp/ps-1.txt; listimage $team > /tmp/images.txt 2>&1; sleep 10; ps -as > /tmp/ps-2.txt" || true
"$ssh" get /tmp/ps-1.txt /tmp/ps-2.txt /tmp/images.txt "/tmp/ssl-$run.txt" "$out/" > /dev/null || true
mv "$out/ssl-$run.txt" "$out/stk-out.txt" || true
hdmi_snap "$out/hdmi.png" || echo "no HDMI frame"
# the game's threads, and app_server's (team and the threads named after the game's team: "w:<team>:...")
tids=$("$ssh" "ps -a SuperTuxKart" | awk 'NF >= 6 && $(NF - 3) !~ /^[0-9]+$/ && $(NF - 4) ~ /^[0-9]+$/ { print $(NF - 4) }' | tr '\n' ' ')
as=$("$ssh" ps | awk 'NF >= 4 && $1 ~ /app_server$/ { print $(NF - 3) }' | head -n 1)
astids=$("$ssh" "ps -a app_server" | awk -v t=":$team:" 'NF >= 6 && index($0, t) && $(NF - 4) ~ /^[0-9]+$/ { print $(NF - 4) }' \
	| tr '\n' ' ')
echo "threads of $team: $tids; app_server $as, its threads for the game: $astids" | tee "$out/kdl.txt"
ulog=$(ls -t "$root"/artifacts/uart/*-session-stkhunt.log | head -n 1)
echo "serial log $ulog" >> "$out/kdl.txt"
args=('0:\x1d\x1d\x1dd' "6:threads $team\r")
t=12
for thread in $tids $astids; do args+=("$t:thread $thread\r" "$((t + 2)):sc $thread\r"); t=$((t + 4)); done
# a running (spinning) thread has no "sc" on arm64: each CPU's stack instead
for cpu in 0 1 2 3; do args+=("$t:cpu $cpu\r" "$((t + 2)):bt\r"); t=$((t + 4)); done
args+=("$t:continue\r")
"$root/scripts/uart-send.sh" "${args[@]}"
sleep $((t + 8))
# the user stacks (a stop ends a kernel wait: last), then the game resumed
cli=""
for thread in $tids; do cli+="stop $thread\n"; done
for thread in $tids; do cli+="thread $thread\nbt\n"; done
cli+="quit\nr\n"
"$ssh" "printf '$cli' > /tmp/stk-cli; (cat /tmp/stk-cli; sleep 120) | timeout 400 Debugger --cli --team $team \
	> /tmp/debugger.txt 2>&1; true"
"$ssh" get /tmp/debugger.txt "$out/" > /dev/null || true
sleep 30
"$ssh" "ps -a SuperTuxKart; echo; grep -a -c 'frames/s' /tmp/ssl-$run.txt; tail -n 5 /tmp/ssl-$run.txt" > "$out/after.txt" 2>&1 || true
echo "after the Debugger: $(sed -n '$p' "$out/after.txt" | cut -c1-120)"
echo "dump in $ulog and $out (session left running: scripts/pi-session.sh stop)"
