#!/usr/bin/env bash
# sd-syslog.sh [--fresh] [IMAGE] — print Haiku's /var/log/syslog from a card image read back with
# `scripts/sd-cycle.sh --read-back` (default: the newest artifacts/readback/*.img). --fresh reads the
# card first (one Pi cycle). Uses the host build of bfs_shell on the image's BFS partition (p2).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
bfs="$root/sources/haiku/generated.arm64/objects/linux/x86_64/release/tools/bfs_shell/bfs_shell"
if [ "${1:-}" = --fresh ]; then
	shift
	mkdir -p "$root/artifacts/readback"
	img="$root/artifacts/readback/$(date +%Y%m%d-%H%M%S).img"
	"$root/scripts/sd-cycle.sh" --read-back "$img" --label readback >&2
fi
img="${1:-$(ls -t "$root"/artifacts/readback/*.img | head -n 1)}"
start=$(( $(sfdisk -J "$img" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["partitiontable"]["partitions"][1]["start"])') * 512 ))
# (/var is a symlink to /boot/system/var, created at run time)
echo "cat /myfs/system/var/log/syslog" | "$bfs" --start-offset "$start" "$img" 2>&1 \
	| grep -v '^bfs: mounted' | sed 's/^fssh:[^>]*> //'
