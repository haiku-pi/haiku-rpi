#!/bin/sh
# vkquake.sh — a UserBootscript for vkQuake (Quake on Vulkan: SDL2's Vulkan window, Mesa's Haiku WSI,
# V3DV; scripts/build-vkquake.sh): the shareware timedemo, then the attract demos, in a window at
# 1280x720 for 40 seconds. Frame rates: the timedemo's "N frames M seconds X fps"
# (from the console log, -condebug: stdout is block-buffered and lost when the game is killed), the
# WSI's "wsi_haiku: N frames/s drawn" every 5 s (HAIKU_VK_FPS), scr_showfps on screen (HDMI).
#
#   scripts/mkimage-pi4.sh --in <pi-mmc image> --add-tree artifacts/gl-stack/non-packaged \
#       --add-tree artifacts/games/non-packaged --bootscript tools/pi-tests/vkquake.sh \
#       --out artifacts/images/haiku-pi4-vkquake.img
#
# A boot script gets no environment: change secs, size and args below. args (empty: upstream's
# settings) adds console commands, e.g. the V3D-friendly "+r_oit 0 +r_gpulightmapupdate 0
# +vid_vsync 2" (no weighted-blended OIT passes, CPU lightmaps, a three-image FIFO swapchain).
# Serial console lines: "VKQ " markers, vkQuake's and Mesa's own output unprefixed.
#
# A good run: "VKQ start 1280x720", Mesa/loader quiet, "wsi_haiku: N frames/s drawn" lines while it
# runs, "VKQ result: N frames M seconds X fps" (timedemo demo1), "VKQ 1280x720 still running after
# 40 s" (the attract demos keep running; killed), "VKQ console: Device: V3D 4.2..." and no
# "Couldn't ..." lines, HDMI showing the textured, lit demo in a window.
sleep 20
out=/dev/dprintf
dir=/boot/system/non-packaged/apps/vkQuake
secs=40
size="1280 720"
args=""
say() { echo "VKQ $*" > $out; }
cd $dir || { say "no $dir"; exit 1; }
set -- $size
w=$1 h=$2
say "start ${w}x$h, ${secs} s, args: ${args:-none}"
rm -f $dir/qconsole.log
HAIKU_VK_FPS=1 VK_LOADER_DEBUG=error,warn ./vkquake -basedir $dir -window -width $w -height $h \
	-nosound -condebug +scr_showfps 1 $args +timedemo demo1 > $out 2>&1 &
pid=$!
waited=0
while [ $waited -lt $secs ] && kill -0 $pid 2> /dev/null; do
	sleep 5
	waited=$((waited + 5))
done
if kill -0 $pid 2> /dev/null; then
	say "${w}x$h still running after $waited s"
	kill $pid
	sleep 2
	kill -9 $pid 2> /dev/null
else
	wait $pid
	say "${w}x$h exited after $waited s (status $?)"
fi
grep -a -E 'frames.*seconds.*fps' $dir/qconsole.log | while read -r line; do say "result: $line"; done
grep -a -i -E 'vulkan|device:|driver:|using|swap|error|couldn' $dir/qconsole.log | head -n 30 \
	| while read -r line; do say "console: $line"; done
tail -n 8 $dir/qconsole.log | while read -r line; do say "console tail: $line"; done
say end
