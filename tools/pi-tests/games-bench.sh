#!/bin/sh
# games-bench.sh — a UserBootscript: the games' frame rates, one fixed set, for before/after comparisons of
# the graphics stack (images: scripts/games-bench-image.sh). Each game runs bounded, in the same order:
#   QuakeSpasm   timedemo demo1 (969 frames), 640x480 / 1280x720 / 1920x1080 window, 3 runs each (uncapped:
#                a timedemo ignores host_maxfps; a played demo sits on its 72 fps cap). From id1/autoexec.cfg:
#                QuakeSpasm 0.96.3 never runs a +timedemo of its command line (the demo loop starts instead)
#   vkQuake      timedemo demo1, 1280x720 / 1920x1080 window (Vulkan)
#   Quake II     Yamagi, GL1 renderer: timedemo of the demo's q2demo1.dm2 (632 frames), 640x480 / 1280x720 /
#                1920x1080 window, 3 runs each
#   Quake III    the demo's q3dm1, bots, orbiting camera, 60 s, 1280x720 window: egl_haiku's frame rate
#                (its own demos cannot play on ioquake3)
#   OpenArena    timedemo demo088-test1 (3398 frames), 1280x720 window, then full screen 1920x1080
#   SuperTuxKart --profile-time=60 race on hacienda, 1280x720 window (the package): egl_haiku's rate (its
#                own "Average FPS" counts loop iterations, ~118 whatever it draws)
#   Wine         a prefix if there is none (with Wine Mono), then gltest (OpenGL) arm64 and x86, d3dtest
#                (Direct3D 9) x86 windowed and full screen, arm64 full screen; Half-Life Uplink (x86, its
#                software renderer in a window): the console's timerefresh (128 frames) 3 times on its
#                first map, typed by input.exe, best effort
# A timedemo's own result is the figure; egl_haiku's / the Vulkan WSI's "frames/s" (HAIKU_EGL_FPS,
# HAIKU_VK_FPS, every ~5 s) are a second measure (mean of the samples after the first).
# Serial console lines "GB ": one result line per run,
#   GB <game> <setting>: <fps> fps (<details>) | <temperature, throttling, clocks after the run>
# with "n/a" for a run that produced no figure, "GB thermal <when>: ..." lines, and "GB end". Repeated
# runs: the mean, then each run's figure. ~25 min on a network boot (cold shader cache, a new Wine prefix).
#
#   scripts/netboot-cycle.sh --image artifacts/images/gb-after.img --secs 2400 --label gb-after1 \
#       --until 'GB end' --retry-wedge
#   (or scripts/sd-cycle.sh --flash IMG ...; a second boot of the card then runs with warm caches)
#   scripts/games-bench-table.py --a before LOG... --b after LOG...   (the table)
# Interleave the boots (before, after, before, after: thermal drift cancels). Wine's gltest settles at a
# rate per boot (163-194 fps seen on one image), so compare it over several boots.
sleep 30
out=/dev/dprintf
np=/boot/system/non-packaged
export HOME=/boot/home
say() { echo "GB $*" > $out; }
# temperature, throttling (now / since boot) and the clocks the firmware runs
thermal() {
	tr -s ' \n' ' ' < /dev/power/bcm2835_thermal/0 | sed -e \
		's/.*Current Temperature: \([0-9.]*\) C.*Throttled: \([0-9a-fx]*\) (since boot: \([0-9a-fx]*\)).*ARM \([0-9]*\) MHz.*V3D \([0-9]*\) MHz.*/\1 C, throttled \2 (boot \3), ARM \4 MHz, V3D \5 MHz/'
}
# fps_of: the number before " fps" in the result line on stdin
fps_of() { sed -e 's/.* \([0-9.]*\) fps.*/\1/' | tail -n 1; }
# mean N...: the mean of the numbers given, "n/a" for none
mean() { echo "$@" | tr ' ' '\n' | awk '/^[0-9.]+$/ { s += $1; n++ } END { if (n) printf "%.1f", s / n; else printf "n/a" }'; }
# egl FILE: the mean of the "N frames/s" samples in FILE after the first (loading) one
egl() {
	grep -a 'frames/s' "$1" 2> /dev/null | sed -e 's/.*: \([0-9.]*\) frames\/s.*/\1/' \
		| awk 'NR > 1 { s += $1; n++ } END { if (n) printf "%.1f (%d samples)", s / n, n; else printf "n/a" }'
}
# bounded NAME SECS DONE_RE DONE_FILE COMMAND...: COMMAND in the background (output to /tmp/gb-NAME.txt)
# until it exits, SECS pass, or DONE_FILE has a line matching DONE_RE (a game that stays at its console after
# a timedemo; $done_count such lines, default 1); then killed. Sets $ran (seconds) and $status.
bounded() {
	name=$1 secs=$2 done_re=$3 done_file=$4
	shift 4
	"$@" > /tmp/gb-$name.txt 2>&1 &
	pid=$!
	ran=0
	while [ $ran -lt $secs ] && kill -0 $pid 2> /dev/null; do
		sleep 1
		ran=$((ran + 1))
		hits=0
		[ -n "$done_re" ] && hits=$(grep -a -c -E "$done_re" "$done_file" 2> /dev/null)
		if [ "${hits:-0}" -ge "${done_count:-1}" ]; then
			sleep 1
			break
		fi
	done
	if kill -0 $pid 2> /dev/null; then
		kill $pid
		sleep 2
		kill -9 $pid 2> /dev/null
		status=stopped
	else
		wait $pid
		status="exit $?"
	fi
}

