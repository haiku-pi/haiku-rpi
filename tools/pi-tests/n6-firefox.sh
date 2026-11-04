#!/bin/sh
# n6-firefox.sh [SECS] — one Firefox first start with a new profile, for the BFS journal measurement of
# perf-round-h20.md N6: the profile directories are removed, Firefox is launched through the roster
# (/boot/home/launchtime, tools/haiku-tests/launchtime.cpp) and left running SECS s (default 45) after its
# first window, while it writes the new profile; then it is asked to quit (SIGKILL after 30 s).
# Run it under the system profiler to see what the writes cost:
#
#   profile -a -k -S -i 1000 -o /boot/home/n6-ff.prof sh /boot/home/n6-firefox.sh
#
# Lines "N6FF window N ms", "N6FF profile: F files, K KiB", "N6FF gone after N ms", "N6FF total N ms".
secs=${1:-45}
export HOME=/boot/home
ms() { echo $(( ($(date +%s%N) - $1) / 1000000 )); }
rm -rf /boot/home/config/settings/Mozilla /boot/home/.mozilla /boot/home/config/cache/Mozilla
sync
t0=$(date +%s%N)
/boot/home/launchtime /boot/system/apps/Firefox/Firefox 120 > /tmp/n6ff.txt 2>&1 < /dev/null
echo "N6FF window $(grep -o 'window after [0-9]*' /tmp/n6ff.txt | grep -o '[0-9]*$') ms"
sleep "$secs"
echo "N6FF profile: $(find /boot/home/config/settings/Mozilla /boot/home/config/cache/Mozilla -type f 2> /dev/null | wc -l) files, $(du -sk /boot/home/config/settings/Mozilla 2> /dev/null | cut -f1) KiB"
t1=$(date +%s%N)
hey Firefox quit > /dev/null 2>&1
i=0
while [ $i -lt 30 ] && ps | grep -a -q '/Firefox/Firefox'; do sleep 1; i=$((i + 1)); done
echo "N6FF gone after $(ms "$t1") ms"
kill -9 $(ps | awk 'index($1, "/Firefox/") { print $2 }') 2> /dev/null
echo "N6FF total $(ms "$t0") ms"
