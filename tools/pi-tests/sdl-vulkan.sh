#!/bin/sh
# sdl-vulkan.sh — a UserBootscript for SDL2's Vulkan path: sdlvk (tools/gl-tests/sdlvk.c, staged by
# scripts/build-games.sh) opens an SDL_WINDOW_VULKAN window, gets its surface from
# SDL_Vulkan_CreateSurface (SDL's Haiku driver, patches/libsdl2: Mesa's Haiku WSI on the window's
# view) and renders a triangle on a changing clear colour, in its variants. Needs the GL stack
# (libvulkan, V3DV) and the games tree (the Vulkan-enabled libSDL2, sdlvk) in the image:
#
#   scripts/mkimage-pi4.sh --in <pi-mmc image> --add-tree artifacts/gl-stack/non-packaged \
#       --add-tree artifacts/games/non-packaged --bootscript tools/pi-tests/sdl-vulkan.sh \
#       --out artifacts/images/haiku-pi4-sdlvk.img
#
# Serial console lines: "SVK " (sdlvk's and the markers here), "wsi_haiku: N frames/s drawn" (the
# WSI's rate, HAIKU_VK_FPS); the loader's and Mesa's messages go to the same place. HDMI shows the
# window: a magenta triangle on a slowly changing purple/blue background.
#
# A good run: per variant "SVK begin SDL 2.32.10, video driver haiku", "SVK instance extensions from
# SDL (2): VK_KHR_surface VK_EXT_headless_surface", "SVK SDL_Vulkan_CreateSurface ok", "SVK device
# V3D 4.2...", "SVK swapchain 1: surface current extent WxH, SDL drawable WxH: match ok", fps lines,
# "SVK PASS" and "SVK <variant>-exit 0"; the resize variant also "SVK swapchain 2: ... match ok".
sleep 20
out=/dev/dprintf
bin=/boot/system/non-packaged/bin
say() { echo "SVK $*" > $out; }
run() {
	# a hung GPU job must not stall the boot script forever
	if command -v timeout > /dev/null 2>&1; then timeout 120 "$@"; else "$@"; fi
}

say "boot-begin dri: $(ls /dev/dri 2>&1)"
say "libSDL2: $(ls -l /boot/system/non-packaged/lib/libSDL2-2.0.so.0 2>&1)"

# 1. FIFO, 640x480
run env HAIKU_VK_FPS=1 VK_LOADER_DEBUG=error,warn $bin/sdlvk -s 12 > $out 2>&1
say "fifo-exit $?"

# 2. MAILBOX at 1280x720
run env HAIKU_VK_FPS=1 VK_LOADER_DEBUG=error,warn $bin/sdlvk -s 10 -W 1280 -H 720 -m mailbox > $out 2>&1
say "mailbox-exit $?"

# 3. the window grows halfway: a resize event, the swapchain is made again at the new size
run env HAIKU_VK_FPS=1 VK_LOADER_DEBUG=error,warn $bin/sdlvk -s 10 -r > $out 2>&1
say "resize-exit $?"

say end
