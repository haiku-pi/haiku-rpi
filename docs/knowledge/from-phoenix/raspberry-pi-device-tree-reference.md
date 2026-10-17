# Raspberry Pi Device-Tree Reference

This note captures the Raspberry Pi-specific device-tree sources and runtime
rules that matter most for the Phoenix RTOS Pi 4 bring-up.

## Primary References

- Raspberry Pi Linux downstream tree:
  `https://github.com/raspberrypi/linux`
- Raspberry Pi documentation computers folder:
  `https://github.com/raspberrypi/documentation/tree/master/documentation/asciidoc/computers`
- Raspberry Pi device-tree documentation source:
  `https://github.com/raspberrypi/documentation/blob/master/documentation/asciidoc/computers/configuration/device-tree.adoc`
- Raspberry Pi boot/configuration reference:
  `https://www.raspberrypi.com/documentation/configuration/bootconfig.md`
- Raspberry Pi serial/UART reference:
  `https://www.raspberrypi.com/documentation/configuration/serial.md`

## Branch Guidance

As of `2026-03-20`, the Raspberry Pi downstream kernel repo exposes `rpi-X.Y.y`
branches through at least `rpi-7.0.y`.

For the Pi 4 DTS files used by this project:

- `rpi-6.19.y` and `rpi-7.0.y` currently carry identical copies of:
  - `arch/arm/boot/dts/broadcom/bcm2711-rpi-4-b.dts`
  - `arch/arm/boot/dts/broadcom/bcm2711-rpi.dtsi`
- `rpi-6.12.y` is older and differs in some board and peripheral details, but
  it still carries the same boot-critical semantics for:
  - bootloader-filled `memory@0`
  - `chosen/stdout-path = "serial1:115200n8"`

Current recommendation:

- prefer `rpi-6.19.y` or newer when citing Raspberry Pi Linux DTS intent
- re-verify branch contents before depending on them in a future session

## Source Selection Rules

- Prefer original Raspberry Pi Linux `*.dts` and `*.dtsi` sources over `dtc`
  reverse-decompiled DTBs when the goal is to understand board intent.
- Use the firmware-distributed DTB from `raspberrypi/firmware/boot` when the
  goal is to build or boot a real Pi 4 image.
- Treat the runtime DTB handed to the OS as firmware-modified state, not as a
  static copy of the source DTS.

## Key DTS Findings

From `bcm2711-rpi.dtsi`:

- `memory@0` is intentionally incomplete in source:
  `/* Will be filled by the bootloader */`
- The memory node uses bootloader-populated `reg`, so QEMU or synthetic boot
  paths may require explicit DTB fixing if firmware customization is absent.

From `bcm2711-rpi-4-b.dts`:

- `chosen/stdout-path` is `serial1:115200n8`
- the source comment says `8250 auxiliary UART instead of pl011`

Implications:

- Phoenix should not assume the source DTS `stdout-path` directly matches the
  UART used by the current early PL011 diagnostics
- alias-aware resolution matters because Raspberry Pi uses `/aliases` plus
  firmware policy to describe the active console path

## Firmware DTB Rules

Raspberry Pi documentation states that firmware:

- selects a base DTB for the board
- applies `config.txt` settings
- applies overlays and `dtparam`s
- passes the merged DTB to the kernel

Implications for Phoenix:

- treat the firmware-merged DTB as authoritative input
- do not reconstruct overlay or parameter effects inside the kernel
- preserve and parse firmware-populated `/chosen` and `/aliases` data

## Overlay And Alias Notes

- `dtoverlay=<name>` resolves to `overlays/<name>.dtbo` in the firmware boot
  partition
- `dtparam=` applies in firmware, not in Phoenix
- overlay parameter scope is overlay-local in Raspberry Pi firmware processing
- alias resolution is important because non-absolute DT paths are commonly
  expressed through `/aliases`

For bring-up:

- preserve firmware-generated alias tables
- do not hardcode only absolute UART node paths when `stdout-path` can name
  `serial0` or `serial1`

## UART-Specific Notes For Pi 4

Raspberry Pi UART documentation says Pi 4 commonly uses:

- auxiliary UART for the default console path in the DTS source
- PL011 at `0xfe201000` as a valid early debug UART
- auxiliary UART at `0xfe215040` as another documented earlycon target

Implications:

- a firmware-selected console may not be the same UART Phoenix currently uses
  for earliest PL011 probes
- early debug on Pi 4 can still use PL011 while the fuller DTB interpretation
  catches up

## Re-verify

- Re-check Raspberry Pi downstream branch tips and DTS contents before citing
  them as authoritative in later sessions.
- Re-check Raspberry Pi documentation URLs because rendered-site paths may move
  even when the GitHub source path remains stable.
