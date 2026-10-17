# NetBSD aarch64 RPi 4 Boot Path — Deep Dive

Round-3 deep research focused on **NetBSD's** aarch64 boot path on the
Raspberry Pi 4 / BCM2711, intentionally avoiding Linux as a comparison
point. NetBSD's aarch64 port is a clean-room implementation by Ryo
Shimizu, Tohru Nishimura, Nick Hudson, Jared McNeill ("jmcneill"), and
Matt Thomas; the recent maintenance is dominated by Nick Hudson
("skrll"). It is therefore a useful second opinion against FreeBSD,
U-Boot, and TF-A, especially because NetBSD shares no code with Linux
at any level of the boot path.

All file paths refer to NetBSD-current as of revision 1.103 of
`locore.S` (`$NetBSD: locore.S,v 1.103 2026/04/03 07:15:03 skrll Exp $`).
GitHub mirror used for line numbers:
`github.com/NetBSD/src` branch `trunk`.

---

## 1. Where the kernel enters: image format & EL state at entry

NetBSD/evbarm-aarch64 supports two boot fronts on the Pi 4:

* **TF-A + U-Boot + UEFI** (the production path on RPi 4): Trusted
  Firmware-A's `bl31.bin` is loaded as `armstub8.bin` via a
  `armstub=bl31.bin` line in `config.txt`. BL31 returns to U-Boot at
  EL2, U-Boot runs the EFI loader (`bootaa64.efi`), the loader passes
  the FDT pointer in `x0` and jumps to the kernel `_start` at EL2 with
  caches and MMU disabled. This is the path the RPi 4 image (e.g.
  `2023-12-05-netbsd-raspi-aarch64.img`) ships.
* **Direct armstub mode** (RPi 3 legacy path): the firmware loads
  `kernel8.img` directly, `armstub8.bin` drops it at EL2 with the FDT
  in `x0`. NetBSD-10 still supports this path for RPi 3 but the wiki
  recommends UEFI for RPi 4.

Either way the kernel sees: caches off, MMU off, EL2, FDT pointer in
`x0`.

Source: NetBSD wiki `ports/evbarm/raspberry_pi/`, NetBSD-10 release
notes, Trusted Firmware-A `plat/rpi4` documentation.

---

## 2. EL transitions on Pi 4 entry

The very first instructions of NetBSD's `aarch64_start`
(`sys/arch/aarch64/aarch64/locore.S` lines 103–111) test current EL:

```
mrs    x20, CurrentEL
lsr    x20, x20, #2
cmp    x20, #2
bcc    1f                     // already at EL1, skip drop
```

If `CurrentEL >= EL2` it falls into the `#include
"locore_el2.S"` block (line 111), which does the drop. Inside
`locore_el2.S`:

* Line 99: `mov x2, #(HCR_RW)` — only the `RW` bit is set in
  `HCR_EL2`; no virtualisation, no SError routing, no GIC trapping
  changes are layered on top.
* Lines 110–114: the SCTLR_EL1 baseline is asserted — see §3.
* Line 117: `CPACR_EL1` enables FP/SIMD access for EL1.
* Lines 135–145: `ICC_SRE_EL2` is set if `ID_AA64PFR0_EL1.GIC` is
  non-zero, enabling GICv3 system-register access. (Cosmetic on RPi 4
  which uses the BCM2836 legacy interrupt controller, but harmless.)
* Line 147: `mov x2, #(SPSR_F | SPSR_I | SPSR_A | SPSR_A64_D |
  SPSR_M_EL1H)` — masks DAIF and selects EL1h with SP_EL1.
* Line 150: `msr elr_el2, lr` — return address is the link register
  (i.e. the post-include path in `locore.S`).
* Line ~152: `eret`.

Notably **no Cortex-A72 errata workaround** is applied at EL2. NetBSD
does not touch CPUACTLR_EL1, CPUECTLR_EL1, or any other implementation
defined register on Cortex-A72 in this file. It also does not apply
the Linux-style "secondary boot" SError unmask trick.

