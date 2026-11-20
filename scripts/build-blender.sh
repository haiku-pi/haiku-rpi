#!/usr/bin/env bash
# build-blender.sh — cross-build Blender 3.6.23 LTS for Haiku arm64 with the minimal option set of
# docs/design/blender.md §4 (milestone M2), and every library it needs that the arm64 repository lacks,
# as HaikuPorts-style test packages (scripts/cross-port.sh, scripts/package-port.py --out) in
# artifacts/packages-test/blender/ — nothing here is published.
#
#   scripts/build-blender.sh [STEP [LAST]]   (STEP: start at that step; the earlier ones must already be
#                                            in the sysroot; LAST: stop after that step)
#
# Steps, in order:
#   sysroot      the packages the build needs extracted into artifacts/sysroot-arm64 (it was recreated
#                11-03 without many of them; a library configure does not find silently drops a feature)
#   python       CPython 3.10.22 (scripts/build-python.sh --version 3.10.22): python3.10 + _devel
#   libdeflate imath openexr tiff epoxy boost tbb oiio pugixml sse2neon
#                the libraries (packages <port> + <port>_devel; Imath, OIIO 2.4.15 and sse2neon from our
#                recipes in tools/recipes/, the others from HaikuPorts' recipes and patchsets)
#   oidn         OpenImageDenoise 2.5.1 (Cycles' Denoise; -7): oidn + oidn_devel, our recipe, its NEON
#                kernels compiled by the host's ISPC
#   numpy        NumPy 1.26.4 for Python 3.10 (the `aud` module; -7): numpy_python3.10
#                (scripts/build-numpy.sh --python 3.10)
#   alembic fftw Alembic 1.8.3 (Alembic import/export) and FFTW 3.3.10 (the Ocean modifier; -7), the
#                recipes and patchsets
#   blosc openvdb gmp potrace libharu
#                c-blosc 1.21.6, OpenVDB 10.1.0 (+ NanoVDB), GMP 6.3.0, potrace 1.16, libharu 2.4.3 (-8)
#   usd          OpenUSD 24.08 (-9: USD import/export): usd + usd_devel, our recipe and patchset
#   freetype     FreeType with Brotli, static, into Blender's own deps/ (not packaged)
#   blender_source  artifacts/downloads/blender/blender-3.6.23 + patches/blender/*.patch
#   hosttools    makesdna, makesrna, datatoc, datatoc_icon, smaa_areatex, msgfmt built for this host
#   configure    the cross configure (tools/cmake/haiku-arm64.cmake + tools/cmake/blender-minimal.cmake,
#                -DBLENDER_HOST_TOOLS); fails unless its WITH_* options equal the host configure's
#   build        ninja blender, under scripts/heavy-build.sh (≤ 16 GB)
#   stage        the install tree + runtime packages for the Pi test, artifacts/blender-tests/
#   blender_package  blender-3.6.23-9-arm64.hpkg (apps/Blender, Deskbar entry) in artifacts/packages-test/blender-9
#
# Packages: the libraries of revisions 1-6 in artifacts/packages-test/blender/ (unchanged since); what
# -7 adds (oidn, numpy_python3.10, alembic, fftw) in artifacts/packages-test/blender-7/; what -8 adds (boost1.83
# -2 with regex, iostreams and locale; c_blosc, openvdb, gmp, potrace, libharu) in
# artifacts/packages-test/blender-8/; what -9 adds (usd; blender itself) in artifacts/packages-test/blender-9/.
#
# Work directories: artifacts/cross-ports/<port>-<version>/ for the libraries,
# artifacts/cross-ports/blender-3.6.23/{src,deps,host-build,host-tools,build}/ for Blender.
# Host tools: cmake, ninja, meson, gcc/g++ (the host generators), python3, curl, file.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
ports="$root/sources/haikuports"
cross="$root/scripts/cross-port.sh"
gen="$root/sources/haiku/generated.arm64"
sysroot="$root/artifacts/sysroot-arm64"
np="$sysroot/boot/system/non-packaged"
pkgtool="$gen/objects/linux/x86_64/release/tools/package/package"
hostTools="$gen/objects/linux/x86_64/release/tools"
tools="$gen/cross-tools-arm64/bin/aarch64-unknown-haiku"
out="$root/artifacts/packages-test/blender"
out7="$root/artifacts/packages-test/blender-7"
out8="$root/artifacts/packages-test/blender-8"
out9="$root/artifacts/packages-test/blender-9"
package() { "$root/scripts/package-port.py" "$@" --out "$out"; }
mkdir -p "$out" "$out7" "$out8" "$out9"

# the script-mode builds see pkg-config into the sysroot
export PKG_CONFIG_SYSROOT_DIR="$sysroot"
export PKG_CONFIG_LIBDIR="$np/lib/pkgconfig:$np/develop/lib/pkgconfig:$sysroot/boot/system/develop/lib/pkgconfig"

# need FILE...: fail unless each path (relative to the sysroot's boot/system) exists
need() {
	local f missing=0
	for f in "$@"; do
		[ -e "$sysroot/boot/system/$f" ] || { echo "build-blender: $f missing from the sysroot" >&2; missing=1; }
	done
	[ "$missing" = 0 ] || exit 1
}

# the newest revision of a package (NAME-VERSION) in DIR
newest() {
	ls "$1"/"$2"-[0-9]*-arm64.hpkg 2> /dev/null | sort -V | tail -n 1
}

sysroot() {
	local f p
	for p in zstd zstd_devel brotli brotli_devel libwebp libwebp_devel bzip2 bzip2_devel libedit \
			libedit_devel libpng16 libpng16_devel libjpeg_turbo libjpeg_turbo_devel libiconv libiconv_devel \
			ffmpeg6 ffmpeg6_devel lz4 lz4_devel; do
		f="$(newest "$root/artifacts/packages" "$p")"
		[ -n "$f" ] || { echo "build-blender: no $p package in artifacts/packages" >&2; exit 1; }
		"$pkgtool" extract -C "$sysroot/boot/system" "$f"
		echo "build-blender: extracted $(basename "$f")"
	done
	# SDL2 with the per-thread GL context (M1, blender.md §3.2), not published yet
	for p in libsdl2 libsdl2_devel; do
		f="$(newest "$root/artifacts/packages-test/libsdl2-8" "$p")"
		[ -n "$f" ] || { echo "build-blender: no $p in artifacts/packages-test/libsdl2-8" >&2; exit 1; }
		"$pkgtool" extract -C "$sysroot/boot/system" "$f"
		echo "build-blender: extracted $(basename "$f")"
	done
	# expat (CPython's pyexpat, --with-system-expat): the bootstrap packages jam's repository lists
	for p in expat expat_devel; do
		"$pkgtool" extract -C "$sysroot/boot/system" "$gen/download/$p-2.5.0_bootstrap-1-arm64.hpkg"
	done
	rm -f "$sysroot/boot/system/.PackageInfo"
	sed -i 's|/packages/[^/]*/\.self|/boot/system|g' "$sysroot"/boot/system/develop/lib/pkgconfig/expat.pc
	need lib/libzstd.so.1 develop/headers/zstd.h lib/libbrotlidec.so.1 develop/lib/libbrotlidec.so \
		lib/libwebp.so.7 develop/headers/webp/decode.h lib/libbz2.so.1.0 lib/libedit.so.0 \
		lib/libpng16.so.16 develop/headers/png.h lib/libjpeg.so.62 develop/headers/jpeglib.h \
		lib/libexpat.so.1 develop/headers/expat.h develop/lib/libSDL2.so develop/headers/SDL2/SDL.h \
		develop/lib/libGL.so develop/lib/libEGL.so lib/libiconv.so.2 lib/liblz4.so.1 develop/headers/lz4.h
}

python() {
	"$root/scripts/build-python.sh" --version 3.10.22 --out "$out"
}

# a copy of RECIPE (into artifacts/cross-ports/recipes/<category>/, with its patches and licenses)
# in which the text FROM (a recipe-local variable, a bash expansion) is replaced by TO:
# cross-port.sh and haikuports-fetch.sh substitute only $portVersion and friends (build-webkit.sh's)
#   recipe_with RECIPE FROM TO
recipe_with() {
	local dir="$root/artifacts/cross-ports/recipes/$(basename "$(dirname "$1")")" d
	mkdir -p "$dir"
	for d in patches licenses download; do
		[ -d "$(dirname "$1")/$d" ] && ln -sfn "$(dirname "$1")/$d" "$dir/$d"
	done
	FROM="$2" TO="$3" perl -pe 's/\Q$ENV{FROM}\E/$ENV{TO}/g' "$1" > "$dir/$(basename "$1")"
	echo "$dir/$(basename "$1")"
}

