#!/bin/sh
# gpu-report.sh — a UserBootscript for test images: after the desktop is up, opens the V3D GPU
# (which powers it on) and reports its identification to the serial console, "GPR " lines.
sleep 20
out=/dev/dprintf
say() { echo "GPR $*" > $out; }
say begin
ls /dev/dri 2>&1 | while read -r line; do say "dri $line"; done
say "opening /dev/dri/renderD128"
cat /dev/dri/renderD128 2>&1 | while read -r line; do say "ident $line"; done
say end
