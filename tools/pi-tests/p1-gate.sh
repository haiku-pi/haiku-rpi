#!/bin/sh
# p1-gate.sh — the hands-off steps of the P1 package gate (wayland_server -11, wine 11.21-4, libsdl2 -9) on a Pi
# running the mega image, one step per call, so the host can take an HDMI frame between steps (the hardware
# cursor is only on HDMI, not in a screenshot). Run over ssh in a Pi session, with mouseto and winframes next to
# this script.
#
#   sh p1-gate.sh pkgs                the packages' sha256 and revisions, and every libSDL2 on the disk
#   sh p1-gate.sh start NAME          start a program detached: photocraft, war3, d2, npp64, notepad
#   sh p1-gate.sh frames              the windows of the program started last (winframes)
#   sh p1-gate.sh mouse X Y           move the real pointer (mouseto)
#   sh p1-gate.sh centre              the pointer to the middle of the started program's first shown window
#   sh p1-gate.sh libs                the libSDL2 / wayland images the started program loaded (listimage)
#   sh p1-gate.sh stop                end it (and Wine's processes)
#
# Lines start with "P1 ".
here=$(cd "$(dirname "$0")" && pwd)
np=/boot/system/non-packaged
state=/tmp/p1-pid
pid=$(cat $state 2>/dev/null)

# the newest team running PATH (Wine: the program's own process, not the wine launcher)
team_of() { ps | grep -F -- "$1" | grep -v -e grep -e p1-gate | awk '{ t = $(NF - 3) } END { print t }'; }

case "$1" in
pkgs)
	cd /boot/system/packages || exit 1
	for f in libsdl2-* libsdl2_devel-* wayland_server-* wine-* wine_data-* wine_directx-* wine_x86-* wine_x86_64-*; do
		[ -f "$f" ] && echo "P1 pkg $(sha256sum "$f")"
	done
	find /boot -name 'libSDL2*' 2> /dev/null | sed 's/^/P1 lib /'
	;;
start)
	case "$2" in
	photocraft) dir=/boot/system/apps/PhotoCraft; cmd=./PhotoCraft; match=PhotoCraft ;;
	war3) dir=$np/data/wine-games/W3; cmd="wine War3Demo.exe"; match=War3Demo ;;
	d2) dir=$np/data/wine-games/D2; cmd="wine 'Diablo II.exe'"; match="Diablo II" ;;
	npp64) dir=$np/data/windows-apps/npp64; cmd="wine notepad++.exe"; match="notepad++" ;;
	notepad) dir=/boot/home; cmd="wine notepad"; match=notepad ;;
	*) echo "P1 unknown program $2" >&2; exit 2 ;;
	esac
	echo "$match" > /tmp/p1-match
	cd "$dir" || exit 1
	# a separate session and no inherited descriptors: the ssh channel must not wait for the program
	nohup sh -c "exec $cmd" > /tmp/p1-$2.txt 2>&1 < /dev/null &
	echo "P1 started $2 (launcher $!)"
	;;
frames)
	pid=$(team_of "$(cat /tmp/p1-match)")
	echo "$pid" > $state
	echo "P1 team $pid"
	"$here/winframes" "$pid" | sed 's/^WF /P1 window /'
	;;
centre)
	pid=$(team_of "$(cat /tmp/p1-match)")
	f=$("$here/winframes" "$pid" | awk '/hidden=0/ { sub(/.*frame=/, ""); sub(/ .*/, ""); print; exit }')
	[ -n "$f" ] || { echo "P1 no shown window of team $pid"; exit 1; }
	l=${f%%,*}; r=${f#*,}; t=${r%%,*}; r=${r#*,}; rr=${r%%,*}; b=${r#*,}
	x=$(( (${l%.*} + ${rr%.*}) / 2 )); y=$(( (${t%.*} + ${b%.*}) / 2 ))
	"$here/mouseto" $x $y
	echo "P1 pointer at $x,$y (window $f)"
	;;
mouse)
	"$here/mouseto" "$2" "$3"
	echo "P1 pointer at $2,$3"
	;;
libs)
	pid=$(team_of "$(cat /tmp/p1-match)")
	listimage "$pid" | grep -i -E 'sdl|wayland' | sed 's/^/P1 image /'
	;;
stop)
	pid=$(team_of "$(cat /tmp/p1-match)")
	[ -n "$pid" ] && kill "$pid" 2> /dev/null
	wineserver -k > /dev/null 2>&1
	sleep 3
	pid=$(team_of "$(cat /tmp/p1-match)")
	[ -n "$pid" ] && kill -9 "$pid" 2> /dev/null
	echo "P1 stopped"
	;;
*)
	sed -n '7,13p' "$0" >&2
	exit 2
	;;
esac
