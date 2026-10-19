#!/bin/sh
# showcase.sh — a UserBootscript that arranges a desktop for screenshots (the HDMI frames): About Haiku
# (processor, cores, memory), ActivityMonitor, a Terminal with the hardware (the board the firmware
# reports, uname, sysinfo, the SoC's temperature and clocks), WebPositive on haiku-os.org, GLTeapot on
# the V3D; then Quake II (with --add-tree artifacts/games/non-packaged). Windows are placed with hey.
# Serial console lines: "SHOW ".
sleep 25
out=/dev/dprintf
say() { echo "SHOW $*" > $out; }
# the bench's Ethernet: a static address, the host as the gateway (no DHCP during SD cycles)
ifconfig /dev/net/genet/0 10.42.0.50 255.255.255.0 up
route add /dev/net/genet/0 inet default gw 10.42.0.1
mkdir -p /boot/system/settings/network
echo "nameserver 1.1.1.1" > /boot/system/settings/network/resolv.conf
/boot/system/preferences/Time --update > /dev/null 2>&1

# place APP's first window: x y width height
place() {
	hey "$1" set Frame of Window 0 to "BRect($2,$3,$(($2 + $4)),$(($3 + $5)))" > /dev/null 2>&1 \
		|| say "place $1 failed"
}

cat > /tmp/hw.sh <<'HW'
#!/bin/sh
echo "== uname -a =="
uname -a
echo
echo "== sysinfo =="
sysinfo 2>&1 | head -n 22
echo
echo "== the board, temperature and clocks (VideoCore firmware) =="
cat /dev/power/bcm2835_thermal/0
echo
# the GPU powers on with its first client (GLTeapot, started meanwhile)
sleep 15
echo "== GPU =="
grep -a -m 1 'V3D: core ident' /var/log/syslog | sed 's/.*V3D: core ident \([^,]*\).*clock \([0-9]* MHz\).*/V3D 4.2 (ident \1), \2/'
echo
exec sh
HW
chmod +x /tmp/hw.sh

/boot/system/apps/WebPositive https://www.haiku-os.org/ > /dev/null 2>&1 &
/boot/system/apps/Terminal -t "Raspberry Pi 4 — the hardware" /tmp/hw.sh > /dev/null 2>&1 &
/boot/system/apps/ActivityMonitor > /dev/null 2>&1 &
/boot/system/apps/AboutSystem > /dev/null 2>&1 &
sleep 5
teapot=/boot/system/demos/GLTeapot
[ -x "$teapot" ] || teapot=/boot/system/non-packaged/apps/GLTeapot
"$teapot" > /dev/null 2>&1 &
sleep 25
place WebPositive 10 30 900 650
place GLTeapot 10 712 430 330
place ActivityMonitor 458 712 492 330
place Terminal 975 30 795 515
place AboutSystem 975 577 650 468
say "desktop arranged"
sleep 60
say "phase 1 done"

if [ -x /boot/system/non-packaged/apps/quake2/Quake2 ]; then
	cd /boot/system/non-packaged/apps/quake2
	./Quake2 +set vid_renderer gl1 +set r_mode -1 +set r_customwidth 800 +set r_customheight 600 \
		+set vid_fullscreen 0 > /dev/null 2>&1 &
	sleep 25
	place Quake2 975 445 800 600
	say "quake2 placed"
	sleep 60
fi
say end
