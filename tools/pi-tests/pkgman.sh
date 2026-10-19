#!/bin/sh
# pkgman.sh — a UserBootscript for our package repository (scripts/make-repo.sh, served by
# scripts/serve-repo.sh on the bench host): pkgman adds it, refreshes, lists what it offers and installs a
# package that is not in the image (fluidlite_devel: headers and development links).
# Ethernet with a static address, as web.sh. Serial console lines: "PKG ".
sleep 25
out=/dev/dprintf
say() { echo "PKG $*" > $out; }
repo=http://10.42.0.1:8090/arm64
ifconfig /dev/net/genet/0 10.42.0.50 255.255.255.0 up
route add /dev/net/genet/0 inet default gw 10.42.0.1
sleep 3
# the image's HaikuPorts config lists our packages (from the build) but points at Haiku's server, which
# has no arm64 HaikuPorts repository: without it, pkgman takes them from ours
say "drop-repo HaikuPorts: $(echo yes | pkgman drop-repo HaikuPorts 2>&1 | tr '\n' ' ')"
say "add-repo: $(pkgman add-repo $repo 2>&1 | tr '\n' ' ')"
say "refresh: $(pkgman refresh 2>&1 | tr '\n' ' ' | cut -c1-300)"
say "list-repos: $(pkgman list-repos 2>&1 | tr '\n' ' ' | cut -c1-300)"
say "search mesa: $(pkgman search -a mesa 2>&1 | tr '\n' ' ' | cut -c1-300)"
pkgman install -y fluidlite_devel < /dev/null > /tmp/pkgman.txt 2>&1
say "install fluidlite_devel: exit $?"
tail -n 25 /tmp/pkgman.txt | while read -r line; do say "  $line"; done
say "headers: $(ls /boot/system/develop/headers/ 2>&1 | grep -a -i fluid | tr '\n' ' ' | cut -c1-200)"
say "package: $(ls /boot/system/packages | grep -a fluidlite | tr '\n' ' ')"
say end
