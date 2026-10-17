#!/usr/bin/env bash
# snapshot-state.sh <step-name> — write manifests/<date>-<step>.md recording the SHA, branch and
# dirtiness of every repo (coordination + sources/*), the rollback point for a validated step.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
step="${1:?usage: $0 <step-name>}"
out="$root/manifests/$(date +%Y-%m-%d)-$step.md"
{
	echo "# $step — $(date -Iseconds)"
	echo
	echo "| repo | branch | sha | dirty |"
	echo "|---|---|---|---|"
	for r in "$root" "$root"/sources/*/; do
		[ -d "$r/.git" ] || continue
		name="$(basename "$r")"; [ "$r" = "$root" ] && name=coordination
		dirty="$(git -C "$r" status --porcelain --untracked-files=no | wc -l)"
		echo "| $name | $(git -C "$r" rev-parse --abbrev-ref HEAD) | $(git -C "$r" rev-parse HEAD) | $dirty |"
	done
} > "$out"
echo "$out"
