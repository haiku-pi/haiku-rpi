#!/bin/sh
# wine-boot-debug.sh — a UserBootscript: where a new Wine prefix's setup (wineboot -i) stops. Runs wineboot with
# process, module and exception tracing into /boot/home/wineboot-debug.txt and reports every 60 s for up to
# 15 minutes: the files in system32 and syswow64, the Wine processes' threads (ps), the log's last lines.
# Then hello.exe as arm64 and as x86. Serial console lines: "WBD ".
sleep 15
out=/dev/dprintf
say() { echo "WBD $*" > $out; }
export PATH=/boot/system/non-packaged/bin:$PATH
export WINEPREFIX=/boot/home/wineprefix-debug
export XKB_CONFIG_ROOT=/boot/system/non-packaged/data/X11/xkb
log=/boot/home/wineboot-debug.txt
tests=/boot/system/non-packaged/data/wine-tests

say "wine: $(wine --version 2>&1)"
rm -rf $WINEPREFIX
# no Wine Mono / Gecko installer dialogs (Wine 11.20 asks; nobody is there to answer)
WINEDLLOVERRIDES="mscoree,mshtml=" WINEDEBUG=+process,+loaddll,+seh,err+all,fixme-all wineboot -i > $log 2>&1 &
pid=$!
n=0
while [ $n -lt 15 ]; do
	sleep 60
	n=$((n + 1))
	say "$n min: wineboot $(kill -0 $pid 2> /dev/null && echo running || echo done)," \
		"system32 $(ls $WINEPREFIX/drive_c/windows/system32 2> /dev/null | wc -l)," \
		"syswow64 $(ls $WINEPREFIX/drive_c/windows/syswow64 2> /dev/null | wc -l), log $(wc -l < $log) lines"
	ps -a 2> /dev/null | awk '/^\// { team = $1 ~ /wine|\.exe/ } team && NF && !/^Thread/' | head -n 30 \
		| while read -r line; do say "  ps: $line"; done
	tail -n 4 $log | cut -c1-200 | while read -r line; do say "  log: $line"; done
	kill -0 $pid 2> /dev/null || { ps 2> /dev/null | grep -q '[w]ineserver' || break; }
done
grep -a -E 'err:|Unhandled|exception|starting debugger' $log | head -n 20 | cut -c1-200 \
	| while read -r line; do say "  err: $line"; done
wineserver -k
sleep 2
for a in arm64 x86; do
	timeout 120 wine $tests/hello-$a.exe > /tmp/hello-$a.txt 2>&1
	say "hello-$a: exit $?: $(grep -a -v '^$' /tmp/hello-$a.txt | tail -n 3 | tr '\n' '|' | cut -c1-200)"
done
sync
say end
