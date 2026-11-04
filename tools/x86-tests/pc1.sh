#!/bin/sh
# pc1.sh — H22 FS power cut, first half (docs/design/x86-64-check.md §4.3): mounts the scratch disk and writes
# metadata without end (bfsmeta --loop, the oldest of 3000 files removed as new ones come); scripts/x86-test.sh
# cuts the power (QMP quit, the qemu-x86.sh --until) after the "loop" progress line it waits for. pc2.sh then
# mounts the volume (journal replay) and checks it. Serial lines "X86T pc1 ...".
G=pc1
. /boot/home/x86t/lib.sh
waitfor -m application/x-vnd.Be-TRAK
cd $X86T_DIR || exit 1
mount_scratch
say "result armed PASS rc=0 on $scratch_dev"
say end
rm -rf /scratch/pc.*
./bfsmeta --loop /scratch/pc.$$ 3000 2>&1 | while IFS= read -r l; do say "info loop $l"; done
