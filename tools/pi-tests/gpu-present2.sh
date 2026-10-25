#!/bin/sh
# gpu-present2.sh — a UserBootscript for app_server's share of presenting a GL/Vulkan frame
# (docs/design/gpu-present.md, option C1). Run on two images: A with the packaged app_server, B with
# app_server from haiku rpi4-present2 (non-packaged, started instead of the packaged one by a
# user_launch override). Files (scripts/image-add.sh, see the design note's "Pi test, C1"):
#   /boot/home/present2/present-bench          tools/gl-tests/present-bench.cpp
#   /boot/home/present2/bitmapcheck            tools/haiku-tests/bitmapcheck.cpp
#   /boot/home/present2/glview, vkcube         tools/gl-tests (gl-stack build)
#   /boot/home/present2/libgl/libGL.so.1       libglvnd rpi4-present2 (BGLView: transparent view color,
#                                              DrawBitmapAsync), used through LIBRARY_PATH
#   /boot/home/present2/glmark2-es2-async      glmark2 + patches/glmark2-async (DrawBitmapAsync)
#   /boot/home/present2/glmark2.hpkg           installed with pkgman when glmark2-es2 is missing
# Serial console lines "GP2 ...": the app_server in use, bitmapcheck's hashes (equal on A and B),
# present-bench's "PRB" rows, then per client variant the frame rates: glview (stock / new libGL),
# glmark2-es2 (stock / async) at 1920x1080 full screen and 800x600 with build and texture, vkcube
# 1600x900 (Vulkan: the WSI's presenter draws outside an update session); "GP2 end" last. ~7 min.
out=/dev/dprintf
say() { echo "GP2 $*" > $out; }
sleep 25
d=/boot/home/present2
export HAIKU_EGL_FPS=1 HAIKU_VK_FPS=1

if ! command -v glmark2-es2 > /dev/null && [ -f $d/glmark2.hpkg ]; then
	pkgman install -y $d/glmark2.hpkg > /dev/null 2>&1
	sleep 5
fi
data=/boot/system/data/glmark2
say "app_server: $(ps | grep -o '[^ ]*servers/app_server' | head -n 1)"
say "screen: $(screenmode 2>&1 | head -n 1)"

$d/bitmapcheck 2>&1 | while read -r line; do say "$line"; done
$d/present-bench -W 1920 -H 1080 -s cdu 2>&1 | while read -r line; do say "$line"; done
$d/present-bench -W 800 -H 600 -s du 2>&1 | while read -r line; do say "$line"; done

# run NAME COMMAND... — its rate lines to the console
run() {
	name=$1
	shift
	log=/tmp/gp2-$name.txt
	timeout -s KILL 120 "$@" > $log 2>&1 < /dev/null
	status=$?
	grep -a -E 'frames/s|fps|FPS:|Score|PASS|FAIL|rror|ailed|cannot' $log \
		| sed -e 's/^ *//' -e 's/  */ /g' | while read -r line; do say "$name: $line"; done
	say "$name: exit $status"
}

run glview-stock $d/glview -W 1000 -s 5
run glview-new env LIBRARY_PATH=$d/libgl:$LIBRARY_PATH $d/glview -W 1000 -s 5
scenes="-b build:duration=5 -b texture:duration=5"
run gm2-full-stock glmark2-es2 --data-path $data --fullscreen $scenes
run gm2-full-async $d/glmark2-es2-async --data-path $data --fullscreen $scenes
run gm2-800-stock glmark2-es2 --data-path $data --size 800x600 $scenes
run gm2-800-async $d/glmark2-es2-async --data-path $data --size 800x600 $scenes
run vkcube $d/vkcube -W 1600 -H 900 -s 10
say "temp: $(tr -s ' \n' ' ' < /dev/power/bcm2835_thermal/0 2> /dev/null)"
say end
