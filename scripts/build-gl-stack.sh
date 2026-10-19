#!/usr/bin/env bash
# build-gl-stack.sh — cross-build the Haiku arm64 OpenGL stack on this host and stage it for the Pi
# image (GPU design docs/design/gpu-v3d.md, stage 2):
#
#   libdrm    sources/libdrm    (branch rpi4: Haiku build fixes)
#   libglvnd  sources/libglvnd  (branch rpi4: EGL/GLES dispatch + HGL: libGL.so with BGLView)
#   Mesa      sources/mesa      (branch rpi4: v3d + softpipe, egl_haiku opens /dev/dri/renderD128)
#   GLU       glu-9.0.3 release (unchanged; fetched into artifacts/gl-build/dl, SHA-256 pinned)
#   vulkan    the Khronos Vulkan loader + headers 1.4.311 (HaikuPorts' sys-libs/vulkan recipe: same
#             release, its patches, plus patches/vulkan-loader; fetched into artifacts/gl-build/dl,
#             SHA-256 pinned)
#   gl-tests  tools/gl-tests    (gltri: headless GLES render + readback check; glview: BGLView window;
#                                vktest: headless Vulkan render/compute/queries; vkcube: Vulkan
#                                in a window)
#
#   scripts/build-gl-stack.sh [--sysroot] [--reconfigure]
#                             [--only libdrm|libglvnd|mesa|glu|vulkan|gl-tests|stage]
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
#   lib/libvulkan.so.1            the Vulkan loader; it finds drivers in the add-ons directories'
#   add-ons/vulkan/icd.d/         vulkan/icd.d: broadcom_icd.*.json names lib/libvulkan_broadcom.so (V3DV)
#   bin/gltri bin/glview bin/retrace bin/cursor-move bin/vktest bin/vkcube
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

# fetch URL FILE SHA256: download into $build/dl once, check the checksum
fetch() {
	local archive="$build/dl/$2"
	mkdir -p "$build/dl"
	[ -f "$archive" ] || curl -sSfL -o "$archive" "$1"
	echo "$3  $archive" | sha256sum -c --quiet
}

# cmake_project NAME SOURCE [cmake options...]: configure (once), build, install into the sysroot.
cmake_project() {
	local name="$1" src="$2"; shift 2
	local dir="$build/$name"
	if [ "$reconfigure" = 1 ] || [ ! -f "$dir/build.ninja" ]; then
		rm -rf "$dir"
		cmake -S "$src" -B "$dir" -G Ninja -DCMAKE_TOOLCHAIN_FILE="$root/tools/cmake/haiku-arm64.cmake" \
			-DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_BUILD_TYPE=Release "$@" > "$build/$name-configure.log"
	fi
	ninja -C "$dir"
	DESTDIR="$sysroot" ninja -C "$dir" install > "$dir/install.log"
	echo "build-gl-stack: $name built and installed into the sysroot"
}

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
		-Dgallium-drivers=v3d,softpipe -Dvulkan-drivers=broadcom -Dllvm=disabled \
		-Dgallium-rusticl=false -Dgallium-va=disabled -Dvideo-codecs= \
		-Dshader-cache=disabled -Dxmlconfig=disabled -Dexpat=disabled -Dzstd=disabled \
		-Dvalgrind=disabled -Dlibunwind=disabled -Dlmsensors=disabled -Dbuild-tests=false \
		-Dtools= -Dperfetto=false -Dspirv-tools=disabled \
		-Dvulkan-icd-dir="$prefix/add-ons/vulkan/icd.d"
fi
if want glu; then
	# headers in develop/headers/GL, as HaikuPorts' glu recipe and jam's glu build feature have them
	glu=glu-9.0.3
	fetch "https://archive.mesa3d.org/glu/$glu.tar.xz" $glu.tar.xz \
		bd43fe12f374b1192eb15fe20e45ff456b9bc26ab57f0eee919f96ca0f8a330f
	mkdir -p "$build/src"
	[ -d "$build/src/$glu" ] || tar -xf "$build/dl/$glu.tar.xz" -C "$build/src"
	meson_project glu "$build/src/$glu" --includedir=develop/headers -Dgl_provider=glvnd
