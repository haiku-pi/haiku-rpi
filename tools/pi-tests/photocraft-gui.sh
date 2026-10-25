#!/bin/sh
# photocraft-gui.sh — a UserBootscript for Photocraft's GUI app (apps/photocraft: eframe on winit's
# Wayland backend, wgpu on Vulkan) on Haiku's in-process Wayland server (X547's libwayland-client +
# wayland_server, as Wine's Wayland driver uses them); docs/design/photocraft.md, P3 and P4. Image:
#   scripts/build-photocraft.sh --only gui
#   scripts/stage-packages.sh --wine-runtime          (wayland, wayland_server, libxkbcommon,
#                                                     xkeyboard_config into artifacts/wayland-stage)
#   scripts/mkimage-pi4.sh --out artifacts/images/photocraft-gui.img --add-tree artifacts/wayland-stage \
#       --add-tree artifacts/photocraft/gui-non-packaged --bootscript tools/pi-tests/photocraft-gui.sh
# (QEMU virt works too, without a Vulkan device: scripts/qemu-virt.sh --image IMG --secs 300.)
# No WAYLAND_DISPLAY or XDG_RUNTIME_DIR: on Haiku the patched wayland-client connects with
# wl_display_connect(NULL) to the in-process server, and the patched winit picks Wayland there.
# First tools/haiku-tests/wlview (when staged: the server's half of the Vulkan bridge, "PCW wlview: WLV ...",
# "WLV result: 0 bad"). Runs, each under a time limit with a fresh settings folder (PHOTOCRAFT_CONFIG_DIR, so a crash marker
# of one run does not move the next to a safer GPU backend), each followed by a screenshot:
#   1. window: photocraft --new-instance on the JPEG test image, 60 s, then killed (the boot's first GPU
#      run: Mesa's shader cache cold for its shaders — the document appears only after V3D compiled them,
#      ~45 s on the Pi on 10-25; the window and its UI at once)
#   2. trace: the same with WAYLAND_DEBUG=client for 25 s: the protocol requests (globals bound,
#      xdg_toplevel, buffers) — only the interesting lines, the first 80; then the attach/commit counts per
#      wl_surface
#   3. close: the same, 20 s, then asked to quit (hey … quit: the window's close → eframe exits); it must
#      exit by itself within 15 s, without a debugger message on the serial console
#   4. desktop (P4, needs bin/keyinject and bin/photocraft-desktop-test, built with the GUI): photocraft
#      without a document; after 20 s Command+O (File › Open) must show the Tracker's file panel ("Open",
#      modal: the app gives it its window as parent), screenshot photocraft-desktop-panel.png. It starts in
#      /boot/home (no document yet), where the test image is copied as pcw-open-test.jpg. Command is
#      Haiku's shortcut key (left Alt by default), which wayland_server gives clients as Control (keyinject's
#      "%o"); Haiku's Control key reaches them as Alt (tools/pi-tests/wayland-keys.sh). "pcw-open-test" +
#      Return opens it (screenshot photocraft-desktop-doc.png after 15 s); Command+A, +C
#      puts the image on Haiku's clipboard: `clipboard -d` lists image/bitmap and image/png, and
#      photocraft-desktop-test reads it back at the JPEG's size ("copied image WxH = the document's: ok");
#      then asked to quit: "exit 0", and no "entered the debugger" on the serial console
#   5. safe: photocraft --safe-gpu (CPU compositing, wgpu still draws the window), 30 s
# Serial console lines: "PCW "; "PCW <step>: <line>" for the program's output (stdout and stderr, the
# first 120 lines), "PCW <step>: alive after N s" or "PCW <step>: exit N", "PCW <step>: screenshot N
# bytes" (/boot/home/photocraft-<step>.png), "PCW end".
# Positive markers, in order: "wl_ips_client_connected" (the in-process server loaded), the trace's
# registry globals (wl_compositor, xdg_wm_base, wl_shm, wl_seat, ...), xdg_wm_base.get_xdg_surface,
# get_toplevel, set_title("PhotoCraft") and the server's xdg_surface.configure, no
# "NoCompositor"/"NoWaylandLib" error; then the Vulkan surface on the toplevel's BView (patched wgpu-hal
# + wayland_server >= 0.1.20251004-8: "Haiku Wayland surface: wl_surface@N, view 0x..., SurfaceKHR(...)");
# on the Pi: the app's log naming the wgpu adapter (V3D 4.2), wl_surface commits after the frames in the
# trace ("trace: N wl_surface commits, M frame callbacks done"), the process alive after 45 s and the
# window in the screenshot. P4 (desktop): "desktop: panel \"Open\": yes", "PDT clip-image-get: <W>x<H>" at
# photocraft-masks.jpg's size, no "rfd: no dialogs"/"Failed to initialize arboard" lines, and no
# "couldn't find a Compose file" (libxkbcommon 1.13.2-2 ships the X11 locale database; XLOCALEDIR below).
# QEMU virt (no GPU, 10-25): everything up to the surface, then no adapter (no /dev/dri: Mesa cannot open
# renderD128), the app exits (and its crash guard starts it once more with --safe-gpu, which stops the
# same way: "window" shows both launches). Before the bridge it stopped at the surface: "Vulkan driver
# does not support VK_KHR_wayland_surface".
sleep "${PCW_SLEEP:-25}"
out="${PCW_OUT:-/dev/dprintf}"
bin="${PCW_BIN:-/boot/system/non-packaged/bin/photocraft}"
data="${PCW_DATA:-/boot/system/non-packaged/data/photocraft-test}"
tmp="${PCW_TMP:-/tmp/photocraft-gui}"
say() { echo "PCW $*" >> "$out"; }
# the stack comes as a tree in non-packaged (scripts/stage-packages.sh): libxkbcommon's compiled-in
# root is the package's
export XKB_CONFIG_ROOT=/boot/system/non-packaged/data/X11/xkb
export XLOCALEDIR=/boot/system/non-packaged/data/X11/locale
export PATH=/boot/system/non-packaged/bin:$PATH
export WGPU_BACKEND=vulkan
export RUST_BACKTRACE=1
export RUST_LOG="${RUST_LOG:-info,wgpu_hal=warn,wgpu_hal::vulkan::haiku=info,wgpu_core=warn,naga=warn}"
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
	if [ -n "$filter" ]; then grep -a -E "$filter" "$tmp/$step.txt" | head -n "${PCW_LINES:-80}"
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
# the server's half of Vulkan presenting, no GPU needed (tools/haiku-tests/wlview.cpp): a buffer-less
# toplevel drawn into its view, sized by its window geometry; screenshot while it is up (green, 800x500)
if [ -x "${bin%/*}/wlview" ]; then
	"${bin%/*}/wlview" 6 > "$tmp/wlview.txt" 2>&1 &
	pid=$!
	sleep 5
	screenshot -s /boot/home/photocraft-wlview.png > /dev/null 2>&1
	wait $pid
	say "wlview: exit $?"
	grep -a -E 'WLV|wl_ips|rror' "$tmp/wlview.txt" | head -n 40 | while IFS= read -r l; do say "wlview: $l"; done
