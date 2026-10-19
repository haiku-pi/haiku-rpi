#!/usr/bin/env bash
# build-bootstrap-tools.sh — cross-build the command-line tools haikuporter and recipe scripts need but
# the HaikuPorts arm64 bootstrap package set lacks: patch (patchsets with -G / --no-git-repo), tar,
# gzip, xz, bzip2, diff/cmp. Plan: docs/design/package-farm-plan.md, stage 1 item 3.
#
#   scripts/build-bootstrap-tools.sh [--out DIR]     (default artifacts/bootstrap-tools)
#
# Output: DIR/non-packaged/bin/ (mkimage-pi4.sh --add-tree DIR/non-packaged), stripped, needing only
# the system's libraries (liblzma is linked into xz statically). Needs
# scripts/haiku-sysroot.sh's sysroot and the jam-built cross compiler; sources are fetched once into
# DIR/build/dl and checked against the pinned SHA-256s below.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/artifacts/bootstrap-tools"
while [ $# -gt 0 ]; do
	case "$1" in
	--out) out="$2"; shift 2 ;;
	*) echo "build-bootstrap-tools: unknown option $1" >&2; exit 2 ;;
	esac
done
gen="$root/sources/haiku/generated.arm64"
sysroot="$root/artifacts/sysroot-arm64"
tools="$gen/cross-tools-arm64/bin/aarch64-unknown-haiku"
[ -d "$sysroot/boot/system/develop" ] || { echo "build-bootstrap-tools: run scripts/haiku-sysroot.sh first" >&2; exit 1; }
cc="$tools-gcc --sysroot=$sysroot"
jobs=$(nproc)

# name|url|sha256
sources=(
	"patch-2.8|https://ftp.gnu.org/gnu/patch/patch-2.8.tar.xz|f87cee69eec2b4fcbf60a396b030ad6aa3415f192aa5f7ee84cad5e11f7f5ae3"
	"gzip-1.13|https://ftp.gnu.org/gnu/gzip/gzip-1.13.tar.xz|7454eb6935db17c6655576c2e1b0fabefd38b4d0936e0f87f48cd062ce91a057"
	"tar-1.35|https://ftp.gnu.org/gnu/tar/tar-1.35.tar.xz|4d62ff37342ec7aed748535323930c7cf94acf71c3591882b26a7ea50f3edc16"
	"diffutils-3.10|https://ftp.gnu.org/gnu/diffutils/diffutils-3.10.tar.xz|90e5e93cc724e4ebe12ede80df1634063c7a855692685919bfe60b556c9bd09e"
	"xz-5.6.4|https://github.com/tukaani-project/xz/releases/download/v5.6.4/xz-5.6.4.tar.gz|269e3f2e512cbd3314849982014dc199a7b2148cf5c91cedc6db629acdf5e09b"
	"bzip2-1.0.8|https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz|ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269"
)
work="$out/build"
bin="$out/non-packaged/bin"
mkdir -p "$work/dl" "$bin"
for s in "${sources[@]}"; do
	IFS='|' read -r name url sum <<< "$s"
	archive="$work/dl/$(basename "$url")"
	[ -f "$archive" ] || curl -sSfL -o "$archive" "$url"
	echo "$sum  $archive" | sha256sum -c --quiet
	rm -rf "$work/$name"
	mkdir -p "$work/$name"
	tar -xf "$archive" -C "$work/$name" --strip-components=1
done

autotools() {	# name configure-args... — configure + make in the source tree
	local name="$1"; shift
	echo "build-bootstrap-tools: $name"
	(cd "$work/$name" && ./configure -q --host=aarch64-unknown-haiku CC="$cc" --disable-nls "$@" \
		>configure.out 2>&1 && make -s -j"$jobs" >make.out 2>&1) \
		|| { echo "build-bootstrap-tools: $name failed, see $work/$name/{configure,make}.out" >&2; exit 1; }
}
install_bin() {	# file...
	for f in "$@"; do
		"$tools-strip" -o "$bin/$(basename "$f")" "$f"
	done
}

autotools patch-2.8
install_bin "$work/patch-2.8/src/patch"
autotools gzip-1.13
install_bin "$work/gzip-1.13/gzip"
autotools tar-1.35 LIBS=-lnetwork
	# (remote archives: gethostbyname is in libnetwork)
install_bin "$work/tar-1.35/src/tar"
autotools diffutils-3.10
install_bin "$work/diffutils-3.10/src/diff" "$work/diffutils-3.10/src/cmp"
autotools xz-5.6.4 --disable-shared --enable-static --disable-doc --disable-scripts \
	--disable-lzmadec --disable-lzmainfo
install_bin "$work/xz-5.6.4/src/xz/xz"

echo "build-bootstrap-tools: bzip2-1.0.8"
make -s -C "$work/bzip2-1.0.8" CC="$cc" AR="$tools-ar" RANLIB="$tools-ranlib" bzip2 \
	>"$work/bzip2-1.0.8/make.out" 2>&1
install_bin "$work/bzip2-1.0.8/bzip2"

# the usual alias names, as the packages that normally provide these tools install them
ln -sf gzip "$bin/gunzip"
ln -sf xz "$bin/unxz"
ln -sf xz "$bin/xzcat"
ln -sf bzip2 "$bin/bunzip2"
ls -l "$bin"
