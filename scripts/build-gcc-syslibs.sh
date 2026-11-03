#!/usr/bin/env bash
# build-gcc-syslibs.sh — build the gcc_syslibs package (libstdc++.so.6, libgcc_s.so.1, ...) with a GNU hash
# table and libstdc++ with -Bsymbolic-functions: either rebuild only those two libraries of the package we
# ship (default), or (--full) both packages, gcc_syslibs and gcc_syslibs_devel, from another GCC.
#
#   scripts/build-gcc-syslibs.sh [--revision N] [--work DIR] [--no-symbolic] [--jobs N]
#   scripts/build-gcc-syslibs.sh --full --rev REV --version V [--patchset FILE] [--buildtools DIR]
#       [--cross-tools DIR] [--generated DIR] [--out DIR] [--revision N] [--work DIR] [--no-symbolic]
#       [--jobs N]
#
# Our gcc_syslibs is upstream's arm64 bootstrap package (gcc_syslibs-13.3.0_2026_03_29_bootstrap-1,
# from Haiku's build-packages server, scripts/fetch-build-packages.sh), built by haikuports.cross's
# sys-devel/gcc_bootstrap recipe: a Canadian cross (build = this host, host = target = arm64 Haiku) of
# buildtools 850b24947d with the recipe's patchset (patches/gcc_syslibs), its target libraries compiled
# by the cross compiler. Its shared libraries have only a SysV .hash table; the runtime loader reads
# DT_GNU_HASH, and everything jam links has had both since 10-24 (haiku 91012322ef).
#
# This repeats that build — same source tree, patchset, configure arguments, our jam-built cross tools —
# with LDFLAGS_FOR_TARGET=-Wl,--hash-style=both, and relinks libstdc++.so with -Bsymbolic-functions and a
# dynamic list (--no-symbolic leaves that out): its calls to functions only it defines bind locally; data,
# operator new/delete (--dynamic-list-cpp-new) and every function another system library also exports
# stay interposable. That last part matters: libroot carries its own copy of libsupc++ (__cxa_throw,
# __cxa_get_globals, the exception classes, ...) and libstdc++ exports the long double math stubs
# libroot has too; today the first definition in a process's lookup order serves every caller, and with
# a locally bound copy libstdc++ could use a different exception-globals block than the program.
# The cross compiler's libgcc spec
# is overridden to plain `-lgcc`, as in upstream's --disable-shared cross compiler, so libstdc++.so keeps
# NEEDED = libroot.so only (ours links libgcc_s as needed since buildtools 85273c9ba6).
#
# Default mode: only libstdc++.so.6.0.32 and libgcc_s.so.1 are replaced; every other file of the package
# stays byte-identical, and gcc_syslibs_devel (static libraries, headers) does not change. Checks (and
# fails on a difference): SONAME, NEEDED and the exported dynamic symbols (name@version, type, binding,
# visibility) and imports of each new library against the old one; .gnu.hash present.
# Output: artifacts/gcc-syslibs/gcc_syslibs-13.3.0_2026_03_29_bootstrap-<N>-arm64.hpkg (default N = 2) —
# deliberately not in artifacts/packages, which scripts/publish-repo.sh publishes — and the two libraries
# (both variants: hash only, hash + symbolic) with the comparison diffs in <work>/out.
#
# --full: what the recipe's BUILD() and INSTALL() produce for the two packages, from buildtools at REV (a
# commit of --buildtools, default sources/buildtools; e.g. the gcc16 branch) with --patchset (default
# patches/gcc_syslibs/gcc-<V without its date>*.patchset; "none" for none), compiled by the cross tools in
# --cross-tools (the matching GCC; default the main build's): libgcc (+ libgcc_s), libstdc++, libsupc++,
# libatomic, libgomp, libssp, the kernel (-D_KERNEL_MODE) and boot loader variants of libgcc/libgcc_eh/
# libsupc++ (no threads, no TLS), and GCC's and libstdc++'s headers. The sysroot is the haiku and
# haiku_devel packages of --generated (default the main build). Version V (e.g. 16.2.0_2026_11_01), package
# revision N (default 1). Checks against the shipped 13.3 libraries: SONAME and NEEDED unchanged, every
# name@version they export still exported (so what was linked against them keeps working), .gnu.hash.
# Output: gcc_syslibs-V-N-arm64.hpkg and gcc_syslibs_devel-V-N-arm64.hpkg in --out (default
# artifacts/gcc-syslibs).
#
# The work directory (default artifacts/gcc-syslibs-build) takes ~2 GB (--full: ~4 GB); delete it
# afterwards. Staging a package into the image build and the repository is manual (AGENTS.md "A package
# revision bump has three parts").
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
gen="$root/sources/haiku/generated.arm64"
crossTools=
triple=aarch64-unknown-haiku

