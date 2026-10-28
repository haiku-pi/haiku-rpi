#!/usr/bin/env bash
# build.sh [jam args...] — build Haiku arm64 in sources/haiku/generated.arm64 under the heavy-build
# guard (default target: @minimum-mmc), then make the Pi SD image (scripts/mkimage-pi4.sh; for
# @pi-mmc, the regular image: artifacts/images/haiku-pi4-regular.img, or $PI_IMAGE_OUT; @nightly-mmc:
# -nightly.img).
# Log: artifacts/build/<ts>.log; prints the log's warnings count and the JAM rc.
#
#   scripts/build.sh --generated DIR [jam args...]
#       build in another configured output directory DIR instead (a worktree's generated.arm64, for
#       an A/B image from a branch without touching the main checkout's build); its images are
#       DIR/haiku-pi4*.img (@pi-mmc: PI_IMAGE_OUT, if set)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
gen="$root/sources/haiku/generated.arm64"
imgdir="$root/artifacts/images"
if [ "${1:-}" = --generated ]; then
	gen="$(cd "$2" && pwd)"
	imgdir="$gen"
	shift 2
fi
[ $# -gt 0 ] || set -- @minimum-mmc
mkdir -p "$root/artifacts/build"
# the port's build options (tools/build/UserBuildConfig: jam -sHAIKU_PI_DEV=1 ...); no downloads, as
# our arm64 repository definition lists packages only our download directory has (see there)
ln -sfn "$root/tools/build/UserBuildConfig" "$gen/../build/jam/UserBuildConfig"
log="$root/artifacts/build/$(date +%Y%m%d-%H%M%S).log"
rc=0
(cd "$gen" && "$root/scripts/heavy-build.sh" --mem-per-job 1 -- jam -q "-j{JOBS}" -sHAIKU_NO_DOWNLOADS=1 "-sHAIKU_PI_ROOT=$root" "$@") > "$log" 2>&1 || rc=$?
grep -a -E 'error:|\.\.\.failed|don.t know how|^problem' "$log" | head -n 20 || true
echo "build: jam rc=$rc log=$log"
if [ "$rc" != 0 ]; then
	# A failed image step leaves build_haiku_image's bfs_shell server running, holding the heavy-build
	# lock it inherited: every later build would wait for it forever.
	for pid in $(ps -eo pid=,args= | awk -v dir="$gen" \
			'$2 ~ /bfs_shell$/ && $3 == "-n" && index($4, dir) == 1 {print $1}'); do
		echo "build: stopping the image builder's bfs_shell $pid"
		kill "$pid" 2>/dev/null || true
	done
	exit "$rc"
fi
case " $* " in
*nightly-mmc*)
	"$root/scripts/mkimage-pi4.sh" --in "$gen/haiku-nightly.mmc" \
		--out "$imgdir/haiku-pi4-nightly.img" > "$log.mkimage" && head -n 1 "$log.mkimage" ;;
*pi-mmc*)
	# (an haiku-mmc-image profile always writes haiku-mmc.image)
	"$root/scripts/mkimage-pi4.sh" --in "$gen/haiku-mmc.image" \
		--out "${PI_IMAGE_OUT:-$imgdir/haiku-pi4-regular.img}" > "$log.mkimage" \
		&& head -n 1 "$log.mkimage" ;;
*mmc*)
	"$root/scripts/mkimage-pi4.sh" --in "$gen/haiku-mmc.image" \
		--out "$imgdir/haiku-pi4.img" > "$log.mkimage" && head -n 1 "$log.mkimage" ;;
esac
