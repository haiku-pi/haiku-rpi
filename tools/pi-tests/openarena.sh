#!/bin/sh
# openarena.sh — a UserBootscript for OpenArena 0.8.8 on ioquake3 (SDL2 + OpenGL, the GL1 renderer on
# Mesa's V3D; scripts/build-q3.sh): the timedemo demo088-test1 (3398 frames, OpenArena's own
# benchmark demo), first in a 1280x720 window, then fullscreen at the desktop's resolution
# (r_mode -2, 1920x1080 on the bench: no mode switch), each bounded to secs seconds. The demo ends
# with "nextdemo quit", so a good run exits on its own.
# Frame rates, two ways: ioquake3's timedemo line "N frames X seconds Y fps min/avg/max/stddev ms"
# (from the console log, logfile 2: flushed on every line, survives a kill) and egl_haiku's
# "frames/s" every few seconds (HAIKU_EGL_FPS); cg_drawFPS on screen (HDMI).
#
#   scripts/mkimage-pi4.sh --in sources/haiku/generated.arm64/haiku-mmc.image \
#       --add-tree artifacts/gl-stack/non-packaged --add-tree artifacts/games/non-packaged \
#       --bootscript tools/pi-tests/openarena.sh --out artifacts/images/haiku-pi4-q3.img
#
# A boot script gets no environment: change secs, runs and args below. A run is "W H window",
# "W H borderless" (a W x H window without decorations) or "W H fullscreen" (SDL fullscreen at the
# desktop's resolution; W and H only label it). args adds console settings, e.g. "+set r_picmip 1"
# or "+set s_initsound 1" (sound is off: the benchmark measures the renderer).
# The network is left alone (net_enabled 0: a demo needs no sockets).
# Serial console lines: "Q3A " markers only (stdout goes to /tmp/openarena-<run>.txt).
#
# A good run, for each size: "Q3A start 1280x720 window ...", "Q3A 1280x720 exited after N s
# (status 0)", "Q3A result 1280x720: 3398 frames X seconds Y fps ...", "Q3A egl 1280x720: ... frames/s"
# lines, "Q3A console 1280x720: GL_RENDERER: V3D 4.2..." and "GL_VERSION: 2.1 Mesa ...", no
# "Couldn't"/"ERROR" lines; HDMI showing the textured, lit arena with the FPS counter. Expected
# noise: "Couldn't read q3history" (first start) and two "Failed to load model file
# models/players/characters/ayumi/lower.md3" (that model is in pak2-players-mature.pk3, which
# build-q3.sh leaves out; the player gets the default model).
sleep 20
out=/dev/dprintf
dir=/boot/system/non-packaged/apps/OpenArena
log=/boot/home/config/settings/OpenArena/baseoa/qconsole.log
secs=300
args=""
say() { echo "Q3A $*" > $out; }
cd $dir || { say "no $dir"; exit 1; }
# the launcher puts the user's files in $HOME/config/settings/OpenArena (here: no HOME, /boot/home)
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
	say "start $size $mode, $secs s, args: ${args:-none}"
	rm -f $log
	HAIKU_EGL_FPS=1 ./OpenArena +set logfile 2 +set net_enabled 0 +set s_initsound 0 +set com_hunkmegs 256 \
		$display +set cg_drawFPS 1 $args +set nextdemo quit +set timedemo 1 +demo demo088-test1 \
		> /tmp/openarena-$size.txt 2>&1 &
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
	grep -a -E '^[0-9]+ frames [0-9.]+ seconds' $log | while read -r line; do say "result $size: $line"; done
	grep -a 'frames/s' /tmp/openarena-$size.txt | head -n 40 | while read -r line; do say "egl $size: $line"; done
	grep -a -v '^GL_EXTENSIONS' $log | grep -a -i -E 'GL_RENDERER|GL_VERSION|GL_VENDOR|SDL using|setting mode|^ *[0-9]+ [0-9]+$|display aspect|vm file|error|couldn|fail' \
		| head -n 30 | cut -c1-200 | while read -r line; do say "console $size: $line"; done
	tail -n 8 $log | cut -c1-200 | while read -r line; do say "console tail $size: $line"; done
	grep -a -v -E '^GL_EXTENSIONS|frames/s' /tmp/openarena-$size.txt | tail -n 5 | cut -c1-200 \
		| while read -r line; do say "stdout tail $size: $line"; done
	sleep 3
done
say end
