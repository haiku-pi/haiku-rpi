#!/usr/bin/env bash
# fetch-wifi-firmware.sh — the Raspberry Pi 4 WiFi chip's (BCM43455) firmware for Haiku's
# broadcomfmac driver, from linux-firmware, pinned to one tag and checked by SHA-256.
#
#   scripts/fetch-wifi-firmware.sh
#
# Into artifacts/wifi-firmware/: the files under the names the driver asks for
# (brcmfmac43455-sdio.{bin,clm_blob,txt}) and their licences. The firmware is redistributable
# (LICENCE.cypress), the Pi 4 NVRAM file is GPL-2.0 (linux-firmware WHENCE): neither goes into
# the MIT source tree, scripts/mkimage-pi4.sh copies them into the image
# (/boot/system/non-packaged/data/firmware/broadcomfmac/).
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
mkdir -p "$out"
for entry in "${files[@]}"; do
	IFS='|' read -r name path sum <<< "$entry"
	if [ -f "$out/$name" ] && echo "$sum  $out/$name" | sha256sum -c --quiet 2>/dev/null; then
		continue
	fi
	curl -fsSL --retry 3 -o "$out/$name.tmp" "$base/$path?h=$tag"
	echo "$sum  $out/$name.tmp" | sha256sum -c --quiet \
		|| { echo "fetch-wifi-firmware: $path does not match its pinned SHA-256" >&2; exit 1; }
	mv "$out/$name.tmp" "$out/$name"
done
echo "$tag" > "$out/TAG"
echo "wifi-firmware: linux-firmware $tag -> $out"
