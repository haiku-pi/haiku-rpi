#!/bin/sh
# gl-screen.sh — a UserBootscript for the GPU stage 3 exit test: glview (a BGLView window, desktop
# GL on the V3D, presented by egl_haiku's copy into a BBitmap) animates for 5 minutes, so that the
# HDMI frames of the cycle show it moving; then the same 20 s on softpipe for the fps comparison.
# Serial console lines: "GLT " (markers), "GLW " (glview: fps, PASS/FAIL); GPU resets show up as
# "v3d: GPU reset ...".
sleep 20
out=/dev/dprintf
bin=/boot/system/non-packaged/bin
say() { echo "GLT $*" > $out; }
say "v3d 300 s"
$bin/glview -s 300 > $out 2>&1
say "v3d-exit $?"
say "softpipe 20 s"
LIBGL_ALWAYS_SOFTWARE=1 $bin/glview -s 20 > $out 2>&1
say "softpipe-exit $?"
say end
