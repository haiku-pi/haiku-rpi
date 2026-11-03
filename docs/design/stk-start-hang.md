# SuperTuxKart start hang: a lost rw_lock hand-off (2026-11-03)

The games bench's SuperTuxKart step (`tools/pi-tests/games-bench.sh`, the package supertuxkart-1.5-2) ended
"n/a (stopped after 200 s)" in 5 of about 15 runs on GCC 16.2 images from 11-02 22:02 on (gb-g16-3, gb6a-2,
gb6a-3, gb6b-3, gb6sb-1), 0 of 8 on GCC 13.3 ones. The screen: the game's empty white window titled "Untitled",
never a frame (artifacts/hdmi/20261103-090734-gb6a-3-43.png). No kernel message.

## Verdict

**Two bugs in a chain, neither of them GCC 16's:**

1. **libroot's private `rw_lock` loses a hand-off after an interrupted wait** (upstream code, unchanged since
   2009). `rw_lock_wait()` retries an interrupted `_kern_block_thread()` without setting the user thread's
   `wait_status` to 1 again. The interruption leaves `B_INTERRUPTED` there; `_kern_block_thread()` then returns
   at once, every time (the waiter spins, half in the kernel), and `_kern_unblock_thread()` ignores a thread whose
   wait status is not positive. When the lock is released, `rw_lock_unblock()` makes the spinning waiter the
   holder and "wakes" it, which does nothing: the waiter keeps the lock and never returns, and every other thread
   that wants the lock waits for good.
2. **On arm64 a new thread's first interruptible wait is interrupted, when it got an exited thread's stack.**
   `resume_thread()`, which starts every new thread, sends `SIGNAL_CONTINUE_THREAD`. x86 handles pending signals
   when a thread first enters userland (`x86_return_to_userland()`); arm64's `arch_thread_enter_userspace()` does
   not, so the signal waits for the thread's first exception. That used to be a page fault on its new stack, which
   handled it unnoticed. Since 10-29 (ecab951764, our fork: a team keeps the stack areas of exited threads for new
   ones) the stack is often already mapped, and the first exception is the first system call: a first wait
   returns `B_INTERRUPTED` after ~60 µs.

SuperTuxKart opens and closes its window four times in a row (Irrlicht tries OpenGL 4.3, 3.3 and 3.1 core
contexts before the 2.1 one it gets), so window threads exit and new ones start on their stacks. A `BWindow`'s
thread begins with `BLooper::Lock()`, which takes `BLooperList`'s `rw_lock` (`gLooperList`). When the main thread
held that lock at that moment (here in `BMessenger::_InitData()`, posting `SDL_SetWindowTitle()`'s message to the
new window), the window thread's first wait was interrupted (2), it spun, the hand-off was lost (1): the window
never drew, the main thread and the SDL application thread waited for `gLooperList` forever.

GCC 16 is not the cause: the 13.3 images of 11-02 (gb13-1…3) had the stack reuse too and 0 hangs in 3 runs, which
at a rate of one in three is a 30 % chance; the 13.3 runs of 10-25 predate ecab951764. The regression is the stack
reuse, which exposed (2), which triggers (1). Upstream Haiku has (1) and (2) but not the stack reuse, so (2) stays
hidden there and (1) needs a real signal to a thread waiting for an `rw_lock`. Every multi-window application
on our arm64 builds since 10-29 was exposed (a window opened while another thread held `gLooperList`), and every
first wait of a thread on a reused stack could return `B_INTERRUPTED` (an `acquire_sem()` without a retry, say).

## Evidence

### The hang on the Pi (scripts/stk-hang-hunt.sh, artifacts/stk-hang/20261103-123108/)

Network session of `artifacts/images/gb-stage6-a.img` (rpi4 hrev60299+259, GCC 16.2), its UserBootscript
replaced by the session's: SuperTuxKart started with the bench's arguments (`--profile-time=20`, cold shader
cache) by `tools/pi-tests/stk-start-loop.sh`. Starts 1–3 good (29–33 s), **start 4 hung** (no frame after 110 s,
the same white "Untitled" window). `ps -a` 10 s apart: the window thread `w>Untitled` (864) running, user time
+5.4 s and kernel time +4.7 s in 10 s; every other thread of the game waiting, no CPU time.

