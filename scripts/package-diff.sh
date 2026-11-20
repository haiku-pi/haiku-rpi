#!/usr/bin/env bash
# package-diff.sh OLD.hpkg NEW.hpkg — what a new revision of a package changes: its provides/requires and
# its file paths, as diffs. Run before calling a test package ready: a dependency that silently dropped
# out of a build shows up as a missing file or requirement. Exit status 0 either way.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
pkgtool="$root/sources/haiku/generated.arm64/objects/linux/x86_64/release/tools/package/package"
[ $# = 2 ] || { sed -n 2,5p "$0" >&2; exit 2; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
for n in 1 2; do
	f="${!n}"
	"$pkgtool" list -i "$f" | sed -n 's/^\s*\(provides\|requires\): /\1 /p' \
		| sed -E 's/^(provides (blender|[a-z0-9_.]+)) = [0-9][^ ]*$/\1 = VERSION/' | sort > "$tmp/meta$n"
	"$pkgtool" list -p "$f" | sort > "$tmp/files$n"
done
echo "== provides/requires (the package's own version shown as VERSION)"
{ diff -u "$tmp/meta1" "$tmp/meta2" || true; } | tail -n +3 | grep '^[-+]' || echo "(same)"
echo "== files: $(wc -l < "$tmp/files1") -> $(wc -l < "$tmp/files2")"
{ diff -u "$tmp/files1" "$tmp/files2" || true; } | tail -n +3 | grep '^[-+]' || echo "(same paths)"
