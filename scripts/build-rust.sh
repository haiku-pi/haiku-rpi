#!/usr/bin/env bash
# build-rust.sh — a Rust toolchain on this Linux host that cross-compiles for Haiku arm64
# (aarch64-unknown-haiku, with std): rustc VERSION from the release source tarball with our target
# spec (patches/rust/VERSION/) and the libc crate's arm64 Haiku module (patches/rust-libc/, applied
# to the copy std builds with). Built at stage 1 only: an x86_64 Linux rustc (built by the stage0
# bootstrap compiler of the previous release, which x.py downloads) plus std for the host and for
# aarch64-unknown-haiku. No rustc or cargo runs on Haiku. cargo is the official x86_64 Linux binary
# of the same version.
#
#   scripts/build-rust.sh [--version VERSION] [STEP]   (start at STEP; the earlier ones must have run)
#
# Versions (each one needs patches/rust/VERSION/):
#   1.90.0   the default; artifacts/rust/ (Firefox and SpiderMonkey build with it)
#   1.99.1   artifacts/rust-1.99.1/ (Photocraft: edition 2024, rust-version 1.95)
# Below, OUT is artifacts/rust for 1.90.0 and artifacts/rust-VERSION for the others.
#
# Steps:
#   source   download + verify rustc-VERSION-src.tar.xz into sources/rust/dl/, unpack it to
#            sources/rust/rustc-VERSION-src/ (only if missing: rm -rf it to start over), apply the
#            patches, and clear the patched vendored crates' file checksums (cargo checks them)
#   config   OUT/bootstrap.toml and the cross gcc wrappers in OUT/bin/
#            (the jam-built gcc's configured sysroot does not exist; they add
#            --sysroot=artifacts/sysroot-arm64)
#   build    x.py build --stage 1 library, under scripts/heavy-build.sh; resumable (the build
#            directory OUT/build/ is kept); LLVM (AArch64 + X86) is built too: ~25 min
#            at -j8 on a 16-thread host
#   cargo    the official cargo VERSION binary (sha256 checked), into the stage1 bin/
#   env      OUT/env.sh: source it to get rustc + cargo on PATH, with the target's
#            linker and C compiler set
#   tests    tools/rust-tests/ built for the Pi into artifacts/rust-tests/non-packaged/bin/ and
#            lib/ (artifacts/rust-tests-VERSION/ for versions other than 1.90.0;
#            scripts/mkimage-pi4.sh --add-tree; tools/pi-tests/rust.sh runs them)
#
# Toolchain: OUT/build/x86_64-unknown-linux-gnu/stage1/ (bin/rustc, bin/cargo, lib/).
# Needs: the arm64 sysroot (scripts/haiku-sysroot.sh), the jam-built cross gcc, curl, python3,
# cmake, ninja, a host C++ compiler; ~12 GB of disk (4.2 GB source tree, 7.6 GB build).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
version=1.90.0
if [ "${1:-}" = --version ]; then
	version="$2"
	shift 2
fi
[ -d "$root/patches/rust/$version" ] || { echo "build-rust: no patches/rust/$version" >&2; exit 2; }
host=x86_64-unknown-linux-gnu
target=aarch64-unknown-haiku
dl="$root/sources/rust/dl"
src="$root/sources/rust/rustc-$version-src"
if [ "$version" = 1.90.0 ]; then
	out="$root/artifacts/rust"
	testsOut="$root/artifacts/rust-tests"
else
	out="$root/artifacts/rust-$version"
	testsOut="$root/artifacts/rust-tests-$version"
fi
stage1="$out/build/$host/stage1"
crossBin="$root/sources/haiku/generated.arm64/cross-tools-arm64/bin"
sysroot="$root/artifacts/sysroot-arm64"
dist=https://static.rust-lang.org/dist
[ -x "$crossBin/$target-gcc" ] || { echo "build-rust: no cross gcc in $crossBin (build Haiku first)" >&2; exit 1; }
[ -d "$sysroot/boot/system/develop" ] || { echo "build-rust: run scripts/haiku-sysroot.sh first" >&2; exit 1; }

