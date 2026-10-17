# GPIO + pinctrl on BCM2711 — Non-Linux Reference Survey (Round 2)

Round 1 focused on Linux `pinctrl-bcm2835` / `gpio-bcm2835`. This brief
walks the same hardware through every non-Linux open-source port we
could find. Goal: pick the cleanest base for Phoenix's BCM2711 GPIO
driver and document the patterns we actually want to copy.

## 1. FreeBSD `bcm2835_gpio`

Path: `sys/arm/broadcom/bcm2835/bcm2835_gpio.c` (FreeBSD `head`).

The driver attaches as a `gpio(4)` controller — FreeBSD's portable GPIO
KPI — and additionally exposes a pinctrl-style fdt back-end. Each line
is described by `gpio_pin_t` with caps `GPIO_PIN_INPUT | OUTPUT |
PULLUP | PULLDOWN | INVIN | INVOUT`. The bus-facing entry points are
`bcm_gpio_pin_setflags`, `_pin_get`, `_pin_set`, `_pin_toggle`,
`_pin_getcaps`, `_pin_getname`, plus FDT mux callbacks
`bcm_gpio_configure_pin` / `_pinmux_configure`.

Pi 4 specifics. The BCM2711 changed the pull-resistor mechanism: the
old `GPPUD`+`GPPUDCLKn` clock-strobe sequence is dead silicon. FreeBSD
keys on the device-tree compatible string (`brcm,bcm2711-gpio`) and
takes a different code path for the new
`GPIO_PUP_PDN_CNTRL_REG{0..3}` block at offset `0xE4..0xF0` — two bits
per pin, no clock dance, just RMW. The register name and behaviour are
documented in the BCM2711 peripheral manual ([Patchwork: pinctrl
bcm2835 add BCM2711 pull-up support][fbsd1]).

Patterns worth copying for Phoenix:

- One driver, two pull mechanisms, selected by SoC ID — not by build
  flag. Phoenix's plo and HAL already discriminate Pi 3 vs Pi 4 at
  runtime, so this fits.
- Capability mask per pin (`GPIO_PIN_*`). Phoenix's existing GPIO
  drivers don't expose caps but adding it costs nothing and matches
  upstream BSD/Linux semantics.
- Name strings (`P0`, `P1`, …) for diagnostics. Useful when we route
  driver state through `/dev/gpioN/info`.

## 2. NetBSD `bcm2835_gpio`

Path: `sys/arch/arm/broadcom/bcm2835_gpio.c` ([NetBSD/src][nbsd1]).
Smaller than FreeBSD's: it predates the BCM2711-class pull change and
treats GPIO as a flat 54-pin bank with `gpio_pin_t` entries. Attach
glue is shared with `files.bcm2835`. NetBSD's value is mostly as a
clean reading of the original BCM2835 register layout; for Pi 4 work
it's strictly inferior to FreeBSD because the pull register isn't
handled.

## 3. OpenBSD `bcmgpio`

Path: `sys/dev/fdt/bcm2835_gpio.c` (driver name `bcmgpio`,
[openbsd/src][obsd1]). Attaches under FDT, registers as a
`gpio_controller_t` with `bcmgpio_config_pin`, `_set_pin`, `_get_pin`.
OpenBSD's tree currently lacks BCM2711 pull-register handling but has
the cleanest interrupt-controller integration of the three BSDs:
`bcmgpio_intr_establish` / `_disestablish` plug straight into the FDT
intc framework, so a single GIC SPI line can fan out to per-pin
handlers without driver-private dispatch tables.

## 4. Circle (rsta2/circle) — top recommendation

Files: `lib/gpiopin.cpp`, `include/circle/gpiopin.h` ([rsta2/circle][circle1]).
GPLv3, single-author bare-metal C++ runtime, exercised on every Pi
model from Pi 1 to Pi 5. The class `CGPIOPin` is small enough to read
in one sitting and was clearly engineered for retargeting.

Public API (`gpiopin.h`):

