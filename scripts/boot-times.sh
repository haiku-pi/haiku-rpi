#!/usr/bin/env bash
# boot-times.sh LOG... — boot milestones of SD-boot serial logs (artifacts/uart), from the capture's own
# line stamps: the boot loader's banner, the kernel's first line, the boot volume mounted and the display
# driver's hardware cursor (app_server has set its mode), each in seconds after the loader's banner.
#   loader 0.00  kernel 1.20  bootvol 2.61  cursor 7.62  <log>
set -euo pipefail
[ $# -gt 0 ] || { sed -n '2,5p' "$0" >&2; exit 2; }
for log in "$@"; do
	awk -v name="$log" '
		function stamp(line) { return substr(line, 2, index(line, "]") - 2) + 0 }
		!l && /to the Haiku boot loader/ { l = stamp($0) }
		l && !k && /Welcome to kernel debugger output/ { k = stamp($0) }
		l && !b && /Mounted boot partition/ { b = stamp($0) }
		l && !c && /hardware cursor shown/ { c = stamp($0) }
		END {
			if (!l) { print "no loader banner  " name; exit }
			printf "loader 0.00  kernel %.2f  bootvol %.2f  cursor %.2f  %s\n",
				k ? k - l : -1, b ? b - l : -1, c ? c - l : -1, name
		}' "$log"
done
