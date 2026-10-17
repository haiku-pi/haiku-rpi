# Round 3: BCM2711 / Pi 4 Firmware Handoff State

Status: research notes for the cache-enable class problem (TD-04 et al.)
Scope: what state the BCM2711 VPU firmware leaves the four Cortex-A72 cores
in when control reaches the kernel-side armstub, where the gaps are in
Phoenix's current `phoenix-armstub8-rpi4.S`, and what additions are needed
for a robust handoff.

## 1. Firmware boot stages

The BCM2711 cold boot is GPU-led; the ARM cores are held in reset until late.
The published Raspberry Pi documentation describes a multi-stage VideoCore
sequence:

1. **Stage 0 — boot ROM (in BCM2711 mask ROM).** On power-up the ARM cores
   are off and only the VPU is running. The mask-ROM checks for a recovery
   image on SD; if not found, it reads the second-stage bootloader from
   the SPI EEPROM. The Pi 4 is the first flagship Pi to move the second
   stage out of `bootcode.bin` and into EEPROM (`pieeprom.bin`); see
   `raspberrypi/rpi-eeprom` `firmware-2711/release-notes.md` and
   `raspberrypi/documentation` `bootflow-eeprom.adoc`.
2. **Stage 1 — EEPROM bootloader.** Trains DRAM enough to hold the next
   stage, parses `config.txt`, decides boot mode (SD, USB, NVMe, network),
   and loads `start4.elf` + `fixup4.dat` into RAM.
3. **Stage 2 — `start4.elf` (VPU firmware).** Performs the bulk of board
   bring-up while still on the VPU: full DRAM controller calibration,
   clock tree, voltage rails, HDMI/USB/SDHCI hardware init, GPIO mux,
   GIC-400 conditional enable (only when `enable_gic=1` in `config.txt`),
   mailbox setup, framebuffer (if requested), and SD/USB filesystem
   I/O to read `kernel8.img`, the device tree (`*.dtb`), `cmdline.txt`,
   any `armstub` blob, and any `initramfs`. It places these at the
   addresses configured in `config.txt` (defaults: kernel at `0x80000`
   for AArch64, armstub at `0x0` if present).
4. **Stage 3 — ARM release.** The VPU writes the ARM reset vector to
   point at either the loaded armstub at `0x0` or directly at the kernel
   load address, and de-asserts ARM core 0 reset. ARM core 0 then begins
   executing in AArch64 at EL3 (when an armstub is present) or EL2
   (when the firmware uses its built-in stub path that goes directly to
   the kernel).

This staging is documented at a high level in
`raspberrypi/documentation` `bootflow-eeprom.adoc`, in the
`raspberrypi/firmware` README, and in the Trusted Firmware-A `rpi4`
platform port, which assumes exactly this contract for `BL31` to take
over from `start4.elf` (`trustedfirmware-a` docs `plat/rpi4`).

## 2. State of cores 1-3 during firmware execution

Cores 1-3 are held in **reset** while the VPU runs. The Pi 4 firmware
release in use today releases all four cores together once the armstub
is loaded and ready: every core enters the armstub at the same entry
address. Cores 1-3 must be put to sleep by the stub so only core 0
proceeds to the kernel.

Both upstream `armstub8.S` and the Phoenix derivative implement the
"spin table" Linux convention: cores 1-3 `wfe` and poll fixed offsets
inside the stub image (`spin_cpu1`, `spin_cpu2`, `spin_cpu3`) for a
non-zero entry address. See `raspberrypi/tools` `armstubs/armstub8.S`
and the Phoenix file at offset `0xe0/0xe8/0xf0`. The
`leiradel.github.io` "Raspberry Pi Stubs" article walks this code in
detail and confirms `0xd8/0xe0/0xe8` (older layout) vs `0xe0/0xe8/0xf0`
(current Pi 4 layout) — Phoenix uses the latter.

Pi 4 firmware therefore does **not** stagger releases. By the time the
primary CPU has run a few instructions of the stub, all secondaries are
already inside `secondary_spin`. This matters for cache coherency: the
secondaries' L1 D-caches are powered up and architecturally enabled in
the SCTLR sense only after they execute the SMPEN write themselves;
before that they are non-coherent participants on the inner-shareable
domain.

