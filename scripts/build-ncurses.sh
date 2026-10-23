#!/usr/bin/env bash
# build-ncurses.sh — ncurses 6.6 (HaikuPorts' ncurses6 recipe) cross-built for Haiku arm64, replacing the
# arm64 ncurses6 bootstrap package: that one looks for its terminfo database under
# /packages/ncurses6_bootstrap-6.6-1/.self/data/terminfo (a name it is not activated under; a shim package
# used to make it exist). Built with the packaged prefix, the database is /boot/system/data/terminfo.
#
#   scripts/build-ncurses.sh [--revision N]     (default 1)
#
# Steps: the recipe's source (checked against its checksum); the cross build with the recipe's
# configure flags, prefix /boot/system, ncurses' own shared-library rules instead of libtool (no host
# libtool; the same sonames, libncursesw.so.6 and friends); the terminfo database compiled by the host's tic
# (ncurses 6.6 too); the recipe's compatibility names (libncurses.so.6 -> libncursesw.so.6, ...);
# scripts/package-port.py --system-prefix → artifacts/packages/ncurses6-6.6-<N>-arm64.hpkg (libraries,
# programs, the terminfo database) and ncurses6_devel-6.6-<N>-arm64.hpkg; the libraries provided at the
# recipe's 6.6.0 (the bootstrap packages built against upstream's require >= 6.6.0).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
revision=1
while [ $# -gt 0 ]; do
	case "$1" in
	--revision) revision="$2"; shift 2 ;;
	*) echo "build-ncurses: unknown option $1" >&2; exit 2 ;;
	esac
done
recipe="$root/sources/haikuports/sys-libs/ncurses/ncurses6-6.6.recipe"
sysroot="$root/artifacts/sysroot-arm64"
tools="$root/sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku"
work="$root/artifacts/cross-ports/ncurses6-6.6"
tic="$(command -v tic)" || { echo "build-ncurses: the host's tic (ncurses) is needed" >&2; exit 1; }

archive="$("$root/scripts/haikuports-fetch.sh" "$recipe" \
	| sed -n 's/^haikuports-fetch: \(.*\) ([0-9]* bytes, sha256 ok)$/\1/p' | head -n 1)"
[ -f "$archive" ] || { echo "build-ncurses: no source" >&2; exit 1; }

rm -rf "$work"
mkdir -p "$work/unpack" "$work/build"
tar -xf "$archive" -C "$work/unpack"
mv "$work/unpack"/ncurses-snapshots-* "$work/src"
rmdir "$work/unpack"
# (the recipe's patchset is not applied: it only makes progs/ install libtool's .libs/ programs)

# the recipe's flags (--with-libtool aside), the directories its runConfigure passes
(cd "$work/build" && "$work/src/configure" --host=aarch64-unknown-haiku --build="$(gcc -dumpmachine)" \
	--prefix=/boot/system --bindir=/boot/system/bin --sbindir=/boot/system/bin \
	--libdir=/boot/system/lib --includedir=/boot/system/develop/headers \
	--datadir=/boot/system/data --mandir=/boot/system/documentation/man \
	--disable-relink --disable-root-access --enable-root-environ --disable-setuid-environ \
	--disable-static --enable-hard-tabs --enable-pc-files --enable-symlinks --enable-termcap \
	--with-shared --with-cxx-shared --without-normal --without-debug --disable-stripping \
	--without-ada --without-tests --with-pkg-config-libdir=/boot/system/develop/lib/pkgconfig \
	--with-default-terminfo-dir=/boot/system/data/terminfo --with-terminfo-dirs=/boot/system/data/terminfo \
	--with-tic-path="$tic" --with-infocmp-path="$(dirname "$tic")/infocmp" \
	CC="$tools-gcc --sysroot=$sysroot" CXX="$tools-g++ --sysroot=$sysroot" AR="$tools-ar" \
	RANLIB="$tools-ranlib" STRIP="$tools-strip" BUILD_CC=gcc) > "$work/configure.log" 2>&1 \
	|| { tail -n 20 "$work/configure.log" >&2; exit 1; }
make -C "$work/build" -j"$(nproc)" > "$work/build.log" 2>&1 \
	|| { tail -n 30 "$work/build.log" >&2; exit 1; }
make -C "$work/build" install DESTDIR="$work/install" TIC_PATH="$tic" > "$work/install.log" 2>&1 \
	|| { tail -n 20 "$work/install.log" >&2; exit 1; }
sys="$work/install/boot/system"
[ -f "$sys/data/terminfo/x/xterm-256color" ] \
	|| { echo "build-ncurses: no terminfo database in $sys/data/terminfo" >&2; exit 1; }

# the recipe's compatibility names: programs that link -lncurses (or ask pkg-config for "ncurses") get
# the wide-character libraries
for lib in form menu ncurses ncurses++ panel; do
	ln -sfn "lib${lib}w.so.6" "$sys/lib/lib${lib}.so.6"
	ln -sfn "lib${lib}w.so" "$sys/lib/lib${lib}.so"
	ln -sfn "${lib}w.pc" "$sys/develop/lib/pkgconfig/${lib}.pc"
done
mkdir -p "$sys/lib/pkgconfig"
mv "$sys/develop/lib/pkgconfig"/*.pc "$sys/lib/pkgconfig/"
rm -rf "$sys/documentation" "$sys/develop/lib"
ls -l "$sys/lib"/libncursesw.so*

"$root/scripts/package-port.py" "$recipe" --revision "$revision" --system-prefix --devel-bin ncursesw6-config \
	--lib-version 6.6.0
