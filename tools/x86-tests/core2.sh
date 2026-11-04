#!/bin/sh
# core2.sh — the part of tools/x86-tests/core.sh an image without our fixes never reaches (there, threadstress
# hangs: every one of its tests churns threads first; and usercopy panics the kernel): DT_RELR, the team memory
# barrier, the VM tests, and usercopy last. Serial lines "X86T core2 ...".
G=core2
. /boot/home/x86t/lib.sh
waitfor -m application/x-vnd.Be-TRAK
cd $X86T_DIR || { finish; exit 1; }
say "info $(uname -a)"
t relrtest 60 'relrtest: ok' ./relr/relrtest $X86T_DIR/relr
if ./membarrier 1 1 2> /dev/null | grep -q 'MEMBARRIER unavailable'; then
	say "result membarrier N/A rc=0 no _kern_team_memory_barrier on this system"
else
	t membarrier 600 'litmus team: 0 of' ./membarrier 20000 2000
fi
t mmap-shared-mprotect 120 PASS ./mmap-shared-mprotect
t fault-signal-blocked 120 'fault-signal-blocked: passed' ./fault-signal-blocked
t mprotect-unprotect-retry 120 PASS ./mprotect-unprotect-retry
t usercopy 120 'usercopy: PASS' ./usercopy /boot/system/lib/libroot.so
finish
