# Three fixes taken from RenkuOS

2026-11-04. The owner decided (W45, 08:39) to take three fixes from RenkuOS
([github.com/RenkuOS/Source](https://github.com/RenkuOS/Source), a Haiku fork, MIT) into haiku-pi, and nothing else
from that project: no pull requests, contact, forks or posts. Their tree was read at `main` `fe12fcdd3a`.

**Branch:** haiku `renku-fixes-2` (pushed to `origin`): the four commits below on `rpi4` `61fe84cd93`, to be merged
by the main session. They were built and tested first as `renku-fixes` on `rpi4` `b90cb3f0d4` (`2d20fb2ef7`,
`dd668a23f2`, `397fd8597f`, `486e56233c`, also pushed) and moved unchanged (`git range-diff`: identical patches)
when `rpi4` gained two commits that touch other files (BFS mount, usb_disk); the rebased image was built and
booted again (§3, restarts).

| commit | origin | what |
|---|---|---|
| `88be53559b` | RenkuOS `8925cbc599` (PR #189, author atomozero), MIT | `SupportDefs.h`: strong compare-and-swap in `atomic_test_and_set()`/`atomic_test_and_set64()` |
| `fb4e339ce8` | RenkuOS `bff58b0f6b` (PR #231, author Kevin Adams), MIT | launch_daemon: the environment pipe made with `pipe2(O_CLOEXEC)`, closed on the error paths |
| `c7509f4229` | RenkuOS `2fe44aeb62` (PR #160, author Bryan Irvine), MIT | arm64: power-off and reboot through PSCI when the loader found a PSCI conduit |
| `0b22f22f5b` | ours | `bcm2835_pm`: the Raspberry Pi's reboot and power-off through the PM watchdog, for boots without PSCI (ours) |

The three ported commits keep their authors and messages and add `(cherry picked from commit …)` (their commit
inside the PR), `Ported-from: RenkuOS/Source <merge> (PR #n), MIT` and our co-author line. Their tree is a partial
clone, so the commits were applied with `git format-patch` + `git am -3` rather than `cherry-pick -x`; the result
is the same. All three applied without conflicts.

## 1. Strong compare-and-swap (#189)

**The bug.** `atomic_test_and_set(value, new, test)` returns the value it found; callers treat "returned
`test`" as "stored `new`". It was built on `__atomic_compare_exchange_n(..., weak = 1, ...)`, which may fail
spuriously, and on failure writes the value it loaded into `test`. On a load/store-exclusive machine a weak
CAS whose store-exclusive lost its reservation (an interrupt, another CPU's store to the line) therefore returns
`test` without having stored: the caller believes it owns a lock nobody holds. RenkuOS saw "mutex was not actually
locked!" in launch_daemon and net_server (on ARM). Fix: `weak = 0`.

**What our compiler makes of it.** GCC 16.2 for `aarch64-unknown-haiku`, `-march=armv8-a+crc` (no LSE: the
Cortex-A72 is ARMv8.0), has `-moutline-atomics` on by default. Then *both* forms compile to a call of libgcc's
`__aarch64_cas4_acq_rel`/`__aarch64_cas8_acq_rel` (linked into every binary, the kernel included), whose LL/SC
path retries a failed `stlxr`:

```
weak or strong, default flags                weak, -mno-outline-atomics     strong, -mno-outline-atomics
  bl   __aarch64_cas4_acq_rel                  ldaxr w0, [x3]                 ldaxr w0, [x3]
                                               cmp   w0, w2                   cmp   w0, w2
__aarch64_cas4_acq_rel (no LSE path):          b.ne  1f                       b.ne  1f
  ldaxr w0, [x2]; cmp w0, w16; b.ne 1f         stlxr w4, w1, [x3]             stlxr w4, w1, [x3]
  stlxr w17, w1, [x2]; cbnz w17, <ldaxr>     1: ret                           cbnz  w4, <ldaxr>
                                                                            1: ret
```

So the bug is latent in what jam builds for arm64 today; it bites code built without outline atomics
(`-mno-outline-atomics`, 32-bit ARM — RenkuOS's AC100 port —, or another compiler). Checked over the whole build: a
scan of every store-exclusive in the regular image's 565 ELF files plus `kernel_arm64` (`rpi4` b90cb3f0d4 build:
463 store-exclusives; `renku-fixes` build: 463) found **none without a retry test** in either build, and
`libroot`'s `mutex.o` disassembles identically before and after. The kernel uses the same inline from
`SupportDefs.h` (its 10 store-exclusives are the outline helpers). No other weak compare-and-swap exists in
libroot, the kernel, kits, servers or kernel add-ons (`__atomic_compare_exchange*` with weak set and
`compare_exchange_weak` searched: only these two in `SupportDefs.h`; ARM32's `stdatomic.c` has its own loops).

**On the Pi** (`tools/haiku-tests/castest.c`, `tools/pi-tests/castest.sh`, network boot of the `renku-fixes`
image): four threads take a test-and-set lock built on each variant and increment a plain counter under it.
Three runs with one "noise" thread storing to another word of the lock's cache line now and then, three without;
3 s per variant (`artifacts/uart/20261104-092731-renku-cas2.log`):

| variant | acquisitions | increments lost (two owners at once) | "false" acquisitions (lock word still 0) |
|---|---|---|---|
| weak, inline LL/SC (`-mno-outline-atomics`) — the old body | 295.6 million | 158.7 million (53.7 %) | 11.4 million (3.84 %) |
| strong, inline LL/SC (`-mno-outline-atomics`) — the new body | 210.3 million | 0 | 0 |
| `atomic_test_and_set()` from the header, default flags (outline helper) | 213.2 million | 0 | 0 |

The other workers' own successful stores are enough to break the weak lock (the runs without noise lose as many).
A first version of the test whose noise thread stored without pause (`…-090634-renku-cas.log`) showed the
weak variant losing 1 468 367 of 4 000 000 increments, but the strong variant then made no progress in 9 minutes:
a store-exclusive starved by a CPU that keeps writing the line, the Cortex-A72 behaviour behind our WFE fix
`0db3ca639d`; the test now pauses between noise stores.

In the same boot `rw_lock_interrupt_test` passed 20 of 20 and `threadstress` (3000 threads per test, fork, exec,
kill) ended with 0 failures.

## 2. launch_daemon's environment pipe (#231)

**Mechanism.** `BaseJob::_GetSourceFileEnvironment()` (`src/servers/launch/BaseJob.cpp`) evaluates an `env`
source script: it makes a pipe, `posix_spawn()`s `/bin/sh -c '. script; export -p'` with stdout on the write end,
closes its own write end and `read()`s until end of file. launch_daemon launches jobs from up to three worker
threads per CPU (`Worker.cpp`, `MainWorker`), and a job is started with `BRoster::Launch()` → `load_image()`, which
gives the new team every descriptor of launch_daemon that is not close-on-exec (`vfs_new_io_context(parent, true)`
closes only those). A job started by another thread between `pipe()` and `close(pipes[1])` — a window that spans the
`posix_spawn()` (a `vfork()` plus an exec: 3.4 ms on the Pi, HAIKU-RPI4-CHANGES `0fe465e233`) — inherits the write end, and the `read()` sees end of
file only when that job exits. For a server, never.

**Can it hit us?** Yes, the same code runs here. The user session's launch_daemon (`data/launch/user`) evaluates
`/system/boot/SetupEnvironment` twice: for app_server's job (in `Job::Launch()`, on a worker thread) and for the
`desktop` target (in `LaunchDaemon::_LaunchJob()` → `ResolveSourceFiles()`, on launch_daemon's main thread) while
workers launch other jobs. If app_server, Tracker, Deskbar or the UserBootscript's daemons inherit the write end of
the target's evaluation, launch_daemon's main thread blocks for good and the desktop never starts — RenkuOS's "the
user session never started", in 6 of 11 of their boots [their claim]. We had not recorded such a stall: the bench's
10/10 boots (C1, 11-03) and the network boots since reached the desktop; the window is narrow on a 4-core Pi.
A look at what the teams hold after a boot (`tools/pi-tests/launch-pipes.sh`: every team's descriptors on the
pipe's device, via `fdinfo`; one network boot each, `…-093111-renku-lpipes-old.log` = release 11-04b,
`…-093111-renku-lpipes-new.log` = `renku-fixes`) found the same set in both — standard descriptors and the same
few extra ones in app_server (fd 3), input_server (3, 27, 28) and media_addon_server (12, 13), present without the
fix too — so no leaked environment pipe in either boot. The window is a few milliseconds per evaluation, two
evaluations per boot; we never caught the stall, and these boots did not either. (That run listed modes only;
the script now prints device:inode as well.)

**Fix** (RenkuOS's, unchanged): `pipe2(pipes, O_CLOEXEC)`. The child shell still gets the write end as its
stdout/stderr through `posix_spawn_file_actions_adddup2()` (dup2 clears close-on-exec on the new descriptor), so
the environment still arrives; the pipe is also closed on two error paths that leaked it.

**On the Pi: 10 of 10 network boots reached the desktop** (`scripts/boot-bench.sh 10 --netboot --bootscript
tools/pi-tests/launch-env.sh`, the `renku-fixes` image, 09:06–11:08 interleaved with other jobs on the bench;
the bench's grade: app_server set its mode and the kernel debugger's thread list at 158 s has Deskbar's and
Tracker's windows; `artifacts/uart/*-renku-bb-t1..10.log`). The known rate for `rpi4` is the same: 10 of 10 cold
SD boots for C1 (11-03) and every network boot since. So no change and no stall, which at our stall rate (none
seen) is all a 10-boot bench can show; the fix rests on the mechanism above. **Daemons still get their
environment:** in all 10 boots the UserBootscript job, whose only source of these variables is the `desktop`
target's `SetupEnvironment` evaluated through the pipe, printed
`LENV XDG_CONFIG_HOME=/boot/home/config/settings LC_MESSAGES=en.UTF-8 USER=user GROUP=root`. (Trials 3 and 5 have
a million-line serial log: the host capture repeated the previous capture's last line before power-on, a known
host artifact; the boots themselves are normal.)

## 3. Power-off and reboot (#160 + our watchdog driver)

**RenkuOS's change.** `arch_cpu_shutdown()` on arm64 was a stub, so "Shut down" ended in the kernel debugger
("The system is shut down. It's now safe to turn off the computer.") and "Restart" did not restart. They pass the
PSCI conduit the loader found (FADT on ACPI, the device tree's `/psci` `method`) in `arch_kernel_args` and call
PSCI `SYSTEM_OFF`/`SYSTEM_RESET`; they boot the Pi 400 through the UEFI firmware, whose TF-A provides PSCI.

**PSCI on our boot path: absent.** Firmware → U-Boot (EFI) → `haiku_loader.efi`:
- the device tree the firmware passes (`bcm2711-rpi-4-b.dtb`, firmware `6c87074190d5`, which U-Boot hands on) has
  **no `/psci` node**; the CPUs have `enable-method = "spin-table"` with `cpu-release-addr` 0xd8/0xe0/0xe8/0xf0;
- U-Boot `rpi_4_defconfig`: `# CONFIG_ARMV8_PSCI is not set`, `# CONFIG_ARMV8_SEC_FIRMWARE_SUPPORT is not set`,
  `# CONFIG_ACPI is not set` (no FADT either);
- no `armstub` in `config.txt`: the firmware's built-in ARMv8 stub, which parks the secondary CPUs on the spin
  table and provides no PSCI.

So the loader never sets a conduit (`psci_conduit` stays 0) and the PSCI path is skipped, harmlessly. (FreeBSD's
`bcm2835_wdog.c` notes that even on the UEFI path PSCI reset "just puts the Pi into a halt state"; we have not
checked that.)

**Their path, checked in QEMU** (`scripts/qemu-virt.sh`, `virt` + EDK2, the `renku-fixes-2` image with a
UserBootscript that runs `shutdown -q -r`, then on the next boot `shutdown -q`;
`artifacts/qemu/20261104-113452-renku-psci.log`): the loader logs `discovered fadt from acpi: psci_compliant=1,
psci_use_hvc=1`; `shutdown -q -r` → the UEFI firmware banner again → boot 2; `shutdown -q` → QEMU exits (PSCI
`SYSTEM_OFF`), well before the run's time limit.

**Our part** (`0b22f22f5b`). `arch_cpu_shutdown()` falls back to a hook a platform driver installs,
`arm64_set_shutdown_hook()` (`headers/private/kernel/arch/arm64/arch_cpu.h`), when there is no PSCI or it returned.
The new `drivers/power/bcm2835_pm` attaches, like our other BCM2711 drivers, to the device tree node by
`fdt/compatible` (`brcm,bcm2711-pm`, `brcm,bcm2835-pm`, `brcm,bcm2835-pm-wdt`: `/soc/watchdog@7e100000`) and maps
its first `reg` (the PM block, 0xfe100000 after `ranges`). Register facts (BCM2835 power management watchdog; the
same in NetBSD `bcm2835_pmwdog.c` and FreeBSD `bcm2835_wdog.c`, both BSD-2-Clause, and Linux `bcm2835_wdt.c`; the
driver was written from these facts, no code copied):

| register | offset | use |
|---|---|---|
| `PM_RSTC` | 0x1c | reset control; `WRCFG` (bits 4–5) = 0b10: full reset when the watchdog expires |
| `PM_RSTS` | 0x20 | reset status; the partition to boot next in the even bits 0–10 (6 bits spread out); the firmware takes partition 63 (0x555) as "halt" |
| `PM_WDOG` | 0x24 | watchdog timeout in ticks of 1/65536 s (20 bits) |
| — | — | every write carries the password 0x5a in bits 24–31 |

Reboot: partition 0 into `PM_RSTS`, 10 ticks (~150 µs) into `PM_WDOG`, full-reset configuration into `PM_RSTC`.
Power-off: the same with partition 63 — the firmware then halts instead of booting (as Linux does it; the board's
5 V stays on, the SoC idles). Power-off is offered only when the node has `system-power-controller` (it has).
The hook disables interrupts and waits up to 1 s with `spin()`, so it also works from the kernel debugger
(`reboot`, `shutdown` commands); it returns `B_ERROR` if the reset never comes. The PSCI call was also given the
x1–x17 clobbers a failed SMCCC 1.0 call may leave.

Every path ends in the same place: Deskbar's "Restart"/"Shut down" call `BRoster::Private::ShutDown()`
(`src/apps/deskbar/BarApp.cpp:703`), as `shutdown` without `-q` does (`src/bin/shutdown.cpp:185`); the registrar's
`ShutdownProcess` then calls `_kern_shutdown()` (`ShutdownProcess.cpp:1200`) → `system_shutdown()` →
`arch_cpu_shutdown()`. `shutdown -q` calls `_kern_shutdown()` directly; the kernel debugger's commands call
`arch_cpu_shutdown()`.

**On the Pi** (network boots of the `renku-fixes` image; the driver reports
`bcm2835_pm: at 0xfe100000: reboot and power-off through the watchdog` at ~44 s in every boot):

| test | log (`artifacts/uart/`) | result |
|---|---|---|
| `tools/pi-tests/shutdown-test.sh`: boot 1 `shutdown -r` (registrar = Deskbar's Restart), boot 2 `shutdown -q -r` (straight to the kernel), boot 3 `shutdown` (registrar = Deskbar's Shut down), one cycle, no power cycling by the harness | `20261104-090526-renku-shutdown.log` | `shutdown -r` at 66.8 s → U-Boot banner again at 98.8 s → Haiku boot 2; `shutdown -q -r` at 134.7 s → U-Boot at 162.7 s → boot 3; `shutdown` at 198.5 s → the last line at 201.9 s (BFS during the final sync), then **no output for the remaining 278 s** and no U-Boot banner; HDMI black from the next frame on |
| kernel debugger `reboot` (typed at 110/114 s) | `20261104-090646-renku-kdlreboot.log` | `kdebug> reboot` at 114.5 s → U-Boot at 142.8 s → the desktop again (159.7 s) |
| rebased image (`renku-fixes-2`), the same test | `20261104-111118-renku2-shutdown.log` | `shutdown -r` at 68.8 s: **Tracker crashed** (segment violation, 72.5 s) while the registrar quit it; its crash alert waited for a click, so the shutdown stopped at "Asking net_server to quit" (HDMI) and never reached the kernel — see Open |
| rebased image, 5 registrar restarts, then `shutdown -q -r`, then `shutdown`; crashes save a report instead of the alert (the test now sets debug_server's `default_action log`) | `20261104-111925-renku2-restarts.log` | 6 restarts → 6 new U-Boot banners (32 s from `shutdown -r` each), power-off at 471.0 s, then silence for 229 s; no crash report |
| power-off once more (boot count preset to 3) | `20261104-093417-renku-poweroff.log` | desktop (HDMI frame 03), `shutdown` at 67.4 s, then nothing on the serial line for 230 s, HDMI black in every frame from the next one (11 frames) |

The reset takes the firmware's normal ~28 s to U-Boot (as after power-on: 30.8–31.2 s), and the network boot
starts again by itself (the bench's TFTP and disk servers stay up for the whole cycle; the disk keeps what the
previous boot wrote, which is how the test counts its boots). Before, both ended in the kernel debugger. The
power-off evidence is the serial line and the screen: no further firmware or U-Boot output (a watchdog reset
with partition 0 would have shown the banner, as the restarts did) and the display stopped (the display controller
scans out the last frame by itself, CPUs stopped or not, until the SoC is reset). Whether the firmware then also lowers the board's
power use (`POWER_OFF_ON_HALT` in the EEPROM configuration) was not measured; the bench has no power meter.

## Open

- **Tracker can crash while the registrar quits it** (1 of the 10 registrar-driven shutdowns above; segment
  violation in thread 200; no report, as the alert was waiting). With the alert, the shutdown stops for good — on
  the desktop as well (Deskbar's Restart takes this path). Not caused by these commits (it happens before the
  kernel is asked), and not seen before only because a shutdown never got this far on purpose. Not investigated;
  the test now saves reports, so the next occurrence leaves one. Worth a KNOWN-ISSUES line.
- `bfs: Could not find value in index "size"!` / `"last_modified"` at the final sync of most shutdowns of the
  network-boot disk (also before the rebase): an index entry missing for a file removed at shutdown; not looked at.
- Power use after the power-off halt was not measured (no meter); the Pi stays powered by its supply as under
  Linux's `poweroff`, until the plug is switched.
- The stall #231 fixes was never observed here (0 of 10 bench boots, and none recorded before); the fix is taken on
  the mechanism.
