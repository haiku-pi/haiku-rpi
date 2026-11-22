#!/bin/sh
# wp2-browse.sh MODE ARG LABEL — a plain browsing smoke test of WebPositive (WP2: a new HaikuWebKit build must
# still render pages and take typing, not only play video). Window 1600x900 at 40,40, as wp1-video.sh.
#   site URL LABEL   WebPositive on URL; after WAIT s (default 25) the window title (the page's <title>), a SNAP
#                    line for the HDMI frame, then NEXT (default https://example.com/) typed into the URL field
#                    (it has the focus after a load) + return, the title WAIT2 s (12) later (SNAP next); quit
#   type TEXT LABEL  a local page with a focused text field (the top 300 px of the page, clicked first) that
#                    copies what is typed into the page title and a big line under the field; TEXT typed with
#                    uiinject (one key per character); the title then says "typed: TEXT" when the keys reached
#                    the page
# Lines "WP2 <label> ...". Afterwards the debugger entries in the syslog since the start.
# Run over ssh in a bench session (scripts/pi-session.sh, scripts/pi-ssh.sh), from the directory of the kit
# (uiinject next to it, tools/pi-tests/wp1-run.sh setup puts one there).
mode=${1:?usage: wp2-browse.sh MODE ARG LABEL}
arg=${2:?usage: wp2-browse.sh MODE ARG LABEL}
label=${3:?usage: wp2-browse.sh MODE ARG LABEL}
dir=$(cd "$(dirname "$0")" && pwd)
log=$dir/wp2-$label.log
say() { echo "WP2 $label $*"; }
wpteams() { ps | awk '$1 ~ /WebPositive$/ { print $(NF-3) }'; }
wtitle() { timeout 3 hey WebPositive get Title of Window "$1" 2>/dev/null | sed -n 's/^ *"result" (B_STRING_TYPE) : "\(.*\)"$/\1/p'; }
# the browser window's index (WebPositive also has Downloads, Settings and never-shown windows that do not answer)
wpwin() {
	i=0
	while [ $i -lt 8 ]; do
		case "$(wtitle $i)" in *" - WebPositive"|WebPositive) echo $i; return ;; esac
		i=$((i + 1))
	done
}
title() { w=$(wpwin); [ -n "$w" ] && wtitle "$w"; }
quit_wp() {
	timeout 10 hey WebPositive quit > /dev/null 2>&1 &
	i=0
	while [ -n "$(wpteams)" ] && [ $i -lt 15 ]; do sleep 1; i=$((i + 1)); done
	left=$(wpteams)
	for t in $left; do say "WebPositive $t did not quit: killed"; kill -9 "$t"; done
	[ -z "$left" ] && say "quit in $i s"
}
start_wp() {	# URL
	for t in $(wpteams); do kill -9 "$t"; done
	rm -f /boot/home/config/settings/WebPositive/Session
	/boot/system/apps/WebPositive "$1" > "$log" 2>&1 &
	team=$!
	sleep 3
	w=$(wpwin)
	[ -n "$w" ] && timeout 5 hey WebPositive set Frame of Window "$w" to "BRect(40,40,1639,939)" > /dev/null 2>&1
	say "started team $team: $1"
}

dbgStart=$(grep -a -c "entered the debugger" /var/log/syslog)
case "$mode" in
site)
	start_wp "$arg"
	sleep "${WAIT:-25}"
	say "title: $(title)"
	say "SNAP page"
	# the URL field has the keyboard focus (its text selected) after a page loads: a new address typed into it
	"$dir/uiinject" "$team" " - WebPositive" activate text "${NEXT:-https://example.com/}" key return \
		> /dev/null 2>&1
	sleep "${WAIT2:-12}"
	say "title after typing ${NEXT:-https://example.com/}: $(title)"
	say "SNAP next"
	sleep 2
	quit_wp
	;;
type)
	page=$dir/wp2-$label.html
	cat > "$page" << 'EOF'
<!DOCTYPE html><html><head><title>type here</title></head>
<body style="font:28px sans-serif;margin:0">
<input id="i" autofocus placeholder="type here" style="font:48px sans-serif;width:100%;height:300px;box-sizing:border-box">
<p id="o" style="font:48px serif;color:#036"></p>
<script>const i = document.getElementById("i"), o = document.getElementById("o");
i.focus();
i.addEventListener("input", () => { document.title = "typed: " + i.value; o.textContent = i.value; });</script>
</body></html>
EOF
	start_wp "file://$page"
	sleep 8
	say "title before: $(title)"
	"$dir/uiinject" "$team" " - WebPositive" activate click 1 800 250 wait 300 text "$arg" > /dev/null 2>&1
	sleep 3
	say "title after: $(title)"
	say "SNAP typed"
	sleep 2
	quit_wp
	;;
*) say "unknown mode $mode"; exit 2 ;;
esac
say "debugger entries: $(( $(grep -a -c "entered the debugger" /var/log/syslog) - dbgStart ))"
