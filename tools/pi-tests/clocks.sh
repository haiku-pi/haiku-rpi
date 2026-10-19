#!/bin/sh
# clocks.sh — a UserBootscript: the temperature and the clocks the firmware runs (ARM, core, V3D),
# every 5 s for 3 minutes after the desktop, with no load. Serial console lines: "CLK ".
out=/dev/dprintf
say() { echo "CLK $*" > $out; }
i=0
while [ $i -lt 36 ]; do
	say "$(tr -s ' \n' ' ' < /dev/power/bcm2835_thermal/0)"
	sleep 5
	i=$((i + 1))
done
say end
