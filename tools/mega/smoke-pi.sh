#!/bin/sh
# smoke-pi.sh [SECS [DIR]] — on a Pi running the mega image (scripts/mega-smoke.sh runs it over ssh): starts each
# entry of ~/Desktop/Test Apps (the launchers and the linked applications; made by first-boot.sh) in turn,
# waits SECS s (default 25), records whether it still runs, takes a screenshot (/boot/home/smoke/NN.png, NN its
# position; its output NN.log), then ends every team it started (a launcher may hand over to another program, and Wine starts
# several; system servers started on demand stay). One line per entry: "SMOKE NN <name>: running|exited N".
secs=${1:-25}
dir="${2:-/boot/home/Desktop/Test Apps}"
out=/boot/home/smoke
mkdir -p $out
screenshot -s $out/00.png > /dev/null 2>&1
# the teams now running: ID and path (ps: path args... team threads ...)
teams() { ps | awk 'NR > 1 { print $(NF - 3), $1 }' | sort; }
n=0
for f in "$dir"/*; do
	[ -x "$f" ] && [ ! -d "$f" ] || continue
	n=$((n + 1))
	nn=$(printf '%02d' $n)
	name=$(basename "$f")
	teams > /tmp/smoke-before
	# the link's target, as Tracker starts it (SuperTuxKart finds its data next to argv[0])
	"$(readlink -f "$f")" > $out/$nn.log 2>&1 < /dev/null &
	pid=$!
	sleep $secs
	if kill -0 $pid 2> /dev/null; then
		state=running
	else
		wait $pid
		state="exited $?"
	fi
	screenshot -s $out/$nn.png > /dev/null 2>&1
	echo "SMOKE $nn $name: $state"
	# (the list first: the stages of a pipeline are teams too, and must not be in it when it is used)
	teams | comm -13 /tmp/smoke-before - | grep -v ' /boot/system/servers/' > /tmp/smoke-new
	while read -r team path; do kill $team 2> /dev/null; done < /tmp/smoke-new
	wineserver -k > /dev/null 2>&1
	sleep 2
	while read -r team path; do kill -9 $team 2> /dev/null; done < /tmp/smoke-new
	sleep 3
done
echo "SMOKE end $n"
