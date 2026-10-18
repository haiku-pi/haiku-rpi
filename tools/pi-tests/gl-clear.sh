#!/bin/sh
# gl-clear.sh — a UserBootscript for the windowed-GL wedge, which only a glClear triggers: how the
# v3d driver clears (V3D_CLEAR_TRACE: TLB clear or a quad drawn by the blitter, per buffer) in a
# window (which always has a Z24S8 depth/stencil buffer), with depth and stencil cleared together
# (-S), in an FBO without depth (the control) and in an FBO with a Z24S8 renderbuffer (-f -d).
# Serial console lines: "GLT " (markers), "GLW " (glview), "v3d_clear:".
sleep 20
out=/dev/dprintf
bin=/boot/system/non-packaged/bin
say() { echo "GLT $*" > $out; }
run() {
	if command -v timeout > /dev/null 2>&1; then timeout 60 "$@"; else "$@"; fi
}
for args in "" "-S" "-f" "-f -d" "-f -d -S"; do
	say "glview $args"
	V3D_CLEAR_TRACE=1 run $bin/glview -s 1 $args > $out 2>&1
	say "exit $?"
done
say end