```
enum TGPIOMode  { GPIOModeInput, GPIOModeOutput,
                  GPIOModeInputPullUp, GPIOModeInputPullDown,
                  GPIOModeAlternateFunction0..5 (..8 on Pi 5) };
enum TGPIOPullMode  { GPIOPullModeOff, GPIOPullModeDown, GPIOPullModeUp };
enum TGPIOInterrupt { GPIOInterruptOnRisingEdge, ..FallingEdge,
                      ..HighLevel, ..LowLevel,
                      ..AsyncRisingEdge, ..AsyncFallingEdge };
```

Methods: `AssignPin`, `SetMode`, `SetPullMode`, `SetAlternateFunction`,
`Read`, `Write`, `Invert`, `ConnectInterrupt`, `EnableInterrupt`,
`DisableInterrupt`, `AcknowledgeInterrupt`, plus dual-edge variants
`EnableInterrupt2` and the static bulk operations `SetModeAll`,
`WriteAll`, `ReadAll`.

Implementation highlights (`gpiopin.cpp`):

- Pin-to-register decoding is the canonical
  `m_nRegOffset = (nPin / 32) * 4; m_nRegMask = 1 << (nPin % 32);`
  for the per-bank registers (`GPSETn`, `GPCLRn`, `GPLEVn`, …) and the
  per-pin trio (`GPFSELn`, with three bits per pin).
- Pull configuration is `#if RASPPI <= 3`-gated: legacy GPPUD clock
  walk on Pi 1–3, single-write to `GPPUPPDN0` on Pi 4. The Pi 4 path
  uses a small lookup `{Off,Down,Up} -> {0, 2, 1}` because the encoding
  flipped between revisions.
- IRQs are wired through `CGPIOManager` (optional, FIQ-capable). Each
  `CGPIOPin` registers a handler and the manager dispatches by reading
  `GPEDS0/1`, ack'ing the bit, then calling out to user callbacks. This
  is exactly the pattern Phoenix wants in its libphoenix/IRQ layer.

Why Circle is the right base for Phoenix:

- **Scope match**: bare-metal, no OS abstractions to strip.
- **Pi 4 tested**: pull-register code is in place and proven.
- **Small**: ~600 LoC including header, easy to translate to C while
  preserving the structure.
- **License**: GPL v3 — compatible with Phoenix-RTOS BSD-3 only via
  rewrite, not direct copy. We can study, then reimplement clean-room.

## 5. Ultibo (Pascal)

Repo `ultibohub/Core`, unit `BCM2711` plus `wiring.pas` ([Ultibo][ulti1]).
Pascal source, exhaustively commented. Educational value is high
because every register write is annotated with the datasheet section
that justifies it; Ultibo also documents Pi-4 pin-function differences
table-by-table. Not portable code (FreePascal RTL dependencies) but a
useful reference when a register write looks wrong and you want a
second opinion.

## 6. Bare-metal Pi tutorials

- **rpi4-osdev** ([rpi4os.com][rpi4os1]) — the canonical Pi 4 bare-
  metal tutorial. PERIPHERAL_BASE = `0xFE000000` (low-peri),
  GPFSEL/GPSET/GPCLR/GPPUPPDN0 in plain `mmio_read/write`. Uses the
  new pull register from page one. Closest match to what plo and the
  Phoenix HAL already do.
- **bztsrc/raspi3-tutorial** ([github][bzt1]) — Pi 3 specific (legacy
  GPPUD path). Useful only for the boot-time UART setup pattern.
- **leiradel "Blinking the LED"** ([leiradel.github.io][leira1]) — Pi
  3, very small, walks GPFSEL bit-fields step by step.
- **dwelch67/raspberrypi**, **PeterLemon/RaspberryPi**,
  **mrvn/RaspberryPi-baremetal** — collected register references; no
  Pi-4 pull-register coverage.
