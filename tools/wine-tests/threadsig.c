/* threadsig.c — what the wineserver can do to a thread that is busy (running, not waiting for it), which needs a
 * Unix signal to that thread (KNOWN-ISSUES W9: on Haiku the server had no thread to signal until Wine 0027):
 * SuspendThread() stops it, GetThreadContext() reads its registers, ResumeThread() lets it run again,
 * TerminateThread() ends it, and GetThreadTimes() reports the time it ran.
 *
 *   threadsig.exe
 *
 * Prints "THREADSIG <check>: ok|FAIL ..." per check and "THREADSIG done: <n> of 5 ok". A check that waits for
 * the thread gives up after 5 s (a lost signal shows as a FAIL, or as a hang of GetThreadContext). */
#include <windows.h>
#include <stdio.h>
#include <string.h>

static volatile LONG64 counter;

static DWORD WINAPI spinner(void *arg)
{
    for (;;) counter++;
    return 0;
}

static LONG64 advance(DWORD ms)
{
    LONG64 before = counter;
    Sleep(ms);
    return counter - before;
}

int main(void)
{
    HANDLE thread = CreateThread(NULL, 0, spinner, NULL, 0, NULL);
    FILETIME creation, exitTime, kernel, user;
    CONTEXT context;
    DWORD code, wait;
    LONG64 moved;
    int ok = 0;

    setvbuf(stdout, NULL, _IONBF, 0);  /* each line out at once: a hang shows where it is */
    while (!counter) Sleep(1);

    /* SuspendThread returns once the thread has stopped (the server waits for its context) */
    SuspendThread(thread);
    Sleep(50);
    moved = advance(300);
    printf("THREADSIG suspend: %s (the counter moved %lld while suspended)\n", moved ? "FAIL" : "ok", moved);
    ok += !moved;

    memset(&context, 0, sizeof(context));
    context.ContextFlags = CONTEXT_CONTROL;
    if (GetThreadContext(thread, &context))
    {
#if defined(__aarch64__)
        ULONG64 pc = context.Pc;
#elif defined(__x86_64__)
        ULONG64 pc = context.Rip;
#else
        ULONG64 pc = context.Eip;
#endif
        HMODULE module = NULL;
        BOOL inSpinner = GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS
                                            | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                                            (const char *)(ULONG_PTR)pc, &module)
                         && module == GetModuleHandleA(NULL);
        printf("THREADSIG context: %s (pc %#llx, %s)\n", inSpinner ? "ok" : "FAIL", pc,
               inSpinner ? "in the program" : "not in the program");
        ok += inSpinner;
    }
    else printf("THREADSIG context: FAIL (error %lu)\n", GetLastError());

    ResumeThread(thread);
    moved = advance(300);
    printf("THREADSIG resume: %s (the counter moved %lld)\n", moved ? "ok" : "FAIL", moved);
    ok += !!moved;

    if (GetThreadTimes(thread, &creation, &exitTime, &kernel, &user))
    {
        ULONG64 t = ((ULONG64)user.dwHighDateTime << 32 | user.dwLowDateTime) / 10000;
        printf("THREADSIG times: %s (user time %llu ms)\n", t ? "ok" : "FAIL", t);
        ok += !!t;
    }
    else printf("THREADSIG times: FAIL (error %lu)\n", GetLastError());

    TerminateThread(thread, 7);
    wait = WaitForSingleObject(thread, 5000);
    GetExitCodeThread(thread, &code);
    Sleep(50);
    moved = advance(300);
    printf("THREADSIG terminate: %s (wait %lu, exit code %lu, the counter moved %lld afterwards)\n",
           wait == WAIT_OBJECT_0 && code == 7 && !moved ? "ok" : "FAIL", wait, code, moved);
    ok += wait == WAIT_OBJECT_0 && code == 7 && !moved;

    printf("THREADSIG done: %d of 5 ok\n", ok);
    /* a spinner that survived TerminateThread must not keep the process alive */
    ExitProcess(ok == 5 ? 0 : 1);
}
