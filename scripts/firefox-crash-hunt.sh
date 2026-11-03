#!/usr/bin/env bash
# firefox-crash-hunt.sh [--image IMG] [--starts N] [--secs S] [--url URL] [--add FILE:PATH]... [--label L] [--keep]
# — the Firefox content-process crash of the 11-03 mega smoke test (docs/design/firefox-contentproc-crash.md) on
# the bench Pi: one network session of IMG (default artifacts/images/haiku-pi4-2026-11-03b.img), Firefox started
# N times (default 25), S s each (default 25), then ended with SIGTERM/SIGKILL as tools/mega/smoke-pi.sh does
# (tools/pi-tests/firefox-start-loop.sh); debug_server writes reports, which are collected.
# --add: files onto the session's disk (scripts/pi-session.sh); --keep: leave the session running;
# --kdl-then CMD: after the loop, CMD in the kernel debugger (over the serial line), then the loop once more (an
# A/B in one boot, for a diagnostic kernel's switch).
# Output: artifacts/firefox-crash/<ts>-<label>/ (loop.txt, reports/*.report, syslog); the serial log is the
# session's (artifacts/uart/<ts>-session-ffhunt-<label>.log).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
img="$root/artifacts/images/haiku-pi4-2026-11-03b.img" starts=25 secs=25 url="" adds=() label=run keep=0 kdl=""
while [ $# -gt 0 ]; do
	case "$1" in
	--image) img="$(realpath "$2")"; shift 2 ;;
	--starts) starts="$2"; shift 2 ;;
	--secs) secs="$2"; shift 2 ;;
	--url) url="$2"; shift 2 ;;
	--add) adds+=(--add "$2"); shift 2 ;;
	--label) label="$2"; shift 2 ;;
	--keep) keep=1; shift ;;
	--kdl-then) kdl="$2"; shift 2 ;;
	*) sed -n '2,11p' "$0" >&2; exit 2 ;;
	esac
done
ssh="$root/scripts/pi-ssh.sh"
out="$root/artifacts/firefox-crash/$(date +%Y%m%d-%H%M%S)-$label"
mkdir -p "$out/reports"
"$root/scripts/pi-session.sh" start --minutes 240 --image "$img" --label "ffhunt-$label" "${adds[@]}"
"$ssh" put "$root/tools/pi-tests/firefox-start-loop.sh" /boot/home/ > /dev/null
echo "image $img, starts $starts, $secs s, url '${url:-home page}', ${adds[*]}" > "$out/loop.txt"
"$ssh" "uname -a; sha256sum /boot/system/lib/libroot.so" >> "$out/loop.txt" 2>&1 || true
loop() {
	timeout $((starts * (secs + 400) + 120)) "$ssh" "sh /boot/home/firefox-start-loop.sh $starts $secs $url" 2>&1 \
		| tee -a "$out/loop.txt" | grep --line-buffered '^FSL' | cut -c1-220 || true
}
loop
if [ -n "$kdl" ]; then
	echo "kernel debugger: $kdl" | tee -a "$out/loop.txt"
	"$root/scripts/uart-send.sh" '0:\x1d\x1d\x1dd' "4:$kdl\n" '7:continue\n' > /dev/null
	sleep 15
	loop
fi
"$ssh" get '/boot/home/Desktop/*.report' "$out/reports/" > /dev/null 2>&1 || echo "no reports"
"$ssh" get /var/log/syslog "$out/" > /dev/null 2>&1 || true
[ "$keep" = 1 ] || "$root/scripts/pi-session.sh" stop > /dev/null 2>&1 || true
echo "$out"
