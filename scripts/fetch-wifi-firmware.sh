#!/usr/bin/env bash
# fetch-wifi-firmware.sh — the Raspberry Pi 4 WiFi chip's (BCM43455) firmware for Haiku's
# broadcomfmac driver, from linux-firmware, pinned to one tag, and the same chip's Bluetooth patch
# RAM file for the bcm2711_bt driver, from the Raspberry Pi's bluez-firmware repository, pinned to
# one commit; all checked by SHA-256.
#
#   scripts/fetch-wifi-firmware.sh
#
# Into artifacts/wifi-firmware/: the files under the names the drivers ask for
# (brcmfmac43455-sdio.{bin,clm_blob,txt}, BCM4345C0.hcd) and their licences. The WiFi firmware is
# redistributable (LICENCE.cypress), the Pi 4 NVRAM file is GPL-2.0 (linux-firmware WHENCE), the
# Bluetooth patch is redistributable by Broadcom's permission (bluez-firmware debian/copyright):
# none goes into the MIT source tree, scripts/mkimage-pi4.sh copies them into the image
# (/boot/system/non-packaged/data/firmware/broadcomfmac/ and .../firmware/brcm/).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/artifacts/wifi-firmware"
tag=20260810
base="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain"
# name in the image | path in linux-firmware | sha256
files=(
	"brcmfmac43455-sdio.bin|cypress/cyfmac43455-sdio.bin|d408faa9d0d5b1a2f9912dcea53ab0be48217288e398406d117f0edafe7c3edd"
	"brcmfmac43455-sdio.clm_blob|cypress/cyfmac43455-sdio.clm_blob|15f50a27020b263d1bea215c8f68d0550d912932d1d9ef19ffd59f18d82dd460"
	"brcmfmac43455-sdio.txt|brcm/brcmfmac43455-sdio.raspberrypi,4-model-b.txt|edb6f4e4fb19e18940004124feb4ffe160d72fc607243a07a4480338a28b2748"
	"LICENCE.cypress|LICENSES/LICENCE.cypress|ae0db6cc4db33941148df0f67de53e76a77b1b5a46b3165edb7040aa2750015f"
	"GPL-2.0|LICENSES/GPL-2.0|edaef632cbb643e4e7a221717a6c441a4c1a7c918e6e4d56debc3d8739b233f6"
)
# Bluetooth: name in the image | URL | sha256
btCommit=6851250bf9d51ff50e3c5b2cf2111e2419d4335b
btBase="https://raw.githubusercontent.com/RPi-Distro/bluez-firmware/$btCommit"
btFiles=(
	"BCM4345C0.hcd|$btBase/broadcom/BCM4345C0.hcd|51c45e77ddad91a19e96dc8fb75295b2087c279940df2634b23baf71b6dea42c"
	"BCM-LEGAL.txt|$btBase/broadcom/BCM-LEGAL.txt|092aaac7a0743f6e98ef224dfd68cac7554aa267581121fadcace8599b7d29dd"
	"copyright.bluez-firmware|$btBase/debian/copyright|611b9f690d41e3cb200d66b1c9c5b23172be40d1f6ca4e59efb2b8232c476ad3"
)
mkdir -p "$out"
# fetch NAME URL SHA256: into $out/NAME unless it is there already
fetch() {
	local name="$1" url="$2" sum="$3"
	if [ -f "$out/$name" ] && echo "$sum  $out/$name" | sha256sum -c --quiet 2>/dev/null; then
		return
	fi
	curl -fsSL --retry 3 -o "$out/$name.tmp" "$url"
	echo "$sum  $out/$name.tmp" | sha256sum -c --quiet \
		|| { echo "fetch-wifi-firmware: $url does not match its pinned SHA-256" >&2; exit 1; }
	mv "$out/$name.tmp" "$out/$name"
}
for entry in "${files[@]}"; do
	IFS='|' read -r name path sum <<< "$entry"
	fetch "$name" "$base/$path?h=$tag" "$sum"
done
for entry in "${btFiles[@]}"; do
	IFS='|' read -r name url sum <<< "$entry"
	fetch "$name" "$url" "$sum"
done
echo "$tag" > "$out/TAG"
echo "$btCommit" > "$out/BT_COMMIT"
echo "wifi-firmware: linux-firmware $tag, bluez-firmware ${btCommit:0:12} -> $out"
