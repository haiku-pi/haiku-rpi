#!/usr/bin/env bash
# build-vchiq-test.sh — cross-build tools/haiku-tests/vchiq-gcmd.c (the /dev/vchiq ioctl round trip with the
# firmware's gencmd service) against a haiku tree's VCHIQ driver headers:
#
#   scripts/build-vchiq-test.sh [TREE] OUT      (TREE: default sources/haiku-vchiq, the H21 worktree)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tree="$root/sources/haiku-vchiq"
[ $# -eq 2 ] && { tree="$(realpath "$1")"; shift; }
[ $# -eq 1 ] || { sed -n '5p' "$0" >&2; exit 2; }
g="$root/sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc"
sysroot="$root/artifacts/sysroot-arm64"
drv="$tree/src/add-ons/kernel/drivers/misc/vchiq"
"$g" "--sysroot=$sysroot" -O2 -Wall -I "$sysroot/boot/system/develop/headers/bsd" -I "$drv" \
	-I "$drv/interface/vchiq_arm" -o "$1" "$root/tools/haiku-tests/vchiq-gcmd.c"
echo "build-vchiq-test: $1"
