#!/bin/sh
# wine-games.sh — a UserBootscript: 32-bit x86 Windows games under Wine (WoW64, Box64) on the Haiku desktop.
# The games are free demos unpacked into the test image's non-packaged/data/wine-games (never published:
# downloaded for the test only, see docs/design/wine-x86.md). Makes a prefix with the x86 emulator if the disk
# has none (netboot-cycle.sh --keep-disk keeps it for the next run), sets wined3d's GDI renderer (a game may ask for OpenGL),
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
	# no Wine Mono / Gecko installer dialogs (Wine 11.20 asks; nobody is there to answer)
	WINEDLLOVERRIDES="mscoree,mshtml=" wineboot -i > /tmp/wineboot.txt 2>&1
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
# wined3d's renderer: OpenGL, what the packages give a user (DirectDraw and Direct3D on the V3D; since Wine
# 0006/0016 a DirectDraw game's frames reach its window there too); the GDI one with WINE_D3D_CONFIG=renderer=gdi
# in the environment of this script or in a game's run line. Plain OpenGL programs (gltest) use the V3D either way.
# (The registry value the GDI renderer was once set by was lost at the wineserver's exit: Wine 0014.)
export WINE_D3D_CONFIG=${WINE_D3D_CONFIG:-renderer=gl}

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
	t=0
	while [ $t -lt $secs ]; do
		step=$((secs - t)); [ $step -gt 60 ] && step=60
		sleep $step
		t=$((t + step))
		screenshot -s /boot/home/wine-games-$game-$n.png > /dev/null 2>&1
		say "$game: $t s, $(kill -0 $pid 2> /dev/null && echo running || echo exited)," \
			"screenshot $(ls -l /boot/home/wine-games-$game-$n.png 2>&1 | awk '{print $5}') bytes"
		n=$((n + 1))
		kill -0 $pid 2> /dev/null || break
	done
	grep -a -v '^$' /tmp/$game.txt | head -n 25 | while read -r line; do say "  $game: $(echo "$line" | cut -c1-200)"; done
	# the game's threads as it ends (a hang shows where: state, user and kernel time)
	# (a team line starts with its path; awk's own team, whose command line holds the name too, left out)
	ps -a 2> /dev/null | awk -v exe="${exe%% *}" '/^\// { team = index($0, exe) && $1 !~ /awk$/ } team && NF' \
		| head -n 40 | while read -r line; do say "  $game: ps: $line"; done
	wineserver -k
	sleep 3
	cp /tmp/$game.txt /boot/home/wine-games-$game.txt
}

