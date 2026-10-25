#!/bin/sh
# wayland-exit.sh — a UserBootscript: Wayland clients of Haiku's in-process server exiting in the ways that
# crashed Photocraft at exit on the Pi (10-25, photocraft-gui5: "Segment violation" in
# BLooperList::FindLooperPred on the "wayland" looper's thread after `hey … quit`, the team left in the
# debugger): a message reaching a looper the server held at exit after libbe's static destructors ran.
# wayland_server >= 0.1.20251004-10 suspends the held loopers' threads; rfd's Haiku shim holds the loopers of
# a dialog still open at exit. Image: as photocraft-desktop.sh (artifacts/wayland-stage +
# artifacts/photocraft/gui-non-packaged: wlexit, photocraft-desktop-test, keyinject).
# Runs (PEX_N times each, default 20):
#   wlexit      tools/haiku-tests/wlexit: a toplevel, a thread committing every ms, exit() after 50-450 ms,
#               plus a request from an exit handler that runs after the server's hold
#   dialog      photocraft-desktop-test open: the panel, Escape, exit right after it closed
#   alert       photocraft-desktop-test alert: Return, exit right after
#   open-exit   photocraft-desktop-test exit-during open 1500: exit with the panel still open
#   alert-exit  photocraft-desktop-test exit-during alert 1500: exit with the alert still open
# A run that has not ended 10 s after it should have is counted as stuck (a crashed team waits in the
# debugger; debug_server's "entered the debugger" lines are on the serial console too) and killed.
# Serial lines: "PEX <run>: <ok> ok, <stuck> stuck of <n>", "PEX end".
sleep "${PEX_SLEEP:-25}"
out="${PEX_OUT:-/dev/dprintf}"
bin="${PEX_BIN:-/boot/system/non-packaged/bin}"
n="${PEX_N:-20}"
tmp="${PEX_TMP:-/tmp/wayland-exit}"
say() { echo "PEX $*" >> "$out"; }
export XKB_CONFIG_ROOT=/boot/system/non-packaged/data/X11/xkb
rm -rf "$tmp"
mkdir -p "$tmp"
say begin

# wait for PID to end within SECS; 0 ended, 1 stuck (its threads reported, then killed)
ended() {
	waited=0
	while [ $waited -lt $(($2 * 10)) ] && kill -0 $1 2> /dev/null; do sleep 0.1; waited=$((waited + 1)); done
	if kill -0 $1 2> /dev/null; then
		ps -a 2>&1 | awk -v id="$1" '$0 ~ /^Team/ {t = 0} t {print} $0 ~ (" " id " ") && !t {t = 1; print}' \
			| grep -a -v '^ *$\|^Thread\|^---' | head -n 30 | while IFS= read -r l; do say "stuck $1: $l"; done
		kill -9 $1 2> /dev/null
		wait $1 2> /dev/null
		return 1
	fi
	wait $1 2> /dev/null
	return 0
}

# RUN TITLE KEYS ARGS...: start the test program, KEYS into its window TITLE once there ("" = no keys)
cycle() {
	run=$1 title=$2 keys=$3
	shift 3
	"$@" > "$tmp/$run.txt" 2>&1 &
	pid=$!
	if [ -n "$keys" ]; then
		tries=0
		until "$bin/keyinject" $pid "$title" "$keys" > /dev/null 2>&1 || [ $tries -ge 50 ]; do
			sleep 0.2
			tries=$((tries + 1))
		done
	fi
	ended $pid 12
}

for run in ${PEX_RUNS:-wlexit dialog alert open-exit alert-exit}; do
	ok=0 stuck=0 i=0
	while [ $i -lt "$n" ]; do
		case $run in
		wlexit) cycle $run "" "" "$bin/wlexit" $((50 + (i * 20) % 400)) ;;
		dialog) cycle $run Open "^[" "$bin/photocraft-desktop-test" open /boot/home ;;
		alert) cycle $run "PDT alert" "~" "$bin/photocraft-desktop-test" alert "PDT alert" "Exit test" ok ;;
		open-exit) cycle $run "" "" "$bin/photocraft-desktop-test" exit-during open 1500 ;;
		alert-exit) cycle $run "" "" "$bin/photocraft-desktop-test" exit-during alert 1500 ;;
		esac
		if [ $? = 0 ]; then ok=$((ok + 1)); else stuck=$((stuck + 1)); say "$run: run $i stuck"; fi
		i=$((i + 1))
	done
	say "$run: $ok ok, $stuck stuck of $n"
	tail -n 3 "$tmp/$run.txt" | while IFS= read -r l; do say "$run: last: $l"; done
done
grep -a -E "entered the debugger|serious_debug_event|Segment violation" /var/log/syslog 2> /dev/null | tail -n 20 \
	| while IFS= read -r l; do say "syslog: $l"; done
say end
