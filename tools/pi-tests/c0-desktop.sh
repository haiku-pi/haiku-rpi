#!/bin/sh
# c0-desktop.sh — the scripted ~5-minute desktop session of H20 item C0 (docs/design/perf-round-h20.md), run
# over ssh on a Pi session (scripts/pi-session.sh, scripts/pi-ssh.sh) under the system profiler:
#
#   profile -a -k -S -i 1000 -o /boot/home/c0-desktop.prof sh /boot/home/c0-desktop.sh
#
# (profile -a ends when the command does). Steps: Terminal; Firefox showing a web page (URL: $C0_URL, default
# https://www.haiku-os.org/) and a second page in a new window; MediaPlayer playing $C0_CLIP (default
# /boot/home/fhd.mp4) for 30 s; `pkgman search`; a game's main menu ($C0_GAME, default SuperTuxKart if installed)
# for $C0_GAME_SECS s (default 60; a first start compiles its shaders into a cold Mesa cache); then everything
# quits. Lines "C0D <seconds> <step>" on stdout.
url=${C0_URL:-https://www.haiku-os.org/}
url2=${C0_URL2:-https://en.wikipedia.org/wiki/Haiku_(operating_system)}
clip=${C0_CLIP:-/boot/home/fhd.mp4}
game=${C0_GAME:-/boot/system/apps/SuperTuxKart/SuperTuxKart}
game_secs=${C0_GAME_SECS:-60}
export HOME=/boot/home
start=$(date +%s)
say() { echo "C0D $(($(date +%s) - start)) $*"; }

say "begin $(uname -v)"
/boot/system/apps/Terminal > /dev/null 2>&1 &
sleep 8
say "terminal up"
/boot/system/apps/Firefox/Firefox --new-window "$url" > /tmp/c0-ffx.log 2>&1 &
sleep 45
say "firefox page 1"
/boot/system/apps/Firefox/Firefox --new-window "$url2" >> /tmp/c0-ffx.log 2>&1 &
sleep 30
say "firefox page 2"
if [ -f "$clip" ]; then
	/boot/system/apps/MediaPlayer "$clip" > /dev/null 2>&1 &
	sleep 30
	hey MediaPlayer quit > /dev/null 2>&1
	say "mediaplayer clip"
else
	say "mediaplayer: no clip $clip"
fi
sleep 3
pkgman search -a gcc > /tmp/c0-pkgman.txt 2>&1
say "pkgman search: exit $? $(wc -l < /tmp/c0-pkgman.txt) lines"
pkgman search -a python > /dev/null 2>&1
say "pkgman search 2: exit $?"
if [ -x "$game" ]; then
	(cd "$(dirname "$game")" && exec "$game" --windowed --screensize=1024x576) > /tmp/c0-game.log 2>&1 &
	sleep $game_secs
	say "game menu"
	hey "$(basename "$game")" quit > /dev/null 2>&1 || true
	sleep 3
	kill $(ps | awk -v g="$(basename "$game")" 'index($1, g) { print $2 }') 2> /dev/null
else
	say "game: none at $game"
fi
hey Firefox quit > /dev/null 2>&1
hey Terminal quit > /dev/null 2>&1
sleep 10
say "end"
