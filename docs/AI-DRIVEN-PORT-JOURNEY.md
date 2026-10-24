# Porting Haiku to the Raspberry Pi 4, autonomously — a field report

> A dated report: it covers 2026-10-17 23:25 CEST to the late evening of 2026-10-20. For what the
> port does now, see the [showcase](../SHOWCASE.md), [TRY-IT.md](TRY-IT.md) and the
> [User Guide](USER-GUIDE.md). Every number below comes from the weekly logs
> ([WEEK-2026-W42](log/WEEK-2026-W42.md), [WEEK-2026-W43](log/WEEK-2026-W43.md)), where each one is
> recorded with the test that produced it.

*About three days. 216 coordination-repository commits; 113 commits on the Haiku fork's `rpi4`
branch on top of upstream (112 of ours by the evening of 10-20, 114 on 10-21, plus one upstream merge; 156 files, about 33 000 lines added);
14 commits on the Mesa fork, 3 on libglvnd, 2 on Haiku's buildtools. The whole port was done by an AI
coding agent (Claude, in one long-running Claude Code session with sub-agents), started by a single
prompt from the project's owner. The owner wrote no code; [OWNER-PROMPTS.md](OWNER-PROMPTS.md) lists
every prompt they wrote, six by the evening of 2026-10-20. The commits carry the owner's git identity,
but the agent made them. This is an account of what that looked like: what came quickly, what took a
day and a half, where the agent was wrong, and what is still open.*

## Where it started

