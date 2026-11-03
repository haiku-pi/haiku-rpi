#!/bin/sh
# startcost-steps.sh — over ssh on a fresh Pi session (scripts/pi-session.sh): the cost of a program start
# (tools/haiku-tests/forkbench.c in /boot/home: fork+exit, fork+exec of /bin/true, posix_spawn) after each step of a
# desktop session, to find the step after which process start gets slower (H20 C0: 4.6 → 7.9 ms after a
# session on 11-03c). Needs /boot/home/forkbench and the STK packages in /boot/home (*.hpkg).
# Lines "SCS <step> | forkbench ... | teams N | areas N".
cd /boot/home || exit 1
export HOME=/boot/home
measure() {
	f=$(./forkbench 100 | grep -v thread | awk '{ printf "%s %s ", $2, $3 }')
	echo "SCS $1 | $f | teams $(ps | wc -l) | areas $(listarea 2> /dev/null | wc -l)"
}
measure fresh
ls config/settings > /tmp/scs-settings-0.txt
pkgman install -y ./supertuxkart*.hpkg > /dev/null 2>&1
measure after-pkgman
/boot/system/apps/Terminal > /dev/null 2>&1 &
sleep 5
measure terminal-open
hey Terminal quit > /dev/null 2>&1
/boot/system/apps/Firefox/Firefox --new-window https://www.haiku-os.org/ > /dev/null 2>&1 &
sleep 45
measure firefox-open
hey Firefox quit > /dev/null 2>&1
sleep 10
measure firefox-quit
(cd /boot/system/apps/SuperTuxKart && ./SuperTuxKart --windowed --screensize=1024x576 > /dev/null 2>&1 &)
sleep 40
measure stk-open
kill $(ps | awk '$1 ~ /SuperTuxKart$/ { print $2 }') 2> /dev/null
sleep 5
measure stk-quit
ls config/settings > /tmp/scs-settings-1.txt
echo "SCS new settings: $(comm -13 /tmp/scs-settings-0.txt /tmp/scs-settings-1.txt | tr '\n' ' ')"
echo "SCS env LANG=${LANG:-} LC_ALL=${LC_ALL:-}"
