#!/bin/sh
# pmustat.sh — a UserBootscript for the CPU's hardware performance counters: the arm64_pmu driver
# (/dev/misc/pmu, haiku src/add-ons/kernel/drivers/misc/arm64_pmu) and pmustat (src/bin/pmustat,
# "perf stat -a" for Haiku), counted system-wide on all four Cortex-A72 cores. Image (any image built
# from haiku rpi4 >= d6580d9550 has both in the haiku package):
#   scripts/mkimage-pi4.sh --in sources/haiku/generated.arm64/haiku-mmc.image \
#       --bootscript tools/pi-tests/pmustat.sh --out artifacts/images/haiku-pi4-pmustat.img
# or into an existing image without a rebuild (scripts/build.sh arm64_pmu pmustat first):
#   o=sources/haiku/generated.arm64/objects/haiku/arm64/release
#   scripts/image-add.sh IMG artifacts/images/pmustat.img \
#       $o/add-ons/kernel/drivers/misc/arm64_pmu/arm64_pmu:/boot/system/non-packaged/add-ons/kernel/drivers/dev/misc/arm64_pmu \
#       $o/bin/pmustat/pmustat:/boot/system/non-packaged/bin/pmustat \
#       tools/pi-tests/pmustat.sh:/boot/home/config/settings/boot/UserBootscript
# (QEMU virt works too: scripts/qemu-virt.sh --image IMG --secs 240; its cortex-a72 has a PMUv3 with
# 6 counters but implements only sw_incr and cpu_cycles (inst_retired with "-- -icount shift=0"),
# so pmustat says "not implemented by this CPU" for the rest; its cycle counter runs at 1 GHz whether
# a CPU is idle or not, so "MHz while busy" means nothing there. 10-25: all steps ran; spin5's
# cpu_cycles event counter, 32 bits, summed 5.0e9 per CPU = the cycle counter, so the wrap handling
# works; -u + -k = the unfiltered count; the second opener got "Device/File/Resource busy".)
# Read first: the syslog line's counter count. "0 event counters" means the firmware's MDCR_EL2.HPMN
# hides them from EL1 (haiku_loader's drop_to_el1 does not set MDCR_EL2), not a driver fault.
# Serial console lines: "PMU "; "PMU <step>: <pmustat's output line>"; "PMU end".
# Positive markers: "arm64_pmu: PMUv3 (version 1), 6 event counters, 4 CPUs" (syslog); "list:" lines
# saying which events the core implements; for each step a "cycles" line and the events with counts
# > 0 (on the Pi: idle — CPUs busy a few %, MHz while busy near the minimum clock; dd — IPC ~1-2,
# kernel-heavy (the "-k" run near the plain one, "-u" small); copy-64M — L1D refills ~1/16 of
# l1d_cache-ish and L2 refills high; copy-16K — L1D/L2 miss rates near 0; spin5 — cycles ≈ 4 CPUs ×
# 5 s × clock (counters sampled across the 32-bit wrap: no "could not sample" line); busy: the
# second opener gets "/dev/misc/pmu: Device/File/Resource busy"). sd-cycle.sh --secs 180 covers it.
sleep ${PMU_DELAY:-20}
out=/dev/dprintf
say() { echo "PMU $*" > $out; }
run() {
	step=$1; shift
	say "$step: \$ pmustat $*"
	pmustat "$@" 2>&1 | while IFS= read -r line; do
		[ -n "$line" ] && say "$step: $line"
	done
}

say "start $(uname -a)"
grep -a "arm64_pmu" /var/log/syslog | tail -n 3 | while read -r l; do say "syslog: $l"; done
ls -l /dev/misc/pmu 2>&1 | while read -r l; do say "dev: $l"; done
pmustat -l 2>&1 | head -n 48 | while IFS= read -r l; do say "list: $l"; done

run idle -A -a 2
run dd dd if=/dev/zero of=/dev/null bs=1M count=2000
run dd-user -u dd if=/dev/zero of=/dev/null bs=1M count=2000
run dd-kernel -k dd if=/dev/zero of=/dev/null bs=1M count=2000
run dd-mem -e mem_access,bus_access,l1d_tlb_refill,l1i_cache_refill,exc_svc,exc_irq \
	dd if=/dev/zero of=/dev/null bs=64k count=20000
if command -v python3.14 > /dev/null 2>&1; then
	# memcpy: 64 MiB buffers (DRAM-bound) and 16 KiB ones (in the 32 KiB L1D), the same bytes copied
	run copy-64M python3.14 -c 'b = bytearray(64 << 20)
for i in range(16): bytes(b)'
	run copy-16K python3.14 -c 'b = bytearray(16 << 10)
for i in range(65536): bytes(b)'
	run branches -e inst_retired,br_pred,br_mis_pred,cpu_cycles,stall_frontend,stall_backend \
		python3.14 -c 'import random
r = random.Random(1); n = 0
for i in range(2000000):
	if r.random() < 0.5: n += 1'
else
	say "no python3.14: copy and branch steps skipped"
fi

# 4 busy loops for 5 s: several 32-bit wraps of every counter (the driver samples them every 0.2 s)
pids=""
for i in 1 2 3 4; do sh -c 'while :; do :; done' & pids="$pids $!"; done
run spin5 -A -e inst_retired,cpu_cycles,br_mis_pred,l1d_cache -a 5
kill $pids

# one opener at a time: the second run must be refused while the first counts
pmustat -a 3 > /dev/null 2>&1 &
sleep 1
run busy -a 0.5
wait

say end
