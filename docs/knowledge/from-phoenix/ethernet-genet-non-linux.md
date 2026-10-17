# GENET on Pi 4 — Non-Linux Implementations

Round-2 survey. Round 1 covered the Linux GENET driver
(`drivers/net/ethernet/broadcom/genet/`). This round documents every
*independent* implementation we can find: BSDs, U-Boot, UEFI, Circle,
Ultibo, and bare-metal blogs. The goal is to find the smallest proven
GENET subset and decide what Phoenix should port.

## 1. FreeBSD `if_genet.c`

FreeBSD's driver lives at `sys/arm64/broadcom/genet/if_genet.c` (plus
`if_genetreg.h`). It was committed as **rS360181** on 2020-04-22, after
review **D24436**, written by Mike Karels and **derived in part from
the NetBSD `bcmgenet.c` by Jared McNeill** — the file header notes the
NetBSD lineage explicitly. The man page `genet(4)` declares support
for IPv4/IPv6 checksum offload and 10/100/1000 full-duplex / 10/100
half-duplex on BCM-2711. (FreeBSD review **D24436**; man page
`man.freebsd.org/cgi/man.cgi?query=genet`.)

Structurally the FreeBSD driver follows the standard FreeBSD network
driver template:

- **Attach path** — FDT/`simplebus` probe, three IRQs (TX, RX, status),
  one register window. MAC address sourced via `if_getlladdr` after
  reading `UMAC_MAC0/1` if firmware programmed valid bytes (see §7).
- **Bus-DMA** — uses `bus_dma(9)` for descriptor rings and packet
  buffers. Each TX/RX descriptor gets its own `bus_dmamap_t`; explicit
  `BUS_DMASYNC_PREWRITE/POSTREAD` calls. There is no CMA equivalent —
  FreeBSD's bus-dma layer handles bounce buffers if needed, but on
  arm64 with coherent DMA the buffers are mapped device-coherent.
- **MII/MDIO** — uses FreeBSD's `miibus` framework. `genet_miibus_*`
  callbacks poll `UMAC_MDIO_CMD` for `MDIO_START_BUSY`, identical
  protocol to the Linux `bcmmii.c`.
- **TX coalescing / multi-queue** — single default ring (`DESC_INDEX`,
  ring 16); the 16 priority queues are not used. **No TSO/GSO**.
- **Interrupt handling** — full IRQ-driven, with separate TX/RX
  handlers that schedule taskqueues for descriptor reclaim.

The driver is roughly 1.5–2 kLOC of C. It is the most useful single
non-Linux reference because it is small, FreeBSD-licensed (BSD-2),
fully working on hardware in production, and structurally close to
what Phoenix-RTOS needs (a separate netif over a hardware DMA driver).

## 2. NetBSD GENET

Documented at `man.netbsd.org/genet.4`. Source lives at
`sys/dev/ic/bcmgenet*.c` plus `sys/dev/fdt/if_genet_fdt.c` (FDT
attach) and `sys/dev/acpi/if_genet_acpi.c` (ACPI attach for SBBR
boots). The original author is **Jared McNeill** and this is the
ancestor of the FreeBSD port (FreeBSD review D24436 says so). It uses
NetBSD's `bus_dma(9)` (same API as FreeBSD) and its `mii(4)` framework.
Same single-default-queue design as FreeBSD. The man page lists
attachment at both `acpi` and `fdt`.

## 3. OpenBSD `bse(4)`

OpenBSD drove the same hardware under the name `bse`. Manual page at
`man.openbsd.org/arm64/bse.4`. The driver first appeared in **OpenBSD
6.7** (2020). Source path: `sys/dev/fdt/if_bse.c` and
`sys/dev/fdt/if_bsereg.h`. OpenBSD does not advertise checksum offload
in this driver; the design is otherwise the same single-queue,
IRQ-driven model the BSDs share.

## 4. U-Boot `drivers/net/bcmgenet.c`

U-Boot's driver was committed in 2019 by **Amit Singh Tomar**
(GPL-2.0+, derived from Linux). It is the *minimum interesting subset*
for booting via TFTP. Total file: **~734 lines**, ~600 LOC.

