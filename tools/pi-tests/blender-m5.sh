#!/bin/sh
# blender-m5.sh — Blender milestone M5 (docs/design/blender.md §7): EEVEE Legacy on V3D's 4 color attachments.
# Run over ssh in a Pi session, with the desktop running (EEVEE needs an OpenGL context even with -b), after
# blender-m3.sh installed the packages:
#
#   sh blender-m5.sh DIR [LABEL]
#
# DIR as for blender-m3.sh; blender-m5-scene.py next to this script; Blender is the installed package
# (BLENDER=PATH for another). Renders, each a PNG in /boot/home/bm5-LABEL/ and a log /tmp/bm5-LABEL-NAME.txt:
#   factory   the factory startup scene with EEVEE (its default engine), F12's render
#   scene     blender-m5-scene.py's lit scene with five materials, EEVEE
#   cycles    the same scene with Cycles, for comparison
# Grade by "BM5 ... PASS" lines; "sss-warning" says whether the one-time SSS message appeared.
dir=$1 label=${2:-run}
bl="${BLENDER:-/boot/system/apps/Blender/Blender}"
here=$(dirname "$0")
[ -x "$bl" ] || { echo "BM5 $label blender: FAIL no $bl"; exit 1; }
out=/boot/home/bm5-$label
mkdir -p "$out"
mkdir -p /boot/home/config/settings/system/debug_server 2> /dev/null
echo "default_action log" 2> /dev/null > /boot/home/config/settings/system/debug_server/settings || true

render() {
	name=$1
	shift
	start=$(date +%s)
	"$bl" -b --factory-startup "$@" -o "$out/${name}_####" -F PNG -f 1 > /tmp/bm5-$label-$name.txt 2>&1
	status=$?
	t=$(sed -n 's/.*Time: \([0-9:.]*\).*/\1/p' /tmp/bm5-$label-$name.txt | tail -n 1)
	if [ $status = 0 ] && [ -s "$out/${name}_0001.png" ]; then
		echo "BM5 $label $name: PASS $t ($(( $(date +%s) - start )) s wall)"
	else
		echo "BM5 $label $name: FAIL status $status"
		grep -v '^Fra:' /tmp/bm5-$label-$name.txt | tail -n 15
	fi
	grep -E 'failed to compile|Error: invalid|EEVEE:' /tmp/bm5-$label-$name.txt | sort | uniq -c | head -n 5
}

render factory -E BLENDER_EEVEE
render scene --python "$here/blender-m5-scene.py" -E BLENDER_EEVEE
render cycles --python "$here/blender-m5-scene.py" -E CYCLES
grep -q 'Subsurface Scattering is not available' /tmp/bm5-$label-scene.txt \
	&& echo "BM5 $label sss-warning: shown" || echo "BM5 $label sss-warning: not shown"
echo "BM5 $label debugger: $(grep -c 'debug_server: Thread' /var/log/syslog)"
echo "BM5 $label done"