Haiku is a desktop operating system in the tradition of BeOS. At the upstream revision the port
started from (hrev60262, 2026-10-17), Haiku's arm64 port ran on QEMU's `virt` machine: EFI loader,
GIC, PL011 serial, FDT, PCI, virtio, xHCI, SMP. Nothing was specific to the Raspberry Pi: no board
definition, an SD host driver that attached only through PCI or ACPI, and no drivers for the
BCM2711's Ethernet (GENET), PCIe root complex, VideoCore mailbox, V3D GPU, GPIO or thermal sensor.
There was also no HaikuPorts repository for arm64 (Haiku's own arm64 system packages exist).

What did exist was a lab. The owner's earlier project, a port of Phoenix-RTOS to the same Pi 4, had
left a bench that an agent can drive alone: the Pi network-boots into Linux to write and verify its own
SD card; a serial console and an HDMI capture card are recorded; a switchable plug powers the board;
QEMU has a `raspi4b` machine with a gdbstub. The earlier port had also left notes on how this SoC
behaves (caches, DMA, the firmware handoff, the mailbox, PCIe and the VL805 USB controller, GENET, the
V3D GPU, the WiFi chip). The prompt asked for Haiku on the Pi "on par" with that port — GPU, Ethernet,
WiFi, NFS, SD, GPIO, thermal, SMP — stable and fast, with work pushed to a new GitHub organization,
`haiku-pi`.

## The arc

All times are CEST, from the logs and the commit history.

| When | What |
|---|---|
| 10-17 23:25 | The owner's first prompt |
| 10-17 23:51 | The coordination repository's first commit; Haiku built for arm64 boots to Tracker on QEMU `virt` in under 100 s |
| 10-18 00:39 | **The Haiku kernel on the real Pi, on 4 CPUs**, reaching its debugger (no boot volume yet) — after six generic loader and driver bugs were fixed |
| 10-18 02:00 | **The Haiku desktop on the real Pi**: SD card → U-Boot → Haiku loader → kernel → Tracker and Deskbar on HDMI at 1920×1080. 2 h 35 min after the prompt |
| 10-18 04:00 | USB: a new PCIe root-complex driver, link gen 2 ×1, the VL805 controller, a USB stick and a keyboard enumerate |
| 10-18 05:30 | Ethernet: a new GENET driver, 1000 Mbit/s link on its first run; NFSv4 mounts the bench's export |
| 10-18 07:15 | WiFi: SDIO bring-up at 06:15, then the BCM43455's firmware, a WPA2 join, DHCP and ping |
| 10-18 07:25–19:00 | The GPU: the V3D powers on (07:25), runs jobs (08:15), renders OpenGL ES 3.1 through Mesa 26.2 (10:00), and windowed OpenGL runs 5 minutes on HDMI at 485.6 fps with 0 GPU resets (19:00) |
| 10-19 01:20–01:50 | A display driver: 60.00 Hz retrace, scaled display modes, a hardware cursor on a firmware plane |
| 10-19 05:10–07:55 | QuakeSpasm and Quake II on the V3D; the first package built natively on Haiku arm64 by haikuporter; the regular Haiku image (all applications, media kit) builds for arm64; audio on the 3.5 mm jack |
| 10-19 10:30–23:40 | NetSurf renders https://www.haiku-os.org/ (10:30); Bluetooth through Haiku's stack (14:10); a CPU stall that had been chased since the first night root-caused (21:30); `pkgman` installs from our own repository (22:45); WebPositive (HaikuWebKit) renders the same page (23:40) |
| 10-19 22:53–23:16 | The owner's prompts 2–5: publish packages, weekly upstream merges, a portable repository, a test script for the owner, network boot, hardware video decoding, Firefox, screenshots |
| 10-20 00:05–02:50 | Packages published on GitHub Pages; the first upstream merge; Vulkan in a Haiku window; network boot from the build host (02:10); HEVC decoded by the SoC's decoder block, bit-exact, and vkQuake on Vulkan (02:50) |
| 10-20 03:20–07:40 | Rust 1.90 for `aarch64-unknown-haiku`; Firefox's JavaScript engine with its JIT (04:10); HEVC 1080p at 115 fps (04:30); OpenArena and CPython 3.14 (04:55); C++ exceptions found broken and fixed in the toolchain (06:30–07:30); SuperTuxKart (07:30); **Firefox 157 renders https://www.haiku-os.org/** (07:40) |
| 10-20 08:30–21:10 | OpenGL ES contexts in Haiku windows; a 15-minute soak of Firefox + SuperTuxKart + 1080p HEVC at once, 0 crashes; vkQuake 29 → 52 fps; SD 43 MB/s; SDL's double free; WebGL and video in Firefox; ICU rebuilt; user/kernel time accounting |
| 10-20 evening | Kernel profiling on arm64; kernel stacks faulting inside the exception vector fixed (22:35); the kernel's debug level lowered, Ethernet ~915 Mbit/s each way (23:45) |

A few things from those three days, by area:

- **Boot and kernel**: four CPUs; a GIC-400 setup that matches Linux; a fix for a livelock in the
  kernel's spin-waits on the Cortex-A72; a cpufreq driver; user time counted as user time; kernel
  stack traces and profiling on arm64; spinlock deadlock detection by time.
- **Devices**: SD at UHS-I DDR50 (43 MB/s reads), USB 3 storage at 78–90 MB/s, GENET Ethernet at ~915
  Mbit/s, WiFi at 37 up / 46 down Mbit/s, Bluetooth, PWM audio, the hardware random number generator,
  thermal and clock readouts, GPIO, the HEVC decoder block.
- **Graphics**: an in-kernel V3D driver exposing Linux's `v3d` interface, Mesa's `v3d` (OpenGL 2.1,
  OpenGL ES 3.1) and `v3dv` (Vulkan 1.3) drivers, a Haiku Vulkan WSI, a zero-copy present path, a
  display driver on the firmware's planes.
- **Software**: 88 arm64 packages built from HaikuPorts recipes and published; WebPositive, NetSurf
  and Firefox 157; five 3D games; CPython 3.14; Rust; llama2.c.

## What was easy for the agent

Broadly: **anything with a reference implementation and a fast test.** Several drivers worked on
their first run on the hardware:

- The **VideoCore mailbox** module worked first try (it gave the SD controller its 100 MHz base
  clock).
- The **GENET Ethernet driver**, drafted by a sub-agent from the Linux driver and the earlier port's,
  with each register sequence cited: 1000 Mbit/s full duplex and ping at ~0.5 ms on its first boot.
- The **V3D** identified itself with exactly the register values the earlier port had recorded on
  this board, so the GPU work started from known ground.
- The **PWM audio driver** measured 44117.657 Hz against a programmed 44117.647 Hz over 128 periods,
  0 underruns, on its first run.
- The **HEVC decoder** was tested against a mock driver on the build host first (4 clips and 24
  encoder-tool variants bit-exact under AddressSanitizer), so its first run on the Pi decoded 223
  pictures, all bit-exact against FFmpeg's software decoder.

Breadth came easily too. The regular Haiku image needed a long tail of ports cross-built and packaged
before it would even link — tar, gzip, bzip2, unzip, libogg, libvorbis, fluidlite, zstd — and later
the web stack (OpenSSL, curl, brotli, dav1d, libxml2, ICU, WebKit) and the games. These were done by
sub-agents and scripts in parallel with the bench work, while the one shared Pi ran a single cycle at
a time. Once one Pi driver worked, the next ones (thermal, GPIO, cpufreq, the random number
generator) followed the same pattern.

Many generic bugs in upstream Haiku were found on the way and fixed, among them:
the EL2-to-EL1 drop overwrote the translation table base, so secondary CPUs ran with TTBR0 = 0; the
SDHCI driver acknowledged write-1-to-clear interrupt status with `|=`, losing "transfer complete"; the
FDT bus ignored parent `ranges`; `get_next_child_node()` returned only the first child; arm64 never
set `CNTKCTL_EL1` on the EL2 path, so reading the virtual counter from user mode trapped (the earlier
port had hit the same bug); Mesa's v3d driver never initialized its buffer-cache mutex (zero-filled
memory is an unlocked mutex on glibc, not on Haiku).

