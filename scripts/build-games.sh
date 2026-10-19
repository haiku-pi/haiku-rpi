#!/usr/bin/env bash
# build-games.sh — cross-build SDL2 and the games on this host and stage them for the Pi image
# (mkimage-pi4.sh --add-tree artifacts/games/non-packaged). The image must come from a
# `jam -sHAIKU_PI_GL=1 @pi-mmc` build: the mesa and libsdl2 packages, libmedia/libgame.
#
#   scripts/build-games.sh [--quake-data DIR] [--quake2-data DIR]
#       DIR/id1/pak0.pak: Quake's shareware data, DIR/baseq2/pak0.pak: Quake II's demo data (not in
#       git; defaults: QUAKE_DATA and QUAKE2_DATA from local.conf or the environment)
#
#   SDL2 2.32.10   HaikuPorts recipe + patchset (scripts/cross-port.sh)
#   QuakeSpasm 0.96.3  HaikuPorts recipe's source, its Makefile (no MP3/Vorbis codecs: no
#                  libmad/libvorbis yet), into apps/QuakeSpasm with the shareware id1/pak0.pak
#   Yamagi Quake II 8.60  HaikuPorts recipe + patchset (CMake; no curl/OpenAL yet), into apps/quake2
#                  as the recipe installs it, with the demo's baseq2/pak0.pak
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
[ -f "$(dirname "$0")/../local.conf" ] && . "$(dirname "$0")/../local.conf"
quakeData="${QUAKE_DATA:-}"
quake2Data="${QUAKE2_DATA:-}"
while [ $# -gt 0 ]; do
	case "$1" in
	--quake-data) quakeData="$2"; shift 2 ;;
	--quake2-data) quake2Data="$2"; shift 2 ;;
	*) echo "build-games: unknown option $1" >&2; exit 2 ;;
	esac
done
[ -f "$quakeData/id1/pak0.pak" ] && [ -f "$quake2Data/baseq2/pak0.pak" ] \
	|| { echo "build-games: no game data (--quake-data/--quake2-data or QUAKE_DATA/QUAKE2_DATA)" >&2; exit 2; }
tools="$root/sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku"
sysroot="$root/artifacts/sysroot-arm64"
np="$sysroot/boot/system/non-packaged"
ports="$root/sources/haikuports"
stage="$root/artifacts/games/non-packaged"

# SDL2 links libmedia and libgame, which the minimum image's haiku_devel does not have
objects="$root/sources/haiku/generated.arm64/objects/haiku/arm64/release/kits"
for l in game/libgame.so media/libmedia.so; do
	[ -f "$objects/$l" ] || { echo "build-games: $objects/$l missing (jam -sHAIKU_PI_GL=1 build)" >&2; exit 1; }
	cp "$objects/$l" "$sysroot/boot/system/develop/lib/"
done

"$root/scripts/cross-port.sh" "$ports/media-libs/libsdl2/libsdl2-2.32.10.recipe" cmake \
	-DSDL_STATIC=OFF -DSDL_RPATH=OFF -DSDL_TEST=OFF

recipe="$ports/games-fps/quakespasm/quakespasm-0.96.3.recipe"
"$root/scripts/haikuports-fetch.sh" "$recipe" >/dev/null
work="$root/artifacts/cross-ports/quakespasm-0.96.3"
rm -rf "$work"
mkdir -p "$work"
tar -xf "$ports/games-fps/quakespasm/download/quakespasm-0.96.3.tar.gz" -C "$work"
quake="$work/quakespasm-quakespasm-0.96.3/Quake"
make -C "$quake" -j"$(nproc)" HOST_OS=haiku CC="$tools-gcc --sysroot=$sysroot" STRIP="$tools-strip" \
	SDL_CONFIG="$np/bin/sdl2-config" USE_SDL2=1 USE_CODEC_MP3=0 USE_CODEC_VORBIS=0 DO_USERDIRS=1 \
	> "$work/build.log" 2>&1 || { tail -n 20 "$work/build.log" >&2; exit 1; }
echo "build-games: quakespasm built, $(grep -c 'warning:' "$work/build.log" || true) compiler warnings"

rm -rf "$stage"
mkdir -p "$stage/apps/QuakeSpasm/id1"
# SDL2 itself is a package (libsdl2, scripts/build-packages.sh) in the pi-mmc image
cp "$quake/quakespasm" "$quake/quakespasm.pak" "$stage/apps/QuakeSpasm/"
cp "$quakeData/id1/pak0.pak" "$stage/apps/QuakeSpasm/id1/"
# Quake II: the recipe's CMake build has no install target; its INSTALL() copies the binaries
"$root/scripts/cross-port.sh" "$ports/games-fps/yamagi-quake2/yamagi_quake2-8.60.recipe" script '
cmake -S . -B build -G Ninja -DCMAKE_TOOLCHAIN_FILE="$SYSROOT/../../tools/cmake/haiku-arm64.cmake" \
	-DCMAKE_BUILD_TYPE=Release -DCURL_SUPPORT=OFF -DOPENAL_SUPPORT=OFF \
	-DSDL2_INCLUDE_DIR="$SYSROOT/boot/system/non-packaged/include/SDL2"
ninja -C build
mkdir -p "$DEST/apps/quake2/baseq2"
cp build/release/quake2 "$DEST/apps/quake2/Quake2"
cp build/release/q2ded "$DEST/apps/quake2/Quake2_dedicated"
cp build/release/*.so "$DEST/apps/quake2/"
cp build/release/baseq2/game.so "$DEST/apps/quake2/baseq2/"'
cp -r "$root/artifacts/cross-ports/yamagi_quake2-8.60/install/boot/system/non-packaged/apps/quake2" \
	"$stage/apps/"
"$tools-strip" "$stage/apps/quake2/Quake2" "$stage/apps/quake2/Quake2_dedicated" \
	"$stage"/apps/quake2/*.so "$stage/apps/quake2/baseq2/game.so"
cp "$quake2Data/baseq2/pak0.pak" "$stage/apps/quake2/baseq2/"

find "$stage" -type f -printf 'build-games: %P %s\n' | sort
