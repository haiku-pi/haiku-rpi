#!/usr/bin/env bash
# c4b-x86-ab.sh — timing A/B of tools/x86-tests/bigfile.sh (1.06 GiB written + sync, then read back after a
# remount) under KVM for H20 C4b: ISO_A and ISO_B alternating, ROUNDS times, scratch disk on AHCI and on NVMe,
# each run on a fresh 2 GB BFS scratch volume and nothing else running in the guest.
#
#   scripts/c4b-x86-ab.sh ISO_A ISO_B [ROUNDS]       (ROUNDS default 2)
#
# Prints one line per run: "c4b-x86-ab DISK ISO write N s, read N s, md5 PASS|FAIL".
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
a="$(realpath "${1:?usage: c4b-x86-ab.sh ISO_A ISO_B [ROUNDS]}")" b="$(realpath "${2:?ISO_B}")" rounds="${3:-2}"
bfs="$root/sources/haiku-x86/generated.x86_64/objects/linux/x86_64/release/tools/bfs_shell/bfs_shell"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/c4b-x86ab.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
for r in $(seq 1 "$rounds"); do
	for d in ahci nvme; do
		for iso in "$a" "$b"; do
			rm -f "$tmp/s.img"; truncate -s 2G "$tmp/s.img"
			LD_LIBRARY_PATH="${bfs%/objects/*}/objects/linux/lib" "$bfs" --initialize "$tmp/s.img" scratch > /dev/null
			out=$("$root/scripts/x86-test.sh" bigfile "$iso" --scratch "$tmp/s.img" --scratch-disk $d 2>&1)
			w=$(echo "$out" | grep -o 'bytes in [0-9]* s' | head -n 1)
			rd=$(echo "$out" | grep -o 'read in [0-9]* s' | head -n 1)
			m=$(echo "$out" | grep -q 'md5-remount *PASS' && echo PASS || echo FAIL)
			echo "c4b-x86-ab $d $(basename "$iso") write ${w#bytes in }, ${rd}, md5 $m"
		done
	done
done
