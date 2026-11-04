#!/bin/sh
# lib.sh — helpers for the H22 x86-64 test bootscripts (tools/x86-tests/*.sh; docs/design/x86-64-check.md §4.3),
# installed by scripts/x86-test.sh as /boot/home/x86t/lib.sh next to the cross-built tests
# (scripts/build-x86-tests.sh). A bootscript sets G (its group) and sources this file.
#
# Serial lines (to /dev/dprintf, which the kernel copies to COM1), graded by scripts/x86-grade.sh:
#   X86T <G> out <test>: <line>                      the test's output (first $X86T_LINES lines, default 40)
#   X86T <G> result <test> PASS|FAIL|N/A rc=<n> ...  one per test
#   X86T <G> info <text>                             anything else worth keeping
#   X86T <G> end                                     the group ran to its end
#
#   t TEST SECS CHECK CMD...    runs CMD (standard input /dev/null) under timeout SECS, its output in a file:
#                               the exit status is taken from CMD itself, before anything filters the output.
#                               PASS: exit 0 and CHECK found. CHECK is an extended regex the output must match,
#                               "!REGEX" one it must not match, or "-" (none). A program the runtime loader
#                               cannot load (a symbol or library this system lacks) is N/A, a timeout FAIL.
#   loop TEST N SECS CMD...     CMD N times (each under timeout SECS); PASS when every run exits 0
out=/dev/dprintf
X86T_LINES=${X86T_LINES:-40}
X86T_DIR=/boot/home/x86t
say() { echo "X86T $G $*" > $out; }

t() {
	name=$1 secs=$2 check=$3
	shift 3
	timeout -k 5 "$secs" "$@" < /dev/null > /tmp/x86t.out 2>&1
	rc=$?
	head -n "$X86T_LINES" /tmp/x86t.out | while IFS= read -r l; do say "out $name: $l"; done
	verdict=PASS why=""
	[ "$rc" = 0 ] || { verdict=FAIL; why="exit $rc"; }
	if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
		verdict=FAIL why="timeout ${secs}s"
	elif grep -a -q -i -E "could not resolve symbol|missing library|could not load|cannot open shared|resolving symbol" \
			/tmp/x86t.out && [ "$rc" != 0 ]; then
		verdict=N/A why="does not load"
	fi
	case "$check" in
	-) ;;
	!*) if grep -a -q -E "${check#!}" /tmp/x86t.out; then
			[ "$verdict" = PASS ] && verdict=FAIL
			why="$why; output matches ${check#!}"
		fi ;;
	*) if ! grep -a -q -E "$check" /tmp/x86t.out; then
			[ "$verdict" = PASS ] && verdict=FAIL
			why="$why; no '$check' in the output"
		fi ;;
	esac
	say "result $name $verdict rc=$rc $why"
}

loop() {
	name=$1 n=$2 secs=$3
	shift 3
	i=1 ok=0 last=""
	while [ "$i" -le "$n" ]; do
		timeout -k 5 "$secs" "$@" < /dev/null > /tmp/x86t.out 2>&1
		rc=$?
		if [ "$rc" = 0 ]; then ok=$((ok + 1)); else last="run $i exit $rc: $(tr '\n' ' ' < /tmp/x86t.out | cut -c1-160)"; fi
		i=$((i + 1))
	done
	[ -n "$last" ] && say "out $name: last failure: $last"
	verdict=PASS
	[ "$ok" = "$n" ] || verdict=FAIL
	say "result $name $verdict rc=0 passed $ok of $n"
}

# the scratch disk (scripts/x86-test.sh --scratch: a BFS volume named "scratch", an AHCI disk), mounted at
# /scratch; sets scratch_dev to its device (e.g. /dev/disk/scsi/0/1/0/raw)
mount_scratch() {
	if ! df /scratch 2> /dev/null | grep -q 'Volume Name: "scratch"'; then
		# by name the first time; by its device after an unmount (mountvolume does not find it again)
		if [ -n "${scratch_dev:-}" ]; then
			mkdir -p /scratch && mount "$scratch_dev" /scratch > /dev/null 2>&1
		else
			mountvolume scratch > /dev/null 2>&1
		fi
	fi
	scratch_dev=$(df /scratch 2> /dev/null | awk '$1 == "Device:" { print $2 }')
	say "info scratch on ${scratch_dev:-?}"
}

finish() {
	say end
	sleep 2
	[ -e "$X86T_DIR/no-shutdown" ] || shutdown -q
}