- **WiringPi** (deprecated by author but mirrored) — Linux-userspace
  but the register-level helpers
  (`pinModeAlt`, `pullUpDnControl`, the `GPPUD`/`GPPUDCLK` strobe) map
  one-to-one onto the BCM2835 manual; useful as a sanity check.

## 7. pigpio

Repo `joan2937/pigpio` ([github][pigpio1]). C library, Linux user-
space, but goes straight to `/dev/mem` and pokes the same registers
the kernel touches. Three reasons it's still relevant:

- It open-codes the legacy GPPUD timing (150-cycle waits) — a useful
  reference if we ever need to support a Pi 3 fallback in the same
  driver.
- The DMA-driven sampling loop demonstrates how to read `GPLEVn` at
  microsecond rates. Likely overkill for first-light Phoenix but worth
  bookmarking.
- The output-PWM pattern (writing GPSET/GPCLR pairs through DMA chains)
  is the standard reference for any "fast GPIO" implementation.

## 8. gpioz / gpio-mmio / c-periphery

Library family that abstracts MMIO GPIO behind a tiny VTable
(`open`, `read`, `write`, `set_direction`, `close`). c-periphery
(vsergeev) is the cleanest of the bunch. The takeaway for Phoenix is
the abstraction itself: keep the SoC-specific register layer behind a
small struct of function pointers so Pi 5 (different controller) can
slot in without touching callers.

## 9. MicroPython on Pi 4

