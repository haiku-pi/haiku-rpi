#!/usr/bin/env bash
# run.sh — run a Windows program under the reference Wine (scripts/build-wine-ref.sh) on a virtual X server, with
# a screenshot every SHOT seconds: what the program looks like with the same Wine on real x86, to compare with the
# Pi (tools/pi-tests/wine-games.sh).
#
#   tools/wine-ref/run.sh NAME DIR EXE [SECONDS [SHOT]] [-- VAR=VALUE...]
#
# DIR is where EXE is (the program runs there); screenshots artifacts/wine-ref/shots/NAME-<n>.png and the log
# artifacts/wine-ref/shots/NAME.txt. The prefix is artifacts/wine-ref/prefix (made on the first run), with wined3d's
# GDI renderer as on the Pi (RENDERER=gl: OpenGL, by Mesa's software rasterizer on Xvfb); the X server is
# 1920x1080, as the Pi's HDMI.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
[ $# -ge 3 ] || { sed -n '4,9p' "$0" >&2; exit 2; }
name=$1 dir=$2 exe=$3
shift 3
secs=120 shot=20
[ $# -gt 0 ] && [ "$1" != -- ] && { secs=$1; shift; }
[ $# -gt 0 ] && [ "$1" != -- ] && { shot=$1; shift; }
[ "${1:-}" = -- ] && shift
wine="$root/artifacts/wine-ref/install/bin"
shots="$root/artifacts/wine-ref/shots"
mkdir -p "$shots"
export WINEPREFIX="$root/artifacts/wine-ref/prefix" WINEDEBUG="${WINEDEBUG:-err+all,fixme-all}" PATH="$wine:$PATH"

# a free display number, its own X server
d=97
while [ -e /tmp/.X11-unix/X$d ]; do d=$((d + 1)); done
Xvfb :$d -screen 0 1920x1080x24 -nolisten tcp > "$shots/$name.xvfb.txt" 2>&1 &
xvfb=$!
export DISPLAY=:$d
trap 'wineserver -k 2> /dev/null || true; kill $xvfb 2> /dev/null || true' EXIT
sleep 2

if [ ! -f "$WINEPREFIX/drive_c/windows/syswow64/kernel32.dll" ]; then
	# no Wine Mono / Gecko installer dialogs: nobody could answer them on the virtual display
	WINEDLLOVERRIDES="mscoree,mshtml=" wineboot -i > "$shots/wineboot.txt" 2>&1
	wineserver -w
fi
wine reg add 'HKCU\Software\Wine\Direct3D' /v renderer /d "${RENDERER:-gdi}" /f > /dev/null 2>&1
# a Wine virtual desktop the size of the screen for every program: it emulates display mode changes, as the Pi's
# Wayland driver does (Xvfb has one mode only, so SetDisplayMode would fail)
wine reg add 'HKCU\Software\Wine\Explorer' /v Desktop /d Default /f > /dev/null 2>&1
wine reg add 'HKCU\Software\Wine\Explorer\Desktops' /v Default /d 1920x1080 /f > /dev/null 2>&1
wineserver -w

cd "$dir"
env "$@" wine $exe > "$shots/$name.txt" 2>&1 &
pid=$!
# CLICK="TITLE|BUTTON[|TITLE|BUTTON]...": those dialogs' buttons pressed as they appear (tools/wine-tests/click.c,
# built for x86 as artifacts/wine-ref/click-x86.exe)
if [ -n "${CLICK:-}" ]; then
	( IFS='|'; wine "$root/artifacts/wine-ref/click-x86.exe" -t "$secs" $CLICK ) >> "$shots/$name.txt" 2>&1 &
fi
for ((t = shot, n = 1; t <= secs; t += shot, n++)); do
	sleep "$shot"
	ffmpeg -loglevel error -y -f x11grab -video_size 1920x1080 -i ":$d" -frames:v 1 "$shots/$name-$n.png"
	echo "run: $name $t s, $(kill -0 $pid 2> /dev/null && echo running || echo exited), $shots/$name-$n.png"
done
