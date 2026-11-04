#!/usr/bin/env bash
# x86-matrix.sh — the H22 BOOT matrix (docs/design/x86-64-check.md §4.3): scripts/x86-test.sh boot IMAGE in each
# firmware / disk / CPU / memory configuration, IMAGEs alternated per configuration (A, B, A, B ...).
#
#   scripts/x86-matrix.sh [--configs "NAME ..."] IMAGE...      (IMAGE: rpi4, up, kd1 or a path)
#
# Configurations: uefi-ahci uefi-nvme uefi-virtio-scsi uefi-usb bios-ahci bios-ide bios-cdrom uefi-smp1
# uefi-512m uefi-legacy-virtio (virtio-scsi with disable-modern=on: the I/O-port BAR path) uefi-e1000
# uefi-rtl8139 uefi-smt (-smp 4 as 2 cores x 2 threads). Rows go to artifacts/qemu-x86/results.tsv.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
configs="uefi-ahci uefi-nvme uefi-virtio-scsi uefi-usb bios-ahci bios-ide bios-cdrom uefi-smp1 uefi-512m uefi-legacy-virtio uefi-e1000 uefi-rtl8139 uefi-smt"
[ "${1:-}" = --configs ] && { configs="$2"; shift 2; }
[ $# -ge 1 ] || { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
args_of() {
	case "$1" in
	uefi-ahci) echo "--fw uefi --disk ahci" ;;
	uefi-nvme) echo "--fw uefi --disk nvme" ;;
	uefi-virtio-scsi) echo "--fw uefi --disk virtio-scsi" ;;
	uefi-usb) echo "--fw uefi --disk usb" ;;
	bios-ahci) echo "--fw bios --disk ahci" ;;
	bios-ide) echo "--fw bios --disk ide" ;;
	bios-cdrom) echo "--fw bios --disk cdrom" ;;
	uefi-smp1) echo "--fw uefi --disk ahci --smp 1" ;;
	uefi-512m) echo "--fw uefi --disk ahci --mem 512M" ;;
	uefi-legacy-virtio) echo "--fw uefi --disk virtio-scsi --legacy-virtio" ;;
	uefi-e1000) echo "--fw uefi --disk ahci --nic e1000" ;;
	uefi-rtl8139) echo "--fw uefi --disk ahci --nic rtl8139" ;;
	uefi-smt) echo "--fw uefi --disk ahci --topo cores=2,threads=2" ;;
	*) echo "x86-matrix: unknown configuration $1" >&2; return 1 ;;
	esac
}
fails=0
for c in $configs; do
	a=$(args_of "$c") || exit 2
	for image in "$@"; do
		echo "x86-matrix: $c $image"
		# shellcheck disable=SC2086
		"$root/scripts/x86-test.sh" boot "$image" --secs 300 $a 2>&1 | grep -E '^(x86-grade|boot|kernel|qemu) '
		[ "${PIPESTATUS[0]}" = 0 ] || fails=$((fails + 1))
	done
done
echo "x86-matrix: done, $fails runs with a failure"
