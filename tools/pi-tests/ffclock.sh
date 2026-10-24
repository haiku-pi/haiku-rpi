#!/bin/sh
# ffclock.sh — a UserBootscript asking whether Firefox's slow start on a card boot without a network
# comes from the clock (no RTC, no NTP: 1970): the Firefox package read first; Firefox under strace
# (all threads, --no-color, to a file) with the clock as it is, quit after 30 s, and its syscalls that
# took over 300 ms; then launchtime with the clock as it is, and twice after setting the clock to the
# build day. Serial lines "FCL ...". Needs /boot/home/launchtime (tools/haiku-tests/launchtime.cpp).
out=/dev/dprintf
say() { echo "FCL $*" > $out; }
ff=/boot/system/apps/Firefox
# run NAME: one timed launch, quit 2 s after the window
run() {
	/boot/home/launchtime -q $ff/Firefox 120 > /tmp/fcl.txt 2>&1 < /dev/null
	say "$1 $(grep -o 'window after [0-9]*' /tmp/fcl.txt | grep -o '[0-9]*$') quit $(grep -o 'gone after [0-9]*' /tmp/fcl.txt | grep -o '[0-9]*$')"
	sleep 3
}
sleep 25
find $ff -type f -exec cat {} + > /dev/null
say "date: $(date)"
strace -T -s -t --no-color -o /tmp/ff.strace $ff/Firefox > /dev/null 2>&1 < /dev/null &
sleep 30
hey Firefox quit > /dev/null 2>&1
sleep 10
say "strace: $(wc -l < /tmp/ff.strace) lines; syscalls over 300 ms:"
grep -a -E '\(([3-9][0-9]{5}|[0-9]{7,}) us\)' /tmp/ff.strace | cut -c1-300 | while read line; do say "$line"; done
for t in $(ps | grep -a '[a]pps/Firefox/Firefox' | awk '{print $(NF-3)}'); do kill -9 $t; done
sleep 2
run clock-1970
date -s "2026-10-24 22:00:00" > /dev/null 2>&1
say "date: $(date)"
run clock-set-1
run clock-set-2
say done
