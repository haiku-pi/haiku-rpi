#!/usr/bin/env bash
# build-stk.sh — cross-build SuperTuxKart 1.5 (3D kart racing) on this host and stage it, with the
# mobile-sized data of the official 1.5 release, as its own tree for the Pi image:
#
#   artifacts/stk/non-packaged/apps/SuperTuxKart/
#       SuperTuxKart      the game (one executable; stripped)
#       data/             the game data (the release's Android data set: ~180 MB; see below)
#   (mkimage-pi4.sh --add-tree artifacts/stk/non-packaged; tools/pi-tests/supertuxkart.sh runs it)
#
#   scripts/build-stk.sh [--no-data]   (--no-data: the executable only, the staged data stays)
#
#   SuperTuxKart 1.5  the release's source tarball (HaikuPorts' supertuxkart-1.5 recipe pins the same
#                file), its CMake build with tools/cmake/haiku-arm64.cmake and the recipe's options
#                (no recorder, no Wiimote), plus:
#                - desktop OpenGL (-DUSE_GLES2=OFF; STK's default on aarch64 is its GLES build): SDL2 on
#                  Haiku makes every GL context through BGLView (libglvnd's HGL), which asks EGL for
#                  a compatibility context without a version and ignores SDL's ES/core/version
#                  attributes. On V3D that context is OpenGL 2.1, so Irrlicht's 4.3/3.3/3.1 core
#                  attempts fail and STK runs its legacy (fixed-function) renderer — the GL path
#                  ioquake3 already runs on this stack. A GLES build would get the same 2.1
#                  context, not the ES 3 one its shader renderer needs.
#                - no Vulkan renderer (-DNO_SHADERC=ON: no shaderc port)
#                - sound through STK's bundled MojoAL (OpenAL 1.1 on SDL2 audio, -DUSE_MOJOAL=ON):
#                  openal-soft has no Haiku backend; MojoAL needs libsamplerate
#                - its bundled libraries: Irrlicht, Bullet, AngelScript, ENet (IPv6), mcpp,
#                  libsquish, SheenBidi, tinygettext
#                - from the image's packages: SDL2 (libsdl2), libGL (mesa), libpng16, libjpeg_turbo,
#                  libogg/libvorbis, curl, openssl3 (libcrypto), sqlite, zlib
#   linked in statically (built here from their HaikuPorts recipes' sources, into the work directory,
#   not the sysroot):
#     FreeType 2.14.3   with PNG (the colour emoji font) and zlib; the image has only the bootstrap
#                       freetype 2.6.3 (app_server's) and its sysroot has no freetype headers. A newer
#                       libfreetype.so.6 in non-packaged/lib would replace app_server's for every
#                       program, so it goes into the game
#     HarfBuzz 14.5.1   (+ the recipe's patchset) with FreeType; no package of it exists for arm64
#     libsamplerate 0.2.2 (+ the recipe's patchset)
#   Data: the official SuperTuxKart-1.5.apk's assets/data/ — the same 1.5 data set the release's
#   Android build runs, with textures reduced and recompressed (209 MB against the source tarball's
#   776 MB; all 18 karts and 44 tracks/arenas) — without the ghost replays in replay/ but the one
#   --benchmark plays (po/, the translations, must stay: STK stops without it). The source tarball's
#   own data/ is not used.
#
# Downloads (pinned by sha256): artifacts/downloads/supertuxkart/; the dependencies' sources go to
# their recipes' download/ directories (scripts/haikuports-fetch.sh). Build directory:
# artifacts/cross-ports/supertuxkart-1.5/ (src/, deps/ with the static libraries, build/, install/
# with the unstripped executable for addr2line), recreated each run. The compile runs under
# scripts/heavy-build.sh.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
data=1
argv=("$@")
while [ $# -gt 0 ]; do
	case "$1" in
	--no-data) data=0; shift ;;
	*) echo "build-stk: unknown option $1" >&2; exit 2 ;;
	esac
done

version=1.5
srcUrl="https://github.com/supertuxkart/stk-code/releases/download/$version/SuperTuxKart-$version-src.tar.gz"
srcSha256=33cf8841e4ff4082d80b9248014295bbbea61d14683e86dff100e3ab8f7b27cb
apkUrl="https://github.com/supertuxkart/stk-code/releases/download/$version/SuperTuxKart-$version.apk"
apkSha256=e1f2f49152abfb8f3ed0ced47981e84096758bff9758563aa3b917111a2a3cbd
tools="$root/sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku"
toolchain="$root/tools/cmake/haiku-arm64.cmake"
sysroot="$root/artifacts/sysroot-arm64"
ports="$root/sources/haikuports"
dl="$root/artifacts/downloads/supertuxkart"
work="$root/artifacts/cross-ports/supertuxkart-$version"
deps="$work/deps"
app="$root/artifacts/stk/non-packaged/apps/SuperTuxKart"

[ -f "$sysroot/boot/system/non-packaged/include/SDL2/SDL.h" ] \
	|| { echo "build-stk: no SDL2 in the sysroot (scripts/build-games.sh builds it)" >&2; exit 1; }
