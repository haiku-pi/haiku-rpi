# Firefox ended by SIGSEGV on a normal quit (2026-11-04)

During the H20 C0b measurements (docs/design/perf-round-h20.md), `tools/pi-tests/startcost-steps.sh` on image
`h20-imgevt` (release image-2026-11-03c + f6c52282df; it has e09cfa1d9e, the dying-team stack fix of
firefox-contentproc-crash.md) printed, right after its `hey Firefox quit` step:

```
/boot/home/startcost-steps.sh: line 25:  5224 Segmentation violation     /boot/system/apps/Firefox/Firefox --new-window https://www.haiku-os.org/
```

(artifacts/h20-c0b/startcost-before-10min.txt line 6; session h20-c0b-idle, serial log
artifacts/uart/20261103-223431-session-h20-c0b-idle.log.) The parent process, not a content process, and on
`B_QUIT_REQUESTED`, not SIGTERM. The SIGILL at SIGTERM (`MOZ_RELEASE_ASSERT(mFrameLoader)`) is a different, known
problem in Firefox.

## Verdict

**Not reproduced: 0 in 120 quits. The one event is unattributed: no stack exists for it, and it is rare (1 in
about 123 quits counted; with 0 of 120 here, the rate is below ~2.5 % at 95 %).** What can be said about it:

