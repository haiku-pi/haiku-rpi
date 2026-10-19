/*
 * btinquiry — asks the bluetooth_server for its first local device (the Bluetooth kit's LocalDevice),
 * prints its address, name and class, then runs an inquiry and prints the devices that answer.
 * "BTQ " lines; exit status 0 when the local device has a non-zero address.
 *
 *   btinquiry [-n] [-t UNITS]     -n: no inquiry; -t: inquiry length in 1.28 s units (default 8)
 *
 * (Haiku's own bt_dev_info prints the address with "%s" of a BString, and bt_discovery does not
 * build any more.) Build, after a jam build of libbluetooth.so (scripts/build.sh libbluetooth.so):
 *
 *   g=sources/haiku/generated.arm64
 *   $g/cross-tools-arm64/bin/aarch64-unknown-haiku-g++ --sysroot=artifacts/sysroot-arm64 \
 *     -I artifacts/sysroot-arm64/boot/system/develop/headers/private/bluetooth \
 *     -o artifacts/bt-tests/btinquiry tools/bt-tests/btinquiry.cpp \
 *     $g/objects/haiku/arm64/release/kits/bluetooth/libbluetooth.so -lbe
 */

#include <bluetooth/DeviceClass.h>
#include <bluetooth/DiscoveryAgent.h>
#include <bluetooth/DiscoveryListener.h>
#include <bluetooth/LocalDevice.h>
#include <bluetooth/RemoteDevice.h>
#include <bluetooth/bdaddrUtils.h>

#include <OS.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SAY(...) do { printf("BTQ " __VA_ARGS__); printf("\n"); fflush(stdout); } while (0)

using namespace Bluetooth;


static BString
class_string(DeviceClass deviceClass)
{
	BString string;
	deviceClass.GetServiceClass(string);
	string << " | ";
	deviceClass.GetMajorDeviceClass(string);
	string << " | ";
	deviceClass.GetMinorDeviceClass(string);
	return string;
}


class Listener : public DiscoveryListener {
public:
	Listener(sem_id done)
		:
		fDone(done),
		fFound(0)
	{
	}

	void DeviceDiscovered(RemoteDevice* device, DeviceClass deviceClass)
	{
		fFound++;
		SAY("found %s, %s", bdaddrUtils::ToString(device->GetBluetoothAddress()).String(),
			class_string(deviceClass).String());
	}

	void InquiryStarted(status_t status)
	{
		SAY("inquiry started: %s", strerror(status));
	}

	void InquiryResponse(int discType)
	{
		SAY("inquiry finished (%d), %d device(s)", discType, fFound);
		release_sem(fDone);
	}

private:
	sem_id	fDone;
	int		fFound;
};


int
main(int argc, char** argv)
{
	bool inquiry = true;
	int units = 8;
	int option;
	while ((option = getopt(argc, argv, "nt:")) != -1) {
		switch (option) {
			case 'n':
				inquiry = false;
				break;
			case 't':
				units = atoi(optarg);
				break;
			default:
				fprintf(stderr, "usage: btinquiry [-n] [-t UNITS]\n");
				return 2;
		}
	}

	SAY("local devices: %" B_PRIu32, LocalDevice::GetLocalDeviceCount());
	LocalDevice* local = LocalDevice::GetLocalDevice();
	if (local == NULL) {
		SAY("no local device");
		return 1;
	}

	bdaddr_t address = local->GetBluetoothAddress();
	SAY("local device %" B_PRId32 ": address %s, name \"%s\", class %s", local->ID(),
		bdaddrUtils::ToString(address).String(), local->GetFriendlyName().String(),
		class_string(local->GetDeviceClass()).String());
	const bool valid = !bdaddrUtils::Compare(address, bdaddrUtils::NullAddress());

	if (inquiry) {
		DiscoveryAgent* agent = local->GetDiscoveryAgent();
		sem_id done = create_sem(0, "btinquiry");
		Listener* listener = new Listener(done);
		status_t status = agent != NULL
			? agent->StartInquiry(BT_GIAC, listener, units) : B_ERROR;
		SAY("inquiry of %d x 1.28 s requested: %s", units, strerror(status));
		if (status == B_OK) {
			status = acquire_sem_etc(done, 1, B_RELATIVE_TIMEOUT,
				(units * 1280000LL) + 15000000LL);
			if (status != B_OK)
				SAY("no end of inquiry: %s", strerror(status));
		}
	}

	return valid ? 0 : 1;
}
