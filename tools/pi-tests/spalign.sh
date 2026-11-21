#!/bin/sh
# spalign.sh — a UserBootscript that runs tools/haiku-tests/spalign (arm64 user-fault
# classification: an SP-alignment fault, an undefined instruction, __builtin_trap() and an SVE
# instruction must each give the program a signal, not panic the kernel — HK-01 and EC 0x26). Serial lines
# "SPALIGN ...", the last "SPALIGN end". scripts/spalign-image.sh puts it and the program on
# an image; boot it under scripts/qemu-virt.sh --image OUT.
sleep 15
out=/dev/dprintf
echo "SPALIGN $(uname -a)" > $out
cd /boot/home || { echo "SPALIGN no /boot/home" > $out; echo "SPALIGN end: FAIL" > $out; exit 1; }
./spalign > $out 2>&1
echo "SPALIGN program rc $?" > $out
