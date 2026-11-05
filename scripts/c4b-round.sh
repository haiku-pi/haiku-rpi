#!/usr/bin/env bash
# c4b-round.sh — one H20 C4b session round (docs/design/perf-round-h20.md §6 "C4b results"): a network session
# on IMG (scripts/pi-session.sh, holds the bench lock), the test programs copied over, then
#   ab:   tools/pi-tests/c4b.sh ab (card: raw controls, BFS writes + cold reads by request size, MD5s after
#         remounts, checkfs), c4b.sh usb (USB disk BFS write + cold read) and tools/pi-tests/usb-bfs.sh;
#   cut:  c4b.sh cut-write, then a power cut (pi-session.sh stop --no-sync) WAIT seconds into the 2 GiB write;
#   check: c4b.sh cut-check (the volume a cut left);
# then the session is stopped. DESTROYS the card's data: restore its image afterwards (sd-cycle.sh --flash).
#
#   scripts/c4b-round.sh IMG LABEL [ab|cut [WAIT]|check]
#
# Output: artifacts/h20-c4b/LABEL.txt (the "C4B"/"UB" lines).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
img="${1:?usage: c4b-round.sh IMG LABEL [ab|cut [WAIT]|check]}" label="${2:?label}" what="${3:-ab}" wait="${4:-20}"
out="$root/artifacts/h20-c4b"
bin="$out/bin"
mkdir -p "$bin"
g="$root/sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc --sysroot=$root/artifacts/sysroot-arm64 -O2"
for p in fcfile diskwrite disklat; do $g -o "$bin/$p" "$root/tools/haiku-tests/$p.c"; done
cp "$root/tools/pi-tests/c4b.sh" "$root/tools/pi-tests/usb-bfs.sh" "$bin/"
ssh_() { "$root/scripts/pi-ssh.sh" "$@"; }
"$root/scripts/pi-session.sh" start --minutes 60 --image "$img" --label "c4b-$label"
ssh_ mkdir -p /boot/home/c4b
ssh_ put "$bin/fcfile" "$bin/diskwrite" "$bin/disklat" "$bin/c4b.sh" "$bin/usb-bfs.sh" /boot/home/c4b/
run() { ssh_ "cd /boot/home/c4b && $*" 2>&1 | tee -a "$out/$label.txt"; }
: > "$out/$label.txt"
echo "C4B round $label image $(basename "$img") $(date +%H:%M:%S)" | tee -a "$out/$label.txt"
case "$what" in
ab)
	run sh c4b.sh ab
	run sh c4b.sh usb
	run "t0=\$(date +%s); sh usb-bfs.sh; echo \"UB total \$((\$(date +%s) - t0)) s\""
	"$root/scripts/pi-session.sh" stop
	;;
cut)
	run sh c4b.sh cut-write
	sleep "$wait"
	run "cat /tmp/c4b-cut.out; ls -l /sd/home" || true
	echo "C4B power cut $(date +%H:%M:%S) after $wait s" | tee -a "$out/$label.txt"
	"$root/scripts/pi-session.sh" stop --no-sync
	;;
check)
	run sh c4b.sh cut-check
	"$root/scripts/pi-session.sh" stop
	;;
esac
grep -a -c 'PANIC\|debug_server\|KDL' "$(ls -t "$root"/artifacts/uart/*-c4b-"$label".log | head -n 1)" \
	| sed 's/^/C4B serial PANIC|debug_server|KDL lines: /' | tee -a "$out/$label.txt" || true
