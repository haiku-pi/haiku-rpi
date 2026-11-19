#!/bin/sh
# blender-m3.sh — Blender milestone M3 (docs/design/blender.md §7): Blender 3.6.23 starts headless on the Pi and
# Cycles renders the default scene. Run over ssh in a Pi session (scripts/pi-session.sh, scripts/pi-ssh.sh).
#
#   sh blender-m3.sh DIR [LABEL]
#
# DIR is artifacts/blender-tests from scripts/build-blender.sh's stage step: Blender/ (the install tree) and
# packages/ (python3.10, the libraries, SDL2 -8; test packages, not in the repository), installed here with
# pkgman first. Output lines start with "BM3 "; each run's log is /tmp/bm3-LABEL-*.txt. Grade by the
# positive markers: "version: PASS", "bpy: PASS", "render: PASS ... ms" and "png: PASS".
dir=$1 label=${2:-run}
[ -x "$dir/Blender/blender" ] || { echo "usage: $0 DIR [LABEL]" >&2; exit 2; }
out=/boot/home/bm3-$label
mkdir -p "$out"
# a crash is logged, not shown as an alert that waits for a click (as blender-probe.sh)
mkdir -p /boot/home/config/settings/system/debug_server 2> /dev/null
echo "default_action log" 2> /dev/null > /boot/home/config/settings/system/debug_server/settings || true

pkgman install -y "$dir"/packages/*.hpkg > /tmp/bm3-$label-pkgman.txt 2>&1
echo "BM3 $label pkgman: status $?"
bl="$dir/Blender/blender"
# every library the executable needs is found (the runtime loader names a missing one and stops)
run() {
	name=$1
	shift
	start=$(date +%s)
	"$@" > /tmp/bm3-$label-$name.txt 2>&1
	status=$?
	echo "BM3 $label $name: status $status, $(( $(date +%s) - start )) s"
	return $status
}

run version "$bl" --version
grep -q '^Blender 3.6.23' /tmp/bm3-$label-version.txt && echo "BM3 $label version: PASS" \
	|| { echo "BM3 $label version: FAIL"; head -n 20 /tmp/bm3-$label-version.txt; }

# Python: the interpreter, the standard library (from the python3.10 package) and bpy
run bpy "$bl" -b --factory-startup --python-expr \
	"import sys, bpy; print('BM3PY', sys.version.split()[0], bpy.app.version_string, len(bpy.data.objects))"
grep -q '^BM3PY 3.10.22 3.6.23' /tmp/bm3-$label-bpy.txt && echo "BM3 $label bpy: PASS $(grep '^BM3PY' /tmp/bm3-$label-bpy.txt)" \
	|| { echo "BM3 $label bpy: FAIL"; tail -n 20 /tmp/bm3-$label-bpy.txt; }

# Cycles, CPU: the default cube, frame 1, at 960x540 and 32 samples first (minutes, not hours, if it is slow)
run render "$bl" -b --factory-startup -E CYCLES -o "$out/cube_####" -F PNG \
	--python-expr "import bpy; s = bpy.context.scene; s.render.resolution_x = 960; s.render.resolution_y = 540; s.render.resolution_percentage = 100; s.cycles.samples = 32; s.cycles.device = 'CPU'" \
	-f 1
grep -E 'Saved:|Time:|Fra:1 .*Sample' /tmp/bm3-$label-render.txt | tail -n 3
t=$(sed -n 's/.*Time: \([0-9:.]*\).*/\1/p' /tmp/bm3-$label-render.txt | tail -n 1)
grep -q "Saved: .*cube_0001.png" /tmp/bm3-$label-render.txt && echo "BM3 $label render: PASS $t" \
	|| { echo "BM3 $label render: FAIL"; tail -n 30 /tmp/bm3-$label-render.txt; }
[ -s "$out/cube_0001.png" ] && echo "BM3 $label png: PASS $(ls -l "$out/cube_0001.png" | awk '{print $5}') bytes" \
	|| echo "BM3 $label png: FAIL"
echo "BM3 $label threads: $(sysinfo -cpu 2> /dev/null | grep -c 'CPU #')"
