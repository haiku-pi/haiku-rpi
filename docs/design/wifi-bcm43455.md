# BCM43455 WiFi for Haiku on the Raspberry Pi 4 (SDIO, `bwfm`)

Status: design only (2026-10-18). Nothing here has been built or run on hardware.
Goal (PLAN.md H11): scan, WPA2-PSK join and a DHCP lease on the on-board CYW43455, through
Haiku's normal NetServer / wpa_supplicant path.

Citation keys (file:line). Haiku paths are relative to `sources/haiku/` at `bf3a1d0bdb`.
- **[OB]** OpenBSD `sys/dev/ic/bwfm.c`, **[OBR]** `bwfmreg.h`, **[OS]** `sys/dev/sdmmc/if_bwfm_sdio.c`,
  **[OIO]** `sys/dev/sdmmc/sdmmc_io.c`, **[OF]** `sys/dev/fdt/sdhc_fdt.c` — from
  `<phoenix-rpi>/external/openbsd-src` (HEAD `3d80b15`; the sdmmc files are outside the
  sparse checkout: `git show HEAD:sys/dev/sdmmc/<file>`).
- **[LS]** Linux `drivers/net/wireless/broadcom/brcm80211/brcmfmac/sdio.c`, **[LC]** `.../cfg80211.c`,
  **[LI]** `drivers/mmc/host/sdhci-iproc.c` — `<phoenix-rpi>/external/linux` (raspberrypi/linux).
- **[PX]** `<phoenix-rpi>/sources/phoenix-rtos-devices/wifi/rpi4-wifi/rpi4-wifi.c` (Phoenix driver,
  WPA2 + DHCP + 3 MB/s proven); **[PM]** `~/.claude/projects/-home-houp-phoenix-rpi/memory/project_wifi_fw_exec_gate_91.md`;
  **[PK]** `docs/knowledge/from-phoenix/wifi-bcm43455-non-linux.md`.
