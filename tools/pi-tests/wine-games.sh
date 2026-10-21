#!/bin/sh
# wine-games.sh — a UserBootscript: 32-bit x86 Windows games under Wine (WoW64, Box64) on the Haiku desktop.
# The games are free demos unpacked into the test image's non-packaged/data/wine-games (never published:
# downloaded for the test only, see docs/design/wine-x86.md). Makes a prefix with the x86 emulator if the disk
# has none (netboot-cycle.sh --keep-disk keeps it for the next run), sets wined3d's GDI renderer (no GL yet),
# then runs each game for a while, with a screenshot every 60 s (/boot/home/wine-games-<game>-<n>.png): all of them,
# or those /boot/home/wine-games.list names.
# Serial console lines: "WGM ".
sleep 15
out=/dev/dprintf
say() { echo "WGM $*" > $out; }
export PATH=/boot/system/non-packaged/bin:$PATH
export WINEPREFIX=/boot/home/wineprefix
export WINEDEBUG=err+all,fixme-all
export XKB_CONFIG_ROOT=/boot/system/non-packaged/data/X11/xkb
games=/boot/system/non-packaged/data/wine-games

if [ ! -f $WINEPREFIX/drive_c/windows/syswow64/kernel32.dll ]; then
	rm -rf $WINEPREFIX
	start=$(date +%s)
	wineboot -i > /tmp/wineboot.txt 2>&1
	# wineboot returns before the 32-bit setup (x86 rundll32 under the emulator) is done
	wineserver -w &
	wpid=$!
	waited=0
	while [ $waited -lt 900 ] && kill -0 $wpid 2> /dev/null; do sleep 1; waited=$((waited + 1)); done
	kill -0 $wpid 2> /dev/null && { say "prefix: setup still running after 900 s"; wineserver -k; }
	say "prefix: $(( $(date +%s) - start )) s, syswow64 $(ls $WINEPREFIX/drive_c/windows/syswow64 2> /dev/null | wc -l) files"
fi
# D: is /boot: Z: (/) is Haiku's rootfs, which has no free space, and a game checking the free space of its drive
# (Heroes III) refuses to run from it; Wine maps a folder to its deepest drive, so the games are on D:
ln -sfn /boot $WINEPREFIX/dosdevices/d:
say "disk: $(df /boot 2> /dev/null | grep -a -i -E 'free|total' | tr -s ' ' | tr '\n' ' ')"
wine reg add 'HKCU\Software\Wine\Direct3D' /v renderer /d gdi /f > /dev/null 2>&1
wineserver -w

# GAME DIR "EXE [ARGS]" SECONDS [VAR=VALUE...]   (the variables for that game only, e.g. BOX64_DYNAREC=0); with
# click="TITLE|BUTTON[|TITLE|BUTTON]..." set, those dialogs' buttons are pressed in turn as they appear
# (tools/wine-tests/click.c); with input="STEP|STEP..." set, those input steps are played into the game
# (tools/wine-tests/input.c: wait:MS, click:X,Y in the game window, key:VK, text:...)
run() {
	cd "$games/$2" || { say "$1: no $games/$2"; return; }
	say "$1: start"
	game=$1 exe=$3 secs=$4
	shift 4
	if [ -n "${click:-}" ]; then
		( IFS='|'; wine /boot/system/non-packaged/data/wine-tests/click.exe -t $secs $click 2>&1 \
			| tr -d '\r' | grep -a --line-buffered '^click:' | while read -r line; do say "$game: $line"; done ) &
	fi
	env "$@" wine $exe > /tmp/$game.txt 2>&1 &
	pid=$!
	if [ -n "${input:-}" ]; then
		( IFS='|'; wine /boot/system/non-packaged/data/wine-tests/input.exe $input 2>&1 \
			| tr -d '\r' | grep -a --line-buffered '^input:' | while read -r line; do say "$game: $line"; done ) &
	fi
	n=1
	while [ $((n * 60)) -le $secs ]; do
		sleep 60
		screenshot -s /boot/home/wine-games-$game-$n.png > /dev/null 2>&1
		say "$game: $((n * 60)) s, $(kill -0 $pid 2> /dev/null && echo running || echo exited)," \
			"screenshot $(ls -l /boot/home/wine-games-$game-$n.png 2>&1 | awk '{print $5}') bytes"
		n=$((n + 1))
	done
	grep -a -v '^$' /tmp/$game.txt | head -n 25 | while read -r line; do say "  $game: $(echo "$line" | cut -c1-200)"; done
	wineserver -k
	sleep 3
	cp /tmp/$game.txt /boot/home/wine-games-$game.txt
}

# /boot/home/wine-games.list (netboot-cycle.sh --add, for a kept disk's next run): only the games it names
list=$(cat /boot/home/wine-games.list 2> /dev/null)
want() { [ -z "$list" ] || case " $(echo $list) " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
want ddtest8 && run ddtest8 ../wine-tests "ddtest-x86.exe 640 480 8 50" 60
want simcity3000 && run simcity3000 SC3 sc3demo.exe 360
# Heroes III's demo: after the intro (~70 s on the Pi; Escape at the main menu quits), the menus' keys — N New Game,
# S Single Scenario, Return Begin (its mouse is DirectInput's relative motion: absolute clicks do not land)
input="focus:Heroes|wait:90000|key:0x4e|wait:6000|key:0x53|wait:8000|key:0x0d|wait:30000|key:0x0d"
want heroes3 && run heroes3 H3 h3demo.exe 360
input=
click="Electronic Registration|Register Later|Electronic Registration|Forfeit"
want fallout && run fallout falldemo Falldemo.exe 300
click=
want simcity3000-interp && run simcity3000-interp SC3 sc3demo.exe 240 BOX64_DYNAREC=0
# the dynarec checked against the interpreter, opcode by opcode (Box64's COSIM; very slow): where they differ
want simcity3000-cosim && run simcity3000-cosim SC3 sc3demo.exe 300 BOX64_DYNAREC_TEST=1 BOX64_DYNAREC_TEST_NODUP=1
sync
say end
