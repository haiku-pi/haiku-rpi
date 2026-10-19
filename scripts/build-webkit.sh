#!/usr/bin/env bash
# build-webkit.sh — cross-build HaikuWebKit (HaikuPorts haiku-libs/haikuwebkit, the WebKitLegacy
# port WebPositive uses) and every library it needs that the arm64 repository lacks, as HaikuPorts-
# style packages (scripts/cross-port.sh, scripts/package-port.py), in dependency order:
#
#   icu74 (+ _devel)             not built: the arm64 bootstrap packages (which the haiku package
#                                already requires) are extracted into the sysroot
#   libexecinfo, sqlite, libxml2, libxslt, lcms, brotli, woff2, libwebp, dav1d, libavif1.0, libpsl
#   haikuwebkit                  libWebKitLegacy, libJavaScriptCore, jsc
#
# Reused from scripts/build-netsurf.sh (must be in the sysroot first): libiconv, libpng16,
# libjpeg_turbo, openssl3, curl. Each recipe's build options are repeated here; where one differs,
# the comment says why. Not built, although the recipe lists them: libgpg_error (WebCore's libgcrypt
# use is commented out in this version, and nothing links it), libjxl (+ highway; USE_JPEGXL is off
# in OptionsHaiku.cmake), rav1e (libavif's AV1 encoder, a Rust crate; WebKit only decodes), and
# libidn2 + libunistring (libpsl takes its IDNA from ICU instead, which WebKit needs anyway; the
# recipe's libidn2 would also pull in gettext's libintl).
# Host tools: ruby, perl, python3, gperf, bison, flex, unifdef, cmake + ninja, meson.
# Output: artifacts/packages/*.hpkg.
#
#   scripts/build-webkit.sh [STEP]      (STEP: start at that step, e.g. "haikuwebkit"; the earlier
#                                        ones must already be in the sysroot)
#
# The WebKit steps keep their tree between runs (artifacts/cross-ports/haikuwebkit-1.10.0/: src/,
# build/), so that a failed or interrupted build continues where it stopped:
#   webkit_source     unpack + patch (only if src/ is missing; rm -rf it to start over)
#   webkit_configure  cmake
#   webkit_build      ninja, under scripts/heavy-build.sh (memory-capped; several hours)
#   haikuwebkit       install + package
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
ports="$root/sources/haikuports"
cross="$root/scripts/cross-port.sh"
package="$root/scripts/package-port.py"
gen="$root/sources/haiku/generated.arm64"
sysroot="$root/artifacts/sysroot-arm64"
np="$sysroot/boot/system/non-packaged"
hostTools="$gen/objects/linux/x86_64/release/tools"
export LD_LIBRARY_PATH="$gen/objects/linux/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
[ -f "$np/include/curl/curl.h" ] && [ -f "$np/include/openssl/ssl.h" ] \
	|| { echo "build-webkit: no curl/openssl3 in the sysroot: run scripts/build-netsurf.sh first" >&2; exit 1; }

# the script-mode builds see pkg-config into the sysroot
export PKG_CONFIG_SYSROOT_DIR="$sysroot"
export PKG_CONFIG_LIBDIR="$np/lib/pkgconfig:$sysroot/boot/system/develop/lib/pkgconfig"

# icu74 + icu74_devel: ICU, from the bootstrap packages (in the image already: the haiku package
# requires them). Their compiled-in data directory is wrong (the image sets ICU_DATA instead:
# tools/build/data/UserSetupEnvironment).
icu74() {
	local p
	for p in icu74 icu74_devel; do
		"$hostTools/package/package" extract -C "$sysroot/boot/system" \
			"$gen/download/$p-74.1_bootstrap-1-arm64.hpkg"
	done
	rm -f "$sysroot/boot/system/.PackageInfo"
	sed -i 's|/packages/[^/]*/\.self|/boot/system|g' "$sysroot"/boot/system/develop/lib/pkgconfig/icu-*.pc
}

