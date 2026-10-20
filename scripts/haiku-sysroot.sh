#!/usr/bin/env bash
# haiku-sysroot.sh — (re)create the Haiku arm64 cross sysroot for building userland ports (libdrm,
# libglvnd, Mesa, test tools) on this Linux host with the jam-built cross compiler.
#
#   scripts/haiku-sysroot.sh [--out DIR]       (default artifacts/sysroot-arm64)
#
# The sysroot is the content of the packages a Haiku system would have installed, extracted with the
# jam-built host `package` tool into DIR/boot/system/ — the layout the cross gcc's built-in search
# paths expect (<sysroot>/boot/system/develop/{headers/*,lib}, see buildtools gcc/config/haiku.h):
#   haiku.hpkg + haiku_devel.hpkg                      (our tree: libroot/libbe/libnetwork…, headers
#                                                       incl. private/, crt objects)
#   gcc_syslibs + gcc_syslibs_devel, zlib + zlib_devel, ncurses6 + ncurses6_devel
#                                                      (HaikuPorts arm64 bootstrap packages, from
#                                                       generated.arm64/download/)
# Use it with `--sysroot=DIR` (tools/meson/haiku-arm64.cross does). Needs a jam build that produced
# haiku_devel.hpkg (scripts/build.sh @minimum-mmc does). Ports built on top install into
# DIR/boot/system/non-packaged (scripts/build-gl-stack.sh), which this script wipes.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/artifacts/sysroot-arm64"
while [ $# -gt 0 ]; do
	case "$1" in
	--out) out="$2"; shift 2 ;;
	*) echo "haiku-sysroot: unknown option $1" >&2; exit 2 ;;
	esac
done
gen="$root/sources/haiku/generated.arm64"
pkgtool="$gen/objects/linux/x86_64/release/tools/package/package"
[ -x "$pkgtool" ] || { echo "haiku-sysroot: $pkgtool missing (build Haiku first)" >&2; exit 1; }
packages=(
	"$gen/objects/haiku/arm64/packaging/packages/haiku.hpkg"
	"$gen/objects/haiku/arm64/packaging/packages/haiku_devel.hpkg"
)
for p in gcc_syslibs gcc_syslibs_devel zlib zlib_devel ncurses6 ncurses6_devel; do
	f=$(ls "$gen"/download/"$p"-[0-9]*-arm64.hpkg 2>/dev/null | head -n 1)
	[ -n "$f" ] || { echo "haiku-sysroot: no $p arm64 package in $gen/download" >&2; exit 1; }
	packages+=("$f")
done

rm -rf "$out"
mkdir -p "$out/boot/system"
for p in "${packages[@]}"; do
	[ -f "$p" ] || { echo "haiku-sysroot: $p missing" >&2; exit 1; }
	LD_LIBRARY_PATH="$gen/objects/linux/lib" "$pkgtool" extract -C "$out/boot/system" "$p"
	echo "haiku-sysroot: $(basename "$p")"
done
rm -f "$out/boot/system/.PackageInfo"
# Packaged .pc files name the package's own mount point (/packages/<name>/.self); installed, those
# files appear under /boot/system.
sed -i 's|/packages/[^/]*/\.self|/boot/system|g' "$out"/boot/system/develop/lib/pkgconfig/*.pc
mkdir -p "$out/boot/system/non-packaged"
for f in develop/lib/libroot.so develop/lib/crti.o develop/lib/libstdc++.so develop/lib/libz.so \
	develop/headers/posix/stdio.h develop/headers/os/interface/View.h \
	develop/headers/private/drivers/drm/v3d_drm.h; do
	[ -e "$out/boot/system/$f" ] || { echo "haiku-sysroot: $f missing in the sysroot" >&2; exit 1; }
done
echo "haiku-sysroot: $out ($(du -sh "$out" | cut -f1))"
