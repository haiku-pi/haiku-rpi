#!/bin/sh
# ta1-sweep.sh [TIMEOUT [HOLD [QUIT [MATCH]]]] — on a Pi running the mega image: open every entry of ~/Desktop/Test Apps
# and the Deskbar Applications entries the mega image adds, as a double-click does (trackeropen: a
# B_REFS_RECEIVED to Tracker, which launches the entry with its own environment), one at a time. Per entry:
# a shown window within TIMEOUT s (default 90), the team still running with a window HOLD s later (default 10),
# a screenshot (/boot/home/ta1/NN.png); with QUIT=1, B_QUIT_REQUESTED to the team and whether it ended (QUIT=2: to its shown windows, as their close
# buttons send it). Then
# every team the entry started is ended (as tools/mega/smoke-pi.sh does). MATCH: only the entries whose
# path matches that extended regular expression. (With QUIT=1 the screenshot comes after the quit.) One line per entry: "TA1 NN NAME: ...".
# Needs /boot/home/trackeropen (tools/haiku-tests/trackeropen.cpp).
timeout=${1:-90}
hold=${2:-10}
quit=${3:-0}
match=${4:-.}
out=/boot/home/ta1
mkdir -p $out
teams() { ps | awk 'NR > 1 { print $(NF - 3), $1 }' | sort; }
entries=/tmp/ta1-entries
: > $entries
for f in "/boot/home/Desktop/Test Apps"/*; do
	[ -x "$f" ] && [ ! -d "$f" ] && echo "$f" >> $entries
done
for name in Blender OpenArena PhotoCraft SuperTuxKart Firefox; do
	f=/boot/system/data/deskbar/menu/Applications/$name
	[ -e "$f" ] && echo "$f" >> $entries
done
grep -E -- "$match" $entries > $entries.m
mv $entries.m $entries
n=0
while read -r f; do
	n=$((n + 1))
	nn=$(printf '%02d' $n)
	teams > /tmp/ta1-before
	q=
	[ "$quit" = 1 ] && q=-q
	[ "$quit" = 2 ] && q=-w
	result=$(/boot/home/trackeropen $q -h $hold "$f" $timeout 2>&1 | sed 's/^trackeropen: [^:]*: //' | tr '\n' ';')
	screenshot -s $out/$nn.png > /dev/null 2>&1
	case "$f" in /boot/system/data/deskbar/*) where=Deskbar ;; *) where="Test Apps" ;; esac
	echo "TA1 $nn $where/$(basename "$f"): $result"
	teams | comm -13 /tmp/ta1-before - | grep -v ' /boot/system/servers/' > /tmp/ta1-new
	while read -r team path; do kill $team 2> /dev/null; done < /tmp/ta1-new
	wineserver -k > /dev/null 2>&1
	sleep 2
	while read -r team path; do kill -9 $team 2> /dev/null; done < /tmp/ta1-new
	sleep 3
done < $entries
echo "TA1 end $n"