What U-Boot deliberately does **not** do, compared to Linux:

- **No interrupts.** `bcmgenet_gmac_eth_recv()` polls the RX
  descriptor ring; `bcmgenet_gmac_eth_send()` polls TX completion.
- **No TX coalescing.** Every packet is one descriptor with SOP+EOP
  set; producer index is bumped immediately.
- **One queue only.** All 256 descriptors are assigned to the default
  queue (ring 16); the 16 priority queues are ignored.
- **No checksum offload, no scatter/gather, no VLAN, no multicast
  filter.** Promiscuous-or-broadcast is enough for TFTP.
- **RGMII only.** Other PHY modes are unimplemented.
- **Static descriptor / buffer pool.** RX uses a pre-allocated 256 ×
  2048 byte buffer (`ARCH_DMA_MINALIGN`-aligned); TX uses caller's
  packet buffer with explicit cache flush + invalidate.
- **Burst length 8** instead of the GENETv5 default — a documented
  BCM2711-specific tweak.

U-Boot's driver is the closest in spirit to what a first-pass Phoenix
driver should look like.

## 5. Circle (`rsta2/circle`) `lib/bcm54213.cpp`

Circle is a single-author MIT-ish bare-metal C++ Pi runtime, and its
`lib/bcm54213.cpp` is **~1933 lines**, dual-derived from Linux GENET
(GPLv2) and `phy_device.c` (GPLv2, Andy Fleming), wrapped in GPLv3+
glue by R. Stange. The class is `CBcm54213Device`. Circle is the
single most useful *bare-metal* reference because it has no kernel
abstraction layer below it.

Init sequence (per the file):

1. Validate `SYS_REV_CTRL` is GENET v5 (accept v6 as v5).
2. `reset_umac()` — soft reset + loopback.
3. `dma_disable()` to flush queues, then `init_dma()` to lay out rings,
   then `enable_dma()` for ring 16.
4. Configure HFB (hardware filter blocks).
5. Connect two IRQ vectors (`INTRL2_CPU_STAT` at offsets 0x200 and
   0x240). Note the in-source comment: **"Rx interrupts are not
   used"** — Circle uses the IRQ for TX completion only and *polls*
   RX from `ReceiveFrame()`.
6. `mii_probe()` — strobes `EXT_GPHY_RESET` via `ext_writel`, waits,
   then reads link/speed/duplex through the MII registers.
7. `netif_start()` — enable MAC, set RX mode.

DMA strategy: **256 fixed descriptors** (`#define TOTAL_DESC 256`),
**4 TX queues × 32 BD/queue** plus the default ring; per-frame buffers
are heap-allocated `new u8[ENET_MAX_MTU_SIZE]`. Buffers are made
coherent by `CleanAndInvalidateDataCacheRange()` — i.e. **non-coherent
DMA buffers, manually maintained**. No coherent-memory pool, no IOMMU,
no CMA. This is exactly the regime Phoenix is in.

