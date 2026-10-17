# Cache enable on Pi 4 — round-3 research synthesis

This document integrates the ten round-3 research briefs and the
prior diagnostic data we have on disk into a single coherent picture
of why Phoenix's Stage 1 cache enable has been failing on real Pi 4
and what to do next.

The contributing briefs (all in `docs/research/`):

- `round3-arm-arm-a72-authoritative.md` — what the ARM ARM and the
  Cortex-A72 TRM actually require for cache+MMU enable
- `round3-bcm2711-firmware-handoff.md` — what state the BCM2711
  firmware leaves the cores in
- `round3-freebsd-arm64-rpi4-deep.md` — FreeBSD's working Pi 4 boot
  path
- `round3-netbsd-aarch64-rpi4-deep.md` — NetBSD's clean-room aarch64
  boot path
- `round3-microkernels-rpi4-handoff.md` — seL4 / Genode comparison +
  Phoenix-side audit
- `round3-baremetal-pi4-cache-bugs.md` — bare-metal Pi 4 forum / blog
  consensus
- `round3-diagnostic-techniques.md` — how other projects observe
  early-boot bugs
- `round3-plo-kernel-handoff.md` — Phoenix-specific handoff audit
- `round3-phoenix-port-conventions-audit.md` — comparison of Phoenix
  rpi4b port against canonical Phoenix idiom (the most actionable
  brief)
- `early-boot-diagnostic-instrumentation.md` (in `docs/plans/`) —
  ready-to-apply UART instrumentation patch

## 1. Symptoms (refresher)

- Kernel boots cleanly with **MMU on, caches OFF** (M=1, C=0, I=0):
  reaches `psh: readcmd` and exposes `(psh)%`. This is the validated
  baseline.
- **Phase A (M+I)**: boot reaches X4/X5 + the TD-15/16 probes, then
  faults during `syspage.c:476` (`hal_syspageRelocate`). Identical
  signature across multiple variants (with and without pre/post
  `ic iallu`, with and without `RES1` baseline, with and without
  armstub-side erratum 859971).
- **Phase B (M+C+I)**: boot hangs at X3, immediately post-MMU.M flip,
  before X4 marker. Classic "stale cache shadows page tables".
- Neither phase produces an explicit panic — the no-call exception
  dump prints register fragments but no clear ESR/FAR labels.

## 2. Hypotheses we ruled out

1. **TTL3 coverage too small** — kernel ELF is 150 KB total, fits in
   the existing 2 MB TTL3 mapping. Not the cause.
2. **plo dirty cache lines** — plo runs caches OFF end-to-end on
   rpi4b (verified via `plo/hal/aarch64/generic/_init.S:107,118,147`).
   No dirty lines on plo's side to leak.
3. **PL011 MMIO TTE missing XN/PXN** — verified `EARLY_UART_DEVICE_BLOCK`
   already has bits 53 and 54 set (the leading `0x6` in
   `0x60000000000709`). Not the cause.
4. **A72 erratum 859971 worked around at EL1** — the kernel-side
   write hung at the MRS to S3_1_C15_C2_0; the fix moved to EL3 via
   the armstub. Real fix, but not the underlying cause of the cache
   regression.
5. **Bit number for 859971** — was wrong (we used bit 47, ATF says
   bit 32 — `DIS_INSTR_PREFETCH`). Corrected. Still not the cause.
6. **Speculative I-fetch into MMIO** — the only Device-mapped block
   already has XN+PXN. Not the cause.
7. **RES1 SCTLR baseline** — `0x30d4d938` (the convergent BSD-style
   value) actually **regressed** even M-only boot for reasons not
   yet understood; reverted to `0x30c0c938`. Pursue separately when
   the structural fixes below are in place.

## 3. Hypotheses still in play (ranked by evidence)

### 3.1 (Most likely) Phoenix rpi4b breaks the canonical Phoenix plo→kernel handoff contract

This is the strongest finding from
`round3-phoenix-port-conventions-audit.md` — independently corroborated
by `round3-microkernels-rpi4-handoff.md`,
`round3-arm-arm-a72-authoritative.md`,
`round3-freebsd-arm64-rpi4-deep.md`, and
`round3-netbsd-aarch64-rpi4-deep.md`.

**Phoenix's canonical idiom**, observed in `imx6ull`, `zynq7000`,
`zynqmp`:

