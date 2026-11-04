#!/bin/sh
# core.sh — H22 test group THR + TLS + LIBC + VM (docs/design/x86-64-check.md §4.3) as a UserBootscript:
# scripts/x86-test.sh core IMAGE. The arch-neutral tests of our fixes, each graded PASS / FAIL / N/A by
# tools/x86-tests/lib.sh; serial lines "X86T core ...", the last "X86T core end", then power-off.
G=core
. /boot/home/x86t/lib.sh
waitfor -m application/x-vnd.Be-TRAK
cd $X86T_DIR || { say "info no $X86T_DIR"; finish; exit 1; }
say "info $(uname -a)"

# THR
t threadstress 900 'THREADSTRESS end 0 failures' ./threadstress 1000
loop rw_lock_interrupt_test 20 30 ./rw_lock_interrupt_test
t killrace 900 'KRL end 30 kills, 0 faults' sh ./kill-race-loop.sh 30 ./kill_race2
t castest 120 '!(strong|header) .*(lost=[1-9]|false=[1-9])' ./castest 3 4 1
t threadbench 300 - ./threadbench 2000 64
t forkbench 300 - ./forkbench 200
t spread 120 - ./spread

# TLS (scripts/build-tls-tests.sh: the libraries next to the programs)
cd $X86T_DIR/tls
export LIBRARY_PATH="%A:${LIBRARY_PATH:-%A/lib:/boot/home/config/non-packaged/lib:/boot/home/config/lib:/boot/system/non-packaged/lib:/boot/system/lib}"
t tlsstatic 120 'tlsstatic: PASS' ./tlsstatic
t tlsstatic-preload 120 'tlsstatic: PASS' env LD_PRELOAD_ADDONS=$X86T_DIR/tls/libtlsp.so ./tlsstatic -p
t tlsreload 120 'tlsreload: PASS' ./tlsreload ./libtlsr.so
t tlsunload 300 'tlsunload: PASS' ./tlsunload 200
t tlsbench 300 - ./tlsbench 20 ./libtlsbench2.so
cd $X86T_DIR

# LIBC
t strtold 300 'strtold: ok' ./strtold
t setrlimit 60 'setrlimit: ok' ./setrlimit
t strtest 600 'strtest: PASS' ./strtest
t polltest 60 'POLLTEST ok' ./polltest
t usercopy 120 'usercopy: PASS' ./usercopy /boot/system/lib/libroot.so
t relrtest 60 'relrtest: ok' ./relr/relrtest $X86T_DIR/relr
if ./membarrier 1 1 2> /dev/null | grep -q 'MEMBARRIER unavailable'; then
	say "result membarrier N/A rc=0 no _kern_team_memory_barrier on this system"
else
	t membarrier 600 'litmus team: 0 of' ./membarrier 20000 2000
fi

# VM
t mmap-shared-mprotect 120 PASS ./mmap-shared-mprotect
t fault-signal-blocked 120 'fault-signal-blocked: passed' ./fault-signal-blocked
t mprotect-unprotect-retry 120 PASS ./mprotect-unprotect-retry
finish
