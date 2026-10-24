#!/usr/bin/env bash
# image-add.sh — a copy of an SD image with files put into its Haiku (BFS) partition, for one-off
# experiments that need a setting or a tool on the card (e.g. the kernel's syslog time stamps):
#
#   scripts/image-add.sh IMG OUT FILE:PATH...      (PATH as the booted system sees it, under /boot)
#
#   printf 'syslog_time_stamps true\n' > /tmp/kernel
#   scripts/image-add.sh artifacts/images/X.img artifacts/images/X-ts.img \
#       /tmp/kernel:/boot/home/config/settings/kernel/drivers/kernel
#
# Each PATH's directory is created; an existing file there is replaced. Checks each copy's size.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
bfs="$root/sources/haiku/generated.arm64/objects/linux/x86_64/release/tools/bfs_shell/bfs_shell"
[ $# -ge 3 ] || { echo "usage: $0 IMG OUT FILE:PATH..." >&2; exit 2; }
img="$1" out="$2"; shift 2
cp --sparse=always "$img" "$out"
p2=$(( $(sfdisk -J "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["partitiontable"]["partitions"][1]["start"])') * 512 ))
for a in "$@"; do
	src="$(realpath "${a%%:*}")" dest="/myfs${a#*:/boot}"
	printf 'mkdir -p %s\nrm %s\ncp :%s %s\nsync\n' "$(dirname "$dest")" "$dest" "$src" "$dest" \
		| "$bfs" --start-offset "$p2" "$out" > /dev/null 2>&1 || true
	echo "ls -l $dest" | "$bfs" --start-offset "$p2" "$out" 2>&1 | grep -q " $(stat -c %s "$src") " \
		|| { echo "image-add: $src not copied to ${a#*:}" >&2; exit 1; }
	echo "image-add: ${a#*:} ($(stat -c %s "$src") bytes)"
done
