#!/usr/bin/env bash
# x86-bfsrm.sh — the BFS `rm -rf` hang probe under KVM (docs/design/bfs-rmrf-hang.md): N runs of the bfsrm group
# (tools/x86-tests/bfsrm.sh), each on a fresh scratch BFS disk and a fresh overlay (a first boot). When a run's rm
# hangs, the guest enters KDL (artifacts/x86-tests/kdl); the KDL commands (default: the stacks of rm and of the
# scratch disk's I/O notifier, thread 29 on the q35/AHCI layout) are typed through the serial socket
# (scripts/kdl-x86.py) and QEMU is stopped by its PID.
#
#   scripts/x86-bfsrm.sh IMAGE N [--hang-secs S] [--kdl CMD]... [--keep-kdl]
#
# IMAGE as scripts/x86-test.sh. CMD may use {p}, rm's team (and thread) id. --keep-kdl: stop after the first hang
# and leave the guest in KDL (until x86-test.sh's --secs) to type more commands. One line per run on stdout and in
# artifacts/qemu-x86/bfsrm.tsv: time, image, PASS|HANG|FAIL, log.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -ge 2 ] || { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
image="$1" n="$2"; shift 2
hangsecs=60 cmds=() keep=0
while [ $# -gt 0 ]; do
	case "$1" in
	--hang-secs) hangsecs="$2"; shift 2 ;;
	--kdl) cmds+=("$2"); shift 2 ;;
	--keep-kdl) keep=1; shift ;;
	*) echo "x86-bfsrm: unknown option $1" >&2; exit 2 ;;
	esac
done
[ ${#cmds[@]} -gt 0 ] || cmds=("bt {p}" "bt 29")
kdl="$root/artifacts/x86-tests/kdl"
[ -x "$kdl" ] || { echo "x86-bfsrm: no $kdl (scripts/build-x86-tests.sh)" >&2; exit 2; }
bfs="$root/sources/haiku-x86/generated.x86_64/objects/linux/x86_64/release/tools/bfs_shell/bfs_shell"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/x86-bfsrm.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
printf '%s\n' "$hangsecs" > "$tmp/hangsecs"
tsv="$root/artifacts/qemu-x86/bfsrm.tsv"

for i in $(seq 1 "$n"); do
	sc="$tmp/scratch.img"
	rm -f "$sc"
	truncate -s 2G "$sc"
	LD_LIBRARY_PATH="${bfs%/objects/*}/objects/linux/lib" "$bfs" --initialize "$sc" scratch > /dev/null \
		|| { echo "x86-bfsrm: bfs_shell --initialize failed" >&2; exit 1; }
	out="$tmp/run.out"
	touch "$tmp/start"
	"$root/scripts/x86-test.sh" bfsrm "$image" --secs $((hangsecs + 900)) --scratch "$sc" --serial-sock \
		--file "$kdl:/boot/home/x86t/kdl" --file "$tmp/hangsecs:/boot/home/x86t/hang-secs" > "$out" 2>&1 &
	tpid=$!
	log="" rundir=""
	while kill -0 $tpid 2> /dev/null; do
		# (x86-test.sh's own output reaches $out only at its end: a pipe buffers it)
		if [ -z "$log" ]; then
			rundir=$(find "$root/artifacts/qemu-x86" -maxdepth 1 -type d -newer "$tmp/start" \
				-name "run-*-bfsrm-$(basename "$image")-*" | head -n 1)
			[ -n "$rundir" ] && log="$(dirname "$rundir")/$(basename "$rundir" | sed 's/^run-//').log"
		fi
		if [ -n "$log" ] && grep -a -q 'X86T bfsrm info round .* still running after' "$log" 2> /dev/null; then
			break
		fi
		sleep 2
	done
	verdict=FAIL
	if [ -n "$log" ] && grep -a -q 'still running after' "$log"; then
		verdict=HANG
		python3 "$root/scripts/kdl-x86.py" "$rundir/serial.sock" "$log" --timeout 120 \
			--wait 'bfsrm hang team (?P<p>[0-9]+)' "${cmds[@]}" > /dev/null
		if [ "$keep" = 1 ]; then
			echo "x86-bfsrm: run $i hung; left in KDL: $rundir/serial.sock, log $log"
			printf '%s\t%s\t%s\t%s\n' "$(date +%FT%T)" "$(basename "$image")" "$verdict" "$log" >> "$tsv"
			wait $tpid
			exit 3
		fi
		q=$(pgrep -f -- "qemu-system-x86_64 .*$rundir/" | head -n 1)
		[ -n "$q" ] && kill "$q"
	fi
	wait $tpid
	[ -n "$log" ] && grep -a -q 'X86T bfsrm result bfsrm PASS' "$log" && verdict=PASS
	[ "$verdict" = FAIL ] && cp "$out" "$root/artifacts/qemu-x86/bfsrm-fail-$(date +%Y%m%d-%H%M%S).out"
	printf '%s\t%s\t%s\t%s\n' "$(date +%FT%T)" "$(basename "$image")" "$verdict" "$log" | tee -a "$tsv"
done
