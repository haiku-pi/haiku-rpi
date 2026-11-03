# Firefox content-process crash at SIGTERM: an exited thread's stack deleted under its team (2026-11-03)

The mega19 smoke test (artifacts/images/haiku-pi4-mega19.img = release image-2026-11-03b + test content) showed
once `debug_server: Thread 1596 entered the debugger: Segment violation` (artifacts/uart/20261103-154611-session-
mega-smoke.log line 466) and the dialog "The application: /boot/system/apps/Firefox/Firefox -contentproc
-isForBrowser -p … has encountered an error" (artifacts/mega-smoke/20261103-154611/smoke/06.png). Suspects were the
two commits new in 11-03b: 5d9132a49c (arm64: kernel exit work at a thread's first entry to userland) and
2bf2f773ba (libroot `rw_lock`, see stk-start-hang.md).

## Verdict

**Neither of the two commits. An old kernel race (upstream's too), in how a team dies of a signal:**

1. A signal sent to a team whose default action ends it (SIGTERM, which `tools/mega/smoke-pi.sh` sends to every
   team it started) interrupts every thread of the team (`send_signal_to_team_locked()`); **one** thread dequeues
   it, sets the team's exit status, sends SIGKILLTHR to the main thread and **exits at once, on its own**
   (`handle_signals()` → `thread_exit()`). The other threads keep running until the main thread, in its own
   `thread_exit()`, shuts the team down and kills them.
2. `thread_exit()` of a non-main thread deletes the thread's stack area (since ecab951764 unless the team keeps it
   for a new thread: at most four, only while the team is running normally). So for a moment the team runs on
   with one of its threads' stacks gone; threads killed during the shutdown delete theirs the same way.
3. Firefox keeps objects on thread stacks that other threads read: `nsThreadPool` links every idle pool thread's
   `MRUIdleEntry` — a local of `nsThreadPool::Run()` — into the pool's `mMRUIdleThreads` list. The trace below
   shows a pool thread counting that list and reading a deleted stack: SIGSEGV, debug_server. The thread that
   took the SIGTERM was presumably an idle pool thread (it waits interruptibly, so the signal interrupts it): it
   exits killed, not woken, so its entry stays in the list, and its stack is deleted (in a content process,
   with its many short-lived threads, the team's four kept stacks are usually taken already).

The team is going down anyway, so the damage is the crash dialog (and a debug_server report attempt) for a
process that was being ended — but it is a real fault, it can hit any program ended by a signal, and the dialog
looks like a crash of the application.

Why it looked new: it is rare — about 2 of 100 Firefox starts ended by SIGTERM (below; each such start ends ~10
content processes) — and only the mega smoke ends Firefox with SIGTERM: the release check quits it
(`launchtime -q`, B_QUIT_REQUESTED), the 120 Pi logs before had no SIGTERM-ended Firefox, and the three earlier
smoke runs (mega17/18) at ~2 % each have a 94 % chance of no crash.

## Evidence

### Reproduction (scripts/firefox-crash-hunt.sh, tools/pi-tests/firefox-start-loop.sh)

Network sessions; Firefox started as the smoke test starts it (no arguments, home page, a new profile each start:
the smoke's start was the image's first), ended after 25 s (15 s in arm C) as the smoke ends it (SIGTERM to each
team it started, SIGKILL 2 s later). debug_server set to `report` (`default_action report`; no report was ever
written: each time the team was gone before the Debugger could attach, "Failed to prepare debugger handover: Bad
port ID" — itself a sign the fault happened while the team was dying).

| image / kernel | starts | content-process faults | parent MOZ_CRASH (below) |
|---|---|---|---|
| image-2026-11-03b (artifacts/firefox-crash/20261103-162740-r03b) | 30 | **1** (start 11: thread 3872, team 3832, which the parent then reported as "exited on signal 15") | 3 |
| 11-03b + diagnostic kernel, first-entry exit work on (20261103-172326-diag, arm A) | 30 | 0 | 2 |
| same boot, first-entry exit work **off** (arm B; = arm64 before 5d9132a49c) | 30 | 0 | 1 |
| same boot, on again, 15 s runs (arm C, stopped once the trace was in) | 10 | **1** (start 1, with the trace below) | 1 |
| 11-03b + the fix (20261103-184556-fix) | 30 | **0** (0 debugger entries in the syslog) | 2 |

The diagnostic kernel (diff kept in the diag directory, `diag.diff`, not committed) printed, for every user fault
the kernel turned into a signal, the thread, its team's state, its pending/blocked signals, its user/kernel time,
registers and frame-pointer chain with area names, and switched 5d9132a49c's work at runtime (kernel debugger
command `ffcrash_first_exit 0|1`, sent over the serial line by the hunt script's `--kdl-then`).

### The trace (arm C, serial.log line 884)

```
FFCRASH: thread 20804 "StreamTrans #4" team 20765 "Firefox" (state 0, main 20765) read 0xf78da1ab68
  status 0x80001301; flags 0x0 pending 0x0 blocked 0x0 user 1606 kernel 1248 us; ... esr 0x92000007
FFCRASH:  #0 0xa80601f8f0 libxul.so_seg0rx + 0x14dc8f0      nsThreadPool::Run()
FFCRASH:  #1 0xa80601f8d8 libxul.so_seg0rx + 0x14dc8d8      nsThreadPool::Run() (after TimeStamp::Now())
FFCRASH:  #2 0x5b6183e4208 commpage + 0x208                  (thread exit stub: the outermost frame)
FFCRASH:  address in no area
debug_server: Thread 20804 entered the debugger: Segment violation
debug_server: Failed to prepare debugger handover: Bad port ID
```

Symbols from artifacts/firefox/obj/dist/bin/libxul.so (same build ID 7c0c701f… as the packaged one). The faulting
instruction `ldr x2, [x2]` at +0x14dc8f0 is the loop of `mMRUIdleThreads.length()` in `nsThreadPool::Run()`
(sources/firefox/firefox-157.0.1/xpcom/threads/nsThreadPool.cpp: `uint32_t cnt = mMRUIdleThreads.length() + …`):
the list's next element is at an address in no area — a deleted stack. The team is still `TEAM_STATE_NORMAL`
(0): the main thread has not started the shutdown yet; the faulting thread has no signal pending — the SIGTERM
was taken by another thread. (A new thread — 1.6 ms of user time — which is not relevant: 5d9132a49c's work at
its first entry found nothing to do, `flags 0`.)

### The mechanism, deterministic (tools/haiku-tests/killrace.cpp, tools/pi-tests/kill-race-loop.sh)

`kill_race2` (killrace.cpp): a "victim" thread puts a list node on its stack and waits; it alone does not block SIGTERM, so it
takes it. Three walker threads read the list in a loop. Four threads were joined first (the stack cache is full,
so the victim's stack is deleted, as in a content process); the main thread spends its time in 64 MiB reads of
/dev/zero, so it gets to the shutdown late. The loop sends SIGTERM once it is ready.

| kernel | kills | faults (`entered the debugger: Segment violation`) |
|---|---|---|
| diagnostic (= 11-03b's), first-entry exit work on | 20 | **20** (each: walkers, `state 0`, address in no area) |
| same boot, first-entry exit work off | 10 | **8** |
| the fix | 30 | **0** |

The race does not depend on 5d9132a49c; it does not involve `rw_lock` (2bf2f773ba). The code that deletes the
stack is upstream's (`thread_exit()`: "We postponed deleting the user stack until now …" — it waits for the
threads waiting for *this* thread's death, not for the team's other threads); upstream Haiku has the same race on
every architecture.

### Not this: the parent's SIGILL

In about one start in ten the parent `Firefox` ended with "Illegal instruction" and no debugger entry: a
`MOZ_RELEASE_ASSERT(mFrameLoader) (Expecting to have mFrameLoader here.)` in
`nsFrameLoaderOwner::ChangeRemoteness()` (brk #1000 = `__builtin_trap()`, MOZ_CRASH on Haiku; Firefox's own
SIGILL handler then ends the process quietly), called from browser JS during the shutdown the parent's SIGTERM
handler (`nsAppShell::TermSignalHandler()`) starts while its content processes are being killed. Firefox's
behaviour when its tabs' processes die under it during shutdown; the same with and without 5d9132a49c (arms A/B).

## Fix (haiku branch `ffcrash`, e09cfa1d9e, not merged)

**`kernel/thread: keep an exited thread's stack while its team goes down`** — `put_cached_user_stack()` becomes
`keep_user_stack()`: while the team is going down (`state >= TEAM_STATE_SHUTDOWN`, or its exit status already set
— which the signal path, `exit()` and `team_init_exit_info_on_error()` do first), the stack area of an exiting
thread is left alone; it goes with the team's address space, as Linux keeps a dying thread group's memory until
its last thread is gone. A team that is not going down keeps or deletes the area as before. No change to
5d9132a49c or 2bf2f773ba.

## Verification

One network session of image-2026-11-03b with the fixed kernel (its haiku package rebuilt with the branch's
`kernel_arm64`) and the SuperTuxKart packages added (artifacts/firefox-crash/20261103-184556-fix: loop.txt,
syslog, serial.log):

| check | result |
|---|---|
| `kill_race2` (kill-race-loop.sh 30) | 30 kills, **0 faults** (unfixed: 20 of 20, and 8 of 10 without 5d9132a49c's work) |
| `tools/pi-tests/stk-start-loop.sh 20 20` (the STK start hang's loop, cold shader cache) | 20 starts, **0 hangs** (29–34 s each) |
| Firefox loop (firefox-start-loop.sh 30 25) | 30 starts, **0 content-process faults**; the parent's MOZ_CRASH 2 times (Firefox's, above) |

The Firefox numbers alone prove little (2 faults in 100 unfixed starts; 0 in 30 is 55 % likely by chance at that
rate); the deterministic test shows that the fault class is gone, the Firefox trace that Firefox's crash is that
fault. The fix keeps 5d9132a49c and 2bf2f773ba as they are (the STK loop).

## Tools

- `scripts/firefox-crash-hunt.sh [--image IMG] [--starts N] [--secs S] [--url URL] [--add FILE:PATH]... [--label L]
  [--keep] [--kdl-then CMD]` — a network session, Firefox started and ended N times as the smoke test does
  (`tools/pi-tests/firefox-start-loop.sh`: "FSL i: ok|CRASH"), debug_server reports collected; `--kdl-then`: a
  kernel debugger command between two loops in one boot.
- `tools/pi-tests/kill-race-loop.sh N [PROGRAM [ARGS]]` with `tools/haiku-tests/killrace.cpp` — the deterministic
  test ("KRL end N kills, F faults").
- The test images (scratch, not kept): image-2026-11-03b with the diagnostic kernel, and with the fixed one plus
  the SuperTuxKart packages (for the STK check) — each `scripts/image-add.sh` of the release image with its haiku
  package rebuilt by `package add -f -C DIR haiku-….hpkg kernel_arm64` (the options before the package's name).
