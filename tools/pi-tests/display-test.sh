#!/bin/sh
# display-test.sh — a UserBootscript for the Raspberry Pi 4 display driver (GPU stage 4): which
# graphics device app_server uses, the vertical retrace rate (BScreen::WaitForRetrace, the
# accelerant's retrace semaphore), then a short GL window on top. Serial console lines: "DSP "
# (markers), "RTR " (retrace), "GLW " (glview); the driver's own lines start with "bcm2711_display:".
sleep 20
out=/dev/dprintf
bin=/boot/system/non-packaged/bin
say() { echo "DSP $*" > $out; }
say "graphics devices: $(ls /dev/graphics 2>&1)"
$bin/retrace -s 5 > $out 2>&1
say "retrace-exit $?"
$bin/glview -s 3 > $out 2>&1
say "glview-exit $?"
say end
