#!/usr/bin/env bash
# build-python-modules.sh — cross-build the compression modules the HaikuPorts arm64 bootstrap python3.10
# lacks (zlib, _bz2, _lzma), so that haikuporter (tarfile, zipfile) can unpack .tar.gz/.tar.bz2/.tar.xz
# and .zip sources on the Pi. Without them every port stops at "Unrecognized archive type".
#
#   scripts/build-python-modules.sh [--out DIR]     (default artifacts/python-modules)
#
# Output: DIR/non-packaged/lib/python3.10/lib-dynload/{zlib,_bz2,_lzma}.cpython-310.so (mkimage-pi4.sh
# --add-tree DIR/non-packaged). bzip2 and liblzma are linked in statically
# (the bootstrap package set has neither); zlib comes from the sysroot (zlib is part of the dev image).
# The test scripts add /boot/system/non-packaged/lib/python3.10/lib-dynload to PYTHONPATH. Needs
# scripts/haiku-sysroot.sh's sysroot and the jam-built cross compiler.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/artifacts/python-modules"
while [ $# -gt 0 ]; do
	case "$1" in
	--out) out="$2"; shift 2 ;;
	*) echo "build-python-modules: unknown option $1" >&2; exit 2 ;;
	esac
done
gen="$root/sources/haiku/generated.arm64"
sysroot="$root/artifacts/sysroot-arm64"
tools="$gen/cross-tools-arm64/bin/aarch64-unknown-haiku"
pkgtool="$gen/objects/linux/x86_64/release/tools/package/package"
[ -d "$sysroot/boot/system/develop" ] || { echo "build-python-modules: run scripts/haiku-sysroot.sh first" >&2; exit 1; }
cc="$tools-gcc --sysroot=$sysroot"

# name|url|sha256 (python: the version of the bootstrap package)
sources=(
	"cpython-3.10.19|https://github.com/python/cpython/archive/refs/tags/v3.10.19.tar.gz|f17bfa7f531634cae186e3c1d6a6f48704febeddf86c59a3998bf4e7d128191f"
	"bzip2-1.0.8|https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz|ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269"
	"xz-5.6.4|https://github.com/tukaani-project/xz/releases/download/v5.6.4/xz-5.6.4.tar.gz|269e3f2e512cbd3314849982014dc199a7b2148cf5c91cedc6db629acdf5e09b"
)
work="$out/build"
dynload="$out/non-packaged/lib/python3.10/lib-dynload"
mkdir -p "$work/dl" "$dynload"
for s in "${sources[@]}"; do
	IFS='|' read -r name url sum <<< "$s"
	archive="$work/dl/$name.tar.gz"
	[ -f "$archive" ] || curl -sSfL -o "$archive" "$url"
	echo "$sum  $archive" | sha256sum -c --quiet
	rm -rf "$work/$name"
	mkdir -p "$work/$name"
	tar -xzf "$archive" -C "$work/$name" --strip-components=1
done

# the python headers of the bootstrap package (not in the sysroot)
pyhpkg=$(ls "$gen"/download/python3.10-*-arm64.hpkg | head -n 1)
rm -rf "$work/python3.10"
mkdir -p "$work/python3.10"
"$pkgtool" extract -C "$work/python3.10" "$pyhpkg"
pyinc="$work/python3.10/develop/headers/python3.10"

# bzip2: a static PIC archive
bz="$work/bzip2-1.0.8"
for f in blocksort huffman crctable randtable compress decompress bzlib; do
	$cc -O2 -fPIC -D_FILE_OFFSET_BITS=64 -c "$bz/$f.c" -o "$bz/$f.o"
done
"$tools-ar" rcs "$bz/libbz2.a" "$bz"/*.o

# liblzma: a static PIC archive, nothing else of xz
xz="$work/xz-5.6.4"
(cd "$xz" && ./configure -q --host=aarch64-unknown-haiku CC="$cc" --disable-shared --enable-static \
	--with-pic --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo --disable-lzma-links \
	--disable-scripts --disable-doc --disable-nls >/dev/null && make -s -C src/liblzma >/dev/null)

modules="$work/cpython-3.10.19/Modules"
build_module() {	# name source extra-flags...
	local name="$1" src="$2"; shift 2
	$cc -O2 -fPIC -shared -DPy_BUILD_CORE_MODULE -I"$pyinc" -I"$pyinc/internal" -I"$modules" "$modules/$src" "$@" \
		-o "$dynload/$name.cpython-310.so"
	echo "build-python-modules: $dynload/$name.cpython-310.so"
}
build_module zlib zlibmodule.c -lz
build_module _bz2 _bz2module.c -I"$bz" "$bz/libbz2.a"
build_module _lzma _lzmamodule.c -I"$xz/src/liblzma/api" "$xz/src/liblzma/.libs/liblzma.a"