```
plo (caches+MMU ON)
   ↓ build syspage in cacheable DDR (writes through D-cache)
   ↓ at hal_cpuJump():
   ↓   dcacheFlush(OCRAM)
   ↓   dcacheFlush(DDR-FULL)              ← entire DRAM, not just heap
   ↓   icacheInval()
   ↓   mmu_disable()
   ↓ jump to kernel
kernel (caches OFF, MMU OFF) at _start
   ↓   ic ialluis; tlbi vmalle1is
   ↓   dc isw set/way invalidate ALL levels (CLIDR_EL1 walk)
   ↓ build page tables
   ↓ flip SCTLR.{M,C,I} TOGETHER in one MSR
```

**rpi4b deviates** on four dimensions:

| # | Dimension | Canonical | rpi4b |
|---|---|---|---|
| 1 | plo cache state | MMU+caches ON | caches OFF (`plo/hal/aarch64/generic/hal.c:86-96`) |
| 2 | plo flush range | full DDR + OCRAM | only `[__heap_base, __heap_limit)` (`generic/hal.c:386`) |
| 3 | kernel `_start` `dc isw` | calls full set/way invalidate | function exists (`_init.S:1188-1242`) but not called |
| 4 | SCTLR flip | M\|C\|I single write | currently M-only; Phase A added I, Phase B added C |

Each deviation is fixable independently and they compound. Once
aligned with canonical idiom, the cache-coherency edge cases that
have plagued every Phase A/B variant should reduce to a tractable
per-line issue rather than a cross-cutting failure mode.

### 3.2 (Secondary) BSDs use Inner-Shareable broadcast cache/TLB ops

FreeBSD and NetBSD both use:
- `tlbi vmalle1is` (broadcast IS), not `tlbi vmalle1` (local)
- `ic ialluis`, not `ic iallu`
- `dsb ish`, not `dsb nsh`

Phoenix uses the local variants. On a single-core boot this should
not cause a hang, but it could leave stale lines on cores 1-3 that
the spin-table secondaries inherit. Fix order: align with BSDs after
3.1 lands.

### 3.3 (Convergent recommendation) M+C+I in a single SCTLR write

Every working A-class Phoenix port (imx6ull, zynq7000, zynqmp) and
every BSD on Pi 4 enables M, C, and I in a single MSR. The
"unstable middle state" hypothesis isn't well-founded
architecturally, but it is empirically supported: nobody else stages
the bits, and our staged attempts (Phase A) fail.

## 4. Hypotheses that need further investigation

### 4.1 SCTLR baseline regression

Setting SCTLR baseline to `0x30d4d938` (the proper RES1 value per
A57/A72 SDEN) **regressed** even the M-only boot on Pi 4. This is
unexpected — RES1 bits should be safe to set. Possible explanations:

- One of the bits we added (LSMAOE / nTLSMD / EIS / TSCXT / EOS — the
  bits that distinguish 0x30d4d938 from 0x30c0c938) is interpreted
  as "behaviour change" not "RES1" by A72 r0p3 silicon and breaks
  something downstream.
- Decoding error: `0x30d4d938` is not what we think it is. Verify by
  reading SCTLR_EL1 bit-by-bit per the ARM ARM definition and
  cross-checking against ATF/Linux/seL4 macros.

Investigate **after** the 3.1 fix lands, in case the regression was a
secondary effect of the un-canonical handoff.

### 4.2 The actual fault location at `syspage.c:476`

The Phase A bisection ladder claims the fault is at the
`hal_syspageRelocate(...)` call. Verify by running the
diagnostic-instrumentation patch (see §6) once Phase A is restored —
specifically the kernel-side instrumentation in `syspage.c` and
`_hal_init`.

### 4.3 Cache-line shadow population during firmware handoff

The BCM2711 firmware writes the kernel image into DRAM. Per the
firmware-handoff brief, A72 r0p3 hardware-invalidates L1 at cold
reset, so any speculative fills should be empty. But "cold reset"
applies only to the very first power-on — if there's any reset path
that doesn't reset the L1 (e.g. soft reset, watchdog), this might
leak. Investigate via diagnostic instrumentation (read CSSELR /
CCSIDR at `_start` and confirm L1 is empty).

## 5. Concrete fix sequence (ordered by lowest risk first)

The order below is designed so each step is independently
verifiable, and so a regression in step N can be rolled back without
losing earlier steps.

### Step 1 — Add `hal_cpuInvalDataCacheAll` to kernel `_start`

The function at `_init.S:1188-1242` walks CLIDR_EL1 levels and runs
`dc isw` per set/way. Currently never called. Add a call at `_start`
right after the existing `ic ialluis; tlbi vmalle1` block.

Pattern: matches `imx6ull/_init.S:519-545` and `zynq7000/_init.S:117-148`.

