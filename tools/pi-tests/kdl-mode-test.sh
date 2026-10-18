#!/bin/sh
# kdl-mode-test.sh — a UserBootscript for GPU stage 4's "the kernel debugger still prints on HDMI after
# a mode change": switches to 1280x720 (scaled by a firmware plane) and stays; the cycle then enters
# the kernel debugger (sd-cycle.sh --send) and its HDMI frames show where KDL draws.
sleep 20
echo "MOD set 1280 720" > /dev/dprintf
screenmode -q 1280 720 > /dev/dprintf 2>&1
echo "MOD now: $(screenmode -s 2>&1)" > /dev/dprintf
