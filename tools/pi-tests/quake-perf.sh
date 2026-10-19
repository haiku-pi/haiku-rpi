#!/bin/sh
# quake-perf.sh — a UserBootscript: why does QuakeSpasm wait? It plays demo1 for 40 s in a window of
# each size (640x480 1280x720 1920x1080) with its frame rate (HAIKU_EGL_FPS: egl_haiku reports it
# every 5 s), the temperature and clocks every 5 s, and Mesa's V3D_DEBUG=perf warnings (flushes and
# stalls, with their reasons) counted by message. Serial console lines: "QPF <size> ...".
sleep 20
out=/dev/dprintf
dir=/boot/system/non-packaged/apps/QuakeSpasm
say() { echo "QPF $*" > $out; }
cd $dir || { say "no $dir"; exit 1; }
for size in 640x480 1280x720 1920x1080; do
	width=${size%x*}
	height=${size#*x}
	say "$size quake start"
	HAIKU_EGL_FPS=1 V3D_DEBUG=perf ./quakespasm -basedir $dir -window -width $width -height $height \
		-nosound -condebug +playdemo demo1 > /tmp/quake.txt 2>&1 &
	quake=$!
	# temperature and the clocks the firmware runs, every 5 s
	for i in 1 2 3 4 5 6 7 8; do
		sleep 5
		say "$size thermal: $(tr -s ' \n' ' ' < /dev/power/bcm2835_thermal/0)"
	done
	kill $quake
	sleep 3
	grep -a 'frames/s' /tmp/quake.txt | while read -r line; do say "$size rate: $line"; done
	say "$size lines: $(wc -l < /tmp/quake.txt)"
	# the messages without their numbers, counted
	sed -e 's/[0-9][0-9]*/N/g' /tmp/quake.txt | sort | uniq -c | sort -rn | head -n 15 \
		| while read -r line; do say "$size perf: $line"; done
	rm -f qconsole.log
done
say end
