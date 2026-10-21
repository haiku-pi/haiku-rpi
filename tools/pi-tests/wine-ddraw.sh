#!/bin/sh
# wine-ddraw.sh — a UserBootscript for a disk with a Wine prefix (netboot-cycle.sh --keep-disk after wine-games.sh,
# --add the ddtest builds): Wine's DirectDraw 2D path against a known picture. ddtest (tools/wine-tests/ddtest.c)
# as arm64 (Wine alone) and as x86 (under the emulator), at 16 and 32 bpp, a screenshot of each
# (/boot/home/wine-ddraw-<name>.png); then SimCity 3000 for 120 s with ddraw's mode and surface traces.
# Serial console lines: "WDD ".
sleep 15
out=/dev/dprintf
say() { echo "WDD $*" > $out; }
export PATH=/boot/system/non-packaged/bin:$PATH
export WINEPREFIX=/boot/home/wineprefix
export WINEDEBUG=err+all,fixme-all
export XKB_CONFIG_ROOT=/boot/system/non-packaged/data/X11/xkb
tests=/boot/system/non-packaged/data/wine-tests
[ -f $WINEPREFIX/drive_c/windows/syswow64/kernel32.dll ] || { say "no prefix with syswow64"; say end; exit 0; }

# NAME EXE ARGS...
dd() {
	name=$1
	shift
	wine "$@" > /tmp/dd-$name.txt 2>&1 &
	pid=$!
	sleep 20
	screenshot -s /boot/home/wine-ddraw-$name.png > /dev/null 2>&1
	sleep 15
	kill -0 $pid 2> /dev/null && say "$name: still running"
	grep -a -E 'ddtest|err:' /tmp/dd-$name.txt | head -n 8 | while read -r line; do say "$name: $(echo "$line" | cut -c1-200)"; done
	wineserver -k
	sleep 3
}

dd arm64-16 $tests/ddtest-arm64.exe 640 480 16 25
dd x86-16 $tests/ddtest-x86.exe 640 480 16 25
dd x86-32 $tests/ddtest-x86.exe 640 480 32 25

cd /boot/system/non-packaged/data/wine-games/SC3
WINEDEBUG=err+all,fixme-all,trace+ddraw wine sc3demo.exe > /tmp/sc3.txt 2>&1 &
pid=$!
sleep 120
screenshot -s /boot/home/wine-ddraw-sc3.png > /dev/null 2>&1
wineserver -k
sleep 3
grep -a -i -E 'SetDisplayMode|SetCooperativeLevel|GetDisplayMode|CreateSurface|PixelFormat|bpp|RGBBitCount|DDPF' /tmp/sc3.txt \
	| head -n 40 | while read -r line; do say "sc3: $(echo "$line" | cut -c1-220)"; done
say "sc3: trace $(wc -l < /tmp/sc3.txt) lines"
cp /tmp/sc3.txt /boot/home/wine-ddraw-sc3.txt
sync
say end