gccRev=850b24947d5c95b68d2dc6c75844fd7acc462941    # the gcc_bootstrap recipe's srcGitRev
portVersion=13.3.0_2026_03_29
buildtools="$root/sources/buildtools"
patchset=
revision=
work="$root/artifacts/gcc-syslibs-build"
outDir="$root/artifacts/gcc-syslibs"
symbolic=true
full=false
jobs="$(nproc)"
while [ $# -gt 0 ]; do
	case "$1" in
	--full) full=true; shift ;;
	--rev) gccRev="$2"; shift 2 ;;
	--version) portVersion="$2"; shift 2 ;;
	--patchset) patchset="$2"; shift 2 ;;
	--buildtools) buildtools="$(realpath "$2")"; shift 2 ;;
	--cross-tools) crossTools="$(realpath "$2")"; shift 2 ;;
	--generated) gen="$(realpath "$2")"; shift 2 ;;
	--out) outDir="$(realpath -m "$2")"; shift 2 ;;
	--revision) revision="$2"; shift 2 ;;
	--work) work="$(realpath -m "$2")"; shift 2 ;;
	--no-symbolic) symbolic=false; shift ;;
	--jobs) jobs="$2"; shift 2 ;;
	*) echo "build-gcc-syslibs: unknown option $1" >&2; exit 2 ;;
	esac
done
[ -n "$crossTools" ] || crossTools="$gen/cross-tools-arm64"
cross="$crossTools/bin"
pkgtool="$gen/objects/linux/x86_64/release/tools/package/package"
pkg() { LD_LIBRARY_PATH="$gen/objects/linux/lib" "$pkgtool" "$@"; }
# extracted package trees: the build tools' rm_attrs, not rm (their attribute emulation keys attributes by
# inode; a stale entry attaches itself to the next file with that inode — WEEK-2026-W43 10-24, W45 11-03)
rmAttrs() { [ ! -e "$1" ] || LD_LIBRARY_PATH="$gen/objects/linux/lib" "$gen/objects/linux/x86_64/release/tools/rm_attrs" -rf "$1"; }
gccVersion="${portVersion%%_*}"
if [ -z "$patchset" ]; then
	patchset="$(ls "$root/patches/gcc_syslibs/gcc-$gccVersion"_*.patchset 2>/dev/null | tail -n 1)"
	[ -n "$patchset" ] || { echo "build-gcc-syslibs: no patches/gcc_syslibs/gcc-${gccVersion}_*.patchset (--patchset none?)" >&2; exit 1; }
fi
if $full; then
	[ -n "$revision" ] || revision=1
else
	[ -n "$revision" ] || revision=2
fi

# the shipped 13.3 packages: the default mode's base, --full's reference for the ABI check
oldVersion=13.3.0_2026_03_29
base="$root/sources/haiku/generated.arm64/download/gcc_syslibs-${oldVersion}_bootstrap-1-arm64.hpkg"
baseDevel="$root/sources/haiku/generated.arm64/download/gcc_syslibs_devel-${oldVersion}_bootstrap-1-arm64.hpkg"
for f in "$base" "$baseDevel" "$cross/$triple-gcc" "$pkgtool" \
	"$gen/objects/haiku/arm64/packaging/packages/haiku.hpkg" \
	"$gen/objects/haiku/arm64/packaging/packages/haiku_devel.hpkg"; do
	[ -e "$f" ] || { echo "build-gcc-syslibs: $f missing" >&2; exit 1; }
done
"$cross/$triple-gcc" --version | head -n 1 | grep -q " $gccVersion\$" \
	|| { echo "build-gcc-syslibs: $cross/$triple-gcc is not GCC $gccVersion" >&2; exit 1; }
src="$work/src/gcc" sysroot="$work/sysroot" obj="$work/obj" out="$work/out"
mkdir -p "$work" "$out"

