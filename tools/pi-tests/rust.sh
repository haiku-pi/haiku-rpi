#!/bin/sh
# rust.sh — a UserBootscript for the Rust cross toolchain (scripts/build-rust.sh): its test programs
# from artifacts/rust-tests/non-packaged (scripts/mkimage-pi4.sh --add-tree) run on the Pi.
#   rust-smoke      Rust std: args, env, threads, fs, TCP (loopback echo; connect timeout to an
#                   unreachable address), time, panic unwinding, HashMap, child process
#   rust-c-static   C calling a Rust staticlib (threads, unwinding, HashSet, fs inside Rust)
#   rust-c-shared   the same C program with the Rust cdylib (non-packaged/lib/librust_clib.so)
# Serial console lines: "RST "; per program "RST <name> PASS" or "RST <name> FAIL exit N".
sleep 20
out=/dev/dprintf
say() { echo "RST $*" > $out; }
bin=/boot/system/non-packaged/bin
cd /tmp || exit 1
# no DHCP on the bench's Ethernet during SD cycles: the connect-timeout check needs an interface
# with a route, else the connect fails at once (ENETUNREACH; that is accepted too)
ifconfig /dev/net/genet/0 10.42.0.50 255.255.255.0 up > $out 2>&1
route add /dev/net/genet/0 inet default gw 10.42.0.1 > $out 2>&1
run() {
	name=$1
	shift
	say "$name: start"
	"$bin/$name" "$@" > /tmp/$name.txt 2>&1
	status=$?
	while IFS= read -r line; do say "$line"; done < /tmp/$name.txt
	if [ $status -eq 0 ]; then say "$name PASS"; else say "$name FAIL exit $status"; fi
}
run rust-smoke alpha beta
run rust-c-static
run rust-c-shared
say end
