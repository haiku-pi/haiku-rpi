#!/usr/bin/env bash
# mkimage-pi4.sh — turn Haiku's arm64 MMC image into a bootable Raspberry Pi 4 SD image.
#
#   scripts/mkimage-pi4.sh [--in haiku-mmc.image] [--out artifacts/images/haiku-pi4.img]
#                          [--kernel-setting "name value"]...   (e.g. "disable_smp true")
#                          [--bootscript FILE]   (installed as ~/config/settings/boot/UserBootscript,
#                                                 run at every boot; its output to /dev/dprintf
#                                                 reaches the serial console: a test channel)
#                          [--add-bin FILE]...   (installed into ~/config/non-packaged/bin, e.g. a
#                                                 test tool built by jam)
#                          [--block-entry PATH]... (hides PATH of the haiku package, e.g.
#                                                 add-ons/kernel/drivers/graphics/v3d: /boot/system/
#                                                 settings/packages BlockedEntries)
#                          [--no-v3d]            (leave the V3D GPU disabled: no haiku-v3d overlay)
#                          [--no-fkms]           (no haiku-fkms overlay: the firmware's KMS node stays
#                                                 disabled, so no SMI vblank interrupt; the display driver
#                                                 then waits on SET_VSYNC)
#                          [--config LINE]...    (appended to config.txt, e.g. "force_turbo=1")
#                          [--add-tree DIR]...   (DIR's files and symlinks, with their relative paths, into
#                                                 /boot/system/non-packaged/, e.g. the GL stack of
#                                                 scripts/build-gl-stack.sh: artifacts/gl-stack/non-packaged)
#
# Adds to the image's FAT partition (p1): the pinned Pi firmware (scripts/fetch-pi-firmware.sh),
# the bcm2711 DTB + overlays, U-Boot (sources/u-boot/u-boot.bin) and config.txt, which loads
# U-Boot; U-Boot's bootflow then starts EFI/BOOT/BOOTAA64.EFI (haiku_loader) from the same partition,
# and the loader boots Haiku from the BFS partition (p2). p1's MBR type is set to 0x0c (FAT32 LBA),
# which every Pi firmware accepts (Haiku's image uses 0xef).
# The BFS partition gets the WiFi chip's firmware (scripts/fetch-wifi-firmware.sh) in
# /boot/system/non-packaged/data/firmware/broadcomfmac/, and its Bluetooth patch RAM file
# (BCM4345C0.hcd, for the bcm2711_bt driver) in /boot/system/non-packaged/data/firmware/brcm/.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
in="$root/sources/haiku/generated.arm64/haiku-mmc.image"
out="$root/artifacts/images/haiku-pi4.img"
settings=()
bootscript=""
bins=()
trees=()
v3dOverlay=haiku-v3d
fkmsOverlay=haiku-fkms
blocked=()
configLines=()
while [ $# -gt 0 ]; do
	case "$1" in
	--in) in="$2"; shift 2 ;;
	--out) out="$2"; shift 2 ;;
	--kernel-setting) settings+=("$2"); shift 2 ;;
	--bootscript) bootscript="$(realpath "$2")"; shift 2 ;;
	--add-bin) bins+=("$(realpath "$2")"); shift 2 ;;
	--add-tree) trees+=("$(realpath "$2")"); shift 2 ;;
	--config) configLines+=("$2"); shift 2 ;;
	--no-v3d) v3dOverlay=""; shift ;;
	--no-fkms) fkmsOverlay=""; shift ;;
	--block-entry) blocked+=("$2"); shift 2 ;;
	*) echo "mkimage-pi4: unknown option $1" >&2; exit 2 ;;
	esac
