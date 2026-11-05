#!/usr/bin/env bash
# c4b-x86.sh — the x86-64 KVM file-system checks of H20 C4b (page writer / file cache request sizes; docs/design/
# perf-round-h20.md §6 "C4b results"), one after another on ISO, each on a fresh 2 GB BFS scratch volume, for
# the scratch disk on AHCI and on NVMe: the FS group (bfsmeta, copy + MD5 after a remount, fragwrite, checkfs,
# bfsbits), bigfile (1.06 GiB written, MD5 from the cache and after a remount, checkfs, bfsbits), CUTS power cuts
# during metadata writes (scripts/x86-powercut.sh) and CUTS during a large data write (tools/x86-tests/pcbig.sh).
#
#   scripts/c4b-x86.sh ISO [CUTS [data]]   (CUTS default 2; data: only the data-write cuts)
#
# Rows in artifacts/qemu-x86/results.tsv (scripts/x86-test.sh); the summary lines here go to stdout.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
iso="$(realpath "${1:?usage: c4b-x86.sh ISO [CUTS [data]]}")" cuts="${2:-2}" only="${3:-}"
bfs="$root/sources/haiku-x86/generated.x86_64/objects/linux/x86_64/release/tools/bfs_shell/bfs_shell"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/c4b-x86.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fresh() {	# a new 2 GB BFS volume "scratch" at $tmp/scratch.img
	rm -f "$tmp/scratch.img"; truncate -s 2G "$tmp/scratch.img"
	LD_LIBRARY_PATH="${bfs%/objects/*}/objects/linux/lib" "$bfs" --initialize "$tmp/scratch.img" scratch > /dev/null
}
for d in ahci nvme; do
	echo "== c4b-x86: $d $(date +%H:%M:%S)"
	[ "$only" = data ] || {
	fresh; "$root/scripts/x86-test.sh" fs "$iso" --scratch "$tmp/scratch.img" --scratch-disk $d 2>&1 | tail -n 25
	fresh; "$root/scripts/x86-test.sh" bigfile "$iso" --scratch "$tmp/scratch.img" --scratch-disk $d 2>&1 | tail -n 15
	"$root/scripts/x86-powercut.sh" "$iso" "$cuts" 20000 --scratch-disk $d 2>&1 | tail -n 30
	}
	fresh
	for i in $(seq 1 "$cuts"); do
		echo "== c4b-x86: $d data cut $i of $cuts"
		"$root/scripts/x86-test.sh" pcbig "$iso" --secs 900 --scratch "$tmp/scratch.img" --scratch-disk $d \
			--until 'X86T pcbig info big 1024 MiB' 2>&1 | tail -n 8
		"$root/scripts/x86-test.sh" pcbig "$iso" --secs 900 --scratch "$tmp/scratch.img" --scratch-disk $d 2>&1 | tail -n 15
	done
done
echo "== c4b-x86: end $(date +%H:%M:%S)"
