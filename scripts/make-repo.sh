#!/usr/bin/env bash
# make-repo.sh — a pkgman repository (HaikuPorts format) of our arm64 packages: artifacts/packages/*.hpkg
# (scripts/build-packages.sh) with their index, for a static HTTP server. Not published anywhere: the bench
# serves it to the Pi (scripts/serve-repo.sh); publishing binaries waits for the owner.
#
#   scripts/make-repo.sh [--out DIR] [--url BASEURL]
#
# Layout (as haikuporter's --create-package-repository): DIR/repo.info, DIR/repo (package_repo create),
# DIR/repo.sha256 (pkgman fetches it first), DIR/packages/*.hpkg (hard links). Unsigned: nothing in Haiku
# checks a .minisig today. On the Pi: pkgman add-repo BASEURL && pkgman refresh.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/artifacts/repo/arm64"
url="http://10.42.0.1:8090/arm64"
while [ $# -gt 0 ]; do
	case "$1" in
	--out) out="$2"; shift 2 ;;
	--url) url="$2"; shift 2 ;;
	*) echo "make-repo: unknown option $1" >&2; exit 1 ;;
	esac
done
tools="$root/sources/haiku/generated.arm64/objects/linux/x86_64/release/tools"
packageRepo="$tools/package_repo/package_repo"
[ -x "$packageRepo" ] || { echo "make-repo: no $packageRepo (scripts/build.sh builds it)" >&2; exit 1; }

rm -rf "$out"
mkdir -p "$out/packages"
ln "$root"/artifacts/packages/*.hpkg "$out/packages/"
cat > "$out/repo.info" <<INFO
name haiku-pi
vendor "Haiku Project"
summary "Packages of the Haiku port to the Raspberry Pi 4 (arm64)"
priority 2
baseurl $url
identifier tag:github.com/haiku-pi,2026:repositories/haiku-pi/arm64
architecture arm64
INFO
# (it writes "repo" into the current directory; its libraries are the build's host libraries)
(cd "$out" && LD_LIBRARY_PATH="$tools/../lib" "$packageRepo" create -q repo.info packages/*.hpkg)
[ -f "$out/repo" ] || { echo "make-repo: package_repo wrote no repo" >&2; exit 1; }
sha256sum "$out/repo" | cut -d' ' -f1 > "$out/repo.sha256"
echo "make-repo: $(ls "$out/packages" | wc -l) packages, $out (base URL $url)"
