#!/bin/sh
# ffprofile.sh — a UserBootscript asking whether a Firefox start from the card waits on its profile's
# writes: with the whole Firefox package read first (no package reads left), Firefox twice with its
# default profile (on the card), twice with a new profile on a RAM file system, twice with a new profile
# on the card. Serial lines "CST <what> <window-ms> quit <ms>". Needs /boot/home/launchtime
# (tools/haiku-tests/launchtime.cpp), /boot/home/fsyncbench and /boot/home/resolvetime (fsyncbench.c,
# resolvetime.c there; timed first, with the network setup); scripts/image-add.sh puts them on a copy
# of an image.
out=/dev/dprintf
say() { echo "CST $*" > $out; }
ms() { echo $(( ($(date +%s%N) - $1) / 1000000 )); }
ff=/boot/system/apps/Firefox
# run NAME [ARGS...]
run() {
	name=$1; shift
	/boot/home/launchtime -q $ff/Firefox 120 "$@" > /tmp/cst.txt 2>&1 < /dev/null
	say "$name $(grep -o 'window after [0-9]*' /tmp/cst.txt | grep -o '[0-9]*$') quit $(grep -o 'gone after [0-9]*' /tmp/cst.txt | grep -o '[0-9]*$')"
	sleep 3
}
sleep 25
say "$(/boot/home/fsyncbench 2>&1)"
say "hostname $(hostname); resolv.conf: $(grep -v '^#' /boot/system/settings/network/resolv.conf 2>&1 | tr '\n' ' ')"
say "$(ifconfig 2>&1 | grep -E 'inet addr' | tr -s ' ' | tr '\n' ' ')"
/boot/home/resolvetime 2>&1 | while read line; do say "$line"; done
# a candidate libnetwork.so in /boot/home/lib, if there is one
if [ -f /boot/home/lib/libnetwork.so ]; then
	LIBRARY_PATH=/boot/home/lib:$LIBRARY_PATH /boot/home/resolvetime 2>&1 | while read line; do say "new-lib $line"; done
fi
t0=$(date +%s%N); find $ff -type f -exec cat {} + > /dev/null; say "cat-firefox $(ms $t0)"
run default-1
run default-2
mkdir -p /ram && mount -t ramfs /ram && say "ramfs mounted"
mkdir -p /ram/p /boot/home/ffp-new
run ram-new-1 --profile /ram/p
run ram-new-2 --profile /ram/p
run card-new-1 --profile /boot/home/ffp-new
run card-new-2 --profile /boot/home/ffp-new
rm -rf /boot/home/ffp-new
if [ -f /boot/home/lib/libnetwork.so ]; then
	export LIBRARY_PATH=/boot/home/lib:$LIBRARY_PATH
	run new-lib-default-1
	run new-lib-default-2
fi
say done
