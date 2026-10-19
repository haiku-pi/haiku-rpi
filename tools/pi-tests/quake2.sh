#!/bin/sh
# quake2.sh — a UserBootscript: Yamagi Quake II (SDL2 + OpenGL on the V3D, cross-built:
# scripts/build-games.sh) plays the demo's attract demo in a 640x480 window with the GL1 and then
# the GL3 renderer, 40 s each; egl_haiku reports the frame rate (HAIKU_EGL_FPS). Serial console
# lines: "Q2 " markers and rates; the game's own output unprefixed.
sleep 20
out=/dev/dprintf
dir=/boot/system/non-packaged/apps/quake2
say() { echo "Q2 $*" > $out; }
cd $dir || { say "no $dir"; exit 1; }
for renderer in gl1 gl3; do
	say "renderer $renderer"
	HAIKU_EGL_FPS=1 ./Quake2 +set vid_renderer $renderer +set vid_fullscreen 0 +set r_mode -1 \
		+set r_customwidth 640 +set r_customheight 480 +set s_initsound 0 \
		+demomap demo1.dm2 > /tmp/quake2-$renderer.txt 2>&1 &
	quake=$!
	sleep 40
	kill $quake
	sleep 3
	grep -a 'frames/s' /tmp/quake2-$renderer.txt | while read -r line; do say "$renderer rate: $line"; done
	grep -a -i -E 'error|fail|renderer|GL_' /tmp/quake2-$renderer.txt | head -n 12 \
		| while read -r line; do say "$renderer: $line"; done
done
say end
