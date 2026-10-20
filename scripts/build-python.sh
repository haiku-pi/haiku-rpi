#!/usr/bin/env bash
# build-python.sh — cross-build CPython 3.14 (HaikuPorts' python3.14 recipe, the default python3 of
# HaikuPorts) for Haiku arm64 and package it as python3.14 + python3.14_devel.
#
#   scripts/build-python.sh [--no-host]   (--no-host: reuse artifacts/python-host as it is)
#
# Steps:
#   1. the build python: the same Python-3.14.8 tarball built for this host into artifacts/python-host
#      (a cross build runs the build's own scripts, freezing, compileall with --with-build-python;
#      it must be the same version). Rebuilt when missing or of another version.
#   2. libffi (ctypes): the arm64 libffi + libffi_devel 3.4.6 bootstrap packages that the HaikuPorts
#      repository definition already lists (generated.arm64/download), extracted into the sysroot.
#   3. liblzma (_lzma): the xz_utils 5.8.4 recipe's source, built with CMake as a static PIC archive
#      and linked into _lzma (no xz_utils package in our repository; the recipe's autotools build
#      needs autopoint, which this host lacks).
#   4. CPython: the recipe's source and patchset, then patches/python3/*.patch (ours), configure
#      regenerated with autoconf (the recipe runs autoreconf; aclocal.m4 already holds the
#      autoconf-archive macros), configured as the recipe does (prefix /boot/system, headers in
#      develop/headers, shared libpython, system expat, bundled libmpdec) but without
#      --enable-optimizations/--with-lto (PGO runs the target's python), built and installed into
#      artifacts/cross-ports/python3.14-3.14.8/install; the recipe's INSTALL() steps after that.
#   5. packages: scripts/package-port.py --system-prefix --lib-tree python3.14 → artifacts/packages/
#      python3.14-3.14.8-1-arm64.hpkg and python3.14_devel-3.14.8-1-arm64.hpkg.
#   6. test trees for images without the package (scripts/mkimage-pi4.sh --add-tree DIR;
#      tools/pi-tests/python.sh): artifacts/python-tests/packages, the python3.14 and libffi packages
#      (the test script installs them), or artifacts/python-tests/non-packaged, python3.14,
#      libpython, libffi and the standard library without the test suite, the GUI modules and the
#      bytecode caches (fewer files to copy into the image).
#
# Modules not built: readline (no libedit in our repository), _curses/_curses_panel (no ncurses
# headers in the sysroot), _dbm/_gdbm, _uuid (libuuid), _tkinter (the recipe disables it too).
# Needs scripts/haiku-sysroot.sh's sysroot with our ports (openssl3, sqlite, bzip2, zstd:
# scripts/build-packages.sh) and the jam-built cross compiler. Heavy steps run under
# scripts/heavy-build.sh.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
buildHost=1
while [ $# -gt 0 ]; do
	case "$1" in
	--no-host) buildHost=0; shift ;;
	*) echo "build-python: unknown option $1" >&2; exit 2 ;;
	esac
done
gen="$root/sources/haiku/generated.arm64"
sysroot="$root/artifacts/sysroot-arm64"
tools="$gen/cross-tools-arm64/bin/aarch64-unknown-haiku"
pkgtool="$gen/objects/linux/x86_64/release/tools/package/package"
heavy="$root/scripts/heavy-build.sh"
ports="$root/sources/haikuports"
[ -d "$sysroot/boot/system/develop" ] || { echo "build-python: run scripts/haiku-sysroot.sh first" >&2; exit 1; }
[ -x "$tools-gcc" ] || { echo "build-python: no cross compiler at $tools-gcc" >&2; exit 1; }
for lib in libssl.so.3 libsqlite3.so.0 libbz2.so.1.0 libzstd.so.1; do
	[ -e "$sysroot/boot/system/non-packaged/lib/$lib" ] \
		|| { echo "build-python: $lib missing from the sysroot: run scripts/build-packages.sh" >&2; exit 1; }
done

