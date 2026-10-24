#!/bin/sh
# coldcat.sh — a UserBootscript separating where a cold Firefox start from the card goes: either the
# first launch alone (MODE=launch), or after reading every file of the Firefox package first
# (MODE=catall), so what remains is the rest of the system. Then a second, warm launch. Serial lines
# "CST <what> <ms>". Put on an image copy with scripts/image-add.sh (with /boot/home/launchtime,
# tools/haiku-tests/launchtime.cpp), as coldstart.sh; MODE comes from /boot/home/coldcat.mode.
out=/dev/dprintf
say() { echo "CST $*" > $out; }
ms() { echo $(( ($(date +%s%N) - $1) / 1000000 )); }
mode=$(cat /boot/home/coldcat.mode 2> /dev/null || echo launch)
ff=/boot/system/apps/Firefox
sleep 25
if [ "$mode" = catall ]; then
	t0=$(date +%s%N); find $ff -type f -exec cat {} + > /dev/null; say "cat-firefox $(ms $t0)"
fi
for run in Firefox Firefox-again; do
	/boot/home/launchtime -q $ff/Firefox 120 > /tmp/cst.txt 2>&1 < /dev/null
	say "$run $(grep -o 'window after [0-9]*' /tmp/cst.txt | grep -o '[0-9]*$') quit $(grep -o 'gone after [0-9]*' /tmp/cst.txt | grep -o '[0-9]*$')"
	sleep 3
done
say done
