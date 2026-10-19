#!/bin/sh
# quake.sh — a UserBootscript for the first game on the port: QuakeSpasm (SDL2 + OpenGL on the V3D,
# cross-built: scripts/cross-port.sh, artifacts/games) runs the shareware timedemo in a window at two
# sizes; the "N frames M seconds X fps" result (from its console log, -condebug) goes to the serial
# console.
# Serial console lines: "QSP " markers, QuakeSpasm's own output unprefixed.
sleep 20
out=/dev/dprintf
dir=/boot/system/non-packaged/apps/QuakeSpasm
say() { echo "QSP $*" > $out; }
cd $dir || { say "no $dir"; exit 1; }
for size in ${QUAKE_SIZES:-"640 480"}; do
	set -- $size
	say "timedemo demo1 ${1}x$2"
	./quakespasm -basedir $dir -window -width $1 -height $2 -nosound -condebug +scr_showfps 1 +timedemo demo1 > $out 2>&1 &
	pid=$!
	# the timedemo prints its result ("N frames M seconds X fps") and stays at the console
	waited=0
	while [ $waited -lt 200 ] && kill -0 $pid 2> /dev/null; do
		sleep 5
		waited=$((waited + 5))
	done
	if kill -0 $pid 2> /dev/null; then
		say "${1}x$2 still running after $waited s"
		kill $pid
	else
		wait $pid
		say "${1}x$2 exited after $waited s (status $?)"
	fi
	# its stdout is block-buffered and lost with the kill: the console log has the result
	grep -a -E 'frames.*seconds.*fps' $dir/qconsole.log | while read -r line; do
		say "${1}x$2 result: $line"
	done
	tail -n 8 $dir/qconsole.log | while read -r line; do say "${1}x$2 console: $line"; done
	rm -f $dir/qconsole.log
	sleep 3
done
say end
