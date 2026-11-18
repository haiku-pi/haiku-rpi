#!/usr/bin/env bash
# wifi-autojoin.sh — runs tools/pi-tests/wifi-autojoin.sh (a saved WiFi network re-joined after a reboot,
# docs/design/wifi-autojoin.md) on the Pi of a running session (scripts/pi-session.sh start).
#
#   scripts/wifi-autojoin.sh LABEL join|joinbad|save|check|down|up|cycle [SECS] [now (check) | N (cycle)]
#
# The network comes from local.conf (WIFI_SSID, WIFI_PSK or WIFI_PSK_FILE, WIFI_GATEWAY), as for
# scripts/n7-wifi.sh. LABEL must be the running session's label (scripts/pi-session.sh start --label LABEL):
# another session is never touched. The passphrase goes to the Pi on ssh's stdin only, and the output (appended to
# artifacts/wifi-autojoin/LABEL.txt) is checked not to hold it.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -ge 2 ] || { sed -n '6p' "$0" | sed 's/^# //' >&2; exit 2; }
label=$1 mode=$2 secs=${3:-150} now=${4:-}
# shellcheck source=/dev/null
[ -f "$root/local.conf" ] && . "$root/local.conf"
conf="${WIFI_PSK_FILE:-}"
[ -n "$conf" ] && [ ! -f "$conf" ] && [ -f "$conf.off" ] && conf="$conf.off"
psk="${WIFI_PSK:-$( [ -n "$conf" ] && sed -n 's/^psk=//p' "$conf" 2>/dev/null || true)}"
[ -n "${WIFI_SSID:-}" ] && [ -n "$psk" ] && [ -n "${WIFI_GATEWAY:-}" ] \
	|| { echo "wifi-autojoin: set WIFI_SSID, WIFI_PSK (or WIFI_PSK_FILE) and WIFI_GATEWAY (local.conf)" >&2; exit 1; }
# only on our own session: the session state is shared by every agent on this host
state="$root/artifacts/pi-session/state"
grep -q "^label=session-$label\$" "$state" 2>/dev/null \
	|| { echo "wifi-autojoin: the running session is not session-$label: not touching it" >&2; exit 1; }
out="$root/artifacts/wifi-autojoin"
mkdir -p "$out"
"$root/scripts/pi-ssh.sh" put "$root/tools/pi-tests/wifi-autojoin.sh" /boot/home/wifi-autojoin.sh
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
printf '%s\n' "$psk" | "$root/scripts/pi-ssh.sh" sh /boot/home/wifi-autojoin.sh "$mode" "$WIFI_SSID" \
	"$WIFI_GATEWAY" "$secs" "$now" > "$tmp" 2>&1 || true
leaks=$(grep -c -F -- "$psk" "$tmp" || true)
if [ "$leaks" != 0 ]; then
	echo "wifi-autojoin: the output held the passphrase ($leaks lines): not kept" >&2
	exit 1
fi
cat "$tmp" | tee -a "$out/$label.txt"
