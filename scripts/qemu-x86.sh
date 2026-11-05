#!/usr/bin/env bash
# qemu-x86.sh — boot a Haiku x86_64 image under KVM (H22, docs/design/x86-64-check.md §4.1): our tree's or
# upstream's haiku-nightly-anyboot.iso (scripts/build-x86.sh), as a disk (UEFI or BIOS) or as a CD.
#
#   scripts/qemu-x86.sh [--image IMG] [--fw uefi|bios] [--machine q35|pc]
#                       [--disk ahci|nvme|virtio-scsi|usb|ide|cdrom] [--smp N] [--topo cores=2,threads=2]
#                       [--mem 4G] [--nic virtio|e1000|rtl8139|none] [--legacy-virtio] [--scratch IMG [--scratch-disk ahci|nvme|virtio-scsi|usb]] [--sd IMG] [--audio]
#                       [--bootscript FILE] [--add FILE:PATH]... [--desktop] [--bfs-shell PATH]
#                       [--secs N] [--until REGEX] [--shot-every N] [--label L] [--vnc] [--gdb] [--keep]
#                       [--serial-sock]
#                       [-- extra qemu args]
#
# IMG defaults to sources/haiku-x86/generated.x86_64/haiku-nightly-anyboot.iso; it is never written: the
# guest runs on a qcow2 overlay. --bootscript FILE (installed as ~/config/settings/boot/UserBootscript, the
# arm64 tests' convention: tagged lines to /dev/dprintf, which the kernel copies to COM1), --add FILE:PATH
# (scripts/image-add.sh) and --desktop (ships "Locale settings", so the first boot goes to the desktop, not
# to FirstBootPrompt) work on a sparse raw copy of IMG first; --bfs-shell names the bfs_shell for that
# (default: the one sources/haiku-x86's build made).
#
# Machine: q35 (ICH9 AHCI) by default; --disk ide selects -machine pc (PIIX IDE). UEFI = QEMU's
# edk2-x86_64-code.fd + a per-run copy of edk2-i386-vars.fd (OVMF_CODE/OVMF_VARS in local.conf override);
# BIOS = SeaBIOS. virtio-blk is not offered: x86_64 images have no virtio_block driver (packages/Haiku).
# --legacy-virtio: virtio-scsi and virtio-net as legacy devices (disable-modern=on: I/O-port BARs).
# xHCI with a USB keyboard and tablet, std VGA, user-mode networking, SMP 4, 4 GB.
#
# Output in artifacts/qemu-x86/: <ts>-<label>.log (COM1), <ts>-<label>-tNNN.png every --shot-every s (default
# 20, 0 = off) and <ts>-<label>.png at the end. The run ends when the guest powers off (shutdown), when the
# serial log matches --until REGEX, or after --secs N (0 = no limit); then the summary: the end reason, the
# time, PANIC / KDL / page-fault lines. A QMP socket (scripts/qmp-hmp.py, qmp-screendump.py) is in the run
# directory, printed at the start; the run directory (overlay, vars) is removed afterwards unless --keep.
# --serial-sock: COM1 is also a unix socket, <run dir>/serial.sock (the log is kept as before): type kernel
# debugger commands into it (scripts/kdl-x86.py) after the guest enters KDL.
# Exit status: 0 = powered off or --until matched, 1 = --secs ran out first, 2 = usage.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
[ -f "$root/local.conf" ] && . "$root/local.conf"
img="$root/sources/haiku-x86/generated.x86_64/haiku-nightly-anyboot.iso"
bfs="$root/sources/haiku-x86/generated.x86_64/objects/linux/x86_64/release/tools/bfs_shell/bfs_shell"
fw=uefi machine="" disk=ahci smp=4 topo="" mem=4G nic=virtio scratch="" scratchdisk=ahci sd="" audio=0 legacy=""
serialsock=0 bootscript="" adds=() desktop=0 secs=0 until="" every=20 label=x86 display=(-display none) gdb=() keep=0
while [ $# -gt 0 ]; do
	case "$1" in
	--image) img="$2"; shift 2 ;;
	--fw) fw="$2"; shift 2 ;;
	--machine) machine="$2"; shift 2 ;;
	--disk) disk="$2"; shift 2 ;;
	--smp) smp="$2"; shift 2 ;;
	--topo) topo="$2"; shift 2 ;;
	--mem) mem="$2"; shift 2 ;;
	--nic) nic="$2"; shift 2 ;;
	--scratch) scratch="$(realpath "$2")"; shift 2 ;;
	--scratch-disk) scratchdisk="$2"; shift 2 ;;
	--sd) sd="$(realpath "$2")"; shift 2 ;;
	--audio) audio=1; shift ;;
	--legacy-virtio) legacy=",disable-modern=on"; shift ;;
	--bootscript) bootscript="$(realpath "$2")"; shift 2 ;;
	--add) adds+=("$2"); shift 2 ;;
	--desktop) desktop=1; shift ;;
	--bfs-shell) bfs="$2"; shift 2 ;;
	--secs) secs="$2"; shift 2 ;;
	--until) until="$2"; shift 2 ;;
	--shot-every) every="$2"; shift 2 ;;
	--label) label="$2"; shift 2 ;;
	--vnc) display=(-vnc :8); shift ;;
	--gdb) gdb=(-s -S); shift ;;
	--keep) keep=1; shift ;;
	--serial-sock) serialsock=1; shift ;;
	--) shift; break ;;
	*) echo "qemu-x86: unknown option $1" >&2; exit 2 ;;
	esac
