#!/usr/bin/env bash
# wifi-join-image.sh — a test image whose bootscript joins the bench's WiFi AP
# (tools/pi-tests/wifi-join.sh with the SSID, passphrase and gateway filled in).
#
#   scripts/wifi-join-image.sh [--out IMG] [--script tools/pi-tests/net-perf.sh]
#
# The passphrase comes from the peer project's AP configuration (psk= in wifi.conf, or the
# environment: WIFI_SSID / WIFI_PSK / WIFI_GATEWAY); it only lands in a temporary file and the
# (git-ignored) test image.
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
conf=/srv/phoenix-rpi4-nfs-gcc16/etc/wifi.conf
[ -f "$conf" ] || conf="$conf.off"
ssid="${WIFI_SSID:-PhoenixNet}"
psk="${WIFI_PSK:-$(sed -n 's/^psk=//p' "$conf" 2>/dev/null || true)}"
gateway="${WIFI_GATEWAY:-10.43.0.1}"
[ -n "$psk" ] || { echo "wifi-join-image: no passphrase (WIFI_PSK or $conf)" >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
python3 - "$script" "$tmp/$(basename "$script")" "$ssid" "$psk" "$gateway" <<'PY'
import sys
src, dst, ssid, psk, gw = sys.argv[1:]
s = open(src).read().replace("@SSID@", ssid).replace("@PSK@", psk).replace("@GATEWAY@", gw)
open(dst, "w").write(s)
PY
"$root/scripts/mkimage-pi4.sh" --out "$out" "${extra[@]}" --bootscript "$tmp/$(basename "$script")" > /dev/null
echo "wifi-join-image: $out (SSID $ssid, gateway $gateway)"
