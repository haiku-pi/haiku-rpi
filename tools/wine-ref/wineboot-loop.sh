#!/usr/bin/env bash
# wineboot-loop.sh — the Pi's tools/pi-tests/wineboot-loop.sh on this host: N fresh prefixes (wineboot -i, then
# wineserver -w, at most 120 s) under the reference Wine (scripts/build-wine-ref.sh) on a virtual X server, or under
# INSTALL: e.g. artifacts/wine-ref/install-address, the reference with scripts/build-wineserver-host.sh's
# AddressSanitizer wineserver of the patched tree.
#
#   tools/wine-ref/wineboot-loop.sh N [DIR [INSTALL]]
#
# DIR (default artifacts/wine-ref/wbl): the prefixes (DIR/prefix, remade each run) and the logs, DIR/<i>.log
# (wineboot) and DIR/asan.<pid> (sanitizer reports: ASAN_OPTIONS log_path). A run whose processes have not
# ended after 120 s counts as a hang (a wineboot still running after 300 s is ended first); a run that left a
# sanitizer report as an error. Lines "WBL ..." on stdout;
# ends "WBL end N runs, H hangs, E errors".
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
n=${1:-10}
dir=${2:-$root/artifacts/wine-ref/wbl}
wine="${3:-$root/artifacts/wine-ref/install}/bin"
mkdir -p "$dir"
export PATH="$wine:$PATH" WINEPREFIX="$dir/prefix" WINEDEBUG="${WINEDEBUG:--all}"
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"
export ASAN_OPTIONS="${ASAN_OPTIONS:-log_path=$dir/asan:detect_leaks=0:abort_on_error=0}"

d=97
while [ -e /tmp/.X11-unix/X$d ]; do d=$((d + 1)); done
Xvfb :$d -screen 0 1280x720x24 -nolisten tcp > "$dir/xvfb.txt" 2>&1 &
xvfb=$!
export DISPLAY=:$d
trap 'wineserver -k 2> /dev/null; kill $xvfb 2> /dev/null' EXIT
sleep 2

hangs=0 errors=0
for i in $(seq 1 "$n"); do
	wineserver -k > /dev/null 2>&1
	rm -rf "$WINEPREFIX"
	before=$(ls "$dir" | grep -c '^asan\.')
	start=$(date +%s)
	timeout 300 wineboot -i > "$dir/$i.log" 2>&1 < /dev/null
	rc=$?
	timeout 120 wineserver -w
	w=$?
	after=$(ls "$dir" | grep -c '^asan\.')
	if [ "$after" != "$before" ]; then
		errors=$((errors + 1))
		echo "WBL $i: SANITIZER REPORT (wineboot exit $rc): $(ls -t "$dir" | grep '^asan\.' | head -n 1)"
	fi
	if [ $w = 124 ]; then
		hangs=$((hangs + 1))
		echo "WBL $i: HANG (wineboot exit $rc); left: $(pgrep -u "$USER" -f 'services.exe|winedevice.exe|explorer.exe|wineserver' | tr '\n' ' ')"
		[ "${WBL_KEEP:-0}" = 1 ] && { trap - EXIT; echo "WBL end $i runs, $hangs hangs, $errors errors (kept)"; exit 0; }
	elif [ "$after" = "$before" ]; then
		echo "WBL $i: ok, wineboot exit $rc, all ended after $(( $(date +%s) - start )) s"
	fi
done
echo "WBL end $n runs, $hangs hangs, $errors errors"
