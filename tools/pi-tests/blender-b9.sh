#!/bin/sh
# blender-b9.sh — blender -9 (docs/design/blender.md §7.16): USD import/export. Run over ssh in a Pi session:
#
#   sh blender-b9.sh DIR [LABEL]
#
# DIR/packages: blender -9 and what it needs (pkgman installs the ones the image does not have in that very
# version, as blender-b8.sh); DIR/ref/b9/factory.{usdc,usda,usdz}: the scene the official x86-64 Blender
# 3.6.23 exported (blender-b9.py's "export" check there); blender-b9.py next to this script. Blender is the
# installed package (BLENDER=PATH for another). Output lines start with "BB9 "; grade by the PASS lines and
# compare the numbers with the reference's (DIR/ref/b9ref.txt, the same script on x86-64). Logs:
# /tmp/bb9-LABEL-NAME.txt; files: /boot/home/bb9-LABEL/.
dir=$1 label=${2:-run}
bl="${BLENDER:-/boot/system/apps/Blender/Blender}"
here=$(dirname "$0")
[ -d "$dir/packages" ] || { echo "usage: $0 DIR [LABEL]" >&2; exit 2; }
out=/boot/home/bb9-$label
mkdir -p "$out"
mkdir -p /boot/home/config/settings/system/debug_server 2> /dev/null
echo "default_action log" 2> /dev/null > /boot/home/config/settings/system/debug_server/settings || true
dbg0=$(grep -c 'debug_server: Thread' /var/log/syslog)

new=""
for f in "$dir"/packages/*.hpkg; do
	[ -e "/boot/system/packages/$(basename "$f")" ] || new="$new $f"
done
if [ -n "$new" ]; then
	pkgman install -y $new > /tmp/bb9-$label-pkgman.txt 2>&1
	echo "BB9 $label pkgman: status $?, $(echo $new | wc -w) packages"
else
	echo "BB9 $label pkgman: all installed"
fi
[ -x "$bl" ] || { echo "BB9 $label blender: FAIL no $bl"; exit 1; }
echo "BB9 $label packages: $(ls /boot/system/packages | grep -E '^(blender|usd)-' | tr '\n' ' ')"

# run NAME COMMAND...: the command's output in /tmp/bb9-LABEL-NAME.txt and its wall time
run() {
	name=$1
	shift
	start=$(date +%s)
	"$@" > /tmp/bb9-$label-$name.txt 2>&1
	status=$?
	echo "BB9 $label $name: status $status, $(( $(date +%s) - start )) s wall"
	return $status
}
# results NAME: the script's BB9X lines of that run
results() {
	grep '^BB9X' /tmp/bb9-$label-$1.txt | grep -v 'BB9X done' | sed "s/^BB9X /BB9 $label /"
	grep -q '^BB9X done' /tmp/bb9-$label-$1.txt || { echo "BB9 $label $1: FAIL did not finish"; \
		grep -v '^BB9X' /tmp/bb9-$label-$1.txt | tail -n 15; }
	# USD's own diagnostics (a missing plug-in or schema shows up here first)
	grep -i -E 'coding error|runtime error|failed to|plugin|warning' /tmp/bb9-$label-$1.txt | grep -v '^BB9X' \
		| sort | uniq -c | head -n 10 | sed "s/^/BB9 $label $1 diag: /"
}
b9() { "$bl" -b --factory-startup -t 4 --python "$here/blender-b9.py" -- "$@"; }

# 1. build option, the factory scene (+ Suzanne, a material) exported to .usdc/.usda/.usdz and re-imported,
# the five UsdGeom gprims imported through usdImaging's adapters
run local b9 "$out" options export shapes
results local
# 2. the files x86-64's official Blender wrote, imported
run ref b9 "$out/ref" refimport --ref "$dir/ref/b9"
results ref
ls -l "$out" | grep factory | sed "s/^/BB9 $label file: /"

echo "BB9 $label debugger: $(( $(grep -c 'debug_server: Thread' /var/log/syslog) - dbg0 )) new entries"
echo "BB9 $label done"
