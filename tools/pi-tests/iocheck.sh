#!/bin/sh
# iocheck.sh — a UserBootscript for storage-path changes, on a card boot without a network. First boot:
# Firefox's first (cold) and second launch. Later boots: the whole Firefox package read from the card
# (cold; timed) and its MD5 sums (one sum over all files, as on the host), the package file read
# uncached in requests of 21/64/256 KiB at aligned and unaligned offsets (nocacheread), raw reads by
# size (disklat), and Firefox's second launch. Serial lines "IOC ...". Needs /boot/home/launchtime,
# /boot/home/nocacheread and /boot/home/disklat (tools/haiku-tests).
out=/dev/dprintf
say() { echo "IOC $*" > $out; }
ms() { echo $(( ($(date +%s%N) - $1) / 1000000 )); }
ff=/boot/system/apps/Firefox
run() {
	/boot/home/launchtime -q $ff/Firefox 120 > /tmp/ioc.txt 2>&1 < /dev/null
	say "$1 $(grep -o 'window after [0-9]*' /tmp/ioc.txt | grep -o '[0-9]*$') quit $(grep -o 'gone after [0-9]*' /tmp/ioc.txt | grep -o '[0-9]*$')"
	sleep 3
}
sleep 25
boot=$(( $(cat /boot/home/iocheck.boot 2> /dev/null || echo 0) + 1 ))
echo $boot > /boot/home/iocheck.boot
say "boot $boot"
if [ $boot = 1 ]; then
	run Firefox-cold
	run Firefox-warm
else
	t0=$(date +%s%N); find $ff -type f -exec cat {} + > /dev/null; say "cat-firefox $(ms $t0)"
	say "md5 $(cd $ff && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 md5sum | md5sum)"
	/boot/home/nocacheread $(ls /boot/system/packages/firefox-*.hpkg | head -1) 16 2>&1 | while read l; do say "$l"; done
	/boot/home/disklat /dev/disk/mmc/0/raw 100 2>&1 | while read l; do say "$l"; done
	run Firefox-warm
fi
say done
