# Raspberry Pi 4 / BCM2711 OS Development Guide

A reference for anyone bringing up a new operating system, or porting an
existing one, on the Raspberry Pi 4 Model B (or Compute Module 4 / Pi 400).
The target audience is bare-metal OS developers: kernel hackers, RTOS
porters, hypervisor authors, and demo-writers. The guide focuses on
**platform knowledge** — what the SoC does and does not do, what the
firmware leaves behind, what every other working stack agrees on — and
treats Phoenix-RTOS-specific outcomes as case studies / war stories at the
end.

The document was written during the Phoenix-RTOS Pi 4 port and is
deliberately pragmatic: every section starts from "what someone bringing
up their first Pi 4 OS actually needs to know" rather than reproducing
the BCM2711 ARM Peripherals datasheet (which you should also read).

Conventions used below:

- "ARM-side phys" means the **low-peripheral** address mapping used by
  64-bit Linux and almost all bare-metal stacks (peripherals at
  `0xFC000000`–`0xFEFFFFFF`). The legacy "high-peripheral" mode at
  `0x7E000000` exists for 32-bit BCM2835 compatibility; do not use it on
  a new Pi 4 OS.
- DT addresses are quoted in the legacy SoC view (`0x7Dxxxxxx`) when the
  device tree node uses that view, with the ARM-side phys called out
  alongside.
- Errata bit numbers and register encodings come from the Cortex-A72 r0p3
  TRM, ARM Trusted Firmware's `lib/cpus/aarch64/cortex_a72.S`, and the
  Raspberry Pi `armstubs/armstub8.S`. Cross-check against your own
  silicon revision before trusting any single source.


## Pi 4 / BCM2711 at a glance

| Property | Value |
| --- | --- |
| SoC | Broadcom BCM2711 (B0 / C0 stepping in shipping units) |
| CPU | Cortex-A72 r0p3, 4 cores, ARMv8-A, 1.5 GHz (turbo up to 1.8 GHz with overvolt) |
| Caches | L1I+L1D 48 KB each per core, cluster L2 1 MB (A72-internal — see "Cache topology") |
| Memory controller | LPDDR4-3200, 1/2/4/8 GB SKUs |
| GPU | VideoCore VI (VC6) — runs `start4.elf` and remains live after handoff |
| Interrupt controller | GIC-400 (GICv2), distributor + 4 CPU interfaces |
| Generic timer | ARMv8 architectural timer, 54 MHz reference |
| Boot CPU | VPU (VideoCore) — loads firmware, ARM cores wait for release |
| Ethernet | Broadcom GENET v5 MAC + BCM54213PE PHY over RGMII (1 Gbps) |
| Wi-Fi / BT | BCM43455 (SDIO + UART for BT) |
| USB | xHCI via VLI VL805 (USB 3.0 host) behind the integrated PCIe RC |
| Display | 2× HDMI via VC6 (driven by firmware until you take it over) |

The ARM cores are **not** the boot CPU. The VideoCore VPU is. The VPU
brings up DRAM, loads firmware, parses `config.txt`, patches the device
tree, loads the kernel image (or armstub), and finally releases the A72
cluster to a known PA. Anything the ARM cores want to know about the
hardware comes from one of three sources: the device tree the firmware
patched, the property mailbox interface to the VC6, or direct MMIO. There
is no "BIOS" or ACPI on Pi 4 (UEFI is achievable via `pftf/RPi4` but is
not the default path).


## Memory map (low-peripheral mode, ARM-side)

```
0x0000_0000 - 0x0000_00FF   armstub / spin-table area
0x0000_0100 - 0x0007_FFFF   firmware-reserved low-memory scratch
0x0000_8000 - 0x0007_FFFF   typical kernel load address (32-bit Linux)
0x0008_0000 - 0x????_????   typical kernel load address (64-bit, kernel8.img)
0x???? .... - 0x3B3F_FFFF   first ARM-visible DRAM bank (size = ARM_total - GPU_reserve)
0x3B40_0000 - 0x3FFF_FFFF   76 MB GPU reserve (default; tunable via gpu_mem)
0x4000_0000 - 0xFBFF_FFFF   second ARM-visible DRAM bank (3008 MB on 4 GB SKUs)
0xFC00_0000 - 0xFCFF_FFFF   reserved (some SoC subsystems)
0xFD00_0000 - 0xFD9F_FFFF   PCIe + GENET + SDIO + thermal + RNG + ...
0xFE00_0000 - 0xFEFF_FFFF   classic VC4 peripherals (UARTs, GPIO, USB2 EHCI/OHCI,
                            mailbox, SDHCI, DMA, watchdog, framebuffer)
0xFF80_0000 - 0xFF8F_FFFF   ARM-local: GIC-400 distributor + CPU interface
```

Note that the 4 GB SKU has **two ARM-visible DRAM banks** described by
**two separate `/memory@*` device tree nodes**. Any parser that picks up
only the first node will silently see ~948 MB of RAM and lose the upper
3 GB. This is one of the most common Pi 4 porting pitfalls.

The split between the two banks is fixed by SoC routing, not by firmware
config. `total_mem=` in `config.txt` can only cap the visible RAM; it
cannot enlarge or shift the banks.

The 8 GB SKU exposes a third bank above 4 GB. As of writing, Phoenix has
not tested that path; behaviour of code that assumes ≤4 GB on 8 GB units
is undefined (most likely it will see two banks and ignore the third).


## Boot pipeline & handoff

Pi 4 boot is a multi-stage handoff. Each stage can leave invisible state
(cache lines, MMIO writes, GIC interrupt-pending bits, DMA descriptor
rings) that bites later stages. Always reason about what your
predecessor left behind.

```
EEPROM bootloader (in SPI EEPROM since Pi 4)
  └── selects boot device per `boot_order` (SD, USB-MSD, network, NVMe, ...)
      └── reads bootcode (from EEPROM on Pi 4) and the FAT boot partition
          └── start4.elf  (VideoCore VPU firmware, ~2.3 MB)
              ├── reads config.txt
              ├── parses bcm2711-rpi-4-b.dtb + applied overlays
              ├── patches DTB at runtime:
              │     - /memory@* nodes (one or two banks)
              │     - /chosen/bootargs (from cmdline.txt)
              │     - /chosen/linux,initrd-{start,end}
              │     - ethernet@7d580000/local-mac-address (from OTP)
              │     - serial-number, board-rev
              ├── loads ARM payloads at the addresses below
              └── releases the four A72 cores to PA 0x0 (or `armstub=`'s target)
                  └── armstub (runs at EL3) — your code or the canonical one
                      └── transitions to EL2 (or EL1) and branches to the kernel
                          └── kernel / bootloader
```

### What the firmware loads, by default

| File | Default load PA | Purpose |
| --- | --- | --- |
| `bootcode.bin` | (EEPROM on Pi 4; FAT fallback) | First-stage VPU loader |
| `start4.elf` | (VPU side) | Main VPU firmware |
| `fixup4.dat` | (VPU side) | Memory-split parameters for `start4.elf` |
| `bcm2711-rpi-4-b.dtb` | (parsed in VPU memory; pointer passed) | Device tree |
| `armstub8.bin` (or `armstub=...`) | `0x00000000` | First code A72 core 0 runs |
| `kernel8.img` (`kernel=`) | `0x00080000` (override with `kernel_address=`) | 64-bit kernel |
| `initramfs <file> <addr>` | `<addr>` | Optional ramdisk |
| `overlays/*.dtbo` | (merged into DTB) | DT overlays |

The `start4cd.elf` / `fixup4cd.dat` pair is a stripped firmware (~850 KB)
that disables hardware-decoder bring-up, 3D bring-up, and a few other
non-essential paths. It is a useful experiment when you suspect VC6 is
interfering with your DMA or peripheral programming.

### Exception levels and CPU state at handoff

By default the firmware enters the armstub at **EL3** with caches and
MMU off, MMU disabled, all DAIF masked. The canonical Raspberry Pi
armstub then sets up GIC, drops to EL2 (the level Linux expects), and
the kernel decides whether to stay at EL2 or drop to EL1.

You can replace the armstub with `armstub=<your-binary>` in `config.txt`.
Most OS ports do this and inline the EL3-only initialisation (errata
workarounds, L2 cache RAM timing, generic timer, GIC) into their own
armstub so they keep tight control over what runs before the kernel.

### Spin-table secondary release protocol

The canonical Pi 4 armstub leaves cores 1, 2, and 3 spinning in a
`WFE` loop polling four memory locations near the start of the armstub
image (typically at offsets `0xd8`, `0xe0`, `0xe8` for `spin_cpu1`,
`spin_cpu2`, `spin_cpu3`; offset `0xf8` is `dtb_ptr32`). To release a
secondary, write its release address to the corresponding slot and
`SEV`. The released core picks the address up, branches to it, and your
kernel takes over.

The device tree's `/cpus/cpu@N` nodes have
`enable-method = "spin-table"` and a `cpu-release-addr` property that
points at the slot. Read the DTB; don't hard-code offsets.

Important: the firmware does **not** issue a `dsb ish` between writing
the spin-table magic and releasing core 0, and Linux/U-Boot historically
issued a self-CPU writeback to make the writes visible to other cores
when caches were off. If your armstub runs with caches off (almost all
of them do), make sure the kernel cleans the spin-table cache line
**before** doing the release write.

### DTB pointer convention

There is no standard register containing the DTB pointer at A72 entry
on the canonical Pi 4 armstub: the firmware writes the DTB physical
address into the armstub's `dtb_ptr32` field at offset `0xf8`. Custom
armstubs typically forward that pointer to the kernel through `x0`
(Linux ABI) or through a known fixed slot in low memory. Pick a
convention and document it; the device tree pointer is the only way to
know which DRAM banks are real, where peripherals live, and what your
MAC address is.


## Critical EL3 / armstub initialization

This is the **single biggest landmine** in Pi 4 bring-up. Every working
Pi 4 bare-metal stack — the canonical Raspberry Pi armstub, ARM Trusted
Firmware (`plat/rpi`), Circle, U-Boot, Linux's `head.S` when chain-loaded
by U-Boot — performs a small fixed set of EL3-only writes. Skipping or
mis-encoding any of them can produce a system that boots **on most
silicon** and crashes on yours.

### Cortex-A72 r0p3 errata workarounds

The errata documented for the A72 r0p3 are listed in the ARM Cortex-A72
MPCore Processor Software Developers Errata Notice. The two most
commonly applied on BCM2711 are:

- **Erratum 859971** — speculative instruction prefetch into XN page can
  corrupt instructions. Workaround:
  `CPUACTLR_EL1[32] = 1` (DIS_INSTR_PREFETCH).
- **Erratum 1319367** — speculative AT (address-translation) instruction
  during context switch can populate the TLB with stale entries.
  Workaround: `CPUACTLR_EL1[46] = 1` (DIS_HW_PAGE_AGGREGATION).

The encoding for both is the implementation-defined system register
`CPUACTLR_EL1`, accessed as `S3_1_C15_C2_0`. The companion register
`CPUECTLR_EL1` is `S3_1_C15_C2_1`. The encoding `S3_1_C15_C2_2`
(sometimes mis-named "CPUACTLR2_EL1" in third-party headers) is **not
documented** on Cortex-A72 r0p3; writes to it are not guaranteed to
have any effect, and may silently corrupt some other state. ARM Trusted
Firmware's `cortex_a72.S errata_a72_1319367_wa` confirms the correct
target is `CPUACTLR_EL1[46]`.

A typical EL3 sequence (pseudo-assembly):

```
    mrs   x0, S3_1_C15_C2_0           // CPUACTLR_EL1
    orr   x0, x0, #(1 << 32)          // 859971
    orr   x0, x0, #(1 << 46)          // 1319367
    msr   S3_1_C15_C2_0, x0
    isb
```

`CPUACTLR_EL1` and `CPUECTLR_EL1` **trap from EL1** on Cortex-A72 r0p3
unless `ACTLR_EL2.{CPUACTLR,CPUECTLR}` grants access. The simplest fix
is to do all the impl-defined writes in your armstub (at EL3) before
you ever drop to EL2 or EL1.

### L2 cache RAM timing (BCM2711-specific)

The A72 cluster's L2 cache RAM needs explicit timing on BCM2711's
1.5 GHz silicon. The TRM default of 2-cycle data RAM latency does not
meet timing; cacheable loads after `SCTLR.C=1` return corrupt data.

```
    mrs   x0, S3_1_C11_C0_2           // L2CTLR_EL1
    orr   x0, x0, #(0x22)             // Data RAM Latency=3, Setup=1
    msr   S3_1_C11_C0_2, x0
    isb
```

This is set by:

- `raspberrypi/tools` `armstubs/armstub8.S`
- ARM Trusted Firmware `plat/rpi/common/aarch64/plat_helpers.S`
- Circle `boot/armstub/armstub8.S`
- U-Boot `arch/arm/cpu/armv8/start.S` when chain-loaded

If you write your own armstub, **program L2CTLR_EL1 = 0x22**. The
symptom of skipping it is described in the war story at the end of
this document; expect days-to-weeks of false leads in kernel cache code.

### CPUECTLR_EL1 — SMPEN and L2 prefetch

```
    mrs   x0, S3_1_C15_C2_1           // CPUECTLR_EL1
    orr   x0, x0, #(1 << 6)           // SMPEN
    bic   x0, x0, #(3 << 38)          // clear L2 store prefetch
    orr   x0, x0, #(3 << 32)          // L1 instruction-fetch distance
    msr   S3_1_C15_C2_1, x0
    isb
```

`SMPEN` is required for any cache-coherent multi-core operation. Leaving
it clear and then enabling D-caches gives you incoherent caches across
cores.

### Generic timer

```
    msr   CNTFRQ_EL0,   x_19200000_or_54000000   // see below
    msr   CNTVOFF_EL2,  xzr
    mrs   x0, CNTHCTL_EL2
    orr   x0, x0, #3                  // EL1PCEN | EL1PCTEN
    msr   CNTHCTL_EL2, x0
```