# cmake_relative NAME: a CMake package (lib/cmake/NAME in the sysroot's non-packaged/) that names its
# install prefix as an absolute path (/boot/system/non-packaged/include) instead of _IMPORT_PREFIX:
# with the sysroot, the path must be relative to where the file is
cmake_relative() {
	sed -i 's|"/boot/system/non-packaged/|"${_IMPORT_PREFIX}/|g' "$np/lib/cmake/$1"/*.cmake
}

# libdeflate (OpenEXR 3.2's compression): the recipe's options, without the gzip/gunzip programs
libdeflate() {
	local recipe="$ports/app-arch/libdeflate/libdeflate-1.18.recipe"
	"$cross" "$recipe" cmake -DLIBDEFLATE_BUILD_STATIC_LIB=OFF -DLIBDEFLATE_BUILD_GZIP=OFF
	cmake_relative libdeflate
	package "$recipe"
	need non-packaged/lib/libdeflate.so.0 develop/headers/libdeflate.h
}

# Imath 3.1 (OpenEXR, OIIO, Blender's imbuf): ours (tools/recipes; HaikuPorts builds it inside openexr3.2)
imath() {
	local recipe="$root/tools/recipes/media-libs/imath/imath-3.1.12.recipe"
	"$cross" "$recipe" cmake -DBUILD_TESTING=OFF -DPYTHON=OFF -DIMATH_INSTALL_PKG_CONFIG=ON
	package "$recipe"
	need non-packaged/lib/libImath-3_1.so.29 develop/headers/Imath/ImathVec.h
}

# OpenEXR 3.2.4: the recipe + patchset, against the Imath and libdeflate above (not its own downloads),
# libraries only (the recipe's _tools package is not made)
openexr() {
	local recipe="$ports/media-libs/openexr/openexr3.2-3.2.4.recipe" w="$root/artifacts/cross-ports/openexr3.2-3.2.4"
	"$cross" "$recipe" cmake -DBUILD_TESTING=OFF -DOPENEXR_BUILD_TOOLS=OFF -DOPENEXR_INSTALL_TOOLS=OFF \
		-DOPENEXR_INSTALL_EXAMPLES=OFF -DOPENEXR_BUILD_EXAMPLES=OFF -DOPENEXR_INSTALL_DOCS=OFF \
		-DOPENEXR_FORCE_INTERNAL_IMATH=OFF -DOPENEXR_FORCE_INTERNAL_DEFLATE=OFF -Wno-dev
	if grep -qi -E 'internal (imath|deflate)|fetching|FetchContent' "$w/configure.log"; then
		grep -i -E 'imath|deflate' "$w/configure.log" >&2
		echo "build-blender: OpenEXR did not take the sysroot's Imath/libdeflate" >&2
		exit 1
	fi
	package "$recipe"
	need non-packaged/lib/libOpenEXR-3_2.so.31 develop/headers/OpenEXR/ImfRgbaFile.h
}

# libtiff 4.7.0 (OIIO): the recipe's autotools build, with only zlib and JPEG as codecs (the others
# would each pull in a library Blender does not otherwise need), no tools/tests/docs
tiff() {
	local recipe="$ports/media-libs/tiff/tiff-4.7.0.recipe"
	"$cross" "$recipe" autotools --disable-static --disable-jbig --disable-lerc --disable-lzma \
		--disable-webp --disable-zstd --disable-libdeflate --disable-tools --disable-tests \
		--disable-contrib --disable-docs --disable-cxx --enable-zlib --enable-jpeg
	rm -rf "$root/artifacts/cross-ports/tiff-4.7.0/install/boot/system/non-packaged/share"
	package "$recipe"
	need non-packaged/lib/libtiff.so.6 develop/headers/tiffio.h
}

# libepoxy 1.5.8 (Blender's GL loader): the recipe + patchset; EGL, no GLX/X11 (blender.md §3.4)
epoxy() {
	local recipe="$ports/media-libs/libepoxy/libepoxy-1.5.8.recipe"
	"$cross" "$recipe" meson -Degl=yes -Dglx=no -Dx11=false -Dtests=false
	package "$recipe"
	need non-packaged/lib/libepoxy.so.0 develop/headers/epoxy/gl.h
}

# Boost 1.83 (the version HaikuPorts' blender3 builds against; Blender 3.6 pins 1.80), shared, as the
# recipe's b2 options. Revision 1 (published) had only what OIIO 2.4 links (thread; filesystem is
# std::filesystem with GCC >= 9) and what thread needs. Revision 2 (-8, artifacts/packages-test/blender-8)
# adds what Blender's own find_package(Boost) asks for once WITH_BOOST is on (OpenVDB, Quadriflow, i18n):
# regex, iostreams (OpenVDB's delayed loading: mapped_file only, so no compression filters: no zlib,
# bzip2, lzma, zstd) and locale (i18n; iconv from libiconv, no ICU, no POSIX backend). b2 has no cross
# mode of its own: the engine is built for the host (bootstrap.sh), the cross g++ is a "gcc-haiku"
# toolset in a user-config.jam, target-os=haiku.
boost() {
	local recipe lib l
	recipe="$(recipe_with "$ports/dev-libs/boost/boost1.83-1.83.0.recipe" '${portVersion%.*}' 1.83)"
	"$cross" "$recipe" script '
./bootstrap.sh --with-toolset=gcc --without-icu > bootstrap.log 2>&1 || { cat bootstrap.log; exit 1; }
cxx="${CXX%% *}"
echo "using gcc : haiku : $cxx : <compileflags>--sysroot=$SYSROOT <linkflags>--sysroot=$SYSROOT <archiver>$AR <ranlib>$RANLIB ;" > user-config.jam
./b2 -q -j"$(nproc)" --user-config=user-config.jam toolset=gcc-haiku target-os=haiku \
	architecture=arm address-model=64 binary-format=elf abi=aapcs \
	--with-thread --with-chrono --with-atomic --with-date_time --with-system --with-filesystem \
	--with-regex --with-iostreams --with-locale \
	-sNO_ZLIB=1 -sNO_BZIP2=1 -sNO_LZMA=1 -sNO_ZSTD=1 \
	--disable-icu boost.locale.icu=off boost.locale.posix=off boost.locale.iconv=on \
	pch=off inlining=on threading=multi variant=release \
	link=shared runtime-link=shared --prefix="$DEST" --libdir="$DEST/lib" --includedir="$DEST/include" \
	--layout=system install'
	lib="$root/artifacts/cross-ports/boost1.83-1.83.0/install/boot/system/non-packaged/lib"
	for l in thread chrono atomic date_time system filesystem regex iostreams locale; do
		[ -f "$lib/libboost_$l.so.1.83.0" ] || { echo "build-blender: Boost built without $l" >&2; exit 1; }
	done
	# iostreams without filters (nothing but libroot/libstdc++), locale with iconv
	! "$tools-readelf" -d "$lib/libboost_iostreams.so.1.83.0" | grep -E 'NEEDED.*\[lib(z|bz2|lzma|zstd)' \
		|| { echo "build-blender: Boost iostreams links a compression library" >&2; exit 1; }
	"$tools-readelf" -d "$lib/libboost_locale.so.1.83.0" | grep 'NEEDED.*\[libiconv' > /dev/null \
		|| { echo "build-blender: Boost locale does not link libiconv" >&2; exit 1; }
	# (libiconv is in the sysroot's lib/, which package-port.py does not turn into requires)
	"$root/scripts/package-port.py" "$recipe" --revision 2 --requires lib:libiconv --out "$out8"
	need non-packaged/lib/libboost_thread.so.1.83.0 non-packaged/lib/libboost_iostreams.so.1.83.0 \
		non-packaged/lib/libboost_regex.so.1.83.0 non-packaged/lib/libboost_locale.so.1.83.0 \
		develop/headers/boost/thread.hpp develop/headers/boost/graph/adjacency_list.hpp
	# the unpacked and the built source trees: 1.8 GB
	rm -rf "$root/artifacts/cross-ports/boost1.83-1.83.0/src" "$root/artifacts/cross-ports/boost1.83-1.83.0/source"
}

# oneTBB 2022.3.0 (Cycles and Blender's threading; WITH_TBB gates Cycles): the recipe + its patchset (the
# stock headers stop with "Unknown platform/compiler" on Haiku), Release instead of the recipe's
# RelWithDebInfo, no tests
tbb() {
	local recipe="$ports/dev-cpp/tbb/tbb-2022.3.0.recipe"
	"$cross" "$recipe" cmake -DTBB_STRICT=OFF -DTBB_TEST=OFF -DTBB_EXAMPLES=OFF -DTBB_DISABLE_HWLOC_AUTOMATIC_SEARCH=ON
	cmake_relative TBB
	package "$recipe"
	need non-packaged/lib/libtbb.so.12 develop/headers/oneapi/tbb.h develop/headers/tbb/tbb.h
}

# pinned downloads that are not recipes (fmt and robin-map: OIIO's header-only dependencies, which its
# configure would otherwise git-clone): artifacts/downloads/blender-deps/, checked here
#   pinned FILE URL SHA256 -> the path
pinned() {
	local f="$root/artifacts/downloads/blender-deps/$1"
	mkdir -p "$(dirname "$f")"
	[ -f "$f" ] || curl -sSLf -o "$f" "$2"
	echo "$3  $f" | sha256sum -c --quiet - >&2 || { echo "build-blender: $f: wrong sha256" >&2; exit 1; }
	echo "$f"
}

# OpenImageIO 2.4.15.0 (Blender: REQUIRED): ours (tools/recipes). The readers/writers Blender's minimal
# build needs (OpenEXR, TIFF, PNG, JPEG, WebP; the built-in BMP, HDR, TGA, ... need nothing), every other
# optional library off explicitly (the sysroot has FFmpeg, FreeType, GL, which it would otherwise pick
# up), no tools/tests/Python. fmt 9.1.0 + robin-map 0.6.2 (Blender's pins) from pinned downloads, fmt
# internalized into OIIO's headers. Compile jobs take up to ~1 GB: under heavy-build.sh.
oiio() {
	local recipe="$root/tools/recipes/media-libs/openimageio/openimageio2.4-2.4.15.0.recipe" ext
	local w="$root/artifacts/cross-ports/openimageio2.4-2.4.15.0" lib
	ext="$root/artifacts/cross-ports/blender-ext"
	rm -rf "$ext"
	mkdir -p "$ext"
	tar -xzf "$(pinned fmt-9.1.0.tar.gz https://github.com/fmtlib/fmt/archive/9.1.0.tar.gz \
		5dea48d1fcddc3ec571ce2058e13910a0d4a6bab4cc09a809d8b1dd1c88ae6f2)" -C "$ext"
	tar -xzf "$(pinned robin-map-0.6.2.tar.gz https://github.com/Tessil/robin-map/archive/v0.6.2.tar.gz \
		c08ec4b1bf1c85eb0d6432244a6a89862229da1cb834f3f90fba8dc35d8c8ef1)" -C "$ext"
	"$root/scripts/heavy-build.sh" -j 8 --mem-per-job 2 --max 12 -- env CROSS_PORT_JOBS='{JOBS}' \
		"$cross" "$recipe" cmake -DCMAKE_CXX_STANDARD=17 -DOIIO_BUILD_TESTS=OFF -DBUILD_TESTING=OFF \
		-DOIIO_BUILD_TOOLS=OFF -DUSE_PYTHON=OFF -DBUILD_DOCS=OFF -DINSTALL_DOCS=OFF -DINSTALL_FONTS=OFF \
		-DUSE_QT=OFF -DUSE_OPENGL=OFF -DUSE_OPENCV=OFF -DUSE_FFMPEG=OFF -DUSE_FREETYPE=OFF \
		-DUSE_OPENCOLORIO=OFF -DUSE_LIBRAW=OFF -DUSE_LIBHEIF=OFF -DUSE_GIF=OFF -DUSE_OPENJPEG=OFF \
		-DUSE_OPENVDB=OFF -DUSE_PTEX=OFF -DUSE_DCMTK=OFF -DUSE_TBB=OFF -DUSE_NUKE=OFF -DUSE_R3DSDK=OFF \
		-DUSE_BZIP2=OFF -DUSE_JPEGTURBO=ON -DUSE_PNG=ON -DUSE_WEBP=ON -DUSE_OPENEXR=ON -DUSE_TIFF=ON \
		-DBUILD_MISSING_FMT=OFF -DBUILD_MISSING_ROBINMAP=OFF -DBUILD_MISSING_DEPS=OFF -DINTERNALIZE_FMT=ON \
		-DFMT_INCLUDE_DIR="$ext/fmt-9.1.0/include" -DROBINMAP_INCLUDE_DIR="$ext/robin-map-0.6.2/include" \
		-DOIIO_DOWNLOAD_MISSING_TESTDATA=OFF -DEMBEDPLUGINS=ON -Wno-dev \
		-DCMAKE_CXX_FLAGS="-ffile-prefix-map=$w/src=/sources/OpenImageIO-2.4.15.0"
	cmake_relative OpenImageIO
	# the libraries it was meant to link, and no others
	lib="$w/install/boot/system/non-packaged/lib/libOpenImageIO.so.2.4"
	"$tools-readelf" -d "$lib" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' ' | sed 's/^/build-blender: libOpenImageIO needs: /'
	echo
	for n in libOpenEXR-3_2 libtiff libpng16 libjpeg libwebp libboost_thread; do
		"$tools-readelf" -d "$lib" | grep "NEEDED.*\[$n" > /dev/null || { echo "build-blender: OIIO does not link $n" >&2; exit 1; }
	done
	! "$tools-readelf" -d "$lib" | grep -E "NEEDED.*\[(libav|libfreetype|libGL|libOpenColorIO|libraw|libheif|libgif)" \
		|| { echo "build-blender: OIIO links an optional library it should not" >&2; exit 1; }
	package "$recipe" --revision 2
	need non-packaged/lib/libOpenImageIO.so.2.4 develop/headers/OpenImageIO/imageio.h \
		develop/headers/OpenImageIO/detail/fmt/format.h
}

# pugixml 1.15 (Cycles' XML reader; Blender's grease-pencil SVG export): the recipe's shared build.
# Blender 3.6 looks for OIIO's internal copy as OpenImageIO/pugixml.hpp, where OIIO 2.4 no longer puts it
# (detail/pugixml/, in the OIIO namespace), so Cycles needs a pugixml of its own (as Blender's own
# library builds have)
pugixml() {
	local recipe="$ports/dev-libs/pugixml/pugixml-1.15.recipe"
	"$cross" "$recipe" cmake -DBUILD_SHARED_LIBS=ON -DPUGIXML_BUILD_TESTS=OFF
	cmake_relative pugixml
	package "$recipe"
	need non-packaged/lib/libpugixml.so.1 develop/headers/pugixml.hpp
}

# OpenColorIO 2.3.2 and what it needs (M6: Filmic and the other view transforms; Blender 3.6 handles OCIO
# 2.3's API): yaml-cpp 0.8, pystring 1.1.4, minizip-ng 4.0.7 (zlib only), the recipes' shared builds; expat
# and Imath are in the sysroot already (expat given by path: the bootstrap package's CMake config names
# /boot/system/include)
yaml_cpp() {
	local recipe="$ports/dev-cpp/yaml_cpp/yaml_cpp0.8-0.8.0.recipe"
	"$cross" "$recipe" cmake -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DBUILD_SHARED_LIBS=ON -DYAML_BUILD_SHARED_LIBS=ON -DYAML_CPP_BUILD_TOOLS=OFF \
		-DYAML_CPP_BUILD_TESTS=OFF -DYAML_CPP_BUILD_CONTRIB=OFF
	cmake_relative yaml-cpp
	package "$recipe"
	need non-packaged/lib/libyaml-cpp.so.0.8 develop/headers/yaml-cpp/yaml.h
}

pystring() {
	local recipe="$ports/dev-cpp/pystring/pystring-1.1.4.recipe"
	"$cross" "$recipe" cmake -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DBUILD_SHARED_LIBS=ON
	package "$recipe"
	need non-packaged/lib/libpystring.so.1.1.4 develop/headers/pystring.h
}

minizip_ng() {
	local recipe="$ports/sys-libs/minizip-ng/minizip_ng-4.0.7.recipe"
	"$cross" "$recipe" cmake -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DMZ_LIB_SUFFIX=-ng -DBUILD_SHARED_LIBS=ON -DMZ_ZLIB=ON -DMZ_BZIP2=OFF \
		-DMZ_LZMA=OFF -DMZ_ZSTD=OFF -DMZ_OPENSSL=OFF -DMZ_LIBBSD=OFF -DMZ_ICONV=OFF -DMZ_FETCH_LIBS=OFF \
		-DMZ_PKCRYPT=OFF -DMZ_WZAES=OFF
	cmake_relative minizip-ng
	package "$recipe"
	need non-packaged/lib/libminizip-ng.so.1 develop/headers/minizip-ng/mz.h
}

opencolorio() {
	local recipe="$ports/media-libs/opencolorio/opencolorio2.3-2.3.2.recipe" lib
	lib="$root/artifacts/cross-ports/opencolorio2.3-2.3.2/install/boot/system/non-packaged/lib/libOpenColorIO.so.2.3"
	"$cross" "$recipe" cmake -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DBUILD_SHARED_LIBS=ON -DOCIO_BUILD_APPS=OFF -DOCIO_BUILD_GPU_TESTS=OFF \
		-DOCIO_BUILD_PYTHON=OFF -DOCIO_BUILD_TESTS=OFF -DOCIO_BUILD_DOCS=OFF -DOCIO_BUILD_OPENFX=OFF \
		-DOCIO_INSTALL_EXT_PACKAGES=NONE -DOCIO_USE_SIMD=OFF -DOCIO_USE_SSE=OFF \
		-Dminizip-ng_INCLUDE_DIR="$np/include/minizip-ng" -Dminizip-ng_LIBRARY="$np/lib/libminizip-ng.so" \
		-Dexpat_ROOT="$sysroot/boot/system/develop" -Dexpat_INCLUDE_DIR="$sysroot/boot/system/develop/headers" \
		-Dexpat_LIBRARY="$sysroot/boot/system/develop/lib/libexpat.so" -Wno-dev
	cmake_relative OpenColorIO
	for n in libyaml-cpp libpystring libminizip-ng libexpat libImath; do
		"$tools-readelf" -d "$lib" | grep "NEEDED.*\[$n" > /dev/null || { echo "build-blender: OCIO does not link $n" >&2; exit 1; }
	done
	package "$recipe"
	need non-packaged/lib/libOpenColorIO.so.2.3 develop/headers/OpenColorIO/OpenColorIO.h
}

# OpenSubdiv 3.5.0 (M6: the Subdivision Surface and Multires modifiers, "Disabled, built without
# OpenSubdiv" without it; Blender's pin): CPU and the GL backend Blender links (osdGPU; its GPU
# evaluation needs compute shaders, which V3D's desktop GL lacks, so Blender uses the CPU one). No TBB
# evaluator: 3.5 uses tbb/task_scheduler_init.h, which oneTBB removed (Blender does its own threading)
opensubdiv() {
	local recipe
	recipe="$(recipe_with "$ports/media-libs/opensubdiv/opensubdiv3.5-3.5.0.recipe" '${portVersion//\./_}' 3_5_0)"
	"$cross" "$recipe" cmake -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DNO_EXAMPLES=ON -DNO_TUTORIALS=ON -DNO_REGRESSION=ON -DNO_TESTS=ON \
		-DNO_GLTESTS=ON -DNO_DOC=ON -DNO_PTEX=ON -DNO_CUDA=ON -DNO_OPENCL=ON -DNO_CLEW=ON -DNO_DX=ON \
		-DNO_METAL=ON -DNO_OMP=ON -DNO_GLFW=ON -DNO_GLFW_X11=ON -DNO_TBB=ON -DNO_OPENGL=OFF \
		-DCMAKE_SKIP_RPATH=ON -Wno-dev
	package "$recipe"
	need non-packaged/lib/libosdCPU.so.3.5.0 non-packaged/lib/libosdGPU.so.3.5.0 \
		develop/headers/opensubdiv/far/topologyRefiner.h
}

# sse2neon 1.6.0 (Blender's pin): the one header, for Cycles' SSE code on NEON (blender.md §5); only a
# sse2neon_devel package (package-port.py makes no runtime package without files)
sse2neon() {
	local recipe="$root/tools/recipes/dev-cpp/sse2neon/sse2neon-1.6.0.recipe"
	"$cross" "$recipe" script 'mkdir -p "$DEST/include" && cp sse2neon.h "$DEST/include/"'
	package "$recipe"
	need non-packaged/include/sse2neon.h develop/headers/sse2neon.h
}

# Intel Open Image Denoise 2.5.1 (-7: Cycles' Denoise for final renders and the viewport, the
# compositor's Denoise node; blender.md §7.14): ours (tools/recipes; one Haiku patch, a no-op thread
# affinity). The CPU device only, with TBB; its kernels are ISPC programs, compiled on this host by the
# official ISPC 1.32.0 Linux build (pinned) for aarch64 NEON (neon-i32x8; ISPC's linux target-os gives
# plain ELF objects); only the RT filter's weights (Blender uses no other filter); oidnDenoise and
# oidnBenchmark packaged, oidnTest not. OIDN 1.4 (Blender 3.6's pin) is x86-only (oneDNN).
oidn() {
	local recipe="$root/tools/recipes/media-libs/oidn/oidn-2.5.1.recipe" w="$root/artifacts/cross-ports/oidn-2.5.1"
	local ispc="$root/artifacts/cross-ports/ispc-1.32.0" lib o n
	if [ ! -x "$ispc/bin/ispc" ]; then
		rm -rf "$ispc"
		mkdir -p "$ispc"
		tar -xzf "$(pinned ispc-v1.32.0-linux.tar.gz \
			https://github.com/ispc/ispc/releases/download/v1.32.0/ispc-v1.32.0-linux.tar.gz \
			faf266bda2b702d68976ffd26bbd36c1ddba43424cc3c44f25b092cd1aa1f64a)" -C "$ispc" --strip-components=1
	fi
	"$root/scripts/heavy-build.sh" -j 12 --mem-per-job 1 --max 12 -- env CROSS_PORT_JOBS='{JOBS}' \
		"$cross" "$recipe" cmake -DISPC_EXECUTABLE="$ispc/bin/ispc" -DOIDN_DEVICE_CPU=ON \
		-DOIDN_DEVICE_CUDA=OFF -DOIDN_DEVICE_HIP=OFF -DOIDN_APPS=ON -DOIDN_APPS_OPENIMAGEIO=OFF \
		-DOIDN_FILTER_RT=ON -DOIDN_FILTER_RTLIGHTMAP=OFF -DOIDN_INSTALL_DEPENDENCIES=OFF \
		-DCMAKE_SKIP_RPATH=ON -Wno-dev
	grep -q '^ISPC_VERSION:STRING=1.32.0$' "$w/build/CMakeCache.txt" \
		|| { echo "build-blender: OIDN did not find ISPC 1.32.0" >&2; exit 1; }
	# the CPU device with its ISPC kernels (13 objects for ARM64), none of them using Armv8.2 FP16
	# arithmetic (the Cortex-A72 is Armv8.0: SIGILL), linked to TBB
	n="$(find "$w/build/devices/cpu" -name '*.dev.o' | wc -l)"
	[ "$n" -ge 13 ] || { echo "build-blender: only $n ISPC objects in the OIDN CPU device" >&2; exit 1; }
	for o in $(find "$w/build/devices/cpu" -name '*.dev.o'); do
		"$tools-readelf" -h "$o" | grep 'Machine:.*AArch64' > /dev/null || { echo "build-blender: $o is not AArch64" >&2; exit 1; }
		! "$tools-objdump" -d "$o" | grep -E '\sf(add|sub|mul|mla|mls|max|min|maxnm|minnm|div|abs|neg|sqrt|cm[a-z]+|rint[a-z]|cvtz[su])\s+(v[0-9]+\.[48]h|h[0-9]+)' > /dev/null \
			|| { echo "build-blender: $o uses FP16 arithmetic" >&2; exit 1; }
	done
	lib="$w/install/boot/system/non-packaged/lib"
	"$tools-readelf" -d "$lib/libOpenImageDenoise_device_cpu.so.2.5.1" | grep 'NEEDED.*\[libtbb.so' > /dev/null \
		|| { echo "build-blender: the OIDN CPU device does not link TBB" >&2; exit 1; }
	! "$tools-readelf" -d "$lib/libOpenImageDenoise_core.so.2.5.1" | grep -E 'RPATH|RUNPATH' > /dev/null \
		|| { echo "build-blender: OIDN has a run path" >&2; exit 1; }
	rm -f "$w/install/boot/system/non-packaged/bin/oidnTest"
	rm -rf "$w/install/boot/system/non-packaged/share"
	cmake_relative OpenImageDenoise-2.5.1
	"$root/scripts/package-port.py" "$recipe" --out "$out7"
	need non-packaged/lib/libOpenImageDenoise.so.2 non-packaged/lib/libOpenImageDenoise_device_cpu.so.2.5.1 \
		develop/headers/OpenImageDenoise/oidn.hpp
}

# NumPy 1.26.4 for Blender's Python 3.10 (-7: audaspace's Python API, the `aud` module, needs it at build
# and run time; add-ons like the glTF importer use it too): numpy_python3.10, also extracted into the
# sysroot (lib/python3.10/vendor-packages), where Blender's configure finds its C headers
numpy() {
	"$root/scripts/build-numpy.sh" --python 3.10 --out "$out7"
	need lib/python3.10/vendor-packages/numpy/core/include/numpy/ndarrayobject.h
}

# Alembic 1.8.3 (-7: File > Import/Export > Alembic; Blender's pin): the recipe + patchset, Ogawa only (no
# HDF5, as Blender's own builds), the library only (no abc* tools, tests, Python binding)
alembic() {
	local recipe="$ports/media-libs/alembic/alembic-1.8.3.recipe" lib
	"$cross" "$recipe" cmake -DUSE_HDF5=OFF -DUSE_TESTS=OFF -DUSE_BINARIES=OFF -DUSE_PYALEMBIC=OFF \
		-DUSE_ARNOLD=OFF -DUSE_MAYA=OFF -DUSE_PRMAN=OFF -DALEMBIC_SHARED_LIBS=ON -DCMAKE_SKIP_RPATH=ON \
		-DCMAKE_POLICY_VERSION_MINIMUM=3.5 -Wno-dev
	lib="$root/artifacts/cross-ports/alembic-1.8.3/install/boot/system/non-packaged/lib/libAlembic.so.1.8.3"
	"$tools-readelf" -d "$lib" | grep 'NEEDED.*\[libImath-3_1' > /dev/null \
		|| { echo "build-blender: Alembic does not link Imath 3.1" >&2; exit 1; }
	cmake_relative Alembic
	"$root/scripts/package-port.py" "$recipe" --out "$out7"
	need non-packaged/lib/libAlembic.so.1.8 develop/headers/Alembic/Abc/All.h
}

# FFTW 3.3.10 (-7: the Ocean modifier needs it; WITH_MOD_OCEANSIM requires WITH_FFTW3): the recipe +
# patchset, the double-precision library and its threads library only (the one Blender links; the
# recipe also builds float, long double and quad), no static libraries, no Fortran wrappers
fftw() {
	local recipe="$ports/sci-libs/fftw/fftw-3.3.10.recipe"
	"$cross" "$recipe" autotools --enable-shared --disable-static --enable-threads --disable-fortran --disable-doc
	rm -rf "$root/artifacts/cross-ports/fftw-3.3.10/install/boot/system/non-packaged/share"
	"$root/scripts/package-port.py" "$recipe" --out "$out7"
	need non-packaged/lib/libfftw3.so.3 develop/headers/fftw3.h
}

# c-blosc 1.21.6 (-8: OpenVDB's grid compression; Blender pins 1.21.1, HaikuPorts has 1.18.1): ours
# (tools/recipes), shared, the system's LZ4 (OpenVDB writes LZ4 blocks: a Blosc without it builds and
# links, then fails on real .vdb files), Zstd and zlib, no Snappy; C11 (GCC 16 defaults to C23, where
# shuffle.c's typedef of bool is an error)
blosc() {
	local recipe="$root/tools/recipes/dev-libs/c_blosc/c_blosc-1.21.6.recipe" lib n
	"$cross" "$recipe" cmake -DBUILD_STATIC=OFF -DBUILD_TESTS=OFF -DBUILD_FUZZERS=OFF -DBUILD_BENCHMARKS=OFF \
		-DPREFER_EXTERNAL_LZ4=ON -DPREFER_EXTERNAL_ZLIB=ON -DPREFER_EXTERNAL_ZSTD=ON -DDEACTIVATE_SNAPPY=ON \
		-DDEACTIVATE_AVX2=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -Wno-dev \
		-DCMAKE_C_STANDARD=11 -DCMAKE_C_EXTENSIONS=ON
	lib="$root/artifacts/cross-ports/c_blosc-1.21.6/install/boot/system/non-packaged/lib/libblosc.so.1.21.6"
	for n in liblz4 libzstd libz; do
		"$tools-readelf" -d "$lib" | grep "NEEDED.*\[$n\.so" > /dev/null \
			|| { echo "build-blender: Blosc does not link $n" >&2; exit 1; }
	done
	# (the system's LZ4 and Zstd are in the sysroot's lib/: named here)
	"$root/scripts/package-port.py" "$recipe" --requires lib:liblz4 --requires lib:libzstd --out "$out8"
	need non-packaged/lib/libblosc.so.1 develop/headers/blosc.h
}

# OpenVDB 10.1.0 (-8: voxel remesh, .vdb import, the volume nodes, the OpenVDB fluid cache; NanoVDB for
# Cycles' volumes): ours (tools/recipes; Blender pins 10.0.0, 10.1 is the same ABI 10), the core library
# shared with Blosc, zlib, delayed loading (Boost iostreams), oneTBB, OpenVDB's own half; NanoVDB's headers;
# vdb_print. Explicit instantiation makes compile jobs of 2-3 GB (8 jobs went over 14 GB): under
# heavy-build.sh, 5 jobs.
openvdb() {
	local recipe="$root/tools/recipes/media-gfx/openvdb/openvdb-10.1.0.recipe" w="$root/artifacts/cross-ports/openvdb-10.1.0"
	local lib n v
	"$root/scripts/heavy-build.sh" -j 5 --mem-per-job 3 --max 16 -- env CROSS_PORT_JOBS='{JOBS}' \
		"$cross" "$recipe" cmake -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DOPENVDB_BUILD_CORE=ON \
		-DOPENVDB_CORE_SHARED=ON -DOPENVDB_CORE_STATIC=OFF -DOPENVDB_BUILD_BINARIES=ON -DOPENVDB_BUILD_VDB_PRINT=ON \
		-DOPENVDB_BUILD_PYTHON_MODULE=OFF -DOPENVDB_BUILD_UNITTESTS=OFF -DOPENVDB_BUILD_DOCS=OFF \
		-DOPENVDB_BUILD_AX=OFF -DUSE_AX=OFF -DUSE_BLOSC=ON -DUSE_ZLIB=ON -DUSE_IMATH_HALF=OFF -DUSE_EXR=OFF \
		-DUSE_PNG=OFF -DUSE_LOG4CPLUS=OFF -DUSE_CCACHE=OFF -DOPENVDB_USE_DELAYED_LOADING=ON \
		-DUSE_NANOVDB=ON -DOPENVDB_BUILD_NANOVDB=ON -DNANOVDB_BUILD_TOOLS=OFF -DNANOVDB_BUILD_UNITTESTS=OFF \
		-DNANOVDB_BUILD_EXAMPLES=OFF -DNANOVDB_BUILD_BENCHMARK=OFF -DNANOVDB_USE_CUDA=OFF -DNANOVDB_USE_OPENVDB=ON \
		-DOPENVDB_ENABLE_RPATH=OFF -DCMAKE_SKIP_RPATH=ON -DDISABLE_DEPENDENCY_VERSION_CHECKS=OFF \
		-DTBB_ROOT="$np" -DBlosc_ROOT="$np" -DBoost_ROOT="$np" -DBoost_NO_SYSTEM_PATHS=ON \
		-DZLIB_ROOT="$sysroot/boot/system/develop" -DZLIB_INCLUDE_DIR="$sysroot/boot/system/develop/headers" \
		-DZLIB_LIBRARY="$sysroot/boot/system/develop/lib/libz.so" -Wno-dev
	lib="$w/install/boot/system/non-packaged/lib/libopenvdb.so.10.1.0"
	"$tools-readelf" -d "$lib" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' ' | sed 's/^/build-blender: libopenvdb needs: /'
	echo
	for n in libblosc libz libtbb libboost_iostreams; do
		"$tools-readelf" -d "$lib" | grep "NEEDED.*\[$n\.so" > /dev/null \
			|| { echo "build-blender: OpenVDB does not link $n" >&2; exit 1; }
	done
	! "$tools-readelf" -d "$lib" | grep -E 'RPATH|RUNPATH' > /dev/null || { echo "build-blender: OpenVDB has a run path" >&2; exit 1; }
	# the features in the installed version header (a configure that loses one only warns)
	v="$w/install/boot/system/non-packaged/include/openvdb/version.h"
	for n in OPENVDB_USE_BLOSC OPENVDB_USE_ZLIB OPENVDB_USE_DELAYED_LOADING; do
		grep -q "^#define $n" "$v" || { echo "build-blender: OpenVDB built without $n" >&2; exit 1; }
	done
	! grep -q '^#define OPENVDB_USE_IMATH_HALF' "$v" || { echo "build-blender: OpenVDB uses Imath's half" >&2; exit 1; }
	[ -f "$w/install/boot/system/non-packaged/include/nanovdb/NanoVDB.h" ] \
		|| { echo "build-blender: NanoVDB headers not installed" >&2; exit 1; }
	cmake_relative OpenVDB 2> /dev/null || true
	"$root/scripts/package-port.py" "$recipe" --out "$out8"
	need non-packaged/lib/libopenvdb.so.10.1 develop/headers/openvdb/openvdb.h develop/headers/nanovdb/NanoVDB.h
	rm -rf "$w/src" "$w/source" "$w/build"
}

# GMP 6.3.0 (-8: the Boolean modifier's Exact solver; without it Blender silently uses Fast): the recipe
# (autotools), libgmp + the C++ libgmpxx Blender links, the generic ARM64 assembly. Fetched from the GNU
# mirror (gmplib.org refused connections on 2026-11-20; same file, the recipe's sha256 checks it)
gmp() {
	local recipe lib="$root/artifacts/cross-ports/gmp-6.3.0/install/boot/system/non-packaged/lib"
	recipe="$(recipe_with "$ports/dev-libs/gmp/gmp-6.3.0.recipe" https://gmplib.org/download/gmp/ https://ftp.gnu.org/gnu/gmp/)"
	# The recipe's configure, built in script mode for one fix: libtool links C++ libraries with
	# -lstdc++ resolved through the cross tools' libstdc++.la, whose libstdc++.a does not exist (libtiffxx,
	# blender.md §7.3), so libgmpxx would not link; the generated libtool names the shared one (-l:libstdc++.so) instead.
	# C17: GCC 16 defaults to C23, which rejects the K&R-style tests of GMP's configure ("could not find a
	# working compiler").
	"$cross" "$recipe" script '
touch doc/*.info*
autoreconf -fi > autoreconf.log 2>&1
mkdir -p build && cd build
../configure --host=aarch64-unknown-haiku --prefix=/boot/system/non-packaged CC="$CC" CXX="$CXX" AR="$AR" \
	RANLIB="$RANLIB" STRIP="$STRIP" CFLAGS="-O2 -std=gnu17" --enable-cxx --disable-static
grep -q "^postdeps=\"-lstdc++ " libtool
sed -i "s|^postdeps=\"-lstdc++ |postdeps=\"-l:libstdc++.so |" libtool
make -j"$(nproc)"
make install DESTDIR="${DEST%/boot/system/non-packaged}"
find "$DEST" -name "*.la" -delete'
	rm -rf "$root/artifacts/cross-ports/gmp-6.3.0/install/boot/system/non-packaged/share"
	[ -f "$lib/libgmp.so.10.5.0" ] && [ -f "$lib/libgmpxx.so.4.7.0" ] \
		|| { ls -l "$lib" >&2; echo "build-blender: GMP built without libgmp/libgmpxx" >&2; exit 1; }
	"$tools-readelf" -d "$lib/libgmpxx.so.4.7.0" | grep 'NEEDED.*\[libgmp.so' > /dev/null \
		|| { echo "build-blender: libgmpxx does not link libgmp" >&2; exit 1; }
	"$root/scripts/package-port.py" "$recipe" --out "$out8"
	need non-packaged/lib/libgmp.so.10 non-packaged/lib/libgmpxx.so.4 develop/headers/gmp.h develop/headers/gmpxx.h
}

# potrace 1.16 (-8: Grease Pencil's Trace Image; Blender's pin): the recipe + patchset, libpotrace and the
# potrace/mkbitmap programs
potrace() {
	local recipe="$ports/media-gfx/potrace/potrace-1.16.recipe"
	"$cross" "$recipe" autotools --with-libpotrace --disable-static CFLAGS="-O2 -std=gnu17"
	rm -rf "$root/artifacts/cross-ports/potrace-1.16/install/boot/system/non-packaged/share"
	"$root/scripts/package-port.py" "$recipe" --out "$out8"
	need non-packaged/lib/libpotrace.so.0 develop/headers/potracelib.h
}

# libharu 2.4.3 (-8: Grease Pencil's PDF export; Blender 3.6 pins 2.3.0, its calls are in 2.4 unchanged):
# the recipe + patchset, shared, with libpng and zlib
libharu() {
	local recipe="$ports/media-libs/libharu/libharu-2.4.3.recipe" lib
	"$cross" "$recipe" cmake -DLIBHPDF_STATIC=NO -DBUILD_SHARED_LIBS=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -Wno-dev
	lib="$(ls "$root"/artifacts/cross-ports/libharu-2.4.3/install/boot/system/non-packaged/lib/libhpdf.so.* | head -n 1)"
	"$tools-readelf" -d "$lib" | grep 'NEEDED.*\[libpng16' > /dev/null \
		|| { echo "build-blender: libharu does not link libpng" >&2; exit 1; }
	rm -rf "$root/artifacts/cross-ports/libharu-2.4.3/install/boot/system/non-packaged/share"
	"$root/scripts/package-port.py" "$recipe" --requires lib:libpng16 --out "$out8"
	need develop/headers/hpdf.h develop/lib/libhpdf.so
}

# OpenUSD 24.08 (-9: File > Import/Export > Universal Scene Description; blender.md §7.16): ours
# (tools/recipes). Blender 3.6 pins 23.05, which needs the TBB 2020 API; 24.08 is the first release that
# builds with oneTBB (2022: the patchset backports OpenUSD PR #3392), and Blender 3.6's io/usd compiles
# against it unchanged. The patchset also ports the arch library to Haiku. One shared library, libusd_ms
# (PXR_BUILD_MONOLITHIC, the name Blender's FindUSD takes); usdImaging without GL (Blender's gprim reader
# meshes Cube/Sphere/... with its shape adapters, so imaging cannot be off); no Python (Blender 3.6's io/usd
# does not need it, and without it no Boost), no tools, tests, OpenVDB/OIIO/OCIO/MaterialX/Alembic/Draco
# plug-ins. The plug-in descriptions (lib/usd/<module>/resources/plugInfo.json: schemas, the usda/usdc/usdz
# file formats) are found at run time relative to libusd_ms (Plug_InitConfig, dladdr), so they go into the
# runtime package as lib/usd. Compile jobs up to ~1.5 GB: heavy-build.sh.
usd() {
	local recipe="$root/tools/recipes/media-gfx/usd/usd-24.08.recipe" w="$root/artifacts/cross-ports/usd-24.08"
	local inst lib n j rel
	"$root/scripts/heavy-build.sh" -j 8 --mem-per-job 3 --max 20 -- env CROSS_PORT_JOBS='{JOBS}' \
		"$cross" "$recipe" cmake -DPXR_ENABLE_PYTHON_SUPPORT=OFF -DPXR_BUILD_IMAGING=ON -DPXR_BUILD_USD_IMAGING=ON \
		-DPXR_ENABLE_GL_SUPPORT=OFF -DPXR_ENABLE_VULKAN_SUPPORT=OFF -DPXR_ENABLE_METAL_SUPPORT=OFF \
		-DPXR_BUILD_TESTS=OFF -DPXR_BUILD_EXAMPLES=OFF -DPXR_BUILD_TUTORIALS=OFF -DPXR_BUILD_USD_TOOLS=OFF \
		-DPXR_BUILD_USDVIEW=OFF -DPXR_BUILD_DOCUMENTATION=OFF -DPXR_ENABLE_PTEX_SUPPORT=OFF \
		-DPXR_ENABLE_OPENVDB_SUPPORT=OFF -DPXR_ENABLE_OSL_SUPPORT=OFF -DPXR_ENABLE_HDF5_SUPPORT=OFF \
		-DPXR_ENABLE_MATERIALX_SUPPORT=OFF -DPXR_BUILD_OPENIMAGEIO_PLUGIN=OFF -DPXR_BUILD_OPENCOLORIO_PLUGIN=OFF \
		-DPXR_BUILD_EMBREE_PLUGIN=OFF -DPXR_BUILD_PRMAN_PLUGIN=OFF -DPXR_BUILD_ALEMBIC_PLUGIN=OFF \
		-DPXR_BUILD_DRACO_PLUGIN=OFF -DPXR_BUILD_MONOLITHIC=ON -DBUILD_SHARED_LIBS=ON \
		-DPXR_ENABLE_PRECOMPILED_HEADERS=OFF -DCMAKE_SKIP_RPATH=ON -DTBB_ROOT_DIR="$np" -DOPENSUBDIV_ROOT_DIR="$np" \
		-Wno-dev
	grep -q 'Found TBB: .*(found version "2022\.3")' "$w/configure.log" \
		|| { grep -i tbb "$w/configure.log" >&2; echo "build-blender: USD did not find the sysroot's oneTBB 2022.3" >&2; exit 1; }
	inst="$w/install/boot/system/non-packaged"
	lib="$inst/lib/libusd_ms.so"
	# The monolithic build puts three plug-ins (usdShaders, sdrGlslfx, hioAvif: compiled into libusd_ms,
	# "LibraryPath": "") into <prefix>/plugin/usd, which USD searches as lib/../plugin/usd: moved into lib/usd
	# (whose plugInfo.json includes */resources/), so that the package has no top-level plugin/ directory.
	# pxrConfig.cmake and cmake/pxrTargets*.cmake name this host's sysroot: dropped (Blender's FindUSD does not
	# use them). Both in the work tree and in the sysroot, where cross-port.sh copied the install tree.
	for d in "$inst/plugin/usd"/*/; do
		mv "$d" "$inst/lib/usd/"
		rm -rf "$np/plugin/usd/$(basename "$d")"
		cp -a "$inst/lib/usd/$(basename "$d")" "$np/lib/usd/"
	done
	rm -rf "$inst/plugin" "$inst/pxrConfig.cmake" "$inst/cmake" "$np/plugin" "$np/pxrConfig.cmake" "$np/cmake"
	"$tools-readelf" -d "$lib" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' ' | sed 's/^/build-blender: libusd_ms needs: /'
	echo
	for n in libtbb.so.12 libosdCPU.so.3.5.0; do
		"$tools-readelf" -d "$lib" | grep "NEEDED.*\[$n\]" > /dev/null || { echo "build-blender: USD does not link $n" >&2; exit 1; }
	done
	! "$tools-readelf" -d "$lib" | grep -E 'RPATH|RUNPATH|NEEDED.*\[lib(GL|EGL|python|boost)' > /dev/null \
		|| { echo "build-blender: USD has a run path or links GL/Python/Boost" >&2; exit 1; }
	# ArchGetAddressInfo() through dladdr() (Haiku has no _GNU_SOURCE; without it Plug cannot find lib/usd
	# beside the library and every USD file operation fails: "Failed to find plugin for ArDefaultResolver")
	"$tools-readelf" --dyn-syms -W "$lib" | grep -E ' UND dladdr$' > /dev/null \
		|| { echo "build-blender: libusd_ms does not use dladdr (ArchGetAddressInfo)" >&2; exit 1; }
	# no Python support (Blender's FindUSD turns USD_PYTHON_SUPPORT on when pyModule.h exists)
	[ ! -e "$inst/include/pxr/base/tf/pyModule.h" ] \
		&& grep -B1 '^#define PXR_PYTHON_SUPPORT_ENABLED' "$inst/include/pxr/pxr.h" | grep -q '^#if 0$' \
		|| { echo "build-blender: USD built with Python support" >&2; exit 1; }
	grep -q '^#define PXR_VERSION 2408$' "$inst/include/pxr/pxr.h" || { echo "build-blender: not USD 24.08" >&2; exit 1; }
	[ -f "$inst/include/pxr/usdImaging/usdImaging/capsuleAdapter.h" ] \
		|| { echo "build-blender: USD built without usdImaging" >&2; exit 1; }
	# the plug-in descriptions Blender needs at run time, each pointing at libusd_ms
	for n in usd/plugInfo.json usd/sdf/resources/plugInfo.json usd/usd/resources/plugInfo.json \
			usd/usdGeom/resources/plugInfo.json usd/usdGeom/resources/generatedSchema.usda \
			usd/usdShade/resources/plugInfo.json usd/usdLux/resources/plugInfo.json \
			usd/usdSkel/resources/plugInfo.json usd/usdVol/resources/plugInfo.json \
			usd/usdImaging/resources/plugInfo.json usd/ar/resources/plugInfo.json \
			usd/usdShaders/resources/plugInfo.json; do
		[ -f "$inst/lib/$n" ] || { echo "build-blender: USD's lib/$n missing" >&2; exit 1; }
	done
	# (the plug-ins: */resources/plugInfo.json, as lib/usd/plugInfo.json includes them; usd/resources/
	# codegenTemplates/ holds usdGenSchema's templates, not a plug-in)
	for j in "$inst"/lib/usd/*/resources/plugInfo.json; do
		rel="$(sed -n 's/.*"LibraryPath": *"\([^"]*\)".*/\1/p' "$j" | head -n 1)"
		[ -z "$rel" ] || [ "$(realpath -m "$(dirname "$j")/$rel")" = "$(realpath "$lib")" ] \
			|| { echo "build-blender: $j: LibraryPath $rel is not libusd_ms" >&2; exit 1; }
	done
	"$root/scripts/package-port.py" "$recipe" --lib-tree usd --out "$out9"
	need non-packaged/lib/libusd_ms.so non-packaged/lib/usd/plugInfo.json develop/headers/pxr/usd/usd/api.h
	rm -rf "$w/src" "$w/source" "$w/build"
}

