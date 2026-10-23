/* serverbench.c — wineserver round trips per second: SetEvent/ResetEvent on an event (a server request each,
 * where the platform has no in-process synchronization), and CreateEvent/CloseHandle pairs; to compare
 * wineservers (poll() against kqueue on Haiku).
 *
 *   serverbench.exe [ITERATIONS]      (default 20000)
 *
 * Prints "SERVERBENCH set/reset <n>/s, create/close <n>/s". */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

static double now(void)
{
    LARGE_INTEGER t, f;
    QueryPerformanceCounter(&t);
    QueryPerformanceFrequency(&f);
    return (double)t.QuadPart / f.QuadPart;
}

int main(int argc, char **argv)
{
    int n = argc > 1 ? atoi(argv[1]) : 20000, i;
    HANDLE event = CreateEventW(NULL, TRUE, FALSE, NULL);
    double start, setReset, createClose;

    start = now();
    for (i = 0; i < n; i++)
    {
        SetEvent(event);
        ResetEvent(event);
    }
    setReset = 2 * n / (now() - start);

    start = now();
    for (i = 0; i < n; i++)
        CloseHandle(CreateEventW(NULL, TRUE, FALSE, NULL));
    createClose = n / (now() - start);

    printf("SERVERBENCH set/reset %.0f/s, create/close %.0f/s\n", setReset, createClose);
    CloseHandle(event);
    return 0;
}
