#!/usr/bin/env bash
# net-perf-server.sh — TCP endpoints on the bench host for tools/pi-tests/net-perf.sh:
# port 5001 swallows whatever the Pi sends (its upload), port 5002 sends 64 MiB of zeros (its
# download). Listens on all addresses (the Pi LAN and the WiFi AP) until killed.
#
#   scripts/net-perf-server.sh &      ... run the cycle ...      kill %1
set -euo pipefail
trap 'kill $(jobs -p) 2>/dev/null' EXIT
socat -u TCP-LISTEN:5001,reuseaddr,fork OPEN:/dev/null &
socat TCP-LISTEN:5002,reuseaddr,fork SYSTEM:'head -c 67108864 /dev/zero' &
wait
