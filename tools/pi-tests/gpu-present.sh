#!/bin/sh
# gpu-present.sh — a UserBootscript for the GL present path (docs/design/gpu-present.md, task #73):
# what each present step costs, and the prototype present path (Mesa branch rpi4-present) against
# the packaged Mesa, in one boot. Files (scripts/image-add.sh, see the design note's "Pi test"):
#   /boot/home/present/present-bench        tools/gl-tests/present-bench.cpp
#   /boot/home/present/glview               tools/gl-tests/glview.cpp (BGLView, desktop GL)
#   /boot/home/present/egl/libEGL_mesa.so.0 + 50_mesa.json   the prototype's EGL vendor library,
#                                           used through __EGL_VENDOR_LIBRARY_FILENAMES
#   /boot/home/present/glmark2.hpkg         installed with pkgman when glmark2-es2 is missing
# and the kernel setting "v3d_stats true" (the v3d driver's per-5-s statistics on the serial line,
# with the SYNC_BO time once the driver has it).
# Variants: base (the packaged Mesa), proto (merged present blit + bitmaps synced once + three
# bitmaps), proto-sepblit (HAIKU_EGL_SEPARATE_BLIT=1: a blit job of its own, as before), proto-legacy
# (+ HAIKU_EGL_SYNC_EACH_FRAME=1: the old present with a third bitmap). Each: glview 1000x1000 5 s,
# glmark2-es2 full screen and 800x600 with build, texture, refract, terrain (5 s each).
# Serial console lines "GPP ...": the bench's "PRB" lines, egl_haiku's "frames/s; per frame ... ms
# waiting" lines (HAIKU_EGL_FPS), glview's rate, glmark2's FPS lines and score; "GPP end" last.
# ~9 min after the desktop is up.
out=/dev/dprintf
say() { echo "GPP $*" > $out; }
sleep 25
dir=/boot/home/present
export HAIKU_EGL_FPS=1

if ! command -v glmark2-es2 > /dev/null && [ -f $dir/glmark2.hpkg ]; then
	pkgman install -y $dir/glmark2.hpkg > /dev/null 2>&1
	sleep 5
fi
data=/boot/system/data/glmark2
[ -d $data ] || data=/boot/system/non-packaged/data/glmark2
say "screen: $(screenmode 2>&1 | head -n 1)"
say "glmark2-es2: $(command -v glmark2-es2), prototype: $(ls -l $dir/egl/libEGL_mesa.so.0 2>&1)"

for size in 1920x1080 800x600; do
	$dir/present-bench -W ${size%x*} -H ${size#*x} 2>&1 | while read -r line; do say "$line"; done
done

# run VARIANT NAME COMMAND... — a GL program with the variant's environment, its output to the console
run() {
	variant=$1 name=$2
	shift 2
	log=/tmp/gpp-$variant-$name.txt
	case $variant in
	base) env -u __EGL_VENDOR_LIBRARY_FILENAMES "$@" > $log 2>&1 < /dev/null ;;
	proto) env __EGL_VENDOR_LIBRARY_FILENAMES=$dir/egl/50_mesa.json "$@" > $log 2>&1 < /dev/null ;;
	proto-sepblit) env __EGL_VENDOR_LIBRARY_FILENAMES=$dir/egl/50_mesa.json \
		HAIKU_EGL_SEPARATE_BLIT=1 "$@" > $log 2>&1 < /dev/null ;;
	proto-legacy) env __EGL_VENDOR_LIBRARY_FILENAMES=$dir/egl/50_mesa.json \
		HAIKU_EGL_SEPARATE_BLIT=1 HAIKU_EGL_SYNC_EACH_FRAME=1 "$@" > $log 2>&1 < /dev/null ;;
	esac
	status=$?
	grep -a -E 'frames/s|fps|FPS:|Score|GL_RENDERER|renderer:|check|PASS|FAIL|rror|ailed|cannot' $log \
		| sed -e 's/^ *//' -e 's/  */ /g' | while read -r line; do say "$variant $name: $line"; done
	say "$variant $name: exit $status"
}

scenes="-b build:duration=5 -b texture:duration=5 -b refract:duration=5 -b terrain:duration=5"
for variant in base proto proto-sepblit proto-legacy; do
	say "variant $variant"
	run $variant glview timeout -s KILL 60 $dir/glview -W 1000 -s 5
	run $variant gm2-full timeout -s KILL 120 glmark2-es2 --data-path $data --fullscreen $scenes
	run $variant gm2-800 timeout -s KILL 120 glmark2-es2 --data-path $data --size 800x600 $scenes
done
say "temp: $(tr -s ' \n' ' ' < /dev/power/bcm2835_thermal/0 2> /dev/null)"
say end
