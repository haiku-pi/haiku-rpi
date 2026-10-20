#!/bin/sh
# soak-apps.sh — a UserBootscript: 15 minutes of the heaviest applications at once on the regular image
# (Firefox in it) plus the STK tree (mkimage-pi4.sh --add-tree artifacts/stk/non-packaged) and the HEVC
# test clips (--add-tree artifacts/media-tests/hevc/non-packaged): Firefox showing a live web page,
# SuperTuxKart's GLES renderer racing (restarted when a race ends), MediaPlayer looping a 1080p HEVC
# stream on the decoder block. Every minute: free memory, temperature/throttling/clocks, which of
# the three still run, and new crash reports (debug_server) in the syslog. Serial lines "SAK ";
# "SAK end ... crashes N" at the end. Needs the network (DHCP) for the web page.
sleep 25
out=/dev/dprintf
say() { echo "SAK $*" > $out; }
secs=900
stk=/boot/system/non-packaged/apps/SuperTuxKart
clip=/boot/system/non-packaged/data/hevc-tests/fhd.mp4
export HOME=/boot/home

say "begin $(uname -a)"
/boot/system/apps/Firefox/Firefox --new-window https://www.haiku-os.org/ > /tmp/ffx.log 2>&1 &
sleep 20
(
	while true; do
		cd $stk && ./SuperTuxKart-GLES --windowed --screensize=1024x576 --disable-texture-compression \
			--profile-time=120 --track=hacienda --numkarts=4 --kart=tux --difficulty=0 \
			> /tmp/stk.log 2>&1
		sleep 2
	done
) &
sleep 20
(
	while true; do
		/boot/system/apps/MediaPlayer "$clip" > /dev/null 2>&1 &
		sleep 30
		hey MediaPlayer quit > /dev/null 2>&1
		sleep 3
	done
) &

crashes0=$(grep -a -c "debug_server: Thread" /var/log/syslog)
start=$(date +%s)
while [ $(( $(date +%s) - start )) -lt $secs ]; do
	sleep 60
	t=$(( $(date +%s) - start ))
	mem=$(sysinfo -mem 2>/dev/null | grep -i 'free\|used' | head -2 | tr -s ' ' | tr '\n' ' ')
	run=""
	for p in Firefox SuperTuxKart-GLES MediaPlayer; do
		if ps | grep -v grep | grep -q "$p"; then run="$run $p"; fi
	done
	crashes=$(( $(grep -a -c "debug_server: Thread" /var/log/syslog) - crashes0 ))
	say "${t}s running:$run crashes $crashes mem $mem"
	cat /dev/power/bcm2835_thermal/0 2>/dev/null | grep -i 'temperature\|throttled\|clocks' | tr '\n' ' ' \
		| while read -r l; do say "${t}s $l"; done
done
crashes=$(( $(grep -a -c "debug_server: Thread" /var/log/syslog) - crashes0 ))
grep -a "debug_server: Thread" /var/log/syslog | tail -n 5 | while read -r l; do say "crash: $l"; done
say "end after ${secs}s crashes $crashes"
