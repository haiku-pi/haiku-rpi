#!/usr/bin/env bash
# build-spidermonkey.sh — Firefox's standalone SpiderMonkey shell (`js`, JIT on) cross-built on this
# Linux host for Haiku arm64 (aarch64-unknown-haiku): Firefox 157.0.1, HaikuPorts' Haiku patchsets
# (www-client/firefox in sources/haikuports), then ours (patches/spidermonkey/: the arm64 signal
# context for the wasm trap handler, the JIT icache flush, libbe/libbsd/libnetwork links) and the libc
# crate's arm64 Haiku module (patches/rust-libc/, also applied to Firefox's vendored copy).
#
#   scripts/build-spidermonkey.sh [STEP]     (start at STEP; the earlier ones must have run)
#
# Steps:
#   source   download + verify firefox-157.0.1.source.tar.xz into sources/firefox/dl/, unpack it to
#            sources/firefox/firefox-157.0.1/ (only if missing: rm -rf it to start over), apply the
#            patches, and clear the vendored crates' file checksums (as the HaikuPorts recipe does)
#   hosttools  cbindgen 0.29.4 (configure requires it, also for js) built with our cargo into
#            artifacts/spidermonkey/host/bin
#   config   artifacts/spidermonkey/mozconfig
#   build    ./mach build under scripts/heavy-build.sh; resumable (objdir artifacts/spidermonkey/obj)
#   check    the shell is PIE-style DYN, has no relocation the arm64 runtime_loader lacks, and no
#            thread-pointer-relative TLS access (mrs tpidr_el0: local-exec/initial-exec TLS, which
#            Haiku's TLS layout does not provide)
#   tests    artifacts/spidermonkey-tests/non-packaged/{bin,lib,data/spidermonkey-tests}: the shell
#            and the scripts of tools/spidermonkey-tests/ (scripts/mkimage-pi4.sh --add-tree;
#            tools/pi-tests/spidermonkey.sh runs them)
#
# Toolchain: C/C++ = the jam-built Haiku cross gcc 13.3 (artifacts/rust/bin wrappers, which add the
# sysroot): its specs default to -fPIC and -mtls-dialect=trad, so __thread uses the general-dynamic
# model (TLS_DTPMOD64/DTPREL64 + __tls_get_addr), which Haiku's arm64 runtime_loader supports; host
# clang emits TLSDESC for this target instead. Rust = scripts/build-rust.sh's rustc 1.90.0.
# Needs: scripts/build-rust.sh (all steps), the arm64 sysroot, python3 3.10-3.14, host gcc/g++;
# ~5 GB source tree, ~5.3 GB objdir; the build takes ~7 min at -j10 on a 16-thread host.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
version=157.0.1
sha256=483bedee9059df2479e4531c443b1073c6ebaed3570bda0c164eb562ee241c4c
target=aarch64-unknown-haiku
dl="$root/sources/firefox/dl"
src="$root/sources/firefox/firefox-$version"
recipe="$root/sources/haikuports/www-client/firefox"
out="$root/artifacts/spidermonkey"
obj="$out/obj"
crossBin="$root/sources/haiku/generated.arm64/cross-tools-arm64/bin"
sysroot="$root/artifacts/sysroot-arm64"
tarball="firefox-$version.source.tar.xz"
[ -f "$root/artifacts/rust/env.sh" ] || { echo "build-spidermonkey: run scripts/build-rust.sh first" >&2; exit 1; }
[ -x "$root/artifacts/rust/bin/$target-g++" ] || { echo "build-spidermonkey: no $target-g++ wrapper (scripts/build-rust.sh config)" >&2; exit 1; }