recipe="$ports/dev-lang/python/python3.14-3.14.8.recipe"
name="$(basename "$recipe" .recipe)"	# python3.14-3.14.8
version="${name##*-}"
short="${version%.*}"			# 3.14
xzRecipe="$ports/app-arch/xz_utils/xz_utils-5.8.4.recipe"
fetch() {	# the archive scripts/haikuports-fetch.sh got (or found) for a recipe
	"$root/scripts/haikuports-fetch.sh" "$1" \
		| sed -n 's/^haikuports-fetch: \(.*\) ([0-9]* bytes, sha256 ok)$/\1/p' | head -n 1
}
pyArchive="$(fetch "$recipe")"
xzArchive="$(fetch "$xzRecipe")"
[ -f "$pyArchive" ] && [ -f "$xzArchive" ] || { echo "build-python: sources not fetched" >&2; exit 1; }

# 1. the build python
host="$root/artifacts/python-host"
hostPython="$host/bin/python$short"
if [ "$buildHost" = 1 ] && ! "$hostPython" -c "import sys; sys.exit(sys.version.split()[0] != '$version')" 2>/dev/null; then
	echo "build-python: building the build python $version into $host"
	rm -rf "$host" "$host-build"
	mkdir -p "$host-build"
	tar -xf "$pyArchive" -C "$host-build" --strip-components=1
	(cd "$host-build" && ./configure -q --prefix="$host" --disable-test-modules --with-ensurepip=no) \
		> "$host-build/configure.log" 2>&1 || { tail -n 30 "$host-build/configure.log" >&2; exit 1; }
	"$heavy" --mem-per-job 1 -- make -C "$host-build" -j '{JOBS}' > "$host-build/build.log" 2>&1 \
		|| { tail -n 30 "$host-build/build.log" >&2; exit 1; }
	make -C "$host-build" install > "$host-build/install.log" 2>&1 \
		|| { tail -n 30 "$host-build/install.log" >&2; exit 1; }
	rm -rf "$host-build"
fi
"$hostPython" -c "import sys; sys.exit(sys.version.split()[0] != '$version')" \
	|| { echo "build-python: $hostPython is not Python $version" >&2; exit 1; }
echo "build-python: build python $("$hostPython" --version)"

work="$root/artifacts/cross-ports/$name"
rm -rf "$work"
mkdir -p "$work/deps"

# 2. libffi: the bootstrap packages, into the sysroot
for p in libffi libffi_devel; do
	hpkg="$gen/download/$p-3.4.6_bootstrap-1-arm64.hpkg"
	[ -f "$hpkg" ] || { echo "build-python: $hpkg missing (scripts/fetch-build-packages.sh)" >&2; exit 1; }
	"$pkgtool" extract -C "$sysroot/boot/system" "$hpkg"
done
rm -f "$sysroot/boot/system/develop/lib/libffi.la"

# 3. liblzma: static, PIC
xz="$work/deps/xz"
mkdir -p "$xz/src"
tar -xf "$xzArchive" -C "$xz/src" --strip-components=1
cmake -S "$xz/src" -B "$xz/build" -G Ninja -DCMAKE_TOOLCHAIN_FILE="$root/tools/cmake/haiku-arm64.cmake" \
	-DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
	-DXZ_NLS=OFF -DXZ_DOC=OFF > "$xz/configure.log" 2>&1 || { tail -n 30 "$xz/configure.log" >&2; exit 1; }
ninja -C "$xz/build" liblzma > "$xz/build.log" 2>&1 || { tail -n 30 "$xz/build.log" >&2; exit 1; }
[ -f "$xz/build/liblzma.a" ] || { echo "build-python: no liblzma.a" >&2; exit 1; }

