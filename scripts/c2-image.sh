#!/usr/bin/env bash
# c2-image.sh — a copy of an SD image for the cold-start read-ahead tests (perf-round-h20.md C2): the
# UserBootscript tools/pi-tests/c2.sh; launchtime, mmapcat and disklat (tools/haiku-tests/) in /boot/home;
# /boot/home/ffx = the staged Firefox (artifacts/firefox/non-packaged/apps/Firefox) with the DT_RELR
# libxul.so the -6 package ships (artifacts/relr/ffx-relr), as plain BFS files; /boot/home/c2data = test
# files of assorted sizes (made once, seeded, in artifacts/c2/c2data) with their MD5 sums in
# /boot/home/c2data.md5; /boot/home/c2.mode = MODE (launch, or catall: read Firefox's files first).
#
#   scripts/c2-image.sh [--mode launch|catall] IMG OUT
#
# Then: scripts/sd-cycle.sh --flash OUT --secs 900 --until 'C2 end' --label ...
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
mode=launch
[ "${1:-}" = --mode ] && { mode=$2; shift 2; }
[ $# = 2 ] || { sed -n '9p' "$0" >&2; exit 2; }
img="$1" out="$2"
case "$mode" in launch|catall) ;; *) echo "c2-image: unknown mode $mode" >&2; exit 2 ;; esac
t="$root/tools/haiku-tests" b="$root/artifacts/c2"
mkdir -p "$b"
tp="$root/sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-"
sysroot="$root/artifacts/sysroot-arm64"
${tp}gcc --sysroot="$sysroot" -O2 -Wall -o "$b/mmapcat" "$t/mmapcat.c"
${tp}gcc --sysroot="$sysroot" -O2 -Wall -o "$b/disklat" "$t/disklat.c"
${tp}g++ --sysroot="$sysroot" -O2 -I "$root/sources/haiku/headers/private/interface" \
	-o "$b/launchtime" "$t/launchtime.cpp" -lbe

# test files: page-size edge cases and 1-8 MiB files with odd tails, ~64 MB in all; made once
if [ ! -s "$b/c2data.md5" ]; then
	rm -rf "$b/c2data"
	mkdir -p "$b/c2data"
	python3 -I - "$b/c2data" <<-'EOF'
	import os, random, sys
	d = sys.argv[1]
	r = random.Random(2026_11_04)
	sizes = [1, 100, 4095, 4096, 4097, 65535, 65536, 65537, 131073, 262145]
	sizes += [r.randrange(1 << 20, 8 << 20) | 1 for _ in range(14)]
	for i, s in enumerate(sizes):
	    with open(os.path.join(d, "f%02d" % i), "wb") as f:
	        f.write(r.randbytes(s))
	EOF
	(cd "$b/c2data" && md5sum f* > ../c2data.md5)
fi
[ -d "$root/artifacts/relr/ffx-relr" ] || { echo "c2-image: artifacts/relr/ffx-relr missing" >&2; exit 1; }
"${tp}readelf" -d "$root/artifacts/relr/ffx-relr/lib/libxul.so" | grep -q '(RELR)' \
	|| { echo "c2-image: ffx-relr's libxul.so has no DT_RELR" >&2; exit 1; }
printf '%s\n' "$mode" > "$b/c2.mode"

"$root/scripts/image-add.sh" "$img" "$out" \
	"$root/tools/pi-tests/c2.sh:/boot/home/config/settings/boot/UserBootscript" \
	"$b/launchtime:/boot/home/launchtime" "$b/mmapcat:/boot/home/mmapcat" "$b/disklat:/boot/home/disklat" \
	"$b/c2data.md5:/boot/home/c2data.md5" "$b/c2.mode:/boot/home/c2.mode"
"$root/scripts/disk-add-tree.sh" --disk "$out" "$b/c2data" /boot/home/c2data
"$root/scripts/disk-add-tree.sh" --disk "$out" "$root/artifacts/relr/ffx-relr" /boot/home/ffx
echo "c2-image: $out (mode $mode)"
