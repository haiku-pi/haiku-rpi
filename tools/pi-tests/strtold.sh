#!/bin/sh
# strtold.sh — a UserBootscript for the long double conversion test tools/haiku-tests/strtold.c
# (/boot/home/strtold: strtold, wcstold, sscanf %Lf, printf %Lg, round trips; see there). For QEMU
# (scripts/qemu-virt.sh --image IMG) or the Pi. Serial lines "STRTOLD ...", the last
# "STRTOLD end rc=N" (0: ok); then the system shuts down.
sleep 5
out=/dev/dprintf
/boot/home/strtold ${STRTOLD_ARGS:-} > /tmp/strtold.txt 2>&1
rc=$?
sed 's/^/STRTOLD /' /tmp/strtold.txt > $out
echo "STRTOLD end rc=$rc" > $out
sleep 2
shutdown -q
