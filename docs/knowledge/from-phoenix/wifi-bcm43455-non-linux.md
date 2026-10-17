# BCM43455 / CYW43455 WiFi — Non-Linux Reference Implementations

Round-2 research, non-Linux sources only. Goal: identify the cleanest reference
for porting full-MAC WiFi to Phoenix-RTOS, where Linux's monolithic device-model
assumptions actively hurt.

## 1. Infineon WHD (Wi-Fi Host Driver)

Repository: <https://github.com/Infineon/wifi-host-driver>. Documentation
landing: <https://infineon.github.io/wifi-host-driver/html/index.html>.

WHD is "an independent, embedded Wi-Fi Host Driver that provides a set of APIs
to interact with Infineon WLAN chips" and is "easily portable to embedded
software environments including Mbed OS, Amazon FreeRTOS and Azure RTOS
ThreadX". This is the closest spiritual fit for Phoenix: a real production
WiFi stack written for an RTOS, not Linux.

Layout (from the repo tree under `WHD/`):

- `WHD/COMPONENT_WIFI6/` — primary source tree. WHD has been refactored around
  WiFi-6 chips and the older WIFI4 split is no longer the active path.
- `External/`, `deps/` — pulled-in headers (cybsp glue, hostap, etc.).
- `library.mk`, `version.xml` — build glue for ModusToolbox.

Currently advertised chip support per the README is **CYW55500, CYW55900,
CYW55572** — i.e. WHD has been narrowed to WiFi-6 parts. Earlier releases
covered 4373 / 43012 / 43439 (and historical CYW43455 attaches exist) but
the master branch no longer markets 43455. Confirmed by Infineon community:
"WHD doesn't support 43455" (Infineon developer community — multiple threads).
Older WHD tags still include 43455 chip-init paths and are usable as
reference even if not maintained.

