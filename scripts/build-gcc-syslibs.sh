#!/usr/bin/env bash
# build-gcc-syslibs.sh — rebuild libstdc++.so.6 and libgcc_s.so.1 of the gcc_syslibs package with a GNU
# hash table (and libstdc++ with -Bsymbolic-functions), from the same gcc sources as the package we ship.
#
#   scripts/build-gcc-syslibs.sh [--revision N] [--work DIR] [--no-symbolic] [--jobs N]
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
# Only libstdc++.so.6.0.32 and libgcc_s.so.1 are replaced; every other file of the package stays
# byte-identical, and gcc_syslibs_devel (static libraries, headers) does not change.
#
# Checks (and fails on a difference): SONAME, NEEDED and the exported dynamic symbols (name@version,
# type, binding, visibility) and imports of each new library against the old one; .gnu.hash present.
#
# Output: artifacts/gcc-syslibs/gcc_syslibs-13.3.0_2026_03_29_bootstrap-<N>-arm64.hpkg (default N = 2) —
# deliberately not in artifacts/packages, which scripts/publish-repo.sh publishes — and the two libraries
# (both variants: hash only, hash + symbolic) with the comparison diffs in <work>/out. The work directory
# (default artifacts/gcc-syslibs-build) takes ~2 GB; delete it afterwards. Staging the package into the
# image build and the repository is manual (AGENTS.md "A package revision bump has three parts").
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
gen="$root/sources/haiku/generated.arm64"
cross="$gen/cross-tools-arm64/bin"
triple=aarch64-unknown-haiku
pkgtool="$gen/objects/linux/x86_64/release/tools/package/package"
pkg() { LD_LIBRARY_PATH="$gen/objects/linux/lib" "$pkgtool" "$@"; }

gccRev=850b24947d5c95b68d2dc6c75844fd7acc462941    # the gcc_bootstrap recipe's srcGitRev
portVersion=13.3.0_2026_03_29
base="$gen/download/gcc_syslibs-${portVersion}_bootstrap-1-arm64.hpkg"
baseDevel="$gen/download/gcc_syslibs_devel-${portVersion}_bootstrap-1-arm64.hpkg"
revision=2
work="$root/artifacts/gcc-syslibs-build"
symbolic=true
jobs="$(nproc)"
while [ $# -gt 0 ]; do
	case "$1" in
	--revision) revision="$2"; shift 2 ;;
	--work) work="$(realpath -m "$2")"; shift 2 ;;
	--no-symbolic) symbolic=false; shift ;;
	--jobs) jobs="$2"; shift 2 ;;
	*) echo "build-gcc-syslibs: unknown option $1" >&2; exit 2 ;;
	esac
done
for f in "$base" "$baseDevel" "$cross/$triple-gcc" "$pkgtool" \
	"$gen/objects/haiku/arm64/packaging/packages/haiku.hpkg" \
	"$gen/objects/haiku/arm64/packaging/packages/haiku_devel.hpkg"; do
	[ -e "$f" ] || { echo "build-gcc-syslibs: $f missing" >&2; exit 1; }
done
src="$work/src/gcc" sysroot="$work/sysroot" obj="$work/obj" out="$work/out"
mkdir -p "$work" "$out"

# 1. The recipe's source tree: buildtools at gccRev (gcc/ only) + its patchset + its config.sub copies
if [ ! -f "$work/src/.done" ]; then
	rm -rf "$work/src"
	git -C "$root/sources/buildtools" archive --prefix=src/ "$gccRev" gcc | tar -x -C "$work"
	patch -s -p1 -d "$src" < "$root/patches/gcc_syslibs/gcc-$portVersion.patchset"
	for d in gmp mpfr mpc/build-aux isl/interface isl; do cp "$src/config.sub" "$src/$d/config.sub"; done
	(cd "$src/gcc" && touch c-parse.c c-parse.h cexp.c cp/parse.c cp/parse.h c-gperf.h)
	touch "$work/src/.done"
fi

# 2. The recipe's build sysroot: haiku_devel (+ haiku, gcc_syslibs for the native compiler's link)
if [ ! -f "$sysroot/.done" ]; then
	rm -rf "$sysroot"; mkdir -p "$sysroot/boot/system"
	for p in "$gen/objects/haiku/arm64/packaging/packages/haiku.hpkg" \
		"$gen/objects/haiku/arm64/packaging/packages/haiku_devel.hpkg" "$base" "$baseDevel"; do
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
ln -sfn "$gen/cross-tools-arm64/$triple/lib/libstdc++-static.a" "$work/lib/libstdc++.a"
for t in gcc g++ c++ cpp; do
	printf '#!/bin/sh\nexec %s --sysroot=%s -specs=%s -L%s "$@"\n' "$cross/$triple-$t" "$sysroot" \
		"$work/libgcc.specs" "$work/lib" > "$work/bin/$triple-$t"
	chmod +x "$work/bin/$triple-$t"