# 4. CPython
mkdir -p "$work/unpack"
tar -xf "$pyArchive" -C "$work/unpack"
mv "$work/unpack/Python-$version" "$work/src"
rmdir "$work/unpack"
recipePatches="$(dirname "$recipe")/patches"
echo "build-python: applying python$short-$version.patchset"
patch -s -p1 -d "$work/src" < "$recipePatches/python$short-$version.patchset"
for p in "$root"/patches/python3/*.patch; do
	echo "build-python: applying $(basename "$p")"
	patch -s -p1 -d "$work/src" < "$p"
done
(cd "$work/src" && autoconf && autoheader) > "$work/autoconf.log" 2>&1 \
	|| { cat "$work/autoconf.log" >&2; exit 1; }

# answers configure cannot find out without running a Haiku program
cat > "$work/config.site" <<'EOF'
ac_cv_file__dev_ptmx=yes
ac_cv_file__dev_ptc=no
ac_cv_buggy_getaddrinfo=no
EOF
tzpath=/boot/home/config/non-packaged/data/zoneinfo:/boot/home/config/data/zoneinfo
tzpath=$tzpath:/boot/system/non-packaged/data/zoneinfo:/boot/system/data/zoneinfo
# in the source tree, as the recipe builds (out of tree, getpath.c gets the source directory as VPATH)
(cd "$work/src" && CONFIG_SITE="$work/config.site" \
	PKG_CONFIG_LIBDIR="$sysroot/boot/system/non-packaged/lib/pkgconfig:$sysroot/boot/system/develop/lib/pkgconfig" \
	PKG_CONFIG_SYSROOT_DIR="$sysroot" \
	BASECFLAGS="-pipe -D_BSD_SOURCE" OPT="-Wall -O3" \
	CFLAGS_NODIST="-ffile-prefix-map=$work/src=/sources/Python-$version" \
	LIBLZMA_CFLAGS="-I$xz/src/src/liblzma/api" LIBLZMA_LIBS="$xz/build/liblzma.a" \
	./configure --host=aarch64-unknown-haiku --build="$(gcc -dumpmachine)" \
	--with-build-python="$hostPython" \
	--prefix=/boot/system --bindir=/boot/system/bin --includedir=/boot/system/develop/headers \
	--datarootdir=/boot/system/data --mandir=/boot/system/documentation/man \
	--enable-shared --without-static-libpython --with-ensurepip=no --without-readline \
	--with-system-expat --with-system-libmpdec=no --with-openssl-rpath=no --with-tzpath="$tzpath" \
	CC="$tools-gcc --sysroot=$sysroot" CXX="$tools-g++ --sysroot=$sysroot" AR="$tools-ar" \
	RANLIB="$tools-ranlib" READELF="$tools-readelf" STRIP="$tools-strip" \
	LDFLAGS="-L$sysroot/boot/system/non-packaged/lib") > "$work/configure.log" 2>&1 \
	|| { tail -n 30 "$work/configure.log" >&2; exit 1; }
"$heavy" --mem-per-job 1 -- make -C "$work/src" -j '{JOBS}' > "$work/build.log" 2>&1 \
	|| { tail -n 40 "$work/build.log" >&2; exit 1; }
echo "build-python: compiler warnings: $(grep -c 'warning:' "$work/build.log" || true)"
# the build's module summary (make checksharedmods): what is missing, disabled or failed
sed -n '/^The necessary bits to build these optional modules were not found:/,/^$/p;/^Following modules built successfully but were removed/,/^$/p;/^The following modules are \*disabled\*/,/^$/p;/^Failed to build these modules:/,/^$/p' \
	"$work/build.log" | sed 's/^/build-python: /'
make -C "$work/src" install DESTDIR="$work/install" > "$work/install.log" 2>&1 \
	|| { tail -n 30 "$work/install.log" >&2; exit 1; }

