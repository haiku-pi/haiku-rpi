#!/usr/bin/env bash
# image-cat.sh IMAGE PATH — print a file from the BFS partition (p2) of a Haiku Pi image: a card read back
# with `scripts/sd-cycle.sh --read-back`, or a network boot's disk after the cycle
# (artifacts/netboot/disk.img: what the Pi wrote stays there until the next netboot-server.sh up).
# PATH as Haiku sees it under /boot (e.g. /boot/system/cache/tmp/x.txt: Haiku's /tmp; /boot/system/var/
# log/syslog). Uses the host build of bfs_shell, as scripts/sd-syslog.sh.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -eq 2 ] || { echo "usage: $0 IMAGE PATH" >&2; exit 2; }
img="$1" path="$2"
case "$path" in
/boot/*) path="/myfs/${path#/boot/}" ;;
*) echo "image-cat: PATH must start with /boot/" >&2; exit 2 ;;
esac
bfs="$root/sources/haiku/generated.arm64/objects/linux/x86_64/release/tools/bfs_shell/bfs_shell"
start=$(( $(sfdisk -J "$img" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["partitiontable"]["partitions"][1]["start"])') * 512 ))
echo "cat $path" | "$bfs" --start-offset "$start" "$img" 2>&1 | grep -v '^bfs: mounted' | sed 's/^fssh:[^>]*> //'
