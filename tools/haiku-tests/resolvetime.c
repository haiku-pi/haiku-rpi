/*
 * resolvetime.c — how long a host name lookup takes: gethostbyname() and getaddrinfo() of each NAME
 * (default: this machine's own host name and "localhost"), timed; the way Firefox's profile lock and
 * many other programs look up their own host.
 *
 *   resolvetime [NAME...]
 *
 * Prints "resolvetime: NAME: gethostbyname R in N ms, getaddrinfo R in N ms" per name.
 *
 * Build (cross):
 *   g=sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc
 *   $g --sysroot=artifacts/sysroot-arm64 -O2 -o resolvetime tools/haiku-tests/resolvetime.c -lnetwork
 */
#include <netdb.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>


static double
now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000.0 + ts.tv_nsec / 1000000.0;
}


static void
resolve(const char* name)
{
	double start = now_ms();
	struct hostent* host = gethostbyname(name);
	double hostTime = now_ms() - start;

	struct addrinfo hints;
	memset(&hints, 0, sizeof(hints));
	hints.ai_socktype = SOCK_STREAM;
	struct addrinfo* info = NULL;
	start = now_ms();
	int error = getaddrinfo(name, NULL, &hints, &info);
	double infoTime = now_ms() - start;
	if (info != NULL)
		freeaddrinfo(info);

	printf("resolvetime: %s: gethostbyname %s in %.0f ms, getaddrinfo %s in %.0f ms\n", name,
		host != NULL ? "ok" : "failed", hostTime, error == 0 ? "ok" : gai_strerror(error), infoTime);
}


int
main(int argc, char** argv)
{
	if (argc > 1) {
		for (int i = 1; i < argc; i++)
			resolve(argv[i]);
		return 0;
	}

	char hostname[256];
	if (gethostname(hostname, sizeof(hostname)) == 0)
		resolve(hostname);
	resolve("localhost");
	return 0;
}
