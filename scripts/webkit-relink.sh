#!/usr/bin/env bash
# webkit-relink.sh — rebuild libWebKitLegacy.so from the existing HaikuWebKit build tree
# (artifacts/cross-ports/haikuwebkit-1.10.0, scripts/build-webkit.sh) after a change to a few source files,
# without running ninja there: that tree was compiled by GCC 13.3, its build.ninja is older than
# tools/cmake/haiku-arm64.cmake, and the sysroot no longer holds WebKit's dependencies, so ninja would re-run
# CMake and rebuild everything (hours) with today's GCC 16.2. Instead: the named objects are compiled with
# ninja's own command lines (ninja -t commands) by today's cross compiler, the dependencies' headers and
# libraries come from their packages in artifacts/packages (extracted once into a private directory), and
# libWebKitLegacy.so.1.10.0 is linked with ninja's link line, the new objects in place of the old ones.
# The result is a mixed 13.3/16.2 link: good for tests, not for a release (that is a full build-webkit.sh).
# Since WP2 (2026-11-22) the tree is a full GCC 16.2 build against the private sysroot artifacts/sysroot-webkit:
# while that sysroot exists, `WEBKIT_SYSROOT=$PWD/artifacts/sysroot-webkit scripts/build-webkit.sh webkit_build`
# recompiles only what changed, and this script is not needed.
#
#   scripts/webkit-relink.sh OUTDIR SOURCE...
#
# SOURCE: paths below the tree's src/Source/ that are compiled on their own (not unified), e.g.
#   WebCore/platform/graphics/haiku/MediaPlayerPrivateHaiku.cpp WebKitLegacy/haiku/API/WebPage.cpp
# Output: OUTDIR/libWebKitLegacy.so.1.10.0 (unstripped, as the package's), OUTDIR/obj/*.o, OUTDIR/relink.log.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
wk="$root/artifacts/cross-ports/haikuwebkit-1.10.0"
build="$wk/build"
sysroot="$root/artifacts/sysroot-arm64"
deps="$wk/deps-relink"
out="${1:?usage: webkit-relink.sh OUTDIR SOURCE...}"
shift
[ $# -gt 0 ] || { echo "webkit-relink: no SOURCE" >&2; exit 2; }
mkdir -p "$out/obj"
out="$(cd "$out" && pwd)"
log="$out/relink.log"
: > "$log"

# the dependencies' packages (runtime + devel), extracted once
if [ ! -f "$deps/.done" ]; then
	pkgtool="$root/sources/haiku/generated.arm64/objects/linux/x86_64/release/tools/package/package"
	export LD_LIBRARY_PATH="$root/sources/haiku/generated.arm64/objects/linux/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
	rm -rf "$deps"
	mkdir -p "$deps"
	for p in icu74 brotli curl dav1d lcms libavif1.0 libexecinfo libiconv libjpeg_turbo libpng16 libpsl libwebp \
			libxml2 libxslt openssl3 sqlite woff2; do
		for s in "" _devel; do
			f=$(ls "$root"/artifacts/packages/"$p$s"-[0-9]*-arm64.hpkg 2> /dev/null | sort -V | tail -n 1)
			[ -n "$f" ] || { [ -z "$s" ] && { echo "webkit-relink: no package $p" >&2; exit 1; }; continue; }
			"$pkgtool" extract -C "$deps" "$f"
		done
	done
	touch "$deps/.done"
fi

np="$sysroot/boot/system/non-packaged"
# rewrite: the sysroot's non-packaged headers/libraries -> the extracted packages'
# (the libraries only where a package has them: libGLESv2 is the sysroot's), and ICU from its package
fix_paths() {
	local args=(-e "s|$np/include|$deps/develop/headers|g"
		-e "s|$sysroot/boot/system/develop/lib/\(libicu[a-z0-9]*\.so\)|$deps/develop/lib/\1|g") l
	for l in "$deps"/develop/lib/lib*.so; do
		args+=(-e "s|$np/lib/$(basename "$l")|$l|g")
	done
	sed "${args[@]}"
}

cd "$build"
newObjs=()
for src in "$@"; do
	[ -f "$wk/src/Source/$src" ] || { echo "webkit-relink: no $wk/src/Source/$src" >&2; exit 1; }
	target=$(grep -o "^build [^:]*/${src#*/}\.o:" build.ninja | head -n 1 | sed 's/^build \(.*\):$/\1/')
	[ -n "$target" ] || { echo "webkit-relink: $src is not compiled on its own (unified?)" >&2; exit 1; }
	obj="$out/obj/$(basename "$src" .cpp).o"
	cmd=$(ninja -t commands "$target" | tail -n 1 | fix_paths \
		| sed -e "s| -MD -MT [^ ]* -MF [^ ]* -o [^ ]* | -o $obj |" \
			-e "s|-g++ --sysroot=\([^ ]*\) |-g++ --sysroot=\1 -isystem $deps/develop/headers -fdiagnostics-color=never |" \
			-e "s| -Winvalid-pch | -Wno-invalid-pch |")
	echo "webkit-relink: compiling $src" | tee -a "$log"
	eval "$cmd" >> "$log" 2>&1 || { grep -a -E "error|Error" "$log" | head -n 30 >&2; exit 1; }
	newObjs+=("$target=$obj")
done

# the link line: new objects in place of the old ones (WebKitLegacy's own objects are on it by path; a WebCore
# object is put in front of libWebCore.a, so that the archive's old member is not pulled in)
lib=lib/libWebKitLegacy.so.1.10.0
cmd=$(ninja -t commands "$lib" | tail -n 1 | fix_paths \
	| sed -e "s|^: && ||" -e "s| && :$||" -e "s| -o $lib | -o $out/libWebKitLegacy.so.1.10.0 |" \
		-e "s| -Wl,-rpath,[^ ]*| -L$deps/develop/lib -Wl,-rpath-link,$deps/lib:$build/lib|")
front=""
for pair in "${newObjs[@]}"; do
	old=${pair%%=*} new=${pair#*=}
	if [[ " $cmd " == *" $old "* ]]; then
		cmd=${cmd/ $old / $new }
	else
		front="$front $new"
	fi
done
[ -z "$front" ] || cmd=${cmd/ lib\/libWebCore.a / $front lib/libWebCore.a }
echo "webkit-relink: linking" | tee -a "$log"
eval "$cmd" >> "$log" 2>&1 || { grep -a -E "error|undefined|multiple definition" "$log" | head -n 30 >&2; exit 1; }
echo "webkit-relink: warnings: $(grep -a -c 'warning:' "$log" || true)"
ls -l "$out/libWebKitLegacy.so.1.10.0"
