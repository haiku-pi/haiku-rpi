#!/usr/bin/env bash
# build-dev-tools.sh — cross-build the developer tools for Haiku arm64 that do not depend on the
# GCC 16.2 switch (H18 part 1, docs/design/dev-tools.md) and package them as HaikuPorts does:
#
#   make 4.4.1, ninja 1.13.2, pkgconf 3.0.10 (cmd:pkg_config), cmake 4.4.5 (+ ccmake, ctest, cpack),
#   binutils 2.46.1 (sources/buildtools, native as/ld/objdump/...), meson 1.12.1 (`meson`, arch any)
#   and the python3.14 modules pip, setuptools, wheel, Cython, meson-python, pyproject-metadata.
#
#   scripts/build-dev-tools.sh [--only NAME]...   (NAME: make ninja pkgconf cmake binutils python
#                                                  check; default: all of them, in that order)
#
# Each tool is built from its HaikuPorts recipe and that recipe's patches (scripts/cross-port.sh),
# with the recipe's own options repeated here. Where the newest release is newer than the recipe
# (cmake 4.4.4 -> 4.4.5, pkgconf 1.5.3 -> 3.0.10), the bumped recipe is in tools/recipes/ (the same
# recipe with the new version and checksum; the 4.4.4 patchset applies to 4.4.5 unchanged).
# Packages (scripts/package-port.py, scripts/package-python-wheel.py) go to artifacts/packages/.
#
# "check" (run last) extracts every package built here and fails on: a NEEDED library or an undefined
# dynamic symbol that no library on the image provides (libroot, libbsd, libnetwork, libstdc++,
# libgcc_s, libz, libexpat, libcurl, libncursesw, libiconv, libpkgconf, ...: a missing one links fine and fails
# only when the program starts on the Pi), a build-host path in any packaged file, and
# /boot/system/non-packaged (the cross builds' prefix) in a program or library.
#
# Not here: the native gcc (it is built once, on GCC 16.2, after the main build switches:
# docs/design/gcc16.md, "Next steps" 6). Needs scripts/haiku-sysroot.sh's sysroot with our ports
# (curl, ncurses6: scripts/build-packages.sh), scripts/build-python.sh's build python and uv.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
only=()
while [ $# -gt 0 ]; do
	case "$1" in
	--only) only+=("$2"); shift 2 ;;
	*) echo "build-dev-tools: unknown option $1" >&2; exit 2 ;;
	esac
