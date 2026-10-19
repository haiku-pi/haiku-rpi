#!/bin/sh
# quake-perf.sh — a UserBootscript: why does QuakeSpasm wait? It plays demo1 at 640x480 for 40 s with
# its frame times (host_speeds, from -condebug's console log) and Mesa's V3D_DEBUG=perf
# warnings (flushes and stalls, with their reasons) counted by message. Serial console lines: "QPF ".
sleep 20
out=/dev/dprintf
dir=/boot/system/non-packaged/apps/QuakeSpasm
say() { echo "QPF $*" > $out; }
cd $dir || { say "no $dir"; exit 1; }
say "quake start"
V3D_DEBUG=perf ./quakespasm -basedir $dir -window -width 640 -height 480 -nosound -condebug \
	+host_speeds 1 +playdemo demo1 > /tmp/quake.txt 2>&1 &
sleep 40
# Haiku's ps: the team's name, then its id
kill $(ps | grep -a quakespasm | grep -v grep | awk '{print $2}') 2> /dev/null
sleep 3
say "lines: $(wc -l < /tmp/quake.txt)"
# the messages without their numbers, counted
sed -e 's/[0-9][0-9]*/N/g' /tmp/quake.txt | sort | uniq -c | sort -rn | head -n 40 \
	| while read -r line; do say "perf: $line"; done
# host_speeds: per frame "tot ms server ms gfx ms snd ms" (in the console log, as stdout is lost)
tail -n 25 qconsole.log | while read -r line; do say "speeds: $line"; done
grep -a -i -E 'egl_haiku|import' qconsole.log /tmp/quake.txt | head -n 5 | while read -r line; do say "egl: $line"; done
rm -f qconsole.log
say end
