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
#   freetype     FreeType with Brotli, static, into Blender's own deps/ (not packaged)
#   blender_source  artifacts/downloads/blender/blender-3.6.23 + patches/blender/*.patch
#   hosttools    makesdna, makesrna, datatoc, datatoc_icon, smaa_areatex built for this host
#   configure    the cross configure (tools/cmake/haiku-arm64.cmake + tools/cmake/blender-minimal.cmake,
#                -DBLENDER_HOST_TOOLS); fails unless its WITH_* options equal the host configure's
#   build        ninja blender, under scripts/heavy-build.sh (≤ 12 GB)
#   stage        the install tree + runtime packages for the Pi test, artifacts/blender-tests/
#   blender_package  blender-3.6.23-1-arm64.hpkg (apps/Blender, Deskbar entry) in artifacts/packages-test/blender
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
tools="$gen/cross-tools-arm64/bin/aarch64-unknown-haiku"
out="$root/artifacts/packages-test/blender"
package() { "$root/scripts/package-port.py" "$@" --out "$out"; }
mkdir -p "$out"

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
			libedit_devel libpng16 libpng16_devel libjpeg_turbo libjpeg_turbo_devel libiconv libiconv_devel; do
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
		develop/lib/libGL.so develop/lib/libEGL.so lib/libiconv.so.2
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

