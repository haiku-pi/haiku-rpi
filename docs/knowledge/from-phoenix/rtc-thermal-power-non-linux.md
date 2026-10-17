# RTC, Thermal, Watchdog, Power — Non-Linux Sources (Round 2)

Round 1 walked the Linux drivers. This round surveys BSDs, bare-metal frameworks (Circle, Ultibo, raspi3-tutorial, LdB), BCM2835/BCM2711 datasheet bitfields, and the firmware mailbox property protocol every non-Linux Pi project reimplements. Goal: smallest cleanest reference for Phoenix's watchdog/poweroff.

## 1. FreeBSD — `bcm2835_wdog.c`

Source: `sys/arm/broadcom/bcm2835/bcm2835_wdog.c` in `freebsd/freebsd-src` (master). Header `bcm2835_wdog.h` exports only one prototype, `bcmwd_watchdog_reset(void)` — all register macros live in the `.c` file.

Layout (FreeBSD numbers the offsets from a per-driver base, not from `PM_BASE`):

- `BCM2835_RSTC_REG = 0x00`
- `BCM2835_RSTS_REG = 0x04`
- `BCM2835_WDOG_REG = 0x08`
- `BCM2835_PASSWORD = 0x5a`, shifted left 24 bits before each write
- `BCM2835_WDOG_TIME_MASK = 0x000fffff` (20-bit countdown in ~16 µs ticks of the 32 kHz osc)
- `BCM2835_RSTC_WRCFG_CLR = 0xffffffcf`, `BCM2835_RSTC_WRCFG_FULL_RESET = 0x00000020`

The kick path in `bcmwd_watchdog_fn()` computes ticks `(seconds << 16) & TIME_MASK`, ORs the password, writes WDOG, then RMWs RSTC with WRCFG_CLR/WRCFG_FULL_RESET. `bcmwd_watchdog_reset()` is the reboot entry: same pattern, short timeout. Notably `if (howto & RB_HALT || howto & RB_POWEROFF) return;` — the FreeBSD driver does **not** implement halt; that's left to mailbox/poweroff (see §10).

## 2. FreeBSD arm64 — thermal

`sys/arm64/broadcom/` contains only `brcmmdio/` and `genet/`. There is **no native FreeBSD BCM2711 thermal driver** as of 14.x. Pi temperature is read via the legacy `bcm2835_mbox` channel-6 thermal-sensor request through VideoCore — consistent with FreeBSD's general policy of using the firmware mailbox for non-critical Pi telemetry.

## 3. NetBSD — `bcm2835_pmwdog.c`

Source: `src/sys/arch/arm/broadcom/bcm2835_pmwdog.c` in `NetBSD/src`. Header layout uses canonical PM offsets (relative to `PM_BASE = 0x7e10_0000` on Pi, `0x7e10_0000` mapped from `0xfe10_0000` on Pi 4):

```
#define BCM2835_PM_PASSWORD       0x5a000000
#define BCM2835_PM_RSTC           0x1c
#define BCM2835_PM_RSTS           0x20
#define BCM2835_PM_WDOG           0x24
#define BCM2835_PM_WDOG_TIMEMASK  0x000fffff
```

`bcmpmwdog_tickle()` writes `period << 16` to WDOG (16 ticks/sec, 32 kHz crystal divided). `bcmpmwdog_setmode()` disarms by writing `PASSWORD | RSTC_RESET` to RSTC. NetBSD wires up `bcm2835_power_poweroff()` and `bcm2835_system_reset()` from the same softc:

```c
static void bcm2835_power_poweroff(device_t self) {
    /* Boot from partition 63 is magic to halt boot process */
    bcm2835_restart(sc, 63);
}
```

`bcm2835_restart()` encodes a 6-bit partition into RSTS bits {0,2,4,6,8,10}, writes it with the password, sets a short WDOG, then arms RSTC. Partition 0 = reboot, 63 = halt — the GPU bootloader on next boot reads RSTS, sees the magic, and parks instead of reloading firmware. This is the only "poweroff" Pi 4 has; there is no PMIC kill line. NetBSD is the cleanest BSD reference: poweroff, restart, watchdog kick, disarm all in ~250 lines.

