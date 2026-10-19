#!/usr/bin/env bash
# bootstrap.sh — set up a fresh checkout of this repository: clone the sources (our forks' rpi4
# branches, HaikuPorts, U-Boot at the commit the images are built from) into sources/, configure the
# Haiku arm64 build (cross tools) in sources/haiku/generated.arm64, and fetch the Pi firmware.
# Afterwards, see docs/TRY-IT.md for the build.
#
#   scripts/bootstrap.sh
#
# Needs: git, a host toolchain for Haiku's build (see Haiku's "Pre-requisite software" docs), the
# aarch64-linux-gnu cross compiler (U-Boot), meson, ninja, cmake, python3, mtools, sfdisk.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
uboot=8d534cec
	# U-Boot commit the images are built from (scripts/build-uboot.sh adds patches/u-boot)

clone() {	# URL DIR [BRANCH]
	local url="$1" dir="$root/sources/$2" branch="${3:-}"
	if [ -d "$dir/.git" ]; then
		echo "bootstrap: $2 exists"
		return
	fi
	git clone -q ${branch:+--branch "$branch"} "$url" "$dir"
	echo "bootstrap: cloned $2"
}
mkdir -p "$root/sources"
clone https://github.com/haiku-pi/haiku.git haiku rpi4
clone https://github.com/haiku-pi/buildtools.git buildtools
clone https://github.com/haiku-pi/mesa.git mesa rpi4
clone https://github.com/haiku-pi/libdrm.git libdrm rpi4
clone https://github.com/haiku-pi/libglvnd.git libglvnd rpi4
clone https://github.com/haikuports/haikuports.git haikuports
clone https://source.denx.de/u-boot/u-boot.git u-boot
git -C "$root/sources/u-boot" checkout -q "$uboot"

# the Haiku build: cross tools for arm64, in the output directory scripts/build.sh uses
gen="$root/sources/haiku/generated.arm64"
if [ ! -f "$gen/build/BuildConfig" ]; then
	mkdir -p "$gen"
	(cd "$gen" && ../configure --build-cross-tools arm64 --cross-tools-source ../../buildtools \
		-j"$(nproc)")
fi
"$root/scripts/fetch-pi-firmware.sh"
echo "bootstrap: done; next: docs/TRY-IT.md"
