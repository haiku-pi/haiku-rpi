#!/usr/bin/env bash
# stage-packages.sh — unpack Haiku packages into one tree, for scripts/mkimage-pi4.sh --add-tree (files in
# /boot/system/non-packaged, for test images that need a package's files without installing it).
#
#   scripts/stage-packages.sh OUT PKG.hpkg...
#   scripts/stage-packages.sh --wine-runtime [OUT]     what Wine's Wayland driver needs (wayland,
#                                                      wayland_server, libxkbcommon, xkeyboard_config from
#                                                      artifacts/packages);
#                                                      OUT defaults to artifacts/wayland-stage
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
gen="$root/sources/haiku/generated.arm64"
pkgtool="$gen/objects/linux/x86_64/release/tools/package/package"
export LD_LIBRARY_PATH="$gen/objects/linux/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

if [ "${1:-}" = --wine-runtime ]; then
	out="${2:-$root/artifacts/wayland-stage}"
	set -- "$out"
	for name in wayland wayland_server libxkbcommon xkeyboard_config; do
		p=$(ls "$root"/artifacts/packages/"$name"-[0-9]*-arm64.hpkg | sort -V | tail -n 1)
		set -- "$@" "$p"
	done
fi
[ $# -ge 2 ] || { sed -n '5,9p' "$0" >&2; exit 2; }
out=$1
shift
rm -rf "$out"
mkdir -p "$out"
for p in "$@"; do
	tmp=$(mktemp -d)
	"$pkgtool" extract -C "$tmp" "$p"
	rm -f "$tmp/.PackageInfo"
	cp -a "$tmp/." "$out/"
	rm -rf "$tmp"
	echo "stage-packages: $(basename "$p")"
done
echo "stage-packages: $out ($(find "$out" -type f | wc -l) files)"