done
fw="$root/artifacts/pi-firmware"
uboot="$root/sources/u-boot/u-boot.bin"
[ -f "$fw/start4.elf" ] || "$root/scripts/fetch-pi-firmware.sh"
wifi="$root/artifacts/wifi-firmware"
"$root/scripts/fetch-wifi-firmware.sh" > /dev/null
[ -f "$uboot" ] || { echo "mkimage-pi4: build U-Boot first (scripts/build-uboot.sh)" >&2; exit 1; }
mkdir -p "$(dirname "$out")"
cp "$in" "$out.tmp"
sfdisk -q --part-type "$out.tmp" 1 c
off=$(( $(sfdisk -J "$out.tmp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["partitiontable"]["partitions"][0]["start"])') * 512 ))
fat="$out.tmp@@$off"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/config.txt" <<CFG
# Haiku on the Raspberry Pi 4 (haiku-rpi scripts/mkimage-pi4.sh)
arm_64bit=1
kernel=u-boot.bin
# PL011 (uart0) on GPIO14/15 = the console; Bluetooth gets no UART.
enable_uart=1
dtoverlay=disable-bt
# Lets the ARM side power the V3D GPU on (tools/overlays/haiku-v3d.dts)
dtoverlay=$v3dOverlay
# The firmware's KMS node: vertical blanks as SMI interrupts (tools/overlays/haiku-fkms.dts)
dtoverlay=$fkmsOverlay
disable_overscan=1
CFG
for line in "${configLines[@]}"; do
	echo "$line" >> "$tmp/config.txt"
done
dtc -@ -q -I dts -O dtb -o "$tmp/haiku-v3d.dtbo" "$root/tools/overlays/haiku-v3d.dts"
dtc -@ -q -I dts -O dtb -o "$tmp/haiku-fkms.dtbo" "$root/tools/overlays/haiku-fkms.dts"
mcopy -o -i "$fat" "$fw/start4.elf" "$fw/fixup4.dat" "$fw/bcm2711-rpi-4-b.dtb" "$uboot" "$tmp/config.txt" ::
mmd -i "$fat" ::overlays 2>/dev/null || true
mcopy -o -i "$fat" "$fw"/overlays/*.dtbo "$tmp/haiku-v3d.dtbo" "$tmp/haiku-fkms.dtbo" ::overlays/
# The Haiku build's ESP step can leave an empty loader (its FAT copy fails on a stale emulated attribute,
# 10-24): U-Boot then cannot start Haiku from this partition, and a network boot silently uses the card
loaderSize=$(mdir -i "$fat" -b ::EFI/BOOT/BOOTAA64.EFI >/dev/null 2>&1 && mtype -i "$fat" ::EFI/BOOT/BOOTAA64.EFI | wc -c)
[ "${loaderSize:-0}" -gt 100000 ] || { echo "mkimage-pi4: EFI/BOOT/BOOTAA64.EFI is ${loaderSize:-missing} bytes" >&2; exit 1; }

p2=$(( $(sfdisk -J "$out.tmp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["partitiontable"]["partitions"][1]["start"])') * 512 ))
bfs="$root/sources/haiku/generated.arm64/objects/linux/x86_64/release/tools/bfs_shell/bfs_shell"
# (bfs_shell may report a busy unmount at the end of its input: check the results instead)
wifiDir=/myfs/system/non-packaged/data/firmware/broadcomfmac
{
	echo "mkdir -p $wifiDir"
	for f in brcmfmac43455-sdio.bin brcmfmac43455-sdio.clm_blob brcmfmac43455-sdio.txt LICENCE.cypress GPL-2.0; do
		echo "cp :$wifi/$f $wifiDir/$f"
	done
	echo sync
} | "$bfs" --start-offset "$p2" "$out.tmp" > "$tmp/bfs-wifi.log" 2>&1 || true
echo "ls $wifiDir" | "$bfs" --start-offset "$p2" "$out.tmp" 2>&1 \
	| grep -q "$(stat -c %s "$wifi/brcmfmac43455-sdio.bin").*brcmfmac43455-sdio.bin" \
	|| { cat "$tmp/bfs-wifi.log" >&2; echo "mkimage-pi4: WiFi firmware not written" >&2; exit 1; }
btDir=/myfs/system/non-packaged/data/firmware/brcm
{
	echo "mkdir -p $btDir"
	for f in BCM4345C0.hcd BCM-LEGAL.txt copyright.bluez-firmware; do
		echo "cp :$wifi/$f $btDir/$f"
	done
	echo sync
} | "$bfs" --start-offset "$p2" "$out.tmp" > "$tmp/bfs-bt.log" 2>&1 || true
echo "ls $btDir" | "$bfs" --start-offset "$p2" "$out.tmp" 2>&1 \
	| grep -q "$(stat -c %s "$wifi/BCM4345C0.hcd").*BCM4345C0.hcd" \
	|| { cat "$tmp/bfs-bt.log" >&2; echo "mkimage-pi4: Bluetooth firmware not written" >&2; exit 1; }

if [ ${#settings[@]} -gt 0 ]; then
	# kernel settings file on the BFS partition (also read for safemode options)
	printf '%s\n' "${settings[@]}" > "$tmp/kernel"
	printf 'mkdir -p /myfs/home/config/settings/kernel/drivers\ncp %s /myfs/home/config/settings/kernel/drivers/kernel\nsync\n' \
		":$tmp/kernel" | "$bfs" --start-offset "$p2" "$out.tmp" > "$tmp/bfs.log" 2>&1 || true
	echo "cat /myfs/home/config/settings/kernel/drivers/kernel" | "$bfs" --start-offset "$p2" "$out.tmp" 2>&1 \
		| grep -q -F "${settings[0]}" || { cat "$tmp/bfs.log" >&2; echo "mkimage-pi4: kernel settings not written" >&2; exit 1; }
	echo "mkimage-pi4: kernel settings: ${settings[*]}"
fi
if [ ${#blocked[@]} -gt 0 ]; then
	{ echo "Package haiku {"; echo "	BlockedEntries {"; printf '		%s\n' "${blocked[@]}"; echo "	}"; echo "}"; } \
		> "$tmp/packages"
	printf 'mkdir -p /myfs/system/settings\ncp %s /myfs/system/settings/packages\nsync\n' ":$tmp/packages" \
		| "$bfs" --start-offset "$p2" "$out.tmp" > "$tmp/bfs-pkg.log" 2>&1 || true
	echo "cat /myfs/system/settings/packages" | "$bfs" --start-offset "$p2" "$out.tmp" 2>&1 \
		| grep -q -F "${blocked[0]}" || { cat "$tmp/bfs-pkg.log" >&2; echo "mkimage-pi4: package settings not written" >&2; exit 1; }
	echo "mkimage-pi4: blocked entries: ${blocked[*]}"
fi
if [ -n "$bootscript" ]; then
	printf 'mkdir -p /myfs/home/config/settings/boot\ncp %s /myfs/home/config/settings/boot/UserBootscript\nsync\n' \
		":$bootscript" | "$bfs" --start-offset "$p2" "$out.tmp" > "$tmp/bfs-boot.log" 2>&1 || true
	echo "cat /myfs/home/config/settings/boot/UserBootscript" | "$bfs" --start-offset "$p2" "$out.tmp" 2>&1 \
		| grep -q -F "$(head -n 1 "$bootscript")" || { cat "$tmp/bfs-boot.log" >&2; echo "mkimage-pi4: bootscript not written" >&2; exit 1; }
	echo "mkimage-pi4: bootscript $(basename "$bootscript")"
fi
if [ ${#bins[@]} -gt 0 ]; then
	binDir=/myfs/home/config/non-packaged/bin
	{
		echo "mkdir -p $binDir"
		for b in "${bins[@]}"; do echo "cp :$b $binDir/$(basename "$b")"; echo "chmod 755 $binDir/$(basename "$b")"; done
		echo sync
	} | "$bfs" --start-offset "$p2" "$out.tmp" > "$tmp/bfs-bin.log" 2>&1 || true
	for b in "${bins[@]}"; do
		echo "ls $binDir" | "$bfs" --start-offset "$p2" "$out.tmp" 2>&1 | grep -q "$(basename "$b")" \
			|| { cat "$tmp/bfs-bin.log" >&2; echo "mkimage-pi4: $(basename "$b") not written" >&2; exit 1; }
	done
	echo "mkimage-pi4: added ${bins[*]##*/}"
fi
# one bfs_shell argument, double-quoted (bfs_shell splits on blanks; inside quotes only \ and " are
# escaped)
fssh_quote() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }
for tree in ${trees[@]+"${trees[@]}"}; do
	[ -d "$tree" ] || { echo "mkimage-pi4: --add-tree $tree is not a directory" >&2; exit 1; }
	npDir=/myfs/system/non-packaged
	{
		(cd "$tree" && find . -mindepth 1 -type d -printf '%P\n') | sort | while read -r d; do
			echo "mkdir -p $(fssh_quote "$npDir/$d")"
		done
		(cd "$tree" && find . -type f -printf '%P\n') | sort | while read -r f; do
			echo "cp $(fssh_quote ":$tree/$f") $(fssh_quote "$npDir/$f")"
			echo "chmod 755 $(fssh_quote "$npDir/$f")"
		done
		(cd "$tree" && find . -type l -printf '%P\t%l\n') | sort | while IFS=$'\t' read -r l target; do
			echo "ln -sf $(fssh_quote "$target") $(fssh_quote "$npDir/$l")"
		done
		echo sync
	} | "$bfs" --start-offset "$p2" "$out.tmp" > "$tmp/bfs-tree.log" 2>&1 || true
	# verify every file by its size (fixed strings: Unreal Tournament has files named "dm-deck16][.itt")
	(cd "$tree" && find . -type f -printf '%P\n') | while read -r f; do
		echo "ls $(fssh_quote "$npDir/$f")" | "$bfs" --start-offset "$p2" "$out.tmp" 2>&1 \
			| grep -F " $(stat -c %s "$tree/$f") " | grep -qF "$(basename "$f")" \
			|| { cat "$tmp/bfs-tree.log" >&2; echo "mkimage-pi4: $f of $tree not written" >&2; exit 1; }
	done
	echo "mkimage-pi4: added $(cd "$tree" && find . -type f | wc -l) files and $(cd "$tree" && find . -type l | wc -l) symlinks of $tree to /boot/system/non-packaged"
done
mv "$out.tmp" "$out"
echo "mkimage-pi4: $out ($(stat -c %s "$out") bytes, firmware $(cut -c1-12 "$fw/COMMIT"), u-boot $(git -C "$root/sources/u-boot" rev-parse --short HEAD))"
mdir -/ -b -i "$out@@$off" ::
