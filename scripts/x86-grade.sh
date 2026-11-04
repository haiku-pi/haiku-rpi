#!/usr/bin/env bash
# x86-grade.sh — grade an H22 x86-64 test run's serial log (docs/design/x86-64-check.md §4.3) by its positive
# markers: the "X86T <group> result <test> PASS|FAIL|N/A rc=<n> ..." lines of tools/x86-tests/lib.sh and the
# group's "X86T <group> end" line; a group without its end line is INCOMPLETE (it hung, crashed or ran out of
# time), not FAIL. Also counts the kernel's PANIC / KDL lines, debug_server's "entered the debugger" lines and
# user page faults ("vm_page_fault: ... user 1").
#
#   scripts/x86-grade.sh LOG [--image TAG] [--config CFG] [--poweroff yes|no] [--tsv FILE]
#
# --tsv appends one row per test (and one per group end, kernel check and power-off) to FILE:
#   date  image  config  group  test  verdict  detail  log
# Exit status: 0 when every test is PASS or N/A, the end lines are there and the kernel stayed out of KDL.
set -uo pipefail
[ $# -ge 1 ] || { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
log="$1"; shift
image=? config=? poweroff="" tsv=""
while [ $# -gt 0 ]; do
	case "$1" in
	--image) image="$2"; shift 2 ;;
	--config) config="$2"; shift 2 ;;
	--poweroff) poweroff="$2"; shift 2 ;;
	--tsv) tsv="$2"; shift 2 ;;
	*) echo "x86-grade: unknown option $1" >&2; exit 2 ;;
	esac
done
[ -f "$log" ] || { echo "x86-grade: no log $log" >&2; exit 2; }
name="$(basename "$log")"
now="$(date +%Y-%m-%dT%H:%M)"
bad=0
row() {	# GROUP TEST VERDICT DETAIL
	printf '%-6s %-28s %-10s %s\n' "$1" "$2" "$3" "$4"
	case "$3" in PASS|N/A|info) ;; *) bad=1 ;; esac
	[ -n "$tsv" ] && printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$image" "$config" "$1" "$2" "$3" "$4" "$name" >> "$tsv"
	return 0
}

echo "x86-grade: $name ($image, $config)"
groups=$(grep -a -o -E 'X86T [a-z0-9-]+ ' "$log" | awk '{print $2}' | sort -u)
for g in $groups; do
	# result lines: X86T G result TEST VERDICT rc=N DETAIL...
	while IFS= read -r line; do
		set -- $line
		test="$4" verdict="$5"; shift 5
		row "$g" "$test" "$verdict" "$*"
	done < <(grep -a -o -E "X86T $g result .*" "$log" | tr -d '\r')
	if grep -a -q -E "X86T $g end" "$log"; then
		row "$g" "(end)" PASS "group ran to its end"
	else
		last=$(grep -a -o -E "X86T $g .*" "$log" | tail -n 1 | cut -c1-120)
		row "$g" "(end)" INCOMPLETE "no 'X86T $g end'; last: $last"
	fi
done
[ -n "$groups" ] || row "-" "(groups)" INCOMPLETE "no X86T lines at all"

kdl=$(grep -a -c -E 'PANIC|panic:|Welcome to Kernel Debugging Land' "$log")
dbg=$(grep -a -c 'entered the debugger' "$log")
upf=$(grep -a -c -E 'vm_page_fault: .*(user 1|, user,)' "$log")
if [ "$kdl" -gt 0 ]; then
	row kernel "panic/KDL" FAIL "$kdl lines: $(grep -a -m 1 -E 'PANIC|panic:|Kernel Debugging Land' "$log" | cut -c1-120)"
else
	row kernel "panic/KDL" PASS "none"
fi
row kernel "debugger-entries" info "$dbg 'entered the debugger', $upf user page faults"
# pmexit (tools/x86-tests/app.sh): crashes while exiting leave debugger / user-fault lines between its markers
if grep -a -q 'X86T app info pmexit start' "$log"; then
	pmf=$(awk '/X86T app info pmexit start/ { on = 1; next } /X86T app info pmexit done/ { on = 0 }
		on && (/entered the debugger/ || /vm_page_fault: .*(user 1|, user,)/) { n++ } END { print n + 0 }' "$log")
	[ "$pmf" = 0 ] && row app pmexit-faults PASS "no debugger entry or user page fault during the pmexit runs" \
		|| row app pmexit-faults FAIL "$pmf debugger-entry / user-page-fault lines during the pmexit runs"
fi
case "$poweroff" in
yes) row qemu poweroff PASS "guest powered itself off" ;;
no) row qemu poweroff FAIL "the run ended without a guest power-off" ;;
esac
exit $bad