`CNTFRQ_EL0` on Pi 4 is `54000000` (54 MHz) by default. `CNTVOFF_EL2`
must be cleared before the first read of `CNTVCT_EL0`; otherwise the
virtual timer is offset by whatever the reset value happened to be.

### GICv2 distributor + CPU interface

The GIC-400 lives at ARM-side phys `0xFF841000` (distributor) and
`0xFF842000` (CPU interface). The bringup is the standard GICv2 dance:

- Distributor: set `GICD_CTLR.EnableGrp0 = 1`, configure all SPIs as
  level-low (default) or as documented in the DT.
- CPU interface (per-core): `GICC_PMR = 0xFF` (lowest priority that
  still passes), `GICC_CTLR.EnableGrp0 = 1`, optionally `BPR = 0`.

Cores 1-3 each need their own `GICC_*` programming after release; the
armstub typically does CPU-interface setup right before dropping the
exception level.

### SCTLR_EL2 / SCTLR_EL1 RES1 bits

Several SCTLR bits are reserved-1 on AArch64. The conservative baseline
that matches Linux + ARM Trusted Firmware is `0x30C50830` for SCTLR_EL2
(caches off) and `0x30D50838` for SCTLR_EL1 (caches off, alignment-fault
disabled). Bits 4, 5, 11, 16, 18, 22, 28, 29 are RES1 on A72. Check
the TRM for your exact silicon; using a value that is missing required
bits is silently wrong on A72 even though it works on Cortex-A53.

### Reference armstubs

Reading working code is the fastest way to internalise the EL3 setup:

