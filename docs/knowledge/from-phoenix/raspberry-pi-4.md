# Raspberry Pi 4 Notes

## 1. Why Pi 4 Is First

Pi 4 is materially easier than Pi 5 because the essential board I/O is not delegated to RP1.

Important properties:

- SoC: BCM2711
- CPU: Broadcom BCM2711 quad-core Cortex-A72 (ARM v8) 64-bit SoC
- interrupt controller: GIC-400
- standard UART: PL011
- Ethernet: Broadcom GENET v5
- PCIe host: Broadcom BCM2711 PCIe root complex
- USB 3 host path: VL805 behind PCIe
- SD/MMC: Broadcom SDHCI / SDHOST family

This makes Pi 4 a realistic first full-system target.

## 2. Official Boot/Configuration Facts

Important official behavior from Raspberry Pi documentation:

- Pi 4 firmware loads the kernel-style image from the firmware partition.
- Device Tree loading is standard and expected.
- `boot_load_flags` exists for custom firmware on Pi 4 and disables some compatibility checks.
- `uart_2ndstage=1` enables more boot UART logging.
- The FAT boot partition remains the normal firmware-visible entry point.
- `enable_gic=1` is the documented default, but the newer low-level survey now
  records that real controller selection may still depend on the DTB and
  armstub combination on the card, not only on that single config value.

Re-verify:

- exact file naming and firmware expectations
- current EEPROM defaults
- any changes in secure boot or boot image handling

## 3. Device Tree Facts

Key Linux DT paths:

- `arch/arm/boot/dts/broadcom/bcm2711.dtsi`
- `arch/arm/boot/dts/broadcom/bcm2711-rpi-ds.dtsi`
- `arch/arm64/boot/dts/broadcom/bcm2711-rpi-4-b.dts`

Important observations from DT:

- GIC node:
  `compatible = "arm,gic-400"`
- CPUs on AArch64 use `spin-table`
- release addresses are present in DT (`cpu-release-addr`)
- mailbox interrupts are routed through GIC
- SDHCI, SPI, I2C, system timer, PCIe, GENET, and xHCI interrupt wiring is explicitly described

Low-level reference note:

- for the consolidated boot, MMIO alias, timer, GIC, GPIO, and firmware facts
  now gathered from official docs plus the external Pi 4 bare-metal references,
  consult `docs/knowledge/raspberry-pi-4-low-level-reference-survey.md`
- current high-confidence address translation model from Linux DTS:
  - `0x7e000000 -> 0xfe000000`
  - `0x7c000000 -> 0xfc000000`
  - `0x40000000 -> 0xff800000`
- current high-confidence Pi 4 early constants:
  - `LOCAL_CONTROL = 0xff800000`
  - `LOCAL_PRESCALER = 0xff800008`
  - `GICD = 0xff841000`
  - `GICC = 0xff842000`
  - `CNTFRQ_EL0 = 54000000`
- current additional firmware-stage caution from the EDK2 Pi 4 platform:
  custom armstub or firmware payload paths may reserve the DTB in the low
  memory window `0x003e0000..0x00400000`, so radical low-memory experiments
  should avoid colliding with that region

## 4. CPU and SMP Notes

Pi 4 secondary CPUs are described in DT with:

- `enable-method = "spin-table"`
- per-CPU `cpu-release-addr`

Implication for Phoenix:

- single-core boot is straightforward
- SMP requires a proper spin-table secondary release implementation in the AArch64 platform layer

## 5. Core Low-Level Bring-Up Requirements

Minimum `plo` support on Pi 4:

1. EL1/EL2 transition handling as needed for firmware handoff reality
2. MMU enablement
3. cache maintenance
4. PL011 UART output
5. DTB handoff parsing
6. image loading from a simple medium

Earliest real-board diagnostic note:

- the Pi 4 activity LED is on GPIO 42
- that makes GPIO42 one of the best no-UART earliest-entry proof points if the
  board still stays black before the current HDMI path becomes visible
