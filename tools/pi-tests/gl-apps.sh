#!/bin/sh
# gl-apps.sh — a UserBootscript for the packaged GL stack (jam -sHAIKU_PI_GL=1): Haiku's own GL
# applications, built by jam against the mesa/glu packages, run on the V3D. GLTeapot (its frame rate
# drawn in the window) for 60 s, then GLInfo for 20 s; the HDMI frames of the cycle show them. Serial
# console lines: "GLA ".
sleep 20
out=/dev/dprintf
apps=/boot/system/non-packaged/apps
say() { echo "GLA $*" > $out; }
run() {	# APP SECONDS
	say "$1 start"
	$apps/$1 > $out 2>&1 &
	pid=$!
	sleep $2
	if kill -0 $pid 2> /dev/null; then
		say "$1 still running after $2 s ok"
		kill $pid
	else
		wait $pid
		say "$1 exited early (status $?) BAD"
	fi
}
run GLTeapot 60
run GLInfo 20
say end