For secondary CPUs (`cpu_mpstart`, line 573 of `locore.S`) the same
EL detection runs, with an explicit `drop_to_el1` invocation around
line 527.

---

## 3. Initial SCTLR_EL1 baseline

This is the most important answer for Phoenix's debugging. NetBSD
applies the SCTLR_EL1 baseline twice — once unconditionally before
`eret` to EL1 (in `locore_el2.S`), and once again as the value the
later `mmu_enable` writes back.

`armreg.h` defines:

* `SCTLR_RES1 = 0x30d00800` — i.e. bits 30, 28, 23, 22, 20, 11 set.
* `SCTLR_RES0 = 0xc8222400` — i.e. bits 31, 27, 21, 17, 13, 10 cleared.

The `locore_el2.S` sequence at line 110:

```
ldr   x2, .Lsctlr_res1       // .quad SCTLR_RES1 (=0x30d00800)
mrs   x1, sctlr_el1
and   x1, x1, #(SCTLR_EE | SCTLR_E0E)   // preserve endianness only
orr   x2, x2, x1
msr   sctlr_el1, x2
```

So at the moment of `eret`, SCTLR_EL1 is exactly `0x30d00800` (plus
the inherited big-endian bits, which are zero on RPi 4). MMU off,
D-cache off, I-cache off, alignment off, WXN off, SED on (UAL),
ITD off, CP15BEN off — a deliberately minimal value. The RES1 bits
that A72 actually requires (bits 11, 20, 22, 23, 28, 29) are all set;
bit 30 (set in RES1 here) is RES1 in ARMv8.0-A and matches the A72
TRM.

Bit 8 (`SCTLR_SED`) is not in `SCTLR_RES1`, but no AArch32
compatibility is exercised, so this is irrelevant on RPi 4.

This **differs from FreeBSD's locore** (`sys/arm64/arm64/locore.S`
line 245), which uses a named constant `SCTLR_MMU_OFF` containing
both RES1 bits *and* explicitly cleared M/C/I bits. Functionally
equivalent, but FreeBSD makes the cleared bits visible in the source.

---

## 4. Cache & MMU enable sequence

The dedicated function is `mmu_enable` at lines 973–1001 of
`locore.S`. The order is:

```
983:   ldr   x0, mair_setting     // .quad MAIR_NORMAL_WB(attr0) |
                                  //       MAIR_NORMAL_NC(attr1) |
                                  //       MAIR_NORMAL_WT(attr2) |
                                  //       MAIR_DEVICE_MEM(attr3) |
                                  //       MAIR_DEVICE_MEM_NP(attr4)
984:   msr   mair_el1, x0
985:   isb
986:   ldr   x0, tcr_setting      // T0SZ/T1SZ from VIRT_BIT,
                                  // TG0=4KB, TG1=4KB, AS=64K,
                                  // ORGN/IRGN = WB-WA inner & outer,
                                  // TCR_SHAREABLE (inner-shareable)
987:   mrs   x1, id_aa64mmfr0_el1
988:   bfi   x0, x1, #32, #3      // splice IPS into TCR.IPS
989:   msr   tcr_el1, x0
990:   isb
                                  // (TTBR0/TTBR1 written earlier by
                                  //  init_mmutable, line ~1005)

979:   dsb   sy                   // pre-barrier
981:   dsb   ishst                // store-side IS barrier
985:   tlbi  vmalle1is            // invalidate stage-1 EL1 TLB IS
987:   dsb   ish
989:   isb

991:   mrs   x0, sctlr_el1
992:   ldr   x1, sctlr_clear      // bits to clear
993:   bic   x0, x0, x1
994:   ldr   x1, sctlr_pac        // PAC enable bits, if available
995:   bic   x0, x0, x1
996:   ldr   x1, sctlr_set        // M | C | I | (UCT/UCI/SPAN/...)
997:   orr   x0, x0, x1
998:   msr   sctlr_el1, x0
1000:  isb
```

Critical observations for Phoenix-RTOS:

