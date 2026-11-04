#!/bin/sh
# tlsperf.sh — tlsbench five times in one boot (the thread-local access cost through __tls_get_addr; H22 §9.3).
# Serial lines "X86T tlsperf ...".
G=tlsperf
. /boot/home/x86t/lib.sh
waitfor -m application/x-vnd.Be-TRAK
sleep 10
cd $X86T_DIR/tls || { finish; exit 1; }
export LIBRARY_PATH="%A:${LIBRARY_PATH:-%A/lib:/boot/home/config/non-packaged/lib:/boot/home/config/lib:/boot/system/non-packaged/lib:/boot/system/lib}"
for i in 1 2 3 4 5; do
	t tlsbench-$i 300 - ./tlsbench 20 ./libtlsbench2.so
done
finish
