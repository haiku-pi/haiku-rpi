# Performance, next round (H20): a ranked candidate list

Written 2026-11-03 (desk work, no Pi time used) from the measurements this repository already has. PLAN.md
backlog row 6: "a measured list ranked by gain/effort, then done in that order". Baseline system:
**image-2026-11-03b** (haiku `rpi4` 5d9132a49c, hrev60299+262, GCC 16.2, GPU stage 7 queues, DWARF 5).
Nothing here was measured today; every number is quoted from a log entry or document named next to it. C0 was run
the same evening: its measurements and the re-ranked list are in §6 "C0 results".

Legend. **measured**: a number in the named file/log entry. **derived**: arithmetic on measured numbers (shown).
**estimated**: a guess with its basis stated. **unmeasured**: no number exists. Effort: **S** = under a day,
**M** = 1–3 days, **L** = more than 3 days (all including the Pi runs). Sources are `file:line` or
`W43`/`W44`/`W45` (= `docs/log/WEEK-2026-W4x.md`) with the entry's date and time.

## 0. Rules for every item below

1. **Quote the 11-03 baseline, not older tables.** The Wine *windowed* numbers in gcc16.md and lto.md were taken
   behind Haiku's screen saver (it starts after 900 s, during the Wine tests; a window behind it is never shown),
   13–19 % higher than on screen (W45 11-03 09:55, `scripts/games-bench-image.sh` header). The saver-off table is
   `artifacts/queue-1103/gb6s-table.md` (stage-6 A/B, saver off, 3 boots each); only it is comparable with future runs.
2. **Alternate, three boots per side** (A, B, A, B, A, B), network boots, as gcc16.md "Performance comparison".
   Rates settle per boot: gltest arm64 162.7 / 168.6 / 187.6 on three boots of one image (W43 10-28 21:03);
   inside a boot ±1 %.
3. **Same compiler on both sides.** The stage-6 A/B had a confound (Mesa -1 built with 13.3 vs -2 with 16.2,
   gpu-stage6.md §10). Anything that changes a package changes both images' package set the same way.
4. **Pi bench is shared and the cycles hold its lock** (`scripts/sd-cycle.sh`, `scripts/netboot-cycle.sh`,
   `scripts/pi-session.sh`); a Firefox change waits for the content-process crash hunt of 11-03 16:20 (W45).
5. An item is "done" only with a before/after row in this file's §6 table, from the same kind of run.

## 1. Baseline numbers (image-2026-11-03b and the 11-03 benches)

| Area | Number | Source |
|---|---|---|
| Games, saver off: QuakeSpasm 640×480 / 720p / 1080p | 202.5 / 80.3 / 41.0 fps | `artifacts/queue-1103/gb6s-table.md` (rpi4 column) |
| vkQuake 720p / 1080p; Quake II 640×480 / 720p / 1080p | 54.9 / 33.1; 206.8 / 102.3 / 53.1 fps | same |
| Quake III 720p; OpenArena 720p window / 1080p full screen; STK 720p | 89.0; 53.3 / 28.1; 37.6 fps | same |
| Wine gltest arm64 / x86; d3dtest x86 window / full screen; d3dtest arm64 full; Half-Life window | 161.6 / 163.6; 126.4 / 142.6; 149.9; 90.7 fps | same |
| Wine prefix creation (fresh network boot of the bench image) | 126 / 126 / 131 s | same, last line |
| glmark2-es2 window / full screen (800×600 / 1920×1080) | 330–337 / 88–90 | gcc16.md:433, lto.md:234 |
| App first launch → first window: Terminal, StyledEdit, DeskCalc, ShowImage | 110–120 ms, then 35–100 ms | gcc16.md:436 |
| Debugger / MediaPlayer first launch (16.2) | 166–186 / 77–92 ms | gcc16.md:434-435 |
| Firefox window: first launch / warm / quit | 10 236 ms (network boot) / 3 072, 3 068 ms / 4 801, 2 164, 1 926 ms | `artifacts/queue-1103/relcheck-1103b.log` |
| Firefox first launch after boot, from the card; warm | 8.2 s; 3.1–3.5 s | W43 10-25 01:43; 10-24 23:21 |
| SD boot, loader banner → desktop cursor (warm) | 5.4–5.8 s | gcc16.md:439; PLAN.md row H13 |
| SD card: raw read; 128 MB write + fsync | 42.6–45 MB/s; 19–22 MB/s (10-23: 6–8 MB/s sustained) | HARDWARE-SUPPORT.md:89; W43 10-25 01:43, 10-23 10:45 |
| TCP Ethernet up / down; WiFi up / down | 914 / 918; 37.4 / 46.0 Mbit/s | HARDWARE-SUPPORT.md:105, :114 |
| fork+exec / posix_spawn / thread create+join | 4.7–5.0 ms / 3.4–3.5 ms / 49.5 µs | W43 10-24 13:46, 16:25; W44 10-29 01:44 |
| Python 3.14 start cold / warm; `sum(range(1e7))` | 0.33 / 0.09 s; 0.81 s | gcc16.md:437-438 |
| cpubench (ms): arm64 / Box64 x86 / FEX x86 (TSO off) / FEX x86-64 | 1969 / 2957 / 2650 / 17 311 | wine-x86.md:163-172 |
| HEVC 1080p / 2160p hardware decode | 114.8 / 38.2 fps | HARDWARE-SUPPORT.md:75 |
| Temperature in the games bench | 58–73 °C, throttle flags 0x0 | gb6s-table.md footer |

## 2. Already done: do not redo

Each row is merged on `rpi4` (the image carries it) unless marked.

| Item | Measured effect | Source |
|---|---|---|
| **LTO of Haiku's userland** (ruled out, owner 11-02) | games/GPU/launch ±1 %; Wine gltest arm64 **−4 %** in all 3 rounds; Python cold −4 %; +17 % build time, libroot +5.9 % text | lto.md:222-252 |
| **GCC 13.3 → 16.2** (adopted, neutral) | games, GPU, Wine, Python within noise; Debugger first launch −15 %, MediaPlayer −25 %; SD boot 5.4–5.8 s both | gcc16.md:415-448 |
| GPU stage 7 (concurrent queues, in the image) | +1–3 %: QuakeSpasm 79.1 → 80.0, glmark2 337 → 339/348 → 360 | W45 11-03 00:50, 02:21 |
| GL present path: A1–A3 (Mesa) + B1 (v3d) | glmark2 build 1080p 73 → 110 fps, whole glmark2 233 → 304 (window), 64 → 81 (1080p) | gpu-present.md:3-5 |
| C1 fused app_server copy | `DrawBitmap+Sync` 1080p 6.92 → 6.04 ms; vkcube 117 → 132 fps; glview 233 → 271 | W43 10-25 12:56 |
| Mesa shader disk cache | Photocraft pipelines 41.3 → 0.26 s on the second start | W43 10-25 04:56 |
| V3D compiler liveness (3.5×) | Photocraft pipelines 43.1 → 11.8 s; one shader 33.5 → 6.6 s | W43 10-25 14:23 |
| Thread-local storage fast path | TLS access 35 → 17.4 ns; Python `sum(i*i …)` 521 → 391 ms | W43 10-24 04:55 |
| Arm Optimized Routines + kernel user copy | memcpy 1 KiB 5280 → 11 223 MB/s, unaligned 731 → 9036; `read()` at an odd offset 630 → 2060–2350 MB/s | W43 10-24 05:47 |
| `arch_cpu_sync_icache` loop 16× too fine | fork+exec 7.8 → 4.7 ms; posix_spawn 7.4 → 3.4 ms; shell loop 1.87 → 1.07 s | W43 10-24 13:46 |
| GNU hash for everything jam links; `-Bsymbolic-functions`; gcc_syslibs with GNU hash | Terminal 95 → 80 ms, MediaPlayer 120 → 81; then Debugger 94 → 74, Terminal 84 → 75; syslibs lookup misses 2249 → 0 | W43 10-24 13:46, 17:27; W44 10-28 23:40, 10-29 00:37 |
| Thread stacks of exited threads reused | thread create+join 75 → 49.5 µs | W44 10-29 01:44 |
| `/dev/random` as ChaCha20 | 16-byte reads 145 → 2.3 µs; 4 KiB 2.8 → 149 MB/s | W43 10-24 14:40 |
| `poll()` no longer rewrites `events` | Firefox quit: 4306 → 141 `poll()` calls | W43 10-24 15:15 |
| ICMPv6 errors + own host name resolves | Firefox from the card, first launch 21.6–23.0 → 9.1 s; later 17.1 → 3.1–3.7 s | W43 10-24 22:37, 23:21 |
| Scheduler: busy threads stuck on one core | 10/10 stuck → 0/10; 412–474 s run → 81 s | W44 10-29 16:47, 18:35 |
| `KDEBUG_LEVEL 2 → 1` | TCP upload 600 → 914 Mbit/s | HARDWARE-SUPPORT.md:42 |
| Serial output: queued, sent from the UART interrupt | desktop ~1 s sooner (boot volume → cursor 5.35/5.48/4.47 → 4.64/3.84/3.83 s) | W44 10-29 00:26 |
| Loader traces off the console | loader → kernel 1.0 → 0.4–0.6 s | W44 10-28 22:32 |
| Loader chunk cache + U-Boot EMMC2 no 1 ms wait | loader phase 3.1 → 1.2 s | W43 10-23 03:00 |
| Loader loads 57 modules instead of 139 | loader 2.0 → 1.2–1.4 s | W43 10-24 20:17 |
| U-Boot starts USB only when the card has nothing to boot | U-Boot banner → "Booting" 1.8 → 0.6 s | W44 10-28 22:12 |
| USB explored in parallel; boot reprobe keeps modules | boot volume 7.1 → 5.8 s; reprobe 2.9 → 0.76 s | W43 10-24 02:41 |
| remote_disk hello retried every 1 s (network boot) | boot volume 5–9 s after link → 29–35 ms | W44 10-29 00:49 |
| `_vm_map_file` prefetch 10 MB → 1 MB; app_server font/vblank trims | launch_daemon → first child 1.25 → 0.63 s; app_server main → cursor 0.89 → 0.81 s | W43 10-24 18:40, 19:21 |
| packagefs reads 256 KiB after two in-order reads; DMAResource bounce 128 kB | whole Firefox package 9.0 → 5.35 s; Firefox cold 9.2 → 8.2 s | W43 10-25 01:43 |
| SD: ADMA2, DDR50, one command per transfer; USB 256 segments | 17.4 → 43 MB/s; USB 78 → 87.5 MB/s | W43 10-19 02:10, 10-20 11:00, 10-25 05:43 |
| GENET RX/TX work; remote disk 16 requests in flight, pipelined writes | RX 250 → 735 → 918 Mbit/s; remote-disk writes 24× | W43 10-19 02:00, 10-23 16:30 |
| CPU/core clock held (`bcm2835_cpufreq`, V3D core clock): the firmware had dropped the ARM to 600 MHz after 2 minutes | QuakeSpasm 1080p 19–27 → 30–43 fps, 720p 38–55 → 56–70; Quake II 720p 42–52 → 81–89 | W43 10-19 12:30; HARDWARE-SUPPORT.md:29-30 |
| Wine: wineserver on kqueue; real display modes (0019); prefix update rewrites only changed DLLs (0021); WoW64 GL buffer ranges (0028) | round trips 5–7×; full screen 22 → 140 fps; update 171 → 61 s; Warcraft III menu 3 → 12 fps (game 11–18), NFS menus 2.5 → 26, UT Direct3D 6 → 16 | W43 10-23 09:30, 07:10, 10:45; W44 10-31 10:56 |
| Box64 cooperative suspend (W9) | cpubench +2.1 %, 7-Zip −0.9 % (the cost, accepted) | W44 10-29 21:21 |

## 3. Ruled out, at a ceiling, or parked

| Item | Why | Source |
|---|---|---|
| SD card faster than 50 MB/s | hardware: EMMC2 base clock 100 MHz, SDR104 out of reach (P5) | KNOWN-ISSUES.md:35 |
| Ethernet | at gigabit's TCP ceiling (~940 Mbit/s payload): 914 / 918 | HARDWARE-SUPPORT.md:105 |
| 64-bit-load ones'-complement checksum | within noise both ways, not kept | W43 10-20 22:30 |
| 64 KB page-fault read-around | no gain (Firefox 21.8–23.4 s vs 21.6–23.0), not committed. **Superseded by C2 (11-05)**: that run measured the *packaged* Firefox inside a 14.5 s DNS wait; on BFS files the same idea is −5.7 s (C2), on packagefs it costs +0.49 s, so it runs only for files on a partition | W43 10-24 22:37; §6 "C2 results" |
| Trace-based package prefetch (C2 part ii) | not built: pre-reading the whole Firefox package takes 5.2 s and saves 3.2 s of the 7.7 s first start; the first start touches about the whole package, so a replayed trace reads about as much; only an idle-time prefetch after boot could gain, by moving ~5 s of card reads and ~100 MB of RAM there | §6 "C2 results" |
| Fixed 128 KiB × 16 packagefs read-ahead pool | regression: loader → cursor +2.4 s, first Firefox 16.9 s | W43 10-24 23:21 |
| Skipping the icache flush in `Protect()` | no measurable change, reverted | W43 10-24 13:46 |
| Per-drawable readback buffer in Wine's full-screen path | no change (24.5/21.4 vs 21.1/21.1 fps); superseded by real display modes | W43 10-23 05:20 |
| Larger Firefox video queue (`media.video-queue.default-size` 30) | no change in drops | W43 10-21 01:00 |
| Wine thread affinity | decided against | W44 10-29 17:08 |
| NEON / non-temporal app_server copies | copies already DRAM-bound (~2.2 / 2.6 GB/s) | gpu-present.md:219 |
| GPU option D (render straight into the frame buffer), skip the back buffer | not exact (stale back buffer) | gpu-present.md:78, 218 |
| Network boot at 1 KiB per request (F8) | bench-only; users boot from the card; owner parked | W45 11-02 21:28 |
| Firefox 1080p H.264 software compositing (WebRender renderer 4.4 s + SwComposite 3.9 s of 8 s CPU) | Gecko-internal, multi-hour rebuild per try; parked; the same on Pi 4 Linux | W44 10-29 18:45 |
| H.264 hardware decode / camera | needs VCHIQ, H21, last in the queue | PLAN.md row 7 |
| Firefox first-video drops: the order of codecs | explained by the test's order (H.264 first), not the codec | W43 10-21 01:00 |

## 4. Candidates

Gain is what a user or the benchmark would see; "unmeasured" is stated where no number exists.

### C0. Desktop-session profile with `profile` / `pmustat` (and three attribution measurements)

- **Slow today**: nothing is known to be slow; that is the point. The two biggest userland wins of the last
  round came from the first profile of an area: a busy python3 spent 33 % of its CPU time in TLS lookups
  (W43 10-24 04:24; fixed: 2×) and `arch_cpu_sync_icache` was 45 % of all ticks in a fork+exec loop (W43
  10-24 13:46; fixed: 2× process start). No whole-desktop session has been profiled since (the last baselines:
  W43 10-24 03:00 "no slow spot found", before the GNU-hash/TLS/icache work).
- **Expected gain**: unmeasured by definition; precedent above (two ≥ 2× items in two profiles). Output = the
  ranked input for the next list.
- **Effort**: S. One Pi session (~1 h), a script (`tools/pi-tests/soak-apps.sh` as the workload: Firefox,
  STK, video, Terminal), tools exist.
- **Risk**: low. `profile -f -k` panicked a kernel once (C5, fixed 10-24, W43 10-24 04:24); use `-a -k` and
  `-k -S`, `-f` only on a single team.
- **Measure**: `profile -a -k -S -i 1000 -o FILE` over a scripted 5-minute desktop session (open Terminal, Firefox
  page, a game's menu, MediaPlayer, pkgman); `pmustat -a 30` and `pmustat COMMAND` (IPC, L1D/L2 miss rates, "MHz
  while busy") for the same workloads; callers with `tools/haiku-tests/cgcallers.py`. Compare the top 10 symbols
  against §2 (a symbol that reappears means a fix regressed).
- **Folded in, because each needs one Pi session anyway and each decides a candidate below**:
  1. *SD write attribution*: is the 19–22 MB/s write (6–8 MB/s sustained on 10-23) the card or the driver?
     Run the same raw 1 MiB write on **Linux in the flash lane** against the same card (`dd oflag=direct`), next to
     `tools/pi-tests/iocheck.sh` (128 MB + fsync) on Haiku. Same speed on Linux = the card (nothing to fix; replace
     the bench card); a multiple = a driver/BFS item (C4).
  2. *WiFi CPU headroom*: `tools/pi-tests/net-perf.sh` over WiFi (`scripts/wifi-join-image.sh --script
     tools/pi-tests/net-perf.sh`) with `pmustat -a` / `profile -k` running (C8 needs it).
  3. *Wine prefix breakdown on today's build*: `tools/pi-tests/prefix-timeline.sh` (C5 needs it).
  4. *WoW64 GL after Wine 0028*: `profile -f` on Warcraft III / NFS demo menus (C7 needs it).
- **Still unmeasured**: everything this item produces. → Measured 11-03 evening: §6 "C0 results".

### C1. DT_RELR for Firefox (and the cold A/B that was never run)

- **Slow today**: libxul has 492 734 `R_AARCH64_RELATIVE` relocations, `.rela.dyn` **11.96 MB**, read by every
  Firefox process (W44 10-28 21:57). With DT_RELR: 0.14 MB + 0.11 MB (same entry).
- **Expected gain**: **measured** warm: `dlopen` of a half-million-relocation library 29.5 → 16.0 ms (−46 %), Firefox
  warm start ~3.16 → ~3.12 s (−1.5 %) (W44 10-28 22:24). Cold: **unmeasured** (the card-boot cold A/B is explicitly
  open, same entry). Bound, **derived**: 11.7 MB less to read once per boot = 11.7 / 45 MB/s ≈ 0.26 s if read
  sequentially, more if the page-fault path reads it in 24 KiB pieces; so a cold gain of roughly 0.3 s is the order,
  not seconds. Also −12 MB in the package and 1.5 MB (zstd) of download (W44 10-28 21:57).
- **Effort**: S. The loader support is merged (4539cd2f00), the linker honours the option (buildtools 1cad3a62fa, in
  the 16.2 cross tools: gcc16.md:26). What is left: `-Wl,-z,pack-relative-relocs` in `scripts/build-firefox.sh`
  (full relink; the last LDFLAGS change cost ~45 min, W43 10-24 16:09), a package revision, 3+3 cold card boots.
- **Risk**: medium on the ABI: an older `runtime_loader` ignores DT_RELR and runs with unrelocated pointers (a
  crash, no error), so the package must require a haiku with 4539cd2f00 (W44 10-28 21:57, 22:24). Also the open
  Firefox content-process crash hunt (W45 11-03 16:20): do not ship a new Firefox revision on top of it. Other
  userland gains nothing (Terminal 254 and Tracker 3 relative relocations; only `Devices`/`listdev` have 65–71 k).
- **Measure**: `tools/pi-tests/relr.sh` (round 1 cold, rounds 2–5 warm; `dlopen` of the big library, Devices as a
  positive control, Terminal/GLTeapot as controls) plus `launchtime` Firefox-1, on `scripts/sd-cycle.sh --flash` of
  both images, 3 cold card boots each (`scripts/boot-bench.sh` shape: power off between). The old A/B images
  (`artifacts/images/relr-ab-*.img`) are **gone** (11-02/11-03 cleanups); the pieces remain in `artifacts/relr/`
  (`libxul-relr.so`, `ffx-rela`, `ffx-relr`, `relink-libxul.sh`, `librelrbig-*.so`) and the rebuild recipe is
  `scripts/relr-image.sh --cross <RELR cross tools> --firefox artifacts/relr/libxul-relr.so IMG OUT`
  (W44 10-28 21:57); the 16.2 cross tools make `-z pack-relative-relocs` work without a special tree. Those pieces are
  from the 13.3-era Firefox: rebuild them against the 16.2 runtime or label the A/B accordingly.
- **Still unmeasured**: cold first-launch effect; effect on the page cache footprint (relocation pages touched).
  → Measured 11-04 (cold card A/B from a BFS tree; the packaged cold case derived): §6 "C1 results".

### C2. Cold-start prefetch for big applications (extend the packagefs read-ahead to scattered reads)

- **Slow today**: Firefox first launch after boot 8.2 s from the card vs 3.1–3.5 s warm (**measured**, W43 10-25
  01:43; 10-24 23:21). A cold start makes ~4500 package reads of ~24 KiB, 73 % scattered; reading the whole
  package sequentially takes 5.28 s (same entry). WebPositive 2.9 s cold vs 1.1 s warm (W43 10-24 03:00).
- **Expected gain**: bound, **derived**: cold 8.2 s − the sequential floor 5.3 s ≈ **≤ 3 s**, and 4500 × 24 KiB ≈
  108 MB, about the whole compressed package (102 MB), so the first launch touches most of it; a prefetch that reads
  only what is touched would save less than the full 3 s unless it overlaps with start-up work. Actual: **unmeasured**.
- **Effort**: M. The in-order case is done (6f53989b14: after two in-order heap reads, read 256 KiB). What is
  left is a *trace-based* prefetch: record the page-in order of a first launch, replay it as one sequential pass at
  the next launch (or at idle after boot). Kernel (packagefs/VM) plus a tool.
- **Risk**: medium. Two earlier attempts failed on this path (a 64 KB read-around: no gain; a fixed 128 KiB × 16 pool:
  boot +2.4 s, first Firefox 16.9 s — §3), and extra reads at boot compete with the 5.4–5.8 s boot and 4 GB of RAM.
  Guardrail: loader → cursor must not move.
- **Measure**: `tools/pi-tests/coldstart.sh` / `coldcat.sh` (cold launch times; whole-package read), `tools/pi-tests/iocheck.sh`
  (package read uncached in 21/64/256 KiB aligned and unaligned, raw reads by size, 128 MB write; needs
  `launchtime`, `nocacheread`, `disklat`), `scripts/boot-times.sh` over `scripts/sd-cycle.sh` boots for the
  guardrail; 3 cold card boots per side, MD5 of the package as in the 10-24 tests.
- **Still unmeasured**: what fraction of the package the first launch touches; the page-fault order's stability
  between boots (needed for a recorded trace to help).
  → Measured 11-04/05 (the pre-read experiment, page-fault read-around for files on a partition): §6 "C2 results".

### C3. Boot: what remains after 21.3 → 5.6 s

- **Slow today**: loader banner → desktop cursor **5.4–5.8 s** (gcc16.md:439). The last per-phase figures are
  from 10-24/10-29, before the later trims: loader 1.2–1.4 s (kernel load ~1.2 s, W43 10-24 20:17, left open in the
  W43 Next list), boot volume mounted at ~5.5 s of system time then ~5 s to the cursor on 10-24 (W43 10-24 18:40, 19:21; before the later trims), app_server main → cursor 0.81 s
  (font manager 0.23 s, driver → mode 0.11 s; W43 10-24 19:21), `media_addon_server` → `notification_server` 3.8 s
  *after* the desktop (W43 10-24 18:40), the link-up report on whole seconds (a 1 Hz PHY tick, 3–4 s; network boot
  only, W44 10-29 00:49). U-Boot 0.6 s (W44 10-28 22:12). Not Haiku's: ~58 s on the bench before U-Boot (the EEPROM
  tries the network first; W43 10-23 03:00).