done
[ -f "$img" ] || { echo "qemu-x86: no image $img" >&2; exit 2; }
img="$(realpath "$img")"
[ -n "$machine" ] || { [ "$disk" = ide ] && machine=pc || machine=q35; }
qemu="${QEMU_X86:-qemu-system-x86_64}"
fwdir="$(dirname "$(command -v "$qemu")")/../share/qemu"
code="${OVMF_CODE:-$fwdir/edk2-x86_64-code.fd}" vars="${OVMF_VARS:-$fwdir/edk2-i386-vars.fd}"

out="$root/artifacts/qemu-x86"
ts="$(date +%Y%m%d-%H%M%S)"
run="$out/run-$ts-$label"
log="$out/$ts-$label.log"
mkdir -p "$run"
qpid=""
cleanup() {
	[ -n "$qpid" ] && kill "$qpid" 2>/dev/null || true
	[ "$keep" = 1 ] || rm -rf "$run"
}
trap cleanup EXIT

# the image the guest sees: IMG itself, or a raw copy with the requested files in its BFS partition
base="$img"
files=("${adds[@]+"${adds[@]}"}")
[ -n "$bootscript" ] && files+=("$bootscript:/boot/home/config/settings/boot/UserBootscript")
[ "$desktop" = 1 ] && files+=("$root/tools/build/data/Locale settings:/boot/home/config/settings/Locale settings")
if [ ${#files[@]} -gt 0 ]; then
	base="$run/image.raw"
	cp --sparse=always "$img" "$base"
	"$root/scripts/image-add.sh" --bfs-shell "$bfs" --in-place "$base" "${files[@]}" | sed 's/^/qemu-x86: /'
fi

cmd=("$qemu" -machine "$machine,accel=kvm" -cpu host -smp "$smp${topo:+,$topo}" -m "$mem")
if [ "$fw" = uefi ]; then
	cp "$vars" "$run/vars.fd"
	cmd+=(-drive "if=pflash,format=raw,readonly=on,file=$code" -drive "if=pflash,format=raw,file=$run/vars.fd")
elif [ "$fw" != bios ]; then
	echo "qemu-x86: --fw uefi|bios" >&2; exit 2
fi
cmd+=(-device qemu-xhci,id=xhci -device usb-kbd,bus=xhci.0 -device usb-tablet,bus=xhci.0)
if [ "$disk" = cdrom ]; then
	cmd+=(-drive "file=$base,if=none,id=cd0,media=cdrom,readonly=on,format=raw"
		-device ide-cd,drive=cd0,bus=ide.0,bootindex=0)
else
	qemu-img create -q -f qcow2 -b "$base" -F raw "$run/disk.qcow2"
	cmd+=(-drive "file=$run/disk.qcow2,if=none,format=qcow2,id=hd0")
	case "$disk" in
	ahci|ide) cmd+=(-device ide-hd,drive=hd0,bus=ide.0,bootindex=0) ;;
	nvme) cmd+=(-device nvme,drive=hd0,serial=h22,bootindex=0) ;;
	virtio-scsi) cmd+=(-device "virtio-scsi-pci,id=vs$legacy" -device scsi-hd,drive=hd0,bus=vs.0,bootindex=0) ;;
	usb) cmd+=(-device usb-storage,bus=xhci.0,drive=hd0,bootindex=0) ;;
	*) echo "qemu-x86: --disk ahci|nvme|virtio-scsi|usb|ide|cdrom" >&2; exit 2 ;;
	esac
