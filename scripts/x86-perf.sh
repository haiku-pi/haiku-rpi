#!/usr/bin/env bash
# x86-perf.sh — the H22 timing A/B (docs/design/x86-64-check.md §4.6): N rounds of tools/x86-tests/perf.sh on
# each IMAGE in turn (A, B, A, B ...; a fresh overlay each, so boot 1 is a first boot), all under the heavy-build
# lock so that no build runs beside them, with nothing else on the VM side either (start it alone). Per run one
# row in artifacts/qemu-x86/perf.tsv: image, round, host seconds from QEMU start to boot 1's desktop marker (polled
# every 0.1 s), the serial log. scripts/x86-perf-table.py makes the table (medians, spreads) from the logs.
#
#   scripts/x86-perf.sh N IMAGE...        (IMAGE as scripts/x86-test.sh: rpi4, up, kd1 or a path)
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -ge 2 ] || { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
n="$1"; shift
# shellcheck source=/dev/null
[ -f "$root/local.conf" ] && . "$root/local.conf"
lock="${HEAVY_BUILD_LOCK:-/tmp/heavy-build.lock}"
exec 9> "$lock"
echo "x86-perf: waiting for the heavy-build lock $lock"
flock 9
echo "x86-perf: have the lock ($(date +%H:%M:%S))"
tsv="$root/artifacts/qemu-x86/perf.tsv"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/x86-perf.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
for round in $(seq 1 "$n"); do
	for image in "$@"; do
		out="$tmp/run.out"
		: > "$out"
		touch "$tmp/start"
		"$root/scripts/x86-test.sh" perf "$image" --secs 900 > "$out" 2>&1 &
		pid=$!
		log="" t0="" host=""
		label="perf-$(basename "$image")-uefi-ahci"
		while kill -0 "$pid" 2> /dev/null; do
			if [ -z "$log" ]; then
				# qemu-x86.sh's serial log appears when QEMU starts (x86-test.sh's own output is buffered)
				log=$(find "$root/artifacts/qemu-x86" -maxdepth 1 -name "*-$label.log" -newer "$tmp/start" | head -n 1)
				[ -n "$log" ] && t0=$(date +%s.%N)
			elif [ -z "$host" ] && grep -a -q 'X86T perf info boot1 ' "$log" 2> /dev/null; then
				host=$(echo "$(date +%s.%N) - $t0" | bc)
			fi
			sleep 0.1
		done
		wait "$pid"
		grep -E '^(perf|kernel|qemu) ' "$out" | grep -v -E ' PASS ' || true
		printf '%s\t%s\t%s\t%s\n' "$image" "$round" "${host:-?}" "$log" | tee -a "$tsv"
	done
done
