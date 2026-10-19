#!/usr/bin/env bash
# wifi-join-image.sh — a test image whose bootscript joins the bench's WiFi AP
# (tools/pi-tests/wifi-join.sh with the SSID, passphrase and gateway filled in).
#
#   scripts/wifi-join-image.sh [--out IMG] [--script tools/pi-tests/net-perf.sh]
#
# The network and its passphrase come from local.conf or the environment (WIFI_SSID, WIFI_PSK or
# WIFI_PSK_FILE, WIFI_GATEWAY); the passphrase only lands in a temporary file and the (git-ignored)
# test image.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/artifacts/images/haiku-pi4-test.img"
script="$root/tools/pi-tests/wifi-join.sh"
extra=()
while [ $# -gt 0 ]; do
	case "$1" in
	--out) out="$2"; shift 2 ;;
	--script) script="$(realpath "$2")"; shift 2 ;;
	*) extra+=("$1"); shift ;;	# passed on to mkimage-pi4.sh (e.g. --add-bin FILE)
	esac
done
# shellcheck source=/dev/null
[ -f "$root/local.conf" ] && . "$root/local.conf"
# the passphrase: WIFI_PSK, or the "psk=" line of WIFI_PSK_FILE (or of WIFI_PSK_FILE.off)
conf="${WIFI_PSK_FILE:-}"
[ -n "$conf" ] && [ ! -f "$conf" ] && [ -f "$conf.off" ] && conf="$conf.off"
ssid="${WIFI_SSID:-}"
psk="${WIFI_PSK:-$( [ -n "$conf" ] && sed -n 's/^psk=//p' "$conf" 2>/dev/null || true)}"
gateway="${WIFI_GATEWAY:-}"
[ -n "$ssid" ] && [ -n "$psk" ] && [ -n "$gateway" ] \
	|| { echo "wifi-join-image: set WIFI_SSID, WIFI_PSK (or WIFI_PSK_FILE) and WIFI_GATEWAY (local.conf)" >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
python3 - "$script" "$tmp/$(basename "$script")" "$ssid" "$psk" "$gateway" <<'PY'
import sys
src, dst, ssid, psk, gw = sys.argv[1:]
s = open(src).read().replace("@SSID@", ssid).replace("@PSK@", psk).replace("@GATEWAY@", gw)
open(dst, "w").write(s)
PY
"$root/scripts/mkimage-pi4.sh" --out "$out" "${extra[@]}" --bootscript "$tmp/$(basename "$script")" > /dev/null
echo "wifi-join-image: $out (SSID $ssid, gateway $gateway)"
