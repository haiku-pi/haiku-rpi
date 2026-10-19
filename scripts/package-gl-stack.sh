#!/usr/bin/env bash
# package-gl-stack.sh — turn the cross-built OpenGL stack (scripts/build-gl-stack.sh, installed into the
# sysroot's non-packaged/) into real packages, for the image and for jam's mesa/glu build features
# (GLTeapot, GLInfo, Haiku3d, the GL screen savers, libglut). Package farm stage 0,
# docs/design/package-farm-plan.md.
#
#   scripts/package-gl-stack.sh [--revision N]      (default 1)
#
# Output: artifacts/packages/{mesa,mesa_devel,glu,glu_devel}-<version>-<N>-arm64.hpkg
#   mesa        libdrm + libglvnd (libGL with BGLView, libEGL, libGLES*, libOpenGL) + Mesa's EGL vendor
#               library (v3d, softpipe) in add-ons/opengl/egl_vendor.d — one package, as jam's mesa
#               feature extracts only mesa and mesa_devel
#   mesa_devel  headers (develop/headers/os/opengl, libdrm), develop/lib symlinks, pkg-config files
#   glu, glu_devel  GLU 9.0.3
# The libraries are those build-gl-stack.sh stages (stripped, named by soname).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
revision=1
while [ $# -gt 0 ]; do
	case "$1" in
	--revision) revision="$2"; shift 2 ;;
	*) echo "package-gl-stack: unknown option $1" >&2; exit 2 ;;
	esac
done
gen="$root/sources/haiku/generated.arm64"
pkgtool="$gen/objects/linux/x86_64/release/tools/package/package"
tools="$gen/cross-tools-arm64/bin/aarch64-unknown-haiku"
np="$root/artifacts/sysroot-arm64/boot/system/non-packaged"
stage="$root/artifacts/gl-stack/non-packaged"
out="$root/artifacts/packages"
work="$out/build"
[ -f "$stage/lib/libGL.so.1" ] || { echo "package-gl-stack: run scripts/build-gl-stack.sh first" >&2; exit 1; }
[ -f "$np/lib/libGLU.so.1" ] || { echo "package-gl-stack: run scripts/build-gl-stack.sh --only glu first" >&2; exit 1; }
mesaVersion=$(cat "$root/sources/mesa/VERSION")
gluVersion=9.0.3
mkdir -p "$out"
rm -rf "$work"

# devel_link DIR LIB... — develop/lib/<name>.so -> ../../lib/<soname>, as HaikuPorts' fixDevelopLibDirReferences
devel_link() {
	local dir="$1"; shift
	mkdir -p "$dir/develop/lib"
	for soname in "$@"; do
		ln -s "../../lib/$soname" "$dir/develop/lib/${soname%%.so*}.so"
	done
}
# pkgconfig DIR FILE... — the files with the packaged paths
pkgconfig() {
	local dir="$1"; shift
	mkdir -p "$dir/develop/lib/pkgconfig"
	for f in "$@"; do
		sed -e 's|^prefix=/boot/system/non-packaged$|prefix=/boot/system|' \
			-e 's|^libdir=.*|libdir=${prefix}/develop/lib|' \
			"$np/develop/lib/pkgconfig/$f" > "$dir/develop/lib/pkgconfig/$f"
	done
}
# create NAME VERSION DIR — DIR/.PackageInfo must exist
create() {
	local name="$1" version="$2" dir="$3"
	local file="$out/$name-$version-$revision-arm64.hpkg"
	rm -f "$file"
	"$pkgtool" create -q -C "$dir" -i "$dir/.PackageInfo" "$file"
	rm "$dir/.PackageInfo"
	echo "package-gl-stack: $file ($(stat -c %s "$file") bytes)"
}
# NAME VERSION SUMMARY LICENSE PROVIDES REQUIRES (one item per line). The vendor is the HaikuPorts
# repository's: package_repo refuses a package of another vendor in it; the packager says who built it.
packageInfo() {
	cat <<-EOF
	name			$1
	version			$2-$revision
	architecture	arm64
	summary			"$3"
	description		"$3. Built for the Raspberry Pi 4 by the haiku-pi project."
	packager		"haiku-pi build farm <build@haiku-pi.invalid>"
	vendor			"Haiku Project"
	licenses		{ "$4" }
	copyrights		{ "The Mesa, libglvnd, libdrm and GLU authors" }
	provides {
	$5
	}
	requires {
	$6
	}
	EOF
}