done
for t in ar as ld nm objcopy objdump ranlib readelf strip; do ln -sfn "$cross/$triple-$t" "$work/bin/$triple-$t"; done
export PATH="$work/bin:$PATH"
# the sub-configures run at make time cannot run a test program for the endianness (as the recipe)
export ac_cv_c_bigendian=no

# 4. Configure as the recipe does (prefix /boot/system/develop/tools; -L to the target libgcc built here,
#    so -lgcc is that libgcc.a, without the unwinder: the cross compiler's --disable-shared libgcc.a has it)
libgccPath="$obj/$triple/libgcc"
if [ ! -f "$obj/.configured" ]; then
	rm -rf "$obj"; mkdir -p "$obj"
	(cd "$obj" && CFLAGS="-O2 -U_FORTIFY_SOURCE -L$libgccPath" CXXFLAGS="-O2 -L$libgccPath" \
		LDFLAGS="-L$libgccPath" LDFLAGS_FOR_TARGET="-L$libgccPath -Wl,--hash-style=both" \
		"$src/configure" --build="$(sh "$src/config.guess")" --host=$triple --target=$triple \
		--prefix=/boot/system/develop/tools --libexecdir=/boot/system/develop/tools/lib \
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

# 5. Build: the native compiler first (libgcc takes its generated headers), then the two libraries
"$root/scripts/heavy-build.sh" -j "$jobs" --mem-per-job 1 -- \
	make -C "$obj" -j{JOBS} all-target-libgcc all-target-libstdc++-v3 > "$work/build.log" 2>&1 \
	|| { tail -30 "$work/build.log"; exit 1; }
gccS="$obj/$triple/libgcc/libgcc_s.so.1"
stdcxx="$obj/$triple/libstdc++-v3/src/.libs/libstdc++.so.6.0.32"
cp "$gccS" "$out/libgcc_s.so.1"
cp "$stdcxx" "$out/libstdc++.so.6.0.32.hash"

# 6. libstdc++ relinked with -Bsymbolic-functions; the functions other system libraries also export
#    (libroot, libatomic, ...: the sysroot's lib/) and operator new/delete stay interposable
re="$cross/$triple-readelf"
funcs() { "$re" --dyn-syms -W "$1" | awk 'NR > 3 && $7 != "UND" && $4 == "FUNC" { sub(/@.*/, "", $8); print $8 }' | LC_ALL=C sort -u; }
stdcxxNew="$out/libstdc++.so.6.0.32.hash"
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
	cp "$stdcxx" "$out/libstdc++.so.6.0.32.symbolic"
	stdcxxNew="$out/libstdc++.so.6.0.32.symbolic"
fi

# 7. Compare with the shipped libraries
rm -rf "$work/old"; mkdir -p "$work/old"
pkg extract -C "$work/old" "$base"
defined() { "$re" --dyn-syms -W "$1" | awk 'NR > 3 && $7 != "UND" && $8 != "" { print $8, $4, $5, $6 }' | sort; }
imports() { "$re" --dyn-syms -W "$1" | awk 'NR > 3 && $7 == "UND" && $8 != "" { print $8, $5 }' | sort; }
dyn() { "$re" -d "$1" | grep -E 'NEEDED|SONAME' | sed 's/^ *0x[0-9a-f]* *//'; }
check() {
	local old="$1" new="$2" name="$3" bad=0
	"$re" -S -W "$new" | grep -q ' \.gnu\.hash ' || { echo "build-gcc-syslibs: $name has no .gnu.hash" >&2; bad=1; }
	"$re" -S -W "$new" | grep -q ' \.hash ' || { echo "build-gcc-syslibs: $name lost its .hash" >&2; bad=1; }
	diff <(dyn "$old") <(dyn "$new") > "$out/$name.dynamic.diff" || { echo "build-gcc-syslibs: $name: SONAME/NEEDED differ" >&2; bad=1; }
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
check "$work/old/lib/libstdc++.so.6.0.32" "$out/libstdc++.so.6.0.32.hash" libstdc++.hash
$symbolic && check "$work/old/lib/libstdc++.so.6.0.32" "$stdcxxNew" libstdc++.symbolic

# 8. The package: the old one with the two libraries replaced and the revision bumped
rm -rf "$work/pkg"; cp -a "$work/old" "$work/pkg"
install -m 644 "$out/libgcc_s.so.1" "$work/pkg/lib/libgcc_s.so.1"
install -m 755 "$stdcxxNew" "$work/pkg/lib/libstdc++.so.6.0.32"
sed -i -e "s/^version\t*.*/version\t\t\t${portVersion}_bootstrap-$revision/" \
	-e 's/^packager\t*.*/packager\t\t"haiku-pi build farm <build@haiku-pi.invalid>"/' "$work/pkg/.PackageInfo"
mkdir -p "$root/artifacts/gcc-syslibs"
file="$root/artifacts/gcc-syslibs/gcc_syslibs-${portVersion}_bootstrap-$revision-arm64.hpkg"
rm -f "$file"
pkg create -q -C "$work/pkg" -i "$work/pkg/.PackageInfo" "$file"
echo "build-gcc-syslibs: $file ($(stat -c %s "$file") bytes)"