- **Expected gain**: each remaining phase is bounded by its figure (≤ ~1 s each, **derived** from the phase
  times above); the current sum is **unmeasured** (no phase table since 10-29).
- **Effort**: S per item after one timestamped boot (`syslog_time_stamps true` in the image's kernel settings,
  `scripts/image-add.sh`), M for the kernel-load phase.
- **Risk**: low (boot-path changes need the 10-cold-boot gate again: C1 was a cold-start bug, PLAN row 1).
- **Measure**: `scripts/sd-cycle.sh --flash IMG --secs 120` + `scripts/boot-times.sh LOG` (loader → kernel →
  bootvol → cursor), 3 cold + 2 warm boots per side; `scripts/boot-bench.sh` for the reliability gate.
- **Still unmeasured**: today's phase table; the effect of the C0 profile on boot (profile a boot with
  `profile` started from the first boot script).

### C4. SD card write path

- **Slow today**: raw reads 42.6–45 MB/s but writes **6–8 MB/s sustained** on 10-23 (raw 1 MiB writes and BFS
  alike; 29–36 MB/s in 64 MiB samples on 10-20), 128 MB + fsync **19–22 MB/s** on 10-25 (HARDWARE-SUPPORT.md:89;
  W43 10-23 10:45, 10-25 01:43). The note says "likely the card, much rewritten by the flash lane".
- **Expected gain**: if it is the driver/path, up to 2× (19–22 → ~43 MB/s) on everything that writes: Wine prefix
  (~990 MB, W43 10-23 10:45), `pkgman install`, Firefox profile, `numpy` builds. If it is the card: none.
  **Unmeasured** which it is.
- **Effort**: S to attribute (C0 item 1), M to fix (ADMA2 write path, write sizes/alignment, BFS write-behind), nothing
  if the card.
- **Risk**: low for the attribution; medium for driver changes (the card is also the flash target and the boot path).
- **Measure**: Linux `dd oflag=direct` on the flash lane vs Haiku `iocheck.sh`/raw writes, same card, same
  sizes (1 MiB, 64 MiB); a second, different card on Haiku; `scripts/sd-cycle.sh --read-back` for integrity.
- **Still unmeasured**: the card's write speed on Linux; a second card. (C0 11-03: still unmeasured, the card was in use.)
  → Measured 11-05 (§6 "C4 results"): the driver path, not the card; fixed (512 KiB commands), raw writes 24 → 36 MB/s.

### C5. Wine first-start: the prefix

- **Slow today**: a fresh prefix in the games-bench image takes **126 / 126 / 131 s** per boot (gb6s-table.md footer;
  mega image `wineboot` 123 s, W44 10-29 18:35); other sessions 56–98 s (W43 10-24 00:24: 87 s with both Mono
  parts; 10-24 11:10: 62 s; games before/after 10-28 21:03: 89–98 s). On 10-23 the same step was 387 s on the old 2.9 MB/s
  remote disk, "~32 s CPU", i.e. disk-bound (W43 10-23 10:45) — the disk side has since improved 24×, so today's
  split between disk and CPU is **unmeasured**. A new Wine version rewrites most of the ~1 GB again (KNOWN-ISSUES
  W5; 61 s on the card for a same-version revision).
- **Expected gain**: unmeasured. Once per prefix, so a first-run cost, not a throughput item.
- **Effort**: M (a shipped prefix template, or fewer/linked builtins, depending on the breakdown).
- **Risk**: medium: prefix contents depend on user name/paths/registry; a stale template misbehaves silently.
- **Measure**: `tools/pi-tests/prefix-timeline.sh PREFIX` + `tools/wine-tests/prefix-timeline.py` (per-process wall and
  CPU, written bytes), on the card and on the network boot; compare to the C4 write speed.
- **Still unmeasured**: the whole breakdown today. → Network boot measured in C0 (§6): 80 s, 32 CPU-s, ~1 core busy;
  the card side is still open.

### C6. Firefox first-video warm-up (G2)

- **Slow today**: the first clip after Firefox starts drops **32 and 37 of 300** frames (H.264 720p, images 10-29c/10-29d;
  W43 had 121–226), 81 / 189 for 1080p later in the run, 61 from the card with logging on; the same clip again 14
  (network) or **0** (card) (KNOWN-ISSUES.md:25; W44 10-29 18:41). The RDD process stalls up to 1.8 s while warming up
  (W43 10-21 01:00).
- **Expected gain**: a smoother first clip, **no fps number**. Fix is Gecko-internal or a pre-load of the decoder
  libraries: **estimated** low value (first seconds only, the card case is 0).
- **Effort**: M to L: the cause is not identified; every Firefox try is a multi-hour rebuild or a settings
  experiment (W44 10-29 18:45).
- **Risk**: low to medium; Firefox crash hunt in progress.
- **Measure**: `tools/pi-tests/firefox-video.sh` (clips from `scripts/make-web-video-clips.sh`; the dropped count per
  clip, MOZ_LOG module name), first vs repeat order, card boot vs network boot, with and without the whole
  Firefox package read first (the decisive cheap A/B: if pre-reading removes the drops, it is C2's problem, not Gecko's);
  `tools/pi-tests/ffstall.sh` for thread states during the stall.
- **Still unmeasured**: whether a pre-read package removes the drops.

### C7. `GL_MESA_map_buffer_client_pointer` for Wine's 32-bit OpenGL

- **Slow today**: before Wine 0028, WoW64 GL mapped each buffer in and out through a thunk copy: Warcraft III
  3 fps, `profile -f` memcpy 53 % under `wow64_ext_glMapBufferRange`/`wow64_glUnmapBuffer` (W44 10-31 10:56). **0028**
  (copy only flushed ranges) made the Warcraft III menu 12 fps (game 11–18), NFS Porsche menus 2.5 → 26, UT Direct3D
  6 → 16. Wine 11.21's own path needs the extension; Mesa 26.2.6 has "no trace of it" (W44 11-01 12:49: so 0028
  stays the live path).
- **Expected gain beyond 0028**: **unmeasured**. The standard benchmarks will not show it: gltest-x86 163.6 fps vs
  arm64 161.6 (gb6s-table.md) means x86 GL is not copy-bound there.
- **Effort**: L (implement the extension in Mesa's gallium frontend for the v3d driver; not in 26.2.6;
  whether a newer Mesa release carries it is **unverified** from this repository).
- **Risk**: medium (a Mesa extension nobody else ships on this target; the Wine side is upstream code).
- **Measure**: first the cheap step: `profile -f -k` on the two mega-image demos with 0028 (Warcraft III menu and
  NFS menus; archive.org assets in `tools/mega/assets.txt`, driven by `tools/pi-tests/wine-games.sh` with
  `WINEDEBUG=+fps`, W44 10-31 10:56). If memcpy is still > ~30 %, implement; if not, drop. These demos are not in
  `games-bench`, so a before/after needs them added to the bench image.
- **Still unmeasured**: the post-0028 profile; whether any measurable title is copy-bound now. → C0 (§6): Warcraft III
  menu memcpy 3.1 %: **C7 dropped**.

### C8. WiFi SDIO DMA (F4)

- **Slow today**: TCP **37.4 up / 46.0 down Mbit/s**, "close to what the bench's 2.4 GHz access point gives; SDIO
  runs PIO and is CPU-bound" (KNOWN-ISSUES.md:45; HARDWARE-SUPPORT.md:114, :221). The controller is the legacy
  Arasan SDHCI at 41.67 MHz, no SDMA/ADMA in its capabilities (wifi-bcm43455.md:55, :61).
- **Expected gain**: **a DMA change may show zero Mbit/s gain on this bench**: the stated limit is the access
  point. The claimable gain is CPU time (and the upload was 26.5 → 37.4 Mbit/s when the ARM clock was fixed, i.e. it
  does depend on CPU: W43 10-19 12:30). No CPU measurement of the SDIO path exists in the repository:
  **unmeasured** whether the CPU is saturated during a WiFi transfer.
- **Effort**: L: a DMA path on a controller whose DMA is not SDHCI's ADMA (external DMA channel), in a stack whose
  bring-up was fragile (R2: PIO lost edge → partial firmware download, wifi-bcm43455.md:172).
- **Risk**: high for WiFi bring-up and the shared interrupt with EMMC2.
- **Measure (the prerequisite, a C0 item)**: `net-perf.sh` over WiFi with `pmustat -a`/`profile -k` running: CPU
  busy % and the share of the SDIO PIO loops; and the same transfer against a different access point or band
  (5 GHz) to see whether Mbit/s moves at all. Only if CPU > ~80 % busy or the rate moves with a better AP does DMA
  have a case.
- **Still unmeasured**: CPU load during WiFi transfers; the throughput limit without the bench AP. → C0 (§6): CPUs
  15–17 % busy, spin-waits 37–58 % of non-idle: **DMA dropped** (N7 instead); another AP still untried.

### C9. Box64 / FEX settings per game

- **Slow today**: nothing game-level is measured. Measured only on `cpubench`: Box64 default x86 2957 ms vs arm64
  1969; `BOX64_DYNAREC_STRONGMEM=1` costs store-heavy code up to 3× (sort 2.2 → 6.8 s; KNOWN-ISSUES.md W6); FEX with
  TSO on 8511 vs off 1874 on the x86 sort (wine-x86.md:163-172). Game rates (W44 10-31 10:56, W45 11-02 06:12):
  AoE II ~31 fps, SimCity 3000 43, StarCraft intro 15, Diablo II 25, UT Direct3D 16, UT OpenGL ~50 — **not known which are
  CPU-bound** (window GL tests are GPU/present-bound: ~160 fps for arm64 and x86 alike).
- **Expected gain**: unmeasured; only CPU-bound titles can gain. W4 showed Box64's safe settings
  (SAFEFLAGS=2 STRONGMEM=2 BIGBLOCK=0 CALLRET=0) were "not noticeably slower" for StarCraft (W43 10-23 16:00), so the
  safety/speed trade at the game level is unquantified both ways. Correctness first (KNOWN-ISSUES W6).
- **Effort**: S per title (an environment sweep), M to build a settings table.
- **Risk**: medium: relaxing ordering/flags settings reintroduces W6-type races; every setting needs a
  correctness check, not only fps.
- **Measure**: `tools/pi-tests/x86-cpubench.sh` (cpubench-x86 + 7-Zip `7zr b -mmt1`, N rounds) for the settings'
  CPU effect; `tools/pi-tests/wine-games.sh` with `WINEDEBUG=+fps` per game, settings via the game's environment;
  `pmustat` first to see whether the game is CPU-bound at all (busy % per CPU).
- **Still unmeasured**: which games are CPU-bound; per-setting effect on any game.
- **Related, larger**: the ARM64EC transition cost, **~0.8 µs** per call into x86-64 code: the x86-64 qsort of
  20 M comparator calls takes 16.6 s vs 1.3 s native and 2.2 s for the 32-bit x86 build under Box64 (wine-x86.md:171,
  :178-179). Only x86-64 programs that call back often pay (FEX is internal); effort L; the x86-64
  programs that run (Chocolate Doom x64, OpenTTD x64: PLAN.md H15) are not known to be affected. Do not start without a title
  that is.

### C10. GPU scanout planes (stage 6, PLAN row 6b/F2 — not re-planned under H20)

- **Measured**: the games A/B with the saver off (`artifacts/queue-1103/gb6s-table.md`, W45 11-03 12:31): native
  games −3…+3 %, Quake II 1080p **+3 %** (the plane case), QuakeSpasm 640×480 −2 %, 1080p −2 %, Quake II 640×480 −3 %,
  Wine full screen −3 %; flip-vsync 1200 frames in 20.000 s = **60.00 fps**, 0 missed; flip-free **130.4** fps vs
  flip-window **124.1** (gpu-stage6.md §10). PLAN's "≤ 15 %" is **superseded by measurement**: the gain in fps is
  ≤ ~3–5 %; the deliverable is vsync/no tearing and the video/overlay path, not speed. Games at 1080p are GPU-bound
  (QuakeSpasm 41.0 fps at 1080p vs 80.3 at 720p: 1.96× the rate for 0.44× the pixels, **derived**; GPU ~95 % busy,
  HARDWARE-SUPPORT.md:68).
- **Open**: the off-plane cost (app_server's alpha-forced copies) is addressed on `stage6-keying` (keying only while an
  overlay is up; the present-bench says the forced alpha costs ≤ 1.5 % of a copy: an uncommitted edit of gpu-stage6.md §3 "Cost" in the working tree on 11-03) and has **not been
  A/B'd on the Pi yet**. That re-run (`scripts/games-bench-image.sh` + `scripts/netboot-cycle.sh`, 3+3, as §10) is the
  step; it belongs to F2, listed here only so nobody plans it twice.
- Follow-up with a real speed angle: YCbCr overlays for MediaPlayer/rpivid (today MediaPlayer converts to
  B_RGB32; the conversion cost per frame is **unmeasured**).

### C11. Smaller items, each cheap to check, none with a measured pain

| Item | Basis | Gain | Effort |
|---|---|---|---|
| `KDEBUG_LEVEL 0` | level 2 → 1 gave TCP up 600 → 914 Mbit/s (HARDWARE-SUPPORT.md:42); level 1 → 0 never measured | unmeasured | S, but it removes the assertions that caught real bugs (W43 10-20 23:30): stability first, profile a level-1 kernel under load before deciding |
| Out-of-line atomics in the kernel | `__aarch64_ldadd4_acq_rel` 5–8 % of kernel ticks in a fork+exec loop, no single caller (W43 10-24 13:46); the A72 has no LSE | unmeasured | S flag (`-mno-outline-atomics`) + rebuild; wide blast radius |
| Ports built with the 16.2 toolchain get GNU hash by default | the default is in the 16.2 cross tools (gcc16.md:26); published ports are 13.3-era (no mass republish, W45 11-03 00:51); "HaikuPorts binaries (SysV) gain little" (W43 10-24 13:46) | unmeasured per port; check with `readelf -S` on WebKit/Wine/SDL libs | S per port at its next revision |
| numpy without BLAS | `numpy.linalg` "works, slower on large matrices" (numpy.md:51); no matmul rate measured | unmeasured | M (an OpenBLAS port with NEON kernels) |
| Quitting Firefox | 1.9–4.8 s (relcheck-1103b.log); 2.1 s before the poll fix (W43 10-24 14:40) | seconds on quit only | M (Gecko shutdown) |
| Over/under-clock | ARM held at 1.5 GHz, core 500 MHz, "turbo never requested" (HARDWARE-SUPPORT.md:29-30); 58–73 °C in the bench | unmeasured; only CPU-bound work | S to try, but the owner's stability-first rule and the cold-start history (heat) argue against; not recommended now |

## 5. Ranking (gain/effort)

(The ranking as written before C0. After it: N1, N2, N3, then C1, C2 — §6 "C0 results"; C7 and C8 dropped.)

Ranked by expected gain per effort, weighting by how much of the gain is measured. "Gain" bucket: H = seconds on a
frequent action or ≥ 2× on a hot path; M = sub-second to ~3 s, or one user-visible stall; L = ≤ 5 % or first-run
only; ? = unmeasured.

| # | Candidate | Gain | Effort | Why this place |
|---|---|---|---|---|
| 1 | **C0** desktop-session profile + attribution measurements | ? (precedent: two ≥ 2× items) | S | enabler; settles C4, C5, C7, C8 with one session; its output re-ranks everything below |
| 2 | **C1** DT_RELR for Firefox, cold A/B | L–M (≈ 0.3 s derived bound; −1.5 % warm measured) | S | the loader and linker work is merged; only a relink, a package revision and 3+3 cold boots are left; closes the open A/B |
| 3 | **C2** cold-start prefetch (trace-based) | M (≤ ~3 s derived bound on 8.2 s) | M | biggest measured cold/warm gap in daily use (Firefox, WebKit); history of failed attempts keeps the confidence moderate |
| 4 | **C4** SD write path | M–H if not the card, 0 if it is | S to attribute | a measured read/write gap (45 vs 6–22 MB/s); the attribution is one Linux `dd` in C0 |
| 5 | **C3** boot phases | L–M (each ≤ ~1 s) | S–M | already at 5.4–5.8 s; the table is stale (10-24/10-29) |
| 6 | **C5** Wine prefix | ? (126 s, once per prefix) | M | first-run cost; the breakdown is missing (C0 item 3) |
| 7 | **C9** Box64/FEX per game | ? | S per title | needs the "is it CPU-bound" answer first; correctness-first (W6) |
| 8 | **C7** map_buffer_client_pointer | ? (Warcraft III 3 → 12 with 0028 already) | L | gate: the post-0028 profile; Mesa-side work |
| 9 | **C6** Firefox first-video warm-up | L (first seconds; card case 0) | M–L | cause unknown; Gecko rebuilds; the pre-read A/B is cheap and may hand it to C2 |
| 10 | **C8** WiFi SDIO DMA | ? (zero Mbit/s likely on this bench) | L | the prerequisite CPU measurement is in C0; the stated limit is the access point |
| – | **C10** stage 6 | ≤ 3–5 % fps; vsync is the point | S left | owned by F2 (PLAN 6b), not re-planned here |
| – | C11 items | ? | S | only after C0's profile names them |

## 6. First three, with measurement plans

Run order: C0 (one bench slot) → C1 → C2; C4's attribution is inside C0. Each result goes into the table at the end
of this section with its image, date, labels and `artifacts/uart` logs.

### First: C0, the profile session (~2 h of bench, one session)

1. Image: `haiku-pi4-2026-11-03b.img` (or the next release) + `launchtime`, `pmustat`/`profile` (in the haiku package),
   `tools/pi-tests/soak-apps.sh` as the scripted desktop workload; `syslog_time_stamps true`.