# the recipe's three gcc lines; the soname is libexecinfo.so.1.1, as there
libexecinfo() {
	"$cross" "$ports/sys-libs/libexecinfo/libexecinfo-1.1.recipe" script '
${CC} -O2 -fPIC -c -o execinfo.o execinfo.c
${CC} -O2 -fPIC -c -o stacktraverse.o stacktraverse.c
${CC} -shared -Wl,-soname,libexecinfo.so.1.1 -o libexecinfo.so.1.1 execinfo.o stacktraverse.o
mkdir -p "$DEST/lib" "$DEST/include"
cp libexecinfo.so.1.1 "$DEST/lib/"
ln -s libexecinfo.so.1.1 "$DEST/lib/libexecinfo.so"
cp execinfo.h "$DEST/include/"'
	"$package" "$ports/sys-libs/libexecinfo/libexecinfo-1.1.recipe"
}

# a copy of RECIPE (into artifacts/cross-ports/recipes/<category>/, with its patches and licenses)
# in which the text FROM (a recipe-local variable, a bash expansion) is replaced by TO:
# cross-port.sh and haikuports-fetch.sh substitute only $portVersion and friends
#   recipe_with RECIPE FROM TO
recipe_with() {
	local dir="$root/artifacts/cross-ports/recipes/$(basename "$(dirname "$1")")" d
	mkdir -p "$dir"
	for d in patches licenses; do
		[ -d "$(dirname "$1")/$d" ] && ln -sfn "$(dirname "$1")/$d" "$dir/$d"
	done
	FROM="$2" TO="$3" perl -pe 's/\Q$ENV{FROM}\E/$ENV{TO}/g' "$1" > "$dir/$(basename "$1")"
	echo "$dir/$(basename "$1")"
}

# sqlite: the recipe's flags; its configure is autosetup (no autoreconf), soname libsqlite3.so.0
# (--soname=legacy). The sqlite3 shell (bin/) goes into the runtime package, as the recipe has it.
sqlite() {
	local recipe
	recipe="$(recipe_with "$ports/dev-db/sqlite/sqlite-3.53.4.0.recipe" '$sqliteVersion' 3530400)"
	"$cross" "$recipe" script '
export CPPFLAGS="-DSQLITE_ENABLE_COLUMN_METADATA=1 -DSQLITE_ENABLE_UNLOCK_NOTIFY \
	-DSQLITE_ENABLE_DBSTAT_VTAB -DSQLITE_SECURE_DELETE=1 -DSQLITE_ENABLE_FTS3=1 \
	-DSQLITE_ENABLE_FTS3_PARENTHESIS -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_RTREE"
./configure --host=aarch64-unknown-haiku --prefix=/boot/system/non-packaged --soname=legacy \
	--disable-static --disable-readline CC="$CC" AR="$AR"
make
make install DESTDIR="${DEST%/boot/system/non-packaged}"
rm -rf "$DEST/share"'
	"$package" "$recipe"
}

# libxml2: the recipe's options; no python module, no ICU (only for xmllint's --encode), iconv from
# libiconv (libroot has none)
libxml2() {
	local recipe
	recipe="$(recipe_with "$ports/dev-libs/libxml2/libxml2-2.15.3.recipe" '${portVersion%.*}' 2.15)"
	"$cross" "$recipe" autotools --disable-static \
		--with-legacy --without-python --without-icu --with-iconv="$np" LDFLAGS="-L$np/lib -lnetwork"
	rm -rf "$root/artifacts/cross-ports/libxml2-2.15.3/install/boot/system/non-packaged/share"
	"$package" "$recipe" --devel-bin xml2-config
}

# libxslt: --without-python (the recipe's is a separate package), --without-crypto (libexslt's
# EXSLT crypto functions need libgcrypt, which is not ported)
libxslt() {
	"$cross" "$ports/dev-libs/libxslt/libxslt-1.1.45.recipe" autotools --disable-static \
		--without-python --without-crypto
	rm -rf "$root/artifacts/cross-ports/libxslt-1.1.45/install/boot/system/non-packaged/share"
	"$package" "$ports/dev-libs/libxslt/libxslt-1.1.45.recipe" --devel-bin xslt-config
}

# lcms2: without the jpeg/tiff utilities (jpgicc, tificc: the recipe builds them; WebKit needs
# the library only)
lcms() {
	"$cross" "$ports/media-libs/lcms/lcms-2.19.1.recipe" autotools --disable-static \
		--without-jpeg --without-tiff
	rm -rf "$root/artifacts/cross-ports/lcms-2.19.1/install/boot/system/non-packaged/share"
	"$package" "$ports/media-libs/lcms/lcms-2.19.1.recipe"
}

