#!/usr/bin/env bash
# bootstrap.sh — set up a fresh checkout of this repository: clone the sources (our forks' rpi4
# branches, HaikuPorts, U-Boot at the commit the images are built from) into sources/, configure the
# Haiku arm64 build (cross tools) in sources/haiku/generated.arm64, and fetch the Pi firmware.
# Afterwards, see docs/TRY-IT.md for the build.
#
#   scripts/bootstrap.sh
#
# Needs the host tools listed in docs/TRY-IT.md ("Host prerequisites"), including Haiku's own jam.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# the commits the images are built from (the scripts name recipe files of this HaikuPorts tree)
uboot=8d534cec
	# scripts/build-uboot.sh adds patches/u-boot
haikuports=c17ec5a8d2f0a48b3dc2da9118ce11957cef6ba4
firmware=6c87074190d5d364b814dccca83229801a4ac939

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
git -C "$root/sources/haikuports" checkout -q "$haikuports"

# Haiku's build names its revision after the newest hrev tag; only Haiku's own repository has them
# (not our fork, not the GitHub mirror)
if [ -z "$(git -C "$root/sources/haiku" tag -l 'hrev*' | head -n 1)" ]; then
	git -C "$root/sources/haiku" fetch -q --no-tags https://review.haiku-os.org/haiku \
		'refs/tags/hrev*:refs/tags/hrev*'
	echo "bootstrap: fetched Haiku's hrev tags"
fi

# the Haiku build: cross tools for arm64, in the output directory scripts/build.sh uses
gen="$root/sources/haiku/generated.arm64"
if [ ! -f "$gen/build/BuildConfig" ]; then
	mkdir -p "$gen"
	(cd "$gen" && "$root/scripts/heavy-build.sh" --mem-per-job 1 -- ../configure \
		--build-cross-tools arm64 --cross-tools-source ../../buildtools -j"{JOBS}")
fi
# the build never downloads (scripts/build.sh): the upstream build packages, by upstream's definition
"$root/scripts/fetch-build-packages.sh"
"$root/scripts/fetch-pi-firmware.sh" "$firmware"
echo "bootstrap: done; next: docs/TRY-IT.md"