UART signature: same as today (boot to `(psh)%`); zero functional
delta in M-only mode because there are no D-cache lines yet to
invalidate. Confirms the function works without crashing.

### Step 2 — Extend plo's `hal_cpuJump` flush

In `plo/hal/aarch64/generic/hal.c:386` (rpi4b), expand the `dc civac`
range from `[__heap_base, __heap_limit)` to `[ADDR_DDR, ADDR_DDR + DDR_SIZE)`
plus OCRAM if applicable. Mirror `plo/hal/aarch64/zynqmp/hal.c:257-262`.

UART signature: same as today; zero functional delta in caches-off
mode because there are no dirty lines. Confirms the broader range
is correctly addressed and no helper is broken.

### Step 3 — Make plo run with MMU+caches ON

Add `hal_memoryInit()` to plo's rpi4b `hal_init`
(`plo/hal/aarch64/generic/hal.c:86-96`), matching the zynqmp port.
Now plo writes to syspage go through D-cache; plo's `dcacheFlush(DDR)`
in `hal_cpuJump` is now load-bearing.

UART signature: plo phase prints faster; everything else unchanged.
Confirms plo can run with caches without breaking the existing
caches-off kernel path.

### Step 4 — Switch to broadcast IS variants in kernel `_init.S`

- `tlbi vmalle1` → `tlbi vmalle1is`
- `ic iallu` → `ic ialluis`
- `dsb nsh` → `dsb ish`

Matches FreeBSD, NetBSD, seL4. UART signature: identical M-only
boot. Confirms broadcast variants don't hang.

### Step 5 — Single M+C+I SCTLR flip

Replace the staged `M=1, C=0, I=0` flip at `_init.S:444-449` with a
single `M|C|I` write, flanked by the canonical barrier ritual:

```
ic ialluis
dsb ish
tlbi vmalle1is
dsb ish
isb
mrs x0, sctlr_el1
orr x0, x0, #(1 << 0)    /* M */
orr x0, x0, #(1 << 2)    /* C */
orr x0, x0, #(1 << 12)   /* I */
msr sctlr_el1, x0
isb
ic ialluis
dsb ish
isb
```

This is the moment of truth. With Steps 1-4 in place, the cache
coherency picture is now canonical and Phase B should succeed.

### Step 6 — Investigate RES1 baseline regression

Once Step 5 boots, retry the `0x30d4d938` SCTLR baseline. With
canonical handoff in place it may now be safe (Steps 1-4 may have
been masking an interaction).

### Step 7 — Diagnostic instrumentation

Apply the patch from `docs/done/early-boot-diagnostic-instrumentation.md`
to get rich UART output for the next round of debugging — full
register dumps at each phase, sysreg readbacks, syspage state.
Should be applied **before** Step 5 if Step 5 hangs unexpectedly,
to give us proper observability instead of single-character markers.

## 6. Why the order matters

Steps 1-4 are individually low-risk (each functionally a no-op in
the current caches-off boot). They establish the canonical
preconditions Phoenix's other ports rely on. Step 5 is the actual
cache enable; with the preconditions in place it has the highest
probability of succeeding.

If Step 5 still fails, Step 7 (diagnostic instrumentation) gives us
proper observability for further investigation. The bisection
ladder, the BSD survey, and the ARM ARM each provide additional
fallback hypotheses (broadcast TLB invalidate timing, Cortex-A72
errata 1319367, deeper page-table-walker ordering) that we can
test methodically once we have the diagnostic harness.

## 7. Pi 5 forward-compatibility

All the fixes in Section 5 align rpi4b with Phoenix's canonical
A-class handoff. They will transfer cleanly to the Pi 5 / Cortex-A76
port when we get there — RP1 changes peripheral plumbing but does
not change the kernel↔loader handoff contract.

## 8. What we are NOT changing in this round

- USB phase 2 (xhci scratchpad) — already in tree; defer validation
  until cache enable lands.
- Anything in user space.
- Armstub — current 859971 + SMPEN at EL3 stays in.
- Userspace demo apps / tinyx X11 — those plans are downstream
  milestones, untouched.

## 9. Acceptance criteria for "Stage 1 done"

- Pi 4 boots through `(psh)%` with M+C+I all enabled.
- HDMI rendering speed visibly higher (text appears in real time, not
  glyph-by-glyph).
- `dd if=/dev/zero of=/tmp/x bs=1M count=8` runs at cache speed
  (multiple MB/s, not single-digit KB/s).
- Three consecutive cold-boot cycles all reach `(psh)%` cleanly.

Once those four hold, Stage 1 is closed and Stages 2 (4 GiB DRAM)
and 3 (SMP) become unblocked.