brotli() {
	"$cross" "$ports/app-arch/brotli/brotli-1.2.0.recipe" cmake -DBROTLI_DISABLE_TESTS=ON \
		-DBUILD_TESTING=OFF
	rm -rf "$root/artifacts/cross-ports/brotli-1.2.0/install/boot/system/non-packaged/share"
	"$package" "$ports/app-arch/brotli/brotli-1.2.0.recipe"
}

woff2() {
	"$cross" "$ports/media-libs/woff2/woff2-1.0.2.recipe" cmake \
		-DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_SKIP_RPATH=ON -DCANONICAL_PREFIXES=ON
	"$package" "$ports/media-libs/woff2/woff2-1.0.2.recipe"
}

# libwebp: the libraries (webp, webpdemux, webpmux, sharpyuv) without the command-line tools (the
# recipe's _tools package; they would need libtiff and giflib)
libwebp() {
	"$cross" "$ports/media-libs/libwebp/libwebp-1.6.0.recipe" cmake -DBUILD_SHARED_LIBS=ON \
		-DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF \
		-DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF \
		-DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF \
		-DCMAKE_C_FLAGS=-DNDEBUG
	rm -rf "$root/artifacts/cross-ports/libwebp-1.6.0/install/boot/system/non-packaged/share"
	"$package" "$ports/media-libs/libwebp/libwebp-1.6.0.recipe"
}

# dav1d: the library (libavif's AV1 decoder), not the dav1d tool (the recipe packages it)
dav1d() {
	"$cross" "$ports/media-libs/dav1d/dav1d-1.5.4.recipe" meson -Denable_tools=false \
		-Denable_tests=false -Denable_examples=false
	"$package" "$ports/media-libs/dav1d/dav1d-1.5.4.recipe"
}

# libavif: decoding through dav1d only; the recipe also builds the rav1e encoder (a Rust crate,
# not ported) and the avifenc/avifdec tools (its _tools package)
libavif() {
	"$cross" "$ports/media-libs/libavif/libavif1.0-1.4.2.recipe" cmake -DAVIF_BUILD_APPS=OFF \
		-DAVIF_CODEC_DAV1D=SYSTEM -DAVIF_CODEC_RAV1E=OFF -DAVIF_CODEC_SVT=OFF -DAVIF_CODEC_AOM=OFF \
		-DAVIF_LIBSHARPYUV=SYSTEM -DAVIF_LIBYUV=OFF
	"$package" "$ports/media-libs/libavif/libavif1.0-1.4.2.recipe"
}

# libpsl: the public suffix list built in, IDNA through ICU (the recipe: libidn2, see the top). The
# recipe's PATCH (psl.c's _UNUSED clashes with Haiku's), then the shipped configure: the recipe's
# autoreconf needs autopoint (gettext), for nothing this build uses.
libpsl() {
	"$cross" "$ports/net-libs/libpsl/libpsl-0.21.5.recipe" script '
sed -i -e "s/\<_UNUSED/_&/g" src/psl.c
./configure --host=aarch64-unknown-haiku --prefix=/boot/system/non-packaged --disable-static \
	--enable-runtime=libicu --enable-builtin --disable-man --disable-gtk-doc CC="$CC" AR="$AR" \
	RANLIB="$RANLIB"
make -j"$(nproc)" LIBS="-lnetwork"
make install DESTDIR="${DEST%/boot/system/non-packaged}"
find "$DEST" -name "*.la" -delete
rm -f "$DEST"/lib/libpsl.a
rm -rf "$DEST/share"'
	"$package" "$ports/net-libs/libpsl/libpsl-0.21.5.recipe" --requires lib:libicuuc
}

# --- HaikuWebKit ---------------------------------------------------------------------------------
wkRecipe="$ports/haiku-libs/haikuwebkit/haikuwebkit-1.10.0.recipe"
wk="$root/artifacts/cross-ports/haikuwebkit-1.10.0"

