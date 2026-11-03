#!/usr/bin/env bash
# release-docs-check.sh — before publishing a release image: are the user-facing docs up to date with it?
# (docs/RELEASING.md step 5; owner 2026-11-02: every big change reaches README, KNOWN-ISSUES,
# HAIKU-RPI4-CHANGES … when it is released.)
#
#   scripts/release-docs-check.sh TAG [PREVIOUS-MANIFEST]
#
# TAG: the release about to be published (e.g. image-2026-11-03). PREVIOUS-MANIFEST: the last release's
# manifests/*-release-*.md (default: the newest one). Checks:
#   - every commit of ours on haiku rpi4 since the previous release (first parent, no merges: upstream's
#     commits come in through merges) is named in docs/HAIKU-RPI4-CHANGES.md by its 10-character hash,
#     and so is every commit of ours since the upstream merge base (branch commits too), and the header's
#     "carries N commits of its own" equals that count;
#   - README.md and docs/TRY-IT.md point at TAG;
#   - docs/KNOWN-ISSUES.md was checked against the logs today;
#   - docs/HANDS-ON-CHECKS.md names TAG (what the newest release is);
#   - no docs/KNOWN-ISSUES.md row says it is fixed in the "next image": this release is that image, so the
#     row leaves the register (RELEASING.md step 5).
# Exit 0 when all pass; each failure is one line.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tag="${1:?usage: release-docs-check.sh TAG [PREVIOUS-MANIFEST]}"
prev="${2:-$(ls "$root"/manifests/*-release-*.md | LC_ALL=C sort | tail -n 1)}"
cd "$root"
fail=0
bad() { echo "release-docs-check: $*"; fail=1; }

base=$(awk -F'|' '$2 ~ /^ *haiku *$/ { gsub(/ /, "", $4); print $4 }' "$prev")
[ -n "$base" ] || { echo "release-docs-check: no haiku SHA in $prev" >&2; exit 2; }
n=0
while read -r sha subject; do
	n=$((n + 1))
	grep -q "${sha:0:10}" docs/HAIKU-RPI4-CHANGES.md \
		|| bad "HAIKU-RPI4-CHANGES.md does not name ${sha:0:10} ($subject)"
done < <(git -C sources/haiku log --first-parent --no-merges --format='%H %s' "$base..rpi4")
echo "release-docs-check: $n commit(s) of ours since $(basename "$prev") (haiku ${base:0:10})"

# every commit of ours since upstream (also those that came in through a merged branch: stage 6/7, dwarf5,
# gcc16), and the header's count of them, which goes stale between releases otherwise (owner 11-04)
mb=$(git -C sources/haiku merge-base rpi4 upstream/master 2>/dev/null)
if [ -n "$mb" ]; then
	total=0
	while read -r sha subject; do
		total=$((total + 1))
		grep -q "${sha:0:10}" docs/HAIKU-RPI4-CHANGES.md \
			|| bad "HAIKU-RPI4-CHANGES.md does not name ${sha:0:10} ($subject; came in through a branch)"
	done < <(git -C sources/haiku log --no-merges --format='%H %s' "$mb..rpi4")
	grep -q "carries \*\*$total commits of its own\*\*" docs/HAIKU-RPI4-CHANGES.md \
		|| bad "HAIKU-RPI4-CHANGES.md: the header's commit count is not $total (git log --no-merges merge-base..rpi4)"
fi

for f in README.md docs/TRY-IT.md docs/HANDS-ON-CHECKS.md; do
	grep -q -- "$tag" "$f" || bad "$f does not mention $tag"
done
grep -q "Checked against the weekly logs up to \*\*$(date +%F)" docs/KNOWN-ISSUES.md \
	|| bad "docs/KNOWN-ISSUES.md: \"Checked against the weekly logs up to\" is not today ($(date +%F))"
grep -n -i 'next image' docs/KNOWN-ISSUES.md | grep '^[0-9]*:| ' | while IFS= read -r l; do
	echo "release-docs-check: docs/KNOWN-ISSUES.md row fixed in the \"next image\" (this one): ${l:0:60}"
done | grep . && fail=1
[ "$fail" = 0 ] && echo "release-docs-check: ok"
exit "$fail"
