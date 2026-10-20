#!/usr/bin/env bash
# build-icu.sh — ICU 74.1 (HaikuPorts' icu74 recipe) cross-built for Haiku arm64, replacing the arm64
# icu74 bootstrap package: that one looks for its data under /packages/icu74_bootstrap-74.1-1 (a name it
# is not activated under; a shim package used to make it exist). This build puts the data into
# libicudata itself (--with-data-packaging=library, as Linux distributions build it; the recipe uses
# "archive", a data file in data/icu/74.1), so nothing depends on a data path.
#
#   scripts/build-icu.sh [--revision N]     (default 1)
#
# Steps: the recipe's source and data zip (checked against the recipe's checksums), its patchset; a host
# build of the same source (ICU's cross build runs the host's tools: --with-cross-build); the cross build
# with the recipe's flags, prefix /boot/system; scripts/package-port.py --system-prefix → artifacts/
# packages/icu74-74.1-<N>-arm64.hpkg (libraries and tools) and icu74_devel-74.1-<N>-arm64.hpkg.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
revision=1
while [ $# -gt 0 ]; do
	case "$1" in
	--revision) revision="$2"; shift 2 ;;
	*) echo "build-icu: unknown option $1" >&2; exit 2 ;;
	esac
done
recipe="$root/sources/haikuports/dev-libs/icu/icu74-74.1.recipe"
sysroot="$root/artifacts/sysroot-arm64"
tools="$root/sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku"
heavy="$root/scripts/heavy-build.sh"
work="$root/artifacts/cross-ports/icu74-74.1"
field() { sed -n "s/^$1=\"\\(.*\\)\"$/\\1/p" "$recipe" | head -n 1; }

# the sources: the tarball by the fetch script, the data zip (SOURCE_URI_2) here
archive="$("$root/scripts/haikuports-fetch.sh" "$recipe" \
	| sed -n 's/^haikuports-fetch: \(.*\) ([0-9]* bytes, sha256 ok)$/\1/p' | head -n 1)"
[ -f "$archive" ] || { echo "build-icu: no source" >&2; exit 1; }
dataZip="$(dirname "$archive")/icu4c-74_1-data.zip"
if [ ! -f "$dataZip" ]; then
	curl -sSL -o "$dataZip.part" \
		"https://github.com/unicode-org/icu/releases/download/release-74-1/icu4c-74_1-data.zip"
	mv "$dataZip.part" "$dataZip"
fi
echo "$(field CHECKSUM_SHA256_2)  $dataZip" | sha256sum -c --quiet - \
	|| { echo "build-icu: $dataZip checksum mismatch" >&2; exit 1; }

rm -rf "$work"
mkdir -p "$work/unpack" "$work/host" "$work/cross"
tar -xf "$archive" -C "$work/unpack"
mv "$work/unpack/icu" "$work/src"
rmdir "$work/unpack"
patch -s -p1 -d "$work/src" < "$(dirname "$recipe")/patches/icu74-74.1.patchset"
# as the recipe: the data from the zip (the tarball's prebuilt icudt74l.dat out)
(cd "$work/src/source" && unzip -oq "$dataZip" && rm -f data/in/icudt??l.dat && autoconf)

# the host build (its tools build the target's data)
(cd "$work/host" && "$work/src/source/configure" --disable-samples --disable-extras --disable-tests) \
	> "$work/host-configure.log" 2>&1 || { tail -n 20 "$work/host-configure.log" >&2; exit 1; }
"$heavy" --mem-per-job 1 -- make -C "$work/host" -j '{JOBS}' > "$work/host-build.log" 2>&1 \
	|| { tail -n 30 "$work/host-build.log" >&2; exit 1; }

# the cross build
(cd "$work/cross" && CFLAGS="-O2 -fno-semantic-interposition" CXXFLAGS="-O2 -fno-semantic-interposition" \
	LDFLAGS="-Wl,-Bsymbolic-functions" \
	"$work/src/source/configure" --host=aarch64-unknown-haiku --build="$(gcc -dumpmachine)" \
	--with-cross-build="$work/host" \
	--prefix=/boot/system --bindir=/boot/system/bin --sbindir=/boot/system/bin \
	--libdir=/boot/system/lib --includedir=/boot/system/develop/headers \
	--datadir=/boot/system/data --mandir=/boot/system/documentation/man \
	--disable-samples --disable-extras --disable-tests --with-data-packaging=library \
	CC="$tools-gcc --sysroot=$sysroot" CXX="$tools-g++ --sysroot=$sysroot" AR="$tools-ar" \
	RANLIB="$tools-ranlib") > "$work/cross-configure.log" 2>&1 \
	|| { tail -n 20 "$work/cross-configure.log" >&2; exit 1; }
"$heavy" --mem-per-job 1 -- make -C "$work/cross" -j '{JOBS}' > "$work/cross-build.log" 2>&1 \
	|| { tail -n 30 "$work/cross-build.log" >&2; exit 1; }
make -C "$work/cross" install DESTDIR="$work/install" > "$work/install.log" 2>&1 \
	|| { tail -n 20 "$work/install.log" >&2; exit 1; }
sys="$work/install/boot/system"
# icu-config and the pkg-config files name the build's directories nowhere but the prefix; data/ holds
# only the build's makefile fragments (lib/icu: the _devel package's), the man pages
rm -rf "$sys/data" "$sys/documentation"
ls -l "$sys/lib"/libicudata.so.* | head -n 3

"$root/scripts/package-port.py" "$recipe" --revision "$revision" --system-prefix --devel-bin icu-config
