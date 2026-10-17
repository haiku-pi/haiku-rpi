#!/usr/bin/env bash
# flashlane-build.sh — assemble the Linux flash lane's TFTP root (artifacts/flashlane/tftp):
# the pinned Pi firmware + Raspberry Pi kernel (scripts/fetch-pi-firmware.sh) and an initramfs
# made of a static arm64 busybox + tools/flashlane/init. No NFS root, no kernel modules
# (GENET and the emmc2 SDHCI are built into the Pi kernel).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
fw="$root/artifacts/pi-firmware"
lane="$root/artifacts/flashlane"
tftp="$lane/tftp"
bb="$lane/bb/usr/bin/busybox-static"

[ -f "$fw/kernel8.img" ] || "$root/scripts/fetch-pi-firmware.sh"
if [ ! -x "$bb" ]; then
	deb="busybox-static_1.38.0-3ubuntu5_arm64.deb"
	(cd "$lane" && curl -fsSLO "https://ports.ubuntu.com/ubuntu-ports/pool/universe/b/busybox/$deb" && dpkg-deb -x "$deb" bb)
fi

rm -rf "$tftp" "$lane/initramfs"
mkdir -p "$tftp" "$lane/initramfs/bin"
cp "$bb" "$lane/initramfs/bin/busybox"
cp "$root/tools/flashlane/init" "$lane/initramfs/init"
chmod 755 "$lane/initramfs/init" "$lane/initramfs/bin/busybox"
(cd "$lane/initramfs" && find . | cpio -o -H newc --quiet | gzip -9 > "$tftp/initramfs.cpio.gz")

cp "$fw/start4.elf" "$fw/fixup4.dat" "$fw/bcm2711-rpi-4-b.dtb" "$fw/kernel8.img" "$tftp/"
mkdir -p "$tftp/overlays"; cp "$fw/overlays/disable-bt.dtbo" "$tftp/overlays/"
cat > "$tftp/config.txt" <<'EOF'
# Haiku-Pi flash lane (scripts/flashlane-build.sh)
arm_64bit=1
enable_uart=1
dtoverlay=disable-bt
kernel=kernel8.img
initramfs initramfs.cpio.gz followkernel
EOF
# The LAST console= is /dev/console, where init (and its HFL lines) writes: keep serial0 last.
echo "console=tty1 console=serial0,115200 rdinit=/init loglevel=4 hfl.host=10.42.0.1 hfl.port=8099" > "$tftp/cmdline.txt"
echo "flashlane: $(ls "$tftp" | tr '\n' ' ')"