## 3. Exception level and SCTLR_EL3 at handoff

The firmware enters the armstub in **AArch64 EL3 (secure)** with the
MMU off. This is the published contract — see the
`forums.raspberrypi.com` thread "Aarch64 - EL2 switch to EL3" (t=257543),
and the upstream `armstub8.S` which begins with EL3-only register writes
(`SCR_EL3`, `CPTR_EL3`, `CPUECTLR_EL1` via the EL3 trap path).
SCTLR_EL3 contents are architecturally **mostly UNKNOWN** at cold reset
on Cortex-A72 except for the RES1 bits — the ARM Cortex-A72 r0p3 TRM
(Section 4.5.x "System control register, EL3") states that `M`, `C`,
`I`, `SA`, and `A` are all 0 on reset, and that other bits are reset
to 0 or RES1 as listed.

In practice the `start4.elf` VPU firmware does **not** turn on caches
or MMU in the ARM cores before releasing them — it cannot, since only
the VPU is running until that release. Stage 2 work happens on the
VideoCore. So when ARM core 0 begins executing the armstub the
guaranteed register state is the architectural cold-reset state per
the Cortex-A72 TRM:

- `SCTLR_EL3.M = 0` (MMU off)
- `SCTLR_EL3.C = 0` (D-cache off — note the bit being clear in SCTLR
  does *not* mean the cache structures are empty, only that they are
  bypassed for accesses)
- `SCTLR_EL3.I = 0` (I-cache off)
- `SCTLR_EL3.A = 0` (alignment check off)
- branch predictor, BTB, GHB, indirect predictor — invalidated by the
  reset itself per Cortex-A72 TRM "Resets" section

The cores are running, GIC is in either disabled or
firmware-initialised state, and DRAM is fully calibrated.

## 4. Cache state at handoff — what is and is not guaranteed

This is the heart of the TD-04 problem. The Cortex-A72 TRM, Section
"Resets", states that on a Cold reset the core invalidates: the
branch prediction arrays (BTB, GHB, indirect predictor), the L1
instruction TLB, the L1 data TLB, the L1 instruction cache, and
the L1 data cache. So at architectural cold reset, L1I and L1D
**are** invalidated by hardware on Cortex-A72; the
"L1 D-cache contents are UNKNOWN at reset" hazard that exists on
some other Arm cores (Cortex-A53 in particular requires explicit
`DC ISW` over all sets/ways before enabling caches — see U-Boot
`arch/arm/cpu/armv8/cache.S`) is **not** the same on A72.

That said:

- **L2 cache**: Cortex-A72's L2 may contain hardware-invalidated
  contents at cold reset, but the TRM treats L2 line states as
  invalidated by reset. The `L2CTLR_EL1` write in the upstream
  `armstub8.S` configures latencies but does not bear on initial
  contents.
- **System / interconnect caches**: BCM2711 has no system-level cache
  outside the A72 cluster (no SLC), so this risk is absent — unlike
  most server-class SoCs where a system cache must be invalidated
  separately.
- **Coherency**: Until SMPEN is set in `CPUECTLR_EL1`, the core does
  not participate in the inner-shareable coherency domain. Loads
  before SMPEN may bypass the cache, but stores from this CPU are
  not visible to other cores' caches and vice versa. This is the
  well-known "SMPEN-before-MMU-enable" rule referenced by ATF's
  `cortex_a72_reset_func`.
- **Firmware-touched DRAM**: `start4.elf` ran on the VPU, not the
  ARM cores. The VPU has its own caches. DRAM regions written by
  the VPU (kernel image, dtb, armstub, framebuffer if any) are
  reflected in DRAM by the time ARM is released — from the ARM core's
  perspective those bytes are "fresh from DRAM" with cold L1. There
  is no scenario in which firmware leaves dirty A72 L1 D-cache
  lines aliasing the kernel image.

So the formal answer is: caches are architecturally invalidated at
cold reset on A72, but **the firmware does not promise any of this
in writing**. The published Raspberry Pi armstub does not perform
explicit `DC ISW` / `IC IALLUIS` / `TLBI` either, on the assumption
that A72 reset behaviour and the absence of a system cache make it
unnecessary. ATF's `el3_entrypoint_common` (in
`arm-trusted-firmware/include/arch/aarch64/el3_common_macros.S`) does
do explicit `inv_dcache_range` over its own RW data region — but for
data written by `BL2` into RAM that may still be sitting in some
prior cache hierarchy. That defensive pattern is the right one to
mirror when the hand-off provenance is uncertain.

