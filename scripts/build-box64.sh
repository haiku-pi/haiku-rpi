#!/usr/bin/env bash
# build-box64.sh — Box64's WoW64 DLL (wowbox64.dll): the x86 emulator Wine on arm64 loads to run
# 32-bit x86 Windows programs (H15, docs/design/wine-x86.md). A Windows arm64 PE DLL, built with the
# llvm-mingw of scripts/build-wine.sh; Box64's Linux binary is not needed (Haiku runs no Linux programs).
#
#   [BOX64_VERSION=0.4.4] scripts/build-box64.sh
#
# Source: the tag archive (pinned SHA-256) into sources/box64/, the version's patches on a copy (box64-haiku):
# 0.4.0 patches/box64 (strcasecmp for wowbox64's own C runtime, which llvm-mingw's does not provide; the TEB as
# FS's base), 0.4.4 patches/box64-0.4.4 (the FS base only: 0.4.4 has its own strcasecmp).
# Box64's CMake project generates wowbox64's source lists, so it is configured for an aarch64 target
# (the host's aarch64-linux-gnu-gcc, only for that) and only the wowbox64 target is built.
# Output: artifacts/box64/wowbox64.dll (the default version) or artifacts/box64-VERSION/wowbox64.dll;
# scripts/build-wine.sh install copies the default one next to Wine's DLLs.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
defaultVersion=0.4.0
version=${BOX64_VERSION:-$defaultVersion}
case $version in
0.4.0) sha=4504b0df2d9ccfcf15b4d0c80664e216dc1170a4f8caeca46e79b93ff47e5e87 patches="$root/patches/box64" ;;
0.4.4) sha=99c6de4f509e46ab1de15df740d0e0ea338a7790efa3f67510dfbb975cc24029 patches="$root/patches/box64-0.4.4" ;;
*) echo "build-box64: no pinned archive for $version" >&2; exit 2 ;;
esac
srcDir="$root/sources/box64"
suffix=; [ "$version" = "$defaultVersion" ] || suffix="-$version"
src="$srcDir/box64-haiku$suffix"
out="$root/artifacts/box64$suffix"
mingw="$root/sources/wine/llvm-mingw-20260826-ucrt-ubuntu-22.04-x86_64/bin"
[ -x "$mingw/aarch64-w64-mingw32-clang" ] || { echo "build-box64: run scripts/build-wine.sh source first" >&2; exit 1; }

mkdir -p "$srcDir"
archive="$srcDir/box64-$version.tar.gz"
if ! { [ -f "$archive" ] && echo "$sha  $archive" | sha256sum -c --quiet 2> /dev/null; }; then
	curl -fsSL -o "$archive" "https://github.com/ptitSeb/box64/archive/refs/tags/v$version.tar.gz"
	echo "$sha  $archive" | sha256sum -c --quiet || { echo "build-box64: wrong SHA-256" >&2; exit 1; }
fi
rm -rf "$srcDir/box64-$version" "$src"
tar -xf "$archive" -C "$srcDir"
mv "$srcDir/box64-$version" "$src"
for p in "$patches"/*.patch; do
	patch -d "$src" -p1 --quiet < "$p"
done

rm -rf "$out/build"
mkdir -p "$out/build"
export PATH="$mingw:$PATH"
(cd "$out/build" && cmake "$src" -DARM_DYNAREC=ON -DWOW64=ON -DCMAKE_BUILD_TYPE=RelWithDebInfo \
	-DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc -DCMAKE_ASM_COMPILER=aarch64-linux-gnu-gcc > cmake.log 2>&1 \
	&& make -j"$(nproc)" wowbox64 > wowbox64.log 2>&1) || { tail -n 20 "$out/build/wowbox64.log" >&2; exit 1; }
cp "$out/build/wowbox64-prefix/src/wowbox64-build/wowbox64.dll" "$out/"
"$mingw/llvm-strip" --strip-debug "$out/wowbox64.dll"
ls -l "$out/wowbox64.dll"
