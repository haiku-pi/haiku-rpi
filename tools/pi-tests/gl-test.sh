#!/bin/sh
# gl-test.sh — a UserBootscript for test images with the GL stack (scripts/build-gl-stack.sh, added
# with mkimage-pi4.sh --add-tree artifacts/gl-stack/non-packaged): after the desktop is up, runs
# gltri (headless GLES) on the GPU (v3d when /dev/dri/renderD128 exists, else softpipe), then on
# softpipe for comparison, then glview (a BGLView window, desktop GL) the same two ways. Serial
# console lines: "GLT " (gltri's and the markers here), "GLW " (glview's); Mesa's messages go to
# the same place.
sleep 20
out=/dev/dprintf
bin=/boot/system/non-packaged/bin
say() { echo "GLT $*" > $out; }
run() {
	# a hung GPU job must not stall the boot script forever
	if command -v timeout > /dev/null 2>&1; then timeout 120 "$@"; else "$@"; fi
}
say "boot-begin dri: $(ls /dev/dri 2>&1)"
run $bin/gltri -n 100 > $out 2>&1
say "hw-exit $?"
LIBGL_ALWAYS_SOFTWARE=1 run $bin/gltri -n 10 > $out 2>&1
say "sw-exit $?"
run $bin/glview -s 10 > $out 2>&1
say "glview-hw-exit $?"
LIBGL_ALWAYS_SOFTWARE=1 run $bin/glview -s 5 > $out 2>&1
say "glview-sw-exit $?"
say end
