#!/bin/sh
# coldstart.sh — a UserBootscript that times first launches after a boot from the card (nothing cached
# yet): Firefox, WebPositive, Terminal, MediaPlayer, ShowImage, each to its first window, quit after.
# Needs /boot/home/launchtime (tools/haiku-tests/launchtime.cpp); scripts/image-add.sh puts both on a
# copy of an image. Serial lines "CST <app> <ms>".
out=/dev/dprintf
say() { echo "CST $*" > $out; }
sleep 25
for app in apps/Firefox/Firefox apps/WebPositive apps/Terminal apps/MediaPlayer apps/ShowImage; do
	/boot/home/launchtime -q /boot/system/$app 120 > /tmp/cst.txt 2>&1 < /dev/null
	say "$(basename $app) $(grep -o '[0-9]* ms' /tmp/cst.txt | head -1)"
	sleep 5
done
say done
