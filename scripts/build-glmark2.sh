#!/usr/bin/env bash
# build-glmark2.sh — glmark2, the OpenGL (ES) 2.0 benchmark (github.com/glmark2/glmark2), for arm64 Haiku:
# glmark2-es2 (OpenGL ES 2.0) and glmark2 (OpenGL 2.1), both through EGL on Mesa (V3D on the Pi 4,
# softpipe elsewhere), each frame in a BWindow (patches/glmark2: a Haiku native state on Mesa's EGL
# "haiku" platform).
#
#   scripts/build-glmark2.sh [--package] [--revision N]
#
# Builds release 2023.01 (sha256-checked) with its meson build and tools/meson/haiku-arm64.cross
# (needs the sysroot of scripts/haiku-sysroot.sh with libjpeg and libpng; glmark2 carries its own EGL/GL
# headers and opens libEGL at run time) and
# stages it as a test tree:
#   artifacts/glmark2/non-packaged/{bin/glmark2-es2, bin/glmark2, data/glmark2/{models,shaders,textures},
#   documentation/man/man1}
# for scripts/mkimage-pi4.sh --add-tree (it lands in /boot/system/non-packaged). The programs look for
# their data in /boot/system/data/glmark2 (the package's); from the tree, pass
#   --data-path /boot/system/non-packaged/data/glmark2
# (tools/pi-tests/glmark2.sh picks whichever exists).
# --package also makes artifacts/packages/glmark2-2023.01-<N>-arm64.hpkg (default N = 1; the same files
# and the SGI notice in data/licenses; not published: scripts/publish-repo.sh does that).
#
# Run: glmark2-es2 [--size 800x600 | --fullscreen] [-b SCENE[:OPTION=VALUE...]]... [--data-path DIR];
# Escape, q or closing the window stops it. HAIKU_EGL_FPS=1 has Mesa print its presented frame rate.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tools="$root/sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku"
pkgtool="$root/sources/haiku/generated.arm64/objects/linux/x86_64/release/tools/package/package"
dl="$root/artifacts/downloads/glmark2"
work="$root/artifacts/glmark2"
stage="$work/non-packaged"
out="$root/artifacts/packages"

version=2023.01
sha256=8fece3fc323b643644a525be163dc4931a4189971eda1de8ad4c1712c5db3d67
package=false
revision=1
while [ $# -gt 0 ]; do
	case "$1" in
	--package) package=true; shift ;;
	--revision) revision="$2"; shift 2 ;;
	*) echo "build-glmark2: unknown option $1" >&2; exit 2 ;;
	esac
done
for p in meson ninja; do
	command -v "$p" > /dev/null || { echo "build-glmark2: $p missing on this host" >&2; exit 1; }
done

archive="$dl/glmark2-$version.tar.gz"
mkdir -p "$dl"
if [ ! -f "$archive" ]; then
	curl -fsSL -o "$archive.part" "https://github.com/glmark2/glmark2/archive/refs/tags/$version.tar.gz"
	mv "$archive.part" "$archive"
fi
echo "$sha256  $archive" | sha256sum -c --quiet - || { echo "build-glmark2: $archive: checksum mismatch" >&2; exit 1; }

rm -rf "$work/src" "$work/build" "$work/install" "$stage"
mkdir -p "$work/src"
tar -xzf "$archive" -C "$work/src" --strip-components=1
for p in "$root"/patches/glmark2/*.patch; do
	echo "build-glmark2: applying $(basename "$p")"
	patch -s -p1 -d "$work/src" < "$p"
done

meson setup "$work/build" "$work/src" --cross-file "$root/tools/meson/haiku-arm64.cross" \
	--buildtype=release --prefix=/boot/system --bindir=bin --datadir=data --mandir=documentation/man \
	-Dflavors=haiku-glesv2,haiku-gl -Ddata-path=/boot/system/data/glmark2 \
	> "$work/configure.log" 2>&1 || { tail -n 30 "$work/configure.log" >&2; exit 1; }
ninja -C "$work/build" > "$work/build.log" 2>&1 || { grep -E 'error|FAILED' "$work/build.log" | head -n 30 >&2; exit 1; }
echo "build-glmark2: compiler warnings: $(grep -c 'warning:' "$work/build.log" || true)"
DESTDIR="$work/install" meson install -C "$work/build" --no-rebuild > "$work/install.log"
installed="$work/install/boot/system"
for b in glmark2-es2 glmark2; do
	if "$tools-readelf" -d "$installed/bin/$b" | grep -q -E 'RPATH|RUNPATH'; then
		echo "build-glmark2: $b still has a run path" >&2
		exit 1
	fi
	"$tools-strip" "$installed/bin/$b"
done

mkdir -p "$stage"
cp -a "$installed/bin" "$installed/data" "$installed/documentation" "$stage/"
echo "build-glmark2: staged $stage ($(du -sh "$stage" | cut -f1)):" \
	"needs $("$tools-readelf" -d "$stage/bin/glmark2-es2" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' ')"

if $package; then
	pkg="$work/package"
	rm -rf "$pkg"
	mkdir -p "$pkg"
	cp -a "$installed/bin" "$installed/data" "$installed/documentation" "$pkg/"
	# the "ideas" scene's SGI notice (GPL v3 is one of Haiku's own licenses)
	mkdir -p "$pkg/data/licenses"
	cp "$work/src/COPYING.SGI" "$pkg/data/licenses/SGI Free Software License B v2.0"
	# EGL, GL and GLES are opened at run time (libEGL.so.1, libGLESv2.so.2, libGL.so.1: mesa)
	cat > "$pkg/.PackageInfo" <<-EOF
	name			glmark2
	version			$version-$revision
	architecture	arm64
	summary			"OpenGL (ES) 2.0 benchmark"
	description		"glmark2 renders a set of scenes (shading, texturing, buffers, effects, terrain, jellyfish...) and reports each one's frames per second and an overall score. glmark2-es2 uses OpenGL ES 2.0, glmark2 OpenGL 2.1, both through EGL. Run from Terminal, e.g. glmark2-es2 --size 800x600 or --fullscreen; glmark2-es2 --help lists the options. Built for the Raspberry Pi 4 by the haiku-pi project."
	packager		"haiku-pi build farm <build@haiku-pi.invalid>"
	vendor			"Haiku Project"
	licenses		{ "GNU GPL v3" "SGI Free Software License B v2.0" }
	copyrights		{ "2008 Ben Smith" "2010-2012 Linaro Limited" "2010-2023 glmark2 contributors" }
	provides {
		glmark2 = $version-$revision
		cmd:glmark2 = $version-$revision
		cmd:glmark2_es2 = $version-$revision
	}
	requires {
		haiku
		mesa
		lib:libjpeg
		lib:libpng16
		lib:libstdc++
		lib:libgcc_s
	}
	EOF
	file="$out/glmark2-$version-$revision-arm64.hpkg"
	mkdir -p "$out"
	rm -f "$out"/glmark2-*-arm64.hpkg
	"$pkgtool" create -q -z zstd -C "$pkg" -i "$pkg/.PackageInfo" "$file"
	rm -rf "$pkg"
	echo "build-glmark2: $file ($(stat -c %s "$file") bytes)"
fi
# intermediates (the configure/build logs stay)
rm -rf "$work/src" "$work/build" "$work/install"
