#!/bin/sh
# stk-start-loop.sh N [PROFILE_SECS] — SuperTuxKart's games-bench start, N times (scripts/stk-hang-hunt.sh):
# the package's game with the bench's arguments (a PROFILE_SECS race, default 20, instead of 60), a cold
# Mesa shader cache each time as in the bench (STK_WARM=1: kept). A start is good when the game prints its
# "Average FPS" line and ends within 90 + PROFILE_SECS s; one that does not (on 11-02/03 the white "Untitled"
# window, no frame) shows as "SSL i: HANG team <id>" and is left running, the loop ended, to be examined.
# STK_PRE_OA=SECS: before each start, OpenArena's benchmark demo full screen 1920x1080 for SECS s (in the bench
# STK starts right after that run). Output of run i: /tmp/ssl-i.txt. Lines "SSL ..." on stdout; ends
# "SSL end N runs, H hangs".
n=${1:-25}
profile=${2:-20}
dir=/boot/system/apps/SuperTuxKart
export HOME=/boot/home
mkdir -p /boot/home/config/settings/system/debug_server
echo "default_action log" > /boot/home/config/settings/system/debug_server/settings
cd $dir || { echo "SSL end 0 runs: no $dir"; exit 1; }
hangs=0
i=1
while [ $i -le $n ]; do
	if [ "${STK_PRE_OA:-0}" -gt 0 ] && cd /boot/system/non-packaged/apps/OpenArena; then
		env HAIKU_EGL_FPS=1 ./OpenArena +set net_enabled 0 +set s_initsound 0 +set com_hunkmegs 256 +set r_mode -2 \
			+set r_fullscreen 1 +set nextdemo quit +set timedemo 1 +demo demo088-test1 > /tmp/ssl-oa.txt 2>&1 < /dev/null &
		oa=$!
		sleep $STK_PRE_OA
		kill $oa 2> /dev/null && sleep 2 && kill -9 $oa 2> /dev/null
		sleep 3
		cd $dir
	fi
	[ "${STK_WARM:-0}" = 1 ] || rm -rf /boot/home/config/cache/mesa_shader_cache
	start=$(date +%s)
	env HAIKU_EGL_FPS=1 ./SuperTuxKart --windowed --screensize=1280x720 --disable-texture-compression \
		--profile-time=$profile --track=hacienda --numkarts=4 --kart=tux --difficulty=0 \
		> /tmp/ssl-$i.txt 2>&1 < /dev/null &
	pid=$!
	t=0
	while [ $t -lt $((90 + profile)) ] && kill -0 $pid 2> /dev/null; do
		sleep 1
		t=$((t + 1))
		grep -a -q 'Average FPS' /tmp/ssl-$i.txt && break
	done
	if grep -a -q 'Average FPS' /tmp/ssl-$i.txt; then
		[ $i = 1 ] && echo "SSL libroot: $(listimage $pid 2> /dev/null | grep -o '/[^ ]*libroot.so' | head -n 1)"
		frames=$(grep -a -c 'frames/s' /tmp/ssl-$i.txt)
		# it ends by itself after the profile; else as the bench ends it
		t2=0
		while [ $t2 -lt 15 ] && kill -0 $pid 2> /dev/null; do sleep 1; t2=$((t2 + 1)); done
		kill $pid 2> /dev/null && sleep 2 && kill -9 $pid 2> /dev/null
		echo "SSL $i: ok after $t s ($frames egl samples; $(grep -a 'Average FPS' /tmp/ssl-$i.txt | tail -n 1 \
			| sed -e 's/.*Average FPS: //' | cut -c1-8) its fps)"
	elif kill -0 $pid 2> /dev/null; then
		hangs=$((hangs + 1))
		echo "SSL $i: HANG team $pid (no Average FPS after $t s; $(grep -a -c 'frames/s' /tmp/ssl-$i.txt) egl samples;" \
			"last output: $(tail -n 1 /tmp/ssl-$i.txt | cut -c1-120))"
		if [ "${STK_KEEP:-1}" = 1 ]; then
			echo "SSL end $i runs, $hangs hangs (kept)"
			exit 0
		fi
		kill -9 $pid
	else
		wait $pid
		echo "SSL $i: ended (exit $?) after $t s without Average FPS: $(tail -n 2 /tmp/ssl-$i.txt | tr '\n' ' ' | cut -c1-160)"
	fi
	sleep 3
	i=$((i + 1))
done
echo "SSL end $n runs, $hangs hangs"
