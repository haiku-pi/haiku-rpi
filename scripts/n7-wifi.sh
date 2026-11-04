#!/usr/bin/env bash
# n7-wifi.sh — runs tools/pi-tests/n7-wifi.sh (H20 item N7: WiFi bring-up, TCP up/down under pmustat and
# profile, the SD controller check) on the Pi of a running session (scripts/pi-session.sh start), with
# scripts/net-perf-server.sh listening here for the duration.
#
#   scripts/n7-wifi.sh LABEL [RUNS]
#
# Output: artifacts/h20-n7/LABEL.txt (the "N7 LABEL" lines) and LABEL-up.prof / LABEL-down.prof.
# The WiFi network comes from local.conf (WIFI_SSID, WIFI_PSK or WIFI_PSK_FILE, WIFI_GATEWAY), as for
# scripts/wifi-join-image.sh; the passphrase goes to the Pi on ssh's stdin only.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -ge 1 ] || { sed -n '6p' "$0" | sed 's/^# //' >&2; exit 2; }
label=$1 runs=${2:-3}
# shellcheck source=/dev/null
[ -f "$root/local.conf" ] && . "$root/local.conf"
conf="${WIFI_PSK_FILE:-}"
[ -n "$conf" ] && [ ! -f "$conf" ] && [ -f "$conf.off" ] && conf="$conf.off"
psk="${WIFI_PSK:-$( [ -n "$conf" ] && sed -n 's/^psk=//p' "$conf" 2>/dev/null || true)}"
[ -n "${WIFI_SSID:-}" ] && [ -n "$psk" ] && [ -n "${WIFI_GATEWAY:-}" ] \
	|| { echo "n7-wifi: set WIFI_SSID, WIFI_PSK (or WIFI_PSK_FILE) and WIFI_GATEWAY (local.conf)" >&2; exit 1; }
tp="$root/sources/haiku-n7/generated.arm64/objects/haiku/arm64/release/tests/system/network/tcp_throughput/tcp_throughput"
[ -f "$tp" ] || tp="$root/sources/haiku/generated.arm64/objects/haiku/arm64/release/tests/system/network/tcp_throughput/tcp_throughput"
[ -f "$tp" ] || { echo "n7-wifi: no tcp_throughput (scripts/build.sh tcp_throughput)" >&2; exit 1; }
out="$root/artifacts/h20-n7"
mkdir -p "$out"

server=
if ! ss -ltn | grep -q -E ':5001\b'; then
	setsid "$root/scripts/net-perf-server.sh" > /dev/null 2>&1 &
	server=$!
	sleep 1
fi
trap '[ -n "$server" ] && kill -TERM -- -"$server" 2>/dev/null; true' EXIT

"$root/scripts/pi-ssh.sh" mkdir -p /boot/home/n7
"$root/scripts/pi-ssh.sh" put "$root/tools/pi-tests/n7-wifi.sh" "$tp" /boot/home/n7/
printf '%s\n' "$psk" | "$root/scripts/pi-ssh.sh" sh /boot/home/n7/n7-wifi.sh "$label" "$WIFI_SSID" \
	"$WIFI_GATEWAY" "$runs" | tee "$out/$label.txt"
"$root/scripts/pi-ssh.sh" get "/tmp/n7-$label-up.prof" "/tmp/n7-$label-down.prof" "$out/" || true
for d in up down; do
	[ -f "$out/n7-$label-$d.prof" ] && mv "$out/n7-$label-$d.prof" "$out/$label-$d.prof"
done
echo "n7-wifi: $out/$label.txt"