# /boot/home/wine-games.list (netboot-cycle.sh --add, for a kept disk's next run): only the games it names
list=$(cat /boot/home/wine-games.list 2> /dev/null)
want() { [ -z "$list" ] || case " $(echo $list) " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
# sound (winehaiku.drv): a 1 kHz tone, 3 s, as arm64 and as x86 (tools/wine-tests/tone.c)
want tone-arm64 && WINEDEBUG=err+all,fixme-all,+haiku run tone-arm64 ../wine-tests "tone-arm64.exe 3 1000" 60
want tone-x86 && run tone-x86 ../wine-tests "tone-x86.exe 3 1000" 60
# OpenGL (tools/wine-tests/gltest.c): a context, a clear read back, a spinning triangle and its frame rate
want gltest-arm64 && run gltest-arm64 ../wine-tests "gltest-arm64.exe 20" 60
want gltest-x86 && run gltest-x86 ../wine-tests "gltest-x86.exe 20" 60
want gltest-gdi && run gltest-gdi ../wine-tests "gltest-arm64.exe 30 gdi" 50
want gltest-trace && run gltest-trace ../wine-tests "gltest-arm64.exe 5" 40 WINEDEBUG=err+all,fixme-all,+wgl,+opengl
want simcity3000-gl && run simcity3000-gl SC3 sc3demo.exe 300 WINE_D3D_CONFIG=renderer=gl
want ddtest8 && run ddtest8 ../wine-tests "ddtest-x86.exe 640 480 8 50" 60
# SimCity 3000 on wined3d's OpenGL renderer (its GDI renderer garbles the 8-bit city; Wine 0006 made DirectDraw show on GL)
want simcity3000 && run simcity3000 SC3 sc3demo.exe 360 WINE_D3D_CONFIG=renderer=gl
# StarCraft (the 1998 shareware CD, installed on the host's reference Wine: tools/wine-ref; 640x480x8): the game
# reads the CD's INSTALL.EXE (data/wine-games/SCCD) where the installer's registry keys say
if want starcraft || want starcraft-interp || want starcraft-safe; then
	key='HKLM\Software\Wow6432Node\Blizzard Entertainment\Starcraft Shareware'
	wine reg add "$key" /v InstallPath /d 'D:\system\non-packaged\data\wine-games\SC' /f > /dev/null 2>&1
	wine reg add "$key" /v Program /d 'D:\system\non-packaged\data\wine-games\SC\Starcraft.exe' /f > /dev/null 2>&1
	wine reg add "$key" /v StarCD /d 'D:\system\non-packaged\data\wine-games\SCCD' /f > /dev/null 2>&1
	want starcraft && run starcraft SC Starcraft.exe 240
	want starcraft-interp && run starcraft-interp SC Starcraft.exe 240 BOX64_DYNAREC=0
	want starcraft-safe && run starcraft-safe SC Starcraft.exe 240 BOX64_DYNAREC_SAFEFLAGS=2 \
		BOX64_DYNAREC_STRONGMEM=2 BOX64_DYNAREC_BIGBLOCK=0 BOX64_DYNAREC_CALLRET=0
fi
# Half-Life: Uplink (Valve's free 1999 demo, installed on the host's reference Wine): its default software renderer
# (sw.dll; the launcher takes no -gl, its renderer is chosen in its own video menu) in a window (-windowed:
# 320x240; full screen shows nothing yet), the game's console in HL/valve/qconsole.log (-condebug); New Game (N),
# the difficulty (Return), then the first map
input="focus:Half-Life|wait:60000|key:0x4e|wait:5000|key:0x0d"
want halflife && run halflife HL "hldemo.exe -windowed -condebug" 300
# the same with where each module loaded and the exceptions traced, and with Box64's interpreter
want halflife-trace && run halflife-trace HL "hldemo.exe -windowed -condebug" 200 \
	WINEDEBUG=+loaddll,+seh,err+all,fixme-all
input="focus:Half-Life|wait:240000|key:0x4e|wait:15000|key:0x0d"
want halflife-interp && run halflife-interp HL "hldemo.exe -windowed -condebug" 600 BOX64_DYNAREC=0
input=
# Heroes III's demo: after the intro (~70 s on the Pi; Escape at the main menu quits), the menus' keys — N New Game,
# S Single Scenario, Return Begin, then the welcome's Return (a further Return opens the hero's screen); the hero
# walks by the numpad (2 down, 6 right, 3 down-right...; the arrow keys scroll the map). Its mouse is DirectInput's
# relative motion: absolute clicks do not land.
input="focus:Heroes|wait:90000|key:0x4e|wait:6000|key:0x53|wait:8000|key:0x0d|wait:30000|key:0x0d|wait:4000\
|key:0x62|wait:2500|key:0x63|wait:2500|key:0x66|wait:2500|key:0x66|wait:2500|key:0x63|wait:2500|key:0x62\
|wait:2500|key:0x64|wait:2500|key:0x64|wait:2500|key:0x68"
# without a sound driver (Wine's driver list empty), for an A/B with the run above
if want heroes3-nosound; then
	wine reg add 'HKCU\Software\Wine\Drivers' /v Audio /d "" /f > /dev/null 2>&1
	run heroes3-nosound H3 h3demo.exe 300
	wine reg delete 'HKCU\Software\Wine\Drivers' /v Audio /f > /dev/null 2>&1
fi
want heroes3 && run heroes3 H3 h3demo.exe 360
want heroes3-gltrace && run heroes3-gltrace H3 h3demo.exe 60 WINEDEBUG=err+all,fixme-all,+wgl WINE_D3D_CONFIG=renderer=gl
# the same with the sound path traced (Heroes III's menu stopped answering once Wine had a sound driver)
want heroes3-trace && run heroes3-trace H3 h3demo.exe 180 WINEDEBUG=err+all,fixme-all,+haiku,+mmdevapi,+dsound
input=
click="Electronic Registration|Register Later|Electronic Registration|Forfeit"
want fallout && run fallout falldemo Falldemo.exe 300
click=
want simcity3000-interp && run simcity3000-interp SC3 sc3demo.exe 240 BOX64_DYNAREC=0
# the dynarec checked against the interpreter, opcode by opcode (Box64's COSIM; very slow): where they differ
want simcity3000-cosim && run simcity3000-cosim SC3 sc3demo.exe 300 BOX64_DYNAREC_TEST=1 BOX64_DYNAREC_TEST_NODUP=1
sync
say end
