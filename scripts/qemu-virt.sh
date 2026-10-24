#!/usr/bin/env bash
# qemu-virt.sh — boot a Haiku arm64 image on QEMU's generic `virt` machine with EDK2 (the
# reference platform: if something fails here it is not a Pi problem).
#
#   scripts/qemu-virt.sh [--image IMG] [--secs N] [--smp N] [--blk mmio|pci] [--gdb] [--vnc] [--no-copy]
#                        [-- extra qemu args]
#
# Serial goes to artifacts/qemu/<ts>-virt.log (and stdout). --secs N kills QEMU after N s and
# saves a screenshot of the display just before that (artifacts/qemu/<ts>-virt.png).
# The block device is virtio-MMIO by default; --blk pci attaches it as virtio-blk-pci instead (KNOWN-ISSUES D4).
# A writable copy of the image is used, so the build output is never modified; --no-copy boots IMG
# itself (a throwaway test image, when the disk is short of space for a copy).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
img="$root/sources/haiku/generated.arm64/haiku-mmc.image"
secs=0 smp=4 blk=mmio gdb=() display=(-display none) copy=1
while [ $# -gt 0 ]; do
	case "$1" in
	--image) img="$2"; shift 2 ;;
	--secs) secs="$2"; shift 2 ;;
	--smp) smp="$2"; shift 2 ;;
	--blk) blk="$2"; shift 2 ;;
	--gdb) gdb=(-s -S); shift ;;
	--vnc) display=(-vnc :7); shift ;;
	--no-copy) copy=0; shift ;;
	--) shift; break ;;
	*) echo "qemu-virt: unknown option $1" >&2; exit 2 ;;
	esac
done
case "$blk" in mmio) blkdev=virtio-blk-device ;; pci) blkdev=virtio-blk-pci ;; *) echo "qemu-virt: --blk mmio|pci" >&2; exit 2 ;; esac
out="$root/artifacts/qemu"; mkdir -p "$out"
ts="$(date +%Y%m%d-%H%M%S)"
# a copy per run (and its own monitor socket), so that runs can overlap
disk="$out/$ts-virt-disk.img"
qmp="$out/$ts-qmp.sock"
if [ "$copy" = 1 ]; then
	trap 'rm -f "$disk" "$qmp"' EXIT
	cp --reflink=auto "$img" "$disk"
else
	trap 'rm -f "$qmp"' EXIT
	disk="$img"
fi
cmd=(qemu-system-aarch64 -M virt -cpu cortex-a72 -smp "$smp" -m 2G
	-bios /usr/share/qemu-efi-aarch64/QEMU_EFI.fd
	-drive "file=$disk,if=none,format=raw,id=hd0" -device "$blkdev",drive=hd0
	-device ramfb -device qemu-xhci -device usb-kbd -device usb-tablet
	-serial stdio -monitor none -qmp "unix:$qmp,server,nowait" "${display[@]}" "${gdb[@]}" "$@")
echo "qemu-virt: ${cmd[*]}" >&2
if [ "$secs" -gt 0 ]; then
	( sleep "$((secs - 3))"; "$root/scripts/qmp-screendump.py" "$qmp" "$out/$ts-virt.png" ) &
	timeout --foreground "$secs" "${cmd[@]}" < /dev/null 2>&1 | tee "$out/$ts-virt.log" || true
	wait
	[ -f "$out/$ts-virt.png" ] && echo "qemu-virt: screenshot $out/$ts-virt.png" >&2
else
	"${cmd[@]}" 2>&1 | tee "$out/$ts-virt.log"
fi
