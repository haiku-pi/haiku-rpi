#!/bin/sh
# firefox-quit-loop.sh N [URL [MAXWAIT [SETTLE]]] — Firefox started with a page and quit normally N times, as
# tools/pi-tests/startcost-steps.sh does it (docs/design/firefox-quit-crash.md): `Firefox --new-window URL` (default
# https://www.haiku-os.org/), wait until the window title names the page (`hey`; at most MAXWAIT s, default 90),
# SETTLE s more (default 3; startcost-steps.sh quits 45 s after the start), then `hey Firefox quit` (B_QUIT_REQUESTED) and wait for the process to end (at most 60 s; then SIGKILL
# to every team it started). The exit status of the parent is recorded (0 or the signal that ended it).
# debug_server writes reports (default_action report: ~/Desktop/*.report). Each start with a new profile
# (FQL_WARM=1: the profile is kept). As startcost-steps.sh around its quit: FQL_TERMINAL=1 opens Terminal for 5 s
# and quits it before each start; FQL_MEASURE=1 runs ./forkbench 100 (in /boot/home), ps and listarea just before
# the quit.
# Lines "FQL i: exit <status> ..." per start; last "FQL end N quits: C clean, S signalled (list), D debugger entries".
n=${1:-40}
url=${2:-https://www.haiku-os.org/}
maxwait=${3:-90}
settle=${4:-3}
ff=/boot/system/apps/Firefox/Firefox
export HOME=/boot/home
mkdir -p /boot/home/config/settings/system/debug_server /boot/home/Desktop
echo "default_action report" > /boot/home/config/settings/system/debug_server/settings
debugger() { c=$(grep -a -c "entered the debugger" /var/log/syslog 2> /dev/null); echo ${c:-0}; }
reports() { ls /boot/home/Desktop/*.report 2> /dev/null | wc -l; }
teams() { ps | awk 'NR > 1 { print $(NF - 3), $1 }' | grep -a -v -e ' /boot/system/servers/' -e '/Debugger$' | sort; }
ffteams() { ps | grep -a -c '^[/]boot/system/apps/Firefox/Firefox'; }
clean=0
sigd=0
siglist=""
d0=$(debugger)
r0=$(reports)
echo "FQL start: $n quits, url $url, settle $settle s, syslog debugger entries $d0, reports $r0"
i=1
while [ $i -le $n ]; do
	teams > /tmp/fql-before
	d1=$(debugger)
	[ "${FQL_WARM:-0}" = 1 ] || rm -rf /boot/home/config/settings/Mozilla /boot/home/.mozilla /boot/home/config/cache/Mozilla
	if [ "${FQL_TERMINAL:-0}" = 1 ]; then
		/boot/system/apps/Terminal > /dev/null 2>&1 &
		sleep 5
		hey Terminal quit > /dev/null 2>&1
	fi
	"$ff" --new-window "$url" > /tmp/fql-$i.txt 2>&1 < /dev/null &
	pid=$!
	t=0
	title=""
	while [ $t -lt $maxwait ]; do
		title=$(hey Firefox get Title of Window 0 2> /dev/null | grep -a '"result"' | sed 's/^[^:]*: //')
		case "$title" in *Haiku*) break ;; esac
		sleep 1
		t=$((t + 1))
	done
	sleep $settle
	teams | comm -13 /tmp/fql-before - > /tmp/fql-new
	nteams=$(wc -l < /tmp/fql-new)
	if [ "${FQL_MEASURE:-0}" = 1 ]; then
		(cd /boot/home && ./forkbench 100 > /dev/null 2>&1)
		ps | wc -l > /dev/null
		listarea 2> /dev/null | wc -l > /dev/null
	fi
	hey Firefox quit > /dev/null 2>&1
	q=0
	while [ $q -lt 60 ] && kill -0 $pid 2> /dev/null; do sleep 1; q=$((q + 1)); done
	killed=""
	if kill -0 $pid 2> /dev/null; then
		killed=" (still running after 60 s: SIGKILL)"
		while read -r team path; do kill -9 $team 2> /dev/null; done < /tmp/fql-new
	fi
	wait $pid
	rc=$?
	# content processes still running 15 s after the parent ended
	w=0
	while [ $w -lt 15 ] && [ "$(ffteams)" -gt 0 ]; do sleep 1; w=$((w + 1)); done
	left=$(ffteams)
	while read -r team path; do kill -9 $team 2> /dev/null; done < /tmp/fql-new
	sleep 1
	d2=$(debugger)
	if [ $rc = 0 ]; then
		st=0
		clean=$((clean + 1))
	elif [ $rc -gt 128 ]; then
		st="SIG$(kill -l $((rc - 128)) 2> /dev/null)($((rc - 128)))"
		sigd=$((sigd + 1))
		siglist="$siglist $i:$st"
	else
		st="rc $rc"
		sigd=$((sigd + 1))
		siglist="$siglist $i:$st"
	fi
	extra=""
	[ "$d2" = "$d1" ] || extra=" DEBUGGER: $(grep -a 'entered the debugger' /var/log/syslog | tail -n $((d2 - d1)) | cut -c1-160 | tr '\n' ' ')"
	echo "FQL $i: exit $st after quit ${q}s, page ${t}s title $title, $nteams teams, $left Firefox teams left after ${w}s$killed$extra"
	i=$((i + 1))
done
echo "FQL end $n quits: $clean clean, $sigd signalled ($siglist), $(( $(debugger) - d0 )) debugger entries, $(( $(reports) - r0 )) reports"
