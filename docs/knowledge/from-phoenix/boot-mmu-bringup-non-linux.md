# Early-boot / MMU / cache / EL handling on Pi 4 — non-Linux survey

Phoenix-RTOS Pi 4 currently silent-hangs at the SCTLR_EL1 write that turns the
MMU + caches on. The working theory is that the kernel is still at EL2 (the
state the VideoCore firmware leaves it in on Pi 4) while writing EL1 sysregs,
so TCR_EL1 / TTBR_EL1 / MAIR_EL1 do not actually configure the translation
regime that gets used when M=1 fires. Linux solves this by dropping EL2 -> EL1
nVHE in `head.S`. Phoenix is a microkernel, so before copying Linux verbatim
it is useful to see how non-Linux kernels — especially other microkernels and
hypervisors — handle the same Pi 4 / Cortex-A72 hardware.

This survey deliberately excludes Linux. All citations are to primary sources
(source files, official docs, archived blog posts).

## 1. Comparison table

| Project | EL on entry (Pi 4) | Drop EL2 -> EL1? | SCTLR enable shape | XN/PXN on MMIO | SMPEN handling | Errata WAs |
|---|---|---|---|---|---|---|
| seL4 (non-hyp) | EL2 from firmware; elfloader drops to EL1 | Yes, in `seL4_tools` elfloader before kernel entry | Single read-modify-write on `SCTLR` macro that resolves to `sctlr_el1` or `sctlr_el2` per build, with `isb` after | Not in core enable path; left to `map_kernel_devices` | Done by elfloader/U-Boot before kernel runs | Inherits ATF / U-Boot WAs |
| seL4 (hyp/EL2) | EL2 directly | No — runs at EL2, uses VHE-style remap of EL1 sysreg names to EL2 via `#define SCTLR sctlr_el2` | Same RMW, but on `sctlr_el2`; vCPU-side `SCTLR_EL1_NATIVE` programmed from C later | As above | Same | Same |
| FreeBSD arm64 | EL2 (firmware) or EL1 | Yes — but first **disables EL2 MMU** by writing `SCTLR_EL2_RES1 \| EIS \| EOS`, then ERETs to EL1 | `start_mmu` does `bic clear / orr set` on `sctlr_el1`, `isb`; preceded by full TLB invalidate | Set per-mapping in pmap, enforced via PTE attrs | Done by ATF / U-Boot | A53 errata via Kconfig; A72 mostly relies on firmware |
| NetBSD aarch64 | EL2 or EL1 | Yes, in `locore_el2.S` | RMW on `sctlr_el1` with `bic clear / orr set` and `isb`; `dsb sy` before, `dsb ishst; tlbi vmalle1is; dsb ish; isb` immediately before the M=1 write | PTE-attr based, not in enable path | Done before kernel | Generic |
| OpenBSD arm64 | EL2 or EL1 | Yes, `drop_to_el1` in `locore.S` | Two-stage: `SCTLR_EL1 = RES1` first (MMU off, sane defaults), then later in `start_mmu` apply set/clear masks with `isb` | PTE-attr | Bootloader | Minimal |
| Xen | EL2 always | **No** — Xen runs at EL2 by design; uses `sctlr_el2`, `ttbr0_el2`, `tcr_el2`; required to be entered with MMU off and D-cache off | RMW on `sctlr_el2`, `isb` after | Stage-2 plus stage-1 EL2; MMIO is non-cacheable Device by attribute | Inherits | Targets a72 for Pi 4 builds |
| Circle (rsta2) | EL3 -> EL2 (armstub8) -> EL1 (kernel) | Yes, via Pi-firmware `armstub8.S` ERET, then in-kernel `armv8_switch_to_el1_m` | Programs `sctlr_el1` RES1+RES0 with M=0, then later C-level `EnableMMU` does single MSR with all bits | XN on MMIO regions in the page-table descriptors | Set in armstub before kernel | None Pi-4-specific |
| Ultibo (Pascal) | EL2 from firmware | Yes; bootstub drops to EL1 explicitly | RMW on `sctlr_el1`, `isb` | Yes, MMIO marked XN | Set in stub | None |
| rpi4-osdev tutorial | EL2 (the post explicitly observes "we start at EL2 on Pi 4") | Yes — Part 12 is titled "drop to EL1" and shows the SPSR/ELR/eret dance | tutorial-grade RMW on `sctlr_el1` | tutorial-only | tutorial-only | none |
| bztsrc/raspi3-tutorial | EL2 | Yes, in `start.S` | Aggressive RMW: clears EE/E0E/WXN/I/SA0/SA/C/A, sets RES + M, single MSR + ISB; **note it leaves I and C cleared** | Tutorial-only | n/a | n/a |
| Genode base-hw | EL2 from firmware | Yes; bootstrap `crt0.s` first force-disables MMU at *whatever* EL it finds (CurrentEL switch), then drops | C++ `Cpu::enable_mmu()` does a single MSR after MAIR/TCR/TTBR are programmed; `dsb sy; isb` straddle the write | Stage-1 attrs on each region | Bootstrap | None Pi-4-specific |
| NuttX | Originally entered at EL2; used `sctlr_el2`, hit `ldaxr` fault until MMU truly came up | Yes (ported to drop) | Standard A53/A57/A72 sequence | PTE-attr | Stub | None |
| rpi-open-firmware | Runs on VPU (VC4), not on the A72 ARM cores | Out of scope for ARM EL handling | n/a | n/a | n/a | n/a |

