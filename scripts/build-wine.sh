#!/usr/bin/env bash
# build-wine.sh — Wine 11.0 cross-built on this Linux host for Haiku arm64 (H15, docs/design/wine-x86.md):
# the Unix side with the Haiku arm64 cross compiler, the Windows (PE) side with llvm-mingw; packaged as
# wine and wine_x86 for our arm64 repository.
#
#   scripts/build-wine.sh [STEP]          (start at STEP; the earlier ones must have run)
#   scripts/build-wine.sh --only STEP     (just that step)
#
# Steps:
#   source     Wine 11.0 (the GitHub mirror's tag archive: winehq.org does not resolve here) and llvm-mingw
#              20260826 into sources/wine/, both checked against pinned SHA-256s; patches/wine/*.patch on a
#              copy (sources/wine/wine-haiku: HaikuPorts' Haiku patches brought to 11.0, plus arm64 Haiku
#              support), then autoreconf
#   tools      Wine's build tools (winegcc, widl, wrc, winebuild, sfnt2fon) for the host: artifacts/wine/host-tools
#   build      configure for aarch64-unknown-haiku with the packaged prefix, as the HaikuPorts recipe
#              (app-emulation/wine: /boot/system, data in data/wine, manuals in documentation/man), PE side
#              aarch64 and i386 (32-bit x86 programs through WoW64), and make: artifacts/wine/cross (a
#              changed configure line starts it afresh). Window driver: winewayland.drv over X547's
#              in-process server (scripts/build-wayland.sh), when that stack is built. FreeType (text:
#              without it every font metric, and so every window's caption and size, is garbage) from the
#              headers of the 2.14 in the sysroot (scripts/build-firefox.sh); Wine loads libfreetype.so.6 at
#              run time, the image's own (app_server's 2.6.3). OpenGL: win32u's EGL driver on Mesa's
#              surfaceless platform (libEGL, loaded at run time); the Wayland driver's own EGL path is
#              configured out (Mesa on Haiku has no Wayland EGL platform: with it, no GL at all). Sound:
#              winehaiku.drv (patches/wine/0002), a BSoundPlayer per stream into the system mixer; its C++
#              Media Kit shim (dlls/winehaiku.drv/haiku_player.cpp: Wine's makedep builds no C++) is compiled
#              here into a static library that configure links into winehaiku.so (HAIKU_AUDIO_LIBS)
#   install    make install into artifacts/wine/stage/boot/system (what the packages hold): debug info
#              stripped, no headers or import libraries, Box64's x86 emulator (scripts/build-box64.sh) as
#              wowbox64.dll and xtajit.dll. Then the test tree artifacts/wine/install/boot/system/non-packaged:
#              the same files (hard links; Wine finds bin/, lib/wine and data/wine relative to ntdll.so, so
#              the packaged layout also runs from non-packaged/) plus the test programs of tools/wine-tests
#              (hello.c, ddtest.c, tone.c for arm64 and x86; click.c, input.c) in data/wine-tests
#              (~690 MB; a prefix takes ~1 GB more: images need -sHAIKU_IMAGE_SIZE=3500)
#   package    from the staged tree, zstd-compressed, into artifacts/packages and jam's download directory:
#                wine-11.0-<rev>-arm64.hpkg      the Unix side, the aarch64 PE side, data/wine, manuals
#                wine_x86-11.0-<rev>-arm64.hpkg  the i386 PE side and Box64's wowbox64.dll/xtajit.dll
#                                                (32-bit x86 programs); requires wine of the same revision
#              (58 MB each with zstd, under GitHub's 100 MiB limit; `pkgman install wine wine_x86` on the Pi)
#
# Test: scripts/mkimage-pi4.sh --in <a 3500 MB build's haiku-mmc.image> \
#           --add-tree artifacts/wine/install/boot/system/non-packaged --bootscript tools/pi-tests/wine-hello.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
wineVersion=11.0
wineSha=f09e8153aa46a581d2b56a5b1363b04832070b9409d9244a68cf482b243ff14a
mingwRelease=20260826
mingwName=llvm-mingw-$mingwRelease-ucrt-ubuntu-22.04-x86_64
mingwSha=cee8d2ce3da5145ce4dc882e70d0b0719a783d53a99752c60948fc0659975a65

