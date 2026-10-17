#!/usr/bin/env bash
# upstream-sync.sh — pull upstream Haiku (and buildtools) into the haiku-pi forks.
#
#   scripts/upstream-sync.sh [--merge]
#
# 1. Fast-forwards each fork's `master` to upstream/master and pushes it to origin (the fork's
#    master mirrors upstream; it never carries our commits).
# 2. With --merge: merges upstream/master into `rpi4` in sources/haiku (a merge, never a rebase:
#    rpi4 is published), stopping on conflicts. Validate afterwards with scripts/build.sh +
#    scripts/qemu-virt.sh + scripts/qemu-raspi.sh before pushing rpi4.
# Never force-pushes.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
merge=0; [ "${1:-}" = --merge ] && merge=1
for r in haiku buildtools; do
	g=(git -C "$root/sources/$r")
	"${g[@]}" fetch -q upstream
	"${g[@]}" fetch -q origin
	old="$("${g[@]}" rev-parse origin/master)"; new="$("${g[@]}" rev-parse upstream/master)"
	if [ "$old" = "$new" ]; then echo "$r: master up to date ($(echo "$new" | cut -c1-10))"; continue; fi
	"${g[@]}" merge-base --is-ancestor "$old" "$new" || { echo "$r: fork master diverged from upstream — fix by hand" >&2; exit 1; }
	"${g[@]}" push -q origin "upstream/master:refs/heads/master"
	echo "$r: master $(echo "$old" | cut -c1-10) -> $(echo "$new" | cut -c1-10) ($("${g[@]}" rev-list --count "$old..$new") commits)"
done
[ "$merge" = 1 ] || exit 0
h=(git -C "$root/sources/haiku")
[ "$("${h[@]}" rev-parse --abbrev-ref HEAD)" = rpi4 ] || { echo "sources/haiku is not on rpi4" >&2; exit 1; }
[ -z "$("${h[@]}" status --porcelain --untracked-files=no)" ] || { echo "sources/haiku has local changes" >&2; exit 1; }
if "${h[@]}" merge-base --is-ancestor upstream/master HEAD; then echo "rpi4: already contains upstream/master"; exit 0; fi
"${h[@]}" merge --no-edit -m "Merge upstream master into rpi4" upstream/master
echo "rpi4: merged $("${h[@]}" rev-parse --short upstream/master); now build + test, then: git -C sources/haiku push origin rpi4"