- **[DTS]** `artifacts/pi-firmware/bcm2711-rpi-4-b.dts` (the DT the firmware hands to U-Boot/Haiku).
- **[WS]** `github.com/haiku/wpa_supplicant` `wpa_supplicant/wpa_gui-haiku/main_haiku.cpp` @`025a7eb`
  (the HaikuPorts recipe's pinned source; fetched with `gh`).

## 0. Key findings

1. **Haiku already has the right 802.11 stack: `openbsd_wlan`** (OpenBSD net80211 incl. the in-kernel
   EAPOL supplicant `ieee80211_pae_*.c`), used by `idualwifi7260` (iwm) and `iaxwifi200` (iwx). Its
   Haiku glue has a join ioctl that hands the driver an SSID + **32-byte PMK** computed by
   wpa_supplicant (`IEEE80211_IOC_HAIKU_JOIN`, `src/libs/compat/openbsd_wlan/net80211/ieee80211_haiku.cpp:367-456`;
   sender [WS]:564-605, used when `wpa_supplicant_add_iface()` fails, [WS]:436-443). OpenBSD's `bwfm`
   is written against exactly this net80211 and does WPA host-side (`sup_wpa=0`, [OB]:564-569; EAPOL
   into `ieee80211_eapol_key_input`, [OB]:2401). → port `bwfm`, do not write a FullMAC stack.
2. **SDIO does not exist in Haiku.** The mmc bus manager only knows SD/MMC memory; `CARD_TYPE_SDIO`
   is declared (`headers/private/drivers/mmc.h:28`) but never produced. sdhci's command table rejects
   CMD5/52/53 (`busses/mmc/sdhci.cpp:289` "Unknown command"). Worse, an SDIO-only card **hangs the
   scan**: CMD8 fails → CMD1 fails → the ACMD41 loop `while ((ocr & (1 << 31)) == 0)` never ends
   (`bus_managers/mmc/mmc_bus.cpp:236-292`; `ocr` is never written by the failing command).
3. **The WiFi controller is the *legacy* Arasan ("mmcnr", `brcm,bcm2835-mmc`), not emmc2**, with a
   different quirk set, a different firmware clock id, and **the same GIC SPI 126 as the boot SD card**
   ([DTS]:1886-1907 vs 2073-2077). Attaching it carelessly can break the root disk (§1.1).
4. **The Phoenix "firmware won't execute" saga is already solved in bwfm**: TCM size from CR4
   bank info ([OB]:1533-1557; Phoenix measured 0xC8000 → RAM top 0x260000, not the folklore 0x238000,
   [PM] 2026-08-09), NVRAM at `ramtop - len` with the length token ([OB]:3009-3087, [OS]:526-542),
   SDIO-core intstatus clear before the reset vector ([OS]:1049), ALP-only download ([OS]:420-429),
   fw+NVRAM read-back verify ([OS]:514-542), RX glom ([OS]:1294-1303, 1313-1421) and the credit
   window ([OS]:1249). The remaining risk is in *our* SDHCI/SDIO layer, which is where Phoenix's
   other bugs were (byte-count wrap, F2 block size, PIO lost edge, chip doze).

## 1. What exists vs. what is missing

### 1.1 Host controller (mmcnr @ 0x7e300000 → CPU 0xfe300000)

| Item | Haiku today | Needed for mmcnr | Evidence |
|---|---|---|---|
| FDT match | only `brcm,bcm2711-emmc2` (`sdhci_fdt.cpp:40-45`); only the **first** compatible is visible (`:206` TODO) | add `brcm,bcm2835-mmc` (mmcnr's first string) | [DTS]:1887 |
| Disabled twin | none | `mmc@7e300000` (status `disabled`) has the same reg + compatible → check `status` like `genet.cpp:350`, or two `SdhciBus` drive one block | [DTS]:1388-1392 |
| Base clock | firmware **EMMC2** (id 12), hard-coded (`sdhci_fdt.cpp:71`) | **EMMC** (id 1, `BCM2835_CLOCK_EMMC`); Phoenix saw 250 MHz at core_freq=250, ask, don't assume | [PX]:398-446 |
| Caps register | trusted (`sdhci.cpp:134` DMA, `:155` timeout, `PowerOn` voltages) | **ignore caps**: 3.3 V, HS, max blk 1024, no SDMA/ADMA → PIO; data timeout counts SDCLK → program 0xE | [LI]:253-271 (`missing_caps`, `DATA_TIMEOUT_USES_SDCLK`), [OF]:252-261 |
| Card detect | `PowerOn()` and `SetScanSemaphore()` require `IsCardInserted()` (`sdhci.cpp:819,862`) | `non-removable` → always powered + scanned (Linux: `BROKEN_CARD_DETECTION`) | [DTS]:1894, [LI]:254 |
| HISPD bit | set above 25 MHz since `bf3a1d0bdb` (`sdhci.cpp:660`) | **never** on this controller (`NO_HISPD_BIT`) | [LI]:256, [OF]:261 |
| 32-bit access | `NarrowRegister` (`sdhci.h:84-119`) | same rule here (`sdhci_iproc_32only_ops`, OpenBSD `SDHC_F_32BIT_ACCESS`) — already OK | [LI]:258, [OF]:260 |
| Shared IRQ 126 | `HandleInterrupt` returns `B_HANDLED_INTERRUPT` for **any** non-zero status (`sdhci.cpp:929-1013`), and the constructor status-enables all normal bits incl. 0x100 (`:164`, `sdhci.h:359-362`) | claim only `status & signal_enable`; level dispatch stops at the first claimer (`system/kernel/interrupts.cpp:298-308`), so a falsely-claiming mmcnr starves emmc2 | [DTS]:1889/2076 |
| Card interrupt (0x100, misnamed `SDHCI_INT_CARD_STATUS`) | unused, but status-enabled → logged as "Remaining interrupts" forever (level, not W1C) | SDHCI §2.2.18 service: clear status-enable while servicing, re-enable after | [PX]:5604-5621, 5708-5715 |
| PIO | `_TransferPio` (`sdhci.cpp:566`): fixed 512 B blocks, waits on the **latched** BUF_*_READY bit; `ExecuteDataCommand` (`:434`) read-only, ≤512 B, R1 | variable block size (F1 64, F2 512), byte mode 4..512, writes; ack first then poll PRESENT_STATE level bits 10/11 (`bcm2835_mmc_transfer_pio`) | lost-edge hazard [PX]:688-709 |
| Pinmux | — | GPIO 34-39 → ALT3 (fsel 7), pulls none/up/up/up/up/up; nobody verified the firmware does it | [DTS]:1130-1134, [PX]:4200-4202 |

### 1.2 MMC bus manager / SDIO

Exists: `mmc_bus_interface` (bus manager → sdhci) and `mmc_device_interface` (driver → bus manager)
with `execute_command`, `do_io(IOOperation)`, and since `bf3a1d0bdb` `execute_data_command` (read
≤512 B) and `set_clock` (`mmc.h:89-137`); per-card nodes with `mmc/rca`, `mmc/type`; one card per bus.
`mmc_disk` already ignores `CARD_TYPE_SDIO` (`drivers/disk/mmc/mmc_disk.cpp:104-106`).

Missing (all of it): CMD5 (R4) probing **before** CMD8/ACMD41; CMD3/CMD7 for I/O cards; CCCR/FBR
access and CIS parsing (manufacturer 0x02d0, device 0xa9bf, Linux `include/linux/mmc/sdio_ids.h:56,78`);
CCCR I/O reset (reg 0x06 bit 3) since CMD0 does not reset the I/O part; function enable/ready
(CCCR 0x02/0x03); per-function block size (FBR 0x110/0x210); 4-bit (CCCR 0x07) and high-speed
(CCCR 0x13 SHS/EHS); CMD52 (R5); CMD53 byte/block, incrementing or fixed address, read/write;
SDIO card interrupt delivery (CCCR 0x04 IEN) to a function driver in thread context; publishing the
node with `sdio/vendor`, `sdio/device`, `sdio/functions`. Reference order: [OIO]:73-127 (reset, CMD5,
OCR), 134-167 (CMD3/CMD7, functions), 173-203 (CIS, HS + 4-bit), 230-270 (enable/disable),
551-657 (multi/region = whole blocks in block mode + remainder in byte mode → never over-reads).

### 1.3 FullMAC driver

None in Haiku. FreeBSD has only LinuxKPI `brcmfmac` with SDIO compiled out (`BRCMFMAC_SDIO= 0`,
needs MMCCAM; `sys/modules/brcm80211/brcmfmac/Makefile`) — and Haiku has no LinuxKPI. OpenBSD/NetBSD
`bwfm` (ISC licence; NetBSD's is a port with a known-working Pi 4 setup, [PK] §3) = core [OB] 3269
lines + SDIO glue [OS] 1528 + headers ~1200. The SDIO glue needs only 13 `sdmmc_*` calls
(`io_read/write_1/4`, `io_read/write_region_1`, `io_read_multi_1`, `io_set_blocklen`,
`io_function_enable/disable`, `intr_establish/enable`, CIS manufacturer/product) — a thin shim.

### 1.4 net80211 and WPA

- `openbsd_wlan` net80211 + crypto exist; `openbsd_network` already provides `ml_*`, `task_*`/`systq`,
  `rwlock`, `tsleep_nsec`, `if_input`. Missing for bwfm: `dma_alloc` (→ `malloc`, PIO only),
  `mallocarray` (local `#define`, as `if_iwx.c:137`), `config_mountroot` (call the hook directly, as
  `if_iwx.c:12097-12104`), FDT `OF_getprop` for the board type ([OB]:3135-3150; root
  `compatible` = `raspberrypi,4-model-b`). Build with `IEEE80211_STA_ONLY` (drops the AP paths).
- Haiku glue limits shared with iwx: `SCAN_REQ` is a no-op, results come from
  `SIOCG80211ALLNODES` (`ieee80211_haiku.cpp:180-214`); `STA_INFO` unsupported. bwfm scans all
  channels in firmware (`IEEE80211_C_SCANALL`, [OB]:207) on `bwfm_init`, so this fits.
- Join: NetServer always goes through wpa_supplicant (`servers/net/NetServer.cpp:1077-1125`);
  when `add_iface` fails (as for iwx/iwm, whose stack it cannot drive) it falls back to `HAIKU_JOIN`
  with the PMK ([WS]:581-602) → `SIOCS80211NWID/WPAPSK/WPAPARMS` → bwfm `bwfm_connect` ([OB]:1985-2065).
- **Fallback** (what Phoenix proved, [PM] 2026-08-12): firmware supplicant — `wsec=4`,
  `wpa_auth=0x80`, `sup_wpa=1`, `WLC_SET_WSEC_PMK` (268), `WLC_SET_SSID`. The HAIKU_JOIN PMK maps
  1:1 onto `brcmf_set_pmk` (raw 32 bytes, flags 0, [LC]:1710-1743), so this is a ~40-line switch
  inside `bwfm_connect`, not a different architecture.

### 1.5 Firmware files

bwfm asks for (`[OB]:3153-3269`, chip name from chipcommon rev, [OS]:377-382):
`brcmfmac43455-sdio.bin`, `brcmfmac43455-sdio.raspberrypi,4-model-b.txt` (else `...-sdio.txt`),
`brcmfmac43455-sdio.clm_blob`. Haiku looks in `/boot/system/{non-packaged/,}data/firmware/<driver>/`
(`src/libs/compat/freebsd_network/firmware.c:63-86`, wrapped by `openbsd_network/compat/sys/device.h:13`).
The Phoenix-pinned set (`<phoenix-rpi>/.firmware/`): `.bin` 643651 B sha256 `d408faa9…`
(= linux-firmware `cypress/cyfmac43455-sdio.bin`, fw 7.45.234), `.clm_blob` 4733 B `15f50a27…`,
`.txt` 1883 B. Licence: `LICENCE.cypress` permits redistributing the object code "solely for use
in connection with Cypress integrated circuit products" — fine for an image, not for the MIT
source tree: ship as a separate package / mkimage fetch pinned by sha256, as Phoenix does
([PX]:79-90). The NVRAM `.txt` has its own linux-firmware WHENCE entry — verify before publishing.
**CLM is optional in bwfm** ([OB]:3249-3253) **but mandatory for the radio**: without it `WLC_UP`
succeeds and the radio has no channels ([PM] 2026-08-09) → make the Haiku glue fail loudly.

## 2. Architecture

**Pick: port OpenBSD `bwfm` (core + SDIO glue, kept close to verbatim with `__HAIKU__` hunks,
iwx-style) onto `openbsd_wlan`, on top of real SDIO support in the Haiku mmc bus manager and
sdhci, joined by a small `sdmmc` shim; WPA host-side as in bwfm, firmware supplicant as a switch.**

```
NetServer → wpa_supplicant ──HAIKU_JOIN(PMK)──► openbsd_wlan net80211 (scan table, EAPOL, keys)
                                                  ▲ ic_newstate/ic_set_key/if_start
drivers/network/wlan/brcmwifi43xx (new):  bwfm.c  +  if_bwfm_sdio.c  +  sdmmc shim (sdio_compat.cpp)
                                                  ▼ mmc_device_interface (+SDIO ops)
bus_managers/mmc (SDIO enumeration, CCCR/CIS, card-int thread)
busses/mmc/sdhci + sdhci_fdt (mmcnr quirks, R4/R5, CMD53 PIO, shared-IRQ fix, WL_ON + pinmux)
```

Attachment (the one genuinely new compat piece): compat drivers are old-style drivers whose
`init_hardware` enumerates a bus into `sProbedDevices[]`, with only `BUS_pci` and `BUS_uhub`
(`src/libs/compat/freebsd_network/device.h:31-33`, `driver.c:52-85,154`; USB model in `usb.cpp`).
`HAIKU_FBSD_WLAN_DRIVER_GLUE` is hard-wired to `_fbsd_init_hardware_pci`
(`compat/sys/haiku-module.h:156-166`), so add a `HAIKU_FBSD_WLAN_SDIO_DRIVER_GLUE` →
`_fbsd_init_hardware_sdio`, `BUS_mmc` and `sdio.cpp`: walk device-manager nodes with `B_DEVICE_BUS`=`mmc`,
`mmc/type`=`CARD_TYPE_SDIO`, vendor 0x02d0; get `mmc_device_interface` + cookie the way
`mmc_disk.cpp:284-292` does; `report_probed_device()`; bwfm's `DRIVER_MODULE(bwfm, mmc, …)`. Trap:
the mmc scan runs asynchronously in the bus worker thread, so the SDIO node may not exist when the
net stack first loads the driver → retry/rescan in `init_hardware`.

Effort (ed = focused engineer-day incl. bench cycles; Phoenix needed ~2 months without a reference):

| Piece | New/changed code | ed |
|---|---|---|
| sdhci/sdhci_fdt mmcnr support, shared-IRQ fix, PIO rewrite, CMD53 path | ~400 lines | 3-4 |
| WL_REG_ON + GPIO 34-39 pinmux (mailbox `GET_GPIO_STATE` 0x00030041 is missing from `bcm2835_mailbox.h:34-50`) | ~80 | 0.5 |
| mmc bus manager SDIO (enumeration, CCCR/CIS, ops, card-int thread) | ~600 | 4-5 |
| compat `BUS_mmc` attach + sdmmc shim | ~450 | 3 |
| bwfm port (+ KSO wake, 43455 watermark, fw-supplicant switch) | ~5 kLoC mostly verbatim, ~300 changed | 5-7 |
| bring-up through DHCP + glom/throughput stabilisation | — | 5-8 |
| **Total** | | **~21-28** |

Rejected alternatives: (B) native Haiku FullMAC driver from Phoenix's `rpi4-wifi.c` with its own
`wlan_control` — no net80211 means re-implementing scan tables, link notifications and the join
ioctl, and 7.4 kLoC of probe-shaped code would need a rewrite anyway; (C) LinuxKPI `brcmfmac` —
Haiku has no LinuxKPI, and even FreeBSD ships it without SDIO; (D) Infineon WHD / pico
`cyw43-driver` — no 43455 on WHD master, gSPI-only bus layer, no net80211 ([PK] §1, §6).

Risks (ordered):

| # | Risk | Mitigation |
|---|---|---|
| R1 | mmcnr's handler claims emmc2's interrupts → root disk stalls/storms | land the `status & signal_enable` fix **first**, regress SD boot + disk bench before any SDIO code |
| R2 | PIO lost edge → partial firmware download (Phoenix rc −5, ~1/100 boots, ~2/11 at core_freq=500, [PM] 2026-09-27) | level-bit PIO; on failure WL_ON cycle + reload ×3 (`wifi_bringupRetry`, [PX]:5066) |
| R3 | compat layer never attached a non-PCI/USB device (probe order, `gDevices[]`, giant lock) | `BUS_mmc` spike before porting bwfm: a stub driver that attaches and publishes `/dev/net/bwfm/0` |
| R4 | chip dozes / drops HT while idle → first control frame after idle fails ([PX]:1878-1924); bwfm sets `mpc=1`, fast PS ([OB]:469,543-548) and treats 4345 as save-restore capable so `htclk` is a no-op ([OB]:1393-1401, [OS]:596-602) | start with `mpc=0` + `PM=CAM`; add a KSO/HT wake before every control frame (brcmf `kso_control` analogue) |
| R5 | host-EAPOL timing over SDPCM (M1→M2 must beat the AP's retry timer while frames sit in our queues) | if (d) fails, flip to the firmware supplicant (§1.4) |
| R6 | RX stream desync (glom pad, block over-read) — Phoenix lost 18% of RX until glom handling ([PM] 2026-09-02) | bwfm's exact-length reads; count desyncs; `brcmf_sdio_rxfail`-style resync ([PX]:2042-2081) |

## 3. Staged plan

Every stage runs under the bench lock; WiFi tests use the existing `PhoenixNet` soft-AP (never
changed), with the PSK in an uncommitted file. Grade by positive markers (the Pi UART corrupts ~1%
of lines). Each stage ends with `scripts/snapshot-state.sh`.

### Stage 0 — controller attach (no SDIO yet)
Files: `busses/mmc/sdhci_fdt.cpp` (compatible table with per-entry quirks: clock id, `non-removable`,
no-HISPD, fixed caps, `status` check), `sdhci.cpp/.h` (quirk flags, `HandleInterrupt` claim rule,
card-int status masking, level-bit PIO), mailbox header (`GET_GPIO_STATE`).
Gotchas: the SPI 126 sharing (R1); EMMC clock id 1; HISPD; disabled twin node. sdhci **panics**
on the error paths SDIO hits routinely (command inhibit at entry, failed waits: `sdhci.cpp:336,353,
419,782`) — a wrong-length F2 read gives DATA_CRC and a wedged bus that reads 0x18181818 ([PM]
2026-08-09); these must become `B_IO_ERROR` + CMD/DAT reset. `_ExecuteCommand` also returns
`B_BUSY` on DataInhibit before its `SD_IO_ABORT` exemption, which would refuse the CCCR-abort CMD52
that RX resync needs ([PX]:2053-2081).
Exit: SD boot + disk bench unchanged; syslog shows mmcnr at 0xfe300000 with the EMMC base clock;
`WL_ON` read **before** any toggle is logged (this answers §4's "who left it on" on our bench).

### Stage (a) — SDIO enumeration
Files: `bus_managers/mmc/mmc_bus.cpp` (CMD5 branch after CMD0, before CMD8), `mmc_module.cpp` +
`mmc.h` (SDIO ops on both interfaces: `io_rw_direct(fn, reg, write, data)`,
`io_rw_extended(fn, addr, incr, write, blksz, nblocks|nbytes, buf)`, `set_card_interrupt`), `sdhci.cpp`
(R4 = `kR3Type` shape for CMD5, R5 = `kR1Type` shape for 52/53, CMD53 data via the new PIO; the
`_ExecuteCommand` split of `bf3a1d0bdb` makes the reply type a parameter already, `sdhci.cpp:299`).
Sequence (Phoenix-proven, [PX]:4203-4250; [OIO]:73-203): WL_ON cycle → 400 kHz → CCCR reset → CMD0 →
CMD5(0) → CMD5(OCR & 0xffffff) until bit 31 (≤50 × 1 ms) → CMD3 (R6 → RCA) → CMD7 → CIS walk →
F1 enable (CCCR 0x02 bit 1, wait 0x03) → **KSO** (F1 0x1001F bit 0, required on SDIO core rev ≥ 12,
[PX]:4241-4250, [OS]:311-318) → 4-bit + EHS → 25 MHz → F1 blksz 64, **F2 blksz 512** (Phoenix forgot
FBR2 for months, [PM] 2026-09-01; Linux uses 512, `bcmsdh.c:45`).
Gotchas: no HISPD; 41.67 MHz (250/6) is the fastest legal clock and only after a round-trip check
([PX]:1197-1224, 1328); CMD53 byte count is 9 bits, 0 = 512, never ask byte mode for >512 ([PM]
2026-09-01); OpenBSD's `sdmmcdevs:63` labels 0xa9bf "BCM43364" — the match ([OS]:231) works, the
name is wrong; log chipcommon id/rev (expect 0x4345 rev 6 = 43455c0; rev 9 would request 43456
firmware we do not ship).
Exit: `mmc: SDIO card 02d0:a9bf, RCA …`, CMD5 OCR function count ≥ 2 (expect 2: F1 backplane,
F2 WLAN; BT is on the UART; bwfm needs > 1, [OS]:238), CCCR rev, F1 ready; a 4 KB backplane
write/read-back pattern at 0x198000 matches.

### Stage (b) — firmware download and "fw ready"
Files: new `src/add-ons/kernel/drivers/network/wlan/<name>/` (`dev/ic/bwfm.c`, `bwfmreg.h`, `bwfmvar.h`,
`dev/sdmmc/if_bwfm_sdio.c/.h`, `glue.c` with `HAIKU_DRIVER_REQUIREMENTS(OBSD_WLAN)` like
`iaxwifi200/glue.c`), `src/libs/compat/freebsd_network/sdio.cpp` + `driver.c`/`device.h` (`BUS_mmc`),
the shim (`sdmmc_io_*` → mmc device interface; one rwlock as `sc_lock`).
Sequence is bwfm's: `buscore_prepare` (ALP request, [OS]:1001-1042) → EROM walk / `bwfm_chip_attach`
→ download at rambase 0x198000 → NVRAM at `rambase + ramsize − nvlen` → intstatus=0xffffffff →
reset vector to address 0 → CR4 `resetcore(CPUHALT,0,0)` ([OB]:1275-1285) → HT clock → F2 enable →
`hostintmask`, watermark ([OS]:433-464).
Gotchas: expected numbers from Phoenix ([PM] 2026-08-09): ChipCommon 0x18000000, ARM CR4
0x18002000 (wrapper 0x18102000), **SDIO_DEV 0x18004000** (Phoenix's 0x18005000 guess read the wrong
mailbox), TCM ramsize 0xC8000 → token at 0x25FFFC; FWREADY in `tohostmailboxdata` (SDIO_DEV+0x4C)
= 0x0004_0008; CHIPCLKCSR HT_AVAIL 0x80. "HT avail timeout" ([OS]:633) is the historic OpenBSD-on-Pi
symptom; for Phoenix its root cause was NVRAM placement. Watermark: bwfm writes 8 ([OS]:450); Linux
uses the 43455-specific F2 watermark 0x60 + `F2WM_ENAB` + `MESBUSYCTRL` 0x50|enable
([LS]:57-59, 4522-4533) — first knob if F2 transfers CRC or time out. Don't reset F2 transfers blindly:
a single bad header is what an empty FIFO looks like ([PX]:2042-2050).
Exit: "firmware verification" passes ([OS]:514-542 — free milestone), then `BWFM_DEBUG` console
([OS]:1482-1527) prints `wl0: Broadcom BCM4345 … 7.45.234` and `sdpcmd_dpc: Enable`; `GET_VERSION`
returns 2; `cur_etheraddr` = dc:a6:32:… (bwfm prints `address …`, [OB]:267).

### Stage (c) — scan
Files: bwfm as is; the shim's card-interrupt path (CCCR IEN = 0x07, `hostintmask` frame bit, thread
calls `bwfm_sdio_intr`) plus a 10 ms poll fallback (Phoenix ran IRQ with a 10 ms timeout,
[PX]:5570-5572, 5690-5744; bwfm itself reads RX unconditionally, [OS]:733-736).
Gotchas: CLM must be loaded before `WLC_UP` ([OB]:269; chunks of 1400 B, [OBR]:794 — > 512, so the
F2 write uses block mode: `tx_ctrlframe` pads to 512, [OS]:1120-1124); events arrive on SDPCM
channel 1 interleaved with control replies — bwfm's `proto_rxctl` matches by request id; escan
returns one result per beacon (dedup in net80211).
Exit: `ifconfig /dev/net/bwfm/0 list` / Network preflet lists ≥ the APs Phoenix saw (16 on this
bench, RSSI −37…−78), incl. `PhoenixNet` on channel 6.

### Stage (d) — WPA2-PSK association
Files: none new if host-side EAPOL works; else the `sup_wpa=1` switch in `bwfm_connect`.
Gotchas: bwfm keys go through `ic_set_key` → `wsec_key` iovar; the 4-way handshake frames are data
frames (ethertype 0x888e) on SDPCM channel 2 — they must not wait behind the TX credit window
([OS]:1076-1108; credits arrive on every RX frame, [PX]:1996-2004). Phoenix's first join after idle
failed until the KSO/HT wake (R4).
Exit: `B_NETWORK_WLAN_JOINED` notification (`ieee80211_haiku.cpp:471-489`), net80211 state RUN;
host journal shows `EAPOL-4WAY-HS-COMPLETED` for the Pi MAC.

### Stage (e) — DHCP and a usable link
Files: none expected (NetServer's DHCP client).
Gotchas: MTU frames are > 512 B in both directions → block mode + byte remainder; GLOM superframes
are not optional (`bus:rxglom=0` is ignored, [PM] 2026-09-02) — bwfm reads each sub-frame by its
slot length and strips the superframe header from slot 0 ([OS]:1350-1358), which matches Phoenix's
decoded wire format; TX stays non-glom (bwfm never enables txglom; bare frames egress, [PM]
2026-09-01). **Detector traps**: `tcpdump` on the AP interface and `iw station dump` rx_bytes show
nothing even when DHCP works ([PM] 2026-09-01); ground truth is the dnsmasq journal
(`DHCPACK(…) <ip> dc:a6:32:…`) and an application socket.
Exit: lease bound, `ping 10.43.0.1`, a 10 MB TCP transfer both ways with the desync/resync counters at
zero; target ≥ 3 MB/s (Phoenix PIO figure); n ≥ 3 runs, median (one-run A/B varies 2.6×, [PM]).

## 4. Power / reset sequencing (WL_REG_ON)

- **Who drives it:** the VideoCore firmware. WL_REG_ON is line 1 (`WL_ON`) of the firmware-owned
  expander (`raspberrypi,firmware-gpio`, [DTS]:1849-1855); the ARM reaches it only through the
  mailbox property `SET_GPIO_STATE` 0x00038041 / `GET_GPIO_STATE` 0x00030041 with GPIO number
  **129** (128 + line) ([PX]:300-316). BT_ON is line 0 (BT shares the chip but has its own enable);
  do not touch line 3 (`GLOBAL_RESET`).
- **Who leaves it on:** the firmware's DT has **no** `mmc-pwrseq`: the downstream DT deletes the
  upstream `wifi-pwrseq` (`external/linux/arch/arm/boot/dts/broadcom/bcm2711-rpi-4-b.dts:303-305`;
  upstream defines it as `mmc-pwrseq-simple` with `reset-gpios = <&expgpio 1 GPIO_ACTIVE_LOW>`,
  `bcm283x-rpi-wifi-bt.dtsi:4-17` + `bcm2711-rpi-4-b.dts:279-281`), i.e. Raspberry Pi OS never toggles
  it and relies on the firmware having raised it at boot. U-Boot has no WL_ON code
  (`board/raspberrypi/rpi/rpi.c`), but its `bcm2835_sdhci` driver binds `brcm,bcm2835-sdhci`
  (`drivers/mmc/bcm2835_sdhci.c:240`, mmcnr's second compatible) and `boot_targets=mmc`
  (`board/raspberrypi/rpi/rpi.env:80`) may probe it: CMD0/CMD8/ACMD41 are harmless to an SDIO card,
  but the chip may be left selected/half-initialised. Stage 0 logs the line before touching it.
- **What Haiku does:** always power-cycle at attach, so U-Boot and warm-reboot leftovers do not
  matter (CMD0 does not reset the I/O part): `WL_ON=0`, 50 ms, `WL_ON=1`, 150 ms, read back = 1
  ([PX]:325-346, the timing Phoenix enumerated reliably with; a 20× longer off time changed nothing,
  [PX]:318-322). Linux's `mmc-pwrseq-simple` uses 0 ms extra delays plus the core's ~10 ms power-up
  — 150 ms is comfortable. Then 400 kHz SD clock and ≥ 1 ms / 74 clocks before CMD5 ([PX]:4204-4209).
- **Pins and clocks around it:** GPIO 34-39 to ALT3 before the cycle ([PX]:4200-4202); no host action
  is needed for the 32 kHz LPO (Phoenix never set one up). The same cycle + full reload is the
  recovery for a failed download (R2) and for a chip that stops answering; forget the cached
  backplane window afterwards ([PX]:327, [OS]:768-780 `sc_bar0`).
- **Shutdown:** `bwfm_stop` + `WL_ON=0` on driver unload, so a warm boot into another OS starts cold.
