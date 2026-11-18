#!/bin/sh
# blender-probe.sh — run over ssh in a Pi session (scripts/pi-session.sh, scripts/pi-ssh.sh): what Blender 3.6's
# OpenGL backend and Blender 4.5/5.3's Vulkan backend would find on this system (docs/design/blender.md, step 0).
#
#   sh blender-probe.sh DIR [LABEL]
#
# DIR holds blender-glprobe and blender-vkprobe (tools/gl-tests, cross-built as docs/design/blender.md step 0
# says) and glinfo. Needs the desktop-GL branch stack (docs/design/desktop-gl.md: Mesa v5-gl + libglvnd v5-gl
# installed as the -91 test packages) and an SDL2 with patches/libsdl2/libsdl2-2.32.10-haiku-glview-core.patch;
# a libSDL2 in DIR is used first (LIBRARY_PATH). Output lines start with "BPR "; each program's own lines
# follow, its log in /tmp/bpr-LABEL-*.txt. The SDL thread check runs last and alone: with stock SDL2 it is
# expected to stop in the debugger (the HaikuPorts Blender crash), which is its answer.
dir=$1 label=${2:-run}
[ -x "$dir/blender-glprobe" ] || { echo "usage: $0 DIR [LABEL]" >&2; exit 2; }
export PATH=$dir:/boot/system/non-packaged/bin:$PATH
export LIBRARY_PATH=$dir:${LIBRARY_PATH:-}
# a crash is logged, not shown as an alert that waits for a click (as games-bench.sh)
mkdir -p /boot/home/config/settings/system/debug_server
echo "default_action log" > /boot/home/config/settings/system/debug_server/settings
run() {
	name=$1
	shift
	"$@" > /tmp/bpr-$label-$name.txt 2>&1
	echo "BPR $label $name: status $?"
}
echo "BPR $label mesa: $(pkgman search -i -D mesa 2>/dev/null | grep -o 'mesa  *[^ ]*' | head -n 1)"
echo "BPR $label sdl2: $(pkgman search -i -D libsdl2 2>/dev/null | grep -o 'libsdl2  *[^ ]*' | head -n 1)"
run glinfo glinfo -k core33
grep -E '^GLI (core33|  version|  glsl|  profile)' /tmp/bpr-$label-glinfo.txt
run glprobe blender-glprobe
grep -E '^BGP ' /tmp/bpr-$label-glprobe.txt
run egl blender-glprobe -e
grep -E '^BGP ' /tmp/bpr-$label-egl.txt
run vkprobe blender-vkprobe
grep -E '^BVK ' /tmp/bpr-$label-vkprobe.txt
# last: may end in the debugger (stock SDL2); a debugger stop shows up as a status other than 0..N
run sdlthread blender-glprobe -t
grep -E '^BGP (PASS|FAIL|INFO) sdl thread|UnlockGL' /tmp/bpr-$label-sdlthread.txt
grep -a debug_server /var/log/syslog 2> /dev/null | grep -a -i -E 'thread|team' | tail -n 3 \
	| while read -r l; do echo "BPR $label crash: $l"; done
echo "BPR $label done"