# mesa
d="$work/mesa"
mkdir -p "$d/lib" "$d/add-ons/opengl" "$d/documentation/packages/mesa"
cp "$stage"/lib/* "$d/lib/"
cp -r "$stage/add-ons/opengl/egl_vendor.d" "$d/add-ons/opengl/"
cp "$stage/add-ons/opengl/gl-stack-versions.txt" "$d/documentation/packages/mesa/"
packageInfo mesa "$mesaVersion" "Mesa 3D graphics library with the V3D (Raspberry Pi 4) and softpipe drivers" MIT \
"	mesa = $mesaVersion-$revision compat >= 26
	lib:libGL = 1.0.0 compat >= 1
	lib:libEGL = 1.1.0 compat >= 1
	lib:libGLESv2 = 2.1.0 compat >= 2
	lib:libGLESv1_CM = 1.2.0 compat >= 1
	lib:libGLdispatch = 0.0.0 compat >= 0
	lib:libOpenGL = 0.0.0 compat >= 0
	lib:libdrm = 2.134.0 compat >= 2" \
"	haiku
	lib:libstdc++
	lib:libz" > "$d/.PackageInfo"
create mesa "$mesaVersion" "$d"

# mesa_devel
d="$work/mesa_devel"
mkdir -p "$d/develop/headers/os"
cp -r "$np/develop/headers/os/opengl" "$d/develop/headers/os/"
cp "$np/develop/headers/os/OpenGLKit.h" "$d/develop/headers/os/"
cp -r "$np/develop/headers/libdrm" "$np/develop/headers/xf86drm.h" "$np/develop/headers/xf86drmMode.h" \
	"$np/develop/headers/libsync.h" "$d/develop/headers/"
devel_link "$d" libGL.so.1 libEGL.so.1 libGLESv2.so.2 libGLESv1_CM.so.1 libGLdispatch.so.0 \
	libOpenGL.so.0 libdrm.so.2
pkgconfig "$d" gl.pc egl.pc glesv1_cm.pc glesv2.pc opengl.pc libglvnd.pc libdrm.pc
packageInfo mesa_devel "$mesaVersion" "Mesa 3D graphics library: development files" MIT \
"	mesa_devel = $mesaVersion-$revision compat >= 26
	devel:libGL = 1.0.0 compat >= 1
	devel:libEGL = 1.1.0 compat >= 1
	devel:libGLESv2 = 2.1.0 compat >= 2
	devel:libGLESv1_CM = 1.2.0 compat >= 1
	devel:libGLdispatch = 0.0.0 compat >= 0
	devel:libOpenGL = 0.0.0 compat >= 0
	devel:libdrm = 2.134.0 compat >= 2" \
"	mesa == $mesaVersion-$revision" > "$d/.PackageInfo"
create mesa_devel "$mesaVersion" "$d"

# glu
d="$work/glu"
mkdir -p "$d/lib"
"$tools-strip" --strip-unneeded -o "$d/lib/libGLU.so.1" "$np/lib/libGLU.so.1"
packageInfo glu "$gluVersion" "The OpenGL Utility library" MIT \
"	glu = $gluVersion-$revision compat >= 9
	lib:libGLU = 1.3.1 compat >= 1" \
"	haiku
	lib:libOpenGL
	lib:libstdc++" > "$d/.PackageInfo"
create glu "$gluVersion" "$d"

# glu_devel
d="$work/glu_devel"
mkdir -p "$d/develop/headers"
cp -r "$np/develop/headers/GL" "$d/develop/headers/"
devel_link "$d" libGLU.so.1
pkgconfig "$d" glu.pc
packageInfo glu_devel "$gluVersion" "The OpenGL Utility library: development files" \
	MIT \
"	glu_devel = $gluVersion-$revision compat >= 9
	devel:libGLU = 1.3.1 compat >= 1" \
"	glu == $gluVersion-$revision" > "$d/.PackageInfo"
create glu_devel "$gluVersion" "$d"
