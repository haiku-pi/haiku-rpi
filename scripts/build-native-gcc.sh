#!/usr/bin/env bash
# build-native-gcc.sh — cross-build the native GCC for Haiku arm64 (a compiler that runs on the Pi and
# compiles for it; H18 part 2, docs/design/native-gcc.md) and package it as HaikuPorts' sys-devel/gcc does:
#
#   gcc-V-N-arm64.hpkg          gcc, g++, cpp, cc, c++, gcc-ar/nm/ranlib, gcov*, lto-dump; cc1, cc1plus,
#                               lto1, collect2, the LTO plugin, g++-mapper-server; GCC's and libstdc++'s
#                               headers, crt files, libgcc.a/libgcc_eh.a/libgcov.a/libstdc++exp.a
#   gcc_fortran-V-N-arm64.hpkg  gfortran, f951, libgfortran (shared + static), the Fortran modules
#
#   scripts/build-native-gcc.sh [--only STEP]... [--version V] [--revision N] [--rev REV]
#       [--buildtools DIR] [--cross-tools DIR] [--generated DIR] [--work DIR] [--no-fortran] [--jobs N]
#   STEP: source sysroot xfortran configure build install package check clean (default: all, in order;
#         each step but check and clean is skipped when its stamp in the work directory exists; clean
#         keeps the logs in artifacts/native-gcc/ and deletes the work directory)
#
# Source: buildtools at REV (default c2213226f9, branch gcc16: GCC 16.2.0 with Haiku's changes; read with
# git archive, the checkout is not touched) and the gcc_syslibs patchset (patches/gcc_syslibs/
# gcc-16.2.0_*.patchset: limits.h, shared libgcc for libstdc++) — the source of the gcc_syslibs 16.2
# packages, so compiler, headers and runtime are one build of one tree.
#
# How: as scripts/build-gcc-syslibs.sh --full, a Canadian cross (build = this host, host = target =
# aarch64-unknown-haiku) with the cross tools of the main build (16.2) and a sysroot of jam's haiku and
# haiku_devel packages; HaikuPorts' configure options (prefix /boot/system/develop/tools, version-specific
# runtime libraries, posix threads, __cxa_atexit, LTO, the gcc4-compatible libstdc++ ABI, libssp, frame
# pointers). Differences to the recipe, each for a reason:
#   - gmp, mpfr, mpc, isl and zlib are the copies in the buildtools tree, linked statically: no
#     lib:libgmp/libmpfr/libmpc/libz requirements (those packages are not in our repository);
#   - no libsanitizer (its Haiku arm64 support is the recipe's separate patches), no jit, no Objective-C,
#     no GCC plugins (cc1 would export every symbol);
#   - the runtime libraries come from gcc_syslibs 16.2.0 (scripts/build-gcc-syslibs.sh --full, the same
#     source): the compiler's lib directory links to /boot/system/lib, as the recipe's does; libgfortran,
#     which our gcc_syslibs does not carry, is in gcc_fortran;
#   - Fortran needs a gfortran on the build host for libgfortran: step xfortran builds a cross
#     aarch64-unknown-haiku-gfortran (driver + f951 only; libgcc and crt files from the cross tools).
# GCC 16 needs two settings to build its programs for Haiku (docs/design/gcc16.md, step 2):
# gcc_cv_c_no_fpie=no gcc_cv_no_pie=no (Haiku links every executable -shared) and -lnetwork (socket()).
# __FILE__ and `gcc -v`'s "Configured with" are kept free of build-host paths.
#
# check: every ELF file's NEEDED libraries and undefined dynamic symbols resolve against haiku, gcc_syslibs
# 16.2 and the packages themselves; no build-host path in any file; the requirements have providers; the
# driver's built-in search paths are Haiku's (no sysroot).
#
# Output: artifacts/packages/gcc-V-N-arm64.hpkg (+ gcc_fortran); not published. The work directory
# (default artifacts/native-gcc-build) grows to ~4 GB; step clean deletes it. Extracted package trees are
# deleted with the build tools' rm_attrs, not rm: their attribute emulation keys attributes by inode, and a
# stale entry attaches itself to the next file with that inode (WEEK-2026-W43, 10-24).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
gen="$root/sources/haiku/generated.arm64"
crossTools=
triple=aarch64-unknown-haiku
gccRev=c2213226f9
portVersion=16.2.0_2026_11_01
revision=1
buildtools="$root/sources/buildtools"
work="$root/artifacts/native-gcc-build"
packages="$root/artifacts/packages"
fortran=true
jobs="$(nproc)"
only=()
while [ $# -gt 0 ]; do
	case "$1" in
	--only) only+=("$2"); shift 2 ;;
	--version) portVersion="$2"; shift 2 ;;
	--revision) revision="$2"; shift 2 ;;
	--rev) gccRev="$2"; shift 2 ;;
	--buildtools) buildtools="$(realpath "$2")"; shift 2 ;;
	--cross-tools) crossTools="$(realpath "$2")"; shift 2 ;;
	--generated) gen="$(realpath "$2")"; shift 2 ;;
	--work) work="$(realpath -m "$2")"; shift 2 ;;
	--no-fortran) fortran=false; shift ;;
	--jobs) jobs="$2"; shift 2 ;;
	*) echo "build-native-gcc: unknown option $1" >&2; exit 2 ;;
	esac
