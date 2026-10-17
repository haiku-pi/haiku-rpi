# EL2 to EL1 drop on BCM2711 Cortex-A72: design and patch

Status: design doc, not yet applied. Likely root cause behind the
TD-16 cache-enable failures: the kernel has been writing EL1 sysregs
from EL2, so SCTLR_EL1.M=1 has been programming a future EL1 context
we never actually `eret`ed into.

## 1. Problem statement

The armstub `eret`s to **EL2h** and the kernel begins at EL2. From
`sources/phoenix-rtos-project/_projects/aarch64a72-generic-rpi4b/phoenix-armstub8-rpi4.S`:

- Line 65: `SPSR_EL3_MODE_EL2H 9` — target mode bits.
- Lines 171–175: `spsr_el3 = SPSR_EL3_VAL`, `elr_el3 = in_el2`, `eret`.
  After this `eret`, hardware state is EL2h.
- Line 169 programs SCTLR_EL2; line 179 sets VBAR_EL2.

From `sources/phoenix-rtos-kernel/hal/aarch64/_init.S`:

- Line 186 (`_start:`) entered with `CurrentEL == 0b1000` (EL2).
- Line 211: `ldr x0, =0x30c0c938`.
- Line 212: `msr sctlr_el1, x0` — **the bug**. Writing SCTLR_EL1
  from EL2 is legal but programs only the EL1 *context*; until an
  `eret` to EL1 happens, SCTLR_EL1.M=1 has zero effect on the
  currently-executing instruction stream, which is governed by
  SCTLR_EL2.
- Lines 267–322 write TCR/MAIR/TTBR0/TTBR1/VBAR_EL1 — all stashed
  for an EL1 we never enter.
- Line 353: the "MMU enable" `orr…#(1<<0); msr sctlr_el1, x0` —
  same problem.

This explains the TD-16 iteration log at lines 516–559: the MMU we
were "enabling" was the EL1 MMU; the walker actually serving
instruction fetch was the EL2 walker, which we had not given any
translation tables.

## 2. Why running the kernel at EL2 is infeasible

Leaving the kernel at EL2 and rewriting `_init.S` against EL2 sysregs
is not viable on BCM2711:

- **No TTBR1_EL2 on armv8.0.** Phoenix's pmap relies on dual VA-space
  translation (low-VA TTBR0 idmap + high-VA TTBR1 kernel at
  `0xffffffffc0000000+`). armv8.0 EL2 has only TTBR0_EL2 and a single
  VA space — the high/low split does not exist.
- **No VHE on Cortex-A72.** FEAT_VHE (armv8.1) adds TTBR1_EL2 and
  lets a kernel run at EL2 behaving like EL1 (E2H=1, TGE=1). A72 is
  baseline armv8-A and does not implement FEAT_VHE. Linux's
  `init_kernel_el` falls through to the nvhe drop on non-VHE silicon
  for the same reason.

The kernel must therefore run at EL1, and `_init.S` must drop EL2→EL1
before the line-211 SCTLR_EL1 write. The drop must run on every core
(primary + 3 secondaries) because the armstub leaves all four at EL2.

## 3. Linux's nvhe drop sequence, annotated

Linux's drop sequence lives in `arch/arm64/kernel/head.S`
(`init_kernel_el` / `init_el2`) and the macro pack in
`arch/arm64/include/asm/el2_setup.h`. The shape (v6.6):

```
init_kernel_el:
    mrs  x0, CurrentEL
    cmp  x0, #CurrentEL_EL2
    b.eq init_el2
    /* fall through: already at EL1 */
    msr  sctlr_el1, <INIT_SCTLR_EL1_MMU_OFF>
    isb
    mov  w0, #BOOT_CPU_MODE_EL1
    str  w0, __boot_cpu_mode
    eret              // we were entered via bl; "ret" via eret to LR

init_el2:
    msr  sctlr_el2, <INIT_SCTLR_EL2_MMU_OFF>
    init_el2_state         // expands to the macros below
    /* nVHE: build SPSR/ELR for EL1h and eret */
    mov  x0, #INIT_PSTATE_EL1   // EL1h, DAIF masked = 0x3c5
    msr  spsr_el2, x0
    msr  elr_el2, lr
    mov  w0, #BOOT_CPU_MODE_EL2
    eret
```

