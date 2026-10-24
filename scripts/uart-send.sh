#!/usr/bin/env bash
# uart-send.sh — type text into the Pi's serial line while a cycle (sd-cycle.sh, netboot-cycle.sh, a
# pi-session) is capturing it: each argument is "OFFSET:TEXT" (Python escapes; OFFSET seconds from now),
# handed to the running uart-capture.py through its --inbox directory.
#
#   scripts/uart-send.sh '0:\x1d\x1d\x1dd' '3:threads\n'      (the kernel debugger, then a command)
#   scripts/uart-send.sh --kdl                                  (break in; each CPU's stack crawl, ICIs,
#                                                                interrupts, the threads; no continue)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
inbox="$root/artifacts/uart/inbox"
mkdir -p "$inbox"
if [ "${1:-}" = --kdl ]; then
	set -- '0:\x1d\x1d\x1dd'
	for cpu in 0 1 2 3; do
		set -- "$@" "$((4 + cpu * 4)):cpu $cpu\n" "$((5 + cpu * 4)):bt\n"
	done
	set -- "$@" '22:ici\n' '25:ints\n' '28:threads\n'
fi
[ $# -gt 0 ] || { echo "usage: $0 OFFSET:TEXT... | --kdl" >&2; exit 2; }
tmp="$inbox/.send-$$"
printf '%s\n' "$@" > "$tmp"
mv "$tmp" "$inbox/send-$(date +%s%N)"
echo "uart-send: $# texts queued (the capture picks them up within 0.2 s; see its log)"
