#!/bin/sh
# ffprofile.sh — a UserBootscript asking whether a Firefox start from the card waits on its profile's
# writes: with the whole Firefox package read first (no package reads left), Firefox twice with its
# default profile (on the card), twice with a new profile on a RAM file system, twice with a new profile
# on the card. Serial lines "CST <what> <window-ms> quit <ms>". Needs /boot/home/launchtime
# (tools/haiku-tests/launchtime.cpp); scripts/image-add.sh puts both on a copy of an image.
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
say done
