#!/usr/bin/env bash
# build-packages.sh — (re)build every package of ours that sources/haiku's arm64 repository definition
# lists, and stage them with the "any" packages in jam's download directory, so that
# `scripts/build.sh -sHAIKU_PI_GL=1 @pi-mmc` (or @minimum-mmc) finds them all:
#
#   mesa, mesa_devel, glu, glu_devel       scripts/build-gl-stack.sh + scripts/package-gl-stack.sh
#   libogg, libvorbis, fluidlite (+_devel) scripts/cross-port.sh + scripts/package-port.py
#   libsdl2                                scripts/cross-port.sh + scripts/package-port.py
#   ffmpeg6                                scripts/build-ffmpeg.sh
#   zstd (+ zstd_source)                   scripts/cross-port.sh + scripts/package-port.py
#   gzip, tar, bzip2, unzip                scripts/build-base-ports.sh
#   netsurf + OpenSSL 3, curl, ...         scripts/build-netsurf.sh
#   haikuwebkit + libxml2, sqlite, ...     scripts/build-webkit.sh (several hours)
#   python3.14 (+_devel)                   scripts/build-python.sh (after OpenSSL and sqlite)
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

# SDL2 (the games) and ffmpeg link libmedia and libgame, which the sysroot's haiku_devel (from the
# minimum build) does not have: the libraries jam built (as scripts/build-games.sh does)
objects="$root/sources/haiku/generated.arm64/objects/haiku/arm64/release/kits"
for l in game/libgame.so media/libmedia.so; do
	cp "$objects/$l" "$root/artifacts/sysroot-arm64/boot/system/develop/lib/"
done
# with patches/libsdl2 (Vulkan windows through Mesa's Haiku WSI); revision 2 = with that patch
"$root/scripts/cross-port.sh" --patches "$root/patches/libsdl2" \
	"$ports/media-libs/libsdl2/libsdl2-2.32.10.recipe" cmake \
	-DSDL_STATIC=OFF -DSDL_RPATH=OFF -DSDL_TEST=OFF -DSDL_VULKAN=ON
"$root/scripts/package-port.py" "$ports/media-libs/libsdl2/libsdl2-2.32.10.recipe" \
	--revision 2 --devel-bin sdl2-config

# ffmpeg (the media kit's ffmpeg plugin, MediaPlayer), with HEVC on the Pi 4's decoder block
"$root/scripts/build-ffmpeg.sh"

# zstd: the packages from Haiku's servers are zstd-compressed, and packagefs and the package kit
# read them only with jam's zstd feature (zstd_devel + zstd_source: packagefs compiles the decoder)
"$root/scripts/cross-port.sh" "$ports/app-arch/zstd/zstd-1.5.7.recipe" script '
make -j"$(nproc)" CC="$CC" AR="$AR" RANLIB="$RANLIB" prefix=/boot/system/non-packaged lib-release \
	zstd-release
make CC="$CC" AR="$AR" RANLIB="$RANLIB" prefix=/boot/system/non-packaged \
	DESTDIR="${DEST%/boot/system/non-packaged}" install
rm -f "$DEST"/lib/libzstd.a
rm -rf "$DEST/share"'
"$root/scripts/package-port.py" "$ports/app-arch/zstd/zstd-1.5.7.recipe" --source-package

"$root/scripts/build-base-ports.sh"
"$root/scripts/build-netsurf.sh"
"$root/scripts/build-webkit.sh"
"$root/scripts/build-python.sh"
"$root/scripts/fetch-any-packages.sh"
"$root/scripts/make-icu-shim.sh"

mkdir -p "$download"
cp "$root"/artifacts/packages/*.hpkg "$download/"
echo "build-packages: staged $(ls "$root"/artifacts/packages/*.hpkg | wc -l) packages in $download"
