#!/usr/bin/env bash
# run.sh [HAIKU_TREE] — builds and runs the host test of app_server's keyed front-buffer copy
# (default tree: sources/haiku). Prints "KEY ... PASS"; exit status 0 = pass.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tree="${1:-$here/../../../sources/haiku}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
g++ -O2 -Wall -Wextra -Werror -I"$here/stub" -I"$tree/src/servers/app/drawing" \
	"$here/test.cpp" "$tree/src/servers/app/drawing/OverlayKeying.cpp" -o "$out/test"
"$out/test"
