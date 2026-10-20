#!/usr/bin/env bash
# build-llama2.sh — llama2.c (Andrej Karpathy's pure-C Llama 2 inference, the commit the Phoenix-RTOS
# port ran) for arm64 Haiku, with the TinyStories models, staged as a test tree:
# artifacts/llama2/non-packaged/{bin/llama2-run, bin/llama2-run-st, data/llama2/*}.
#
#   scripts/build-llama2.sh
#
# llama2-run uses OpenMP (libgomp, gcc's: in the image) across the 4 cores; llama2-run-st is the same
# code single-threaded. Models (git-ignored downloads, sha256-checked): stories15M.bin (60 MB) with the
# repository's tokenizer.bin, and stories260K.bin with its tok512.bin. Pi test: tools/pi-tests/llama2.sh.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tools="$root/sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku"
sysroot="$root/artifacts/sysroot-arm64"
dl="$root/artifacts/downloads/llama2"
work="$root/artifacts/llama2"
stage="$work/non-packaged"

commit=350e04fe35433e6d2941dce5a1f53308f87058eb
models=https://huggingface.co/karpathy/tinyllamas/resolve/main
fetch() {	# URL FILE SHA256
	if [ ! -f "$dl/$2" ] || ! echo "$3  $dl/$2" | sha256sum -c --quiet - 2>/dev/null; then
		curl -fsSL -o "$dl/$2.part" "$1"
		echo "$3  $dl/$2.part" | sha256sum -c --quiet - || { echo "build-llama2: $2: checksum mismatch" >&2; exit 1; }
		mv "$dl/$2.part" "$dl/$2"
	fi
}
mkdir -p "$dl"
fetch "https://github.com/karpathy/llama2.c/archive/$commit.tar.gz" "llama2.c-$commit.tar.gz" \
	9210e104192375f2c156fd24a84d2692c6b199f8ebbc2337551842c03cc1ddce
fetch "$models/stories15M.bin" stories15M.bin \
	cd590644d963867a2b6e5a1107f51fad663c41d79c149fbecbbb1f95fa81f49a
fetch "$models/stories260K/stories260K.bin" stories260K.bin \
	b0a507e7ad0f626624f17112325e66691f9076d622e1d3274d103d00299f2696
fetch "$models/stories260K/tok512.bin" tok512.bin \
	037cb335abb25d1fa9e8ecae30ed2a3a8ace9302862ebcdc05d51a6bbb10c312

rm -rf "$work"
mkdir -p "$work/src" "$stage/bin" "$stage/data/llama2"
tar -xzf "$dl/llama2.c-$commit.tar.gz" -C "$work/src" --strip-components=1
flags=(-O3 -march=armv8-a+crc -mtune=cortex-a72 -std=gnu11)
# (the cross gcc has no libgomp.spec, so -fopenmp only for the compile, libgomp linked by hand)
"$tools-gcc" --sysroot="$sysroot" "${flags[@]}" -fopenmp -c "$work/src/run.c" -o "$work/run-omp.o"
"$tools-gcc" --sysroot="$sysroot" "$work/run-omp.o" -o "$stage/bin/llama2-run" -lgomp -lm
"$tools-gcc" --sysroot="$sysroot" "${flags[@]}" "$work/src/run.c" -o "$stage/bin/llama2-run-st" -lm
"$tools-strip" "$stage/bin/llama2-run" "$stage/bin/llama2-run-st"
cp "$dl/stories15M.bin" "$dl/stories260K.bin" "$dl/tok512.bin" "$work/src/tokenizer.bin" "$stage/data/llama2/"
find "$stage" -type f -printf 'build-llama2: %P %s\n' | sort
