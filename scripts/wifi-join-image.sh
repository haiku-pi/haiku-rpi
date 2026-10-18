#!/usr/bin/env bash
# wifi-join-image.sh — a test image whose bootscript joins the bench's WiFi AP
# (tools/pi-tests/wifi-join.sh with the SSID, passphrase and gateway filled in).
#
#   scripts/wifi-join-image.sh [--out artifacts/images/haiku-pi4-test.img]
#
# The passphrase comes from the peer project's AP configuration (psk= in wifi.conf, or the
# environment: WIFI_SSID / WIFI_PSK / WIFI_GATEWAY); it only lands in a temporary file and the
# (git-ignored) test image.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/artifacts/images/haiku-pi4-test.img"
[ "${1:-}" = "--out" ] && out="$2"
conf=/srv/phoenix-rpi4-nfs-gcc16/etc/wifi.conf
[ -f "$conf" ] || conf="$conf.off"
ssid="${WIFI_SSID:-PhoenixNet}"
psk="${WIFI_PSK:-$(sed -n 's/^psk=//p' "$conf" 2>/dev/null || true)}"
gateway="${WIFI_GATEWAY:-10.43.0.1}"
[ -n "$psk" ] || { echo "wifi-join-image: no passphrase (WIFI_PSK or $conf)" >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
python3 - "$root/tools/pi-tests/wifi-join.sh" "$tmp/wifi-join.sh" "$ssid" "$psk" "$gateway" <<'PY'
import sys
src, dst, ssid, psk, gw = sys.argv[1:]
s = open(src).read().replace("@SSID@", ssid).replace("@PSK@", psk).replace("@GATEWAY@", gw)
open(dst, "w").write(s)
PY
"$root/scripts/mkimage-pi4.sh" --out "$out" --bootscript "$tmp/wifi-join.sh" > /dev/null
echo "wifi-join-image: $out (SSID $ssid, gateway $gateway)"
