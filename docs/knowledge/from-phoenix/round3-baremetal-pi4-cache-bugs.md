# Round 3: Bare-Metal Pi 4 / Cortex-A72 Cache-Enable Bugs in the Wild

Scope: synthesise what other bare-metal Pi 4 projects have hit when flipping
SCTLR_EL1.M / .C / .I and how they recovered. Where a forum thread, repo, or
errata document directly answers one of our questions, the URL is cited inline
so the underlying primary source can be re-read.

## 1. Where bare-metal devs got hung at the SCTLR.M flip — most common fix

Across every "MMU enable hangs the Pi 4" thread we surveyed, the dominant root
cause is **not** an architecturally subtle cache bug; it is a page-table
content / mapping mistake that only manifests once translation begins. The
Raspberry Pi forum thread "AArch64 MMU setup: crashes on enable despite
correct mappings" (https://forums.raspberrypi.com/viewtopic.php?t=384228) is
the canonical example: the code looks fine, the tables look fine, and the
core dies as soon as `msr sctlr_el1, x0` retires. The cluster of solutions
across that thread plus the older "Aarch64 RPi3 - MMU issue"
(https://www.raspberrypi.org/forums/viewtopic.php?t=255430) and "How to turn
on the MMU of RPi 4" (https://forums.raspberrypi.com/viewtopic.php?t=262772)
threads can be summarised as four invariants that *every* successful
bring-up satisfies:

1. **The block of code containing the SCTLR write must be identity-mapped**,
   so the post-MMU instruction fetch resolves the same physical address as
   the pre-MMU one. LdB-ECM and several others reiterate this:
   "the new MMU scheme and the old one MUST map the instructions being
   executed on the same address."
2. **Reserved (RES1) bits in SCTLR_EL1 must be set.** Bits 29, 28, 23, 22,
   20, 11 are RES1 in EL1; clearing them is undefined and on A72 typically
   manifests as an immediate hang. The Raspberry Pi forum thread "Check a
   specific bit in SCTLR_EL1 Register on Rasperry pi 4"
   (https://forums.raspberrypi.com/viewtopic.php?t=280192) reports a real
   measured baseline of `0x0000000034d5d83d` on Pi 4 once the kernel has
   booted, which lines up with the Linux reset value
   `0x30d50800 | 0x0800` for little-endian.
3. **Descriptor encoding errors** — bits above the supported PA range left
   non-zero, AF/SH/AP fields wrong, or output addresses unaligned to the
   level granule — make the table walker fault on the very first fetch.
   The same forum threads call this out repeatedly: "the MMU may find
   descriptors with bits 47:xxxx not zeroed out".
4. **Peripheral ranges left as Normal-cacheable**, which both miscaches MMIO
   and (because BCM2711 MMIO does not respond to cacheable transactions in
   a way the core expects) hangs on the first peripheral access after the
   SCTLR flip. "Peripherals like UART and GPIO should be mapped to the
   same virtual=physical address but with the data cache turned off"
   (the high-peri thread,
   https://forums.raspberrypi.com/viewtopic.php?t=322157).

In short: when other people's Pi 4 hangs at the SCTLR.M flip, the fix is
almost never a cache-maintenance op — it is fixing a table or a SCTLR
constant.

## 2. "Reaches marker X, then exception/hang on M+I or M+C+I"

This pattern is documented most cleanly in OP-TEE issue #5403, "aarch64 MMU
setup sequence" (https://github.com/OP-TEE/optee_os/issues/5403). The
reporter (porting OP-TEE to Neoverse-N1, same MMU programming model as
A72) noted three concrete hazards that each trigger a hang on the M+I+C
flip:

- D-cache cleaned/invalidated *before* page tables and code/data are at
  their final physical locations, so the lines that the table walker
  fetches after MMU-enable are stale.
- VBAR_EL1 set to a virtual address whose translation is only valid after
  enable, with relocation in between — a nested fault during the first
  exception is unrecoverable.
- SCTLR_EL1.I set early but the I-cache only invalidated *after* MMU
  enable, so prefetch buffers can hold pre-MMU instructions tagged with
  the wrong attributes.

The OP-TEE thread settles on the architecturally clean ordering: invalidate
I-cache *before* setting SCTLR.I, clean+invalidate D-cache by VA over the
page-table region *after* the tables are at their final location, then
`dsb ish; isb`, then write SCTLR with M|C|I in one MSR.

The same pattern shows up in the Raspberry Pi Forums "Raspberry Pi MMU
Debugging" thread (https://forums.raspberrypi.com/viewtopic.php?t=331894)
and "RPi 4B - MMU config with high-peri profile"
(https://forums.raspberrypi.com/viewtopic.php?t=322157), where MMU works
with caches off and dies with caches on.

## 3. L1 D-cache invalidation by set/way at boot

ARMv8-A is explicit that hardware automatically invalidates the L1 caches
out of reset, so software set/way invalidation is not architecturally
required at cold boot. ARM's "Bare-metal Boot Code for ARMv8-A
Processors" application note
(http://classweb.ece.umd.edu/enee447.S2019/baremetal_boot_code_for_ARMv8_A_processors.pdf)
states this directly and shows the *power-down* path as the place
set/way ops are needed.

Despite that, several projects do issue a set/way clean+invalidate loop in
the boot path defensively, because their entry conditions are not "from
reset" — they enter from VC firmware, from `armstub8.bin`, or after
`hexdump`-style debug code that may have left dirty lines. Examples:

- **Circle** (https://github.com/rsta2/circle/blob/master/lib/memory.cpp)
  runs `InvalidateDataCacheL1Only()` (or full `InvalidateDataCache()`)
  followed by `InvalidateInstructionCache()` and a branch-target flush
  before touching the page tables.
- **Trusted Firmware-A**'s `cortex_a72.S`
  (https://github.com/ARM-software/arm-trusted-firmware/blob/master/lib/cpus/aarch64/cortex_a72.S)
  performs an L1 + L2 invalidate by set/way as part of its A72 reset
  handler.
- **LdB-ECM's SmartStart64.S**
  (https://github.com/LdB-ECM/Raspberry-Pi/blob/master/10_virtualmemory/SmartStart64.S)
  runs the same set/way loop before enabling the MMU on Pi 3/4 in EL2.

Consensus: explicit set/way invalidation is not strictly mandated on a
clean reset, but it is defensive practice when the entry preconditions are
not tightly controlled. It should run *before* page-table writes are
issued, otherwise a clean-and-invalidate can write back a stale line over
the freshly-stored descriptors.

## 4. Page-table cache maintenance — concrete examples

`dc cvac` / `dc civac` over the page-table region, paired with `dsb ish`,
is the architectural recipe for "make sure the table walker sees what I
just wrote". Concrete bare-metal Pi 4 examples we found:

- **Circle**'s `lib/memory.cpp` (link above) flushes the table region with
  `dc civac` then issues `dsb ish; tlbi vmalle1; dsb ish; isb` before the
  SCTLR write.
- The OSDev thread "[SOLVED] Help With Arm64 MMU Setup"
  (https://forum.osdev.org/viewtopic.php?p=350137) shows a
  walker-pinning version: `dc cvac` over each table, `dsb ish`, then
  enable. Forum reply confirms this is what unblocked their hang.
- **rust-raspberrypi-OS-tutorials** — the higher-half tutorial
  (https://github.com/rust-embedded/rust-raspberrypi-OS-tutorials/tree/master/16_virtual_mem_part4_higher_half_kernel)
  does the cache maintenance inside `enable_mmu_and_caching`, calling
  pre-computed table flushes before TTBR0/TTBR1 are loaded.

The reason this is critical on Pi 4 specifically: the BCM2711 has no
hardware cache coherency for non-CPU masters and the core may have
prefetched the page-table region into cache *before* the table was
written — this is mentioned in the PCIe DMA threads
(https://forums.raspberrypi.com/viewtopic.php?t=335399) as the same
underlying behaviour. The architectural sequence is:

```
str   x_descriptor, [x_pt_entry]
dc    cvac, x_pt_entry
dsb   ish
tlbi  vmalle1
dsb   ish
isb
```

## 5. A72 erratum 859971 — bare-metal handling

Erratum 859971 affects A72 r0p0–r0p3 (the BCM2711 stepping). The
workaround is a single bit in `CPUACTLR_EL1`, the
`CORTEX_A72_CPUACTLR_EL1_DIS_INSTR_PREFETCH` bit, which disables the
problematic instruction prefetcher. ARM Trusted Firmware applies it in
its A72 reset handler at EL3:
https://github.com/ARM-software/arm-trusted-firmware/blob/master/lib/cpus/aarch64/cortex_a72.S
guarded by `ERRATA_A72_859971` (built in for the Pi 4 platform target,
https://github.com/ARM-software/arm-trusted-firmware/blob/master/plat/rpi/rpi4/platform.mk).

**Important constraint for bare-metal that does not run TF-A**:
`CPUACTLR_EL1` is only writable from EL3. If the kernel is launched at
EL2 by the GPU + `armstub8` (the default Pi 4 path,
https://github.com/raspberrypi/tools/blob/master/armstubs/armstub8.S),
the workaround **cannot** be applied unless either (a) you replace the
armstub with a TF-A image (the rpi4 TF-A platform exists for exactly
this:
https://trustedfirmware-a.readthedocs.io/en/latest/plat/rpi4.html), or
(b) you ship your own EL3 stub that sets the bit before dropping. Most
bare-metal projects do not — they accept residual erratum risk because
the failure mode is rare instruction-prefetch corruption, not a hang at
the SCTLR flip.

## 6. TLB invalidation timing — best-practice consensus

Across the OSDev thread "How to invalidate TLB on ARMv8?"
(https://forum.osdev.org/viewtopic.php?t=36412), the rust-pi-os
tutorials, Circle, and the OP-TEE discussion, the agreed-upon pre-MMU
sequence is:

```
dsb   ishst             ; ensure table stores are visible
tlbi  vmalle1           ; invalidate stage-1 EL1 TLB
dsb   ish               ; wait for invalidation to complete
isb                     ; context-synchronise
msr   sctlr_el1, x_new  ; M|C|I (and RES1 bits)
isb                     ; serialise so the next fetch is post-MMU
```

The `dsb ish` (inner-shareable) scope is enough on a single-cluster A72;
`dsb sy` is over-conservative but harmless. The ISB *after* the SCTLR
write is the one most often missed in broken code — without it, a
prefetched instruction may execute under the new translation but with
the old attributes.

## 7. SCTLR_EL1 baseline values used by other projects

Concrete values in active use:

- **Linux arm64 head.S**: `(SCTLR_EL1_SET & ~SCTLR_EL1_DSSBS)` resolves
  to `0x34d50838` (M=0, C=0, I=0) at `__cpu_setup`, then OR's M|C|I as
  the last step. The RES1 mask is `0x30d00800`.
- **Pi 4 measured (Linux, post-boot)**: `0x0000000034d5d83d` from the
  forum thread cited above — RES1 bits set, EE=0, WXN=1, SA=1, M|C|I=1.
- **rpi4-osdev** (https://www.rpi4os.com/): minimal value
  `(1<<0)|(1<<2)|(1<<12)` plus ARM-defined RES1 bits; the tutorial
  hard-codes the constant.
- **Circle** (Pi 4 path): writes through `MMU_MODE` defined in
  `sysconfig.h` which composes M|C|I|Z (branch prediction).
- **Trusted Firmware-A**: leaves caches/MMU off in EL3, sets RES1 only.

The dispersion is small: every working Pi 4 baseline has the six RES1
bits set, the EE bit reflects endianness, and exactly the M|C|I trio is
the variable. There is no consensus around setting WXN, UCI, UCT, SED,
ITD on first enable — those are policy bits set later.

## 8. A72 cache topology gotchas

A72 has split L1 I (48 KiB, 3-way) / L1 D (32 KiB, 2-way) and a unified
L2 (1 MiB on BCM2711). Two practical gotchas that bite bare-metal Pi 4
code:

- **L2 set/way clean from EL1 doesn't reach the SCU**: on the Pi 4 the
  L2 is shared across the cluster and certain set/way ops behave as the
  architecture allows (broadcast or local), and the architecture
  *deprecates* set/way from non-secure EL1 for coherence purposes.
  Bare-metal code that "flushes L2 by set/way" before DMA setup is
  technically wrong; clean+invalidate by VA to PoC is the architected
  path. The Pi forum PCIe-DMA thread
  (https://forums.raspberrypi.com/viewtopic.php?t=335399) reports
  exactly this: per-VA partial maintenance lost races with speculative
  refill, and only a global set/way clean (technically deprecated)
  cleared the problem reliably.
- **L2RSTDISABLE**: per the A72 TRM
  (https://www.scs.stanford.edu/~zyedidia/docs/arm/cortex_a72.pdf) the
  L2 RAM is invalidated at reset only when `L2RSTDISABLE` is tied LOW.
  On BCM2711 this is the default, but warm resets through `armstub8`
  do *not* re-trigger this. Re-entering kernel via SMC/HVC return paths
  is therefore not equivalent to a cold reset for L2 state.

## 9. Specific bug reports / fixes — direct links

- ARM-TF A72 erratum 859971 workaround: file
  `lib/cpus/aarch64/cortex_a72.S` in
  https://github.com/ARM-software/arm-trusted-firmware/blob/master/lib/cpus/aarch64/cortex_a72.S
  — sets `CPUACTLR_EL1[bit 32]` (DIS_INSTR_PREFETCH).
- bztsrc/raspi3-tutorial issue #27, "Virtual Memory example deeply
  flawed" (https://github.com/bztsrc/raspi3-tutorial/issues/27) —
  documents that the original tutorial's TCR_EL1 / MAIR_EL1 / TTBR
  setup will hang on Pi 4 and proposes a corrected flow with proper
  `dsb ish; tlbi; isb` ordering.
- LdB-ECM's `10_virtualmemory/mmu.c`
  (https://github.com/LdB-ECM/Raspberry-Pi/blob/master/10_virtualmemory/mmu.c)
  — a working AArch64 MMU bring-up that reuses 4 KiB granule, identity
  + high-half, with cache maintenance interleaved correctly.
- Pi 4 high-peri thread, post-by-post resolution
  (https://forums.raspberrypi.com/viewtopic.php?t=322157) — the
  problem was the peripheral window not being mapped at the new
  high-peri base; once the table covered the new window with Device
  attributes, MMU+cache enable stopped hanging.
- TF-A Pi 4 platform notes
  (https://trustedfirmware-a.readthedocs.io/en/latest/plat/rpi4.html)
  — describes why `armstub8.bin` is replaced by TF-A's BL31 to get
  EL3 errata + correct cache maintenance before the kernel runs.

## 10. Postmortems / "what we learned"

The closest things we found to multi-week postmortems are:

- Andre Leiradella's "The Raspberry Pi Stubs"
  (https://leiradel.github.io/2019/01/20/Raspberry-Pi-Stubs.html) —
  a careful walk through what `armstub*.S` does and what state the
  kernel inherits, including which caches are off and which SMP /
  coherency bits are pre-set.
- Adam Greenwood-Byrne's "Writing a bare metal operating system for
  Raspberry Pi 4" series (https://www.rpi4os.com/) — Part 12 in
  particular documents the MMU bring-up. The author flags the EL1 vs
  EL2 trap (the kernel actually starts in EL2 on Pi 4 by default) as
  the single biggest source of "I configured the MMU but nothing
  happens", because the SCTLR write was hitting the wrong EL.
- The rust-embedded/rust-raspberrypi-OS-tutorials discussion #155
  ("rpi4's bare-metal hashing performance is poor without caching",
  https://github.com/rust-embedded/rust-raspberrypi-OS-tutorials/discussions/155)
  — turns into a long thread on why the author's own MMU enable
  initially crashed and what specific change to the SCTLR_EL1 write
  unblocked it (the answer: the prior code was at the wrong EL).
- Vinnie's "Bare Metal on Raspberry Pi 4: Getting Started"
  (https://www.vinnie.work/blog/2020-11-06-baremetal-rpi4-setup/)
  — practical setup notes, including UART caveats once the MMU
  marks everything but the peripheral window as cacheable.

## Synthesis for the Phoenix-RPi cache-coherency class problem

Mapping the above against TD-04 and the BCM2711 cache-coherency line of
investigation in this repo:

- The "code reaches X marker, then dies on M+C+I" failure mode is the
  most-reported symptom and almost always traces to (a) page-table
  visibility to the table walker, or (b) an attribute mismatch on the
  region that contains the SCTLR write. Defensive `dc cvac` over the
  table region + `dsb ish; tlbi vmalle1; dsb ish; isb` before the SCTLR
  write resolves the majority.
- The BCM2711's complete lack of hardware coherency for non-CPU masters
  is widely acknowledged and is *not* the cause of the SCTLR flip
  hang; it is the cause of every subsequent DMA correctness bug. So if
  the kernel hangs at the flip, look at descriptors and attributes
  first, not at L2 or SCU state.
- A72 erratum 859971 is real but its symptom (rare instruction-prefetch
  corruption) does not match a deterministic hang. It is worth applying
  via TF-A in the medium term, not the path to first boot.
- The set/way-vs-VA debate is a red herring for first-boot bring-up:
  cold reset already invalidates L1; what you need is *VA-based
  cleaning of the page-table region* immediately before enabling.
- The single most under-cited fix across forum threads: the SCTLR_EL1
  baseline must include the RES1 bits 29/28/23/22/20/11. Many tutorials
  show `M | C | I` only and rely on the reset value carrying RES1 bits
  through, which is fragile. Constructing the value as
  `0x30d00800 | M | C | I` (plus EE/SA policy) is the safe pattern
  every working project converges on.

Sources cited inline above. Primary sources used:

- ARM Trusted Firmware-A (cortex_a72.S, rpi4 platform docs):
  https://github.com/ARM-software/arm-trusted-firmware
- Raspberry Pi Forums: 384228, 331894, 322157, 262772, 280192, 329308,
  335399, 255430, 269324, 227139, 268543
- OSDev: forum.osdev.org threads 37479, 36412, 33354, 40370,
  p=350137; wiki ARM_Paging, MMU
- Repos: rsta2/circle, LdB-ECM/Raspberry-Pi, bztsrc/raspi3-tutorial,
  babbleberry/rpi4-osdev, rust-embedded/rust-raspberrypi-OS-tutorials,
  PeterLemon/RaspberryPi, dwelch67/raspberrypi, raspberrypi/tools
  (armstub8.S)
- Blog/postmortem: leiradel.github.io,
  rpi4os.com (Adam Greenwood-Byrne), vinnie.work,
  s-matyukevich.github.io/raspberry-pi-os
- ARM specs: Cortex-A72 TRM r0p3,
  http://classweb.ece.umd.edu/enee447.S2019/baremetal_boot_code_for_ARMv8_A_processors.pdf