## 4. OpenBSD — watchdog + thermal

OpenBSD's Pi 4 watchdog is in the PM driver under `sys/dev/fdt/`; the implementation mirrors NetBSD: same PASSWORD, same offsets, same partition-63 halt trick. OpenBSD adds a dedicated thermal monitor: **`bcmtmon(4)`**, first in OpenBSD 6.8 (`sys/dev/fdt/bcmtmon.c`).

`bcmtmon(4)` targets the BCM2711 AVS ring-oscillator block. Per the manpage and `tech@openbsd.org` announcement: AVS monitor base `0x7d5d_2000`, size `0xf00`; temperature status at offset `0x200` (AVS_RO_TEMP_STATUS). Sample is `valid_bit | 10-bit code`; conversion to millideg-C is `410040 - sample * 487`. Exposed via `sysctl hw.sensors.bcmtmon0.temp0`. True MMIO sensor — no mailbox round-trip, unlike Linux's `bcm2711_thermal.c` (same hardware, same driver).

## 5. Circle (`rsta2/circle`)

`lib/bcmwatchdog.cpp` + `include/circle/bcmwatchdog.h`. API: `Start(seconds=15)`, `Stop()`, `Restart(partition=0)`, `IsRunning()`, `GetTimeLeft()`. Constants: `MaxTimeoutSeconds=15`, `PartitionHalt=63`. `Start()` writes `ARM_PM_PASSWD | (seconds << 16)` to `ARM_PM_WDOG` then arms `ARM_PM_RSTC` with REBOOT bits; `Stop()` writes `PASSWD | RSTC_RESET`; `Restart()` spreads the 6-bit partition across {0,2,4,6,8,10}, programs ~150 µs WDOG, triggers RSTC.

No dedicated Circle thermal class. Temperature via `CPropertyTags::GetTag(PROPTAG_GET_TEMPERATURE, ...)` in `lib/bcmpropertytags.cpp`. Mailbox primitive in `lib/bcmmailbox.cpp` — `MAILBOX0_READ`/`STATUS`, `MAILBOX1_WRITE`/`STATUS`, polls EMPTY/FULL, masks channel in low 4 bits, guarded by `CSpinLock`. `addon/sensor/` is I²C peripherals, not SoC.

## 6. Ultibo — Pascal

`source/rtl/ultibo/drivers/bcm2710.pas` has `BCM2710WatchdogStart/Stop/Refresh/GetRemain` with the same registers (`BCM2837_PM_RSTC=$1C`, `BCM2837_PM_WDOG=$24`, `BCM2837_PM_PASSWORD=$5A000000`). `BCM2710PowerHardReset` uses partition 0, `BCM2710PowerHardOff` partition 63. Temperature via mailbox `Tag_GetTemperature` ($00030006). Both wrap into Ultibo's generic `WatchdogDevice`/`PowerDevice` framework.

## 7. Bare-metal mailbox examples — property tag protocol

Identical across every non-Linux project; framing at `github.com/raspberrypi/firmware/wiki/Mailbox-property-interface`. **Buffer**: `[u32 size_bytes, u32 code, ...tags..., u32 0 /* end tag */]`, 16-byte aligned, physical address ORed with channel 8 written to `MBOX1_WRITE`. **Per-tag**: `[u32 id, u32 value_buf_size, u32 req_resp_size_or_code, u8[value_buf_size] payload]`. `code` = `0x00000000` request, `0x80000000` success. Tag's third word: low 31 bits = request payload size on send / response size on return; bit 31 = response indicator.

Reference implementations:

