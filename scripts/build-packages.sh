#!/usr/bin/env bash
# build-packages.sh — (re)build every package of ours that sources/haiku's arm64 repository definition
# lists, and stage them with the "any" packages in jam's download directory, so that
# `scripts/build.sh -sHAIKU_PI_GL=1 @pi-mmc` (or @minimum-mmc) finds them all:
#
#   mesa, mesa_devel, glu, glu_devel       scripts/build-gl-stack.sh + scripts/package-gl-stack.sh
#   libogg, libvorbis, fluidlite (+_devel) scripts/cross-port.sh + scripts/package-port.py
#   libsdl2                                scripts/cross-port.sh + scripts/package-port.py
#   gzip, tar, bzip2, unzip                scripts/build-base-ports.sh
#   fonts, sounds, firmware, user guide    scripts/fetch-any-packages.sh (x86_64 repository)
#
#   scripts/build-packages.sh [--sysroot]   (--sysroot: recreate the sysroot first)
#
# Needs a jam build of the tree (the cross compiler, haiku_devel.hpkg, the host package tool).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
ports="$root/sources/haikuports"
download="$root/sources/haiku/generated.arm64/download"
if [ "${1:-}" = --sysroot ]; then
	"$root/scripts/haiku-sysroot.sh"
fi

"$root/scripts/build-gl-stack.sh"
"$root/scripts/package-gl-stack.sh"

"$root/scripts/cross-port.sh" "$ports/media-libs/libogg/libogg-1.3.6.recipe" cmake \
	-DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF -DINSTALL_DOCS=OFF
"$root/scripts/package-port.py" "$ports/media-libs/libogg/libogg-1.3.6.recipe"
# autotools: libvorbis' CMake build gives the libraries their full version as soname
"$root/scripts/cross-port.sh" "$ports/media-libs/libvorbis/libvorbis-1.3.7.recipe" autotools \
	--disable-static
"$root/scripts/package-port.py" "$ports/media-libs/libvorbis/libvorbis-1.3.7.recipe"
"$root/scripts/cross-port.sh" "$ports/media-sound/fluidlite/fluidlite-1.0.9.recipe" cmake \
	-DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DENABLE_SF3=YES -DSTB_VORBIS=NO
# jam's fluidlite build feature links the static library as libfluidlite-static.a
"$root/scripts/package-port.py" "$ports/media-sound/fluidlite/fluidlite-1.0.9.recipe" \
	--static-suffix=-static

# SDL2 (the games): links libmedia/libgame, which haiku_devel has only in the regular build type
"$root/scripts/cross-port.sh" "$ports/media-libs/libsdl2/libsdl2-2.32.10.recipe" cmake \
	-DSDL_STATIC=OFF -DSDL_RPATH=OFF -DSDL_TEST=OFF
"$root/scripts/package-port.py" "$ports/media-libs/libsdl2/libsdl2-2.32.10.recipe" \
	--devel-bin sdl2-config

"$root/scripts/build-base-ports.sh"
"$root/scripts/fetch-any-packages.sh"

mkdir -p "$download"
cp "$root"/artifacts/packages/*.hpkg "$download/"
echo "build-packages: staged $(ls "$root"/artifacts/packages/*.hpkg | wc -l) packages in $download"