done
[ ${#only[@]} -gt 0 ] || only=(make ninja pkgconf cmake binutils python check)
gen="$root/sources/haiku/generated.arm64"
sysroot="$root/artifacts/sysroot-arm64"
tools="$gen/cross-tools-arm64/bin/aarch64-unknown-haiku"
pkgtool="$gen/objects/linux/x86_64/release/tools/package/package"
ports="$root/sources/haikuports"
recipes="$root/tools/recipes"
cross="$root/scripts/cross-port.sh"
package="$root/scripts/package-port.py"
heavy="$root/scripts/heavy-build.sh"
packages="$root/artifacts/packages"
[ -d "$sysroot/boot/system/develop" ] || { echo "build-dev-tools: run scripts/haiku-sysroot.sh first" >&2; exit 1; }
[ -x "$tools-gcc" ] || { echo "build-dev-tools: no cross compiler at $tools-gcc" >&2; exit 1; }
df -BG --output=avail / | tail -n 1 | tr -d ' G' | { read -r free; [ "$free" -ge 17 ] \
	|| { echo "build-dev-tools: only ${free} GB free on /" >&2; exit 1; }; }
want() { local n; for n in "${only[@]}"; do [ "$n" = "$1" ] && return 0; done; return 1; }

# --- make: the recipe configures and builds natively; here configure for the host, then make.
# make bakes the C++ compiler configure used into its built-in $(CXX) (MAKE_CXX): the cross
# compiler's path on the host; it is g++ on Haiku. Its default include and -l directories are
# Haiku's develop/headers and develop/lib (the recipe gets them from runConfigure).
if want make; then
	"$cross" "$ports/sys-devel/make/make-4.4.1.recipe" script '
./configure -q --host=aarch64-unknown-haiku --prefix=/boot/system --includedir=/boot/system/develop/headers \
	--libdir=/boot/system/develop/lib --disable-rpath --with-gnu-ld --disable-dependency-tracking \
	--disable-nls --without-guile CC="$CC" CXX="$CXX"
sed -i "s|^#define MAKE_CXX .*|#define MAKE_CXX \"g++\"|" src/config.h
grep -q "^#define MAKE_CXX \"g++\"" src/config.h
make -j"$(nproc)"
install -D make "$DEST/bin/make"
install -D -m 644 src/gnumake.h "$DEST/develop/headers/gnumake.h"'
	"$package" "$ports/sys-devel/make/make-4.4.1.recipe" --tree develop/headers --no-devel
fi

# --- ninja: the recipe's configure.py (its patch adds the haiku platform: getloadavg from libbsd),
# generating build.ninja for the cross compiler instead of --bootstrap, then the host's ninja
if want ninja; then
	"$cross" "$ports/dev-build/ninja/ninja-1.13.2.recipe" script '
CXX="$CXX" AR="$AR" python3 configure.py --host=linux --platform=haiku
ninja ninja
install -D ninja "$DEST/bin/ninja"'
	"$package" "$ports/dev-build/ninja/ninja-1.13.2.recipe" --requires lib:libbsd
fi

# --- pkgconf (provides pkg-config, as HaikuPorts' pkgconf): its search path is Haiku's own
# (find_paths() of develop/lib/pkgconfig and data/pkgconfig in every installation location:
# libpkgconf/personality.c), so only the directories it filters out of -I/-L, which configure would
# otherwise take from the prefix, are given
if want pkgconf; then
	AUTORECONF=0 "$cross" "$recipes/dev-util/pkgconf/pkgconf-3.0.10.recipe" autotools --disable-static \
		--with-system-libdir=/boot/system/develop/lib --with-system-includedir=/boot/system/develop/headers \
		--with-personality-dir=/boot/system/data/pkgconfig/personality.d \
		CFLAGS="-O2 -ffile-prefix-map=$root/artifacts/cross-ports/pkgconf-3.0.10/src=pkgconf-3.0.10"
	ln -s pkgconf "$root/artifacts/cross-ports/pkgconf-3.0.10/install/boot/system/non-packaged/bin/pkg-config"
	"$package" "$recipes/dev-util/pkgconf/pkgconf-3.0.10.recipe" --lib-version 8.0.0
fi

# --- cmake: built with CMake (its bootstrap script compiles and runs programs on the build host).
# As the recipe: curl, expat, zlib from the system (curl is our curl package); unlike the recipe,
# libuv and librhash bundled too (no packages of them here), as are libarchive, jsoncpp, cppdap,
# zstd, liblzma, bzip2 (patches/cmake-4.4.5: the bundled libuv's Haiku sources); ccmake on ncurses6;
# -lbsd as its LDFLAGS; no RPATH (the linker path would name non-packaged/lib, where our curl was
# found in the sysroot); __FILE__ without the build directory; the recipe's install directories (data/cmake, as CMake finds its modules
# relative to bin/cmake)
if want cmake; then
	"$heavy" --mem-per-job 1 -- "$cross" --patches "$root/patches/cmake-4.4.5" \
		"$recipes/dev-build/cmake/cmake-4.4.5.recipe" cmake \
		-DCMAKE_USE_SYSTEM_LIBRARY_CURL=ON -DCMAKE_USE_SYSTEM_LIBRARY_EXPAT=ON \
		-DCMAKE_USE_SYSTEM_LIBRARY_ZLIB=ON -DBUILD_CursesDialog=ON -DBUILD_QtDialog=OFF -DBUILD_TESTING=OFF \
		-DCMake_ENABLE_DEBUGGER=ON -DSPHINX_MAN=OFF -DSPHINX_HTML=OFF \
		-DCMAKE_EXE_LINKER_FLAGS=-lbsd -DCMAKE_SKIP_RPATH=ON \
		-DCMAKE_C_FLAGS="-ffile-prefix-map=$root/artifacts/cross-ports/cmake-4.4.5/src=cmake-4.4.5" \
		-DCMAKE_CXX_FLAGS="-ffile-prefix-map=$root/artifacts/cross-ports/cmake-4.4.5/src=cmake-4.4.5" \
		-DCMAKE_DATA_DIR=data/cmake -DCMAKE_DOC_DIR=documentation/packages/cmake \
		-DCMAKE_MAN_DIR=documentation/man -DCMAKE_XDGDATA_DIR=data
	"$package" "$recipes/dev-build/cmake/cmake-4.4.5.recipe" --requires lib:libbsd \
		--requires lib:libexpat --requires lib:libz --requires lib:libncursesw
fi

# --- binutils: sources/buildtools' binutils (Haiku's patches on 2.46.1, the cross tools' source),
# a Canadian cross (build linux, host = target = aarch64-unknown-haiku), with the recipe's options:
# programs in bin/, the tool directory develop/tools/aarch64-unknown-haiku (bin/: links to bin/, what
# the gcc driver runs; lib/ldscripts) as the binutils bootstrap package lays it out; no libraries
# or headers (the recipe deletes them), no gold, no gprofng, the bundled zlib, no zstd; __FILE__
# (bfd's assertions) without the build directory.
if want binutils; then
	version=2.46.1
	work="$root/artifacts/cross-ports/binutils-$version"
	rm -rf "$work"
	mkdir -p "$work/src" "$work/build" "$work/install"
	git -C "$root/sources/buildtools" archive HEAD binutils | tar -x -C "$work/src" --strip-components=1
	grep -q "BFD_VERSION\], \[$version\]" "$work/src/bfd/version.m4" \
		|| { echo "build-dev-tools: sources/buildtools' binutils is not $version" >&2; exit 1; }
	echo "build-dev-tools: binutils $version from buildtools $(git -C "$root/sources/buildtools" rev-parse --short HEAD)"
	(cd "$work/build" && PATH="$(dirname "$tools"):$PATH" "$work/src/configure" \
		--build=x86_64-pc-linux-gnu --host=aarch64-unknown-haiku --target=aarch64-unknown-haiku \
		--prefix=/boot/system --exec-prefix=/boot/system/develop/tools --bindir=/boot/system/bin \
		--libdir=/boot/system/develop/lib --includedir=/boot/system/develop/headers/binutils \
		--datarootdir=/boot/system/data --mandir=/boot/system/documentation/man \
		--infodir=/boot/system/documentation/info \
		--disable-nls --disable-werror --disable-shared --enable-plugins --enable-64-bit-bfd \
		--enable-largefile=yes --disable-libtool-lock --enable-ld=default --disable-gold \
		--disable-gprofng --without-zstd --without-system-zlib --with-sysroot=/ \
		--enable-default-execstack=no --disable-gdb --disable-gdbserver --disable-sim \
		--disable-readline --disable-libdecnumber \
		CC="$tools-gcc --sysroot=$sysroot" CXX="$tools-g++ --sysroot=$sysroot" \
		AR="$tools-ar" RANLIB="$tools-ranlib" STRIP="$tools-strip" NM="$tools-nm" \
		OBJCOPY="$tools-objcopy" OBJDUMP="$tools-objdump" READELF="$tools-readelf" \
		CC_FOR_BUILD=gcc CXX_FOR_BUILD=g++ CFLAGS="-O2 -ffile-prefix-map=$work/src=binutils-$version" \
		CXXFLAGS="-O2 -ffile-prefix-map=$work/src=binutils-$version") > "$work/configure.log" 2>&1 \
		|| { tail -n 30 "$work/configure.log" >&2; exit 1; }
	(cd "$work/build" && PATH="$(dirname "$tools"):$PATH" "$heavy" --mem-per-job 1 -- \
		make -j"$(nproc)" MAKEINFO=true LEXLIB=) > "$work/build.log" 2>&1 \
		|| { tail -n 30 "$work/build.log" >&2; exit 1; }
	echo "build-dev-tools: binutils compiler warnings: $(grep -c 'warning:' "$work/build.log" || true)"
	(cd "$work/build" && PATH="$(dirname "$tools"):$PATH" make install MAKEINFO=true \
		DESTDIR="$work/install") > "$work/install.log" 2>&1 || { tail -n 30 "$work/install.log" >&2; exit 1; }
	sys="$work/install/boot/system"
	# the recipe's INSTALL(): no libraries, headers, documentation; dlltool & co. are not built for
	# this target; the tool directory's copies become links to bin/, ld.bfd a link to ld
	rm -rf "$sys/develop/lib" "$sys/develop/headers" "$sys/documentation" "$sys/data" "$sys/lib"
	ln -sf ld "$sys/bin/ld.bfd"
	for f in "$sys/develop/tools/aarch64-unknown-haiku/bin"/*; do
		ln -sf "../../../../bin/$(basename "$f")" "$f"
	done
	"$package" "$ports/sys-devel/binutils/binutils-$version.recipe" --system-prefix --no-devel \
		--tree develop/tools --summary "Assembler, linker and binary tools for target aarch64-unknown-haiku"
fi

# --- python: meson (the recipe's sdist and patchset; HaikuPorts packages it as `meson`, arch any),
# setuptools (its sdist with the recipe's patch: the Haiku install schemes in distutils), and the
# PyPI wheels of the others (pure Python: Cython's py3-none-any wheel is its uncompiled build)
if want python; then
	hostPython="$root/artifacts/python-host/bin/python3.14"
	"$hostPython" -c "import sys; sys.exit(sys.version_info[:2] != (3, 14))" 2>/dev/null \
		|| { echo "build-dev-tools: no build python 3.14: run scripts/build-python.sh" >&2; exit 1; }
	command -v uv > /dev/null || { echo "build-dev-tools: needs uv (https://docs.astral.sh/uv/)" >&2; exit 1; }
	venv="$root/artifacts/python-build-venv"	# scripts/build-numpy.sh's
	[ -x "$venv/bin/python" ] || uv venv -q -p "$hostPython" "$venv"
	"$venv/bin/python" -c "import build, installer, packaging, setuptools" 2>/dev/null \
		|| uv pip install -q --python "$venv/bin/python" build installer packaging setuptools
	dl="$root/artifacts/cross-ports/dl"
	mkdir -p "$dl"
	fetch() {	# url|sha256 -> the file in $dl
		local url="${1%|*}" sum="${1##*|}" file="$dl/$(basename "${1%|*}")"
		[ -f "$file" ] || curl -sSfL -o "$file" "$url"
		echo "$sum  $file" | sha256sum -c --quiet || { echo "build-dev-tools: $file: bad checksum" >&2; exit 1; }
		echo "$file"
	}
	wheel() {	# sdist-directory -> the wheel built from it
		(cd "$1" && "$venv/bin/python" -m build -q --wheel --no-isolation --skip-dependency-check \
			--outdir "$1/dist" .) > "$1.build.log" 2>&1 || { tail -n 20 "$1.build.log" >&2; exit 1; }
		ls "$1"/dist/*.whl
	}
	pyWheel="$root/scripts/package-python-wheel.py"

	# meson: the recipe's source (the PyPI sdist) and patchset
	recipe="$ports/dev-build/meson/meson-1.12.1.recipe"
	sdist="$("$root/scripts/haikuports-fetch.sh" "$recipe" | sed -n 's/^haikuports-fetch: \(.*\) ([0-9]* bytes, sha256 ok)$/\1/p' | head -n 1)"
	work="$root/artifacts/cross-ports/meson-1.12.1-sdist"
	rm -rf "$work" "$work.build.log"
	mkdir -p "$work"
	tar -xzf "$sdist" -C "$work" --strip-components=1
	patch -s -p1 -d "$work" < "$ports/dev-build/meson/patches/meson-1.12.1.patchset"
	"$venv/bin/python" "$pyWheel" "$(wheel "$work")" --name meson --requires 'cmd:ninja >= 1.6'

	# setuptools: the sdist and the recipe's patch (82.0.1's applies to 84.2.1 with offsets)
	sdist="$(fetch "https://files.pythonhosted.org/packages/70/b3/c19426f783614d625699a4b247faf628ea9ab1db228674491767b417f9e1/setuptools-84.2.1.tar.gz|3ff8b3b5492a0aa66960f4419365a86b84e013070d4313e4d4a6894f5d64d6bc")"
	work="$root/artifacts/cross-ports/setuptools-84.2.1-sdist"
	rm -rf "$work" "$work.build.log"
	mkdir -p "$work"
	tar -xzf "$sdist" -C "$work" --strip-components=1
	patch -s -p1 -d "$work" < "$ports/dev-python/setuptools/patches/setuptools-82.0.1.patchset"
	"$venv/bin/python" "$pyWheel" "$(wheel "$work")"

	# url|sha256 of the newest releases' py3-none-any wheels
	for w in \
		"https://files.pythonhosted.org/packages/3f/06/3e4420302363fbb71be3c7f35ce042f54bfca330e3e66b3a2e3c4cca579f/pip-26.2.2-py3-none-any.whl|fd7f4dfa8190e014013b9f08f3e973f4e4c26ffd179a204895533a7254813a70" \
		"https://files.pythonhosted.org/packages/2e/29/69cfbb602cd91690c55d38ba9fe53e6a7e76a6fa647bf38f19c138d25449/wheel-0.48.0-py3-none-any.whl|3217dcc807155e45db462d7ef2431f5ddda0d7273b700d05a67b271ceb1287ab" \
		"https://files.pythonhosted.org/packages/9d/55/088578d75bc8dbcbc535af04b1d596ff227ca756dd74f9d3c1c526f955d0/cython-3.3.1-py3-none-any.whl|61abc7feedd20dac6c4ff7ab3a30e17136a067b242ab9253e2b4a6d9a72c2b61" \
		"https://files.pythonhosted.org/packages/b9/8e/d883718e872abc214ba053f60f7e6edc2abd5ffbd1544beb01a9c92ddd3c/pyproject_metadata-0.12.1-py3-none-any.whl|f7162d580a96386a8eb096da06215f981f547d1490f03055ef99e323bc2da427"; do
		"$venv/bin/python" "$pyWheel" "$(fetch "$w")"
	done
	# meson-python: HaikuPorts' requires cmd:meson (the meson package), not a meson_python314
	"$venv/bin/python" "$pyWheel" --map meson cmd:meson "$(fetch "https://files.pythonhosted.org/packages/96/62/0c1cf20fe158b0e623e78acbf5fb6de5f1410a408f65f727e4090497627b/meson_python-0.22.1-py3-none-any.whl|258fde948cf45aab5df23fcc9e17a9050ee73d4e1002fe6cf86519f61c414778")"
fi

# --- check: the packages as the Pi gets them
if want check; then
	pkgs=(make-4.4.1-1-arm64 ninja-1.13.2-1-arm64 pkgconf-3.0.10-1-arm64 pkgconf_devel-3.0.10-1-arm64
		cmake-4.4.5-1-arm64 binutils-2.46.1-1-arm64 meson-1.12.1-1-any pip_python3.14-26.2.2-1-any
		setuptools_python3.14-84.2.1-1-any wheel_python3.14-0.48.0-1-any cython_python3.14-3.3.1-1-any
		meson_python_python3.14-0.22.1-1-any pyproject_metadata_python3.14-0.12.1-1-any)
	check="$root/artifacts/cross-ports/dev-tools-check"
	rm -rf "$check"
	mkdir -p "$check/x"
	for p in "${pkgs[@]}"; do
		[ -f "$packages/$p.hpkg" ] || { echo "build-dev-tools: $p.hpkg missing" >&2; exit 1; }
		"$pkgtool" extract -C "$check/x" "$packages/$p.hpkg"
	done
	# what the image has (haiku, gcc_syslibs, zlib, expat; our curl, ncurses6, libiconv, libexecinfo)
	# and these packages
	lib="$sysroot/boot/system/lib"
	libs=("$lib/libroot.so" "$lib/libbsd.so" "$lib/libnetwork.so" "$lib/libbe.so" "$lib/libstdc++.so.6"
		"$lib/libgcc_s.so.1" "$lib/libz.so.1" "$lib/libexpat.so.1" "$lib/libcurl.so.4" "$lib/libncursesw.so.6"
		"$lib/libncurses.so.6" "$lib/libiconv.so.2" "$lib/libcharset.so.1" "$lib/libexecinfo.so.1.1"
		"$check/x/lib/libpkgconf.so.8")
	for l in "${libs[@]}"; do basename "$l"; done | LC_ALL=C sort -u > "$check/sonames.txt"
	for l in "${libs[@]}"; do "$tools-nm" -D --defined-only "$l" | awk '{print $NF}'; done \
		| sed 's/@.*//' | LC_ALL=C sort -u > "$check/defined.txt"
	elves=0
	while IFS= read -r -d '' f; do
		[ "$(head -c 4 "$f" | od -An -c | tr -d ' ')" = '177ELF' ] || continue
		elves=$((elves + 1))
		missingLibs="$("$tools-readelf" -d "$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | LC_ALL=C sort -u \
			| LC_ALL=C comm -23 - "$check/sonames.txt")"
		[ -z "$missingLibs" ] || { echo "build-dev-tools: ${f#"$check/x/"} needs $missingLibs" >&2; exit 1; }
		missing="$("$tools-nm" -D --undefined-only "$f" | awk '$1 == "U" {print $2} $1 == "w" {next}' \
			| sed 's/@.*//' | LC_ALL=C sort -u | LC_ALL=C comm -23 - "$check/defined.txt")"
		[ -z "$missing" ] || { echo "build-dev-tools: ${f#"$check/x/"}: undefined on Haiku: $missing" >&2; exit 1; }
	done < <(find "$check/x" -type f -print0)
	echo "build-dev-tools: $elves ELF files, every library and symbol resolved"
	# (Python modules name /boot/system/non-packaged on purpose: setuptools' Haiku install scheme)
	leaks="$(grep -rlaF -e "$root" -e "$HOME/" "$check/x" || true)"
	leaks+="$(find "$check/x" -type f -exec sh -c 'head -c 4 "$1" | grep -q ELF && grep -qaF non-packaged "$1" \
		&& echo " $1"' sh {} \;)"
	[ -z "$leaks" ] || { echo "build-dev-tools: host or non-packaged paths in: $leaks" >&2; exit 1; }
	echo "build-dev-tools: no host paths in the packaged files, no non-packaged path in a program"
	for p in "${pkgs[@]}"; do
		echo "== $p.hpkg ($(stat -c %s "$packages/$p.hpkg") bytes)"
		"$pkgtool" list -i "$packages/$p.hpkg" | sed -n 's/^\t\(provides\|requires\): /  \1 /p'
	done
	rm -rf "$check"
fi
