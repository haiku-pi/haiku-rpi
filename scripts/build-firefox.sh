#!/usr/bin/env bash
# build-firefox.sh — the Firefox browser (libxul, the Firefox binary, omni.ja) cross-built on this Linux
# host for Haiku arm64 (aarch64-unknown-haiku): Firefox 157.0.1 with HaikuPorts' Haiku patchsets
# (www-client/firefox, native toolkit cairo-haiku), patches/spidermonkey/ (step B) and patches/firefox/
# (ours: xptcall for arm64 Haiku, NSPR/NSS built in-tree for Haiku, arm64 UA strings and CPU feature
# detection, headless mode, fontconfig's configuration in the app directory).
#
#   scripts/build-firefox.sh [STEP]          (start at STEP; the earlier ones must have run)
#   scripts/build-firefox.sh --only STEP     (just that step; configure = ./mach configure alone)
#
# Steps:
#   source   scripts/build-spidermonkey.sh source (download, unpack to sources/firefox/firefox-157.0.1,
#            HaikuPorts + spidermonkey patches), then patches/firefox/*.patch (once; recorded in
#            .haiku-rpi-firefox-patches in the tree)
#   deps     the target libraries the native toolkit needs that the sysroot lacks, cross-built with
#            scripts/cross-port.sh from their HaikuPorts recipes: freetype 2.14.3 (the image has only
#            the 2.6.3 bootstrap package), fontconfig 2.18.2 (gfx/thebes' Haiku font list is
#            fontconfig-based), libevent 2.1.13 (IPC); NSPR, NSS, libvpx, harfbuzz, cairo, ICU are
#            Firefox's own copies; ffi, jpeg, webp, zlib, GL, libxml2 are the image's
#   hosttools  cbindgen (scripts/build-spidermonkey.sh hosttools)
#   config   artifacts/firefox/mozconfig
#   build    ./mach build under scripts/heavy-build.sh; resumable (objdir artifacts/firefox/obj)
#   relink   (only with --only, not in the chain) libxul.so alone from the objdir's objects, with the
#            link line of toolkit/library/build and $ldflags, into obj/dist/bin and obj/toolkit/library/build:
#            for an objdir that cannot be reconfigured because the sysroot lost the link libraries
#            (libffi, libjpeg, libwebp, freetype, fontconfig, libevent) since it was configured; the
#            link-only libraries come from jam's download directory and artifacts/cross-ports
#   check    every ELF file of dist/bin passes the runtime_loader checks (as build-spidermonkey.sh:
#            DYN, no COPY/TLSDESC/TPREL relocations, no tpidr_el0 reads)
#   stage    ./mach package's dist/Firefox, stripped, as artifacts/firefox/non-packaged/apps/Firefox
#            (libxul and the other libraries in lib/, as the HaikuPorts recipe arranges them, plus
#            freetype/fontconfig/libevent from the deps step's install trees; fails unless libxul.so
#            carries DT_RELR), fontconfig's configuration in fontconfig/ (Firefox sets
#            FONTCONFIG_PATH to it), and the HaikuPorts launcher "Firefox Browser"
#            (scripts/mkimage-pi4.sh --add-tree artifacts/firefox/non-packaged)
#   package  artifacts/firefox/firefox-157.0.1-<revision>-arm64.hpkg from the staged app (vendor "Haiku Project";
#            zstd), copied to jam's download directory and artifacts/packages (published)
#
# Toolchain: C/C++ = the Haiku cross gcc 13.3 (artifacts/rust/bin wrappers; see build-spidermonkey.sh
# for why not clang); Rust = scripts/build-rust.sh's rustc 1.90.0; bindgen parses the headers with the
# host's libclang 21 (--target=aarch64-unknown-haiku, the arm64 sysroot), it generates no code.
# Needs: scripts/build-rust.sh, scripts/build-spidermonkey.sh hosttools, the arm64 sysroot, host
# clang/libclang (no -dev package needed), node, python3, ~6 GB source tree (shared with
# build-spidermonkey.sh). Measured 2026-10-20 on the 16-thread / 29 GB host: ~1 h of compiling at
# -j11 (heavy-build caps it), MemAvailable down to ~4 GB at the peak; objdir 3.4 GB (no debug
# symbols; libxul.so 237 MB, 179 MB stripped); staged tree 288 MB; hpkg 112 MB.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
version=157.0.1
# the package's revision (3: WebGL on an OpenGL ES context; 4: zstd, 112 -> 102 MB, under GitHub's
# 100 MiB file limit, so the published repository carries it; 5: getentropy() for random bytes, GNU
# hash tables; 6: packed relative relocations, DT_RELR: libxul.so's 11.7 MB of RELA entries become a
# 0.1 MB .relr.dyn, so the package needs the runtime_loader of haiku 4539cd2f00)
revision=6
# the link flags: GNU hash tables too (as the Haiku build, haiku-pi 91012322ef): the runtime loader's
# symbol lookups skip an image that lacks a symbol with a Bloom filter test instead of walking its hash
# chain; and DT_RELR (perf-round-h20.md C1: Firefox's cold start 1.85 s faster from BFS, warm -0.8 %).
# An older runtime_loader runs a DT_RELR libxul.so with unrelocated pointers: the package's `requires`
# names the haiku package that has the loader (hrev60295-178)
ldflags="-Wl,--hash-style=both -Wl,-z,pack-relative-relocs"
haikuLoader="r1~beta6_hrev60295_178"
target=aarch64-unknown-haiku
src="$root/sources/firefox/firefox-$version"
out="$root/artifacts/firefox"
obj="$out/obj"
crossBin="$root/sources/haiku/generated.arm64/cross-tools-arm64/bin"
sysroot="$root/artifacts/sysroot-arm64"
np="$sysroot/boot/system/non-packaged"
recipes="$root/sources/haikuports"
libclang="${LIBCLANG_PATH:-/usr/lib/llvm-21/lib}"
[ -f "$root/artifacts/rust/env.sh" ] || { echo "build-firefox: run scripts/build-rust.sh first" >&2; exit 1; }

