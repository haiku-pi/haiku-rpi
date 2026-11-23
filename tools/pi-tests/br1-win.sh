#!/bin/sh
# br1-win.sh — Blender's windows on the screen, one step per call, for the host to take an HDMI frame between steps
# (docs/design/blender.md §7.20: the render window's tab above the screen, the zoom button giving "full screen").
# Run over ssh in a Pi session, with uiinject, winmsg, winframes and sdl-winpos next to this script.
#
#   sh br1-win.sh start [LIBDIR]     Blender (factory settings), LIBDIR first in LIBRARY_PATH (a test libSDL2);
#                                    prints the libSDL2 it loaded
#   sh br1-win.sh q2 SIZE|full [LIBDIR]   Yamagi Quake II's demo in a SIZE (e.g. 1920x1080) window, or full screen
#   sh br1-win.sh stk [LIBDIR]       SuperTuxKart in a 1280x720 window
#   sh br1-win.sh winpos LIBDIR|- ARGS...   sdl-winpos ARGS in the background (its lines: sh br1-win.sh log)
#   sh br1-win.sh frames             every window of the program started last: index, title, frame, hidden
#   sh br1-win.sh keys K...          activate the main window, mouse to its middle, then uiinject commands
#   sh br1-win.sh zoom [TITLE]       the window's zoom button (B_ZOOM; TITLE default "Blender")
#   sh br1-win.sh fulltoggle         Window > Toggle Window Fullscreen (by F3 menu search)
#   sh br1-win.sh prefs              Edit > Preferences (by F3 menu search)
#   sh br1-win.sh stop
#
# Lines start with "BR1 ".
here=$(cd "$(dirname "$0")" && pwd)
# the packaged binary has B_ARGV_ONLY, which keeps scripting (uiinject, winframes) out: BLENDER=a copy without
# resources, beside a link to the installed 3.6/ (objcopy drops the appended resources)
bl=${BLENDER:-/boot/home/br1app/Blender}
state=/tmp/br1-blender.pid
pid=$(cat $state 2>/dev/null)

libpath() {
	if [ -n "$1" ]; then
		export LIBRARY_PATH="$1:%A/lib:/boot/home/config/non-packaged/lib:/boot/home/config/lib:/boot/system/non-packaged/lib:/boot/system/lib"
	fi
}
started() {
	echo $! > $state
	sleep $1
	echo "BR1 started pid $(cat $state)"
	listimage "$(cat $state)" | grep -i sdl | sed 's/^/BR1 image /'
}

case "$1" in
start)
	libpath "$2"
	"$bl" --factory-startup > /tmp/br1-blender.txt 2>&1 &
	started 25
	;;
q2)
	libpath "$3"
	case "$2" in
	full) display="+set vid_fullscreen 1 +set r_mode -2" ;;
	*) display="+set vid_fullscreen 0 +set r_mode -1 +set r_customwidth ${2%x*} +set r_customheight ${2#*x}" ;;
	esac
	cd /boot/system/non-packaged/apps/quake2 || exit 1
	./Quake2 +set vid_renderer gl1 $display +set s_initsound 0 +demomap q2demo1.dm2 > /tmp/br1-q2.txt 2>&1 &
	started 15
	;;
stk)
	libpath "$2"
	cd /boot/system/apps/SuperTuxKart || exit 1
	./SuperTuxKart --windowed --screensize=1280x720 > /tmp/br1-stk.txt 2>&1 &
	started 30
	;;
winpos)
	# "-": the system's libSDL2: a copy away from here (the loader looks in the program's own lib/ first, %A/lib)
	prog="$here/sdl-winpos"
	if [ "$2" = - ]; then
		mkdir -p /tmp/br1-ctl && cp "$prog" /tmp/br1-ctl/ && prog=/tmp/br1-ctl/sdl-winpos
	else
		libpath "$2"
	fi
	shift 2
	"$prog" "$@" > /tmp/br1-swp.txt 2>&1 &
	started 2
	;;
log)
	cat /tmp/br1-swp.txt
	;;
frames)
	"$here/winframes" "$pid" | sed 's/^WF /BR1 window /'
	;;
keys)
	shift
	"$here/uiinject" "$pid" Blender activate move 700 450 "$@" > /dev/null 2>&1
	echo "BR1 keys $*: $?"
	;;
zoom)
	"$here/winmsg" "$pid" "${2:-Blender}" _WZM
	echo "BR1 zoom ${2:-Blender}: $?"
	;;
fulltoggle)
	"$here/uiinject" "$pid" Blender activate move 700 450 key f3 wait 1500 text "Toggle Window Fullscreen" \
		wait 1500 key return > /dev/null 2>&1
	echo "BR1 fulltoggle: $?"
	;;
prefs)
	"$here/uiinject" "$pid" Blender activate move 700 450 key f3 wait 1500 text "Preferences" wait 1500 \
		key return > /dev/null 2>&1
	echo "BR1 prefs: $?"
	;;
stop)
	kill "$pid" 2>/dev/null
	sleep 2
	kill -9 "$pid" 2>/dev/null
	rm -f $state
	echo "BR1 stopped"
	;;
*)
	sed -n '5,16p' "$0" >&2
	exit 2
	;;
esac
