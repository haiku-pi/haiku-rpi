#!/usr/bin/env bash
# dwarf5-image.sh — a copy of an SD image with the Debugger DWARF 5 tests (design/debugger-dwarf5.md):
# the UserBootscript tools/pi-tests/dwarf5.sh and, in /boot/home/dwarf5, the Debugger and libdebugger.so
# under test (lib/: the runtime loader looks in the application's lib/ first, so the system's Debugger
# stays as it is) and the test programs tools/haiku-tests/dbgtarget.c (-O0) and dbgtarget-cxx.cpp (-O2),
# each built with -gdwarf-4 and -gdwarf-5 by the GCC 13 cross compiler, and their sources. For QEMU
# (scripts/qemu-virt.sh --image OUT --no-copy) or the Pi (scripts/netboot-cycle.sh --image OUT).
#
#   scripts/dwarf5-image.sh [--generated DIR] IMG OUT
#
#   --generated DIR  the output directory the Debugger was built in (jam libdebugger.so Debugger;
#                    default sources/haiku-dwarf5/generated.arm64, the dwarf5 worktree's)
#
# The programs are built in artifacts/dwarf5/image/.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
gen="$root/sources/haiku-dwarf5/generated.arm64"
[ "${1:-}" = --generated ] && { gen="$(cd "$2" && pwd)"; shift 2; }
[ $# = 2 ] || { echo "usage: $0 [--generated DIR] IMG OUT" >&2; exit 2; }
img="$1" out="$2"
t="$root/tools/haiku-tests" b="$root/artifacts/dwarf5/image"
mkdir -p "$b"
tp="$root/sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-"
sysroot="--sysroot=$root/artifacts/sysroot-arm64"
d=/boot/home/dwarf5
# the sources are put on the image where the debug information says they are (the Debugger shows
# source lines only for a source file it finds)
map="-fdebug-prefix-map=$t=$d/src"
for v in 4 5; do
	"${tp}gcc" $sysroot $map -Wall -O0 -g -gdwarf-$v -o "$b/c-dw$v" "$t/dbgtarget.c"
	"${tp}g++" $sysroot $map -Wall -O2 -g -gdwarf-$v -o "$b/cxx-dw$v" "$t/dbgtarget-cxx.cpp"
done
debugger="$gen/objects/haiku/arm64/release/apps/debugger/Debugger"
library="$gen/objects/haiku/arm64/release/kits/debugger/libdebugger.so"
for f in "$debugger" "$library"; do
	[ -f "$f" ] || { echo "dwarf5-image: no $f (jam libdebugger.so Debugger in $gen)" >&2; exit 1; }
done
"$root/scripts/image-add.sh" "$img" "$out" \
	"$root/tools/pi-tests/dwarf5.sh:/boot/home/config/settings/boot/UserBootscript" \
	"$debugger:$d/Debugger" "$library:$d/lib/libdebugger.so" \
	"$b/c-dw4:$d/c-dw4" "$b/c-dw5:$d/c-dw5" "$b/cxx-dw4:$d/cxx-dw4" "$b/cxx-dw5:$d/cxx-dw5" \
	"$t/dbgtarget.c:$d/src/dbgtarget.c" "$t/dbgtarget-cxx.cpp:$d/src/dbgtarget-cxx.cpp"
