#!/usr/bin/env bash
# make-icu-shim.sh — artifacts/packages/icu74_bootstrap-74.1-1-any.hpkg, an empty package that only
# exists to give ICU its data: the arm64 icu74 bootstrap package (the build's icu74-74.1_bootstrap-1)
# was built with its data directory as /packages/icu74_bootstrap-74.1-1/.self/data/icu/74.1, a package
# name it is not activated under, so ICU finds no data (time zones, collation, break iterators:
# U_MISSING_RESOURCE_ERROR) in any process. packagefs gives every activated package a
# /packages/<name>-<version>/.self link to its installation location (/boot/system), so a package
# activated as icu74_bootstrap-74.1-1 makes that path /boot/system/data/icu/74.1, where icu74 puts
# its data. Remove it once icu74 is rebuilt for arm64.
#
#   scripts/make-icu-shim.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tools="$root/sources/haiku/generated.arm64/objects/linux/x86_64/release/tools"
out="$root/artifacts/packages/icu74_bootstrap-74.1-1-any.hpkg"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/.PackageInfo" <<'INFO'
name			icu74_bootstrap
version			74.1-1
architecture	any
summary			"The data directory of the arm64 icu74 bootstrap package"
description		"Activated as icu74_bootstrap-74.1-1, it makes the data directory the arm64 icu74 bootstrap package was built with (/packages/icu74_bootstrap-74.1-1/.self/data/icu/74.1) lead to the data icu74 installs."
packager		"haiku-pi <https://github.com/haiku-pi>"
vendor			"Haiku Project"
copyrights		"2026 haiku-pi"
licenses		"MIT"
provides {
	icu74_bootstrap = 74.1-1
}
requires {
	icu74
}
INFO
mkdir -p "$(dirname "$out")"
rm -f "$out"
LD_LIBRARY_PATH="$tools/../lib" "$tools/package/package" create -q -C "$tmp" "$out"
echo "make-icu-shim: $out"
