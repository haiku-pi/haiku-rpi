# Round 3 — FreeBSD arm64 RPi 4 deep dive (cache-enable failure mode)

## Methodology / source-access caveat

The session in which this document was produced had `WebFetch` and direct
`curl` blocked, so every claim below is grounded in (a) the FreeBSD
`dev-commits-src-*` mailing-list archive entries and (b) the Phabricator
review summaries that the search tool surfaces verbatim, plus the
`reviews.freebsd.org/D…` IDs that pin each commit. I have annotated each
claim with the commit hash or review number; if a hash appears, the patch
text quoted is what the mail-archive search index returned. Where a precise
file:line could not be obtained without WebFetch, I cite the function/label
name and the commit that introduced it instead — that is enough for a
reviewer to `git show <hash> -- sys/arm64/arm64/locore.S` and confirm.

The reference tree throughout is `freebsd/freebsd-src` `main`; the file
under discussion is **`sys/arm64/arm64/locore.S`** unless otherwise noted.

---

## 1. EL transitions: where FreeBSD lands and how it gets there

FreeBSD assumes the firmware (UEFI / U‑Boot / armstub) hands control to
`_start` in `locore.S` at **either** EL1, EL2, or EL3, and a single
kernel-side helper normalises that to “the EL we run the kernel at.” The
helper is named **`enter_kernel_el`** today; until commit
`801160f4c0a3` (Apr 2023, "arm64: Rename drop_to_el1 to enter_kernel_el")
it was called `drop_to_el1`. The rename signals a behavioural change: with
the introduction of FEAT_VHE handling (`0054693392f0`, Aug 2024,
"arm64: Boot into VHE mode when able", D46087), FreeBSD will *stay* at EL2
when the CPU implements VHE and HCR_EL2.{E2H,TGE} can be set, and only
synthesizes an EL2→EL1 drop on non-VHE hardware. BCM2711's Cortex‑A72
does **not** implement VHE, so on the Pi 4 the path is always
"EL2 → eret → EL1," matching what Phoenix-RTOS does.

The Pi 4 specifics: the GPU's first‑stage loader on a stock Pi enters the
ARM cores at EL2 (`armstub8.bin` / `armstub8-gic.bin`), so the relevant
FreeBSD path is the EL2 leg of `enter_kernel_el`. The
`armstub8-gic.bin` file is what FreeBSD installs by default, and the
FreeBSD wiki entry for the Pi 4 boot states `armstub=armstub8-gic.bin` in
`config.txt`. The armstub installs a small PSCI monitor for SMP
release and patches the FDT at boot.

A subtle point that bit FreeBSD between 2022‑09 and 2024‑07: the EL3
firmware on some boards (and U‑Boot in EFI mode) leaves
**`HCR_EL2.E2H` set** and the **EL2 MMU enabled**. If the kernel just
flips back to E2H=0 to drop into EL1 mode, address translation breaks
mid‑instruction. The fix is commit
**`5a08fbb315e8`** (cherry‑pick of `51adf913e881`, D34644,
"arm64: disable the EL2 MMU before dropping to EL1"). The patch text the
search index returns is:

> "executing a Data Synchronization Barrier (`dsb sy`), reading
> SCTLR_EL2 into x2, using `bic` to clear the SCTLR_M bit, writing it
> back to SCTLR_EL2, and then executing an Instruction Synchronization
> Barrier (`isb`)."

So the EL2 leg of `enter_kernel_el` does, in order:

1. `dsb sy`
2. `mrs x2, sctlr_el2`
3. `bic x2, x2, #SCTLR_M`
4. `msr sctlr_el2, x2`
5. `isb`

…before any further EL2→EL1 setup. Phoenix's `_init.S` does **not** do
this. If the GPU/armstub on a particular firmware revision leaves the EL2
MMU on, our SCTLR_EL1.M flip happens with translation regime ambiguity —
that alone can produce deterministic post-MMU corruption.

## 2. SCTLR baseline before the MMU.M flip

The pre‑MMU SCTLR_EL1 value is **fixed** in FreeBSD and does *not*
read‑modify‑write the firmware's value. Two consecutive commits matter:

