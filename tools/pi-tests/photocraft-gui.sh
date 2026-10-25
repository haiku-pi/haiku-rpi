#!/bin/sh
# photocraft-gui.sh — a UserBootscript for Photocraft's GUI app (apps/photocraft: eframe on winit's
# Wayland backend, wgpu on Vulkan) on Haiku's in-process Wayland server (X547's libwayland-client +
# wayland_server, as Wine's Wayland driver uses them); docs/design/photocraft.md, P3. Image:
#   scripts/build-photocraft.sh --only gui
#   scripts/stage-packages.sh --wine-runtime          (wayland, wayland_server, libxkbcommon,
#                                                     xkeyboard_config into artifacts/wayland-stage)
#   scripts/mkimage-pi4.sh --out artifacts/images/photocraft-gui.img --add-tree artifacts/wayland-stage \
#       --add-tree artifacts/photocraft/gui-non-packaged --bootscript tools/pi-tests/photocraft-gui.sh
# (QEMU virt works too, without a Vulkan device: scripts/qemu-virt.sh --image IMG --secs 300.)
# No WAYLAND_DISPLAY or XDG_RUNTIME_DIR: on Haiku the patched wayland-client connects with
# wl_display_connect(NULL) to the in-process server, and the patched winit picks Wayland there.
# Runs, each under a time limit with a fresh settings folder (PHOTOCRAFT_CONFIG_DIR, so a crash marker
# of one run does not move the next to a safer GPU backend), each followed by a screenshot:
#   1. window: photocraft --new-instance on the JPEG test image, 45 s, then killed
#   2. trace: the same with WAYLAND_DEBUG=client for 25 s: the protocol requests (globals bound,
#      xdg_toplevel, buffers) — only the interesting lines, the first 80
#   3. safe: photocraft --safe-gpu (CPU compositing, wgpu still draws the window), 30 s
# Serial console lines: "PCW "; "PCW <step>: <line>" for the program's output (stdout and stderr, the
# first 120 lines), "PCW <step>: alive after N s" or "PCW <step>: exit N", "PCW <step>: screenshot N
# bytes" (/boot/home/photocraft-<step>.png), "PCW end".
# Positive markers, in order: "wl_ips_client_connected" (the in-process server loaded), the trace's
# registry globals (wl_compositor, xdg_wm_base, wl_shm, wl_seat, ...), xdg_wm_base.get_xdg_surface,
# get_toplevel, set_title("PhotoCraft") and the server's xdg_surface.configure, no
# "NoCompositor"/"NoWaylandLib" error; later (once presenting works) the app's log naming the wgpu
# adapter (V3D 4.2), the process alive after 45 s and the window in the screenshot.
# Expected stop today (QEMU virt, 10-25: everything above up to the configure): eframe's wgpu surface,
# "Vulkan driver does not support VK_KHR_wayland_surface" — the Vulkan loader and Mesa on Haiku have no
# Wayland WSI (Haiku's is VK_EXT_headless_surface + VkHaikuSurfaceCreateInfoMESA on a BView), so the app
# exits 1 s after the toplevel exists (and its crash guard starts it once more with --safe-gpu, which
# stops the same way: "window" shows both launches).
sleep "${PCW_SLEEP:-25}"
out="${PCW_OUT:-/dev/dprintf}"
bin="${PCW_BIN:-/boot/system/non-packaged/bin/photocraft}"
data="${PCW_DATA:-/boot/system/non-packaged/data/photocraft-test}"
tmp="${PCW_TMP:-/tmp/photocraft-gui}"
say() { echo "PCW $*" >> "$out"; }
# the stack comes as a tree in non-packaged (scripts/stage-packages.sh): libxkbcommon's compiled-in
# root is the package's
export XKB_CONFIG_ROOT=/boot/system/non-packaged/data/X11/xkb
export PATH=/boot/system/non-packaged/bin:$PATH
export WGPU_BACKEND=vulkan
export RUST_BACKTRACE=1
export RUST_LOG="${RUST_LOG:-info,wgpu_hal=warn,wgpu_core=warn,naga=warn}"
export VK_LOADER_DEBUG="${VK_LOADER_DEBUG:-error,warn}"
date -s "@$(stat -c %Y /boot/home/config/settings/boot/UserBootscript)" > /dev/null 2>&1
# show STEP SECS FILTER ARGS...: run the app with ARGS for SECS seconds (then a screenshot and kill -9:
# a crashed program waits in the debugger), its output into STEP.txt; FILTER: a grep -E pattern for
# the lines to report, or "" for all
show() {
	step=$1 secs=$2 filter=$3
	shift 3
	rm -rf "$tmp/config-$step"
	mkdir -p "$tmp/config-$step"
	PHOTOCRAFT_CONFIG_DIR="$tmp/config-$step" "$bin" "$@" > "$tmp/$step.txt" 2>&1 &
	pid=$!
	waited=0
	while [ $waited -lt "$secs" ] && kill -0 $pid 2> /dev/null; do sleep 1; waited=$((waited + 1)); done
	shot=/boot/home/photocraft-$step.png
	screenshot -s "$shot" > /dev/null 2>&1
	if kill -0 $pid 2> /dev/null; then
		say "$step: alive after $secs s"
		kill -9 $pid 2> /dev/null
		wait $pid 2> /dev/null
	else
		wait $pid
		say "$step: exit $? after $waited s"
	fi
	say "$step: screenshot $(stat -c %s "$shot" 2> /dev/null || echo none) bytes"
	if [ -n "$filter" ]; then grep -a -E "$filter" "$tmp/$step.txt" | head -n 80
	else head -n 120 "$tmp/$step.txt"; fi | while IFS= read -r l; do say "$step: $(echo "$l" | cut -c1-240)"; done
	say "$step: $(wc -l < "$tmp/$step.txt") lines of output"
}
say begin
say "bin: $(ls -l "$bin" 2>&1 | awk '{print $5, $NF}')"
for lib in libwayland-client.so.0 libwayland-cursor.so.0 wayland-server-inproc.so libxkbcommon.so.0 \
		libvulkan.so.1 libffi.so.8; do
	say "lib: $lib $(ls /boot/system/non-packaged/lib/$lib /boot/system/lib/$lib 2> /dev/null | tr '\n' ' ')"
done
say "icd: $(ls /boot/system/add-ons/vulkan/icd.d /boot/system/non-packaged/add-ons/vulkan/icd.d 2> /dev/null | tr '\n' ' ')"
say "dri: $(ls /dev/dri 2>&1 | tr '\n' ' ')"
rm -rf "$tmp"
mkdir -p "$tmp"
cd "$tmp" || exit 1
show window 45 "" --new-instance "$data/photocraft-masks.jpg"
WAYLAND_DEBUG=client show trace 25 \
	'wl_registry@[0-9]+\.(global|bind)|xdg_wm_base|xdg_surface|xdg_toplevel|wl_compositor|wl_shm|wl_seat|wl_output|error|panic|Error' \
	--new-instance "$data/photocraft-masks.jpg"
show safe 30 "" --new-instance --safe-gpu "$data/photocraft-masks.jpg"
sync
say end
