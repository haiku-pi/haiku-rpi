#!/bin/sh
# threads.sh TEAM_ID — the team's thread IDs. `ps -a` prints each team's line (Id is 4 fields before the
# end) then its threads (Id 4 fields before the end too; names contain spaces).
ps -a | awk -v team="$1" '
	/^Team / {inteam = 0; next}
	/^Thread / {next}
	NF < 5 {next}
	!inteam && $(NF-3) == team && $(NF-2) ~ /^[0-9]+$/ {inteam = 1; got = 1; next}
	inteam && $(NF-3) ~ /^(wait|run|rdy|zzz|susp|dead)$/ {print $(NF-4); next}
	inteam {inteam = 0}'
