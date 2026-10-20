#!/usr/bin/env bash
# cross-port.sh — cross-build a HaikuPorts port on this host (package farm plan §3.1, the fast path
# while native haikuporter builds come up): the recipe's source (scripts/haikuports-fetch.sh), its
# patches applied, configured with tools/cmake/haiku-arm64.cmake or tools/meson/haiku-arm64.cross,
# built, and installed into the sysroot's non-packaged/ (where later ports find it) and into
# artifacts/cross-ports/<port>-<version>/install/ (what scripts/package-port.sh packages).
#
#   scripts/cross-port.sh RECIPE cmake [cmake args...]
#   scripts/cross-port.sh RECIPE meson [meson args...]
#   scripts/cross-port.sh RECIPE script 'COMMANDS'   (bespoke Makefiles: COMMANDS run in the source
#                                     tree with CC, CXX, AR, RANLIB, STRIP and DEST, the install prefix
#                                     inside the staging tree, in the environment)
#   scripts/cross-port.sh RECIPE autotools [configure args...]   (autoreconf -fi first, as recipes do;
#                                                                 AUTORECONF=0 in the environment: not)
#   scripts/cross-port.sh --patches DIR RECIPE ...   (DIR/*.patch, ours, applied with -p1 after the
#                                                     recipe's patches, e.g. patches/libsdl2; and
#                                                     DIR/files/, copied into the source tree)
#
#   e.g. scripts/cross-port.sh sources/haikuports/media-libs/libsdl2/libsdl2-2.32.10.recipe cmake \
#            -DSDL_STATIC=OFF -DSDL_RPATH=OFF
#
# Build directory: artifacts/cross-ports/<port>-<version>/ (src/, source/: src/ before the build,
# build/, install/), recreated each run.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
ourPatches=""
if [ "${1:-}" = --patches ]; then
	ourPatches="$(realpath "$2")"
	shift 2
	[ -d "$ourPatches" ] || { echo "cross-port: no patch directory $ourPatches" >&2; exit 2; }
