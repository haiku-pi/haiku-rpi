#!/usr/bin/env bash
# mkimage-pi4.sh — turn Haiku's arm64 MMC image into a bootable Raspberry Pi 4 SD image.
#
#   scripts/mkimage-pi4.sh [--in haiku-mmc.image] [--out artifacts/images/haiku-pi4.img] [--grow MB]
#
# Adds to the image's FAT partition (p1): the pinned Pi firmware (scripts/fetch-pi-firmware.sh),
# the bcm2711 DTB + overlays, U-Boot (sources/u-boot/u-boot.bin) and config.txt, which loads
# U-Boot; U-Boot's bootflow then starts EFI/BOOT/BOOTAA64.EFI (haiku_loader) from the same partition,
# and the loader boots Haiku from the BFS partition (p2). p1's MBR type is set to 0x0c (FAT32 LBA),
# which every Pi firmware accepts (Haiku's image uses 0xef).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
in="$root/sources/haiku/generated.arm64/haiku-mmc.image"
out="$root/artifacts/images/haiku-pi4.img"
while [ $# -gt 0 ]; do
	case "$1" in
	--in) in="$2"; shift 2 ;;
	--out) out="$2"; shift 2 ;;
	*) echo "mkimage-pi4: unknown option $1" >&2; exit 2 ;;
	esac
done
fw="$root/artifacts/pi-firmware"
uboot="$root/sources/u-boot/u-boot.bin"
[ -f "$fw/start4.elf" ] || "$root/scripts/fetch-pi-firmware.sh"
[ -f "$uboot" ] || { echo "mkimage-pi4: build U-Boot first (scripts/build-uboot.sh)" >&2; exit 1; }
mkdir -p "$(dirname "$out")"
cp "$in" "$out.tmp"
sfdisk -q --part-type "$out.tmp" 1 c
off=$(( $(sfdisk -J "$out.tmp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["partitiontable"]["partitions"][0]["start"])') * 512 ))
fat="$out.tmp@@$off"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/config.txt" <<'CFG'
# Haiku on the Raspberry Pi 4 (haiku-rpi scripts/mkimage-pi4.sh)
arm_64bit=1
kernel=u-boot.bin
# PL011 (uart0) on GPIO14/15 = the console; Bluetooth gets no UART.
enable_uart=1
dtoverlay=disable-bt
disable_overscan=1
CFG
mcopy -o -i "$fat" "$fw/start4.elf" "$fw/fixup4.dat" "$fw/bcm2711-rpi-4-b.dtb" "$uboot" "$tmp/config.txt" ::
mmd -i "$fat" ::overlays 2>/dev/null || true
mcopy -o -i "$fat" "$fw"/overlays/*.dtbo ::overlays/
mv "$out.tmp" "$out"
echo "mkimage-pi4: $out ($(stat -c %s "$out") bytes, firmware $(cut -c1-12 "$fw/COMMIT"), u-boot $(git -C "$root/sources/u-boot" rev-parse --short HEAD))"
mdir -/ -b -i "$out@@$off" ::
