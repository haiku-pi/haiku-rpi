#!/bin/sh
# candtest.sh — a UserBootscript for a candidate image's start-up fixes, on a card boot without a
# network. First boot: host name lookups (own name, localhost, a name that does not exist), then
# Firefox's first (cold) and second launch. Later boots: reading the whole Firefox package from the
# card, timed (cold; the packagefs read-ahead), its MD5 sums (one sum over all files, as on the
# host), and Firefox's second launch. Serial lines "CAN ...". Needs /boot/home/launchtime and
# /boot/home/resolvetime (tools/haiku-tests).
out=/dev/dprintf
say() { echo "CAN $*" > $out; }
ms() { echo $(( ($(date +%s%N) - $1) / 1000000 )); }
ff=/boot/system/apps/Firefox
run() {
	/boot/home/launchtime -q $ff/Firefox 120 > /tmp/can.txt 2>&1 < /dev/null
	say "$1 $(grep -o 'window after [0-9]*' /tmp/can.txt | grep -o '[0-9]*$') quit $(grep -o 'gone after [0-9]*' /tmp/can.txt | grep -o '[0-9]*$')"
	sleep 3
}
sleep 25
boot=$(( $(cat /boot/home/candtest.boot 2> /dev/null || echo 0) + 1 ))
echo $boot > /boot/home/candtest.boot
say "boot $boot"
if [ $boot = 1 ]; then
	/boot/home/resolvetime shredder localhost nosuchhost.example 2>&1 | while read line; do say "$line"; done
	run Firefox-cold
	run Firefox-warm
else
	t0=$(date +%s%N); find $ff -type f -exec cat {} + > /dev/null; say "cat-firefox $(ms $t0)"
	say "md5 $(cd $ff && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 md5sum | md5sum)"
	run Firefox-warm
fi
say done
