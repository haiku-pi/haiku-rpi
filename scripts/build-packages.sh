#!/usr/bin/env bash
# build-packages.sh — (re)build every package of ours that sources/haiku's arm64 repository definition
# lists, and stage them with the "any" packages in jam's download directory, so that
# `scripts/build.sh -sHAIKU_PI_GL=1 @pi-mmc` (or @minimum-mmc) finds them all:
#
#   mesa, mesa_devel, glu, glu_devel       scripts/build-gl-stack.sh + scripts/package-gl-stack.sh
#   libogg, libvorbis, fluidlite (+_devel) scripts/cross-port.sh + scripts/package-port.py
#   libsdl2, ffmpeg6                       scripts/cross-port.sh + scripts/package-port.py
#   zstd (+ zstd_source)                   scripts/cross-port.sh + scripts/package-port.py
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

# SDL2 (the games) and ffmpeg link libmedia and libgame, which the sysroot's haiku_devel (from the
# minimum build) does not have: the libraries jam built (as scripts/build-games.sh does)
objects="$root/sources/haiku/generated.arm64/objects/haiku/arm64/release/kits"
for l in game/libgame.so media/libmedia.so; do
	cp "$objects/$l" "$root/artifacts/sysroot-arm64/boot/system/develop/lib/"
done
"$root/scripts/cross-port.sh" "$ports/media-libs/libsdl2/libsdl2-2.32.10.recipe" cmake \
	-DSDL_STATIC=OFF -DSDL_RPATH=OFF -DSDL_TEST=OFF
"$root/scripts/package-port.py" "$ports/media-libs/libsdl2/libsdl2-2.32.10.recipe" \
	--devel-bin sdl2-config

# ffmpeg (the media kit's ffmpeg plugin, MediaPlayer): its own decoders + libvorbis; the recipe's other
# external libraries (lame, opus, speex, theora, openssl, ...) are not ported yet
"$root/scripts/cross-port.sh" "$ports/media-video/ffmpeg/ffmpeg6-6.1.6.recipe" script '
./configure --enable-cross-compile --target-os=haiku --arch=aarch64 \
	--cc="$CC" --cxx="$CXX" --ar="$AR" --ranlib="$RANLIB" --strip="$STRIP" --pkg-config=pkg-config \
	--prefix=/boot/system/non-packaged --disable-debug --disable-stripping --disable-static \
	--enable-shared --enable-version3 --enable-pic --enable-libvorbis --disable-ffplay \
	--disable-doc --extra-cflags="-I$SYSROOT/boot/system/non-packaged/include" \
	--extra-ldflags="-L$SYSROOT/boot/system/non-packaged/lib"
make -j"$(nproc)"
make install DESTDIR="${DEST%/boot/system/non-packaged}"'
"$root/scripts/package-port.py" "$ports/media-video/ffmpeg/ffmpeg6-6.1.6.recipe"

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
"$root/scripts/fetch-any-packages.sh"

mkdir -p "$download"
cp "$root"/artifacts/packages/*.hpkg "$download/"
echo "build-packages: staged $(ls "$root"/artifacts/packages/*.hpkg | wc -l) packages in $download"
