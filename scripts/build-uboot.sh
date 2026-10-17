#!/usr/bin/env bash
# build-uboot.sh — U-Boot for the Pi 4 (rpi_4_defconfig) from sources/u-boot (an upstream clone)
# plus our patches in patches/u-boot/*.patch, applied to a clean tree each time.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/sources/u-boot"
git -C "$src" checkout -q -- .
for p in "$root"/patches/u-boot/*.patch; do
	git -C "$src" apply "$p"
	echo "build-uboot: applied $(basename "$p")"
done
make -C "$src" -s CROSS_COMPILE=aarch64-linux-gnu- rpi_4_defconfig
make -C "$src" -s CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" > "$root/artifacts/uboot-build.log" 2>&1
ls -la "$src/u-boot.bin" | awk '{print "build-uboot: u-boot.bin " $5 " bytes"}'