# 1. The recipe's source tree: buildtools at gccRev (gcc/ only) + its patchset + its config.sub copies
if [ ! -f "$work/src/.done" ]; then
	rm -rf "$work/src"
	git -C "$buildtools" archive --prefix=src/ "$gccRev" gcc | tar -x -C "$work"
	[ "$patchset" = none ] || patch -s -p1 -d "$src" < "$patchset"
	for d in gmp mpfr mpc/build-aux isl/interface isl; do cp "$src/config.sub" "$src/$d/config.sub"; done
	(cd "$src/gcc" && touch c-parse.c c-parse.h cexp.c cp/parse.c cp/parse.h c-gperf.h)
	touch "$work/src/.done"
fi

# 2. The recipe's build sysroot: haiku_devel (+ haiku, and for the default mode the shipped gcc_syslibs
#    for the native compiler's link; --full builds no more than the target libraries and keeps 13.3's
#    C++ headers out of the way)
if [ ! -f "$sysroot/.done" ]; then
	rmAttrs "$sysroot"; mkdir -p "$sysroot/boot/system"
	sysrootPackages=("$gen/objects/haiku/arm64/packaging/packages/haiku.hpkg"
		"$gen/objects/haiku/arm64/packaging/packages/haiku_devel.hpkg")
	$full || sysrootPackages+=("$base" "$baseDevel")
	for p in "${sysrootPackages[@]}"; do
		pkg extract -C "$sysroot/boot/system" "$p"
	done
	rm -f "$sysroot/boot/system/.PackageInfo"
	touch "$sysroot/.done"
fi

# 3. The cross tools under their own names, with the sysroot, upstream's libgcc spec and, as the recipe
#    does, the cross compiler's static libstdc++ as libstdc++.a (g++ adds -lstdc++ to libstdc++.so's own
#    link, where it must find nothing to add; the sysroot's libstdc++.so would become a DT_NEEDED)
mkdir -p "$work/bin" "$work/lib"
printf '*libgcc:\n-lgcc\n\n' > "$work/libgcc.specs"
ln -sfn "$crossTools/$triple/lib/libstdc++-static.a" "$work/lib/libstdc++.a"
for t in gcc g++ c++ cpp; do
	printf '#!/bin/sh\nexec %s --sysroot=%s -specs=%s -L%s "$@"\n' "$cross/$triple-$t" "$sysroot" \
		"$work/libgcc.specs" "$work/lib" > "$work/bin/$triple-$t"
	chmod +x "$work/bin/$triple-$t"
done
for t in ar as ld nm objcopy objdump ranlib readelf strip; do ln -sfn "$cross/$triple-$t" "$work/bin/$triple-$t"; done
export PATH="$work/bin:$PATH"
# the sub-configures run at make time cannot run a test program for the endianness (as the recipe)
export ac_cv_c_bigendian=no
# Haiku links every executable as a shared object (the cross compiler's link spec passes -shared) and
# compiles with -fPIC by default: keep gcc's configure from building the native tools with -fno-PIE
# (with GCC 16, gcov then failed to link)
export gcc_cv_c_no_fpie=no gcc_cv_no_pie=no

# 4. Configure as the recipe does (prefix /boot/system/develop/tools; -L to the target libgcc built here,
#    so -lgcc is that libgcc.a, without the unwinder: the cross compiler's --disable-shared libgcc.a has it);
#    the native tools link libnetwork, where Haiku has socket() (GCC 16's diagnostics code uses it)
prefix=/boot/system/develop/tools
libgccPath="$obj/$triple/libgcc"
if [ ! -f "$obj/.configured" ]; then
	rm -rf "$obj"; mkdir -p "$obj"
	(cd "$obj" && CFLAGS="-O2 -U_FORTIFY_SOURCE -L$libgccPath" CXXFLAGS="-O2 -L$libgccPath" \
		LDFLAGS="-L$libgccPath -lnetwork" LDFLAGS_FOR_TARGET="-L$libgccPath -Wl,--hash-style=both" \
		"$src/configure" --build="$(sh "$src/config.guess")" --host=$triple --target=$triple \
		--prefix=$prefix --libexecdir=$prefix/lib \
		--mandir=/boot/system/documentation/man --docdir=/boot/system/documentation/packages/gcc \
		--enable-threads=posix --disable-nls --enable-shared --disable-plugin --disable-c++-tools \
		--with-gnu-ld --with-gnu-as --enable-version-specific-runtime-libs --enable-languages=c,c++ \
		--disable-lto --enable-frame-pointer --with-pkgversion="${portVersion#*_}" \
		--enable-__cxa-atexit --enable-checking=release --with-bug-url=http://dev.haiku-os.org/ \
		--with-build-sysroot="$sysroot/" --with-default-libstdcxx-abi=gcc4-compatible \
		--disable-libstdcxx-pch --enable-libssp --disable-multilib) > "$work/configure.log" 2>&1 \
		|| { tail -20 "$work/configure.log"; exit 1; }
	touch "$obj/.configured"
