#!/usr/bin/env bash
# image-add.sh — a copy of an SD image with files put into its Haiku (BFS) partition, for one-off
# experiments that need a setting or a tool on the card (e.g. the kernel's syslog time stamps):
#
#   scripts/image-add.sh [--remove PATH]... IMG OUT [FILE:PATH]...   (PATH as the booted system sees it, under /boot)
#
#   printf 'syslog_time_stamps true\n' > /tmp/kernel
#   scripts/image-add.sh artifacts/images/X.img artifacts/images/X-ts.img \
#       /tmp/kernel:/boot/home/config/settings/kernel/drivers/kernel
#
# Each PATH's directory is created; an existing file there is replaced. Checks each copy's size.
# --remove PATH deletes a file first (e.g. a package being swapped for another revision:
# --remove /boot/system/packages/mesa-26.2.5-6-arm64.hpkg) and checks that it is gone.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
bfs="$root/sources/haiku/generated.arm64/objects/linux/x86_64/release/tools/bfs_shell/bfs_shell"
removes=()
while [ "${1:-}" = --remove ]; do removes+=("$2"); shift 2; done
[ $# -ge 3 ] || [ $# -ge 2 -a ${#removes[@]} -gt 0 ] || { echo "usage: $0 [--remove PATH]... IMG OUT FILE:PATH..." >&2; exit 2; }
img="$1" out="$2"; shift 2
cp --sparse=always "$img" "$out"
p2=$(( $(sfdisk -J "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["partitiontable"]["partitions"][1]["start"])') * 512 ))
for r in ${removes[@]+"${removes[@]}"}; do
	dest="/myfs${r#/boot}"
	printf 'rm %s\nsync\n' "$dest" | "$bfs" --start-offset "$p2" "$out" > /dev/null 2>&1 || true
	echo "ls $(dirname "$dest")" | "$bfs" --start-offset "$p2" "$out" 2>&1 | grep -q " $(basename "$dest")\$" \
		&& { echo "image-add: $r not removed" >&2; exit 1; }
	echo "image-add: removed $r"
done
for a in "$@"; do
	src="$(realpath "${a%%:*}")" dest="/myfs${a#*:/boot}"
	printf 'mkdir -p %s\nrm %s\ncp :%s %s\nsync\n' "$(dirname "$dest")" "$dest" "$src" "$dest" \
		| "$bfs" --start-offset "$p2" "$out" > /dev/null 2>&1 || true
	echo "ls -l $dest" | "$bfs" --start-offset "$p2" "$out" 2>&1 | grep -q " $(stat -c %s "$src") " \
		|| { echo "image-add: $src not copied to ${a#*:}" >&2; exit 1; }
	echo "image-add: ${a#*:} ($(stat -c %s "$src") bytes)"
done
