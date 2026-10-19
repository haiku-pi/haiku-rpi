#!/bin/sh
# quake2.sh — a UserBootscript: Yamagi Quake II (SDL2 + OpenGL on the V3D, cross-built:
# scripts/build-games.sh) plays the demo's attract demo (demos/q2demo1.dm2) with the GL1 renderer in
# a 640x480 and a 1280x720 window, 40 s each; egl_haiku reports the frame rate (HAIKU_EGL_FPS). (The
# GL3 renderer needs a GL 3.2 context; V3D offers 3.1.) Serial console lines: "Q2 ".
sleep 20
out=/dev/dprintf
dir=/boot/system/non-packaged/apps/quake2
say() { echo "Q2 $*" > $out; }
cd $dir || { say "no $dir"; exit 1; }
for size in "640 480" "1280 720"; do
	set -- $size
	renderer=${1}x$2
	say "gl1 $renderer"
	HAIKU_EGL_FPS=1 ./Quake2 +set vid_renderer gl1 +set vid_fullscreen 0 +set r_mode -1 \
		+set r_customwidth $1 +set r_customheight $2 +set s_initsound 0 \
		+demomap q2demo1.dm2 > /tmp/quake2-$renderer.txt 2>&1 &
	quake=$!
	sleep 40
	kill $quake
	sleep 3
	grep -a 'frames/s' /tmp/quake2-$renderer.txt | while read -r line; do say "$renderer rate: $line"; done
	grep -a -i -E 'error|fail|couldn' /tmp/quake2-$renderer.txt | head -n 8 \
		| while read -r line; do say "$renderer: $line"; done
done
say end
