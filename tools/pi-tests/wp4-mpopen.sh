#!/bin/sh
# wp4-mpopen.sh N URL LABEL — MediaPlayer started on URL N times (4 s each, then killed): how often it enters the
# debugger while opening a URL (WP4: a double free in BUrl::UrlString() from MainWin::_AddPlaylistItem(), before any
# request reaches the server). LIB=DIR: DIR first in LIBRARY_PATH (a control libmedia.so). Lines "WP4 <label> ...".
n=${1:?usage: wp4-mpopen.sh N URL LABEL}
url=${2:?usage: wp4-mpopen.sh N URL LABEL}
label=${3:?usage: wp4-mpopen.sh N URL LABEL}
say() { echo "WP4 $label $*"; }
players() { ps | awk '$1 ~ /MediaPlayer$/ { print $(NF-3) }'; }
dbg() { grep -a -c "entered the debugger" /var/log/syslog; }
[ -n "${LIB:-}" ] && export LIBRARY_PATH="$LIB:%A/lib:/boot/home/config/non-packaged/lib:/boot/home/config/lib:/boot/system/non-packaged/lib:/boot/system/lib"
crashes=0
i=0
while [ $i -lt "$n" ]; do
	i=$((i + 1))
	for t in $(players); do kill -9 "$t"; done
	before=$(dbg)
	/boot/system/apps/MediaPlayer "$url" > /dev/null 2>&1 &
	sleep 4
	after=$(dbg)
	if [ "$after" -gt "$before" ]; then
		crashes=$((crashes + 1))
		say "open $i: entered the debugger"
	fi
	for t in $(players); do kill -9 "$t"; done
	sleep 1
done
say "$crashes of $n opens entered the debugger (LIB=${LIB:-system})"
