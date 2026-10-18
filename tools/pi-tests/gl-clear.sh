#!/bin/sh
# gl-clear.sh — a UserBootscript for the windowed-GL wedge, which only a glClear triggers: how the
# v3d driver clears (V3D_CLEAR_TRACE: TLB clear or a quad drawn by the blitter, per buffer) in a
# window with a depth buffer, without one (-n), with depth and stencil cleared together (-S), and
# in an FBO (the control). Serial console lines: "GLT " (markers), "GLW " (glview), "v3d_clear:".
sleep 20
out=/dev/dprintf
bin=/boot/system/non-packaged/bin
say() { echo "GLT $*" > $out; }
run() {
	if command -v timeout > /dev/null 2>&1; then timeout 60 "$@"; else "$@"; fi
}
for args in "" "-n" "-S" "-f"; do
	say "glview $args"
	V3D_CLEAR_TRACE=1 run $bin/glview -s 1 $args > $out 2>&1
	say "exit $?"
done
say end
