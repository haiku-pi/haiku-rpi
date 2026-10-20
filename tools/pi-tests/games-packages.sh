#!/bin/sh
# games-packages.sh — a UserBootscript for an image with the games packages (scripts/package-games.sh,
# jam -sHAIKU_PI_GL=1 -sHAIKU_PI_GAMES=1 @pi-mmc): both are activated, have their Deskbar entries, and
# start from their packaged directories: OpenArena's timedemo (demo088-test1, 1280x720 window) and a
# 60 s SuperTuxKart race (1280x720 window), each bounded to secs seconds.
#
#   scripts/mkimage-pi4.sh --in sources/haiku/generated.arm64/haiku-mmc.image \
#       --bootscript tools/pi-tests/games-packages.sh --out artifacts/images/haiku-pi4-games-test.img
#
# Serial console lines: "GPK ". A good run: "GPK package openarena-0.8.8-..." and "supertuxkart-1.5-...",
# "GPK deskbar OpenArena -> ..." and "SuperTuxKart -> ...", "GPK openarena exited after N s (status 0)"
# with a "GPK openarena result: 3398 frames ..." line, "GPK supertuxkart exited after N s (status 0)"
# with a "GPK supertuxkart result: ... Average FPS ..." line, then "GPK end".
sleep 20
out=/dev/dprintf
say() { echo "GPK $*" > $out; }
secs=150
export HOME=/boot/home
mkdir -p /boot/home/config/settings/system/debug_server
echo "default_action log" > /boot/home/config/settings/system/debug_server/settings

for p in /boot/system/packages/openarena-*.hpkg /boot/system/packages/supertuxkart-*.hpkg; do
	say "package $(basename "$p")"
done
for e in OpenArena SuperTuxKart; do
	say "deskbar $e -> $(readlink /boot/system/data/deskbar/menu/Applications/$e 2>&1)"
done

# run NAME DIR COMMAND... — in DIR, bounded to secs seconds
run() {
	name=$1 dir=$2; shift 2
	say "start $name"
	(cd "$dir" && "$@" > /tmp/$name.txt 2>&1) &
	pid=$!
	waited=0
	while [ $waited -lt $secs ] && kill -0 $pid 2> /dev/null; do
		sleep 5
		waited=$((waited + 5))
	done
	if kill -0 $pid 2> /dev/null; then
		say "$name still running after $waited s"
		kill $pid; sleep 2; kill -9 $pid 2> /dev/null
	else
		wait $pid
		say "$name exited after $waited s (status $?)"
	fi
}

oa=/boot/system/apps/OpenArena
run openarena $oa ./OpenArena +set logfile 2 +set net_enabled 0 +set s_initsound 0 +set com_hunkmegs 256 \
	+set r_mode -1 +set r_customwidth 1280 +set r_customheight 720 +set r_fullscreen 0 +set cg_drawFPS 1 \
	+set nextdemo quit +set timedemo 1 +demo demo088-test1
grep -a -E '^[0-9]+ frames [0-9.]+ seconds' /boot/home/config/settings/OpenArena/baseoa/qconsole.log \
	| while read -r line; do say "openarena result: $line"; done
tail -n 3 /tmp/openarena.txt | cut -c1-160 | while read -r line; do say "openarena tail: $line"; done

stk=/boot/system/apps/SuperTuxKart
run supertuxkart $stk ./SuperTuxKart --windowed --screensize=1280x720 --disable-texture-compression \
	--profile-time=60 --track=hacienda --numkarts=4 --kart=tux --difficulty=0
grep -a 'Average FPS' /tmp/supertuxkart.txt | cut -c1-200 | while read -r line; do say "supertuxkart result: $line"; done
grep -a -i -E '\[(fatal|error)' /tmp/supertuxkart.txt | head -n 5 | cut -c1-160 \
	| while read -r line; do say "supertuxkart error: $line"; done

grep -a "debug_server: Thread" /var/log/syslog | tail -n 3 | while read -r l; do say "crash: $l"; done
say end
