#!/bin/sh
# castest.sh — UserBootscript for the strong compare-and-swap check (design/renkuos-fixes.md): castest
# (tools/haiku-tests/castest.c) three times with one noise thread and three without, rw_lock_interrupt_test 20 times, then threadstress
# (tools/haiku-tests/threadstress.c); the binaries in /boot/home (netboot-cycle.sh --add). Serial lines "CAS ...",
# the last "CAS end".
out=/dev/dprintf
say() { echo "CAS $*" > $out; }
sleep 20
cd /boot/home || exit 1
ds=/boot/home/config/settings/system/debug_server/settings
if [ ! -e $ds ]; then
	mkdir -p $(dirname $ds)
	printf 'executable_actions {\n\tthreadstress log\n\tcastest log\n\trw_lock_interrupt_test log\n}\n' > $ds
fi
for run in 1 2 3; do
	./castest 3 4 1 2>&1 | while read -r line; do say "run $run noise 1 $line"; done
	./castest 3 4 0 2>&1 | while read -r line; do say "run $run noise 0 $line"; done
done
pass=0
for run in $(seq 1 20); do
	./rw_lock_interrupt_test > /tmp/rwl.txt 2>&1 && pass=$((pass + 1))
done
say "rw_lock_interrupt_test passed $pass of 20; last: $(tr '\n' ' ' < /tmp/rwl.txt)"
./threadstress 3000 2>&1 | while read -r line; do say "$line"; done
say end