fi

# 5. Build: the native compiler first (libgcc takes its generated headers), then the libraries
targetLibs="libgcc libstdc++-v3"
$full && targetLibs="$targetLibs libatomic libgomp libssp"
makeTargets=all-gcc
for l in $targetLibs; do makeTargets="$makeTargets all-target-$l"; done
"$root/scripts/heavy-build.sh" -j "$jobs" --mem-per-job 1 -- \
	make -C "$obj" -j{JOBS} $makeTargets > "$work/build.log" 2>&1 \
	|| { tail -30 "$work/build.log"; exit 1; }
gccS="$obj/$triple/libgcc/libgcc_s.so.1"
stdcxxName="$(cd "$obj/$triple/libstdc++-v3/src/.libs" && ls libstdc++.so.6.0.* | grep -E '^libstdc\+\+\.so\.6\.0\.[0-9]+$')"
stdcxx="$obj/$triple/libstdc++-v3/src/.libs/$stdcxxName"
cp "$gccS" "$out/libgcc_s.so.1"
cp "$stdcxx" "$out/$stdcxxName.hash"

# 6. libstdc++ relinked with -Bsymbolic-functions; the functions other system libraries also export
#    (libroot, libatomic, ...: the sysroot's lib/) and operator new/delete stay interposable
re="$cross/$triple-readelf"
funcs() { "$re" --dyn-syms -W "$1" | awk 'NR > 3 && $7 != "UND" && $4 == "FUNC" { sub(/@.*/, "", $8); print $8 }' | LC_ALL=C sort -u; }
stdcxxNew="$out/$stdcxxName.hash"
if $symbolic; then
	for f in "$sysroot"/boot/system/lib/*.so*; do
		case "$(basename "$f")" in libstdc++*|libsupc++*|libgcc_s*) continue ;; esac
		[ -L "$f" ] || funcs "$f"
	done | LC_ALL=C sort -u | LC_ALL=C comm -12 <(funcs "$stdcxx") - > "$out/libstdc++.shared-functions"
	{ echo '{'; sed 's/$/;/' "$out/libstdc++.shared-functions"; echo '};'; } > "$work/libstdc++.dynamic-list"
	echo "build-gcc-syslibs: $(wc -l < "$out/libstdc++.shared-functions") libstdc++ functions also exported elsewhere stay interposable"
	optLd="$(sed -n 's/^OPT_LDFLAGS = //p' "$obj/$triple/libstdc++-v3/src/Makefile")"
	rm -f "$obj/$triple/libstdc++-v3/src/libstdc++.la" "$obj/$triple/libstdc++-v3/src/.libs"/libstdc++.so*
	make -C "$obj/$triple/libstdc++-v3/src" libstdc++.la OPT_LDFLAGS="$optLd -Wl,-Bsymbolic-functions \
		-Wl,--dynamic-list-cpp-new -Wl,--dynamic-list=$work/libstdc++.dynamic-list" >> "$work/build.log" 2>&1 \
		|| { tail -30 "$work/build.log"; exit 1; }
	grep -q -- '-Bsymbolic-functions' "$work/build.log" || { echo "build-gcc-syslibs: relink without -Bsymbolic-functions" >&2; exit 1; }
	cp "$stdcxx" "$out/$stdcxxName.symbolic"
	stdcxxNew="$out/$stdcxxName.symbolic"
fi

# 7. Compare with the shipped libraries
rmAttrs "$work/old"; mkdir -p "$work/old"
pkg extract -C "$work/old" "$base"
defined() { "$re" --dyn-syms -W "$1" | awk 'NR > 3 && $7 != "UND" && $8 != "" { print $8, $4, $5, $6 }' | sort; }
exported() { "$re" --dyn-syms -W "$1" | awk 'NR > 3 && $7 != "UND" && $4 != "SECTION" && $8 != "" { print $8 }' | LC_ALL=C sort -u; }
imports() { "$re" --dyn-syms -W "$1" | awk 'NR > 3 && $7 == "UND" && $8 != "" { print $8, $5 }' | sort; }
dyn() { "$re" -d "$1" | grep -E 'NEEDED|SONAME' | sed 's/^ *0x[0-9a-f]* *//'; }
check() {
	local old="$1" new="$2" name="$3" bad=0
	"$re" -S -W "$new" | grep -q ' \.gnu\.hash ' || { echo "build-gcc-syslibs: $name has no .gnu.hash" >&2; bad=1; }
	"$re" -S -W "$new" | grep -q ' \.hash ' || { echo "build-gcc-syslibs: $name lost its .hash" >&2; bad=1; }
	diff <(dyn "$old") <(dyn "$new") > "$out/$name.dynamic.diff" || { echo "build-gcc-syslibs: $name: SONAME/NEEDED differ" >&2; bad=1; }
	if $full; then
		# another GCC: a superset of the old exports (name@version), nothing more
		LC_ALL=C comm -23 <(exported "$old") <(exported "$new") > "$out/$name.missing"
		[ ! -s "$out/$name.missing" ] || { echo "build-gcc-syslibs: $name: $(wc -l < "$out/$name.missing") old exports missing ($out/$name.missing)" >&2; bad=1; }
		echo "build-gcc-syslibs: $name: $(exported "$new" | wc -l) exports ($(exported "$old" | wc -l) before, all still there), $(imports "$new" | wc -l) imports"
		return $bad
	fi
	diff <(defined "$old") <(defined "$new") > "$out/$name.exports.diff" || { echo "build-gcc-syslibs: $name: exported symbols differ ($out/$name.exports.diff)" >&2; bad=1; }
	diff <(imports "$old") <(imports "$new") > "$out/$name.imports.diff" || { echo "build-gcc-syslibs: $name: imports differ ($out/$name.imports.diff)" >&2; bad=1; }
	# data object sizes (only a copy relocation would care; Haiku programs are PIC and have none)
	diff <("$re" --dyn-syms -W "$old" | awk '$4 == "OBJECT" && $7 != "UND" { print $8, $3 }' | sort) \
		<("$re" --dyn-syms -W "$new" | awk '$4 == "OBJECT" && $7 != "UND" { print $8, $3 }' | sort) \
		> "$out/$name.objsize.diff" || echo "build-gcc-syslibs: $name: note: data object sizes differ ($out/$name.objsize.diff)"
	echo "build-gcc-syslibs: $name: $(defined "$new" | wc -l) exports, $(imports "$new" | wc -l) imports, diffs $(cat "$out/$name".*.diff | wc -l) lines"
	return $bad
}
check "$work/old/lib/libgcc_s.so.1" "$out/libgcc_s.so.1" libgcc_s.so.1
check "$work/old/lib/libstdc++.so.6.0.32" "$out/$stdcxxName.hash" libstdc++.hash
$symbolic && check "$work/old/lib/libstdc++.so.6.0.32" "$stdcxxNew" libstdc++.symbolic

