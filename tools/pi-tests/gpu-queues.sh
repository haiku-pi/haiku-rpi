#!/bin/sh
# gpu-queues.sh — a UserBootscript for the V3D driver's job queues (GPU stage 7, docs/design/gpu-stage7.md):
# the driver setting "queues serial" (one job on the GPU at a time) against "queues concurrent" (one job per
# unit: binner, renderer, TFU, CSD), switched inside one boot by rewriting the settings file "v3d" (the
# driver reads it at every open of /dev/dri/renderD128). Image: scripts/gpu-queues-image.sh.
#   1. v3dtest in each mode: the default tests, burst (8 jobs in flight), overlap (a clear's binner list beside
#      a hung render list: concurrent or not), restart (two hung jobs: two resets), then a clear
#   2. glmark2-es2, 800x600 window, the default benchmark: serial, concurrent, serial, concurrent
#   3. QuakeSpasm timedemo demo1 at 1280x720: serial, concurrent, serial, concurrent
#   4. a soak in concurrent mode, 30 minutes: QuakeSpasm cycling its demos and glmark2-es2 in a loop, both at
#      once (two GPU clients, so the units overlap), a line per minute
# /boot/home/gpu-queues/phases (optional) lists the steps to run: "tests glmark2 quake soak" (the default);
# /boot/home/gpu-queues/soak-minutes (optional) the soak's length. netboot-cycle.sh --add sets them per cycle.
# Serial console lines "GQ ...": per step the mode the driver reports, the results, the GPU resets and
# restarted jobs counted in the syslog since the step began; "GQ end" last. The kernel setting v3d_stats
# (the image sets it) adds the driver's "v3d: stats" lines every 5 s while the GPU works, with
# "two or more units busy N ms". ~70 min after the desktop is up.
sleep 25
out=/dev/dprintf
say() { echo "GQ $*" > $out; }
np=/boot/system/non-packaged
settings=/boot/home/config/settings/kernel/drivers/v3d
syslog=/var/log/syslog
export HOME=/boot/home
mkdir -p /boot/home/config/settings/system/debug_server
echo "default_action log" > /boot/home/config/settings/system/debug_server/settings

data=/boot/system/data/glmark2
[ -d $data ] || data=/boot/system/non-packaged/data/glmark2
quake=$np/apps/QuakeSpasm
v3dtest=/boot/home/gpu-queues/v3dtest
phases=" $(cat /boot/home/gpu-queues/phases 2> /dev/null || echo tests glmark2 quake soak) "
minutes=$(cat /boot/home/gpu-queues/soak-minutes 2> /dev/null || echo 30)
want() { case "$phases" in *" $1 "*) return 0 ;; esac; return 1; }

thermal() {
	tr -s ' \n' ' ' < /dev/power/bcm2835_thermal/0 2> /dev/null | sed -e \
		's/.*Current Temperature: \([0-9.]*\) C.*Throttled: \([0-9a-fx]*\) (since boot: \([0-9a-fx]*\)).*/\1 C, throttled \2 (boot \3)/'
}
# syslog_count RE: lines of the syslog (and the part rotated out) matching RE; the UART log stays the
# authority (two rotations within a step would lose lines here)
syslog_count() { n=$(cat $syslog.old $syslog 2> /dev/null | grep -a -c -E "$1"); echo ${n:-0}; }
# mode M: switch the driver to M (serial|concurrent); the next open() applies it
mode() {
	printf 'queues %s\n' "$1" > $settings
	want=$1
}
# mark: remember the syslog's reset/restart counts before a step; delta: what the step added, and the mode
# the driver last reported
mark() { resets0=$(syslog_count 'v3d: GPU reset after'); restarts0=$(syslog_count 'v3d: job [0-9]+ starts over'); }
delta() {
	r=$(( $(syslog_count 'v3d: GPU reset after') - resets0 ))
	s=$(( $(syslog_count 'v3d: job [0-9]+ starts over') - restarts0 ))
	m=$(cat $syslog.old $syslog 2> /dev/null | grep -a 'v3d: job queues:' | tail -n 1 | sed -e 's/.*job queues: \([a-z]*\).*/\1/')
	echo "driver mode $m (wanted $want), $r GPU resets, $s jobs restarted"
}
# bounded SECS DONE_RE DONE_FILE COMMAND...: COMMAND in the background until it exits, SECS pass or DONE_FILE
# has a line matching DONE_RE; then killed
bounded() {
	secs=$1 done_re=$2 done_file=$3
	shift 3
	"$@" > /tmp/gq-run.txt 2>&1 &
	pid=$!
	ran=0
	while [ $ran -lt $secs ] && kill -0 $pid 2> /dev/null; do
		sleep 1
		ran=$((ran + 1))
		if [ -n "$done_re" ] && grep -a -q -E "$done_re" "$done_file" 2> /dev/null; then
			sleep 1
			break
		fi
	done
	if kill -0 $pid 2> /dev/null; then
		kill $pid
		sleep 2
		kill -9 $pid 2> /dev/null
	fi
}

