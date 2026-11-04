/*
 * usbport.cpp — send PORT_POWER (or PORT_RESET) requests to a hub port through usb_raw, to make the device
 * behind it drop off its port without anyone touching it (task 116: the SuperSpeed stick that reconnected during
 * the N6 "basepc3" boot, design/usb-storage-integrity.md "Follow-ups").
 * What it does on the Pi 4 (VL805): on the root hub's SuperSpeed port 2, PORT_POWER off/on makes the stick
 * enumerate again on the USB 2 side (hub 7, port 1) while the hub explorer never sees the SuperSpeed device go:
 * its usb_disk stays, every command to it failing ("ghost" device). On the VL805's USB 2 hub (/dev/bus/usb/0/0/hub)
 * a power cycle is reported as a removal and a new connection, as from a real unplug.
 *
 *   usbport HUB PORT off|on|reset          one request (HUB: e.g. /dev/bus/usb/0/hub; PORT: 1-based)
 *   usbport HUB PORT cycle OFF_MS [N [GAP_MS]]
 *                                          N times (default 1): power off, wait OFF_MS, power on, wait GAP_MS
 *                                          (default 3000); a short OFF_MS lets the explorer see only a
 *                                          new connection on a port that still has its old device
 *
 * Build (cross):
 *   g=sources/haiku/generated.arm64
 *   $g/cross-tools-arm64/bin/aarch64-unknown-haiku-g++ --sysroot=artifacts/sysroot-arm64 -O2 \
 *     -o usbport tools/haiku-tests/usbport.cpp -ldevice
 */
#include <USBKit.h>

#include <OS.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>


// USB 2.0 §11.24 (hub class requests to a port)
static const uint8 kRequestTypeClassOtherOut = 0x23;
static const uint8 kClearFeature = 1;
static const uint8 kSetFeature = 3;
static const uint16 kPortReset = 4;
static const uint16 kPortPower = 8;


static bool
port_request(BUSBDevice& hub, uint8 request, uint16 feature, uint16 port)
{
	// usb_raw wants a user address even without a data stage
	uint8 dummy;
	ssize_t result = hub.ControlTransfer(kRequestTypeClassOtherOut, request, feature, port, 0,
		&dummy);
	printf("usbport: %s feature %u port %u: %s\n",
		request == kSetFeature ? "set" : "clear", feature, port,
		result < 0 ? strerror(result) : "ok");
	fflush(stdout);
	return result >= 0;
}


int
main(int argc, char** argv)
{
	if (argc < 4) {
		fprintf(stderr, "usage: %s HUB PORT off|on|reset|cycle [OFF_MS [N [GAP_MS]]]\n", argv[0]);
		return 2;
	}

	BUSBDevice hub(argv[1]);
	if (hub.InitCheck() != B_OK) {
		fprintf(stderr, "usbport: %s: %s\n", argv[1], strerror(hub.InitCheck()));
		return 1;
	}
	const uint16 port = atoi(argv[2]);
	const char* action = argv[3];

	if (strcmp(action, "off") == 0)
		return port_request(hub, kClearFeature, kPortPower, port) ? 0 : 1;
	if (strcmp(action, "on") == 0)
		return port_request(hub, kSetFeature, kPortPower, port) ? 0 : 1;
	if (strcmp(action, "reset") == 0)
		return port_request(hub, kSetFeature, kPortReset, port) ? 0 : 1;
	if (strcmp(action, "cycle") != 0 || argc < 5) {
		fprintf(stderr, "usbport: unknown action %s\n", action);
		return 2;
	}

	const bigtime_t offTime = atoll(argv[4]) * 1000;
	const int count = argc > 5 ? atoi(argv[5]) : 1;
	const bigtime_t gap = (argc > 6 ? atoll(argv[6]) : 3000) * 1000;
	for (int i = 0; i < count; i++) {
		printf("usbport: cycle %d/%d\n", i + 1, count);
		if (!port_request(hub, kClearFeature, kPortPower, port))
			return 1;
		snooze(offTime);
		if (!port_request(hub, kSetFeature, kPortPower, port))
			return 1;
		snooze(gap);
	}
	return 0;
}