# fetch FILE from $dist into $dl, checked against the published .sha256
fetch() {
	mkdir -p "$dl"
	[ -f "$dl/$1.sha256" ] || curl -fsSL -o "$dl/$1.sha256" "$dist/$1.sha256"
	if ! (cd "$dl" && sha256sum --quiet -c "$1.sha256" > /dev/null 2>&1); then
		curl -fSL -o "$dl/$1" "$dist/$1"
		(cd "$dl" && sha256sum --quiet -c "$1.sha256")
	fi
}

source_() {
	fetch "rustc-$version-src.tar.xz"
	if [ ! -d "$src" ]; then
		tar -C "$(dirname "$src")" -xf "$dl/rustc-$version-src.tar.xz"
		local p libc
		for p in "$root"/patches/rust/"$version"/*.patch; do
			patch -d "$src" -p1 --no-backup-if-mismatch < "$p"
		done
		# the libc std builds with (library/Cargo.lock), vendored
		libc="libc-$(sed -n '/^name = "libc"$/{n;s/^version = "\(.*\)"$/\1/p;q}' "$src/library/Cargo.lock")"
		for p in "$root"/patches/rust-libc/*.patch; do
			patch -d "$src/vendor/$libc" -p1 --no-backup-if-mismatch < "$p"
		done
		python3 -c 'import json, sys
f = sys.argv[1]; c = json.load(open(f)); c["files"] = {}; json.dump(c, open(f, "w"))' \
			"$src/vendor/$libc/.cargo-checksum.json"
		echo "build-rust: $src unpacked and patched (vendor/$libc)"
	fi
}

config() {
	mkdir -p "$out/bin"
	local t
	for t in gcc g++; do
		printf '#!/bin/sh\nexec "%s" --sysroot="%s" "$@"\n' "$crossBin/$target-$t" "$sysroot" > "$out/bin/$target-$t"
		chmod +x "$out/bin/$target-$t"
	done
	cat > "$out/bootstrap.toml" <<EOF
# written by scripts/build-rust.sh
change-id = "ignore"

[build]
build-dir = "$out/build"
host = ["$host"]
target = ["$host", "$target"]
docs = false
extended = false
vendor = true
locked-deps = true

[llvm]
download-ci-llvm = false
targets = "AArch64;X86"
experimental-targets = ""
assertions = false
ninja = true
link-jobs = 2

[rust]
download-rustc = false
channel = "stable"
debug = false
debuginfo-level = 0
incremental = false

[target.$target]
cc = "$out/bin/$target-gcc"
cxx = "$out/bin/$target-g++"
ar = "$crossBin/$target-ar"
ranlib = "$crossBin/$target-ranlib"
linker = "$out/bin/$target-gcc"
EOF
}

build() {
	local start=$SECONDS
	# the stage0 compiler does not know the target (patches/rust: STAGE0_MISSING_TARGETS)
	(cd "$src" && "$root/scripts/heavy-build.sh" -j 8 --mem-per-job 2 -- \
		python3 x.py build --config "$out/bootstrap.toml" --stage 1 -j '{JOBS}' \
		library --target "$host,$target")
	echo "build-rust: x.py build took $(( (SECONDS - start) / 60 )) min"
	"$stage1/bin/rustc" --version
}

cargo_() {
	local name="cargo-$version-$host"
	fetch "$name.tar.xz"
	rm -rf "$out/cargo-unpack"
	mkdir -p "$out/cargo-unpack"
	tar -C "$out/cargo-unpack" -xf "$dl/$name.tar.xz"
	install -m 755 "$out/cargo-unpack/$name/cargo/bin/cargo" "$stage1/bin/cargo"
	rm -rf "$out/cargo-unpack"
	"$stage1/bin/cargo" --version
}

env_() {
	cat > "$out/env.sh" <<EOF
# written by scripts/build-rust.sh ($version): . this file, then cargo build --target $target
export PATH="$stage1/bin:\$PATH"
export CARGO_HOME="$out/cargo-home"
export CARGO_TARGET_AARCH64_UNKNOWN_HAIKU_LINKER="$out/bin/$target-gcc"
export CC_aarch64_unknown_haiku="$out/bin/$target-gcc"
export CXX_aarch64_unknown_haiku="$out/bin/$target-g++"
export AR_aarch64_unknown_haiku="$crossBin/$target-ar"
EOF
	echo "build-rust: $out/env.sh"
}

# the test programs (tools/rust-tests/), and a check of every binary: PIE, and no relocation the
# arm64 runtime_loader lacks (it has NONE, ABS64, GLOB_DAT, JUMP_SLOT, RELATIVE, TLS_DTPMOD64 and
# TLS_DTPREL64 only: no COPY, no TLSDESC, no TPREL)
tests() {
	# shellcheck source=/dev/null
	. "$out/env.sh"
	local t="$root/tools/rust-tests" tree="$testsOut/non-packaged" rel
	local cargoTarget="$testsOut/target"
	rm -rf "$tree"
	mkdir -p "$tree/bin" "$tree/lib" "$cargoTarget"
	# patches/rust-libc's struct layouts: the same numbers asserted in C (Haiku headers) and Rust
	"$out/bin/$target-gcc" -fsyntax-only "$t/libc-layout/layout.c"
	RUSTC_BOOTSTRAP=1 rustc --target "$target" --crate-type lib --emit metadata \
		-o "$cargoTarget/libc-layout.rmeta" "$t/libc-layout/layout.rs"
	echo "build-rust: libc mcontext_t/ucontext_t layout matches the Haiku headers"
	cargo build --offline --release --target "$target" --target-dir "$cargoTarget" \
		--manifest-path "$t/rust-smoke/Cargo.toml"
	cargo build --offline --release --target "$target" --target-dir "$cargoTarget" \
		--manifest-path "$t/rust-clib/Cargo.toml"
	# the libraries a C link of the staticlib needs, as rustc reports them
	local staticLibs
	staticLibs="$(cargo rustc --offline --release --target "$target" --target-dir "$cargoTarget" \
		--manifest-path "$t/rust-clib/Cargo.toml" --lib --crate-type staticlib -- \
		--print native-static-libs 2>&1 | sed -n 's/^note: native-static-libs: //p')"
	echo "build-rust: the staticlib needs: $staticLibs"
	rel="$cargoTarget/$target/release"
	cp "$rel/rust-smoke" "$tree/bin/"
	cp "$rel/librust_clib.so" "$tree/lib/"
	# the same C program twice: with the static library, and with the shared one
	# shellcheck disable=SC2086
	"$out/bin/$target-gcc" -O2 -pie -fPIE -o "$tree/bin/rust-c-static" "$t/rust-clib/main.c" \
		"$rel/librust_clib.a" $staticLibs
	"$out/bin/$target-gcc" -O2 -pie -fPIE -o "$tree/bin/rust-c-shared" "$t/rust-clib/main.c" \
		-L"$rel" -lrust_clib
	local f bad=0
	for f in "$tree"/bin/* "$tree"/lib/*; do
		"$crossBin/$target-readelf" -h "$f" | grep -q 'Type: *DYN' \
			|| { echo "build-rust: $f is not PIE"; bad=1; }
		if "$crossBin/$target-readelf" -rW "$f" | grep -E 'R_AARCH64_(COPY|TLSDESC|TLS_TPREL|TLSLE|TLSIE)'; then
			echo "build-rust: $f has relocations Haiku's runtime_loader lacks"; bad=1
		fi
	done
	[ "$bad" = 0 ] || exit 1
	ls -l "$tree/bin" "$tree/lib"
}

steps=(source config build cargo env tests)
first="${1:-source}"
run=0
for s in "${steps[@]}"; do
	[ "$s" = "$first" ] && run=1
	[ "$run" = 1 ] || continue
	case "$s" in
	source) source_ ;;
	cargo) cargo_ ;;
	env) env_ ;;
	*) "$s" ;;
	esac
done
[ "$run" = 1 ] || { echo "build-rust: no step $first (${steps[*]})" >&2; exit 2; }
