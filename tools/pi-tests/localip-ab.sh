#!/bin/sh
# localip-ab.sh — Wine's view of the local network with and without patches/wine-11.21/0031 (the IPv4 routing table
# on Haiku), over ssh in a Pi session whose non-packaged Wine has lib/wine/aarch64-unix/nsiproxy.so.orig (as
# packaged) and nsiproxy.so.new (with 0031) next to each other (docs/design/wine-x86.md, W11):
#
#   sh localip-ab.sh [orig|new]...       (default: orig new; the last one stays installed)
#
# Runs data/wine-tests/localip-x86.exe (tools/wine-tests/localip.c: Need for Speed: Porsche Unleashed's local
# address probe and the IP Helper tables) with each nsiproxy.so, the wineserver stopped in between so the
# library is loaded afresh. Lines "LAB <which> ...".
. /boot/home/wenv.sh
np=/boot/system/non-packaged
unix=$np/lib/wine/aarch64-unix
[ $# -gt 0 ] || set -- orig new
# a prefix with the x86 emulator, as tools/pi-tests/wine-games.sh makes it
if [ ! -f "$WINEPREFIX/drive_c/windows/syswow64/kernel32.dll" ]; then
	start=$(date +%s)
	WINEDLLOVERRIDES="mscoree,mshtml=" wineboot -i > /tmp/wineboot.txt 2>&1
	timeout 900 wineserver -w
	echo "LAB prefix: $(( $(date +%s) - start )) s, syswow64 $(ls "$WINEPREFIX/drive_c/windows/syswow64" 2> /dev/null | wc -l) files"
fi
ln -sfn /boot "$WINEPREFIX/dosdevices/d:"
for which in "$@"; do
	wineserver -k > /dev/null 2>&1
	sleep 2
	cp "$unix/nsiproxy.so.$which" "$unix/nsiproxy.so" || { echo "LAB $which: no nsiproxy.so.$which"; continue; }
	wine "$np/data/wine-tests/localip-x86.exe" 2>&1 | grep -a 'LOCALIP' | while read -r l; do echo "LAB $which $l"; done
done
echo "LAB route: $(route 2>&1 | grep -a -c -E 'genet|broadcom|loop') routes in Haiku's table"
