#!/bin/sh
# wine-gui-trace.sh — a UserBootscript for a disk that already has a Wine prefix (netboot-cycle.sh --keep-disk
# --bootscript this; with no prefix it makes one, without the x86 emulator): Minesweeper with the Wayland driver's trace, a screenshot, the trace's window lines.
# Serial console lines: "WGT ".
sleep 15
out=/dev/dprintf
say() { echo "WGT $*" > $out; }
export PATH=/boot/system/non-packaged/bin:$PATH
export WINEPREFIX=/boot/home/wineprefix
export XKB_CONFIG_ROOT=/boot/system/non-packaged/data/X11/xkb
# no prefix yet: make one without the x86 emulator (the 32-bit setup is not what is tested here)
if [ ! -f $WINEPREFIX/drive_c/windows/system32/kernel32.dll ]; then
	rm -rf $WINEPREFIX
	rm -f /boot/system/non-packaged/lib/wine/aarch64-windows/xtajit.dll
	start=$(date +%s)
	WINEDEBUG=err+all,fixme-all wineboot -i > /tmp/wineboot.txt 2>&1 &
	bpid=$!
	( sleep 200; ps -a > /tmp/ps-boot.txt 2>&1 ) &
	waited=0
	while [ $waited -lt 280 ] && kill -0 $bpid 2> /dev/null; do sleep 1; waited=$((waited + 1)); done
	say "wineboot (no x86): $(kill -0 $bpid 2> /dev/null && echo 'still running' || echo done) after $waited s"
	if [ -s /tmp/ps-boot.txt ]; then
		awk '/^Team/{team=1} {print}' /tmp/ps-boot.txt | grep -a -A14 -E 'wine|rundll|services|explorer|plugplay|winedevice' \
			| grep -a -v '^--$' | head -n 60 | while read -r line; do say "  ps: $line"; done
	fi
	wineserver -k > /dev/null 2>&1
fi
say "prefix: $(ls $WINEPREFIX/drive_c/windows/system32 2> /dev/null | wc -l) system32 files"
WINEDEBUG=err+all,fixme-all,+waylanddrv wine winemine > /tmp/wm.txt 2>&1 &
pid=$!
sleep 45
screenshot -s /boot/home/wine-gui-trace.png > /dev/null 2>&1
say "screenshot: $(ls -l /boot/home/wine-gui-trace.png 2>&1 | awk '{print $5}') bytes; trace $(wc -l < /tmp/wm.txt) lines"
grep -a -i -E 'configure|size|rect|geometry|output|mode|scale|buffer|surface_role|map|toplevel' /tmp/wm.txt | head -n 70 \
	| while read -r line; do say "  $(echo "$line" | cut -c1-210)"; done
# the threads of Wine's processes (an event thread that spins shows as "run" with growing user time)
ps -a 2> /dev/null | grep -a -A14 -E '^[^ ]*(wine|explorer|winemine)' | grep -a -E 'pthread|wayland|run ' | head -n 20 \
	| while read -r line; do say "  ps: $line"; done
kill -9 $pid 2> /dev/null
for t in $(ps | grep -a -E 'wine' | grep -a -v grep | awk '{print $2}'); do kill -9 $t 2> /dev/null; done
cp /tmp/wm.txt /boot/home/wine-gui-trace.txt
sync
say end