- the current exported Pi 4 hardware image now uses exactly that proof:
  the custom Pi 4 armstub drives GPIO42 high on the primary core before the
  existing timer and GIC setup

Current early-HDMI note:

- the first validated HDMI path is now a `plo`-side mailbox/property
  framebuffer allocation plus a painted marker rectangle
- on the current Pi 4 A72 fast lane, a mailbox request buffer located inside
  the generic high-linked `plo` image range failed under `raspi4b` QEMU
- a bounded gdbstub experiment proved that the exact same request succeeds when
  redirected to low physical memory (`0x02000000`)
- treat low physical request-buffer placement as part of the current Pi 4 early
  framebuffer contract until a later step proves a cleaner generic solution

Circle-derived note:

- Circle independently validates the same early Pi 4 video direction:
  - property-mailbox framebuffer allocation
  - coherent low-memory request buffers
  - firmware-driven display sizing and display selection on Pi 4
- Phoenix now also has the first transport-independent USB keyboard foundation:
  `phoenix-rtos-devices/tty/usbkbd/` provides a generic HID boot-keyboard
  class driver and `/dev/kbdN` interface, so the remaining Pi 4 gap is no
  longer “no keyboard logic exists” but “PCIe plus xHCI transport is still
  missing”
- the current Pi 4 A72 project also enables a minimal `pl011-tty` bridge for
  `/dev/kbd0`, so once transport exists the existing HDMI text console can take
  keyboard input through the same `libtty` discipline path
- Circle also confirms that USB keyboard support on Pi 4 is not an early
  shortcut:
  its path depends on PCIe plus VL805 xHCI before HID keyboard support is even
  reachable
- for the current no-UART lab, that means the next small steps should stay
  HDMI-visible first and treat USB keyboard as a later PCIe/xHCI milestone

Minimum kernel support on Pi 4:

1. GICv2
2. ARMv8 architectural timer
3. early console
4. physical memory parsing from DTB
5. single-core scheduling
6. panic/reboot path

## 6. Driver Priority Order

### 6.1 PL011 UART

Needed twice:

- in `plo` for early loader console
- in `phoenix-rtos-devices` for the runtime tty driver

Primary Linux references:

- `arch/arm/boot/dts/broadcom/bcm283x.dtsi`
- `drivers/tty/serial/amba-pl011.c` in Linux upstream/mainline tree if needed

Phoenix implication:

- do not rely on a Zynq UART model
- use a clean PL011-specific implementation

### 6.2 SDHCI / storage

Key Linux references:

- `drivers/mmc/host/sdhci-brcmstb.c`
- Broadcom DT nodes in `bcm2711.dtsi`

Strategy:

- first add simple raw block loading in `plo`
- then add runtime block access in the OS
- keep the firmware FAT partition separate from Phoenix runtime partitions

### 6.3 GPIO / pinctrl

Key Linux references:

- `drivers/pinctrl/bcm/pinctrl-bcm2835.c`
- BCM2711 DT pin mappings

Strategy:

- implement runtime GPIO/pinctrl as a user-space server
- expose stable interfaces for later test automation

### 6.4 Ethernet

Key references:

- Linux: `drivers/net/ethernet/broadcom/genet/bcmgenet.c`
- FreeBSD: `sys/arm64/broadcom/genet/if_genet.c`
- NetBSD/FreeBSD support status confirms GENET is a solved class of device on Pi 4

Priority:

- high, because network dramatically improves remote automation and artifact handling

### 6.5 PCIe and USB

Key references:

- Linux DT: BCM2711 PCIe root complex in `bcm2711.dtsi`
- Linux DT: VL805 xHCI in `bcm2711-rpi-ds.dtsi`

Strategy:

1. get Broadcom PCIe host working
2. add generic xHCI HCD to Phoenix
3. validate VL805 behind PCIe

