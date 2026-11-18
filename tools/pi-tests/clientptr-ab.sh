#!/bin/sh
# clientptr-ab.sh — run over ssh in a Pi session (scripts/pi-session.sh, scripts/pi-ssh.sh): one WoW64 OpenGL
# program under Wine with GL_MESA_map_buffer_client_pointer on or off (docs/design/gl-client-pointer.md), the
# same Mesa build either way (off: MESA_EXTENSION_OVERRIDE=-GL_MESA_map_buffer_client_pointer, so Wine takes its
# copying path, our patch 0028). Prints the mean of WINEDEBUG=+fps's "approx" rates after the first WARMUP
# seconds, and the number of client-pointer ranges Wine allocated (a short +opengl trace run, with "trace").
#
#   sh clientptr-ab.sh on|off|trace DIR SECS WARMUP EXE [ARGS...]
#
# DIR: the program's directory (Wine's working directory). Output lines start with "CPAB ". The program's own
# output: /tmp/cpab-<mode>.txt; a screenshot at the end: /boot/home/cpab-<mode>.png; with PROFILE=1 the run is
# profiled system-wide (profile -a -k -S, from WARMUP to 10 s before the end) into
# /boot/home/cpab-<mode>.prof.
mode=$1 dir=$2 secs=$3 warmup=$4
shift 4
export HOME=/boot/home
export PATH=/boot/system/non-packaged/bin:$PATH
export WINEDEBUG=${WINEDEBUG:-err+all,fixme-all,+fps}
export XKB_CONFIG_ROOT=${XKB_CONFIG_ROOT:-/boot/system/data/X11/xkb}
case $mode in
on) unset MESA_EXTENSION_OVERRIDE ;;
off) export MESA_EXTENSION_OVERRIDE=-GL_MESA_map_buffer_client_pointer ;;
trace) export WINEDEBUG=err+all,fixme-all,trace+opengl ;;
*) echo "usage: $0 on|off|trace DIR SECS WARMUP EXE [ARGS...]" >&2; exit 2 ;;
esac
out=/tmp/cpab-$mode.txt
cd "$dir" || exit 1
start=$(date +%s)
wine "$@" > $out 2>&1 &
pid=$!
if [ "${PROFILE:-0}" = 1 ]; then
	# the steady state only: from WARMUP to 10 s before the end
	sleep $warmup
	profile -a -k -S -i 1000 -o /boot/home/cpab-$mode.prof sleep $((secs - warmup - 10)) > /tmp/cpab-prof.txt 2>&1
	sleep 10
else
	sleep $secs
fi
screenshot -s /boot/home/cpab-$mode.png > /dev/null 2>&1
running=$(kill -0 $pid 2> /dev/null && echo running || echo exited)
wineserver -k
sleep 3
wait
echo "CPAB $mode: $* after $secs s: $running"
# fps lines: "...:trace:fps:wglSwapBuffers @ approx 12.90fps, total 7.07fps", one per second of play
grep -a 'fps:wglSwapBuffers' $out | sed -n 's/.*approx \([0-9.]*\)fps.*/\1/p' | awk -v skip=$warmup '
	NR > skip { s += $1; n++; if (min == "" || $1 < min) min = $1; if ($1 > max) max = $1 }
	END { if (n) printf "CPAB fps: mean %.2f over %d s (min %.2f, max %.2f; first %d s left out)\n", s / n, n, min, max, skip
		else print "CPAB fps: none" }'
echo "CPAB client-pointer ranges allocated: $(grep -a -c 'Allocated Wow64 client pointer range' $out)"
echo "CPAB wow64 copy maps: $(grep -a -c 'returning flush-explicit copy buffer\|Copying .* to wow64 buffer' $out)"
grep -a -i 'err:\|assert\|segment' $out | grep -a -v 'init_unix_codepage\|wayland\|winebth\|vulkan_init_once' | head -n 8 \
	| while read -r line; do echo "CPAB   $(echo "$line" | cut -c1-200)"; done
exit 0
