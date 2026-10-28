#!/usr/bin/env bash
# relr-image.sh — a copy of an SD image with the packed relative relocation (DT_RELR) tests: the
# UserBootscript tools/pi-tests/relr.sh and, in /boot/home, relrtest with its libraries, relrbig.c's
# library linked with RELA and with DT_RELR, dlopentime and launchtime (tools/haiku-tests/). For QEMU
# (scripts/qemu-virt.sh --image OUT) or the Pi (scripts/sd-cycle.sh --flash OUT).
#
#   scripts/relr-image.sh [--cross DIR] [--firefox LIBXUL] IMG OUT
#
#   --cross DIR     cross tools whose ld packs relative relocations for aarch64-unknown-haiku (buildtools
#                   with "binutils/haiku: support -z pack-relative-relocs on arm64"); default
#                   sources/haiku/generated.arm64/cross-tools-arm64. Checked: the DT_RELR libraries must
#                   have a DT_RELR entry (an older ld only warns).
#   --firefox LIBXUL  also /boot/home/ffx-rela and /boot/home/ffx-relr: the staged Firefox
#                   (artifacts/firefox/non-packaged/apps/Firefox) as it is, and with LIBXUL (libxul.so
#                   linked with -z pack-relative-relocs) in its lib/, stripped; relr.sh launches both
#
# The programs are built in artifacts/relr/.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cross="$root/sources/haiku/generated.arm64/cross-tools-arm64"
libxul=
while [ $# -gt 2 ]; do
	case "$1" in
	--cross) cross="$(cd "$2" && pwd)"; shift 2 ;;
	--firefox) libxul="$(realpath "$2")"; shift 2 ;;
	*) echo "relr-image: unknown option $1" >&2; exit 2 ;;
	esac
done
[ $# = 2 ] || { echo "usage: $0 [--cross DIR] [--firefox LIBXUL] IMG OUT" >&2; exit 2; }
img="$1" out="$2"
t="$root/tools/haiku-tests" b="$root/artifacts/relr"
mkdir -p "$b"
tp="$cross/bin/aarch64-unknown-haiku-"
cc="${tp}gcc --sysroot=$root/artifacts/sysroot-arm64 -O2 -Wall"
pack=-Wl,-z,pack-relative-relocs

$cc -fPIC -shared $pack -o "$b/librelr.so" "$t/relrlib.c"
$cc -fPIC -shared $pack -DCHECK=relrdl_check -o "$b/librelrdl.so" "$t/relrlib.c"
$cc $pack -o "$b/relrtest" "$t/relrtest.c" -L"$b" -lrelr -Wl,-rpath,'$ORIGIN'
$cc -fPIC -shared -o "$b/librelrbig-rela.so" "$t/relrbig.c"
$cc -fPIC -shared $pack -o "$b/librelrbig-relr.so" "$t/relrbig.c"
$cc -o "$b/dlopentime" "$t/dlopentime.c"
${tp}g++ --sysroot="$root/artifacts/sysroot-arm64" -O2 -I "$root/sources/haiku/headers/private/interface" \
	-o "$b/launchtime" "$t/launchtime.cpp" -lbe
for f in librelr.so librelrdl.so relrtest librelrbig-relr.so; do
	"${tp}readelf" -d "$b/$f" | grep -q '(RELR)' \
		|| { echo "relr-image: $f has no DT_RELR: $cross's ld does not pack relative relocations" >&2; exit 1; }
done
echo "relr-image: test programs built in $b"

"$root/scripts/image-add.sh" "$img" "$out" \
	"$root/tools/pi-tests/relr.sh:/boot/home/config/settings/boot/UserBootscript" \
	"$b/relrtest:/boot/home/relrtest" "$b/librelr.so:/boot/home/librelr.so" \
	"$b/librelrdl.so:/boot/home/librelrdl.so" "$b/librelrbig-rela.so:/boot/home/librelrbig-rela.so" \
	"$b/librelrbig-relr.so:/boot/home/librelrbig-relr.so" "$b/dlopentime:/boot/home/dlopentime" \
	"$b/launchtime:/boot/home/launchtime"

if [ -n "$libxul" ]; then
	"${tp}readelf" -d "$libxul" | grep -q '(RELR)' || { echo "relr-image: $libxul has no DT_RELR" >&2; exit 1; }
	ffx="$root/artifacts/firefox/non-packaged/apps/Firefox"
	rm -rf "$b/ffx-rela" "$b/ffx-relr"
	cp -a "$ffx" "$b/ffx-rela"
	cp -a "$ffx" "$b/ffx-relr"
	"${tp}strip" -o "$b/ffx-relr/lib/libxul.so" "$libxul"
	"$root/scripts/disk-add-tree.sh" --disk "$out" "$b/ffx-rela" /boot/home/ffx-rela
	"$root/scripts/disk-add-tree.sh" --disk "$out" "$b/ffx-relr" /boot/home/ffx-relr
fi
echo "relr-image: $out"
