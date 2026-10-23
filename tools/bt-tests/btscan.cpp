/*
 * btscan — sets the first local Bluetooth device's scan mode (HCI Write Scan Enable) through the
 * bluetooth_server, so other devices can find it (inquiry scan) and connect to it (page scan), e.g. to pair
 * from another computer. "BTS " lines; exit status 0 when the controller accepted the mode.
 *
 *   btscan [MODE]     MODE: 0 none, 1 inquiry scan, 2 page scan, 3 both (default 3)
 *
 * Build: as tools/bt-tests/btinquiry.cpp (libbluetooth.so, -lbe).
 */
#include <stdio.h>
#include <stdlib.h>

#include <bluetooth/LocalDevice.h>
#include <bluetooth/bdaddrUtils.h>

using namespace Bluetooth;

int
main(int argc, char** argv)
{
	int mode = argc > 1 ? atoi(argv[1]) : 3;
	LocalDevice* local = LocalDevice::GetLocalDevice();
	if (local == NULL) {
		printf("BTS no local device\n");
		return 1;
	}
	status_t status = local->SetDiscoverable(mode);
	printf("BTS %s: scan mode %d: %s (now %d)\n",
		bdaddrUtils::ToString(local->GetBluetoothAddress()).String(), mode,
		status == B_OK ? "ok" : "refused", local->GetDiscoverable());
	return status == B_OK ? 0 : 1;
}
