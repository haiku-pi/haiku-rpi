#!/usr/bin/env bash
# disk-add-tree.sh — copy a directory of this host onto a Haiku disk image (BFS, the image's second partition),
# by bfs_shell, as mkimage-pi4.sh --add-tree does; for a disk kept between network boots (netboot-cycle.sh
# --keep-disk: artifacts/netboot/disk.img), e.g. a game for a Wine prefix already on it.
#
#   scripts/disk-add-tree.sh [--disk IMG] DIR PATH        (PATH: where DIR goes in the booted system, /boot/...)
#
# Not while a cycle runs from that disk. Every file is checked by its size afterwards.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
disk="$root/artifacts/netboot/disk.img"
[ "${1:-}" = --disk ] && { disk=$2; shift 2; }
[ $# -eq 2 ] && [ -d "$1" ] && [[ $2 == /boot/* ]] || { sed -n '6p' "$0" >&2; exit 2; }
tree="$(realpath "$1")" dest="/myfs${2#/boot}"
gen="$root/sources/haiku/generated.arm64"
bfs="$gen/objects/linux/x86_64/release/tools/bfs_shell/bfs_shell"
export LD_LIBRARY_PATH="$gen/objects/linux/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
p2=$(sfdisk -J "$disk" | python3 -c 'import json,sys; print(json.load(sys.stdin)["partitiontable"]["partitions"][1]["start"])')
run_bfs() { "$bfs" --start-offset $((p2 * 512)) "$disk"; }
# one bfs_shell argument, double-quoted (bfs_shell splits on blanks; inside quotes only \ and " are escaped)
fssh_quote() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }

log="$(mktemp)"
trap 'rm -f "$log"' EXIT
{
	echo "mkdir -p $(fssh_quote "$dest")"
	(cd "$tree" && find . -mindepth 1 -type d -printf '%P\n') | sort | while read -r d; do
		echo "mkdir -p $(fssh_quote "$dest/$d")"
	done
	(cd "$tree" && find . -type f -printf '%P\n') | sort | while read -r f; do
		echo "cp $(fssh_quote ":$tree/$f") $(fssh_quote "$dest/$f")"
	done
	echo sync
} | run_bfs > "$log" 2>&1 || true
(cd "$tree" && find . -type f -printf '%P\n') | while read -r f; do
	echo "ls $(fssh_quote "$dest/$f")" | run_bfs 2>&1 | grep -q " $(stat -c %s "$tree/$f") .*$(basename "$f")" \
		|| { cat "$log" >&2; echo "disk-add-tree: $f not written" >&2; exit 1; }
done
echo "disk-add-tree: $(cd "$tree" && find . -type f | wc -l) files of $tree to $2"
