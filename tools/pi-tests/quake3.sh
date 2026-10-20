#!/bin/sh
# quake3.sh — a UserBootscript for Quake III Arena on ioquake3 (SDL2 + OpenGL, the GL1 renderer on
# Mesa's V3D; scripts/build-q3.sh with QUAKE3_DATA: the demo's or retail data, not free). The demo's
# own demos (demos/demo00[12].dm3, protocol 43) cannot play on ioquake3, so this is a bot deathmatch
# on q3dm1 watched by an orbiting third-person camera (the action of a match, the motion of a flyby),
# in a 1280x720 window, then fullscreen at the desktop's resolution, secs seconds each, then killed.
# Frame rate: egl_haiku's "frames/s" every few seconds (HAIKU_EGL_FPS); cg_drawFPS on screen (HDMI).
# For a timedemo figure, run tools/pi-tests/openarena.sh: same engine, OpenArena's benchmark demo.
#
#   scripts/mkimage-pi4.sh --in sources/haiku/generated.arm64/haiku-mmc.image \
#       --add-tree artifacts/gl-stack/non-packaged --add-tree artifacts/games/non-packaged \
#       --bootscript tools/pi-tests/quake3.sh --out artifacts/images/haiku-pi4-q3.img
#
# A boot script gets no environment: change secs, runs, map and args below (see openarena.sh for
# the run modes). The network is left alone (net_enabled 0: a local game needs no sockets).
# Serial console lines: "Q3 " markers only (stdout goes to /tmp/quake3-<run>.txt).
#
# A good run, for each size: "Q3 start 1280x720 window ...", "Q3 1280x720 still running after 90 s",
# "Q3 egl 1280x720: ... frames/s" lines, "Q3 console 1280x720: GL_RENDERER: V3D 4.2...", "Loading
# DLL file: .../cgame.so" (ioq3's native game modules) and "... entered the game" lines for the bots;
# HDMI showing the arena with bots fighting and the FPS counter.
sleep 20
out=/dev/dprintf
dir=/boot/system/non-packaged/apps/Quake3
secs=90
map=q3dm1
args=""
say() { echo "Q3 $*" > $out; }
cd $dir || { say "no $dir"; exit 1; }
game=demoq3
[ -d $dir/baseq3 ] && game=baseq3
log=/boot/home/config/settings/Quake3/$game/qconsole.log
# the launcher puts the user's files in $HOME/config/settings/Quake3 (here: no HOME, /boot/home)
export HOME=/boot/home
for run in "1280 720 window" "1920 1080 fullscreen"; do
	set -- $run
	w=$1 h=$2 mode=$3 size=${1}x$2
	case $mode in
	window) display="+set r_mode -1 +set r_customwidth $w +set r_customheight $h +set r_fullscreen 0" ;;
	borderless) display="+set r_mode -1 +set r_customwidth $w +set r_customheight $h +set r_fullscreen 0 +set r_noborder 1" ;;
	fullscreen) display="+set r_mode -2 +set r_fullscreen 1" ;;
	*) say "unknown mode $mode"; continue ;;
	esac
	say "start $size $mode, $game $map, $secs s, args: ${args:-none}"
	rm -f $log
	HAIKU_EGL_FPS=1 ./Quake3 +set logfile 2 +set net_enabled 0 +set s_initsound 0 +set com_hunkmegs 256 \
		$display +set cg_drawFPS 1 +set bot_enable 1 +set bot_minplayers 5 +set g_spSkill 3 \
		+set g_doWarmup 0 +set cg_thirdPerson 1 +set cg_thirdPersonRange 120 +set cg_cameraOrbit 1 \
		+set cg_cameraOrbitDelay 1 $args +devmap $map > /tmp/quake3-$size.txt 2>&1 &
	pid=$!
	waited=0
	while [ $waited -lt $secs ] && kill -0 $pid 2> /dev/null; do
		sleep 5
		waited=$((waited + 5))
	done
	if kill -0 $pid 2> /dev/null; then
		say "$size still running after $waited s"
		kill $pid
		sleep 2
		kill -9 $pid 2> /dev/null
	else
		wait $pid
		say "$size exited after $waited s (status $?)"
	fi
	[ -f $log ] || say "$size: no console log $log"
	grep -a 'frames/s' /tmp/quake3-$size.txt | head -n 40 | while read -r line; do say "egl $size: $line"; done
	grep -a -v '^GL_EXTENSIONS' $log | grep -a -i -E 'GL_RENDERER|GL_VERSION|SDL using|setting mode|loading dll file|entered the game|error|couldn|fail' \
		| head -n 30 | cut -c1-200 | while read -r line; do say "console $size: $line"; done
	tail -n 8 $log | cut -c1-200 | while read -r line; do say "console tail $size: $line"; done
	grep -a -v -E '^GL_EXTENSIONS|frames/s' /tmp/quake3-$size.txt | tail -n 5 | cut -c1-200 \
		| while read -r line; do say "stdout tail $size: $line"; done
	sleep 3
done
say end