fi
if want vulkan; then
	# The loader as HaikuPorts' sys-libs/vulkan recipe builds it (release, sources, patches: its
	# FindDirectory patch makes it look for drivers in <add-ons>/vulkan/icd.d, where Mesa's
	# -Dvulkan-icd-dir puts V3DV's), without X11/Wayland, against the matching headers.
	vk=1.4.311
	recipe="$root/sources/haikuports/sys-libs/vulkan"
	fetch "https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/v$vk.tar.gz" \
		Vulkan-Headers-$vk.tar.gz 7989c360b870bcc2de52b9fd626fd2ba7a212fe177ade3aa3a10b2bcb61f8689
	fetch "https://github.com/KhronosGroup/Vulkan-Loader/archive/refs/tags/v$vk.tar.gz" \
		Vulkan-Loader-$vk.tar.gz bcebd281753384a2b019a633e6a81dca0e75414f0c8ec49f56edfcda8020ec20
	mkdir -p "$build/src"
	[ -d "$build/src/Vulkan-Headers-$vk" ] || tar -xf "$build/dl/Vulkan-Headers-$vk.tar.gz" -C "$build/src"
	# the recipe's patchset, then ours (patches/vulkan-loader: the Haiku view surfaces of Mesa's WSI);
	# the source is unpacked again when the patches change
	loaderSrc="$build/src/Vulkan-Loader-$vk"
	loaderPatches=("$recipe/patches/vulkan-$vk.patchset" "$root"/patches/vulkan-loader/*.patch)
	patchSum=$(cat "${loaderPatches[@]}" | sha256sum | cut -d' ' -f1)
	if [ ! -d "$loaderSrc" ] || [ "$(cat "$loaderSrc/.patches" 2>/dev/null)" != "$patchSum" ]; then
		rm -rf "$loaderSrc"
		tar -xf "$build/dl/Vulkan-Loader-$vk.tar.gz" -C "$build/src"
		for p in "${loaderPatches[@]}"; do
			patch -s -p1 -d "$loaderSrc" < "$p"
		done
		echo "$patchSum" > "$loaderSrc/.patches"
	fi
	cmake_project vulkan-headers "$build/src/Vulkan-Headers-$vk" -DCMAKE_INSTALL_INCLUDEDIR=develop/headers
	cmake_project vulkan-loader "$build/src/Vulkan-Loader-$vk" -DCMAKE_INSTALL_INCLUDEDIR=develop/headers \
		-DBUILD_WSI_XCB_SUPPORT=OFF -DBUILD_WSI_XLIB_SUPPORT=OFF -DBUILD_WSI_XLIB_XRANDR_SUPPORT=OFF \
		-DBUILD_WSI_WAYLAND_SUPPORT=OFF -DBUILD_TESTS=OFF \
		-DVulkanHeaders_DIR="$sysroot$prefix/share/cmake/VulkanHeaders"
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
	for l in libEGL.so libGLESv2.so libGL.so libGLdispatch.so libOpenGL.so libGLESv1_CM.so libdrm.so \
			libvulkan.so libvulkan_broadcom.so; do
		put_lib "$src/lib/$l" "$stage/lib"
	done
	# V3DV's ICD file (the loader's search path, see "vulkan" above); it names the library by its
	# absolute path in lib/
	mkdir -p "$stage/add-ons/vulkan/icd.d"
	cp "$src/add-ons/vulkan/icd.d/"broadcom_icd.*.json "$stage/add-ons/vulkan/icd.d/"
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
	for b in gltri glview retrace cursor-move vktest vkcube; do
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
