#!/usr/bin/env bash
# build-gl-stack.sh — cross-build the Haiku arm64 OpenGL stack on this host and stage it for the Pi
# image (GPU design docs/design/gpu-v3d.md, stage 2):
#
#   libdrm    sources/libdrm    (branch rpi4: Haiku build fixes)
#   libglvnd  sources/libglvnd  (branch rpi4: EGL/GLES dispatch + HGL: libGL.so with BGLView)
#   Mesa      sources/mesa      (branch rpi4: v3d + softpipe, egl_haiku opens /dev/dri/renderD128)
#   gl-tests  tools/gl-tests    (gltri: headless GLES render + readback check; glview: BGLView window)
#
#   scripts/build-gl-stack.sh [--sysroot] [--reconfigure] [--only libdrm|libglvnd|mesa|gl-tests|stage]
#
# Uses tools/meson/haiku-arm64.cross and the sysroot of scripts/haiku-sysroot.sh (created when
# missing, recreated with --sysroot). Build dirs: artifacts/gl-build/<name>; each project is
# installed into the sysroot (DESTDIR, prefix /boot/system/non-packaged) so the next one finds it.
# Mesa builds under scripts/heavy-build.sh. --reconfigure wipes the meson configuration.
#
# Output: artifacts/gl-stack/non-packaged/ — the runtime files, stripped, laid out as they go into
# the image's /boot/system/non-packaged/ (scripts/mkimage-pi4.sh --add-tree DIR):
#   lib/                          libEGL.so.1 libGLESv2.so.2 libGL.so.1 (BGLView) libGLdispatch.so.0
#                                 libOpenGL.so.0 libGLESv1_CM.so.1 libdrm.so.2
#   add-ons/opengl/egl_vendor.d/  libEGL_mesa.so.0 + 50_mesa.json (libglvnd's EGL vendor search
#                                 path includes this directory)
#   bin/gltri bin/glview bin/retrace
# Shared-library symlinks are resolved: each library is a file named by its soname.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cross="$root/tools/meson/haiku-arm64.cross"
sysroot="$root/artifacts/sysroot-arm64"
build="$root/artifacts/gl-build"
stage="$root/artifacts/gl-stack/non-packaged"
tools="$root/sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku"
prefix=/boot/system/non-packaged
only="" newSysroot=0 reconfigure=0
while [ $# -gt 0 ]; do
	case "$1" in
	--sysroot) newSysroot=1; shift ;;
	--reconfigure) reconfigure=1; shift ;;
	--only) only="$2"; shift 2 ;;
	*) echo "build-gl-stack: unknown option $1" >&2; exit 2 ;;
	esac
done
want() { [ -z "$only" ] || [ "$only" = "$1" ]; }

if [ "$newSysroot" = 1 ] || [ ! -e "$sysroot/boot/system/develop/lib/libroot.so" ]; then
	"$root/scripts/haiku-sysroot.sh" --out "$sysroot"
fi

# meson_project NAME SOURCE [meson options...]: configure (once), build, install into the sysroot.
meson_project() {
	local name="$1" src="$2"; shift 2
	local dir="$build/$name"
	if [ "$reconfigure" = 1 ] || [ ! -f "$dir/build.ninja" ]; then
		rm -rf "$dir"
		meson setup "$dir" "$src" --cross-file "$cross" --prefix="$prefix" --libdir=lib \
			--buildtype=release -Db_ndebug=true "$@"
	fi
	if [ "$name" = mesa ]; then
		"$root/scripts/heavy-build.sh" -j 8 -- ninja -C "$dir" -j "{JOBS}"
	else
		ninja -C "$dir"
	fi
	DESTDIR="$sysroot" ninja -C "$dir" install > "$dir/install.log"
	echo "build-gl-stack: $name built and installed into the sysroot"
}