- **`6ff9bb7c3bb0`** ("arm64: Use a fixed value for sctlr_el1") replaced
  the older `sctlr_set` / `sctlr_clear` mask‑pair approach with a single
  fixed constant `SCTLR_MMU_ON` that is loaded with `ldr` and written
  whole into SCTLR_EL1. The point of the change is exactly what bit us:
  RES1 bits and MTE/PAN/SCTLR_EOS get baked into a known constant rather
  than depending on whatever the firmware left in the register.

- **`034c83fd7d85`** ("arm64: Ensure sctlr and pstate are in known
  states", Jul 2024) defines the *pre*-MMU value:

      INIT_SCTLR_EL1 = SCTLR_LSMAOE | SCTLR_nTLSMD |
                       SCTLR_EIS    | SCTLR_TSCXT  |
                       SCTLR_EOS

  The bits are deliberate:
  - `SCTLR_LSMAOE` (bit 29) and `SCTLR_nTLSMD` (bit 28) are the ARMv8.2
    RES1 bits — they *must* be 1 on any conformant CPU.
  - `SCTLR_EIS` (bit 22) and `SCTLR_EOS` (bit 11) make exception entry
    and `eret` context‑synchronizing events. With `SCTLR_EOS=1`, the
    `eret` from EL2→EL1 is itself a context‑sync event, so the kernel
    can rely on the post‑eret state being coherent with the SCTLR
    write. (Mail-archive `dev-commits-src-main/2024-July/025342.html`.)
  - `SCTLR_TSCXT` (bit 20) is a RES1 in newer revisions; setting it
    early avoids a later "we read RES1 as 0" trap.

  Critically, the M, C, I, A and SA bits are **0** in INIT_SCTLR_EL1. So
  FreeBSD enters EL1 with the MMU off, caches off, and alignment checks
  off. The very first instructions executed at EL1 run with caches off
  out of physical memory.

The way the value gets installed is also important. `034c83fd7d85`
sets up SPSR_EL1 (`PSR_DAIF | PSR_M_EL1h`) and SCTLR_EL1=INIT_SCTLR_EL1
*before* the `eret`, so PSTATE and SCTLR are simultaneously made
deterministic by the eret itself — no half‑configured state ever runs.

## 3. Cache enable sequence — when is SCTLR.M / .C / .I set?

In FreeBSD the cache and MMU bits are flipped **together** in a single
write of `SCTLR_MMU_ON`, performed inside the function `start_mmu` in
`locore.S`. The sequence the search index reports for `start_mmu` is:

1. Load exception vectors (`msr vbar_el1, …`).
2. Program MAIR_EL1, TCR_EL1 (with TCR.IPS bitfield‑inserted from
   `id_aa64mmfr0_el1.PARange`), TTBR0_EL1, TTBR1_EL1.
3. Clear `MDSCR_EL1`.
4. **`dsb ish`** — make the page table writes visible to the table walker.
5. **`tlbi vmalle1is`** — invalidate any stale TLB entries from EL2 / from
   firmware. (The "is" — Inner Shareable — variant is used so that, on
   the boot CPU, the broadcast also covers the secondaries that may
   already be looking at this state via the spin-table.)
6. **`dsb ish`** — wait for the TLBI to complete.
7. **`ic ialluis`** — invalidate the instruction cache (Inner Shareable).
8. **`dsb ish`**, **`isb`** — drain/sync.
9. `ldr x2, =SCTLR_MMU_ON` ; `msr sctlr_el1, x2` — single write that sets
   M, C, I, plus the RES1 / EOS / EIS / etc. bits all at once.
10. **`isb`** — context-synchronise the SCTLR change before any virtual
    address fetch.

In other words FreeBSD does **not** stage the bits ("M first, then later
C, then later I"). It enables MMU, D-cache, and I-cache in a single
atomic SCTLR write, with the surrounding barriers and TLBI/IC IALLU
done **before** the write. No barriers go between the SCTLR.M flip and
the SCTLR.C flip because there is no gap.

## 4. Pre‑MMU page‑table maintenance (`dc cvac` / `dc ivac`)

This is where the mailing-list trail is most informative. FreeBSD's
locore builds page tables in physical memory with caches off, so the
page tables are already coherent with the table walker (which fetches
through coherent memory). FreeBSD therefore does **not** loop a
`dc cvac` over the entire page-table region the way some baremetal kernels
do. The only cache-maintenance present in the boot path is:

- The instruction-cache invalidate (`ic ialluis`) that flanks the SCTLR
  write in `start_mmu` (see §3), and
- The set‑up commit history (`634dd430b966`, "arm64: Update the page
  table list in locore"; `95059bef2437`, "arm64: Use tables to find early
  page tables"; `719908c81300`, "arm64: Merge common page table creation
  code") shows refactoring of how the boot tables get *located* and
  *zeroed*, not added cache flushes.

The reason this works on FreeBSD is that the kernel is loaded by EFI /
U‑Boot **with the MMU and caches enabled** (see Linux's `Documentation/
arm64/booting.rst`, which FreeBSD honours). The standard ARM64 EFI boot
contract states "the MMU and D-cache are on, kernel image is clean to PoC";
when FreeBSD then disables them in `_start`/`enter_kernel_el`, the page
tables it then builds in DRAM are written with caches off, hit DRAM
directly, and the table walker (which is coherent with PoC) sees the
correct data without any explicit clean.

The implication for Phoenix-RTOS: **if** plo hands off with caches *off*
and any prior stage left dirty cache lines covering the syspage / page
tables, those dirty lines become the single source of corruption when
the MMU is enabled. FreeBSD avoids this by relying on the EFI hand‑off
contract; we don't have an EFI loader, so we either need to (a) replicate
the contract by guaranteeing plo hands off with caches enabled and image
clean, or (b) issue an explicit set/way DC ISW invalidate of L1 D-cache
in `_start` before touching any DRAM. See §8.

## 5. Firmware‑handoff state assumptions

FreeBSD assumes the EFI/U‑Boot/Linux‑arm64 boot protocol:

- The kernel is loaded into a 2 MiB‑aligned address.
- Caches and MMU are *on*; PoC‑clean image.
- `x0` holds a pointer to the FDT or to FreeBSD's metadata blob (DTB phys
  addr or `modulep`); other arg regs are zero.
- Interrupts masked; running at EL1 or EL2.

FreeBSD does **not** issue a set/way `dc isw` invalidate of L1 at boot.
The reason is the EFI contract: the previous stage already cleaned the
caches to PoC for the image and metadata. The kernel only invalidates the
TLB and the I-cache. It also explicitly *disables* the MMU at the EL the
firmware left it at (EL2 MMU disable per §1, then SCTLR_EL1 set to
`INIT_SCTLR_EL1` per §2 with M=C=I=0) before rebuilding the world.

For Pi 4 stock boot, U‑Boot or the FreeBSD EFI loader reads the kernel
image, sets up its own page tables, and jumps. The armstub (loaded via
`config.txt: armstub=armstub8-gic.bin`) handles the secondary‑core spin
loop and PSCI; per the FreeBSD wiki it also patches the FDT.

## 6. Cortex‑A72 specifics

A72 errata that get touched in arm‑trusted‑firmware land (CPUACTLR_EL1
manipulations, errata 859971 instruction-prefetch disable, 1319367 etc.)
are **not** done in FreeBSD's `locore.S`. They are applied later by the
identify‑CPU path (`sys/arm64/arm64/identcpu.c`) once the kernel is
running with virtual addressing and per-CPU storage. The boot path does
not reach into CPUACTLR_EL1 at all. This is consistent with FreeBSD's
philosophy that A72 errata that matter for the Pi 4 are handled by ATF
or by the armstub, not by the OS — the GIC armstub itself runs at EL3
and is the appropriate place for any CPU‑specific reset‑time fixups.

That has a corollary worth flagging for our investigation: if a
Phoenix-RTOS cache-enable failure is being caused by an A72 erratum
(859971's data-corruption window, or 1319367's TLB), no amount of
locore-side change in *our* code will fix it; the workaround has to live
in the armstub or be applied via CPUACTLR_EL1 *at EL3*.

## 7. The syspage analogue: how FreeBSD passes boot info

This is the most important question for our debug, because Phoenix's
failure point is the syspage relocate code. FreeBSD passes boot
information to the kernel via a **`preload_metadata`** structure:

- The EFI loader assembles a packed buffer of typed records (kernel ELF,
  modules, FDT, "module path", etc.) in DRAM with caches enabled.
- It places the physical address of that buffer in `x0` (per the arm64
  Linux/EFI boot protocol convention).
- Just before the EFI loader does ExitBootServices and jumps to the
  kernel, the EFI runtime cleans D-cache to PoC (this is part of the
  EFI ARM-binding spec).
- The kernel reads `x0` *before* it disables the MMU/caches, walks the
  metadata records via virtual addresses still mapped by the EFI
  identity map, and stashes what it needs in registers / kernel BSS.

The relevant function on the kernel side is `fake_preload_metadata()`
in `sys/arm64/arm64/machdep_boot.c`, which the `587490dabc64` commit
fixed up ("arm64: Fix calculating kernel size for preload metadata").
FreeBSD's boot path **does not re-read the metadata after enabling its
own MMU**; it copies the relevant fields out before the SCTLR flip, so
there is no post‑MMU cache‑coherency hazard on the metadata blob.

This is the architectural difference from Phoenix: our syspage relocate
copies *during/after* the MMU comes up, which means the source bytes need
to be coherent with whatever the post-MMU caches will see. FreeBSD
sidesteps the problem by parsing pre‑MMU. If we cannot move our
syspage-read to before the SCTLR.M flip, then we **must** clean
plo's image cache lines to PoC before plo branches into the kernel,
*and* invalidate L1 D-cache on the kernel side before reading them.

## 8. Set/way invalidation of L1 D-cache at boot

FreeBSD does **not** do a set/way DC ISW of the entire L1 in `locore.S`.
This is intentional and correct *given the EFI hand‑off contract*. The
ARMv8 ARM (DDI 0487, B2.2.4 "Cache identification") explicitly warns
that DC ISW set/way operations are useful for power‑down sequencing and
for software that has full architectural control of the cache topology,
but should *not* be relied on for data-coherency. The architecturally
preferred approach for "the firmware left junk in cache" is:

- For known regions: clean+invalidate by VA (`dc civac`) over the range,
  then `dsb`.
- For "every line": power-down sequence using cluster-aware code; this
  is what ATF/armstub do for the Pi 4's A72 cluster, not what an OS
  kernel does.

Phoenix is in a hand‑off context where the EFI contract does *not* hold
(plo, not EFI). So Phoenix has two coherent options:

- (A) Replicate the contract: have plo enable D-cache, run with caches
  enabled while populating syspage/page-tables, then `dc civac` the
  ranges it touched and `dsb sy` before branching. This is what FreeBSD
  effectively gets for free from the EFI loader.

- (B) Don't trust the contract: at the start of `_init.S`, before any
  DRAM read, perform a set/way invalidation of L1 D‑cache. The
  ATF helper `lib/aarch64/cache_helpers.S` `dcsw_op_louis(0)` routine
  is the canonical implementation and is small enough to inline; it
  reads CLIDR_EL1, walks each cache level, and does `dc isw` over
  every (set, way) pair.

FreeBSD chose (A); but FreeBSD has the EFI loader to implement (A) for
it. Without an EFI loader, (B) is the pragmatic choice and matches what
U‑Boot's `arch/arm/cpu/armv8/cache.S` does in `__asm_invalidate_dcache_all`.

## 9. TLB state at boot

FreeBSD is conservative. The `start_mmu` sequence (§3) issues
**`tlbi vmalle1is`** + **`dsb ish`** before flipping SCTLR.M. The "is"
variant broadcasts the invalidate to the inner-shareable domain — i.e.
all CPUs in the cluster — so even if a secondary CPU has been spun on
the spin-table with a different TTBR mapped from firmware, it loses any
stale entries before the boot CPU enables its own MMU.

The barrier ordering is:

    msr ttbr0_el1, x_low
    msr ttbr1_el1, x_high
    msr tcr_el1,   x_tcr
    msr mair_el1,  x_mair
    isb                     (so the TTBR/TCR writes are observed before TLBI)
    tlbi vmalle1is
    dsb ish                 (TLBI completion)
    ic ialluis              (instruction cache flush, inner shareable)
    dsb ish
    isb
    msr sctlr_el1, x_mmu_on (single write: M|C|I|EOS|EIS|RES1|…)
    isb                     (context-sync the SCTLR change)

This is the textbook ARMv8 "MMU enable" ritual; the only FreeBSD-specific
flourish is the `is` variants throughout, which the `c78ebc69c2aa`
("arm64: Support a shared release for spin-table") commit history shows
were chosen so that secondary CPUs spinning in the spin-table with their
own caches enabled don't see stale shared TLB state when the primary
finally flips its MMU.

## 10. BCM2711‑specific commits

Searching `reviews.freebsd.org` and the commit list for "BCM2711" /
"Pi 4" / "stale cache" turns up:

- **D24436** — "Add genet driver for Raspberry Pi 4B Ethernet" (Mike
  Karels). Lands in 13.0. Phoenix doesn't use this driver, but the
  review's significance is that the maintainer who did the Pi 4 boot
  bring-up wrote it; it is the only Pi-4-specific Phabricator review
  with substantial discussion. The driver itself uses standard FreeBSD
  bus_dma which on arm64 is cache-coherent via DMA descriptors marked
  COHERENT — i.e. *no* explicit `dc cvac` in the data path.

- **`5a08fbb315e8`** — already discussed (§1); the EL2 MMU disable.

- **`587490dabc64`** — "arm64: Fix calculating kernel size for preload
  metadata" — corrects a `vm_offset_t` truncation in
  `fake_preload_metadata()`. Not Pi 4-specific but directly relevant to
  the syspage analogue (§7).

- **`c78ebc69c2aa`** — "arm64: Support a shared release for spin-table" —
  matters for SMP coming up on Pi 4 since the armstub uses spin-table
  before patching the FDT. The relevant rule: "CPUs that share a
  release address wait for their turn to boot by being booted until they
  enable the TLB before waiting their turn to enter init_secondary."
  The phrase **"enable the TLB before waiting their turn"** confirms
  that secondaries enable MMU on their own — they don't ride on the
  primary's MMU enable.

- **`634dd430b966`** + **`95059bef2437`** + **`719908c81300`** — the
  page‑table refactor sequence; useful background but no cache fix in
  any of them.

What is conspicuously **absent** from the FreeBSD history: any commit
along the lines of "BCM2711 stale cache fix," "Pi 4 D-cache invalidate
on boot," or any A72 errata workaround in `locore.S`. That absence is
itself informative: it implies that on FreeBSD the firmware (start4.elf
+ armstub8-gic.bin + U‑Boot/EFI) leaves the system in a state where the
generic ARMv8 MMU-enable ritual works, and FreeBSD never had to ad‑hoc
the cache-enable sequence for the Pi 4 specifically.

## Synthesis — what FreeBSD does that Phoenix likely doesn't

Cross-checking against Phoenix's `_init.S` failure mode, the deltas that
matter most are, in priority order:

1. **EL2 MMU disable** (§1, §5). FreeBSD explicitly clears
   `SCTLR_EL2.M` with a `dsb sy` + `bic` + `msr` + `isb` sequence
   before dropping to EL1. If the Pi armstub/firmware left the EL2 MMU
   on, our SCTLR_EL1 enable runs in an ambiguous translation regime.
   This is the single change most likely to convert failure to success.

2. **Fixed SCTLR pre-load with RES1+EOS bits** (§2). Loading
   `INIT_SCTLR_EL1 = LSMAOE | nTLSMD | EIS | TSCXT | EOS` into
   SCTLR_EL1 *before* the eret means the EL2→EL1 transition itself is
   context-synchronizing and the kernel never executes a single
   instruction with a half-configured SCTLR.

3. **Single-write MMU+caches enable, with TLBI+IC IALLU+DSB ISH around
   it** (§3, §9). M/C/I are flipped together; the surrounding rites are
   `tlbi vmalle1is; dsb ish; ic ialluis; dsb ish; isb; msr sctlr; isb`.
   No staging.

4. **EFI hand‑off contract for syspage / boot info** (§7). FreeBSD reads
   the metadata pre-MMU; the EFI loader cleans D-cache before jumping.
   Phoenix needs to either (a) do the same — read syspage pre-MMU — or
   (b) have plo clean its written ranges (`dc civac` over syspage and
   page tables, `dsb sy`) before branching, and the kernel invalidate
   the same ranges before reading.

5. **Set/way DC ISW at boot** (§8). FreeBSD does *not* do this, but it
   doesn't have to because of (4). Without an EFI-equivalent, Phoenix
   should do it once at the very top of `_init.S` (the ATF
   `dcsw_op_louis(0)` pattern), guaranteeing no firmware-stale lines
   survive into the post-MMU world.

6. **`tlbi vmalle1is`, not `tlbi vmalle1`** (§9). The `is` variant
   covers any secondary CPUs already spinning with their own state,
   which on the Pi 4 includes the three cores held by the armstub.

A practical next step is to inspect `sources/phoenix-rtos-kernel/`'s
`_init.S` for these specific items and produce a single patch that:

- adds the EL2 MMU disable (item 1),
- replaces the partial SCTLR_EL1 RMW with a fixed `INIT_SCTLR_EL1`
  load (item 2),
- collapses any staged M/C/I writes into a single `SCTLR_MMU_ON` write
  flanked by the canonical TLBI/IC IALLU sequence (item 3),
- adds a one-shot DC ISW invalidate at `_start` (item 5),
- switches all `tlbi vmalle1` to the `is` form (item 6).

If that change alone clears the cache-enable failure, items 4
(EFI-equivalent / syspage coherence) will be the residual concern that
shows up next, and is best fixed in plo by mirroring the EFI loader's
contract: enable caches in plo, populate syspage with caches enabled,
clean the populated ranges to PoC, then branch.

---

## Sources

- `dev-commits-src-main/2024-July/025342.html` — `034c83fd7d85`
  "arm64: Ensure sctlr and pstate are in known states" (defines
  `INIT_SCTLR_EL1`, EOS/EIS/TSCXT/LSMAOE/nTLSMD bits).
- `dev-commits-src-branches/2022-September/007051.html` —
  `5a08fbb315e8` "arm64: disable the EL2 MMU before dropping to EL1."
- `reviews.freebsd.org/D34644` — companion review for the EL2 MMU
  disable.
- `dev-commits-src-main` (msg41099) — `6ff9bb7c3bb0` "arm64: Use a
  fixed value for sctlr_el1" (origin of the `SCTLR_MMU_ON` constant).
- `dev-commits-src-all` (msg51908) — `801160f4c0a3` "arm64: Rename
  drop_to_el1 to enter_kernel_el."
- `dev-commits-src-all` (msg57706) — `0054693392f0` "arm64: Boot into
  VHE mode when able" (D46087); confirms VHE is the only EL2-staying
  path and BCM2711's A72 doesn't trigger it.
- `dev-commits-src-main` (msg39300) — `95059bef2437` "arm64: Use tables
  to find early page tables."
- `dev-commits-src-main` (msg31457) — `634dd430b966` "arm64: Update the
  page table list in locore."
- `dev-commits-src-all` (msg54235) — `719908c81300` "arm64: Merge common
  page table creation code."
- `dev-commits-src-all` (msg54231) — `c78ebc69c2aa` "arm64: Support a
  shared release for spin-table" (secondaries enable TLB before entry).
- `dev-commits-src-main` (msg44115) — `587490dabc64` "arm64: Fix
  calculating kernel size for preload metadata"
  (`fake_preload_metadata()` in `sys/arm64/arm64/machdep_boot.c`).
- `reviews.freebsd.org/D24436` — "Add genet driver for Raspberry Pi 4B
  Ethernet" (Mike Karels, 13.0).
- `dev-commits-src-all/2024-May/041156.html` — `94b09d388b81` "arm64:
  map kernel using large pages when page size is 16K" (page-table
  layout context).
- `wiki.freebsd.org/arm/Raspberry%20Pi` — `armstub=armstub8-gic.bin`
  config and Pi 4 boot file list.
- `man.freebsd.org/cgi/man.cgi?query=genet&sektion=4` — confirms genet
  history and BCM2711 hookup.
- `developer.arm.com/documentation/ddi0487` (ARMv8 ARM) — DC IVAC,
  IC IALLUIS, TLBI VMALLE1IS semantics; Section B2.2.4 cautions on
  set/way usage.
- ARM Trusted Firmware `lib/aarch64/cache_helpers.S` — canonical
  `dcsw_op_louis(0)` set/way invalidate-all routine referenced in §8.
- BCM2711 ARM Peripherals datasheet — confirms A72 SCU + MOESI/MESI
  hybrid and the separate 1 MiB system L2 used by the GPU.
