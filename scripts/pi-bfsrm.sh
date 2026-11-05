#!/usr/bin/env bash
# pi-bfsrm.sh — the BFS `rm -rf` hang probe on the Pi (docs/design/bfs-rmrf-hang.md "Pi check"): N network boots of
# IMG, each a fresh copy of the image (a first boot: the first-login PostInstallScript's `sync` runs near the probe's
# `rm -rf`), each running tools/pi-tests/bfsrm.sh as its UserBootscript against a fresh BFS volume on the USB disk
# (never the SD card). A run ends at the probe's "BFSRM end"; when rm hangs, the probe enters the kernel debugger
# and this script types `bt <rm>`, `threads` and `bt` of every notifier thread into it, then ends the run.
#
#   scripts/pi-bfsrm.sh IMG N LABEL [--rounds R] [--hang-secs S] [--first K]
#
# --first K: runs K+1... only (numbering continues an earlier series). One row per run in
# artifacts/bfsrm-pi/bfsrm.tsv: time, label, run, PASS|HANG|NOBOOT|FAIL, overlap, serial log. Each boot holds the bench
# lock (scripts/netboot-cycle.sh) and restores the bench default on exit.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -ge 3 ] || { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
img="$(realpath "$1")" n="$2" label="$3"; shift 3
rounds=5 hang=60 first=0
while [ $# -gt 0 ]; do
	case "$1" in
	--rounds) rounds="$2"; shift 2 ;;
	--hang-secs) hang="$2"; shift 2 ;;
	--first) first="$2"; shift 2 ;;
	*) echo "pi-bfsrm: unknown option $1" >&2; exit 2 ;;
	esac
done
bin="$root/artifacts/bfsrm-pi/bin"
out="$root/artifacts/bfsrm-pi"
mkdir -p "$bin" "$out"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/pi-bfsrm.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
g="$root/sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc"
for p in bfsmeta kdl; do
	[ -x "$bin/$p" ] || "$g" "--sysroot=$root/artifacts/sysroot-arm64" -O2 -o "$bin/$p" "$root/tools/haiku-tests/$p.c" || exit 1
done
printf '%s\n' "$rounds" > "$tmp/rounds"
printf '%s\n' "$hang" > "$tmp/hang-secs"
tsv="$out/bfsrm.tsv"

for k in $(seq $((first + 1)) $((first + n))); do
	rl="$label-$k"
	setsid nohup "$root/scripts/netboot-cycle.sh" --image "$img" --retry-wedge --secs $((hang + 600)) --label "bfsrm-$rl" \
		--hdmi-every 120 --bootscript "$root/tools/pi-tests/bfsrm.sh" \
		--add "$bin/bfsmeta:/boot/home/bfsrm/bfsmeta" --add "$bin/kdl:/boot/home/bfsrm/kdl" \
		--add "$tmp/rounds:/boot/home/bfsrm/rounds" --add "$tmp/hang-secs:/boot/home/bfsrm/hang-secs" \
		> "$tmp/cycle.out" 2>&1 < /dev/null &
	cpid=$!
	verdict=NOBOOT log="" t=0 kdl_done=0 bt_at=0
	while kill -0 "$cpid" 2> /dev/null; do
		sleep 3
		t=$((t + 3))
		log=$(ls -t "$root"/artifacts/uart/*-"bfsrm-$rl".log 2> /dev/null | head -n 1)
		[ -n "$log" ] || continue
		if grep -a -q 'BFSRM result bfsrm PASS' "$log" && grep -a -q 'BFSRM end' "$log"; then verdict=PASS; break; fi
		if grep -a -q 'BFSRM result bfsrm FAIL' "$log"; then
			if grep -a -q 'rm hung in round' "$log"; then
				verdict=HANG
				if [ "$kdl_done" = 0 ] && grep -a -q 'kdebug> ' "$log"; then
					team=$(grep -a -o 'bfsrm hang team [0-9]*' "$log" | head -n 1 | grep -o '[0-9]*$')
					"$root/scripts/uart-send.sh" "1:bt $team\n" "6:threads\n" > /dev/null
					kdl_done=1 bt_at=$t
				elif [ "$kdl_done" = 1 ] && [ $((t - bt_at)) -ge 20 ]; then
					# the notifier threads' stacks (the thread list is long: its first column is the address, the second the id)
					ids=$(sed -E 's/^\[ *[0-9.]+\] *//' "$log" | grep -a -E '^0x[0-9a-f]+ +[0-9]+ .*notifier' | awk '{ print $2 }' | head -n 6)
					a=0 args=()
					for id in $ids; do a=$((a + 4)); args+=("$a:bt $id\n"); done
					[ ${#args[@]} -gt 0 ] && "$root/scripts/uart-send.sh" "${args[@]}" > /dev/null
					kdl_done=2 bt_at=$t
				elif [ "$kdl_done" = 2 ] && [ $((t - bt_at)) -ge $((6 * 4 + 12)) ]; then
					break
				fi
			else
				verdict=FAIL
				break
			fi
		fi
	done
	kill -TERM "$cpid" 2> /dev/null
	while kill -0 "$cpid" 2> /dev/null; do sleep 1; done
	log=$(ls -t "$root"/artifacts/uart/*-"bfsrm-$rl".log 2> /dev/null | head -n 1)
	ov=""
	[ -n "$log" ] && ov=$(grep -a -o 'PIS seen=[01]' "$log" | head -n 1)
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%FT%T)" "$label" "$k" "$verdict" "${ov:-}" "${log:-none}" | tee -a "$tsv"
done
