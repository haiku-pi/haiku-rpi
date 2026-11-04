#!/bin/sh
# pwr.sh — H22 test group PWR (docs/design/x86-64-check.md §4.3; the Pi's tools/pi-tests/shutdown-test.sh for
# QEMU): boot 1 `shutdown -r` (the registrar's restart, as Deskbar's "Restart"), boot 2 `shutdown -q -r`
# (straight to the kernel), boot 3 `shutdown` (the registrar's power-off: QEMU exits). The boot count lives in
# /boot/home (the run's disk overlay survives the restarts). Each boot shows the crash reports of the previous
# ones. Serial lines "X86T pwr ...".
G=pwr
. /boot/home/x86t/lib.sh
state=/boot/home/pwr.state
n=$(cat $state 2> /dev/null || echo 0)
n=$((n + 1))
echo $n > $state
sync
waitfor -m application/x-vnd.Be-TRAK
waitfor -m application/x-vnd.Be-TSKB
say "result boot$n PASS rc=0 desktop up"
for r in /boot/home/Desktop/*.report; do
	[ -e "$r" ] || continue
	say "result crash-report FAIL rc=1 $r"
	head -n 30 "$r" | while IFS= read -r l; do say "out report: $l"; done
	mv "$r" "$r.shown"
done
sleep 10
case $n in
1) say "info shutdown -r"; shutdown -r ;;
2) say "info shutdown -q -r"; shutdown -q -r ;;
3) say "info shutdown (power-off)"; say end; shutdown ;;
*) say "result boot-count FAIL rc=1 boot $n"; finish ;;
esac
say "info shutdown returned $?"