Kernel debugger (serial log, kept as `serial.log`): 848 `SuperTuxKart` and 855 `SDLApplication` "waiting for
user" (`_user_block_thread`), 864 running on CPU 3 (`sc` of a running thread is not supported on arm64; `cpu 3`,
`bt`):

```
16 ... </boot/system/lib/libroot.so> _kern_block_thread (nearest) + 0x04
17 ... </boot/system/lib/libroot.so> __rw_lock_write_lock + 0x68
18 ... </boot/system/lib/libbe.so> BPrivate::BLooperList::Lock() + 0x0c
19 ... </boot/system/lib/libbe.so> BLooper::_Lock(BLooper*, int, long) + 0x4c
20 ... </boot/system/lib/libbe.so> BLooper::Lock() + 0x14
21 ... </boot/system/lib/libbe.so> BLooper::_task0_(void*) + 0x14
```

Debugger's command line (`debugger.txt`), the user stacks:

| thread | where |
|---|---|
| 848 SuperTuxKart (main) | `__rw_lock_write_lock` ← `BLooperList::Lock` ← `BMessenger::_InitData` ← `BLooper::_PostMessage` ← `HAIKU_SetWindowTitle` ← SDL ← `irr::CIrrDeviceSDL::tryCreateOpenGLContext` ← `createWindow` ← `IrrDriver::initDevice` ← `main` |
| 855 SDLApplication | `__rw_lock_write_lock` ← `BLooperList::Lock` ← `BLooper::_Lock` ← `BLooper::Lock` ← `BLooper::task_looper` ← `BApplication::Run` |
| 864 w>Untitled (spinning) | `__rw_lock_write_lock` ← `BLooperList::Lock` ← `BLooper::_Lock` ← `BLooper::Lock` ← `BLooper::_task0_` |
| 854 SDLTimer | `pthread_cond_wait` (idle) |
| 860 disk$0 | `pthread_cond_wait` in libEGL_mesa (Mesa's disk cache thread, idle) |

No Mesa compile thread, no V3D wait, nothing in app_server (its threads for the game, `a:848:x-SDL-executable`
and `w:848:Untitled`, wait for their ports). Every thread that matters wants `gLooperList`.

The Debugger's `stop` interrupts a thread's wait too: after it resumed the team, 848 and 855 **spun as well**
(`after.txt`: state `run`, user and kernel time rising), which is mechanism (1) seen directly.

### The mechanism, deterministic (artifacts/stk-hang/rwlock-test/)

`rw_lock_interrupt_test` (new, `src/tests/system/libroot/os/`): the main thread holds an `rw_lock`, a new
thread asks for it; (a) its wait is interrupted by its start, (b) by `SIGUSR1` while it waits; then the lock is
released. With the image's libroot both FAIL 3 of 3 (`LIBRARY_PATH=/boot/system/lib`), with the fixed one both
PASS 3 of 3, in the same boot. A failed writer (probe 4): holder = the writer, no waiters, owner count 0, the
writer running ~50/50 user/kernel — STK's state exactly.

What interrupts a new thread's first wait (probes 2–8, scratch programs kept there; `_kern_block_thread(0, 0)`
as a new thread's first system call, unblocked after 200 ms):

| situation | first wait |
|---|---|
| first thread of the team | 200 ms, `B_OK` |
| a thread after one that exited (waited for or not) | `B_INTERRUPTED` after 40–90 µs |
| a thread while the earlier one is still alive | 200 ms, `B_OK` |
| after a thread with a 512 KiB stack exited (no stack to reuse) | 200 ms, `B_OK` |
| after a thread with the default stack exited (pthread) | `B_INTERRUPTED` |
| any thread whose first call was `snooze()` / a `find_thread("name")` system call | not interrupted |

So: interrupted exactly when the thread got a kept stack, and only on its first system call.

### Ruled out

Mesa shader compilation, the V3D driver, app_server, a futex in libroot's pthread code, GCC 16 codegen
(`__rw_lock_write_lock`/`rw_lock_wait` disassembly matches the source; the bug is in the algorithm).

## Fix (haiku branch `stk-hang`, worktree, not merged)

- **2bf2f773ba `libroot/os: rw_lock: wait again after an interrupted block`** — a waiter has a `queued` flag and
  a `status`, set by whoever dequeues it (`rw_lock_unblock()`, `__rw_lock_destroy()`) with the lock's mutex held;
  the waiter blocks, with `wait_status` set anew under that mutex, until it is dequeued (the idiom of
  `pthread_rwlock`'s `_Wait()`). An interruption can no longer lose the hand-off, whatever interrupts. Adds
  `rw_lock_interrupt_test`. A `#pragma GCC diagnostic ignored "-Wdangling-pointer"` around the enqueue: GCC 16
  cannot see that the stack waiter is dequeued before the function returns.
- **5d9132a49c `kernel/arm64: kernel exit work when a thread first enters userland`** — `arch_thread_enter_userspace()`
  does what an exception's return to EL0 does (`thread_at_kernel_exit()` when signals are pending, else
  `thread_at_kernel_exit_no_signals()`), with the frame pushed on the thread's iframe stack so that a signal
  handler's frame goes into it. Removes the spurious `B_INTERRUPTED` of first waits.

Either alone ends the STK hang (verification below); both are written for upstream. Not touched:
`pthread_rwlock`'s `_Wait()` has the same retry without setting the wait status again, but it checks `queued`
after each block, so after an interruption it spins until it is handed the lock instead of losing it.

## Verification

All on the Pi, `gb-stage6-a.img` network sessions, `scripts/stk-hang-hunt.sh` (20 s races, cold shader cache):

| what | STK starts | hangs |
|---|---|---|
| image as built (libroot and kernel unfixed) | 4 | 1 (start 4) |
| + the fixed `libroot.so` in `/boot/system/non-packaged/lib` (system-wide; the game loaded it: `SSL libroot:`) | 25 | **0** |
| the image's libroot, + the fixed kernel (its haiku package with the worktree's `kernel_arm64`) | 25 | **0** |