mkdir -p "$outDir"
if ! $full; then
	# 8. The package: the old one with the two libraries replaced and the revision bumped
	rm -rf "$work/pkg"; cp -a "$work/old" "$work/pkg"
	install -m 644 "$out/libgcc_s.so.1" "$work/pkg/lib/libgcc_s.so.1"
	install -m 755 "$stdcxxNew" "$work/pkg/lib/libstdc++.so.6.0.32"
	sed -i -e "s/^version\t*.*/version\t\t\t${portVersion}_bootstrap-$revision/" \
		-e 's/^packager\t*.*/packager\t\t"haiku-pi build farm <build@haiku-pi.invalid>"/' "$work/pkg/.PackageInfo"
	file="$outDir/gcc_syslibs-${portVersion}_bootstrap-$revision-arm64.hpkg"
	rm -f "$file"
	pkg create -q -C "$work/pkg" -i "$work/pkg/.PackageInfo" "$file"
	echo "build-gcc-syslibs: $file ($(stat -c %s "$file") bytes)"
	exit 0
fi

# 8. --full: install, as the recipe's INSTALL() — the target libraries, GCC's headers — and put
#    libstdc++.so back to the checked (relinked) one, should libtool have relinked it on install
inst="$work/inst"
rm -rf "$inst"
installTargets=
for l in $targetLibs; do installTargets="$installTargets install-target-$l"; done
make -C "$obj" DESTDIR="$inst" $installTargets > "$work/install.log" 2>&1 \
	|| { tail -30 "$work/install.log"; exit 1; }