fi
[ $# -ge 2 ] || { echo "usage: $0 [--patches DIR] RECIPE cmake|meson|autotools|script [args...]" >&2; exit 2; }
recipe="$(realpath "$1")" system="$2"; shift 2
sysroot="$root/artifacts/sysroot-arm64"
prefix=/boot/system/non-packaged
[ -d "$sysroot/boot/system/develop" ] || { echo "cross-port: run scripts/haiku-sysroot.sh first" >&2; exit 1; }

name="$(basename "$recipe" .recipe)"
portDir="$(dirname "$recipe")"
field() { sed -n "s/^$1=\"\\(.*\\)\"$/\\1/p" "$recipe" | head -n 1; }
version="${name##*-}"
port="${name%-*}"
srcGitRev="$(field srcGitRev)"
homepage="$(field HOMEPAGE)"
subst() {
	sed -e "s/\\\${portVersion}/$version/g; s/\\\$portVersion/$version/g; s/\\\${portName}/$port/g" \
		-e "s/\\\$portName/$port/g; s/\\\${srcGitRev}/$srcGitRev/g; s/\\\$srcGitRev/$srcGitRev/g" \
		-e "s|\\\$HOMEPAGE|$homepage|g; s|\\\${HOMEPAGE}|$homepage|g"
}

# the fetch script names the file it got (or found)
archive="$("$root/scripts/haikuports-fetch.sh" "$recipe" | sed -n 's/^haikuports-fetch: \(.*\) ([0-9]* bytes, sha256 ok)$/\1/p' | head -n 1)"
[ -f "$archive" ] || { echo "cross-port: no source for $recipe" >&2; exit 1; }
sourceDir="$(field SOURCE_DIR | subst)"

work="$root/artifacts/cross-ports/$name"
rm -rf "$work"
mkdir -p "$work/unpack"
case "$archive" in
*.zip) unzip -q "$archive" -d "$work/unpack" ;;
*) tar -xf "$archive" -C "$work/unpack" ;;
esac
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
if [ -n "$ourPatches" ]; then
	for p in "$ourPatches"/*.patch; do
		echo "cross-port: applying $(basename "$p")"
		patch -s -p1 -d "$work/src" < "$p"
	done
	# DIR/files/: whole source files of ours, copied into the tree (e.g. patches/ffmpeg6/files)
	if [ -d "$ourPatches/files" ]; then
		echo "cross-port: adding $(cd "$ourPatches/files" && find . -type f | wc -l) files"
		cp -a "$ourPatches/files/." "$work/src/"
	fi
fi

# the patched, unbuilt sources (package-port.py --source-package)
cp -a "$work/src" "$work/source"

tools="$root/sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku"
case "$system" in
script)
	mkdir -p "$work/install$prefix"
	(cd "$work/src" && CC="$tools-gcc --sysroot=$sysroot" CXX="$tools-g++ --sysroot=$sysroot" \
		AR="$tools-ar" RANLIB="$tools-ranlib" STRIP="$tools-strip" DEST="$work/install$prefix" SYSROOT="$sysroot" \
		bash -euo pipefail -c "$1") > "$work/build.log" 2>&1 || { tail -n 30 "$work/build.log" >&2; exit 1; }
	echo "cross-port: compiler warnings: $(grep -c 'warning:' "$work/build.log" || true)"
	cp -a "$work/install/." "$sysroot/"
	echo "cross-port: $name built and installed into $sysroot$prefix and $work/install"
	exit 0
	;;
cmake)
	cmake -S "$work/src" -B "$work/build" -G Ninja \
		-DCMAKE_TOOLCHAIN_FILE="$root/tools/cmake/haiku-arm64.cmake" \
		-DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_BUILD_TYPE=Release "$@" > "$work/configure.log"
	;;
meson)
	meson setup "$work/build" "$work/src" --cross-file "$root/tools/meson/haiku-arm64.cross" \
		--prefix="$prefix" --libdir=lib --buildtype=release -Db_ndebug=true "$@" > "$work/configure.log"
	;;
autotools)
	# AUTORECONF=0 for recipes that use the shipped configure
	if [ "${AUTORECONF:-1}" != 0 ]; then
		(cd "$work/src" && autoreconf -fi) > "$work/autoreconf.log" 2>&1
	fi
	mkdir -p "$work/build"
	(cd "$work/build" && PKG_CONFIG_LIBDIR="$sysroot$prefix/develop/lib/pkgconfig:$sysroot$prefix/lib/pkgconfig:$sysroot/boot/system/develop/lib/pkgconfig" \
		PKG_CONFIG_SYSROOT_DIR="$sysroot" "$work/src/configure" --host=aarch64-unknown-haiku \
		--prefix="$prefix" CC="$tools-gcc --sysroot=$sysroot" CXX="$tools-g++ --sysroot=$sysroot" \
		AR="$tools-ar" RANLIB="$tools-ranlib" STRIP="$tools-strip" \
		CPPFLAGS="-I$sysroot$prefix/include" LDFLAGS="-L$sysroot$prefix/lib" "$@") > "$work/configure.log" 2>&1 \
		|| { tail -n 30 "$work/configure.log" >&2; exit 1; }
	;;
*) echo "cross-port: unknown build system $system" >&2; exit 2 ;;
esac
if [ "$system" = autotools ]; then
	make -C "$work/build" -j"$(nproc)" > "$work/build.log" 2>&1 || { tail -n 30 "$work/build.log" >&2; exit 1; }
else
	ninja -C "$work/build" > "$work/build.log" || { tail -n 30 "$work/build.log" >&2; exit 1; }
fi
echo "cross-port: compiler warnings: $(grep -c 'warning:' "$work/build.log" || true)"
if [ "$system" = autotools ]; then
	make -C "$work/build" install DESTDIR="$work/install" > "$work/install.log" 2>&1
	# libtool archives carry the build's paths, and nothing on Haiku needs them
	find "$work/install" -name '*.la' -delete
else
	DESTDIR="$work/install" ninja -C "$work/build" install > "$work/install.log"
fi
cp -a "$work/install/." "$sysroot/"
echo "cross-port: $name built and installed into $sysroot$prefix and $work/install"
