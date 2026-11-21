#!/usr/bin/env bash
# run.sh [HAIKU_TREE] — builds and runs the host test of app_server's overlay read-back (screenshots of what
# overlays show; src/servers/app/drawing/OverlayReadBack.cpp; default tree: sources/haiku).
# Prints "READBACK ... PASS"; exit status 0 = pass. docs/design/gpu-stage6.md §11.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tree="${1:-$here/../../../sources/haiku}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
g++ -O2 -Wall -Wextra -Werror -Wno-unused-parameter -Wno-deprecated-copy -I"$here/stub" -I"$tree/headers/os/interface" \
	-I"$tree/headers/private/graphics" -I"$tree/src/servers/app/drawing" \
	"$here/test.cpp" "$tree/src/servers/app/drawing/OverlayReadBack.cpp" -o "$out/test"
"$out/test"
