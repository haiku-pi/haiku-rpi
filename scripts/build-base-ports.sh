#!/usr/bin/env bash
# build-base-ports.sh — cross-build and package the base command-line ports the regular (@nightly)
# arm64 image requires (the haiku package requires cmd:tar, cmd:gunzip, cmd:bunzip2, cmd:unzip) and the
# arm64 build-packages repository lacks: gzip, tar, bzip2, unzip, from their HaikuPorts recipes
# (scripts/cross-port.sh, scripts/package-port.py). Each recipe's own build options are repeated here.
# Output: artifacts/packages/*.hpkg; copy them into generated.arm64/download (sources/haiku's arm64
# repository definition lists them).
#
#   scripts/build-base-ports.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
ports="$root/sources/haikuports"
cross="$root/scripts/cross-port.sh"
package="$root/scripts/package-port.py"

# gzip, tar: the shipped configure (the recipes do not regenerate it)
AUTORECONF=0 "$cross" "$ports/app-arch/gzip/gzip-1.9.recipe" autotools --disable-nls \
	CFLAGS=-Wno-error AUTOCONF=: AUTOMAKE=: ACLOCAL=:
"$package" "$ports/app-arch/gzip/gzip-1.9.recipe"

AUTORECONF=0 "$cross" "$ports/app-arch/tar/tar-1.35.recipe" autotools --disable-nls \
	--disable-gcc-warnings LDFLAGS=-lnetwork CFLAGS=-D_BSD_SOURCE FORCE_UNSAFE_CONFIGURE=1 \
	AUTOCONF=: AUTOMAKE=: ACLOCAL=: YACC=:
"$package" "$ports/app-arch/tar/tar-1.35.recipe"

# bzip2: its Makefiles; the default target would also run the tests, which cannot run here
"$cross" "$ports/app-arch/bzip2/bzip2-1.0.8.recipe" script '
make CC="$CC" AR="$AR" RANLIB="$RANLIB" libbz2.a bzip2 bzip2recover
make -f Makefile-libbz2_so CC="$CC"
make install CC="$CC" AR="$AR" RANLIB="$RANLIB" PREFIX="$DEST" BINDIR="$DEST/bin" LIBDIR="$DEST/lib" \
	INCLUDEDIR="$DEST/include" MANDIR="$DEST/documentation/man/man1"
ln -sf libbz2.so.1.0.8 libbz2.so
cp -a libbz2.so.1.0.8 libbz2.so.1.0 libbz2.so "$DEST/lib/"
rm -f "$DEST"/lib/*.a
rm -rf "$DEST/documentation"'
"$package" "$ports/app-arch/bzip2/bzip2-1.0.8.recipe"

# unzip: the recipe's "haiku" target forces CC=cc, so the same flags are given here; without
# ICONV_MAPPING (no libiconv port yet), which is also what made it include <locale.h>
"$cross" "$ports/app-arch/unzip/unzip-6.10c23.recipe" script '
make -f unix/Makefile unix_make
make -f unix/Makefile unzip funzip unzipsfx CC="$CC" AS="$CC -c" CRCA_O="" LN="ln -s" \
	CFLAGS="-O2 -DLARGE_FILE_SUPPORT -DUNICODE_SUPPORT -DUNICODE_WCHAR -DUTF8_MAYBE_NATIVE \
		-DNO_LCHMOD -DHAVE_DIRENT_H -DHAVE_TERMIOS_H -DHAVE_LOCALE_H -DHAVE_WCHAR_H -DHAVE_CTYPE_H \
		-DHAVE_WCTYPE_H -DHAVE_LANGINFO_H -DNO_SYSDIR -DBZIP2_SUPPORT \
		-I$SYSROOT/boot/system/non-packaged/include" \
	LF2="-lbe -L$SYSROOT/boot/system/non-packaged/lib -lbz2"
make -f unix/Makefile install PREFIX="$DEST" MANDIR="$DEST/documentation/man/man1" LN="ln -s"
ln -sf unzip "$DEST/bin/zipinfo"
rm -rf "$DEST/documentation"'
"$package" "$ports/app-arch/unzip/unzip-6.10c23.recipe"
