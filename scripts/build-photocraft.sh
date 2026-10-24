#!/usr/bin/env bash
# build-photocraft.sh — Photocraft's command-line tool (photocraft-cli, a photo editor in Rust:
# https://github.com/storytold/photocraft) for arm64 Haiku, and the same commit for this x86_64 Linux
# host, so their outputs can be compared (docs/design/photocraft.md, phase P1).
#
#   scripts/build-photocraft.sh [STEP]     (start at STEP; the earlier ones must have run)
#
# Steps:
#   source    clone the pinned commit into sources/photocraft (only if missing; an existing tree must
#             be at that commit, it is never checked out here)
#   vendor    cargo vendor (all of Cargo.lock: crates.io + the git dependencies) into
#             artifacts/photocraft/vendor/ (fresh each time), then the Haiku patches: patches/rust-libc/
#             on the vendored libc, and patches/photocraft/<crate>-<version>/*.patch on that crate. The
#             patched crates' file checksums are cleared; the package checksums stay, so the build runs
#             --locked against the unmodified Cargo.lock (no [patch] section, nothing in the source tree)
#   build     cargo build --release -p photocraft-cli for aarch64-unknown-haiku and for the host
#             (x86_64-unknown-linux-gnu), offline and locked, under scripts/heavy-build.sh
#   stage     artifacts/photocraft/non-packaged/{bin/photocraft-cli, data/photocraft-test/*} (stripped;
#             checked PIE and free of relocations Haiku's runtime_loader lacks) and
#             artifacts/photocraft/host/photocraft-cli
#   hosttest  tools/pi-tests/photocraft-cli.sh run on the host build, into
#             artifacts/photocraft/host-results.txt (the Pi's "PCC " serial lines should match)
#
#   scripts/build-photocraft.sh compare LOG   (a UART or QEMU log of tools/pi-tests/photocraft-cli.sh)
#             diff its "PCC " lines against host-results.txt, wall times left out; exit 0 if equal
#
# Toolchain: scripts/build-rust.sh --version 1.99.1 (Photocraft needs rust-version 1.95, edition 2024).
# Features: the defaults (no heif: libheif is C). The GUI app (apps/photocraft) is not built here.
# Pi test: scripts/mkimage-pi4.sh --add-tree artifacts/photocraft/non-packaged
#          --bootscript tools/pi-tests/photocraft-cli.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
commit=486afd82cce99255e999224bcfe28de00fd766aa	# main of 2026-10-24, version 0.15.1
repo=https://github.com/storytold/photocraft
rustVersion=1.99.1
target=aarch64-unknown-haiku
host=x86_64-unknown-linux-gnu
src="$root/sources/photocraft"
work="$root/artifacts/photocraft"
vendor="$work/vendor"
stage="$work/non-packaged"
crossBin="$root/sources/haiku/generated.arm64/cross-tools-arm64/bin"
rustEnv="$root/artifacts/rust-$rustVersion/env.sh"
# the test images: from the pinned source tree
testImages=(docs/images/photocraft-masks.jpg assets/app-icon/photocraft-1024.png)

toolchain() {
	[ -f "$rustEnv" ] || { echo "build-photocraft: run scripts/build-rust.sh --version $rustVersion" >&2; exit 1; }
	# shellcheck source=/dev/null
	. "$rustEnv"
	export CARGO_HOME="$work/cargo-home"
}

clearChecksums() {	# CRATE_DIR: cargo checks vendored files against .cargo-checksum.json
	python3 -c 'import json, sys
f = sys.argv[1]; c = json.load(open(f)); c["files"] = {}; json.dump(c, open(f, "w"))' \
		"$1/.cargo-checksum.json"
}

source_() {
	if [ ! -d "$src" ]; then
		git clone "$repo" "$src"
		git -C "$src" -c advice.detachedHead=false switch --detach "$commit"
	fi
	local head
	head="$(git -C "$src" rev-parse HEAD)"
	[ "$head" = "$commit" ] || { echo "build-photocraft: $src is at $head, not $commit" >&2; exit 1; }
	git -C "$src" diff --quiet || { echo "build-photocraft: $src has local changes" >&2; exit 1; }
	echo "build-photocraft: $src at $commit"
}

