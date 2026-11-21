#!/usr/bin/env bash
# spalign-image.sh — a copy of a Haiku arm64 image with the user-fault test: the UserBootscript
# tools/pi-tests/spalign.sh and /boot/home/spalign (tools/haiku-tests/spalign.c: a misaligned stack
# pointer, an undefined instruction, __builtin_trap() and an SVE instruction must each give the program a
# signal, not panic the kernel). Serial lines "SPALIGN ...". For QEMU (scripts/qemu-virt.sh --image OUT;
# add `-- -cpu neoverse-v1` to make the SVE case trap as EC 0x19; EDK2 hangs on -cpu max) or the Pi
# (scripts/sd-cycle.sh --flash OUT). QEMU does not model the SP alignment check: that case is a SKIP there.
#
#   scripts/spalign-image.sh [--bfs-shell PATH] IMG OUT
#
# IMG is a raw Haiku image (generated.arm64/haiku-mmc.image) or a Pi SD image. The program is built in
# artifacts/spalign/.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
bfs=()
[ "${1:-}" = --bfs-shell ] && { bfs=(--bfs-shell "$2"); shift 2; }
[ $# = 2 ] || { echo "usage: $0 [--bfs-shell PATH] IMG OUT" >&2; exit 2; }
img="$1" out="$2"
b="$root/artifacts/spalign"
mkdir -p "$b"
tp="$root/sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-"
"${tp}gcc" --sysroot="$root/artifacts/sysroot-arm64" -O2 -Wall -o "$b/spalign" "$root/tools/haiku-tests/spalign.c"
"$root/scripts/image-add.sh" "${bfs[@]}" "$img" "$out" \
	"$root/tools/pi-tests/spalign.sh:/boot/home/config/settings/boot/UserBootscript" \
	"$b/spalign:/boot/home/spalign"
echo "spalign-image: $out"