Ring memory itself is *register-mapped*: the descriptor arrays live
inside the GENET register window at `ARM_BCM54213_BASE +
GENET_TDMA_REG_OFF`, so they don't need to be cache-managed at all
(they're device memory). Only the packet payload buffers need cache
maintenance.

## 6. Other bare-metal sources

- **Ultibo** — Pascal RTOS, `Unit GENET` (`ultibo.org/wiki/Unit_GENET`).
  Independent Pascal reimplementation. Reference only; awkward to port.
- **rpi4-osdev part 14** (`rpi4os.com/part14-spi-ethernet/`)
  deliberately bypasses GENET — bolts on an external ENC28J60 over
  SPI. Negative data point: a tutorial author chose to avoid GENET.
- **iosoft.blog** — covers BCM4345 Wi-Fi (`zerowi`), not GENET.
- **EDK2 `BcmGenetDxe`** — UEFI driver under
  `tianocore/edk2-platforms/Silicon/Broadcom/BcmGenetDxe` (commit
  `8f330ca`). Used by pftf/RPi4 firmware. Driver-model
  Supported/Start/Stop, separate `BcmGenetPlatformDeviceProtocol`
  injecting MAC + register base. Polled — another minimal subset.
- **FreeRTOS Pi 4 ports** — none ship a GENET driver in-tree.

## 7. Firmware-programmed MAC address

On BCM2711, the VideoCore boot firmware (`start4.elf` /
`start_cd.elf`) reads the MAC from the OTP/EEPROM and writes it into
`UMAC_MAC0` (offset `0x80c`) and `UMAC_MAC1` (offset `0x810`) of the
GENET register block before kernel handoff. All non-Linux drivers we
surveyed read it back the same way:

- **U-Boot**: reads MAC0/MAC1 in `bcmgenet_eth_probe()` and copies
  into the eth-device structure.
- **Circle**: reads from `UMAC_MAC0` / `UMAC_MAC1` and stores in
  `m_MACAddress` (`set_hw_addr` writes them back after reset).
- **EDK2 BcmGenetDxe**: receives the MAC via
  `BcmGenetPlatformDeviceProtocol` from the platform DXE, which
  itself read it from the firmware. (See edk2-platforms commit
  `193bc27`.)
- **FreeBSD/NetBSD**: `bcmgenet_get_hwaddr()` reads MAC0/MAC1 if the
  device-tree `local-mac-address` is missing or zero.

This matters: GENET on Pi 4 has **no EEPROM of its own**. If the
firmware did not pre-program these registers (e.g. on certain netboot
paths), the driver must source the MAC from somewhere else (DTB, OTP
mailbox call). Linux patch series confirms this:
`patchwork.ozlabs.org/.../20200201074625.8698-6-jeremy.linton@arm.com`.

## 8. MDIO / BCM54213PE PHY init

All non-Linux drivers do the same thing:

1. Strobe `EXT_RGMII_OOB_CTRL.EXT_GPHY_RESET` low/high to hard-reset
   the PHY (Circle `mii_probe()`, U-Boot `bcmgenet_phy_init()`).
2. Configure `EXT_RGMII_OOB_CTRL` for RGMII.
3. Use `UMAC_MDIO_CMD` (offset `0x614`): write
   `MDIO_START_BUSY | RD/WR | (phy<<21) | (reg<<16) | data`,
   poll `MDIO_START_BUSY`, 20 ms timeout.
4. Read PHY ID/status, configure speed/duplex.

Pi-4-specific quirks: the GPHY reset GPIO above and BCM54213PE LED/EEE
config (Circle reuses Linux `phy_device.c` verbatim; U-Boot uses
generic PHY).

## 9. DMA without CMA

None of the non-Linux drivers use a CMA-style allocator:

- **U-Boot**: one static `__aligned(ARCH_DMA_MINALIGN)` RX pool
  (256 × 2048 = 512 KB); TX uses caller's buffer with explicit flush.
- **Circle**: descriptors are *register-mapped* GENET memory (no
  cache mgmt); packet buffers heap-allocated, manually maintained
  via `CleanAndInvalidateDataCacheRange()`.
- **FreeBSD/NetBSD**: `bus_dma(9)` — one DMA tag per ring with
  coherent mapping for descriptors, per-mbuf bus-dmamaps for payload.
- **EDK2**: `PciIo->Map()` over platform-injected region; UEFI
  handles coherency.

Circle's pattern (descriptors in device memory + manually
cache-managed payload buffers) is closest to a minimal RTOS approach.

## 10. Smallest proven non-Linux implementation

Ranking by demonstrable working scope and LOC:

| Project | LOC | TX | RX | IRQ | PHY | Verdict |
| --- | --- | --- | --- | --- | --- | --- |
| U-Boot `bcmgenet.c` | ~600 | poll | poll | none | full RGMII | **TFTP-grade, smallest proven** |
| EDK2 BcmGenetDxe | ~1k | poll | poll | none | full | UEFI SNP layer |
| Circle `bcm54213.cpp` | ~1.9k | IRQ | poll | TX-only | full + EEE | full lwIP-grade RTOS driver |
| FreeBSD `if_genet.c` | ~1.5k | IRQ | IRQ | full | miibus | full BSD net driver |
| NetBSD `bcmgenet.c` | ~1.5k | IRQ | IRQ | full | mii | ancestor of FreeBSD |
| OpenBSD `if_bse.c` | ~1.3k | IRQ | IRQ | full | mii | similar |

