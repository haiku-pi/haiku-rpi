#!/usr/bin/env bash
# gpu-queues-image.sh — the test image of GPU stage 7 (asynchronous per-unit V3D job queues,
# docs/design/gpu-stage7.md): a copy of BASE with the v3d driver and v3dtest of a stage7 build in place of the
# packaged driver, the kernel setting v3d_stats, glmark2 (if BASE lacks it), QuakeSpasm with its SDL2 from the
# games tree, and tools/pi-tests/gpu-queues.sh as the UserBootscript.
#
#   scripts/gpu-queues-image.sh [--generated DIR] BASE OUT
#
# DIR: the stage7 worktree's output directory (default sources/haiku-stage7/generated.arm64, built with
# `scripts/build.sh --generated DIR v3d v3dtest`). BASE should be an image of the rpi4 commit the stage7 branch
# is based on (the driver is a kernel add-on). The driver's queue mode is not fixed in the image: the
# UserBootscript writes the settings file "v3d" before each step; without one the driver runs serialised.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
gen="$root/sources/haiku-stage7/generated.arm64"
[ "${1:-}" = --generated ] && { gen="$(realpath "$2")"; shift 2; }
[ $# -eq 2 ] || { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
base="$(realpath "$1")" out="$(realpath -m "$2")"
obj="$gen/objects/haiku/arm64/release"
driver="$obj/add-ons/kernel/drivers/graphics/v3d/v3d"
v3dtest="$obj/tests/add-ons/kernel/drivers/v3d/v3dtest"
for f in "$driver" "$v3dtest"; do
	[ -f "$f" ] || { echo "gpu-queues-image: no $f (build it first)" >&2; exit 1; }
done
stage="$root/artifacts/gpu-queues"
rm -rf "$stage"
mkdir -p "$stage/np/apps" "$stage/np/lib"

cp --sparse=always "$base" "$out"
bfs="$root/sources/haiku/generated.arm64/objects/linux/x86_64/release/tools/bfs_shell/bfs_shell"
p2=$(( $(sfdisk -J "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["partitiontable"]["partitions"][1]["start"])') * 512 ))
packages=$(echo "ls /myfs/system/packages" | "$bfs" --start-offset "$p2" "$out" 2>&1)

# The kernel settings of BASE (if any) plus v3d_stats; the packaged driver hidden (BASE must not hide
# anything yet: merging BlockedEntries is not done here)
"$root/scripts/image-cat.sh" "$out" /boot/home/config/settings/kernel/drivers/kernel 2> /dev/null \
	| grep -v -E '^(v3d_stats|fssh|cat:|.*No such file)' > "$stage/kernel" || true
echo "v3d_stats true" >> "$stage/kernel"
if "$root/scripts/image-cat.sh" "$out" /boot/system/settings/packages 2> /dev/null | grep -q BlockedEntries; then
	echo "gpu-queues-image: BASE already has /boot/system/settings/packages; merge it by hand" >&2
	exit 1
fi
printf 'Package haiku {\n\tBlockedEntries {\n\t\tadd-ons/kernel/drivers/graphics/v3d\n\t}\n}\n' > "$stage/packages"

files=(
	"$driver:/boot/system/non-packaged/add-ons/kernel/drivers/graphics/v3d"
	"$stage/packages:/boot/system/settings/packages"
	"$v3dtest:/boot/home/gpu-queues/v3dtest"
	"$stage/kernel:/boot/home/config/settings/kernel/drivers/kernel"
	"$root/tools/pi-tests/gpu-queues.sh:/boot/home/config/settings/boot/UserBootscript"
)
if ! grep -q 'glmark2-' <<< "$packages"; then
	gm2=$(ls "$root"/artifacts/packages/glmark2-*-arm64.hpkg | sort -V | tail -n 1)
	files+=("$gm2:/boot/system/packages/$(basename "$gm2")")
fi
grep -q 'mesa-' <<< "$packages" || echo "gpu-queues-image: warning: BASE has no mesa package (no GL)" >&2
"$root/scripts/image-add.sh" --in-place "$out" "${files[@]}"

cp -a "$root/artifacts/games/non-packaged/apps/QuakeSpasm" "$stage/np/apps/"
cp -a "$root/artifacts/games/non-packaged/lib/libSDL2-2.0.so.0" "$stage/np/lib/"
"$root/scripts/disk-add-tree.sh" --disk "$out" "$stage/np" /boot/system/non-packaged
rm -rf "$stage/np"
echo "gpu-queues-image: $out (kernel settings: $(grep -v -E '^[[:space:]]*(#|$)' "$stage/kernel" | tr '\n' ' '))"