source_() {
	mkdir -p "$dl"
	if ! echo "$sha256  $dl/$tarball" | sha256sum --quiet -c 2> /dev/null; then
		curl -fSL -o "$dl/$tarball" "https://ftp.mozilla.org/pub/firefox/releases/$version/source/$tarball"
		echo "$sha256  $dl/$tarball" | sha256sum --quiet -c
	fi
	[ -d "$src" ] && return
	tar -C "$(dirname "$src")" -xf "$dl/$tarball"
	local p
	for p in "$recipe/patches/firefox-$version.patchset" "$recipe/patches/firefox_launcher-$version.patchset" \
		"$root"/patches/spidermonkey/*.patch; do
		patch -d "$src" -p1 -s --no-backup-if-mismatch < "$p"
	done
	for p in "$root"/patches/rust-libc/*.patch; do
		patch -d "$src/third_party/rust/libc" -p1 -s --no-backup-if-mismatch < "$p"
	done
	# the recipe's PATCH(): the patchset edits vendored crates, so cargo must not check them
	find "$src/third_party/rust" -name .cargo-checksum.json -print0 |
		while IFS= read -r -d '' f; do printf '{"files":{}}' > "$f"; done
	sed -i '/^checksum =/d' "$src/Cargo.lock"
	chmod +x "$src/build/cargo-linker" "$src/mach"
	echo "build-spidermonkey: $src unpacked and patched"
}

hosttools() {
	# shellcheck source=/dev/null
	. "$root/artifacts/rust/env.sh"
	[ -x "$out/host/bin/cbindgen" ] || cargo install cbindgen --version 0.29.4 --locked --root "$out/host"
	"$out/host/bin/cbindgen" --version
}

config() {
	mkdir -p "$out/state"
	cat > "$out/mozconfig" <<EOF
# written by scripts/build-spidermonkey.sh
mk_add_options MOZ_OBJDIR=$obj
ac_add_options --enable-project=js
ac_add_options --host=x86_64-pc-linux-gnu
ac_add_options --target=$target
ac_add_options --disable-bootstrap
ac_add_options --enable-jit
ac_add_options --enable-optimize=-O2
ac_add_options --disable-debug
ac_add_options --disable-tests
ac_add_options --disable-lto
ac_add_options --disable-strip
export CC="$root/artifacts/rust/bin/$target-gcc"
export CXX="$root/artifacts/rust/bin/$target-g++"
export AR="$crossBin/$target-ar"
export RANLIB="$crossBin/$target-ranlib"
export STRIP="$crossBin/$target-strip"
export OBJCOPY="$crossBin/$target-objcopy"
export HOST_CC=gcc
export HOST_CXX=g++
export CBINDGEN="$out/host/bin/cbindgen"
# target libraries (zlib) from the arm64 sysroot, never the host's
export PKG_CONFIG_SYSROOT_DIR="$sysroot"
export PKG_CONFIG_LIBDIR="$sysroot/boot/system/develop/lib/pkgconfig"
EOF
	echo "build-spidermonkey: $out/mozconfig"
}

# the environment mach runs in: our rustc + cargo, offline, its Python state under artifacts/
mach_env() {
	# shellcheck source=/dev/null
	. "$root/artifacts/rust/env.sh"
	export MOZCONFIG="$out/mozconfig" MOZBUILD_STATE_PATH="$out/state"
	export CARGO_NET_OFFLINE=true CARGO_INCREMENTAL=0
	export MACH_BUILD_PYTHON_NATIVE_PACKAGE_SOURCE=none PIP_NO_INDEX=1 PIP_DISABLE_PIP_VERSION_CHECK=1
	export MOZ_NOSPAM=1
}

build() {
	mach_env
	local start=$SECONDS
	(cd "$src" && "$root/scripts/heavy-build.sh" -j 12 --mem-per-job 2 -- \
		./mach --no-interactive build -j '{JOBS}')
	echo "build-spidermonkey: mach build took $(( (SECONDS - start) / 60 )) min"
	ls -l "$obj/dist/bin/js"
}

# fails if FILE would not load or would misbehave under Haiku's arm64 runtime_loader
check_elf() {
	local f=$1 bad=0
	"$crossBin/$target-readelf" -h "$f" | grep -q 'Type: *DYN' || { echo "build-spidermonkey: $f is not DYN"; bad=1; }
	if "$crossBin/$target-readelf" -rW "$f" | grep -E 'R_AARCH64_(COPY|TLSDESC|TLS_TPREL)'; then
		echo "build-spidermonkey: $f has relocations Haiku's runtime_loader lacks"; bad=1
	fi
	if "$crossBin/$target-objdump" -d "$f" | grep -m3 'mrs.*tpidr_el0'; then
		echo "build-spidermonkey: $f reads tpidr_el0 (static TLS model)"; bad=1
	fi
	return $bad
}

check() {
	local js="$obj/dist/bin/js"
	check_elf "$js"
	"$crossBin/$target-readelf" -d "$js" | grep NEEDED
	echo "build-spidermonkey: $js passes the loader checks"
}

tests() {
	local tree="$root/artifacts/spidermonkey-tests/non-packaged" f
	rm -rf "$tree"
	mkdir -p "$tree/bin" "$tree/lib" "$tree/data/spidermonkey-tests"
	# stripped (the objdir copy keeps its symbols for addr2line): 540 MB -> ~30 MB
	"$crossBin/$target-strip" -o "$tree/bin/js" "$obj/dist/bin/js"
	# shared libraries of the objdir the shell needs (none for the default static shell)
	for f in $("$crossBin/$target-readelf" -d "$tree/bin/js" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p'); do
		if [ -f "$obj/dist/bin/$f" ]; then
			"$crossBin/$target-strip" -o "$tree/lib/$f" "$obj/dist/bin/$f"
			check_elf "$tree/lib/$f"
		fi
	done
	cp "$root"/tools/spidermonkey-tests/*.js "$tree/data/spidermonkey-tests/"
	find "$tree" -type f -exec ls -l {} +
}

steps=(source hosttools config build check tests)
first="${1:-source}"
run=0
for s in "${steps[@]}"; do
	[ "$s" = "$first" ] && run=1
	[ "$run" = 1 ] || continue
	case "$s" in
	source) source_ ;;
	*) "$s" ;;
	esac
done
[ "$run" = 1 ] || { echo "build-spidermonkey: no step $first (${steps[*]})" >&2; exit 2; }
