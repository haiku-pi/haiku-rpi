#!/bin/sh
# mode-test.sh — a UserBootscript for the Raspberry Pi 4 display driver's modes (GPU stage 4): the
# mode list, then 1280x720 and 1024x768 (scaled up by a firmware plane, letterboxed) and back to the
# native mode, each held 15 s for the cycle's HDMI frames; the retrace rate in a scaled mode.
# Serial console lines: "MOD " (markers and screenmode's output), "RTR "; the driver's own
# "bcm2711_display: mode ..." lines.
sleep 20
out=/dev/dprintf
bin=/boot/system/non-packaged/bin
say() { echo "MOD $*" > $out; }
screenmode -l 2>&1 | while read line; do say "$line"; done
say "now: $(screenmode -s 2>&1)"
for mode in "1280 720" "1024 768" "1920 1080"; do
	say "set $mode"
	screenmode -q $mode > $out 2>&1
	say "set-exit $? now: $(screenmode -s 2>&1)"
	[ "$mode" = "1280 720" ] && $bin/retrace -s 2 > $out 2>&1
	sleep 15
done
say end