## 2. Per-project narratives

### seL4 (non-hyp build)

seL4 is the closest microkernel comparator to Phoenix and is the most relevant
data-point. The kernel itself does **not** drop EL2 -> EL1; that work is done
in the **elfloader** in `seL4/seL4_tools` before control reaches `head.S`.
The kernel `head.S` contains the macro
`#ifdef CONFIG_ARM_HYPERVISOR_SUPPORT / #define SCTLR sctlr_el2 / #else /
#define SCTLR sctlr_el1 / #endif`, then a single
`mrs x4, SCTLR / orr / bic / msr SCTLR, x4`. Issue
[seL4#1025](https://github.com/seL4/seL4/issues/1025) documents that the
SCTLR\_EL1 value seen by native threads differs between the two builds:
`SCTLR_EL1_NATIVE = SCTLR_EL1 | C | I | UCI` where
`SCTLR_EL1 = SCTLR_EL1_RES (=0x30d00800, "A57 default") | CP15BEN | NTWI |
NTWE`. The constant `0x30d00800` is the architectural RES1-mask for A57/A72.
Implication for Phoenix: the constant value seL4 trusts as "RES1 baseline" is
the same `0x30d00800` Linux uses, and the same value the Pi 4 firmware leaves
in `SCTLR_EL2`.

### seL4 (hyp / EL2 build)

When `CONFIG_ARM_HYPERVISOR_SUPPORT` is set, seL4 runs at EL2 and just
re-aims the macro at `sctlr_el2`. No drop happens. This is the proof that you
*can* run a microkernel at EL2 on A72 — but seL4's Pi 4 platform docs
([docs.sel4.systems/Hardware/Rpi4](https://docs.sel4.systems/Hardware/Rpi4.html))
still recommend the non-hyp build for normal use and route boot through
U-Boot, which has already configured a sensible state. So the EL2-direct path
exists but needs the surrounding stack to cooperate.

### FreeBSD arm64

FreeBSD's
[`sys/arm64/arm64/locore.S`](https://github.com/freebsd/freebsd-src/blob/main/sys/arm64/arm64/locore.S)
contains `enter_kernel_el` (ex-`drop_to_el1`). Phabricator review
[D34644](https://reviews.freebsd.org/D34644) — committed as
`5a08fbb315e8` — explicitly **disables the EL2 MMU** before the drop:

> "An earlier stage may have set HCR\_EL2.E2H, the clearing of which may
> break address translation. ... the EL2 MMU is not needed at the point of
> dropping to EL1, just drop to EL1 as usual."

The code does `mov_q x2, (SCTLR_EL2_RES1 | SCTLR_EL2_EIS | SCTLR_EL2_EOS); msr
sctlr_el2, x2; isb` *with `mov` so no memory access happens between the
SCTLR\_EL2 write and the EL drop*. Then it sets `HCR_EL2 = HCR_RW | APK | API
| ATA`, `sctlr_el1 = SCTLR_MMU_OFF`, then ERETs. Later, `start_mmu` does the
standard `mrs / bic clear / orr set / msr sctlr_el1; isb` after MAIR/TCR/TTBR
are fully programmed. This is the most defensive sequence in the survey.

### NetBSD aarch64

NetBSD's
[`sys/arch/aarch64/aarch64/locore.S`](http://cvsweb.netbsd.org/bsdweb.cgi/src/sys/arch/aarch64/aarch64/locore.S)
includes `<aarch64/locore_el2.S>` for the drop. The `mmu_enable` routine puts
`dsb sy / dsb ishst / tlbi vmalle1is / dsb ish / isb` *before* the M=1 write,
then writes SCTLR\_EL1 with `bic clear / orr set` and a final `isb`. MAIR is
programmed with four standard attrs (write-back, non-cacheable, write-through,
device); TCR is programmed with shareability and granule before TTBRs.

### OpenBSD arm64

OpenBSD's
[`sys/arch/arm64/arm64/locore.S`](https://github.com/openbsd/src/blob/master/sys/arch/arm64/arm64/locore.S)
is famously short. `drop_to_el1` reads `CurrentEL`, branches if EL2, sets
`sctlr_el1` to a sentinel RES1-only value (MMU off, sane state), then ERETs.
Later `start_mmu` programs MAIR / TCR / TTBR0/TTBR1, runs the
`dsb ishst; tlbi vmalle1is; dsb ish; isb` invalidate, then RMWs `sctlr_el1`.
TTBR1 is loaded *before* the M=1 write — the kernel has already moved its
view of itself into TTBR1 high half during identity-mapped boot.

### Xen on ARM

Xen is the only project here that **runs at EL2 in production**. Per
[xenbits.xen.org/docs/unstable/misc/arm/booting.txt](https://xenbits.xen.org/docs/unstable/misc/arm/booting.txt),
Xen demands "MMU = off, D-cache = off" on entry (i.e. SCTLR\_EL2.M = 0 and
.C = 0). It then programs `sctlr_el2 / ttbr0_el2 / tcr_el2 / mair_el2` and
enables. Note: there is no `ttbr1_el2` on a non-VHE system; Xen is
single-TTBR. This is the trade-off Phoenix would inherit if it chose to stay
at EL2: no split user/kernel TTBR unless we enable VHE
(HCR\_EL2.E2H=1, HCR\_EL2.TGE=0), in which case the EL1 sysreg names are
re-mapped to EL2 banked copies and TTBR1\_EL2 actually exists. A72 does not
support VHE (it's a v8.0 core). So "stay at EL2 and use TTBR1\_EL2" is **not
a viable option for Pi 4**.

### Circle (rsta2)

Circle uses the Raspberry Pi firmware's
[`boot/armstub/armstub8.S`](https://github.com/rsta2/circle/blob/master/boot/armstub/armstub8.S)
to do the EL3 -> EL2 drop, set `CPUECTLR_EL1.SMPEN`, set `SCTLR_EL2 =
0x30c50830` (RES1 / cache-off / align-off). Then in
[`lib/startup64.S`](https://github.com/rsta2/circle/blob/master/lib/startup64.S)
it does `armv8_switch_to_el1_m`: programs `cnthctl_el2` (timer),
`cptr_el2 = 0x33ff` (FP/SIMD trap off), `cpacr_el1 = 3<<20`,
`hcr_el2 = (1<<31)` (RW=64-bit), `sctlr_el1` with RES1 bits set and M=0,
ELR\_EL2 + SPSR\_EL2, `eret`. The actual MMU enable happens later in C code,
single MSR. Circle is the canonical "small, single-purpose" reference.

### Ultibo

Ultibo (Pascal-based) follows the same pattern as Circle — a small ASM stub
drops to EL1, then high-level code programs the page tables and finally
enables the MMU. Source: ultibo.org "Boot process" docs and the
`ultibo/core/source/aarch64/` boot ASM.

### Bare-metal blog posts

- **rpi4-osdev** Part 12 ([rpi4os.com/part12-wgt](https://www.rpi4os.com/part12-wgt/))
  is explicit: on Pi 4 firmware drops the kernel at EL2; the tutorial drops to
  EL1 with the standard SPSR\_EL2 / ELR\_EL2 / eret dance before doing
  anything else.
- **bztsrc/raspi3-tutorial** ([github.com/bztsrc/raspi3-tutorial](https://github.com/bztsrc/raspi3-tutorial/blob/master/10_virtualmemory/mmu.c))
  enables MMU but **leaves I and C cleared** (lines 161–169 of `mmu.c`),
  proving the M-bit can be flipped without C/I and the kernel stays alive.
  This is a useful sanity test — if Phoenix's M-only flip also hangs, the
  bug is not in the C/I bits.
- **leiradel** ([leiradel.github.io/2019/01/20/Raspberry-Pi-Stubs.html](https://leiradel.github.io/2019/01/20/Raspberry-Pi-Stubs.html))
  documents the Pi firmware stub: it sets `CPUECTLR_EL1.SMPEN` (bit 6,
  S3\_1\_c15\_c2\_1) before MMU/cache enable, in line with the A72 TRM
  requirement.
- **iosoft.blog** (Jeremy Bentham) and **lowlevel.eu** mostly cover Pi 0/3
  and BCM2835/2837; Pi-4-specific notes in those blogs are limited to UART
  base addresses and IRQ controller changes, not EL/MMU behavior.

### Genode base-hw

Genode's bootstrap
[`spec/arm_64/crt0.s`](https://github.com/genodelabs/genode/blob/master/repos/base-hw/src/bootstrap/spec/arm_64/crt0.s)
opens with `_mmu_disable`: read `CurrentEL`, branch on EL1/EL2/EL3, clear
`SCTLR_ELx.M`, `isb`. So Genode does *not* assume any particular EL on
entry; whatever EL it lands in, it forces MMU off there before doing
anything. Boot then proceeds in C++ (`Cpu::enable_mmu`), which programs MAIR
/ TCR / TTBR and does the M-write with `dsb sy` and `isb` straddling. This is
"insurance against unknown firmware state" taken to its logical conclusion.

### NuttX

The NuttX BCM2711 port-blog
([linguini1.github.io/blog/2024/12/25/nuttx-bcm2711](https://linguini1.github.io/blog/2024/12/25/nuttx-bcm2711.html))
is a candid log of porting pain. Notable: the porter hit a fault from `ldaxr`
that ARM's docs revealed was illegal until the MMU was enabled — i.e. the
*absence* of MMU/cache breaks load-acquire/store-release semantics on A72.
This is the same class of bug Phoenix is suspected to be hitting in reverse
(SCTLR write while at EL2 leaves coherency in a bad state for the next
instruction).

### rpi-open-firmware (Christina Brooks)

Out of scope for ARM EL handling: this firmware runs on the **VC4 / VPU**
(VideoCore), the SoC's housekeeping CPU that initializes SDRAM and brings the
ARM cluster up. Its boot code is interesting for understanding what state the
ARM cores arrive in (PLLC clocked, SDRAM at 0xC0000000 uncached alias) but it
does not itself execute any AArch64 boot code. Source:
[github.com/christinaa/rpi-open-firmware](https://github.com/christinaa/rpi-open-firmware).

## 3. Synthesis — what is unanimous, what diverges

**Unanimous:**

1. *Drop to EL1 before enabling EL1's MMU.* Every project that runs an OS
   kernel at EL1 (seL4 non-hyp, FreeBSD, NetBSD, OpenBSD, Circle, Ultibo,
   NuttX, Genode, every blog) does the EL2 -> EL1 drop **before** writing
   SCTLR\_EL1.M=1. None of them program EL1 sysregs while still at EL2 and
   then "fall through". This is decisive evidence that Phoenix's silent hang
   matches the textbook EL2/EL1 mismatch failure mode.
2. *Single MSR for the M=1 flip, with ISB after.* The actual MMU enable is
   one `msr sctlr_el1, xN; isb`. No project staggers the bits across multiple
   writes (M then I then C). The variation is *which* bits are in the value
   — some include M only, some include M+C+I.
3. *MAIR / TCR / TTBR0 / TTBR1 must be live before M=1.* Every project
   programs all four before the SCTLR write.
4. *TLB invalidate before M=1.* The `dsb ishst; tlbi vmalle1is; dsb ish;
   isb` sequence is universal.
5. *SMPEN must be set before MMU/cache enable on A72.* Every project
   either sets it itself (Circle armstub, U-Boot) or relies on a stub/ATF
   that already did. A72 TRM 4.3.40 makes this mandatory.

**Divergence:**

- *Whether to disable the EL2 MMU before dropping.* FreeBSD does, citing
  HCR\_EL2.E2H risk. Most others assume firmware left EL2 MMU off. The Pi 4
  firmware does leave EL2 MMU off, but FreeBSD's defense is cheap insurance.
- *Whether to include C and I bits in the same MSR as M.* bztsrc explicitly
  doesn't (M only). Linux, FreeBSD, NetBSD, seL4 do (M+C+I together). For
  bring-up debugging, M-only is safer because it isolates the failure mode.
- *Where the drop happens.* seL4 does it in the loader (elfloader); Linux,
  FreeBSD, NetBSD, OpenBSD do it in their own `head.S`. There is no
  correctness reason to prefer one over the other — only an architectural
  taste choice about what "kernel" means.
- *Whether to run at EL2 long-term.* Only Xen does, and Xen is a hypervisor.
  No microkernel in this survey runs at EL2 in production on A72, because
  A72 lacks VHE so EL2 has no TTBR1 — kernel/user split is impractical.

## 4. Recommendations for Phoenix `_init.S`, ranked by confidence

**(R1) [highest confidence] Drop EL2 -> EL1 before any EL1 sysreg write.**
Add an explicit `CurrentEL` check at the very top of `_init.S`. If at EL2,
program `HCR_EL2.RW=1`, `SPSR_EL2 = D|A|I|F|0x5` (EL1h), `ELR_EL2 =
<continuation>`, `eret`. Do this before MAIR/TCR/TTBR programming, not after.
Five projects (seL4-loader, FreeBSD, NetBSD, OpenBSD, Circle, Genode, NuttX)
agree on this, no project disagrees. Source-of-truth: FreeBSD `enter_kernel_el`,
Circle `armv8_switch_to_el1_m`.

**(R2) [high confidence] Defensive: disable the EL2 MMU first, with `mov`-only
operands.** Following FreeBSD D34644, write `SCTLR_EL2 = SCTLR_EL2_RES1 | EIS
| EOS` using `mov_q` (no memory access between the SCTLR\_EL2 write and the
ERET). Even if VPU firmware leaves EL2 MMU off today, a future firmware bump
or a different boot path (kexec-style, U-Boot chain, …) could leave it on.

**(R3) [high confidence] Verify SMPEN is set, set it if not.** A72 TRM
requires `CPUECTLR_EL1.SMPEN = 1` before any cache or TLB maintenance op.
Either probe-and-set in `_init.S`, or document explicitly that we trust
armstub8/U-Boot to have done it. Source-of-truth: U-Boot
`armv8/start.S` `CONFIG_ARMV8_SET_SMPEN`, Circle `armstub8.S`.

**(R4) [medium confidence] First boot: enable M only, leave C and I cleared.**
Mirror bztsrc's split. If the M-only flip succeeds and we get a heartbeat
print, then a follow-up commit can OR in C and I. This isolates whether the
hang is in M-bit virt-translation activation vs C/I cache-coherency activation.
This is a *bring-up* recommendation, not a final-shape one.

**(R5) [lower confidence] Mark MMIO mappings XN.** Cortex-A72 erratum 855873
is the A53 "ll/sc deadlock under speculative execution" item; the
A72-equivalent risk is speculative *instruction* prefetch into Device-nGnRnE
regions, mitigated by setting XN/PXN in stage-1 descriptors for MMIO. We
should set XN on UART/GIC/mailbox/etc. mappings as a matter of hygiene; this
is not load-bearing for the current hang but is upstreaming-blocking later.
This claim is supported by Linux's silicon-errata page and ARM Cortex-A72 TRM
chapter on speculative behaviour rather than by a single non-Linux project's
choice.

## Sources

- [seL4 head.S](https://github.com/seL4/seL4/blob/master/src/arch/arm/64/head.S)
- [seL4 vspace.c (activate_kernel_vspace)](https://github.com/seL4/seL4/blob/master/src/arch/arm/64/kernel/vspace.c)
- [seL4 vcpu.h SCTLR_EL1 defines](https://github.com/seL4/seL4/blob/master/include/arch/arm/armv/armv8-a/64/armv/vcpu.h)
- [seL4 issue #1025: SCTLR_EL1 hyp vs non-hyp](https://github.com/seL4/seL4/issues/1025)
- [seL4 Rpi4 hardware docs](https://docs.sel4.systems/Hardware/Rpi4.html)
- [FreeBSD locore.S](https://github.com/freebsd/freebsd-src/blob/main/sys/arm64/arm64/locore.S)
- [FreeBSD D34644: arm64 disable EL2 MMU early boot](https://reviews.freebsd.org/D34644)
- [FreeBSD commit 5a08fbb315e8 announcement](https://lists.freebsd.org/archives/dev-commits-src-branches/2022-September/007051.html)
- [NetBSD aarch64 locore.S (CVS)](http://cvsweb.netbsd.org/bsdweb.cgi/src/sys/arch/aarch64/aarch64/locore.S)
- [OpenBSD arm64 locore.S](https://github.com/openbsd/src/blob/master/sys/arch/arm64/arm64/locore.S)
- [Xen ARM booting protocol](https://xenbits.xen.org/docs/unstable/misc/arm/booting.txt)
- [Circle armstub8.S](https://github.com/rsta2/circle/blob/master/boot/armstub/armstub8.S)
- [Circle startup64.S](https://github.com/rsta2/circle/blob/master/lib/startup64.S)
- [bztsrc raspi3-tutorial mmu.c](https://github.com/bztsrc/raspi3-tutorial/blob/master/10_virtualmemory/mmu.c)
- [bztsrc raspi3-tutorial start.S](https://github.com/bztsrc/raspi3-tutorial/blob/master/10_virtualmemory/start.S)
- [rpi4-osdev Part 12 (drop to EL1)](https://www.rpi4os.com/part12-wgt/)
- [Andre Leiradella, "The Raspberry Pi Stubs"](https://leiradel.github.io/2019/01/20/Raspberry-Pi-Stubs.html)
- [Genode base-hw arm_64 crt0.s](https://github.com/genodelabs/genode/blob/master/repos/base-hw/src/bootstrap/spec/arm_64/crt0.s)
- [Genode "Exploring the ARMv8 system level"](https://genodians.org/skalk/2019-06-18-arm64-kernel)
- [Genode "Pi 4 booting"](https://genodians.org/tomga/2019-07-07-rpi-booting)
- [NuttX BCM2711 port writeup](https://linguini1.github.io/blog/2024/12/25/nuttx-bcm2711.html)
- [NuttX BCM2711 docs](https://nuttx.apache.org/docs/latest/guides/porting-case-studies/bcm2711-rpi4b.html)
- [rpi-open-firmware](https://github.com/christinaa/rpi-open-firmware)
- [U-Boot armv8/start.S (SMPEN)](https://github.com/u-boot/u-boot/blob/master/arch/arm/cpu/armv8/start.S)
- [Linux ARM64 silicon errata reference](https://docs.kernel.org/arch/arm64/silicon-errata.html)
- [ARM Cortex-A72 TRM r0p3 (Stanford mirror)](https://www.scs.stanford.edu/~zyedidia/docs/arm/cortex_a72.pdf)
