#!/usr/bin/env bash
# cross-port.sh — cross-build a HaikuPorts port on this host (package farm plan §3.1, the fast path
# while native haikuporter builds come up): the recipe's source (scripts/haikuports-fetch.sh), its
# patches applied, configured with tools/cmake/haiku-arm64.cmake or tools/meson/haiku-arm64.cross,
# built, and installed into the sysroot's non-packaged/ (where later ports find it; package it with a
# package script, as scripts/package-gl-stack.sh does).
#
#   scripts/cross-port.sh RECIPE cmake [cmake args...]
#   scripts/cross-port.sh RECIPE meson [meson args...]
#
#   e.g. scripts/cross-port.sh sources/haikuports/media-libs/libsdl2/libsdl2-2.32.10.recipe cmake \
#            -DSDL_STATIC=OFF -DSDL_RPATH=OFF
#
# Build directory: artifacts/cross-ports/<port>-<version>/ (src/ and build/), recreated each run.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -ge 2 ] || { echo "usage: $0 RECIPE cmake|meson [args...]" >&2; exit 2; }
recipe="$(realpath "$1")" system="$2"; shift 2
sysroot="$root/artifacts/sysroot-arm64"
prefix=/boot/system/non-packaged
[ -d "$sysroot/boot/system/develop" ] || { echo "cross-port: run scripts/haiku-sysroot.sh first" >&2; exit 1; }

name="$(basename "$recipe" .recipe)"
portDir="$(dirname "$recipe")"
field() { sed -n "s/^$1=\"\\(.*\\)\"$/\\1/p" "$recipe" | head -n 1; }
version="${name##*-}"
port="${name%-*}"
subst() { sed -e "s/\\\${portVersion}/$version/g; s/\\\$portVersion/$version/g; s/\\\${portName}/$port/g; s/\\\$portName/$port/g"; }

"$root/scripts/haikuports-fetch.sh" "$recipe" >/dev/null
uri="$(field SOURCE_URI | subst)"
archive="$portDir/download/$(field SOURCE_FILENAME | subst)"
[ -f "$archive" ] || archive="$portDir/download/$(basename "${uri%%#*}")"
sourceDir="$(field SOURCE_DIR | subst)"

work="$root/artifacts/cross-ports/$name"
rm -rf "$work"
mkdir -p "$work/unpack"
tar -xf "$archive" -C "$work/unpack"
if [ -n "$sourceDir" ]; then
	mv "$work/unpack/$sourceDir" "$work/src"
else
	mv "$work/unpack"/* "$work/src"
fi
rmdir "$work/unpack" 2>/dev/null || true

for p in $(field PATCHES | subst); do
	echo "cross-port: applying $p"
	patch -s -p1 -d "$work/src" < "$portDir/patches/$p"
done

case "$system" in
cmake)
	cmake -S "$work/src" -B "$work/build" -G Ninja \
		-DCMAKE_TOOLCHAIN_FILE="$root/tools/cmake/haiku-arm64.cmake" \
		-DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_BUILD_TYPE=Release "$@" > "$work/configure.log"
	;;
meson)
	meson setup "$work/build" "$work/src" --cross-file "$root/tools/meson/haiku-arm64.cross" \
		--prefix="$prefix" --libdir=lib --buildtype=release -Db_ndebug=true "$@" > "$work/configure.log"
	;;
*) echo "cross-port: unknown build system $system" >&2; exit 2 ;;
esac
ninja -C "$work/build" > "$work/build.log" || { tail -n 30 "$work/build.log" >&2; exit 1; }
grep -c 'warning:' "$work/build.log" | sed 's/^/cross-port: compiler warnings: /'
DESTDIR="$sysroot" ninja -C "$work/build" install > "$work/install.log"
echo "cross-port: $name built and installed into $sysroot$prefix"
