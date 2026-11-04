#!/bin/sh
# n5-tls.sh — the measurements of H20 item N5 (thread-local storage through __tls_get_addr,
# docs/design/perf-round-h20.md "N5 results"), over ssh in a Pi session on a fresh boot, from /boot/home/tls
# (scripts/build-tls-tests.sh; copy with scripts/pi-ssh.sh put DIR /boot/home/):
#
#   scripts/pi-ssh.sh sh /boot/home/tls/n5-tls.sh LABEL
#
# Lines "N5 LABEL ...": the TLS tests (tls-tests.sh), tlsbench (ns per access: a library the program links,
# a dlopen()ed copy) three times, python3 -m timeit "sum(i*i for i in range(1000000))" five times, the wall
# time of python3 -c "sum(i*i for i in range(10**7))" five times, then that command twice under pmustat -u (cycles, instructions) and under profile -k -S
# (its header and top lines, and __tls_get_addr's line). The profile is left in /tmp/n5-py-LABEL.prof.
label=${1:-run}
cd /boot/home/tls || exit 1
export LIBRARY_PATH="%A:${LIBRARY_PATH:-%A/lib:/boot/home/config/non-packaged/lib:/boot/home/config/lib:/boot/system/non-packaged/lib:/boot/system/lib}"
say() { echo "N5 $label $*"; }
say "image: $(uname -a | cut -c1-100)"
TLST_OUT=- TLST_NO_SHUTDOWN=1 sh ./tls-tests.sh | while read -r l; do say "$l"; done
for i in 1 2 3; do say "$(./tlsbench 50 ./libtlsbench2.so | tr '\n' ' ')"; done
for i in 1 2 3 4 5; do say "timeit: $(python3 -m timeit 'sum(i*i for i in range(1000000))')"; done
for i in 1 2 3 4 5; do
	s=$(date +%s%N 2>/dev/null)
	python3 -c 'sum(i*i for i in range(10**7))'
	e=$(date +%s%N 2>/dev/null)
	say "sum 1e7 wall: $(( (e - s) / 1000000 )) ms"
done
# instructions and cycles of the same command, user mode (the second tool next to the profile)
for i in 1 2; do
	pmustat -u -e cpu_cycles,inst_retired,br_mis_pred python3 -c 'sum(i*i for i in range(10**7))' 2>&1 \
		| grep -a -E 'cpu_cycles|inst_retired|br_mis_pred|elapsed' | while read -r l; do say "pmu $i: $l"; done
done
prof=/tmp/n5-py-$label.prof
profile -k -S -i 1000 -o $prof python3 -c 'sum(i*i for i in range(10**7))' > /dev/null 2>&1
grep -a -E 'total ticks|unknown ticks' $prof | while read -r l; do say "profile: $l"; done
grep -a -E '^ +[0-9]+ +[0-9]+ +[0-9.]+ ' $prof | head -n 8 | while read -r l; do say "profile: $l"; done
say "profile: $(grep -a '__tls_get_addr' $prof | head -n 1)"
say "end"
