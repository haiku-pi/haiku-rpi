#!/usr/bin/env bash
# build-photocraft.sh — Photocraft's command-line tool (photocraft-cli, a photo editor in Rust:
# https://github.com/storytold/photocraft) for arm64 Haiku, and the same commit for this x86_64 Linux
# host, so their outputs can be compared (docs/design/photocraft.md, phase P1).
#
#   scripts/build-photocraft.sh [STEP]        (start at STEP; the earlier ones must have run)
#   scripts/build-photocraft.sh --only STEP   (just that step)
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
#   gpu       the GPU compositor, headless (phase P2): tools/photocraft-gpu-test (photocraft-gpu-probe and
#             crates/gpu's integration tests as photocraft-gpu-it) and crates/gpu's unit tests
#             (photocraft-gpu-unit), release/test builds for both targets; staged stripped into
#             artifacts/photocraft/gpu-non-packaged/bin/ (arm64) and artifacts/photocraft/host-gpu/
#   gpuhost   tools/pi-tests/photocraft-gpu.sh run on the host build (this machine's default Vulkan
#             adapter), into artifacts/photocraft/host-gpu-results.txt
#   gui       the GUI app (phase P3: apps/photocraft, eframe on winit's Wayland backend + wgpu), release,
#             for arm64 Haiku only. Staged stripped into artifacts/photocraft/gui-non-packaged/{bin/photocraft,
#             data/photocraft-test/*}; checked PIE and free of the relocations Haiku lacks. libwayland-client,
#             -cursor, libxkbcommon and libvulkan are dlopened at run time (wayland-sys's dlopen feature,
#             which wgpu-hal turns on), not linked — so no pkg-config for the target (were dlopen ever off,
#             wayland-sys would need PKG_CONFIG_{ALLOW_CROSS,SYSROOT_DIR_*,LIBDIR_*} at the sysroot's
#             develop/lib/pkgconfig); the check is that the binary names libwayland-client.so.0
#
#   scripts/build-photocraft.sh compare LOG   (a UART or QEMU log of tools/pi-tests/photocraft-cli.sh)
#             diff its "PCC " lines against host-results.txt, wall times left out; exit 0 if equal
#   scripts/build-photocraft.sh gpucompare LOG   (a log of tools/pi-tests/photocraft-gpu.sh)
#             the CPU results' MD5s equal the host's; the probe's cases all within the tolerance; every
#             test run "ok" with as many tests passed as on the host; prints the skips and the reload step
#             (several Vulkan instances without the driver preloaded: reported only). GPU results are
#             compared with the CPU compositor on the machine itself (their MD5s differ per driver)
#
# Toolchain: scripts/build-rust.sh --version 1.99.1 (Photocraft needs rust-version 1.95, edition 2024).
# Features: the defaults (no heif: libheif is C).
# Pi test: scripts/mkimage-pi4.sh --add-tree artifacts/photocraft/non-packaged
#          --bootscript tools/pi-tests/photocraft-cli.sh
#          (GPU: --add-tree artifacts/photocraft/gpu-non-packaged --bootscript tools/pi-tests/photocraft-gpu.sh)
#          (GUI: scripts/stage-packages.sh --wine-runtime, then --add-tree artifacts/wayland-stage
#          --add-tree artifacts/photocraft/gui-non-packaged --bootscript tools/pi-tests/photocraft-gui.sh)
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
gpuTest="$root/tools/photocraft-gpu-test"
gpuStage="$work/gpu-non-packaged"
guiStage="$work/gui-non-packaged"

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
	cleanPatched "$root"/patches/rust-libc "$root"/patches/photocraft/*/
}

# Cargo never rebuilds a registry (here: vendored) crate because its files changed, so after a crate's
# patches change, its old Haiku artifacts would still be linked. $work/patches.md5 records each patched
# crate's patches; for every crate whose patches differ from the previous vendor step's (or are new),
# remove its artifacts for the Haiku target (all versions of the name: cargo clean ignores the version)
# in each target directory whose workspace has it.
cleanPatched() {	# PATCH_DIR...
	local list="$work/patches.md5" new dir crate sum changed=() tdir specs c profile
	new="$(mktemp)"
	for dir in "$@"; do
		dir="${dir%/}" crate="${dir##*/}"
		[ "$crate" != rust-libc ] || crate=libc-any	# patches/rust-libc: the libc crate
		sum="$(cat "$dir"/*.patch | md5sum | cut -c1-32)"
		echo "$crate $sum" >> "$new"
		grep -qxF "$crate $sum" "$list" 2> /dev/null || changed+=("${crate%-*}")
	done
	for dir in "$src:$work/target" "$gpuTest:$work/target-gpu"; do
		tdir="${dir#*:}" dir="${dir%%:*}"
		[ -d "$tdir/$target" ] || continue
		specs=()
		for c in "${changed[@]}"; do
			if grep -q "^name = \"$c\"\$" "$dir/Cargo.lock"; then specs+=(-p "$c"); fi
		done
		[ ${#specs[@]} -gt 0 ] || continue
		echo "build-photocraft: patches changed: cleaning ${specs[*]} in $tdir/$target"
		for profile in dev release; do	# (cargo clean -p cleans one profile, dev by default)
			(cd "$dir" && cargo clean --frozen "${specs[@]}" --profile "$profile" --target "$target" \
				--target-dir "$tdir" --config "$work/vendor-config.toml")
		done
	done
	mv "$new" "$list"
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
	checkElf "$stage/bin/photocraft-cli"
	find "$stage" "$work/host" -type f -printf 'build-photocraft: %p %s\n' | sed "s|$work/||" | sort
}

checkElf() {	# FILE: an arm64 Haiku executable the runtime_loader can start
	local f="$1"
	"$crossBin/$target-readelf" -h "$f" | grep -q 'Type: *DYN' \
		|| { echo "build-photocraft: $f is not PIE" >&2; exit 1; }
	if "$crossBin/$target-readelf" -rW "$f" | grep -E 'R_AARCH64_(COPY|TLSDESC|TLS_TPREL|TLSLE|TLSIE)'; then
		echo "build-photocraft: $f has relocations Haiku's runtime_loader lacks" >&2; exit 1
	fi
	echo "build-photocraft: ${f##*/} needs $("$crossBin/$target-readelf" -dW "$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' ')"
}

