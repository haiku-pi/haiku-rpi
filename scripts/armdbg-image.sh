#!/usr/bin/env bash
# armdbg-image.sh — a copy of an SD image with the arm64 user debugging tests: the UserBootscript
# tools/pi-tests/armdbg.sh and, in /boot/home, armdbg (the debug nub API: breakpoints, steps,
# watchpoints), dbgtarget (built with -g -O0, for Debugger's command line interface) and launchtime
# from tools/haiku-tests/. For QEMU (scripts/qemu-virt.sh --image OUT) or the Pi (scripts/netboot-cycle.sh
# --image OUT, scripts/sd-cycle.sh --flash OUT).
#
#   scripts/armdbg-image.sh [--direct-serial] IMG OUT
#
#   --direct-serial  also the kernel setting "serial_debug_buffered false" (was needed for QEMU between
#                    haiku rpi4 5ec650bbb0 and 7a2282df3c: QEMU's PL011 kept its receive interrupt
#                    raised and the boot stopped after the scheduler's lines)
#
# The programs are built in artifacts/armdbg/.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
direct=0
[ "${1:-}" = --direct-serial ] && { direct=1; shift; }
[ $# = 2 ] || { echo "usage: $0 [--direct-serial] IMG OUT" >&2; exit 2; }
img="$1" out="$2"
t="$root/tools/haiku-tests" b="$root/artifacts/armdbg"
mkdir -p "$b"
tp="$root/sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-"
sysroot="--sysroot=$root/artifacts/sysroot-arm64"
cc="${tp}gcc $sysroot -Wall"
$cc -O2 -g -o "$b/armdbg" "$t/armdbg.c"
$cc -O0 -g -gdwarf-4 -o "$b/dbgtarget" "$t/dbgtarget.c"
${tp}g++ $sysroot -O2 -I "$root/sources/haiku/headers/private/interface" -o "$b/launchtime" \
	"$t/launchtime.cpp" -lbe
files=("$root/tools/pi-tests/armdbg.sh:/boot/home/config/settings/boot/UserBootscript"
	"$b/armdbg:/boot/home/armdbg" "$b/dbgtarget:/boot/home/dbgtarget"
	"$b/launchtime:/boot/home/launchtime")
if [ "$direct" = 1 ]; then
	printf 'serial_debug_buffered false\n' > "$b/kernel"
	files+=("$b/kernel:/boot/home/config/settings/kernel/drivers/kernel")
fi
"$root/scripts/image-add.sh" "$img" "$out" "${files[@]}"
