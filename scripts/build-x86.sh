#!/usr/bin/env bash
# build-x86.sh — build Haiku x86_64 from our tree and from its upstream baseline, side by side, to check
# that our changes still build and work on x86-64 (H22, docs/design/x86-64-check.md §3). Two detached
# worktrees of sources/haiku, one set of cross tools (upstream buildtools, GCC 13.3) shared by both:
#
#   sources/haiku-x86      our tree (rpi4 at the time of the check)
#   sources/haiku-x86-up   its upstream baseline (hrev60314)
#   sources/buildtools-x86 upstream buildtools (33d46bf5c3)
#
#   scripts/build-x86.sh configure [rpi4|up|all|DIR]
#       rpi4: build the x86_64 cross tools from sources/buildtools-x86 into
#       sources/haiku-x86/generated.x86_64/cross-tools-x86_64 (heavy-build guarded, ~6 min);
#       up: configure sources/haiku-x86-up/generated.x86_64 with those tools (--cross-tools-prefix);
#       all (default): both, in that order; DIR: configure the output directory DIR (e.g. another
#       worktree's generated.x86_64) with those tools.
#   scripts/build-x86.sh build rpi4|up|DIR [jam args...]
#       jam in that tree's generated.x86_64 (or in the configured output directory DIR), heavy-build
#       guarded; default target @nightly-anyboot (haiku-nightly-anyboot.iso). Before any tree but rpi4
#       builds, the packages the rpi4 tree has already downloaded are hard-linked into its download/.
#       Log: artifacts/build/x86-<tree>-<ts>.log; prints the first errors, the warnings count and the jam rc.
#       (Catalog key extraction preprocesses the translators without their build-feature headers; its
#       "fatal error: ...: No such file or directory" lines are not build failures, upstream's too.)
#
# The x86_64 build downloads its packages from Haiku's repository (no HAIKU_NO_DOWNLOADS, no
# UserBuildConfig), as upstream's own builds do. scripts/build.sh stays the arm64 build.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tools_src="$root/sources/buildtools-x86"
rpi4="$root/sources/haiku-x86/generated.x86_64"
up="$root/sources/haiku-x86-up/generated.x86_64"
prefix="$rpi4/cross-tools-x86_64/bin/x86_64-unknown-haiku-"
heavy=("$root/scripts/heavy-build.sh" --mem-per-job 1 --)

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
tree_dir() {
	case "$1" in
	rpi4) echo "$rpi4" ;;
	up) echo "$up" ;;
	*) [ -f "$1/build/BuildConfig" ] || { echo "build-x86: $1 is not a configured output directory" >&2; exit 2; }
		(cd "$1" && pwd) ;;
	esac
}

configure_rpi4() {
	[ -d "$tools_src/gcc" ] || { echo "build-x86: $tools_src missing (git -C sources/buildtools worktree add)" >&2; exit 1; }
	mkdir -p "$rpi4" "$root/artifacts/build"
	local log="$root/artifacts/build/x86-crosstools-$(date +%Y%m%d-%H%M%S).log" rc=0 t0=$SECONDS
	(cd "$rpi4" && "${heavy[@]}" ../configure --build-cross-tools x86_64 \
		--cross-tools-source "$tools_src" "-j{JOBS}") > "$log" 2>&1 || rc=$?
	tail -n 3 "$log"
	echo "build-x86: cross tools rc=$rc in $((SECONDS - t0)) s, log=$log"
	[ "$rc" = 0 ] && "${prefix}gcc" --version | head -n 1
	return "$rc"
}

configure_other() {	# DIR: an output directory of another haiku worktree, with rpi4's cross tools
	[ -x "${prefix}gcc" ] || { echo "build-x86: ${prefix}gcc missing (configure rpi4 first)" >&2; exit 1; }
	[ -x "$(dirname "$1")/configure" ] || { echo "build-x86: no configure next to $1" >&2; exit 2; }
	mkdir -p "$1"
	(cd "$1" && ../configure --cross-tools-prefix "$prefix") | tail -n 3
}

link_downloads() {	# GEN: hard-link rpi4's downloaded packages into GEN/download (only names it lacks)
	local n=0 f
	[ -d "$rpi4/download" ] || return 0
	mkdir -p "$1/download"
	for f in "$rpi4"/download/*; do
		[ -f "$f" ] && [ ! -e "$1/download/${f##*/}" ] || continue
		ln "$f" "$1/download/" && n=$((n + 1))
	done
	echo "build-x86: $n downloaded file(s) hard-linked from the rpi4 tree"
}

build() {
	local gen name log rc=0 t0=$SECONDS
	gen="$(tree_dir "$1")"
	name="$1"; [ "$name" = rpi4 ] || [ "$name" = up ] || name="$(basename "$(dirname "$gen")")"
	shift
	[ $# -gt 0 ] || set -- @nightly-anyboot
	[ "$gen" = "$rpi4" ] || link_downloads "$gen"
	mkdir -p "$root/artifacts/build"
	log="$root/artifacts/build/x86-$name-$(date +%Y%m%d-%H%M%S).log"
	echo "build-x86: $name ($(git -C "$gen/.." rev-parse --short=10 HEAD)) jam $* -> $log"
	(cd "$gen" && "${heavy[@]}" jam -q "-j{JOBS}" "$@") > "$log" 2>&1 || rc=$?
	grep -a -E 'error:|\.\.\.failed|don.t know how|^problem|not available!' "$log" | grep -a -v -E 'fatal error: .*: No such file or directory' | head -n 20 || true
	echo "build-x86: $name jam rc=$rc in $((SECONDS - t0)) s, warnings $(grep -a -c 'warning:' "$log" || true), log=$log"
	if [ "$rc" != 0 ]; then
		# a failed image step leaves build_haiku_image's bfs_shell server running, holding the
		# heavy-build lock it inherited (scripts/build.sh does the same)
		for pid in $(ps -eo pid=,args= | awk -v dir="$gen" \
				'$2 ~ /bfs_shell$/ && $3 == "-n" && index($4, dir) == 1 {print $1}'); do
			echo "build-x86: stopping the image builder's bfs_shell $pid"
			kill "$pid" 2>/dev/null || true
		done
	fi
	return "$rc"
}

[ $# -gt 0 ] || usage
cmd="$1"; shift
case "$cmd" in
configure)
	case "${1:-all}" in
	rpi4) configure_rpi4 ;;
	up) configure_other "$up" ;;
	all) configure_rpi4; configure_other "$up" ;;
	*) configure_other "$1" ;;
	esac ;;
build) [ $# -gt 0 ] || usage; build "$@" ;;
*) usage ;;
esac
