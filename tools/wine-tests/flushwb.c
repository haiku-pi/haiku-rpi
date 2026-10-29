/* flushwb.c — FlushProcessWriteBuffers (ntdll's NtFlushProcessWriteBuffers): whether it does anything, what
 * it costs, and the store-buffering litmus test it exists for. Built for arm64, x86 and x86-64.
 *
 *   flushwb.exe [ROUNDS [CALLS]]     (default 50000 litmus rounds per variant, 20000 calls per cost case)
 *
 * Cost: microseconds per call with 0 and with N-1 other threads of the process spinning. A stub returns in
 * well under a microsecond whatever the other threads do; the real barrier (an interrupt to every CPU that
 * runs a thread of the process) costs microseconds and grows with the busy threads.
 * Prints "FLUSHWB cost <n> busy: <us> us/call".
 *
 * Litmus: two threads, fresh cells every round:  A: x = 1; r0 = y;   B: y = 1; <barrier>; r1 = x;
 * r0 == 0 && r1 == 0 is the store-buffering outcome; with FlushProcessWriteBuffers as B's barrier it is
 * forbidden (A runs no barrier of its own). Variant "none" (no barrier) shows whether the harness can see a
 * reordering at all (on x86 under Box64 it depends on the emulator's memory-ordering mode).
 * Prints "FLUSHWB litmus <none|flush>: <n> of <rounds> forbidden".
 *
 * Wine on Haiku before patch 0025 printed "fixme:virtual:NtFlushProcessWriteBuffers stub" (stderr). */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

static int rounds = 50000;
static volatile LONG *xs, *ys;
static LONG *r0s, *r1s;
static volatile LONG arrive;
static volatile LONG stop;
static int flush;

static void round_barrier(int i)
{
	LONG target = 2 * (i + 1);
	InterlockedIncrement(&arrive);
	while (arrive < target)
		YieldProcessor();
}

static DWORD WINAPI side_a(void *arg)
{
	int i;
	SetThreadAffinityMask(GetCurrentThread(), 1);
	for (i = 0; i < rounds; i++) {
		round_barrier(i);
		xs[i] = 1;
		r0s[i] = ys[i];
	}
	return 0;
}

static DWORD WINAPI side_b(void *arg)
{
	int i;
	SetThreadAffinityMask(GetCurrentThread(), 2);
	for (i = 0; i < rounds; i++) {
		round_barrier(i);
		ys[i] = 1;
		if (flush)
			FlushProcessWriteBuffers();
		r1s[i] = xs[i];
	}
	return 0;
}

static void litmus(int with_flush)
{
	HANDLE t[2];
	int i, forbidden = 0;

	xs = calloc(rounds, sizeof(LONG));
	ys = calloc(rounds, sizeof(LONG));
	r0s = calloc(rounds, sizeof(LONG));
	r1s = calloc(rounds, sizeof(LONG));
	flush = with_flush;
	arrive = 0;
	t[0] = CreateThread(NULL, 0, side_a, NULL, 0, NULL);
	t[1] = CreateThread(NULL, 0, side_b, NULL, 0, NULL);
	WaitForMultipleObjects(2, t, TRUE, INFINITE);
	CloseHandle(t[0]);
	CloseHandle(t[1]);
	for (i = 0; i < rounds; i++)
		forbidden += r0s[i] == 0 && r1s[i] == 0;
	printf("FLUSHWB litmus %s: %d of %d forbidden (r0=0 r1=0)\n", with_flush ? "flush" : "none", forbidden,
		rounds);
	fflush(stdout);
	free((void *)xs); free((void *)ys); free(r0s); free(r1s);
}

static DWORD WINAPI spin(void *arg)
{
	SetThreadAffinityMask(GetCurrentThread(), (DWORD_PTR)1 << (INT_PTR)arg);
	while (!stop)
		YieldProcessor();
	return 0;
}

static void cost(int busy, int calls)
{
	HANDLE t[64];
	LARGE_INTEGER f, a, b;
	int i;

	stop = 0;
	for (i = 0; i < busy; i++)
		t[i] = CreateThread(NULL, 0, spin, (void *)(INT_PTR)(i + 1), 0, NULL);
	Sleep(50);
	QueryPerformanceFrequency(&f);
	QueryPerformanceCounter(&a);
	for (i = 0; i < calls; i++)
		FlushProcessWriteBuffers();
	QueryPerformanceCounter(&b);
	stop = 1;
	for (i = 0; i < busy; i++) {
		WaitForSingleObject(t[i], INFINITE);
		CloseHandle(t[i]);
	}
	printf("FLUSHWB cost %d busy: %.2f us/call\n", busy,
		(b.QuadPart - a.QuadPart) * 1e6 / f.QuadPart / calls);
	fflush(stdout);
}

int main(int argc, char **argv)
{
	SYSTEM_INFO si;
	int calls = 20000, cpus;

	if (argc > 1) rounds = atoi(argv[1]);
	if (argc > 2) calls = atoi(argv[2]);
	GetSystemInfo(&si);
	cpus = si.dwNumberOfProcessors > 64 ? 64 : si.dwNumberOfProcessors;
	printf("FLUSHWB %d CPUs\n", cpus);
	SetThreadAffinityMask(GetCurrentThread(), 1);
	cost(0, calls);
	if (cpus > 1)
		cost(cpus - 1, calls);
	if (cpus > 1) {
		litmus(0);
		litmus(1);
	}
	printf("FLUSHWB end\n");
	return 0;
}