fi
show window 60 "" --new-instance "$data/photocraft-masks.jpg"
WAYLAND_DEBUG=client show trace 25 \
	'wl_registry@[0-9]+\.(global|bind)|xdg_wm_base|xdg_surface|xdg_toplevel|wl_compositor|wl_shm|wl_seat|wl_output|Haiku Wayland surface|error|panic|Error' \
	--new-instance "$data/photocraft-masks.jpg"
# the frames' commits (wgpu-hal commits the wl_surface after each present) and the frame callbacks
say "trace: $(grep -a -c -E -- '-> wl_surface@[0-9]+\.commit\(' "$tmp/trace.txt") wl_surface commits, $(grep -a -c -E 'wl_callback@[0-9]+\.done\(' "$tmp/trace.txt") frame callbacks done"
# per surface: which ones get buffers (the cursor, winit's hidden frame subsurfaces?) and how many commits
grep -a -o -E -- '-> wl_surface@[0-9]+\.(attach|commit)' "$tmp/trace.txt" | sed 's/^-> //' | sort | uniq -c \
	| while read -r n what; do say "trace: $what x$n"; done
# closing: the toplevel destroyed, then exit() — wayland_server holds its loopers through libbe's static
# destructors (before: "bogus pointer (double free?)" in BTokenSpace::RemoveToken from ~BWindow at exit)
rm -rf "$tmp/config-close"
mkdir -p "$tmp/config-close"
PHOTOCRAFT_CONFIG_DIR="$tmp/config-close" "$bin" --new-instance "$data/photocraft-masks.jpg" > "$tmp/close.txt" 2>&1 &
pid=$!
sleep 20
say "close: hey: $(hey "$pid" quit 2>&1 | tr '\n' ' ' | cut -c1-120)"
waited=0
while [ $waited -lt 15 ] && kill -0 $pid 2> /dev/null; do sleep 1; waited=$((waited + 1)); done
if kill -0 $pid 2> /dev/null; then
	say "close: still running after 15 s"
	kill -9 $pid 2> /dev/null
	wait $pid 2> /dev/null