source_() {
	"$root/scripts/build-spidermonkey.sh" source
	local stamp="$src/.haiku-rpi-firefox-patches" p
	for p in "$root"/patches/firefox/*.patch; do
		grep -qxF "$(basename "$p")" "$stamp" 2> /dev/null && continue
		patch -d "$src" -p1 -s --no-backup-if-mismatch < "$p"
		basename "$p" >> "$stamp"
		echo "build-firefox: applied $(basename "$p")"
	done
}

deps() {
	local cross="$root/scripts/cross-port.sh"
	"$cross" "$recipes/media-libs/freetype/freetype-2.14.3.recipe" meson \
		-Dharfbuzz=disabled -Dbrotli=disabled -Dpng=enabled -Dbzip2=enabled -Dzlib=system -Derror_strings=true
	# the shipped configure (autoreconf needs autopoint); va_copy cannot be run-tested when cross-compiling
	AUTORECONF=0 "$cross" "$recipes/media-libs/fontconfig/fontconfig-2.18.2.recipe" autotools \
		--disable-static --disable-nls --disable-docs --enable-libxml2 --disable-cache-build \
		--sysconfdir=/boot/system/non-packaged/settings --localstatedir=/boot/system/non-packaged/var \
		--with-default-fonts=/boot/system/data/fonts \
		--with-add-fonts=/boot/system/non-packaged/data/fonts,/boot/home/config/data/fonts,/boot/home/config/non-packaged/data/fonts \
		--with-cache-dir=/boot/home/config/cache/fontconfig ac_cv_va_copy=C99
	# the recipe's flags
	"$cross" "$recipes/dev-libs/libevent/libevent-2.1.13.recipe" autotools \
		--disable-static --disable-samples --disable-openssl --disable-libevent-regress \
		CPPFLAGS="-D_BSD_SOURCE -DEV_ENABLE=0" LIBS="-lbsd -lnetwork"
}

hosttools() {
	"$root/scripts/build-spidermonkey.sh" hosttools
	# bindgen's libclang: configure looks for libclang.so (the host has only libclang-21.so.1, no
	# -dev package), and libclang finds its headers (stddef.h, …) in ../lib/clang/21 next to itself
	mkdir -p "$out/host/lib"
	ln -sfn "$(ls "$libclang"/libclang-*.so.[0-9]* | head -n 1)" "$out/host/lib/libclang.so"
	ln -sfn "$libclang/clang" "$out/host/lib/clang"
	ls -l "$out/host/lib"
}

config() {
	mkdir -p "$out/state"
	local cxxInc="$sysroot/boot/system/develop/headers/c++"
	cat > "$out/mozconfig" <<EOF
# written by scripts/build-firefox.sh
mk_add_options MOZ_OBJDIR=$obj
ac_add_options --enable-project=browser
ac_add_options --host=x86_64-pc-linux-gnu
ac_add_options --target=$target
ac_add_options --disable-bootstrap

# HaikuPorts' mozconfig_native (www-client/firefox/additional-files)
export MOZILLA_OFFICIAL=1
ac_add_options --enable-release
ac_add_options --enable-official-branding
ac_add_options --with-app-name=Firefox
ac_add_options --enable-default-toolkit=cairo-haiku
ac_add_options --enable-audio-backends=haiku
# system libraries the image has; NSPR, NSS, libvpx are Firefox's own copies (the recipe uses system
# ones, which are not built for arm64); libevent comes from the deps step
ac_add_options --with-system-ffi
ac_add_options --with-system-jpeg
ac_add_options --with-system-libevent
ac_add_options --with-system-webp
ac_add_options --with-system-zlib
ac_add_options --allow-addon-sideload
ac_add_options --with-unsigned-addon-scopes=app,system
ac_add_options --disable-tests
ac_add_options --disable-updater
ac_add_options --disable-valgrind
ac_add_options --disable-crashreporter
ac_add_options --without-wasm-sandboxed-libraries
mk_add_options MOZ_CRASHREPORTER=0
ac_add_options --enable-skia-pdf
ac_add_options --disable-lto
ac_add_options --enable-jit
ac_add_options --disable-debug
ac_add_options --disable-debug-symbols
ac_add_options --disable-debug-js-modules
# ours: no WebRTC (needs gn + the libwebrtc Haiku bits; later), no sandbox (Haiku has none), -O2
# (as the js shell of step B; the recipe uses -O3), the objdir keeps its symbols (stage strips)
ac_add_options --disable-webrtc
ac_add_options --disable-sandbox
ac_add_options --enable-optimize=-O2
ac_add_options --disable-strip
ac_add_options --disable-install-strip

ac_add_options --with-libclang-path=$out/host/lib
ac_add_options --with-clang-path=/usr/bin/clang++
export BINDGEN_CFLAGS="--sysroot=$sysroot -isystem $cxxInc -isystem $cxxInc/$target"
# clang (HaikuPorts builds Firefox with it) predefines __unix__ for Haiku, gcc does not: code such as
# Skia's SkFeatures.h then takes Haiku for macOS
# Firefox expects system libevent's headers in the compiler's default path (it ignores
# MOZ_LIBEVENT_CFLAGS); the deps step installs them under non-packaged/include: searched last
export CFLAGS="-D__unix__=1 -D__unix=1 -idirafter $np/include"
export CXXFLAGS="-D__unix__=1 -D__unix=1 -idirafter $np/include"
# GNU hash tables and DT_RELR ($ldflags at the top of this script)
export LDFLAGS="$ldflags"
export CC="$root/artifacts/rust/bin/$target-gcc"
export CXX="$root/artifacts/rust/bin/$target-g++"
export AR="$crossBin/$target-ar"
export RANLIB="$crossBin/$target-ranlib"
export STRIP="$crossBin/$target-strip"
export OBJCOPY="$crossBin/$target-objcopy"
export HOST_CC=gcc
export HOST_CXX=g++
export CBINDGEN="$root/artifacts/spidermonkey/host/bin/cbindgen"
# target libraries from the arm64 sysroot (with the deps step's in non-packaged/), never the host's
export PKG_CONFIG_SYSROOT_DIR="$sysroot"
export PKG_CONFIG_LIBDIR="$np/develop/lib/pkgconfig:$np/lib/pkgconfig:$sysroot/boot/system/develop/lib/pkgconfig"
export RUST_BACKTRACE=full
EOF
	echo "build-firefox: $out/mozconfig"
}

# the environment mach runs in: our rustc + cargo, offline, its Python state under artifacts/
mach_env() {
	# shellcheck source=/dev/null
	. "$root/artifacts/rust/env.sh"
	export MOZCONFIG="$out/mozconfig" MOZBUILD_STATE_PATH="$out/state"
	export CARGO_NET_OFFLINE=true CARGO_INCREMENTAL=0
	export MACH_BUILD_PYTHON_NATIVE_PACKAGE_SOURCE=none PIP_NO_INDEX=1 PIP_DISABLE_PIP_VERSION_CHECK=1
	export MOZ_NOSPAM=1
}

build() {
	mach_env
	local start=$SECONDS
	# ~2 GB per C++ job; the libxul link alone needs several GB (MemoryMax caps the whole build)
	(cd "$src" && "$root/scripts/heavy-build.sh" -j 12 --mem-per-job 2 -- \
		./mach --no-interactive build -j '{JOBS}')
	echo "build-firefox: mach build took $(( (SECONDS - start) / 60 )) min"
	ls -l "$obj/dist/bin/Firefox" "$obj/dist/bin/libxul.so"
}

# libxul.so alone, from the objdir's objects: the link line of toolkit/library/build (as ./mach build ran it
# on 10-24, objects compiled by GCC 13.3) with the current cross tools and $ldflags. For an objdir that
# ./mach cannot reconfigure any more: the sysroot was recreated on 11-03 (scripts/haiku-sysroot.sh) and lost
# the libraries the link needs, which are put together in $out/linklib from jam's download directory and the
# deps step's install trees; the sysroot is not touched. The link command is the 13.3-era one: a new
# libxul_so.list or flags need a ./mach build.
relink() {
	local gen="$root/sources/haiku/generated.arm64" L="$out/linklib" p f ports="$root/artifacts/cross-ports"
	local pkgtool="$gen/objects/linux/x86_64/release/tools/package/package"
	rm -rf "$L"
	mkdir -p "$L/develop/lib"
	for p in libffi-3.4.6_bootstrap libffi_devel-3.4.6_bootstrap libjpeg_turbo-3.1.4.1 libjpeg_turbo_devel-3.1.4.1 \
		libwebp-1.6.0 libwebp_devel-1.6.0; do
		LD_LIBRARY_PATH="$gen/objects/linux/lib" "$pkgtool" extract -C "$L" "$gen/download/$p-1-arm64.hpkg"
	done
	ln -sf "$ports/freetype-2.14.3/install/boot/system/non-packaged/lib/libfreetype.so.6" "$L/develop/lib/libfreetype.so"
	ln -sf "$ports/fontconfig-2.18.2/install/boot/system/non-packaged/lib/libfontconfig.so.1" "$L/develop/lib/libfontconfig.so"
	ln -sf "$ports/libevent-2.1.13/install/boot/system/non-packaged/lib/libevent-2.1.so.7" "$L/develop/lib/libevent.so"
	f="$obj/toolkit/library/build/libxul.so.relink"
	(cd "$obj/toolkit/library/build" &&
	"$root/artifacts/rust/bin/$target-g++" -std=gnu++20 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2 -fstack-protector-strong \
		-fstrict-flex-arrays=1 -fno-rtti -pthread -fno-sized-deallocation -fno-aligned-new -ffunction-sections \
		-fdata-sections -fno-math-errno -fno-exceptions -pipe -fPIC -D__unix__=1 -D__unix=1 -O2 -fomit-frame-pointer \
		-funwind-tables -shared -Wl,-z,defs -Wl,--gc-sections -Wl,-h,libxul.so -o "$f" -Wl,@libxul_so.list \
		$ldflags -Wl,--build-id=sha1 -Wl,-z,noexecstack -Wl,-z,text -Wl,-z,relro -Wl,-z,now -Wl,-z,nocopyreloc \
		-fstack-protector-strong -Wl,-rpath-link,"$obj/dist/bin" -Wl,-rpath-link,"$L/lib" \
		../../../third_party/angle/translator_gn/libtranslator_gn.a \
		../../../third_party/angle/angle_common_gn/libangle_common_gn.a \
		../../../third_party/angle/angle_common_shader_state_gn/libangle_common_shader_state_gn.a \
		../../../third_party/angle/preprocessor_gn/libpreprocessor_gn.a ../../../js/src/build/libjs_static.a \
		../../../build/pure_virtual/libpure_virtual.a ../../../aarch64-unknown-haiku/release/libgkrust.a \
		../../../dist/bin/libnspr4.so ../../../dist/bin/libplc4.so ../../../dist/bin/libplds4.so \
		../../../dist/bin/libgkcodecs.so ../../../dist/bin/liblgpllibs.so ../../../dist/bin/libnss3.so \
		../../../dist/bin/libnssutil3.so ../../../dist/bin/libsmime3.so ../../../dist/bin/libmozsqlite3.so \
		../../../dist/bin/libssl3.so -Wl,--version-script,libxul.so.symbols \
		-lbe -lmedia -lnetwork -ldevice -lroot -ltranslation -ltracker -lpthread -lgnu -L"$L/develop/lib" -lffi \
		-L"$sysroot/boot/system/lib" -lz -lm -lfreetype -lfontconfig -lgame -lGL -ljpeg -lwebpdemux -lwebp -levent -lbsd)
	"$crossBin/$target-readelf" -dW "$f" | grep -q '(RELR)' || { echo "build-firefox: relinked libxul.so has no DT_RELR" >&2; exit 1; }
	mv -f "$f" "$obj/toolkit/library/build/libxul.so"
	cp -f "$obj/toolkit/library/build/libxul.so" "$obj/dist/bin/libxul.so"
	ls -l "$obj/dist/bin/libxul.so"
}

# fails if FILE would not load or would misbehave under Haiku's arm64 runtime_loader
check_elf() {
	local f=$1 bad=0
	"$crossBin/$target-readelf" -h "$f" | grep -q 'Type: *DYN' || { echo "build-firefox: $f is not DYN"; bad=1; }
	if "$crossBin/$target-readelf" -rW "$f" | grep -m5 -E 'R_AARCH64_(COPY|TLSDESC|TLS_TPREL)'; then
		echo "build-firefox: $f has relocations Haiku's runtime_loader lacks"; bad=1
	fi
	if "$crossBin/$target-objdump" -d "$f" | grep -m3 'mrs.*tpidr_el0'; then
		echo "build-firefox: $f reads tpidr_el0 (static TLS model)"; bad=1
	fi
	return $bad
}

# an AArch64 ELF file (dist/bin also links host tools such as nsinstall)
is_elf() { [ "$(head -c 5 "$1" | od -An -tx1 | tr -d ' \n')" = 7f454c4602 ] &&
	[ "$(head -c 20 "$1" | od -An -tx1 -j 18 | tr -d ' \n')" = b700 ]; }

check() {
	local f bad=0
	while IFS= read -r -d '' f; do
		is_elf "$f" || continue
		check_elf "$f" || bad=1
	done < <(find -L "$obj/dist/bin" -type f -print0)
	"$crossBin/$target-readelf" -d "$obj/dist/bin/libxul.so" | grep NEEDED
	[ $bad = 0 ] && echo "build-firefox: dist/bin passes the loader checks"
	return $bad
}

# libraries the HaikuPorts recipe moves from the app directory into lib/ (the runtime_loader finds
# them there, %A/lib, also when Firefox dlopen()s them by their app-directory path)
libDirLibs="libgkcodecs.so liblgpllibs.so libmozavcodec.so libmozavutil.so libmozinference.so
	libmozsqlite3.so libxul.so"

stage() {
	mach_env
	local tree="$out/non-packaged" app="$out/non-packaged/apps/Firefox" f l
	local hostTools="$root/sources/haiku/generated.arm64/objects/linux/x86_64/release/tools"
	# dist/Firefox: what the installer and ./mach install would ship (omni.ja made here)
	(cd "$obj" && make -C browser/installer stage-package)
	rm -rf "$tree"
	mkdir -p "$app/lib"
	cp -a "$obj/dist/Firefox/." "$app/"
	for l in $libDirLibs; do
		[ -f "$app/$l" ] && mv "$app/$l" "$app/lib/"
	done
	# the deps step's libraries (by soname, as the runtime_loader looks them up), from their install
	# trees (the sysroot's non-packaged/ is wiped by scripts/haiku-sysroot.sh)
	for l in freetype-2.14.3/install/boot/system/non-packaged/lib/libfreetype.so.6 \
		fontconfig-2.18.2/install/boot/system/non-packaged/lib/libfontconfig.so.1 \
		libevent-2.1.13/install/boot/system/non-packaged/lib/libevent-2.1.so.7; do
		cp -L "$root/artifacts/cross-ports/$l" "$app/lib/"
	done
	# stripped (the objdir keeps the symbols for addr2line)
	while IFS= read -r -d '' f; do
		is_elf "$f" && "$crossBin/$target-strip" --strip-unneeded "$f"
	done < <(find "$app" -type f -print0)
	# DT_RELR: an older runtime_loader would run this libxul.so with unrelocated pointers (a crash, no
	# error), so a link without the flag must not become a package whose `requires` promise the loader
	"$crossBin/$target-readelf" -dW "$app/lib/libxul.so" | grep -E 'RELR|RELACOUNT' || true
	"$crossBin/$target-readelf" -dW "$app/lib/libxul.so" | grep -q '(RELR)' ||
		{ echo "build-firefox: $app/lib/libxul.so has no DT_RELR (LDFLAGS lacks -z pack-relative-relocs)" >&2; exit 1; }
	# fontconfig's configuration in the app directory: Firefox points FONTCONFIG_PATH there
	# (patches/firefox, nsBrowserApp.cpp); conf.d's links into conf.avail become copies
	f="$root/artifacts/cross-ports/fontconfig-2.18.2/install/boot/system/non-packaged"
	mkdir -p "$app/fontconfig/conf.d"
	cp "$f/settings/fonts/fonts.conf" "$app/fontconfig/"
	for l in "$f"/settings/fonts/conf.d/*; do
		if [ -L "$l" ]; then
			cp "$f/share/fontconfig/conf.avail/$(basename "$l")" "$app/fontconfig/conf.d/"
		else
			cp "$l" "$app/fontconfig/conf.d/"
		fi
	done
	# the recipe's launcher and resources (app signature, version, icon), with the host rc + xres
	"$root/artifacts/rust/bin/$target-g++" -O2 -o "$app/Firefox Browser" "$src/tools/haiku-launcher/launcher.cpp" -lbe
	"$crossBin/$target-strip" "$app/Firefox Browser"
	local add="$recipes/www-client/firefox/additional-files" v1 v2 v3
	IFS=. read -r v1 v2 v3 <<< "$version"
	sed -e "s|@APP_SIGNATURE@|application/x-vnd.Mozilla-Firefox|" -e "s|@MAJOR@|$v1|" -e "s|@MIDDLE@|$v2|" \
		-e "s|@MINOR@|$v3|" -e "s|@LONG_INFO@|A fast, private and open-source web browser|" \
		"$add/firefox.rdef.in" > "$out/firefox.rdef"
	sed -e "s|@MAJOR@|$v1|" -e "s|@MIDDLE@|$v2|" -e "s|@MINOR@|$v3|" \
		-e "s|@LONG_INFO@|A fast, private and open-source web browser|" \
		"$add/firefox_launcher.rdef.in" > "$out/firefox_launcher.rdef"
	"$hostTools/rc/rc" -o "$out/firefox.rsrc" "$out/firefox.rdef"
	"$hostTools/rc/rc" -o "$out/firefox_launcher.rsrc" "$out/firefox_launcher.rdef"
	"$hostTools/xres" -o "$app/Firefox" "$out/firefox.rsrc"
	"$hostTools/xres" -o "$app/Firefox Browser" "$out/firefox_launcher.rsrc"
	for f in "$app"/lib/*.so* "$app"/*.so "$app/Firefox"; do
		check_elf "$f" > /dev/null || { check_elf "$f"; exit 1; }
	done
	du -sh "$tree"
	ls -l "$app/lib/libxul.so"
}

# the staged app as a HaikuPorts-style package (the recipe's layout: apps/Firefox, bin/firefox, a
# Deskbar entry); its requires are the image's packages for the NEEDED libraries outside the app
package() {
	local pkg="$out/hpkg" app="$out/non-packaged/apps/Firefox"
	local gen="$root/sources/haiku/generated.arm64"
	local hpkg="$out/firefox-$version-$revision-arm64.hpkg"
	[ -x "$app/Firefox" ] || { echo "build-firefox: run the stage step first" >&2; exit 1; }
	rm -rf "$pkg"
	mkdir -p "$pkg/apps" "$pkg/bin" "$pkg/data/deskbar/menu/Applications"
	cp -a "$app" "$pkg/apps/"
	ln -s ../apps/Firefox/Firefox "$pkg/bin/firefox"
	ln -s ../../../../apps/Firefox/Firefox "$pkg/data/deskbar/menu/Applications/Firefox"
	cat > "$pkg/.PackageInfo" <<INFO
name			firefox
version			$version-$revision
architecture	arm64
summary			"A fast, private and open-source web browser"
description		"Firefox $version with HaikuPorts' native Haiku port (cairo-haiku). Cross-built for the Raspberry Pi 4 by the haiku-pi project (scripts/build-firefox.sh); freetype, fontconfig and libevent come with it, in apps/Firefox/lib."
packager		"haiku-pi build farm <build@haiku-pi.invalid>"
vendor			"Haiku Project"
licenses		{ "MPL v2.0" }
copyrights		{ "1995-2026 Mozilla Developers and Contributors" }
provides {
	firefox = $version
	app:Firefox = $version
	cmd:firefox = $version
}
requires {
	haiku >= $haikuLoader
	lib:libbz2
	lib:libffi
	lib:libgl
	lib:libjpeg
	lib:libpng16
	lib:libstdc++
	lib:libwebp
	lib:libwebpdemux
	lib:libxml2
	lib:libz
}
INFO
	rm -f "$hpkg"
	LD_LIBRARY_PATH="$gen/objects/linux/lib" "$gen/objects/linux/x86_64/release/tools/package/package" \
		create -q -z zstd -C "$pkg" -i "$pkg/.PackageInfo" "$hpkg"
	rm -rf "$pkg"
	# where the image build takes it from (the arm64 repository definition lists this revision), and
	# where scripts/publish-repo.sh takes the published packages from
	local dir
	for dir in "$gen/download" "$root/artifacts/packages"; do
		[ -d "$dir" ] || continue
		rm -f "$dir"/firefox-"$version"-*-arm64.hpkg
		cp "$hpkg" "$dir/"
	done
	ls -l "$hpkg"
}

# ./mach configure alone (--only configure): quicker turnarounds on configure problems
configure() {
	mach_env
	(cd "$src" && ./mach --no-interactive configure)
}

steps=(source deps hosttools config build check stage package)
if [ "${1:-}" = --only ]; then
	[ $# = 2 ] || { echo "usage: $0 --only STEP" >&2; exit 2; }
	case " ${steps[*]} configure relink " in
	*" $2 "*) [ "$2" = source ] && source_ || "$2" ;;
	*) echo "build-firefox: no step $2" >&2; exit 2 ;;
	esac
	exit 0
fi
first="${1:-source}"
run=0
for s in "${steps[@]}"; do
	[ "$s" = "$first" ] && run=1
	[ "$run" = 1 ] || continue
	case "$s" in
	source) source_ ;;
	*) "$s" ;;
	esac
done
[ "$run" = 1 ] || { echo "build-firefox: no step $first (${steps[*]})" >&2; exit 2; }
