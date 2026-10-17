#!/usr/bin/env bash
#
# heavy-build.sh — run a memory-heavy host build (WebKit, Mesa, an image build) so that it can
# neither run alongside another heavy build nor take the host down when it runs out of memory.
#
#   scripts/heavy-build.sh [-j N] [--mem-per-job GB] [--max GB] [--] <command...>
#
# Why: on 2026-10-02 01:44 two WebKit C++ builds (a `jsc` rebuild at -j8 and a subagent's WPE
# build) ran at once; at 26.4 GB of 29 systemd-oomd killed the whole terminal scope, and with it
# the coordinating Claude session and both builds. One WebKit compile job takes 1-2 GB.
#
# What it does:
#   1. Serialises: holds an exclusive flock on $HEAVY_BUILD_LOCK (default /tmp/phoenix-heavy-build.lock,
#      also taken by rebuild-rpi4b-fast.sh unless HEAVY_BUILD_LOCKED=1, which this script exports)
#      for the whole command, waiting for any other heavy build to finish first.
#   2. Caps parallelism: exports HEAVY_BUILD_JOBS = min(N, MemAvailable / --mem-per-job (default 2 GB)),
#      at least 1. The command decides how to use it (e.g. `-j "$HEAVY_BUILD_JOBS"`); the value is
#      also substituted for a literal {JOBS} in the arguments.
#   3. Contains: runs the command in its own systemd user scope with MemoryMax (default 22 GB) and no
#      swap, so if it still runs out of memory the kernel kills the build, not the session around it.
#
# Exit status is the command's.
set -euo pipefail

jobs="$(nproc)"
mem_per_job=2
max_gb=22
while [ $# -gt 0 ]; do
	case "$1" in
	-j) jobs="$2"; shift 2 ;;
	--mem-per-job) mem_per_job="$2"; shift 2 ;;
	--max) max_gb="$2"; shift 2 ;;
	--) shift; break ;;
	*) break ;;
	esac
done
[ $# -gt 0 ] || { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

lock="${HEAVY_BUILD_LOCK:-/tmp/phoenix-heavy-build.lock}"
exec 9>"${lock}"
if ! flock -n 9; then
	printf 'heavy-build: waiting for another heavy build (%s)\n' "${lock}" >&2
	flock 9
fi

avail_gb=$(awk '/^MemAvailable:/ {printf "%d", $2 / 1048576}' /proc/meminfo)
fit=$(( avail_gb / mem_per_job ))
[ "${fit}" -ge 1 ] || fit=1
[ "${jobs}" -le "${fit}" ] || jobs="${fit}"
export HEAVY_BUILD_JOBS="${jobs}" HEAVY_BUILD_LOCKED=1
printf 'heavy-build: %s job(s) (MemAvailable %s GB, %s GB/job), MemoryMax %sG\n' \
	"${jobs}" "${avail_gb}" "${mem_per_job}" "${max_gb}" >&2

args=()
for a in "$@"; do args+=("${a//\{JOBS\}/${jobs}}"); done
exec systemd-run --user --scope -q -p MemoryMax="${max_gb}G" -p MemorySwapMax=0 -- "${args[@]}"