1. **MAIR is programmed before TCR**, with an explicit `isb`
   between them. NetBSD does not rely on a single barrier-and-pray
   pattern.
2. **TLB invalidation precedes MMU enable** with a `dsb ishst /
   tlbi vmalle1is / dsb ish / isb` quartet. Even though the TLB
   should be empty at cold reset, NetBSD always does this — it makes
   the secondary-CPU path (CPUs that have been running ATF or U-Boot
   code) safe.
3. **Inner-shareable (`ish`/`ishst`) variants** are used throughout,
   matching `TCR_SHAREABLE`. On the Pi 4 the BCM2711 cluster of four
   A72s lives in one inner-shareable domain; outer-shareable variants
   (`osh`) would be wrong because the VideoCore is not a coherent
   master.
4. The final `isb` at line 1000 is what makes the MMU enable
   architecturally observable to the immediately following fetched
   instructions. NetBSD does *not* try to relocate the PC across this
   boundary in the same function — the call site (`init_mmutable` at
   ~line 1000–1080) returns through a virtual address that was set up
   in advance.

The full sequence cleanly maps to the Arm ARM C5.2.2 "Boot code
example" pattern. It's the single most-cited reference template I've
seen in cleanly written aarch64 ports.

---

## 5. Set/way invalidation of L1 caches at locore start

**NetBSD does not perform set/way cache invalidation at locore
start.** I grepped the entire `locore.S`, `locore_el2.S`, and
`cpufunc_asm_armv8.S` and there are no `dc isw`, `dc cisw`, `dc csw`
instructions in the early-boot path. The only set/way operations live
in `cpu_dcache_wbinv_all` and friends, used in `dumpsys()` and CPU
suspend, never at boot.

Justification (paraphrasing comments and the Arm ARM): set/way ops
are not broadcast, not architecturally guaranteed to flush the system
cache hierarchy, and the architecture explicitly says boot software
should rely on cache-line invalidation by VA *after* MMU enable, or
trust the firmware to have left caches in a sane state. NetBSD's
position is the latter — it trusts BL31 / ATF / U-Boot to deliver a
clean cache state.

This is the same conclusion FreeBSD reaches in
`sys/arm64/arm64/locore.S` (line 87 comment: "D-Cache: off"); the
boot software contract is "MMU off, D-cache off, I-cache state
indeterminate but no dirty data targetting kernel image".

---

## 6. Page-table cache maintenance

`sys/arch/aarch64/aarch64/pmapboot.c::pmapboot_enter()` is the only
PTE-writing path before the runtime pmap is up. Its cache-maintenance
discipline is **minimal**:

* Per-entry: nothing. Page-table descriptors are written with plain
  `str` and rely on inner-shareable, write-back, write-allocate
  attributes for both TTBR0 and TTBR1 (`TCR_IRGN0_WB_WA |
  TCR_ORGN0_WB_WA | TCR_IRGN1_WB_WA | TCR_ORGN1_WB_WA |
  TCR_SHAREABLE`).
* End of the operation: a single `dsb(ish)`.
* No `dc cvac` or `dc civac` on the page tables.

This is **only safe because the kernel image and its initial page
tables are mapped via the same Normal-WB-WA-Inner-Shareable
attributes that the table-walker uses**. The architectural rule
(ARM ARM D5.10.2) is: if all observers (here, the EL1 store path and
the table-walker) use the same shareable+cacheable attributes, no
explicit clean-to-PoC is needed; coherency is in the inner
shareable domain.

