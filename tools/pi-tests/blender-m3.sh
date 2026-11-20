#!/bin/sh
# blender-m3.sh — Blender milestone M3 (docs/design/blender.md §7): Blender 3.6.23 starts headless on the Pi and
# Cycles renders the default scene. Run over ssh in a Pi session (scripts/pi-session.sh, scripts/pi-ssh.sh).
#
#   sh blender-m3.sh DIR [LABEL]
#
# DIR is artifacts/blender-tests from scripts/build-blender.sh's stage step: Blender/ (the install tree) and
# packages/ (python3.10, the libraries, SDL2 -8; test packages, not in the repository), installed here with
# pkgman first. Output lines start with "BM3 "; each run's log is /tmp/bm3-LABEL-*.txt. Grade by the
# positive markers: "version: PASS", "bpy: PASS", "render: PASS <time>", "png: PASS" and "factory: PASS <time>".
# The PNGs: /boot/home/bm3-LABEL/cube_0001.png (960x540, 32 samples) and factory_0001.png (the factory scene).
# BLENDER=PATH in the environment: that blender instead of DIR/Blender/blender (the packaged one:
# /boot/system/apps/Blender/Blender, with the blender package among DIR/packages)
dir=$1 label=${2:-run}
bl="${BLENDER:-$dir/Blender/blender}"
[ -d "$dir/packages" ] || { echo "usage: $0 DIR [LABEL]" >&2; exit 2; }
out=/boot/home/bm3-$label
mkdir -p "$out"
# a crash is logged, not shown as an alert that waits for a click (as blender-probe.sh)
mkdir -p /boot/home/config/settings/system/debug_server 2> /dev/null
echo "default_action log" 2> /dev/null > /boot/home/config/settings/system/debug_server/settings || true

# only the packages the image does not have in this very version: "upgrading" a package to the same file
# fails the whole transaction ("Failed to change the package activation in packagefs: Name in use")
new=""
for f in "$dir"/packages/*.hpkg; do
	[ -e "/boot/system/packages/$(basename "$f")" ] || new="$new $f"
done
if [ -n "$new" ]; then
	pkgman install -y $new > /tmp/bm3-$label-pkgman.txt 2>&1
	echo "BM3 $label pkgman: status $?, $(echo $new | wc -w) packages"
else
	echo "BM3 $label pkgman: all installed"
fi
[ -x "$bl" ] || { echo "BM3 $label blender: FAIL no $bl"; exit 1; }
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

# OpenSubdiv: the cube with a level-2 Subdivision Surface, evaluated (8 vertices -> 98; a build without
# OpenSubdiv leaves it at 8: "Disabled, built without OpenSubdiv")
run subsurf "$bl" -b --factory-startup --python-expr \
	"import bpy; o = bpy.data.objects['Cube']; m = o.modifiers.new('s', 'SUBSURF'); m.levels = 2; dg = bpy.context.evaluated_depsgraph_get(); print('BM3SUB', len(o.evaluated_get(dg).data.vertices))"
grep -q '^BM3SUB 98$' /tmp/bm3-$label-subsurf.txt && echo "BM3 $label subsurf: PASS 98 vertices" \
	|| { echo "BM3 $label subsurf: FAIL"; grep -E 'BM3SUB|OpenSubdiv' /tmp/bm3-$label-subsurf.txt; }

# system memory in use, sampled every second while the render runs (sysinfo -mem's "used"): the peak minus the
# idle value before it is Blender's
used() { sysinfo -mem | sed -n 's/.*used\/max *\([0-9]*\) .*/\1/p'; }
idle=$(used)
( peak=$idle; while [ ! -f /tmp/bm3-$label-done ]; do u=$(used); [ "$u" -gt "$peak" ] && peak=$u; echo $peak > /tmp/bm3-$label-peak; sleep 1; done ) &
rm -f /tmp/bm3-$label-done
# Cycles, CPU, 4 threads: the default cube, frame 1, at 960x540 and 32 samples first (minutes, not hours, if
# it is slow). Denoising off: the time is the path tracing alone (the factory scene has denoising on; up to
# -6 there was no OpenImageDenoise, from -7 it runs, blender.md §7.14)
run render "$bl" -b --factory-startup -t 4 -E CYCLES -o "$out/cube_####" -F PNG \
	--python-expr "import bpy; s = bpy.context.scene; s.render.resolution_x = 960; s.render.resolution_y = 540; s.render.resolution_percentage = 100; s.cycles.samples = 32; s.cycles.device = 'CPU'; s.cycles.use_denoising = False" \
	-f 1
touch /tmp/bm3-$label-done
sleep 2
echo "BM3 $label memory: peak $(( ($(cat /tmp/bm3-$label-peak) - idle) / 1048576 )) MB above idle ($(( idle / 1048576 )) MB)"
grep -E 'Saved:|Time:|Fra:1 .*Sample' /tmp/bm3-$label-render.txt | tail -n 3
t=$(sed -n 's/.*Time: \([0-9:.]*\).*/\1/p' /tmp/bm3-$label-render.txt | tail -n 1)
grep -q "Saved: .*cube_0001.png" /tmp/bm3-$label-render.txt && echo "BM3 $label render: PASS $t" \
	|| { echo "BM3 $label render: FAIL"; tail -n 30 /tmp/bm3-$label-render.txt; }
[ -s "$out/cube_0001.png" ] && echo "BM3 $label png: PASS $(ls -l "$out/cube_0001.png" | awk '{print $5}') bytes" \
	|| echo "BM3 $label png: FAIL"

# the factory scene exactly as it is (1920x1080, up to 4096 samples with adaptive sampling, final-render
# denoising on: -1 to -6 rendered without it (patches/blender/0006, no OpenImageDenoise), -7 denoises with
# OpenImageDenoise: 1 min 37 s became 3 min 30 s on the Pi 4)
rm -f /tmp/bm3-$label-done
( peak=$idle; while [ ! -f /tmp/bm3-$label-done ]; do u=$(used); [ "$u" -gt "$peak" ] && peak=$u; echo $peak > /tmp/bm3-$label-peak; sleep 1; done ) &
run factory "$bl" -b --factory-startup -t 4 -E CYCLES -o "$out/factory_####" -F PNG -f 1
touch /tmp/bm3-$label-done
sleep 2
echo "BM3 $label factory memory: peak $(( ($(cat /tmp/bm3-$label-peak) - idle) / 1048576 )) MB above idle"
t=$(sed -n 's/.*Time: \([0-9:.]*\).*/\1/p' /tmp/bm3-$label-factory.txt | tail -n 1)
grep -q "Saved: .*factory_0001.png" /tmp/bm3-$label-factory.txt && echo "BM3 $label factory: PASS $t" \
	|| { echo "BM3 $label factory: FAIL"; tail -n 30 /tmp/bm3-$label-factory.txt; }
# colour management: Blender's OCIO config with Filmic (a build without OpenColorIO falls back to "Standard")
grep -q 'Filmic" not found' /tmp/bm3-$label-factory.txt && echo "BM3 $label filmic: FAIL (no OpenColorIO)" \
	|| echo "BM3 $label filmic: PASS"
echo "BM3 $label cpu: $(sysinfo -cpu | head -n 1)"
