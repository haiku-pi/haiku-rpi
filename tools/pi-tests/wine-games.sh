#!/bin/sh
# wine-games.sh — a UserBootscript: 32-bit x86 Windows games under Wine (WoW64, Box64) on the Haiku desktop.
# The games are free demos unpacked into the test image's non-packaged/data/wine-games (never published:
# downloaded for the test only, see docs/design/wine-x86.md). Makes a prefix with the x86 emulator if the disk
# has none (netboot-cycle.sh --keep-disk keeps it for the next run), sets wined3d's GDI renderer (no GL yet),
# then runs each game for a while, with a screenshot every 60 s (/boot/home/wine-games-<game>-<n>.png).
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
say "disk: $(df -h /boot 2> /dev/null | tail -n 1)"
wine reg add 'HKCU\Software\Wine\Direct3D' /v renderer /d gdi /f > /dev/null 2>&1
wineserver -w

# GAME DIR EXE SECONDS
run() {
	cd "$games/$2" || { say "$1: no $games/$2"; return; }
	say "$1: start"
	wine "$3" > /tmp/$1.txt 2>&1 &
	pid=$!
	n=1
	while [ $((n * 60)) -le $4 ]; do
		sleep 60
		screenshot -s /boot/home/wine-games-$1-$n.png > /dev/null 2>&1
		say "$1: $((n * 60)) s, $(kill -0 $pid 2> /dev/null && echo running || echo exited)," \
			"screenshot $(ls -l /boot/home/wine-games-$1-$n.png 2>&1 | awk '{print $5}') bytes"
		n=$((n + 1))
	done
	grep -a -v '^$' /tmp/$1.txt | head -n 25 | while read -r line; do say "  $1: $(echo "$line" | cut -c1-200)"; done
	wineserver -k
	sleep 3
	cp /tmp/$1.txt /boot/home/wine-games-$1.txt
}

run simcity3000 SC3 sc3demo.exe 360
run fallout falldemo Falldemo.exe 240
sync
say end