The **smallest demonstrated working** GENET driver on Pi 4 is U-Boot's
~600 LOC polling-only subset. The smallest *full* (TX + RX with IRQs,
production-grade) bare-metal driver is **Circle's ~1.9 kLOC**.

## 11. Recommendation for Phoenix

**Port from Circle**, with the U-Boot subset as a staging milestone.

Reasoning:

- **Circle is the only non-Linux source** implementing full GENET TX+RX
  with IRQs *outside any kernel network stack*. FreeBSD/NetBSD drivers
  are entangled with `bus_dma(9)`, `miibus`, mbufs, and ifnet — porting
  them means porting their abstractions.
- **Circle's coherency model matches Phoenix's reality** — manual cache
  maintenance for payload buffers, descriptors in device memory, no
  CMA. Same regime BCM2711 forces on us per
  `docs/TEMPORARY-FIXES-AND-FUTURE-CLEANUP.md`.
- **License**: Circle is GPLv3+ derived from Linux GPLv2 — *do not copy
  Circle code*. Use it as a behavioral reference, write fresh code,
  cite Circle in comments. For a BSD-licensed reference of any specific
  sequence, FreeBSD's `if_genet.c` is the BSD-2 fallback.
- **Staging plan**:
  1. **Milestone 1**: U-Boot-style polling driver. ~600 LOC. Single
     RX buffer pool, single TX descriptor, no IRQs. Boundary: link
     up + ARP + one ICMP echo over a polled netif. Validates MAC
     read-back, MDIO, RGMII config, descriptor format, cache mgmt.
  2. **Milestone 2**: add IRQ-driven TX completion, keep RX polling
     (Circle's exact split). Add the netif ring-buffer interface
     Phoenix's `lwip` port expects.
  3. **Milestone 3**: full RX IRQ + multi-buffer pool, link-state
     handler. Match Circle scope.

The Phoenix driver should target **~1500 LOC** in `phoenix-rtos-devices`
(BSD-style header + register file + driver), not pull in any of the
BCM7xxx/SystemPort/UniMAC abstractions Linux carries for non-Pi
SoCs. Drop EEE, drop HFB, drop RXCHK/TXCHK, drop multi-queue. We need
GENETv5 + RGMII + BCM54213PE only.

## Sources

- FreeBSD review **D24436** — `reviews.freebsd.org/D24436`
- FreeBSD commit **rS360181** — `reviews.freebsd.org/rS360181`
- FreeBSD `genet(4)` — `man.freebsd.org/cgi/man.cgi?query=genet`
- NetBSD `genet(4)` — `man.netbsd.org/genet.4`
- OpenBSD `bse(4)` — `man.openbsd.org/arm64/bse.4`
- U-Boot `drivers/net/bcmgenet.c` — github.com/u-boot/u-boot
- Circle `lib/bcm54213.cpp` — github.com/rsta2/circle
- Circle memory map — `github.com/rsta2/circle/blob/master/doc/memorymap.txt`
- EDK2 BcmGenetDxe commit `8f330ca` — github.com/tianocore/edk2-platforms
- EDK2 platform-protocol commit `193bc27` — github.com/tianocore/edk2-platforms
- Ultibo `Unit GENET` — `ultibo.org/wiki/Unit_GENET`
- rpi4-osdev part 14 — `rpi4os.com/part14-spi-ethernet/` (negative data)
- Linux MAC fetch patch — `patchwork.ozlabs.org/project/netdev/patch/20200201074625.8698-6-jeremy.linton@arm.com/`
- Pi forum, GENET hardware pitfalls — `forums.raspberrypi.com/viewtopic.php?t=349563`
