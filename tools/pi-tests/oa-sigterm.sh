#!/bin/sh
# oa-sigterm.sh BIN N — SIGTERM OpenArena's timedemo 4 s after start N times (40 s to exit); count the runs left alive
bin=$1
i=1; alive=0; crash=0
while [ $i -le $2 ]; do
	wait=4
	"$bin" +set fs_basepath /boot/system/apps/OpenArena +set fs_homepath /boot/home/config/settings/OpenArena \
		+set com_basegame baseoa +set net_enabled 0 +set s_initsound 0 +set r_mode -2 +set r_fullscreen 0 \
		+set timedemo 1 +demo demo088-test1 > /tmp/oakill.txt 2>&1 &
	team=$!
	sleep $wait
	kill -TERM $team
	k=0
	while [ $k -lt 80 ] && kill -0 $team 2> /dev/null; do sleep 0.5; k=$((k + 1)); done; times="$times $k"
	if kill -0 $team 2> /dev/null; then
		alive=$((alive + 1)); echo "K $i: ALIVE (after $wait s)"; kill -9 $team; sleep 2
	fi
	grep -q "Error: \." /tmp/oakill.txt && { crash=$((crash + 1)); echo "K $i: Sys_Error from the handler"; }
	sleep 2
	i=$((i + 1))
done
echo "K exit times:$times"; echo "K end: $alive of $2 alive, $crash Sys_Error"