# the recipe's INSTALL()
sys="$work/install/boot/system"
rm -f "$sys/lib/libpython3.so"
rm -f "$sys/bin/idle$short" "$sys/bin/idle3"
mkdir -p "$sys/lib/python$short/vendor-packages"
echo 'This directory contains packaged python modules.' > "$sys/lib/python$short/vendor-packages/README"
mkdir -p "$sys/non-packaged/lib/python$short"
mv "$sys/lib/python$short/site-packages" "$sys/non-packaged/lib/python$short/"
rm -rf "$sys/lib/python$short/idlelib/idle_test" "$sys/lib/python$short/test"
# sysconfig (_sysconfigdata, the config Makefile: what python3.14-config and extension builds on
# Haiku read) names the cross compiler and this host's directories: the names on Haiku instead
# (gcc; the sources as HaikuPorts' chroot has them), then the _sysconfigdata bytecode again
grep -rlI -F "$root" "$sys" | while read -r f; do
	sed -i -e "s|$tools-||g; s| --sysroot=$sysroot||g; s|-L$sysroot/boot/system/non-packaged/lib||g" \
		-e "s|$sysroot/packages/libffi_bootstrap-3.4.6-1/.self|/boot/system|g; s|$sysroot||g" \
		-e "s|$work/src|/sources/Python-$version|g" \
		-e "s|$xz/src|/sources/xz-5.8.4|g; s|$xz/build|/sources/xz-5.8.4|g; s|$hostPython|python$short|g" "$f"
done
# (the binaries: __FILE__ is mapped by -ffile-prefix-map; libgcc's debug strings name the cross
# compiler's build directory, as in every port built with it)
"$hostPython" -m compileall -q -f -o 0 -o 1 -o 2 -d "/boot/system/lib/python$short" \
	"$sys/lib/python$short"/_sysconfigdata_*.py
leaks="$(grep -rlI -F "$root" "$sys"; grep -rl -F "$work" "$sys" || true)"
[ -z "$leaks" ] || { echo "build-python: host paths left in: $leaks" >&2; exit 1; }
# (data/: the man pages, which package-port.py does not package)
# the extension modules this port is for (the build only warns when one is missing), with the
# libraries they link
for m in _ssl _hashlib _sqlite3 _ctypes zlib _bz2 _lzma _zstd _socket select _decimal _json \
		_posixsubprocess pyexpat; do
	f="$(ls "$sys/lib/python$short/lib-dynload/$m".cpython-*.so 2>/dev/null | head -n 1 || true)"
	[ -n "$f" ] || { echo "build-python: module $m was not built" >&2; exit 1; }
	echo "build-python: module $m: $("$tools-readelf" -d "$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' ')"
done

# 5. the packages (libffi from the bootstrap package is in the sysroot's system lib/, where
# package-port.py does not look for requirements: named here)
"$root/scripts/package-port.py" "$recipe" --system-prefix --lib-tree "python$short" \
	--global-writable "non-packaged/lib/python$short/site-packages" \
	--devel-bin "python$short-config" --devel-bin python3-config --requires lib:libffi

# 6. the test trees
rm -rf "$root/artifacts/python-tests"
mkdir -p "$root/artifacts/python-tests/packages/data/python-packages"
cp "$root/artifacts/packages/python$short-$version-1-arm64.hpkg" "$gen/download/libffi-3.4.6_bootstrap-1-arm64.hpkg" \
	"$root/artifacts/python-tests/packages/data/python-packages/"
tests="$root/artifacts/python-tests/non-packaged"
mkdir -p "$tests/bin" "$tests/lib"
cp -a "$sys/bin/python$short" "$tests/bin/"
"$tools-strip" "$tests/bin/python$short"
ln -s "python$short" "$tests/bin/python3"
"$tools-strip" --strip-unneeded -o "$tests/lib/libpython$short.so.1.0" "$sys/lib/libpython$short.so.1.0"
cp -a "$sysroot/boot/system/lib"/libffi.so.8* "$tests/lib/"
cp -a "$sys/lib/python$short" "$tests/lib/"
stdlib="$tests/lib/python$short"
find "$stdlib" -name __pycache__ -type d -prune -exec rm -rf {} +
rm -rf "$stdlib"/{idlelib,tkinter,turtledemo,ensurepip,pydoc_data,__phello__} \
	"$stdlib"/config-* "$stdlib"/turtle.py "$stdlib"/vendor-packages
find "$stdlib" -name '*.so' -exec "$tools-strip" --strip-unneeded {} +
echo "build-python: test tree $tests: $(find "$tests" -type f | wc -l) files," \
	"$(du -sh "$tests" | cut -f1)"
ls -l "$root"/artifacts/packages/python$short*-"$version"-1-arm64.hpkg