`init_el2_state` (in `el2_setup.h`) expands to:

- `__init_el2_timers`: `CNTHCTL_EL2 = EL1PCEN | EL1PCTEN` (bits 1:0
  with E2H=0); `CNTVOFF_EL2 = 0`. EL1 physical timer accessible to
  EL1 with no virtual offset.
- `__init_el2_stage2`: `VTTBR_EL2 = 0`. Stage-2 off.
- `__init_el2_hcr`: HCR_EL2 with RW (bit 31, AArch64 EL1) set. For
  nvhe, E2H and TGE are zero.
- `__init_el2_fpsimd`: clears CPTR_EL2 traps so EL1 can use FP/SIMD.

`INIT_PSTATE_EL1 = 0x3c5`: bits 9:6 = DAIF mask (0xf), bits 3:0 =
0b0101 (EL1h, M[3:0]=0101).

## 4. Proposed Phoenix `_init.S` patch

Insert a drop block immediately before the existing SCTLR_EL1 write
on line 211. The SCTLR_EL1 write becomes the EL1 entry point reached
through `eret`. All four cores execute the same block — the secondary
spin loop in the armstub (lines 184–195 of the armstub) `br`s each
secondary into the same kernel entry, so the drop runs unconditionally
per core. We branch over the drop on the EL1 fast-path so the patch is
also a no-op if a future bring-up flow (or QEMU `-machine virt` with
`-cpu cortex-a72,el2=off`) ever delivers us already at EL1.

```diff
--- a/hal/aarch64/_init.S
+++ b/hal/aarch64/_init.S
@@ -185,11 +185,55 @@
 _start:
 	uart_reinit_115200
-        /* DEBUG: Check current exception level */
-        mrs x0, CurrentEL
-        uart_putc 90 /* DEBUG: CurrentEL value */
-        
-        /* Assumptions:
+        /* Drop to EL1 (mirrors Linux nvhe init_kernel_el). A72 has no
+         * VHE/TTBR1_EL2 so kernel must run at EL1 for dual-VA pmap. */
+        mrs x0, CurrentEL
+        cmp x0, #(2 << 2)            /* EL2 == 0b1000 */
+        b.ne el1_entry               /* already at EL1: skip drop */
+
+        /* HCR_EL2.RW = 1: EL1 is AArch64. Others zero (not virtualizing).
+         * armv8.0 baseline has no RES1 bits in HCR_EL2; revisit if SoC
+         * gains FEAT_E2H0 / FEAT_RME. */
+        mov  x0, #(1 << 31)
+        msr  hcr_el2, x0
+
+        /* Stage-2 translation off. */
+        msr  vttbr_el2, xzr
+
+        /* Timer virtualization for EL1: enable EL1 physical timer
+         * (EL1PCEN bit 1) and physical counter (EL1PCTEN bit 0); zero
+         * the virtual offset. Matches Linux __init_el2_timers nvhe path. */
+        mov  x0, #3
+        msr  cnthctl_el2, x0
+        msr  cntvoff_el2, xzr
+
+        /* Mirror VBAR_EL2 into VBAR_EL1 so an exception in the window
+         * before the real VBAR_EL1 install lands in the armstub's
+         * wfe-loop rather than at PC=0. */
+        mrs  x0, vbar_el2
+        msr  vbar_el1, x0
+
+        /* Don't trap FP/SIMD/SVE at EL2 on the way through. */
+        msr  cptr_el2, xzr
+
+        /* SPSR_EL2 = 0x3c5: EL1h, DAIF masked. */
+        mov  x0, #0x3c5
+        msr  spsr_el2, x0
+        adr  x0, el1_entry
+        msr  elr_el2, x0
+        isb
+        eret
+
+el1_entry:
+        /* At EL1. EL1 sysreg writes now affect the executing context. */
+        mrs x0, CurrentEL            /* expect 0x4 (EL1) — diag only */
+        uart_putc 90
+
+        /* Assumptions:
          * x9 => PA of syspage from PLO */
         uart_putc 75
 	/* Mask all interrupts */
 	msr daifSet, #0xf
@@ -208,7 +252,7 @@
 		UCT == 1 => don't trap accesses to CTR_EL0 (cache type reg.) from EL0
 		DZE == 1 => don't trap DC ZVA instructions from EL0
 		UCI == 0 => trap cache maintenance instructions executed at EL0
 	 */
 	ldr x0, =0x30c0c938
 	msr sctlr_el1, x0
```

