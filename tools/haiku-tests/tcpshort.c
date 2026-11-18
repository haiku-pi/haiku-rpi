/*
 * tcpshort: N short TCP connections to HOST:PORT (each connects, reads the server's first bytes, closes): exercises
 * TCP endpoint creation and teardown (RenkuOS bdecbeb). Prints "TCPSHORT ok K of N".
 *   tcpshort HOST PORT [N]      (default N 200)
 * Build: aarch64-unknown-haiku-gcc -O2 -o tcpshort tcpshort.c -lnetwork
 */
#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

int
main(int argc, char** argv)
{
	if (argc < 3) {
		fprintf(stderr, "usage: tcpshort HOST PORT [N]\n");
		return 2;
	}
	int n = argc > 3 ? atoi(argv[3]) : 200, ok = 0;
	struct sockaddr_in sa = { 0 };
	sa.sin_family = AF_INET;
	sa.sin_port = htons(atoi(argv[2]));
	inet_pton(AF_INET, argv[1], &sa.sin_addr);
	for (int i = 0; i < n; i++) {
		int fd = socket(AF_INET, SOCK_STREAM, 0);
		if (fd < 0)
			continue;
		struct timeval tv = { 5, 0 };
		setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
		char buf[8];
		if (connect(fd, (struct sockaddr*)&sa, sizeof(sa)) == 0 && read(fd, buf, 3) == 3)
			ok++;
		close(fd);
	}
	printf("TCPSHORT ok %d of %d\n", ok, n);
	return ok == n ? 0 : 1;
}