# --- Blender itself: artifacts/cross-ports/blender-3.6.23/ (kept between runs: src/ is only made
# when missing; rm -rf it to start over) ---
bl="$root/artifacts/cross-ports/blender-3.6.23"
blDeps="$bl/deps"
options="$root/tools/cmake/blender-minimal.cmake"
pyHost="$root/artifacts/python-host-3.10"
# numpy_python3.10 in the sysroot (the numpy step): its headers for audaspace's Python API; the host
# configure is pointed at the same tree (the generators do not use NumPy, the options must agree)
numpyPath="$sysroot/boot/system/lib/python3.10/vendor-packages"

# FreeType 2.14.3 with Brotli, static, Blender's own (as build-stk.sh's): Blender stops at configure
# without Brotli (WOFF2 fonts), the sysroot's has none, and a newer libfreetype.so.6 in the image would
# replace app_server's for every program
freetype() {
	local recipe="$ports/media-libs/freetype/freetype-2.14.3.recipe" archive src="$bl/deps-src/freetype"
	archive="$("$root/scripts/haikuports-fetch.sh" "$recipe" \
		| sed -n 's/^haikuports-fetch: \(.*\) ([0-9]* bytes, sha256 ok)$/\1/p' | head -n 1)"
	rm -rf "$src" "$bl/deps-build/freetype"
	mkdir -p "$src" "$bl/deps-build"
	tar -xf "$archive" -C "$src" --strip-components=1
	cmake -S "$src" -B "$bl/deps-build/freetype" -G Ninja -DCMAKE_TOOLCHAIN_FILE="$root/tools/cmake/haiku-arm64.cmake" \
		-DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$blDeps" -DBUILD_SHARED_LIBS=OFF \
		-DCMAKE_POSITION_INDEPENDENT_CODE=ON -DFT_REQUIRE_PNG=ON -DFT_REQUIRE_ZLIB=ON \
		-DFT_REQUIRE_BROTLI=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_HARFBUZZ=ON \
		> "$bl/deps-build/freetype.configure.log" 2>&1 || { tail -n 30 "$bl/deps-build/freetype.configure.log" >&2; exit 1; }
	ninja -C "$bl/deps-build/freetype" install > "$bl/deps-build/freetype.build.log" 2>&1 \
		|| { tail -n 30 "$bl/deps-build/freetype.build.log" >&2; exit 1; }
	grep -q '^#define FT_CONFIG_OPTION_USE_BROTLI' "$blDeps/include/freetype2/freetype/config/ftoption.h" \
		|| { echo "build-blender: FreeType built without Brotli" >&2; exit 1; }
}

