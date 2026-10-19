#!/usr/bin/env bash
# publish-repo.sh — publish our arm64 packages as a pkgman repository on GitHub Pages:
# github.com/haiku-pi/packages, served at https://haiku-pi.github.io/packages/arm64.
#
#   scripts/publish-repo.sh [--dry-run]
#
# Clones (or updates) the packages repository in artifacts/publish/packages, rebuilds arm64/ with
# scripts/make-repo.sh (the index, repo.sha256, packages/ = artifacts/packages/*.hpkg), and commits and
# pushes what changed. A package file only changes when its version or revision does, so rebuilding
# a package without bumping its revision republishes nothing; bump the revision to publish a fix.
# Never force-pushes. On the Pi: pkgman add-repo https://haiku-pi.github.io/packages/arm64
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
remote="${PACKAGES_REMOTE:-https://github.com/haiku-pi/packages.git}"
url="${PACKAGES_URL:-https://haiku-pi.github.io/packages/arm64}"
dry=0; [ "${1:-}" = --dry-run ] && dry=1
checkout="$root/artifacts/publish/packages"

if [ ! -d "$checkout/.git" ]; then
	mkdir -p "$(dirname "$checkout")"
	git clone -q "$remote" "$checkout"
fi
# a new, empty repository has no branch yet
git -C "$checkout" symbolic-ref HEAD refs/heads/main
if [ -n "$(git -C "$checkout" ls-remote --heads origin main)" ]; then
	git -C "$checkout" pull -q --ff-only origin main
fi

# keep the packages already published at their bytes: a rebuilt package with the same file name
# would only churn the history (and the checksums pkgman has cached)
staged="$root/artifacts/publish/staging"
rm -rf "$staged"; mkdir -p "$staged"
for f in "$root"/artifacts/packages/*.hpkg; do
	name="$(basename "$f")"
	if [ -f "$checkout/arm64/packages/$name" ]; then
		cp "$checkout/arm64/packages/$name" "$staged/"
	else
		cp "$f" "$staged/"
	fi
done
# the name and identifier of the arm64 images' HaikuPorts repository config
# (sources/haiku src/data/repository_infos/haikuports_arm64)
"$root/scripts/make-repo.sh" --packages "$staged" --out "$checkout/arm64" --url "$url" --copy \
	--name HaikuPorts --identifier tag:github.com/haiku-pi,2026:repositories/haikuports/arm64

cp "$root/tools/publish/packages-README.md" "$checkout/README.md"
touch "$checkout/.nojekyll"
git -C "$checkout" add -A
if git -C "$checkout" diff --cached --quiet; then
	echo "publish-repo: nothing changed"; exit 0
fi
git -C "$checkout" diff --cached --stat | tail -n 3
[ "$dry" = 1 ] && { echo "publish-repo: dry run, not committed"; exit 0; }
git -C "$checkout" commit -q -m "arm64: $(ls "$checkout/arm64/packages" | wc -l) packages (haiku-rpi $(git -C "$root" rev-parse --short HEAD))"
git -C "$checkout" push -q origin main
echo "publish-repo: pushed; $url"