- **`rsta2/circle`** (`lib/bcmpropertytags.cpp`): C++ wrapper. `GetTag()` serializes into a 16-byte-aligned buffer, calls `CBcmMailBox::WriteRead`, validates response.
- **`bztsrc/raspi3-tutorial/04_mailboxes`**: minimal C — global `mbox[36] __attribute__((aligned(16)))`, `mbox_call(MBOX_CH_PROP)` polls flags directly. ~50 LoC.
- **`isometimes/rpi4-osdev`** lesson 5: near-clone of bztsrc, Pi 4 mailbox base `0xFE00B880`.
- **`LdB-ECM/Raspberry-Pi`**: similar to Circle, polls `MAIL_FULL`/`MAIL_EMPTY`. Treats bus-alias address (`buf | 0xC0000000`) explicitly.

Key tag IDs (from `include/circle/bcmpropertytags.h` and `firmware/wiki`):

| Tag | ID | Purpose |
|---|---|---|
| `GET_TEMPERATURE` | `0x00030006` | u32 sensor_id → u32 millideg-C |
| `GET_MAX_TEMPERATURE` | `0x0003000A` | same shape, returns thermal-trip target |
| `GET_THROTTLED` | `0x00030046` | u32 throttle bitfield (under-volt, freq-cap, throttled, soft-temp-limit, plus sticky bits) |
| `SET_POWER_STATE` | `0x00028001` | u32 dev_id, u32 state — bit0=on, bit1=wait |
| `SET_CLOCK_RATE` | `0x00038002` | u32 clk_id, u32 rate, u32 skip_turbo |
| `GET_BOARD_REVISION` | `0x00010002` | identifies Pi model (ABI in BCM2835 ARM Peripherals appendix) |

There is **no dedicated "shutdown" property tag**. See §10.

## 8. PCF8523 / DS3231 RTC drivers — non-Linux

Pi has no on-die RTC; every HAT (DS3231, PCF8523, RV3028) is I²C. Non-Linux drivers:

- **FreeBSD `sys/dev/iicbus/rtc/ds3231.c`** — full driver (Luiz Otavio O Souza, FreeBSD 11+). BCD time/date, 32 kHz out, SQW pin, on-die temperature; attaches via FDT or `device.hints`. PCF8523 had a Phabricator review (D1016) but never landed.
- **NetBSD `sys/dev/i2c/ds3232rtc.c`** covers DS3231/3232; `pcf8523rtc.c` in tree since ~2019. Both register `todr_chip_handle_t`.
- **OpenBSD `sys/dev/i2c/maxrtc.c`** and `pcfrtc.c` — Maxim and NXP; attach via fdt/iic.
- **Circle**: no RTC class — user instantiates `CI2CMaster` and reads BCD manually.
- **Ultibo**: `RTCDevice` framework with PCF8523/DS3231 implementations.

Cleanest port path for Phoenix is FreeBSD's DS3231 driver — compact, datasheet-faithful.

## 9. BCM2835 watchdog hardware — primary doc confirmation

Authoritative source: **BCM2835 ARM Peripherals datasheet** (Raspberry Pi Foundation reissue, available at `datasheets.raspberrypi.com/bcm2835/bcm2835-peripherals.pdf`). The Power Management chapter (chapter 13 in the 2012 errata edition) documents:

- `PM_RSTC` (offset `0x1c` from PM base): bits [31:24] password (must be `0x5a`), bits [5:4] `WRCFG` (`0b00` clear, `0b01` set, `0b10` full reset), bit [9] `RSTCHK`. Writes with wrong password are silently ignored.
- `PM_RSTS` (offset `0x20`): bits {0,2,4,6,8,10} encode 6-bit partition; bit 12 `HADWRH`, bit 11 `HADPOR`. Same password requirement.
- `PM_WDOG` (offset `0x24`): bits [19:0] `TIME` countdown in ~16 µs ticks (32 kHz / 2). Writing arms or refreshes the counter atomically with the password.

The BCM2711 documentation supplement does not redefine these — the PM block is unchanged from BCM2835. AVS thermal block is new at `0x7d5d_2000` (datasheet "BCM2711 ARM Peripherals" §11.6, AVS monitor / RO temperature sensor).

## 10. Power-off via mailbox

