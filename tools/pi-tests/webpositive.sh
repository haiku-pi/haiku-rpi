#!/bin/sh
# webpositive.sh — a UserBootscript for WebKit (HaikuWebKit 1.10: scripts/build-webkit.sh) over
# Ethernet (static address, the bench host as gateway): JavaScriptCore's shell with and without
# its JIT, then WebPositive opens a page over HTTPS; the HDMI frames show the rendered page. Serial
# console lines: "WPOS "; a crash shows as "debug_server:"/"DEBUGGER:" lines (the crashed team then
# waits in the debugger, hence the KILL timeouts).
sleep 25
out=/dev/dprintf
say() { echo "WPOS $*" > $out; }
url=https://www.haiku-os.org/
# no DHCP on the bench's Ethernet during SD cycles (the peer project's server is down): a static
# address, the host as the gateway (it masquerades 10.42.0.0/24), a public resolver
ifconfig /dev/net/genet/0 10.42.0.50 255.255.255.0 up
route add /dev/net/genet/0 inet default gw 10.42.0.1
mkdir -p /boot/system/settings/network
echo "nameserver 1.1.1.1" > /boot/system/settings/network/resolv.conf
sleep 3
# the boot's NTP sync ran before this static configuration: once more (no clock = no valid certificate)
/boot/system/preferences/Time --update > $out 2>&1
say "date: $(date)"
say "ifconfig: $(ifconfig /dev/net/genet/0 2>&1 | grep -a 'inet addr' | head -n 1)"
# ICU's data is in libicudata (scripts/build-icu.sh), not ICU_DATA
say "ICU_DATA=$ICU_DATA, packages: $(ls /packages | grep -a icu | tr '\n' ' ')"

# JavaScriptCore: the interpreter (LLInt) alone, then with the baseline/DFG/FTL JITs (the default);
# the loop runs long enough for every tier to compile it
js='var s = 0; for (var i = 0; i < 20000000; i++) s = (s + i * 7) % 1000003; print("sum " + s);'
run() { timeout -s KILL 120 env "$@"; }
say "jsc: $(run jsc -e 'print(6 * 7, Intl.supportedValuesOf("timeZone").length)' 2>&1 | tr '\n' ' ')"
t0=$(date +%s)
say "jsc nojit loop: $(run JSC_useJIT=false jsc -e "$js" 2>&1 | tr '\n' ' ') ($(( $(date +%s) - t0 )) s)"
t0=$(date +%s)
say "jsc jit loop: $(run jsc -e "$js" 2>&1 | tr '\n' ' ') ($(( $(date +%s) - t0 )) s)"

/boot/system/apps/WebPositive "$url" > /tmp/webpositive.txt 2>&1 &
sleep 90
say "webpositive: $(ps | grep -a '/apps/WebPositive' | grep -a -v grep | head -n 1 | tr -s ' ')"
say "webpositive output: $(tail -n 5 /tmp/webpositive.txt | tr '\n' ' ')"
say end