2. `scripts/pi-session.sh start --image IMG --label h20-c0` (shared bench lock held), then over ssh:
   - `profile -a -k -S -i 1000 -o c0-desktop.prof` for a 5-minute scripted session (Terminal, Firefox + a page,
     MediaPlayer clip, pkgman search, a game menu); `pmustat -a 30` at idle and under load; `pmustat COMMAND` for a
     CPU-bound and a memory-bound run; `profile -k -S` on a `fork+exec` loop (`tools/haiku-tests/forkbench.c`), to
     check that the icache/atomics items stay down.
   - `tools/pi-tests/iocheck.sh` (128 MB write + fsync; package read) and `tools/pi-tests/prefix-timeline.sh
     /boot/home/pfx` (with `WINEDLLOVERRIDES=mscoree,mshtml=`).
   - WiFi: `scripts/wifi-join-image.sh --script tools/pi-tests/net-perf.sh` image, `pmustat -a 10` and
     `profile -k -S` during the transfers.
3. Flash lane (Linux): `dd if=/dev/zero of=/dev/<card> bs=1M count=512 oflag=direct` (card contents are rewritten
   afterwards by the usual flash; **restore the bench default and the release image on the card as sd-cycle.sh does**).
4. Read-out: top 15 symbols per profile with `tools/haiku-tests/cgcallers.py` for callers; a table in this file
   (§6) — each symbol above ~5 % that is not already in §2 becomes a candidate with its measured share.
5. Done when: a profile of a desktop session exists and is summarised here; C4/C5/C7/C8 each have their gating
   number or "still unmeasured" with the reason.

### Second: C1, DT_RELR cold A/B

1. Build B: Firefox relinked with `-Wl,-z,pack-relative-relocs` (`artifacts/relr/relink-libxul.sh`, or the
   `scripts/build-firefox.sh` LDFLAGS change) on the 16.2 runtime; A: the same Firefox without the option; same
   image otherwise (`scripts/relr-image.sh`, which also writes `tools/pi-tests/relr.sh` as the boot script).
2. Run: `scripts/sd-cycle.sh --flash IMG --secs 900 --label relr-A-sd --until 'RELR end'` (and `-B-sd`), 3 power-cycled
   cold boots each in the order A, B, A, B, A, B; then network boots for round 2–5 warm numbers
   (`scripts/netboot-cycle.sh`). Restore the release image afterwards (`scripts/sd-cycle.sh --flash` with it).
3. Read: `grep -a 'RELR ' artifacts/uart/*-relr-*-sd.log` (first window time of Firefox-1, `dlopen` rounds, Devices
   control); `launchtime` Firefox-1/2/3 as in `relcheck.sh`.
4. Pass: B's cold first window is not slower, and the median over 3 boots is lower by more than the A-to-A spread;
   warm ~3.1 s unchanged or −1 to −2 %; Terminal/GLTeapot controls ±noise; `debugger entries 0`. Decision: ship in
   the next Firefox revision only if it passes **and** the content-process hunt (W45 11-03 16:20) is closed; the
   package requires a haiku with 4539cd2f00.
5. Not done here: enabling `HAIKU_PACK_RELATIVE_RELOCS=1` for the whole image (only `Devices`/`listdev` gain; the
   older-loader ABI trap makes every non-image package a risk).

### Third: C2, trace-based cold-start prefetch

1. Baselines (before any code), 3 cold card boots each, saved as `h20-c2-base-*`: `tools/pi-tests/coldstart.sh`
   (first launch of Firefox, WebPositive, Terminal, MediaPlayer after boot), `tools/pi-tests/coldcat.sh` (whole
   package read), `tools/pi-tests/iocheck.sh` (read sizes, 128 MB write), `scripts/boot-times.sh` (guardrail:
   loader → cursor 5.4–5.8 s).
2. Cheap decisive experiment first (no kernel change): pre-read the Firefox package (as `coldcat.sh` does), then launch:
   if the first-launch time falls to the warm 3.1–3.5 s, the ceiling is the sequential-read floor and a trace-based
   prefetch is worth building; if it stays at ~8 s, the cost is not I/O and C2 stops here. The 10-24 test said:
   reading all of the package first took 8.9–9.0 s and Firefox still needed 17.6–18.8 s — but that run still had the
   14.5 s DNS wait (fixed 10-24 23:21), so it must be redone now.
3. Prototype: record the (package, offset, length) page-in order of a Firefox first launch (a packagefs/VM debug
   facility, off by default), store it per package, replay it as one pass at the next launch or at idle after boot.
4. Pass: first launch after boot ≥ 1.5 s faster than 8.2 s on the card, 3 boots each; loader → cursor unchanged
   (`boot-times.sh`); `iocheck.sh` raw rates unchanged; no regression in the 24-cycle `scripts/release-check.sh`
   (0 problems). Fail: boot slower, or < 0.5 s gain → drop and record in §3.
5. The same plan covers WebPositive (2.9 s cold vs 1.1 warm, W43 10-24 03:00) as a second application.

### Results table (fill in as items are done)