Current implementation note:

- Phoenix's platform-agnostic PCIe server scan path no longer hardcodes direct
  ECAM access throughout the scan logic; it now uses a small server-local
  config-space backend interface
- the first BCM2711-specific indexed config-space backend now exists behind
  that interface and is selected by the Pi 4 A72 build settings
- the first BCM2711 host-bridge preparation slice now also exists:
  reset sequencing, SerDes IDDQ clear, revision read, and early `MISC_CTRL`
  preparation
- the first BCM2711 link-state slice now also exists:
  `PERST` release, settle wait, and link / RC-mode sampling with downstream
  access gated on that sampled state
- the first BCM2711 outbound-window / root-bridge shaping slice now also
  exists:
  one outbound window, RC BAR2 programming, and root-bridge class shaping
- the first BCM2711 bridge-exposure slice now also exists:
  root-bridge cache-line, bus-number, memory-window, and command programming
- the first BCM2711 bridge-capability slice now also exists:
  root-bridge parity plus PCIe root-control CRS software visibility
- the Pi 4 image path now also stages the `pcie` server itself
- the next bounded Pi 4 transport slice is therefore one direct downstream
  endpoint readback from that staged server, not xHCI
- for the fastest first Pi 4 USB path, the current external-reference contract
  is now explicit:
  VL805 as the single downstream xHCI endpoint at `bus 1 / slot 0 / func 0`,
  class `0x0c0330`, with MMIO through the outbound PCIe window

This work is also strategically useful later because it builds Phoenix PCIe and xHCI capabilities that Pi 5 will also need.

## 7. Recommended Early Boot Image Layout

Recommended first practical layout:

- partition 1: FAT32
  contains Raspberry Pi firmware files, `config.txt`, DTB, Phoenix loader image
- partition 2: raw Phoenix kernel/runtime image or simple block image
- partition 3+: optional Phoenix rootfs partitions

Progression:

1. first image uses RAM rootfs
2. next image adds persistent rootfs on SD

## 8. Suggested Milestones

### Milestone A: `plo` boots

Success criteria:

- UART banner
- stable repeated boot
- DTB presence confirmed

### Milestone B: kernel boots

Success criteria:

- shell prompt on UART
- interrupt and timer operation
- stable reboot

### Milestone C: storage works

Success criteria:

- persistent rootfs
- image updates without manual byte surgery

### Milestone D: GPIO/I2C/SPI work

Success criteria:

- external loopback and peripheral tests pass

### Milestone E: Ethernet works

Success criteria:

- DHCP/static networking
- remote command and file transfer

### Milestone F: USB works

Success criteria:

- keyboard or storage enumeration
- hotplug survives repeated cycles

## 9. Test Focus for Pi 4

Essential repeated tests:

- 100x cold boot loop
- 100x warm reboot loop
- shell smoke test
- timer monotonicity
- interrupt storm safety
- SD read/write stress
- GPIO interrupt tests
- Ethernet soak
- USB hotplug

## 10. Main Pi 4 Risks

### Broadcom PCIe quirks

The Linux DT notes a DMA limitation around the first 3 GB for BCM2711 PCIe. Any Phoenix PCIe implementation must account for addressability constraints and DMA-safe memory allocation.

### QEMU mismatch

Re-verify this against the exact QEMU build in use.

On the current `phoenix-dev` workstation baseline, `qemu-system-aarch64 -machine help` does not list `raspi4b` at all. The practical no-hardware Pi 4 lane is therefore:

- generic `virt` runtime validation for shared AArch64 code paths
- Pi 4 image-shape and artifact inspection

If `raspi4b` becomes available in a future QEMU build, still do not close Pi 4 bring-up tasks based only on QEMU because peripheral fidelity remains incomplete.

### Firmware assumptions

Do not assume current Raspberry Pi firmware behavior will remain stable across EEPROM or firmware revisions.