# Boost 1.83 (the version HaikuPorts' blender3 builds against; Blender 3.6 pins 1.80): only what OIIO
# 2.4 links (thread; filesystem is std::filesystem with GCC >= 9) and what thread needs, shared, as the
# recipe's b2 options. b2 has no cross mode of its own: the engine is built for the host
# (bootstrap.sh), the cross g++ is a "gcc-haiku" toolset in a user-config.jam, target-os=haiku.
boost() {
	local recipe
	recipe="$(recipe_with "$ports/dev-libs/boost/boost1.83-1.83.0.recipe" '${portVersion%.*}' 1.83)"
	"$cross" "$recipe" script '
./bootstrap.sh --with-toolset=gcc --without-icu > bootstrap.log 2>&1 || { cat bootstrap.log; exit 1; }
cxx="${CXX%% *}"
echo "using gcc : haiku : $cxx : <compileflags>--sysroot=$SYSROOT <linkflags>--sysroot=$SYSROOT <archiver>$AR <ranlib>$RANLIB ;" > user-config.jam
./b2 -q -j"$(nproc)" --user-config=user-config.jam toolset=gcc-haiku target-os=haiku \
	architecture=arm address-model=64 binary-format=elf abi=aapcs \
	--with-thread --with-chrono --with-atomic --with-date_time --with-system --with-filesystem \
	--disable-icu boost.locale.icu=off pch=off inlining=on threading=multi variant=release \
	link=shared runtime-link=shared --prefix="$DEST" --libdir="$DEST/lib" --includedir="$DEST/include" \
	--layout=system install'
	package "$recipe"
	need non-packaged/lib/libboost_thread.so.1.83.0 develop/headers/boost/thread.hpp
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
		"$tools-readelf" -d "$lib" | grep -q "NEEDED.*\[$n" || { echo "build-blender: OIIO does not link $n" >&2; exit 1; }
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
		"$tools-readelf" -d "$lib" | grep -q "NEEDED.*\[$n" || { echo "build-blender: OCIO does not link $n" >&2; exit 1; }
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

# --- Blender itself: artifacts/cross-ports/blender-3.6.23/ (kept between runs: src/ is only made
# when missing; rm -rf it to start over) ---
bl="$root/artifacts/cross-ports/blender-3.6.23"
blDeps="$bl/deps"
options="$root/tools/cmake/blender-minimal.cmake"
pyHost="$root/artifacts/python-host-3.10"

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
		-DOPENCOLORIO_ROOT_DIR="$np" -DOPENSUBDIV_ROOT_DIR="$np" \
		-DWEBP_INCLUDE_DIR="$sysroot/boot/system/develop/headers" -DWEBP_WEBP_LIBRARY="$dl/libwebp.so" \
		-DWEBP_WEBPMUX_LIBRARY="$dl/libwebpmux.so" -DWEBP_WEBPDEMUX_LIBRARY="$dl/libwebpdemux.so" \
		> "$bl/host-configure.log" 2>&1 || { tail -n 40 "$bl/host-configure.log" >&2; exit 1; }
	ninja -C "$bl/host-build" makesdna makesrna datatoc datatoc_icon smaa_areatex > "$bl/host-build.log" 2>&1 \
		|| { grep -A10 FAILED "$bl/host-build.log" | head -n 40 >&2; exit 1; }
	mkdir -p "$bl/host-tools"
	for t in makesdna makesrna datatoc datatoc_icon smaa_areatex; do
		cp "$bl/host-build/bin/$t" "$bl/host-tools/"
	done
	file "$bl/host-tools"/* | sed 's/^/build-blender: /'
}

# the cross configure: the toolchain file, the options file, the generators from hosttools
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
			WITH_OPENCOLORIO WITH_OPENSUBDIV; do
		grep -q "^$o:BOOL=ON" "$bl/build/CMakeCache.txt" || { echo "build-blender: $o is off" >&2; exit 1; }
	done
	grep -q '^SSE2NEON_INCLUDE_DIR:PATH=/' "$bl/build/CMakeCache.txt" \
		|| { echo "build-blender: sse2neon not found (Cycles would build without SIMD)" >&2; exit 1; }
	grep -q -- '-DWITH_SSE2NEON' "$bl/build/build.ninja" \
		|| { echo "build-blender: not built WITH_SSE2NEON" >&2; exit 1; }
}

# ninja under the heavy-build guard: ~0.6-1 GB per compile job (Cycles kernels), at most 12 GB; every
# target (stage installs them all)
build() {
	"$root/scripts/heavy-build.sh" -j 6 --mem-per-job 2 --max 12 -- ninja -C "$bl/build" -k 0 -j '{JOBS}' \
		> "$bl/build.log" 2>&1 || { grep -a -A12 'FAILED:' "$bl/build.log" | head -n 80 >&2; exit 1; }
	echo "build-blender: compiler warnings: $(grep -c 'warning:' "$bl/build.log" || true)"
	"$tools-readelf" -h -d "$bl/build/bin/blender" | grep -E 'Machine|NEEDED' | sed 's/^/build-blender: /'
	ls -l "$bl/build/bin/blender"
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
	rm -f "$sys/apps/Blender"/blender.desktop "$sys/apps/Blender"/*.svg
	mkdir -p "$sys/data/deskbar/menu/Applications"
	ln -s ../../../../apps/Blender/Blender "$sys/data/deskbar/menu/Applications/Blender"
	r=()
	for lib in libpython3.10 libzstd libbrotlidec libbrotlicommon libwebp libwebpmux libwebpdemux libpng16 \
			libjpeg libexpat; do
		r+=(--requires "lib:$lib")
	done
	# revision 2: EEVEE on 4 color attachments (patches/blender/0007)
	package "$recipe" --revision 2 --system-prefix --no-devel --provides app:Blender \
		--requires "libsdl2 >= 2.32.10-8" --requires python3.10 "${r[@]}"
	"$pkgtool" list -i "$out/blender-3.6.23-2-arm64.hpkg" | grep -E 'requires|provides' | sed 's/^/build-blender: /'
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
	# and the run-time libraries of ours an image may not have yet (pkgman skips those it has)
	# (python3.10's modules link openssl, sqlite, bz2, libedit, expat, which package-port.py does not
	# turn into requires: they are in the sysroot's lib/, not non-packaged/)
	for p in zstd brotli libwebp libjpeg_turbo libpng16 openssl3 sqlite bzip2 libedit; do
		cp "$(newest "$root/artifacts/packages" "$p")" "$t/packages/"
	done
	cp "$gen/download/libffi-3.4.6_bootstrap-1-arm64.hpkg" "$gen/download/expat-2.5.0_bootstrap-1-arm64.hpkg" \
		"$t/packages/"
	rm -f "$t/packages"/*_devel-*.hpkg
	echo "build-blender: $t: $(du -sh "$t/Blender" | cut -f1) Blender, $(ls "$t/packages" | wc -l) packages"
}

steps=(sysroot python libdeflate imath openexr tiff epoxy boost tbb oiio pugixml yaml_cpp pystring
	minizip_ng opencolorio opensubdiv sse2neon freetype blender_source
	hosttools configure build stage blender_package)
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
