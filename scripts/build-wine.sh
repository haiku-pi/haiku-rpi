#!/usr/bin/env bash
# build-wine.sh — Wine 11.0 cross-built on this Linux host for Haiku arm64 (H15, docs/design/wine-x86.md):
# the Unix side with the Haiku arm64 cross compiler, the Windows (PE) side with llvm-mingw.
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
#   build      configure for aarch64-unknown-haiku (PE side: aarch64, and i386 for 32-bit x86 programs through
#              WoW64), with the Wayland window driver when scripts/build-wayland.sh has run, and make:
#              artifacts/wine/cross. FreeType (text: without it every font metric, and so every window's
#              caption and size, is garbage) from the headers of the 2.14 in the sysroot (scripts/build-firefox.sh);
#              Wine loads libfreetype.so.6 at run time, the image's own (app_server's 2.6.3). Sound:
#              winehaiku.drv (patches/wine/0002), a BSoundPlayer per stream into the system mixer; its C++
#              Media Kit shim (dlls/winehaiku.drv/haiku_player.cpp: Wine's makedep builds no C++) is compiled
#              here into a static library that configure links into winehaiku.so (HAIKU_AUDIO_LIBS)
#   install    make install into artifacts/wine/install (prefix /boot/system/non-packaged), bin/wine linked
#              to the loader, debug info stripped (~970 MB with i386; a prefix takes ~1 GB more: images need
#              -sHAIKU_IMAGE_SIZE=3500); the test
#              programs of tools/wine-tests (hello.c, ddtest.c, tone.c for arm64 and x86; click.c) in
#              data/wine-tests
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
	# neither it reports nothing and still enables the driver, which then fails to link)
	local display=(--without-wayland --disable-winewayland.drv)
	if [ -x "$root/artifacts/wayland-host/bin/wayland-scanner" ] \
		&& [ -f "$sysroot/boot/system/develop/lib/pkgconfig/wayland-client.pc" ]; then
		display=(--with-wayland WAYLAND_SCANNER="$root/artifacts/wayland-host/bin/wayland-scanner")
	fi
	# winehaiku.drv's Media Kit shim; hidden symbols: winehaiku.so exports only Wine's entry points
	local shim="$out/cross/haiku-audio"
	mkdir -p "$shim"
	rm -f "$shim/libwinehaiku_player.a"
	"$tools-g++" --sysroot="$sysroot" -O2 -fPIC -fvisibility=hidden -Wall -Wextra \
		-c "$src/dlls/winehaiku.drv/haiku_player.cpp" -o "$shim/haiku_player.o"
	"$tools-ar" rcs "$shim/libwinehaiku_player.a" "$shim/haiku_player.o"
	(cd "$out/cross" && PATH="$mingw:$PATH" PKG_CONFIG=pkg-config \
		PKG_CONFIG_LIBDIR="$sysroot/boot/system/develop/lib/pkgconfig:$sysroot/boot/system/data/pkgconfig" \
		PKG_CONFIG_SYSROOT_DIR="$sysroot" "$src/configure" --host=aarch64-unknown-haiku \
		--prefix=/boot/system/non-packaged --enable-archs=aarch64,i386 --with-wine-tools="$out/host-tools" \
		--without-x "${display[@]}" --without-gnutls \
		--without-vulkan --without-opengl --without-pulse --without-alsa --without-oss --without-cups \
		--without-dbus --without-sane --without-gphoto --without-v4l2 --without-pcap --without-usb \
		--without-krb5 --without-netapi --without-gstreamer --without-ffmpeg --without-sdl --without-capi \
		--without-opencl --without-udev --without-unwind --without-inotify --disable-tests \
		CC="$tools-gcc --sysroot=$sysroot" CXX="$tools-g++ --sysroot=$sysroot" LDFLAGS="-lnetwork" \
		FREETYPE_CFLAGS="-I$sysroot/boot/system/non-packaged/include/freetype2" \
		FREETYPE_LIBS="-L$sysroot/boot/system/non-packaged/lib -lfreetype" \
		HAIKU_AUDIO_LIBS="$shim/libwinehaiku_player.a -lmedia -lbe -lstdc++" \
		> configure.log 2>&1) || { tail -n 20 "$out/cross/configure.log" >&2; exit 1; }
	# configure's own last step (config.status, makedep) can fail after a zero exit of its checks
	grep -q 'could not create Makefile' "$out/cross/configure.log" \
		&& { tail -n 20 "$out/cross/configure.log" >&2; exit 1; }
	(cd "$out/cross" && PATH="$mingw:$PATH" "$root/scripts/heavy-build.sh" -- make -j{JOBS} > build.log 2>&1) \
		|| { tail -n 30 "$out/cross/build.log" >&2; exit 1; }
}

step_install() {
	local dest="$out/install" prefix="$out/install/boot/system/non-packaged"
	rm -rf "$dest"
	(cd "$out/cross" && PATH="$mingw:$PATH" make install DESTDIR="$dest" > install.log 2>&1) \
		|| { tail -n 20 "$out/cross/install.log" >&2; exit 1; }
	rm -rf "$prefix/include"
	ln -sf ../lib/wine/aarch64-unix/wine "$prefix/bin/wine"
	for f in "$prefix"/lib/wine/aarch64-unix/*; do "$tools-strip" --strip-debug "$f" 2> /dev/null || true; done
	find "$prefix/lib/wine/aarch64-windows" -type f ! -name '*.a' -print0 \
		| xargs -0 -n 50 "$mingw/llvm-strip" --strip-debug 2> /dev/null || true
	# Box64's x86 emulator for WoW64 (scripts/build-box64.sh), if built — also under the name WoW64 loads
	# by default on arm64, xtajit.dll: the first wineboot fills the prefix's 32-bit system directory by
	# running 32-bit rundll32, before any registry setting could name another emulator
	if [ -f "$root/artifacts/box64/wowbox64.dll" ]; then
		cp "$root/artifacts/box64/wowbox64.dll" "$prefix/lib/wine/aarch64-windows/"
		cp "$root/artifacts/box64/wowbox64.dll" "$prefix/lib/wine/aarch64-windows/xtajit.dll"
	fi
	mkdir -p "$prefix/data/wine-tests"
	"$mingw/aarch64-w64-mingw32-clang" -O2 -o "$prefix/data/wine-tests/hello-arm64.exe" \
		"$root/tools/wine-tests/hello.c"
	"$mingw/i686-w64-mingw32-clang" -O2 -o "$prefix/data/wine-tests/hello-x86.exe" \
		"$root/tools/wine-tests/hello.c"
	"$mingw/aarch64-w64-mingw32-clang" -O2 -o "$prefix/data/wine-tests/click.exe" "$root/tools/wine-tests/click.c"
	for a in aarch64:arm64 i686:x86; do
		"$mingw/${a%%:*}-w64-mingw32-clang" -O2 -o "$prefix/data/wine-tests/ddtest-${a#*:}.exe" \
			"$root/tools/wine-tests/ddtest.c" -lddraw -ldxguid
		"$mingw/${a%%:*}-w64-mingw32-clang" -O2 -o "$prefix/data/wine-tests/tone-${a#*:}.exe" \
			"$root/tools/wine-tests/tone.c" -lwinmm
	done
	du -sh "$prefix"
}

steps=(source tools build install)
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
