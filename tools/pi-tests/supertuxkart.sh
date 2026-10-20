#!/bin/sh
# supertuxkart.sh — a UserBootscript for SuperTuxKart 1.5 (SDL2 + desktop OpenGL; scripts/build-stk.sh):
# runs of the game in a 1280x720 window, each bounded to secs seconds, frame rates on the serial console.
#
#   scripts/mkimage-pi4.sh --in sources/haiku/generated.arm64/haiku-mmc.image \
#       --add-tree artifacts/gl-stack/non-packaged --add-tree artifacts/stk/non-packaged \
#       --bootscript tools/pi-tests/supertuxkart.sh --out artifacts/images/haiku-pi4-stk.img
#
# Runs, in this order (change runs, secs and args below; a boot script gets no environment):
#   race       --profile-time=60 on hacienda with 4 karts: every kart, the player's too, AI-driven for
#              60 s of race time, then STK exits. Its "Number of frames: N time T, Average FPS: F" line
#              counts physics TICKS, not frames (several per frame on a slow GPU): printed, not a frame rate
#   benchmark  STK's own benchmark (--benchmark): the black_forest replay (ghost karts) as a time
#              trial, then STK exits. Its profiler times every frame and logs "Profiler: Frame count
#              'N', Time (ms) 'T', Steady FPS 'a', Mostly stable FPS 'b', Typical FPS 'c'" (real frames)
# Wall time: 20 s + up to 2 x (secs + ~10 s) = ~21 min; capture at least 1300 s.
# Frame rates two ways: STK's line above, and egl_haiku's presented "frames/s" every 5 s (HAIKU_EGL_FPS).
# The first run of a boot also creates STK's settings in ~/config/settings/SuperTuxKart/config-0.10/.
# Texture compression is off (--disable-texture-compression): libsquish would compress every kart and
# track texture on the CPU at load (minutes each on the other Pi 4 port). Sound is on (MojoAL on SDL2's
# Haiku audio); add --no-sound to args to rule it out. The network is left alone: STK only goes online
# when its settings allow it, and a first start has not been asked.
#
# Serial console lines: "STK " markers only (stdout goes to /tmp/stk-<run>.txt). A good run:
# "STK start <run> ...", "STK <run> exited after N s (status 0)", "STK log <run>: ... OpenGL version
# string: 2.1 Mesa ..." and "GL_RENDERER ... V3D 4.2" lines, "STK result <run>: ..." (the Profiler
# line, or the profile line for race), "STK egl <run>: ... frames/s" lines; no "[fatal]"/"[error]"
# lines beyond expected noise; no "STK <run> crashed" line, and no "DEBUGGER: abort() called" /
# "debug_server:" lines from the kernel on the serial console. A non-zero status AFTER the result line
# is still a result (the other Pi 4 port's STK faulted while printing the per-kart table that follows
# the frame line). Expected noise: "Material: Missing container id for ..." (texture compression is
# off) and "kartDirt shader is missing". HDMI: the window shows the track (legacy renderer: textures,
# no dynamic lighting or shadows).
sleep 20
out=/dev/dprintf
dir=/boot/system/non-packaged/apps/SuperTuxKart
secs=600
runs="race benchmark"
args=""
say() { echo "STK $*" > $out; }
cd $dir || { say "no $dir"; exit 1; }
export HOME=/boot/home
for run in $runs; do
	case $run in
	benchmark) what="--benchmark" ;;
	race) what="--profile-time=60 --track=hacienda --numkarts=4 --kart=tux --difficulty=0" ;;
	*) say "unknown run $run"; continue ;;
	esac
	say "start $run 1280x720 window, $secs s: $what ${args:-}"
	HAIKU_EGL_FPS=1 ./SuperTuxKart --windowed --screensize=1280x720 --disable-texture-compression \
		--unlock-all $what $args > /tmp/stk-$run.txt 2>&1 &
	pid=$!
	waited=0
	while [ $waited -lt $secs ] && kill -0 $pid 2> /dev/null; do
		sleep 5
		waited=$((waited + 5))
		# a crash leaves the team held by debug_server: stop waiting for it
		if grep -a -q -E 'terminate called|^Abort|Segmentation' /tmp/stk-$run.txt; then
			say "$run crashed after $waited s"
			break
		fi
	done
	if kill -0 $pid 2> /dev/null; then
		say "$run still running after $waited s"
		kill $pid
		sleep 2
		kill -9 $pid 2> /dev/null
	else
		wait $pid
		say "$run exited after $waited s (status $?)"
	fi
	grep -a -E "Frame count '|Number of frames:" /tmp/stk-$run.txt | while read -r line; do
		say "result $run: $line"
	done
	grep -a 'frames/s' /tmp/stk-$run.txt | head -n 60 | while read -r line; do say "egl $run: $line"; done
	grep -a -v 'frames/s' /tmp/stk-$run.txt \
		| grep -a -i -E 'OpenGL|GL_|renderer|IrrDriver|SDL|MojoAL|OpenAL|audio|sfx|fatal|error|warn|abort|segment' \
		| head -n 40 | cut -c1-200 | while read -r line; do say "log $run: $line"; done
	grep -a -v 'frames/s' /tmp/stk-$run.txt | tail -n 8 | cut -c1-200 | while read -r line; do
		say "tail $run: $line"
	done
	sleep 3
done
say end
