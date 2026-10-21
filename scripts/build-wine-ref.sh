#!/usr/bin/env bash
# build-wine-ref.sh — a reference Wine for this x86-64 Linux host: the same Wine 11.0 as scripts/build-wine.sh,
# unpatched, with WoW64 for 32-bit programs (PE side: i386 and x86_64 by llvm-mingw) and the X11 driver, to run a
# Windows program here under a virtual X server (Xvfb) and compare with the Pi: a defect in both is Wine's or the
# program's; one only on the Pi is the port's (Box64, the Wayland stack, Haiku).
#
#   scripts/build-wine-ref.sh                         (needs scripts/build-wine.sh source: the archive, llvm-mingw)
#
# Host packages: the X11 development headers (libx11-dev, libxext-dev, libxrender-dev, libxrandr-dev,
# libxi-dev, libxfixes-dev, libxcursor-dev), libfreetype-dev; to run: xvfb (tools/wine-ref/run.sh).
# Output: artifacts/wine-ref/install (bin/wine, ~1 GB), not packaged.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
pristine="$root/sources/wine/wine-wine-11.0"
mingw="$root/sources/wine/llvm-mingw-20260826-ucrt-ubuntu-22.04-x86_64/bin"
out="$root/artifacts/wine-ref"
[ -d "$pristine" ] && [ -x "$mingw/i686-w64-mingw32-clang" ] || { echo "build-wine-ref: run scripts/build-wine.sh source first" >&2; exit 1; }

mkdir -p "$out/build"
(cd "$out/build" && PATH="$mingw:$PATH" "$pristine/configure" --prefix="$out/install" --enable-archs=i386,x86_64 \
	--with-x --without-wayland --without-gnutls --without-vulkan --without-pulse --without-alsa --without-oss \
	--without-cups --without-dbus --without-sane --without-gphoto --without-v4l2 --without-pcap --without-usb \
	--without-krb5 --without-netapi --without-gstreamer --without-ffmpeg --without-sdl --without-capi --without-opencl \
	--without-udev --without-unwind --without-inotify --disable-tests > configure.log 2>&1) \
	|| { tail -n 20 "$out/build/configure.log" >&2; exit 1; }
(cd "$out/build" && PATH="$mingw:$PATH" "$root/scripts/heavy-build.sh" -- make -j{JOBS} > build.log 2>&1) \
	|| { tail -n 30 "$out/build/build.log" >&2; exit 1; }
(cd "$out/build" && PATH="$mingw:$PATH" make install > install.log 2>&1) || { tail -n 20 "$out/build/install.log" >&2; exit 1; }
du -sh "$out/install"
