#!/bin/sh
# wine-apps.sh [NAME...] — on a Pi session with Wine (scripts/pi-ssh.sh): everyday Windows programs, unpacked in
# /boot/home/apps (downloaded for the test only, never published): each GUI program runs SECS seconds, then its
# windows ("w>" threads new since the start), a screenshot (/boot/home/apps-<name>.png), Wine's crash lines and new
# debug_server entries are reported, and the wineserver is ended. 7-Zip's console program packs and tests an archive;
# Notepad++ gets typed text (needs /boot/home/keyinject).
# Lines: "APP <name> ...".
cd /boot/home/apps || exit 1
export WINEDEBUG=${WINEDEBUG:-err+all,fixme-all}
secs=${SECS:-45}
windows() { ps -a | grep '^w>' | sed 's/ *[0-9]* *[a-z]* .*//' | sort; }
gui() {	# NAME DIR "EXE [ARGS]"
	name=$1 dir=$2 exe=$3
	[ $# -gt 0 ] && [ -n "$only" ] && ! echo " $only " | grep -q " $name " && return
	windows > /tmp/apps-before.txt
	n0=$(grep -c "entered the debugger" /var/log/syslog)
	start=$(date +%s)
	(cd "$dir" && exec wine $exe > /tmp/apps-$name.txt 2>&1) &
	sleep $secs
	alive=$(ps | grep -c "[w]ine .*$(echo "$exe" | sed 's/ .*//; s/.*\///')")
	windows > /tmp/apps-after.txt
	new=$(comm -13 /tmp/apps-before.txt /tmp/apps-after.txt | tr '\n' ';')
	screenshot -s /boot/home/apps-$name.png > /dev/null 2>&1
	echo "APP $name: processes $alive, new windows: ${new:-none}, crash lines $(grep -c '^crash:' /tmp/apps-$name.txt)," \
		"debugger entries $(( $(grep -c "entered the debugger" /var/log/syslog) - n0 )), screenshot $(ls -l /boot/home/apps-$name.png 2> /dev/null | awk '{print $5}')"
	grep -a -m 5 "^crash:\|err:" /tmp/apps-$name.txt | grep -v "err:environ\|waylanddrv\|err:cursor" | sed "s/^/APP $name:   /" | cut -c1-200
	wineserver -k; sleep 3
}
only="$*"
gui putty32 putty "putty32.exe"
gui putty64 putty "putty64.exe"
gui npp32 npp32 "notepad++.exe"
gui npp64 npp64 "notepad++.exe"
gui sumatra32 sumatra "Sumatra32.exe test.pdf"
gui sumatra64 sumatra "Sumatra64.exe test.pdf"
if [ -z "$only" ] || echo " $only " | grep -q " 7z "; then
	# paths relative to the current directory: a Unix path is a path on the current Windows drive
	rm -f t.7z
	s=$(date +%s)
	wine 7z/7zr.exe a t.7z sumatra/test.pdf npp64/change.log > /tmp/apps-7z.txt 2>&1
	wine 7z/7zr.exe t t.7z >> /tmp/apps-7z.txt 2>&1
	echo "APP 7z: $(tr -d '\r' < /tmp/apps-7z.txt | grep -a -c 'Everything is Ok') of 2 Ok, $(($(date +%s) - s)) s, archive $(ls -l t.7z 2> /dev/null | awk '{print $5}') bytes"
	rm -f t.7z
	wineserver -k
fi
# typing: Notepad++ (x86-64) gets a line through Haiku's key path (/boot/home/keyinject, tools/haiku-tests:
# B_KEY_DOWN/UP and Shift as input_server sends them); the screenshot shows the line. (Wine-side SendInput,
# tools/wine-tests/input.c, loses Shift for typed capitals: winewayland's text comes from the Wayland keys.)
if [ -z "$only" ] || echo " $only " | grep -q " npp-type "; then
	(cd npp64 && exec wine notepad++.exe > /tmp/apps-npp-type.txt 2>&1) &
	sleep $secs
	for t in $(ps | grep wine | grep -v grep | awk '{print $(NF-3)}'); do
		/boot/home/keyinject $t "new 1" "Typed ON Haiku, Shift test 123!" 2> /dev/null && break
	done | sed 's/^/APP npp-type: /'
	sleep 3
	screenshot -s /boot/home/apps-npp-type.png > /dev/null 2>&1
	echo "APP npp-type: screenshot $(ls -l /boot/home/apps-npp-type.png 2> /dev/null | awk '{print $5}')"
	wineserver -k
fi
echo "APP end"
