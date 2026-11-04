# Tracker crash while quitting at shutdown: libbe frees the message cache under a running looper (2026-11-04)

KNOWN-ISSUES C15. A network boot of `rpi4` 0b22f22f5b (the RenkuOS fixes, design/renkuos-fixes.md) showed, in
1 of 10 registrar-driven shutdowns, `debug_server: Thread 200 entered the debugger: Segment violation` 3.6 s after
`shutdown -r` (artifacts/uart/20261104-111118-renku2-shutdown.log line 391) and the alert "The application:
/boot/system/Tracker has encountered an error"; the alert waited for a click, so the restart stopped with the
shutdown window at "Asking net_server to quit" (artifacts/hdmi/20261104-111118-renku2-shutdown-05.png … -final).

## Verdict

**Not a Tracker bug, and not one of ours: libbe deletes `BMessage`'s block cache in its termination hook while
the team's other threads still run. Upstream master (4f1074d5e1, 11-04) has the same code.**

1. A program's `exit()` runs the images' termination hooks; libbe's `terminate_after()`
   (`src/kits/app/InitTerminateLibBe.cpp:84`) called `BMessage::Private::StaticCacheCleanup()`, which deletes
   `BMessage::sMsgCache` and sets it to NULL (`src/kits/app/Message.cpp:2101`). The team's other threads are
   killed only after that, when the main thread leaves the kernel's `exit_thread()`.
2. Every `new BMessage`/`delete` goes through that cache (`Message.cpp:249`, `:275`). A looper still dispatching a
   message then calls `BBlockCache::Get()`/`Save()` (`src/kits/support/BlockCache.cpp:107`, `:136`) on NULL:
   a read at 0x34 inside `__pthread_mutex_lock()`.
3. Tracker has such a looper: **BPathMonitor's "PathMonitor looper"**, created on first use and never quit
   (`src/kits/storage/PathMonitor.cpp:2129`). Tracker's Desktop window watches
   `~/config/settings/shortcuts_settings` (`src/kits/tracker/DeskWindow.cpp:345`) and never stops watching, so the
   looper watches that file's ancestors (`/boot`, `/boot/home`, `/boot/home/config`, `~/config/settings`) for
   entries until the end. When an entry is created or removed there while Tracker is in `exit()`, the looper
   faults. Tracker's other loopers are gone by then (windows, TrashWatcher, ClipboardRefsWatcher quit in
   `TTracker::Quit()`, the launch looper in `~TTracker()`).

The faulting thread in every trace is "PathMonitor looper" (`#2 BBlockCache::Save()` ← `BLooper::task_looper()`
(`src/kits/app/Looper.cpp:1270`), or `BBlockCache::Get()` ← `BLooper::ConvertToMessage()` ← `task_looper()`).
Its thread id on the Pi is 202–208 in a first boot (`SDT tracker threads` lines below) — the crash's thread 200
is in that range; Tracker's only other long-lived threads there are 172–179 and 212–226.

Why mostly the **first** boot of a disk: Tracker's watch only reacts to entries created or removed in those four
directories; at the first shutdown, settings directories and files are created there for the first time (later
shutdowns rewrite existing files). This is inferred from the watch, not traced.

Why the alert only sometimes: the fault happens while the team is exiting. Usually the team is already being
torn down when the kernel wants to hand the thread to debug_server (`thread_hit_serious_debug_event(): Failed to
install debugger: ... Operation on invalid team`) — then nothing is visible and the shutdown goes on. In the
crash run the team was still valid: debug_server caught it, could not read its registers (no `stack trace` line,
which debug_server prints for every catch it can read — compare the null-dereference check below) and showed the
alert.