# the patched source tree: the 3.6.23 release (artifacts/downloads/blender) + patches/blender/*.patch
blender_source() {
	local p
	[ -d "$bl/src" ] && { echo "build-blender: $bl/src exists, kept"; return; }
	mkdir -p "$bl"
	cp -a "$root/artifacts/downloads/blender/blender-3.6.23" "$bl/src.tmp"
	for p in "$root"/patches/blender/*.patch; do
		echo "build-blender: applying $(basename "$p")"
		patch -s -p1 -d "$bl/src.tmp" < "$p"
	done
	mv "$bl/src.tmp" "$bl/src"
}

# the libraries -8 adds (and -9's USD), for both configures (the host one only finds them so that the options stay on):
# OpenVDB + NanoVDB + Blosc, GMP, potrace, libharu, Boost 1.83 (its CMake config, not CMake's removed
# FindBoost; Boost_NO_SYSTEM_PATHS: never the host's own Boost)
roots8() {
	echo -DOPENVDB_ROOT_DIR="$np" -DNANOVDB_ROOT_DIR="$np" -DBLOSC_ROOT_DIR="$np" -DGMP_ROOT_DIR="$np" \
		-DPOTRACE_ROOT_DIR="$np" -DHARU_ROOT_DIR="$np" -DBoost_ROOT="$np" -DBOOST_ROOT="$np" \
		-DBoost_NO_SYSTEM_PATHS=ON -DBoost_DIR="$np/lib/cmake/Boost-1.83.0" -DUSD_ROOT_DIR="$np"
}

# the WITH_* values a configured build ended with
with_options() {
	grep -E '^WITH_[A-Z0-9_]+:BOOL=' "$1/CMakeCache.txt" | sort
}

# the -DWITH_* defines one object of a build.ninja is compiled with
#   object_defines BUILD_NINJA OBJECT_PATTERN
object_defines() {
	awk -v pat="$2" '$0 ~ "^build " && $0 ~ pat {f=1; next} f && /^  DEFINES = / {print; exit}' "$1" \
		| tr ' ' '\n' | grep '^-DWITH_' | sort -u
}

# the generators for the host (blender.md §4.2): the same tree and options file, the host compiler; the
# libraries the host lacks (OpenImageIO, OpenEXR, TBB, WebP headers) are found in the sysroot only so
# that configure keeps their options on (no generator links them), Python is the host 3.10
# build-python.sh made
hosttools() {
	local dl="$sysroot/boot/system/develop/lib"
	local t
	rm -rf "$bl/host-build" "$bl/host-tools"
	cmake -S "$bl/src" -B "$bl/host-build" -G Ninja -C "$options" -DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
		-DPYTHON_INCLUDE_DIR="$pyHost/include/python3.10" -DPYTHON_INCLUDE_CONFIG_DIR="$pyHost/include/python3.10" \
		-DPYTHON_LIBRARY="$pyHost/lib/libpython3.10.a" -DPYTHON_LIBPATH="$pyHost/lib" \
		-DOPENIMAGEIO_ROOT_DIR="$np" -DOPENEXR_ROOT_DIR="$np" -DTBB_ROOT_DIR="$np" -DPUGIXML_ROOT_DIR="$np" \
		-DOPENCOLORIO_ROOT_DIR="$np" -DOPENSUBDIV_ROOT_DIR="$np" -DFFMPEG_ROOT_DIR="$np" \
		-DOPENIMAGEDENOISE_ROOT_DIR="$np" -DALEMBIC_ROOT_DIR="$np" -DFFTW3_ROOT_DIR="$np" \
		$(roots8) \
		-DPYTHON_NUMPY_PATH="$numpyPath" \
		-DPYTHON_NUMPY_INCLUDE_DIRS="$numpyPath/numpy/core/include" \
		-DTEST_PYTHON_EXE="$(command -v python3)" \
		-DWEBP_INCLUDE_DIR="$sysroot/boot/system/develop/headers" -DWEBP_WEBP_LIBRARY="$dl/libwebp.so" \
		-DWEBP_WEBPMUX_LIBRARY="$dl/libwebpmux.so" -DWEBP_WEBPDEMUX_LIBRARY="$dl/libwebpdemux.so" \
		> "$bl/host-configure.log" 2>&1 || { tail -n 40 "$bl/host-configure.log" >&2; exit 1; }
	ninja -C "$bl/host-build" makesdna makesrna datatoc datatoc_icon smaa_areatex > "$bl/host-build.log" 2>&1 \
		|| { grep -A10 FAILED "$bl/host-build.log" | head -n 40 >&2; exit 1; }
	# msgfmt (-8: translations, .po -> .mo at build time) links bf_blenlib, whose link line names the
	# target's libraries the host configure found in the sysroot (TBB, GMP: wrong format); the objects
	# it uses need none of them, so it is linked with that line minus the sysroot's libraries. Its
	# German .mo was checked byte-identical to the official x86-64 3.6.23 release's (2026-11-20).
	ninja -C "$bl/host-build" -k 0 bin/msgfmt >> "$bl/host-build.log" 2>&1 || true
	(cd "$bl/host-build" && bash -c "$(ninja -t commands bin/msgfmt | tail -n 1 \
		| sed -E "s# $sysroot/[^ ]*\.so##g")") >> "$bl/host-build.log" 2>&1 \
		|| { tail -n 20 "$bl/host-build.log" >&2; exit 1; }
	file "$bl/host-build/bin/msgfmt" | grep -q 'x86-64' || { echo "build-blender: no host msgfmt" >&2; exit 1; }
	mkdir -p "$bl/host-tools"
	for t in makesdna makesrna datatoc datatoc_icon smaa_areatex msgfmt; do
		cp "$bl/host-build/bin/$t" "$bl/host-tools/"
	done
	file "$bl/host-tools"/* | sed 's/^/build-blender: /'
}

# the cross configure: the toolchain file, the options file, the generators from hosttools
# (TEST_PYTHON_EXE: with FFmpeg the tests' configure wants a Python; the tests are not run here)
configure() {
	local diff
	# (BLENDER_CLEAN=1: from an empty build directory; otherwise CMake reconfigures the one there and
	# ninja rebuilds only what changed)
	[ "${BLENDER_CLEAN:-0}" = 1 ] && rm -rf "$bl/build"
	# -lgcc_s: the cross g++ links programs with the static libgcc only, and then C++ exceptions end in
	# terminate() (build-stk.sh). FreeType is static: its users link what it needs.
	cmake -S "$bl/src" -B "$bl/build" -G Ninja -C "$options" -DCMAKE_TOOLCHAIN_FILE="$root/tools/cmake/haiku-arm64.cmake" \
		-DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_SKIP_RPATH=ON \
		-DBLENDER_HOST_TOOLS="$bl/host-tools" \
		-DCMAKE_CXX_STANDARD_LIBRARIES="-Wl,--no-as-needed -lgcc_s" \
		-DPYTHON_INCLUDE_DIR="$sysroot/boot/system/develop/headers/python3.10" \
		-DPYTHON_INCLUDE_CONFIG_DIR="$sysroot/boot/system/develop/headers/python3.10" \
		-DPYTHON_LIBRARY="$sysroot/boot/system/develop/lib/libpython3.10.so" \
		-DPYTHON_LIBPATH="$sysroot/boot/system/develop/lib" \
		-DOPENIMAGEIO_ROOT_DIR="$np" -DOPENEXR_ROOT_DIR="$np" -DTBB_ROOT_DIR="$np" -DSSE2NEON_ROOT_DIR="$np" \
		-DPUGIXML_ROOT_DIR="$np" -DOPENCOLORIO_ROOT_DIR="$np" -DOPENSUBDIV_ROOT_DIR="$np" \
		-DFFMPEG_ROOT_DIR="$np" -DOPENIMAGEDENOISE_ROOT_DIR="$np" -DALEMBIC_ROOT_DIR="$np" -DFFTW3_ROOT_DIR="$np" \
		$(roots8) \
		-DPYTHON_NUMPY_PATH="$numpyPath" \
		-DPYTHON_NUMPY_INCLUDE_DIRS="$numpyPath/numpy/core/include" \
		-DTEST_PYTHON_EXE="$(command -v python3)" \
		-DFREETYPE_INCLUDE_DIR_ft2build="$blDeps/include/freetype2" \
		-DFREETYPE_INCLUDE_DIR_freetype2="$blDeps/include/freetype2" \
		-DFREETYPE_LIBRARY="$blDeps/lib/libfreetype.a;brotlidec;brotlicommon;png16;z" \
		> "$bl/configure.log" 2>&1 || { tail -n 40 "$bl/configure.log" >&2; exit 1; }
	# the generators' output depends on the options: host and target must agree
	diff="$(diff <(with_options "$bl/host-build") <(with_options "$bl/build") || true)"
	if [ -n "$diff" ]; then
		echo "build-blender: host and cross configures differ in WITH_* options:" >&2
		echo "$diff" >&2
		exit 1
	fi
	# what the generators were really compiled with (an option a configure turns off is only a normal
	# variable, not in the cache): makesrna's sources on the host against the same sources compiled into
	# bf_rna for the target (WITH_SSE2NEON: global, the cross build's only, unused by RNA/DNA)
	diff="$(diff <(object_defines "$bl/host-build/build.ninja" 'makesrna.dir/rna_scene.c.o') \
		<(object_defines "$bl/build/build.ninja" 'bf_rna.dir/rna_scene_gen.c.o' | grep -v '^-DWITH_SSE2NEON$') || true)"
	if [ -n "$diff" ] || [ -z "$(object_defines "$bl/host-build/build.ninja" 'makesrna.dir/rna_scene.c.o')" ]; then
		echo "build-blender: makesrna (host) and bf_rna (target) are compiled with different WITH_* defines:" >&2
		echo "$diff" >&2
		exit 1
	fi
	# what the minimal build is for, still on after configure
	for o in WITH_GHOST_SDL WITH_PYTHON WITH_TBB WITH_CYCLES WITH_IMAGE_OPENEXR WITH_IMAGE_WEBP WITH_PUGIXML \
			WITH_OPENCOLORIO WITH_OPENSUBDIV WITH_CODEC_FFMPEG WITH_AUDASPACE WITH_OPENIMAGEDENOISE \
			WITH_PYTHON_NUMPY WITH_ALEMBIC WITH_FFTW3 WITH_MOD_OCEANSIM WITH_MOD_FLUID WITH_BOOST WITH_OPENVDB \
			WITH_OPENVDB_BLOSC WITH_NANOVDB WITH_GMP WITH_POTRACE WITH_HARU WITH_INTERNATIONAL WITH_QUADRIFLOW \
			WITH_DRACO WITH_USD; do
		grep -q "^$o:BOOL=ON" "$bl/build/CMakeCache.txt" || { echo "build-blender: $o is off" >&2; exit 1; }
	done
	# -8: what set_and_warn_dependency or a find module could still turn off with a normal variable (the
	# cache keeps ON): the defines the sources get (WITH_DRACO: extern_draco is built; WITH_INTERNATIONAL:
	# the locale files are made)
	for o in WITH_OPENVDB WITH_OPENVDB_BLOSC WITH_NANOVDB WITH_GMP WITH_POTRACE WITH_HARU WITH_INTERNATIONAL \
			WITH_QUADRIFLOW WITH_USD; do
		grep -q -- "-D$o\b" "$bl/build/build.ninja" || { echo "build-blender: nothing is compiled with -D$o" >&2; exit 1; }
	done
	grep -q 'libextern_draco.so' "$bl/build/build.ninja" || { echo "build-blender: no extern_draco target" >&2; exit 1; }
	grep -q '^SSE2NEON_INCLUDE_DIR:PATH=/' "$bl/build/CMakeCache.txt" \
		|| { echo "build-blender: sse2neon not found (Cycles would build without SIMD)" >&2; exit 1; }
	grep -q -- '-DWITH_SSE2NEON' "$bl/build/build.ninja" \
		|| { echo "build-blender: not built WITH_SSE2NEON" >&2; exit 1; }
}

# ninja under the heavy-build guard: ~0.6-1 GB per compile job (Cycles kernels), more where OpenVDB's
# headers come in (-8), 5 jobs at most 16 GB; every target (stage installs them all)
build() {
	"$root/scripts/heavy-build.sh" -j 5 --mem-per-job 3 --max 16 -- ninja -C "$bl/build" -k 0 -j '{JOBS}' \
		> "$bl/build.log" 2>&1 || { grep -a -A12 'FAILED:' "$bl/build.log" | head -n 80 >&2; exit 1; }
	echo "build-blender: compiler warnings: $(grep -c 'warning:' "$bl/build.log" || true)"
	"$tools-readelf" -h -d "$bl/build/bin/blender" | grep -E 'Machine|NEEDED' | sed 's/^/build-blender: /'
	ls -l "$bl/build/bin/blender"
	# -7: OIDN linked, audaspace's Python module (PyInit_aud, only built with NumPy) in
	"$tools-readelf" -d "$bl/build/bin/blender" | grep 'NEEDED.*\[libOpenImageDenoise.so.2\]' > /dev/null \
		|| { echo "build-blender: blender does not link OpenImageDenoise" >&2; exit 1; }
	"$tools-nm" "$bl/build/bin/blender" | grep ' T PyInit_aud$' > /dev/null \
		|| { echo "build-blender: blender has no aud module (PyInit_aud)" >&2; exit 1; }
	for n in libAlembic.so.1.8 libfftw3.so.3 libopenvdb.so.10.1 libgmp.so.10 libgmpxx.so.4 libpotrace.so.0 \
			libhpdf.so.2.4.3 libboost_locale.so.1.83.0 libusd_ms.so; do
		"$tools-readelf" -d "$bl/build/bin/blender" | grep "NEEDED.*\[$n\]" > /dev/null \
			|| { echo "build-blender: blender does not link $n" >&2; exit 1; }
	done
}

# the package (M6): blender + its 3.6/ tree in apps/Blender (Blender's portable layout; the program is
# "Blender" there) and a Deskbar entry. package-port.py turns the NEEDED libraries of our ports
# (non-packaged/ in the sysroot) into requires; the ones from packages extracted into the sysroot's lib/
# (python3.10, zstd, brotli, webp, libpng, libjpeg) are named, and SDL2 at least 2.32.10-8 (per-thread GL
# contexts, docs/design/blender.md §3.2: render jobs and shader compiles make contexts current on other threads)
blender_package() {
	local recipe="$root/tools/recipes/media-gfx/blender/blender-3.6.23.recipe" sys="$bl/install/boot/system" r
	rm -rf "$bl/install"
	cmake --install "$bl/build" --prefix "$sys/apps/Blender" > "$bl/install.log" 2>&1 \
		|| { tail -n 20 "$bl/install.log" >&2; exit 1; }
	mv "$sys/apps/Blender/blender" "$sys/apps/Blender/Blender"
	# the app's resources (HaikuPorts' blender3 rdef: vector icon, signature application/x-vnd.blender,
	# version): stripped first, as package-port.py does not strip a program with resources (strip would drop them)
	"$tools-strip" "$sys/apps/Blender/Blender"
	sed -e 's/@MAJOR@/3/; s/@MIDDLE@/6/; s/@MINOR@/23/' \
		"$root/tools/recipes/media-gfx/blender/additional-files/blender.rdef.in" > "$bl/blender.rdef"
	LD_LIBRARY_PATH="$gen/objects/linux/lib" "$hostTools/rc/rc" -o "$bl/blender.rsrc" "$bl/blender.rdef"
	LD_LIBRARY_PATH="$gen/objects/linux/lib" "$hostTools/xres" -o "$sys/apps/Blender/Blender" "$bl/blender.rsrc"
	rm -f "$sys/apps/Blender"/blender.desktop "$sys/apps/Blender"/*.svg
	mkdir -p "$sys/data/deskbar/menu/Applications"
	ln -s ../../../../apps/Blender/Blender "$sys/data/deskbar/menu/Applications/Blender"
	r=()
	for lib in libpython3.10 libzstd libbrotlidec libbrotlicommon libwebp libwebpmux libwebpdemux libpng16 \
			libjpeg libexpat; do
		r+=(--requires "lib:$lib")
	done
	# revision 2: EEVEE on 4 color attachments (patches/blender/0007); 3: the app icon; 4: the viewport's depth
	# copy as a GPU blit on V3D (0008); 5: video (FFmpeg), audio (audaspace on SDL), Unicode text input (0009);
	# 6: a bit rate from the quality setting for encoders without CRF, e.g. h264_mmal (0010); 7: denoising
	# (OpenImageDenoise 2.5: 0011 instead of 0006, Balanced quality 0012), the aud module (NumPy:
	# numpy_python3.10, a run-time requirement that no NEEDED entry shows: `import aud` imports numpy),
	# Alembic, the Ocean modifier (FFTW), fluid simulation (Mantaflow), and Cycles' Rendered viewport
	# (GL contexts shared with the first one, 0013); 8: OpenVDB 10.1 + NanoVDB (voxel remesh, .vdb import, volume
	# nodes and Cycles volumes, the OpenVDB fluid cache), GMP (the Exact Boolean solver), Quadriflow, Draco
	# (glTF compression, 0014: libextern_draco.so in 3.6/lib), potrace, libharu, translations (Boost.Locale:
	# boost1.83 -2, which also has regex and iostreams); 9: USD import/export (usd 24.08, 0015)
	[ -f "$sys/apps/Blender/3.6/lib/libextern_draco.so" ] || { echo "build-blender: no libextern_draco.so" >&2; exit 1; }
	[ ! -e "$sys/apps/Blender/3.6/python" ] \
		|| { echo "build-blender: 3.6/python exists (Blender would take it as its Python home)" >&2; exit 1; }
	[ -f "$sys/apps/Blender/3.6/datafiles/locale/de/LC_MESSAGES/blender.mo" ] \
		|| { echo "build-blender: no translations in 3.6/datafiles/locale" >&2; exit 1; }
	# (no 3.6/datafiles/usd: USD finds its plug-ins beside libusd_ms, in the usd package)
	[ ! -e "$sys/apps/Blender/3.6/datafiles/usd" ] || { echo "build-blender: 3.6/datafiles/usd installed" >&2; exit 1; }
	"$root/scripts/package-port.py" "$recipe" --revision 9 --system-prefix --no-devel --provides app:Blender \
		--requires "libsdl2 >= 2.32.10-8" --requires python3.10 --requires numpy_python3.10 \
		--requires "boost1.83 >= 1.83.0-2" "${r[@]}" --out "$out9"
	"$pkgtool" list -i "$out9/blender-3.6.23-9-arm64.hpkg" | grep -E 'requires|provides' | sed 's/^/build-blender: /'
}

# the install tree for the Pi test (M3): artifacts/blender-tests/Blender/ (blender, stripped, and its
# 3.6/{scripts,datafiles}, WITH_INSTALL_PORTABLE's layout; Python's standard library comes from the
# python3.10 package), the test packages beside it in artifacts/blender-tests/packages/
stage() {
	local t="$root/artifacts/blender-tests" p
	# (only what this step makes: m3/ and other results of Pi runs stay)
	rm -rf "$t/Blender" "$t/packages"
	cmake --install "$bl/build" --prefix "$t/Blender" --strip > "$bl/install.log" 2>&1 \
		|| { tail -n 20 "$bl/install.log" >&2; exit 1; }
	rm -f "$t/Blender"/blender.desktop "$t/Blender"/*.svg
	[ -x "$t/Blender/blender" ] && [ -d "$t/Blender/3.6/scripts" ] && [ -d "$t/Blender/3.6/datafiles" ] \
		|| { echo "build-blender: incomplete install tree $t/Blender" >&2; exit 1; }
	mkdir -p "$t/packages"
	cp "$out"/*.hpkg "$root"/artifacts/packages-test/libsdl2-8/libsdl2-2.32.10-8-arm64.hpkg "$t/packages/"
	# -7/-8/-9: blender itself (blender_package runs first) from blender-9/, its libraries from blender-7/,
	# blender-8/ and blender-9/, not the earlier revisions of blender/ (blender, boost1.83 -1: pkgman would
	# get two versions of one package)
	cp "$out7"/*.hpkg "$out8"/*.hpkg "$out9"/*.hpkg "$t/packages/"
	rm -f "$t/packages"/blender-3.6.23-[1-8]-*.hpkg "$t/packages"/boost1.83*-1.83.0-1-*.hpkg
	# and the run-time libraries of ours an image may not have yet (pkgman skips those it has)
	# (python3.10's modules link openssl, sqlite, bz2, libedit, expat, which package-port.py does not
	# turn into requires: they are in the sysroot's lib/, not non-packaged/)
	for p in zstd brotli libwebp libjpeg_turbo libpng16 openssl3 sqlite bzip2 libedit lz4 libiconv; do
		cp "$(newest "$root/artifacts/packages" "$p")" "$t/packages/"
	done
	cp "$gen/download/libffi-3.4.6_bootstrap-1-arm64.hpkg" "$gen/download/expat-2.5.0_bootstrap-1-arm64.hpkg" \
		"$t/packages/"
	rm -f "$t/packages"/*_devel-*.hpkg
	echo "build-blender: $t: $(du -sh "$t/Blender" | cut -f1) Blender, $(ls "$t/packages" | wc -l) packages"
}

steps=(sysroot python libdeflate imath openexr tiff epoxy boost tbb oiio pugixml yaml_cpp pystring
	minizip_ng opencolorio opensubdiv sse2neon oidn numpy alembic fftw blosc openvdb gmp potrace libharu usd freetype blender_source
	hosttools configure build blender_package stage)
start="${1:-${steps[0]}}" last="${2:-}"
started=0
for s in "${steps[@]}"; do
	[ "$s" = "$start" ] && started=1
	[ "$started" = 1 ] || continue
	echo "build-blender: === $s ($(date +%H:%M:%S))"
	"$s"
	[ "$s" != "$last" ] || break
done
[ "$started" = 1 ] || { echo "build-blender: no step $start (${steps[*]})" >&2; exit 2; }
