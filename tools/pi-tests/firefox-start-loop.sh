#!/bin/sh
# firefox-start-loop.sh N [SECS [URL]] — Firefox started and ended N times the way the mega image's smoke test
# (tools/mega/smoke-pi.sh) does it, to catch the content-process crash of 11-03 (docs/design/firefox-contentproc-crash.md):
# /boot/system/apps/Firefox/Firefox (URL if given, else its home page) runs SECS s (default 25), then every team it
# started gets SIGTERM, 2 s later SIGKILL, 3 s pause. debug_server writes a report instead of its dialog
# (default_action report: ~/Desktop/*.report, kept); after a crash the loop waits for the report before it kills.
# Each start with a new profile, a first launch as in the smoke test (FSL_WARM=1: the profile is kept).
# Lines "FSL ..." on stdout; "FSL i: ok|CRASH ..." per start; last "FSL end N starts, C crashes, R reports".
n=${1:-25}
secs=${2:-25}
url=${3:-}
ff=/boot/system/apps/Firefox/Firefox
export HOME=/boot/home
mkdir -p /boot/home/config/settings/system/debug_server /boot/home/Desktop
# (debug_server reads it at each crash)
echo "default_action report" > /boot/home/config/settings/system/debug_server/settings
debugger() { c=$(grep -a -c "entered the debugger" /var/log/syslog 2> /dev/null); echo ${c:-0}; }
reports() { ls /boot/home/Desktop/*.report 2> /dev/null | wc -l; }
# the teams now running: ID and path; never the Debugger writing a report, nor a server
teams() { ps | awk 'NR > 1 { print $(NF - 3), $1 }' | grep -a -v -e ' /boot/system/servers/' -e '/Debugger$' | sort; }
debugger_running() { ps | awk '{ print $1 }' | grep -a -q '/Debugger$'; }
crashes=0
d0=$(debugger)
r0=$(reports)
echo "FSL start: $n starts of $secs s, url '${url:-home page}', syslog debugger entries $d0, reports $r0"
i=1
while [ $i -le $n ]; do
	teams > /tmp/fsl-before
	d1=$(debugger)
	# a first launch each time, as in the smoke test (FSL_WARM=1: the profile is kept)
	[ "${FSL_WARM:-0}" = 1 ] || rm -rf /boot/home/config/settings/Mozilla /boot/home/.mozilla /boot/home/config/cache/Mozilla
	"$ff" $url > /tmp/fsl-$i.txt 2>&1 < /dev/null &
	pid=$!
	sleep $secs
	teams | comm -13 /tmp/fsl-before - > /tmp/fsl-new
	nteams=$(wc -l < /tmp/fsl-new)
	[ $i != 1 ] || echo "FSL profile: $(ls -d /boot/home/config/settings/Mozilla/*/* /boot/home/.mozilla/*/* 2> /dev/null | tr '\n' ' ')"
	alive=yes
	kill -0 $pid 2> /dev/null || alive=no
	# a crash: let the Debugger write its report before the crashed team is killed (debug_server ends it after)
	wait_report() {
		[ "$(debugger)" != "$d1" ] || return 0
		sleep 3
		t=0
		while [ $t -lt 300 ] && debugger_running; do sleep 2; t=$((t + 2)); done
	}
	wait_report
	while read -r team path; do kill $team 2> /dev/null; done < /tmp/fsl-new
	sleep 2
	wait_report
	while read -r team path; do kill -9 $team 2> /dev/null; done < /tmp/fsl-new
	sleep 3
	d2=$(debugger)
	if [ "$d2" != "$d1" ]; then
		crashes=$((crashes + 1))
		echo "FSL $i: CRASH ($nteams teams, parent alive $alive): $(grep -a 'entered the debugger' /var/log/syslog | tail -n $((d2 - d1)) | cut -c1-160 | tr '\n' ' ')"
	else
		echo "FSL $i: ok ($nteams teams, parent alive $alive)"
	fi
	i=$((i + 1))
done
echo "FSL end $n starts, $crashes crashes, $(( $(reports) - r0 )) reports"
