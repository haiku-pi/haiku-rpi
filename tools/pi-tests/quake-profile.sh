#!/bin/sh
# quake-profile.sh — a UserBootscript: where does QuakeSpasm's frame time go on the Pi? It plays the
# timedemo at 640x480 while `profile -a -k -S` samples the whole system for 25 s (all teams, kernel
# frames, one combined report), and a `top` snapshot of all threads is taken half-way. Serial console lines:
# "QPR " markers and the reports.
sleep 20
out=/dev/dprintf
dir=/boot/system/non-packaged/apps/QuakeSpasm
say() { echo "QPR $*" > $out; }
cd $dir || { say "no $dir"; exit 1; }
say "quake start"
./quakespasm -basedir $dir -window -width 640 -height 480 -nosound +timedemo demo1 \
	> /tmp/quake.txt 2>&1 &
sleep 15
# the whole system (app_server, the v3d worker, the kernel too) for 25 s; SIGINT makes it report
profile -a -k -S -i 2000 -o /tmp/profile.txt > /tmp/profile.out 2>&1 &
profiler=$!
sleep 10
top -n 1 -d > /tmp/top.txt 2>&1
sleep 15
kill -INT $profiler
sleep 5
# Haiku's ps: the team's name, then its id
kill $(ps | grep -a quakespasm | grep -v grep | awk '{print $2}') 2> /dev/null
sleep 3
head -n 40 /tmp/top.txt | while read -r line; do say "top: $line"; done
cat /tmp/profile.out | while read -r line; do say "profile: $line"; done
head -n 150 /tmp/profile.txt | while read -r line; do say "prof: $line"; done
say end
