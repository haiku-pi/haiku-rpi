#!/bin/sh
# tls-tests.sh — the thread-local storage tests (scripts/build-tls-tests.sh) from /boot/home/tls: tlsstatic
# (also with an add-on preloaded by LD_PRELOAD_ADDONS that uses its TLS in its init routine), tlsreload,
# tlsunload, then tlsbench. As a UserBootscript (QEMU: scripts/image-add.sh ... tls-tests.sh:
# /boot/home/config/settings/boot/UserBootscript) its lines go to the serial console, "TLST ...", the last
# "TLST end failures=N"; then the system shuts down. Over ssh: TLST_OUT=- (standard output) TLST_NO_SHUTDOWN=1.
[ -n "${TLST_NO_SHUTDOWN:-}" ] || sleep 5
out=${TLST_OUT:-/dev/dprintf}
say() { if [ "$out" = - ]; then echo "$@"; else echo "$@" > $out; fi; }
cd /boot/home/tls || { say "TLST no /boot/home/tls"; exit 1; }
export LIBRARY_PATH="%A:${LIBRARY_PATH:-%A/lib:/boot/home/config/non-packaged/lib:/boot/home/config/lib:/boot/system/non-packaged/lib:/boot/system/lib}"
failures=0
run() {
	r=$("$@" 2>&1)
	rc=$?
	echo "$r" | while read -r l; do say "TLST $l"; done
	say "TLST rc=$rc: $*"
	[ $rc = 0 ] || failures=$((failures + 1))
}
run ./tlsstatic
run env LD_PRELOAD_ADDONS=/boot/home/tls/libtlsp.so ./tlsstatic -p
run ./tlsreload ./libtlsr.so
run ./tlsunload 200
run ./tlsbench 20 ./libtlsbench2.so
say "TLST end failures=$failures"
[ -n "${TLST_NO_SHUTDOWN:-}" ] || { sleep 2; shutdown -q; }
exit $failures