executable() {	# JSON TARGET TEST: the executable cargo built for TARGET (TEST: true for a test harness)
	python3 -c 'import json, sys
for line in open(sys.argv[1]):
    if not line.startswith("{"):
        continue
    m = json.loads(line)
    if m.get("reason") == "compiler-artifact" and m["target"]["name"] == sys.argv[2] \
            and m.get("executable") and str(m["profile"]["test"]).lower() == sys.argv[3]:
        print(m["executable"])' "$@" | tail -n 1
}

gpu() {
	toolchain
	local t start json probe it unit dir
	rm -rf "$gpuStage" "$work/host-gpu"
	mkdir -p "$gpuStage/bin" "$work/host-gpu"
	for t in "$target" "$host"; do
		start=$SECONDS
		json="$work/gpu-build-$t.json"
		# the probe and the integration tests: optimised (the parity tests composite large documents)
		(cd "$gpuTest" && "$root/scripts/heavy-build.sh" -j 8 --mem-per-job 2 -- \
			cargo test --frozen --release --no-run -j '{JOBS}' --target "$t" --target-dir "$work/target-gpu" \
			--config "$work/vendor-config.toml" --message-format json-render-diagnostics) > "$json"
		# the unit tests, as upstream builds them (the test profile) in the Photocraft workspace
		(cd "$src" && "$root/scripts/heavy-build.sh" -j 8 --mem-per-job 2 -- \
			cargo test --frozen --no-run --lib -p photocraft-gpu -j '{JOBS}' --target "$t" --target-dir "$work/target" \
			--config "$work/vendor-config.toml" --message-format json-render-diagnostics) >> "$json"
		probe="$(executable "$json" photocraft-gpu-probe false)"
		it="$(executable "$json" photocraft-gpu-it true)"
		unit="$(executable "$json" photocraft_gpu true)"
		[ -n "$probe" ] && [ -n "$it" ] && [ -n "$unit" ] \
			|| { echo "build-photocraft: $t: no executable in $json" >&2; exit 1; }
		if [ "$t" = "$target" ]; then
			dir="$gpuStage/bin"
			"$crossBin/$target-strip" -o "$dir/photocraft-gpu-probe" "$probe"
			"$crossBin/$target-strip" -o "$dir/photocraft-gpu-it" "$it"
			"$crossBin/$target-strip" -o "$dir/photocraft-gpu-unit" "$unit"
			for f in "$dir"/*; do checkElf "$f"; done
		else
			cp "$probe" "$work/host-gpu/photocraft-gpu-probe"
			cp "$it" "$work/host-gpu/photocraft-gpu-it"
			cp "$unit" "$work/host-gpu/photocraft-gpu-unit"
		fi
		echo "build-photocraft: gpu $t built in $(( (SECONDS - start) / 60 )) min"
	done
	find "$gpuStage" "$work/host-gpu" -type f -printf 'build-photocraft: %p %s\n' | sed "s|$work/||" | sort
}

gpuhost() {
	local tmp
	tmp="$(mktemp -d)"
	PCG_BIN="$work/host-gpu" PCG_TMP="$tmp" PCG_OUT=/dev/stdout PCG_SLEEP=0 PCG_PRELOAD= \
		sh "$root/tools/pi-tests/photocraft-gpu.sh" > "$work/host-gpu-results.txt"
	rm -rf "$tmp"
	grep -E 'PCG (probe: (chosen|result)|md5|[a-z-]+: (exit|test result))' "$work/host-gpu-results.txt"
}

gpucompare() {	# LOG
	local pcg='s/^.*\(PCG .*\)$/\1/p' log hostLog bad=0 step want got
	log="$(mktemp)" hostLog="$work/host-gpu-results.txt"
	tr -d '\r' < "$1" | sed -n "$pcg" > "$log"
	grep -q '^PCG end' "$log" || { echo "build-photocraft: $1 has no \"PCG end\" (cut short?)" >&2; bad=1; }
	grep -E '^PCG probe: (chosen|compositor|limits below)' "$log"
	if diff <(grep -E '^PCG md5 .*\.cpu ' "$hostLog") <(grep -E '^PCG md5 .*\.cpu ' "$log"); then
		echo "build-photocraft: CPU reference MD5s equal the host's ($(grep -c -E '^PCG md5 .*\.cpu ' "$log"))"
	else
		echo "build-photocraft: CPU reference MD5s differ from the host's (< host, > log)" >&2; bad=1
	fi
	grep -E '^PCG probe: case ' "$log"
	grep -q '^PCG probe: exit 0$' "$log" || { echo "build-photocraft: the probe failed" >&2; bad=1; }
	for step in unit it device-loss; do
		want="$(grep -E "^PCG $step: test result:" "$hostLog" | sed 's/; finished in.*//')"
		got="$(grep -E "^PCG $step: test result:" "$log" | sed 's/; finished in.*//')"
		echo "build-photocraft: $step: ${got:-no result} (host: ${want:-none})"
		if [ -z "$got" ] || [ "$got" != "$want" ] || ! grep -q "^PCG $step: exit 0\$" "$log"; then
			grep -E "^PCG $step: (test .*FAILED|---- |thread .* panicked|exit )" "$log" | head -n 40 >&2
			bad=1
		fi
	done
	echo "build-photocraft: reload (not graded): $(grep -E '^PCG reload: (test result|exit)' "$log" | sed 's/^PCG reload: //' | tr '\n' ' ')"
	grep -E '^PCG [a-z-]+: .*(skipping|SKIP )' "$log" | sort | uniq -c | sed 's/^/build-photocraft: skip /'
	rm -f "$log"
	[ "$bad" = 0 ] && echo "build-photocraft: $1 passes"
	return "$bad"
}

