# RenkuOS and our Raspberry Pi 4 work

(Read-only analysis, 2026-11-04. Nothing was built, pushed, forked or posted. Their tree read at RenkuOS/Source `main`
`fe12fcdd3a`; ours at haiku rpi4 `83db805485`. Markers: [V] verified in their tree, on GitHub or in ours; [C] their
claim, not checked; [I] inference. The working data — clones of their three repositories and the per-commit and
per-file merge checks behind §4 — was kept only for the analysis and is not in this repository.)

**Status (2026-11-04 evening).** Owner decision: take RenkuOS's three fixes that we lacked into our fork and keep them;
do **not** go further with the plan in §4–§5 (no contact, no pull requests) for now. Done in `rpi4` 0b22f22f5b —
strong compare-and-swap (#189; our GCC 16.2 build turned out not to be affected: outline atomics already retry),
launch_daemon `pipe2(O_CLOEXEC)` (#231), PSCI power-off/reboot (#160; our U-Boot path has no PSCI, so our own
`bcm2835_pm` watchdog driver does it) — see [renkuos-fixes.md](renkuos-fixes.md). Since the analysis our fork also
fixed the USB disk cache maintenance and DMA window, C14 and TLS access; the commit SHAs and counts below are as of
the analysis.

## Executive summary

1. RenkuOS (github.com/RenkuOS/Source, created 2026-09-02) is a Haiku fork set up to accept machine-assisted code. It
   has 309 non-merge commits since the fork point. 46 are upstream cherry-picks, and 186 carry `Assisted-by:`, mostly
   Claude Opus 5/5.5 [V].
2. Very active: 259 PRs, about 182 merged, median 1 day from opening to merge [V]. KevinAdams05 pressed merge on all but
   one, so he is a single point of failure.
3. Rules are strict but mechanical: DCO `Signed-off-by`, `Assisted-by`, SPDX on new files, `Ported-from`/
   `Ported-from-license` trailers, a 400/1000-line cap and a two-subsystem cap. A human must be the engineer of record
   for every line [V].
4. Pi 4 support came in 8 PRs by linkslice (Bryan Irvine), +7.7k lines, all Claude-assisted, merged 10-23 to 11-01;
   tested on a Pi 400 [C].
5. Their port boots through the Raspberry Pi 4 UEFI firmware in ACPI mode, and its drivers attach to ACPI device IDs.
   Ours boots through U-Boot with a device tree. That difference decides how our work can be merged.
6. They have EFI boot, SD (polled, no DMA), GENET, xHCI on firmware-initialised PCIe, their own WiFi driver, PSCI
   power-off and SIGILL delivery. They have no GPU, display driver, audio, Bluetooth, HEVC, cpufreq, thermal, RNG or
   GPIO, no arm64 CI build and no arm64 image [V].
7. We are ahead in almost every area. Of our 44 ★ generic fixes only one (`get_next_child_node`) is in their tree;
   two or three are partly covered by their own equivalents. Missing there: the upstream TTBR0 cold-boot regression, the
   page-writer regression and an arm64 sigreturn privilege escalation [V].
8. Mechanically the merge is mostly easy: 330 of our 363 changed files take our final diff cleanly; 192 of our 254
   commits cherry-pick cleanly in order. Real overlaps in about six areas: MMC/SDHCI/SDIO, GENET, xHCI, the EFI arm64
   loader, the arm64 exception handler, EFI networking.
9. The main costs are not technical: the owner must sign and defend each of roughly 70–90 PRs; ACPI vs device tree
   must be settled with them first; 91 files need an SPDX line; "Copyright Haiku, Inc." lines need correcting; every
   place a driver "follows Linux" needs a provenance note.
10. Recommendation: worth doing in stages. Start with the small generic ★ fixes, take the three fixes of theirs we
    lack, talk about ACPI vs device tree before any Pi driver; do not rebase haiku-pi onto RenkuOS.

## 1. What RenkuOS is

**Repositories and licence [V].** Three repos: `Source` (the OS, branch `main`, 18 stars, 16 forks),
`PlanAndGovernance` (`DECISIONS.md`, `CONTRIBUTING.md`, `REVIEW.md`, `engineering-charter.md`) and `RenkuOSPorts`
(a full HaikuPorts fork from `46b2f4b3e13f`, 2026-10-21). `License.md` is Haiku's, unchanged (MIT plus per-file
licences). Decision D3: new code MIT (= MIT-compatible permissive: BSD and ISC accepted); copyleft needs the council
and must ship as a separate add-on. "Pre-release"; nightly ISOs only for x86_64 and x86_gcc2h (build00071, 2026-11-03).

