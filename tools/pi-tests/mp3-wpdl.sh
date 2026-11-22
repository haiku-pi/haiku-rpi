#!/bin/sh
# mp3-wpdl.sh URL NAME LABEL — WebPositive downloads URL (a file served as application/octet-stream, e.g. by
# wp4-httpd.py from a directory of its own): started on URL, after WAIT s (default 15) the file NAME is looked for
# in the usual download folders (Desktop, Downloads) and its size and md5 printed; then WebPositive quits.
# Lines "MP3 <label> ...", and the debugger entries since the start (MP3: WebPositive on the BUrl change).
url=${1:?usage: mp3-wpdl.sh URL NAME LABEL}
name=${2:?usage: mp3-wpdl.sh URL NAME LABEL}
label=${3:?usage: mp3-wpdl.sh URL NAME LABEL}
say() { echo "MP3 $label $*"; }
wpteams() { ps | awk '$1 ~ /WebPositive$/ { print $(NF-3) }'; }
for t in $(wpteams); do kill -9 "$t"; done
for d in /boot/home/Desktop /boot/home/Downloads; do rm -f "$d/$name"; done
d0=$(grep -a -c "entered the debugger" /var/log/syslog)
/boot/system/apps/WebPositive "$url" > /dev/null 2>&1 &
sleep "${WAIT:-15}"
found=0
for d in /boot/home/Desktop /boot/home/Downloads; do
	if [ -f "$d/$name" ]; then
		found=1
		say "downloaded $d/$name: $(stat -c %s "$d/$name" 2>/dev/null || ls -l "$d/$name" | awk '{print $5}') bytes, md5 $(md5sum < "$d/$name" | cut -d' ' -f1)"
	fi
done
[ $found = 1 ] || say "FAIL: $name not found in Desktop or Downloads"
hey WebPositive quit > /dev/null 2>&1 &
sleep 3
for t in $(wpteams); do say "WebPositive $t did not quit: killed"; kill -9 "$t"; done
say "debugger entries: $(( $(grep -a -c "entered the debugger" /var/log/syslog) - d0 ))"
