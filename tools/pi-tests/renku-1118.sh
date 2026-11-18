#!/bin/sh
# renku-1118.sh — on the Pi, in a bench session (scripts/pi-ssh.sh), from the directory holding schedmode and
# swapfloat (tools/haiku-tests/): checks for the RenkuOS fixes ported 2026-11-18 (docs/design/renkuos-fixes.md).
#
#   sh renku-1118.sh [DIR]
#
#   swap    B_SWAP_FLOAT/B_SWAP_DOUBLE return the swapped value (PR #477)
#   sched   power-saving scheduler mode under load on three CPUs while CPU 0 goes idle, and the mode switched back
#           and forth under load: the IRQ packing loop could spin with the scheduler lock held (5de6fe7, f883abc).
#           Each step prints the time; a frozen system stops printing (the ssh session then times out)
#   ints    the GIC's SGIs and PPIs now registered as local interrupts (4a763f8): the PMU's PPI still counts
#   tcp     200 short TCP connections to the bench host's ssh port (endpoint teardown, bdecbeb)
# Lines start with "RNK "; the run ends with "RNK result: N problems".
dir=${1:-/boot/home/rnk}
cd "$dir" || exit 1
problems=0
say() { echo "RNK $*"; }
fail() { say "FAIL: $*"; problems=$((problems + 1)); }

# swap
./swapfloat | sed 's/^/RNK /' || fail "swapfloat"

# sched
say "sched start $(./schedmode)"
pids=""
for i in 1 2 3; do sh -c 'while :; do :; done' & pids="$pids $!"; done
./schedmode 1 | sed 's/^/RNK sched /'
for i in $(seq 1 15); do sleep 2; say "sched power-saving alive $i $(date +%T)"; done
for i in $(seq 1 20); do ./schedmode $((i % 2)) > /dev/null || fail "schedmode switch $i"; sleep 0.5; done
say "sched switched 20 times, alive $(date +%T)"
./schedmode 1 > /dev/null
kill $pids 2> /dev/null
for i in $(seq 1 10); do sleep 2; say "sched power-saving idle alive $i $(date +%T)"; done
./schedmode 0 | sed 's/^/RNK sched end /'

# ints: the PMU's per-CPU interrupt (a PPI) and the timer still work with PPIs registered as local
pmustat -A sleep 1 2>&1 | head -4 | sed 's/^/RNK ints pmustat /'
say "ints cpus: $(sysinfo -cpu 2> /dev/null | head -1)"

# tcp: short connections to the host (its ssh port answers and closes)
host=${RNK_HOST:-10.42.0.1}
ok=0
for i in $(seq 1 200); do
	if timeout 5 bash -c "exec 3<>/dev/tcp/$host/22 && head -c 7 <&3" 2> /dev/null | grep -q SSH; then
		ok=$((ok + 1))
	fi
done
say "tcp short connections: $ok of 200"
[ "$ok" -ge 195 ] || fail "tcp: only $ok of 200 connections"

say "result: $problems problems"
