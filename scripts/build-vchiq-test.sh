#!/usr/bin/env bash
# build-vchiq-test.sh — cross-build the /dev/vchiq tests into OUTDIR:
#
#   scripts/build-vchiq-test.sh [TREE] OUTDIR      (TREE: default sources/haiku-vchiq, the H21 worktree)
#
# vchiq-gcmd: tools/haiku-tests/vchiq-gcmd.c, the ioctls by hand (a round trip with the firmware's gencmd
# service), against TREE's driver headers. vchiq_test: Broadcom's libvchiq + VCOS (pthreads) + vchiq_test from
# external/userland (raspberrypi/userland, BSD-3-Clause; docs/design/vchiq.md), unchanged but for
# tools/haiku-tests/vchiq-shim (linux/ioctl.h -> <sys/ioccom.h>, linux/param.h); its -f / -p / -b / -c modes run
# against the firmware's own test services ("func", "echo").
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tree="$root/sources/haiku-vchiq"
[ $# -eq 2 ] && { tree="$(realpath "$1")"; shift; }
[ $# -eq 1 ] || { sed -n '4p' "$0" >&2; exit 2; }
out="$1"
mkdir -p "$out"
g="$root/sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc"
sysroot="$root/artifacts/sysroot-arm64"
bsd="$sysroot/boot/system/develop/headers/bsd"
drv="$tree/src/add-ons/kernel/drivers/misc/vchiq"
"$g" "--sysroot=$sysroot" -O2 -Wall -I "$bsd" -I "$drv" -I "$drv/interface/vchiq_arm" \
	-o "$out/vchiq-gcmd" "$root/tools/haiku-tests/vchiq-gcmd.c"

u="$root/external/userland"
[ -d "$u/interface/vchiq_arm" ] || { echo "build-vchiq-test: no $u (git clone https://github.com/raspberrypi/userland)" >&2; exit 1; }
obj="$(mktemp -d "${TMPDIR:-/tmp}/vchiqtest.XXXXXX")"
trap 'rm -rf "$obj"' EXIT
# userland's own definitions (its CMakeLists.txt); gnu11: the K&R prototypes predate C23
flags=(-std=gnu11 -O2 -D_REENTRANT -DUSE_VCHIQ_ARM -DVCHI_BULK_ALIGN=1 -DVCHI_BULK_GRANULARITY=1 -D_GNU_SOURCE
	-D__VIDEOCORE4__ -I "$root/tools/haiku-tests/vchiq-shim" -I "$bsd" -I "$u" -I "$u/interface/vcos"
	-I "$u/interface/vcos/pthreads" -I "$u/interface/vchiq_arm")
for s in interface/vchiq_arm/{vchiq_lib,vchiq_util,vchiq_test}.c \
		interface/vcos/pthreads/{vcos_pthreads,vcos_dlfcn}.c interface/vcos/glibc/vcos_backtrace.c \
		interface/vcos/generic/vcos_{generic_event_flags,mem_from_malloc,generic_named_sem,generic_safe_string,generic_reentrant_mtx,abort,cmd,init,msgqueue,logcat,generic_blockpool}.c; do
	"$g" "--sysroot=$sysroot" "${flags[@]}" -w -c "$u/$s" -o "$obj/$(basename "${s%.c}").o"
done
"$g" "--sysroot=$sysroot" -o "$out/vchiq_test" "$obj"/*.o
echo "build-vchiq-test: $out/vchiq-gcmd $out/vchiq_test (userland $(git -C "$u" rev-parse --short=12 HEAD))"
