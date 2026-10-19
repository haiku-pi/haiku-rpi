#!/usr/bin/env bash
# upstream-sync.sh — keep the haiku-pi forks up with upstream (weekly, on the weekend).
#
#   scripts/upstream-sync.sh [--merge] [REPO...]      (default: haiku buildtools)
#
# Haiku and buildtools follow upstream development. Mesa, libdrm and libglvnd stay on stable releases
# (rpi4 is based on a release tag): for them the script only reports newer releases of the same
# series (e.g. a Mesa 26.2.x point release), to adopt deliberately; name one explicitly to mirror
# its development branch anyway.
#
# For each fork named:
# 1. Mirrors upstream's main branch into the fork's branch of the same name and pushes it (that branch
#    never carries our commits).
# 2. With --merge: merges upstream's main branch into our `rpi4` branch (a merge, never a rebase: rpi4
#    is published), stopping on conflicts or local changes. Validate afterwards (scripts/build.sh, the
#    GL stack, a Pi boot) before pushing rpi4: `git -C sources/<repo> push <fork remote> rpi4`.
# The fork remote is the one whose URL is under github.com/haiku-pi; the upstream remote is added when
# a clone lacks it. Never force-pushes.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
merge=0
if [ "${1:-}" = --merge ]; then merge=1; shift; fi
repos=("$@")
[ ${#repos[@]} -gt 0 ] || repos=(haiku buildtools)

# repo: upstream URL and its main branch
declare -A upstreamUrl=(
	[haiku]=https://review.haiku-os.org/haiku
	[buildtools]=https://review.haiku-os.org/buildtools
	[mesa]=https://gitlab.freedesktop.org/mesa/mesa.git
	[libdrm]=https://gitlab.freedesktop.org/mesa/drm.git
	[libglvnd]=https://gitlab.freedesktop.org/glvnd/libglvnd.git
)
declare -A upstreamBranch=([haiku]=master [buildtools]=master [mesa]=main [libdrm]=main [libglvnd]=master)

status=0
for r in "${repos[@]}"; do
	dir="$root/sources/$r"
	[ -d "$dir/.git" ] || { echo "$r: no $dir (scripts/bootstrap.sh)" >&2; status=1; continue; }
	g=(git -C "$dir")
	fork="$("${g[@]}" remote -v | awk '/github\.com[:\/]haiku-pi\// && /\(push\)/ { print $1; exit }')"
	[ -n "$fork" ] || { echo "$r: no remote under github.com/haiku-pi" >&2; status=1; continue; }
	up="$("${g[@]}" remote -v | awk -v u="${upstreamUrl[$r]}" '$2 == u && /\(fetch\)/ { print $1; exit }')"
	if [ -z "$up" ]; then
		up=upstream
		"${g[@]}" remote add "$up" "${upstreamUrl[$r]}"
	fi
	branch="${upstreamBranch[$r]}"
	if ! "${g[@]}" fetch -q "$up" "$branch" || ! "${g[@]}" fetch -q "$fork"; then
		echo "$r: fetch failed (try again later)" >&2; status=1; continue
	fi
	new="$("${g[@]}" rev-parse "$up/$branch")"
	old="$("${g[@]}" rev-parse -q --verify "$fork/$branch" || true)"
	if [ "$old" = "$new" ]; then
		echo "$r: $fork/$branch up to date (${new:0:10})"
	elif [ -n "$old" ] && ! "${g[@]}" merge-base --is-ancestor "$old" "$new"; then
		echo "$r: $fork/$branch diverged from $up/$branch — fix by hand" >&2; status=1; continue
	else
		"${g[@]}" push -q "$fork" "$up/$branch:refs/heads/$branch"
		echo "$r: $fork/$branch ${old:0:10} -> ${new:0:10}${old:+ ($("${g[@]}" rev-list --count "$old..$new") commits)}"
	fi

	[ "$merge" = 1 ] || continue
	if ! "${g[@]}" rev-parse -q --verify rpi4 >/dev/null; then
		echo "$r: no rpi4 branch (nothing of ours to merge into)"; continue
	fi
	[ "$("${g[@]}" rev-parse --abbrev-ref HEAD)" = rpi4 ] \
		|| { echo "$r: not on rpi4" >&2; status=1; continue; }
	[ -z "$("${g[@]}" status --porcelain --untracked-files=no)" ] \
		|| { echo "$r: local changes, not merging" >&2; status=1; continue; }
	if "${g[@]}" merge-base --is-ancestor "$up/$branch" HEAD; then
		echo "$r: rpi4 already contains $up/$branch"; continue
	fi
	if "${g[@]}" merge --no-edit -m "Merge upstream $branch into rpi4" "$up/$branch" >/dev/null; then
		echo "$r: rpi4 merged ${new:0:10}; validate, then: git -C sources/$r push $fork rpi4"
	else
		echo "$r: merge conflicts — resolve in sources/$r, or git -C sources/$r merge --abort" >&2
		status=1
	fi
done
# the release-based components: newer releases of the series rpi4 is on
for r in mesa libdrm libglvnd; do
	dir="$root/sources/$r"
	[ -d "$dir/.git" ] || continue
	base="$(git -C "$dir" describe --tags --abbrev=0 rpi4 2>/dev/null)" || continue
	series="${base%.*}."
	newest="$(git ls-remote --tags --refs "${upstreamUrl[$r]}" "$series*" 2>/dev/null \
		| sed 's|.*refs/tags/||' | grep -v -E 'rc|devel' | sort -V | tail -n 1)" || true
	if [ -z "$newest" ]; then
		echo "$r: on $base (no tag list: upstream unreachable?)"
	elif [ "$newest" != "$base" ]; then
		echo "$r: on $base; newer release in the series: $newest (adopt deliberately)"
	else
		echo "$r: on $base, the newest of its series"
	fi
done
exit "$status"
