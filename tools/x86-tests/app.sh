#!/bin/sh
# app.sh — H22 test group APP (docs/design/x86-64-check.md §4.3): launchtime (start to first window, then quit)
# of the system's applications, bitmapcheck (app_server bitmap drawing, hashes compared between images),
# drawbench, and pmexit (a program that exits while BPathMonitor's looper is busy; haiku a779571e90) N times
# (/boot/home/x86t/pmx.count, default 400) with the path-churn loop of tools/pi-tests/pmexit-loop.sh. A pmexit
# run that crashes shows as an exit status other than 0 or as a debug_server / user page fault line in the
# kernel log between "pmexit start" and "pmexit done". Serial lines "X86T app ...".
G=app
. /boot/home/x86t/lib.sh
waitfor -m application/x-vnd.Be-TRAK
waitfor -m application/x-vnd.Be-TSKB
sleep 5
cd $X86T_DIR || { finish; exit 1; }
for app in Terminal StyledEdit ShowImage DeskCalc Devices FileTypes MediaPlayer WebPositive; do
	path=/boot/system/apps/$app
	[ -e $path ] || path=/boot/system/preferences/$app
	t launch-$app 180 'window after' ./launchtime -q $path 120
	sleep 2
done
t bitmapcheck 120 'BMC ' ./bitmapcheck 2
t drawbench 120 - ./drawbench 1024 640 2

n=$(cat pmx.count 2> /dev/null || echo 400)
mkdir -p /boot/home/pmx
( while :; do mkdir -p /boot/home/pmx/a/b; touch /boot/home/pmx/a/b/settings_file; rm -rf /boot/home/pmx/a; done ) &
churn=$!
say "info pmexit start n=$n"
i=1 bad=0
while [ $i -le $n ]; do
	./pmexit $(( (i % 10) * 5000 + 1000 )) > /dev/null 2>&1
	rc=$?
	if [ $rc != 0 ]; then bad=$((bad + 1)); say "out pmexit: run $i exit $rc"; fi
	i=$((i + 1))
done
kill $churn
say "info pmexit done"
[ $bad = 0 ] && say "result pmexit PASS rc=0 $n runs, 0 bad exits" \
	|| say "result pmexit FAIL rc=1 $n runs, $bad bad exits"
finish