done
[ ${#only[@]} -gt 0 ] || only=(source sysroot xfortran configure build install package check clean)
want() { local n; for n in "${only[@]}"; do [ "$n" = "$1" ] && return 0; done; return 1; }
[ -n "$crossTools" ] || crossTools="$gen/cross-tools-arm64"
cross="$crossTools/bin"
pkgtool="$gen/objects/linux/x86_64/release/tools/package/package"
hostTools="$gen/objects/linux/x86_64/release/tools"
pkg() { LD_LIBRARY_PATH="$gen/objects/linux/lib" "$pkgtool" "$@"; }
rmAttrs() { LD_LIBRARY_PATH="$gen/objects/linux/lib" "$hostTools/rm_attrs" "$@"; }
gccVersion="${portVersion%%_*}"
languages=c,c++
$fortran && languages=c,c++,fortran
patchset="$(ls "$root/patches/gcc_syslibs/gcc-$gccVersion"_*.patchset 2>/dev/null | tail -n 1)"
syslibs="$gen/download/gcc_syslibs-$portVersion-1-arm64.hpkg"
syslibsDevel="$gen/download/gcc_syslibs_devel-$portVersion-1-arm64.hpkg"
haikuPkg="$gen/objects/haiku/arm64/packaging/packages/haiku.hpkg"
haikuDevel="$gen/objects/haiku/arm64/packaging/packages/haiku_devel.hpkg"
for f in "$cross/$triple-gcc" "$pkgtool" "$patchset" "$syslibs" "$syslibsDevel" "$haikuPkg" "$haikuDevel"; do
	[ -e "$f" ] || { echo "build-native-gcc: $f missing" >&2; exit 1; }
done
"$cross/$triple-gcc" --version | head -n 1 | grep -q " $gccVersion\$" \
	|| { echo "build-native-gcc: $cross/$triple-gcc is not GCC $gccVersion" >&2; exit 1; }
[ "$(git -C "$buildtools" show "$gccRev:gcc/gcc/BASE-VER")" = "$gccVersion" ] \
	|| { echo "build-native-gcc: buildtools $gccRev is not GCC $gccVersion" >&2; exit 1; }
freeGB() { df -BG --output=avail / | tail -n 1 | tr -d ' G'; }
needFree() { [ "$(freeGB)" -ge "$1" ] || { echo "build-native-gcc: only $(freeGB) GB free on / (want $1)" >&2; exit 1; }; }

src="$work/src/gcc" sysroot="$work/sysroot" obj="$work/obj" inst="$work/inst" xf="$work/xfortran"
prefix=/boot/system/develop/tools
gccLibDir="lib/gcc/$triple/$gccVersion"
mkdir -p "$work"
# neutral names for the build directories in __FILE__ (gcc's internal errors print it)
prefixMap="-ffile-prefix-map=$src=gcc-$gccVersion -ffile-prefix-map=$obj=gcc-$gccVersion-obj"

# 1. The source: buildtools' gcc/ at REV + the gcc_syslibs patchset (+ the recipe's config.sub copies)
if want source && [ ! -f "$work/src/.done" ]; then
	rm -rf "$work/src"
	git -C "$buildtools" archive --prefix=src/ "$gccRev" gcc | tar -x -C "$work"
	patch -s -p1 -d "$src" < "$patchset"
	for d in gmp mpfr mpc/build-aux isl/interface isl; do cp "$src/config.sub" "$src/$d/config.sub"; done
	touch "$work/src/.done"
	echo "build-native-gcc: source buildtools $gccRev + $(basename "$patchset")"
fi

# 2. The build sysroot: haiku + haiku_devel only (the compiler's own C++ headers and libraries come
#    from the cross tools; libstdc++ for its programs statically, below)
if want sysroot && [ ! -f "$sysroot/.done" ]; then
	[ ! -e "$sysroot" ] || rmAttrs -rf "$sysroot"
	mkdir -p "$sysroot/boot/system"
	for p in "$haikuPkg" "$haikuDevel"; do pkg extract -C "$sysroot/boot/system" "$p"; done
	rm -f "$sysroot/boot/system/.PackageInfo"
	touch "$sysroot/.done"
fi

# 3. The cross tools under their own names, with the sysroot, a plain -lgcc libgcc spec and the cross
#    compiler's static libstdc++ as libstdc++.a (as build-gcc-syslibs.sh: the native programs link
#    libstdc++ statically, libstdc++.so's own link must find nothing to add)
mkdir -p "$work/bin" "$work/lib"
printf '*libgcc:\n-lgcc\n\n' > "$work/libgcc.specs"
ln -sfn "$crossTools/$triple/lib/libstdc++-static.a" "$work/lib/libstdc++.a"
wrap() {	# name driver [specs]
	printf '#!/bin/sh\nexec %s --sysroot=%s %s -L%s "$@"\n' "$2" "$sysroot" "${3--specs=$work/libgcc.specs}" \
		"$work/lib" > "$work/bin/$triple-$1"
	chmod +x "$work/bin/$triple-$1"
}
for t in gcc g++ c++ cpp; do wrap $t "$cross/$triple-$t"; done
for t in ar as ld nm objcopy objdump ranlib readelf strip; do ln -sfn "$cross/$triple-$t" "$work/bin/$triple-$t"; done
# (libgfortran.so, the one library of this build that is shipped, so gets NEEDED libroot.so only; its two
# unwinder calls for backtraces resolve in libgcc_s.so.1, which libroot.so itself needs: step check
# resolves every file in its NEEDED closure)
$fortran && wrap gfortran "$xf/bin/$triple-gfortran"
export PATH="$work/bin:$PATH"

# 4. A cross gfortran for the build host (libgfortran is compiled with it): the same source, only the
#    driver and f951 (all-gcc); libgcc and the crt files are the cross tools'
if $fortran && want xfortran && [ ! -f "$xf/.done" ]; then
	needFree 17
	rm -rf "$xf" "$work/xfortran-obj"; mkdir -p "$work/xfortran-obj"
	(cd "$work/xfortran-obj" && "$src/configure" --target=$triple --prefix="$xf" \
		--with-sysroot="$sysroot" --with-as="$cross/$triple-as" --with-ld="$cross/$triple-ld" \
		--disable-nls --disable-shared --disable-multilib --disable-lto --disable-plugin \
		--enable-languages=c,fortran --enable-frame-pointer --enable-__cxa-atexit --enable-threads=posix \
		--with-default-libstdcxx-abi=gcc4-compatible) > "$work/xfortran-configure.log" 2>&1 \
		|| { tail -n 20 "$work/xfortran-configure.log" >&2; exit 1; }
	"$root/scripts/heavy-build.sh" -j "$jobs" --mem-per-job 2 -- \
		make -C "$work/xfortran-obj" -j{JOBS} all-gcc > "$work/xfortran-build.log" 2>&1 \
		|| { tail -n 30 "$work/xfortran-build.log" >&2; exit 1; }
	make -C "$work/xfortran-obj" install-gcc > "$work/xfortran-install.log" 2>&1 \
		|| { tail -n 30 "$work/xfortran-install.log" >&2; exit 1; }
	for f in "$crossTools/$gccLibDir"/*; do
		[ -e "$xf/$gccLibDir/$(basename "$f")" ] || ln -s "$f" "$xf/$gccLibDir/"
	done
	rm -rf "$work/xfortran-obj"
	echo 'program t; print *, "ok"; end program' > "$work/t.f90"
	"$work/bin/$triple-gfortran" -c -o "$work/t.o" "$work/t.f90"
	touch "$xf/.done"
	echo "build-native-gcc: cross $("$xf/bin/$triple-gfortran" --version | head -n 1)"
fi

# 5. Configure as the recipe (paths: Haiku's), the Canadian cross as build-gcc-syslibs.sh; with a
#    relative source directory, so that file names compiled into the programs and libraries (gfortran's
#    run-time error messages, which -ffile-prefix-map does not change) name no build-host directory
libgccPath="$obj/$triple/libgcc"
export ac_cv_c_bigendian=no gcc_cv_c_no_fpie=no gcc_cv_no_pie=no
if want configure && [ ! -f "$obj/.configured" ]; then
	needFree 18
	rm -rf "$obj"; mkdir -p "$obj"
	(cd "$obj" && CFLAGS="-O2 -U_FORTIFY_SOURCE -L$libgccPath $prefixMap" \
		CXXFLAGS="-O2 -L$libgccPath $prefixMap" LDFLAGS="-L$libgccPath -lnetwork" \
		CFLAGS_FOR_TARGET="-O2 $prefixMap" CXXFLAGS_FOR_TARGET="-O2 $prefixMap" \
		FCFLAGS_FOR_TARGET="-O2 $prefixMap" LDFLAGS_FOR_TARGET="-L$libgccPath -Wl,--hash-style=both" \
		"../src/gcc/configure" --build="$(sh "$src/config.guess")" --host=$triple --target=$triple \
		--prefix=$prefix --libexecdir=$prefix/lib \
		--mandir=/boot/system/documentation/man --docdir=/boot/system/documentation/packages/gcc \
		--enable-threads=posix --disable-nls --enable-shared --with-gnu-ld --with-gnu-as \
		--enable-version-specific-runtime-libs --enable-languages=$languages --enable-lto \
		--enable-frame-pointer --with-pkgversion="${portVersion#*_}" --enable-__cxa-atexit \
		--enable-checking=release --with-bug-url=http://dev.haiku-os.org/ \
		--with-default-libstdcxx-abi=gcc4-compatible --enable-libssp --disable-libsanitizer \
		--disable-plugin --disable-multilib --disable-libstdcxx-pch \
		--with-build-sysroot="$sysroot/") > "$work/configure.log" 2>&1 \
		|| { tail -n 20 "$work/configure.log" >&2; exit 1; }
	# `gcc -v` prints the configure line ("Configured with: ..."): without the build host's paths
	make -C "$obj" -j"$jobs" configure-gcc > "$work/configure-gcc.log" 2>&1 || { tail -n 20 "$work/configure-gcc.log" >&2; exit 1; }
	sed -i -e "s|\.\./src/gcc/configure|gcc-$gccVersion/configure|" -e "s|$work|/build|g" "$obj/gcc/configargs.h"
	if grep -qF -e "$root" -e "$HOME" "$obj/gcc/configargs.h"; then
		echo "build-native-gcc: host path left in configargs.h" >&2; exit 1
	fi
	touch "$obj/.configured"
fi

# 6. Build: everything, as the recipe's `make` (host programs, then the target libraries)
if want build && [ ! -f "$obj/.built" ]; then
	needFree 16
	"$root/scripts/heavy-build.sh" -j "$jobs" --mem-per-job 2 -- \
		make -C "$obj" -j{JOBS} > "$work/build.log" 2>&1 || { tail -n 40 "$work/build.log" >&2; exit 1; }
	echo "build-native-gcc: built; compiler warnings: $(grep -c 'warning:' "$work/build.log" || true)"
	touch "$obj/.built"
fi

# 7. Install into a staging tree, then lay it out as the recipe's INSTALL() does
if want install && [ ! -f "$inst/.done" ]; then
	rm -rf "$inst"
	make -C "$obj" DESTDIR="$inst" install > "$work/install.log" 2>&1 || { tail -n 30 "$work/install.log" >&2; exit 1; }
	touch "$inst/.done"
fi

stage="$work/stage"
gccTree="$stage/gcc" fortranTree="$stage/gcc_fortran"
if want package; then
	needFree 15
	[ ! -e "$stage" ] || rmAttrs -rf "$stage"
	mkdir -p "$gccTree" "$fortranTree"
	cp -a "$inst/boot/system/." "$gccTree/"
	t="$gccTree/develop/tools" L="$gccTree/develop/tools/$gccLibDir" F="$fortranTree/develop/tools/$gccLibDir"
	[ -x "$L/cc1" ] && [ -x "$L/cc1plus" ] || { echo "build-native-gcc: no cc1/cc1plus in $L" >&2; exit 1; }
	# the runtime's shared libraries are gcc_syslibs': links to /boot/system/lib in the compiler's lib
	# directory (as the recipe), except libgfortran's, which gcc_fortran carries; GCC 16's linker
	# scripts libatomic_asneeded.so and libgcc_s_asneeded.so stay
	syslibsFiles="$(pkg list -p "$syslibs" | sed -n 's|^lib/||p')"
	for f in "$L"/lib*.so*; do
		n="$(basename "$f")"
		case "$n" in
		libgfortran*|liblto_plugin*) continue ;;
		*-gdb.py) rm -f "$f"; continue ;;
		esac
		if printf '%s\n' "$syslibsFiles" | grep -qxF "$n"; then
			rm -f "$f"; ln -s "/boot/system/lib/$n" "$f"
		elif [ "$(head -c 4 "$f" | od -An -c | tr -d ' ')" = '177ELF' ]; then
			echo "build-native-gcc: $n is not in gcc_syslibs" >&2; exit 1
		fi
	done
	# static runtime libraries other than libgcc's, libstdc++exp and libatomic (GCC 16's
	# libatomic_asneeded.a links to it) go: the recipe keeps libgcc*.a and moves the others to
	# gcc_syslibs_devel, which has them; no .la files
	rm -f "$L"/*.la "$L"/libstdc++.a "$L"/libsupc++.a "$L"/libgomp.a "$L"/libssp.a \
		"$L"/libssp_nonshared.a "$L"/libstdc++fs.a
	rm -rf "$t/share" "$t/info" "$gccTree/data" "$gccTree/documentation/info" "$t/$triple" "$t/include"
	rm -rf "$t/lib/gcc/$triple/$gccVersion/plugin"
	# strip: programs and the LTO plugin entirely, static libraries and objects of their debug info
	strip="$cross/$triple-strip"
	while IFS= read -r -d '' f; do
		[ -L "$f" ] && continue
		case "$f" in
		*.a|*.o) "$strip" --strip-debug "$f"; continue ;;
		esac
		[ "$(head -c 4 "$f" | od -An -c | tr -d ' ')" = '177ELF' ] && "$strip" --strip-unneeded "$f"
	done < <(find "$gccTree" -type f -print0)
	# cc as the recipe; every program also in /boot/system/bin, and the triple-version driver (jit's)
	ln -sfn gcc "$t/bin/cc"
	mkdir -p "$gccTree/bin"
	for f in c++ cc cpp g++ gcc gcc-ar gcc-nm gcc-ranlib gcov gcov-dump gcov-tool gfortran lto-dump; do
		[ -e "$t/bin/$f" ] || [ -L "$t/bin/$f" ] || continue
		ln -sfn "../develop/tools/bin/$f" "$gccTree/bin/$f"
	done
	ln -sfn ../develop/tools/bin/gcc "$gccTree/bin/$triple-gcc-$gccVersion"

	# gcc_fortran: gfortran, f951, the modules, libgfortran (shared in lib/, as gcc_syslibs would)
	if $fortran; then
		mkdir -p "$fortranTree/bin" "$fortranTree/lib" "$fortranTree/develop/lib" \
			"$fortranTree/develop/tools/bin" "$fortranTree/develop/tools/$gccLibDir" \
			"$fortranTree/documentation/man/man1"
		mv "$gccTree/bin/gfortran" "$fortranTree/bin/"
		mv "$t/bin/gfortran" "$t/bin/$triple-gfortran" "$fortranTree/develop/tools/bin/"
		mv "$L/f951" "$L/finclude" "$L/libgfortran.spec" "$L/libgfortran.a" "$L"/libcaf_*.a "$F/"
		for f in "$L"/libgfortran.so*; do
			mv "$f" "$fortranTree/lib/"
			ln -s "/boot/system/lib/$(basename "$f")" "$F/$(basename "$f")"
			ln -s "../../lib/$(basename "$f")" "$fortranTree/develop/lib/$(basename "$f")"
		done
		[ -f "$gccTree/documentation/man/man1/gfortran.1" ] && mv "$gccTree/documentation/man/man1/gfortran.1" "$fortranTree/documentation/man/man1/"
	fi
	# the files GCC installs for a sanitizer/jit/objc build are absent; none of ours left behind?
	leftover="$(find "$gccTree" "$fortranTree" -name '*.la' -o -name '*gdb.py' | head -n 5)"
	[ -z "$leftover" ] || { echo "build-native-gcc: left over: $leftover" >&2; exit 1; }

	# HaikuPorts disables ASLR for the compiler (precompiled headers are mapped at a fixed address):
	# SYS:ENV DISABLE_ASLR=1 on the drivers and the compiler proper (the build tools' attribute
	# emulation; its entries are removed again after packaging, they are keyed by inode)
	addattr() { LD_LIBRARY_PATH="$gen/objects/linux/lib" "$hostTools/addattr/addattr" "$@"; }
	aslrFiles=()
	for f in "$t"/bin/* "$fortranTree"/develop/tools/bin/* "$L"/{cc1,cc1plus,collect2,lto1,lto-wrapper,g++-mapper-server} "$F/f951"; do
		[ -f "$f" ] && [ ! -L "$f" ] && aslrFiles+=("$f")
	done
	for f in "${aslrFiles[@]}"; do addattr -t string SYS:ENV DISABLE_ASLR=1 "$f"; done

	packager='"haiku-pi build farm <build@haiku-pi.invalid>"'
	common() {
		cat <<-EOF
		version			$portVersion-$revision
		architecture		arm64
		packager		$packager
		vendor			"Haiku Project"
		licenses {
			"GNU GPL v3"
			"GNU LGPL v3"
		}
		copyrights {
			"1988-2026 Free Software Foundation, Inc."
		}
		urls {
			"https://gcc.gnu.org/"
		}
		source-urls {
			"https://github.com/haiku-pi/buildtools/tree/$(git -C "$buildtools" rev-parse "$gccRev")"
		}
		EOF
	}
	cmdV="$portVersion compat >= 7"
	{ echo "name			gcc"
		echo "summary			\"C/C++ compiler for target $triple\""
		echo 'description		"The standard compiler for non-legacy Haiku (i.e. for all architectures other than x86_gcc2). GCC '"$gccVersion"' with C, C++ and LTO; built natively for Haiku arm64 (the haiku-pi port)."'
		common
		echo 'provides {'
		echo "	gcc = $cmdV"
		for c in c++ cc cpp g++ gcc gcc_ar gcc_nm gcc_ranlib gcov gcov_dump gcov_tool lto_dump; do
			echo "	cmd:$c = $cmdV"
		done
		echo "	cmd:${triple//-/_}_gcc_$gccVersion = $portVersion"
		echo '}'
		cat <<-EOF
		requires {
			haiku
			gcc_syslibs == $portVersion base
			gcc_syslibs_devel == $portVersion
			binutils >= 2.46.1
		}
		EOF
	} > "$gccTree/.PackageInfo"
	stdcxxLib="$(pkg list -i "$syslibs" | sed -n 's/^\tprovides: lib:libstdc++ = \([0-9.]*\).*/\1/p')"
	if $fortran; then
		gfVersion="$(cd "$fortranTree/lib" && ls libgfortran.so.*.*.* | sed 's/^libgfortran\.so\.//')"
		{ echo "name			gcc_fortran"
			echo 'summary			"Fortran compiler (gfortran) and runtime for GCC"'
			echo 'description		"gfortran and f951, the Fortran front end of GCC '"$gccVersion"', the Fortran intrinsic modules and the libgfortran runtime (shared and static; HaikuPorts ships the shared library in gcc_syslibs)."'
			common
			cat <<-EOF
			provides {
				gcc_fortran = $cmdV
				cmd:gfortran = $cmdV
				lib:libgfortran = $gfVersion compat >= ${gfVersion%%.*}
				devel:libgfortran = $gfVersion compat >= ${gfVersion%%.*}
				devel:libcaf_single = $gfVersion compat >= ${gfVersion%%.*}
			}
			requires {
				haiku
				gcc == $portVersion base
				gcc_syslibs == $portVersion
			}
			EOF
		} > "$fortranTree/.PackageInfo"
	fi
	mkdir -p "$packages"
	names=(gcc)
	$fortran && names+=(gcc_fortran)
	for n in "${names[@]}"; do
		file="$packages/$n-$portVersion-$revision-arm64.hpkg"
		rm -f "$file"
		pkg create -q -C "$stage/$n" -i "$stage/$n/.PackageInfo" "$file"
		echo "build-native-gcc: $file ($(stat -c %s "$file") bytes)"
	done
	rmAttrs -rf "$stage"	# the files and their emulated attributes
	echo "build-native-gcc: SYS:ENV DISABLE_ASLR=1 on $(pkg list -a "$packages/gcc-$portVersion-$revision-arm64.hpkg" \
		| grep -c '<SYS:ENV') files of gcc (${#aslrFiles[@]} set)"
	echo "build-native-gcc: libstdc++ of gcc_syslibs: $stdcxxLib"
fi

# 8. Check the packages as the Pi gets them
if want check; then
	chk="$work/check"
	[ ! -e "$chk" ] || rmAttrs -rf "$chk"
	mkdir -p "$chk/x" "$chk/sys" "$chk/syms"
	names=(gcc)
	[ -f "$packages/gcc_fortran-$portVersion-$revision-arm64.hpkg" ] && names+=(gcc_fortran)
	for n in "${names[@]}"; do pkg extract -C "$chk/x" "$packages/$n-$portVersion-$revision-arm64.hpkg"; done
	for p in "$haikuPkg" "$syslibs"; do pkg extract -C "$chk/sys" "$p"; done
	re="$cross/$triple-readelf" nm="$cross/$triple-nm"
	isElf() { [ "$(head -c 4 "$1" | od -An -c | tr -d ' ')" = '177ELF' ]; }
	needed() { "$re" -d "$1" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'; }
	# the system's libraries (haiku, gcc_syslibs) and the packages' own (libgfortran), by SONAME
	declare -A libFile=()
	while IFS= read -r -d '' l; do
		isElf "$l" || continue
		so="$("$re" -d "$l" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')"
		libFile[${so:-$(basename "$l")}]="$l"
		"$nm" -D --defined-only "$l" | awk '{print $NF}' | sed 's/@.*//' | LC_ALL=C sort -u \
			> "$chk/syms/${so:-$(basename "$l")}"
	done < <(find "$chk/sys/lib" "$chk/x/lib" -maxdepth 1 -name '*.so*' -type f -print0 2>/dev/null)
	# each file's undefined symbols must be defined in its own NEEDED closure (as the runtime loader
	# finds them for a program that does not happen to load the library some other way)
	elves=0 bad=0
	while IFS= read -r -d '' f; do
		isElf "$f" || continue
		[ "$("$re" -h "$f" | sed -n 's/^ *Type: *\([A-Z]*\).*/\1/p')" = DYN ] || continue	# objects, archives: linked by user programs
		elves=$((elves + 1))
		declare -A seen=()
		queue=($(needed "$f")) closure=()
		while [ ${#queue[@]} -gt 0 ]; do
			n="${queue[0]}"; queue=("${queue[@]:1}")
			[ -z "${seen[$n]:-}" ] || continue
			seen[$n]=1
			[ -n "${libFile[$n]:-}" ] || { echo "build-native-gcc: ${f#"$chk/x/"} needs $n, which the system lacks" >&2; bad=1; continue; }
			closure+=("$chk/syms/$n")
			queue+=($(needed "${libFile[$n]}"))
		done
		unset seen
		missing="$("$nm" -D --undefined-only "$f" | awk '$1 == "U" {print $2}' | sed 's/@.*//' | LC_ALL=C sort -u \
			| LC_ALL=C comm -23 - <(cat /dev/null "${closure[@]}" | LC_ALL=C sort -u))"
		[ -z "$missing" ] || { echo "build-native-gcc: ${f#"$chk/x/"}: not defined by its NEEDED libraries: $missing" >&2; bad=1; }
		echo "  ${f#"$chk/x/"}: NEEDED $(needed "$f" | tr '\n' ' ')" >> "$chk/needed.txt"
	done < <(find "$chk/x" -type f -print0)
	[ $bad = 0 ] || exit 1
	echo "build-native-gcc: $elves programs/libraries, every NEEDED library present, every symbol defined in its NEEDED closure"
	sed 's/.*: NEEDED //' "$chk/needed.txt" | sort | uniq -c | sed 's/^/  NEEDED: /'
	[ -x "$chk/x/develop/tools/$gccLibDir/cc1" ] && [ -x "$chk/x/develop/tools/$gccLibDir/cc1plus" ] \
		|| { echo "build-native-gcc: cc1/cc1plus missing" >&2; exit 1; }
	leaks="$(grep -rlaF -e "$root" -e "$HOME/" -e "$work" "$chk/x" || true)"
	[ -z "$leaks" ] || { echo "build-native-gcc: host paths in: $leaks" >&2; exit 1; }
	echo "build-native-gcc: no build-host path in the packaged files"
	# the driver's built-in paths (strings in the driver and cc1): Haiku's, no sysroot
	# (grep on saved files: grep -q at the end of a pipe trips pipefail)
	strings -a "$chk/x/develop/tools/bin/gcc" > "$chk/driver.txt"
	strings -a "$chk/x/develop/tools/$gccLibDir/cc1" > "$chk/cc1.txt"
	for s in /boot/system/develop/lib/ /boot/system/non-packaged/develop/lib/ \
		"/boot/system/develop/tools/lib/gcc/"; do
		grep -qxF "$s" "$chk/driver.txt" || { echo "build-native-gcc: the driver lacks $s" >&2; exit 1; }
	done
	for s in /boot/system/develop/headers/posix /boot/system/develop/headers \
		"/boot/system/develop/tools/lib/gcc/$triple/$gccVersion/include/c++"; do
		grep -qxF "$s" "$chk/cc1.txt" || { echo "build-native-gcc: cc1 lacks $s" >&2; exit 1; }
	done
	! grep -q 'TARGET_SYSTEM_ROOT\|--with-sysroot' "$chk/driver.txt" || { echo "build-native-gcc: the driver has a sysroot" >&2; exit 1; }
	echo "build-native-gcc: built-in paths: libraries /boot/system/develop/lib/ (+ non-packaged), headers /boot/system/develop/headers/..., C++ headers in the compiler's directory, no sysroot"
	# every requirement has a provider among our packages, the image build's and haiku
	provided="$chk/provided.txt"
	for f in "$packages"/*.hpkg "$gen"/download/*.hpkg "$haikuPkg"; do
		pkg list -i "$f" | sed -n 's/^\tprovides: \([^ =<>]*\).*/\1/p; s/^\tname: \(.*\)/\1/p'
	done | LC_ALL=C sort -u > "$provided"
	for n in "${names[@]}"; do
		f="$packages/$n-$portVersion-$revision-arm64.hpkg"
		unresolved="$(pkg list -i "$f" | sed -n 's/^\trequires: \([^ =<>]*\).*/\1/p' | LC_ALL=C sort -u \
			| LC_ALL=C comm -23 - "$provided")"
		[ -z "$unresolved" ] || { echo "build-native-gcc: $n requires what nothing provides: $unresolved" >&2; exit 1; }
		echo "== $(basename "$f") ($(stat -c %s "$f") bytes)"
		pkg list -i "$f" | sed -n 's/^\t\(provides\|requires\): /  \1 /p'
	done
	echo "build-native-gcc: every requirement has a provider"
	rmAttrs -rf "$chk"
fi

# 9. Clean: the logs to artifacts/native-gcc/, the work directory away
if want clean; then
	mkdir -p "$root/artifacts/native-gcc"
	for l in configure.log configure-gcc.log build.log install.log xfortran-configure.log xfortran-build.log; do
		[ ! -f "$work/$l" ] || cp "$work/$l" "$root/artifacts/native-gcc/"
	done
	rmAttrs -rf "$work"
	echo "build-native-gcc: $work deleted (logs in artifacts/native-gcc/)"
fi
