#!/bin/sh
# photocraft-gpu.sh — a UserBootscript for Photocraft's GPU compositor (crates/gpu, wgpu) on V3DV,
# headless (scripts/build-photocraft.sh gpu; docs/design/photocraft.md, P2). Image:
#   scripts/mkimage-pi4.sh --out artifacts/images/photocraft-gpu.img \
#       --add-tree artifacts/photocraft/gpu-non-packaged --bootscript tools/pi-tests/photocraft-gpu.sh
# Runs, each under a timeout, with WGPU_BACKEND=vulkan (the parity tests then fail instead of
# skipping when there is no adapter, no device or no Rgba32Float target):
#   1. photocraft-gpu-probe: the adapter, its limits and formats, four documents composited on the
#      GPU and checked against the CPU compositor; then the MD5 of every result file
#   2. photocraft-gpu-unit: the crate's unit tests (CPU: planning, bounds, effect fields)
#   3. reload: three of the integration tests as they are (each test creates its own Vulkan
#      instance on its own thread): on Haiku arm64 the second vkCreateInstance jumps to NULL in
#      V3DV once the driver was unloaded (tools/haiku-tests/vkloop.c -t reproduces it without Rust);
#      reported, not graded
#   4. photocraft-gpu-it: the integration tests (GPU vs CPU parity, pipeline errors, timing,
#      uniform limits, vector masks) without device_loss, then device_loss alone (it loses the
#      device on purpose), both with the driver preloaded (LD_PRELOAD: it then stays loaded
#      between instances, which avoids the crash of 3)
# Serial console lines: "PCG "; "PCG <step>: <line>" for each program's output (stdout and stderr),
# "PCG <step>: exit N" and "PCG <step>: ms N", "PCG md5 <file> <md5>", "PCG end". The same script
# runs on the host build (PCG_* variables below; scripts/build-photocraft.sh gpuhost). A crashed program
# stops in the debug_server and ignores SIGTERM: every step runs under timeout -s KILL (budgets sum to
# 41 min with the boot's ~2 min: scripts/netboot-cycle.sh --secs 2700). Grading:
# scripts/build-photocraft.sh gpucompare LOG (the CPU MD5s equal the host's; the GPU's are
# per driver).
sleep "${PCG_SLEEP:-20}"
out="${PCG_OUT:-/dev/dprintf}"
bin="${PCG_BIN:-/boot/system/non-packaged/bin}"
tmp="${PCG_TMP:-/tmp/photocraft-gpu}"
preload="${PCG_PRELOAD-/boot/system/lib/libvulkan_broadcom.so}"
say() { echo "PCG $*" >> "$out"; }	# (>>: on the host, out is a file)
now() { date +%s%N | cut -c1-13; }	# ms
run() {	# STEP SECS PROGRAM ARGS...
	step=$1 secs=$2
	shift 2
	t0=$(now)
	if command -v timeout > /dev/null 2>&1; then timeout -s KILL "$secs" "$@" > "$step.txt" 2>&1
	else "$@" > "$step.txt" 2>&1; fi
	status=$?
	t1=$(now)
	while IFS= read -r l; do say "$step: $l"; done < "$step.txt"
	say "$step: exit $status"
	say "$step: ms $((t1 - t0))"
}
export WGPU_BACKEND=vulkan
export VK_LOADER_DEBUG="${VK_LOADER_DEBUG:-error,warn}"
say begin
say "dri: $(ls /dev/dri 2>&1 | tr '\n' ' ')"
say "icd: $(ls /boot/system/add-ons/vulkan/icd.d /boot/system/non-packaged/add-ons/vulkan/icd.d 2>/dev/null | tr '\n' ' ')"
rm -rf "$tmp"
mkdir -p "$tmp/out"
cd "$tmp" || exit 1
run probe 300 "$bin/photocraft-gpu-probe" "$tmp/out"
for f in out/*; do
	[ -f "$f" ] && say "md5 ${f#out/} $(md5sum < "$f" | cut -c1-32)"
done
rm -rf "$tmp/out"
run unit 120 "$bin/photocraft-gpu-unit" --test-threads=4
run reload 120 "$bin/photocraft-gpu-it" --test-threads=1 parity::blend_
run it 1500 env LD_PRELOAD="$preload" "$bin/photocraft-gpu-it" --test-threads=1 --nocapture --skip device_loss
run device-loss 300 env LD_PRELOAD="$preload" "$bin/photocraft-gpu-it" --test-threads=1 --nocapture device_loss
say end
