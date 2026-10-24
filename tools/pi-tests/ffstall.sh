#!/bin/sh
# ffstall.sh — a UserBootscript looking at what Firefox waits on while it starts from the card: the
# Firefox package read first, Firefox launched, then its teams' threads with their states and
# semaphores (ps -s) 4, 8 and 12 s into the launch. Serial lines "FST ...". Needs /boot/home/launchtime
# (tools/haiku-tests/launchtime.cpp); scripts/image-add.sh puts both on a copy of an image.
out=/dev/dprintf
say() { echo "FST $*" > $out; }
ff=/boot/system/apps/Firefox
sleep 25
find $ff -type f -exec cat {} + > /dev/null
say "date: $(date) uptime: $(uptime)"
say "ifconfig: $(ifconfig 2>&1 | tr -s ' \t' ' ' | tr '\n' '|')"
/boot/home/launchtime $ff/Firefox 120 > /tmp/fst.txt 2>&1 < /dev/null &
for s in 4 8 12; do
	sleep 4
	say "--- +$s s"
	for t in $(ps | grep -a '[a]pps/Firefox/Firefox' | awk '{print $(NF-3)}'); do
		ps -s $t 2>&1 | grep -a -v "^\s*$" | while read line; do say "$line"; done
	done
done
wait
say "$(cat /tmp/fst.txt)"
say done