## 5. Memory state at handoff

`start4.elf` writes the following into DRAM before release:

- the kernel/plo image at the configured kernel address
  (default `0x80000` for AArch64 Pi 4)
- the device-tree blob at the configured `device_tree_address`
  (default just below the kernel)
- `cmdline.txt` content into a region pointed to by the dtb
- the armstub at `0x0` if `armstub=` is set in `config.txt`
- a small region near `0x0` containing the spin-table magic
  (`0x5afe570b` at offset `0xf0`), version, dtb pointer at `0xf8`,
  kernel entry pointer at `0xfc`

Everything outside these ranges is undefined-but-stable DRAM. The ARM
core's L1 is invalidated by reset, so the first reads from any of
these regions are guaranteed to fetch from DRAM and see what the VPU
wrote. `start4.elf` is reported (via Pi forum discussion and the
TF-A platform port) to perform a `dsb`/cache-clean sequence on its
side before releasing ARM, but this is not formally specified.

The DRAM controller is fully calibrated: linear DRAM is usable
immediately. SDRAM refresh is running.

## 6. GIC state

The BCM2711 has a **GIC-400** (GICv2) at `0xff841000` (distributor)
and `0xff842000` (CPU interface). Initialisation of the GIC by
`start4.elf` is **conditional** on `enable_gic=1` in `config.txt`.
Without that key the GIC is left in cold-reset state and the legacy
ARM local interrupt controller is used.

Phoenix's project `config.txt` enables `enable_gic=1`; the armstub
nevertheless re-runs `setup_gic` (distributor enable on core 0,
CPU interface enable, IGROUPR all set to group 1) because the
firmware-side init is conservative. This is consistent with how
Linux historically treated the same path before
firmware GIC enable became reliable.

## 7. DRAM controller

DRAM is calibrated and the controller is running by the time ARM
core 0 enters the armstub. There is no DRAM init left for the kernel
on Pi 4 — this is a major difference from the Pi 1/2/3 armstubs,
which did not need it for a different reason (no DDR controller
visible on ARM side either).

## 8. Firmware versions

The relevant moving parts are:

- `pieeprom.bin` (EEPROM bootloader): tracked via
  `raspberrypi/rpi-eeprom`. The "default" channel as of 2025 is
  recent stable; the "latest" channel may include feature-flag
  changes (e.g. one-shot boot menu, `BOOT_WATCHDOG_TIMEOUT`).
- `start4.elf` + `fixup4.dat`: tracked via `raspberrypi/firmware`
  releases. These are paired and must be updated together.
- `bcm2711-rpi-4-b.dtb`: tracked alongside firmware.

For Phoenix bring-up the safest target is the EEPROM and firmware
combination shipped with the most recent Raspberry Pi OS image
that boots Linux successfully on the lab board, then **pin** that
combination in the integration manifest. The Linux-host ATF rpi4
port documentation singles out
`firmware-stable` (now equivalent to `default`) as the validated
channel for ATF testing.

## 9. What upstream `armstub8.S` assumes

Reading `raspberrypi/tools` `armstubs/armstub8.S` line by line:

- enters at `0x0`, EL3, AArch64, MMU off, caches off, scalar regs free
- writes `LOCAL_CONTROL` and `LOCAL_PRESCALER` to ensure the local
  timer increments by 1 from the 19.2 MHz crystal
- sets `CNTFRQ_EL0` to oscillator frequency (54 MHz on BCM2711)
- enables FP/SIMD via `CPTR_EL3 = 0`
- writes `SCR_EL3 = RW | HCE | SMD | RES1 | NS`
- sets `CPUECTLR_EL1.SMPEN`
- sets `SCTLR_EL2 = 0x30c50830` (the Linux "no MMU/no caches/EE=0/SA=1"
  default the kernel will edit immediately)
- `eret` to EL2 at `in_el2`, where it splits into `primary_cpu` (core 0
  jumps to `kernel_entry32`, x0=dtb) and `secondary_cpu` (cores 1-3
  spin in `wfe` polling `spin_cpuN`)