- [raspberrypi/tools `armstubs/armstub8.S`](https://github.com/raspberrypi/tools/blob/master/armstubs/armstub8.S)
  — the canonical Pi reference.
- [ARM Trusted Firmware `plat/rpi`](https://github.com/ARM-software/arm-trusted-firmware/tree/master/plat/rpi)
  — `plat_reset_handler` for RPi3/RPi4 captures the errata sequence.
- [Circle `boot/armstub/armstub8.S`](https://github.com/rsta2/circle/blob/master/boot/armstub/armstub8.S)
  — independent reimplementation, similar shape.
- [U-Boot `arch/arm/cpu/armv8/start.S`](https://github.com/u-boot/u-boot/blob/master/arch/arm/cpu/armv8/start.S)
  — drops to EL2 from whatever level it entered at.


## DRAM, caches, MMU

### Cache topology

There is no separate "system L2" cache on BCM2711. The phrase "1 MB
system L2 cache" in older BCM datasheets is a copy-paste artefact from
the BCM2835 era. On BCM2711:

- Each A72 core has private 48 KB L1I + 48 KB L1D.
- The four-core A72 cluster shares a 1 MB L2 (cluster-private; the
  GPU/VPU does not see it).
- Everything that's not cached in L1/L2 sits in DRAM (or peripheral
  MMIO).

### Memory-type policy

For a first-cut MMU map:

- DRAM (both banks): **Normal, Inner WB-WA, Outer WB-WA, shareable**.
- All peripheral MMIO (`0xFC000000`–`0xFEFFFFFF`, `0xFD000000`–`0xFD9FFFFF`,
  `0xFF800000`–`0xFF8FFFFF`): **Device-nGnRnE** (or `nGnRE` if you need
  early-write completion).
- **GPU reserve** (`0x3B400000`–`0x3FFFFFFF` by default): **Device** or
  **Normal Non-Cacheable**, never Normal-Cacheable. The VPU writes to
  this region after handoff (HDMI scanout buffer, mailbox response
  buffers if you put them here); a cacheable alias on the ARM side will
  see stale data and may produce dirty lines that overwrite the VPU's
  writes on eviction.

### DMA-coherency

Peripherals on BCM2711 DMA to/from DRAM **without** the help of a system
MMU or IOMMU. Each block has its own bus-address view:

- VC4-era peripherals on the `0xFE000000` bus see ARM-side phys + an
  offset that the firmware programs in the system MMU at boot. For most
  blocks this is a 1:1 mapping in low-peri mode.
- GENET and PCIe go through the SCB (System Coherent Bus) and can use a
  **35-bit DMA address space**: `addr_hi` is a 3-bit field in the
  descriptor. On boards with ≤4 GB DRAM the high bits are always 0; on
  >4 GB boards (and on Compute Module 4 paired with 8 GB Lite SO-DIMM
  variants) they matter.

The B0 silicon stepping has a quirk where PCIe inbound DMA above 3 GB
silently fails. The C0 stepping fixes it. The safe pattern is to keep
your packet/transfer buffers in the low DRAM bank (below 0xC0000000) or
to program the inbound BAR (RC_BAR2) at 0 with size ≥ ARM-visible DRAM.

### MMU bring-up gotchas

- Identity-map the entire ARM-visible DRAM range up front. Identity is
  the easiest place to start; you can lay a high-VA kernel mapping on
  top later.
- The transition from MMU-off to MMU-on is the single most failure-prone
  step. Recommended pattern: build the page tables with caches off,
  flush set/way (Linux uses `__inval_dcache_area`), then SCTLR write in
  one shot. Some Pi 4 stacks (including Phoenix's plo) cannot
  successfully enable `M|C|I` in a single shot on A72 r0p3 + BCM2711
  silicon — staged enable (`M` first, then `C|I` later from a known-good
  cacheable PC) is a workaround if you hit that.
- Always pre-flip `ic ialluis; dsb ish; tlbi vmalle1is; dsb ish; isb`
  and post-flip `isb; ic iallu; dsb nsh; isb` around the SCTLR write.

### Pi 4 4 GB DTB topology

The 4 GB SKU exposes its memory as two DT nodes:

```
memory@0       { reg = <0x0 0x00000000 0x0 0x3B400000>; };
memory@40000000{ reg = <0x0 0x40000000 0x0 0xBC000000>; };
```

A DTB parser that walks only the first `/memory*` node will silently
miss the upper bank. The 8 GB SKU adds a third node beyond 4 GB.


## DTB layout & VideoCore handoff

On Pi 4 the device tree is **not optional**. Even minimal bare-metal
demos need it to discover:

- Memory bank layout (multiple `/memory@*` nodes).
- The firmware-injected MAC address (`/ethernet@7d580000/local-mac-address`).
- Board-revision-dependent peripheral wiring (e.g. which `i2c-NN` is
  routed to the GPIO header on this PCB rev).
- Compatibility strings to disambiguate Pi 4 vs Pi 400 vs CM4.

### What the firmware patches

When `start4.elf` parses the DTB it adds or replaces:

- `/memory@*` nodes for each ARM-visible DRAM bank.
- `/chosen/bootargs`, `/chosen/linux,initrd-*`, `/chosen/kaslr-seed`.
- `local-mac-address` for the GENET and BCM43455 nodes (read from OTP).
- `/aliases/serial0` etc. depending on `dtparam=` and `dtoverlay=` lines
  in `config.txt`.
- The full set of clock and pinctrl nodes the kernel needs.

### VideoCore remains live after handoff

This catches many porters off-guard: the VC6 does **not** halt when it
hands off to ARM. It continues to:

- Drive HDMI (display scanout reads from the GPU reserve in DRAM).
- Answer mailbox property requests on channel 8.
- Respond to firmware notifications (e.g. `NOTIFY_XHCI_RESET`).
- Manage thermals and clocks (you can request changes, but the VPU is
  the actual policy owner).

So the GPU reserve range is **shared with the VPU**, and the mailbox is
how you keep talking to it. Treat the GPU reserve as Device memory and
respect the firmware's continued ownership.


## Mailbox property interface

The mailbox at ARM-side phys `0xFE00B880` is the VideoCore property
interface. Channel 8 is "Property tags (ARM → VC)"; channel 9 is "VC →
ARM". Each request is a buffer of 32-bit words: total size, request
code, then one or more tag triples (tag, value-buffer-size,
request-size, value-words), terminated by an end tag (`0x0`).

Tags every Pi 4 OS port ends up using:

| Tag | Name | Use |
| --- | --- | --- |
| `0x00010003` | `GET_BOARD_MAC_ADDRESS` | Read the unit's MAC from OTP |
| `0x00010002` | `GET_BOARD_SERIAL` | Read the board serial |
| `0x00010004` | `GET_BOARD_REVISION` | Disambiguate Pi 4 / 400 / CM4 / 8GB |
| `0x00000001` | `GET_FIRMWARE_VERSION` | Diagnostics |
| `0x00038041` | `SET_POWER_STATE` | Power-up/down USB, SD, etc. |
| `0x00030058` | `NOTIFY_XHCI_RESET` | Re-load VL805 firmware after PCIe re-init |
| `0x00040001` | `ALLOCATE_FRAMEBUFFER` | Open a framebuffer |
| `0x00040003` | `GET_PHYSICAL_DISPLAY_W_H` | HDMI resolution discovery |

The protocol is documented at
[raspberrypi/firmware mailboxes](https://github.com/raspberrypi/firmware/wiki/Mailboxes).

Address constraints:

- The request buffer pointer is written to `MBOX_WRITE` shifted left by
  4 and OR'd with the channel number. So the buffer must be **16-byte
  aligned**.
- The buffer's **bus address** is what the VPU expects, not the ARM
  phys. On BCM2711 in low-peri mode the bus address for DRAM is
  `phys | 0xC0000000` for the legacy mailbox; this is one of the few
  places the legacy bus alias is still load-bearing.
- The buffer must be in a region the VPU can read — typically the GPU
  reserve, but any ARM-visible DRAM works as long as you clean the cache
  before sending and invalidate after the response arrives.


## PCIe + USB (xHCI / VL805)

### PCIe controller

BCM2711's PCIe is a **single-lane Gen 2** root complex at ARM-side phys
`0xFD500000`. It is the only PCIe controller on the SoC. Pi 4-B uses it
to expose a single device — the VLI VL805 USB 3.0 host controller —
behind it on bus 1. Compute Module 4 routes the PCIe lane out to the
edge connector so it can carry any PCIe device.

The outbound window is a fixed CPU range `0x600000000`–`0x7FFFFFFFF`
(36-bit CPU PA) mapping to PCIe bus addresses starting at
`0xF8000000`. The window base/limit registers are programmed in
**1 MiB granularity** with the math `phys >> 20`; minimum window size
is 1 MiB.

The bring-up sequence that every working stack agrees on:

1. **Reset the RC** (`MISC_PCIE_CTRL.PCIE_BRIDGE_SW_INIT`).
2. **PERST# assert**, wait, **PERST# deassert**, wait **100 ms** per
   PCIe CEM spec §2.6.2.
3. **Inbound BAR (`RC_BAR2`) = 0, size ≥ ARM-visible DRAM**. RC_BAR2
   offset must be **0** — the VPU's xHCI reset firmware assumes
   bus == CPU 1:1 for the inbound translation
   ([firmware#1495](https://github.com/raspberrypi/firmware/issues/1495)).
4. **Outbound window** (`PCIE_MISC_CPU_2_PCIE_MEM_WIN0_*`), 1-MiB-granular.
5. **MISC_CTRL** flags: `PCIE_RCB_MPS_MODE`, `PCIE_RCB_64B_MODE`, set
   `SCB0_SIZE` to `log2(SCB0_size) - 15` (e.g. 17 for 4 GiB).
6. **Poll link-up**, then enumerate via the controller's indexed-config
   interface (BCM2711 PCIe config space is **not** ECAM).
7. **Program BARs** with bus addresses inside the outbound window.
   Use `MEM_TYPE_64` and split into `BAR0 = lower_32 | MEM_TYPE_64`,
   `BAR1 = upper_32`.
8. **Command register**: set Memory-enable and Bus-master.
9. **Mailbox `NOTIFY_XHCI_RESET`** (tag `0x00030058`, channel 8,
   payload `(bus<<20) | (slot<<15) | (func<<12)`). This causes the VPU
   to re-load VL805's SRAM. **Do not** call it more than once
   ([firmware#1617](https://github.com/raspberrypi/firmware/issues/1617));
   firmware state goes stale.
10. **First MMIO read** of VL805 BAR0 (HCIVERSION). If you see
    `0xDEADDEAD`, see the next subsection.

### The 0xDEADDEAD BAR readback — multiple silicon causes

The literal sentinel `0xDEADDEAD` on a BAR read comes from at least
three distinct silicon conditions on BCM2711, and you should rule out
each before iterating on driver code. (Cross-reference for the
canonical write-up: Phoenix's
`memory/project_bcm2711_pcie_64bit_bug.md`.)

**Cause A — oversized BAR mapping.** VL805's BAR0 is exactly **4 KiB**.
If you `mmap` 64 KiB across BAR0, speculative or compiler-coalesced
reads spill past the BAR end into 60 KiB of unmapped space; the
brcmstb PCIe root complex aborts those accesses, and on arm64 the
absorbed external abort surfaces as `0xDEADDEAD`. Fix: probe BAR size
with the write-all-ones / read-back-mask dance and map exactly that.

**Cause B — VL805 AC64 high-half garbage.** VL805 advertises
`HCCPARAMS1.AC64 = 1` but the hardware returns garbage in the high 32
bits of any 64-bit MMIO read. Low 32 bits are correct. Every working
driver (Linux, FreeBSD, Circle, U-Boot, Microsoft's `usbxhci.sys`)
splits 64-bit xHCI registers (CRCR, DCBAAP, ERDP, ERSTBA) into two
32-bit reads as a workaround. Treat AC64 as 0 in your xHCI core.

**Cause C — outbound window not covering the access.** A read to a CPU
PA outside the programmed outbound window returns `0xDEADDEAD` on
BCM2711. So does a sub-word access (the controller requires 32-bit
aligned 32-bit MMIO). Recheck `PCIE_MISC_CPU_2_PCIE_MEM_WIN0_*` math
and confirm your accessors are `readl`/`writel`.

**Cause D — incomplete inbound bridge state after `NOTIFY_XHCI_RESET`.**
Empirically (Phoenix 2026-05-24): the VPU's xHCI reset path can leave
RC_BAR1/RC_BAR2 in a state that breaks subsequent host-controller
DMA. Symptom: USBSTS sets `HSE` (host system error) when you write
`USBCMD.R/S = 1`. Workaround: re-disable RC_BAR1 and re-program RC_BAR2
**after** the mailbox call. This bug is still partially open at the
time of writing; some boots hit HSE intermittently. Treat the bridge
state as **non-deterministic after `NOTIFY_XHCI_RESET`**; defensively
re-validate every BAR you care about before issuing the first DMA.

### Other BCM2711 PCIe quirks

- **ECAM not supported.** Config space is a single 4 KiB movable
  window. You program a target BDF into a config register and access
  the device's config space through the window.
- **No I/O space.** Don't expect or program I/O BARs; the SoC has no
  PCIe I/O range. CM4 panics if a card asks for one.
- **ASPM L1**: BCM2711 advertises L1 substates but Pi engineers
  recommend leaving them disabled. Linux PCI core disables by default
  on this controller.
- **VL805 TRB overfetch**: prefetches up to 4 TRBs past a 4 KiB page
  boundary even when a Link TRB ends the segment. Linux mitigates with
  the `XHCI_TRB_OVERFETCH` quirk; expect to need an equivalent once
  you have transfers running.
- **VL805 link-TRB endpoint context bug**: the controller's
  hardware-maintained endpoint context sticks at the Link TRB address;
  the workaround is to ensure your ring includes a Link TRB at the
  ring-expansion boundary.
- **Reading RC registers before clearing `SERDES_IDDQ` is brutally slow
  *and* harmful.** The host-bridge RC registers (`RC_BAR*`, `MEM_WIN*`,
  `MISC_*`, `HARD_DEBUG`) live behind a PCIe block that is held in
  reset/IDDQ until you clear `HARD_DEBUG.SERDES_IDDQ` during bridge bring-up.
  An MMIO read issued *before* that clear does not fault cleanly — it stalls
  on an AXI/external-abort timeout (~10.8 s on Phoenix's Pi 4) and returns
  `0x0`. A "harmless" pre-init diagnostic that dumps ~10 such registers cost
  ~90–110 s of boot time. Worse, with the AArch64 SError handler unmasked
  these reads are exactly the live external-abort source in PCIe/VL805
  bring-up, and removing a pre-bridge dump of them correlated with USB
  enumeration going from flaky (3/10) to deterministic (10/10) — so the
  aborts may also degrade the subsequent VL805 bring-up. **Touch RC
  registers only after the bridge is out of IDDQ/reset.**

### Single-process bus owner is the workable pattern

Splitting "PCIe bring-up" and "xHCI driver" into separate userspace
processes on a microkernel hits a per-process MMIO mapping race on
BCM2711: the second process's `mmap` of the PCIe outbound window
returns `0xDEADDEAD`-pattern reads. Whether this is an MMU/cache
ownership issue or a controller-state issue is unsettled, but **every**
working Pi 4 USB stack we've examined runs PCIe + xHCI in the **same
address space**. Plan for a single-process bus owner from day one if
you're a microkernel.


## GENET (Ethernet)

The Pi 4 onboard Ethernet is **Broadcom GENET v5** (MAC) + **BCM54213PE**
(external gigabit PHY) over RGMII. The GENET MAC sits at ARM-side phys
`0xFD580000`, size 64 KiB. The DT presents it as
`compatible = "brcm,bcm2711-genet-v5"` at SoC view `0x7D580000`.

### Block layout inside the GENET MMIO window

```
0x0000  SYS         system / revision / port-control / flush
0x0040  GR_BRIDGE   global bridge control
0x0080  EXT         external (PHY reset, RGMII OOB, EEE)
0x0200  INTRL2_0    interrupt level-2 set 0 (general / RX-default / TX-default)
0x0240  INTRL2_1    interrupt level-2 set 1 (priority rings)
0x0300  RBUF        RX buffer / packet filters
0x0800  UMAC        UMAC (Unified MAC) — incl. CMD, MAC0/1
0x0E14  UMAC_MDIO   MDIO command register (single-word on v5)
0x2000  RDMA        RX DMA registers + RX BD ring (256 × 12 B inside MMIO)
0x4000  TDMA        TX DMA registers + TX BD ring (256 × 12 B inside MMIO)
0xFC00  HFB         hardware filter blocks
```

The descriptor rings live **inside the GENET MMIO window**, not in
system memory. You write descriptors via `writel`. Only the **packet
payload buffers** are allocated from system DRAM, and only those need
cache-flush dances.

### Interrupts

Two GIC SPIs: 157 (general / RX-default / TX-default) and 158 (priority
rings). The DT records them as
`interrupts = <0 0x9d 4>, <0 0x9e 4>` (SPI number, level-high). On the
GIC SPI numbering used by some kernels, that's IRQ 189 and 190 after
adding the 32 PPI/SGI offset.

### Bring-up sequence

The shortest path to "link-up + one packet TX + one packet RX" is the
following. Subscripts in brackets are the level of detail each existing
driver lands at: **L** = Linux, **F** = FreeBSD, **U** = U-Boot,
**C** = Circle.

1. **Soft-reset UMAC** [L,F,U,C]:
   `UMAC_CMD |= SW_RESET | LCL_LOOP_EN`, dsb, clear both, dsb.
2. **Flush RBUF + TBUF**:
   `SYS_RBUF_FLUSH_CTRL = 1; usleep(10); SYS_RBUF_FLUSH_CTRL = 0;`
   (same for TBUF).
3. **Confirm silicon revision**:
   read `SYS_REV_CTRL`; v5 reports major == 6 in bits 24..27. Accept
   both 5 and 6 (the silicon-IP minor counter has reused both).
4. **MAC address**:
   - **The Pi 4 firmware does NOT pre-program `UMAC_MAC0`/`UMAC_MAC1`**
     with the OTP MAC. Linux reads `local-mac-address` from the DT
     (which the firmware patched), then writes it back to UMAC.
     **U-Boot, Circle, FreeBSD, NetBSD all do read MAC0/MAC1** and
     expect the firmware to have programmed them — that is the
     Pi-3/Pi-zero convention, and it does not hold on Pi 4 in practice.
     If MAC0/MAC1 read as zero, fall back to a mailbox tag-`0x10003`
     call or to a locally-administered MAC for bring-up.
5. **PHY hard reset** [C, partially L]:
   `EXT_GPHY_CTRL |= EXT_GPHY_RESET; usleep(≥10); &= ~EXT_GPHY_RESET`,
   then wait ≥200 µs before MDIO is reliable.
6. **SYS_PORT_CTRL = `PORT_MODE_EXT_GPHY` (3)** [L, U]:
   **mandatory** for Pi 4. The reset default is `0`
   (internal-EPHY) and the MAC silently drops everything you queue if
   it isn't reprogrammed. Symptom: TDMA consumes BDs (CONS_INDEX
   advances) but nothing appears on the wire.
7. **RGMII configuration**:
   `EXT_RGMII_OOB_CTRL |= RGMII_LINK | RGMII_MODE_EN`,
   clear `OOB_DISABLE`, clear `ID_MODE_DIS` for `phy-mode = "rgmii-rxid"`
   (Pi 4's actual DT value — the GENET adds the internal RX delay; TX
   delay comes from the PCB).
   The phrase "Pi 4 phy-mode is plain rgmii" in some older references
   is wrong; the shipping DTB explicitly says `rgmii-rxid`.
8. **MDIO bring-up**:
   `UMAC_MDIO_CMD` (offset `0x0E14`) is a single 32-bit register with
   the layout
   `[31:28] start/busy/fail, [27] RD, [26] WR, [25:21] phy_addr, [20:16] reg, [15:0] data`.
   Linux/U-Boot poll the start/busy bit with a ~20 ms timeout.
9. **PHY init**:
   read PHY ID at MDIO reg 2 + 3 (BCM54213PE returns `0x600D84A2`),
   kick autoneg via BMCR, wait for BMSR link-up (or run a 1 Hz poll
   thread until you wire up the link-status IRQ).
10. **TX ring init** (default queue is **ring 16**):
    - `TDMA_RING_START_ADDR / END_ADDR / READ_PTR / WRITE_PTR / BUF_SIZE`.
    - `TDMA_RING_CFG |= 1 << 16` (enable ring 16).
    - `TDMA_CTRL |= TDMA_EN | (1 << (RBUF_EN_LSB + 16))` — the
      default-queue select bit is at `RBUF_EN_LSB + ring_idx`.
    - `TDMA_SCB_BURST_SIZE = 8` (U-Boot's BCM2711-specific value).
11. **TX a packet**:
    - Copy payload to a DMA-coherent buffer (or use cacheable +
      explicit `dc cvac`).
    - Write the BD: `addr_lo`, `addr_hi`, then
      `status = (len << 16) | SOP | EOP | TX_CRC`.
    - **Do NOT set `DMA_OWN` (bit 15) on TX BDs.** That bit is a
      RX-only convention on GENET. Setting it on TX BDs causes the
      controller to consume the descriptor through `cons_index` but
      **never emit the frame on the wire**. This is one of two GENET
      gotchas that the public references do not flag clearly.
    - Bump `TDMA_RING_PROD_INDEX` (16-bit running counter).
    - Wait for `TDMA_RING_CONS_INDEX == PROD_INDEX` (polled) or for
      the TX-default IRQ (Tier 4).
12. **RX ring init**: mirror TX but on the RDMA block at offset
    `0x2000`. Program each of the 256 BDs with its own DRAM buffer
    address. Initialize SW's `c_index` from HW's `PROD_INDEX` so you
    don't see stale frames.
13. **RBUF passthrough**:
    `RBUF_CTRL |= RBUF_ALIGN_2B` (so L3 hdr lands 4-byte aligned),
    `RBUF_TBUF_SIZE_CTRL = 1`. Without this the RDMA producer index
    never advances.
14. **Enable TX + RX**: `UMAC_CMD |= TX_EN | RX_EN`, set the speed
    bits, optionally `PROMISC` while bringing up.

### Gotcha #2: RDMA's per-ring register layout is MIRRORED from TDMA

This is the **second** GENET-specific trap that is not flagged in any of
the public references (Linux gets it right by construction because the
macros are split per-direction; if you read the U-Boot driver and
naively reuse the TDMA per-ring offsets for RDMA you will lose hours).
Within each per-ring 0x40 register slice:

```
Per-ring slice offset (within one ring's 0x40 window):
  0x00:  TDMA = READ_PTR         RDMA = WRITE_PTR
  0x08:  TDMA = CONS_INDEX (HW)  RDMA = PROD_INDEX (HW)
  0x0C:  TDMA = PROD_INDEX (SW)  RDMA = CONS_INDEX (SW)
  0x2C:  TDMA = WRITE_PTR        RDMA = READ_PTR
```

The producer/consumer pair is at **swapped offsets** for the two
directions: on TDMA, software writes `PROD_INDEX` at +0x0C and hardware
writes `CONS_INDEX` at +0x08; on RDMA, hardware writes `PROD_INDEX` at
+0x08 and software writes `CONS_INDEX` at +0x0C. Reusing the TDMA
offsets verbatim for RDMA reads will tell you that `PROD_INDEX` is
stuck at zero forever — actually you're reading the SW-written
`CONS_INDEX` that has never been touched. Hardware is delivering
frames; you're looking at the wrong register.

If you hit "tcpdump confirms RX frames on the wire but my driver's
`PROD_INDEX` stays at 0", check this first. Phoenix's GENET port spent
several iterations chasing legitimate-looking but unrelated fixes
(`DMA_DISABLE` handshake, `GR_BRIDGE_CTRL`, `RBUF_64B_EN`, XON/XOFF
thresholds, the full 256-BD aliased ring) before the actual root cause
turned out to be three lines of bad macro reuse. The `GENET_RDMA_RING_*`
constants in Phoenix `bcm-genet-regs.h` capture the right offsets;
copy that table, not the TDMA one.

Once the RX index is read from the right offset, the previously-tried
"legitimate" fixes (`DMA_DISABLE` handshake, XON/XOFF threshold,
`RBUF_64B_EN`) all still apply — they are real init steps Linux does
in the same order. Skipping any of them is fine on first boot but
likely to break on driver re-init.

### Reference drivers

- Linux `drivers/net/ethernet/broadcom/genet/` (the canonical reference;
  ~6 kLOC across `bcmgenet.c`, `bcmmii.c`, `bcmgenet_wol.c`).
- U-Boot `drivers/net/bcmgenet.c` (~600 LOC, polled-only, smallest
  proven path to "TFTP works").
- Circle `lib/bcm54213.cpp` (~1.9 kLOC, MIT-ish, fully bare-metal,
  IRQ-driven TX with polled RX).
- FreeBSD `sys/arm64/broadcom/genet/if_genet.c` (BSD-2, fully working).
- NetBSD `sys/dev/ic/bcmgenet.c` (the original BSD port).


## V3D GPU: 3D acceleration (OpenGL + Vulkan)

The BCM2711 has two distinct graphics blocks, and confusing them wastes days:
- **VideoCore VI (VC6)** — the firmware-owned media/display/clock block reached via the
  mailbox property interface (framebuffer alloc, HDMI mode, clocks). It stays live after
  handoff (see "VideoCore remains live after handoff").
- **V3D 4.2** — a *separate* Broadcom 3D render core (the OpenGL ES / Vulkan-capable GPU),
  MMIO-mapped and driven directly by the OS. Everything below is about V3D.

### Reuse Mesa; do not hand-write a driver
Mesa already has a complete, correct V3D backend: the **`v3d` gallium driver** (OpenGL) and
**`v3dv`** (Vulkan). Porting that code is far cheaper and more correct than hand-encoding
QPU shaders or CLE command lists — this yielded full textured OpenGL (GLQuake) and real
SPIR-V Vulkan (vkQuake) on hardware. Take Mesa's CLE packers and NIR→QPU compiler as-is;
only the **winsys** (the thin layer that submits work to the GPU) is OS-specific.

### In-process winsys, no DRM
There is no DRM kernel driver. The winsys:
- mmaps the V3D register window and pokes it directly;
- gives the GPU a **flat 128 MiB page table** for GPU virtual addresses (simplest correct
  MMU setup; a BO is just mmap + virt→phys);
- submits a control list as **CT0 (binner) + CT1 (render)** via QBA/QEA, then waits on
  **FLDONE/FRDONE**; issues an **SLCACTL / L2T cache flush per submit** (omitting it =
  stale-tile corruption);
- disables early-Z (**EZ**) where the tile pipeline requires it.
V3D 4.2 has **no ray-query hardware** — gate any Vulkan RT path off (V3DV reports it
absent; do not run RT lightmap/shadow shaders or you get garbage).

### Presentation: no-WSI, and the scanout reads color-buffer ALPHA
There is no swapchain / `VK_KHR_surface`. The app renders into an image backed by the
`/dev/fb0` framebuffer and the **HDMI scanout displays that image directly**. The sharp
edge: **the scanout samples the color buffer's ALPHA channel** (a real swapchain ignores
it). So *opaque* geometry must write **alpha = 1.0**, or low-alpha pixels vanish on screen
though they rasterized correctly — this single gotcha cost ~40 debug cycles on vkQuake
(vanishing torches). If you later add a real `VK_KHR_swapchain`, back its images with fb0
and make present a framebuffer page-flip.

### Serialize the mailbox (display + GPU share it)
The GPU winsys and the display both talk to the VideoCore mailbox; concurrent access (e.g.
one path reading virtual width/height while another flips) races into flicker /
single-buffering. Route **all** mailbox traffic through one serialized owner (on Phoenix:
`/dev/vcmbox` via `libvcmbox`).

### Firmware governs buffering — pin it
The RPi firmware (`start4.elf`) decides framebuffer double/triple buffering. A newer
`start4.elf` can silently deny the 3× virtual framebuffer the loader requested → revert to
single-buffered → tearing. **Pin the firmware SHA** in your build; treat unexplained
tearing after a firmware bump as this.

### References
- Mesa `src/broadcom/` (CLE + NIR→QPU compiler) + `src/gallium/drivers/v3d` (GL) +
  `src/broadcom/vulkan` (v3dv).
- `docs/knowledge/gpu-vc6.md` / `gpu-vc6-non-linux.md` (deeper VideoCore/V3D notes).
- Linux `drivers/gpu/drm/v3d/` — the DRM submit/MMU reference the winsys mirrors.


## Display (framebuffer / HDMI) & audio

### Getting a framebuffer
The firmware owns the display. Allocate a framebuffer through the **mailbox property
interface**: set physical W/H, virtual W/H, depth (32 bpp), then read back the base
**physical address + pitch**. Map it uncached and you have a linear ARGB surface the
VideoCore scans out to HDMI. Phoenix exposes it as **`/dev/fb0`** (the `rpi4-fb` userspace
driver). The HDMI mode itself is chosen by the firmware from `config.txt` / EDID; you read
the resulting geometry (e.g. 1920×1080×32) from `GET_VIRTUAL_WH` or the alloc response.

### Double/triple buffering = a tall virtual framebuffer
There is no page-flip register. You request a **virtual height = N × physical** (the loader
asks for 3×) and "flip" by setting the **virtual Y-offset** via `SET_VIRTUAL_OFFSET` — the
scanout then reads a different band. Whether the firmware grants 3× depends on the firmware
build, so **pin `start4.elf`** (an unexpected drop to single-buffer = tearing; see the V3D
section). All mailbox users (display *and* the GPU winsys) must go through **one serialized
owner** (`/dev/vcmbox` / `libvcmbox`) or the shared property buffer races.

### Analog audio (3.5 mm) = PWM
The headphone jack is driven by **PWM1 on GPIO40/41 (ALT0)**. Set the PWM clock to an
audio rate (~44.1 kHz-derived), put PWM1 in its serialized/audio mode, and feed 16-bit
stereo samples into the FIFO — via **DMA** for glitch-free playback (PIO works for
bring-up but underruns under load). Phoenix exposes **`/dev/audio0`** (`rpi4-audio`). HDMI
audio is a *separate* VideoCore path (mailbox/HDMI), not the PWM block.

### These are all userspace MMIO drivers
`rpi4-fb`, `rpi4-audio`, `rpi4-thermal`, `rpi4-gpio`, `rpi4-hwrng` are **userspace**
drivers: mmap the peripheral's MMIO page (uncached) and poke registers — no kernel driver.
The mailbox ones additionally serialize through `/dev/vcmbox`. See
`docs/knowledge/userspace-mmio-driver-pattern.md`.


## UART & console

### PL011 vs mini-UART

BCM2711 ships with multiple UARTs. The two that matter for bring-up:

- **PL011** at ARM-side phys `0xFE201000` — the canonical ARM PrimeCell
  UART, full feature set, FIFOs, interrupts.
- **mini-UART** at `0xFE215040` — a simpler, slower (8-bit FIFO) UART
  whose baud is tied to the core clock; useful when PL011 is needed
  elsewhere.

By default `start4.elf` routes the PL011 to Bluetooth (BCM43455) and the
mini-UART to GPIO14/15 (the header pins). For debug-console work this
is exactly backwards — you want PL011 on the header pins.

Add to `config.txt`:

```
dtoverlay=miniuart-bt        # swap: mini-UART → BT, PL011 → header
enable_uart=1
uart_2ndstage=1              # firmware also logs to UART
init_uart_baud=115200
init_uart_clock=48000000
```

The `init_uart_clock=48000000` line pins the PL011 reference clock to
48 MHz, so the PL011 divisor is independent of the core clock. `force_turbo=1` keeps the core
clock fixed at `core_freq` (500 MHz since 2026-09-27; it was pinned at 250 before), which the
Bluetooth mini-UART needs: its baud divisor is computed once from the core clock at driver start.

### Two paths to the wire

A subtle thing if you have both a UART debug console and an HDMI
framebuffer console:

- **Path A** (direct MMIO from kernel): busy-wait on PL011 `FR.TXFF`,
  write to PL011 `DR`. Synchronous, byte-by-byte. Used by early-boot
  `printf`/`debug()` paths. Does **not** mirror to any other sink.
- **Path B** (userspace TTY mirror): kernel writes go to a TTY device
  via the syscall layer; the TTY driver writes to PL011 **and** to the
  HDMI framebuffer (per-pixel drawChar).

A typical bring-up bug pattern: hundreds of lines visible on UART, only
a handful visible on HDMI. The cause is that early kernel messages take
Path A and never reach the TTY mirror. Knowing which path each message
takes is essential when diagnosing "boot looks stuck" issues — periodic
HDMI screenshots from a capture card complement the UART log because
they capture some Path-B-only state changes that arrive late or in a
different order.

### The klog ring is a *third* path — and the source of "non-deterministic"
logs

In Phoenix specifically there is a third, easy-to-miss path. Kernel
`lib_printf` does **not** go straight to the wire; it appends to a fixed-size
**klog ring** (`log/log.c`), which is drained to the console only by a
*userspace* reader (libklog → the TTY driver) that attaches **late** in boot.
On Pi 4 that reader historically never attached at all (it resolved
`/dev/kmsg` through devfs, whose bind/lookup is slow/fragile here — the TD-14
class). Net effect: a *variable* amount of early `lib_printf` output reached the
console depending on ring-overflow-vs-drain timing — which presents as
"boot logs are long on some boots, short on others" and looks like a
base-OS determinism bug but is purely an **observability artifact**. Before
trusting *any* boot-to-boot comparison, make the console faithful first.

The fix that worked (2026-06-02), and the general shape to copy:

- **Permanent kernel mirror for the UART.** In `log_write`, mirror every byte
  straight to the console (`hal_consolePutch`) unconditionally — do *not* gate it
  on "a reader has attached". The UART then carries the kernel's own complete,
  ordered boot log with zero dependency on userspace coming up. This is the
  source of truth.
- **Split sinks for HDMI.** The framebuffer is owned by the userspace TTY
  process, so the kernel can't write it directly. Have that process attach to the
  klog ring **directly by message to the well-known kernel log port** (in Phoenix
  the kernel log is served at port 0, id 0 — created before any userspace) rather
  than resolving a devfs path, and have its klog callback write **only** to the
  framebuffer (never re-emit to the UART). Then the UART (mirror) and HDMI (ring
  drain) carry the same content with no double-printing.
- **One lock for all console writers.** With multiple cores and every userspace
  `debug()` syscall funnelling through the kernel console (`hal_consolePrint`),
  unlocked writes interleave character-by-character. Serialize all console output
  through a single console lock. Watch the granularity: a *per-byte* locked mirror
  still lets a *per-string* `hal_consolePrint` splice into the middle of a
  mirrored line — eliminate the contended writers (diagnostic spam emitted *during*
  userspace activity) rather than decorating each flush (e.g. routing the mirror
  through a colour-adding print injects escape codes mid-line).

Result on Pi 4: exactly the same UART line count and a byte-identical HDMI final
frame across 10 consecutive boots.

### Cost of byte-by-byte busy-wait

Each character takes one UART-frame-time on the wire (≈87 µs at 115200
baud) plus the FIFO fill/drain pacing. For a kernel with ~100 KB of
debug output during boot, that is **several seconds of pure UART stall
time** on top of the actual work. If your boot looks too slow, count
your debug strings before profiling the kernel.


## Debugging strategy

The most useful tools for Pi 4 bring-up, in order of how often they
save the day:

1. **A captive netboot bridge with `tcpdump`.** Host the TFTP server
   yourself, run `tcpdump` on the bridge interface, and you can see
   every frame the Pi sends or rejects. Several Pi 4 networking bugs
   are only diagnosable from the host side (the Phoenix Tier 3 RX bug
   was first confirmed by `tcpdump` showing the bridge's unicast ARP
   reply while the Pi's RDMA ring stayed empty).
2. **QEMU's gdbstub for early-boot state.** `qemu-system-aarch64
   -machine raspi4b -kernel kernel8.img -s -S` lets you single-step
   the kernel entry, inspect registers, and watch the MMU/cache enable
   step in a controlled environment. The platform model is imperfect —
   PCIe / VL805 / GENET / HDMI behave differently from silicon — but
   for "what does my SCTLR write actually do" the gdbstub is fast and
   reliable.
3. **UART markers per stage.** A single-character `putc` at the entry
   of each boot stage costs nothing and tells you which stage the
   system reached. If you have hangs that look like "no output at all",
   it usually means you crashed before reaching `putc`; if you have
   hangs after a specific marker, you have a 1-stage-wide search space.
4. **HDMI screenshots from a USB capture card.** The framebuffer
   sometimes carries text the UART path doesn't (or carries the same
   text in a different order, which itself is informative).
5. **Cross-referencing what Linux, FreeBSD, Circle, U-Boot, and ATF
   do** for the same hardware. This is the move that broke the
   Phoenix `PC=0x400498` mystery (see war stories below). Anything
   every other working stack does and your code doesn't is a real
   candidate root cause.

A diagnostic anti-pattern: iterating on the same bit of code (cache
enable, DMA bring-up, PCIe register write) for days without sanity-
checking the **EL3-only setup** beneath it. EL3 setup written into the
armstub doesn't change when you `make` the kernel, so kernel-side
edits cannot fix EL3 bugs. The same kernel code can be correct on one
ARMv8-A platform and crash on another because of EL3-only setup that
the kernel doesn't see.


## Pitfalls and war stories

This section is short on purpose. Each item is a real bug that cost
someone real time during a Pi 4 port.

### The `S3_1_C15_C2_2` silent corruption

A common header for "A72 r0p3 errata sysreg" names
`CPUACTLR2_EL1 = S3_1_C15_C2_2`. That encoding is **not a documented
A72 sysreg**. Writes to it are not guaranteed to have any effect; they
may also silently corrupt whatever physical reg happens to live at that
encoding on a given silicon revision. The correct workaround target
for erratum 1319367 on Cortex-A72 r0p3 is `CPUACTLR_EL1[46]` (encoding
`S3_1_C15_C2_0`, same register as erratum 859971, different bit). Trust
ARM Trusted Firmware's `cortex_a72.S errata_a72_1319367_wa` over any
third-party header.

**Phoenix war story.** For weeks the Phoenix kernel crashed at
`PC=0x400498`, `ESR=0x02000000`, `FAR=0x0` immediately after enabling
`SCTLR_EL1.M|C|I`. The fault site was the first cacheable D-side load
following the SCTLR write — a literal-pool fetch with PC-relative
addressing. Every variant of the kernel cache-enable sequence — M-only,
M|C, staged, deferred, with various dsb/isb/ic-iallu permutations —
crashed at the exact same PC. The root cause turned out to be two EL3
bugs:

1. The armstub used `S3_1_C15_C2_2` for erratum 1319367. The
   mitigation never actually applied.
2. The armstub never programmed `L2CTLR_EL1 = 0x22`. The A72 cluster
   L2's data RAM timing was at the TRM default, which BCM2711's
   1.5 GHz silicon does not meet. The first cacheable load after
   `SCTLR.C=1` returned corrupt data.

The fix was a two-line change to the armstub. The kernel code, which
had been edited and re-tested dozens of times, was unchanged.

The lesson: **before iterating on kernel SCTLR/cache code, cross-check
your EL3 setup against the canonical Pi armstub, against ARM Trusted
Firmware's `plat_reset_handler`, and against the Cortex-A72 TRM's
"Initialisation requirements" section.** Different SoCs need different
EL3 setup. Same kernel code can be correct on one platform and crash
on another because of EL3-only setup that doesn't survive any kernel
change.

### PCIe `0xDEADDEAD` after a perfectly correct mmap

VL805 BAR0 is 4 KiB. If you map 64 KiB across it (a common copy-paste
from x86 xHCI bring-up where MMIO regions are 16 KiB+), speculative or
compiler-coalesced reads spill past the BAR, the brcmstb RC aborts the
access, and you see `0xDEADDEAD`. See the PCIe section for the full
multi-cause analysis; the headline is **probe the BAR size, map
exactly that**.

### GENET TX without `SYS_PORT_CTRL = EXT_GPHY`

`SYS_PORT_CTRL` defaults to `0` (`PORT_MODE_INT_EPHY`). On Pi 4 the
internal EPHY is not the active interface — the MAC needs to drive the
**external** BCM54213PE over RGMII. Without changing this register the
TDMA engine **silently consumes descriptors via CONS_INDEX** but
nothing reaches the wire. From the driver's perspective TX looks fine.
From a host `tcpdump`'s perspective the Pi is invisible.

### GENET TX BDs with `DMA_OWN` set

The `DMA_OWN` (bit 15) of the descriptor status word is an **RX-only**
convention on GENET. On RX the host clears it after consuming a frame
and the controller sets it when it deposits one. On TX the producer-
index write is the SW-to-HW handoff, and `DMA_OWN` must remain clear.
Setting it on a TX BD reproduces the silent-failure mode of the
previous bug.

### The Pi 4 firmware does not push the MAC into UMAC

Most BCM2835/BCM2837-era references (Pi 3, Pi Zero) say the VPU
firmware pre-programs `UMAC_MAC0`/`UMAC_MAC1` with the OTP MAC.
**This is not true on Pi 4** in shipping configurations. The firmware
patches the device tree `local-mac-address` property and expects the OS
to read it back into UMAC. If your driver reads `UMAC_MAC0/MAC1` and
trusts the result, you'll see `00:00:00:00:00:00` and lwIP will treat
your interface as deeply confused.

Workable strategies, in order of robustness:

1. Parse the DT and read `local-mac-address`. Requires a DTB parser
   in the right process.
2. Issue a mailbox property request with tag `0x00010003`. Requires the
   mailbox interface up.
3. Fall back to a locally-administered MAC for bring-up only; flag in
   logs.

### The 4 GB DTB has two `/memory@*` nodes

Reiterated here because it has bitten enough porters. A DT parser
walking only the first `/memory*` node will see ~948 MB and lose the
upper 3 GB. Make sure your parser handles multiple memory nodes from
day one; retrofitting is more painful than starting that way.

### The VPU keeps running

Treating the GPU reserve as cacheable system memory is wrong. The VPU
writes to it (HDMI scanout, mailbox responses if you put the buffer
there). A cacheable alias on the ARM side will read stale data and may
write dirty lines back over the VPU's writes on eviction. Map the GPU
reserve as Device memory (or Normal-NC) and accept the throughput cost;
the alternative is invisible corruption.

### Single-shot `M|C|I` MMU enable can hang on A72 r0p3 + BCM2711

Even with all errata workarounds applied, some Pi 4 stacks find that
the bootloader/early kernel cannot reliably enable `M`, `C`, and `I`
of `SCTLR_EL1` in a single instruction. The workaround is staged enable
(`M` first; `C|I` later from a known-good cacheable PC). This is
historically Phoenix-plo's pattern; we have no published root-cause
analysis, but the workaround is reproducible.

### PCIe state after `NOTIFY_XHCI_RESET` is not deterministic

After the mailbox call that re-loads VL805's SRAM, the inbound DMA
bridge state can be left in a configuration where the first xHCI
`R/S = 1` triggers `USBSTS.HSE`. The defensive pattern is to re-disable
`RC_BAR1` and re-program `RC_BAR2` after the mailbox call, and to
revalidate every register you depend on before issuing the first DMA.
Even with those workarounds, some boots see HSE intermittently;
oscilloscope / JTAG tracing is the next step beyond code-only fixes.


## Phoenix-RTOS case study

This is the section where the document narrows from "any Pi 4 OS" to
"what specifically the Phoenix-RTOS port looks like at the time of
writing". Use it as **worked examples**, not as a recipe.

### Boot pipeline (Phoenix-specific)

```
start4.elf  →  phoenix-armstub8-rpi4.bin (replaces armstub8.bin)
            →  kernel8.img (a plo + reloc stub)
            →  initramfs loader.disk (kernel ELF, dummyfs, devfs, ...)

armstub (EL3):
  - LOCAL_CONTROL prescaler
  - CNTFRQ_EL0, CNTHCTL_EL2, CNTVOFF_EL2
  - SCR_EL3 (NS | RW | HCE | RES1)
  - CPUACTLR_EL1 |= bit 32 (859971) | bit 46 (1319367)
  - CPUECTLR_EL1 prefetch config + SMPEN
  - L2CTLR_EL1 |= 0x22 (BCM2711 1.5 GHz silicon timing)
  - GICv2 dist + CPU IF init
  - SCTLR_EL2 = 0x30c50830 (RES1 baseline, caches off)
  - eret → EL2 → drop to EL1 → branch into kernel8.img

plo (EL1, caches off):
  - PL011 init, HDMI mailbox + framebuffer
  - Identity-map ARM-visible DRAM (Normal-WB except GPU reserve as Device)
  - SCTLR.M = 1 only; caches stay off here (single-shot M|C|I hangs)
  - Parse user.plo.yaml; load programs to RAM; build syspage; jump to kernel

kernel (EL1):
  - TTBR0 identity map (low PA), TTBR1 high VA (0xffffffffc0000000)
  - Single-shot SCTLR_EL1 |= M | C | I after the staged ritual
  - Spawn dummyfs, pl011-tty, usb, lwip, psh
```

### Phoenix `config.txt` knobs

```
arm_64bit=1
armstub=phoenix-armstub8-rpi4.bin
kernel=kernel8.img
initramfs loader.disk 0x08000000
enable_uart=1
uart_2ndstage=1
init_uart_baud=115200
init_uart_clock=48000000
dtoverlay=miniuart-bt
force_turbo=1
core_freq=500
gpu_mem=76
hdmi_force_hotplug=1
disable_overscan=1
disable_splash=1
```

Tunable knobs worth knowing:

- `total_mem=` **caps** memory; cannot enlarge it. The high bank
  exposure on 4 GB+ Pi happens via DT nodes added by firmware, not via
  this config knob.
- `start_file=start4cd.elf` + `fixup_file=fixup4cd.dat` switches to the
  compact firmware (~850 KB vs ~2.3 MB); useful when you suspect VC6
  interference.
- `dtparam=audio=off` disables HDMI audio DMA paths.

### Memory layout actually in use on Phoenix 4 GB Pi 4

```
0x00000000 - 0x000000ff   armstub area (firmware also writes spin table here)
0x00000100 - 0x000fffff   free for early use
0x00080000 - 0x000fffff   kernel8.img landed here (default kernel_address)
0x00200000 - 0x003fffff   plo runtime (2 MB)
0x00400000 - 0x006fffff   kernel image runtime (low PA)
0x00700000 - 0x07ffffff   free general DRAM (low bank)
0x08000000 - 0x0Bffffff   initramfs (loader.disk)
0x0C000000 - 0x3b3fffff   free general DRAM (low bank, contiguous)
0x3b400000 - 0x3fffffff   76 MB GPU reserve
0x40000000 - 0xfbffffff   high bank, 3008 MB ARM DRAM
0xfc000000 - 0xfeffffff   peripherals
0xff800000 - 0xff8fffff   ARM-local controllers (GIC, etc.)
```

### Reading a Phoenix boot trace

The Phoenix UART output is dense with single-character per-stage
markers. The marker values here are **Phoenix-specific examples**; if
you adapt the decoder to your own port, change the table to match the
markers you emit.

| Source | Marker | Meaning |
|---|---|---|
| firmware | `MESS:HH:MM:SS.xxxxxx:...` | start4.elf log lines |
| firmware | `MEM GPU:NN ARM:NN TOTAL:NN` | low-bank-only memory split |
| firmware | `arm_loader: Starting ARM with NNMB` | low-bank ARM size |
| armstub | `1` | erratum 859971 + 1319367 workarounds applied |
| armstub | `4` | L2 prefetch policy applied |
| armstub | `2` | SMPEN applied |
| armstub | `5` | `L2CTLR_EL1` BCM2711 timing applied |
| armstub | `A`,`S0` | EL3 final steps + GIC + drop-to-EL2 |
| plo | `hal: console_init done` | PL011 + console layer up |
| plo | `mem: pre/post-init` | `mmu_init` done |
| plo | `mem: pre/post-iallu` | I-cache + TLB invalidate |
| plo | `mem: pre/post-sctlr-M` | SCTLR.M=1 applied (caches stay off) |
| plo | `draw: pre/post-bg-fill` | HDMI framebuffer cleared (blue) |
| plo | `Phoenix-RTOS loader v. 1.21` | banner |
| plo | `call: exec ...` | parsing `user.plo.yaml` |
| plo | `go: enter ... go: jumphal` | jumping to kernel |
| plo | `hal: jump irq off`, `hal: jump exit el1` | cache+MMU teardown done |
| kernel | `A1` | `_start` entry (low PA) |
| kernel | `ZK[LSTUMV` | TTBR0/TTBR1 build progress markers |
| kernel | `X1..X5` | early SCTLR-flip stages |
| kernel | `N!YOPSTUZbcdtd15:OK` | post-flip checkpoint sequence |
| kernel | `td16:cf=...` | tag-16 syspage checkpoint |
| kernel | `T{...}O{...}h{...}` | program-reloc map walk |
| kernel | `lmnPp01234567ZYfhRI` | `_hal_init` enter |
| kernel | `Phoenix-RTOS microkernel v. 3.3.1` | banner |
| kernel | `vm: ...` | VM init |
| kernel | `threads: ...` | scheduler events |
| kernel | `main: spawn ...` | spawning user-space processes |
| kernel | `smp: intr/ppi/tmr/tick cpuN=...` | per-CPU SMP enumeration |
| userspace | `name: registered ...` | dummyfs/devfs registration |
| userspace | `pl011-tty: tty0 lookup` | pl011-tty serving |
| userspace | `usb-daemon: ...` | USB daemon |
| userspace | `xhci-pcie: ...` | xHCI HC init |
| userspace | `pcie: ...` | PCIe scan / VL805 program |
| userspace | `lwip: genet@fd580000: ...` | GENET driver |
| userspace | `psh: ...` | shell startup |
| userspace | `(psh)% ` | interactive prompt |
| exception | `EX=N ESR=... ELR=... FAR=...` | early-vector dump |

### Worked example: the `PC=0x400498` crash

See the war story in the previous section. The TL;DR is that two EL3
bugs combined to make every cacheable D-side load after `SCTLR.C=1`
return corrupt data. The fix was in the armstub, not the kernel.

### Worked example: the USB merge

Phoenix originally had two userspace processes for the BCM2711 USB
stack: a `pcie` daemon (bridge bring-up) and the `xhci` driver. Each
opened its own `mmap` of the PCIe outbound window. The second `mmap`
returned `0xDEADDEAD`-pattern reads — BCM2711's PCIe bridge translation
state is per-process / per-mmap. The fix was to fold bridge bring-up
into the xHCI library so a single process owns the bus and the
controller. This is the convention Phoenix already follows on every
other supported board (imx6ull, imxrt106x/117x, ia32); Pi 4 was the
outlier that forced re-discovery.

A follow-up question worth testing — what about *read-only* access to
xHCI MMIO from a side process? The "USB merge" finding established
that two writing processes break; reads from a side process haven't
been characterized. It was later answered (H3 below) with the since-removed
diag-udp responder (see §"Network-routed observability"). See
`docs/done/usb-resumption-strategy.md` for the resumption plan that uses
this and three other hypotheses to revisit the parked USB wedge.

### USB resumption hypotheses (2026-05-25) — RE-ANALYZED 2026-05-29

> **Correction (2026-05-29).** The "H4 = silicon variability, LEADING
> CANDIDATE" conclusion recorded here on 2026-05-28 has been **retracted**.
> A three-agent re-analysis (forensic re-derivation from the raw UART logs
> + a code-correctness deep-read of the live driver) found the USB failure
> is most likely a **software bug**, not silicon. Full detail:
> `docs/done/2026-05-29-usb-reanalysis.md`. The original table and bench
> are kept below for history, annotated.

The diag-udp infrastructure cheaply tested four hypotheses:

| H | Hypothesis | Outcome |
|---|------------|---------|
| H1 | cmd-ring TRBs in a domain VL805's DMA can't see | RULED OUT — cmd TRBs visible; CRR 0→1 but completion never lands |
| H2 | PMIC under-voltage correlates with HSE | RULED OUT — `GET_THROTTLED` clean |
| H3 | Side-process MMIO reads return 0xdeaddead | RULED OUT — side-process reads succeed |
| H4 | Genuine silicon variability | ~~LEADING CANDIDATE~~ **RETRACTED 2026-05-29 — not supported by the logs** |

**What the 2026-05-29 re-analysis actually found:**

- **Two distinct problems were merged.** The *PoC* fails **100%
  deterministically** (bridge up, `CRR=1`, `first event @idx -1` — zero
  events DMA-written); the *rig* fails *intermittently* with a **different**
  signature (`pre USBSTS=0x00`/`0xdead`, bridge MMIO dead). A deterministic
  failure is not silicon flakiness.
- **The bench below is confounded and the "0/21" elsewhere was inflated.**
  The rig fires minutes post-boot under live GENET traffic; the PoC fires
  at a fixed 10 s — so the table compares different *conditions*, not two
  code paths. Separately, ~12 of the "21" PoC trials cited in other docs
  were truncated before any verdict (powered off / capture too short) and
  are not evidence; the honest count is 0 of ~18 *decidable* runs.
- **The rig's 2 successes enumerate the VIA hub (VID 2109), not the K120
  keyboard** — they never demonstrated a working keyboard.
- **The rig's intermittency** fits the project's own documented
  rapid-cycle bridge-degradation window (≥30 min idle needed; the runs
  were 3–6 min apart) — a software/cadence cause, not silicon.
- **Concrete `xhci.c` bugs** were found that the silicon framing masked:
  the event ring is never advanced (cycle state never toggled, ring
  memset/re-read at index 0 — xHCI §4.9.4 violation, blocks command #2);
  the controller is halted/restarted around every command; DMA rings are
  recycled across runs on a non-coherent fabric without a cache-clean
  (recycled-page hazard — leading non-silicon explanation for the rig's
  intermittency); `resettleOutboundWindow()` is a silent no-op in the live
  DRIVE_ONLY path. The VL805-firmware and MSI hypotheses are disproven.

**Original 2026-05-28 bench (kept for history; conditions confounded):**

| Variant | Trials | Succeeded |
| --- | --- | --- |
| Full PoC bring-up                | 8 | 0 |
| PoC DRIVE_ONLY                   | 4 | 0 |
| PoC MaxSlotsEn=1                 | 2 | 0 |
| PoC contig scratchpad            | 4 | 0 |
| PoC no-bridge-mmap (DRIVE_ONLY)  | 3 | 0 |
| Reference 'X' diag rig           | 4 | 2 |

The real mainline-Linux VL805 silicon issue
([raspberrypi/linux#5060](https://github.com/raspberrypi/linux/issues/5060);
3.3V→nPONRST RC-delay reflow for some boards) is genuine but is **not**
established as our cause — USB keyboard always works on this exact board
under Linux and the firmware boot menu.

lwip PR #133 (i.MX6ULL `cyhal_sdio.c` DMA barriers) remains correctly
ruled out: Pi 4's SDIO path is PIO (`SDHCI_DATA_PORT` FIFO), no DMA
buffer to fence.

**Next (no JTAG):** read-only experiments first (trigger the rig at the
PoC's 10 s mark to separate timing from code; allocate-rings-once vs
munmap-per-run to test the recycled-page hazard), then fix the timing/DMA
variable so any event lands, then a targeted event/command-ring rewrite.
See `docs/done/2026-05-29-usb-reanalysis.md`.

### Worked example: GENET Tier 1 → Tier 5d

The full progression for the Phoenix port through to a production-grade
driver. Each tier ends in a manifest pinning all sibling SHAs and a
doc note explaining what changed.

- **Tier 1 — link-up.** Map MMIO, read `SYS_REV_CTRL`, reset UMAC,
  MDIO bus + BCM54213PE attach, autoneg, link-up. Manifest:
  `2026-05-24-eth-tier1-link-up.md`.
- **Tier 2 — TX one packet.** TDMA ring 16, single-slot polled TX,
  `result=0` on a synthetic gratuitous-ARP. Two key fixes that the
  initial implementation got wrong: `SYS_PORT_CTRL = EXT_GPHY` and
  dropping `DMA_OWN` from the TX BD status. Manifest:
  `2026-05-24-eth-tier2-tx-ok.md`.
- **Tier 3 — RX one packet, polled.** Resolved 2026-05-25 after the
  RDMA-register-mirror finding above. Manifest:
  `2026-05-25-eth-tier3-rx-ok.md`.
- **Tier 4 — lwIP integration + ICMP end-to-end.** Static IP
  `10.42.0.99/24` (autonomous DHCP was deferred at this tier — see
  Tier 5d below for the closure), full
  ARP-request → ARP-reply → ICMP echo-reply chain. 5/5 host pings
  succeed at 3.7–16.8 ms RTT (polled, with per-RX printf still in
  place). Two lwip-port wiring fixes were load-bearing:
  `pbuf_take_at(p, frame, pay_len, ETH_PAD_SIZE)` for RX (lwip's
  ethernet_input does `pbuf_remove_header(p, 2)` before reading the
  L2 header — the pbuf must carry 2 bytes of head pad) and matching
  `pbuf_copy_partial(p, tx_buf, p->tot_len - 2, 2)` on TX (this
  lwip-port leaves the 2-byte pad ON the pbuf when calling
  linkoutput). Manifest: `2026-05-25-eth-tier4-icmp-ok.md`.
- **Tier 5 — IRQ-driven RX.** Replaced the 10 ms RX polling thread
  with a Phoenix-pattern `interrupt()` handler + cond-driven service
  thread on `INTRL2_0_RX_DMA_DONE` (GIC SPI 157 = abs IRQ 189). Per-RX
  printf removed. Result: 5/5 host pings at RTT **0.61–1.17 ms**
  (avg 0.92 ms) — ~8× faster than Tier 4. The bulk of the improvement
  was removing the per-frame printf (kernel-klog round-trip dominated
  per-packet latency); the IRQ-vs-poll shift contributed the
  remainder. Manifest: `2026-05-25-eth-tier5-irq-rx.md`.
- **Tier 5 sustained-load smoke.** 4-phase host-side probe:
  baseline 100 @ 200 ms, fast 500 @ 10 ms, 1400 B jumbo 100 @ 50 ms,
  10-second `ping -f`. Zero loss across all phases, ~1.66 Kpps
  sustained in phase 4, worst-case RTT 2.09 ms. No `tx_timeout`, no
  kernel faults.
- **Tier 5b — real MAC from VideoCore mailbox; PROMISC off.** The
  fallback locally-administered MAC plus `CMD_PROMISC` was a Tier-1
  workaround for the "Pi 4 firmware doesn't pre-program UMAC_MAC0/1"
  caveat noted in the bring-up section above. Tier 5b plumbs the
  BCM2835 mailbox property `GET_BOARD_MAC` (tag `0x10003`) directly
  in `bcm-genet.c`. Validation: host ARP table for `10.42.0.99` now
  reports `dc:a6:32:*` (real Raspberry Pi Trading Ltd OUI). PROMISC
  is cleared on the unicast filter path; 5/5 pings still succeed
  with the unicast filter active. Manifest:
  `2026-05-25-eth-tier5b-mailbox-mac.md`.
- **Tier 5c — net-routed observability (UDP diag responder).**
  Solves the more-general post-fbcon UART silence problem: with the
  GENET driver running, expose Phoenix internal state over the
  network. A tiny `port/diag-udp.c` listens on UDP `:9999` and
  answers a single-byte command with a structured ASCII reply.
  Sub-commands grew to cover: per-netif stats (`q`), top threads by
  cpuTime (`t`), 4-thread saturation burn (`b`), Pi 4 GPIO snapshot
  (`g`), clock+power+thermal+SDHCI register dump (`c`), BCM2711 PM
  watchdog reboot/halt (`r`/`h`). The pattern generalises beyond Pi 4
  and is the recommended observability surface for any future
  multi-threaded Phoenix-on-aarch64 work. Manifest:
  `2026-05-25-eth-tier5c-diag-udp.md`. See also the "Network-routed
  observability" subsection below. (The responder was removed on
  2026-06-06, lwip `05b8ba4`; this entry is kept as history.)
- **Tier 5d — autonomous DHCP (TD-Eth-DHCP CLOSED 2026-05-28).** With
  the GENET driver in steady state, `dhcp_start()` was re-enabled in
  `genet_dhcpStartCb` (previously commented-out because the early-Tier
  driver lost the first DHCP OFFER frame). End-to-end verification:
  `dnsmasq` lease file records `dc:a6:32:3c:dd:f1 → 10.42.0.12`, and
  the diag-udp `q` reply confirms `netif: en1 ip=10.42.0.12 gw=10.42.0.1
  flags=0x1f UP LINK DHCP rx=5 tx=12 mac_src=mailbox`. The static
  `10.42.0.99/24` fallback is kept for the dnsmasq-less / raw-cable
  bring-up case. Two tooling additions made the closure cheap:
  `scripts/test-cycle-netboot.sh --probe q` ran a background diag-udp
  probe in the same test cycle (retired with the responder), and
  `scripts/get-pi-ip.sh` resolves
  the current DHCP-assigned IP by reading
  `artifacts/netboot/dnsmasq.leases` so probes don't need a hard-coded
  address. Manifest: `2026-05-28-eth-tier5d-dhcp-closed.md`.

### SMP Phase E worked example

SMP Phase D landed earlier (all 4 Cortex-A72 cores wake, complete HAL
init, dispatch threads, take timer ticks balanced across cores). Phase E
is the validation question: do the four cores actually pull non-idle
work independently, or is dispatch all on cpu 0 with cpu 1-3 just
ticking through idle threads? The diag-udp `t` and `b` sub-commands
let us answer this rigorously **without UART**.

**Method.** Two paired probes:

1. *Idle endpoint.* Two `t` probes 10 s apart on an otherwise-idle
   system, decoding the per-thread `cpuTime_us`. If the 4 `[idle]`
   threads (one per CPU) each accumulate ~10 s of cpuTime in 10 s of
   wall-clock, the sum is `≈ 4 × Δwall` — which is only achievable
   if 4 independent schedulers are running, one per core.
2. *Saturation endpoint.* `b` spawns 4 busy-loop threads inside the
   lwip-port for 10 s, then paired `t` probes during the burn window
   measure their cpuTime accumulation. If each burner accumulates
   `~Δwall × 0.94` (94% of a CPU), `ΣΔcpu ≈ 3.77 × Δwall` —
   saturation-side proof that 4 cores each picked one up.

**Observed.** Both endpoints validated; closes the validation gap for
SMP. Manifests: `2026-05-25-smp-phase-e-validated.md`,
`2026-05-25-smp-phase-e-saturation.md`.

### Worked example: WiFi P3 firmware load

After SDIO Tier 4 (chip-id readback, see "Platform utilities" below)
the next milestone for BCM43455 is loading the brcmfmac firmware
into the chip's SOCRAM and releasing the on-chip ARM-CR4 so it
executes. The arc broke into:

1. **Block-mode CMD53.** Earlier tiers used CMD52 (byte-at-a-time)
   which is unusable for a 643 KB firmware blob. CMD53 in block
   mode + 4-bit bus width is the production path. The Phoenix
   implementation began in the (since-removed) lwip-port diag-udp
   responder and now lives in
   `sources/phoenix-rtos-devices/wifi/rpi4-wifi/rpi4-wifi.c`
   (`diag_sdioCmd53Read`/`Write`); it is **PIO**, not DMA — it polls
   `BUFFER_READ_READY` / `BUFFER_WRITE_READY` and writes 32-bit
   words to `SDHCI_DATA_PORT`. No host-side DMA buffer is used; the
   lwip i.MX6ULL `cyhal_sdio.c` DMA path is not on the Pi 4 boot
   path and PR #133's DMA-barrier fix has no Pi 4 equivalent.
2. **SBADDR window walk.** F1 SBADDRLOW/MID/HIGH (regs 0x1000A/B/C)
   relocate the 32 KB backplane window across SOCRAM. The firmware
   payload writes 32 KB per CMD53, then increments the window
   pointer and writes the next 32 KB. Multi-block CMD53 with
   `block_count=64 block_size=512` matches Linux brcmfmac's
   sdio_bus_txfr granularity.
3. **NVRAM trailer.** brcmfmac places NVRAM at the end of SOCRAM
   followed by a 4-byte length word and a "magic" trailer. The
   length must be written little-endian as bytes (not as a 32-bit
   word over a misaligned address).
4. **CR4 reset-vector + AXI resetcore toggle.** The ARM-CR4
   `ResetVec` register at chip-internal address 0 must contain the
   firmware's entry point (loaded from the first 4 bytes of the
   firmware blob — Broadcom firmwares embed the reset vector at
   offset 0). Then walk to the ARM-CR4 wrapper at 0x18103000 and
   toggle reset via `ResetCtrl` / `IoCtrl` per AXI Backplane core
   protocol (assert reset, clock-enable, release reset). Linux's
   `brcmf_chip_set_active` and Cypress WHD's
   `whd_chip_armcr4_run` are the cross-stack references.

**Current state.** Steps 1–4 implemented and individually validated.
The firmware-execution gate — observable readbacks of `CHIPCLKCSR.HT_AVAIL`
should set to 1 after firmware ALP-to-HT promotion, and the SDIO
`CARD_INTR` should start firing — is open: HT_AVAIL stays 0 and no
CARD_INTR. CR4 release sequence appears correct (matching all
public references inspected), so the leading hypotheses are:

- Firmware blob version mismatch with NVRAM (Cypress firmware/NVRAM
  pairs must match minor versions; mismatched pairs boot silently
  but don't enable HT clock).
- ARM-CR4 wrapper register layout difference between BCM43455
  revisions — c0 (our chip) vs older revs may have different
  IoCtrl bit positions.
- AXI clock-gating: ChipCommon needs `WL_REG_ON` plus a clock
  request before the CR4 wakeup will hit HT.

Parked behind USB for now; resumes once a USB enumeration is in
hand to compare two BCM43455-class chip-bring-up paths against the
same diag-udp infrastructure (since removed; the WiFi bring-up now lives
in `wifi/rpi4-wifi` in phoenix-rtos-devices).

**Bonus finding: per-thread shared-counter false sharing.** The first
burn implementation used a `volatile unsigned long long counters[4]`
array (all 4 slots fit in one 64-byte L1 cache line) with naive
`counter[slot]++` per inner iteration. Across 5 s of confirmed CPU
activity per burner, only burner 0's counter advanced. The other three
"stuck at 0" looks like a Phoenix bug but is just textbook false
sharing — 4 cores hammering one cache line, with non-atomic RMW races
losing most updates. Padding each slot to its own cache line (one
`_Alignas(64)` struct per counter) restores plain `volatile ++` to
ALU-speed throughput across all 4 cores. Documented as
`TD-Pi4-FalseSharingPenalty` in
`docs/TEMPORARY-FIXES-AND-FUTURE-CLEANUP.md`; the pattern guide there
is the suggested reference for any future multi-threaded userspace
code on Pi 4.

### Network-routed observability

> **Removed 2026-06-06 (lwip `05b8ba4`).** The Phoenix responder described
> here is gone: it was an unauthenticated network control surface (reboot,
> physmem dumps, live SDIO register writes) and diagnostic-only. The pattern
> write-up is kept because it generalises. On today's Pi 4 image, inspect the
> running system from psh instead (`scripts/test-cycle-psh-interact.sh`),
> through device nodes (`/dev/thermal`, `/dev/throttled`, `/dev/gpio`), or with
> a standalone probe binary run from psh (the `tools/wifi-probe` pattern).

The single biggest accelerator after Tier 4 was the discovery that —
once ethernet works — we don't need UART for runtime introspection any
more. Post-fbcon-takeover the pl011 goes silent for userspace prints
on Phoenix (kernel side keeps writing; userspace stdout routes
elsewhere). With a netif up, a tiny lwip raw-API UDP responder
(~140 lines in `port/diag-udp.c`, no extra threads, runs entirely on
the tcpip-thread) gives us a *better* channel than UART: structured
output, host-side scripting, no MTU truncation issues, no fbcon
serialization.

The pattern is broadly applicable to any aarch64 RTOS port:

1. Once a netif is up, listen on UDP `:9999` with `udp_new` + `udp_bind`
   + `udp_recv`.
2. Receive callback peeks the first byte of the request, dispatches
   to a small `diag_format_*` function per command, replies via
   `udp_sendto` from the same callback.
3. Each `diag_format_*` reads its target state synchronously (MMIO,
   syscalls, mailbox property tags) and writes a NUL-terminated
   text response. Cap at one MTU fragment (1400 B) to avoid IP
   fragmentation.
4. Host probes with `echo q | nc -u -w 1 <ip> 9999`.

The `g`/`c`/`s`/`r`/`h`/`t`/`b` Phoenix-specific commands are
illustrative but not the point — the point is that this is the
right surface for any platform-level read/write you need to do once
you can route packets. Phoenix uses it for: lwip stats, thread-cpu
distribution, GPIO/clock/power/thermal/SDHCI snapshots, the PM
watchdog reboot, a 4-thread CPU saturation benchmark. New entries
are one function + one switch case.

### In-process debugging: crash & hang backtraces (`libdbg`)

Phoenix has **no ptrace** (so stock `gdbserver` does not drop in) and its signal handlers get
**no `ucontext`** — the aarch64 ABI is the simple `sa_handler(int)` form. So a naive
frame-pointer walk from inside a `SIGSEGV` handler only reaches the signal *plumbing*
(`_signal_trampoline`, `_startc`), never the code that actually faulted. The fix is a small
libphoenix hook plus a reusable library:

1. **libphoenix enabler.** The kernel already memcpy's the interrupted `cpu_context_t` (with the
   faulting `pc`, `sp`, and all `x[]` incl. `x29` = frame pointer) onto the user signal stack.
   The aarch64 `_signal_trampoline` (`libphoenix/arch/aarch64/signal.S`) stashes that
   `cpu_context_t*` into a global `_dbg_signal_ctx` (and the leaf/fault PC into `_dbg_signal_pc`,
   because `signalCtx->pc` is overwritten with the handler address) before calling the handler.
   This is a few instructions on the signal path and needs no kernel change.
2. **`libdbg` corelib** (`phoenix-rtos-corelibs/libdbg`, link with `-fno-omit-frame-pointer`):
   - `dbg_init()` installs handlers for `SIGSEGV/SIGILL/SIGBUS/SIGFPE/SIGABRT`; on a crash it
     prints the faulting `pc` + a frame-pointer backtrace, then exits `128+signo`.
   - `dbg_backtrace(tag)` prints a backtrace on demand — from a signal handler it unwinds the
     **interrupted** code via `_dbg_signal_ctx`; otherwise it unwinds its caller.
   - `dbg_arm_watchdog(secs)` arms a re-arming `SIGALRM`; when a process **hangs**, the timer
     fires and the handler dumps a backtrace of wherever it is stuck — "process is wedged at
     function X" without a reboot. This is exactly what localizing an engine's init hang needs.
3. **Symbolize host-side**: `aarch64-phoenix-addr2line -f -e <elf> <printed return addresses>`
   (or feed the addresses to `gdb`). Keep the deployed ELF unstripped.

Because the whole facility is userspace + one static-linked trampoline tweak, you iterate by
swapping the NFS binary only — the board stays booted. The arch-specific frame walk is guarded
behind `__aarch64__`, so `libdbg` still builds (as a no-op backtrace) for other targets.

### Platform utilities discovered along the way

While building Phoenix's diag-udp responder we exercised several
Pi 4 platform primitives that any OS porter will eventually want.
Each is small (~30-80 lines) and worth pulling forward:

- **PM watchdog software reboot** (BCM2711 PM block at `0xfe100000`,
  PM_RSTC/PM_RSTS/PM_WDOG, password `0x5a000000`). 100 ms-deferred
  via a one-shot thread so the UDP reply egresses before the
  countdown fires. Saves ~30 s per test cycle vs an external
  smart-plug power-cycle. Same code path serves a `halt` via the
  `PM_RSTS_RASPBERRYPI_HALT = 0x555` magic. Manifest:
  `2026-05-25-watchdog-software-reboot.md`.
- **Thermal + throttle telemetry** via mailbox tags `GET_TEMPERATURE`
  (`0x00030006`), `GET_MAX_TEMPERATURE` (`0x0003000a`), `GET_THROTTLED`
  (`0x00030046`). The throttle bitfield decodes as bits 0-3 = now
  active, bits 16-19 = sticky-since-boot, for under-voltage / ARM-cap
  / throttling / soft-limit. Lab board at idle: SoC 34.5 °C, ceiling
  85 °C, throttle 0x0.
- **GPIO Tier 1 snapshot helpers.** `set_fsel(pin, fn)` /
  `get_fsel(pin)` / `set_pull(pin, code)` over the BCM2711 GPIO block
  at `0xfe200000`. The 'g' diag command dumps GPFSEL0..5, GPLEV0/1,
  GPIO_PUP_PDN_CNTRL_REG0..3 — enough to read full pin function and
  level state. Key Pi 4 finding for SDIO bring-up: GPFSEL3 reads 0
  at boot (GPIO 34-39 are INPUT, not yet routed to SDIO ALT3=7);
  PUP_PDN2 has pins 34-39 at pull-up (firmware-correct for idle SDIO
  bus). So WiFi bus-side bring-up is one GPFSEL3 write + a mailbox
  `WL_REG_ON` assert.
- **WiFi SDIO Tiers 1c–4 (DONE 2026-05-26).** The full Phoenix-side
  SDIO bring-up to chip-id readback was first implemented as diag-udp
  sub-commands `'w'/'i'/'e'/'f'`. Pi 4 result: CMD5 returns OCR
  `0x30ffff00` (3 IO funcs, 2.0-3.6V); CMD3/CMD7 enumerate to
  RCA=0x0001; CCCR rev byte `0x43` (SDIO 3.00 + CCCR/FBR 1.20);
  F0 CIS pointer 0x0010ac with first tuple `TPL_MANFID code=0x20
  vendor=0x02d0 device=0xa9a6`; CCCR 0x02 IOEn write enables Function
  1 in 1 ms; F1 SBADDR window points at ChipCommon (0x18000000) and
  reads back chip-id `0x15264345` — chip_id=0x4345, rev=6
  (BCM43455c0), pkg=1 (WLBGA). The Pi 4 thus carries the **same
  BCM43455c0** that Linux brcmfmac drives with
  `brcmfmac43455-sdio.bin`. The critical SDHCI-host bug uncovered
  along the way was a command-encoding error: RESPONSE_TYPE bits 1:0
  of the SDHCI COMMAND register live at *dword bits 17:16* (upper
  half-word of the 32-bit write to offset 0x0C), **not** at dword
  bits 1:0 (which is TRANSFER_MODE territory). Until that was fixed,
  every CMD52 issued with response-type 0 and the chip's response
  was silently discarded — the symptom was clean `CMD_COMPLETE` IRQ
  with `RESPONSE_0=0x00000000` for every command, mimicking a
  card-not-responding fault.
- **VideoCore mailbox property channel.** Reusable across all three
  utilities above plus the GENET Tier 5b MAC fetch. Pi 4 base
  `0xfe00b880` (non-page-aligned; align down by `_PAGE_SIZE - 1` for
  mmap), property channel 8, standard request envelope of 8 u32
  words `[size, REQUEST, tag, val_buf_size, code, ...args, END]`.
  Response success indicated by `msg[1] == 0x80000000`.

### Phoenix tooling worth reusing

Anyone forking the Phoenix infrastructure for their own Pi 4 port may
find these helpful:

- `scripts/snapshot-integration-state.sh` /
  `scripts/restore-integration-state.sh` — capture a manifest of all
  upstream SHAs at a known-good state; restore deterministically.
- `scripts/rebuild-rpi4b-fast.sh` — incremental rebuild + SD image
  refresh.
- `scripts/test-cycle-netboot.sh` — power-cycle the Pi over a smart
  outlet, serve TFTP, capture UART, recover the netboot bridge on
  DHCP timeout. `scripts/test-cycle-psh-interact.sh` does the same
  and then drives psh commands over the UART.
- `scripts/get-pi-ip.sh` — resolves the Pi's current
  DHCP-assigned IP from `artifacts/netboot/dnsmasq.leases` (default
  MAC `dc:a6:32:3c:dd:f1`).
- `scripts/uart-summary.sh` / `scripts/uart-list.sh` — UART log
  analysis helpers.
- `scripts/qemu-debug.sh --gdb` — QEMU rpi4b model with gdbstub for
  early-boot state capture.


## Pointers for newcomers

A short, opinionated checklist if you are starting fresh:

1. **Read the canonical Pi armstub.** `raspberrypi/tools
   armstubs/armstub8.S` is the reference for EL3 setup. Read it before
   you write your own.
2. **Cross-check your EL3 setup against ARM Trusted Firmware.**
   `plat/rpi/common/aarch64/plat_helpers.S` codifies the errata and
   L2-timing writes. If your armstub diverges, document why.
3. **Iterate against UART + `tcpdump` + HDMI screenshots, in that
   order of usefulness.**
4. **Use QEMU's gdbstub for any early-boot state question you can
   simulate.** Faster than a serial-console boot cycle by an order of
   magnitude.
5. **Always read the DTB at runtime.** Hardcoded addresses will bite
   you on the day Raspberry Pi ships a board revision that moves a
   peripheral.
6. **Treat the GPU reserve as Device memory.** The VPU keeps running.
7. **Plan for a single-process bus owner for PCIe + xHCI on
   microkernels.** Multi-process splits hit a BCM2711-specific
   per-mmap bridge state race.
8. **Walk every `/memory@*` node**, not just the first. The 4 GB SKU
   has two.
9. **When stuck, do what every other working stack does for this SoC.**
   Linux, FreeBSD, Circle, U-Boot, ARM Trusted Firmware, EDK2 each
   represent a partial-overlap view of the BCM2711's quirks; the union
   is the truth.


## Cross-stack references

Canonical sources for Pi 4 EL3 / cache / DMA setup, by topic:

### EL3 / armstub / errata

- [raspberrypi/tools `armstubs/armstub8.S`](https://github.com/raspberrypi/tools/blob/master/armstubs/armstub8.S)
- [ARM Trusted Firmware `plat/rpi`](https://github.com/ARM-software/arm-trusted-firmware/tree/master/plat/rpi)
- [ARM Trusted Firmware `lib/cpus/aarch64/cortex_a72.S`](https://github.com/ARM-software/arm-trusted-firmware/blob/master/lib/cpus/aarch64/cortex_a72.S)
- [Circle `boot/armstub/armstub8.S`](https://github.com/rsta2/circle/blob/master/boot/armstub/armstub8.S)
- Cortex-A72 r0p3 TRM (ARM DDI 0488); Cortex-A72 Software Developers
  Errata Notice.

### PCIe / xHCI

- [U-Boot `drivers/pci/pcie_brcmstb.c`](https://github.com/u-boot/u-boot/blob/master/drivers/pci/pcie_brcmstb.c)
- [Circle `lib/bcmpciehostbridge.cpp`](https://github.com/rsta2/circle/blob/master/lib/bcmpciehostbridge.cpp)
- [FreeBSD `sys/arm/broadcom/bcm2835/bcm2838_pci.c`](https://cgit.freebsd.org/src/tree/sys/arm/broadcom/bcm2835/bcm2838_pci.c)
- [NetBSD `sys/arch/arm/broadcom/bcm2838_pcie.c`](https://nxr.netbsd.org/xref/src/sys/arch/arm/broadcom/bcm2838_pcie.c)
- [raspberrypi/firmware issue 1424 (VL805 AC64 high-half)](https://github.com/raspberrypi/firmware/issues/1424)
- [raspberrypi/firmware issue 1495 (RC_BAR2 must be 0)](https://github.com/raspberrypi/firmware/issues/1495)
- [raspberrypi/firmware issue 1617 (don't re-issue NOTIFY_XHCI_RESET)](https://github.com/raspberrypi/firmware/issues/1617)

### GENET (Ethernet)

- [Linux `drivers/net/ethernet/broadcom/genet/`](https://github.com/torvalds/linux/tree/master/drivers/net/ethernet/broadcom/genet)
- [U-Boot `drivers/net/bcmgenet.c`](https://github.com/u-boot/u-boot/blob/master/drivers/net/bcmgenet.c)
- [Circle `lib/bcm54213.cpp`](https://github.com/rsta2/circle/blob/master/lib/bcm54213.cpp)
- [FreeBSD `sys/arm64/broadcom/genet/if_genet.c`](https://cgit.freebsd.org/src/tree/sys/arm64/broadcom/genet/if_genet.c)
- DT bindings:
  [brcm,bcmgenet.yaml](https://www.kernel.org/doc/Documentation/devicetree/bindings/net/brcm,bcmgenet.yaml),
  [brcm,unimac-mdio.yaml](https://www.kernel.org/doc/Documentation/devicetree/bindings/net/brcm,unimac-mdio.yaml).

### Boot pipeline / firmware / mailbox

- [raspberrypi/firmware wiki — Mailboxes](https://github.com/raspberrypi/firmware/wiki/Mailboxes)
- [raspberrypi/firmware wiki — Mailbox property interface](https://github.com/raspberrypi/firmware/wiki/Mailbox-property-interface)
- [raspberrypi/firmware wiki — `config.txt`](https://www.raspberrypi.com/documentation/computers/config_txt.html)
- [raspberrypi/linux DT for Pi 4-B (`arch/arm/boot/dts/broadcom/bcm2711-rpi-4-b.dts`)](https://github.com/raspberrypi/linux/blob/rpi-6.6.y/arch/arm/boot/dts/broadcom/bcm2711-rpi-4-b.dts)

### Wi-Fi / Bluetooth

- [Linux `drivers/net/wireless/broadcom/brcm80211/brcmfmac/`](https://github.com/torvalds/linux/tree/master/drivers/net/wireless/broadcom/brcm80211/brcmfmac)
- The `cyfmac43455-sdio.bin` firmware blob ships with `linux-firmware`
  and is also required by FreeBSD's `mwlfw`. There is no clean-room
  reimplementation as of writing.

### General ARMv8-A

- ARMv8-A Architecture Reference Manual (ARM DDI 0487).
- Cortex-A72 MPCore Processor TRM (ARM DDI 0488).
- GIC-400 TRM (ARM DDI 0471).
- Generic Interrupt Controller architecture v2 spec (ARM IHI 0048).


## Storage & the root filesystem

Two root filesystems are supported, and each taught its own lessons.

### SD / eMMC (EMMC2 controller)

The Pi 4's `EMMC2` SDHCI controller (`0xfe340000`) drives the microSD slot. Bring-up gotchas
that generalize to any SDHCI port:

- **Reads**: UHS-I **DDR50** (1.8 V) + **SDMA** + multi-block `CMD18`, IRQ-driven. ~38 MB/s
  (~86 % of Linux on the same card). A **lost-wakeup guard** in the command-wait path matters:
  the completion IRQ can land between "issue" and "sleep", so re-check `PRES_STATE`/status before
  blocking (`_sdio_cmdExecutionWait`), or a block read hangs forever on an already-finished op.
- **Writes**: multi-block `CMD25` but **PIO, not DMA** — a BCM2711 controller quirk corrupts DMA
  *writes* specifically, so writes stay PIO (~13–17 MB/s). Write **completion** is the subtle
  part: the `TRANSFER_DONE` IRQ never reliably latches for writes on this silicon, so completion
  is done by **polling `CMD13` (SEND_STATUS) for the card to return to `TRAN`** while holding the
  event lock — reads keep using the IRQ. 16/16 multi-block writes verified 0-corruption.
- **`CMD7` R1b**: after selecting the card, poll `PRES_STATE` rather than trusting the busy IRQ.
- **The crash that wasn't a storage bug**: an ext2 root under load faulted deep in the FS call
  chain — root cause was a **filesystem pool-thread stack overflow**, not the driver. Fix: give
  the storage/FS worker threads a bigger stack (`storage_run(..., 16*_PAGE_SIZE)`). Deep call
  chains (ext2 → cache → block driver) blow a small default stack.
- **Card variance is real**: a "large sequential read EIO" chased as a driver bug turned out to
  be **marginal media** — a known-good card read 2048 consecutive blocks at 50 MHz with zero
  errors. Rule out the card before rewriting the driver.

### NFS root over netboot

For fast iterate-without-reflashing, the board mounts `/` over **NFS** (the SD card must be
**out** — VideoCore firmware won't fall through to network boot with a card present). The chain:

1. `plo` loads the kernel + a RAM image over **TFTP**; early userspace comes up on a sparse
   **dummyfs** root.
2. `lwip` brings up **GENET**; once the netif has an IP, an **nfs-fs** server mounts the real
   export and **takes over `/`** — the log line `registered / (takeover)` marks the handover.
3. From then on `/` is the NFS export; binaries and assets are read over the wire.

The load-bearing lessons:

- **Boot-order race (the dominant test-flakiness)**: `plo` launches `psh` as a *sibling* of the
  takeover server without gating on it, so a command issued right at the first prompt hits the
  pre-takeover dummyfs root and fails `not found`. The proper fix is a `plo` boot-order gate; the
  test harness works around it by **waiting for the `registered / (takeover)` line** before
  sending commands. Any "intermittently empty" game boot is almost always this, not a port bug.
- **NFSv4 lease expiry**: after many reboots the host `nfsd` can hand back `NF4ERR_EXPIRED`
  (surfaces as `-ERANGE`/`exec -12`). nfs-fs runs an `OP_RENEW` thread (~45 s) and does
  reclaim/retry on expiry; a genuinely stuck server state is cleared host-side with
  `systemctl restart nfs-server` (mind the ~90 s grace window before the next boot).
- **Throughput is cable-bound, then buffer-bound**: a crossover cable only wired 2 pairs → the
  link fell back to 100 Mbps; a Cat5e/6 straight cable or a gigabit switch is an ~8–10× win. On
  top of that, GENET RX **buffer aliasing** (16 recycled buffers) collapsed the TCP window —
  giving RX 256 unique buffers from one `dmammap` restored ~8 MB/s. Diagnose the window collapse
  host-side with `ss -tin`.
- **poll() that never wakes**: Phoenix `poll()` didn't wake on socket readiness, so libnfs's
  100 ms default poll stalled every RPC (~20–75× slowdown). Setting `nfs_set_poll_timeout(1)`
  worked around it pending the kernel poll fix.
- **Runtime-read reliability caps asset-heavy workloads**: even after the exec race is fixed, an
  individual file read can transiently fail on the slow link (a game aborting on a "missing" pak
  that exists). So games load and render, but a full asset load is gated by netboot NFS
  reliability — **SD/eMMC boot avoids it entirely**. Treat NFS-root as a dev convenience, not the
  performance path.

## Dynamic code / executable memory (JIT)

Phoenix on aarch64 *can* run JIT-compiled / dynamically-generated code, but the memory-protection
model differs from Linux in one way that trips the standard JIT idiom. Findings (from bringing up
the quake3e aarch64 QVM JIT):

- **`mmap` honors `PROT_EXEC`.** The kernel maps a `PROT_EXEC` request to a `PGHD_EXEC` page
  attribute (`vm/map.c`), so `mmap(..., PROT_READ|PROT_WRITE|PROT_EXEC, ...)` gives you a genuinely
  executable RWX buffer. Executable memory is supported.
- **`mprotect` cannot *escalate* protection.** `vm_mprotect` rejects any `prot` that exceeds the
  mapping's **original** protection (`map_checkProt(entry->protOrig, prot)` → `-EACCES`). This is a
  deliberate W^X-style policy. So the classic JIT pattern — `mmap` a region **RW**, write code, then
  `mprotect` it to **RX** — **fails on the mprotect step** (`EACCES`, because EXEC wasn't in the
  original prot). Diagnose it as `mprotect ... failed` right after a JIT emits code.
- **The fix: allocate RWX up front.** `mmap` the code buffer `PROT_READ|PROT_WRITE|PROT_EXEC` and
  skip (or treat as non-fatal) the later `mprotect(RX)`. You lose the W^X hardening on that buffer,
  but the code runs. (A future enhancement could let `mprotect` widen within a `PROT_MAX`; today it
  can't.)
- **EL0 cache maintenance is enabled**, so `__builtin___clear_cache()` (the mandatory I-cache flush
  after emitting aarch64 code — `dc cvau` + `ic ivau` + `dsb`/`isb`) works from userspace: the
  kernel sets `SCTLR_EL1.UCI` (bit 26) and `SCTLR_EL1.UCT` (bit 15) in `_init.S`. The toolchain
  exposes no `__clear_cache` prototype, so `#define __clear_cache(b,e) __builtin___clear_cache(...)`.
- **32-bit-VM-on-64-bit-host caveat.** A JIT that targets a 32-bit VM (Quake's QVM) must mask every
  guest data address to the VM's address space; a stray high bit (e.g. bit 32) in a computed
  address faults immediately on aarch64. Verify the JIT's data-address masking against where the VM
  memory actually lands in the Phoenix address space (which can differ from Linux).

Net: executable memory + I-cache flush work; only the `mprotect`-widen idiom needs the RWX-up-front
workaround.

## Porting userspace applications & games

Everything above is about the OS. This section is the other half: getting large existing
C/C++ programs (SDL2, X11, QuakeSpasm, vkQuake, yQuake2) to run on the port. These lessons
came from porting the Quake family + SDL2 to the RPi4.

### Reuse upstream; keep a thin platform backend
Port the *real* upstream source, not a reimplementation. Keep OS-specific code in a small
backend (`tools/<name>-port/platform/pl_phoenix_*.c` + a `<name>-phoenix-port.patch`) plus a
build script that cross-compiles and links. Far more maintainable than forking the app, and it
tracks upstream. Same idea for a *library* (SDL2): a small patch set + overlay driver sources
under `sources/phoenix-rtos-ports/<lib>/`.

### Graphics reality: no WSI, no window system
A fullscreen app renders into a `/dev/fb0`-backed surface the VideoCore scans out (see the V3D
section). No X server required, no GL/Vulkan windowing.
- **OpenGL**: get a context by calling Mesa directly — there is no EGL/GLX on Phoenix. GL entry
  points link straight against `libGL-phoenix.a`; no `dlopen`/`GetProcAddress` table needed.
- **Vulkan**: V3DV has no `VK_KHR_surface`/swapchain; apps calling `SDL_Vulkan_CreateSurface`
  need a minimal fb0-backed WSI added to the ICD first.
- **The alpha trap**: the scanout keys on color-buffer ALPHA — opaque geometry must write
  alpha=1 or it vanishes on screen.

### The dynamic-loader problem: there is no dlopen
Phoenix has **no `dlopen`/`dlsym`** (no `dlfcn.h`; `SDL_dynapi` is off). Programs built around
runtime-loaded shared objects must be **statically folded into one ELF**:
- yQuake2 loads its renderer (`ref_gl1.so`) and game logic (`game.so`) via `Sys_LoadLibrary`.
  Fix: a backend where `Sys_LoadLibrary`/`Sys_GetGameAPI` return the compiled-in
  `GetRefAPI`/`GetGameAPI` directly; patch any file-existence check that gates the load; link
  **exactly one** renderer (each defines the same export symbol).
- Folding N `.so`s into one ELF surfaces **multiply-defined symbols**: shared TUs the build
  compiled once per `.so` (`shared.c`, `md4.c`) must be compiled once; `-fcommon` merges
  tentative globals; rename colliding initialized tables with a `-D`.

### libc/system gaps
Measure them by `nm`-ing the archives (undefined refs only surface at link — `-Wno-error`
compiles hide them). Handle each by patching the app, or — preferably per project policy —
**adding the function to libphoenix** so every future port benefits. Gaps seen: `dlopen`/`dlsym`
(static-link), `realpath(x, NULL)` (glibc alloc form → pass a stack buffer),
`pthread_getcpuclockid`, `pthread_{get,set}schedparam`, POSIX semaphores (SDL uses its generic
sem), `mremap`.

### Memory: no lazy demand-paging of large anonymous maps
Phoenix does **not** demand-page large anonymous allocations — untouched pages translation-fault.
So BSS + a big `malloc` hunk are effectively committed up front (the Quake ports `memset` the
hunk to force it mapped). Implications:
- Keep the linked **stack size** (`-z stack-size=`) only as large as needed; 32 MB suits a deep
  recursive Vulkan renderer, but Phoenix commits `PT_GNU_STACK` eagerly at exec, so a smaller
  stack directly lowers the committed footprint.
- A large **BSS** is the real cost: `process_load64` anon-maps it and `hal_memset`s it eagerly,
  page-by-page under `map->lock` — a 26 MB BSS is ~14k pages committed synchronously during exec.
  That long exec window intermittently **silently hangs** over the flaky netboot NFS (SMP
  contention and/or a stalled per-page NFS text read) — NOT a clean `-ENOMEM` (that would print).
  A binary with tens of MB of BSS exec's reliably ~50% over netboot. Mitigations: trim the linked
  stack (cheap), boot from SD (local), or fix the kernel to demand-page exec-time anon (the proper
  fix — makes exec O(1) in BSS size). See `docs/misc/2026-08-05-large-binary-exec-investigation.md`.

### Asset & exec I/O is NFS-bound over netboot
Over netboot the root is NFS; a 100 Mbps link (a crossover cable wires only 2 pairs) is slow and
latency-bound. A game loading hundreds of textures from a pak, plus demand-paging a big binary's
code, can take **minutes** for the first map. Infrastructure, not a port bug — **SD-boot** (local,
read-ahead clustered) or a gigabit link makes it fast.

### Input & audio
Bind `/dev/kbd0` (raw 8-byte HID), `/dev/mouse0` (4-byte HID), `/dev/audio0` (PWM). The **`poll()`
gotcha**: Phoenix `poll()` does not wake on HID fds — never block on it; drain non-blocking on a
timer with a bounded per-frame read count. When reading raw HID, **carry partial (non-frame-
aligned) bytes across reads** or you desync and fabricate input.

### Networking
Single-player uses the in-process loopback net driver — works. For Quake2, set **`allow_download
0`**: with downloads on, the client tries to fetch a missing file over loopback and hangs the
connect→precache handshake.

### Build/link recipe
Cross-compile with the repo toolchain (`.toolchain/aarch64-phoenix/bin/aarch64-phoenix-gcc`).
Link circular archive sets (app → glue → Mesa; `libGL` ↔ `libv3d`) inside
`-Wl,--start-group … --end-group`; add `-lstdc++ -lm` for Mesa's C++. Deploy the ELF to the NFS
root `/usr/bin` (or bundle the biggest flagships in `loader.disk`) and run over netboot psh.