# the recipe's source and patches (1.10.0 has none for gcc builds), then ours
# (patches/haikuwebkit/: JavaScriptCore on arm64); only when src/ does not exist yet
webkit_source() {
	local archive p
	[ -d "$wk/src" ] && { echo "build-webkit: $wk/src exists, kept"; return; }
	archive="$("$root/scripts/haikuports-fetch.sh" "$wkRecipe" \
		| sed -n 's/^haikuports-fetch: \(.*\) ([0-9]* bytes, sha256 ok)$/\1/p')"
	mkdir -p "$wk/unpack"
	tar -xf "$archive" -C "$wk/unpack"
	mv "$wk/unpack/haikuwebkit" "$wk/src"
	rmdir "$wk/unpack"
	for p in "$root"/patches/haikuwebkit/*.patch; do
		echo "build-webkit: applying $(basename "$p")"
		patch -s -p1 -d "$wk/src" < "$p"
	done
}

# what the recipe's Tools/Scripts/build-webkit --haiku --no-webkit2 passes (PORT, Release, the
# experimental features, the recipe's --cmakeargs), with our toolchain file. JIT: the default for
# ARM64 (JIT, DFG, FTL, WebAssembly; JSC_useJIT=false turns it off at run time). The headers go to
# the port's default, develop/headers (some of its install rules hardcode it; and a relative path
# given here for that PATH cache entry would be made absolute against the current directory).
webkit_configure() {
	cmake -S "$wk/src" -B "$wk/build" -G Ninja -Wno-dev \
		-DCMAKE_TOOLCHAIN_FILE="$root/tools/cmake/haiku-arm64.cmake" \
		-DPORT=Haiku -DCMAKE_BUILD_TYPE=Release -DENABLE_EXPERIMENTAL_FEATURES=ON \
		-DCMAKE_INSTALL_PREFIX=/boot/system/non-packaged -DSHOULD_INSTALL_JS_SHELL=ON \
		-DCMAKE_CXX_FLAGS="-ftrack-macro-expansion=0 --param ggc-min-expand=10" \
		> "$wk/configure.log" 2>&1 || { tail -n 40 "$wk/configure.log" >&2; exit 1; }
	grep -E '^(ENABLE_C_LOOP|ENABLE_JIT|ENABLE_DFG_JIT|ENABLE_FTL_JIT|ENABLE_WEBASSEMBLY):' \
		"$wk/build/CMakeCache.txt" || true
}

# ninja under the heavy-build guard: one WebKit build at a time, ~3 GB per compile job
webkit_build() {
	"$root/scripts/heavy-build.sh" --mem-per-job 3 -- ninja -C "$wk/build" -j '{JOBS}' \
		> "$wk/build.log" 2>&1 || { grep -a -A12 'FAILED:' "$wk/build.log" | head -n 60 >&2; exit 1; }
	echo "build-webkit: compiler warnings: $(grep -c 'warning:' "$wk/build.log" || true)"
}

# installed, then packaged: the headers moved to include/, where package-port.py takes them from
haikuwebkit() {
	local dest="$wk/install/boot/system/non-packaged"
	rm -rf "$wk/install"
	DESTDIR="$wk/install" ninja -C "$wk/build" install > "$wk/install.log"
	mv "$dest/develop/headers" "$dest/include"
	rmdir "$dest/develop"
	cp -a "$wk/install/." "$sysroot/"
	"$package" "$wkRecipe" --requires lib:libicuuc --requires lib:libicui18n
}

steps=(icu74 libexecinfo sqlite libxml2 libxslt lcms brotli woff2 libwebp dav1d libavif libpsl
	webkit_source webkit_configure webkit_build haikuwebkit)
start="${1:-${steps[0]}}"
started=0
for s in "${steps[@]}"; do
	[ "$s" = "$start" ] && started=1
	[ "$started" = 1 ] || continue
	echo "build-webkit: === $s"
	"$s"
done
[ "$started" = 1 ] || { echo "build-webkit: no step $start (${steps[*]})" >&2; exit 2; }
for p in libexecinfo sqlite libxml2 libxslt lcms brotli woff2 libwebp dav1d libavif1.0 libpsl \
		haikuwebkit; do
	ls -l "$root"/artifacts/packages/"$p"{,_devel}-[0-9]*-arm64.hpkg 2>/dev/null || true
done