There is **no upstream MicroPython port for Pi 4 / BCM2711**
([raspberrypi forums][micropy1]). MicroPython on Raspberry Pi means
RP2040/RP2350 (Pico). For BCM2711 MMIO patterns, MicroPython is not a
source. CircuitPython has the same gap (issue [#4314 in adafruit/circuitpython][cpy1]).

## 10. Pi 4 specifics confirmed by non-Linux sources

- **`GPIO_PUP_PDN_CNTRL_REG{0..3}` at offsets `0xE4..0xF0`** replaces
  the old `GPPUD`/`GPPUDCLK` clock-strobe sequence. Two bits per pin,
  encoding `00=off, 01=up, 10=down`. Confirmed in the BCM2711
  peripherals datasheet, in Circle's `gpiopin.cpp` Pi 4 branch, in
  rpi4-osdev, and in the FreeBSD pull patches ([Patchwork][fbsd1]).
- **GPIO interrupts on Pi 4 route through the GIC-400 as SPIs
  113–116** (one per bank plus a combined line), not through the
  legacy ARMC IRQ controller used on Pi 1–3. Confirmed in
  `arch/arm/boot/dts/broadcom/bcm2711.dtsi` ([raspberrypi/linux][gicdt1])
  and replicated by FreeBSD/OpenBSD attach glue.
- **The ACT LED on Pi 4 is NOT a direct GPIO**. It hangs off an I2C
  GPIO expander whose master is the VideoCore firmware, not the ARM
  side. To toggle it from Phoenix we would need a mailbox call to the
  VPU, not a GPSET write. This was the case starting with Pi 3 and
  remains true on Pi 4 ([raspberrypi/linux issue #1363][actled1]).
  For first-light visual indication we should use a header GPIO with
  an LED, not chase ACT.

## 11. Phoenix-RTOS GPIO API conventions

Existing drivers in `phoenix-rtos-devices/gpio/`:

- `imx6ull-gpio/imx6ull-gpio.{c,h}` — message-port driver. Each port
  (`gpio1` … `gpio5`) plus a paired `dirN` is exposed as a separate
  `oid_t`. Reads/writes use the `gpiodata_t` union (`{ val, mask }`)
  to support atomic masked updates.
- `zynq7000-gpio/` — newer style (2022). Public API in
  `zynq7000-gpio-msg.h`:
  ```
  gpio_devctl_read_pin / write_pin
  gpio_devctl_read_port / write_port
  gpio_devctl_read_dir  / write_dir
  ```
  Library wrappers `gpiomsg_readPin`, `gpiomsg_writePin`,
  `gpiomsg_readPort`, `gpiomsg_writePort`, `gpiomsg_readDir`,
  `gpiomsg_writeDir` in `libzynq7000-gpio-msg.c`.
- `zynq7000-xgpio/` — Xilinx-specific PL GPIO; same message-port
  pattern.

The Phoenix convention is therefore: **one userspace driver process,
ports created with `portCreate`, devctl multiplexed by an integer
type, payload is `(val, mask)` tuples, library headers expose typed
wrappers**. There is no in-kernel GPIO subsystem. A new BCM2711
driver should follow the Zynq layout exactly (it's the most recent
example), with the device tree being:

```
/dev/gpio0/{port,dir}    (pins 0..31)
/dev/gpio1/{port,dir}    (pins 32..53)
```

Pull and alt-function configuration extend the existing pattern with
two more devctls — they were absent on Zynq because Zynq routes those
through MIO, not GPIO registers.

## 12. Synthesis and recommendation

**Base reference: Circle's `gpiopin.cpp`/`gpiopin.h`.** Reasons:

1. Bare-metal C++, single header + single TU, ~600 LoC total.
2. Pi 4 pull-register path is already in place and tested on
   real hardware.
3. The IRQ manager pattern (one bank handler that ack's `GPEDSn` and
   dispatches per-pin callbacks) is the right shape for Phoenix's
   message-port driver.
4. Independent cross-check from rpi4-osdev and FreeBSD agrees on every
   register access, so Circle is unlikely to be wrong.

**License gotcha**: Circle is GPL v3. Phoenix-RTOS is BSD-3. We must
not copy lines; we read Circle, write our own C against the BCM2711
peripheral manual, and cite Circle in commit messages as the
correctness reference. Same pattern we used for the kernel HAL.

**Files to port (clean-room)**:

- `lib/gpiopin.cpp`         → `phoenix-rtos-devices/gpio/bcm2711-gpio/bcm2711-gpio.c`
- `include/circle/gpiopin.h` → `phoenix-rtos-devices/gpio/bcm2711-gpio/bcm2711-gpio.h`
  *(API surface: keep Phoenix's `gpio_devctl_*` enum from Zynq, not
  Circle's `TGPIOMode` — Phoenix users should see Phoenix conventions.)*
- The IRQ-manager skeleton from Circle's `gpiomanager.cpp` becomes a
  small dispatcher inside the same driver TU, gated behind a build
  flag because step-1 doesn't need IRQs.

**Cross-references for review**: rpi4-osdev for the simplest possible
register-level baseline, FreeBSD for the runtime SoC-ID dispatch
pattern, OpenBSD for FDT-style interrupt registration, BCM2711
peripherals datasheet ([raspberrypi datasheets][dsh1]) as the final
authority for any register disagreement.

[fbsd1]: https://patchwork.kernel.org/project/linux-mmc/patch/1563776607-8368-3-git-send-email-wahrenst@gmx.net/
[nbsd1]: https://github.com/NetBSD/src/tree/trunk/sys/arch/arm/broadcom
[obsd1]: https://github.com/openbsd/src/tree/master/sys/dev/fdt
[circle1]: https://github.com/rsta2/circle
[ulti1]: https://ultibo.org/wiki/Unit_BCM2711
[rpi4os1]: https://www.rpi4os.com/part4-miniuart/
[bzt1]: https://github.com/bztsrc/raspi3-tutorial
[leira1]: https://leiradel.github.io/2019/01/24/Bare-Bones-C.html
[pigpio1]: https://github.com/joan2937/pigpio
[micropy1]: https://forums.raspberrypi.com/viewtopic.php?t=359892
[cpy1]: https://github.com/adafruit/circuitpython/issues/4314
[gicdt1]: https://github.com/raspberrypi/linux/blob/rpi-6.6.y/arch/arm/boot/dts/broadcom/bcm2711.dtsi
[actled1]: https://github.com/raspberrypi/linux/issues/1363
[dsh1]: https://datasheets.raspberrypi.com/bcm2711/bcm2711-peripherals.pdf
