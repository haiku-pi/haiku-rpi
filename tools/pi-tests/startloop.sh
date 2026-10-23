#!/bin/sh
# startloop.sh N SECS DIR "EXE [ARGS]" [VAR=VALUE...] — on a Pi session with Wine and the test games
# (scripts/pi-ssh.sh): start a game N times, each for SECS, in wine-games.sh's prefix; per start
# "START <i> alive|exited <screenshot bytes> windows=<n>" (Haiku's screenshot of the whole screen, and the
# number of window threads, "w>...", on the system): a start that shows only the desktop has a small
# screenshot and one window fewer. For intermittent start hangs (a game that never opens its window).
n=$1 secs=$2 dir=$3 exe=$4; shift 4
export WINEPREFIX=/boot/home/wineprefix WINEDEBUG=${WINEDEBUG:-err+all,fixme-all}
export WINE_D3D_CONFIG=${WINE_D3D_CONFIG:-renderer=gl}
cd /boot/system/non-packaged/data/wine-games/$dir || exit 1
i=1
while [ $i -le $n ]; do
	env "$@" wine $exe > /tmp/startloop-$i.txt 2>&1 &
	pid=$!
	t=0
	while [ $t -lt $secs ] && kill -0 $pid 2>/dev/null; do sleep 5; t=$((t + 5)); done
	alive=$(kill -0 $pid 2>/dev/null && echo alive || echo exited)
	screenshot -s /boot/home/startloop-$i.png > /dev/null 2>&1
	windows=$(ps -a 2>/dev/null | grep -c '^w>')
	echo "START $i $alive $(ls -l /boot/home/startloop-$i.png | awk '{print $5}') windows=$windows"
	wineserver -k; sleep 3; kill -9 $pid 2>/dev/null
	i=$((i + 1))
done
echo "START end"
