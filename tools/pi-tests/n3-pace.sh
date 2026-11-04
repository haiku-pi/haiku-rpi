#!/bin/sh
# n3-pace.sh — UserBootscript for H20 item N3 (windowed GL presents paced to the display,
# docs/design/perf-round-h20.md "N3 results"): the same programs with two Mesa builds in one boot. The image
# has the Mesa under test packaged and, under /boot/home/n3, the control Mesa (a/libEGL_mesa.so.0, chosen with
# __EGL_VENDOR_LIBRARY_FILENAMES=/boot/home/n3/a.json), a libSDL2 with SDL_GL_SetSwapInterval (sdl/), glflip
# and gl-pace.sh. Network boot:
#
#   scripts/netboot-cycle.sh --image IMG --bootscript tools/pi-tests/n3-pace.sh --secs 3600 --until 'N3 end' \
#       --retry-wedge --label n3-pace
#
# Serial lines "N3 ...": glflip in a 1280x720 window (swap interval 1 and 0, both Mesas, twice); GLTeapot
# (control, test, test with HAIKU_EGL_SWAP_INTERVAL=1) and SuperTuxKart's main menu (control and test Mesa,
# each with the packaged and the new libSDL2), twice, each with gl-pace.sh (fps, the program's and app_server's
# CPU, the CPUs' busy share); glmark2-es2 --swap-mode fifo (build scene) and the default glmark2-es2 run
# (windowed 800x600, swap interval 0), twice each.
sleep 30
out=/dev/dprintf
export HOME=/boot/home
d=/boot/home/n3
say() { echo "N3 $*" > $out; }
A="__EGL_VENDOR_LIBRARY_FILENAMES=$d/a.json"
SDL="LIBRARY_PATH=$d/sdl:%A/lib:/boot/home/config/non-packaged/lib:/boot/home/config/lib:/boot/system/non-packaged/lib:/boot/system/lib"
STK="/boot/system/apps/SuperTuxKart/SuperTuxKart --windowed --screensize=1024x576"
T=/boot/system/demos/GLTeapot
# pace ENV... -- LABEL WARMUP SECS COMMAND...: gl-pace.sh with that environment, its lines to the serial line
pace() {
	envs=""
	while [ "$1" != -- ]; do envs="$envs $1"; shift; done
	shift
	env $envs sh $d/gl-pace.sh "$@" 2>&1 | while read -r l; do echo "$l" > $out; done
}

mkdir -p /boot/home/config/settings/system/debug_server
echo "default_action log" > /boot/home/config/settings/system/debug_server/settings
say "image: $(uname -a | cut -c1-120)"
say "packages: $(ls /boot/system/packages | grep -E '^(haiku-|mesa|libsdl2|supertuxkart-|glmark2)' | tr '\n' ' ')"
say "idle: $(pmustat -a 20 2>&1 | grep -a -o 'CPUs busy [0-9.]* %')"

for run in 1 2; do
	for v in a b; do
		e=""
		[ $v = a ] && e="$A"
		for i in 1 0; do
			cd $d && env $e HAIKU_EGL_FPS=1 ./glflip -w -n 900 -W 1280 -H 720 -i $i > /tmp/n3-flip.txt 2>&1
			say "glflip $v -i $i run $run: $(grep -a 'GLF frames' /tmp/n3-flip.txt | tail -n 1)"
			grep -a 'egl_haiku: window:' /tmp/n3-flip.txt | tail -n 1 | while read -r l; do say "  $l"; done
		done
	done
done

pace -- stk-warm 60 10 $STK
for run in 1 2; do
	pace "$A" -- teapot-a$run 10 30 $T
	pace -- teapot-b$run 10 30 $T
	pace HAIKU_EGL_SWAP_INTERVAL=1 -- teapot-b-i1-$run 10 30 $T
	pace "$A" -- stk-a$run 40 30 $STK
	pace -- stk-b$run 40 30 $STK
	pace "$SDL" -- stk-b-sdl$run 40 30 $STK
	pace "$A" "$SDL" -- stk-a-sdl$run 40 30 $STK
done

cd /boot/home
for v in a b; do
	e=""
	[ $v = a ] && e="$A"
	env $e HAIKU_EGL_FPS=1 glmark2-es2 --swap-mode fifo -b build:duration=10 > /tmp/n3-gmf-$v.txt 2>&1
	say "glmark2 fifo $v: $(grep -a -E '\[build\]|Score' /tmp/n3-gmf-$v.txt | tr '\n' ' ' | tr -s ' ')"
	grep -a 'egl_haiku: window:' /tmp/n3-gmf-$v.txt | tail -n 1 | while read -r l; do say "  $l"; done
done
for run in 1 2; do
	for v in a b; do
		e=""
		[ $v = a ] && e="$A"
		env $e glmark2-es2 > /tmp/n3-gm-$v$run.txt 2>&1
		say "glmark2 $v run $run: $(grep -a 'Score' /tmp/n3-gm-$v$run.txt)"
		grep -a 'FPS:' /tmp/n3-gm-$v$run.txt | sed -e 's/ FrameTime.*//' | while read -r l; do say "  gm $v$run $l"; done
	done
done
say "end"
