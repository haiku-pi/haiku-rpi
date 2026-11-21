#!/bin/sh
# g1-npot.sh — Quake II scenes for the V3D NPOT mipmap check (docs/design/gpu-v3d.md §6), run over ssh in a
# session (scripts/pi-session.sh; the game tree copied to $Q2_DIR):
#
#   g1-npot.sh scene RENDERER NAME   the demo's map demo1 from its start, monsters with non-power-of-two skins
#                                    (soldier 288x195, gunner 292x195, infantry 276x194) spawned 100-1500
#                                    units ahead; Quake II's own screenshot (PNG, glReadPixels) when the scene
#                                    stands, then "G1 SNAP NAME" (scripts/pi-snap-on.sh takes the HDMI frame),
#                                    10 s later the game is ended. Shot: /tmp/g1-NAME.png
#   g1-npot.sh timedemo RENDERER N   the attract demo q2demo1.dm2 as a timedemo, 1280x720 window, N runs:
#                                    "G1 timedemo RENDERER: X fps (wall MS ms)" (wall: start to exit, so the
#                                    texture uploads and their mipmaps are in it)
# G1_W/G1_H: the window size (default 1280x720; a small window samples the small mipmap levels close up).
# vid_pauseonfocuslost 1: the game does not pause when its window loses the focus. RENDERER: gl1 or gl3. The timedemo runs with HAIKU_EGL_SWAP_INTERVAL=0 (uncapped, as games-bench.sh). Output on stdout and in /tmp/g1.log; ends with "G1 done".
mode=$1 r=$2 arg=$3
dir=${Q2_DIR:-/boot/home/quake2}
cfg=$dir/baseq2
export HOME=/boot/home
# Quake II's write directory on Haiku: ~/config/settings/<cfgdir>/baseq2 (screenshots in scrnshot/)
shots() { find $HOME/config/settings -path "*baseq2/scrnshot/q2_*.png" 2>/dev/null; }
log=/tmp/g1.log
say() { echo "G1 $*"; echo "G1 $*" >> $log; }
: > $log
cd "$dir" || { say "no $dir"; exit 1; }
common="+set vid_renderer $r +set vid_fullscreen 0 +set r_mode -1 +set r_customwidth ${G1_W:-1280} +set r_customheight ${G1_H:-720}
	+set s_initsound 0 +set vid_pauseonfocuslost 1"
case "$mode" in
scene)
	# the start of demo1 is at (128, -320, 32) looking at yaw 135: forward (-0.707, 0.707), right (0.707, 0.707)
	{
		i=0; while [ $i -lt 150 ]; do echo "wait;wait;wait;wait;wait;wait;wait;wait;wait;wait"; i=$((i + 1)); done
		echo "notarget"; echo "god"; echo "cl_drawhud 0"
		for d in 100 250 450 700 1000 1500; do
			for m in "monster_soldier -56" "monster_gunner 56"; do
				set -- $m
				echo "spawnentity $1 $((128 + (7071 * ($2 - d)) / 10000)) $((-320 + (7071 * (d + $2)) / 10000)) 40 0 315 0"
			done
		done
		i=0; while [ $i -lt 30 ]; do echo "wait;wait;wait;wait;wait;wait;wait;wait;wait;wait"; i=$((i + 1)); done
		echo "screenshot png"
	} > $cfg/g1scene.cfg
	before=$(shots | wc -l)
	HAIKU_EGL_FPS=1 ./Quake2 $common +map demo1 +exec g1scene.cfg > /tmp/g1-q2-$arg.txt 2>&1 &
	q=$!
	t=0
	while [ $t -lt 180 ] && [ "$(shots | wc -l)" -le "$before" ]; do sleep 1; t=$((t + 1)); done
	shot=$(ls -t $(shots) 2>/dev/null | head -n 1)
	sleep 1
	[ -n "$shot" ] && cp "$shot" /tmp/g1-$arg.png
	say "screenshot $shot after $t s"
	say "SNAP $arg"
	sleep 10
	kill $q; sleep 2
	grep -a -i -E 'frames/s|error|couldn|in solid|bad spawn|unknown command|cheats' /tmp/g1-q2-$arg.txt | head -n 20 | while read -r l; do say "$arg: $l"; done
	;;
timedemo)
	n=0
	while [ $n -lt "${arg:-3}" ]; do
		t0=$(date +%s%N | cut -c1-13)
		HAIKU_EGL_SWAP_INTERVAL=0 ./Quake2 $common +set nextdemo quit +set timedemo 1 +demomap q2demo1.dm2 > /tmp/g1-td.txt 2>&1
		t1=$(date +%s%N | cut -c1-13)
		f=$(grep -a -E '[0-9]+ frames, [0-9.]+ seconds: [0-9.]+ fps' /tmp/g1-td.txt | tail -n 1)
		say "timedemo $r: ${f:-n/a} (wall $((t1 - t0)) ms)"
		n=$((n + 1))
	done
	;;
*) echo "usage: g1-npot.sh scene|timedemo RENDERER NAME|N" >&2; exit 2 ;;
esac
say done
