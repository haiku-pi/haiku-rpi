#!/bin/sh
# shutdown-test.sh — UserBootscript for one network-boot cycle that restarts the Pi twice and then powers it off
# (design/renkuos-fixes.md): boot 1 `shutdown -r` (the registrar's shutdown, the way Deskbar's "Restart" goes),
# boot 2 `shutdown -q -r` (straight to the kernel), boot 3 `shutdown` (power-off, as Deskbar's "Shut down");
# /boot/home/shutdown-test.restarts = N: N registrar restarts first. Crashing programs save reports instead of
# showing the crash alert (debug_server default_action log), and each boot prints the previous boots' reports.
# The boot count lives on the disk, which the network boot's disk server keeps across the restarts.
# Before each shutdown the test lists Tracker's threads ("tracker threads").
# Serial console lines: "SDT ". Grade: three "SDT boot <n>" lines, a new U-Boot banner before boots 2 and 3, and no
# further U-Boot banner after boot 3's shutdown.
out=/dev/dprintf
say() { echo "SDT $*" > $out; }
state=/boot/home/shutdown-test.state
n=$(cat $state 2> /dev/null || echo 0)
n=$((n + 1))
echo $n > $state
sync
say "boot $n"
# a program that crashes while the registrar quits it would stop the shutdown at its crash alert: save a report
# (on the Desktop) instead, and show the reports of the previous boots here
ds=/boot/home/config/settings/system/debug_server/settings
if [ ! -e $ds ]; then
	mkdir -p $(dirname $ds)
	echo 'default_action log' > $ds
fi
for r in /boot/home/Desktop/*.report; do
	[ -e "$r" ] || continue
	say "report $r"
	head -n 60 "$r" | while read -r line; do say "  $line"; done
	mv "$r" "$r.shown"
done
sleep 20
# Tracker's threads (a crash that leaves no report can still be placed by its thread id;
# design/tracker-shutdown-crash.md)
tracker_threads() {
	ps -a Tracker 2> /dev/null | awk 'NF >= 6 && $(NF - 4) ~ /^[0-9]+$/ {
		name = $1; for (i = 2; i <= NF - 5; i++) name = name "_" $i; printf "%s:%s ", $(NF - 4), name }'
}
say "tracker threads $(tracker_threads)"
# /boot/home/shutdown-test.restarts: how many registrar restarts before the direct one (default 1)
restarts=1
[ -r /boot/home/shutdown-test.restarts ] && restarts=$(cat /boot/home/shutdown-test.restarts)
if [ $n -le $restarts ]; then
	say "shutdown -r"; shutdown -r
elif [ $n = $((restarts + 1)) ]; then
	say "shutdown -q -r"; shutdown -q -r
elif [ $n = $((restarts + 2)) ]; then
	say "shutdown"; shutdown
else
	say "done"
fi
say "shutdown returned $?"
