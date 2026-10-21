/* hello.c — a first Windows program for Wine on Haiku arm64: console output, system information,
   a thread, and an access violation handled by a vectored exception handler (Wine's signal path).
   Built with llvm-mingw: aarch64-w64-mingw32-clang -O2 -o hello-arm64.exe hello.c, and for 32-bit x86 (WoW64):
   i686-w64-mingw32-clang -O2 -o hello-x86.exe hello.c */
#include <stdio.h>
#include <windows.h>

static DWORD WINAPI worker(void *arg)
{
	*(LONG *)arg = 42;
	return 0;
}

/* a vectored handler (mingw has no __try on arm64): report the access violation, step over the
   faulting store (one 4-byte instruction) and continue */
static LONG WINAPI handler(EXCEPTION_POINTERS *info)
{
	if (info->ExceptionRecord->ExceptionCode == 0xe0000001)
		return EXCEPTION_CONTINUE_EXECUTION;	/* the software exception of the x86 build */
	if (info->ExceptionRecord->ExceptionCode != EXCEPTION_ACCESS_VIOLATION)
		return EXCEPTION_CONTINUE_SEARCH;
	printf("caught exception %#lx at %p (address %p)\n", info->ExceptionRecord->ExceptionCode,
		info->ExceptionRecord->ExceptionAddress,
		(void *)info->ExceptionRecord->ExceptionInformation[1]);
#ifdef __aarch64__
	info->ContextRecord->Pc += 4;
	return EXCEPTION_CONTINUE_EXECUTION;
#else
	return EXCEPTION_CONTINUE_SEARCH;
#endif
}

int main(void)
{
	SYSTEM_INFO si;
	GetNativeSystemInfo(&si);
	printf("hello from Windows on Haiku: %lu processors, architecture %u, page size %lu\n",
		si.dwNumberOfProcessors, si.wProcessorArchitecture, si.dwPageSize);

	LONG value = 0;
	HANDLE thread = CreateThread(NULL, 0, worker, &value, 0, NULL);
	WaitForSingleObject(thread, INFINITE);
	CloseHandle(thread);
	printf("thread result %ld\n", value);

	AddVectoredExceptionHandler(1, handler);
#ifdef __aarch64__
	volatile int *bad = (int *)16;
	*bad = 1;
	printf("access violation handled\n");
#else
	/* x86 instructions have no fixed length to step over: a software exception, continued */
	RaiseException(0xe0000001, 0, 0, NULL);
	printf("software exception handled\n");
#endif
	printf("done\n");
	return 0;
}
