#!/bin/sh
# sdl-gl-check.sh — run over ssh in a Pi session (scripts/pi-session.sh on the mega image, scripts/pi-ssh.sh): the
# SDL2 OpenGL programs a libsdl2 change can break, with the image's libSDL2 or one under test.
#
#   sh sdl-gl-check.sh LIBDIR LABEL STEP...
#
# LIBDIR: a directory with the libSDL2-2.0.so.0 under test, put first in LIBRARY_PATH; "system" for what the image
# loads by itself (a libSDL2 in /boot/system/non-packaged/lib wins over the package's).
# Steps (any order; each prints "SGC LABEL STEP: ..." lines, its program's output in /tmp/sgc-LABEL-STEP.txt):
#   coreseq     sdl-coreseq (tools/gl-tests, in LIBDIR or PATH): SuperTuxKart's way to its context, each attempt
#   stk-legacy  SuperTuxKart (the package) with force_legacy_device="true" (the package's default): 60 s race on
#               hacienda in a 1280x720 window; GL version, renderer path, egl_haiku's frames/s
#   stk-core    the same with force_legacy_device="false" (its shader renderer on a core context)
#   q2gl3       Yamagi Quake II, GL3 renderer (a 3.2 core context), attract demo as a timedemo, 1280x720 window
#   q2gl1       the same with the GL1 renderer
# A crash is logged by debug_server (not shown as an alert) and reported as "crashed".
lib=$1 label=$2
shift 2 || { echo "usage: $0 LIBDIR LABEL STEP..." >&2; exit 2; }
defaultPath=%A/lib:/boot/home/config/non-packaged/lib:/boot/home/config/lib:/boot/system/non-packaged/lib:/boot/system/lib
# sdl-coreseq from LIBDIR, else beside this script
export PATH=$(cd "$(dirname "$0")" && pwd):$PATH
if [ "$lib" != system ]; then
	export LIBRARY_PATH=$lib:${LIBRARY_PATH:-$defaultPath}
	export PATH=$lib:$PATH
fi
mkdir -p /boot/home/config/settings/system/debug_server 2> /dev/null
echo "default_action log" 2> /dev/null > /boot/home/config/settings/system/debug_server/settings || true
stkConfig=/boot/home/config/settings/SuperTuxKart/config-0.10/config.xml
say() { echo "SGC $label $*"; }
# bounded NAME SECS CMD...: CMD in the background, at most SECS seconds (then SIGKILL); $status, $ran
bounded() {
	name=$1 secs=$2
	shift 2
	"$@" > /tmp/sgc-$label-$name.txt 2>&1 &
	pid=$!
	ran=0
	while [ $ran -lt $secs ] && kill -0 $pid 2> /dev/null; do
		sleep 1
		ran=$((ran + 1))
		if grep -a -q -E 'terminate called|^Abort|Segmentation|debug_server' /tmp/sgc-$label-$name.txt; then
			break
		fi
	done
	if kill -0 $pid 2> /dev/null; then
		kill -9 $pid 2> /dev/null
		status=killed
	else
		wait $pid
		status="status $?"
	fi
}
# egl_haiku's "N frames/s" lines (every 5 s): their mean, how many
egl() {
	grep -a -o 'egl_haiku: [0-9.]* frames/s' "$1" | awk '{ s += $2; n++ } END { if (n) printf "%.1f (%d samples)", s / n, n; else printf "none" }'
}
stk() {
	want=$1
	cd /boot/system/apps/SuperTuxKart || { say "$step: no SuperTuxKart"; return; }
	if [ -f $stkConfig ]; then
		sed -i -e "s/force_legacy_device=\"[a-z]*\"/force_legacy_device=\"$want\"/" $stkConfig
	elif [ "$want" = false ]; then
		say "$step: no $stkConfig yet (run stk-legacy first)"
		return
	fi
	bounded $step 200 env HAIKU_EGL_FPS=1 ./SuperTuxKart --windowed --screensize=1280x720 \
		--disable-texture-compression --profile-time=60 --track=hacienda --numkarts=4 --kart=tux --difficulty=0
	log=/tmp/sgc-$label-$step.txt
	say "$step: force_legacy_device $(grep -a -o 'force_legacy_device="[a-z]*"' $stkConfig 2> /dev/null), $status after $ran s"
	grep -a -E 'OpenGL version string|GLSL supported|too old|Average FPS|Could not initialize' $log | sed -e 's/^[^]]*] *//' \
		| cut -c1-160 | while read -r l; do say "$step: $l"; done
	say "$step: egl $(egl $log)"
	grep -a -c -E 'wrong thread' $log | while read -r n; do say "$step: $n 'wrong thread' lines"; done
}
q2() {
	renderer=$1
	cd /boot/system/non-packaged/apps/quake2 || { say "$step: no quake2"; return; }
	bounded $step 120 env HAIKU_EGL_FPS=1 ./Quake2 +set vid_renderer $renderer +set vid_fullscreen 0 +set r_mode -1 \
		+set r_customwidth 1280 +set r_customheight 720 +set s_initsound 0 +set nextdemo quit +set timedemo 1 \
		+demomap q2demo1.dm2
	log=/tmp/sgc-$label-$step.txt
	say "$step: $status after $ran s"
	grep -a -i -E 'got version|OpenGL version|[0-9]+ frames, [0-9.]+ seconds|error|fail|couldn' $log | head -n 6 \
		| cut -c1-160 | while read -r l; do say "$step: $l"; done
	say "$step: egl $(egl $log)"
}
say "sdl2 package: $(pkgman search -i -D libsdl2 2>/dev/null | grep -o 'libsdl2  *[^ ]*' | head -n 1), LIBRARY_PATH ${LIBRARY_PATH:-(unset)}"
for step in "$@"; do
	case $step in
	coreseq)
		bounded coreseq 60 sdl-coreseq
		grep -a '^SCS ' /tmp/sgc-$label-coreseq.txt | while read -r l; do say "coreseq: ${l#SCS }"; done
		say "coreseq: $status" ;;
	stk-legacy) stk true ;;
	stk-core) stk false ;;
	q2gl3) q2 gl3 ;;
	q2gl1) q2 gl1 ;;
	*) say "unknown step $step" ;;
	esac
done
grep -a debug_server /var/log/syslog 2> /dev/null | grep -a -i -E 'thread|team' | tail -n 3 \
	| while read -r l; do say "syslog: $l"; done
say done
