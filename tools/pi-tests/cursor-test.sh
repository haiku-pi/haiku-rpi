#!/bin/sh
# cursor-test.sh — a UserBootscript for the hardware cursor (a firmware plane, GPU stage 4): the
# pointer moved by a program to the centre and the four corners (held 4 s each for the HDMI frames)
# and around a circle, in the native mode, then again in 1280x720 (scaled). Serial console lines:
# "CUR " (cursor-move), "MOD " (markers); the driver's "bcm2711_display: hardware cursor ..." and
# "cursor at ..." lines show that app_server uses the hardware cursor.
sleep 20
out=/dev/dprintf
bin=/boot/system/non-packaged/bin
say() { echo "MOD $*" > $out; }
$bin/cursor-move -h 4 -c 5 > $out 2>&1
say "native done"
screenmode -q 1280 720 > $out 2>&1
$bin/cursor-move -h 4 -c 5 > $out 2>&1
screenmode -q 1920 1080 > $out 2>&1
say end
