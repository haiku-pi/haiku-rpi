#!/bin/sh
# wine-signals.sh [ROUNDS] — KNOWN-ISSUES W9: can the wineserver signal a busy Wine thread (Wine 0027)? Runs on a
# system with the wine packages (the mega image) as a UserBootscript (QEMU, a Pi boot) or over ssh
# (scripts/pi-ssh.sh 'sh /boot/home/wine-signals.sh 2000'). Needs in /boot/home: cancelio-{arm64,x64,x86}.exe and
# threadsig-{arm64,x64,x86}.exe (tools/wine-tests; the install step of scripts/build-wine.sh builds them).
#   1. a prefix (wineboot -i, without Wine Mono and Gecko) unless there is one;
#   2. a wineserver with -d1 for a 20-round cancelio: the Unix thread IDs the threads report (unix_tid, -1 before
#      0027) and the signals the server sent ("*sent signal*");
#   3. cancelio ROUNDS (default 2000) rounds, io / ex / both (arm64), and ROUNDS/10 both for x86-64 (FEX) and x86
#      (Box64): with signals every read ends "aborted", without them "other";
#   4. threadsig (arm64, x86-64, x86): SuspendThread/GetThreadContext/ResumeThread/GetThreadTimes/TerminateThread
#      of a spinning thread.
# Lines "WSIG ..." on stdout and the serial console; ends "WSIG end".
rounds=${1:-2000}
say() { echo "WSIG $*"; echo "WSIG $*" > /dev/dprintf 2> /dev/null; }
export WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml="
cd /boot/home
# bounded SECS OUT CMD...: CMD with its output in OUT, killed (with all of Wine) after SECS
bounded() {
	secs=$1; outf=$2; shift 2
	"$@" > "$outf" 2>&1 < /dev/null &
	pid=$!
	waited=0
	while [ $waited -lt $secs ] && kill -0 $pid 2> /dev/null; do sleep 1; waited=$((waited + 1)); done
	if kill -0 $pid 2> /dev/null; then
		kill -9 $pid 2> /dev/null
		wineserver -k > /dev/null 2>&1
		echo "(killed after $secs s)" >> "$outf"
		return 124
	fi
	wait $pid
}
say "begin: $(ls /boot/system/packages | grep '^wine-' | tr '\n' ' ')"
if [ ! -f /boot/home/.wine/system.reg ]; then
	start=$(date +%s)
	bounded 2400 /tmp/wsig-wineboot.txt wineboot -i
	say "wineboot: exit $? after $(( $(date +%s) - start )) s"
	bounded 600 /tmp/wsig-wait.txt wineserver -w
	say "wineserver -w: exit $?"
fi

wineserver -k > /dev/null 2>&1
sleep 2
wineserver -f -d1 2> /tmp/wsig-server.txt &
server=$!
sleep 2
bounded 300 /tmp/wsig-traced.txt wine cancelio-arm64.exe 20 io
say "traced: exit $?: $(grep -a '^CANCELIO' /tmp/wsig-traced.txt | tr '\n' ' ')"
wineserver -k > /dev/null 2>&1
sleep 3
kill $server 2> /dev/null
say "traced: unix_tid=-1 in $(grep -a -c 'unix_tid=-1' /tmp/wsig-server.txt) requests, other unix_tid in" \
	"$(grep -a 'unix_tid=' /tmp/wsig-server.txt | grep -a -v -c 'unix_tid=-1'); signals sent:" \
	"$(grep -a -c '\*sent signal\*' /tmp/wsig-server.txt) ($(grep -a -o '\*sent signal\* [A-Z0-9]*' /tmp/wsig-server.txt \
	| sort | uniq -c | tr '\n' ' '))"

for mode in io ex both; do
	start=$(date +%s)
	bounded 1800 /tmp/wsig-cancelio-$mode.txt wine cancelio-arm64.exe "$rounds" $mode
	say "cancelio arm64 $mode: exit $? in $(( $(date +%s) - start )) s: $(grep -a '^CANCELIO' /tmp/wsig-cancelio-$mode.txt \
		| tr '\n' ' ' | cut -c1-200)"
done
for arch in x64 x86; do
	start=$(date +%s)
	bounded 1800 /tmp/wsig-cancelio-$arch.txt wine cancelio-$arch.exe $((rounds / 10)) both
	say "cancelio $arch both: exit $? in $(( $(date +%s) - start )) s: $(grep -a '^CANCELIO' /tmp/wsig-cancelio-$arch.txt \
		| tr '\n' ' ' | cut -c1-200)"
done
for arch in arm64 x64 x86; do
	bounded 300 /tmp/wsig-threadsig-$arch.txt wine threadsig-$arch.exe
	rc=$?
	grep -a '^THREADSIG' /tmp/wsig-threadsig-$arch.txt | while read -r line; do say "threadsig $arch: ${line#THREADSIG }"; done
	say "threadsig $arch: exit $rc"
done
bounded 300 /tmp/wsig-wait2.txt wineserver -w
say "wineserver -w: exit $?"
say end
