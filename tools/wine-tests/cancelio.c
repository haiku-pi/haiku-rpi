/* cancelio.c — cancel pending overlapped reads on a named pipe, the way services.exe and rpcrt4 do (CancelIo by
 * the reading thread; CancelIoEx by another thread while the reader is busy, not waiting), many times over.
 * Known issue W8: when the server cannot queue the completion APC to the reader (on Haiku it can only reach a thread
 * that waits), the read completes in the server during the cancel, and the wineserver used the freed async
 * afterwards: a corrupt list, later a wineserver spinning for ever (Wine patch 0026).
 *
 *   cancelio.exe [ROUNDS [MODE]]      (default 2000 rounds; MODE both (default), io: CancelIo only, ex: CancelIoEx only)
 *
 * Prints "CANCELIO done <rounds> rounds: <a> aborted, <s> success, <o> other, <t> timed out": each read should end
 * ERROR_OPERATION_ABORTED (Windows, Wine on Linux). On Haiku a read whose completion APC could not be queued (its
 * thread was not waiting) ends in the server only: the OVERLAPPED is never filled in (counted as success or other).
 * A broken wineserver shows as a hang (a request never answered) or a wineserver crash, not as a count. */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static HANDLE server, client;
static volatile LONG phase;

/* the other thread's CancelIoEx: the reader spins meanwhile (not in a wait) */
static DWORD WINAPI canceller(void *arg)
{
    for (;;)
    {
        while (phase == 0) YieldProcessor();
        if (phase < 0) return 0;
        CancelIoEx(server, NULL);
        InterlockedExchange(&phase, 0);
    }
}

static int aborted, success, other, timedout;

static void check(OVERLAPPED *ov)
{
    DWORD len, err;

    if (WaitForSingleObject(ov->hEvent, 5000) != WAIT_OBJECT_0) timedout++;
    else if (GetOverlappedResult(server, ov, &len, FALSE)) success++;
    else if ((err = GetLastError()) == ERROR_OPERATION_ABORTED) aborted++;
    else other++;
}

int main(int argc, char **argv)
{
    int rounds = argc > 1 ? atoi(argv[1]) : 2000, i;
    const char *mode = argc > 2 ? argv[2] : "both";
    char name[64], buf[16];
    OVERLAPPED ov;
    HANDLE thread;

    sprintf(name, "\\\\.\\pipe\\cancelio-%lu", GetCurrentProcessId());
    server = CreateNamedPipeA(name, PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED, PIPE_TYPE_BYTE | PIPE_WAIT, 1,
                              4096, 4096, 0, NULL);
    client = CreateFileA(name, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL);
    if (server == INVALID_HANDLE_VALUE || client == INVALID_HANDLE_VALUE)
    {
        printf("CANCELIO FAIL pipe: error %lu\n", GetLastError());
        return 1;
    }
    memset(&ov, 0, sizeof(ov));
    ov.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
    thread = CreateThread(NULL, 0, canceller, NULL, 0, NULL);

    for (i = 0; i < rounds; i++)
    {
        int fromThread = !strcmp(mode, "ex") || (strcmp(mode, "io") && (i & 1));

        ResetEvent(ov.hEvent);
        ov.Internal = STATUS_PENDING;
        if (ReadFile(server, buf, sizeof(buf), NULL, &ov) || GetLastError() != ERROR_IO_PENDING)
        {
            printf("CANCELIO FAIL round %d: the read did not pend (error %lu)\n", i, GetLastError());
            return 1;
        }
        if (fromThread)
        {
            InterlockedExchange(&phase, 1);
            while (phase) YieldProcessor();
        }
        else CancelIo(server);
        check(&ov);
    }
    InterlockedExchange(&phase, -1);
    WaitForSingleObject(thread, INFINITE);
    printf("CANCELIO done %d rounds: %d aborted, %d success, %d other, %d timed out\n", rounds, aborted, success,
           other, timedout);
    return 0;
}