## What was hard — and why

The hard cases share the shape the earlier port's report described: **the cause was in state that no
log showed**, and the first measurements were misleading.

### The boot freeze that was a livelock (43 hours)

At 02:45 on 10-18, less than an hour after the first desktop, boots began to stop silently during the
first burst of SD I/O. What followed is worth telling in order, because most of it was wrong.

- **03:45 — "gone empirically (8/8)."** A GICv2 write barrier and a change to the serial emergency
  keys were followed by 8 good boots. The log said the mechanism was not understood. It was not gone.
- **16:50 — a correction.** The bench had not measured the freeze at all: the test cycle typed a probe
  key at 150 s, which *woke* a frozen boot, and the boot bench passed any log that reached the desktop
  eventually. With a new `--kdl-first` mode (no probe; the kernel debugger at 158 s is the first
  wake) the real rate was **5 of 10**. An earlier "38/38" was withdrawn in the log.
- **22:30 — layout-sensitive.** Trivial kernel changes swung the rate between 0/12 and 5/10, as a
  long-running crash in the earlier port had. The one A/B with an identical kernel binary: V3D driver
  present, 6 of 12 froze; driver blocked by settings, 0 of 10. The driver's presence shifted the rate; it was not the
  mechanism.
- **10-19 00:30 — a workaround.** A watchdog on every CPU, checking every 250 ms for a CPU whose timer
  was overdue, sent it an interrupt: 10/10 boots. The picture it reported — the SD controllers'
  interrupt shown "active" on CPU 0, which then took nothing — pointed firmly at the GIC.
- **14:10 — the soak.** Under load (Quake, an SD write loop, pings for 20 minutes) the watchdog
  recovered **10 stalls**. This was not a rare boot problem; it was once every two minutes.
- **16:20 — Linux parity, no effect.** The GIC setup was rewritten to match Linux's (priorities,
  active states, EOI mode): 21 stalls in 30 minutes, then ~23 in 15. Neither touched it.
- **21:30 — the cause.** Routing the SD interrupt to CPU 1 moved the stalls there, and then they
  appeared after any interrupt on any CPU. The stalled CPU's own registers settled it: **`CNTV_CTL` =
  0x5, the timer had fired on time, and interrupts were masked.** The CPU was not deaf; it was busy
  with interrupts off. The interrupted PC (through `addr2line`) showed two CPUs: one in the SD
  interrupt handler spinning in `ConditionVariable::_NotifyLocked()`, the other in
  `ConditionVariableEntry::_RemoveFromVariable()`. The Cortex-A72 has no LSE atomics, so atomic
  operations are load-exclusive/store-exclusive loops; the notifier's tight polling of the cache line
  that also held the lock kept clearing the waiter's exclusive monitor, and the waiter's store kept
  failing. It ended when anything else touched that line or the GIC — which is why the watchdog's
  interrupt "fixed" it.

