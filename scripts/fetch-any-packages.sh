#!/usr/bin/env bash
# fetch-any-packages.sh — put the architecture-independent ("any") HaikuPorts packages the regular
# (@nightly) arm64 image needs, and that the arm64 build-packages repository lacks, into jam's
# download directory: fonts, sounds, the MIDI soundfont, the user guide and welcome pages, the
# firmware of the USB/PCI WiFi drivers the haiku package requires. They are
# the x86_64 repository's files (an "any" package is the same everywhere), checked against the
# SHA-256s below; sources/haiku's arm64 repository definition lists them.
#
#   scripts/fetch-any-packages.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
download="$root/sources/haiku/generated.arm64/download"
base=https://eu.hpkg.haiku-os.org/haikuports/master/x86_64/current/packages

# package-version-revision sha256
packages=(
	"noto_sans_cjk_jp-2.004-2 42acc6e1f7b805cd0a1515e8db0503d076ca23e7d31106ba9a0362121790ba6e"
	"sounds_community_default-0.1-1 ac3b170b0cad0e22128abd94b994f6a3466e7d8a6ac5438024b44202d1cca26c"
	"timgmsoundfont-2011.12.11-1 bb354146c978402baa6ea43fd77534a8c1ed8aa615d8f545c7deb6bb689e70f0"
	"haiku_userguide-2026_08_11-1 e150dea40b72757277b7899830e40b8829596897e46c3631010c13ccdaa9886f"
	"haiku_userguide_en-2026_08_11-1 6bb65e86c3a7ae7f421b859a020feb1dc9ba1025273985c8067909a432911ac9"
	"haiku_welcome-2026_08_11-1 d977c5402d3f582d3a7d5a5dc912252626e728022d9d98de9a2557e48b0a5cfa"
	"intel_wifi_firmwares-2025_02_11-1 8a8a5cb0aeed4f3ad2cb95b87e980dd85b143c7382985127606d3abacef637a1"
	"realtek_wifi_firmwares-2019_01_02-1 1e5218b7edd1b7e8d5c0e24b718a22ce104a766608272b35446915efcde17c40"
	"ralink_wifi_firmwares-2023_08_04-1 b96ff9d0fc8eb1e3a397a0f62b1e7d0d2cd084cc5d063d7a269afd754f302b1f"
)
mkdir -p "$download"
for entry in "${packages[@]}"; do
	read -r name sum <<< "$entry"
	file="$download/$name-any.hpkg"
	if [ ! -f "$file" ]; then
		curl -sSfL -o "$file.part" "$base/$name-any.hpkg"
		mv "$file.part" "$file"
	fi
	echo "$sum  $file" | sha256sum -c --quiet
	echo "fetch-any-packages: $name"
done