make -C "$obj/gcc" DESTDIR="$inst" install-headers >> "$work/install.log" 2>&1 \
	|| { tail -30 "$work/install.log"; exit 1; }
gccLibDir="$inst$prefix/lib/gcc/$triple/$gccVersion"
install -m 755 "$stdcxxNew" "$gccLibDir/$stdcxxName"
install -m 644 "$out/libgcc_s.so.1" "$gccLibDir/libgcc_s.so.1"

# 9. The kernel and boot loader variants of libgcc, libgcc_eh and libsupc++ (no threads, no TLS), as the
#    recipe builds them — after the shared libraries are out of the build tree: the libsupc++ objects
#    stay in their last (boot) variant
variant() {
	local name="$1" flags="$2"
	cd "$obj/$triple/libgcc"
	mkdir -p saved
	mv libgcc.a libgcc_eh.a libgcc_s* libgcov* saved/
	make clean > /dev/null
	ln -sfn "$src/libgcc/gthr-single.h" gthr-default.h
	make -j"$jobs" CFLAGS="-ffreestanding -O2 $flags" CXXFLAGS="-ffreestanding -O2 $flags"
	mv libgcc.a "$out/libgcc-$name.a"
	mv libgcc_eh.a "$out/libgcc_eh-$name.a"
	ln -sfn "$src/libgcc/gthr-posix.h" gthr-default.h
	rm -f libgcc_s* libgcov*
	mv saved/* .
	rmdir saved

	local bits="../include/$triple/bits"
	cd "$obj/$triple/libstdc++-v3/libsupc++"
	mkdir -p saved
	mv .libs/libsupc++*.a saved/
	cp "$bits/gthr-default.h" ../config.h "$bits/c++config.h" saved/
	make clean > /dev/null
	cp "$bits/gthr-single.h" "$bits/gthr-default.h"
	sed -i -e 's,#define _GLIBCXX_HAS_GTHREADS 1,/* #undef _GLIBCXX_HAS_GTHREADS */,' ../config.h
	sed -i -e 's,#define _GLIBCXX_HAVE_TLS 1,/* #undef _GLIBCXX_HAVE_TLS */,' "$bits/c++config.h"
	make -j"$jobs" CFLAGS="-ffreestanding -O2 $flags" CXXFLAGS="-ffreestanding -O2 $flags"
	mv .libs/libsupc++.a "$out/libsupc++-$name.a"
	mv saved/libsupc++* .libs/
	mv saved/gthr-default.h "$bits/"
	mv saved/config.h ..
	mv saved/c++config.h "$bits/"
	rmdir saved
}
# (called plainly, so that set -e applies inside: on a failure, see variants.log)
echo "build-gcc-syslibs: kernel and boot variants ($work/variants.log)"
variant kernel "-D_KERNEL_MODE" > "$work/variants.log" 2>&1
variant boot "-nostartfiles" >> "$work/variants.log" 2>&1
cmp -s "$stdcxxNew" "$gccLibDir/$stdcxxName" || { echo "build-gcc-syslibs: installed $stdcxxName changed" >&2; exit 1; }

# 10. The two package trees, laid out as the recipe's packageEntries
soVersion() { (cd "$gccLibDir" && ls "$1".so.* | grep -E "^$1\.so\.[0-9]+\.[0-9]+\.[0-9]+\$" | sed "s/^$1\.so\.//"); }
atomicVersion="$(soVersion libatomic)" gompVersion="$(soVersion libgomp)" sspVersion="$(soVersion libssp)"
stdcxxVersion="${stdcxxName#libstdc++.so.}"
syslibs="$work/pkg-syslibs" devel="$work/pkg-devel"
rm -rf "$syslibs" "$devel"
mkdir -p "$syslibs/lib" "$devel/develop/lib" "$devel/develop/headers/gcc"
for l in libatomic libgomp libssp libstdc++; do
	cp -P "$gccLibDir/$l".so* "$syslibs/lib/"
