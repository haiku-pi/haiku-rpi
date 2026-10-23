#!/bin/sh
# oa-sigterm-catch.sh BIN N — SIGTERM OpenArena 4 s after start; on the first run alive after 20 s, save a Debugger report (needs tools/haiku-tests/threads.sh at /boot/home)
bin=$1
dbg=/boot/system/apps/Debugger	# arm64 back end from image-2026-10-23d
i=1
while [ $i -le $2 ]; do
	"$bin" +set fs_basepath /boot/system/apps/OpenArena +set fs_homepath /boot/home/config/settings/OpenArena \
		+set com_basegame baseoa +set net_enabled 0 +set s_initsound 0 +set r_mode -2 +set r_fullscreen 0 \
		+set timedemo 1 +demo demo088-test1 > /tmp/oakill.txt 2>&1 &
	team=$!
	sleep 4
	kill -TERM $team
	k=0
	while [ $k -lt 40 ] && kill -0 $team 2> /dev/null; do sleep 0.5; k=$((k + 1)); done
	if kill -0 $team 2> /dev/null; then
		echo "K $i: ALIVE, team $team"
		ps -a > /boot/home/early-ps.txt
		sh /boot/home/threads.sh $team > /boot/home/early-threads.txt
		echo "K threads: $(tr '\n' ' ' < /boot/home/early-threads.txt)"
		cp /tmp/oakill.txt /boot/home/early-console.txt
		timeout 120 $dbg --save-report=/boot/home/early-report.txt --thread $team > /boot/home/early-dbg.txt 2>&1
		echo "K report rc=$?"
		kill -9 $team 2> /dev/null
		break
	fi
	sleep 2
	i=$((i + 1))
done
echo "K end at $i"
