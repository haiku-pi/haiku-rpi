#!/bin/sh
# blender-b8.sh — blender -8 (docs/design/blender.md §7.15): OpenVDB (voxel remesh, .vdb import rendered by
# Cycles, Volume to Mesh, the OpenVDB fluid cache), GMP (the Exact Boolean solver), Quadriflow, Draco (glTF),
# translations, potrace and libharu. Run over ssh in a Pi session with the desktop running (the PDF export
# needs a window):
#
#   sh blender-b8.sh DIR [LABEL]
#
# DIR/packages: blender -8 and what it needs (pkgman installs the ones the image does not have in that very
# version, as blender-b7.sh); DIR/ref/fluid_data_0012.vdb: a smoke cache frame the official x86-64 Blender
# 3.6.23 wrote (OpenVDB, Blosc); blender-b8.py and blender-b7-extras.py next to this script. Blender is the
# installed package (BLENDER=PATH for another). Output lines start with "BB8 "; grade by the PASS lines and
# compare the numbers with the reference's (DIR/ref/b8ref.txt, the same script on x86-64). Logs:
# /tmp/bb8-LABEL-NAME.txt; files: /boot/home/bb8-LABEL/.
dir=$1 label=${2:-run}
bl="${BLENDER:-/boot/system/apps/Blender/Blender}"
here=$(dirname "$0")
[ -d "$dir/packages" ] || { echo "usage: $0 DIR [LABEL]" >&2; exit 2; }
out=/boot/home/bb8-$label
mkdir -p "$out"
mkdir -p /boot/home/config/settings/system/debug_server 2> /dev/null
echo "default_action log" 2> /dev/null > /boot/home/config/settings/system/debug_server/settings || true
dbg0=$(grep -c 'debug_server: Thread' /var/log/syslog)

new=""
for f in "$dir"/packages/*.hpkg; do
	[ -e "/boot/system/packages/$(basename "$f")" ] || new="$new $f"
done
if [ -n "$new" ]; then
	pkgman install -y $new > /tmp/bb8-$label-pkgman.txt 2>&1
	echo "BB8 $label pkgman: status $?, $(echo $new | wc -w) packages"
else
	echo "BB8 $label pkgman: all installed"
fi
[ -x "$bl" ] || { echo "BB8 $label blender: FAIL no $bl"; exit 1; }
echo "BB8 $label packages: $(ls /boot/system/packages | grep -E '^(blender|boost1.83|openvdb|c_blosc|gmp|potrace|libharu)-' | tr '\n' ' ')"

used() { sysinfo -mem | sed -n 's/.*used\/max *\([0-9]*\) .*/\1/p'; }
# run NAME COMMAND...: the command's output in /tmp/bb8-LABEL-NAME.txt, its wall time and the peak of the
# system's used memory above the value before it (sampled every second)
run() {
	name=$1
	shift
	idle=$(used)
	rm -f /tmp/bb8-$label-done
	( peak=$idle; while [ ! -f /tmp/bb8-$label-done ]; do u=$(used); [ "$u" -gt "$peak" ] && peak=$u; \
		echo $peak > /tmp/bb8-$label-peak; sleep 1; done ) &
	start=$(date +%s)
	"$@" > /tmp/bb8-$label-$name.txt 2>&1
	status=$?
	wall=$(( $(date +%s) - start ))
	touch /tmp/bb8-$label-done
	sleep 2
	mem=$(( ($(cat /tmp/bb8-$label-peak) - idle) / 1048576 ))
	echo "BB8 $label $name: status $status, $wall s wall, peak $mem MB above $(( idle / 1048576 )) MB"
	return $status
}
# results NAME: the script's BB8X lines of that run
results() {
	grep '^BB8X' /tmp/bb8-$label-$1.txt | grep -v 'BB8X done' | sed "s/^BB8X /BB8 $label /"
	grep -q '^BB8X done' /tmp/bb8-$label-$1.txt || { echo "BB8 $label $1: FAIL did not finish"; \
		grep -v '^BB8X' /tmp/bb8-$label-$1.txt | tail -n 15; }
}
b8() { "$bl" -b --factory-startup -t 4 --python "$here/blender-b8.py" -- "$@"; }

# 1. headless: build options, voxel remesh, Quadriflow, Boolean Exact, glTF + Draco, German UI strings,
# Trace Image
run headless b8 "$out" options voxel quadriflow boolean gltf i18n trace
results headless
grep -i 'draco' /tmp/bb8-$label-headless.txt | grep -v '^BB8X' | sort | uniq -c | head -n 3

# 2. a .vdb from x86-64 (Blosc) imported and rendered by Cycles (NanoVDB), and meshed
run vdbrender-ref b8 "$out/ref" vdbrender --vdb "$dir/ref/fluid_data_0012.vdb"
results vdbrender-ref
run vdbmesh-ref b8 "$out/ref" vdbmesh --vdb "$dir/ref/fluid_data_0012.vdb"
results vdbmesh-ref

# 3. the Pi's own OpenVDB smoke cache, its frame 12 rendered the same way
run vdbwrite b8 "$out" vdbwrite
results vdbwrite
run vdbrender-pi b8 "$out/pi" vdbrender --vdb "$out/vdb-cache/data/fluid_data_0012.vdb"
results vdbrender-pi

# 4. Grease Pencil PDF export (libharu): needs a 3D view, so a window
run pdf "$bl" --factory-startup -p 0 0 960 600 --python "$here/blender-b8.py" -- "$out" pdf
results pdf

# 5. -7's extras (Alembic, Ocean, smoke, liquid): the fluid cache format follows the build (OpenVDB now)
run extras "$bl" -b --factory-startup -t 4 --python "$here/blender-b7-extras.py" -- "$out/extras"
grep '^BB7X' /tmp/bb8-$label-extras.txt | sed "s/^BB7X /BB8 $label b7-extras /"
echo "BB8 $label fluid cache files: $(find "$out/extras" -name '*.vdb' | wc -l) .vdb, $(find "$out/extras" -name '*.uni' | wc -l) .uni"

echo "BB8 $label debugger: $(( $(grep -c 'debug_server: Thread' /var/log/syslog) - dbg0 )) new entries"
echo "BB8 $label done"
