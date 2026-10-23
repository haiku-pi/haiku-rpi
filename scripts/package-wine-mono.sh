#!/bin/bash
# package-wine-mono.sh — package Wine Mono (the .NET runtime Wine installs into a prefix) for the arm64 repository
#
#   scripts/package-wine-mono.sh [--revision N]      (default 1)
#
# Wine looks for its add-ons in $datadir/wine/<add-on>/ before it asks to download them (appwiz.cpl,
# install_from_default_dir: our datadir is /boot/system/data). With this package installed, creating or
# updating a prefix installs Mono without the "Wine Mono Installer" question, and .NET programs run on
# Mono's arm64 build natively (no x86 translation). Wine 11.20 wants wine-mono 11.3.0, and on aarch64 the
# arm64 .msi (MONO_VERSION, MONO_ARCH and MONO_SHA in dlls/appwiz.cpl/addons.c); there is no arm64 Gecko,
# so Wine never asks for that.
#
# The .msi is the upstream release (github.com/madewokherd/wine-mono), checked against Wine's pinned
# SHA-256; fetched into artifacts/downloads/wine-mono. Output: artifacts/packages/wine_mono-11.3.0-N-arm64.hpkg.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
revision=1
while [ $# -gt 0 ]; do
	case "$1" in
	--revision) revision="$2"; shift 2 ;;
	*) echo "package-wine-mono: unknown option $1" >&2; exit 2 ;;
	esac
done
version=11.3.0
msi="wine-mono-$version-arm64.msi"
sha=b0c47d374efaf22cbff76cb10488ac2d1627b067e085aef7acec573884120e0f
url="https://github.com/madewokherd/wine-mono/releases/download/wine-mono-$version/$msi"
gen="$root/sources/haiku/generated.arm64"
pkgtool="$gen/objects/linux/x86_64/release/tools/package/package"
dl="$root/artifacts/downloads/wine-mono"
out="$root/artifacts/packages"
work="$out/build-wine-mono"

mkdir -p "$dl" "$out"
if ! echo "$sha  $dl/$msi" | sha256sum -c --quiet - 2> /dev/null; then
	curl -fsSL -o "$dl/$msi.part" "$url"
	mv "$dl/$msi.part" "$dl/$msi"
	echo "$sha  $dl/$msi" | sha256sum -c --quiet - \
		|| { echo "package-wine-mono: $msi does not match Wine's SHA-256" >&2; exit 1; }
fi

rm -rf "$work"
mkdir -p "$work/data/wine/mono"
cp "$dl/$msi" "$work/data/wine/mono/"
cat > "$work/.PackageInfo" <<EOF
name			wine_mono
version			$version-$revision
architecture	arm64
summary			"Wine Mono: the .NET runtime for Wine"
description		"Wine Mono $version (arm64), the open source .NET Framework replacement Wine installs into \
a prefix. With it installed, Wine sets Mono up without asking to download it, and .NET programs run on \
Mono's arm64 build. The upstream release, packaged for the Raspberry Pi 4 by the haiku-pi project."
packager		"haiku-pi build farm <build@haiku-pi.invalid>"
vendor			"Haiku Project"
licenses		{ "MIT" "GNU LGPL v2.1" }
copyrights		{ "Esme Povirk and the Wine Mono contributors" "the Mono project contributors" }
provides {
	wine_mono = $version-$revision
}
requires {
	haiku
}
EOF
file="$out/wine_mono-$version-$revision-arm64.hpkg"
rm -f "$out"/wine_mono-*-arm64.hpkg
# the .msi is compressed already
"$pkgtool" create -q -0 -C "$work" -i "$work/.PackageInfo" "$file"
rm -rf "$work"
echo "package-wine-mono: $file ($(stat -c %s "$file") bytes)"
