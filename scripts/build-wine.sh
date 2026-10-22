#!/usr/bin/env bash
# build-wine.sh — Wine cross-built on this Linux host for Haiku arm64 (H15, docs/design/wine-x86.md):
# the Unix side with the Haiku arm64 cross compiler, the Windows (PE) side with llvm-mingw; packaged as
# wine, wine_x86 and wine_x86_64 for our arm64 repository.
#
#   [WINE_VERSION=V] scripts/build-wine.sh [STEP]          (start at STEP; the earlier ones must have run)
#   [WINE_VERSION=V] scripts/build-wine.sh --only STEP     (just that step)
#
# WINE_VERSION: a numbered release with a pinned archive below — the newest one (11.20) is the default and,
# for now, the only one (owner 2026-10-21: the newest numbered release; 11.0 was removed once 11.20 ran on
# the Pi). Each version has its own patches (patches/wine-<V>), patched tree (sources/wine/wine-haiku-<V>)
# and output (artifacts/wine-<V>). Only the default version's packages are copied into artifacts/packages
# and jam's download directory; another version's stay in its own output directory.
#
# Steps:
#   source     Wine (the GitHub mirror's tag archive: winehq.org does not resolve here) and llvm-mingw
#              20260826 into sources/wine/, both checked against pinned SHA-256s; the version's patches on a
#              copy (sources/wine/wine-haiku[-V]: HaikuPorts' Haiku patches brought to that version, plus arm64
#              Haiku support, the Media Kit sound driver and OpenGL on the V3D), then autoreconf
#   tools      Wine's build tools (winegcc, widl, wrc, winebuild, sfnt2fon) for the host: <out>/host-tools
#   build      configure for aarch64-unknown-haiku with the packaged prefix, as the HaikuPorts recipe
#              (app-emulation/wine: /boot/system, data in data/wine, manuals in documentation/man), PE side
#              arm64ec + aarch64 (ARM64X: each 64-bit DLL holds both, so x86-64 programs run through FEX's
#              ARM64EC emulator) and i386 (32-bit x86 programs through WoW64), and make: <out>/cross (a
#              changed configure line starts it afresh). Window driver: winewayland.drv over X547's
#              in-process server (scripts/build-wayland.sh), when that stack is built. FreeType (text:
#              without it every font metric, and so every window's caption and size, is garbage) from the
#              headers of the 2.14 in the sysroot (scripts/build-firefox.sh); Wine loads libfreetype.so.6 at
#              run time, the image's own (app_server's 2.6.3). OpenGL: win32u's EGL driver on Mesa's
#              surfaceless platform (libEGL, loaded at run time); the Wayland driver's own EGL path is
#              configured out (Mesa on Haiku has no Wayland EGL platform: with it, no GL at all). Sound:
#              winehaiku.drv (patches/wine-<V>/0002), a BSoundPlayer per stream into the system mixer; its C++
#              Media Kit shim (dlls/winehaiku.drv/haiku_player.cpp: Wine's makedep builds no C++) is compiled
#              here into a static library that configure links into winehaiku.so (HAIKU_AUDIO_LIBS)
#   install    make install into <out>/stage/boot/system (what the packages hold): debug info
#              stripped, no headers or import libraries, Box64's x86 emulator (scripts/build-box64.sh) as
#              wowbox64.dll and xtajit.dll, FEX's (scripts/build-fex.sh) as libarm64ecfex.dll and xtajit64.dll
#              (x86-64) and libwow64fex.dll (32-bit x86, the alternative to Box64). Then the test tree
#              <out>/install/boot/system/non-packaged:
#              the same files (hard links; Wine finds bin/, lib/wine and data/wine relative to ntdll.so, so
#              the packaged layout also runs from non-packaged/) plus the test programs of tools/wine-tests
#              (hello.c, ddtest.c, tone.c, gltest.c, crash.c for arm64, x86 and x64; click.c, input.c,
#              winlist.c, threadpcs.c, cpubench.c) in data/wine-tests
#              (~690 MB; a prefix takes ~1 GB more: images need -sHAIKU_IMAGE_SIZE=3500)
#   package    from the staged tree, zstd-compressed, into <out> (and, for the default version, artifacts/packages
#              and jam's download directory):
#                wine-<V>-<rev>-arm64.hpkg       the Unix side, the aarch64 + ARM64EC (ARM64X) PE side, manuals;
#                                                requires wine_data and wine_directx of the same revision
#                wine_data-<V>-<rev>-arm64.hpkg  data/wine (NLS tables, fonts, wine.inf)
#                wine_directx-<V>-<rev>-arm64.hpkg  the 64-bit D3DX/D3DCompiler/XAudio2/XACT DLLs (wine_data and
#                                                wine_directx are split off only for GitHub's file limit)
#                wine_x86-<V>-<rev>-arm64.hpkg   the i386 PE side, Box64's wowbox64.dll/xtajit.dll and FEX's
#                                                libwow64fex.dll (32-bit x86 programs); requires wine of the
#                                                same revision
#                wine_x86_64-<V>-<rev>-arm64.hpkg  FEX's libarm64ecfex.dll/xtajit64.dll (x86-64 programs: the
#                                                ARM64EC halves of Wine's DLLs are in wine); requires wine
#              (each under GitHub's 100 MiB limit; `pkgman install wine wine_x86 wine_x86_64` on the Pi).
#              WINE_PACKAGES_SHARED=no keeps them in <out> only (a trial build of an already published revision)
#
# Test: scripts/mkimage-pi4.sh --in <a 3500 MB build's haiku-mmc.image> \
#           --add-tree <out>/install/boot/system/non-packaged --bootscript tools/pi-tests/wine-hello.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# the version built by default, and the only one whose packages go to the shared package directories
defaultVersion=11.20
wineVersion="${WINE_VERSION:-$defaultVersion}"
case "$wineVersion" in
11.20) wineSha=98b21b4ebdf7d9e2baa4a3508514285cf449f455603f82d3364b014c0e79b793 ;;
*) echo "build-wine: no pinned archive for Wine $wineVersion" >&2; exit 1 ;;
esac
mingwRelease=20260826
mingwName=llvm-mingw-$mingwRelease-ucrt-ubuntu-22.04-x86_64
mingwSha=cee8d2ce3da5145ce4dc882e70d0b0719a783d53a99752c60948fc0659975a65

