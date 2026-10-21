#!/usr/bin/env bash
# pi-ssh.sh — commands and files on the Pi of a running bench session (scripts/pi-session.sh start).
#
#   scripts/pi-ssh.sh CMD...                 run CMD in the Pi's shell (its output and exit status here)
#   scripts/pi-ssh.sh put LOCAL... REMOTE    copy files (or directories) to the Pi
#   scripts/pi-ssh.sh get REMOTE... LOCAL    copy files from the Pi
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
dir="$root/artifacts/pi-session"
[ -f "$dir/state" ] && . "$dir/state"
[ -n "${ip:-}" ] || { echo "pi-ssh: no session (scripts/pi-session.sh start)" >&2; exit 1; }
opts=(-i "$dir/id_ed25519" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no
	-o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ServerAliveInterval=15)
[ $# -gt 0 ] || { sed -n '4,6p' "$0" >&2; exit 2; }
case "$1" in
put)
	shift; [ $# -ge 2 ] || exit 2
	exec scp -r "${opts[@]}" "${@:1:$#-1}" "user@$ip:${!#}" ;;
get)
	shift; [ $# -ge 2 ] || exit 2
	srcs=(); for s in "${@:1:$#-1}"; do srcs+=("user@$ip:$s"); done
	exec scp -r "${opts[@]}" "${srcs[@]}" "${!#}" ;;
*)
	exec ssh "${opts[@]}" "user@$ip" "$@" ;;
esac
