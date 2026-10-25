#!/bin/sh
# glmark2.sh — a UserBootscript: glmark2-es2 (OpenGL ES 2.0 on Mesa's V3D, through EGL; scripts/build-glmark2.sh)
# with its default benchmark set (~33 scenes, 10 s each), first in an 800x600 window, then full screen.
# Serial console lines "GM2 ...": per run the GL strings, the surface, every scene's FPS line, the score and
# the exit status; the SoC temperature; "GM2 end" last. glmark2's whole output stays in /tmp/gm2-<run>.txt.
# Works with the package (/boot/system/data/glmark2) and with the test tree (mkimage-pi4.sh --add-tree
# artifacts/glmark2/non-packaged: /boot/system/non-packaged/data/glmark2). ~13 min after the desktop is up.
out=/dev/dprintf
say() { echo "GM2 $*" > $out; }
sleep 25
data=/boot/system/data/glmark2
[ -d $data ] || data=/boot/system/non-packaged/data/glmark2
if ! command -v glmark2-es2 > /dev/null; then
	say "glmark2-es2 not found"
	say end
	exit 0
fi
say "glmark2-es2: $(command -v glmark2-es2), data $data"

# run NAME ARGS... — one glmark2-es2 run, its results to the console
run() {
	name=$1
	shift
	log=/tmp/gm2-$name.txt
	t0=$(date +%s)
	say "$name: glmark2-es2 $*"
	timeout -s KILL 600 glmark2-es2 --data-path $data "$@" > $log 2>&1 < /dev/null
	status=$?
	grep -a -E 'GL_VENDOR|GL_RENDERER|GL_VERSION|Surface Config|Surface Size|FPS:|Score|rror|Failed' $log \
		| sed -e 's/^ *//' -e 's/  */ /g' | while read -r line; do say "$name: $line"; done
	say "$name: exit $status after $(( $(date +%s) - t0 )) s"
}

run window --size 800x600
run fullscreen --fullscreen
say "temp: $(tr -s ' \n' ' ' < /dev/power/bcm2835_thermal/0 2> /dev/null)"
say end
