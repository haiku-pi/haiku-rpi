#!/bin/sh
# blender-bw-look.sh — what the viewport looks like during and after a middle-button orbit (docs/design/blender.md
# §7.17: patches/blender/0017 leaves anti-aliasing out while navigating), for HDMI frames taken by the host.
# Run as root over ssh in a Pi session, with uiinject next to this script and BLENDER a Blender binary without
# B_ARGV_ONLY (blender-bw.sh's notes):
#
#   BLENDER=/boot/home/bwapp/Blender sh blender-bw-look.sh LABEL
#
# Prints "BBL drag" when the drag starts (6 s), "BBL after" 3 s after it ended, "BBL end" before Blender is
# stopped 10 s later; the host takes a frame after each of the first two.
label=${1:-run}
bl="${BLENDER:-/boot/home/bwapp/Blender}"
here=$(dirname "$0")
"$bl" -p 0 0 1600 900 /boot/home/bbw/default.blend > /tmp/bbl-$label-blender.txt 2>&1 &
pid=$!
sleep 30
"$here/uiinject" $pid Blender activate move 700 450 > /dev/null 2>&1
sleep 5
echo "BBL drag"
"$here/uiinject" $pid Blender drag 3 400 450 1100 450 150 40 > /dev/null 2>&1
sleep 3
echo "BBL after"
sleep 10
echo "BBL end"
kill $pid
wait $pid 2> /dev/null