This is precisely the trap Phoenix-RTOS keeps falling into (see
`docs/TEMPORARY-FIXES-AND-FUTURE-CLEANUP.md` TD-04): if kernel data
ends up in a non-cacheable or device mapping, or if the table-walker
attributes don't match the data-side attributes, the missing `dc
cvac` becomes load-bearing. NetBSD avoids the trap by construction —
it never has a non-coherent page-table writer.

For the FDT and bootargs (lines ~1051 of `init_mmutable`), the same
Normal-WB-WA mapping is used. There is no explicit cache-flush of the
FDT in `aarch64_machdep.c` or `fdt_machdep.c`; the
boot-loader-to-kernel handoff inherits coherence from the firmware
(BL31 / U-Boot run with caches enabled and inner-shareable attrs).

---

## 7. Boot information handoff (NetBSD's syspage equivalent)

NetBSD has no monolithic `syspage`. The handoff is split:

* **FDT pointer**: a global `const uint8_t *fdt_addr_r` (declared
  with `__attribute__((__section__(".data")))` to survive BSS clear)
  is populated from `x0` in the early boot trampoline, then
  immediately copied into a kernel-owned buffer via `fdt_open_into()`
  inside `initarm()` (`sys/arch/evbarm/fdt/fdt_machdep.c`).
* **u-boot legacy register file**: a 4-word `u_long uboot_args[4]` is
  preserved across BSS clear, in case a non-EFI U-Boot path supplies
  arguments through `x0..x3`.
* **EFI memory map / system table**: passed via the EFI image
  protocol when booting through `bootaa64.efi`, captured during
  `efi_boot()` and converted into NetBSD's bootinfo.

Cache-coherency mechanism: none, by design. The FDT lives in DRAM
that the firmware mapped Normal-WB-WA-Inner-Shareable; the kernel
maps it the same way; no cache maintenance is required. The kernel
*relocates* the FDT into a kernel buffer (`fdt_data`) defensively,
which incidentally also handles the case of the original FDT
straddling a non-cacheable region.

The contrast with Phoenix's syspage matters: Phoenix's syspage is
written by `plo` with a particular cache attribute and then read by
the kernel before the kernel's MMU is up. If the two attributes
disagree, you need an explicit `dc civac` over the syspage between
the writer and the reader. NetBSD sidesteps the question by only
ever reading the FDT *after* the kernel MMU is up and the FDT is
mapped with the same attributes as the firmware used.

---

## 8. Cortex-A72 errata

Searched: `cpu.c`, `cpufunc.c`, `cpufunc_asm_armv8.S`,
`aarch64_machdep.c`. Findings:

* `cpu.c` recognises `CPU_ID_CORTEXA72R0` purely for cosmetic ID
  printing ("Arm Cortex-A72 r%dp%d (v8-A)"). There is no errata
  entry, no quirk bit set in the cpu structure.
* `cpufunc_asm_armv8.S` has no Cortex-A72 conditional code. The only
  CPU-specific override visible is `CPU_THUNDERX`'s
  `aarch64_set_ttbr0_thunderx` (Cavium ThunderX erratum 27456,
  emits `ic iallu / dsb nsh` after TTBR0 write).
* No A72 `CPUACTLR_EL1` or `CPUECTLR_EL1` writes. NetBSD does not
  touch the implementation-defined "L2 control" / "L2 prefetch" bits
  that Linux occasionally pokes.

Practically, this means **NetBSD trusts ATF/BL31 to apply A72-class
errata** at EL3 before dropping to EL2. ATF's `lib/cpus/aarch64/
cortex_a72.S` is the canonical workaround set (806969, 855423,
859971, the spectre v2 hardening, etc.) and is applied at every CPU
power-on by the PSCI implementation. RPi 4's `armstub` ships with
ATF, so the kernel inherits a "errata-clean" CPU.

For Phoenix on RPi 4: if you boot through TF-A this is also true. If
you boot directly from `start4.elf` via `armstub8.bin` without ATF,
*nothing* applies A72 errata, and you may need to handle them
yourself — but the publicly-documented A72 errata are mostly latency
and prefetch issues, not correctness bugs in the boot path.

---

## 9. Comparison to FreeBSD

Both ports converge to "MAIR, TCR, TTBR, then SCTLR with M+C+I, with
ISBs between" — the Arm-ARM template. Divergences:

| Aspect | NetBSD | FreeBSD |
|---|---|---|
| Initial SCTLR_EL1 explicit value | `SCTLR_RES1 = 0x30d00800` only | `SCTLR_MMU_OFF` literal w/ M=C=I=0 |
| EL2 → EL1 | Conditional, included from `locore_el2.S` line 111 | Inline at locore line ~245 |
| HCR_EL2 | `HCR_RW` only | `HCR_RW` plus tweaks for SMC/HVC trapping |
| Pre-MMU TLB invalidate | Always (`tlbi vmalle1is`) | Always (`tlbi vmalle1`) |
| Set/way at start | Never | Never |
| Page-table flush | None (relies on cacheable IS) | None (same) |
| GICv3 SRE setup | At EL2 (`ICC_SRE_EL2`) | At EL2 |
| FDT handoff | `x0` → `fdt_addr_r`, copied via `fdt_open_into` | `x0` → `modulep`, decoded later |
| A72 errata | None applied | None applied (also relies on ATF) |
| Initial pmap | `pmapboot_enter` C function | `pmap_bootstrap` C function |

The most important shared architectural decision is **inner-shareable
WB-WA for both data and table-walker, no per-entry cache maintenance
required**. Both ports are correct because they enforce that
invariant; Phoenix-RTOS's TD-04 problem is the symptom of *not*
enforcing it.

---

## 10. Notable commits

From the GitHub commit log of `sys/arch/aarch64/aarch64/locore.S`
(branch trunk):

* **2026-04-03 `5bd8d27` (skrll)** "Set SCTLR_EL0.EOS on CPUs with
  FEAT_ExS" — relevant to exception-synchronization semantics on
  newer cores; not A72.
* **2026-04-02 `5b6e71a` (skrll)** "Fix the comment against
  SCTLR.nAA".
* **2026-04-02 `0d8792b` (skrll)** "Print some more EL2 system
  registers in DEBUG_LOCORE".
* **2025-01-31 `7e5fb63` (skrll)** "CNTKCTL_EL1 init" — fixes
  generic-timer access from EL0.
* **2025-01-30 `46e7c23` (skrll)** "Fix CNTKCTL_EL1 initialization".
* **2023-02-23 `816fa77` (skrll)** "Add missing barriers in
  cpu_switchto" — barrier fix in context-switch, not boot, but
  representative of the project's correctness focus.
* **2021-05-01 (NetBSD source-changes mailing list)** "SCTLR_EnIA
  should be enabled in the caller(s) ..." — split point for
  pointer-authentication enablement.

For RPi 4 / BCM2711 specifically, none of `locore.S`'s recent
commits are platform-specific. The A72-relevant work happens in
`sys/arch/evbarm/fdt/` and `sys/arch/arm/broadcom/`. Notable RPi 4
commits visible on the mailing-list archive (`mail-index.netbsd.org`):

* 2020-08 — first stable RPi 4 image (`2020-08-22-netbsd-raspi-
  aarch64.img.gz`); jmcneill announces UEFI boot working, USB and
  HDMI functional.
* 2023-12 — `2023-12-05-netbsd-raspi-aarch64.img` mailing-list post
  with NetBSD-10 release-quality status.
* 2024-04-15 mail "ARM Cortex-A72 slow multiply (MADD) instruction
  execution" on `port-arm` — discusses A72 performance peculiarity,
  no kernel change resulted.

The deeper point: NetBSD's RPi 4 enablement is **mostly device-tree
driver work** (`bcm2838pcie`, `bcm2838rng`, `bcm2711_pcie`), not
locore-level cache or MMU fixes. The aarch64 boot core has not
needed RPi-4-specific patches — strong evidence that a clean,
firmware-trusting boot template handles the BCM2711 without special
care.

---

## Bottom-line takeaways for Phoenix-RTOS Pi 4

1. NetBSD's SCTLR_EL1 baseline at EL1 entry is **exactly**
   `SCTLR_RES1 = 0x30d00800` (plus inherited `SCTLR_EE`/`SCTLR_E0E`
   if big-endian). All other bits are 0 until `mmu_enable`.
2. The MMU enable is `MAIR; isb; TCR (with IPS spliced from
   ID_AA64MMFR0_EL1); isb; TLB IS invalidate; isb; SCTLR with
   M+C+I; isb`. Use this exact ordering.
3. **Do not** issue set/way invalidation at boot. It's not portable
   and not required if you trust your firmware.
4. **Make page-table memory and kernel data share the same
   Normal-WB-WA-Inner-Shareable attributes** as the table-walker
   (`TCR.{IRGN,ORGN}* = WB-WA`, `TCR.SHARED = inner`). Then no
   `dc cvac` on PTEs is needed. This is the architectural property
   Phoenix's TD-04 hack is approximating manually.
5. **Trust the firmware (TF-A) to apply A72 errata** at EL3. Do not
   replicate them at EL1 unless you boot without ATF.
6. The boot-info handoff should be **read-after-MMU-enable** with the
   same cache attributes the firmware used. Relocate the FDT into a
   kernel-owned buffer with `fdt_open_into()`-style logic to free up
   firmware memory and to dodge any straddling-region edge cases.

---

## Primary sources

* NetBSD `sys/arch/aarch64/aarch64/locore.S` rev 1.103, GitHub mirror
  branch `trunk`, lines 103–111 (EL detect), 573 (`cpu_mpstart`),
  973–1001 (`mmu_enable`), 1000–1083 (`init_mmutable`,
  `mair_setting`, `tcr_setting`).
* NetBSD `sys/arch/aarch64/aarch64/locore_el2.S` lines 99 (HCR_EL2),
  110 (SCTLR_EL1 RES1), 117 (CPACR_EL1), 135–145 (GICv3 SRE), 147
  (SPSR_EL2), 150 (ELR_EL2), `.Lsctlr_res1` literal pool.
* NetBSD `sys/arch/aarch64/include/armreg.h` —
  `SCTLR_RES1 = 0x30d00800`, `SCTLR_RES0 = 0xc8222400`, MAIR
  encodings (`MAIR_DEVICE_nGnRnE = 0x00`, `MAIR_DEVICE_nGnRE = 0x04`,
  `MAIR_NORMAL_NC = 0x44`, `MAIR_NORMAL_WT = 0xbb`,
  `MAIR_NORMAL_WB = 0xff`).
* NetBSD `sys/arch/aarch64/aarch64/pmapboot.c` —
  `pmapboot_enter()`, single trailing `dsb(ish)`.
* NetBSD `sys/arch/aarch64/aarch64/cpufunc_asm_armv8.S` —
  `aarch64_dcache_wb_range`, `aarch64_dcache_wbinv_range`,
  `aarch64_dcache_inv_range`, `aarch64_idcache_wbinv_range`,
  `aarch64_icache_sync_range`, `aarch64_icache_inv_all`,
  `aarch64_set_ttbr0_thunderx` (Cavium-only quirk).
* NetBSD `sys/arch/aarch64/aarch64/cpu.c` — `CPU_ID_CORTEXA72R0`
  match string only, no errata.
* NetBSD `sys/arch/evbarm/fdt/fdt_machdep.c` — `fdt_addr_r`,
  `fdt_open_into`, `fdt_get_bootargs`, `uboot_args[4]`.
* NetBSD `sys/arch/aarch64/aarch64/aarch64_machdep.c` —
  `initarm_common`, `cpu_dcache_wbinv_all` (called only in
  `dumpsys`).
* NetBSD wiki `ports/evbarm/raspberry_pi/`,
  `ports/aarch64/`, `users/leot/aarch64_problems/`.
* NetBSD source-changes hg / cvsweb logs:
  `mail-index.netbsd.org/source-changes-hg/2021/05/01/msg296138.html`
  (SCTLR_EnIA), recent skrll commits 2025–2026.
* Trusted Firmware-A `lib/cpus/aarch64/cortex_a72.S` — the actual
  A72 errata workaround set NetBSD relies on at EL3.
* FreeBSD `sys/arm64/arm64/locore.S` (line 87 comment, 245
  `SCTLR_MMU_OFF`) for cross-port comparison.
