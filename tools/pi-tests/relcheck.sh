#!/bin/sh
# relcheck.sh — a release candidate's checks on a Pi session (scripts/release-check.sh copies the test
# programs to /boot/home and runs this over ssh): poll(), TLS of a reloaded library, host name lookups,
# Python's asyncio, EGL terminate, the PMU counters, GLTeapot and Firefox start times, then LAUNCHES
# launch cycles of four applications (each must show its window and quit; no debugger entry).
# Lines "REL ..."; the last one "REL result: N problems".
cd /boot/home || exit 1
say() { echo "REL $*"; }
problems=0
bad() { say "PROBLEM: $*"; problems=$((problems + 1)); }
debugger() { n=$(grep -c "entered the debugger" /var/log/syslog 2> /dev/null); echo ${n:-0}; }
dbg0=$(debugger)

./polltest > /tmp/rel.txt 2>&1 || bad "polltest: $(grep FAIL /tmp/rel.txt | head -n 3 | tr '\n' ' ')"
say "polltest: $(grep -c 'POLLTEST ok' /tmp/rel.txt) ok"
r=$(./tlsreload ./libtlsr.so 2>&1); say "$r"
echo "$r" | grep -q PASS || bad tlsreload
./resolvetime "$(hostname)" localhost nosuchhost.example 2>&1 | while read -r line; do say "$line"; done
if command -v python3 > /dev/null; then
	r=$(python3 -c 'import asyncio
async def f():
	await asyncio.sleep(0.05)
	return "asyncio ok"
print(asyncio.run(f()))' 2>&1)
	say "python3: $r"
	[ "$r" = "asyncio ok" ] || bad "python3 asyncio"
fi
r=$(./eglterm 2>&1 | tail -n 1); say "eglterm: $r"
[ "$r" = "EGLTERM ok" ] || bad eglterm
r=$(pmustat -a 1 2>&1 | grep -m 1 ' cycles' | sed 's/^ *//'); say "pmustat: $r"
[ -n "$r" ] || bad pmustat
say "audio: $(ls /dev/audio/hmulti 2> /dev/null | tr '\n' ' ')"

launch() {	# LABEL APP: window and quit times
	./launchtime -q "$2" 60 > /tmp/rel-lt.txt 2>&1 < /dev/null
	w=$(grep -o 'window after [0-9]*' /tmp/rel-lt.txt | grep -o '[0-9]*$')
	g=$(grep -o 'gone after [0-9]*' /tmp/rel-lt.txt | grep -o '[0-9]*$')
	say "$1: window ${w:-none} ms, quit ${g:-none} ms"
	[ -n "$w" ] && [ -n "$g" ] || bad "$1 $(tail -n 2 /tmp/rel-lt.txt | tr '\n' ' ')"
	sleep 2
}
launch GLTeapot-1 /boot/system/demos/GLTeapot
launch GLTeapot-2 /boot/system/demos/GLTeapot
for i in 1 2 3; do launch Firefox-$i /boot/system/apps/Firefox/Firefox; done

n=${LAUNCHES:-24}
fail0=$problems
i=0
while [ $i -lt $n ]; do
	case $((i % 4)) in
	0) app=/boot/system/apps/Terminal ;;
	1) app=/boot/system/apps/StyledEdit ;;
	2) app=/boot/system/demos/GLTeapot ;;
	3) app=/boot/system/apps/ShowImage ;;
	esac
	./launchtime -q $app 30 > /tmp/rel-lt.txt 2>&1 < /dev/null
	grep -q 'window after' /tmp/rel-lt.txt && grep -q 'gone after' /tmp/rel-lt.txt \
		|| bad "cycle $i $(basename $app): $(tail -n 1 /tmp/rel-lt.txt)"
	i=$((i + 1))
done
say "launch cycles: $n, problems $((problems - fail0))"
d=$(( $(debugger) - dbg0 ))
say "debugger entries: $d"
[ $d = 0 ] || bad "$d debugger entries"
say "result: $problems problems"