done
rm -f "$syslibs/lib"/*-gdb.py
cp -P "$gccLibDir/libgcc_s.so" "$gccLibDir/libgcc_s.so.1" "$syslibs/lib/"
ln -s libstdc++.so "$syslibs/lib/libsupc++.so"
cp "$gccLibDir"/libgcc.a "$gccLibDir"/libgcc_eh.a "$gccLibDir"/libsupc++.a "$gccLibDir"/libssp_nonshared.a \
	"$out"/libgcc-kernel.a "$out"/libgcc_eh-kernel.a "$out"/libsupc++-kernel.a \
	"$out"/libgcc-boot.a "$out"/libgcc_eh-boot.a "$out"/libsupc++-boot.a "$devel/develop/lib/"
"$cross/$triple-strip" --strip-debug "$devel/develop/lib"/*.a
for f in "$syslibs/lib"/*; do ln -s "../../lib/$(basename "$f")" "$devel/develop/lib/"; done
cp -r "$gccLibDir/include" "$gccLibDir/include-fixed" "$devel/develop/headers/gcc/"
mv "$devel/develop/headers/gcc/include/c++" "$devel/develop/headers/c++"
[ -d "$devel/develop/headers/c++/$gccVersion" ] && { echo "build-gcc-syslibs: unexpected c++/$gccVersion layout" >&2; exit 1; }

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
		"https://github.com/haiku-pi/buildtools/tree/$gccRev"
	}
	EOF
}
{ echo "name			gcc_syslibs"
	echo 'summary			"C/C++-runtime shared libraries, needed to execute C/C++ programs"'
	echo 'description		"The C/C++-runtime libraries that are part of the gcc distribution. This package contains the shared libraries for the runtime loader, so it is required for executing most c/c++ programs."'
	common
	cat <<-EOF
	provides {
		gcc_syslibs = $portVersion compat >= 7
		lib:libatomic = $atomicVersion compat >= ${atomicVersion%%.*}
		lib:libgcc_s = 1 compat >= 1
		lib:libgomp = $gompVersion compat >= ${gompVersion%%.*}
		lib:libssp = $sspVersion compat >= ${sspVersion%%.*}
		lib:libstdc++ = $stdcxxVersion compat >= ${stdcxxVersion%%.*}
		lib:libsupc++ = $portVersion compat >= 7
	}
	requires {
		haiku
	}
	EOF
} > "$syslibs/.PackageInfo"
{ echo "name			gcc_syslibs_devel"
	echo 'summary			"C/C++-runtime static libraries and C++ headers, needed to build Haiku"'
	echo 'description		"This package is not of general interest - it contains the set of gcc'"'"'s C/C++-runtime libraries and headers that is required by Haiku'"'"'s build system when building Haiku."'
	common
	cat <<-EOF
	provides {
		gcc_syslibs_devel = $portVersion compat >= 7
		devel:libatomic = $atomicVersion compat >= ${atomicVersion%%.*}
		devel:libgcc = 1 compat >= 1
		devel:libgcc_eh = 1 compat >= 1
		devel:libgcc_eh_kernel = 1 compat >= 1
		devel:libgcc_kernel = 1 compat >= 1
		devel:libgcc_eh_boot = 1 compat >= 1
		devel:libgcc_boot = 1 compat >= 1
		devel:libgcc_s = 1 compat >= 1
		devel:libgomp = $gompVersion compat >= ${gompVersion%%.*}
		devel:libssp = $sspVersion compat >= ${sspVersion%%.*}
		devel:libssp_nonshared = $sspVersion
		devel:libstdc++ = $stdcxxVersion compat >= ${stdcxxVersion%%.*}
		devel:libsupc++ = $portVersion compat >= 7
		devel:libsupc++_kernel = $portVersion compat >= 7
		devel:libsupc++_boot = $portVersion compat >= 7
	}
	requires {
		gcc_syslibs >= $portVersion
	}
	EOF
} > "$devel/.PackageInfo"
for p in syslibs:gcc_syslibs devel:gcc_syslibs_devel; do
	dir="$work/pkg-${p%%:*}" file="$outDir/${p#*:}-$portVersion-$revision-arm64.hpkg"
	rm -f "$file"
	pkg create -q -C "$dir" -i "$dir/.PackageInfo" "$file"
	echo "build-gcc-syslibs: $file ($(stat -c %s "$file") bytes)"
done