if want libdrm; then
	meson_project libdrm "$root/sources/libdrm" --includedir=develop/headers \
		-Dintel=disabled -Dradeon=disabled -Damdgpu=disabled -Dnouveau=disabled \
		-Dvmwgfx=disabled -Domap=disabled -Dexynos=disabled -Dfreedreno=disabled \
		-Dtegra=disabled -Dvc4=disabled -Detnaviv=disabled -Dcairo-tests=disabled \
		-Dman-pages=disabled -Dvalgrind=disabled -Dinstall-test-programs=false -Dudev=false \
		-Dtests=false
fi
if want libglvnd; then
	# as HaikuPorts' sys-libs/libglvnd recipe: headers under os/opengl
	meson_project libglvnd "$root/sources/libglvnd" --includedir=develop/headers/os/opengl \
		-Dx11=disabled -Dglx=disabled -Dhgl=true
	# and as its INSTALL(): the GL kit headers where Haiku code includes them from
	inc="$sysroot$prefix/develop/headers/os"
	mv -f "$inc/opengl/OpenGLKit.h" "$inc/OpenGLKit.h"
	mv -f "$inc/opengl/opengl/GLView.h" "$inc/opengl/GLView.h"
	rmdir "$inc/opengl/opengl"
fi
if want mesa; then
	meson_project mesa "$root/sources/mesa" --includedir=develop/headers/os/opengl \
		-Dplatforms=haiku -Degl=enabled -Dglvnd=enabled -Dglx=disabled -Dgbm=disabled \
		-Dgallium-drivers=v3d,softpipe -Dvulkan-drivers= -Dllvm=disabled \
		-Dgallium-rusticl=false -Dgallium-va=disabled -Dvideo-codecs= \
		-Dshader-cache=disabled -Dxmlconfig=disabled -Dexpat=disabled -Dzstd=disabled \
		-Dvalgrind=disabled -Dlibunwind=disabled -Dlmsensors=disabled -Dbuild-tests=false \
		-Dtools= -Dperfetto=false -Dspirv-tools=disabled
fi
if want gl-tests; then
	meson_project gl-tests "$root/tools/gl-tests"
fi

if want stage; then
	rm -rf "$stage"
	mkdir -p "$stage/lib" "$stage/add-ons/opengl/egl_vendor.d" "$stage/bin"
	src="$sysroot$prefix"
	# put FILE (a library, resolved through its symlinks) into DIR under its soname
	put_lib() {
		local file="$1" dir="$2" soname
		soname=$("$tools-readelf" -d "$file" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
		[ -n "$soname" ] || { echo "build-gl-stack: $file has no soname" >&2; exit 1; }
		cp -L "$file" "$dir/$soname"
		"$tools-strip" --strip-unneeded "$dir/$soname"
	}
	for l in libEGL.so libGLESv2.so libGL.so libGLdispatch.so libOpenGL.so libGLESv1_CM.so libdrm.so; do
		put_lib "$src/lib/$l" "$stage/lib"
	done
	put_lib "$src/lib/libEGL_mesa.so" "$stage/add-ons/opengl/egl_vendor.d"
	# the vendor file of HaikuPorts' mesa recipe (additional-files/50_mesa.json)
	cat > "$stage/add-ons/opengl/egl_vendor.d/50_mesa.json" <<-'JSON'
	{
	    "file_format_version" : "1.0.0",
	    "ICD" : {
	        "library_path" : "./libEGL_mesa.so.0"
	    }
	}
	JSON
	for b in gltri glview retrace; do
		cp "$src/bin/$b" "$stage/bin/$b"
		"$tools-strip" "$stage/bin/$b"
	done
	{
		echo "# GL stack staged by scripts/build-gl-stack.sh on $(date -u +%Y-%m-%dT%H:%MZ)"
		for r in libdrm libglvnd mesa; do
			printf '%s %s\n' "$r" "$(git -C "$root/sources/$r" describe --always --dirty --tags)"
		done
	} > "$stage/add-ons/opengl/gl-stack-versions.txt"
	echo "build-gl-stack: staged $(find "$stage" -type f | wc -l) files, $(du -sh "$stage" | cut -f1) in $stage"
	find "$stage" -type f -printf '  %P %s\n' | sort
fi