srcDir="$root/sources/wine"
pristine="$srcDir/wine-wine-$wineVersion"
src="$srcDir/wine-haiku-$wineVersion"
out="$root/artifacts/wine-$wineVersion"
patches="$root/patches/wine-$wineVersion"
sysroot="$root/artifacts/sysroot-arm64"
tools="$root/sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku"
mingw="$srcDir/$mingwName/bin"
jobs="$(nproc)"
# the packages' revision (scripts/publish-repo.sh publishes a rebuilt package only under a new one)
wineRevision=4
gen="$root/sources/haiku/generated.arm64"
pkgtool="$gen/objects/linux/x86_64/release/tools/package/package"

fetch() {	# URL FILE SHA256
	[ -f "$2" ] && echo "$3  $2" | sha256sum -c --quiet 2> /dev/null && return 0
	curl -fsSL -o "$2" "$1"
	echo "$3  $2" | sha256sum -c --quiet || { echo "build-wine: $2: wrong SHA-256" >&2; exit 1; }
}

step_source() {
	mkdir -p "$srcDir"
	fetch "https://github.com/wine-mirror/wine/archive/refs/tags/wine-$wineVersion.tar.gz" \
		"$srcDir/wine-$wineVersion.tar.gz" "$wineSha"
	fetch "https://github.com/mstorsjo/llvm-mingw/releases/download/$mingwRelease/$mingwName.tar.xz" \
		"$srcDir/$mingwName.tar.xz" "$mingwSha"
	[ -d "$pristine" ] || tar -xf "$srcDir/wine-$wineVersion.tar.gz" -C "$srcDir"
	[ -d "$srcDir/$mingwName" ] || tar -xf "$srcDir/$mingwName.tar.xz" -C "$srcDir"
	rm -rf "$src"
	cp -a "$pristine" "$src"
	for p in "$patches"/*.patch; do
		patch -d "$src" -p1 --quiet < "$p"
	done
	(cd "$src" && autoreconf -fi > /dev/null 2>&1)
}

step_tools() {
	mkdir -p "$out/host-tools"
	# with FreeType (the host's libfreetype-dev): sfnt2fon makes Wine's bitmap fonts from its TrueType ones
	(cd "$out/host-tools" && "$pristine/configure" --enable-win64 --without-x --without-wayland \
		--without-gnutls --disable-tests --without-mingw > configure.log 2>&1 \
		&& make -j"$jobs" __tooldeps__ > tools.log 2>&1)
}

step_build() {
	mkdir -p "$out/cross"
	# the window driver: Wine's Wayland driver over X547's in-process server (scripts/build-wayland.sh), when
	# that stack is built; configure needs the host's wayland-scanner and pkg-config named explicitly (with
	# neither it reports nothing and still enables the driver, which then fails to link). Its EGL path is
	# off (no wl_egl_window_create): Mesa on Haiku has no Wayland EGL platform, and a driver with that
	# path gives no pixel formats at all; without it win32u's own EGL driver (surfaceless) renders GL
	local display=(--without-wayland --disable-winewayland.drv)
	if [ -x "$root/artifacts/wayland-host/bin/wayland-scanner" ] \
		&& [ -f "$sysroot/boot/system/develop/lib/pkgconfig/wayland-client.pc" ]; then
		display=(--with-wayland WAYLAND_SCANNER="$root/artifacts/wayland-host/bin/wayland-scanner")
		display+=(ac_cv_func_wl_egl_window_create=no)
	fi
	# winehaiku.drv's Media Kit shim; hidden symbols: winehaiku.so exports only Wine's entry points
	local shim="$out/haiku-audio"
	mkdir -p "$shim"
	rm -f "$shim/libwinehaiku_player.a"
	"$tools-g++" --sysroot="$sysroot" -O2 -fmacro-prefix-map="$src/"= -fPIC -fvisibility=hidden -Wall -Wextra \
		-c "$src/dlls/winehaiku.drv/haiku_player.cpp" -o "$shim/haiku_player.o"
	"$tools-ar" rcs "$shim/libwinehaiku_player.a" "$shim/haiku_player.o"
	# the packaged prefix and directories of HaikuPorts' runConfigure. __FILE__ (assertions, debug
	# channels) relative to the source and build trees: the packages must not name this checkout
	local flags="-g -O2 -fmacro-prefix-map=$src/= -fmacro-prefix-map=$out/cross/="
	local conf=(--host=aarch64-unknown-haiku --prefix=/boot/system --datarootdir=/boot/system/data
		--datadir=/boot/system/data --mandir=/boot/system/documentation/man
		--includedir=/boot/system/develop/headers
		--enable-archs=arm64ec,aarch64,i386 --with-wine-tools="$out/host-tools"
		--without-x "${display[@]}" --without-gnutls
		--without-vulkan --without-pulse --without-alsa --without-oss --without-cups
		--without-dbus --without-sane --without-gphoto --without-v4l2 --without-pcap --without-usb
		--without-krb5 --without-netapi --without-gstreamer --without-ffmpeg --without-sdl --without-capi
		--without-opencl --without-udev --without-inotify --disable-tests
		CC="$tools-gcc --sysroot=$sysroot" CXX="$tools-g++ --sysroot=$sysroot" LDFLAGS="-lnetwork"
		CFLAGS="$flags" CROSSCFLAGS="$flags"
		FREETYPE_CFLAGS="-I$sysroot/boot/system/non-packaged/include/freetype2"
		FREETYPE_LIBS="-L$sysroot/boot/system/non-packaged/lib -lfreetype"
		HAIKU_AUDIO_LIBS="$shim/libwinehaiku_player.a -lmedia -lbe -lstdc++")
	# a different configure line (prefix, features) starts from a clean tree: the objects of the old one
	# have its paths and its config.h compiled in
	if [ -f "$out/cross/Makefile" ] \
		&& ! printf '%s\n' "${conf[@]}" | cmp -s - "$out/cross/configure.args"; then
		echo "build-wine: configure line changed, rebuilding from scratch"
		rm -rf "$out/cross"
		mkdir -p "$out/cross"
	fi
	(cd "$out/cross" && PATH="$mingw:$PATH" PKG_CONFIG=pkg-config \
		PKG_CONFIG_LIBDIR="$sysroot/boot/system/develop/lib/pkgconfig:$sysroot/boot/system/data/pkgconfig" \
		PKG_CONFIG_SYSROOT_DIR="$sysroot" "$src/configure" "${conf[@]}" > configure.log 2>&1) \
		|| { tail -n 20 "$out/cross/configure.log" >&2; exit 1; }
	# configure's own last step (config.status, makedep) can fail after a zero exit of its checks
	grep -q 'could not create Makefile' "$out/cross/configure.log" \
		&& { tail -n 20 "$out/cross/configure.log" >&2; exit 1; }
	printf '%s\n' "${conf[@]}" > "$out/cross/configure.args"
	# OpenGL is only a notice when configure finds no EGL: make it an error
	grep -q '^#define SONAME_LIBEGL ' "$out/cross/include/config.h" \
		|| { echo "build-wine: configure found no EGL (OpenGL off)" >&2; exit 1; }
	(cd "$out/cross" && PATH="$mingw:$PATH" "$root/scripts/heavy-build.sh" -- make -j{JOBS} > build.log 2>&1) \
		|| { tail -n 30 "$out/cross/build.log" >&2; exit 1; }
}

step_install() {
	local stage="$out/stage" system="$out/stage/boot/system"
	local dest="$out/install" prefix="$out/install/boot/system/non-packaged"
	rm -rf "$stage" "$dest"
	(cd "$out/cross" && PATH="$mingw:$PATH" make install DESTDIR="$stage" > install.log 2>&1) \
		|| { tail -n 20 "$out/cross/install.log" >&2; exit 1; }
	# no development files (no winegcc in a cross build to use them) and no desktop file (Haiku has none)
	rm -rf "$system/develop" "$system/data/applications"
	find "$system/lib/wine" -name '*.a' -delete
	ln -sf ../lib/wine/aarch64-unix/wine "$system/bin/wine"
	for f in "$system"/lib/wine/aarch64-unix/* "$system/bin/wineserver"; do
		"$tools-strip" --strip-debug "$f" 2> /dev/null || true
	done
	find "$system"/lib/wine/*-windows -type f -print0 \
		| xargs -0 -n 50 "$mingw/llvm-strip" --strip-debug 2> /dev/null || true
	# Box64's x86 emulator for WoW64 (scripts/build-box64.sh), if built — also under the name WoW64 loads
	# by default on arm64, xtajit.dll: the first wineboot fills the prefix's 32-bit system directory by
	# running 32-bit rundll32, before any registry setting could name another emulator
	if [ -f "$root/artifacts/box64/wowbox64.dll" ]; then
		cp "$root/artifacts/box64/wowbox64.dll" "$system/lib/wine/aarch64-windows/"
		cp "$root/artifacts/box64/wowbox64.dll" "$system/lib/wine/aarch64-windows/xtajit.dll"
	fi
	# FEX (scripts/build-fex.sh), if built: the ARM64EC emulator for x86-64 programs, also as xtajit64.dll, the
	# name Wine's ARM64EC ntdll loads when HKLM\Software\Microsoft\Wow64\amd64 names none; and FEX's WoW64
	# emulator, chosen instead of Box64 by naming it in HKLM\Software\Microsoft\Wow64\x86
	if [ -f "$root/artifacts/fex/libarm64ecfex.dll" ]; then
		cp "$root/artifacts/fex/libarm64ecfex.dll" "$system/lib/wine/aarch64-windows/"
		cp "$root/artifacts/fex/libarm64ecfex.dll" "$system/lib/wine/aarch64-windows/xtajit64.dll"
	fi
	[ -f "$root/artifacts/fex/libwow64fex.dll" ] && cp "$root/artifacts/fex/libwow64fex.dll" "$system/lib/wine/aarch64-windows/"
	# packaged files must not name this checkout (a path compiled in) or the non-packaged prefix
	# (-a: grep here skips binary files without it; status 1 = no match, 2 = an error)
	local found rc=0
	found="$(grep -rlaF -e "$root" -e /boot/system/non-packaged "$system")" || rc=$?
	[ "$rc" -le 1 ] || { echo "build-wine: the path check failed" >&2; exit 1; }
	[ -z "$found" ] || { echo "build-wine: build or non-packaged paths in: $found" >&2; exit 1; }

	# the test tree: the same files in non-packaged/ (hard links), plus the test programs
	mkdir -p "$dest/boot/system"
	cp -al "$system" "$prefix"
	mkdir -p "$prefix/data/wine-tests"
	"$mingw/aarch64-w64-mingw32-clang" -O2 -o "$prefix/data/wine-tests/hello-arm64.exe" \
		"$root/tools/wine-tests/hello.c"
	"$mingw/i686-w64-mingw32-clang" -O2 -o "$prefix/data/wine-tests/hello-x86.exe" \
		"$root/tools/wine-tests/hello.c"
	"$mingw/aarch64-w64-mingw32-clang" -O2 -o "$prefix/data/wine-tests/click.exe" "$root/tools/wine-tests/click.c"
	"$mingw/aarch64-w64-mingw32-clang" -O2 -o "$prefix/data/wine-tests/input.exe" "$root/tools/wine-tests/input.c"
	"$mingw/aarch64-w64-mingw32-clang" -O2 -o "$prefix/data/wine-tests/threadpcs.exe" "$root/tools/wine-tests/threadpcs.c"
	"$mingw/aarch64-w64-mingw32-clang" -O2 -o "$prefix/data/wine-tests/winlist.exe" "$root/tools/wine-tests/winlist.c"
	"$mingw/x86_64-w64-mingw32-clang" -O2 -o "$prefix/data/wine-tests/hello-x64.exe" "$root/tools/wine-tests/hello.c"
	for a in aarch64:arm64 i686:x86 x86_64:x64; do
		"$mingw/${a%%:*}-w64-mingw32-clang" -O2 -o "$prefix/data/wine-tests/ddtest-${a#*:}.exe" \
			"$root/tools/wine-tests/ddtest.c" -lddraw -ldxguid
		"$mingw/${a%%:*}-w64-mingw32-clang" -O2 -o "$prefix/data/wine-tests/tone-${a#*:}.exe" \
			"$root/tools/wine-tests/tone.c" -lwinmm
		"$mingw/${a%%:*}-w64-mingw32-clang" -O2 -o "$prefix/data/wine-tests/gltest-${a#*:}.exe" \
			"$root/tools/wine-tests/gltest.c" -lopengl32 -lgdi32
		"$mingw/${a%%:*}-w64-mingw32-clang" -O2 -o "$prefix/data/wine-tests/cpubench-${a#*:}.exe" \
			"$root/tools/wine-tests/cpubench.c"
		# with DWARF: its crash report symbolizes on the build host (llvm-symbolizer --obj=...)
		"$mingw/${a%%:*}-w64-mingw32-clang" -O1 -g -o "$prefix/data/wine-tests/crash-${a#*:}.exe" \
			"$root/tools/wine-tests/crash.c"
	done
	du -sh "$prefix"
}

# requires of the ELF files given: their NEEDED libraries as lib: resolvables (the system's own: "haiku";
# Wine's own ntdll.so and win32u.so: none)
elf_requires() {
	local f
	for f in "$@"; do
		"$tools-readelf" -d "$f" 2> /dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'
	done | sort -u | while read -r lib; do
		case "$lib" in
		ntdll.so|win32u.so) ;;
		libroot.so|libbe.so|libmedia.so|libnetwork.so|libbsd.so|libgnu.so|libgame.so|libdevice.so) ;;
		*) echo "lib:$(echo "${lib%%.so*}" | tr - _)" ;;
		esac
	done
}

# make_package NAME DIR SUMMARY DESCRIPTION LICENSES PROVIDES REQUIRES [COPYRIGHTS] (resolvables separated by
# spaces, written without spaces: cmd:wine=11.20, wine==11.20-1, haiku>=r1~beta6_hrev60262_138)
make_package() {
	local name="$1" dir="$2" hpkg="$out/$1-$wineVersion-$wineRevision-arm64.hpkg"
	{
		printf 'name\t\t\t%s\nversion\t\t\t%s-%s\narchitecture\tarm64\n' "$name" "$wineVersion" "$wineRevision"
		printf 'summary\t\t\t"%s"\ndescription\t\t"%s"\n' "$3" "$4"
		printf 'packager\t\t"haiku-pi build farm <build@haiku-pi.invalid>"\nvendor\t\t\t"Haiku Project"\n'
		printf 'licenses\t\t{ %s }\n' "$5"
		printf 'copyrights\t\t{ "1993-2026 the Wine project authors"%s }\n' "${8:+ $8}"
		printf 'provides {\n%s\n}\nrequires {\n%s\n}\n' "$(printf '\t%s\n' $6)" "$(printf '\t%s\n' $7)"
	} | sed -E 's/(==|>=|<=)/ \1 /; t; s/=/ = /' > "$dir/.PackageInfo"
	rm -f "$hpkg"
	LD_LIBRARY_PATH="$gen/objects/linux/lib" "$pkgtool" create -q -z zstd -C "$dir" -i "$dir/.PackageInfo" "$hpkg"
	rm -f "$dir/.PackageInfo"
	local size
	size="$(stat -c %s "$hpkg")"
	# GitHub's file limit (scripts/publish-repo.sh)
	[ "$size" -le 104857600 ] || { echo "build-wine: $hpkg: $size bytes, over 100 MiB" >&2; exit 1; }
	local d
	# another version's packages stay in its output directory: the shared directories hold one wine; so do
	# packages built with WINE_PACKAGES_SHARED=no (a trial build that must not replace the published revision)
	if [ "$wineVersion" != "$defaultVersion" ] || [ "${WINE_PACKAGES_SHARED:-yes}" = no ]; then
		echo "build-wine: $hpkg ($size bytes)"
		return 0
	fi
	for d in "$gen/download" "$root/artifacts/packages"; do
		[ -d "$d" ] || continue
		rm -f "$d/$name-$wineVersion"-*-arm64.hpkg
		cp "$hpkg" "$d/"
	done
	echo "build-wine: $hpkg ($size bytes)"
}

step_package() {
	local system="$out/stage/boot/system" pkg="$out/hpkg"
	[ -x "$system/bin/wineserver" ] || { echo "build-wine: run the install step first" >&2; exit 1; }
	rm -rf "$pkg"
	mkdir -p "$pkg/wine" "$pkg/wine_x86/lib/wine/aarch64-windows" "$pkg/wine_x86_64/lib/wine/aarch64-windows" \
		"$pkg/wine_data/data" "$pkg/wine_directx/lib/wine/aarch64-windows"
	# wine: everything but the x86 part (hard links of the staged files)
	cp -al "$system"/. "$pkg/wine/"
	mv "$pkg/wine/lib/wine/i386-windows" "$pkg/wine_x86/lib/wine/"
	# with ARM64EC each 64-bit DLL holds two builds (ARM64X) and wine alone was 115 MB: its data (NLS tables,
	# fonts, wine.inf) and the 64-bit DirectX redistributables (D3DX 9-11, D3DCompiler, XAudio2/XACT) are
	# packages of their own, which wine requires — only for GitHub's file limit
	mv "$pkg/wine/data/wine" "$pkg/wine_data/data/"
	local f
	for f in "$pkg/wine/lib/wine/aarch64-windows"/{d3dx9_,d3dx10_,d3dx11_,d3dcompiler_,xactengine,xaudio2_,x3daudio,xapofx}*; do
		[ -f "$f" ] && mv "$f" "$pkg/wine_directx/lib/wine/aarch64-windows/"
	done
	for f in wowbox64.dll xtajit.dll libwow64fex.dll; do
		[ -f "$pkg/wine/lib/wine/aarch64-windows/$f" ] \
			&& mv "$pkg/wine/lib/wine/aarch64-windows/$f" "$pkg/wine_x86/lib/wine/aarch64-windows/"
	done
	local x64=0
	for f in libarm64ecfex.dll xtajit64.dll; do
		[ -f "$pkg/wine/lib/wine/aarch64-windows/$f" ] \
			&& mv "$pkg/wine/lib/wine/aarch64-windows/$f" "$pkg/wine_x86_64/lib/wine/aarch64-windows/" && x64=1
	done
	local provides requires
	provides="wine=$wineVersion-$wineRevision"
	for f in "$pkg/wine/bin"/*; do provides+=" cmd:$(basename "$f")=$wineVersion"; done
	# the libraries Wine loads at run time (NEEDED cannot show them): FreeType (text), EGL (OpenGL), and
	# X547's in-process Wayland server, which libwayland-client loads
	# haiku: a kernel that keeps MAP_SHARED mappings shared across mprotect() (haiku-pi 894c4abe7f, the 138th
	# commit after hrev60262): before it, the ARM64X build's processes detached wineserver's session mapping
	# and no prefix could be made. wayland_server 2 centres a fullscreen window smaller than the screen.
	requires="haiku>=r1~beta6_hrev60262_138 $(elf_requires "$pkg/wine/bin/wineserver" "$pkg/wine/lib/wine/aarch64-unix"/*)"
	requires+=" lib:libfreetype lib:libegl wayland_server>=0.1.20251004-2 wine_data==$wineVersion-$wineRevision"
	requires+=" wine_directx==$wineVersion-$wineRevision"
	make_package wine_data "$pkg/wine_data" "Wine's data files" \
		"The data of Wine $wineVersion (data/wine: NLS tables, fonts, wine.inf), a package of its own only for size; wine requires it. Cross-built for the Raspberry Pi 4 by the haiku-pi project (scripts/build-wine.sh)." \
		'"GNU LGPL v2.1"' "wine_data=$wineVersion-$wineRevision" "haiku"
	make_package wine_directx "$pkg/wine_directx" "Wine's 64-bit DirectX redistributables" \
		"Wine $wineVersion's 64-bit (aarch64 + ARM64EC) D3DX 9-11, D3DCompiler, XAudio2, XACT, X3DAudio and XAPOFX DLLs, a package of its own only for size; wine requires it (the 32-bit ones are in wine_x86). Cross-built for the Raspberry Pi 4 by the haiku-pi project (scripts/build-wine.sh)." \
		'"GNU LGPL v2.1"' "wine_directx=$wineVersion-$wineRevision" "haiku"
	make_package wine "$pkg/wine" "Program which allows running Microsoft Windows programs" \
		"Wine $wineVersion: runs 64-bit Arm (aarch64) Windows programs on Haiku; with wine_x86 also 32-bit x86 ones, with wine_x86_64 64-bit x86 ones. HaikuPorts' Haiku patches with arm64 support, a Haiku sound driver (winehaiku.drv, Media Kit) and the Wayland window driver over X547's in-process server; cross-built for the Raspberry Pi 4 by the haiku-pi project (scripts/build-wine.sh)." \
		'"GNU LGPL v2.1"' "$provides" "$requires"
	make_package wine_x86 "$pkg/wine_x86" "Wine's 32-bit x86 support (WoW64 with the Box64 emulator)" \
		"The i386 Windows side of Wine $wineVersion and Box64's wowbox64.dll (also as xtajit.dll), the x86 emulator WoW64 runs 32-bit x86 Windows programs with on arm64; FEX's libwow64fex.dll as an alternative (chosen in the registry, HKLM Software/Microsoft/Wow64/x86). Cross-built for the Raspberry Pi 4 by the haiku-pi project (scripts/build-wine.sh, scripts/build-box64.sh, scripts/build-fex.sh)." \
		'"GNU LGPL v2.1" "MIT"' "wine_x86=$wineVersion-$wineRevision" "haiku wine==$wineVersion-$wineRevision" \
		'"2018-2026 Sebastien Chevalier and the Box64 contributors" "2018-2026 the FEX-Emu contributors"'
	[ "$x64" = 1 ] || { echo "build-wine: no FEX (scripts/build-fex.sh): no wine_x86_64"; rm -rf "$pkg"; return 0; }
	make_package wine_x86_64 "$pkg/wine_x86_64" "Wine's 64-bit x86 support (ARM64EC with the FEX emulator)" \
		"FEX's libarm64ecfex.dll (also as xtajit64.dll, the name Wine loads by default), the x86-64 emulator Wine $wineVersion runs 64-bit x86 Windows programs with on arm64 through ARM64EC (Wine's own DLLs run as native ARM64EC code; only the program's x86-64 code is emulated). Cross-built for the Raspberry Pi 4 by the haiku-pi project (scripts/build-wine.sh, scripts/build-fex.sh)." \
		'"MIT"' "wine_x86_64=$wineVersion-$wineRevision" "haiku wine==$wineVersion-$wineRevision" \
		'"2018-2026 the FEX-Emu contributors"'
	rm -rf "$pkg"
}

steps=(source tools build install package)
if [ "${1:-}" = --only ]; then
	"step_$2"
	exit 0
fi
start="${1:-source}"
run=0
for s in "${steps[@]}"; do
	[ "$s" = "$start" ] && run=1
	[ "$run" = 1 ] && { echo "build-wine: $s"; "step_$s"; }
done