(The patch is shown at unified-diff level but logically the change is a
40-line insertion before the existing line 211.)

## 5. Predicted UART signature post-fix

- Read of `CurrentEL` after the drop yields `0x4` (EL1) where today
  it yields `0x8` (EL2). Marker `Z` doesn't render the hex today,
  but a QEMU gdbstub or one-line widening of the diagnostic gives an
  unambiguous signature.
- Existing markers `K`/`L`/`M`/`X1`–`X4` continue. The qualitative
  difference: **after `X3` the MMU is actually on**, so high-VA
  literal-pool reads via TTBR1 that TD-16 saw as walker faults now
  succeed.
- The TD-16 cache-enable attempts can be retried with M|C|I together.
  The Iteration 4/5 faults (ESR=0x96000001, FAR=0xfe201018) should
  not recur — those were the EL2 walker hitting a missing TTL1.
- Boot reaches `_hal_init` (line 1153) and proceeds into `main` and
  userspace, producing `(psh)%`.

## 6. Risks and open questions

- **Secondary cores.** Armstub lines 182–195 (`secondary_spin:`) `br`
  each non-zero MPIDR core to whatever core 0 wrote into the
  `spin_cpuN` slot. Today that destination is `_start` for all
  cores, so the new drop block runs on every core unmodified.
  Confirmed by reading the armstub. If a future change adds a
  separate secondary entry point, that entry point must also drop
  EL2→EL1 before touching EL1 sysregs.
- **VBAR_EL1 timing.** The patch mirrors VBAR_EL2 into VBAR_EL1 as
  a fault-survivability measure for the brief window between `eret`
  and the real VBAR_EL1 install (line 319 today). An EL1 fault in
  that window lands in the armstub's wfe-loop — silent but
  informative (no further UART). The real VBAR_EL1 installs at
  lines 319 and 694 are unchanged.
- **HCR_EL2 RES1 bits.** Cortex-A72 is baseline armv8.0; the ARM ARM
  RES1 cases for HCR_EL2 only apply on FEAT_E2H0 / FEAT_RME-bearing
  implementations. Setting HCR_EL2 to `(1<<31)` with all other bits
  zero is legal here. Double-check the Cortex-A72 r1p3 TRM before
  merging in case A72-specific RES1 behaviour exists.
- **Timer setup ordering vs. armstub.** The armstub (lines 153,
  155–157) already programs `cntfrq_el0`, `cntvoff_el2`,
  `cnthctl_el2`. We rewrite the latter two defensively; the
  armstub-set `cntfrq_el0` is preserved.
- **Interaction with TD-04 / TD-16.** With the MMU actually enabling
  at EL1, the TD-04 NC-page workaround may behave differently — the
  observed cache anomaly was diagnosed against a boot where caches
  were "off" only on paper. Re-run the E2 probe after the drop
  lands before assuming TD-04 is still required.

Sources:

- [linux/arch/arm64/kernel/head.S — torvalds/linux on GitHub](https://github.com/torvalds/linux/blob/master/arch/arm64/kernel/head.S)
- [el2_setup.h source code — Codebrowser](https://codebrowser.dev/linux/linux/arch/arm64/include/asm/el2_setup.h.html)
- [arm64: initialize all of CNTHCTL_EL2 — stable backport thread](https://lists-ec2.96boards.org/archives/list/linux-stable-mirror@lists.linaro.org/message/BB7RPGEUG7PIMRGHDZQR2EHPFVAJDGBU/)
- [Booting AArch64 Linux — kernel.org](https://www.kernel.org/doc/html/v5.4/arm64/booting.html)
- [arm64: Simplify init_el2_state to be non-VHE only — patchwork](https://patchwork.kernel.org/project/linux-arm-kernel/patch/20210111132811.2455113-8-maz@kernel.org/)
- [CNTHCTL_EL2 — Jon's Arm Reference](https://arm.jonpalmisc.com/latest_sysreg/AArch64-cnthctl_el2)