Related classes checked first: the Firefox content-process crash (design/firefox-contentproc-crash.md, a dying
team's stack freed; fix e09cfa1d9e is in `rpi4`) — same "fault while the team dies" signature, different memory
(here a heap object freed by libbe, no stack involved); the STK start hang (design/stk-start-hang.md, rw_lock +
arm64 pending signal) — not involved, the trace has no rw_lock wait.

### Why the shutdown stopped, and what the alert's buttons do

`debug_server` tells the registrar when its alert opens (`B_REG_TEAM_DEBUGGER_ALERT`, open); `ShutdownProcess`
adds the team to `fDebuggedTeams` and, after the system-app phase, `_WaitForDebuggedTeams()`
(`src/servers/registrar/ShutdownProcess.cpp:1905`) waits for it to close. The window keeps its last text
("Asking net_server to quit", the last system app asked). From the code (`src/servers/debug/DebugServer.cpp:887`):
closing the alert with **Terminate** (the default, "Oh no!") lets the shutdown continue; **Debug**, **Save report**
and **Write core file** stop it (`stop shutdown` → `ABORT_EVENT` → the shutdown is cancelled). Not tried on the Pi.
With `default_action log`/`report` (what `tools/pi-tests/shutdown-test.sh` sets) there is no alert and no
registrar notice; in the two QEMU faults below the shutdown went on and the machine rebooted.

## Evidence

### Pi, the unfixed image (`rpi4` 0b22f22f5b)

| run | log (`artifacts/uart/`) | registrar shutdowns | faults |
|---|---|---|---|
| RenkuOS tests (3 fresh disks) | `20261104-090526-renku-shutdown`, `-111118-renku2-shutdown`, `-111925-renku2-restarts` | 10 (3 first boots) | **1** (first boot, alert) |
| stock image, one disk, 25 `shutdown -r` in a row | `20261104-115344-c15-stock-r25.log` | 25 (1 first boot) | 0 visible (stock kernel: silent faults not counted) |
| image + user-fault logging kernel ("diag", below), 15 fresh disks, `shutdown -r` at the first boot | `20261104-12*-c15-cold-1..15.log` | 15 (all first boots) | 0, also 0 silent |
| diag, 4 fresh disks, with the new thread listing | `20261104-14*-c15-poll-1..4.log` | 4 (first boots) | 0 |
| diag, Tracker quit 150 times in one boot (`hey Tracker quit`, its settings removed before each) | `20261104-140807-c15-tql-fresh.log` | — | 0 |

So on the Pi the visible crash is rare: 1 in 54 registrar shutdowns (1 in 23 first boots) on this image. At the
"1 in 10" first estimate, 0 in the 44 later ones would have had a chance of 0.9^44 ≈ 1 %.

### QEMU `virt` (scripts/qemu-virt.sh, the diag image's `haiku-mmc.image`)

Fresh disk per run, `tools/pi-tests/shutdown-test.sh` (boot 1 `shutdown -r`, boot 2 `shutdown -q -r`, boot 3
`shutdown`), three runs in parallel (artifacts/tracker-crash/qemu-cold-hunt.sh):

- **2 of 6 first-boot registrar shutdowns faulted in Tracker**, 0 of 6 later ones (`artifacts/tracker-crash/
  qcold-2-2.log`, `qcold-3-2.log`), both silent (team already invalid for debug_server), both:

```
C15DIAG: thread 191 "PathMonitor looper" team 120 "Tracker" (state 0, main 120) read 0x34 status 0x80001301; ...
C15DIAG:  #0 0x3a287a91f4 libroot.so_seg0rx + 0x5b1f4      __pthread_mutex_lock()
C15DIAG:  #2 0xbc312c0760 libbe.so_seg0rx + 0x253760        BBlockCache::Save()
C15DIAG:  #3 0xbc311ab294 libbe.so_seg0rx + 0x13e294        BLooper::task_looper()
C15DIAG:  #4 0xbc311aa948 libbe.so_seg0rx + 0x13d948        BLooper::_task0_()
thread_hit_serious_debug_event(): Failed to install debugger: thread: 191 (PathMonitor looper): Operation on invalid team
```

  (symbols: `addr2line` on the build's unstripped libbe.so/libroot.so; the segment offsets are file addresses).
- Tracker quit loops in one boot (artifacts/tracker-crash/tracker-quit-loop.sh): 185 plain, 251 with its settings
  removed first, 168 with files created/removed in `~/config/settings` all the time — 0 faults. A Tracker quit
  alone rarely meets a node monitor message in the few hundred microseconds the window is open.

### Reproducer without Tracker: `pmexit`

`tools/haiku-tests/pmexit.cpp` watches `/boot/home/pmx/a/b/settings_file` with BPathMonitor and returns from
`main()` after 1–46 ms; `tools/pi-tests/pmexit-loop.sh` runs it N times while another process creates and removes
`/boot/home/pmx/a/b` (so the looper is busy at the exit). Each fault is the same "PathMonitor looper" read 0x34,
`BBlockCache::Save()` or `Get()` ← `ConvertToMessage()`, almost always "Failed to install debugger" (exit status
0: the team was exiting).

| | QEMU (`artifacts/tracker-crash/qpmx*.out`) | Pi (`artifacts/uart/`) |
|---|---|---|
| unfixed (0b22f22f5b + diag) | **6 of 400** | **11 of 1000** (`20261104-142735-c15-pmx-before.log`) |
| fixed (cc4746af7f + diag) | **0 of 400** | **0 of 1000** (`20261104-144824-c15-pmx-after.log`) |

Chance of 0 by luck at the unfixed rate: QEMU (1 − 6/400)^400 ≈ 0.002; Pi (1 − 11/1000)^1000 ≈ 2 × 10⁻⁵.

### Instruments

- **diag kernel**: `artifacts/tracker-crash/c15-diag.diff` (the user-fault dump of the Firefox investigation,
  renamed `C15DIAG`; not committed): every user fault the kernel turns into a signal prints the thread, its team
  and state, registers and the frame-pointer chain with area names — also for faults debug_server never sees.
  Checked in QEMU with a null dereference (`C15DIAG ... "nullderef" read 0x30`, then debug_server's
  `stack trace` and a saved report).
- `tools/pi-tests/shutdown-test.sh` now lists Tracker's threads before each registrar shutdown (`SDT tracker
  threads 129:Tracker 174:launch_looper 179:w>Desktop 202:PathMonitor_looper 212:w>Tracker_status
  223:TrashWatcher 224:ClipboardRefsWatcher 226:TrackerTaskLoop`), so a crash that leaves no report can still be
  placed by its thread id. A poller logging Tracker's threads during the quit was tried and dropped: on the Pi it
  never printed past its first line (in QEMU it stopped after `TTracker::Quit()`), so it gave no quit timing.

## Fix (haiku branch `c15-tracker`: cc4746af7f on `rpi4` 0b22f22f5b, pushed to `origin`, not merged)

`libbe: keep the message cache when the library terminates` — `terminate_after()` no longer deletes the cache
(a comment says why); the reply ports and `be_roster` are still cleaned up there. The cache's memory goes with
the team. `_StaticCacheCleanup()` stays (it is in the public `Message.h` class declaration). The one other
change in behaviour: if libbe were unloaded and loaded again in a living team, `_StaticInit()` would make a new
cache and the old one would be leaked.

The images tested as "fixed" (`sources/haiku-c15/generated.arm64/haiku-pi4-c15fix.img`, `haiku-mmc.image`) also
carry the uncommitted diag kernel; a release image is built from the branch, which has only cc4746af7f.

Alternatives not taken: stopping the Desktop window's path watch in Tracker (`BPathMonitor::StopWatching()` in
`~BDeskWindow`, which Tracker never does) would only remove Tracker's trigger — net_server, input_server,
launch_daemon, Mail and TextSearch also use BPathMonitor, whose looper nobody quits; making
`operator new`/`delete` test `sMsgCache` would still race with the delete.

What remains of the general hazard: libbe's C++ static objects (`gDefaultTokens`, `gLooperList`) are also
destroyed during `exit()` while loopers may run; none of the 19 traced faults here was there.

## Verification

| | unfixed | fixed |
|---|---|---|
| pmexit, Pi | 11 / 1000 | 0 / 1000 (p ≈ 2 × 10⁻⁵ by chance) |
| pmexit, QEMU | 6 / 400 | 0 / 400 (p ≈ 0.002) |
| Tracker, QEMU first-boot registrar shutdowns | 2 / 6 | 0 / 18 (p ≈ 0.0007 by chance at 2 in 6) |
| Tracker, QEMU later registrar shutdowns (boot 3) | 0 / 6 | 0 / 18 |
| Tracker, Pi first-boot registrar shutdowns (diag kernel: silent faults counted) | 1 / 23 (0 / 19 with diag) | 0 / 10 (`20261104-1[45]*-c15-fixcold-1..10.log`) |
| Tracker, Pi later registrar restarts | 0 / 31 | 0 / 20 (one disk, `20261104-154042-c15-fix-r20.log`) |

The Pi's own Tracker rate (about 1 in 20 first-boot shutdowns, 1 in 54 overall) is too low to verify a fix
directly in a day of bench time; the evidence for the fix is the mechanism (identical traces in Tracker and in
`pmexit`) and `pmexit`'s before/after on both machines. The Tracker rows after the fix are a regression check.

## Open

- Tracker's quit took up to 3.6 s in the crash run (the fault came 3.6 s after `shutdown -r`); how long it
  normally takes on a first boot was not measured (the dropped poller above).
- The respawn storm in the crash run: from the fault on, launch_daemon restarted package_daemon every
  ~0.2 s for 350 s, each start failing "failed to init server application: System shutting down". launch_daemon
  restarts a service only when `IsShutDownInProgress()` fails or says no (`src/servers/launch/LaunchDaemon.cpp:587`);
  the registrar answers `fShutdownProcess != NULL` (`src/servers/registrar/Registrar.cpp:435`), which should have
  been true while the shutdown window stood. Not seen in any clean shutdown; not explained.
- libbe's static objects destroyed under running loopers (above).
- `bfs: Could not find value in index "size"!` / `"last_modified"` at the final sync (also in QEMU): not looked at
  (renkuos-fixes.md Open).
