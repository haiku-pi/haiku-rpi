#!/bin/sh
# vkwindow.sh — a UserBootscript for test images with the GL stack and Vulkan (scripts/build-gl-stack.sh,
# added with mkimage-pi4.sh --add-tree artifacts/gl-stack/non-packaged): after the desktop is up, runs
# vkcube (a spinning cube in a window through Mesa's Haiku WSI, V3DV) in its variants, then vktest
# as the headless regression check. Serial console lines: "VKW " (vkcube's and the markers here),
# "VK " (vktest's), "wsi_haiku: " (the WSI's rate of frames drawn, HAIKU_VK_FPS); the loader's and
# Mesa's messages go to the same place. HDMI shows the window.
#
#   scripts/mkimage-pi4.sh --add-tree artifacts/gl-stack/non-packaged \
#       --bootscript tools/pi-tests/vkwindow.sh --out artifacts/images/haiku-pi4-vkwindow.img
#
# A good run: every "VKW ... -exit 0", each vkcube with "VKW surface current extent ... the view's ok",
# "VKW screen ...: corners clear colour, centre cube colour ok" and "VKW PASS"; fps lines and
# "wsi_haiku: N frames/s drawn" in between.
sleep 20
out=/dev/dprintf
bin=/boot/system/non-packaged/bin
say() { echo "VKW $*" > $out; }
run() {
	# a hung GPU job must not stall the boot script forever
	if command -v timeout > /dev/null 2>&1; then timeout 120 "$@"; else "$@"; fi
}

say "boot-begin dri: $(ls /dev/dri 2>&1)"

# 1. a render thread presents (the WSI's presenter thread draws), FIFO
run env HAIKU_VK_FPS=1 VK_LOADER_DEBUG=error,warn $bin/vkcube -s 15 > $out 2>&1
say "fifo-exit $?"

# 1b. the same with the presenter copying the frames (no import of the window's bitmaps): tells
#     a broken import from a broken WSI
run env HAIKU_VK_FPS=1 HAIKU_VK_NO_IMPORT=1 VK_LOADER_DEBUG=error,warn $bin/vkcube -s 8 > $out 2>&1
say "copy-exit $?"

# 2. MAILBOX: the presenter draws the newest frame and drops older ones
run env HAIKU_VK_FPS=1 VK_LOADER_DEBUG=error,warn $bin/vkcube -s 8 -m mailbox > $out 2>&1
say "mailbox-exit $?"

# 3. the window's own thread renders and presents (the WSI draws in that thread)
run env HAIKU_VK_FPS=1 VK_LOADER_DEBUG=error,warn $bin/vkcube -s 8 -w > $out 2>&1
say "window-thread-exit $?"

# 4. the window grows halfway: the swapchain goes suboptimal and is made again
run env HAIKU_VK_FPS=1 VK_LOADER_DEBUG=error,warn $bin/vkcube -s 10 -r > $out 2>&1
say "resize-exit $?"

# 5. a full-screen-sized window (the present path's cost at 1080p)
run env HAIKU_VK_FPS=1 VK_LOADER_DEBUG=error,warn $bin/vkcube -s 10 -W 1600 -H 900 > $out 2>&1
say "large-exit $?"

# 6. headless Vulkan still works (V3DV has a host memory type now)
run env VK_LOADER_DEBUG=error,warn $bin/vktest > $out 2>&1
say "vktest-exit $?"

say end
