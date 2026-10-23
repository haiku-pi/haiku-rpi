#!/bin/sh
# sc3loop.sh N SECS [VAR=VALUE...] — on a Pi session with Wine and the test games (scripts/pi-ssh.sh): start
# SimCity 3000's demo N times for SECS each on wined3d's OpenGL renderer, the variables in its environment
# (e.g. BOX64_DYNAREC_STRONGMEM=1, WINEDLLOVERRIDES=wined3d=n for a test DLL in syswow64). Per run:
# "SC3 <i> ok|BAD alive|exited <first matching line>" (command-stream corruption, crash, unhandled exception).
# W3 (KNOWN-ISSUES): 6 of 8 BAD before Wine 0018, 0 of 8 after.
n=$1 secs=$2; shift 2
. /boot/home/wenv.sh 2>/dev/null
cd /boot/system/non-packaged/data/wine-games/SC3 || exit 1
i=1
while [ $i -le $n ]; do
	env WINE_D3D_CONFIG=renderer=gl "$@" wine sc3demo.exe > /tmp/sc3-$i.txt 2>&1 &
	pid=$!
	t=0
	while [ $t -lt $secs ] && kill -0 $pid 2>/dev/null; do sleep 5; t=$((t + 5)); done
	alive=$(kill -0 $pid 2>/dev/null && echo alive || echo exited)
	screenshot -s /boot/home/sc3-$i.png >/dev/null 2>&1
	bad=$(grep -a -m1 -E 'Invalid opcode|wined3d_cs.*(err|fixme:.*opcode)|page fault|nhandled exception|crash:|Assertion|SIGSEGV' /tmp/sc3-$i.txt)
	if [ -n "$bad" ]; then echo "SC3 $i BAD $alive $(echo "$bad" | cut -c1-160)"; else echo "SC3 $i ok $alive $(ls -l /boot/home/sc3-$i.png | awk '{print $5}')"; fi
	wineserver -k; sleep 3; kill -9 $pid 2>/dev/null
	i=$((i + 1))
done
echo "SC3 end"
