#!/bin/sh
# kill-race-loop.sh N [PROGRAM [ARGS...]] — N times: PROGRAM (default /boot/home/kill_race2: a thread that has a list
# node on its stack takes SIGTERM while others read the list; docs/design/firefox-contentproc-crash.md) started,
# killed with SIGTERM once it prints "KR ready"; a kill that makes a thread fault on the way down shows as a new
# "entered the debugger" line in the syslog. Lines "KRL i: ok|FAULT"; last "KRL end N kills, F faults".
n=${1:-50}
[ $# -gt 0 ] && shift
prog=${1:-/boot/home/kill_race2}
[ $# -gt 0 ] && shift
mkdir -p /boot/home/config/settings/system/debug_server
echo "default_action report" > /boot/home/config/settings/system/debug_server/settings
debugger() { c=$(grep -a -c "entered the debugger" /var/log/syslog 2> /dev/null); echo ${c:-0}; }
faults=0
i=1
while [ $i -le $n ]; do
	d1=$(debugger)
	"$prog" "$@" > /tmp/krl.txt 2>&1 &
	pid=$!
	t=0
	while [ $t -lt 50 ] && ! grep -q "KR ready" /tmp/krl.txt; do sleep 0.1; t=$((t + 1)); done
	sleep 0.5
	kill -TERM $pid
	sleep 2
	kill -9 $pid 2> /dev/null
	wait $pid 2> /dev/null
	d2=$(debugger)
	if [ "$d2" != "$d1" ]; then
		faults=$((faults + 1))
		echo "KRL $i: FAULT $(grep -a 'entered the debugger' /var/log/syslog | tail -n 1 | cut -c1-120)"
	else
		echo "KRL $i: ok"
	fi
	i=$((i + 1))
done
echo "KRL end $n kills, $faults faults"