The fix is Linux's: on arm64 a spin-wait sleeps in `WFE` on the cache line, the generic timer's event
stream bounds every `WFE` (every 152 µs), and `try_acquire_spinlock()` tests before it exchanges. The
watchdog and every stall diagnostic were deleted. Boot bench 10/10 without the watchdog; a 20-minute
soak clean.

Why it was hard: every observation was true and pointed the wrong way. "The SD interrupt is active
on CPU 0" was correct — the handler had not finished, because it was spinning. The answer came from
reading the stalled CPU's own view instead of the interrupt controller's.

### The windowed OpenGL wedge

OpenGL ES rendered into off-screen buffers at 10:00 on 10-18; every frame in a *window* hung the GPU.
The signature (the tile list stuck, the shader processors idle) was the same whatever was ruled out:
y-flip, BGRA, multiple tiles, early-Z, fixed function, the clear path. One early conclusion, "not the
depth buffer", was wrong because Haiku's EGL always asked for depth. The cause was in Mesa's Haiku
frontend: it hard-coded a Z24_UNORM_S8_UINT depth/stencil format for every window, which the V3D cannot
render (it supports S8_UINT_Z24_UNORM). The deciding experiment was an off-screen buffer with a
GL_DEPTH24_STENCIL8 renderbuffer, which rendered: the difference was the format.

### The measurements that measured the wrong thing

