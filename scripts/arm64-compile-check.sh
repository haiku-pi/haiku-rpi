#!/usr/bin/env bash
# arm64-compile-check.sh — compile source files of another haiku worktree (e.g. a fix branch made for x86-64,
# H22) for arm64 with exactly the flags the arm64 build uses (-Werror included), without configuring an arm64
# build there and without touching sources/haiku/generated.arm64's objects:
#
#   scripts/arm64-compile-check.sh WORKTREE SRC...      (SRC relative to the worktree, e.g. src/system/.../IORequest.cpp)
#
# The compile line comes from `jam -n -a -dx <object>` in sources/haiku/generated.arm64 (a dry run); it is run
# from WORKTREE/generated.arm64-check, whose objects/ and build_packages/ are links to the main arm64 build's
# (generated headers, the C++ library headers), so ../src and ../headers are WORKTREE's. Output to a temp file.
# Prints "ok" or the compiler errors per file; exit 1 if any failed.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -ge 2 ] || { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
tree="$(realpath "$1")"; shift
main="$root/sources/haiku/generated.arm64"
[ -d "$main/objects" ] || { echo "arm64-compile-check: no $main/objects" >&2; exit 2; }
chk="$tree/generated.arm64-check"
mkdir -p "$chk"
ln -sfn "$main/objects" "$chk/objects"
ln -sfn "$main/build_packages" "$chk/build_packages"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/arm64cc.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
bad=0
for src in "$@"; do
	dir="$(dirname "$src")" base="$(basename "$src")"
	cmd=""
	# plain grist, or a multi-arch one (libroot, the runtime loader)
	for obj in "<${dir//\//!}>${base%.*}.o" "<${dir//\//!}!arm64>${base%.*}.o"; do
		cmd=$(cd "$main" && jam -n -a -dx "$obj" 2>/dev/null | grep -a -F "\"../$src\"" | head -n 1)
		[ -n "$cmd" ] && break
	done
	if [ -z "$cmd" ]; then
		echo "arm64-compile-check: $src: no compile line for $obj in the arm64 build"; bad=1; continue
	fi
	# the object goes to the temp directory
	cmd=$(printf '%s' "$cmd" | sed -E "s# -o \"?[^ \"]+\"?# -o $tmp/out.o#")
	if (cd "$chk" && eval "$cmd") > "$tmp/log" 2>&1; then
		echo "arm64-compile-check: $src: ok"
	else
		echo "arm64-compile-check: $src: FAILED"; sed 's/^/  /' "$tmp/log" | head -n 30; bad=1
	fi
done
exit $bad
