#!/bin/sh
# soak.sh — a UserBootscript: 20 minutes of sustained load (H13) with the games tree
# (mkimage-pi4.sh --add-tree artifacts/games/non-packaged): QuakeSpasm cycling its demos in a
# 1280x720 window (GPU + CPU), an SD loop (write 64 MiB, read it back, compare checksums) and
# Ethernet pings to the bench host (static address, as the bench runs no DHCP server). Every
# minute: temperature, throttling, clocks, whether Quake still runs, and the loops' counts.
# Serial console lines: "SOAK ".
sleep 20
out=/dev/dprintf
say() { echo "SOAK $*" > $out; }
minutes=${SOAK_MINUTES:-20}
dir=/boot/system/non-packaged/apps/QuakeSpasm
work=/boot/home/soak
mkdir -p $work

cd $dir || { say "no $dir"; exit 1; }
./quakespasm -basedir $dir -window -width 1280 -height 720 -nosound +startdemos demo1 demo2 demo3 \
	> /tmp/soak-quake.txt 2>&1 &
quake=$!

# SD: each pass writes fresh data, reads it back, and counts a pass or a mismatch
(
	pass=0
	while true; do
		dd if=/dev/urandom of=$work/data bs=1048576 count=64 2> /dev/null
		a=$(md5sum < $work/data)
		sync
		b=$(md5sum < $work/data)
		if [ "$a" = "$b" ]; then
			pass=$((pass + 1))
			echo "$pass" > $work/sd-passes
		else
			echo "mismatch" >> $work/sd-errors
		fi
		rm -f $work/data
	done
) &
sd=$!

for n in /dev/net/genet/*; do
	[ -e "$n" ] && ifconfig "$n" 10.42.0.50 255.255.255.0 up
done
sleep 5

pings=0
pingFails=0
m=0
while [ $m -lt $minutes ]; do
	sleep 50
	if ping -c 5 10.42.0.1 > /dev/null 2>&1; then
		pings=$((pings + 1))
	else
		pingFails=$((pingFails + 1))
	fi
	m=$((m + 1))
	if kill -0 $quake 2> /dev/null; then q=running; else q=GONE; fi
	say "minute $m: quake $q, sd passes $(cat $work/sd-passes 2> /dev/null), sd errors" \
		"$(wc -l < $work/sd-errors 2> /dev/null || echo 0), pings ok $pings failed $pingFails," \
		"$(tr -s ' \n' ' ' < /dev/power/bcm2835_thermal/0)"
done
kill $quake $sd
say "end"
