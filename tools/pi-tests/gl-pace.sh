#!/bin/sh
# gl-pace.sh — a GL program's frame rate and CPU use (its own and app_server's) while it runs in a window, for
# H20 item N3 (windowed presents paced to the display, docs/design/perf-round-h20.md). Run over ssh on a Pi
# session (scripts/pi-session.sh, scripts/pi-ssh.sh):
#
#   gl-pace.sh LABEL WARMUP SECS COMMAND [ARGS...]
#
# Starts COMMAND in its directory with HAIKU_EGL_FPS=1 (the environment otherwise as given: e.g.
# HAIKU_EGL_SWAP_INTERVAL, __EGL_VENDOR_LIBRARY_FILENAMES, LIBRARY_PATH), its output in /tmp/gl-pace-LABEL.txt;
# after WARMUP s measures SECS s: the CPU time of COMMAND's team and of app_server (`ps -a`: user + kernel time
# of all their threads), the CPUs' busy share (`pmustat -a`), and egl_haiku's "frames/s" and "window:" lines
# printed in that time; then kills the team (SIGKILL after 5 s: SuperTuxKart ignores SIGTERM). One line:
#   N3 LABEL: F fps (egl samples ...; window: ...) | team T % of a core, app_server A %, CPUs busy B % | M MHz
# CPU in % of one core over the measured time.
[ $# -ge 4 ] || { sed -n '6p' "$0" | sed 's/^# *//' >&2; exit 2; }
label=$1 warmup=$2 secs=$3
shift 3
log=/tmp/gl-pace-$label.txt
name=$(basename "$1")

# cpu_ms TEAM: user + kernel ms of all threads of the teams whose argv[0] contains TEAM
cpu_ms() {
	ps -a "$1" | awk '/^Thread +Id +State/ { t = 1; next } /^Team/ { t = 0 } t && NF >= 6 && $NF ~ /^[0-9]+$/ \
		{ s += $(NF - 1) + $NF } END { print s + 0 }'
}

(cd "$(dirname "$1")" && HAIKU_EGL_FPS=1 exec "$@") > $log 2>&1 &
sleep $warmup
lines0=$(wc -l < $log)
t0=$(cpu_ms "$name") a0=$(cpu_ms app_server)
pmustat -a $secs > /tmp/gl-pace-$label.pmu 2>&1
t1=$(cpu_ms "$name") a1=$(cpu_ms app_server)
busy=$(grep -a -o 'CPUs busy [0-9.]* %' /tmp/gl-pace-$label.pmu | head -n 1 | awk '{ print $3 }')
mhz=$(grep -a -o '[0-9.]* MHz while busy' /tmp/gl-pace-$label.pmu | head -n 1 | awk '{ print $1 }')
fps=$(tail -n +$((lines0 + 1)) $log | grep -a 'egl_haiku: .* frames/s' | sed -e 's/.*egl_haiku: \([0-9.]*\) frames.*/\1/' | tr '\n' ' ')
win=$(tail -n +$((lines0 + 1)) $log | grep -a 'egl_haiku: window:' | tail -n 1 | sed -e 's/.*window: //')
mean=$(echo "$fps" | awk '{ for (i = 1; i <= NF; i++) s += $i } END { if (NF) printf "%.1f", s / NF; else print "n/a" }')

team=$(ps | awk -v g="$name" 'index($1, g) && !/awk/ { print $(NF - 3) }')
kill $team 2> /dev/null
sleep 5
kill -9 $team 2> /dev/null
sleep 2

echo "N3 $label: $mean fps (egl samples: $fps; window: ${win:-none}) | team $(( (t1 - t0) / (secs * 10) )) % of a core, app_server $(( (a1 - a0) / (secs * 10) )) %, CPUs busy ${busy:-?} % | ${mhz:-?} MHz"
grep -a -E '^(GLF|GLTEAPOT)|Average FPS' $log | tail -n 2 | sed -e "s/^/N3 $label:   /"
