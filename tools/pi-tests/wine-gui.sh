#!/bin/sh
# wine-gui.sh — a UserBootscript: Wine windows on Haiku (the Wayland driver over X547's in-process Wayland
# server): creates a prefix, then opens Wine's Minesweeper and Notepad, takes a screenshot of the desktop
# (/boot/home/wine-gui.png) and reports. The Wayland stack comes as a tree in non-packaged (the test image),
# so libxkbcommon's data path is set. Serial console lines: "WGU ".
sleep 15
out=/dev/dprintf
say() { echo "WGU $*" > $out; }
export PATH=/boot/system/non-packaged/bin:$PATH
export WINEPREFIX=/boot/home/wineprefix
export WINEDEBUG=err+all,fixme-all
export XKB_CONFIG_ROOT=/boot/system/non-packaged/data/X11/xkb
date -s "@$(stat -c %Y /boot/home/config/settings/boot/UserBootscript)" > /dev/null 2>&1
# bounded SECS OUT CMD...: runs CMD with its output in OUT, killed after SECS (a crash waits in the debugger)
bounded() {
	secs=$1; outf=$2; shift 2
	"$@" > "$outf" 2>&1 &
	pid=$!
	waited=0
	while [ $waited -lt $secs ] && kill -0 $pid 2> /dev/null; do sleep 1; waited=$((waited + 1)); done
	if kill -0 $pid 2> /dev/null; then
		kill -9 $pid 2> /dev/null
		echo "(killed after $secs s)" >> "$outf"
		return 124
	fi
	wait $pid
}
start=$(date +%s)
bounded 600 /tmp/wineboot.txt wineboot -i
say "wineboot: exit $? after $(( $(date +%s) - start )) s"
say "prefix: after $(( $(date +%s) - start )) s; syswow64 $(ls $WINEPREFIX/drive_c/windows/syswow64 | wc -l) files"
screenshot -s /boot/home/wine-after-boot.png > /dev/null 2>&1
ps | grep -a -E 'wine|explorer|rundll|services|winedevice|plugplay' | grep -a -v grep | awk '{print $1, $NF}' | head -n 20 \
	| while read -r line; do say "  proc: $line"; done
grep -a 'err:\|wine:' /tmp/wineboot.txt | grep -a -v 'nodrv_\|copy error 1812\|winebth\|getaddrinfo' | head -n 12 \
	| while read -r line; do say "  boot: $(echo "$line" | cut -c1-200)"; done
grep -a -i 'wayland\|winediag\|driver' /tmp/wineboot.txt | head -n 10 | while read -r line; do say "  boot: $(echo "$line" | cut -c1-200)"; done
wine winemine > /tmp/winemine.txt 2>&1 &
sleep 20
wine notepad > /tmp/notepad.txt 2>&1 &
sleep 40
screenshot -s /boot/home/wine-gui.png > /dev/null 2>&1
say "screenshot: $(ls -l /boot/home/wine-gui.png 2>&1 | awk '{print $5}') bytes"
for f in /tmp/winemine.txt /tmp/notepad.txt; do
	head -n 12 $f | while read -r line; do say "  $(basename $f .txt): $(echo "$line" | cut -c1-200)"; done
done
say "windows: $(ps | grep -a -c -E 'winemine|notepad')"
sync
sleep 5
say end
