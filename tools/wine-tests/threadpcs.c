/* threadpcs.c — where the threads of a running Windows program are: samples each thread's native (arm64)
 * pc and lr, as module+offset, through Wine's own thread suspension (no debugger: Haiku's cannot attach to an
 * arm64 team, winedbg cannot attach on Haiku). For hangs and busy loops.
 *
 *   threadpcs.exe PID [SAMPLES [INTERVAL_MS]]      (defaults 5 samples, 200 ms apart)
 *
 * The pid is Wine's (winlist.exe or `tasklist` print it). Per thread and sample: pc, lr, sp; the modules are the
 * process's PE modules, so an address in a Unix library (ntdll.so, the host's libraries) prints bare.
 * Built for arm64: GetThreadContext of an x86-64 (ARM64EC) thread then gives the native context too. */
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <stdlib.h>

static MODULEENTRY32W modules[512];
static int module_count;

static void load_modules(DWORD pid)
{
	HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, pid);
	MODULEENTRY32W entry = { .dwSize = sizeof(entry) };

	if (snap == INVALID_HANDLE_VALUE) return;
	if (Module32FirstW(snap, &entry)) {
		do modules[module_count++] = entry;
		while (module_count < 512 && Module32NextW(snap, &entry));
	}
	CloseHandle(snap);
}

static const char *where(ULONG64 address)
{
	static char buffers[4][300];
	static int next;
	char *out = buffers[next++ & 3];
	int i;

	for (i = 0; i < module_count; i++) {
		ULONG64 base = (ULONG64)modules[i].modBaseAddr;
		if (address >= base && address < base + modules[i].modBaseSize) {
			snprintf(out, 300, "%ls+%#llx", modules[i].szModule, (unsigned long long)(address - base));
			return out;
		}
	}
	snprintf(out, 300, "%#llx", (unsigned long long)address);
	return out;
}

int main(int argc, char **argv)
{
	DWORD pid, threads[256];
	int samples, interval, thread_count = 0, i, s;
	THREADENTRY32 entry = { .dwSize = sizeof(entry) };
	HANDLE snap;

	if (argc < 2) {
		fprintf(stderr, "usage: threadpcs.exe PID [SAMPLES [INTERVAL_MS]]\n");
		return 2;
	}
	pid = strtoul(argv[1], NULL, 0);
	samples = argc > 2 ? atoi(argv[2]) : 5;
	interval = argc > 3 ? atoi(argv[3]) : 200;
	load_modules(pid);
	printf("threadpcs: pid %#lx, %d modules\n", (unsigned long)pid, module_count);

	snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
	if (snap != INVALID_HANDLE_VALUE && Thread32First(snap, &entry)) {
		do if (entry.th32OwnerProcessID == pid && thread_count < 256) threads[thread_count++] = entry.th32ThreadID;
		while (Thread32Next(snap, &entry));
	}
	if (snap != INVALID_HANDLE_VALUE) CloseHandle(snap);

	for (s = 0; s < samples; s++) {
		for (i = 0; i < thread_count; i++) {
			HANDLE thread = OpenThread(THREAD_GET_CONTEXT | THREAD_SUSPEND_RESUME, FALSE, threads[i]);
			CONTEXT context = { .ContextFlags = CONTEXT_CONTROL | CONTEXT_INTEGER };

			if (!thread) {
				printf("tid %04lx: cannot open (%lu)\n", threads[i], GetLastError());
				continue;
			}
			if (SuspendThread(thread) != (DWORD)-1) {
				if (GetThreadContext(thread, &context))
					printf("sample %d tid %04lx: pc %s lr %s sp %#llx\n", s, threads[i], where(context.Pc),
						where(context.Lr), (unsigned long long)context.Sp);
				else
					printf("sample %d tid %04lx: no context (%lu)\n", s, threads[i], GetLastError());
				ResumeThread(thread);
			}
			CloseHandle(thread);
		}
		fflush(stdout);
		Sleep(interval);
	}
	return 0;
}