srcDir="$root/sources/wine"
pristine="$srcDir/wine-wine-$wineVersion"
src="$srcDir/wine-haiku"
out="$root/artifacts/wine"
sysroot="$root/artifacts/sysroot-arm64"
tools="$root/sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku"
mingw="$srcDir/$mingwName/bin"
jobs="$(nproc)"
# the packages' revision (scripts/publish-repo.sh publishes a rebuilt package only under a new one)
wineRevision=1
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
	for p in "$root"/patches/wine/*.patch; do
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
		display=(--with-wayland WAYLAND_SCANNER="$root/artifacts/wayland-host/bin/wayland-scanner"
			ac_cv_lib_wayland_egl_wl_egl_window_create=no)
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
		--enable-archs=aarch64,i386 --with-wine-tools="$out/host-tools"
		--without-x "${display[@]}" --without-gnutls
		--without-vulkan --without-pulse --without-alsa --without-oss --without-cups
		--without-dbus --without-sane --without-gphoto --without-v4l2 --without-pcap --without-usb
		--without-krb5 --without-netapi --without-gstreamer --without-ffmpeg --without-sdl --without-capi
		--without-opencl --without-udev --without-unwind --without-inotify --disable-tests
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
	for a in aarch64:arm64 i686:x86; do
		"$mingw/${a%%:*}-w64-mingw32-clang" -O2 -o "$prefix/data/wine-tests/ddtest-${a#*:}.exe" \
			"$root/tools/wine-tests/ddtest.c" -lddraw -ldxguid
		"$mingw/${a%%:*}-w64-mingw32-clang" -O2 -o "$prefix/data/wine-tests/tone-${a#*:}.exe" \
			"$root/tools/wine-tests/tone.c" -lwinmm
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
# spaces, written without spaces: cmd:wine=11.0, wine==11.0-1)
make_package() {
	local name="$1" dir="$2" hpkg="$out/$1-$wineVersion-$wineRevision-arm64.hpkg"
	{
		printf 'name\t\t\t%s\nversion\t\t\t%s-%s\narchitecture\tarm64\n' "$name" "$wineVersion" "$wineRevision"
		printf 'summary\t\t\t"%s"\ndescription\t\t"%s"\n' "$3" "$4"
		printf 'packager\t\t"haiku-pi build farm <build@haiku-pi.invalid>"\nvendor\t\t\t"Haiku Project"\n'
		printf 'licenses\t\t{ %s }\n' "$5"
		printf 'copyrights\t\t{ "1993-2026 the Wine project authors"%s }\n' "${8:+ $8}"
		printf 'provides {\n%s\n}\nrequires {\n%s\n}\n' "$(printf '\t%s\n' $6)" "$(printf '\t%s\n' $7)"
	} | sed 's/==/ == /; t; s/=/ = /' > "$dir/.PackageInfo"
	rm -f "$hpkg"
	LD_LIBRARY_PATH="$gen/objects/linux/lib" "$pkgtool" create -q -z zstd -C "$dir" -i "$dir/.PackageInfo" "$hpkg"
	rm -f "$dir/.PackageInfo"
	local size
	size="$(stat -c %s "$hpkg")"
	# GitHub's file limit (scripts/publish-repo.sh)
	[ "$size" -le 104857600 ] || { echo "build-wine: $hpkg: $size bytes, over 100 MiB" >&2; exit 1; }
	local d
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
	mkdir -p "$pkg/wine" "$pkg/wine_x86/lib/wine/aarch64-windows"
	# wine: everything but the x86 part (hard links of the staged files)
	cp -al "$system"/. "$pkg/wine/"
	mv "$pkg/wine/lib/wine/i386-windows" "$pkg/wine_x86/lib/wine/"
	local f
	for f in wowbox64.dll xtajit.dll; do
		[ -f "$pkg/wine/lib/wine/aarch64-windows/$f" ] \
			&& mv "$pkg/wine/lib/wine/aarch64-windows/$f" "$pkg/wine_x86/lib/wine/aarch64-windows/"
	done
	local provides requires
	provides="wine=$wineVersion-$wineRevision"
	for f in "$pkg/wine/bin"/*; do provides+=" cmd:$(basename "$f")=$wineVersion"; done
	# the libraries Wine loads at run time (NEEDED cannot show them): FreeType (text), EGL (OpenGL), and
	# X547's in-process Wayland server, which libwayland-client loads
	requires="haiku $(elf_requires "$pkg/wine/bin/wineserver" "$pkg/wine/lib/wine/aarch64-unix"/*)"
	requires+=" lib:libfreetype lib:libegl wayland_server"
	make_package wine "$pkg/wine" "Program which allows running Microsoft Windows programs" \
		"Wine $wineVersion: runs 64-bit Arm (aarch64) Windows programs on Haiku; with wine_x86 also 32-bit x86 ones. HaikuPorts' Haiku patches with arm64 support, a Haiku sound driver (winehaiku.drv, Media Kit) and the Wayland window driver over X547's in-process server; cross-built for the Raspberry Pi 4 by the haiku-pi project (scripts/build-wine.sh)." \
		'"GNU LGPL v2.1"' "$provides" "$requires"
	make_package wine_x86 "$pkg/wine_x86" "Wine's 32-bit x86 support (WoW64 with the Box64 emulator)" \
		"The i386 Windows side of Wine $wineVersion and Box64's wowbox64.dll (also as xtajit.dll), the x86 emulator WoW64 runs 32-bit x86 Windows programs with on arm64. Cross-built for the Raspberry Pi 4 by the haiku-pi project (scripts/build-wine.sh, scripts/build-box64.sh)." \
		'"GNU LGPL v2.1" "MIT"' "wine_x86=$wineVersion-$wineRevision" "haiku wine==$wineVersion-$wineRevision" \
		'"2018-2026 Sebastien Chevalier and the Box64 contributors"'
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