No firmware property tag named `SHUTDOWN` exists. Linux `power/reset/raspberrypi-poweroff.c` and the BSDs converge on partition-63: program `PM_RSTS` to `PASSWORD | (HALT << spread) | (RSTS & ~partition_bits)`, set short WDOG, arm RSTC. The GPU stage-1 bootloader, on the RSTC-triggered reboot, reads RSTS, sees 63, parks the SoC instead of reloading kernel.img.

`SET_POWER_STATE` (`0x00028001`) is the closest mailbox route but only powers individual peripherals (USB/SD/UART) — cannot kill the SoC.

## 11. Synthesis & recommendation

Cheapest, most upstreamable Phoenix watchdog driver is a **fresh ~150-line implementation from the BCM2835 datasheet**, not a port:

1. Hardware is trivial — three registers, one password, one bitfield. NetBSD's ~250 lines include `sysmon_wdog` glue we don't have; FreeBSD's is dominated by `eventhandler`/`device_t` boilerplate; Circle's is C++.
2. Partition-63 halt is stable since 2015 (NetBSD, Circle, Ultibo, Linux agree). Implement `pm_poweroff()` and `pm_reset()` together — same RSTC code.
3. Phoenix already has SoC-relative MMIO primitives. Three offsets + a password helper = one file.
4. Watchdog should sit **alongside** mailbox, not depend on it. Mailbox needs GPU firmware running and a 16-byte-aligned uncached buffer; watchdog needs neither and must work when mailbox is wedged.
5. Thermal can wait — Pi 4 won't thermally die during bring-up; once mailbox lands, `GET_TEMPERATURE` is 5 LoC. For VPU-free reading later, port OpenBSD `bcmtmon`.

Concrete plan: one `pmwdog.c` in `phoenix-rtos-kernel/hal/armv8a-aarch64/raspi/` exporting `hal_wdgStart/Kick/Stop`, `hal_systemReset`, `hal_systemHalt` — ~120 LoC. Reference NetBSD's `bcm2835_pmwdog.c` for the partition spread; datasheet for the rest. RTC: defer until userland needs it, then port FreeBSD's `ds3231.c` once I²C lands.

Sources:
- [FreeBSD bcm2835_wdog.c](https://github.com/freebsd/freebsd-src/blob/main/sys/arm/broadcom/bcm2835/bcm2835_wdog.c)
- [FreeBSD arm64/broadcom tree](https://github.com/freebsd/freebsd-src/tree/main/sys/arm64/broadcom)
- [NetBSD bcm2835_pmwdog.c](https://github.com/NetBSD/src/blob/trunk/sys/arch/arm/broadcom/bcm2835_pmwdog.c)
- [OpenBSD bcmtmon(4) manpage](https://man.openbsd.org/bcmtmon)
- [OpenBSD bcmtmon announcement](https://www.mail-archive.com/tech@openbsd.org/msg58200.html)
- [Circle bcmwatchdog.cpp](https://github.com/rsta2/circle/blob/master/lib/bcmwatchdog.cpp)
- [Circle bcmpropertytags.h](https://github.com/rsta2/circle/blob/master/include/circle/bcmpropertytags.h)
- [Circle bcmmailbox.cpp](https://github.com/rsta2/circle/blob/master/lib/bcmmailbox.cpp)
- [Ultibo Core bcm2710.pas](https://github.com/ultibohub/Core/blob/master/source/rtl/ultibo/drivers/bcm2710.pas)
- [bztsrc/raspi3-tutorial mailbox lesson](https://github.com/bztsrc/raspi3-tutorial/tree/master/04_mailboxes)
- [Raspberry Pi firmware mailbox property interface wiki](https://github.com/raspberrypi/firmware/wiki/Mailbox-property-interface)
- [BCM2711 ARM Peripherals datasheet](https://datasheets.raspberrypi.com/bcm2711/bcm2711-peripherals.pdf)
- [FreeBSD ds3231(4) manpage](https://man.freebsd.org/cgi/man.cgi?query=ds3231)
- [Linux bcm2835_wdt.c poweroff patch (Tronnes 2015)](https://patchwork.kernel.org/project/linux-arm-kernel/patch/1434195541-28368-2-git-send-email-noralf@tronnes.org/)
