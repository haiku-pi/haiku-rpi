#!/usr/bin/env bash
# x86-powercut.sh — the H22 FS power-cut test (docs/design/x86-64-check.md §4.3): N times, boot IMAGE with a
# scratch BFS disk, write metadata without end (tools/x86-tests/pc1.sh) and pull the power (QMP quit, through
# qemu-x86.sh --until) after FILES files; then boot again and check the volume (pc2.sh: journal replay on
# mount, checkfs -c, bfsbits, a new write). The same scratch disk goes through all N cuts.
#
#   scripts/x86-powercut.sh IMAGE [N [FILES]]       (IMAGE as scripts/x86-test.sh; N 3, FILES 20000)
#
# Rows in artifacts/qemu-x86/results.tsv (groups pc1, pc2); pc1 ends in a power cut by design, so its
# "poweroff FAIL" row is expected.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -ge 1 ] || { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
image="$1" n="${2:-3}" files="${3:-20000}"
bfs="$root/sources/haiku-x86/generated.x86_64/objects/linux/x86_64/release/tools/bfs_shell/bfs_shell"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/x86-pc.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
scratch="$tmp/scratch.img"
truncate -s 2G "$scratch"
LD_LIBRARY_PATH="${bfs%/objects/*}/objects/linux/lib" "$bfs" --initialize "$scratch" scratch > /dev/null \
	|| { echo "x86-powercut: bfs_shell --initialize failed" >&2; exit 1; }
fails=0
for i in $(seq 1 "$n"); do
	echo "x86-powercut: $image cut $i of $n after $files files"
	"$root/scripts/x86-test.sh" pc1 "$image" --secs 600 --scratch "$scratch" \
		--until "X86T pc1 info loop bfsmeta: loop: $files files" 2>&1 | grep -E '^(pc1|kernel) '
	"$root/scripts/x86-test.sh" pc2 "$image" --secs 600 --scratch "$scratch" 2>&1 \
		| grep -E '^(pc2|kernel|qemu) '
	[ "${PIPESTATUS[0]}" = 0 ] || fails=$((fails + 1))
done
echo "x86-powercut: $image: $fails of $n checks failed"
