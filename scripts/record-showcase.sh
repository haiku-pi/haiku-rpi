#!/usr/bin/env bash
# record-showcase.sh OUT.mp4 — a captioned showcase video of a running Pi session (scripts/pi-session.sh): each
# segment starts a program on the Pi over ssh (scripts/pi-ssh.sh), waits for it to settle, records the HDMI output
# (scripts/hdmi-record.sh), stops it; then the segments are joined with a caption each (ffmpeg drawtext).
# The session needs the regular image with Wine (pkgman install wine wine_x86 wine_x86_64, a prefix in ~/.wine)
# and the test games in /boot/system/non-packaged/data/wine-games (downloaded for the test, never published:
# Heroes III demo, Chocolate Doom win64 + Freedoom, OpenTTD win64 + OpenGFX + OpenSFX).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:?usage: record-showcase.sh OUT.mp4}"
work="$(mktemp -d)"
# a crash alert of debug_server would stay on the screen for every later segment: while recording, crashed teams
# are killed without one (debug_server reads this per crash; the syslog still has "Killing team")
crashes=/boot/home/config/settings/system/debug_server/settings
trap '"$root/scripts/pi-ssh.sh" "rm -f $crashes" || true; rm -rf "$work"' EXIT
"$root/scripts/pi-ssh.sh" "mkdir -p ${crashes%/*}; echo 'default_action kill' > $crashes"
font=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf
games=/boot/system/non-packaged/data/wine-games
ssh() { "$root/scripts/pi-ssh.sh" "$@"; }

# everything the segments start, stopped (and the screen blanker, which would cover the picture). Firefox's parent
# (/boot/system/bin/firefox) first, so it ends its content processes itself: a content process killed under it is
# a crash, and the crash alert would stay on the screen for the remaining segments.
teams() { echo "for t in \$(ps | grep -a -i -E \"$1\" | awk '{print \$(NF-3)}'); do kill ${2:-} \$t 2> /dev/null; done"; }
stop_all() {
	ssh "wineserver -k 2> /dev/null; $(teams '^/boot/system/bin/[f]irefox'); sleep 5; \
$(teams '[f]irefox|[g]lteapot|[a]boutsystem|[s]creen_blanker' -9); true" || true
}

# segment NAME SETTLE SECS "CAPTION" "COMMAND ON THE PI"
n=0
segment() {
	local name=$1 settle=$2 secs=$3 caption=$4 command=$5
	n=$((n + 1))
	echo "record-showcase: $n $name"
	stop_all
	ssh "cd /boot/home; ( $command ) > /tmp/showcase-$name.txt 2>&1 < /dev/null &"
	sleep "$settle"
	ssh "$(teams '[s]creen_blanker'); true" || true
	"$root/scripts/hdmi-record.sh" "$work/raw-$n.mp4" "$secs"
	# the caption through a file: its ':' and ',' would end the filter's option
	printf '%s' "$caption" > "$work/caption-$n.txt"
	ffmpeg -y -loglevel error -i "$work/raw-$n.mp4" -vf "drawbox=x=0:y=ih-90:w=iw:h=90:color=black@0.6:t=fill,\
drawtext=fontfile=$font:textfile=$work/caption-$n.txt:fontcolor=white:fontsize=40:x=40:y=h-68" \
		-c:v libx264 -preset veryfast -crf 23 -r 30 -an "$work/seg-$n.mp4"
	echo "file '$work/seg-$n.mp4'" >> "$work/list.txt"
}

segment desktop 8 7 "Haiku on the Raspberry Pi 4: the desktop, 4 cores at 1.5 GHz" \
	"/boot/system/apps/AboutSystem"
segment firefox 30 10 "Firefox 157 on the V3D GPU" \
	"firefox https://www.haiku-os.org/"
segment glteapot 6 7 "OpenGL on the V3D through Mesa (GLTeapot)" \
	"/boot/system/demos/GLTeapot"
segment heroes 80 14 "Windows x86 through Wine + Box64: Heroes of Might and Magic III (demo)" \
	"ln -sfn /boot ~/.wine/dosdevices/d:; cd $games/H3; wine h3demo.exe"
segment doom 25 14 "Windows x86-64 through Wine + FEX: Chocolate Doom playing Freedoom" \
	"cd $games/DOOM64; SDL_RENDER_DRIVER=opengl wine chocolate-doom.exe -iwad freedoom2.wad -window"
segment openttd 60 12 "Windows x86-64 through Wine + FEX: OpenTTD 15.3" \
	"cd $games/OTTD; wine openttd.exe -m null -v win32 -c pi.cfg"
stop_all

ffmpeg -y -loglevel error -f concat -safe 0 -i "$work/list.txt" -c copy "$out"
echo "record-showcase: $out ($(stat -c %s "$out") bytes, $n segments)"