else
	wait $pid
	say "close: exit $? after $waited s"
fi
grep -a -E 'ERROR|panic|DEBUGGER' "$tmp/close.txt" | head -n 20 | while IFS= read -r l; do say "close: $l"; done
# desktop integration (P4): the file panel from File › Open, the system clipboard from Copy
if [ -x "${bin%/*}/keyinject" ]; then
	keys() { "${bin%/*}/keyinject" "$pid" "$1" "$2" 2>&1 | tail -n 1; }
	pdt="${bin%/*}/photocraft-desktop-test"
	# the panel starts in /boot/home (no document yet): the test image there under a name nothing else
	# starts with (the screenshots are photocraft-*.png)
	cp "$data/photocraft-masks.jpg" /boot/home/pcw-open-test.jpg
	want=$("$pdt" jpeg-size /boot/home/pcw-open-test.jpg 2>&1 | sed -n 's/^PDT jpeg-size: \([0-9]*x[0-9]*\)$/\1/p')
	rm -rf "$tmp/config-desktop"
	mkdir -p "$tmp/config-desktop"
	clipboard -r > /dev/null 2>&1
	PHOTOCRAFT_CONFIG_DIR="$tmp/config-desktop" "$bin" --new-instance > "$tmp/desktop.txt" 2>&1 &
	pid=$!
	sleep 20
	say "desktop: Command+O: $(keys PhotoCraft "%o")"
	found=no
	waited=0
	while [ $waited -lt 15 ] && kill -0 $pid 2> /dev/null; do
		if "${bin%/*}/keyinject" $pid Open "" > /dev/null 2>&1; then found=yes; break; fi
		sleep 1
		waited=$((waited + 1))
	done
	say "desktop: panel \"Open\": $found after $waited s"
	screenshot -s /boot/home/photocraft-desktop-panel.png > /dev/null 2>&1
	if [ $found = yes ]; then
		say "desktop: open: $(keys Open "pcw-open-test~")"
		sleep 15
		screenshot -s /boot/home/photocraft-desktop-doc.png > /dev/null 2>&1
		say "desktop: select all, copy: $(keys PhotoCraft "%a%c")"
		sleep 5
		clipboard -d 2>&1 | grep -a -E 'image/|_frame|text/' | head -n 6 | while IFS= read -r l; do say "desktop: clipboard -d: $l"; done
		"$pdt" clip-image-get > "$tmp/desktop-clip.txt" 2>&1
		grep -a PDT "$tmp/desktop-clip.txt" | while IFS= read -r l; do say "desktop: $l"; done
		got=$(sed -n 's/^PDT clip-image-get: \([0-9]*x[0-9]*\) .*/\1/p' "$tmp/desktop-clip.txt")
		if [ -n "$want" ] && [ "$got" = "$want" ]; then say "desktop: copied image $got = the document's: ok"
		else say "desktop: copied image ${got:-none}, the document ${want:-?}: BAD"; fi
	fi
	say "desktop: hey: $(hey "$pid" quit 2>&1 | tr '\n' ' ' | cut -c1-120)"
	waited=0
	while [ $waited -lt 15 ] && kill -0 $pid 2> /dev/null; do sleep 1; waited=$((waited + 1)); done
	if kill -0 $pid 2> /dev/null; then
		say "desktop: still running after 15 s"
		kill -9 $pid 2> /dev/null
		wait $pid 2> /dev/null
	else
		wait $pid
		say "desktop: exit $? after $waited s"
	fi
	grep -a -E 'rfd|arboard|clipboard|Compose|XKB|panic|ERROR|DEBUGGER' "$tmp/desktop.txt" | head -n 20 \
		| while IFS= read -r l; do say "desktop: $(echo "$l" | cut -c1-240)"; done
	rm -f /boot/home/pcw-open-test.jpg
fi
show safe 30 "" --new-instance --safe-gpu "$data/photocraft-masks.jpg"
sync
say end
