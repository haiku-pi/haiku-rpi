#!/bin/sh
# blender-b7-view.sh — blender -7 (docs/design/blender.md §7.14): the viewport's Cycles denoising
# (OpenImageDenoise) on the desktop. Run over ssh in a Pi session after blender-b7.sh installed the
# packages, while the host takes HDMI frames:
#
#   scripts/pi-snap-on.sh /tmp/bb7v-LABEL.txt OUTDIR done 400 /tmp/bb7v-ack &   (host)
#   sh blender-b7-view.sh [LABEL]                                                 (Pi)
#
# blender-m5-scene.py's lit scene, saved as a file first, opened twice in a 1024x600 window with
# blender-b7-view.py (next to this script): without, then with viewport denoising. It prints "BB7V ..."
# lines and the SNAP markers into /tmp/bb7v-LABEL.txt. At most 5 minutes.
label=${1:-run}
bl="${BLENDER:-/boot/system/apps/Blender/Blender}"
here=$(dirname "$0")
out=/boot/home/bb7v-$label
mkdir -p "$out"
log=/tmp/bb7v-$label.txt
"$bl" -b --factory-startup --python "$here/blender-m5-scene.py" --python-expr \
	"import bpy; bpy.ops.wm.save_as_mainfile(filepath='$out/scene.blend')" > /dev/null 2>&1
# preferences without the splash screen (the first-start "Quick Setup" one would cover the viewport; it
# needs a click to close): saved once, read by the GUI run (which is therefore not --factory-startup)
"$bl" -b --python-expr "import bpy; bpy.context.preferences.view.show_splash = False; bpy.ops.wm.save_userpref()" \
	> /dev/null 2>&1
# without, then with viewport denoising
: > "$log"
for d in 0 1; do
	BB7_DENOISE=$d "$bl" -p 0 0 1024 600 "$out/scene.blend" --python "$here/blender-b7-view.py" >> "$log" 2>&1 &
	pid=$!
	i=0
	while kill -0 $pid 2> /dev/null && [ $i -lt 150 ]; do sleep 1; i=$((i + 1)); done
	kill -0 $pid 2> /dev/null && { echo "BB7V TIMEOUT, killing" >> "$log"; kill $pid; }
	wait $pid
	echo "BB7V exit status $?" >> "$log"
done
echo "BB7V done" >> "$log"
grep '^BB7V' "$log"
