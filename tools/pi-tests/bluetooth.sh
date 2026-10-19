#!/bin/sh
# bluetooth.sh — a UserBootscript for the on-board Bluetooth driver (drivers/bluetooth/h4/bcm2711_bt:
# the BCM43455's Bluetooth on the AUX mini-UART, GPIO 30-33). The driver logs its bring-up to the
# serial console ("bcm2711_bt: " lines: UART routing, core clock and baud, BT_ON, HCI_Reset, local
# version, patch records sent/acknowledged, BD_ADDR); every open runs it from power-on.
#  1. opens the device alone (cat): the bring-up without the stack;
#  2. starts bluetooth_server (nothing launches it at boot), which finds /dev/bluetooth/h4/*/0,
#     opens it again, registers it with the stack and sends BT_UP; its output goes to the console;
#  3. btinquiry (tools/bt-tests, installed with --add-bin): the local device through the server
#     (address, name, class), then an inquiry (~10 s).
# Serial console lines: "BT ", "BTQ ", "bcm2711_bt: " and the server's own output.
sleep 20
out=/dev/dprintf
say() { echo "BT $*" > $out; }
say "begin $(uname -a)"
say "driver: $(ls /boot/system/add-ons/kernel/drivers/dev/bluetooth/h4 2>&1 | tr '\n' ' ')"
say "patch: $(ls -l /boot/system/non-packaged/data/firmware/brcm/BCM4345C0.hcd 2>&1)"

# devfs loads the driver when /dev/bluetooth/h4 is read (created here as the server does it, it may
# not exist yet); the bring-up runs at open (~7 s at 115200)
mkdir -p /dev/bluetooth/h4 2>/dev/null
say "devices: $(ls -R /dev/bluetooth 2>&1 | tr '\n' ' ')"
say "open alone: start $(date +%T)"
cat /dev/bluetooth/h4/bcm2711_bt/0 > /dev/null 2>&1
say "open alone: exit $? at $(date +%T)"
sleep 2

if ps | grep -q '[b]luetooth_server'; then
	say "bluetooth_server already running"
else
	say "starting bluetooth_server"
	/boot/system/servers/bluetooth_server > $out 2>&1 &
fi
sleep 20
say "server: $(ps | grep '[b]luetooth_server' | tr -s ' ' | cut -c1-120)"
say "devices: $(ls -R /dev/bluetooth 2>&1 | tr '\n' ' ')"

tool=/boot/home/config/non-packaged/bin/btinquiry
if [ -x $tool ]; then
	$tool -t 8 > $out 2>&1 &
	pid=$!
	sleep 45
	if kill $pid 2>/dev/null; then
		say "btinquiry did not finish in 45 s"
	else
		say "btinquiry finished"
	fi
else
	say "no $tool (mkimage-pi4.sh --add-bin artifacts/bt-tests/btinquiry)"
fi

grep -a -E 'bcm2711_bt|bluetooth_server|LocalDevice|DeviceManager' /var/log/syslog | tail -n 40 | while read -r line; do
	say "syslog: $line"
done
say end