**Contribution rules [V]** (gov/CONTRIBUTING.md, gov/REVIEW.md, src/AGENTS.md, .github/workflows/lint.yml).
AI-written code is explicitly welcome (REVIEW §0.1: review the code, not how it was produced). Obligations:
`Assisted-by: <model>` when a tool wrote >~20 kept lines or did the design; the submitter is the engineer of record for
every line (§0.2: "'The model wrote it' is never an answer"); check provenance, especially copyleft; §1.5: the PR
summary should be written by the human. CI blocks on: missing `Signed-off-by:` (DCO, no CLA); a new C/C++/asm file
without SPDX; more than 1,000 hand-reviewable lines without `oversize-approved`; more than two subsystems (first two
path segments under `src/`); clang-format differences (skipped today: no .clang-format); `Ported-from:` without
`Ported-from-license:` or the reverse. Only top-level `3rdparty/`/`vendor/` lines are excluded from the count
(lint.yml 155–158). Warnings only: missing `subsystem: ` prefix, subject ≥ 72 chars. Size: ≤ 400 routine, 400–1,000
needs a sentence, > 1,000 needs an agreed splitting plan; "a new self-contained driver in its own directory" is exempt.
Testing: every PR needs "How this was tested"; drivers name the hardware and PCI/USB ID; kernel/VM/boot/fs-write paths
need real hardware, a stress run, a revert plan and (reviewer obligation) two approvals; the tool enforces one.
Merge gate: one approval from KevinAdams05, rainygirl, atomozero or RenkuOSAdmin; required checks `policy checks`,
`build x86_64`, `boot x86_64`. arm64 is never built or booted in CI; only an arm64 cross-compiler image exists (#180);
D4 (proposal) puts ARM in Tier 2. Council drafted, not constituted; no MAINTAINERS/CODEOWNERS. Phase 1 of the charter:
"absorb the existing forks" by ordinary PRs. Kevin reviews with a "review agent" (concrete findings: licence notices
#158/#159, an `ifconfig down` hang, an out-of-bounds read #159, ACPI mapping attributes #155). Some PRs merged without
description or test section (#154, #155, #156, #159).

**Activity [V].** 309 non-merge commits (46 upstream cherry-picks); 18 PR authors; 25 open PRs (oldest #98, 10-16);
time to merge median 1 day, p90 3 days, max 14. Merged PRs per ISO week: W36 2, W38 11, W39 26, W40 21, W41 11, W42 19,
W43 35, W44 41, W45 (part) 16. Work: x86 laptops/tablets (Bay Trail, Chromebooks, MacBook EFI, Sony VAIO P), WiFi,
TCP, media, USB audio, UI, a syscall sandbox (#186), Bluetooth (#185, #252), ARM32 on the Toshiba AC100 (atomozero),
the Pi 400 (linkslice).

**Upstream tracking [V].** Fork point `0eb0a29caaa` = hrev60107 (2026-09-15); upstream is 291 commits ahead; our base
hrev60314 is 260 upstream commits newer. Policy D1: cherry-pick with `-x`, never merge wholesale; 46 imported
(`upstream/2026-10-27` 30, `upstream/2026-10-30` 7, singles); `UPSTREAM.md` lists only 9. Build: still Jam; workflows
lint, pr-gate, nightly, toolchain, `.github/toolchain.pin`; buildtools from upstream master. Rebranding (D2) open, no
owner; `uname` → RenkuOS is open PR #194.

## 2. Their Raspberry Pi 4 / arm64 state

**The Pi 400 series by linkslice [V]** (all "Assisted-by: Claude Opus 5.5"):

| PR | Merged | Size | What |
|---|---|---|---|
| #154 | 10-23 | +79/−19 | EFI loader for the UEFI firmware: bounded bounce-buffer reads; clear SCTLR.A; infer the GIC version when the firmware reports 0; CNTKCTL_EL1 after dropping from EL2; keep the EL1 MMU setup when dropping from EL2 |
| #155 | 11-01 | +91/−1 | ACPI on ARM: non-RAM regions uncached from the loader's cacheable ranges; a fallback device-class table: PNP0D10 (xHCI), BRCME88C (SD), BCM6E4E (Ethernet), BCM2847 (SDIO host) |
| #156 | 10-23 | +340/−15 | xHCI via ACPI (synthetic `pci_info`); USB DMA areas uncached on all arm64; `dsb` on rings and doorbells; 32-TRB prefetch padding for the VL805 / non-coherent controllers |
| #157 | 10-23 | +1086 | `busses/mmc/bcm2711_emmc2.cpp`: separate SD driver, PIO and polling, no DMA, no interrupts; "the system boots from and runs on the card" [C] |
| #158 | 10-30 | +1356 | `drivers/network/ether/genet/` via ACPI, uncached copy buffers; FreeBSD-derived (BSD-2); same directory name as ours |
| #159 | 11-01 | +4670 | `drivers/network/wlan/brcmfmac/`: own FullMAC WiFi (not openbsd_wlan), own SDIO host and mailbox, BCM43455/43456, firmware does WPA; from OpenBSD bwfm + Plan 9 ether4330 (ISC); firmware installed by hand |
| #160 | 10-27 | +26/−1 | arm64 power-off and reboot through PSCI |
| #161 | 10-27 | +35/−3 | arm64 SIGILL for undefined instructions and trapped MSR/MRS, SIGBUS for stack misalignment, SIGFPE for trapped FP |

Not merged (branches on `linkslice/RenkuOSSource`, no PR seen): `pi400/arm64-kdl-getchar` (= our `b3a08271be`),
`pi400/net-server-fullmac-join`, `pi400/usb-disk-timeout`, `pi400/vfs-free-vnode-ref`, `pi400/credits`.
Related: atomozero #189 (strong compare-and-swap in `atomic_test_and_set()`), #191 (`get_next_child_node()`), #196/#197
(ARM32), the AC100 port; wainohito #81/#86/#87 (eMMC: SDHCI transfers, ADMA2, `set_timing`, HS200/HS400); 12akakor open
#276 (SDIO in the MMC bus manager and SDHCI) and #277 (`sdio` bus for freebsd_network), opened 2026-11-03, nearly our
`ec55b68bfe`/`c5f52af56b`/`4d12fd3908`/`e26850ef57`; atomozero open #252 (Bluetooth, incl. the same L2CAP
NULL-endpoint panic as our `b0ea06deaf`); KevinAdams05 in RenkuOSPorts `renkuos/bootstrap/arm64/`: native arm64
packages under QEMU, hours per port (perl ~3.5 h, python3.10 ~2 h 54 min), an arm64 nightly planned; their Source arm64
package list is still upstream's bootstrap set (`cb6c752887`).

**Boot chain:**

| | RenkuOS | haiku-pi |
|---|---|---|
| Boot | Pi firmware → RPi4 UEFI (ACPI) → `haiku_loader.efi` | Pi firmware → U-Boot (EFI) → `haiku_loader.efi` |
| Device discovery | ACPI IDs | device tree |
| Secondary CPUs | PSCI [C] | U-Boot spin table |
| PCIe / VL805 | firmware | our `brcmstb` (full bring-up) |
| Display | probably the UEFI framebuffer [I]; no display driver [V] | `bcm2711_display` (planes, EDID, vblank, modes, cursor, overlays) |

Boot depth cannot be verified: only PR comments ("tested on qemu arch64 and a pi400" #156, "boots from and runs on the
card" #157); no screenshots, Pi issues, Pi docs (`docs/develop/kernel/arch/arm/rpi4.rst` is upstream's old page), arm64
image or arm64 CI. With the bootstrap package set their image can at best be minimal [I].

**Quality (read, not run).** Good: small explained commits, licence notices fixed after review, VL805 quirks gated per
controller (`dc8872b982`), close/error paths fixed after review. Weak [I]: polled-PIO SD (ours: 10.5 → 42.6 MB/s with
ADMA2 + DDR50); GENET copying RX out of uncached buffers (we measured that design at a 250 Mbit/s ceiling before
`06356adcc0`); xHCI pads TRB rings but never clears finished entries (on our board padding *and* clearing fixed the
1-in-10 hub hang, `c65ac5a2e6`).

## 3. Comparison

| Area | RenkuOS (Pi 400) | haiku-pi (Pi 4B, measured) | Ahead | Notes |
|---|---|---|---|---|
| Boot loader | UEFI path, #154 | U-Boot path; EL2/MDCR/CNTKCTL; secondary-CPU cache fixes; TTBR0 clear; U-Boot→desktop 6.4–6.6 s | ours, overlap | #154 ≈ our `022ca91504` (TTBR0/MAIR) and `9148d14cac`; `eb4bdd0ea4` applies under PSCI too [I] |
| SMP | PSCI [C] | 4 cores, 10/10 boot bench; LL/SC livelock fixed with WFE | ours | their `arch_cpu_pause` = `yield` [V] → livelock likely [I] |
| GIC-400 | upstream | IPI barriers, CPU map, Linux-style setup | ours | shared with ARM32 (AC100) [I] |
| Power-off/reboot | PSCI (#160) | stub | **theirs** | worth taking |
| Serial/KDL | upstream | PL011 fixes, emergency keys, IRQ output | ours | |
| SD card | polled PIO | ADMA2, UHS-I DDR50, 42.6 MB/s | ours | hardest merge area |
| PCIe | firmware | `brcmstb`, Gen2 x1 | ours (U-Boot path only) | |
| USB/xHCI | ACPI attach, uncached, barriers, padding | clearing + padding (40/40 cold boots), fragment fix | mixed | |
| Ethernet | ACPI, uncached RX | cacheable RX, 914/918 Mbit/s | ours | same directory |
| WiFi | native FullMAC [C] | bwfm on openbsd_wlan, WPA2, 37/46 Mbit/s | unclear | three SDIO designs now |
| Display | framebuffer [I] | full driver, 60.00 Hz | ours | |
| GPU | none | GL 2.1, GLES 3.1, Vulkan 1.3 (our Mesa fork) | ours | |
| HEVC | none | ~115 fps 1080p | ours | |
| Audio | none | jack + HDMI | ours | |
| Bluetooth | none | `bcm2711_bt` + stack fixes | ours | |
| cpufreq, thermal, RNG, GPIO, PMU | none | all | ours | |
| Network boot | none | remote disk series | ours | |
| Packages | bootstrap set | 154 cross-built | ours | belongs in RenkuOSPorts (D2 undecided) |

**Our ★ generic fixes against RenkuOS `main`** ("applies" = cherry-picks cleanly in our order, cumpick.tsv):

| # | Fix (our commit) | In RenkuOS? | Applies? |
|---|---|---|---|
| 1 | LL/SC livelock: WFE (`0db3ca639d`) | no [V] | yes, after the GIC commits |
| 2 | `ASSERT()` side effects (`55348c5c46`) | no | one sdhci.cpp hunk overlaps wainohito |
| 3 | kernel stacks mapped accessed+dirty (`dc849a150b`) | no | yes |
| 4 | user time counted as kernel time (`24b4e36dcf`) | no [V] | yes |
| 5 | arm64 kernel stack traces (`4413675f5c`) | no (returns 0) [V] | yes |
| 6 | spinlock deadlock detection by time (`a46a16641e`) | no | yes |
| 7 | `get_next_child_node()` (`81deb24f8c`) | **yes** (#191) | present |
| 8 | SDHCI interrupt acknowledge (`23f6235b0d`) | partly (`RecoverError()` still int16 + `&= ~`, sdhci.cpp:1660) [V] | overlap |
| 9 | DT `ranges` translation (`1c9c78289e`) | no | yes |
| 10 | GICv2 IPI barriers (`4eb785f652`, `aa7da3b827`) | no | yes |
| 11 | EL1 setup after the EL2 drop (`022ca91504`) | equivalent for TTBR0/MAIR (`edf69c5603`) | overlap |
| 12 | EFI `ip=` parsing loop (`d8dfb51d8d`) | no | overlap (network.cpp) |
| 13 | `remote_disk` partitions (`a082ab4d4e`) | no | yes |
| 14 | network-boot module deadlock (`cea07d5468`) | no | yes |
| 15 | `BTimeSource` float conversions (`c41702df18`) | no | yes |
| 16 | arm64 debug console 0xff (`b3a08271be`) | no (linkslice branch) | yes |
| 17 | PL011 line settings, bounded FIFO wait (`f5650324d6`, `80a6e1f2fb`) | no | yes |
| 18 | page writer leaves last pages unwritten (`1539d29eee`) | no; cause `3bfaa91290b` present [V] | yes |
| 19 | `IORequest` recursion (`90fa3bc401`) | no | yes |
| 20 | `lock_memory_etc()` panic (`6f810ed2d7`) | no | yes |
| 21 | `MAP_SHARED` lost across `mprotect()` (`894c4abe7f`) | no | yes |
| 22 | blocked-signal fault loops (`6e517bb52c`) | no | yes |
| 23 | profiler timer left armed (`5180e96119`) | no | yes |
| 24 | PCI I/O BAR host address (`cafef4f9bb`) | no | yes |
| 25 | failed `fork()` panic (`e2aefd5d96`, `c8f3757b45`) | no | `c8f…` yes; `e2a…` overlaps #161 |
| 26 | `mmap(PROT_WRITE)` faults forever (`8a7946ae00`) | no | yes |
| 27 | user ID-register reads (`7225a5f244`) | no (#161 sends SIGILL instead) | overlap |
| 28 | `remote_disk` on every boot (`8f0df61a1c`) | no | yes |
| 29 | L2CAP NULL-endpoint panic (`b0ea06deaf`) | no (similar in open #252) | yes, coordinate |
| 30 | Bluetooth tools/kit (`02e02d4ba3`, `0c12640aa2`, `d226612219`, `3cad4e2996`) | no | yes |
| 31 | xHCI clear + pad (`c65ac5a2e6`) | partly (padding) | overlap |
| 32 | ICMPv6 errors (`25c9881600`, `58022c954a`) | no | yes |
| 33 | new thread's TLS generation (`5db923abc6`) | no | yes |
| 34 | **arm64 sigreturn restores the whole SPSR from user memory** (`4cd6f504f8`) | no; `arch_thread.cpp:228` copies it unchecked [V] — a user program can return to kernel mode | yes |
| 35 | breakpoint flag on continue (`40adafebe9`) | no | yes |
| 36 | Debugger step-out arm64 (`88b487e15b`) | no (no arm64 Debugger back end) | yes |
| 37 | secondary-CPU stack cache lines (`eb4bdd0ea4`) | no | yes |
| 38–39 | `strtold`/`strtod` (`12eb998a63`, `73ba44df00`, `69c0374b42`) | no | yes |
| 40 | `setrlimit()` with the current value (`f0a1d5f5cf`) | no | yes |
| 41 | libroot `rw_lock` lost hand-off (`2bf2f773ba`) | no | yes |
| 42 | new thread enters userland with a signal pending (`5d9132a49c`) | no | yes, after `ecab951764` |
| 43 | dying team frees a running thread's stack (`e09cfa1d9e`) | no | yes |
| 44 | image notifications lose their pointer (`f6c52282df`) | no | yes |
| — | **empty TTBR0 table not cleared** (`d1a616afac`, cold-boot freeze) | no; `arch_vm_translation_map.cpp:79`, cause `593f25d6f1e` present [V] | yes (6 lines) |
| — | I-cache line size (`0fe465e233`) | no; `arch_cpu.cpp:107` wrong shift [V] | yes |

**What they have that we lack [V]:** #189 strong compare-and-swap (our `SupportDefs.h:278` still weak: on the A72
without LSE a spurious failure looks like success — a latent bug in our tree and upstream); #231 launch_daemon pipe
with `pipe2(O_CLOEXEC)` (our `BaseJob.cpp:202` uses `pipe()`; they report a stall in 6 of 11 boots [C]); #160 PSCI
power-off/reboot (ours is a stub; check PSCI under U-Boot [I]). Also worth reading: linkslice's unmerged
`vfs-free-vnode-ref` and `usb-disk-timeout`.

## 4. Porting effort

**Merge check.** By file: 330/363 apply cleanly. By commit in order: 192/254 apply, 5 empty (duplicated GCC 16 commits,
plus the fix they already have), 57 conflict: 32 genuine overlaps, 2 caused by upstream changes they lack (`usb_disk.cpp`,
`arch_system_info.cpp`), 23 cascades (e.g. all of `v3d/` fails only because an SDIO commit editing `bcm2835_mailbox.h`
was skipped).

| Area | Our commits | Their work in the way | What to do |
|---|---|---|---|
| MMC/SDHCI/SDIO | `23f6235b0d` `af82a8ca4d` `890f468bf4` `bf3a1d0bdb` `e29c5b7c65` `1cccf09635` `c283f50c5b` `ec55b68bfe` `c5f52af56b` `1be86daecf` `4d12fd3908` `d018d9dfe1` `68293c40a1` | wainohito #81/#86/#87; 12akakor open #276/#277; linkslice's SD driver; brcmfmac's SDIO host | rewrite, not rebase; agree one SDIO interface with 12akakor first; move UHS-I/clock/DMA-window hooks and the DT SDHCI attach onto their `set_timing` |
| GENET | `4ff857683f` `06356adcc0` | #158 (same directory) | one driver with both attach paths and our RX path, or rename; needs linkslice |
| xHCI / USB DMA | `c65ac5a2e6` `1d44b00380` `71bc709601` | #156 | small follow-ups on top of theirs |
| EFI arm64 loader | `022ca91504` `9148d14cac` | #154 | drop our duplicate parts; send spin-table flush and MDCR_EL2 separately |
| arm64 exception handler | `cdd63d4b62` `7225a5f244` `e2aefd5d96` `f753f072d8` | #161 | rebase onto theirs |
| EFI networking/boot | `d8dfb51d8d` `f316d4920e` `bce76d6e73` `b23e7264c0` | rainygirl, 12akakor | small manual rebases |
| System calls | `1582c223b0` (team memory barrier, used by Wine) | idumych #186 (syscall filter) | renumber, add to their filter table |
| Trivial | audio/WiFi Jamfiles, package list, `ieee80211_haiku.cpp`, `NetServer.cpp` | several | by hand |

("Applies" = textual merge only; nothing was built or run against their tree.)

**Clean-up every PR needs:** (1) trailers: owner's `Signed-off-by:` and `Assisted-by: Claude Opus 5.5` (ours carry
`Co-Authored-By`, 209/254, no sign-off); (2) SPDX: 91 of our 105 new source files lack it; (3) copyright lines: ours
say "Copyright 2026, Haiku, Inc.", which Haiku, Inc. did not write — the owner chooses correct attribution;
(4) provenance notes where drivers "follow Linux" (GENET register sequences, `brcmstb` after `brcm_pcie_setup()`, V3D
interface semantics, rpivid, HDMI audio): a "register facts only" statement or `Ported-from:` a permissive source —
their review agent blocked linkslice on exactly this. Vendored code fits their rule (OpenBSD bwfm ISC, NetBSD
disassembler BSD-2, Arm Optimized Routines MIT/Apache-2.0-LLVM, OpenBSD ChaCha ISC, DRM headers MIT, the glibc strtod
template into their existing LGPL `glibc/`); our bwfm copy (~6.4k lines) is not under `3rdparty/`/`vendor/` → oversize
label or move; (5) testing section: x86_64 QEMU build+boot plus our Pi 4B bench; (6) a human owner per PR — the main cost.

**Not for their Source repo:** our package repository and the 37 package-list commits (→ RenkuOSPorts, D2 undecided;
our recipes could save Kevin weeks [I]); the Mesa fork, ffmpeg HEVC, SDL2/Firefox/WebKit patches, Wine/Box64/FEX (the
kernel changes Wine needs — `894c4abe7f`, `7225a5f244`, `1582c223b0`, `6e517bb52c` — are ordinary Source PRs); firmware
blobs (WiFi firmware/CLM, `BCM4345C0.hcd`; neither tree ships them; U-Boot not needed on their path); our configuration
choices (`KDEBUG_LEVEL 1`, image profiles, `-sHAIKU_PI_*`).

**Settle before any Pi driver PR: ACPI or device tree.** Device-tree-only drivers of ours: v3d, display, rpivid, both
audio drivers, `bcm2711_bt`, thermal, cpufreq, rng200, gpio, mailbox, genet, the SDHCI attach, `brcmstb`. The UEFI
firmware's ACPI tables probably do not describe the GPU, display or audio blocks [I]. Options: (a) RenkuOS accepts
U-Boot + device tree as a second Pi boot path (our drivers go in unchanged); (b) we add ACPI attach where the firmware
describes the device (GENET, SD, SDIO, xHCI), the rest stays DT-only; (c) the UEFI firmware also has a device-tree mode —
whether Haiku's loader prefers it was not checked [I].

**PR plan.** About 70–90 PRs, ~39k hand-written lines + ~12k vendored. Large drivers are exempt as new directories,
but > 1,000 lines needs a splitting plan (v3d 5.4k, bwfm 6.8k, Debugger arm64 6.3k → several PRs each). Their review is
fast; the owner's time is the limit.
- **Phase A: small generic fixes**, ~25–30 PRs of 5–150 lines. First five (bug verified in their tree):
  `d1a616afac` TTBR0 clear (6 lines; cold-boot freeze on any arm64 board), `4cd6f504f8` sigreturn SPSR (security),
  `0fe465e233` I-cache line size, `1539d29eee` page-writer data loss, `6f810ed2d7` `lock_memory_etc` panic. Then VM and
  process (`894c4abe7f`, `6e517bb52c`, `90fa3bc401`, `5180e96119`, `127fb34239`), libroot/runtime loader/media kit
  (`5db923abc6`, `2bf2f773ba` with its test, `c41702df18`, `f6c52282df`), PCI/`setrlimit`/ICMPv6/strtod, small arm64
  and PL011 fixes (coordinate with linkslice), Bluetooth (coordinate with #252). Tests we have: `rw_lock_interrupt_test`,
  `tlsreload`, `polltest`, `killrace`, `threadstress`. Also offer an early `ci: build arm64` PR (their toolchain image).
- **Phase B: larger arm64 work**, ~10–15 PRs: WFE livelock (after the GIC barriers), ID-register emulation on top of
  #161, thread/stack lifetime fixes in order, loader cache fixes, user debugging + the Debugger arm64 series,
  performance (Arm Optimized Routines, user memcpy, fast TLS, symbol hash style, `-Bsymbolic-functions`, DT_RELR,
  scheduler, ChaCha20 RNG, packagefs read-ahead, bounce buffers), GCC 16 build fixes, SavedClock (their notes: "the
  arm64 kernel has no RTC driver and boots at time 0").
- **Phase C: Pi platform drivers**, after the ACPI/DT decision and SDIO coordination, ~25–35 PRs in order: cache
  helpers; DT `ranges` + DMA window; mailbox; SDHCI on wainohito's work; the agreed SDIO interface; `brcmstb` + xHCI
  follow-ups; GENET merged with theirs; WiFi (bwfm vs brcmfmac, or both); thermal/cpufreq/RNG/GPIO/PMU; display, V3D
  (split), rpivid, audio, Bluetooth; network boot (~8 PRs).
- **Risks:** no arm64 CI (their x86 work can silently break Pi code); parallel AI-written duplicates keep appearing
  (SDIO already); their base is 260 upstream commits older and the gap grows; a single merger.

## 5. Is it worthwhile?

**For.** Reach: an active community on exactly our platform (Pi 400 drivers, arm64 packages, ARM32), a policy that
accepts our kind of code, a plan to absorb existing forks. Value to them: our generic fixes repair severe defects in
their tree (cold-boot freeze, privilege escalation, a panic any program can trigger, page-writer data loss, an SMP
livelock) — tens of lines each, mostly clean; our Pi stack would take them from "boots on a Pi 400" to a full desktop
with GPU, audio and video. Value to us: they already found bugs we share (weak CAS, launch_daemon pipe stall, PSCI
power-off); a second user base would test our drivers on Pi 400 and 8 GB boards we never ran (KNOWN-ISSUES P6).

**Against.** Two forks to maintain (sending fixes there does not shrink our diff against upstream Haiku; haiku-pi stays
on upstream with weekly merges; rebasing haiku-pi onto RenkuOS is not recommended: older base, cherry-pick-only).
Owner time: sign, summarise and defend 70–90 PRs. Architecture friction: ACPI vs DT, three SDIO designs, two GENET
drivers; some of our work would replace code they merged two weeks ago. Clean-up first: SPDX, copyright, provenance,
trailers, x86_64 smoke tests.

**Licences.** Haiku's MIT and their MIT-compatible rule match ours, provided each file's provenance is stated; no GPL
code was found copied into our tree; the "facts only" statements for Linux-following code are the owner's to make
(not verified here).

**The same fixes matter to upstream Haiku** (noted only; Haiku does not take AI-generated code): every ★ fix is a
defect in upstream code — most importantly the TTBR0 regression (from `593f25d6f1e`), the page-writer regression
(from `3bfaa91290b`; data loss on power cut, every architecture), sigreturn SPSR (privilege escalation), the
`lock_memory_etc` panic, `MAP_SHARED` across `mprotect()`, the `rw_lock` hand-off, TLS generation, 64-bit image
notifications, ICMPv6 errors, `IORequest` recursion, the WFE livelock, the I-cache line size and the `strtod` fixes;
RenkuOS #189's weak CAS is equally an upstream bug.

## Recommended next step

1. Take their three fixes into haiku-pi now (strong CAS #189, `pipe2(O_CLOEXEC)` #231, PSCI #160 after checking PSCI
   under U-Boot), then the usual bench.
2. Owner decision: willing to be the DCO signer and named owner of every PR (their §0.2, §1.5)? If not, stop.
3. If yes, contact them before sending code (nothing was posted): one issue/forum note to KevinAdams05 and linkslice
   pointing at docs/HAIKU-RPI4-CHANGES.md, asking ACPI vs device tree, proposing one SDIO interface with 12akakor
   (#276/#277) and merging the two GENET drivers.
4. Pilot with the five Phase A PRs (TTBR0, sigreturn SPSR, I-cache line size, page writer, `lock_memory_etc`), each
   with SPDX where needed, `Signed-off-by` + `Assisted-by`, a "How this was tested" section (Pi 4B + QEMU x86_64 boot)
   and a revert note; measure review round-trip and owner time per PR; then decide on Phases B and C.

Note added by the main session (2026-11-04, after the report): since this analysis, haiku-pi also fixed USB disk
cache maintenance (`eabad7a921`, `b90cb3f0d4`: every earlier image corrupted USB disk data on the Pi 4) — RenkuOS's
#156 marks USB DMA areas uncached but does no maintenance for usb_disk's physical transfers either; worth checking in
their tree before a USB disk is trusted there.
