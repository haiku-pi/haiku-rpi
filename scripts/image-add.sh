#!/usr/bin/env bash
# image-add.sh — a copy of an SD image with files put into its Haiku (BFS) partition, for one-off
# experiments that need a setting or a tool on the card (e.g. the kernel's syslog time stamps):
#
#   scripts/image-add.sh [--bfs-shell PATH] [--remove PATH]... IMG OUT [FILE:PATH]...   (PATH as the booted system sees it, under /boot)
#   scripts/image-add.sh --in-place [--bfs-shell PATH] [--remove PATH]... IMG [FILE:PATH]...   (changes IMG itself)
#
#   printf 'syslog_time_stamps true\n' > /tmp/kernel
#   scripts/image-add.sh artifacts/images/X.img artifacts/images/X-ts.img \
#       /tmp/kernel:/boot/home/config/settings/kernel/drivers/kernel
#
# Each PATH's directory is created; an existing file there is replaced. Checks each copy's size.
# --remove PATH deletes a file first (e.g. a package being swapped for another revision:
# --remove /boot/system/packages/mesa-26.2.5-6-arm64.hpkg) and checks that it is gone.
# The Haiku partition is the first one of type 0xeb (the Pi SD image's second, an x86 anyboot image's
# own). --bfs-shell PATH uses another build's bfs_shell (default: generated.arm64's; an x86_64 tree's
# for scripts/qemu-x86.sh).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
bfs="$root/sources/haiku/generated.arm64/objects/linux/x86_64/release/tools/bfs_shell/bfs_shell"
removes=()
inPlace=no
while [ $# -gt 0 ]; do
	case "$1" in
	--in-place) inPlace=yes; shift ;;
	--remove) removes+=("$2"); shift 2 ;;
	--bfs-shell) bfs="$2"; shift 2 ;;
	*) break ;;
	esac
done
[ -x "$bfs" ] || { echo "image-add: no bfs_shell $bfs" >&2; exit 1; }
export LD_LIBRARY_PATH="${bfs%/objects/*}/objects/linux/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# one bfs_shell argument, double-quoted (bfs_shell splits on blanks; e.g. "Locale settings")
q() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }
if [ $inPlace = yes ]; then
	[ $# -ge 2 ] || [ $# -ge 1 -a ${#removes[@]} -gt 0 ] || { echo "usage: $0 --in-place [--remove PATH]... IMG FILE:PATH..." >&2; exit 2; }
	img="$1" out="$1"; shift
else
	[ $# -ge 3 ] || [ $# -ge 2 -a ${#removes[@]} -gt 0 ] || { echo "usage: $0 [--remove PATH]... IMG OUT FILE:PATH..." >&2; exit 2; }
	img="$1" out="$2"; shift 2
	cp --sparse=always "$img" "$out"
fi
p2=$(( $(sfdisk -J "$out" | python3 -c 'import json,sys
parts = json.load(sys.stdin)["partitiontable"]["partitions"]
print(next((p for p in parts if p["type"] == "eb"), parts[1])["start"])') * 512 ))
for r in ${removes[@]+"${removes[@]}"}; do
	dest="/myfs${r#/boot}"
	printf 'rm %s\nsync\n' "$(q "$dest")" | "$bfs" --start-offset "$p2" "$out" > /dev/null 2>&1 || true
	echo "ls $(q "$(dirname "$dest")")" | "$bfs" --start-offset "$p2" "$out" 2>&1 | grep -q " $(basename "$dest")\$" \
		&& { echo "image-add: $r not removed" >&2; exit 1; }
	echo "image-add: removed $r"
done
for a in "$@"; do
	src="$(realpath "${a%%:*}")" dest="/myfs${a#*:/boot}"
	printf 'mkdir -p %s\nrm %s\ncp %s %s\nsync\n' "$(q "$(dirname "$dest")")" "$(q "$dest")" "$(q ":$src")" "$(q "$dest")" \
		| "$bfs" --start-offset "$p2" "$out" > /dev/null 2>&1 || true
	echo "ls -l $(q "$dest")" | "$bfs" --start-offset "$p2" "$out" 2>&1 | grep -q " $(stat -c %s "$src") " \
		|| { echo "image-add: $src not copied to ${a#*:}" >&2; exit 1; }
	echo "image-add: ${a#*:} ($(stat -c %s "$src") bytes)"
done