Bus abstraction (from the integrator-side glue
`whd-bsp-integration/cybsp_wifi.c` at
<https://github.com/Infineon/whd-bsp-integration/blob/master/cybsp_wifi.c>):

1. `_cybsp_wifi_reset_wifi_chip()` toggles WL_REG_ON / 32 kHz LPO.
2. `_cybsp_wifi_bus_init()` selects SDIO / SPI / M2M / OCI.
3. SDIO path: `cyhal_sdio_init()` → `_cybsp_wifi_sdio_card_init()` issues
   CMD0/CMD5/CMD3/CMD7 → `whd_bus_sdio_attach()` hands the SDIO HAL handle to
   WHD core.
4. WHD core attaches buffer + network function pointers, configures OOB IRQ,
   and calls into firmware download.

The "SDPCM" protocol — Cypress's framing layer riding on top of SDIO that
multiplexes IOCTLs, async events, and 802.3 frames — lives in
`WHD/.../whd_sdpcm.{c,h}`. Public WHD API for join/scan/data is in
`whd_wifi_api.h`: `whd_wifi_join`, `whd_wifi_scan`, `whd_wifi_set_passphrase`,
`whd_network_send_ethernet_data`, etc. WPA2/WPA3 handshakes are performed
**inside the chip firmware**; the host calls `whd_wifi_set_passphrase` and
issues `WLC_SET_SSID`. This is the full-MAC model.

Firmware loading: the chip CPU is held in reset, the firmware blob (`.clm`,
`.bin`) is shovelled in over SDIO via `whd_chip_specific_init`, NVRAM
calibration (board params) is appended, then the chip is released and
SDPCM-init is awaited.

License: **Permissive Cypress / Infineon source license** (see `LICENSE.txt`).
Compatible with the rest of the Phoenix tree.

## 2. FreeBSD `if_brcmfmac` via LinuxKPI

FreeBSD has no native Broadcom full-MAC driver. Current path: upstream Linux
driver compiled against LinuxKPI compat shims. Status:

- Q4-2024 LinuxKPI 802.11 update
  (<https://www.freebsd.org/status/report-2024-10-2024-12/lkpi-wireless/>):
  brcmfmac compiles for PCIe and loads firmware on arm64 with a workaround,
  "but is lacking some cfg80211 and netdev LinuxKPI compat work in order to
  create the interface and drive wireless".
- A focused fork at <https://github.com/narqo/freebsd-brcmfmac> is targeting
  BCM4350 (MBP 2016) and BCM43455 (RPi4) — the most relevant work-in-progress.

Conclusion: FreeBSD's path is interesting only as a compat-layer benchmark
("how much Linux do you have to fake to host brcmfmac unmodified?") and not
as a clean reference to copy. For Phoenix it is anti-useful — we'd be
exporting more Linux assumptions, not fewer.

## 3. NetBSD `bwfm`

Files (NetBSD CVS / GitHub mirrors): `sys/dev/ic/bwfm.c`, `bwfmvar.h`,
`bwfmreg.h` (chip-independent core), with bus-specific siblings
`sys/dev/sdmmc/if_bwfm_sdio.c`, `sys/dev/pci/if_bwfm_pci.c`,
`sys/dev/usb/if_bwfm_usb.c`. Manual page `bwfm(4)`
(<https://man.netbsd.org/bwfm.4>).

Provenance: the bwfm driver was authored by Patrick Wildt (`bluerise@openbsd`)
and ported to NetBSD. Its WHD-side was written from Cypress documentation +
released brcmfmac headers — it is **not** a `linux-source-to-bsd`
mechanical port. It is a parallel implementation that shares the protocol
constants but is structured for `sys/dev/ic` device-driver conventions
(no `cfg80211`, no `netdev`, no Linux device model). For Phoenix this
matters: it's already proven that brcmfmac's protocol layer can be expressed
as ~5 kLoC of straight C without the Linux compat surface.

Concrete bring-up status on Pi 4 (CYW43455 over SDIO):

- NetBSD has working bwfm-on-Pi-4: a symlink under
  `/libdata/firmware/if_bwfm/` aliases
  `brcmfmac43455-sdio.raspberrypi,4-model-b.txt` so the driver can find the
  NVRAM. (Reference: NetBSD port-arm mailing list discussion of the bwfm
  firmware path,
  <http://mail-index.netbsd.org/port-arm/2024/06/10/msg008760.html>.)
- The Arasan SDHCI is the bus host on Pi 4, just as for Linux.

Architecture (from `sys/dev/ic/bwfm.c`):

- `bwfm_attach()` — chip detection, clm/firmware load, NVRAM upload.
- `bwfm_proto_bcdc_*` — Broadcom Data-Path Control protocol, the
  IOCTL/IOVAR multiplexer (SDPCM equivalent in the brcmfmac fork).
- `bwfm_chip_*` — backplane probing (CHIPCOMMON, ARM CR4 / CM3 cores,
  SOCRAM/SYSMEM windows). This is the part Phoenix has to reimplement
  whatever path is chosen, because it talks to silicon directly.
- `if_bwfm_sdio.c` — `bwfm_sdio_buf_read/write`, F1/F2 functions,
  Mailbox / Interrupt thread, watchdog tick to clock the SDIO host out of
  HT-required mode.

## 4. OpenBSD `bwfm`

Same code base, slightly older. Manual page `bwfm(4)` at
<https://man.openbsd.org/bwfm>. OpenBSD's bwfm is the upstream of NetBSD's
fork; both share `dev/ic/bwfm.c`. Pi-3-class status historically: bwfm
recognises CYW43455 but boot has hit "HT avail timeout",
"bwfm_sdio_buf_write: error 60", "could not load microcode" — i.e. the
SDIO host or the F2 enable sequence trips up. NetBSD's tree has since
recovered Pi 4 specifically (see §3); OpenBSD lags. (Discussion thread:
<https://forums.raspberrypi.com/viewtopic.php?t=245225>.)

## 5. Circle (`rsta2/circle`) WLAN add-on

Circle is a C++ bare-metal environment for the Pi
(<https://github.com/rsta2/circle>). It carries
`addon/wlan/`, of which the headline file is
`addon/wlan/ether4330.c`
(<https://github.com/rsta2/circle/blob/master/addon/wlan/ether4330.c>).

`ether4330.c` is **the Plan 9 driver** — Circle imports the Plan 9 BCM4330
driver almost verbatim. The code is the same lineage that runs on 9front /
Bell-Labs Plan 9 on the Pi. Pi-Forum threads
(<https://forums.raspberrypi.com/viewtopic.php?t=240243>) confirm that the
Plan 9 driver works "on RPi 3B, 3B+ and 4B with only slight modifications"
but with significant caveats: open networks join successfully, **WPA2 was
historically broken**, and EAPOL needed to be added on top. The driver
covers chip init, SDIO transport, IOCTL/IOVAR plumbing, and a primitive
event loop, in roughly 3 kLoC of C — far smaller than bwfm or WHD.

Circle also bundles a working SDHOST driver
(`addon/SDCard/sdhost.h`) used by the WLAN add-on; this is the BCM2835
auxiliary SD host (not Arasan) that the WiFi chip is wired to on the Pi 3
class. On Pi 4 the WiFi chip moved to the dedicated Arasan SDHCI port.

For Phoenix, Circle/Plan 9 is the **reference of choice for "minimum
viable" SDIO-bus + chip-init code**: small, readable, no kernel-API
assumptions.

## 6. Pico-SDK `cyw43-driver` (Damien George)

Network library: <https://www.raspberrypi.com/documentation/pico-sdk/networking.html>.
Source, separate repo: <https://github.com/georgerobotics/cyw43-driver>
(vendored into pico-sdk under `lib/cyw43-driver/`).

Authored by Damien George (MicroPython). Pure C, **no Linux dependencies,
no RTOS dependencies** — the driver expects the integrator to provide a
small set of bus and concurrency callbacks. Architecture:

- `src/cyw43_ll.c` — low-level F0/F1/F2, backplane window paging,
  firmware/CLM/NVRAM upload, IOCTL/IOVAR, async events. The "guts".
- `src/cyw43_ctrl.c` — high-level state machine (scan / join / leave).
- `src/cyw43_stats.c`, `src/cyw43_country.c` — supporting tables.
- `firmware/` — pre-baked firmware blobs as C arrays (no filesystem
  dependency).
- Bus glue is **out of band**: pico-sdk supplies
  `pico_cyw43_driver/cyw43_bus_pio_spi.c` (PIO-driven gSPI). On the Pico W
  the chip is wired SPI-over-PIO, NOT SDIO. CYW43439 (Pico W) only exposes
  a gSPI interface. CYW43455 (Pi 4) is SDIO-only. So **the cyw43-driver
  bus layer cannot be reused unmodified for Phoenix on Pi 4**, but
  `cyw43_ll.c` (firmware upload + IOCTL/IOVAR) is bus-agnostic and reusable.

License: Permissive (BSD-3-Clause-style, see `LICENSE` in the cyw43-driver
repo). Free to integrate into Phoenix.

## 7. Bare-metal blog write-ups

**Zerowi — Jeremy Bentham** (<https://iosoft.blog/zerowi/>). Six-part series
on the Pi Zero W (CYW43438):

- Part 2 — SDIO bring-up (<https://iosoft.blog/2020/03/08/zerowi-part2/>).
- Part 5 — IOCTLs (<https://iosoft.blog/2020/03/27/zerowi-part5/>).
- Part 6 — Joining a network (<https://iosoft.blog/2020/04/14/zerowi-part6/>).
  Confirms: "all the complexities of WPA are handled by the on-chip
  firmware, so it only takes a few simple IOCTL commands to join a secure
  network", and documents the SDPCM + IOCTL header structure.
  The follow-on **PicoWi** project (<https://iosoft.blog/2022/12/06/picowi/>)
  recapitulates the same architecture for Pico W's CYW43439 over SPI.

**Plan 9 / Circle thread** (<https://forums.raspberrypi.com/viewtopic.php?t=240243>)
— actively maintained discussion about porting Plan 9 ether4330 to Pi 3 / 4.

**Failed bare-metal attempts** — multiple Pi 3 WiFi attempts have stalled at:
(a) undocumented BCM2835 auxiliary SD host (sdhost) and SD-vs-WiFi GPIO mux;
(b) board-revision-specific NVRAM that silently produces dead radio with
the wrong calibration data; (c) WPA2 EAPOL re-implemented host-side
before authors realised the chip firmware handles it.

## 8. Cypress / Infineon datasheets

CYW43455 has **no public full datasheet** — Cypress / Infineon distributes
only a brief product brief and the WICED/WHD developer docs.
The WHD HTML reference (<https://infineon.github.io/wifi-host-driver/html/>)
is the closest thing to a public spec for the host-side protocol (SDPCM,
IOCTL/IOVAR list, event codes). For SDIO bring-up (F0/F1/F2 enable, OCR,
backplane window addressing) the SDIO Simplified Specification +
brcmfmac/bwfm source is the substantive primary source.

## 9. NVRAM blob

The `brcmfmac43455-sdio.raspberrypi,4-model-b.txt` calibration file is the
required NVRAM the firmware reads at boot. Authoritative copies:

- OpenWRT: <https://github.com/openwrt/cypress-nvram/blob/master/brcmfmac43455-sdio.raspberrypi,4-model-b.txt>
- linux-firmware (endlessm mirror): <https://github.com/endlessm/linux-firmware/blob/master/brcm/brcmfmac43455-sdio.raspberrypi,4-model-b.txt>

Critical fields: `manfid`/`devid` (chip ID), `boardrev`/`boardtype`/
`boardflags*` (wrong flags → silent radio failure), `macaddr` (usually
blank — Pi 4 reads MAC from OTP via mailbox), `extpagain2g/5g`,
`maxp2ga0`/`maxp5ga0` (TX power caps), `btc_*` (BT coex), and RF
calibration tables (`cckPwrIdxCorr`, `dot11agofdmhrbw202gpo`,
`AvVmid_c0`, etc.). Must be carried verbatim — none can be invented.

## 10. Synthesis — what's the right path for Phoenix?

Three viable options, ranked:

**Option A — Port NetBSD `bwfm`.** Best fit overall. Clean-room C, already
proven on Pi 4 over the same Arasan SDHCI we target for SD. Dependency
surface is `sys/dev/sdmmc` (needed anyway) and `net80211` (small shim).
Effort: SDIO/SDMMC first, then ~5 kLoC of bwfm core plus net glue.
BSD-2-clause licensed.

**Option B — Adopt Pico-SDK `cyw43-driver` + custom SDIO bus.** Smallest
codebase, least baggage, embedded-by-design. Catch: bus layer is gSPI;
CYW43455 needs SDIO. Write fresh `cyw43_bus_sdio.c` against Phoenix
SDHCI, keep `cyw43_ll.c`/`cyw43_ctrl.c` unmodified. Risk: driver was
tested only against CYW43439; CYW43455 chip-init differs (backplane core
IDs, SOCRAM size, firmware ABI minor).

**Option C — Port Infineon WHD.** Production-grade but master has dropped
CYW43455. Most "RTOS-native" option philosophically. Effort similar to
A with more glue.

Not recommended: Circle/Plan 9 ether4330 (BCM4330-era, predates Pi 4
chip-init and Arasan SDHCI), or FreeBSD LinuxKPI (drags in Linux compat
exactly when Phoenix wants the opposite).

**Recommendation:** prototype with Option A (bwfm) as the reference
implementation, with Option B (cyw43-driver) as the long-term simplification
target once SDIO/SDMMC is solid. Keep the NVRAM calibration file
verbatim from `cypress-nvram`. The chip firmware does WPA2 — Phoenix only
ever needs to plumb a passphrase, never an EAPOL state machine.

---

Sources:
- [Infineon wifi-host-driver](https://github.com/Infineon/wifi-host-driver)
- [WHD HTML reference](https://infineon.github.io/wifi-host-driver/html/index.html)
- [whd-bsp-integration cybsp_wifi.c](https://github.com/Infineon/whd-bsp-integration/blob/master/cybsp_wifi.c)
- [FreeBSD LinuxKPI Q4-2024 wireless status](https://www.freebsd.org/status/report-2024-10-2024-12/lkpi-wireless/)
- [narqo/freebsd-brcmfmac (BCM4350/BCM43455)](https://github.com/narqo/freebsd-brcmfmac)
- [NetBSD bwfm(4) man page](https://man.netbsd.org/bwfm.4)
- [OpenBSD bwfm(4) man page](https://man.openbsd.org/bwfm)
- [NetBSD port-arm: bwfm firmware path discussion](http://mail-index.netbsd.org/port-arm/2024/06/10/msg008760.html)
- [Circle ether4330.c (Plan 9 import)](https://github.com/rsta2/circle/blob/master/addon/wlan/ether4330.c)
- [Pi-forum BCM43438/Plan 9 thread](https://forums.raspberrypi.com/viewtopic.php?t=240243)
- [pico-sdk cyw43_bus_pio_spi.c](https://github.com/raspberrypi/pico-sdk/blob/master/src/rp2_common/pico_cyw43_driver/cyw43_bus_pio_spi.c)
- [pico-sdk networking docs](https://www.raspberrypi.com/documentation/pico-sdk/networking.html)
- [Zerowi index](https://iosoft.blog/zerowi/)
- [Zerowi part 2 — SDIO](https://iosoft.blog/2020/03/08/zerowi-part2/)
- [Zerowi part 5 — IOCTLs](https://iosoft.blog/2020/03/27/zerowi-part5/)
- [Zerowi part 6 — joining](https://iosoft.blog/2020/04/14/zerowi-part6/)
- [PicoWi (CYW43439 SPI)](https://iosoft.blog/2022/12/06/picowi/)
- [openwrt cypress-nvram brcmfmac43455 raspberrypi,4](https://github.com/openwrt/cypress-nvram/blob/master/brcmfmac43455-sdio.raspberrypi,4-model-b.txt)
- [endlessm/linux-firmware brcmfmac43455 raspberrypi,4](https://github.com/endlessm/linux-firmware/blob/master/brcm/brcmfmac43455-sdio.raspberrypi,4-model-b.txt)
