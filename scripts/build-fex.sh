#!/usr/bin/env bash
# build-fex.sh — FEX's Wine DLLs: the x86 emulators Wine on arm64 loads to run x86-64 programs (ARM64EC:
# libarm64ecfex.dll) and, as an alternative to Box64, 32-bit x86 programs (WoW64: libwow64fex.dll)
# (H15 step 3, docs/design/wine-x86.md). Windows PE DLLs built with the llvm-mingw of scripts/build-wine.sh;
# FEX's Linux side (FEXInterpreter, FEXServer) is not needed.
#
#   scripts/build-fex.sh
#
# Source: the newest release's tag archive (FEX-2610, pinned SHA-256; owner 2026-10-21: the newest numbered
# release, never master) into sources/fex/. A tag archive has no submodules: the ones the MinGW build adds
# (fmt, xxHash, range-v3, unordered_dense, rpmalloc, cpp-optparse) are fetched as archives of the commits the
# tag pins (from `gh api repos/FEX-Emu/FEX/contents/External?ref=FEX-2610`), each with a pinned SHA-256 too.
# patches/fex/*.patch, if any, on the copy sources/fex/fex-haiku.
#
# Not built: FEX's Unix library (Source/Windows/UnixLib, libarm64ecfex.so): Linux-only (prctl, shm_open), and
# every use of it in the DLLs is optional — without it FEX has no hardware-TSO switch (no such thing on the
# Cortex-A72), no unaligned-atomic prctl, no VMA names, no SHM statistics and no file-backed code cache.
#
# Output: artifacts/fex/libarm64ecfex.dll and libwow64fex.dll (debug info stripped); the unstripped DLLs (for
# llvm-symbolizer) stay in artifacts/fex/build-{arm64ec,wow64}/Bin/. scripts/build-wine.sh install copies
# them next to Wine's DLLs (libarm64ecfex.dll also as xtajit64.dll, the emulator Wine's ARM64EC ntdll loads
# by default: HKLM\Software\Microsoft\Wow64\amd64).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
version=FEX-2610
sha=86509a0d1dcdfaaf68e9f98ddfa78eda6fe5727e72829dc69490f83471874285
# the commit the tag names (FEX reports it; a tag archive has no .git to read it from)
commit=14c92681f4d62cf84d901460e0358de09c8847a7
# submodules: path in the tree, GitHub repository, commit, SHA-256 of its archive
submodules=(
	"External/fmt fmtlib/fmt c07e2aa4b130b4fd359a1c6455a5201b17af01fa e0099a9035521b29523915fae2e5f1b38229df896191e4a046f7b0d55a45c7d2"
	"External/xxhash Cyan4973/xxHash e626a72bc2321cd320e953a0ccf1584cad60f363 34e71c085636fbc1726482996d92719d0a16e6a6097970ecf2990a27b3821162"
	"External/range-v3 ericniebler/range-v3 ca1388fb9da8e69314dda222dc7b139ca84e092f 57a6fca5d60a85b84e8efecc62f0ca064e6b1f89b97b513284fe7f5bd43d49eb"
	"External/unordered_dense martinus/unordered_dense 3234af2c03549bc85656bfd3a86993bf1cd8aef1 aa68d77ef88475db710bf647017f5ccb13ceec6f55f3defa37e995b043eb990b"
	"External/rpmalloc FEX-Emu/rpmalloc 09142d726429416bfa7b459151515fe3ab7622dd 3250fcc53532ed6161642b77f6179c7ba73173fb2130314aa7f019a574266ff6"
	"Source/Common/cpp-optparse Sonicadvance1/cpp-optparse 9f94388a339fcbb0bc95c17768eb786c85988f6e 68e6b500890270517d226abbc3610135de1600ddde29f44c9b68cca5e2a17f60"
)
srcDir="$root/sources/fex"
src="$srcDir/fex-haiku"
out="$root/artifacts/fex"
mingw="$root/sources/wine/llvm-mingw-20260826-ucrt-ubuntu-22.04-x86_64/bin"
[ -x "$mingw/arm64ec-w64-mingw32-clang" ] || { echo "build-fex: run scripts/build-wine.sh source first" >&2; exit 1; }

fetch() {	# URL FILE SHA256: a file already there is checked, a downloaded one checked again
	[ -f "$2" ] && echo "$3  $2" | sha256sum -c --quiet 2> /dev/null && return 0
	curl -fsSL -o "$2" "$1"
	echo "$3  $2" | sha256sum -c --quiet || { echo "build-fex: $2: wrong SHA-256" >&2; exit 1; }
}

mkdir -p "$srcDir"
fetch "https://github.com/FEX-Emu/FEX/archive/refs/tags/$version.tar.gz" "$srcDir/$version.tar.gz" "$sha"
rm -rf "$srcDir/FEX-$version" "$src"
tar -xf "$srcDir/$version.tar.gz" -C "$srcDir"
mv "$srcDir/FEX-$version" "$src"
for s in "${submodules[@]}"; do
	read -r path repo rev ssha <<< "$s"
	archive="$srcDir/${repo#*/}-$rev.tar.gz"
	fetch "https://github.com/$repo/archive/$rev.tar.gz" "$archive" "$ssha"
	rm -rf "${src:?}/$path"
	mkdir -p "$src/$path"
	tar -xf "$archive" -C "$src/$path" --strip-components=1
done
for p in "$root"/patches/fex/*.patch; do
	[ -f "$p" ] || continue
	patch -d "$src" -p1 --quiet < "$p"
done

export PATH="$mingw:$PATH"
build() {	# TRIPLE DIR TARGET DLL
	local dir="$out/$2"
	rm -rf "$dir"
	mkdir -p "$dir"
	# as Hangover builds them (.packaging/*/fexpeec/Dockerfile), with debug info and no host tuning (TUNE_CPU:
	# the default, native, would tune for this x86 host); LTO off (as Hangover; lld's LTO on ARM64EC is young)
	(cd "$dir" && cmake "$src" -DCMAKE_TOOLCHAIN_FILE="$src/Data/CMake/toolchain_mingw.cmake" \
		-DMINGW_TRIPLE="$1" -DCMAKE_BUILD_TYPE=RelWithDebInfo -DENABLE_LTO=False -DTUNE_CPU=none \
		-DBUILD_TESTING=False -DENABLE_ASSERTIONS=False -DENABLE_JEMALLOC_GLIBC_ALLOC=False -DENABLE_CCACHE=False \
		-DOVERRIDE_VERSION="$version" -DOVERRIDE_HASH="$commit" > cmake.log 2>&1) \
		|| { tail -n 20 "$dir/cmake.log" >&2; exit 1; }
	(cd "$dir" && "$root/scripts/heavy-build.sh" -- make -j{JOBS} "$3" > build.log 2>&1) \
		|| { tail -n 30 "$dir/build.log" >&2; exit 1; }
	cp "$dir/Bin/$4" "$out/"
	llvm-strip --strip-debug "$out/$4"
}
build arm64ec-w64-mingw32 build-arm64ec arm64ecfex libarm64ecfex.dll
build aarch64-w64-mingw32 build-wow64 wow64fex libwow64fex.dll
grep -h 'warning:' "$out"/build-*/build.log | sort | uniq -c | sort -rn | head -n 20 || true
ls -l "$out"/*.dll
