#!/usr/bin/env bash
# build-vkquake.sh — cross-build vkQuake (Quake on Vulkan; HaikuPorts has no recipe) on this host and
# stage it for the Pi image: artifacts/games/non-packaged/apps/vkQuake/{vkquake,id1/pak0.pak}
# (mkimage-pi4.sh --add-tree artifacts/games/non-packaged; scripts/build-games.sh calls this).
#
#   scripts/build-vkquake.sh [--quake-data DIR]
#       DIR/id1/pak0.pak: Quake's shareware data (default: QUAKE_DATA from local.conf or the environment)
#
#   vkQuake 1.35.0  the upstream release (github.com/Novum/vkQuake), its meson build with
#                   tools/meson/haiku-arm64.cross, SDL2 (needs scripts/build-games.sh's Vulkan-enabled
#                   SDL2 in the sysroot), the Khronos loader + headers 1.4.311 of scripts/build-gl-stack.sh
#                   (1.36 and later need headers >= 1.4.341), shaders compiled on the host
#                   (glslangValidator, spirv-opt with --canonicalize-ids); no music codecs (none ported);
#                   our patches/vkquake/*.patch (Haiku platform support, shareware + commands).
#
# Build directory: artifacts/cross-ports/vkquake-<version>/ (src/, build/, install/ with the
# unstripped binary for addr2line), recreated each run.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
[ -f "$root/local.conf" ] && . "$root/local.conf"
quakeData="${QUAKE_DATA:-}"
while [ $# -gt 0 ]; do
	case "$1" in
	--quake-data) quakeData="$2"; shift 2 ;;
	*) echo "build-vkquake: unknown option $1" >&2; exit 2 ;;
	esac
done
[ -f "$quakeData/id1/pak0.pak" ] \
	|| { echo "build-vkquake: no game data (--quake-data or QUAKE_DATA)" >&2; exit 2; }

version=1.35.0
sha256=9f3a2bbf7ef22224c26a1a0d574562573fdaae2dc9758a98068617062d49c584
tools="$root/sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku"
sysroot="$root/artifacts/sysroot-arm64"
dl="$root/artifacts/cross-ports/dl"
work="$root/artifacts/cross-ports/vkquake-$version"
stage="$root/artifacts/games/non-packaged/apps/vkQuake"

# SDL2 without Vulkan would build, and fail at run time ("No Vulkan support in video driver")
grep -q '^#define SDL_VIDEO_VULKAN 1' \
	"$sysroot/boot/system/non-packaged/include/SDL2/SDL_config.h" 2>/dev/null \
	|| { echo "build-vkquake: the sysroot's SDL2 has no Vulkan (scripts/build-games.sh builds it)" >&2; exit 1; }
for p in glslangValidator spirv-opt meson ninja; do
	command -v "$p" > /dev/null || { echo "build-vkquake: $p missing on this host" >&2; exit 1; }
done

archive="$dl/vkQuake-$version.tar.gz"
mkdir -p "$dl"
[ -f "$archive" ] || curl -sSfL -o "$archive" "https://github.com/Novum/vkQuake/archive/refs/tags/$version.tar.gz"
echo "$sha256  $archive" | sha256sum -c --quiet

rm -rf "$work"
mkdir -p "$work/unpack"
tar -xzf "$archive" -C "$work/unpack"
mv "$work/unpack/vkQuake-$version" "$work/src"
rmdir "$work/unpack"
for p in "$root"/patches/vkquake/*.patch; do
	echo "build-vkquake: applying $(basename "$p")"
	patch -s -p1 -d "$work/src" < "$p"
done

meson setup "$work/build" "$work/src" --cross-file "$root/tools/meson/haiku-arm64.cross" \
	--prefix=/boot/system/non-packaged --buildtype=release -Duse_sdl3=disabled -Ddo_userdirs=enabled \
	-Duse_codec_mp3=disabled -Duse_codec_flac=disabled -Duse_codec_vorbis=disabled \
	-Duse_codec_opus=disabled > "$work/configure.log" 2>&1 \
	|| { tail -n 30 "$work/configure.log" >&2; exit 1; }
ninja -C "$work/build" > "$work/build.log" 2>&1 || { grep -E 'error|FAILED' "$work/build.log" | head -n 30 >&2; exit 1; }
echo "build-vkquake: compiler warnings: $(grep -c 'warning:' "$work/build.log" || true)"
# the install drops the build tree's rpath (the sysroot's lib directory)
DESTDIR="$work/install" meson install -C "$work/build" --no-rebuild > "$work/install.log"
binary="$work/install/boot/system/non-packaged/bin/vkquake"
if "$tools-readelf" -d "$binary" | grep -q -E 'RPATH|RUNPATH'; then
	echo "build-vkquake: $binary still has a run path" >&2
	exit 1
fi

rm -rf "$stage"
mkdir -p "$stage/id1"
cp "$binary" "$stage/vkquake"
"$tools-strip" "$stage/vkquake"
cp "$quakeData/id1/pak0.pak" "$stage/id1/"
echo "build-vkquake: vkQuake $version staged in $stage ($(du -sh "$stage" | cut -f1))"
