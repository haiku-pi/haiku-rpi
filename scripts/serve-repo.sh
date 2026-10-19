#!/usr/bin/env bash
# serve-repo.sh — serves artifacts/repo (scripts/make-repo.sh) over HTTP on port 8090 for the bench Pi
# (http://10.42.0.1:8090/arm64), until killed. Not a public server: bind it to the Pi LAN only.
#
#   scripts/serve-repo.sh [ADDRESS]      (default 10.42.0.1)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 -m http.server 8090 --bind "${1:-10.42.0.1}" --directory "$root/artifacts/repo"