for p in cmake ninja unzip; do
	command -v "$p" > /dev/null || { echo "build-stk: $p missing on this host" >&2; exit 1; }
done

# fetch FILE URL SHA256
fetch() {
	mkdir -p "$dl"
	[ -f "$dl/$1" ] || { curl -sSfL -o "$dl/$1.part" "$2" && mv "$dl/$1.part" "$dl/$1"; }
	echo "$3  $dl/$1" | sha256sum -c --quiet
}
# the whole build under the heavy-build guard (one wait for the lock, one memory-capped scope), unless
# a caller already holds it (the lock is not re-entrant)
if [ "${HEAVY_BUILD_LOCKED:-0}" != 1 ]; then
	exec "$root/scripts/heavy-build.sh" --mem-per-job 1 -- "$0" ${argv[@]+"${argv[@]}"}
fi
fetch "SuperTuxKart-$version-src.tar.gz" "$srcUrl" "$srcSha256"
[ "$data" = 1 ] && fetch "SuperTuxKart-$version.apk" "$apkUrl" "$apkSha256"

# ninja_build DIR [TARGET...]
ninja_build() {
	local dir="$1" log="$1/build.log"
	shift
	ninja -C "$dir" -j "${HEAVY_BUILD_JOBS:-$(nproc)}" "$@" > "$log" 2>&1 \
		|| { grep -E 'error|FAILED' "$log" | head -n 30 >&2; exit 1; }
	echo "build-stk: $(basename "$dir"): $(grep -c 'warning:' "$log" || true) compiler warnings"
}

# dep RECIPE [PATCHSET...]: the recipe's source, unpacked into $work/deps-src/<port>, with the named
# patchsets of the recipe applied; prints the source directory
dep() {
	local recipe="$ports/$1" archive name src
	shift
	archive="$("$root/scripts/haikuports-fetch.sh" "$recipe" \
		| sed -n 's/^haikuports-fetch: \(.*\) ([0-9]* bytes, sha256 ok)$/\1/p' | head -n 1)"
	[ -f "$archive" ] || { echo "build-stk: no source for $recipe" >&2; exit 1; }
	name="$(basename "$recipe" .recipe)"
	src="$work/deps-src/$name"
	mkdir -p "$src"
	tar -xf "$archive" -C "$src" --strip-components=1
	for p in "$@"; do
		patch -s -p1 -d "$src" < "$(dirname "$recipe")/patches/$p" >&2
	done
	echo "$src"
}

# cmake_dep SRC [ARGS...]: a static library into $deps
cmake_dep() {
	local src="$1" build
	shift
	build="$work/deps-build/$(basename "$src")"
	mkdir -p "$build"
	cmake -S "$src" -B "$build" -G Ninja -DCMAKE_TOOLCHAIN_FILE="$toolchain" -DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX="$deps" -DBUILD_SHARED_LIBS=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 "$@" \
		> "$build/configure.log" 2>&1 || { tail -n 30 "$build/configure.log" >&2; exit 1; }
	ninja_build "$build"
	ninja -C "$build" install > "$build/install.log"
}

rm -rf "$work"
mkdir -p "$work/unpack" "$deps"

src="$(dep media-libs/freetype/freetype-2.14.3.recipe)"
cmake_dep "$src" -DFT_REQUIRE_PNG=ON -DFT_REQUIRE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_BROTLI=ON \
	-DFT_DISABLE_HARFBUZZ=ON
ft="$deps/lib/libfreetype.a"
# static FreeType: its users also link what it needs
ftLibs="$ft;png16;z"
src="$(dep media-libs/harfbuzz/harfbuzz-14.5.1.recipe harfbuzz-14.5.1.patchset)"
cmake_dep "$src" -DHB_HAVE_FREETYPE=ON -DFREETYPE_LIBRARY="$ftLibs" \
	-DFREETYPE_INCLUDE_DIR_ft2build="$deps/include/freetype2" \
	-DFREETYPE_INCLUDE_DIR_freetype2="$deps/include/freetype2" \
	-DHB_BUILD_SUBSET=OFF -DHB_BUILD_RASTER=OFF -DHB_BUILD_VECTOR=OFF -DHB_BUILD_GPU=OFF \
	-DHB_BUILD_UTILS=OFF -DHB_HAVE_GLIB=OFF -DHB_HAVE_ICU=OFF -DHB_HAVE_GOBJECT=OFF
src="$(dep media-libs/libsamplerate/libsamplerate-0.2.2.recipe libsamplerate-0.2.2.patchset)"
cmake_dep "$src" -DBUILD_TESTING=OFF -DLIBSAMPLERATE_EXAMPLES=OFF -DLIBSAMPLERATE_INSTALL=ON
for l in freetype harfbuzz samplerate; do
	[ -f "$deps/lib/lib$l.a" ] || { echo "build-stk: $deps/lib/lib$l.a missing" >&2; exit 1; }
done

