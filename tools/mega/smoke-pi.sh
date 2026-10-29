#!/bin/sh
# smoke-pi.sh [SECS] — on a Pi running the mega image (scripts/mega-smoke.sh runs it over ssh): starts each
# Test Apps launcher (/boot/system/non-packaged/apps/TestApps) in turn, waits SECS s (default 25), records whether
# it still runs, takes a screenshot (/boot/home/smoke/NN.png, NN its position), then ends it (Wine programs
# with their wineserver). One line per launcher: "SMOKE NN <name>: running|exited N".
secs=${1:-25}
dir=/boot/system/non-packaged/apps/TestApps
out=/boot/home/smoke
mkdir -p $out
screenshot -s $out/00.png > /dev/null 2>&1
n=0
for f in "$dir"/*; do
	[ -x "$f" ] || continue
	n=$((n + 1))
	nn=$(printf '%02d' $n)
	name=$(basename "$f")
	"$f" > /dev/null 2>&1 < /dev/null &
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
	kill $pid 2> /dev/null
	sleep 2
	kill -9 $pid 2> /dev/null
	wineserver -k > /dev/null 2>&1
	sleep 3
done
echo "SMOKE end $n"
