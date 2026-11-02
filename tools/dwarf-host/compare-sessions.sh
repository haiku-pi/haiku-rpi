#!/usr/bin/env bash
# compare-sessions.sh — the Debugger sessions of tools/pi-tests/dwarf5.sh in a serial log (QEMU or Pi),
# -gdwarf-4 against -gdwarf-5 build: CLI output and debug report with addresses, team/thread/image IDs,
# sizes and the program's name normalised (and the two variables not yet initialised at the stop,
# add3()'s result and main()'s b, left out), then diffed; and the report's frames of each session.
#
#   tools/dwarf-host/compare-sessions.sh LOG
set -uo pipefail
[ $# = 1 ] || { echo "usage: $0 LOG" >&2; exit 2; }
log="$1"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
grep -a 'DWARF5 ' "$log" | sed 's/^\[[ 0-9.]*\] //' > "$tmp/all"
extract() {	# SESSION KIND
	grep "^DWARF5 $1 $2: " "$tmp/all" | sed "s/^DWARF5 $1 $2: //" \
		| sed -E 's/0x[0-9a-f]+/ADDR/g; s/\b[0-9a-f]{8}\b/HEX/g; s/(team|thread):? [0-9]+/\1 N/g;
			s/stopped: [0-9]+/stopped: N/; s/(c|cxx)-dw[45]/PROGRAM/g; s/\(([0-9]+)\):/(N):/;
			s/[0-9.]+ [KMG]iB/SIZE/g; s/^Memory: .*/Memory/' \
		| grep -Ev '^\s+[0-9]+\s+ADDR\s+ADDR' \
		| grep -Ev '^\s+(result|b): '	# image list (IDs, order); uninitialised at the stop
}
for p in c cxx; do
	for kind in cli report; do
		extract $p-dw4 $kind > "$tmp/4"
		extract $p-dw5 $kind > "$tmp/5"
		d=$(diff "$tmp/4" "$tmp/5" | grep -c '^[<>]')
		echo "$p $kind: $(wc -l < "$tmp/4") / $(wc -l < "$tmp/5") lines, $d differ"
		[ "$d" = 0 ] || diff "$tmp/4" "$tmp/5" | grep '^[<>]' | head -n 20
	done
done
for s in c-dw4 c-dw5 cxx-dw4 cxx-dw5 old-c-dw5 old-cxx-dw4; do
	echo "== $s frames"
	grep "^DWARF5 $s report: " "$tmp/all" | sed "s/^DWARF5 $s report: //" \
		| grep -E '^\s+(0x[0-9a-f]+|00000000)\s+0x[0-9a-f]+\s' | sed -E 's/^\s+//; s/\t/  /g'
done