On 10-19 at 12:30, QuakeSpasm at 1920×1080 ran at 19–27 fps where the earlier port managed 44 on the
same board. Clock readouts added to the thermal driver showed why: **about two minutes after power-on
the firmware drops the ARM from 1500 to 600 MHz and the core clock from 500 to 200 MHz, for good**,
unless an operating system asks for a rate (Linux's cpufreq driver does). Every measurement taken after
the first two minutes had run at 40 % of the CPU clock — the games, the WiFi benchmark, and an earlier
"the GL window is capped at the refresh rate", which turned out to be the slow ARM. A cpufreq driver
fixed it: QuakeSpasm 1080p 30–43 fps, 720p 56–70.

The same day had an earlier example: QuakeSpasm's "≤10 fps" came from a timedemo that never printed a
result. Counting presented frames in Mesa and jobs in the V3D driver gave 61–71 fps at 640×480.

### ICU had no data

WebPositive needed ICU, and ICU had never found its data on arm64: the bootstrap ICU package had been
built with its data directory under the package's *build* name, but was activated under a different
one. Time zones, collation and break iterators had been failing silently — including in Haiku's own
locale code. A one-line environment variable fixed WebPositive; an empty package activated under the
expected name fixed every process; on 10-20 ICU was rebuilt properly with its data inside the library,
so no path can be wrong. The same trap turned up again in the ncurses bootstrap package, where every
curses program had fallen back to "dumb terminal settings".

### C++ exceptions broken by the toolchain

The SuperTuxKart port found that **every `throw` in a cross-built port ended in `terminate()`** —
even `throw 42` in `main`. The arm64 cross g++ linked only the static libgcc, because a configure
probe for `--as-needed` fails while a cross gcc is configured before its binutils exist. A program's
unwind tables then registered with that private unwinder, which libstdc++ never consults. Haiku's own
binaries were fine (its build links `libgcc_s` explicitly); ports were not. The first fix had no
effect at all — Haiku's cross gcc is configured `--disable-shared`, so it builds no libgcc spec — and
the second spelled the spec out. A scan of all 85 packages then found which ones throw or catch (only
`glu` and `mesa`), and those were rebuilt.

### SDL's double free

OpenArena crashed at fullscreen start with a "double free" in 6 of 22 starts. Under Haiku's guarded
heap it crashed in **0 of 17**, and no stray access was trapped. A slower allocator hiding the bug
pointed to a race rather than a bad write. The cause: SDL's Haiku backend ran window events on the
application's looper thread, and a fullscreen window's "shown" event set the display mode at the same
moment the game's thread did, both filling the same mode list without a lock. The fix moves event
handling to the thread that pumps events, as SDL's other backends do: 21 of 21 starts clean.

### User time counted as kernel time

An FFmpeg benchmark reported 2.2 s of system time against 0.7 s of user time. A pure Python loop
showed `user 0.013s sys 4.32s`: the accounting was wrong, not the decoder. On arm64 the kernel ran its
exit-to-user accounting on every return to user mode but its entry accounting only on system calls, so
a thread interrupted by its timer had its whole user stretch counted as kernel time. After the fix the
same loop shows `user 4.17 s, sys 0.19 s`, and `time`, ProcessController and ActivityMonitor tell the
two apart.

### Ethernet 600 → 915 Mbit/s, and a kernel stack that faulted inside the exception vector

With the accounting fixed, the TCP sender was visibly CPU-bound in the kernel (0.78–0.84 s of
0.90–0.95 s). A faster checksum, tested on 200 000 random buffers on the host, made no measurable
difference on the Pi and was not kept. Kernel profiling did not work on arm64 (two stubs put every
sample in the commpage); once implemented, it showed the slab allocator at ~31 % and mutexes at
~14 % — mostly the cost of Haiku's development debug level, `KDEBUG_LEVEL 2`.

Lowering the debug level exposed real bugs. arm64 and arm fetched the signal handler's address inside
`ASSERT()`, and the FDT bus manager fetched each device's node inside `ASSERT()` in nine places:
without the debug level, every signal handler and every Pi driver would have read garbage. Then level
1 panicked at boot with a write fault on a kernel stack taken inside the exception vector. On arm64
the access flag and dirty state are managed in software (the A72 has neither in hardware), so a fresh
kernel stack page faults on first access — and when that first access is the exception entry code
storing a frame, every nested exception faults on the same page again. Kernel stacks are now mapped
accessed and writable from the start. At level 1: **upload 600 → 914 Mbit/s, download 660 → 918**
(gigabit's TCP payload ceiling is about 940), with an SD boot bench, a 15-minute application soak and
15 network boots as the check.

### The network-boot wedge (open)

About one network boot in 18 to 45 stopped about 54 s in, while network drivers loaded and the first
boot's package processing read the remote disk. The serial line went quiet, HDMI froze, the kernel
debugger did not answer, and the remote disk's requests stopped: the whole machine, not just its
output. The hunt so far:

- **A wedge that could not speak.** The agent's own `WFE` fix made each spin iteration last up to
  ~150 µs, while Haiku's spinlock deadlock panic still counted 100 million iterations — about four
  hours. Deadlock detection is now by time (5 s for a spinlock, 10 s for a synchronous inter-CPU call,
  which was never checked before).
- **A UART that could take everything down.** The PL011 driver waited for FIFO room without a limit;
  the first CPU to print would spin holding the debug output lock, every other CPU behind it. It now
  gives up and drops output.
- **A hypothesis refuted.** All three captured wedges came about 6 s after the cpufreq driver asked
  the firmware for turbo; with turbo removed, 42 boots ran clean — then the 43rd wedged at 53.9 s.
- **No post-mortem.** The plan was to leave breadcrumbs in RAM and read them after a watchdog reset.
  A test from U-Boot showed that **RAM does not survive a reset on the Pi 4**: every pattern came back
  scrambled.
- **A candidate.** The kernel-stack fault above — a CPU caught in a cascade with interrupts off would
  stop silently, during heavy thread creation while interrupts arrive — had the right shape. After
  that fix, 15 network boots ran clean; the 16th wedged (2026-10-21, 00:00). Another plausible hypothesis
  refuted by counting.
- **Another observer effect that wasn't.** A lock-free "heartbeat" drawn into the frame buffer ran 30/30
  clean, and so did a variant — which looked like the instrumentation hiding the wedge, until the
  unmodified image ran 25/25 too. The variable that mattered was time: every captured wedge came on
  a Pi that had been **powered off for minutes**; back-to-back series (~10 s off) almost never see it
  (about 1 in 250, against about 1 in 10 cold). Cold SD first boots ran 12/12 clean.

It stays open, characterised: a cold-start problem of network boots, rare enough that a cause needs a
cheaper way to reproduce it.

## Techniques that mattered

1. **Benches, not single boots.** `boot-bench.sh N` flashes, boots and dumps the kernel's state for
   each of N trials. It was itself wrong twice (the probe that woke frozen boots; a desktop test that
   looked for a log line that only appeared when something *failed*), and each time the fix to the
   bench came before the next claim. Every change that touches boot gets a bench; the second and third
   days ended with soaks under load.
2. **Ask the machine for its own view.** Serial emergency keys that drop a running system into the
   kernel debugger, new debugger commands for the GIC and the timers, per-CPU stack dumps, and
   finally the stalled CPU's own timer register — which ended the livelock hunt.
3. **Measure before optimizing.** The frame counter in Mesa and the V3D driver's job statistics, the
   clock readouts, `time` (once it was correct), and a working kernel profiler. Twice a plausible
   optimization (the checksum; GPU plane flips, estimated at ≤ 15 % at 1080p because the GPU was 95 %
   busy) was measured or estimated first and put aside.
4. **Test on the host first.** The HEVC decoder against a mock driver under AddressSanitizer; the
   checksum on 200 000 random cases; the from-scratch build run by a sub-agent in a fresh clone,
   following [TRY-IT.md](TRY-IT.md) exactly (four workarounds found and fixed in the scripts, then a
   clean run in ~24 minutes).
5. **A/B with one variable.** The decisive freeze experiment kept the kernel binary identical and
   changed only a package setting. The "Failed to copy image data" messages in Firefox looked like
   lost frames until two instrumented builds showed the branch never fired: upstream logs the message
   whether the copy fails or not.
6. **Write refutations down.** The logs list what was ruled out — an interrupt storm on the shared SD
   line, a lost inter-CPU interrupt, a stalled UART, the boot-time page table, the firmware overlay,
   turbo — with the test that ruled it out. Several earlier claims are struck through in place rather
   than deleted.
7. **No SD writes per iteration.** By 10-20 the Pi network-booted any freshly built image in about
   60 s, its boot volume served from the build host as a remote disk.
8. **A loop that survives the agent's own limits.** A cron heartbeat every 30 minutes resumes work from
   the weekly log's "Next" list and the plan when the session is idle, and a weekly job merges upstream
   Haiku, builds, benches and pushes only when green. Long builds and ports (WebKit, Firefox, Rust,
   SuperTuxKart) ran in sub-agents while the main session kept the bench busy.

## The human's actual impact

[OWNER-PROMPTS.md](OWNER-PROMPTS.md) holds every prompt the owner wrote, verbatim. The first one
carried the port to the desktop on real hardware and on through USB, Ethernet, WiFi, the GPU, Quake,
audio, Bluetooth and two browsers — about 47 hours of work. Prompts 2–5, sent within half an hour on
the evening of 10-19, added direction: publish the arm64 packages on GitHub Pages, merge upstream
weekly, keep the repository free of machine-local paths, write a test script for the owner, support
network boot, decode video in hardware, port Firefox, take screenshots for a forum post. All of it was
delivered the next day. Prompt 6 asked for the prompt list itself.

What the agent could not do is the same list at the top of the log's "Next" section from the second
day on:

- **Hands and ears.** Typing on the USB keyboard, moving the mouse, keys in an SDL game, listening to
  the headphone jack. The devices enumerate and the audio clock is measured; whether a person can use
  them is unverified.
- **Eyes on a real monitor.** While a GL client runs, frames from the HDMI capture card show ~0.2 % of
  pixels off-colour, at different places in consecutive frames of a static desktop. Whether a real
  monitor shows them, or only the capture card, needs a person.
- **Decisions.** Whether the Firefox package may be published under its official branding, and where
  to host packages over GitHub's 100 MB file limit (the games). The owner settled both on 2026-10-21:
  publish Firefox as it is, and fit big packages under the limit (zstd, data split into parts) rather
  than run another host.

## What the earlier Phoenix-RTOS port contributed

The prompt asked the agent to use the earlier port as a source of tools and knowledge, and it did:

- **The bench and its rules**: the network-booted flash lane, the capture scripts, one Pi cycle at a
  time under a lock shared with the Phoenix-RTOS work, heavy builds under a memory cap.
- **Notes on the hardware**: 19 notes in `docs/knowledge/from-phoenix/` (caches and DMA, the firmware
  handoff, the mailbox, PCIe/VL805, GENET, the V3D, WiFi). Some answered questions before they were
  asked: the earlier port had used **ADMA2** on the SD controller ("no in-tree driver uses SDMA on
  BCM2711"), knew that the V3D's clock stays off without a firmware overlay, and had hit the same
  `CNTKCTL_EL1` bug.
- **A specification for the GPU driver**: the V3D kernel driver was written with the earlier port's
  GPU server as its reference, and its measured register values as the check.
- **A yardstick**: the same board, the same games. QuakeSpasm at 640×480: 61–71 fps (the earlier port:
  ~40). SuperTuxKart's GLES shader renderer: 16–18 fps at 1280×720 (8–12 there). llama2.c with the
  15M model: 45.7 tokens/s (5.8 there).
- **A warning that held**: when trivial changes swung the freeze rate, the log compared it to the
  earlier port's layout-sensitive crash and stopped trusting small A/Bs.

## Where the agent was wrong

- "Boot freeze: gone empirically (8/8)" and "38/38" — both withdrawn; the bench did not measure it.
- "Not the depth buffer" — it was the depth buffer's format.
- "0 wedges in 42 since turbo went away" — refuted by the 43rd boot.
- The first toolchain fix for C++ exceptions did nothing.
- Two image builds shipped **without SDL2**, because a package revision was listed but not staged and
  the build only warned. The three-part version bump is now a written rule.
- A first pipelined remote disk gave up on a request after 2.5 s instead of 25 s; one boot in seven
  stalled until the budget was restored.

Each was caught by the agent's own later measurement and corrected in the log in place.

## Open issues

- The network-boot wedge (above); SD boots are not affected.
- An early-boot hang, seen once in about 30 boots on 10-20, not reproduced since.
- Firefox drops frames on H.264 video (121–271 of 300 in tests; VP9 and AV1 about 4 %); decoding keeps
  up, presentation does not (no GPU compositor in Firefox on Haiku).
- Audio, keyboard, mouse and Bluetooth pairing are not checked by a person.
- No hardware H.264 decoding (on the BCM2711 it is VideoCore firmware only) and no HDMI audio.
- About one ioquake3 run in four needs SIGKILL after SIGTERM; under heavy load the audio time source
  once published nothing for 16 s.
- GPU plane flips and asynchronous queues are deferred. Native haikuporter builds on Haiku arm64 have
  produced one test port so far; the published packages are cross-built on the host.

Next on the plan: Windows programs through Wine with x86 translation ([PLAN.md](PLAN.md), H15).

## Takeaways

- **A good bench turns hardware into a fast loop.** The desktop on real hardware took 2 h 35 min,
  in good part because the lab, the flash lane and the notes already existed. The agent's speed was bounded by
  how quickly it could boot, observe and compare.
- **The proxy metric fails first.** The two hardest bugs were hidden for hours by a bench that woke
  what it was supposed to detect and by measurements taken at 40 % CPU clock. Checking what a metric
  actually measures was worth more than any single fix.
- **Read the stalled thing's own state.** A day of GIC theories ended when the stalled CPU's own timer
  register said the interrupt had fired and interrupts were masked.
- **Reuse beats generation, again.** Drivers came up fastest where a reference existed (GENET from
  Linux and the earlier port, WiFi from OpenBSD's `bwfm`); the GPU stack is upstream Mesa; Firefox is HaikuPorts' native port
  carried to arm64. The agent's own code was mostly glue and fixes.
- **Generic bugs surface on new hardware.** Much of the work was in upstream Haiku code that had
  only run on QEMU: EL2 handling, the GIC, SDHCI, the FDT bus, the toolchain, `ASSERT()` side effects,
  time accounting, kernel stacks. A real board and a lowered debug level found them.
- **One prompt is enough to start; a person is still needed to finish.** The owner's 27 prompts (in six days) set
  direction. What remains open is what only a person can check — a keyboard, a speaker, a monitor —
  and decisions that are theirs to make.