1. **It was a real fault in the parent, and Firefox's own handler ended the process.** That is why there is no
   debug_server entry, no report and no dialog. On Haiku, after a fault in the Firefox parent:
   - `vm_page_fault()` finds a SIGSEGV handler installed (SpiderMonkey's `WasmTrapHandler`), so it does not call
     the debugger. It sends the signal.
   - `WasmTrapHandler` sees that the fault is not in wasm code and calls the previous handler,
     `nsProfileLock::FatalSignalHandler` (toolkit/profile/nsProfileLock.cpp, installed for SIGHUP/INT/QUIT/ILL/
     ABRT/SEGV/TERM when the profile is locked).
   - That handler removes the profile lock, restores `SIG_DFL` and calls `raise(signo)`.
   - A raised signal is a plain `kill()` to the kernel, not a fault. Its default action ends the team with no
     debugger: the shell sees "Segmentation violation", and the syslog and serial line show nothing.

   The diagnostic kernel below showed exactly this chain for the known SIGILL of a SIGTERM end (trace below). It
   is Firefox's design on every Unix: Linux would write a core dump at that point.

   One more path ends a faulting thread just as silently: if the thread had SIGSEGV blocked (a fault inside a
   handler whose `sa_mask` blocks all signals, say), `send_fault_signal()` (6e517bb52c) resets the signal to
   `SIG_DFL` and the fault kills the team. Either way, the parent faulted.
2. **It happened before Firefox's shutdown spawns `pingsender`**, or before the quit itself. Every clean quit
   spawns pingsender for the shutdown ping. The serial line records each spawn because libcurl is missing:
   "Cannot open file libcurl.so (needed by …/pingsender)". In this session these lines come ~51 s after each start,
   at the quit, for all 120 quits; on the h20-c0b-fix session they come at its quit, 44 s after the start. The crash
   session has none: Firefox started at 438 s, and after 483 s (the quit) the serial log shows only SuperTuxKart's
   start. The bash job notice puts the death somewhere between the step's `measure` (45 s) and its `sleep 10` after
   the quit.
3. **Nothing points at Haiku or our port, and nothing clears them.**
   - The dying-team stack race (firefox-contentproc-crash.md) needs a team being killed by a signal; a quit is an
     orderly `exit()`.
   - The kernel with the diagnostic below saw **no user fault at all** in 40 quits of the faithful sequence.
   - Without a stack, a Firefox shutdown bug (the HaikuPorts widget code included) and a platform problem cannot
     be told apart.

**Decision:** documented, no fix. There is nothing to fix without a trace, and more blind quits at a rate below
2.5 % cost hours of bench time for small odds. The diagnostic kernel image is kept, so the next occurrence can
be captured (below).

## Evidence

### Quit loop (tools/pi-tests/firefox-quit-loop.sh)

`firefox-quit-loop.sh N [URL [MAXWAIT [SETTLE]]]` runs N times:

1. Start `Firefox --new-window https://www.haiku-os.org/` with a new profile, a first launch as in startcost-steps.
2. Wait until `hey Firefox get Title of Window 0` names the page, then SETTLE s more.
3. `hey Firefox quit`, wait for the process, and record its exit status (`wait`: 0 or the signal).

debug_server is set to `default_action report`, and new "entered the debugger" syslog lines are counted.
`FQL_TERMINAL=1` / `FQL_MEASURE=1` add startcost-steps' Terminal open/quit before the start and its `forkbench 100`
+ `ps` + `listarea` just before the quit.

| run (network sessions, 11-03/04) | image | quits | exit 0 | signalled | debugger entries |
|---|---|---|---|---|---|
| A: settle 3 s (page title after 6–9 s) | h20-startcost (rpi4 83db805485, cpufreq fix) | 40 | 40 | 0 | 0 |
| B: settle 40 s (the quit ~45–50 s after the start, as startcost-steps) | h20-startcost | 40 | 40 | 0 | 0 |
| C: settle 40 s + Terminal + forkbench before the quit, started 150 s after the session came up (governor's low clock) | h20-imgevt + diagnostic kernel | 40 | 40 | 0 | 0 (and 0 user faults of any thread, kernel trace) |

Firefox exited 2–7 s after `hey Firefox quit`, every time, with no Firefox team left behind. Outputs:
artifacts/firefox-quit/20261103-ffquit-startcost/ (loop-a/b, syslog, serial.log) and
artifacts/firefox-quit/20261104-ffquit-diag-evt/ (loop-c, loop-d, syslog, serial.log, diag.diff).

All counted quits of Firefox with a page:

| | quits | SIGSEGV |
|---|---|---|
| startcost-steps.sh runs on 11-03 (C0, C0b before / fix) | 3 | 1 (the event) |
| this hunt | 120 | 0 |

Every release check also quits Firefox (`launchtime -q`), and none ever reported a crash, but those runs only count
debugger entries, which this crash does not produce, so they are left out.

### The silent ending, traced (run D, same boot)

To see how a fault in the Firefox parent can end it without the debugger, the same session ran
`firefox-start-loop.sh 24 25` (SIGTERM ends, the known `MOZ_RELEASE_ASSERT` SIGILL, ~1 in 10). The diagnostic
kernel prints fault-signal handler entries and deadly signals with the thread's frame-pointer chain. The 5th start
hit it (serial.log line ~2080):

```
FFCRASH: thread 39730 "MainThread" team 39730 "Firefox" (state 0) exception …          brk in ChangeRemoteness
FFSIG: handler 0xf314728ad0 flags 0x68: thread 39730 "MainThread" … signal 4 code 10 … addr 0xf311298344
FFSIG: kill: thread 39730 "MainThread" … signal 4 code 0 sender 39730                   raise() by the team itself
FFCRASH:  #0 libroot.so + 0x4b3f4  #1 libroot.so + 0x5d07c                              raise → kill
FFCRASH:  #2 libxul.so + 0x4ecaae4   nsProfileLock::FatalSignalHandler
FFCRASH:  #3 libxul.so + 0x23da344   nsFrameLoaderOwner::ChangeRemoteness   (the brk, MOZ_CRASH)
FFCRASH:  #4 libxul.so + 0x55d7e94   js::Interpret …
```

The handler at +0x586aad0 is `WasmTrapHandler` (symbols: artifacts/firefox/obj/dist/bin/libxul.so, the same
build). The fault (code 10 = ILL_*) went to the handler, then a `raise()` (code 0 = SI_USER) from
FatalSignalHandler ended the team. A SIGSEGV takes the same path: both handlers cover SIGSEGV.

## Capturing the next one

The diagnostic kernel shows the faulting frame even when Firefox's handler ends the process. Its deadly-signal
trace walks from `raise()` through the handler into the faulting function, as above. To use it:

- **Image:** artifacts/images/h20-ffquit-diag-evt.img (h20-imgevt with the haiku package's `kernel_arm64`
  replaced; not kept in git).
- **Patch:** artifacts/firefox-quit/20261104-ffquit-diag-evt/diag.diff. It is the vm.cpp / arch_int.cpp part of
  firefox-contentproc-crash.md's diagnostic, plus `FFSIG` lines in `handle_signals()`. Apply it to rpi4,
  `scripts/build.sh --generated DIR kernel_arm64` in a worktree, then
  `package add -f -C DIR haiku-….hpkg kernel_arm64` and `scripts/image-add.sh`.
- **Run:** `firefox-quit-loop.sh` in a network session.
- **Filter the serial log:** drop the noise (`signal 1` = the ssh shells' SIGHUP, `signal 15` = the parent ending
  its content processes) and look for `FFSIG: kill … signal 11` or `FFCRASH: thread … read|write`.

Without the diagnostic kernel, a Firefox parent that dies of SIGSEGV/SIGILL leaves no trace on Haiku.
Firefox's handler runs before debug_server could see the fault, and the kernel does not report a self-raised
signal.