say "begin: steps$phases; $(uname -v | cut -c1-80); $(thermal)"
[ -x $v3dtest ] || say "no $v3dtest"

# 1. the driver's own tests, each mode
want tests && for m in serial concurrent; do
	mode $m
	mark
	$v3dtest -d all burst overlap restart > /tmp/gq-v3dtest-$m.txt 2>&1
	status=$?
	grep -a -E 'burst:|overlap: (the|render)|restart: both|resets|checks passed' /tmp/gq-v3dtest-$m.txt \
		| sed -e 's/^v3dtest: //' | while read -r line; do say "v3dtest $m: $line"; done
	say "v3dtest $m: exit $status; $(delta)"
done

# 2. glmark2-es2, interleaved
if ! want glmark2; then
	:
elif command -v glmark2-es2 > /dev/null; then
	for m in serial concurrent serial concurrent; do
		mode $m
		mark
		t0=$(date +%s)
		timeout -s KILL 600 glmark2-es2 --data-path $data --size 800x600 > /tmp/gq-gm2.txt 2>&1 < /dev/null
		status=$?
		score=$(grep -a 'glmark2 Score' /tmp/gq-gm2.txt | sed -e 's/.*Score: *//')
		say "glmark2 $m: score ${score:-n/a}, exit $status after $(( $(date +%s) - t0 )) s; $(delta) | $(thermal)"
		grep -a 'FPS:' /tmp/gq-gm2.txt | sed -e 's/^ *//' -e 's/  */ /g' | while read -r line; do
			say "glmark2 $m scene: $line"
		done
	done
else
	say "glmark2-es2 not found"
fi

# 3. QuakeSpasm timedemo (from id1/autoexec.cfg: it never runs a +timedemo of its command line)
if ! want quake; then
	:
elif [ -x $quake/quakespasm ]; then
	cd $quake
	for m in serial concurrent serial concurrent; do
		mode $m
		mark
		rm -f qconsole.log
		echo "timedemo demo1" > id1/autoexec.cfg
		bounded 120 'frames.*seconds.*fps' $quake/qconsole.log \
			./quakespasm -basedir $quake -window -width 1280 -height 720 -nosound -condebug
		r=$(grep -a -E 'frames.*seconds.*fps' qconsole.log | tail -n 1)
		say "quakespasm $m: ${r:-n/a}; $(delta) | $(thermal)"
		sleep 2
	done
	rm -f id1/autoexec.cfg
	cd /
else
	say "no $quake/quakespasm"
fi

# 4. soak, concurrent: two GPU clients at once
want soak || minutes=0
mode concurrent
mark
qpid="" gpid=""
if [ $minutes -gt 0 ]; then
	if [ -x $quake/quakespasm ]; then
		cd $quake
		./quakespasm -basedir $quake -window -width 1280 -height 720 -nosound +startdemos demo1 demo2 demo3 \
			> /tmp/gq-soak-quake.txt 2>&1 &
		qpid=$!
		cd /
	fi
	(
		n=0
		while true; do
			timeout -s KILL 900 glmark2-es2 --data-path $data --size 640x480 > /tmp/gq-soak-gm2.txt 2>&1 \
				< /dev/null &
			echo $! > /tmp/gq-soak-gm2-pid
			wait $!
			n=$((n + 1))
			echo $n > /tmp/gq-soak-gm2-runs
		done
	) &
	gpid=$!
fi
for i in $(seq 1 $minutes); do
	sleep 60
	alive=no
	[ -n "$qpid" ] && kill -0 $qpid 2> /dev/null && alive=yes
	say "soak $i/$minutes min: quake running $alive, glmark2 runs $(cat /tmp/gq-soak-gm2-runs 2> /dev/null || echo 0); $(delta) | $(thermal)"
done
if [ $minutes -gt 0 ]; then
	kill $gpid 2> /dev/null
	kill $(cat /tmp/gq-soak-gm2-pid 2> /dev/null) 2> /dev/null
	[ -n "$qpid" ] && kill $qpid 2> /dev/null
	sleep 3
	say "soak: $minutes min, $(delta)"
fi

# afterwards a clear still works
$v3dtest -d clear > /tmp/gq-v3dtest-after.txt 2>&1
say "v3dtest clear after the soak: exit $?"
mode serial
say end