Notable **omissions** in upstream:

- no `DC ISW` set/way invalidation of L1 D-cache
- no `IC IALLUIS` of I-cache
- no `TLBI VMALLE1IS`
- no `DSB`/`ISB` boundary specifically for cache state
- no `ACTLR_EL3` write (raspberrypi/tools issue #114)
- no L2CTLR programming (some forks add it)

The implicit assumption is that A72 cold-reset invalidation is
sufficient and that the firmware did not write executable code into
ranges that A72 caches could have been speculatively prefetching.

## 10. How Phoenix's armstub differs

Reading `phoenix-armstub8-rpi4.S` (the file under
`sources/phoenix-rtos-project/_projects/aarch64a72-generic-rpi4b`)
line by line:

What it adds beyond upstream:

- **CPUACTLR_EL1 erratum 859971 disable instruction prefetch** at
  bit 32, applied at EL3 (matches `cortex_a72_reset_func` in
  `arm-trusted-firmware/lib/cpus/aarch64/cortex_a72.S`). The comment
  block correctly notes this register traps from EL1 on r0p3 and so
  must be done by the stub, not the kernel. Good.
- **a single `dsb sy; isb`** between SMPEN/CPUACTLR writes and the
  later EL3->EL2 transition. Necessary, present.
- **`setup_gic`** routine inline — distributor enable on core 0,
  CPU interface enable, PMR=0xff, IGROUPR all-ones over `GIC_IT_NR`
  registers. Reasonable but partial: `GIC_IT_NR=8` covers 256 lines,
  fine for IRQ_NR <= 256.
- **PL011 UART early-print path**: `uart_reinit_115200` and
  `uart_putc` macros, used to emit `'1'`, `'2'`, `'A'`, `'S'`, `'0'`
  before branching to the kernel. Critical diagnostic instrumentation.
- **EL2 vector table** `vectors_el2` with stub exception handler
  (`wfe`/`b .`) so EL2 traps land somewhere observable.
- **fallback kernel entry** at `PI4_KERNEL_FALLBACK_ENTRY = 0x80000`
  if the firmware hasn't filled `kernel_entry32`.
- **dtb fallback** to `x28` (firmware r0/x0 input) when `dtb_ptr32`
  is zero.

What it does **NOT** add (the gaps relative to the TD-04 hypothesis):

- no `DC ISW` set/way clean+invalidate of L1 D-cache
- no `DC IVAC` / `DC CIVAC` of the firmware-handoff data window
  (offsets `0xd8`..`0xff` containing `spin_cpuN`, `dtb_ptr32`,
  `kernel_entry32`)
- no `IC IALLUIS` I-cache invalidate-all
- no `TLBI VMALLE1IS` and `TLBI ALLE3` in EL3
- no `dsb ish` after the spin-table writes by the firmware before
  cores 1-3 read them — though here Phoenix's stub is the *reader*,
  not the writer; it's the kernel that will write `spin_cpuN` later
  to release secondaries, and that path also needs `dc civac` per
  the `forums.raspberrypi.com` "[RPI 4B] Unpark cores" thread

## 11. Recommended additions

For TD-04-class robustness, Phoenix's `phoenix-armstub8-rpi4.S` should
add — in EL3, on every CPU path, before any read of the spin-table
fields, before SMPEN, and before the EL3->EL2 transition — the
following sequence (modeled on ATF
`include/arch/aarch64/el3_common_macros.S` `el3_entrypoint_common`,
on Cortex-A72 boot code in the Xilinx `embeddedsw`
`lib/bsp/standalone/src/arm/ARMv8/64bit/gcc/boot.S`, and on the
U-Boot `arch/arm/cpu/armv8/cache.S` `__asm_invalidate_dcache_all`
helper):

1. **invalidate L1 instruction cache**

       ic ialluis
       dsb ish
       isb

   `IC IALLUIS` documented at
   `developer.arm.com/documentation/ddi0601/.../IC-IALLUIS--`.

2. **invalidate TLBs at EL3**

       tlbi alle3
       dsb sy
       isb

   plus, after the EL2 transition, `tlbi vmalle1is; dsb ish; isb`
   to cover the EL1&0 regime that the kernel will use.

3. **invalidate L1 data cache by set/way**, walking `CSSELR_EL1`
   over each cache level reported in `CLIDR_EL1`, computing
   sets and ways from `CCSIDR_EL1`, and issuing `DC ISW` per
   line. This is the standard ATF/U-Boot snippet; it is
   architecturally correct on A72 and does not depend on the
   "A72 reset already invalidates" assumption. Cite
   `developer.arm.com/documentation/ddi0601/.../DC-ISW--` and
   `arm-trusted-firmware/lib/cpus/aarch64/cortex_a72.S`.

4. **invalidate by VA over the firmware-handoff data window**
   (offsets `0xd8`..`0xff` of the stub image) before reading
   `dtb_ptr32` / `kernel_entry32`:

       adr x0, spin_cpu0
       add x1, x0, #0x28        // through end of kernel_entry32
       dc ivac, x0
       add x0, x0, #64
       cmp x0, x1
       b.lt 1b
       dsb ish

   This is the explicit defence against any speculative prefetch
   the A72 may have done into this region between firmware writing
   it and the stub reading it. It is cheap and matches the pattern
   the kernel will need when it writes `spin_cpuN` to release
   secondaries.

5. **barriers around all of the above** — `dsb sy; isb` after
   the cache/TLB ops complete and before SCTLR writes; an
   additional `isb` after the EL3->EL2 `eret` lands and before
   any first instruction-cache fill from the new EL.

6. **secondary path symmetry**: every secondary core that lands
   at the spin-table entry must run the same SMPEN write, the same
   erratum 859971 write, and the same I-cache and TLB invalidate
   before its own `wfe` loop. Phoenix's current code does the
   SMPEN+CPUACTLR sequence on the *primary* path before splitting,
   which means cores 1-3 take the EL3->EL2 transition with these
   already applied (because the writes happen before `eret` and
   `eret` is taken on every core). Confirm this is intentional and
   add a comment; the Linux convention is for each secondary to
   redo its own per-core register init, so the current Phoenix
   layout is acceptable but unusual.

The Linux AArch64 boot protocol
(`kernel.org/doc/Documentation/arm64/booting.txt`) requires that the
kernel image range be **clean to PoC** and that the I-cache contain
no stale entries for that range. The Pi firmware satisfies neither
explicitly. Adding the three operations above (`IC IALLUIS`,
`DC ISW` over L1D, `DC IVAC` over the handoff window) brings the
Phoenix stub into line with the ATF/U-Boot defensive baseline and
forecloses any "stale firmware-era cache line" hypothesis as a
cause of TD-04-class failures.

## Sources

- raspberrypi/tools `armstubs/armstub8.S` — upstream Pi armstub
- raspberrypi/firmware repo + wiki — VPU firmware binaries, boot flow
- raspberrypi/rpi-eeprom `firmware-2711/release-notes.md`
- raspberrypi/documentation `bootflow-eeprom.adoc`
- Trusted Firmware-A `plat/rpi4` documentation
- ARM Cortex-A72 r0p3 Technical Reference Manual (resets, SCTLR_EL3)
- ARM-software/arm-trusted-firmware
  `include/arch/aarch64/el3_common_macros.S`,
  `lib/cpus/aarch64/cortex_a72.S`
- Xilinx/embeddedsw `lib/bsp/standalone/src/arm/ARMv8/64bit/gcc/boot.S`
- ARM-software/u-boot `arch/arm/cpu/armv8/cache.S`
- developer.arm.com documentation: `DC ISW`, `IC IALLUIS`, `IC IALLU`,
  `SCTLR_EL3`
- kernel.org `Documentation/arm64/booting.txt`
- leiradel.github.io "The Raspberry Pi Stubs" (Jan 2019)
- raspberrypi.com forums threads: t=288900 (BCM2711 booting/flashing),
  t=257543 (EL2->EL3 exception path), t=337168 (Pi 4 unpark cores),
  t=264096 (Pi 4 GIC), t=328000 (Pi 4 kernel load address),
  t=269441 (SCTLR_EL3 bit 11)
- raspberrypi/tools issue #114 (missing ACTLR_EL3 init)
- Phoenix:
  `sources/phoenix-rtos-project/_projects/aarch64a72-generic-rpi4b/phoenix-armstub8-rpi4.S`
