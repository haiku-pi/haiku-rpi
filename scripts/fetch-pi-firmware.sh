#!/usr/bin/env bash
# fetch-pi-firmware.sh — the Raspberry Pi 4 boot files from the official raspberrypi/firmware
# repository, pinned to one commit (recorded in artifacts/pi-firmware/COMMIT).
#
#   scripts/fetch-pi-firmware.sh [commit]     (default: the newest commit on master)
#
# Fetches: start4.elf fixup4.dat bcm2711-rpi-4-b.dtb kernel8.img overlays/{disable-bt,miniuart-bt}.dtbo
# into artifacts/pi-firmware/. kernel8.img is used only by the Linux flash lane (tools/flashlane).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/artifacts/pi-firmware"
commit="${1:-$(git ls-remote https://github.com/raspberrypi/firmware.git refs/heads/master | cut -f1)}"
mkdir -p "$out/overlays"
for f in start4.elf fixup4.dat bcm2711-rpi-4-b.dtb kernel8.img overlays/disable-bt.dtbo overlays/miniuart-bt.dtbo; do
	curl -fsSL --retry 3 -o "$out/$f" "https://raw.githubusercontent.com/raspberrypi/firmware/$commit/boot/$f"
done
echo "$commit" > "$out/COMMIT"
(cd "$out" && sha256sum start4.elf fixup4.dat bcm2711-rpi-4-b.dtb kernel8.img overlays/*.dtbo > SHA256SUMS)
echo "pi-firmware: $commit -> $out"
