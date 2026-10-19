#!/usr/bin/env bash
# cross-port.sh — cross-build a HaikuPorts port on this host (package farm plan §3.1, the fast path
# while native haikuporter builds come up): the recipe's source (scripts/haikuports-fetch.sh), its
# patches applied, configured with tools/cmake/haiku-arm64.cmake or tools/meson/haiku-arm64.cross,
# built, and installed into the sysroot's non-packaged/ (where later ports find it) and into
# artifacts/cross-ports/<port>-<version>/install/ (what scripts/package-port.sh packages).
#
#   scripts/cross-port.sh RECIPE cmake [cmake args...]
#   scripts/cross-port.sh RECIPE meson [meson args...]
#   scripts/cross-port.sh RECIPE autotools [configure args...]   (autoreconf -fi first, as recipes do)
#
#   e.g. scripts/cross-port.sh sources/haikuports/media-libs/libsdl2/libsdl2-2.32.10.recipe cmake \
#            -DSDL_STATIC=OFF -DSDL_RPATH=OFF
#
# Build directory: artifacts/cross-ports/<port>-<version>/ (src/, build/, install/), recreated each run.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -ge 2 ] || { echo "usage: $0 RECIPE cmake|meson|autotools [args...]" >&2; exit 2; }
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
autotools)
	tools="$root/sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku"
	(cd "$work/src" && autoreconf -fi) > "$work/autoreconf.log" 2>&1
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
