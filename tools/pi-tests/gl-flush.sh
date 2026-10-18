#!/bin/sh
# gl-flush.sh — a UserBootscript for the windowed-GL wedge: glview (a BGLView window) as is, then
# with Mesa flushing after every draw (V3D_DEBUG=always_flush: one draw per job, so a wedge points
# at one draw), the same without any glClear (-c), then into an FBO (-f, the path that renders) as
# the control. A wedged job is dumped
# by the v3d driver ("render list of job N wedged", its registers and buffers) and the GPU reset.
# Serial console lines: "GLT " (markers), "GLW " (glview).
sleep 20
out=/dev/dprintf
bin=/boot/system/non-packaged/bin
say() { echo "GLT $*" > $out; }
run() {
	if command -v timeout > /dev/null 2>&1; then timeout 60 "$@"; else "$@"; fi
}
say "window"
run $bin/glview -s 3 > $out 2>&1
say "window-exit $?"
say "window always_flush"
V3D_DEBUG=always_flush run $bin/glview -s 3 > $out 2>&1
say "window-flush-exit $?"
say "window always_flush no clear"
V3D_DEBUG=always_flush run $bin/glview -c -s 3 > $out 2>&1
say "window-noclear-exit $?"
say "fbo"
run $bin/glview -f -s 3 > $out 2>&1
say "fbo-exit $?"
say end
