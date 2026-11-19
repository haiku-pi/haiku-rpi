#!/bin/sh
# blender-m4.sh — Blender milestone M4 (docs/design/blender.md §7): the UI through GHOST_SDL on the desktop. Run
# over ssh in a Pi session after blender-m3.sh installed the packages (same DIR):
#
#   sh blender-m4.sh DIR [LABEL]
#
# Starts DIR/Blender/blender windowed (1600x900 at 0,0) with blender-m4.py (next to this script), which steps
# through the scenario and prints "BM4 ..." lines to /tmp/bm4-LABEL.txt; the host takes an HDMI frame at each
# "BM4 SNAP name". Returns when Blender has quit (at most 6 minutes). Then a keyboard check: Blender again,
# keyinject (DIR/keyinject, tools/haiku-tests/keyinject.cpp) types Escape (closes the splash) and "n" (the 3D
# view's sidebar) into its window,
# and the host takes a frame at "BM4 SNAP 7-key".
dir=$1 label=${2:-run}
[ -x "$dir/Blender/blender" ] || { echo "usage: $0 DIR [LABEL]" >&2; exit 2; }
here=$(dirname "$0")
out=/boot/home/bm4-$label
mkdir -p "$out"
mkdir -p /boot/home/config/settings/system/debug_server 2> /dev/null
echo "default_action log" 2> /dev/null > /boot/home/config/settings/system/debug_server/settings || true
log=/tmp/bm4-$label.txt
# the factory scene saved as a file first: started with a file, Blender shows no splash screen (which
# would cover the viewport in every frame)
"$dir/Blender/blender" -b --factory-startup --python-expr \
	"import bpy; bpy.ops.wm.save_as_mainfile(filepath='$out/default.blend')" > /dev/null 2>&1
"$dir/Blender/blender" --factory-startup -p 0 0 1600 900 "$out/default.blend" --python "$here/blender-m4.py" -- "$out" \
	> "$log" 2>&1 &
pid=$!
i=0
while kill -0 $pid 2> /dev/null && [ $i -lt 360 ]; do sleep 1; i=$((i + 1)); done
kill -0 $pid 2> /dev/null && { echo "BM4 $label TIMEOUT, killing" >> "$log"; kill $pid; }
wait $pid
echo "BM4 exit status $?" >> "$log"

if [ -x "$dir/keyinject" ]; then
	"$dir/Blender/blender" --factory-startup -p 0 0 1600 900 "$out/default.blend" > /tmp/bm4-$label-key.txt 2>&1 &
	pid=$!
	sleep 20
	# Escape first: the splash screen is open (no file was clicked) and takes the keys
	"$dir/keyinject" $pid Blender "^[n" 300 >> /tmp/bm4-$label-key.txt 2>&1
	echo "BM4 keyinject status $?" >> "$log"
	sleep 2
	echo "BM4 SNAP 7-key" >> "$log"
	sleep 10
	kill $pid
	wait $pid 2> /dev/null
fi
echo "BM4 done" >> "$log"
