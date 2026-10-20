#!/usr/bin/env bash
# make-bootstrap-shim.sh NAME VERSION PACKAGE WHAT — artifacts/packages/NAME-VERSION-any.hpkg, an empty
# package that only exists to give an arm64 bootstrap package its data: such packages (the build's
# PACKAGE-<version>_bootstrap-1) were built with their data directories under
# /packages/NAME-VERSION/.self/..., a package name they are not activated under, so the data is not
# found. packagefs gives every activated package a /packages/<name>-<version>/.self link to its
# installation location (/boot/system), so a package activated as NAME-VERSION makes that path lead
# to /boot/system, where PACKAGE puts its data. The shim requires PACKAGE. Remove a shim once its
# package is rebuilt for arm64.
#
#   scripts/make-bootstrap-shim.sh ncurses6_bootstrap 6.6-1 ncurses6 "the terminfo database (data/terminfo)"
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -eq 4 ] || { echo "usage: $0 NAME VERSION PACKAGE WHAT" >&2; exit 2; }
name="$1" version="$2" package="$3" what="$4"
tools="$root/sources/haiku/generated.arm64/objects/linux/x86_64/release/tools"
out="$root/artifacts/packages/$name-$version-any.hpkg"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/.PackageInfo" <<INFO
name			$name
version			$version
architecture	any
summary			"The data directory of the arm64 $package bootstrap package"
description		"Activated as $name-$version, it makes the data directory the arm64 $package bootstrap package was built with (under /packages/$name-$version/.self) lead to the data $package installs: $what."
packager		"haiku-pi <https://github.com/haiku-pi>"
vendor			"Haiku Project"
copyrights		"2026 haiku-pi"
licenses		"MIT"
provides {
	$name = $version
}
requires {
	$package
}
INFO
mkdir -p "$(dirname "$out")"
rm -f "$out"
LD_LIBRARY_PATH="$tools/../lib" "$tools/package/package" create -q -C "$tmp" "$out"
echo "make-bootstrap-shim: $out"
