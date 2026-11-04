#!/bin/sh
# shutdown-test.sh — UserBootscript for one network-boot cycle that restarts the Pi twice and then powers it off
# (design/renkuos-fixes.md): boot 1 `shutdown -r` (the registrar's shutdown, the way Deskbar's "Restart" goes),
# boot 2 `shutdown -q -r` (straight to the kernel), boot 3 `shutdown` (power-off, as Deskbar's "Shut down").
# The boot count lives on the disk, which the network boot's disk server keeps across the restarts.
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
sleep 20
case $n in
1) say "shutdown -r"; shutdown -r ;;
2) say "shutdown -q -r"; shutdown -q -r ;;
3) say "shutdown"; shutdown ;;
*) say "done" ;;
esac
say "shutdown returned $?"