mkdir -p /boot/home/config/settings/system/debug_server
echo "default_action log" > /boot/home/config/settings/system/debug_server/settings
say "image: $(uname -a | cut -c1-120)"
say "packages: $(ls /boot/system/packages | grep -E '^(haiku-|mesa-|wine-|wayland_server|supertuxkart-)' | tr '\n' ' ')"
say "shader cache: $(du -sk /boot/home/config/cache/mesa_shader_cache 2> /dev/null | cut -f1) kB before"
say "thermal start: $(thermal)"

# QuakeSpasm: the timedemo prints "N frames M seconds X fps" and stays at the console
dir=$np/apps/QuakeSpasm
for size in 640x480 1280x720 1920x1080; do
	cd $dir || break
	runs="" eglruns=""
	for n in 1 2 3; do
		rm -f qconsole.log
		echo "timedemo demo1" > id1/autoexec.cfg
		bounded qs-$size 120 'frames.*seconds.*fps' $dir/qconsole.log \
			env HAIKU_EGL_FPS=1 ./quakespasm -basedir $dir -window -width ${size%x*} -height ${size#*x} -nosound \
			-condebug
		r=$(grep -a -E 'frames.*seconds.*fps' qconsole.log | tail -n 1)
		runs="$runs $(echo "$r" | grep -q fps && echo "$r" | fps_of || echo n/a)"
		eglruns="$eglruns $(egl /tmp/gb-qs-$size.txt | cut -d' ' -f1)"
		sleep 2
	done
	rm -f id1/autoexec.cfg
	say "quakespasm $size: $(mean $runs) fps (runs$runs; last: $r; egl$eglruns) | $(thermal)"
	sleep 3
done

# vkQuake: the same timedemo on Vulkan
dir=$np/apps/vkQuake
for size in 1280x720 1920x1080; do
	cd $dir || break
	rm -f qconsole.log
	bounded vkq-$size 180 'frames.*seconds.*fps' $dir/qconsole.log \
		env HAIKU_VK_FPS=1 ./vkquake -basedir $dir -window -width ${size%x*} -height ${size#*x} -nosound \
		-condebug +timedemo demo1
	r=$(grep -a -E 'frames.*seconds.*fps' qconsole.log | tail -n 1)
	say "vkquake $size: $(echo "$r" | grep -q fps && echo "$r" | fps_of || echo n/a) fps ($r; wsi $(egl /tmp/gb-vkq-$size.txt); $status after $ran s) | $(thermal)"
	grep -a -i -E 'error|couldn' qconsole.log | head -n 3 | while read -r l; do say "  vkquake $size: $l"; done
	sleep 3
done

# Yamagi Quake II: "N frames, M seconds: X fps" when the demo ends, then nextdemo quits (stdout: flushed at exit)
dir=$np/apps/quake2
for size in 640x480 1280x720 1920x1080; do
	cd $dir || break
	runs=""
	for n in 1 2 3; do
		bounded q2-$size 120 '' '' env HAIKU_EGL_FPS=1 ./Quake2 +set vid_renderer gl1 +set vid_fullscreen 0 \
			+set r_mode -1 +set r_customwidth ${size%x*} +set r_customheight ${size#*x} +set s_initsound 0 \
			+set nextdemo quit +set timedemo 1 +demomap q2demo1.dm2
		r=$(grep -a -E '[0-9]+ frames, [0-9.]+ seconds: [0-9.]+ fps' /tmp/gb-q2-$size.txt | tail -n 1)
		runs="$runs $(echo "$r" | grep -q fps && echo "$r" | fps_of || echo n/a)"
		sleep 2
	done
	say "quake2 $size: $(mean $runs) fps (runs$runs; last: $(echo "$r" | sed -e 's/.*[^0-9]\([0-9][0-9]* frames,\)/\1/'); $status after $ran s) | $(thermal)"
	sleep 3
done

# Quake III demo: a bot match on q3dm1 watched by an orbiting camera, 60 s; egl_haiku's frame rate
dir=$np/apps/Quake3
if cd $dir; then
	bounded q3-1280x720 75 '' '' env HAIKU_EGL_FPS=1 ./Quake3 +set logfile 2 +set net_enabled 0 +set s_initsound 0 \
		+set com_hunkmegs 256 +set r_mode -1 +set r_customwidth 1280 +set r_customheight 720 +set r_fullscreen 0 \
		+set bot_enable 1 +set bot_minplayers 5 +set g_spSkill 3 +set g_doWarmup 0 +set cg_thirdPerson 1 \
		+set cg_thirdPersonRange 120 +set cg_cameraOrbit 1 +set cg_cameraOrbitDelay 1 +devmap q3dm1
	# the first samples are the map loading: the mean of those after the second
	e=$(grep -a 'frames/s' /tmp/gb-q3-1280x720.txt | sed -e 's/.*: \([0-9.]*\) frames\/s.*/\1/' \
		| awk 'NR > 2 { s += $1; n++ } END { if (n) printf "%.1f", s / n; else printf "n/a" }')
	say "quake3 1280x720: $e fps (egl, bots on q3dm1; samples $(grep -a 'frames/s' /tmp/gb-q3-1280x720.txt \
		| sed -e 's/.*: \([0-9.]*\) frames\/s.*/\1/' | tr '\n' ' '); $status after $ran s) | $(thermal)"
	sleep 3
fi

# OpenArena: its benchmark demo; "nextdemo quit" ends it
dir=$np/apps/OpenArena
log=/boot/home/config/settings/OpenArena/baseoa/qconsole.log
for run in "1280x720 window" "1920x1080 fullscreen"; do
	cd $dir || break
	set -- $run
	size=$1
	case $2 in
	window) display="+set r_mode -1 +set r_customwidth ${size%x*} +set r_customheight ${size#*x} +set r_fullscreen 0" ;;
	fullscreen) display="+set r_mode -2 +set r_fullscreen 1" ;;
	esac
	rm -f $log
	bounded oa-$size 300 '' '' env HAIKU_EGL_FPS=1 ./OpenArena +set logfile 2 +set net_enabled 0 +set s_initsound 0 \
		+set com_hunkmegs 256 $display +set nextdemo quit +set timedemo 1 +demo demo088-test1
	r=$(grep -a -E '^[0-9]+ frames [0-9.]+ seconds' $log | tail -n 1)
	say "openarena $size $2: $(echo "$r" | grep -q fps && echo "$r" | sed -e 's/.* \([0-9.]*\) fps.*/\1/' || echo n/a) fps ($r; egl $(egl /tmp/gb-oa-$size.txt); $status after $ran s) | $(thermal)"
	sleep 3
done

# SuperTuxKart (the package): "profile: Number of frames: N time T, Average FPS: X"
dir=/boot/system/apps/SuperTuxKart
if cd $dir; then
	bounded stk-1280x720 200 '' '' env HAIKU_EGL_FPS=1 ./SuperTuxKart --windowed --screensize=1280x720 \
		--disable-texture-compression --profile-time=60 --track=hacienda --numkarts=4 --kart=tux --difficulty=0
	r=$(grep -a 'Average FPS' /tmp/gb-stk-1280x720.txt | tail -n 1 | sed -e 's/.*profile: //')
	say "supertuxkart 1280x720: $(egl /tmp/gb-stk-1280x720.txt | cut -d' ' -f1) fps (egl $(egl /tmp/gb-stk-1280x720.txt); its profile: $r; $status after $ran s) | $(thermal)"
	sleep 3
fi

# Wine: the prefix (once; ~1-2 min with Wine Mono), then the test programs and Half-Life
export WINEDEBUG=err+all,fixme-all
export WINE_D3D_CONFIG=renderer=gl
if ! command -v wine > /dev/null; then
	say "wine: not installed (packages not activated?)"
else
	say "wine: $(wine --version 2>&1 | head -n 1)"
	if [ ! -f /boot/home/.wine/drive_c/windows/syswow64/kernel32.dll ]; then
		start=$(date +%s)
		wineboot -i > /tmp/gb-wineboot.txt 2>&1 < /dev/null
		bounded wineserver 900 '' '' wineserver -w
		say "wine prefix: $(( $(date +%s) - start )) s, syswow64 $(ls /boot/home/.wine/drive_c/windows/syswow64 2> /dev/null | wc -l) files ($status) | $(thermal)"
	fi
	tests=$np/data/wine-tests
	cd $tests
	for t in gltest-arm64 gltest-x86; do
		bounded $t 90 '' '' wine $t.exe 20
		r=$(tr -d '\r' < /tmp/gb-$t.txt | grep -a -E '^GLTEST [0-9]+ frames' | tail -n 1)
		say "wine $t 20s: $(echo "$r" | grep -q fps && echo "$r" | fps_of || echo n/a) fps ($r; $(tr -d '\r' < /tmp/gb-$t.txt | grep -a -E '^GLTEST (renderer|OK|FAIL)' | tr '\n' ' ')$status after $ran s) | $(thermal)"
		wineserver -k 2> /dev/null
		sleep 3
	done
	for run in "d3dtest-x86 window" "d3dtest-x86 fullscreen" "d3dtest-arm64 fullscreen"; do
		set -- $run
		bounded $1-$2 90 '' '' wine $1.exe 20 $2
		r=$(tr -d '\r' < /tmp/gb-$1-$2.txt | grep -a -E '^d3dtest: [0-9]+ frames' | tail -n 1)
		say "wine $1 $2: $(echo "$r" | grep -q fps && echo "$r" | fps_of || echo n/a) fps ($r; $(tr -d '\r' < /tmp/gb-$1-$2.txt | grep -a -E '^D3DTEST' | tr '\n' ' ')$status after $ran s) | $(thermal)"
		wineserver -k 2> /dev/null
		sleep 3
	done
	# Half-Life Uplink: straight into its first map (the command line's +map), then the console's timerefresh
	# (128 frames turning on the spot: "T seconds (X fps)" in valve/qconsole.log, -condebug) typed by input.exe
	hl=$np/data/wine-games/HL
	if cd $hl 2> /dev/null; then
		rm -f valve/qconsole.log
		wine $tests/input.exe "focus:Half-Life" "wait:90000" "key:0xc0" "wait:3000" "text:timerefresh" "key:0x0d" \
			"wait:8000" "text:timerefresh" "key:0x0d" "wait:8000" "text:timerefresh" "key:0x0d" "wait:30000" \
			> /tmp/gb-hl-input.txt 2>&1 &
		# done at the third result
		done_count=3 bounded halflife 260 'seconds \(.*fps\)' $hl/valve/qconsole.log wine hldemo.exe -windowed \
			-console -condebug +map hldemo1
		done_count=1
		runs=$(tr -d '\r' < valve/qconsole.log 2> /dev/null | grep -a -E 'seconds \(.*fps\)' \
			| sed -e 's/.*(\([0-9.]*\) fps).*/\1/' | tr '\n' ' ')
		say "wine halflife window: $(mean $runs) fps (timerefresh runs: $runs; $status after $ran s) | $(thermal)"
		tr -d '\r' < /tmp/gb-hl-input.txt | grep -a '^input:' | tail -n 3 | while read -r l; do say "  halflife $l"; done
		tr -d '\r' < valve/qconsole.log 2> /dev/null | grep -a -v '^$' | tail -n 4 | cut -c1-160 \
			| while read -r l; do say "  halflife console: $l"; done
		wineserver -k 2> /dev/null
	fi
fi

say "shader cache: $(du -sk /boot/home/config/cache/mesa_shader_cache 2> /dev/null | cut -f1) kB after"
grep -a "debug_server" /var/log/syslog 2> /dev/null | grep -a -i -E 'thread|team' | tail -n 5 \
	| while read -r l; do say "crash: $l"; done
sync
say "thermal end: $(thermal)"
say end