vendor() {
	toolchain
	rm -rf "$vendor"
	mkdir -p "$work"
	(cd "$src" && cargo vendor --locked --versioned-dirs "$vendor") > "$work/vendor-config.toml"
	local libc p dir
	libc="libc-$(sed -n '/^name = "libc"$/{n;s/^version = "\(.*\)"$/\1/p;q}' "$src/Cargo.lock")"
	for p in "$root"/patches/rust-libc/*.patch; do
		patch -d "$vendor/$libc" -p1 --no-backup-if-mismatch < "$p"
	done
	clearChecksums "$vendor/$libc"
	for dir in "$root"/patches/photocraft/*/; do
		dir="${dir%/}"
		[ -d "$vendor/${dir##*/}" ] || { echo "build-photocraft: no vendor/${dir##*/} (Cargo.lock changed?)" >&2; exit 1; }
		for p in "$dir"/*.patch; do
			patch -d "$vendor/${dir##*/}" -p1 --no-backup-if-mismatch < "$p"
		done
		clearChecksums "$vendor/${dir##*/}"
	done
	echo "build-photocraft: $(find "$vendor" -mindepth 1 -maxdepth 1 | wc -l) crates in $vendor"
}

build() {
	toolchain
	local t start
	for t in "$target" "$host"; do
		start=$SECONDS
		(cd "$src" && "$root/scripts/heavy-build.sh" -j 8 --mem-per-job 2 -- \
			cargo build --frozen --release -j '{JOBS}' -p photocraft-cli --target "$t" \
			--target-dir "$work/target" --config "$work/vendor-config.toml")
		echo "build-photocraft: $t built in $(( (SECONDS - start) / 60 )) min"
	done
}

stage() {
	local bin="$work/target/$target/release/photocraft-cli" f
	rm -rf "$stage" "$work/host"
	mkdir -p "$stage/bin" "$stage/data/photocraft-test" "$work/host"
	"$crossBin/$target-strip" -o "$stage/bin/photocraft-cli" "$bin"
	cp "$work/target/$host/release/photocraft-cli" "$work/host/"
	for f in "${testImages[@]}"; do
		cp "$src/$f" "$stage/data/photocraft-test/"
	done
	f="$stage/bin/photocraft-cli"
	"$crossBin/$target-readelf" -h "$f" | grep -q 'Type: *DYN' \
		|| { echo "build-photocraft: $f is not PIE" >&2; exit 1; }
	if "$crossBin/$target-readelf" -rW "$f" | grep -E 'R_AARCH64_(COPY|TLSDESC|TLS_TPREL|TLSLE|TLSIE)'; then
		echo "build-photocraft: $f has relocations Haiku's runtime_loader lacks" >&2; exit 1
	fi
	echo "build-photocraft: needs $("$crossBin/$target-readelf" -dW "$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' ')"
	find "$stage" "$work/host" -type f -printf 'build-photocraft: %p %s\n' | sed "s|$work/||" | sort
}

hosttest() {
	local tmp
	tmp="$(mktemp -d)"
	PCC_BIN="$work/host/photocraft-cli" PCC_DATA="$stage/data/photocraft-test" PCC_TMP="$tmp" \
		PCC_OUT=/dev/stdout PCC_SLEEP=0 sh "$root/tools/pi-tests/photocraft-cli.sh" > "$work/host-results.txt"
	rm -rf "$tmp"
	cat "$work/host-results.txt"
}

compare() {	# LOG
	local pcc='s/^.*\(PCC .*\)$/\1/p'
	if diff <(sed -n "$pcc" "$work/host-results.txt" | grep -v ': ms ') \
		<(tr -d '\r' < "$1" | sed -n "$pcc" | grep -v ': ms '); then
		echo "build-photocraft: $1 matches the host ($(grep -c ': exit ' "$work/host-results.txt") operations)"
	else
		echo "build-photocraft: $1 differs from the host (< host, > log)" >&2
		return 1
	fi
}

if [ "${1:-}" = compare ]; then
	compare "$2"
	exit
fi
steps=(source vendor build stage hosttest)
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
[ "$run" = 1 ] || { echo "build-photocraft: no step $first (${steps[*]})" >&2; exit 2; }