# the source tarball carries the full data (776 MB); the build needs none of it
tar -xzf "$dl/SuperTuxKart-$version-src.tar.gz" -C "$work/unpack" --exclude="SuperTuxKart-$version-src/data/*"
mv "$work/unpack/SuperTuxKart-$version-src" "$work/src"
rmdir "$work/unpack"
mkdir -p "$work/src/data"
for p in "$root"/patches/supertuxkart/*.patch; do
	[ -f "$p" ] || continue
	echo "build-stk: applying $(basename "$p")"
	patch -s -p1 -d "$work/src" < "$p"
done

# -lgcc_s: the cross g++ links executables with the static libgcc only, so crtbeginS registers the
# program's unwind tables with a private copy of the unwinder, and the one libstdc++'s __cxa_throw uses
# never sees them: every C++ exception ends in terminate() (even `throw 42` caught in main; checked in
# QEMU). With libgcc_s.so.1 linked, the program and libstdc++ share one unwinder. STK throws in its
# normal flow (a missing config.xml on the first start).
# FREETYPE_*: patches/supertuxkart/0001 (STK's FindFreetype asks pkg-config otherwise, and the sysroot
# may have a shared libfreetype that the image does not). HARFBUZZ_LIBRARY carries FreeType again: STK
# lists FreeType before HarfBuzz on its link line
cmake -S "$work/src" -B "$work/build" -G Ninja -DCMAKE_TOOLCHAIN_FILE="$toolchain" \
	-DCMAKE_BUILD_TYPE=STKRelease -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
	-DUSE_GLES2=OFF -DNO_SHADERC=ON -DBUILD_RECORDER=OFF -DUSE_WIIUSE=OFF -DCHECK_ASSETS=OFF \
	-DBUILD_SHARED_LIBS=OFF -DUSE_MOJOAL=ON -DCMAKE_CXX_STANDARD_LIBRARIES="-Wl,--no-as-needed -lgcc_s" \
	-DLIBSAMPLERATE_LIBRARY="$deps/lib/libsamplerate.a" -DLIBSAMPLERATE_INCLUDEDIR="$deps/include" \
	-DFREETYPE_LIBRARIES="$ftLibs" -DFREETYPE_INCLUDE_DIRS="$deps/include/freetype2" \
	-DHARFBUZZ_LIBRARY="$deps/lib/libharfbuzz.a;$ftLibs" -DHARFBUZZ_INCLUDEDIR="$deps/include" \
	> "$work/configure.log" 2>&1 || { tail -n 30 "$work/configure.log" >&2; exit 1; }
grep -q -- "-DUSE_GLES2" "$work/build/build.ninja" \
	&& { echo "build-stk: configured as the GLES build" >&2; exit 1; }
ninja_build "$work/build" supertuxkart

mkdir -p "$work/install"
cp "$work/build/bin/supertuxkart" "$work/install/SuperTuxKart"
if "$tools-readelf" -d "$work/install/SuperTuxKart" | grep -q -E 'RPATH|RUNPATH'; then
	echo "build-stk: the executable has a run path" >&2
	exit 1
fi
needed="$("$tools-readelf" -d "$work/install/SuperTuxKart" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | tr '\n' ' ')"
echo "build-stk: needs $needed"
case " $needed " in
*" libgcc_s.so.1 "*) ;;
*) echo "build-stk: libgcc_s.so.1 not linked: C++ exceptions would not work" >&2; exit 1 ;;
esac
if "$tools-nm" "$work/install/SuperTuxKart" | grep -q ' t __register_frame_info$'; then
	echo "build-stk: the executable has its own copy of the unwinder" >&2
	exit 1
fi
case " $needed" in
*" libfreetype"*|*" libharfbuzz"*|*" libsamplerate"*)
	echo "build-stk: linked a shared library that is meant to be static" >&2; exit 1 ;;
esac

mkdir -p "$app"
cp "$work/install/SuperTuxKart" "$app/"
"$tools-strip" "$app/SuperTuxKart"
if [ "$data" = 1 ]; then
	rm -rf "$app/data" "$work/apk"
	# --benchmark replays benchmark_black_forest.replay
	unzip -q "$dl/SuperTuxKart-$version.apk" 'assets/data/*' -x 'assets/data/replay/*' \
		-d "$work/apk"
	unzip -q "$dl/SuperTuxKart-$version.apk" assets/data/replay/benchmark_black_forest.replay -d "$work/apk"
	mv "$work/apk/assets/data" "$app/data"
	rm -rf "$work/apk"
	[ -f "$app/data/supertuxkart.$version" ] \
		|| { echo "build-stk: data/supertuxkart.$version missing" >&2; exit 1; }
	cp "$work/src/COPYING" "$app/"
	echo "build-stk: data: $(ls "$app/data/karts" | wc -l) karts, $(ls "$app/data/tracks" | wc -l) tracks"
fi
echo "build-stk: SuperTuxKart $version staged in $app ($(du -sh "$app" | cut -f1); $(find "$app" -type f | wc -l) files)"
