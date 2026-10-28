#!/usr/bin/env bash
# games-bench-image.sh — an SD image for tools/pi-tests/games-bench.sh (the games' frame rates): a base
# image (a release image or a Pi image made by mkimage-pi4.sh) plus the same game trees, test programs and
# packages every time, so that two systems (before/after a change) are compared on the same games.
#
#   scripts/games-bench-image.sh BASE OUT [--remove PATH]... [FILE:PATH]...
#
#   # before/after the GL present work of 10-25 (mesa -3 vs the release 25e system with mesa -7):
#   scripts/games-bench-image.sh artifacts/images/haiku-pi4-2026-10-25b.img artifacts/images/gb-before.img
#   scripts/games-bench-image.sh artifacts/images/haiku-pi4-2026-10-25e.img artifacts/images/gb-after.img \
#       --remove /boot/system/packages/mesa-26.2.5-6-arm64.hpkg \
#       --remove /boot/system/packages/mesa_devel-26.2.5-6-arm64.hpkg \
#       artifacts/packages/mesa-26.2.5-7-arm64.hpkg:/boot/system/packages/mesa-26.2.5-7-arm64.hpkg \
#       artifacts/packages/mesa_devel-26.2.5-7-arm64.hpkg:/boot/system/packages/mesa_devel-26.2.5-7-arm64.hpkg
#
# What goes in (to /boot/system/non-packaged): artifacts/games/non-packaged (QuakeSpasm, vkQuake, Yamagi
# Quake II, the Quake III demo, OpenArena on ioquake3, their libSDL2), the Wine test programs gltest, d3dtest
# and input.exe (from the Wine build's test tree, never the Wine there: that would shadow the packages), and
# Half-Life Uplink's installed tree (artifacts/wine-games). Not the GL stack's test tree: its lib/ and
# add-ons/ would shadow the packaged Mesa and both images would run the same GL driver.
# To /boot/system/packages: Wine (wine, wine_data, wine_directx, wine_x86, wine_x86_64, wine_mono) and what
# it needs that a release image lacks (wayland, wayland_server, libxkbcommon, xkeyboard_config), and
# SuperTuxKart — the newest of each in artifacts/packages. The UserBootscript is games-bench.sh.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -ge 2 ] || { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
base="$(realpath "$1")" out="$(realpath -m "$2")"; shift 2
stage="$root/artifacts/games-bench/np"
rm -rf "$stage"
mkdir -p "$stage/data/wine-tests" "$stage/data/wine-games"
cp -a "$root/artifacts/games/non-packaged/." "$stage/"
for t in gltest-arm64 gltest-x86 d3dtest-arm64 d3dtest-x86 input; do
	cp -a "$root/artifacts/wine-11.20/install/boot/system/non-packaged/data/wine-tests/$t.exe" "$stage/data/wine-tests/"
done
cp -a "$root/artifacts/wine-games/tree/data/wine-games/HL" "$stage/data/wine-games/"
rm -f "$stage/data/wine-games/HL/valve/qconsole.log"
# nothing in the stage may stand in for the system's GL/Vulkan libraries
if find "$stage" -name 'lib*.so*' | grep -E 'lib(EGL|GL|GLES|GLdispatch|OpenGL|vulkan|drm)'; then
	echo "games-bench-image: the stage has GL libraries (above)" >&2; exit 1
fi

pkgs=()
for name in wine wine_data wine_directx wine_x86 wine_x86_64 wine_mono wayland wayland_server libxkbcommon \
		xkeyboard_config supertuxkart supertuxkart_data_1 supertuxkart_data_2 supertuxkart_data_3; do
	f=$(ls "$root"/artifacts/packages/"$name"-[0-9]*.hpkg | sort -V | tail -n 1)
	[ -n "$f" ] || { echo "games-bench-image: no package $name in artifacts/packages" >&2; exit 1; }
	pkgs+=("$f:/boot/system/packages/$(basename "$f")")
done

"$root/scripts/mkimage-pi4.sh" --in "$base" --out "$out.base" --add-tree "$stage" \
	--bootscript "$root/tools/pi-tests/games-bench.sh"
# --remove options first, then the packages and the caller's FILE:PATH arguments
removes=()
while [ "${1:-}" = --remove ]; do removes+=("$1" "$2"); shift 2; done
"$root/scripts/image-add.sh" ${removes[@]+"${removes[@]}"} "$out.base" "$out" "${pkgs[@]}" "$@"
rm -f "$out.base"
echo "games-bench-image: $out"
