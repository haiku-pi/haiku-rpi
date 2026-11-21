#!/bin/sh
# blender-bw.sh — Blender's viewport against the AXI bus monitor (docs/design/blender.md §7.17): blender-bw.py
# (next to this script) orbits and idles per config while axibw (tools/haiku-tests/axibw) samples three bus
# watchers every 500 ms. Run as root over ssh in a Pi session with the blender package installed:
#
#   AXIBW=/boot/home/bw/axibw SELS="SEL SEL SEL" sh blender-bw.sh LABEL WxH HOLD CONFIG...
#
# Output: /tmp/bbw-LABEL.txt (Blender's "BBW ..." lines) and /tmp/bbw-LABEL-axb.txt (axibw's "AXB ..."
# lines); tools/pi-tests/blender-bw-table.py turns them into rates and bytes per frame on the host.
label=$1 size=$2 hold=$3
shift 3
[ -n "$label" ] && [ -n "$hold" ] && [ $# -gt 0 ] || { sed -n '6p' "$0" >&2; exit 2; }
bl="${BLENDER:-/boot/system/apps/Blender/Blender}"
axibw="${AXIBW:-/boot/home/bw/axibw}"
sels="${SELS:-hvs arm_uc arm_l2}"
here=$(dirname "$0")
out=/boot/home/bbw
mkdir -p "$out"
log=/tmp/bbw-$label.txt
[ -f "$out/default.blend" ] || "$bl" -b --factory-startup --python-expr \
	"import bpy; bpy.ops.wm.save_as_mainfile(filepath='$out/default.blend')" > /dev/null 2>&1
# no splash screen (it would cover the viewport): saved preferences, so the GUI run is not --factory-startup
"$bl" -b --python-expr "import bpy; bpy.context.preferences.view.show_splash = False; bpy.ops.wm.save_userpref()" \
	> /dev/null 2>&1
# at most: start-up + per config a warm-up (Material Preview: up to 120 s) + orbit + idle
limit=$((60 + $# * (130 + 2 * ${hold%.*})))
"$axibw" -i 500 -d $((limit + 10)) $sels > /tmp/bbw-$label-axb.txt 2>&1 &
apid=$!
"$bl" -p 0 0 ${size%x*} ${size#*x} "$out/default.blend" --python "$here/blender-bw.py" -- "$hold" "$@" \
	> "$log" 2>&1 &
pid=$!
i=0
while kill -0 $pid 2> /dev/null && [ $i -lt $limit ]; do sleep 1; i=$((i + 1)); done
kill -0 $pid 2> /dev/null && { echo "BBW TIMEOUT, killing" >> "$log"; kill $pid; }
wait $pid
echo "BBW exit status $?" >> "$log"
kill $apid 2> /dev/null
wait $apid 2> /dev/null
grep -a '^BBW' "$log"
