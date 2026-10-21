#!/bin/sh
# wine-hello.sh — a UserBootscript for Wine on Haiku arm64 (the staged install: mkimage-pi4.sh --add-tree
# artifacts/wine/install/boot/system/non-packaged's parent): creates a prefix (wineboot) and runs the native
# arm64 Windows test program (tools/wine-tests/hello.c). Serial console lines: "WIN ".
sleep 15
out=/dev/dprintf
say() { echo "WIN $*" > $out; }
export PATH=/boot/system/non-packaged/bin:$PATH
export WINEPREFIX=/boot/home/wineprefix
export WINEDEBUG=err+all,fixme-all
date -s "@$(stat -c %Y /boot/home/config/settings/boot/UserBootscript)" > /dev/null 2>&1
# bounded SECS OUT CMD...: runs CMD with its output in OUT, killed after SECS (a crash waits in the debugger)
bounded() {
	secs=$1; outf=$2; shift 2
	"$@" > "$outf" 2>&1 &
	pid=$!
	waited=0
	while [ $waited -lt $secs ] && kill -0 $pid 2> /dev/null; do sleep 1; waited=$((waited + 1)); done
	if kill -0 $pid 2> /dev/null; then
		kill -9 $pid 2> /dev/null
		for t in $(ps | grep -a -E 'wine|wineserver' | grep -a -v grep | awk '{print $2}'); do kill -9 $t 2> /dev/null; done
		echo "(killed after $secs s)" >> "$outf"
		return 124
	fi
	wait $pid
}
bounded 60 /tmp/version.txt wine --version
say "wine --version: exit $?: $(head -n 5 /tmp/version.txt | tr '\n' ' ' | cut -c1-200)"
# where does startup stop? the server in the foreground with debug output, the client with the startup channels,
# and the threads' states while it hangs
WINEDEBUG= wineserver -f -d2 > /tmp/ws.txt 2>&1 &
sleep 2
( sleep 45; ps -a > /tmp/ps.txt 2>&1 ) &
WINEDEBUG=+process,+server,+module,+loaddll,+virtual,+seh,+thread bounded 90 /tmp/dbg.txt \
	wine /boot/system/non-packaged/data/wine-tests/hello-arm64.exe
say "debug run: exit $?"
tail -n 60 /tmp/dbg.txt | while read -r line; do say "  dbg: $(echo "$line" | cut -c1-200)"; done
tail -n 25 /tmp/ws.txt | while read -r line; do say "  srv: $(echo "$line" | cut -c1-200)"; done
grep -a -A12 -E 'wine|preloader' /tmp/ps.txt | head -n 50 | while read -r line; do say "  ps: $line"; done
for t in $(ps | grep -a -E 'wine' | grep -a -v grep | awk '{print $2}'); do kill -9 $t 2> /dev/null; done
sleep 2
start=$(date +%s)
bounded 200 /tmp/wineboot.txt wineboot -i
say "wineboot: exit $? in $(( $(date +%s) - start )) s"
tail -n 30 /tmp/wineboot.txt | while read -r line; do say "  boot: $line"; done
start=$(date +%s)
bounded 120 /tmp/hello.txt wine /boot/system/non-packaged/data/wine-tests/hello-arm64.exe
say "hello: exit $? in $(( $(date +%s) - start )) s"
cat /tmp/hello.txt | head -n 40 | while read -r line; do say "  $line"; done
say end