| Item | Image | Before | After | Runs | Logs |
|---|---|---|---|---|---|
| C0 (measurement, no change) | 11-03c (11-03b for one A/B) | — | profile + pmustat of a desktop session; C5/C7/C8 gates; below | 4 network sessions, 11-03 20:55–22:05 | `artifacts/h20-c0/out/`, `artifacts/uart/20261103-*-session-h20-c0*.log` |
| C0b / N2 (bcm2835_cpufreq total load) | h20-imgevt → h20-startcost (haiku `startcost` 83db805485) | fork+exec 6.6–8.0 ms at ≥ 4 min uptime (4.6–4.7 in the first minutes) | 4.6–4.8 ms at any uptime, after Terminal / Firefox / STK quit; idle still 750 MHz | 3 network sessions, 11-03 22:23–23:12 | `artifacts/h20-c0b/`, `artifacts/uart/20261103-22*-session-h20-c0b*.log` |
| N6 (BFS sub-transaction start walks only changed blocks) | worktree builds of `rpi4` 162164220d: A without, B with haiku `bfs-subtrans` a9db442988 | `cache_start_sub_transaction` 616 / 1055 ms CPU per Firefox first start; 289 ticks = 11.3 % of bfsmeta | 26 / 59 ms; 0 ticks; first window unchanged; check build clean; 6 power cuts like A (5) | 18 network boots, 11-04 05:50–07:05 | `artifacts/h20-n6/`, `artifacts/uart/20261104-0*-session-n6-*.log` |
| N3 (windowed presents paced; SDL2 swap interval) | h20-startcost + mesa 26.2.6-3 A (`rpi4` ebf1ee1ff1b) / B (`paced-windows` 1595aba36ec) | STK menu (SDL2) 132 fps, game 81 % + app_server 45 % of a core, 32.7 % of 4 CPUs busy | with B + the SDL2 patch: 60 fps, 29 % + 12 %, 11.2 %; interval 0 unchanged (glmark2 331/332 → 332/332, games bench ±1 % or noise) | 1 network boot + 4 games-bench boots, 11-04 00:16–03:39 | `artifacts/uart/20261104-001649-n3-pace.log`, `artifacts/uart/20261104-*-gbn3[ab]-[12].log` |
| N5 (TLS of start-up images without the generation check) | worktree builds of `rpi4` b90cb3f0d4: A without, B with haiku `rpi4` c6cab6cc9e + 4d433669a8 | python3 `sum(i*i…)` 1e7: `__tls_get_addr` 19.4 % of ticks, 12.87 G instructions, 7.97 G cycles, 5181 ms median; tlsbench 17.35 ns | 9.8 %, 11.60 G (−9.9 %), 7.65 G (−4 %), 5104 ms (−1.5 %); tlsbench 14.68 ns (a dlopen()ed library's 16.0 → 17.35 ns); TLS test PASS (A fails the 64-byte alignment) | 6 network boots A/B alternating + 1, 11-04 11:43–12:29 | `artifacts/h20-n5/`, `artifacts/uart/20261104-1*-session-n5-*.log` |
| N7 (SDIO data blocks moved in the interrupt handler) | worktree builds of `rpi4` 4d433669a8: A without, B with haiku `n7-sdio-wait` 6018671453 | WiFi TCP 64 MiB: up 49.5 / down 46.8 Mbit/s; 226 / 183 M cycles per MiB; CPUs busy 19.6 / 15.9 %; `spin` + `system_time` 59 / 47 % of non-idle | 49.2 / 46.1 Mbit/s (ARM clock held at 1500 MHz: 49.3 / 46.5 = A); 151 / 126 M cycles per MiB (−33 / −31 %; at 1500 MHz kernel cycles −34 / −31 %); busy 11.6 / 8.9 %; spin 32 / 18 %; bring-up 5/5 one join; SD card probe + raw read unchanged | 10 network boots A/B alternating + 1 (a dropped variant) + 2 lost to a script race, 11-04 14:05–15:33 | `artifacts/h20-n7/`, `artifacts/uart/20261104-1*-session-n7-*.log` |
| C1 (DT_RELR for Firefox's libxul.so) | image-2026-11-04c + `relr-image.sh`: A = libxul relinked as is, B = the same with `-z pack-relative-relocs` (157.0.1-5 objects, GCC 13.3; both linked by the 16.2 cross tools) | Firefox tree in `/boot/home`, cold first window after a card boot 15 624 ms (median; 15 582–16 018); warm 3126 ms | **13 774 ms** (13 722–13 784, **−1850 ms, −11.8 %**); warm 3102.5 ms (−0.75 %); same-binary packaged Firefox control 8260 → 8199 cold, 3112.5 → 3106 warm; controls equal; 0 debugger entries | 6 card boots A,B,A,B,A,B (flashed each time) + 6 network boots, 11-04 17:00–20:20 | `artifacts/uart/20261104-*-relr-c1-[AB]-{sd,net}[123].log` |
| C2 (page faults on files read the missing pages around them, 64 KiB clusters, files on a partition) | worktree builds of `rpi4` b195a41e64: A without, C with haiku `c2-fault-readaround` a38b19efab (B = without the partition test, dropped) | Firefox from a BFS directory, cold first window after a card boot 14 047 ms (median of 5; 13 686–14 145); packaged Firefox 7710, WebPositive 2628; mapped files fault in at 8–10 MB/s | **8358 ms (8303–8772, −5.7 s, −40.5 %)**; packaged Firefox 7749, WebPositive 2641, Terminal 97 = (B: +486 / +163); warm, boot (cursor 5.42–5.63 s) and raw card reads unchanged; mapped files 23–32 MB/s, MD5 24/24 on every boot; x86-64 KVM: a 108 MiB library on BFS dlopen cold 550–567 → 77–88 ms | 13 card boots A×5, B×3, C×3, catall×2, 21:50–00:52; x86-64 6 + 6 KVM runs | `artifacts/uart/2026110[45]-*-c2-*.log`, `artifacts/qemu-x86/2026110[45]-23*-{c2,perf,fs,boot}-x86-*.log` |
| C4 (SD card writes in 512 KiB commands: 128 DMA segments, 512 KiB bounce buffers) | image-2026-11-05 (A) vs worktree build of `rpi4` a38b19efab + haiku `c4-sd-writes` 529875f0eb, 85d80f06f9 (B); Linux 6.18 on the same card | raw 1 MiB writes 24.3 MB/s sustained (median of 6 × 1 GiB; 22.3–36.7, bimodal), 512 KiB–4 MiB 23.9; BFS 1 GiB + fsync 26.2; raw 1 MiB reads 34–36; Linux 32.7 | **35.6 MB/s (33.7–36.0, +46 %, above Linux)**, 512 KiB–4 MiB 35.2–36.4 steady; BFS 1 GiB 32.3 (+23 %; file cache/page writer still 128 KiB); raw 1 MiB reads 43–44; 128 KiB requests −1–2 MB/s; SHA-256 13/13 across Haiku and Linux; release check 0 problems; card boot cursor 5.62 s | 7 network sessions (A1, B1 first variant, A2 B2 A3 B3), 2 Linux flash-lane runs, 1 release check, 1 card boot, 11-05 02:55–04:15 | `artifacts/h20-c4/`, `artifacts/uart/20261105-0[34]*-{c4-*,session-c4-haiku-*}.log` |

### C0 results (2026-11-03 20:55–22:05, image-2026-11-03c, network sessions)

Image 11-03c (hrev60299+276), network boot (remote disk), sessions `h20-c0` (85 min), `h20-c0-fork-b` (11-03b),
`h20-c0-fork-c` and `h20-c0-startcost` (11-03c, fresh boots). The card (the owner's mega20) was not written. Raw output:
`artifacts/h20-c0/out/` (text profiles, pmustat, callgrind trees `cg-stk/` and `cg-ff/`). Workload:
`tools/pi-tests/c0-desktop.sh`, **196 s** (Terminal; Firefox on haiku-os.org, then Wikipedia in a second window;
MediaPlayer on the 1080p HEVC clip for 30 s; two `pkgman search`; SuperTuxKart's main menu 60 s, its first start;
everything quits), run four times: (1) `profile -a -k -S -i 1000`, (2) `profile -k -S` (the debugger path: the script
and every team it starts), (3) `profile -a -k` per thread, (4) `profile -k` per thread; `pmustat -A -a 20` back to back
during (1). Ranked with `tools/haiku-tests/profsum.py` (share of non-idle ticks), callers with
`tools/haiku-tests/cgcallers.py` (`--self` added) on single-team `profile -k -C -v` runs: STK's menu for 6 min with an
unstripped `libEGL_mesa.so.0` of the same build ID (`__EGL_VENDOR_LIBRARY_FILENAMES`), and Firefox from a copy of its
directory holding the unstripped `libxul.so` of the same build ID (parent team only; a first start with a new profile,
since the copy's install path differs). Stripped libraries (libxul, Mesa) and JIT code otherwise show up as stack-walk
fallbacks (`pthread_thread_entry`, `runtime_loader`, `commpage_thread_exit`), not as functions.

**First finding: `profile -a` loses every team started after it.** All userland ticks of those teams count as
"unknown": **65 % of the non-idle ticks** of run (1) (253 863 of 390 155), and `profile -a -k -S sh -c 'python3 …'`
gives 24.7 % unknown, the same python3 as the main command 0.2 %. A traced build of `profile` shows no
`B_SYSTEM_PROFILER_IMAGE_ADDED` event after the initial scan (team, thread and exec events do arrive). Cause, by
arithmetic (not yet tested): `ImageNotificationService::Notify()` (`src/system/kernel/image.cpp`) builds its KMessage in
`char eventBuffer[128]`; with 64-bit pointers the three fields need 28 (header) + 32 + 32 + 40 = **132 bytes**
(`sizeof(FieldHeader)` is 20), and `KMessage::_AllocateSpace()` returns `B_BUFFER_OVERFLOW` for a buffer it does not
own, so `AddPointer("imageStruct")` fails and the system profiler's `EventOccurred()` drops
the event for a NULL `imageStruct`. The team service's message is exactly 128 bytes ("team"/"teamStruct" are one byte
shorter each), which is why team events work. Not an rpi4 change (upstream code; x86_64 should show it too). Fix:
a 256-byte buffer, as thread.cpp's 180. Everything below therefore takes userland shares from the debugger-path runs
and the single-team runs, and system-wide shares only for the teams that existed before the profiler (app_server,
servers) and the kernel.

Load (pmustat during run 1): idle before **0.5 %** busy; Terminal + Firefox loading 55 %, pages + video 42–55 %, STK's
menu with Firefox's two windows still open **74–76 % of all four CPUs** (IPC 0.29; in run 3 STK's main thread ~84 % of a
core and app_server's thread for its window ~38 %), 3 % after; IPC 0.29–0.64, L2 refills 13–22 % of L2 accesses, the ARM
at 1519–1565 MHz while busy. Run 1: 778 744 ticks (4 CPUs × 196 s), idle 49.9 %, kernel ~25 % of the non-idle ticks.

| # | Symbol | Share (run, base) | Where / callers | Explained? → candidate |
|---|---|---|---|---|
| 1 | (userland of teams started after `profile -a`) | 65 % of run 1 non-idle | the profiler bug above | → **N1** |
| 2 | `memcpy` (libroot) | **10.5 %** of system non-idle (run 3, 27.7 s CPU) | app_server window threads: STK's GL window **20.8 s** (72 %; the present copy, `HWInterface::CopyToBackAndFront` in the same thread), Firefox's 6.4 s (`DrawBitmap`, `copy_row_opaque`) | copies already fused (§2) and DRAM-bound (§3); new: the STK menu renders far above the 60 Hz refresh: ~190 fps (derived: the fused copy is 6.27 ms per 1080p frame, gpu-present.md §2 table; × 1024·576 / 1920·1080 = 0.28 → ~1.8 ms; 20.8 s / 1.8 ms ≈ 11 500 frames in ~60 s), and windowed presents are unpaced (flip-window 124.1 fps, C10) → **N3** |
| 3 | `memcpy` (apps) | 12.4 % of the apps' CPU (run 4) | Firefox's busiest thread (an NSPR thread, 46 s; likely its compositor, unverified) 13.2 s, the rest of it in libxul; another Firefox thread 6.6 s; STK 2.6 s (`u_vbuf_draw_vbo`: client vertex arrays, 3.4 % of STK) | Firefox software compositing: parked (§3); STK: the game's GL use |
| 4 | Firefox threads (libxul, JIT) | 70 % of the apps' CPU (run 4) | unstripped parent run: JIT 11 % (`EnterJit` 4.7 %, JIT fallback 6.6 %), `memcpy` 3.9 %, `cache_start_sub_transaction` 2.7 %, `GenetDevice::Send` 1.8 % (remote disk), LZ4HC 1.3 % (startup cache) | Gecko-internal except the BFS item → **N6** |
| 5 | SuperTuxKart main thread | 24.5 % of the apps' CPU (run 4); ~65 % of a core in its menu | `cg-stk` (251 448 ticks): v3d `cache_hash` → BLAKE3 **5.1 %**, `__aarch64_*` atomics 5.5 % (`v3d_draw_vbo`, `util_primconvert_draw_vbo`), `__tls_get_addr` **2.3 %** (from every GL call: glvnd dispatch), `FontWithFace::render` 4.4 % and `irr::…draw2D*` (the game) | → **N4**, **N5**, C11 atomics |
| 6 | `__aarch64_ldadd4_acq_rel` (kernel, stack, genet) | 2.0 % of system non-idle (run 1) | no single caller (as W43 10-24 13:46) | C11, unchanged |
| 7 | `ConditionVariableEntry::Wait` / `_Notify`, `switch_sem_etc`, `thread_block` | 1.0 / 0.5 / 0.4 / 0.3 % (run 1); 1–3 % in every profile | — | most likely the tick landing where interrupts come back on after a context switch, not CPU spent there; unverified |
| 8 | `cache_start_sub_transaction` (block cache) | 0.8 % of system non-idle; **2.9 s** CPU in one Firefox first start | all from BFS `Journal::Lock`; walks every block of the combined transaction at each sub-transaction (O(n) per write, O(n²) per combined transaction) | → **N6** |
| 9 | `GenetDevice::Send` | 0.9 % (run 1); 10.1 % of non-idle while Wine writes its prefix | netboot remote-disk writes: ~12 µs CPU per frame (8.4 s for ~1 GB) | bench only (network boot); not ranked |

Profile controls (§2 items that must stay down): TLS `python3 -m timeit "sum(i*i for i in range(1000000))"` **392 / 412
ms** (10-24: 391) — not regressed, but `__tls_get_addr` is still **18.1 %** of that loop's profile (→ N5); fresh-boot
forkbench: `arch_cpu_sync_icache` 11.8 %, `__aarch64_ldadd4_acq_rel` 7.2 % of its ticks (10-24: 6.5 %, 5–8 %) with
fork+exec at the 10-24 time — not regressed. pmustat: python3 CPU-bound IPC **1.68**, L1D refills 0.04 %; 64 MiB
copies IPC **0.435** (10-25: 0.49), 16 KiB copies 0.86 (0.87).

**Process start gets slower once GUI applications have run (N2).** Same binary (`tools/haiku-tests/forkbench.c`,
GCC 16.2), µs per operation:

| State (11-03c unless noted) | fork+exit | fork+exec `/bin/true` | posix_spawn | `for` 200 × `/bin/true` |
|---|---|---|---|---|
| fresh boot, 11-03b | 1007–1055 | 4607–4670 | 3332–3429 | 1.01–1.04 s |
| fresh boot | 977–1151 | 4607–4701 | 3348–3386 | 1.06 s |
| after `pkgman install` | 1004 | 4595 | 3539 | — |
| Terminal open | 1258 | **6799** | 4867 | — |
| Firefox open / quit | 2231 / 1146 | 6308 / 7847 | 5405 / 5288 | — |
| STK open / quit | 2425 / 2299 | **8748 / 8313** | 6697 / 6572 | — |
| after the 85-minute C0 session | 1298–1751 | 7883–8075 | 4578–5160 | 1.56 s |

So 11-03b = 11-03c = the 10-24 baseline on a fresh boot; the first GUI application (Terminal) adds ~2 ms to every
fork+exec and the slowdown stays after the applications quit (teams back to 29; areas 1723 → 1971–2842). In the slow
state the runtime loader's symbol work (`resolve_symbol`, `find_symbol`, `elf_hash`, `relocate_rela`, `match_symbol`,
`strcmp`) is ~20–29 % of forkbench's ticks; on the fresh boot none of them is in its top 12. `/bin/true` still loads
only libroot and libgcc_s (`listimage` of a `sleep`). Cause unknown. `tools/pi-tests/startcost-steps.sh` repeats the
steps.

**Gating numbers for C4, C5, C7, C8:**

- **C4 (SD writes): still unmeasured.** The card holds the owner's test image (mega20), so no Linux `dd` in the flash
  lane; a network session cannot measure the card's write path.
- **C5 (Wine prefix): 80 s** on this network boot (`prefix-timeline.sh`, Mono/Gecko off, fresh image, 788 system32 /
  855 syswow64 files) — not comparable with the 126–131 s of the games-bench image (other image and package set). Wine's
  processes used **32 CPU-s** (system32 16.3, syswow64 9.4, other 6.5 of which wineserver 6.4); the CPUs were 11.5 %
  busy over a 170 s window that holds the 80 s (≈ one core during the prefix). Kernel top: `GenetDevice::Send` 10.1 %,
  `memcpy` 9.1 %, `arch_user_memcpy` 3.3 % of non-idle (the remote-disk writes). So: neither CPU-bound nor disk-bound
  on four cores — one chain of processes, ~1 core busy, the rest waiting. The card side still needs C4.
- **C7 (map_buffer_client_pointer): dropped.** Warcraft III demo menu (WoW64 + Box64, `WINEDEBUG=+fps`) **12.1 fps**,
  the same as after 0028 on 10-31. `profile -k -S` of wine and its children: `memcpy` **3.1 %**
  (`wow64_glMapBufferRange` 0.35 %; 53 % before 0028), so the gate (> ~30 %) fails. Where the time goes: 54 % in code
  of no Haiku image (Box64's translated x86 code and PE DLLs, charged to "commpage"), `_user_thread_yield` 12.1 % +
  `NtYieldExecution` 3.6 % (a thread spinning on yield), `present_framebuffer_surface_gdi` 3.0 %; CPUs 49 % busy.
- **C8 (WiFi DMA): dropped for this bench.** `tcp_throughput` 64 MiB to the host over PhoenixNet (802.11n, 2.4 GHz):
  **49.6 up / 46.2 down Mbit/s** (HARDWARE-SUPPORT: 37.4 / 46.0); CPUs **15.3 / 16.8 %** busy, the busiest one 31.6 /
  45.4 %. Of the non-idle ticks, `spin` + `system_time` are **58 % / 37 %** (busy-waiting in the SDHCI command path;
  `SdhciBus::_ExecuteCommand` + `ExecuteIoCommand` 12 / 13 %), `memcpy` 22 % on download. Not CPU-bound, so DMA has no
  rate case on this access point; waiting for the controller's interrupt instead of spinning would give back up to
  ~half a core during transfers (N7). Another AP / 5 GHz: not tried (the bench has one).

**New candidates (from this profile):**

| ID | Item | Measured | Likely fix | Effort |
|---|---|---|---|---|
| N1 | `profile -a` drops image events | 65 % of a desktop session's non-idle ticks unattributed | `eventBuffer[256]` in image.cpp's `Notify()`; then re-run C0 run (1) | S |
| N2 | process start 1.5–1.9× slower after GUI apps ran | fork+exec 4.6 → 6.8–8.7 ms, posix_spawn 3.4 → 4.9–6.7, fork+exit 1.0 → 2.3 ms; runtime-loader symbol work 20–29 % of ticks in the slow state | **done (C0b below):** not the apps — the cpufreq governor leaves the ARM at 750–1200 MHz for a fork/exec chain spread over four cores (the "fresh" state was the boot's busy minutes at 1500); fix: the clock also follows the CPUs' total active time (haiku `startcost` 83db805485): 1.03× of fresh | S |
| N3 | windowed GL presents run unpaced | STK's menu: its main thread ~84 % of a core plus app_server's copy for its window 20.8 s CPU per ~60 s (~38 % of a core; ~190 fps derived, row 2) | pace windowed presents to the display (EGL swap interval 1 for windows by default; benchmarks set 0) | M |
| N4 | v3d shader-variant cache hashes its key with BLAKE3 at every lookup — **done: mesa rpi4 ebf1ee1ff1b, ships with mesa 26.2.6-3 (Pi check: STK menu profile)** | 5.1 % of STK's CPU (`cache_hash` → `blake3_compress_*_portable`, from `_mesa_hash_table_search`) | `_mesa_hash_data` over key + the key's stored BLAKE3 instead of a fresh BLAKE3 (`v3d_program.c`); with the next Mesa revision | S |
| N5 | TLS access through `__tls_get_addr` — **done: haiku `rpi4` c6cab6cc9e + 4d433669a8 (static TLS block for the images loaded at start, no generation check), §6 "N5 results": −9.9 % instructions, −4 % cycles of the Python loop; the 18 % share was mostly hidden latency** | 18.1 % of a busy python3; 2.3 % of STK (every GL call through glvnd) | TLS descriptors (TLSDESC) in runtime_loader, or initial-exec TLS for libpython / libGLdispatch | M |
| N6 | BFS journal: sub-transaction start walks all blocks — **done: haiku `bfs-subtrans` a9db442988 (block cache tracks the blocks changed per sub transaction), §6 "N6 results"** | 2.9 s CPU of a Firefox first start; 3.1 s in the 196 s session | bound the combined transaction (Journal) or make the walk incremental (block cache) | S (bound) / M |
| N7 | WiFi SDIO waits by spinning — **done: haiku `n7-sdio-wait` 6018671453 (data blocks of ≥ 256 bytes moved by the interrupt handler, the caller sleeps), §6 "N7 results": −31 to −34 % CPU cycles per MiB, rate unchanged at equal clock** | `spin` + `system_time` 37–58 % of non-idle during transfers | interrupt-driven command completion in the SDHCI path | S–M |

**Re-ranked next three:** (1) **N1**, an hour with the re-run of run (1), because every later system-wide profile
needs it; (2) **N2**, measured 1.5–1.9× on every program start in a normal session (shell scripts, builds, configure,
haikuporter) — attribute, then fix; (3) **N3**, the largest single CPU consumer of the session (a game menu taking
~1.2 cores between the game and app_server). Then C1 and C2 as in §5; N4 rides along with the next Mesa revision
(S); C7 and C8 (DMA) leave the list.

### C0b: start-cost slowdown (N2) — the ARM clock, not the applications (2026-11-03 22:23–23:12)

Image `h20-imgevt` (11-03c + f6c52282df), network sessions `h20-c0b`, `h20-c0b-idle` and (fix) `h20-c0b-fix`; the card
was not written. Raw output `artifacts/h20-c0b/`; tools `tools/haiku-tests/forkbench.c`, `pmustat`,
`tools/pi-tests/startcost-clock.sh` (forkbench with the ARM clock sampled from `/dev/power/bcm2835_thermal/0`) and
`startcost-steps.sh`.

**Cause: the clock governor (`bcm2835_cpufreq`) runs a chain of short processes at 750–1200 MHz.** The "fresh" state
of C0 was the first ~2 minutes after power-on, when the ARM stays at 1500 MHz whatever the load (8 idle samples at 1500
right after the session came up; the drop to 750 came with the CPUs at the same ~2 % busy before and after it, so not
the load: most likely the firmware's boot-time turbo period that `bcm2835_cpufreq`'s header describes, inferred, not
traced). After that an idle desktop sits at 750 MHz and every program start runs at the clock the governor picks for
it. No GUI application is needed:

| State (11-03c + f6c52282df) | fork+exit | fork+exec `/bin/true` | posix_spawn | ARM clock during the run |
|---|---|---|---|---|
| session up (~1.5–2 min after power-on) | 965–1066 | 4619–4731 | 3403–3459 | 1500 |
| Terminal started 5 s before | 1001 | 4647 | 3398 | — |
| the same Terminal, minutes later / after it quit | 1415 / 1011 | 7265 / 8037 | 4841 / 4858 | 750–1500 (mostly 750–1000) |
| **second boot, no application at all, 4 min idle** | **1373** | **6629** | **4549** | 750 ×7, 1000, 1500 ×2 |
| clock held at 1500 by a busy loop (`sh -c 'while :; do :; done'`) | 1049 | **4802** | 3546 | 1500 ×8 |
| the same seconds later, loop killed | 1502 | 6613 | 4265 | 750–1500 |

So C0's "Terminal open → 6.8 ms" was the step order (Terminal came after `pkgman install`, past the boot's busy
minutes), not Terminal: Terminal measured 5 s after its start was fast. The decisive measurement is
`pmustat -u` / `-k` of `forkbench 100` in both states: the same work, fewer cycles per second.

| pmustat, `forkbench 100` | elapsed | cycles (all modes) | inst user / kernel | L1D TLB refills /1k inst (u/k) | L2 refills /1k inst (u/k) | "MHz while busy" |
|---|---|---|---|---|---|---|
| fresh | 0.91 s | 1.70–1.73 G | 241–243 M / 547–584 M | 6.0–6.1 / 6.1–6.5 | 5.2–5.6 / 5.3 | 1723–1724 |
| slow | 1.34 s | 1.66–1.75 G | 263 M / 555 M | 6.2 / 6.7 | 5.7 / 5.8 | 1130–1142 |

(The "MHz while busy" figure is cycles over the scheduler's busy time, so its absolute value is off; the ratio is the
point. The user instruction count is system-wide, so the longer slow run collects more background work.) Why the
governor stays low: `pmustat -A` per CPU during the loop — busy **33.6 / 28.9 / 12.3 / 33.6 %**. A fork+exec chain
(each child waits for the one before) spreads over the four cores at about a quarter each, under the scheduler's
target load (55 %), so `_RequestPerformanceLevel()` only ever *lowers* every CPU's level, and the driver asks for the
rate covering the highest level; together the CPUs are as busy as one CPU that never rests (sum 108 %).

The runtime loader's share (20–29 % in C0) is a consequence: with the clock low, the CPU-bound symbol lookups
(`elf_hash`, `strcmp`, hash-chain walks) take longer while the memory-bound kernel work scales less. `profile -k -S
forkbench` at the governor's clock: runtime_loader functions (`find_symbol`, `strcmp`, `load_image`, ...) 8.5 % of
744 ticks; at a held 1500 MHz 2.6 % of 617 ticks (small samples; `artifacts/h20-c0b/prof-*.txt`), which is why C0's
fresh-boot profile (at 1500 MHz) had none of them in its top 12.

Also from C0, now explained: "fork+exit 2.3 ms after STK" was measured **with SuperTuxKart still running** — the
game does not end on SIGTERM within 5 s and `startcost-steps.sh` killed `$2` of `ps`, which is the game's first
argument (`--windowed`), not its team ID; its "STK quit" rows (C0 and this round) are a running game's menu (two
busy cores between the game and app_server). Fixed in the script (team ID column, SIGKILL after 5 s); with the game
really gone the numbers are back to the fresh ones (below). Areas, semaphores, ports and images after the
applications quit are back within a few % of the fresh counts (areas 1705 → 1795, sems 977 → 995): nothing left
behind matters here.

**Fix (haiku `startcost` 83db805485, `bcm2835_cpufreq: follow the CPUs' total load as well`; pushed; merged into rpi4 2026-11-03 (fast-forward)
into rpi4):** the clock thread also adds up the CPUs' active time (`cpu_get_active_time()`) over its 50 ms interval
and asks for the maximum when the total reaches 55 % of one CPU (the scheduler's target load for one CPU); the
per-CPU levels and the lowering hysteresis are unchanged. Image `artifacts/images/h20-startcost.img` (release build
options `-sHAIKU_PI_GL=1 -sHAIKU_IMAGE_SIZE=4500 @pi-mmc` from the worktree; its haiku package differs from
h20-imgevt's only in `bcm2835_cpufreq`, by `package list`; the tested module is byte-identical to the committed one).

| After the fix (h20-startcost) | fork+exit | fork+exec | posix_spawn | clock |
|---|---|---|---|---|
| session up | 1012 | 4755 | 3496 | 1500 |
| no application, 5 min idle (twice) | 973–1117 | **4611–4667** | 3304–3420 | 1500 during the run |
| `startcost-steps.sh`: after `pkgman install` / Terminal open / Firefox quit | 1031 / 1063 / 1124 | **4637 / 4651 / 4825** | 3393 / 3433 / 3446 | — |
| SuperTuxKart killed (-9) | 1105–1156 | 4765–4839 | 3486–3660 | 1500 |
| (while loaded: Firefox loading pages / STK's menu running) | 2389 / 2389 | 7196 / 8557 | 5313 / 6772 | — |

Before the fix the same script at ~10 min uptime gave after-pkgman 6176, Terminal 7036, Firefox quit **7829** µs
fork+exec. Slow state / fresh: **1.03×** (was 1.4–1.7×); runs with an application busy are contention, not a start
cost. The first step of `startcost-steps.sh` measured ~5.2 ms fork+exec in both the before and the after run (right
after copying 130 MB of packages to the remote disk), so it is left out above; the before run also had one
`posix_spawn failed` in that step (one call, unexplained transient, not seen again). Idle power unchanged: an idle
desktop still samples 750 MHz between bursts, as before the fix (the sampler's own `grep`/`pmustat` starts show as
single 1500 samples in both). The trade-off: a steady light load spread over the cores that totals 55 % of one CPU or
more (video playback, a page load) now runs at 1500 MHz where the per-CPU levels gave 1000–1200, so the SoC runs
warmer then; the firmware still throttles on temperature. Sanity on the fixed image: `stk-start-loop.sh 10` **10/10** ok, 0 hangs (115.5–115.9 fps in its 20 s race); `kill-race-loop.sh 10` **10/10**, 0 faults.

Side observations: `_exit()` in libroot flushes stdio (`_IO_cleanup()` in `_exit.c`, upstream behaviour; POSIX says it
must not), so a forked child that `_exit`s re-prints its parent's buffered output — forkbench's first line appears
once per child when its stdout is a pipe. Firefox ended with a segmentation violation on `hey Firefox quit` once
(before-fix run), not seen in the after run.

### N3 results: windowed GL presents paced to the display (2026-11-04 00:16–03:39)

**Who asks for which swap interval** (code read, then checked on the Pi below). EGL's default is 1; what reaches
Mesa's Haiku EGL driver:

| Program class | Interval Mesa sees | Why | Changes with the Mesa change alone? |
|---|---|---|---|
| BGLView programs (`BGLView::SwapBuffers()`: GLTeapot, haiku3d, GLUT's `glutSwapBuffers`, everything on SDL2) | **0** | libglvnd be20124 (stage 6): `SwapBuffers()` = `SwapBuffers(false)` → `eglSwapInterval(0)`, the BeOS API's "no sync"; `SwapBuffers(true)` → 1 | no |
| SDL2 (libsdl2 2.32.10-5 and the games' copy) | **0**, whatever the game asks | `HAIKU_GL_SetSwapInterval()` returns `SDL_Unsupported()`; `HAIKU_GL_SwapWindow()` calls `BGLView::SwapBuffers()`. SuperTuxKart asks for 1 (`swap-interval-vsync` default 1: `SDL_GL_SetSwapInterval(-1)`, then 1), Yamagi Quake II too (`r_vsync` 1); QuakeSpasm (`vid_vsync` 0), ioquake3/OpenArena (`r_swapInterval` 0) ask for 0 | no |
| glmark2 2023.01 (own `BitmapHook`, EGL directly) | 0 by default (`eglSwapInterval(0)` unless `--swap-mode fifo`) | `gl-state-egl.cpp` | only `--swap-mode fifo` |
| Programs on EGL directly that leave the default; BGLView programs calling `SwapBuffers(true)` (`glflip -i 1`) | **1** | EGL default / explicit | **yes**: paced to 60 |
| Wine's OpenGL (win32u, surfaceless EGL + GDI copy) | — | renders into pbuffers, `present_framebuffer_surface_gdi`; no EGL window surface | no |
| Vulkan (WSI) | — | not EGL | no |

So the premise of N3 ("a program that never calls `eglSwapInterval(0)` renders unpaced") holds only for direct-EGL
programs: the ~130–190 fps of SuperTuxKart's menu is **interval 0 by the SDL2 gap**, not Mesa ignoring interval 1.
Changing `BGLView::SwapBuffers()`'s default instead would cap GLTeapot, GLUT and every SDL game at 60 regardless of
their settings (and break the BeOS API meaning): not done. Two changes therefore:

1. **Mesa** `paced-windows` 1595aba36ec (haiku-pi/mesa, from `rpi4` ebf1ee1ff1b — so it carries N4, the v3d cache
   hash without BLAKE3), `egl/haiku: one windowed frame per vertical blank with swap interval 1`: with interval 1 a
   windowed (non-overlay) frame waits for the next vertical blank (`BScreen::WaitForRetrace`, the retrace semaphore
   the overlay presenter uses) **after** it has been handed to the view, i.e. before the program starts its next
   frame — app_server copies a window's frame when it arrives, not at a blank, so waiting before the present would
   only show it later; the program samples its input and renders right after a blank. A frame that took longer than
   a refresh is not held back for another blank (no wait when a blank went by since the last frame, predicted from
   the blanks woken for before: late swap tearing, so a 45 fps program stays at 45, not 30). Since the wait comes
   after the present, a fast frame right after a late one is presented before its wait: two frames in one refresh
   interval at each late → fast change (not seen in the cases below: 0 late frames at 60 fps). No retrace semaphore,
   or no blank within two periods (display off): a timer at the measured period. Every window surface of a hardware
   screen gets the `BScreen`; overlay bitmaps stay BGLView-only (`hgl_native_window_shows_overlays`). Interval 0
   and the overlay path are unchanged. New: `HAIKU_EGL_SWAP_INTERVAL=0|1` overrides the program's interval
   (benchmarks, A/B); `HAIKU_EGL_FPS=1` adds `egl_haiku: window: N frames waited for a vertical blank, M went late`.
   The software (softpipe) path is not paced (QEMU only).
2. **SDL2** `patches/pending/libsdl2-2.32.10-haiku-swap-interval.patch`: `SDL_GL_SetSwapInterval()` stores the
   interval per window (0, 1, -1 = 1: the GL kit never holds a late frame back) and `SDL_GL_SwapWindow()` calls
   `BGLView::SwapBuffers(interval != 0)`; without a call it stays 0, as before. Built for the test with
   `scripts/cross-port.sh` into a private work directory and sysroot (`CROSS_PORT_WORK`, `CROSS_PORT_SYSROOT`, new;
   `tools/cmake/haiku-arm64.cmake` takes `HAIKU_PI_SYSROOT`), not packaged yet.

Built with `scripts/build-gl-stack.sh` (`--only libglvnd`, `mesa`, `stage`) + `package-gl-stack.sh --revision 3`
into private sysroot copies twice: **A** = `rpi4` ebf1ee1ff1b (control), **B** = `paced-windows` 1595aba36ec; same
libglvnd `rpi4` 8391faa, same GCC 16.2. So A and B differ by the pacing commit only (both have N4; the published
26.2.6-2 has neither).

**Pi, one network boot** (`tools/pi-tests/n3-pace.sh` as bootscript, label `n3-pace`, log
`artifacts/uart/20261104-001649-n3-pace.log`; image: `h20-startcost.img` with mesa 26.2.6-2 replaced by B's -3,
SuperTuxKart 1.5-2, glmark2 2023.01-2, screen saver off; A's `libEGL_mesa.so.0` chosen in the same boot with
`__EGL_VENDOR_LIBRARY_FILENAMES`, the new libSDL2 with `LIBRARY_PATH`). CPU from `tools/pi-tests/gl-pace.sh`: the
user + kernel time of every thread of the program's team and of app_server over 30 s (`ps -a`), and `pmustat -a 30`
for the CPUs' busy share (the two tools agree: program + app_server = 4 × busy minus 1–5 % of a core for the rest of the system). Idle desktop:
0.2 % busy.

| Case (window) | Mesa | fps | program, % of a core | app_server, % | CPUs busy (of 4) | ARM MHz |
|---|---|---|---|---|---|---|
| glflip 1280×720 `-i 1` (BGLView `SwapBuffers(true)`) | A | 272.4 / 272.6 | — | — | — | — |
| | **B** | **60.00 / 60.00** (median 16.667 ms, longest 16.88, 0 stalls; 301 of 301 frames waited, 0 late) | — | — | — | — |
| glflip 1280×720 `-i 0` | A / B | 273.0, 271.6 / 272.2, 271.8 | — | — | — | — |
| GLTeapot (interval 0) | A / B | 60.0 / 60.0 (both runs) | 10, 9 / 10, 9 | 33, 32 / 34, 32 | 11.0, 10.8 / 11.5, 11.0 | — |
| GLTeapot, `HAIKU_EGL_SWAP_INTERVAL=1` | B | 60.0 (0 frames waited, 300–301 "late") | 10, 10 | 33, 33 | 11.1, 11.2 | — |
| SuperTuxKart main menu 1024×576, libsdl2 -5 (interval 0) | A | 132.0 / 131.9 | 81 / 80 | 45 / 45 | 32.7 / 32.5 | 1555 |
| | B | 131.8 / 131.6 | 81 / 80 | 45 / 45 | 32.7 / 32.4 | 1556 |
| SuperTuxKart main menu, **new libSDL2** (game asks for 1) | A | 131.9 / 132.0 (unpaced: A ignores 1 in a window) | 81 / 81 | 45 / 45 | 32.6 / 32.7 | 1555 |
| | **B** | **60.0 / 60.0** (301 of 301 waited, 0 late) | **29 / 29** | **12 / 12** | **11.2 / 11.1** | 1357 |
| glmark2-es2 `--swap-mode fifo -b build` (EGL, interval 1) | A / B | 473.6 (score 472) / **60.2 (score 59)**, 302 waited | — | — | — | — |
| glmark2-es2 default (800×600 window, interval 0), full run | A / B | score **331, 332 / 332, 332** | — | — | — | — |

Findings:

- **SuperTuxKart's menu with both changes: 132 → 60 fps, the game 81 → 29 % of a core, app_server 45 → 12 %, the
  four CPUs 32.7 → 11.2 % busy** — ~1.26 cores → ~0.41 cores (pmustat's cycles per busy time, not the clock,
  1555 → 1357 MHz: the governor runs the lighter load lower part of the time). (C0 derived ~190 fps from the copy cost; measured here it is 132 at 1024×576 on this image.) With the
  Mesa change alone (packaged libSDL2) nothing changes for it; with the SDL2 change alone (Mesa A) neither: both are
  needed.
- GLTeapot is not a consumer: it limits itself to 60 fps (its own timer), so it ran at 60.0 in every case, and with
  interval 1 forced every frame arrives after a blank already passed (all "late", none waited) — the late rule does
  what it should: no extra wait for a program already at the refresh rate. Its 33 % app_server share at 60 fps is
  the window copy (§3, already fused).
- Interval 0 is unchanged: glflip 272 = 272, STK 132 = 132, glmark2 331.5 vs 332 (scores are integers; ±0.3 %).
- Interval 1 in a window: exactly 60.00 with no stalls (glflip, 900 frames twice, longest swap 16.88 ms) and the period
  estimate converges to 16.659–16.663 ms.
- glmark2 by default calls `eglSwapInterval(0)`: its windowed score does not change (331/332 → 332/332).

**Games bench A vs B** (`scripts/games-bench-image.sh h20-startcost.img` + mesa -3 A or B + glmark2 package; network
boots alternating A, B, A, B; labels `gbn3a-1`, `gbn3b-1`, `gbn3a-2`, `gbn3b-2`; `scripts/games-bench-table.py`).
Every game there runs at interval 0 (SDL2 -5 / the games' copy: always 0; Wine: pbuffers; vkQuake: Vulkan), so the
bench checks that the change costs the interval-0 path nothing:

| game, setting | A fps (runs) | B fps (runs) | change |
|---|---|---|---|
| quakespasm 640x480 | 205.9 (205.6 / 206.3) | 206.1 (205.8 / 206.4) | +0 % |
| quakespasm 1280x720 | 82.6 (82.6 / 82.6) | 82.5 (82.5 / 82.6) | −0 % |
| quakespasm 1920x1080 | 40.3 (40.3 / 40.4) | 40.3 (40.4 / 40.3) | +0 % |
| vkquake 1280x720 | 55.2 (55.2 / 55.2) | 55.0 (55.1 / 55.0) | −0 % |
| vkquake 1920x1080 | 33.1 (33.1 / 33.1) | 33.2 (33.2 / 33.1) | +0 % |
| quake2 640x480 | 215.0 (214.7 / 215.3) | 215.2 (215.1 / 215.3) | +0 % |
| quake2 1280x720 | 106.3 (106.2 / 106.4) | 106.3 (106.3 / 106.3) | −0 % |
| quake2 1920x1080 | 55.5 (55.6 / 55.5) | 55.6 (55.6 / 55.6) | +0 % |
| quake3 1280x720 (egl, bots) | 89.5 (89.5 / 89.5) | 88.8 (88.0 / 89.7) | −1 % |
| openarena 1280x720 window | 55.5 (55.7 / 55.3) | 55.6 (55.7 / 55.5) | +0 % |
| openarena 1920x1080 fullscreen | 27.9 (27.9 / 27.8) | 28.0 (28.1 / 27.9) | +1 % |
| supertuxkart 1280x720 (egl) | 36.5 (32.4 / 40.7) | 43.6 (38.0 / 49.2) | +19 % (noise, below) |
| — its own "Average FPS" | 117.7 / 117.8 | 117.8 / 117.8 | 0 % |
| wine gltest-arm64 20s | 161.5 (161.9 / 161.1) | 162.9 (163.4 / 162.3) | +1 % |
| wine gltest-x86 20s | 162.8 (163.4 / 162.2) | 163.2 (163.1 / 163.4) | +0 % |
| wine d3dtest-x86 window | 129.4 (128.4 / 130.5) | 129.8 (129.7 / 129.9) | +0 % |
| wine d3dtest-x86 fullscreen | 140.9 (141.9 / 139.8) | 140.9 (139.8 / 142.1) | +0 % |
| wine d3dtest-arm64 fullscreen | 148.5 (149.5 / 147.5) | 148.2 (146.5 / 150.0) | −0 % |
| wine halflife window | 90.0 (89.4 / 90.6) | 92.0 (92.4 / 91.6) | +2 % (noise, below) |

Temperatures after the runs 62.7–72.5 C, never throttled; Wine prefix 129/124 s (A), 123/126 s (B).
Two cases are outside ±1 %, both by boot-to-boot noise, not by the change: **SuperTuxKart's egl rate** (its presents
per second in the 60 s race) spreads 32–49 between boots of one image (34.7–45.9 over the ten games-bench boots
before these that produced a figure) while its own loop rate is 117.7–117.8 in all four; **Half-Life** (Wine: pbuffers and a GDI copy,
no EGL window surface — the changed code is not reached) spreads 88.3–94.2 over the twelve earlier boots. For every
interval-0 BGLView window (all of the games) B runs the same calls as A plus one `is_overlay()` per frame; the
`BScreen` it now creates for non-BGLView windows was already created for BGLView ones. No case here uses interval 1,
so none is capped at 60.

**Ready to land?** **Yes for the Mesa commit** — interval 0 unchanged (glmark2, glflip, STK menu, 18 games-bench cases within
±1 % or explained noise), interval 1 in a window exactly 60.00 with no stalls, 0 panics or debugger entries in the
five boots. It ships as **mesa 26.2.6-3** built from `paced-windows` (which also carries N4, ebf1ee1ff1b, the
revision -3 was planned for). **The CPU gain needs the SDL2 patch as well** (libsdl2 2.32.10-6): with mesa -3
alone the only programs that change are direct-EGL ones that keep interval 1 and BGLView programs calling
`SwapBuffers(true)`; neither is in the image's default set (glmark2 sets 0). The SDL2 patch is a behaviour change
users see (SuperTuxKart and Yamagi Quake II at 60 fps by default; their own vsync settings turn it off), the reason
it is kept in `patches/pending/` rather than in `patches/libsdl2/` until it is landed with mesa -3. Not checked:
a 50 or 75 Hz display mode (the period is measured, so it should follow), and the full-screen (overlay) path
with the new libSDL2 (stage 6's vsynced flips at 60.00, already measured with `glflip -i 1`).

Landing steps (when decided): mesa `rpi4` fast-forwards to `paced-windows` (it is `rpi4` + one commit); mesa 26.2.6-3
from `package-gl-stack.sh --revision 3` (the three parts of a package bump, AGENTS.md; B's packages are in the job's
tmp, rebuild them from the branch); `patches/pending/libsdl2-2.32.10-haiku-swap-interval.patch` moves into
`patches/libsdl2/` and libsdl2 goes to revision 6 (`scripts/build-packages.sh`'s SDL2 step, `--revision 6`), and
`scripts/build-games.sh` refreshes the games' own copy. Behaviour after landing: SuperTuxKart (default vsync on) and
Yamagi Quake II (`r_vsync 1`) run at the display's 60 Hz in a window and on a plane; any SDL game that asks for
vsync gets it; a direct-EGL program that never sets the interval is paced (glmark2 only with `--swap-mode fifo`).
The games bench therefore exports `HAIKU_EGL_SWAP_INTERVAL=0` from now on (`tools/pi-tests/games-bench.sh`; older
Mesa ignores it), so its figures stay uncapped and comparable.

### N6 results: BFS sub-transaction start walks only the changed blocks (2026-11-04 05:50–07:05)

**Why the walk exists** (code read: `src/system/kernel/cache/block_cache.cpp`, BFS `Journal.cpp`). BFS runs every file
system operation (create, each size-changing `write()`, each attribute write, unlink, ...) as a `Transaction`. To
save log writes, `Journal::_TransactionDone()` does not log a finished one while the combined transaction is under
`fMaxTransactionSize` = log/2 − 5 blocks (**2043** with the 4096-block log of any volume over 1 GiB, our boot volumes
included): `fUnwrittenTransactions++`, and the next operation's `Journal::Lock()` calls `cache_start_sub_transaction()`
on the same block-cache transaction. A sub transaction must be revertible on its own (`cache_abort_sub_transaction()`
when the operation fails, e.g. ENOSPC) and detachable (`cache_detach_sub_transaction()` when it would overflow the
log), so each block remembers its parent version in `parent_data`: `== current_data` means "changed in the parent,
not yet in this sub" (the copy is made lazily on the first write in the sub), a separate buffer is the parent's
version, NULL means "joined in this sub". The start moved the previous sub's changes into the parent by walking
**every** block of the transaction (free the parent copy, set `parent_data = current_data`, revert discarded
blocks): O(n) per operation, O(n²) per combined transaction. The combined transaction ends when it reaches 2043
blocks, after 2 s idle (`TRANSACTION_IDLE` → log flusher), or on a sync; `fsync()` of a file flushes only its file
cache (`Inode::Sync()`), not the log, so a program writing steadily (a new Firefox profile) keeps it near its
maximum. Upstream has neither a bound nor an incremental start (git log of both files: the last journal change is
`MoveLog`).

**Choice: incremental, not bounding.** For every block the start did not touch between two starts, the walk was a
no-op (it set the pointer it already had). Only blocks made writable (`get_writable_cached_block()`, the only way into
a transaction) or discarded (`block_cache_discard()`) during the sub can differ. Bounding the combined transaction
(lower `fMaxTransactionSize`) would shorten the walk only by trading it for more log writes — each one a `writev`
of the log entry, a superblock write and `B_FLUSH_DRIVE_CACHE` — at a cost on the SD card that cannot be measured
here (the card holds the owner's mega21), and it would rewrite hot blocks (bitmap, directory and index B+tree nodes)
to the log more often. The incremental change keeps the disk writes identical (same log entries, same order, by
construction: the log writer takes `current_data` of all blocks, and only `detach`/`abort_sub` read `parent_data`).

**Fix** (haiku `bfs-subtrans` **a9db442988**, `block_cache: only look at changed blocks when starting a sub
transaction`; pushed, not merged): each transaction keeps a list of the blocks made writable or discarded since its
current sub transaction started (`cache_transaction::sub_changed_blocks`, linked through
`cached_block::sub_transaction_next`, `sub_transaction_changed` against double insertion); the start walks that list
only. The full walk stays for the first start of a transaction (no sub yet: every block has `parent_data == NULL`)
and after `abort_sub`/`detach`, which clear `has_sub_transaction`. The list is emptied before any block can leave
the transaction (`end`, `abort`, `abort_sub`, `detach`), so no freed block is ever on it. The per-block step is
unchanged (moved into `start_sub_transaction_block()`). `BLOCK_CACHE_CHECK_SUB_TRANSACTIONS 1` (default 0) checks
after every start that **every** block of the transaction is in the state the full walk leaves (parent = current, or
discarded with neither parent nor original data) and panics naming a missed block. +125/−27 lines, one file; BFS
untouched. The host copy `src/tools/fs_shell/block_cache.cpp` (bfs_shell, used by the image build) keeps its full walk
on purpose: it already differs from the kernel's and runs only on the build host.

**Measured** (network sessions; A = `haiku-pi4-base.img`, B = `haiku-pi4-n6.img`, both built from the worktree's own
`generated.arm64` with the release options, `rpi4` 162164220d without / with a9db442988; test volume: the session's
remote disk, `/boot`, 4.4 GiB BFS, 2 KiB blocks, 4096-block log). Reproducer `tools/haiku-tests/bfsmeta.c`:
4000 files in one new directory, each created, 4 appends of 512 bytes, 2 attributes of 40 bytes (a new browser
profile's pattern; about 7 BFS transactions per file), per-file time every 250 files. Firefox: `tools/pi-tests/n6-firefox.sh`
(profile directories removed, launched through the roster, 45 s after its first window, then quit) under
`profile -a -k -S -i 1000` (ticks = ms of CPU).

| bfsmeta 4000 × (4 writes, 2 attrs) | A (before) | B (after) |
|---|---|---|
| `cache_start_sub_transaction` ticks (under `profile -k -S`) | **289 (11.3 % of the team)**, 2nd after `EntryCache::Lookup` | **0** |
| under `profile -k -S`: wall / sys / profile ticks of the team | 11 267 / 2505 / 2558 | 14 495 / 1888 / 1936 |
| plain run: wall / sys CPU | 11 728 / 2032 ms | 10 697 / 1369 ms |
| µs per file, batches 1–7 (plain run, before the first log-full stall) | 285, 310, 335, 468, 580, 798, 581 (climbing with the batch) | 255, 281, 288, 284, 286, 313, 328 (flat) |

The wall time of both is dominated by two stalls of 2–10 s (batches 8 and 15/16: 8–39 ms per file), when the
4096-block log is full and `_TransactionDone()` syncs the transactions behind it over the network disk; the change does
not touch them (they vary run to run in both). The walk's 289 ticks are what the change accounts for; the team's
total CPU fell more than that in these runs (−24 % ticks, −25–33 % sys; one run per side), the rest being the sync
work that lands in the writer's thread and varies from run to run (`GenetDevice::Send` 235 → 135 ticks).
`get_writable_cached_block` 7 → 14 ticks (the list insertion; ~2 µs per file at most).

| Firefox first start, new profile | A run 1 / 2 | B run 1 / 2 |
|---|---|---|
| first window | 10 341 / 4 357 ms | 10 298 / 4 382 ms |
| `cache_start_sub_transaction` ticks (all teams) | **616 / 1055** | **26 / 59** (the full walks at each transaction's first start) |
| all non-idle ticks of the 82–88 s run | 105 919 / 110 517 | 104 865 / 109 805 |
| profile written (files, KiB) | 1685, 152 360 / 1645, 166 346 | 1600, 145 886 / 2068, 170 170 |

So **0.6–1.0 s of CPU saved per Firefox first start** (C0's 2.9 s came from its Firefox copy with a new profile on a
longer run, not repeated here); the first window is not later or earlier (the profile writes run beside it, not before
it). Run 1 of each is the session's first Firefox start (package reads), run 2 the second.

**Integrity.**

- *Bookkeeping check build* (B with `BLOCK_CACHE_CHECK_SUB_TRANSACTIONS 1`, session `n6-check`): bfsmeta 4000 × (4, 2)
  and 6000 × (1, 6), `rm -rf` of 4000 files; a 48 MiB BFS image (2048-block log) mounted on `/small` and filled to
  ENOSPC five times (create, mkdir and write failing: the abort paths, after which the next start takes the full walk);
  700 / 300 creates followed by a 2.6 MB / 1.6 MB attribute three times (aimed at the detach path; whether it was taken
  is not visible); a Firefox first start; three bfsmeta loops (create + unlink the oldest) for 90 s on both volumes at
  once. **0 panics, `checkfs -c` clean on both volumes** (0 not allocated, 0 already set, 0 could be freed); the
  attribute read back identical (md5).
- *Power cut*, 6 rounds on B and 5 on A for comparison: two bfsmeta loops (keep 3000 / 1200) and `cp -r` of Firefox's
  directory (294 MB) for 45 s, then `scripts/pi-session.sh stop --no-sync` (new: power off without the `sync`), boot
  the kept disk (the journal replays at mount), `checkfs -c /boot`; repaired (`checkfs /boot`) before the next round.

  | round | B: not allocated / already set / could be freed | A: same |
  |---|---|---|
  | 1 | 0 / 0 / 32 | 0 / 0 / 2 |
  | 2 | 0 / 0 / 0 | 0 / 0 / 2 |
  | 3 | 0 / 0 / 34 | 0 / 0 / 0 |
  | 4 | 0 / 0 / 2 | 0 / 0 / 2 (a deleted `f0001333`) |
  | 5 | 0 / 0 / 0 | 0 / 0 / 2 (a deleted `f0002928`) |
  | 6 | 0 / 0 / 2 (a deleted `f0002934`) | — |

  No block referenced but unallocated or referenced twice in any round; the loop directories held their 3000 / 1200
  files. What "could be freed" holds, from rounds B4–B6 and A4–A5 (`tools/haiku-tests/bfsbits.c`: the on-disk bitmap
  against the superblock's `used_blocks`, saved before `checkfs /boot` repairs and compared after): bitmap bits set
  that no file uses (bits = `used_blocks` every time, so not a stale counter), and every freed pair is **an unlinked
  bfsmeta file**: its inode block (flags `INODE_DELETED | INODE_IN_TRANSACTION`, size 2048) and its data block. BFS frees
  an unlinked file's inode and blocks in `bfs_remove_vnode()`, inside the unlink's transaction when nobody else holds
  the vnode, otherwise later in a transaction of its own (here most likely while the file cache's write-back still
  holds it: the files were ~10 s old); a log write between the two and a power cut before the second leaves the space
  allocated (BFS keeps no orphan list). So it is a pre-existing BFS behaviour, on A as on B; B's 32 / 34 are 16–17
  such files (inferred from the same kind of result, not listed: those rounds ran before `bfsbits`), and the number
  depends on how many unlinks were waiting for their free at the last log write. The change cannot alter it: in this
  load (no aborted or detached sub transactions) the log writer takes `current_data` of every block, and only
  `detach`/`abort_sub` read `parent_data`. 0 panics or debugger entries in the 18 boots, except one A boot that froze
  at start (KNOWN-ISSUES C10, retried by the session script).

**Side findings.** (1) The bench's USB stick (SanDisk Ultra, `/dev/disk/usb/0/0/raw`, owner: free to reformat) is not
usable as a scratch volume: after `mkfs -t bfs` the mount fails with "bfs: invalid superblock!", and raw reads return
different data each time (three reads of the same 1 MiB give three md5 sums; the first sectors hold kernel-heap-like
bytes): USB mass-storage reads do not deliver the device's data (HARDWARE-SUPPORT lists raw reads at 92 MB/s, which
only measured speed). A new KNOWN-ISSUES item for whoever owns that file. (2) `EntryCache::Lookup` + `Add` are 22–24 %
of bfsmeta's CPU in both images (the VFS entry cache in one directory of thousands of new names): a candidate for
later, not measured further.

**Ready to land? Yes**, as one commit on `rpi4` (fast-forward from 162164220d): it removes the per-operation walk
(Firefox 0.6–1.0 s CPU per first start; 11 % of a metadata-heavy writer's CPU), writes the disk exactly as before,
and survived the check build's exhaustive comparison under create/unlink/attribute/ENOSPC/concurrent loads and three
power cuts with A-like results (the only finding, leaked space of unlinked files, is A's too). Not exercised for certain: the detach path (a sub transaction that overflows the log),
which the check build would catch when it happens. The image for a re-check: `haiku-pi4-n6.img` in the worktree's
`generated.arm64` (job tmp, not kept).

### N5 results: thread-local storage of the images loaded at program start without the generation check (2026-11-04 10:20–12:29)

**Why arm64 code calls `__tls_get_addr()` at all** (code read + cross-compiled probes). Three causes, each enough:
(1) GCC's Haiku spec forces the traditional dialect: `sources/buildtools/gcc/gcc/config/aarch64/aarch64-haiku.h:81-83`
(`CC1_SPEC … %{!mtls-dialect: -mtls-dialect=trad}`), so no TLS descriptors; (2) **every** Haiku image, the program
included, is linked as a shared object (`LINK_SPEC "… %{!r:-shared} …"`, same file: a probe `__thread int x; int
main(){return x++;}` gives `Type: DYN`, `R_AARCH64_TLS_DTPMOD64`/`DTPREL64` and `bl __tls_get_addr@plt`), so the
linker never relaxes an access to initial-/local-exec, not even the program's own; (3) Haiku has no static TLS:
`tpidr_el0` points at the 64 `tls_get()` slots, every module's block is `malloc()`ed into the dynamic thread vector,
and `runtime_loader/arch/arm64/arch_relocate.cpp:65-73` handles only DTPMOD64/DTPREL64 (TPREL64 and TLSDESC fall to
`default: B_BAD_DATA`). So libpython's 1512 call sites, glvnd's GL entry stubs (STK's callers of `__tls_get_addr` in
`cg-stk` are STK frames: the stubs jump), libstdc++'s exception globals and libgomp all take the general-dynamic path.
The 10-24 fast path (W43 10-24 04:55, haiku 076da9813a) left 21 instructions in `__tls_get_addr`
(`src/system/libroot/os/arch/arm64/tls.c:65-86` on rpi4) with two chains of four dependent loads:
`tpidr_el0 → slot 5 → vector[0] → counter, size` against `GOT → __gRuntimeLoader → tls_generation → counter`, the
check that a reused module ID has not left a stale block (`runtime_loader/elf_tls.cpp` `DynamicThreadVector::operator[]`).

**Options and the choice.** Measured cost to recover: tlsbench, a library's `__thread` 17.4 ns against a global's 7.3 ns
(W43 10-24) — 10 ns per access at most, of which the call (PLT, `bl`, a stack frame in the caller) stays with any
fix that keeps the traditional sequence. (a) TLSDESC (`-mtls-dialect=desc`; the probe links: `R_AARCH64_TLSDESC`,
`DT_TLSDESC_PLT/GOT`) helps only with a static block at a fixed offset from `tpidr_el0` (a resolver of two
instructions, no clobbered registers); that needs the kernel to reserve that space in every thread's TLS area, a
thread-start copy, runtime-loader descriptors, the spec change, and **a rebuild of every TLS-using package**
(python3.14, mesa/glvnd, gcc_syslibs …). With a dynamic resolver it still walks the vector: little gain.
(b) Initial-exec TLS for libpython/libGLdispatch: the same static-block work plus two package rebuilds. (c) Make the
existing call cheap: the images loaded before the program's code runs are never unloaded, so their blocks can
never be stale — give them a path without the generation check. Chosen: (c), because every binary already shipped
benefits (libpython, the glvnd stubs, libstdc++) and nothing is rebuilt; (a) stays a follow-up whose remaining
gain is bounded by the numbers below.

**Change** (haiku branch **`n5-tls`**, measured on base `rpi4` b90cb3f0d4; merged into `rpi4` rebased as c6cab6cc9e + 4d433669a8, in image-2026-11-04c): **c6cab6cc9e**
`runtime_loader: static TLS block for the images loaded at program start` + **4d433669a8** `runtime_loader: align
TLS blocks to their segment's alignment`. The TLS of every image registered before `load_program()` runs the
init routines goes into one per-thread block (offsets aligned to each PT_TLS `p_align`), allocated and filled on
the thread's first access and found through a new slot `TLS_STATIC_TLS_SLOT` (`headers/private/system/tls.h`, before
`TLS_FIRST_FREE_SLOT`; the kernel clears all slots of a new thread since a000d5d6cc; fork copies it). Their DTPMOD64
relocations get `TLS_STATIC_MODULE` (bit 31) `| offset` instead of the module ID — the only relocated word in the
local-dynamic case (libpython: 5 DTPMOD64, no DTPREL64), and 32 bits because `rld_export::get_tls_address()` takes
an `unsigned`. `__tls_get_addr()` is now `ldp; tbz; mrs; ldr [tp, #64]; cbz; and; add; add; ret` for them (one
load from the thread pointer), the old path for the rest. Details: the layout is frozen before the program's init
routines or at the first block a thread allocates (an `LD_PRELOAD_ADDONS` add-on's init routine runs earlier: then the
program's modules stay dynamic); a static module that is unloaded anyway keeps its ID and place, later blocks start
zeroed instead of reading the unmapped image; a module whose load fails is unregistered; `get_tls_address()` maps the
tagged value and the plain ID of a static module to the same block (an older libroot still works, slowly); only arm64
tags (`TLS_STATIC_BLOCK` in elf_tls.h), other architectures unchanged. The second commit fixes an upstream bug found by
the new test: a dynamically allocated block came from plain `malloc()` (16-byte aligned), so an `alignas(64)`
`thread_local` sat at 32 or 48 modulo 64 (A fails that check). +~250 lines in 8 files.

**Test** (`tools/haiku-tests/tlsstatic.c`, built with the others by `scripts/build-tls-tests.sh`, run by
`tools/pi-tests/tls-tests.sh`): TLS in the program, in a linked library (.tdata, .tbss, a 64-byte aligned variable, a
pointer in .tdata that needs a relocation, local-dynamic accesses), in a dlopen()ed library, and one variable of the
linked library used from all three (same address everywhere); main thread and 4 threads before and after the
dlopen(), per-thread values kept across a barrier; dlclose and reload on new threads (tlsreload's case); fork() with
threads in the child; 2000 short threads; an extra dlclose() of the linked library before a new thread's first access
(child process); with `-p`, an add-on preloaded by `LD_PRELOAD_ADDONS` whose init routine uses its TLS before the
program is loaded. Plus tlsreload, tlsunload (200 rounds), tlsbench. **QEMU** (virt, both images with the tests,
11:35): B all PASS; A fails only the 64-byte alignment (`% 64: 32` / `48`), tlsreload/tlsunload PASS. **Pi** (every
session below): B `failures=0`, A `failures=2` (the same alignment check, all three).

**Measured** (network sessions, fresh boot each, alternating A = `haiku-pi4-n5a.img` (worktree build of b90cb3f0d4),
B = `haiku-pi4-n5b.img` (the same + the two commits), same tree, same packages; `tools/pi-tests/n5-tls.sh` over ssh;
A = n5-a1/a2/a3, B = n5-b2/b3/b4, alternating 11:45–12:29 (a3 waited 31 min for another agent's cycles); an extra B boot at 11:43 (n5-b1) ran the Pi test pass, a first A boot at 11:41 was lost to a test-script bug (LIBRARY_PATH); logs `artifacts/uart/20261104-1*-session-n5-*.log`, outputs (and the QEMU logs a.log/b.log) in `artifacts/h20-n5/`). Python: `python3 -c "sum(i*i for i in range(10**7))"` (the C0 control) five times by wall clock, twice
under `pmustat -u` (user-mode cycles, instructions, branch mispredictions), once under `profile -k -S -i 1000`;
`python3 -m timeit "sum(i*i for i in range(1000000))"` five times.

| python3 `sum(i*i …)` 1e7, per run | A (before), 3 boots | B (after), 3 boots | B/A |
|---|---|---|---|
| `__tls_get_addr` share of `profile -k -S` ticks | 18.8 / 20.4 / 19.1 % | 9.1 / 9.8 / 10.5 % | ½ |
| instructions retired (`pmustat -u`, 6 runs) | 12.86–12.88 G | 11.58–11.61 G | **−9.9 %** |
| cycles (6 runs; branch mispredictions) | 8.00 (11 M), 8.19 (25 M), 8.34 (11 M), 7.56 (11 M), 8.02 (11 M), 7.71 (11 M): mean **7.97 G** | 7.98 (41 M), 7.63 (31 M), 8.39 (64 M), 7.36 (11 M), 7.31 (11 M), 7.23 (11 M): mean **7.65 G** | −4.0 % (runs with 11 M mispredictions only: 7.93 → 7.30 G, −8 %) |
| wall clock, 15 runs: median / mean / range | 5181 / 5283 / 5066–5730 ms | 5104 / 5112 / 4924–5437 ms | −1.5 % / −3.2 % |
| `python3 -m timeit "sum(i*i … 1e6)"`, 15 runs: median / range | 396 / 366–422 ms | 386 / 368–425 ms | −2.5 % |
| tlsbench, linked library (9 runs) | 17.35 ns (and 19.35 in 4 runs) | **14.68 ns** (all 9) | −2.7 ns |
| tlsbench, dlopen()ed copy | 16.01 ns (and 19.34 in 4 runs) | 17.35 ns (all 9) | +1.3 ns |
| global variable (control) | 7.34 ns | 7.34 ns | = |
| TLS tests | `failures=2` (alignment only) | `failures=0` | |

**Reading.** The change does what it was built for: `__tls_get_addr` falls from 19–20 % to 9–10 % of the loop's profile
ticks, the loop retires **9.9 % fewer instructions** (12.87 → 11.60 G: ~128 per iteration, ~11 TLS accesses × the 12
instructions the old fast path had in excess), and tlsbench's linked-library access goes 17.35 → **14.68 ns** (the
call itself, 7.3 ns of it, remains). But the CPU time moves much less: cycles **−4 %** on average (−8 % between runs with the same, low, number of branch mispredictions), wall time **−1.5 to −3 %** (median / mean) — within the
run-to-run spread, which is large here (7.56–8.34 G within A at equal mispredictions) and partly follows the branch
mispredictions, bimodal per process on both sides (11 M in most runs, 25–64 M in 1 of 6 A and 3 of 6 B runs; most likely
address-space-layout dependent aliasing, not investigated). So the profile's 18 % overstated the TLS cost: the old check's loads were mostly hidden by the
out-of-order core (IPC ~1.6), and a timer tick tends to land on the instruction waiting for them. Cost found: a
dlopen()ed library's access is 16.0 → **17.35 ns** in B (+1.3 ns; cause not isolated — the one added, taken branch
before the old path, or code placement: A itself gave 16.0 or 19.3 ns for the same binary from boot to boot);
in this workload that is Mesa's own TLS (`_mesa_*` callers: < 2 % of STK's `__tls_get_addr` calls in `cg-stk`).
Per-thread cost: the static block is the sum of the start-up images' PT_TLS sizes, allocated and copied on each
thread's first TLS access whether or not the thread uses all of them (as glibc's static TLS): python3 32 bytes;
Firefox (the largest set in our packages) libxul 457 bytes (align 32) + liblgpllibs 16 + libmozinference 8 +
libstdc++ 32 ≈ 0.6 KB per thread; thread create+join (W44: 49.5 µs) not re-measured under B. SuperTuxKart not measured: neither image has the games packages (`HAIKU_PI_GAMES`), and its expected change, below
2.3 % × the Python ratio, is under the menu's measurement noise.

**Packages need rebuilding?** No for this change — every existing binary uses it. TLSDESC with a fixed-offset static
block (a kernel reserve per thread + `-mtls-dialect=desc` in the spec, then each package as it is next revised) could
take the remaining ~7 ns call per access: by these numbers at most another ~10 % of the Python loop's instructions
and a few % of its cycles; not worth the world rebuild on its own, worth doing together with a toolchain change.

**Ready to land?** Yes, as two commits (n5-tls, fast-forward from b90cb3f0d4; `rpi4` has since moved to 61fe84cd93,
rebase needed): correctness by the new test on QEMU and Pi, tlsreload/tlsunload unchanged; the measured gain is
small but real (−10 % instructions; −2.7 ns per access, −27 % of its cost over a global) and it fixes the alignment bug. Images not kept.

### N7 results: SDIO data blocks moved by the interrupt handler (2026-11-04 13:49–15:35)

**Where the CPU went** (code read of `src/add-ons/kernel/busses/mmc/sdhci.cpp` at `rpi4` 4d433669a8, and the A
profiles below). WiFi on the Pi 4 is SDIO on the legacy Arasan controller, by PIO (no usable DMA, wifi-bcm43455.md:55),
41.7 MHz, 4 bits: a 512-byte F2 block is ~25 µs on the bus. Every CMD53 goes through `SdhciBus::ExecuteIoCommand()`:
(1) **`sdhci.cpp:557-573`: per block, `spin(1)` until the Present State register's buffer enable bit is set** — the
bulk: ~12 000 blocks/s at 49 Mbit/s, each waited out on a CPU; (2) **`:591-599`: `spin(10)` until the transfer
complete interrupt** has set `fCommandResult`, although that interrupt is signalled and the handler already notifies
`fInterruptNotifier`; (3) `:381-385`: the deliberate 50 µs `cpu_pause()` loop for the command complete interrupt
(c283f50c5b, it gave WiFi +80 % upload; a command completes in a few µs, so it stays). `spin()` is itself a loop on
`system_time()`, so the profile's `spin` and `system_time` are one cost. Why polled: interrupts are wired (command and
transfer complete are signalled), but the buffer ready bits were only status-enabled, and the data phase read the level
bit in the thread because of the lost-edge hazard (wifi-bcm43455.md:61, R2 :172). Also in the old loop: one
variable-size `memcpy()` call per 32-bit word — the **21 % `memcpy`** of the C0 download profile was this copy, not the
network stack (A5 download: 1473 `memcpy` ticks, B5: 219).

**Change** (haiku branch **`n7-sdio-wait`**, base `rpi4` 4d433669a8: **6018671453** `sdhci: move SDIO data blocks in the
interrupt handler`, then a98a2c9890 + its revert dd77d0b1e5 — a variant measured and dropped, below; the branch's tree is
6018671453's). Blocks of at least 256 bytes (F2 data) are moved by the interrupt handler, as Linux's sdhci does on this
controller (`sdhci_transfer_pio()` from the data interrupt): before the command, the buffer ready interrupt of the
transfer's direction is signal-enabled and the buffer, block size and count are handed over under a spinlock
(`fInterruptLock`, which now also guards every `interrupt_signal_enable` read-modify-write); the handler **acknowledges
the latched bit first, then moves every block the level bit says is ready**, so an edge that comes during the copy
raises the interrupt again (the R2 order); the caller sleeps on `fInterruptNotifier` until transfer complete, with a
1 ms timeout after which it moves any ready block itself (a missed edge costs ≤ 1 ms, never an I/O error; counted
and logged at powers of two: "data blocks moved without their buffer ready interrupt"); every exit path takes the
transfer back under the lock before returning, so the handler never touches a freed buffer. **Smaller blocks stay
polled, byte for byte the old code**: register accesses and the 64-byte F1 blocks of the backplane window, which carry
the **firmware download and its read-back verification** (`bwfm_sdio_load_microcode`) — they are ready sooner than a
thread wakes, and keeping them unchanged keeps the bring-up path that R2 was about. Words are copied with fixed-size
accesses. A bus without interrupts (ACPI's polling thread) keeps polling (`fWorkerThread` is now initialized, so that this
can be told). The SD card's controller (emmc2) uses ADMA2 and never has such a transfer: for it the handler change is a
no-op. +240 / −53 lines in sdhci.cpp/.h.

**Measured** (network sessions, fresh boot each, alternating A = `haiku-pi4-n7a.img` (worktree build of 4d433669a8),
B = `haiku-pi4-n7b.img` (the same + 6018671453), same tree, same packages: a1 b1 a2 b2 a3 b3 a4 b4 a5 b5, 14:20–15:33;
`scripts/n7-wifi.sh LABEL` runs `tools/pi-tests/n7-wifi.sh` over ssh against `scripts/net-perf-server.sh` on the
bench's 2.4 GHz soft AP (PhoenixNet, 802.11n): WiFi bring-up; 3 × (64 MiB up, 64 MiB down) with `tcp_throughput` under
`pmustat -A`; from boot 3 on the ARM clock sampled every 0.25 s during each transfer, and 2 × (up, down) with the clock
held at 1500 MHz by a user-mode busy loop under `pmustat -k` (kernel cycles and instructions only); one up and one down
under `profile -a -k -S`; the SD card check. Table: `tools/haiku-tests/n7-table.py --a n7-a1 … --b n7-b1 …`; outputs
`artifacts/h20-n7/`, serial logs `artifacts/uart/20261104-1*-session-n7-*.log`).

| per 64 MiB transfer, median (n) | A up | B up | A down | B down |
|---|---|---|---|---|
| TCP Mbit/s (15) | 49.5 | 49.2 (−0.6 %) | 46.8 | 46.1 (−1.5 %) |
| — the same, boots 3–5 only (9) | 49.4 | 49.1 | 46.5 | 46.0 |
| ARM clock samples below 1500 MHz (9) | 0 % | 61 % | 2 % | 89 % (mostly 750 MHz) |
| TCP Mbit/s, clock held at 1500 MHz (6) | 49.3 | 49.3 | 46.3 | 46.5 |
| PMU cycles of all CPUs per MiB (15) | 226 M | 151 M (**−33 %**) | 183 M | 126 M (**−31 %**) |
| kernel cycles per MiB at 1500 MHz (4) | 222.5 M | 147.4 M (**−34 %**) | 175.1 M | 121.4 M (**−31 %**) |
| kernel instructions per MiB at 1500 MHz (4) | 81.0 M | 54.2 M (−33 %) | 59.4 M | 39.3 M (−34 %) |
| CPUs busy, scheduler (15) | 19.6 % | 11.6 % | 15.9 % | 8.9 % |
| `profile`: non-idle share of ticks (5) | 19.5 % | 12.8 % | 15.2 % | 10.3 % |
| `profile`: `spin` + `system_time`, share of non-idle (5) | 58.8 % | 32.4 % | 47.0 % | 17.7 % |
| SD card raw read, `dd` 64 MiB (10 per side) | 35.5–39.2 MB/s | 34.8–40.7 MB/s | | |

Boots 1–2 used the script without the clock sampler (its `grep` 4×/s adds ~7 % of cycles, both sides); the A/B ratios
are the same with and without it (boots 1–2: 213 → 137 and 173 → 103 M cycles per MiB; boots 3–5: 227 → 156 and
185 → 128). The cycle counter stops in WFI, so it includes the interrupt handler's PIO on otherwise idle CPUs; the
profiler does not (its timer cannot sample inside the handler: `_MoveIoBlock` shows 15 ticks), and neither does the
scheduler's busy time — so the cycle rows are the measure, and they include the new cost.

**Reading.** The busy-wait goes from 59 / 47 % to 32 / 18 % of the non-idle time and the CPU cost of a WiFi transfer
falls by a third (kernel cycles −34 % up, −31 % down at the same clock; at 1500 MHz that is ~0.87 → 0.58 of a core
while uploading at 49 Mbit/s and ~0.65 → 0.45 while downloading, derived from cycles/MiB × 5.9 / 5.5 MiB/s). **The rate
does not move at an equal clock** (49.3 / 46.3–46.5 Mbit/s both sides; the AP is the limit). Unpinned, B is 0.6 % /
1.5 % slower: with the spinning gone the CPUs fall under the cpufreq driver's 55 % target and it drops the ARM to
750 MHz for most of a transfer (`bcm2835_cpufreq`, C0b/N2), which slows each packet's software path a little; with the
clock held at 1500 MHz B equals A. The download rate also differs from boot to boot by more than that (A: 47.6–48.7 on
boots 1–2, 46.2–46.9 on boots 3–5). What remains of the busy-wait in B is the polled small-transfer path (`spin(1)` /
`spin(10)` of blocks under 256 bytes: register accesses and frame headers) and the 50 µs command-complete loop
(`_ExecuteCommand` self 8–13 %); no "moved without their buffer ready interrupt" line and no CMD53 error in any B boot
(all 5 syslogs: the 5 attach lines only).

**Dropped variant** (a98a2c9890, image `haiku-pi4-n7c.img`, one boot c1 at 14:50, then reverted on the branch): the
handler woke the caller once the last block was on the bus and the caller polled ≤ 100 µs for transfer complete, to
recover the download rate before the clock effect was known. Download 46.9 Mbit/s (B1/B2: 46.2), but upload 191 M
cycles per MiB against 137 (the caller polls through each write's last block and the card's busy time) — the
rate it seemed to recover is the clock's.

**Reliability.** WiFi bring-up (association + DHCP lease) on fresh network boots: **B 5/5** (one join each, address
5.5 s after the join), **A 4/4** scripted (a4 needed a second join, 32.8 s) + a1 by hand. The first two A boots of the
session (before the script waited 3 s after association before starting DHCP) got no lease: started at once after the
join, `auto-config` gets none — a bench-script race, same on both images, fixed in the script. Firmware download and
read-back verification ran in every boot (the driver attached and its interface came up in all 13 boots of the session, the two script-race boots and c1 included; no panic or kernel debugger entry in any serial log). SD card (emmc2,
same driver): attached and probed in every boot ("mmc@7e340000 … using ADMA2", `disk/mmc/0/raw` published, DDR50),
raw read-only `dd` of 64 MiB at the same speed on both sides; nothing on the card was mounted or written.

**Ready to land?** Yes, one commit (6018671453; the branch head dd77d0b1e5 has the same tree): CPU per WiFi MiB −31 to
−34 %, rate unchanged at an equal clock, bring-up 5/5, SD unaffected. Open: (a) on this bench the governor turns the
saved CPU into a lower clock and ~1 % of rate — a load-based clock floor while a network interface is busy, or a
lower `kBusyForMax`, would be a separate cpufreq change; (b) the small transfers and the 50 µs command loop still spin
(the remaining 18–32 % of non-idle): interrupt-driven small transfers would cost a thread wake-up per register
access; (c) DMA (C8) remains off: not needed for CPU now; (c2) `interrupt_signal_enable` is still written without `fInterruptLock` by the handler's storm masking, `RecoverError()` and `Enable/DisableInterrupts()` (pre-existing; the thread's locked read-modify-write now runs per CMD53, so a storm mask could be undone once and re-masked — no hang, no I/O error); (c3) KNOWN-ISSUES.md:45 and HARDWARE-SUPPORT.md:114/:221 ("SDIO runs PIO and is CPU-bound") need rewording when this lands; (d) another AP or 5 GHz is still untried, so the rate limit
is still the AP's; (e) Images not kept beyond `artifacts/images/haiku-pi4-n7[abc].img`.

### C1 results: DT_RELR for Firefox's libxul.so, cold card A/B (2026-11-04 16:50–20:20)

**What was compared.** One Firefox, linked two ways. A: Firefox 157.0.1-5's `libxul.so` relinked from its objdir
(`artifacts/firefox/obj`, objects compiled by GCC 13.3 on 10-20/10-24) **with the 16.2 cross tools** (gcc 16.2.0, GNU ld
2.46.1) against the 11-03 sysroot (16.2 `libstdc++.so.6.0.36`). B: the same command plus `-Wl,-z,pack-relative-relocs`, nothing else.
So the A/B is "13.3-compiled objects, 16.2 link, 16.2 runtime"; a full 16.2 recompile of Firefox (hours) was not needed for
the relocation question. Both run on **image-2026-11-04c** (haiku `rpi4` 4d433669a8, hrev60314+273, runtime_loader with
DT_RELR since 4539cd2f00).
Recipe (`artifacts/relr/relink-libxul.sh rela|relr OUT LINKLIB`, under `scripts/heavy-build.sh -j 1`; under a minute of link once the objects are cached): the
link line of `toolkit/library/build` from the 10-28 relink, without its `-B` to the old RELR binutils (the 16.2 `ld`
honours the option, buildtools 1cad3a62fa). The 11-03 sysroot no longer has Firefox's link-time libraries, so LINKLIB is a
private directory: libffi, libjpeg_turbo, libwebp (+ `_devel`) extracted from `generated.arm64/download/*.hpkg` with the
jam `package` tool, and `libfreetype.so`/`libfontconfig.so`/`libevent.so` symlinked to the staged Firefox's
`lib/` copies (the shared sysroot was not touched). Checks: `NEEDED` lists identical to the shipped libxul.so (31
entries); exported symbol names (`nm -D --defined-only`) identical on A, B and the shipped one; section sizes identical except
the relocations: `.rela.dyn` **11 962 872 → 137 256 bytes + `.relr.dyn` 110 528** (RELACOUNT 492 734); unstripped 237.3 →
225.6 MB, stripped (`--strip-unneeded`, as the stage step) 178.6 → 166.9 MB. Both relinks are kept as
`artifacts/relr/libxul-{rela,relr}.so` (the 10-28 13.3-ld relink they replace is gone).

**Images.** `scripts/relr-image.sh` gained `--firefox-rela LIBXUL` / `--firefox-relr LIBXUL`: one tree per image,
`/boot/home/ffx-rela` (A) or `/boot/home/ffx-relr` (B) = the staged Firefox with that libxul.so, checked for the absence /
presence of DT_RELR; everything else (the test programs, `tools/pi-tests/relr.sh` as UserBootscript, unchanged) is the
same on both. relr.sh's order per round: Terminal, GLTeapot, Devices, the packaged Firefox (`Firefox-N`, the image's RELA
-5 package, **the same binary on both sides**), then the variant (`Firefox-rela-N` / `Firefox-relr-N`). So in round 1 the
variant's own files (libxul.so, omni.ja, the other libraries of its tree, all on BFS) are cold while the Firefox profile,
the fonts and the system libraries are already warm from the packaged launch: the **cold first window** below is that
launch, and the packaged `Firefox-1` is the boot-to-boot noise control. Every card boot is the first boot of a freshly
flashed image, the same on both sides.

**Measured.** Card: `scripts/sd-cycle.sh --flash artifacts/images/relr-c1-{A,B}.img --secs 900 --until 'RELR end'`, in the
order A, B, A, B, A, B (17:23–19:15), power off between, each flash read back and SHA-256 verified (`HFL done ok=1`), each log
checked to carry only its own variant's lines. Network: `scripts/netboot-cycle.sh --image … --retry-wedge`, B, A, B, A, B, A
(17:00, 19:17–20:20). All 12 boots reached `RELR end`; relrtest `ok` in all (big library 0 bad pointers); **0
`debug_server`, PANIC or kernel-debugger lines** in any serial log. Logs `artifacts/uart/20261104-*-relr-c1-[AB]-sd[123].log`
(+ `-flash.log`) and `…-net[123].log`. Window times from `launchtime -q`, ms; warm = rounds 2–5 of 3 boots (12 values).

| Card boots | A (RELA) | B (DT_RELR) | B − A |
|---|---|---|---|
| **variant, cold first window**, boot 1 / 2 / 3 | 15 624 / 15 582 / 16 018 | 13 722 / 13 774 / 13 784 | |
| — median (A-to-A spread) | **15 624** (436) | **13 774** (62) | **−1850 (−11.8 %)** |
| variant, warm: median / mean / range | 3126 / 3122.6 / 3095–3137 | 3102.5 / 3099.2 / 3070–3113 | −0.75 % |
| packaged Firefox (same binary), cold boot 1 / 2 / 3 | 8260 / 8251 / 8301 | 8199 / 8153 / 8251 | median −61 |
| packaged Firefox, warm median | 3112.5 | 3106 | −0.2 % |
| Terminal cold; warm median | 98–99; 65 | 98–99; 66 | = |
| GLTeapot cold; warm median | 322–329; 61 | 321–329; 60.5 | = |
| Devices cold; warm median | 243–247; 160 | 240–246; 164 | = |
| dlopen big-rela / big-relr, first (all 6 boots) | 2248–2311 / 17.2–17.4 | (same: both libraries are on both images) | |

| Network boots (remote disk) | A | B | B − A |
|---|---|---|---|
| variant, warm: median / mean / range | 3115.5 / 3112.8 / 3083–3137 | 3091.5 / 3096.9 / 3044–3170 | −0.8 % |
| packaged Firefox, warm median | 3081.5 | 3086.5 | +0.2 % |
| variant, cold (not scored: the plan leaves network colds out) | 22 997 / 24 799 / 23 992 | 22 738 / 21 201 / 22 182 | median −1.8 s |
| Terminal / GLTeapot / Devices warm medians | 66 / 59 / 162 | 66.5 / 59 / 160 | = |

**Reading.** The pass rule (§6 "Second: C1") holds: B's cold first window is not slower — every B boot (13.72–13.78 s)
is faster than every A boot (15.58–16.02 s) — and the median is **1850 ms lower, 4× the A-to-A spread** (436 ms); the
same-binary control moved 61 ms, so the difference is the relink. Warm: −0.75 % (card) and −0.8 % (network) against
−0.2 / +0.2 % for the control: "unchanged", at the edge of the expected −1 to −2 % (10-28: −1.5 % from 4 runs).
Controls Terminal/GLTeapot/Devices within a few ms; 0 debugger entries. Why 1.85 s, six times the §4 bound of 0.26 s: the
bound assumed the 11.7 MB of RELA read sequentially at the card's 45 MB/s; it is read by page faults from a BFS file, with
no read-ahead, at ~5 MB/s — the dlopen control shows the same rate on its own (12 MB of RELA in a 16.9 MB library: 2.25 s
cold vs 17 ms packed, in all six boots). **This number is for a Firefox tree on BFS.** The shipped Firefox is a package,
and packagefs reads 256 KiB ahead after two in-order reads (§2); there the same table is a **derived ~0.3–0.5 s** of the
8.2 s first launch (11.7 MB at 25–45 MB/s), not measured: a packaged cold A/B (two hpkgs, two more images, six card
boots) was not run, because the decision below is already made at the §4 bound. Side finding for C2: the same 288 MB
tree takes 15.6 s cold from `/boot/home` — although launched after the packaged Firefox has warmed the profile and the
system libraries — against 8.2 s from the package: the fault path without read-ahead is the cost, on any big
non-packaged application.

**Decision: ship DT_RELR in the next Firefox revision.** Gain: −1.85 s on a cold BFS start (measured), ~0.3–0.5 s cold
from the package (derived), −0.5 to −0.8 % warm, −11.7 MB of relocation table per process start, −12 MB in the package and
~1.5 MB of download; no cost found. The content-process crash hunt (W45 11-03 16:20) is closed (e09cfa1d9e), the other
gate in §6. What the revision needs (`scripts/build-firefox.sh`): `revision=6` (and its comment line: "6: packed relative
relocations"); `export LDFLAGS="-Wl,--hash-style=both -Wl,-z,pack-relative-relocs"` — a relink, not a rebuild (the 10-24
LDFLAGS change cost ~45 min; the relink itself is minutes); in the `package()` `.PackageInfo`, `requires` gets **`haiku >=
r1~beta6_hrev60295_178`** instead of the bare `haiku` (4539cd2f00 = `hrev60295-178-g4539cd2f00` by `git describe`; the
package version format is `r1~beta6_hrev60314_274-1`, `HAIKU_VERSION = r1~beta6` at both commits; first release with it:
image-2026-10-29, hrev60295+186); a stage check that `readelf -d lib/libxul.so` shows `(RELR)`; then the three-part
bump of AGENTS.md (the hpkg in `artifacts/packages/` alone, the copy in `generated.arm64/download/`, the version in
`build/jam/repositories/HaikuPorts/arm64`; grep the image build log for `not available`). An older runtime_loader would run
this libxul with unrelocated pointers (a crash, no error); a version `requires` cannot tell an upstream Haiku at a higher
hrev (no DT_RELR loader) from ours, which is acceptable while the package is served only from the haiku-pi repository —
if that changes, a `provides` capability for the loader feature in the haiku package is the exact form. The relink
here used the 13.3 objects; the revision should be built as `build-firefox.sh` builds it (GCC 16.2 objects): the
relative relocations are Firefox's pointer tables and change little with the compiler, so the measurement carries over (check the new RELACOUNT/RELRSZ at the stage step). Not done: enabling
`HAIKU_PACK_RELATIVE_RELOCS=1` for the image (§6 point 5, unchanged). Images deleted after the run; mega23 put back on the card.

**As built (Firefox 157.0.1-6, 2026-11-04 evening).** `scripts/build-firefox.sh`: `revision=6`, `ldflags="-Wl,--hash-style=both -Wl,-z,pack-relative-relocs"`
(one variable for the mozconfig and the new `relink` step), `requires { haiku >= r1~beta6_hrev60295_178 }`, and a
stage check that fails unless `readelf -d lib/libxul.so` shows `(RELR)`. The objdir could not be reconfigured any more: the
sysroot recreated on 11-03 lost libffi/libjpeg/libwebp and the deps step's freetype/fontconfig/libevent, so `./mach` would have
failed at configure. The new `--only relink` step re-runs the 10-24 link line of `toolkit/library/build` on the objdir's
**GCC 13.3 objects** with the 16.2 cross tools (link-only libraries from jam's download directory and the deps step's
install trees; the sysroot is untouched): 11 s, and the result is **byte-identical to the C1 B `libxul-relr.so`**, so the
measured configuration is the shipped one (it is not a GCC 16.2 recompile of Firefox; that stays a future full `./mach build`).
Stripped libxul.so 178.6 → 166.9 MB; `.rela.dyn` 137 256 bytes + `.relr.dyn` 110 528 (RELRSZ); highest GLIBCXX needed 3.4.30 (so
no newer libstdc++ than before). The package: 102 386 638 → **100 899 438 bytes**. The bump's three parts done; the regular
image built from rpi4 with it (`h20-ffx6.img`, haiku `b195a41e64` for the repository line) carries `firefox-157.0.1-6-arm64.hpkg`
next to the haiku package of that image (the build's `not available` lines name other packages, none Firefox).
Pi check (network boot, `scripts/release-check.sh`): 0 problems, 0 debugger entries, Firefox-1/2/3 windows 9698 / 3189 / 3216 ms
(11-04c: 9885 / 3210 / 3212: the same within noise; the cold card gain is for a card boot and was not re-measured), 24 launch
cycles clean; headless screenshots of a local page (first 9.0 s, then 3.2 s) and of https://www.haiku-os.org/ (5.2 / 4.9 s,
a full 1366x3352 render).

### C2 results: page faults on files read the missing pages around them (2026-11-04 21:50 – 11-05 01:00)

**Where the cold time goes (code read, `rpi4` b195a41e64).** `fault_get_page()` (vm.cpp) reads a page missing from a
file's cache with `cache->Read(offset, 1 vec, B_PAGE_SIZE)` → `VMVnodeCache::Read()` → `vfs_read_pages()` → the file
system: **one 4 KiB request per page fault**, no clustering, no sequential detection. The only multi-page reads on
the mapping path are at `mmap` time (`_vm_map_file`: an async prefetch of the first 1 MB, 67b8a53cbe, and
`pre_map_area_pages()` of pages already cached). Upstream Haiku is the same (master's `fault_get_page`, no fault
read-ahead commit found). Linux reads 128 KiB around a fault (centred; `VM_EXEC` 64 KiB-aligned on arm64; off after
`mmap_miss` > 100 for a file) and FreeBSD a 16-page aligned cluster for a fault that does not follow the previous one,
a window growing to 255 pages for sequential ones (`vm_fault_readahead`). On the card a 4 KiB read costs 0.59 ms
(disklat, below): mapped files faulted in at **8–10 MB/s**. Packaged programs escape most of it because packagefs
decompresses whole 64 KiB heap chunks into its own cache (`CachedDataReader`), so a fault there is a chunk read — the
reason for C1's side finding (the same Firefox 15.6 s from BFS, 8.2 s from its package).

**Images and protocol.** Worktree builds (`sources/haiku-c2`, `generated.arm64` configured with the main cross tools,
`download/` hard-linked) of `rpi4` b195a41e64 (Firefox 157.0.1-6, DT_RELR libxul): **A** = as is, **B** = + the first
read-around commit, **C** = + the partition test (below); each kernel-only (`vm.o`, `vnode_store.h` users). Each image
through `scripts/c2-image.sh`: bootscript `tools/pi-tests/c2.sh`, `/boot/home/ffx` = the -6 Firefox tree as plain BFS
files (`artifacts/relr/ffx-relr`: the same binaries as the package), `/boot/home/c2data` = 24 seeded test files (1 B to
8 MiB, page-size edge cases, 64 MB) with their host MD5s. Per boot, after 25 s: round 1 (cold) and rounds 2–3 (warm)
of Terminal, WebPositive, the packaged Firefox, the BFS Firefox (launchtime, first window); then every c2data file
mapped and its pages touched in one of four orders (`tools/haiku-tests/mmapcat.c`: forward, reverse, every 7th,
random; the mapping's MD5 against the host's; fault-in rate per order); `md5sum -c` of the same files; `disklat` raw
card reads. Card boots by `scripts/sd-cycle.sh --flash` (SHA-256 verified, power off between, every boot the first of
a fresh flash), A,B,A,B,A,B (21:50–23:53), then C,A,C,A,C (23:53–00:52). Table: `scripts/c2-table.py`.

**Baselines (A, 5 card boots).** Terminal cold 92–99 ms; WebPositive cold 2613–2635 ms (warm 688); packaged Firefox cold
7681–7760 ms (median 7710; warm 3080); **BFS Firefox cold 13 686–14 145 ms (median 14 047; warm 3079)**; mapped-file fault-in
7.6–9.6 MB/s; raw reads 4 KiB 0.58–0.61 ms, 64 KiB 1.84–2.67, 128 KiB 3.31–4.05, 1 MiB 26.4–32.6 ms; loader → cursor
5.42–5.63 s; 0 PANIC/debug_server. (The packaged cold start is 7.7 s here against §1's 8.2 s: the -6 libxul's packed
relocations — C1's derived 0.3–0.5 s — and a different launch order, WebPositive before it; not separated.)

**The decisive experiment (§6 step 2, `--mode catall`, 2 card boots of A).** Round 1 reads all files of the packaged
Firefox with `cat` (5210 / 5211 ms), then launches it: **4511 / 4515 ms** (cold 7710, warm 3080); then the BFS tree (8669 /
8382 ms for 277 MB), then its launch: **4332 / 4313 ms** (cold 14 047). So the packaged first start is ~3.2 s of file I/O
and ~1.4 s of other first-start work (profile, fonts, the rest of the system), and the BFS first start ~9.7 s of I/O
that a sequential read does in 8.5 s. **Part (ii), the trace-based package prefetch, is not worth building**: reading
the whole package costs 5.2 s to save 3.2 s, and the first start touches about all of it (§4: ~108 MB read of a 102 MB
package), so a replayed trace would read about as much; it could only pay as an idle-time prefetch after boot, moving
~5 s of card reads and ~100 MB of RAM there for a launch that may not come (§3 row). Part (i) is where the gap is.

**Change** (haiku branch **`c2-fault-readaround`**, one commit **a38b19efab** on `rpi4` d3cc8e3fd1, pushed, not merged;
the same tree is the tip of `c2-readahead`, a695afd793 — that branch's c529d35fb4 squashed my two measured commits onto
a newer `rpi4` and reverted d3cc8e3fd1's usb_disk.cpp by mistake, put back by a695afd793; land `c2-fault-readaround`).
`fault_get_page()`: when the page is missing from a vnode cache whose file lies on a disk partition,
`fault_read_around()` takes the run of missing pages around it inside its **64 KiB aligned cluster** (stops at a
cached or busy page and at the end of the file), inserts them busy (the faulting page `ACTIVE`, the others `CACHED` +
`busy_io`, as `read_into_cache()` leaves its reads), unlocks, reads them with **one** `cache->Read()`, and marks them
unbusy (a page the cache dropped meanwhile is freed as in the file cache; a page the read did not fill before the end
of the file is dropped). Pages for the run come from a second reservation taken with `vm_page_try_reserve_pages()`:
**it never waits for memory**; when it fails, or the neighbours are cached, the single-page read runs unchanged. If the
run does not bring the faulting page (an error, a short read), the fault restarts with `singlePageRead` set, so it
reads and reports that page exactly as before. "On a partition" = the vnode cache has the device's modified page
queue (`vfs_get_vnode_cache()` gives one exactly when `mount->partition != NULL`; new
`VMVnodeCache::IsOnPartition()`): BFS, FAT, ext2… on a disk or image file; not packagefs, nfs4, ramfs. 64 KiB from
disklat: a 64 KiB read costs 3.5× a 4 KiB one (2.06 vs 0.585 ms), 128 KiB 5.7×; and FreeBSD's random-fault cluster. No
sequential growth and no waste guard in this step (one variable; the strictly sequential consumer, the 12 MB RELA
walk, is gone with -6). +167 / −1 lines (vm.cpp, vnode_store.h).

**B, read-around for every vnode cache (604ae215bc, dropped).** BFS Firefox 8631 / 8643 / 8152 ms (−5.4 s), but the
**packaged Firefox +486 ms** (8196 / 8175 / 8216 against A's 7681–7760) and **WebPositive +163 ms** (2777–2796 against
2613–2635), every B boot outside A's range: a file-aligned 64 KiB on packagefs usually spans two heap chunks, so a
fault decompressed (and read) a second chunk the start may not need. Hence C.

| card boots: cold first window, ms (per boot; median) | A (5) | C (3) | C − A | B (3, dropped) |
|---|---|---|---|---|
| **Firefox from a BFS directory** | 14047 / 14145 / 13686 / 13813 / 14097 (**14 047**) | 8358 / 8772 / 8303 (**8358**) | **−5689 (−40.5 %)** | 8631 / 8643 / 8152 (8631) |
| Firefox, packaged | 7686 / 7760 / 7710 / 7681 / 7737 (7710) | 7747 / 7749 / 7781 (7749) | +39 (+0.5 %) | 8196 / 8175 / 8216 (8196) |
| WebPositive | 2613 / 2621 / 2633 / 2635 / 2628 (2628) | 2641 / 2622 / 2642 (2641) | +13 (+0.5 %) | 2796 / 2791 / 2777 (2791) |
| Terminal | 97 / 96 / 98 / 92 / 99 (97) | 98 / 96 / 97 (97) | 0 | 99 / 94 / 94 (94) |
| warm medians (rounds 2–3): BFS Firefox / Firefox / WebPositive / Terminal | 3078.5 / 3079.5 / 687.5 / 66 | 3088 / 3084 / 681.5 / 65.5 | +0.3 / +0.1 / −0.9 / −0.8 % | 3074.5 / 3057 / 686 / 66 |
| mapped-file fault-in, MB/s: forward / reverse / every 7th / random (per boot) | 8.3–9.6 / 8.4–9.3 / 7.6–8.3 / 8.2–8.4 | 22.9–31.7 / 27.8–28.8 / 26.5–28.9 / 27.5–32.4 | ~3.3× | 27.4–31.4 / 26.3–28.3 / 27.9–29.4 / 29.4–31.8 |
| mapped files' MD5 = host; `md5sum -c` | 24/24 and 24/24, every boot | 24/24 and 24/24, every boot | | 24/24, every boot |
| raw card read, mean ms: 4 KiB / 64 KiB / 1 MiB | 0.58–0.61 / 1.84–2.67 / 26.4–32.6 | 0.58–0.60 / 1.84–2.29 / 26.5–27.6 | = | 0.59–0.60 / 2.22–2.63 / 30.2–32.5 |
| loader → desktop cursor (`boot-times.sh`), s | 5.63 / 5.63 / 5.42 / 5.42 / 5.63 | 5.63 / 5.63 / 5.42 | = | 5.63 / 5.63 / 5.62 |
| PANIC / debug_server / KDL lines | 0 | 0 | | 0 |

The raw reads of 64 KiB and up are bimodal from boot to boot (1 MiB: 26.4–27.6 or 29.3–32.6 ms) on **both** kernels
(A boots 3–5, all three B boots): the card or its state after the flash, not the change (the raw device path does not
touch the fault code); the 4 KiB time, which decides the fault path, is 0.58–0.61 ms on all 11.

**x86-64 under KVM** (`haiku-x86-fix` worktree at a2cf89efd1 = A, + the two commits cherry-picked = B, branch
`c2-readahead-x86` local only; the worktree switched back to `x86-fix` and rebuilt afterwards). New test group
`tools/x86-tests/c2.sh` on a fresh BFS scratch volume (IDE): boot 1 copies the largest library of `/boot/system/lib`
(libLLVM-12.so, 108 MiB) and the c2data files to it and restarts; boot 2: WebPositive cold/warm, `dlopentime` of the
library from its package then of the BFS copy, the mapped-file check. A,B,A,B,A,B:

| x86-64 KVM, 3 runs each | A | B |
|---|---|---|
| dlopen of the 108 MiB library from BFS, cold (first) | 550 / 567 / 561 ms | **79 / 77 / 77 ms** (−86 %; a trial run before: 88) |
| the same library from its package, cold | 152–158 ms | 147–157 ms |
| mapped-file fault-in, MB/s (4 orders) | 38–46 | 404–444 |
| mapped files' MD5 | 24/24 ×3 | 24/24 ×4 (incl. the trial run) |
| WebPositive cold / warm | 438–439 / 129–136 ms | 433–455 / 124–130 ms |
| `x86-perf.sh` (perf group): kernel → desktop, first / second boot; app cold starts; dlopen libbe/libtracker/PNG | 4.49 / 4.32 s; — | 4.55 / 4.35 s (within the A ranges 4.40–4.72 / 4.29–4.34); all apps and dlopens ±noise (`x86-perf-table.py`) |
| FS group (bfsmeta, copy + MD5, remount, fragwrite, checkfs, bfsbits), BOOT group | — | all PASS (checkfs "28 blocks could be freed", the same as A's 11-04 run) |

**Correctness.** File contents never changed: every mapped c2data file matched its host MD5 in every order on every
boot (A 5, B 3, C 3, QEMU arm64 virt 1, x86-64 7), and `md5sum -c` (read path) too; 0 PANIC, debug_server or KDL lines
in all 13 card logs and all KVM runs. The read-around reads only pages absent from the cache, under the cache lock it
inserted them with, so a cached or dirty page is never overwritten; errors and short reads fall back to the old path.
Release check (network boot, `scripts/release-check.sh` on C without the bootscript, 00:52): **0 problems**, 24 launch cycles, 0 debugger entries; Firefox-1/2/3 windows
9628 / 3079 / 3090 ms (network boot; 11-04c 9885 / 3210 / 3212, -6 9698 / 3189 / 3216).

**Reading against §6 step 4.** The pass bar there (packaged first launch ≥ 1.5 s faster) was written for part (ii);
the experiment shows (ii) cannot reach it, and part (i) does not aim at the packaged case. Scored as part (i):
**BFS-tree cold first start −5.7 s (−40.5 %), 13× the A-to-A spread (459 ms)**; packaged Firefox +39 ms and WebPositive
+13 ms, inside A's spread (79 / 22 ms): not slower; boot unchanged; raw card rates unchanged; mapped-file contents
unchanged; x86-64 −86 % on the same kind of load with boot and packaged starts unchanged. **Pass: ready to land as
a38b19efab.** Who gains: every program, library or data file mapped from a disk file system — user-installed or
built programs, Wine prefixes, non-packaged trees, mmap'ed data — on every architecture; packaged software is
untouched. Open (not done here): (a) sequential growth of the cluster (FreeBSD's ahead window) and a Linux-style
`mmap_miss` waste guard, if a random-access mapped workload shows wasted reads; (b) a packagefs read-around aligned
to its heap chunks (would save fault round trips there, not card time); (c) the 1.4 s of non-I/O work in the
packaged first start; (d) the bimodal raw card read times. Images deleted after the run; mega23 put back on the card
(01:16, `20261105-005552-mega23-restore.log`: MEGA end, 0 PANIC, hrev60314+273).

### C4 results: SD card writes in 512 KiB commands (2026-11-05 02:55–04:30)

**Attribution first: the same card under Linux.** The flash lane (Raspberry Pi kernel 6.18.56-v8+, the firmware's
device tree) and Haiku ran the same program, `tools/haiku-tests/diskwrite.c` (sequential `pwrite`s of one request size
from a pseudo-random buffer, `fsync`, timed; `O_DIRECT` on Linux, Haiku's raw devices are not cached), driven by
`tools/pi-tests/sdwrite.sh`, at the same place on the card (from 1 GiB in). Both systems run the card the same way:
UHS-I DDR50, 50 MHz, 1.8 V, 4 bits, ADMA2 (Linux's `ios` and `mmc0: new UHS-I speed DDR50 SDXC card`; Haiku's
`mmc_disk: DDR50, 50 MHz`). The card: "SR64G", 59.5 GiB. The board: revision `c03111` (Pi 4 B rev 1.1, BCM2711 **B0**):
`emmc2bus` `dma-ranges` = the first 1 GiB of RAM on both systems, so most buffers have to be bounced.

| MB/s (10^6 B/s) | 4 KiB | 64 KiB | 128 KiB | 256 KiB | 512 KiB | 1 MiB | 4 MiB | 1 GiB in 1 MiB, ×3 | 4 KiB random |
|---|---|---|---|---|---|---|---|---|---|
| Linux (03:03 sweep; 04:03 `sizes`, 3 rounds of 128 MiB) | 2.08 | 17.4 | 23.0; 23.4–23.5 | 28.6 | 32.7; 32.9–33.2 | 33.3; 33.2–33.3 | 33.7–33.9 | 32.5 / 32.5 / 32.0; 32.7 / 32.8 / 32.7 | 602 writes/s |
| Haiku, image-2026-11-05 (A1 sweep) | 2.05 | 17.3 | 25.6 | 25.9 | 25.5 | 25.6 | — | 25.3 / 25.8 / 25.8 | 767 writes/s |

Linux's queue: `max_segments` 128 × 4 KiB pages, and `/sys/block/mmcblk0/stat` counts **512 KiB per request** (1 MiB
writes = 2 requests; the 128 KiB runs = 128 KiB). The card is size-sensitive: Linux limited to 128 KiB commands writes
23 MB/s, no better than Haiku. Haiku was flat at **25.5 MB/s from 128 KiB up** — a cap, not the card. Small and random
writes were equal (or Haiku faster). Verdict: **the driver path, ~1.3×**, not the card. (The 10-23 "6–8 MB/s
sustained" was not reproduced on any run today, Linux or Haiku: lowest 1 GiB run 22.3 MB/s.)

**Why 128 KiB.** Two limits, each 128 KiB: (1) `sdhci_fdt` published 32 DMA segments per transfer, and buffers are
mostly single 4 KiB pages; (2) on this B0 board every page above 1 GiB is bounced, and `DMAResource` builds a bounced
operation from at most one bounce buffer, capped at `kMaxBounceBufferSize` = 32 pages (8edea64c6b, 10-25). The syslog's
`DMAResource@…: low/high 0/40000000, max segment count 32` line shows both. Which limit a run hits depends on where its
buffer landed: a buffer below 1 GiB and physically contiguous already made long commands (A's occasional 36.9 MB/s
runs), which is why the first variant alone (B1: 128 segments) still measured 25.5–26.0 flat in `sizes`. No CMD12/CMD23,
busy-wait or ADMA2 issue showed: at equal command size Haiku (auto-CMD12, interrupt on transfer complete) matches or
beats Linux (CMD23).

**Fix** (haiku branch `c4-sd-writes`, pushed, not merged; on `rpi4` a38b19efab):
- `529875f0eb` sdhci_fdt: 128 DMA segments per transfer (as Linux's `SDHCI_MAX_SEGS`): 512 KiB commands for buffers in
  the DMA window. With ADMA2 one command moves them all (one 4 KiB descriptor table holds 512).
- `85d80f06f9` DMAResource: bounce buffers of up to 512 KiB (was 128), and never larger than the device's maximum
  transfer (usb_disk keeps 1 × 128 KiB); the bounce buffers are printed in the `DMAResource@` syslog line
  (`bounce buffers 16 x 524288` for the card). Cost: the card's 16 bounce buffers take 8 MiB below 1 GiB instead of 2.

**A/B** (network sessions on the card's raw device and on a BFS made fresh each time on its second partition;
A = image-2026-11-05 (hrev60314+282), B = the worktree build with both commits (hrev60314+284), same options; A2 B2 A3
B3 alternating, 03:38–04:03; per session `sdwrite.sh ab`: `sizes`, 1 GiB ×3, `disklat`, `bfs`):

| | A (A2, A3) | B (B2, B3) | Linux |
|---|---|---|---|
| raw 128 KiB requests | 25.6–26.5 | 23.4–24.5 | 23.4–23.5 |
| raw 512 KiB | 22.1–25.8 (median 23.9) | **35.2–36.1** (35.7) | 32.9–33.2 |
| raw 1 MiB | 24.0–37.1 (31.4, bimodal) | **34.9–36.4** (35.8) | 33.2–33.3 |
| raw 4 MiB | 22.6–28.5 (23.9) | **35.2–36.2** (35.6) | 33.7–33.9 |
| raw 1 GiB ×3 (sustained) | 36.7 / 30.2 / 24.2; 23.0 / 22.3 / 24.4 (24.3) | **35.3 / 33.7 / 35.2; 35.9 / 36.0 / 35.9** (35.6) | 32.7 ×3 |
| BFS 1 GiB + fsync | 26.3; 26.2 | **32.5; 32.1** (+23 %) | — |
| BFS 128 MiB + fsync (iocheck's test) | 28.7 / 22.9 / 31.6; 29.3 / 24.5 / 31.8 (29.0) | 29.8 / 23.2 / 32.7; 33.1 / 21.5 / 32.8 (31.3) | — |
| raw reads, `disklat` 1 MiB / 128 KiB / 4 KiB | 34.1 / 36.1 / 6.8; 35.8 / 36.6 / 5.9 | **44.3 / 40.4 / 6.8; 43.3 / 36.1 / 6.2** | dd 1 MiB direct 42 |

Raw sequential writes **+46 %** sustained (24.3 → 35.6 MB/s, now above Linux's 32.7), steady from 512 KiB up instead of
bimodal; 1 MiB reads 34–36 → 43–44 MB/s (the same bounce cap held them, so the old 42.6–45 figure was the lucky case);
128 KiB requests 1–2 MB/s slower (one bounce buffer per 128 KiB request either way; within the card's spread between
sessions, not chased). The 4 KiB random write rate: A 767/s, B1 516/s, Linux 602/s (the card's own state; not
re-measured per side). **BFS gains less (+23 %)**: the file cache (`file_cache.cpp` `MAX_IO_VECS` 32) and the page
writer (`PageWriteTransfer::fVecs[32]`) still hand the disk at most 32 pages per request, so BFS data writes stay at
128 KiB commands unless pages happen to be contiguous; raising those two is a VM change, left for a follow-up (expected:
BFS up to the raw 35 MB/s). The 128 MiB + fsync test is dominated by its first-write variance (21.5–33.1 on both sides).
`pkgman install` was not timed: a network session installs to its remote disk, and a card-booted session needs a
repository server — the BFS rows stand for it.

**Integrity.** `pattern.bin` (64 MiB random, SHA-256 9de9b843…): Haiku A wrote slot 0 → read back on Haiku A and on
Linux (twice): equal; Linux wrote slot 1 → read on Haiku B1 and B3: equal; **Haiku B wrote slot 2 (33.5 MB/s) → read
back on Haiku B and on Linux: equal**; the same file copied through B's file cache onto BFS and read after a remount:
equal (all four A/B sessions). 0 mismatches in 13 comparisons.

**Checks on B.** `scripts/release-check.sh` (network boot, 04:07): **0 problems**, 24 launch cycles, 0 debugger
entries, Firefox 9668 / 3058 / 3046 ms. Card boot (`sd-cycle.sh --flash`, SHA-256 verified, 04:11): hrev60314+284, the new `DMAResource` line, DDR50, 0 PANIC,
loader → cursor **5.62 s** (C2's A: 5.42–5.63), desktop on HDMI. Logs: `artifacts/h20-c4/` (sweep, ab-*, relcheck),
`artifacts/uart/20261105-0[234]*-c4-*`, `artifacts/uart/20261105-0[34]*-session-c4-haiku-*.log`; images deleted
afterwards; MEGA24.

## 7. Still unmeasured, in one list

- (Measured by C0 on 11-03, §6 "C0 results": the desktop-session profile and its pmustat figures, the network-boot
  Wine prefix, the post-0028 Warcraft III profile, WiFi CPU load.)
- A system-wide profile with the applications attributed (needs N1). (N2's cause: found, C0b.)
- (The SD card's write speed on Linux: measured 11-05, §6 "C4 results" — Haiku was capped at 128 KiB commands, fixed.)
  Open from C4: the file cache and page writer's 32-page transfers (BFS writes 32 vs raw 35 MB/s); a second card on
  Haiku; the Wine prefix from the card (C5).
- The WiFi limit without the bench AP (another AP or 5 GHz, C8).
- The fraction of Firefox's package a first launch touches, and the order's stability (C2).
- (Cold-card effect of DT_RELR from a BFS tree: measured 11-04, §6 "C1 results".) The same cold A/B with Firefox
  **as a package** (packagefs read-ahead): only derived (~0.3–0.5 s); and the page-cache footprint of the relocation pages.
- (BFS page-in of a big application tree with no read-ahead on faults: measured and fixed by C2, §6 "C2 results".) Open
  from C2: sequential growth of the fault cluster and a waste guard (Linux's `mmap_miss`); read-around on packagefs aligned
  to its 64 KiB heap chunks; why the card's raw 64 KiB–1 MiB reads take 25 % longer on some boots (both kernels).
- Today's boot phase table (C3).
- Which Wine games are CPU-bound; any per-setting Box64/FEX game rate (C9).
- The stage-6 re-run after `stage6-keying` (C10, owned by F2) and MediaPlayer's per-frame RGB32 conversion cost.
- `KDEBUG_LEVEL 1 → 0`, out-of-line atomics, OpenBLAS (C11).
- First-frame compile hitches of the games with a cold Mesa shader cache: the games bench boots a fresh image
  every time (cold cache by construction) but reports steady-state fps only.
- Cause of G2's first-clip stalls (C6).

## 8. Script and tool index for the measurements above

| Purpose | Tool |
|---|---|
| Games, Wine fps, same content on both images | `scripts/games-bench-image.sh BASE OUT [--remove PATH] [FILE:PATH]` → `scripts/netboot-cycle.sh --image IMG --secs 2400 --until 'GB end' --retry-wedge --label ...` → `scripts/games-bench-table.py --a NAME LOGS --b NAME LOGS` |
| Launch times, Firefox, quirks of a release image | `scripts/release-check.sh IMG [LABEL]` (`tools/pi-tests/relcheck.sh`, `tools/haiku-tests/launchtime.cpp`) |
| GL present path | `tools/gl-tests/present-bench.cpp`, `tools/pi-tests/gpu-present*.sh`, `tools/pi-tests/glmark2.sh` (`GM2 … Score`), `tools/pi-tests/gpu-stage6.sh` |
| Boot | `scripts/sd-cycle.sh --flash IMG --secs 120`, `scripts/boot-times.sh LOG`, `scripts/boot-bench.sh` (reliability) |
| Storage | `tools/pi-tests/iocheck.sh`, `perf-report.sh`, `coldstart.sh`, `coldcat.sh`; `tools/haiku-tests/disklat.c`, `nocacheread.c`; SD writes on Haiku and Linux (C4): `tools/pi-tests/sdwrite.sh` + `tools/haiku-tests/diskwrite.c` (in a session, or in the flash lane by `sd-cycle.sh --script`; destroys the card's data) |
| BFS metadata writes, journal (N6) | `tools/haiku-tests/bfsmeta.c` (files + appends + attributes, per-file time; `--loop` for power cuts), `bfsbits.c` (on-disk bitmap vs used_blocks; the blocks a `checkfs` freed and what they held), `tools/pi-tests/n6-firefox.sh` (Firefox first start with a new profile, under `profile -a`), `scripts/pi-session.sh stop --no-sync` (power cut), `checkfs -c` |
| Network, WiFi | `tools/pi-tests/net-perf.sh`, `scripts/net-perf-server.sh`, `scripts/wifi-join-image.sh`; in a session: `scripts/n7-wifi.sh LABEL` (`tools/pi-tests/n7-wifi.sh`: join + DHCP time, TCP up/down under `pmustat`, ARM clock samples, clock-held runs with kernel cycles, `profile`, SD probe check), `tools/haiku-tests/n7-table.py` |
| Profiling | `profile -a -k -S` (N1: misses teams started after it), `pmustat` (`tools/pi-tests/pmustat.sh`), `tools/haiku-tests/cgcallers.py` (`--self`: flat top of callgrind output), `profsum.py` (rank text profiles, a symbol by thread), `lookupsim.py`; desktop workload `tools/pi-tests/c0-desktop.sh` |
| GL frame rate + CPU of one program in a window (N3) | `tools/pi-tests/gl-pace.sh LABEL WARMUP SECS CMD` (fps from `HAIKU_EGL_FPS`, the team's and app_server's CPU by `ps -a`, `pmustat -a`); bootscript `tools/pi-tests/n3-pace.sh` (two Mesas in one boot by `__EGL_VENDOR_LIBRARY_FILENAMES`) |
| Process start over a session | `tools/pi-tests/startcost-steps.sh` (forkbench after each desktop step), `startcost-clock.sh` (forkbench with the ARM clock sampled) |
| Wine | `tools/pi-tests/prefix-timeline.sh`, `x86-cpubench.sh`, `wine-games.sh`; `tools/wine-tests/cpubench.c`, `prefix-timeline.py` |
| Firefox | `tools/pi-tests/firefox-video.sh`, `ffstall.sh`, `ffv-prof.sh`, `firefox-start-loop.sh` |
| DT_RELR | `tools/pi-tests/relr.sh`, `scripts/relr-image.sh`, `artifacts/relr/` |
| Cold starts, page-fault read-around (C2) | `scripts/c2-image.sh [--mode launch\|catall] IMG OUT` (bootscript `tools/pi-tests/c2.sh`: cold + warm Terminal, WebPositive, packaged and BFS-tree Firefox; `tools/haiku-tests/mmapcat.c` fault-in rates + MD5 of mapped files; disklat) → `scripts/sd-cycle.sh --flash OUT --secs 900 --until 'C2 end'` → `scripts/c2-table.py --a LOGS --b LOGS`; x86-64: `tools/x86-tests/c2.sh` (`scripts/x86-test.sh c2 IMG --scratch S --file artifacts/c2/x86/c2data.tar:/boot/home/x86t/c2data.tar`) |
| Python | `tools/pi-tests/python.sh` |
| Process / thread / memory | `tools/haiku-tests/forkbench.c`, `membench.c`, `tlsbench.c`, `threadstack.sh` |
