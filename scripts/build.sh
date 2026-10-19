#!/usr/bin/env bash
# build.sh [jam args...] — build Haiku arm64 in sources/haiku/generated.arm64 under the heavy-build
# guard (default target: @minimum-mmc), then make the Pi SD image (scripts/mkimage-pi4.sh).
# Log: artifacts/build/<ts>.log; prints the log's warnings count and the JAM rc.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -gt 0 ] || set -- @minimum-mmc
mkdir -p "$root/artifacts/build"
# the port's build options (tools/build/UserBuildConfig: jam -sHAIKU_PI_DEV=1 ...); no downloads, as
# our arm64 repository definition lists packages only our download directory has (see there)
ln -sfn "$root/tools/build/UserBuildConfig" "$root/sources/haiku/build/jam/UserBuildConfig"
log="$root/artifacts/build/$(date +%Y%m%d-%H%M%S).log"
rc=0
(cd "$root/sources/haiku/generated.arm64" && "$root/scripts/heavy-build.sh" --mem-per-job 1 -- jam -q "-j{JOBS}" -sHAIKU_NO_DOWNLOADS=1 "$@") > "$log" 2>&1 || rc=$?
grep -a -E 'error:|\.\.\.failed|don.t know how' "$log" | head -n 20 || true
echo "build: jam rc=$rc log=$log"
[ "$rc" = 0 ] || exit "$rc"
case " $* " in *mmc*) "$root/scripts/mkimage-pi4.sh" > "$log.mkimage" && head -n 1 "$log.mkimage" ;; esac
