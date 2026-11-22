// urlrace N THREADS: THREADS threads read one fresh BUrl at the same time, N times,
// as MediaPlayer's main window, playlist window and controller do with a new
// UrlPlaylistItem: UrlString(), Authority(), UserInfo() and a copy (BMediaFile).
// Prints the number of wrong strings; a heap error aborts.
#include <Url.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <atomic>

static const char* kUrl = "http://user:pw@10.42.0.1:8080/wp4/clip-h264-720p30-15s.mp4?a=1#t";
static const char* kAuthority = "user:pw@10.42.0.1:8080";
static BUrl* sUrl;
static std::atomic<int> sGo, sReady, sBad;
static int sThreads;

static void
check(const BString& s, const char* expected)
{
	if (strcmp(s.String(), expected) != 0)
		sBad.fetch_add(1);
}

static void*
reader(void* arg)
{
	long index = (long)arg;
	int round = 0;
	for (;;) {
		round++;
		sReady.fetch_add(1);
		while (sGo.load() < round)
			;
		if (sUrl == NULL)
			return NULL;
		// vary the order so that every accessor races every other one
		switch ((index + round) % 3) {
			case 0:
				check(sUrl->UrlString(), kUrl);
				break;
			case 1:
				check(sUrl->Authority(), kAuthority);
				check(sUrl->UserInfo(), "user:pw");
				break;
			case 2:
			{
				BUrl copy(*sUrl);
				check(copy.UrlString(), kUrl);
				break;
			}
		}
	}
}

int
main(int argc, char** argv)
{
	int n = argc > 1 ? atoi(argv[1]) : 100000;
	sThreads = argc > 2 ? atoi(argv[2]) : 2;
	pthread_t t[16];
	for (long i = 0; i < sThreads; i++)
		pthread_create(&t[i], NULL, reader, (void*)i);
	for (int i = 1; i <= n; i++) {
		while (sReady.load() < sThreads * i)
			;
		delete sUrl;
		sUrl = new BUrl(kUrl, true);
		sGo.store(i);
	}
	while (sReady.load() < sThreads * (n + 1))
		;
	delete sUrl;
	sUrl = NULL;
	sGo.store(n + 1);
	for (int i = 0; i < sThreads; i++)
		pthread_join(t[i], NULL);
	printf("urlrace: %d threads, %d rounds, %d wrong strings\n", sThreads, n,
		sBad.load());
	return 0;
}