fi
if [ -n "$scratch" ]; then
	cmd+=(-drive "file=$scratch,if=none,format=raw,id=sc0")
	case "$scratchdisk" in
	ahci) cmd+=(-device ide-hd,drive=sc0,bus=ide.1) ;;
	nvme) cmd+=(-device nvme,drive=sc0,serial=h22scratch) ;;
	virtio-scsi) cmd+=(-device virtio-scsi-pci,id=vs1 -device scsi-hd,drive=sc0,bus=vs1.0) ;;
	usb) cmd+=(-device usb-storage,bus=xhci.0,drive=sc0) ;;
	*) echo "qemu-x86: --scratch-disk ahci|nvme|virtio-scsi|usb" >&2; exit 2 ;;
	esac
fi
[ -n "$sd" ] && cmd+=(-drive "file=$sd,if=none,format=raw,id=sd0" -device sdhci-pci -device sd-card,drive=sd0)
[ "$audio" = 1 ] && cmd+=(-audiodev none,id=snd -device intel-hda -device hda-duplex,audiodev=snd)
case "$nic" in
virtio) if [ -n "$legacy" ]; then cmd+=(-netdev user,id=n0 -device "virtio-net-pci,netdev=n0$legacy")
	else cmd+=(-nic user,model=virtio-net-pci); fi ;;
e1000|rtl8139) cmd+=(-nic "user,model=$nic") ;;
none) cmd+=(-nic none) ;;
*) echo "qemu-x86: --nic virtio|e1000|rtl8139|none" >&2; exit 2 ;;
esac
if [ "$serialsock" = 1 ]; then
	serial=(-chardev "socket,id=com1,path=$run/serial.sock,server=on,wait=off,logfile=$log" -serial chardev:com1)
else
	serial=(-serial "file:$log")
fi
cmd+=(-vga std "${display[@]}" "${serial[@]}" -monitor none -qmp "unix:$run/qmp.sock,server,nowait"
	"${gdb[@]}" "$@")
echo "qemu-x86: ${cmd[*]}" >&2
echo "qemu-x86: serial $log, QMP $run/qmp.sock" >&2

shot() { "$root/scripts/qmp-screendump.py" "$run/qmp.sock" "$1" 2>/dev/null || true; }
"${cmd[@]}" < /dev/null > "$run/qemu.out" 2>&1 &
qpid=$!
t0=$SECONDS reason="" rc=0 next=$every
while kill -0 "$qpid" 2>/dev/null; do
	sleep 1
	t=$((SECONDS - t0))
	if [ -n "$until" ] && [ -f "$log" ] && grep -a -q -E "$until" "$log"; then
		reason="--until matched after $t s"; break
	fi
	if [ "$secs" -gt 0 ] && [ "$t" -ge "$secs" ]; then
		reason="--secs $secs ran out"; rc=1; break
	fi
	if [ "$every" -gt 0 ] && [ "$t" -ge "$next" ]; then
		shot "$out/$ts-$label-t$(printf %03d "$t").png"
		next=$((next + every))
	fi
done
if kill -0 "$qpid" 2>/dev/null; then
	shot "$out/$ts-$label.png"
	timeout 5 "$root/scripts/qmp-hmp.py" "$run/qmp.sock" quit > /dev/null 2>&1 || true
	for _ in 1 2 3 4 5; do kill -0 "$qpid" 2>/dev/null || break; sleep 1; done
	kill "$qpid" 2>/dev/null || true
else
	reason="guest powered off after $((SECONDS - t0)) s"
fi
wait "$qpid" 2>/dev/null || true
qpid=""
[ -s "$run/qemu.out" ] && sed 's/^/qemu-x86: qemu: /' "$run/qemu.out" >&2
echo "qemu-x86: $reason; serial $(wc -l < "$log") lines: $log"
[ -f "$out/$ts-$label.png" ] && echo "qemu-x86: screenshot $out/$ts-$label.png"
grep -a -n -E 'PANIC|panic:|Kernel Debugging Land|vm_page_fault' "$log" | head -n 10 \
	| sed 's/^/qemu-x86: !! /' || true
exit "$rc"
