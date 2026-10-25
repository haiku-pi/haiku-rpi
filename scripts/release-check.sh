#!/usr/bin/env bash
# release-check.sh — a release candidate image's session checks: builds the test programs (cross), starts
# a Pi session on IMG (scripts/pi-session.sh, network boot, holds the bench lock), copies them over, runs
# tools/pi-tests/relcheck.sh and stops the session. The cold card boot of the release procedure is separate
# (scripts/sd-cycle.sh --flash).
#
#   scripts/release-check.sh IMG [LABEL]
#
# Output: artifacts/relcheck/<LABEL>.txt (the "REL" lines); exit 0 when relcheck reports 0 problems.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
img="${1:?usage: release-check.sh IMG [LABEL]}"
label="${2:-$(basename "$img" .img)}"
out="$root/artifacts/relcheck"
bin="$out/bin"
mkdir -p "$bin"
cd "$root"
g="sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku"
sys="--sysroot=artifacts/sysroot-arm64"
"$g-gcc" $sys -O2 -o "$bin/polltest" tools/haiku-tests/polltest.c
"$g-gcc" $sys -O2 -o "$bin/resolvetime" tools/haiku-tests/resolvetime.c -lnetwork
"$g-gcc" $sys -O2 -shared -fPIC -o "$bin/libtlsr.so" tools/haiku-tests/tlsreload/libtlsr.c
"$g-gcc" $sys -O2 -o "$bin/tlsreload" tools/haiku-tests/tlsreload/tlsreload.c
"$g-gcc" $sys -O2 -I artifacts/sysroot-arm64/boot/system/develop/headers/os/opengl -o "$bin/eglterm" \
	tools/gl-tests/eglterm.c -lEGL
"$g-gcc" $sys -O2 -I artifacts/sysroot-arm64/boot/system/non-packaged/develop/headers -o "$bin/vkf32" \
	tools/gl-tests/vkf32.c artifacts/sysroot-arm64/boot/system/lib/libvulkan.so.1
"$g-g++" $sys -O2 -I sources/haiku/headers/private/interface -o "$bin/launchtime" \
	tools/haiku-tests/launchtime.cpp -lbe
scripts/pi-session.sh start --minutes 60 --image "$img" --label "relcheck-$label"
trap 'scripts/pi-session.sh stop' EXIT
scripts/pi-ssh.sh put "$bin"/* tools/pi-tests/relcheck.sh /boot/home/
scripts/pi-ssh.sh 'sh /boot/home/relcheck.sh' | tee "$out/$label.txt"
grep -q '^REL result: 0 problems' "$out/$label.txt"
