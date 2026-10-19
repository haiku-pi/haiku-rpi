#!/bin/sh
# web.sh — a UserBootscript for the web stack (OpenSSL 3, curl, NetSurf: scripts/build-netsurf.sh) over
# Ethernet (static address, the bench host as gateway): curl fetches a page over HTTPS (certificate check against ca_root_certificates), then
# NetSurf opens it; the HDMI frames show the rendered page. Serial console lines: "WEB ".
sleep 25
out=/dev/dprintf
say() { echo "WEB $*" > $out; }
url=https://www.haiku-os.org/
# no DHCP on the bench's Ethernet during SD cycles (the peer project's server is down): a static
# address, the host as the gateway (it masquerades 10.42.0.0/24), a public resolver
ifconfig /dev/net/genet/0 10.42.0.50 255.255.255.0 up
route add /dev/net/genet/0 inet default gw 10.42.0.1
mkdir -p /boot/system/settings/network
echo "nameserver 1.1.1.1" > /boot/system/settings/network/resolv.conf
sleep 3
# the boot's NTP sync ran before this static configuration: once more (no clock = no valid certificate)
say "date before: $(date)"
/boot/system/preferences/Time --update > $out 2>&1
say "date after: $(date)"
say "ifconfig: $(ifconfig /dev/net/genet/0 2>&1 | grep -a 'inet addr' | head -n 1)"
say "curl: $(curl -s -o /tmp/page.html -w '%{http_code} %{ssl_verify_result} %{size_download} bytes in %{time_total} s' $url 2>&1)"
say "curl -v: $(curl -sv -o /dev/null $url 2>&1 | grep -a -i -E 'SSL connection|issuer|subject:' | head -n 3 | tr '\n' ' ')"
/boot/system/apps/NetSurf $url > /tmp/netsurf.txt 2>&1 &
sleep 60
say "netsurf output: $(tail -n 5 /tmp/netsurf.txt | tr '\n' ' ')"
say end