At the bench's rate (5 in ~15) or the hunt's (1 in 4), 25 clean starts by chance: 0.004–0.08 %.
`rw_lock_interrupt_test`: unfixed libroot FAIL/FAIL 3 of 3, fixed PASS/PASS 3 of 3 (same boot, `LIBRARY_PATH`).
(The committed test starts and joins a thread first, so that the writers get a reused stack whatever the order;
the binary run on the Pi had a first thread that measured an `acquire_sem_etc()`, which exited the same way.
Not re-run on the Pi: `rw_lock_probe7` is that experiment. The libroot and kernel on the branch are byte-identical
to the ones tested.)

With the fixed kernel (same boot as its 25 starts): `rw_lock_probe7`'s seven situations all `B_OK` after
200 ms (a new thread's first wait is no longer interrupted, also on a reused stack); `rw_lock_interrupt_test`
with the image's libroot: "interrupted by the thread's start" PASS, "interrupted by a signal" FAIL, 3 of 3 —
the kernel fix removes the trigger, the libroot fix the lost hand-off; each alone ends the hang.

Not done: a longer unfixed baseline in the hunt's loop (the bench was shared with the keying A/B queue; the
deterministic test and the bench's 5 in ~15 stand for it). Images and outputs: artifacts/stk-hang/ (20261103-123108
the hang, 20261103-132801 the libroot run, 20261103-140325 the kernel run, rwlock-test/ the tests and probes);
the kernel-fix image was /home/houp/.claude/jobs/62a3561e/tmp/gb-stage6-a-kfix.img (scratch;
`scripts/image-add.sh` of gb-stage6-a.img with the haiku package rebuilt by `package add -f ... kernel_arm64`).

## Tools

- `scripts/stk-hang-hunt.sh [--image IMG] [--starts N] [--profile SECS] [--warm] [--pre-oa SECS] [--add FILE:PATH]...
  [--first CMD]` — one Pi session, STK started up to N times; on a hang `ps -a` twice, `listimage`, an HDMI frame,
  the kernel debugger (`threads`, `thread`/`sc` per thread, each CPU's `bt`), then Debugger's `bt` per thread.
- `tools/pi-tests/stk-start-loop.sh N [PROFILE_SECS]` — the loop on the Pi (`SSL ...` lines).
- `scripts/pi-session.sh` now counts its 300 s ssh timeout only once the cycle has the bench lock (a session
  started while another cycle holds the bench used to give up and retry).
