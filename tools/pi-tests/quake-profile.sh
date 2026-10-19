#!/bin/sh
# quake-profile.sh — a UserBootscript: where does QuakeSpasm's frame time go on the Pi? It plays the
# timedemo at 640x480 for 45 s under `profile -k -s` (sampling, kernel included, summary); a `top`
# snapshot of all threads (app_server, the v3d worker, ...) is taken half-way. Serial console lines:
# "QPR " markers and the reports.
sleep 20
out=/dev/dprintf
dir=/boot/system/non-packaged/apps/QuakeSpasm
say() { echo "QPR $*" > $out; }
cd $dir || { say "no $dir"; exit 1; }
say "profile start"
profile -k -s -i 2000 ./quakespasm -basedir $dir -window -width 640 -height 480 -nosound \
	+timedemo demo1 > /tmp/profile.txt 2>&1 &
sleep 25
top -n 1 -d > /tmp/top.txt 2>&1
sleep 20
# Haiku's ps: the team's name, then its id
kill $(ps | grep -a quakespasm | grep -v -e profile -e grep | awk '{print $2}') 2> /dev/null
sleep 8
say "top:"
head -n 60 /tmp/top.txt | while read -r line; do say "top: $line"; done
say "profile:"
head -n 120 /tmp/profile.txt | while read -r line; do say "prof: $line"; done
say end