gui() {
	toolchain
	local start=$SECONDS bin="$work/target/$target/release/photocraft" f
	(cd "$src" && "$root/scripts/heavy-build.sh" -j 8 --mem-per-job 2 -- \
		cargo build --frozen --release -j '{JOBS}' -p photocraft --bin photocraft --target "$target" \
		--target-dir "$work/target" --config "$work/vendor-config.toml")
	echo "build-photocraft: gui $target built in $(( (SECONDS - start) / 60 )) min"
	rm -rf "$guiStage"
	mkdir -p "$guiStage/bin" "$guiStage/data/photocraft-test"
	"$crossBin/$target-strip" -o "$guiStage/bin/photocraft" "$bin"
	for f in "${testImages[@]}"; do
		cp "$src/$f" "$guiStage/data/photocraft-test/"
	done
	checkElf "$guiStage/bin/photocraft"
	grep -q -a 'libwayland-client\.so\.0' "$guiStage/bin/photocraft" \
		|| { echo "build-photocraft: photocraft does not load libwayland-client.so.0" >&2; exit 1; }
	find "$guiStage" -type f -printf 'build-photocraft: %p %s\n' | sed "s|$work/||" | sort
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

case "${1:-}" in
compare|gpucompare) "$1" "$2"; exit ;;
--only) case "${2:-}" in source) source_ ;; vendor|build|stage|hosttest|gpu|gpuhost|gui) "$2" ;;
	*) echo "build-photocraft: no step ${2:-}" >&2; exit 2 ;; esac; exit ;;
esac
steps=(source vendor build stage hosttest gpu gpuhost gui)
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
