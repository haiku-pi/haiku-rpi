/*
 * localip.c — what a Windows game sees of the local network: the probe Need for Speed: Porsche
 * Unleashed makes before it creates its race session object (docs/design/wine-x86.md, W11), plus
 * the IP Helper tables Wine's gethostbyname() builds its answer from.
 *
 *   localip.exe
 *
 * The game: WSAStartup(1.1), gethostname(), gethostbyname(that name), inet_ntoa() of the first
 * address; "UDP" is available only when that address starts with neither "127." nor "0." and a
 * UDP socket opens. Without UDP (and IPX) the race object is never made: the crash at
 * Porsche.exe+0x8ced6. Prints "LOCALIP game-probe: PASS|FAIL ...".
 */
#include <winsock2.h>
#include <iphlpapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int
main(void)
{
	WSADATA wsa;
	char name[256];
	char addr[64] = "";
	int udp = 0;

	if (WSAStartup(MAKEWORD(1, 1), &wsa) != 0) {
		printf("LOCALIP WSAStartup failed\n");
		return 1;
	}
	if (gethostname(name, sizeof(name)) != 0) {
		printf("LOCALIP gethostname failed: %d\n", WSAGetLastError());
		name[0] = '\0';
	} else
		printf("LOCALIP gethostname: %s\n", name);

	struct hostent* host = gethostbyname(name);
	if (host == NULL)
		printf("LOCALIP gethostbyname: NULL, error %d\n", WSAGetLastError());
	else {
		printf("LOCALIP gethostbyname: type %d length %d\n", host->h_addrtype, host->h_length);
		for (int i = 0; host->h_addr_list[i] != NULL; i++) {
			struct in_addr in;
			memcpy(&in, host->h_addr_list[i], sizeof(in));
			printf("LOCALIP   address %d: %s\n", i, inet_ntoa(in));
		}
		if (host->h_addrtype == AF_INET && host->h_length == 4 && host->h_addr_list[0] != NULL) {
			struct in_addr in;
			memcpy(&in, host->h_addr_list[0], sizeof(in));
			strncpy(addr, inet_ntoa(in), sizeof(addr) - 1);
		}
	}

	if (addr[0] != '\0' && strncmp(addr, "127.", 4) != 0 && strncmp(addr, "0.", 2) != 0) {
		SOCKET s = socket(AF_INET, SOCK_DGRAM, 0);
		if (s != INVALID_SOCKET) {
			udp = 1;
			closesocket(s);
		}
	}
	printf("LOCALIP game-probe: %s (address \"%s\")\n", udp ? "PASS" : "FAIL", addr);

	ULONG size = 0;
	DWORD status = GetAdaptersInfo(NULL, &size);
	printf("LOCALIP GetAdaptersInfo(size): %lu, %lu bytes\n", status, size);
	if (status == ERROR_BUFFER_OVERFLOW) {
		IP_ADAPTER_INFO* adapters = malloc(size);
		if (GetAdaptersInfo(adapters, &size) == NO_ERROR) {
			for (IP_ADAPTER_INFO* a = adapters; a != NULL; a = a->Next) {
				printf("LOCALIP   adapter %lu %s: %s/%s gateway %s\n", a->Index, a->AdapterName,
					a->IpAddressList.IpAddress.String, a->IpAddressList.IpMask.String,
					a->GatewayList.IpAddress.String);
			}
		}
		free(adapters);
	}

	size = 0;
	status = GetIpForwardTable(NULL, &size, FALSE);
	printf("LOCALIP GetIpForwardTable(size): %lu, %lu bytes\n", status, size);
	if (status == ERROR_INSUFFICIENT_BUFFER) {
		MIB_IPFORWARDTABLE* routes = malloc(size);
		if (GetIpForwardTable(routes, &size, FALSE) == NO_ERROR) {
			for (DWORD i = 0; i < routes->dwNumEntries; i++) {
				struct in_addr dest, mask, hop;
				dest.s_addr = routes->table[i].dwForwardDest;
				mask.s_addr = routes->table[i].dwForwardMask;
				hop.s_addr = routes->table[i].dwForwardNextHop;
				char d[20], m[20];
				strcpy(d, inet_ntoa(dest));
				strcpy(m, inet_ntoa(mask));
				printf("LOCALIP   route %s/%s via %s if %lu type %lu metric %lu\n", d, m, inet_ntoa(hop),
					routes->table[i].dwForwardIfIndex, routes->table[i].dwForwardType,
					routes->table[i].dwForwardMetric1);
			}
		}
		free(routes);
	}

	WSACleanup();
	return udp ? 0 : 1;
}
