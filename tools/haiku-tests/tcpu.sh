#!/bin/sh
# tcpu.sh TEAM_ID [SECS] — the team's threads that used CPU over SECS (default 10): id, name, user ms
snap() {
	ps -a | awk -v team="$1" '
		/^Team / {inteam = 0; next}
		/^Thread / {next}
		NF < 5 {next}
		!inteam && $(NF-3) == team && $(NF-2) ~ /^[0-9]+$/ {inteam = 1; next}
		inteam && $(NF-3) ~ /^(wait|run|rdy|zzz|susp|dead)$/ {n = $0; sub(/ +[0-9]+ +[a-z]+ +[0-9]+ +[0-9]+ +[0-9]+ *$/, "", n); print $(NF-4) "\t" $(NF-1) "\t" n; next}
		inteam {inteam = 0}'
}
snap "$1" | sort > /tmp/tcpu.a
sleep "${2:-10}"
snap "$1" | sort > /tmp/tcpu.b
join -t "$(printf '\t')" /tmp/tcpu.a /tmp/tcpu.b | awk -F '\t' '{d = $4 - $2; if (d > 0) printf "%s %s %d ms\n", $1, $3, d / 1000}' | sort -k3 -n -r | head -8
