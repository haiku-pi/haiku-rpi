#!/usr/bin/env bash
# build-uboot.sh — U-Boot for the Pi 4 (rpi_4_defconfig) from sources/u-boot (an upstream clone)
# plus our patches in patches/u-boot/*.patch, applied to a clean tree each time; and a netboot
# variant, artifacts/uboot/u-boot-netboot.bin.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/sources/u-boot"
git -C "$src" checkout -q -- .
for p in "$root"/patches/u-boot/*.patch; do
	git -C "$src" apply "$p"
	echo "build-uboot: applied $(basename "$p")"
done
mk() { make -C "$src" -s CROSS_COMPILE=aarch64-linux-gnu- "$@"; }

# The netboot variant (scripts/netboot-server.sh): DHCP, the Haiku loader by TFTP, booted with
# "ip=" in its load options (bootargs), which makes it boot from a remote disk on the network.
# Without an answer to DHCP it boots as the SD variant does, so one card serves both ways.
# (no "&" in the command: scripts/config sets it with sed)
# Built first: the tree is built in place, and the SD variant must be the one left there.
mk rpi_4_defconfig
# (PHY_BROADCOM: the BCM54213PE's driver, which sets the PHY's RGMII delays for the device tree's
# "rgmii-rxid": receive clock delayed by the PHY, transmit clock by the MAC — patches/u-boot/0002)
"$src/scripts/config" --file "$src/.config" --enable PHY_BROADCOM --enable USE_BOOTCOMMAND --set-str BOOTCOMMAND \
	'setenv autoload no; if dhcp; then if tftpboot ${kernel_addr_r} EFI/BOOT/BOOTAA64.EFI; then setenv bootargs ip=${ipaddr}:${serverip}:${gatewayip}:${netmask}; bootefi ${kernel_addr_r} ${fdtcontroladdr}; fi; fi; bootflow scan'
mk olddefconfig
mk -j"$(nproc)" > "$root/artifacts/uboot-netboot-build.log" 2>&1
mkdir -p "$root/artifacts/uboot"
cp "$src/u-boot.bin" "$root/artifacts/uboot/u-boot-netboot.bin"
ls -la "$root/artifacts/uboot/u-boot-netboot.bin" | awk '{print "build-uboot: u-boot-netboot.bin " $5 " bytes"}'

mk rpi_4_defconfig
# no autoboot countdown (2 s of every SD boot; a key held at power-on still stops it)
"$src/scripts/config" --file "$src/.config" --set-val BOOTDELAY 0
mk olddefconfig
mk -j"$(nproc)" > "$root/artifacts/uboot-build.log" 2>&1
ls -la "$src/u-boot.bin" | awk '{print "build-uboot: u-boot.bin " $5 " bytes"}'
