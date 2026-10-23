#!/bin/sh
# prefix-timeline.sh PREFIX [VAR=VALUE...] — on a Pi session with Wine installed (scripts/pi-ssh.sh): create
# a new Wine prefix (`wineboot -i`, Wine Mono and Gecko off) and record a timeline of it: every 2 s the
# output of `ps -a` (teams with their command lines, threads with their user and kernel times in µs) goes to
# PREFIX.timeline, each sample headed "SAMPLE <seconds since start>". At the end "PREFIX <seconds>" and the
# prefix's counts. tools/wine-tests/prefix-timeline.py turns the file into per-process wall and CPU times.
prefix=$1; shift
[ -e "$prefix" ] && { echo "prefix-timeline: $prefix exists" >&2; exit 1; }
export WINEPREFIX=$prefix WINEDEBUG=${WINEDEBUG:--all} WINEDLLOVERRIDES="mscoree,mshtml="
wineserver -k 2>/dev/null; sleep 2
start=$(date +%s)
env "$@" wineboot -i > "$prefix.log" 2>&1 &
pid=$!
while kill -0 $pid 2>/dev/null || ps | grep -q "[b]in/wineserver"; do
	echo "SAMPLE $(($(date +%s) - start))"
	ps -a
	sleep 2
done >> "$prefix.timeline"
echo "PREFIX $(($(date +%s) - start)) system32=$(ls $prefix/drive_c/windows/system32 | wc -l)" \
	"syswow64=$(ls $prefix/drive_c/windows/syswow64 | wc -l)"
