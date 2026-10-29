/* threadctx.c — the context of a suspended busy thread (KNOWN-ISSUES W9: Box64's WoW64 back end returned the
 * registers of the thread's last call into Wine; with the cooperative suspend, patches/box64/0003, its own):
 * GetThreadContext() reads the values the thread's spinning loop keeps in two registers, and a context set while
 * it is suspended (SetThreadContext: a new program counter) is where it goes on after ResumeThread().
 *
 *   threadctx.exe
 *
 * Prints "THREADCTX <check>: ok|FAIL ..." per check and "THREADCTX done: <n> of 3 ok". */
#include <windows.h>
#include <stdio.h>
#include <string.h>

static volatile LONG counter;
static volatile LONG escaped;

/* spins with 0x5a5a and 0x1234 in two callee-saved registers, counting in memory */
static DWORD WINAPI spinner(void *arg)
{
#if defined(__i386__)
    __asm__ volatile("movl $0x5a5a, %%esi\n\tmovl $0x1234, %%edi\n1:\tlock incl %0\n\tjmp 1b"
                     : "+m"(counter) : : "esi", "edi", "memory");
#elif defined(__x86_64__)
    __asm__ volatile("movl $0x5a5a, %%esi\n\tmovl $0x1234, %%edi\n1:\tlock incl %0\n\tjmp 1b"
                     : "+m"(counter) : : "rsi", "rdi", "memory");
#else
    __asm__ volatile("mov x19, #0x5a5a\n\tmov x20, #0x1234\n1:\tldr w9, %0\n\tadd w9, w9, #1\n\tstr w9, %0\n\tb 1b"
                     : "+m"(counter) : : "x9", "x19", "x20", "memory");
#endif
    return 0;
}

/* where the context set while suspended sends the thread */
static void escape(void)
{
    InterlockedIncrement(&escaped);
    for (;;) Sleep(10);
}

int main(void)
{
    HANDLE thread = CreateThread(NULL, 0, spinner, NULL, 0, NULL);
    CONTEXT context;
    ULONG64 a = 0, b = 0;
    int ok = 0, i;
    BOOL got;

    setvbuf(stdout, NULL, _IONBF, 0);
    while (!counter) Sleep(1);
    Sleep(100);

    SuspendThread(thread);
    memset(&context, 0, sizeof(context));
    context.ContextFlags = CONTEXT_FULL;
    got = GetThreadContext(thread, &context);
#if defined(__i386__)
    a = context.Esi, b = context.Edi;
#elif defined(__x86_64__)
    a = context.Rsi, b = context.Rdi;
#else
    a = context.X19, b = context.X20;
#endif
    printf("THREADCTX registers: %s (%#llx %#llx, the loop keeps 0x5a5a 0x1234)\n",
           got && a == 0x5a5a && b == 0x1234 ? "ok" : "FAIL", a, b);
    ok += got && a == 0x5a5a && b == 0x1234;

    /* the same context again, unchanged: the thread must go on spinning */
    got = got && SetThreadContext(thread, &context);
    ResumeThread(thread);
    a = counter;
    Sleep(300);
    printf("THREADCTX same context: %s (set %s, the counter moved %ld)\n", got && counter != a ? "ok" : "FAIL",
           got ? "ok" : "failed", counter - (LONG)a);
    ok += got && counter != a;

    SuspendThread(thread);
    memset(&context, 0, sizeof(context));
    context.ContextFlags = CONTEXT_FULL;
    got = GetThreadContext(thread, &context);
#if defined(__i386__)
    context.Eip = (ULONG_PTR)escape;
#elif defined(__x86_64__)
    context.Rip = (ULONG_PTR)escape;
    context.Rsp = (context.Rsp & ~(ULONG64)15) - 8;  /* as after a call */
#else
    context.Pc = (ULONG_PTR)escape;
    context.Sp &= ~(ULONG64)15;
#endif
    got = got && SetThreadContext(thread, &context);
    /* read back while still suspended: what the server holds for the thread */
    memset(&context, 0, sizeof(context));
    context.ContextFlags = CONTEXT_CONTROL;
    GetThreadContext(thread, &context);
#if defined(__i386__)
    a = context.Eip;
#elif defined(__x86_64__)
    a = context.Rip;
#else
    a = context.Pc;
#endif
    b = counter;
    ResumeThread(thread);
    for (i = 0; i < 200 && !escaped; i++) Sleep(10);
    printf("THREADCTX new pc: %s (set %s, read back %s, %s, the counter moved %ld)\n", got && escaped ? "ok" : "FAIL",
           got ? "ok" : "failed", a == (ULONG_PTR)escape ? "the same" : "another",
           escaped ? "the thread went there" : "the thread did not go there", counter - (LONG)b);
    ok += got && escaped;

    TerminateThread(thread, 0);
    printf("THREADCTX done: %d of 3 ok\n", ok);
    ExitProcess(ok == 3 ? 0 : 1);
}
