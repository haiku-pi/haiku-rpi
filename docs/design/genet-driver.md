# GENET v5 Ethernet driver (Raspberry Pi 4)

Native Haiku device-manager driver for the BCM2711's on-board Gigabit
Ethernet: Broadcom GENET v5 (`brcm,bcm2711-genet-v5`) with an external
BCM54213PE PHY over RGMII, managed through the GENET's UniMAC MDIO block.

Source: `src/add-ons/kernel/drivers/network/ether/genet/` (arm64 only).

Status: written, syntax-checked with the arm64 cross compiler
(`-Wall -Werror -O2`), not yet built by jam or run on hardware.

## Why a native driver

Haiku's FreeBSD compatibility layer (used by most Ethernet drivers) knows
only PCI/USB and has no FDT/ofw attachment, so FreeBSD's `if_genet.c` cannot
be dropped in. The driver therefore follows the device-manager pattern of
`virtio_net` and the FDT attachment of `busses/mmc/sdhci_fdt.cpp`.

## Attachment

- `supports_device()`: parent has `B_DEVICE_BUS` = `fdt` and
  `fdt/compatible` = `brcm,bcm2711-genet-v5`.
- The driver node's parent *is* the FDT node: one `get_parent_node()` +
  `get_driver()` gives `fdt_device_module_info` and the `fdt_device`.
- `get_reg(0)` → CPU address (0xfd580000; `/scb` "ranges" applied by the
  FDT bus), 64 KiB. `get_interrupt(0/1)` → GIC SPI 157/158 + 32 = 189/190.
- Publishes `net/genet/<n>`; the "ethernet" net device module opens it.
- Lifecycle: `init_driver` maps registers, checks `SYS_REV_CTRL` (major 6
  or 7 = GENET v5), reads `phy-mode` and the MAC address, **masks all
  interrupts and stops both DMA engines** (firmware may leave RX DMA on),
  installs both interrupt handlers. `init_device` allocates the buffers.
  First `open` starts the hardware, last `close` stops it.

## Data path

- Only the **descriptor ring 16** in both directions, all 256 hardware
  descriptors. The hardware filter block is disabled and `INDEX2RING`
  cleared, so every frame lands in ring 16 (Linux's current driver moved to
  ring 0 + HFB rule; FreeBSD and the Phoenix-RTOS driver use ring 16).
- **One fixed 2 KiB buffer per descriptor** (512 KiB RX + 512 KiB TX) in one
  `B_CONTIGUOUS` area. RX frames are copied out in `read()`, TX frames are
  copied in by `write()`. Distinct buffers per descriptor are essential:
  Phoenix once aliased 256 descriptors onto 16 buffers and the hardware
  overwrote undrained frames (TCP cwnd collapse).
- No 64-byte status blocks: `RBUF_64B_EN` and `TBUF_64B_EN` cleared,
  `RBUF_ALIGN_2B` set (2 pad bytes in front of each RX frame, counted in the
  descriptor length), `RBUF_CHK_CTRL` = 0. Phoenix traced lost gigabit RX
  frames to the RX status block; we need no checksum offload anyway.
- FCS is stripped by the MAC (`CMD_CRC_FWD` clear) and appended on TX
  (`DMA_TX_APPEND_CRC`). Runt TX frames are zero-padded to 60 bytes.
- TX descriptors also carry the QTAG mask (0x3f << 7), as Linux does.

### DMA addressing

The `/scb` "dma-ranges" in `bcm2711-rpi-4-b.dts` is
`<0x4 0x7c000000  0x0 0xfc000000  0x0 0x03800000>` (peripheral window) and
`<0x0 0x0  0x0 0x0  0x4 0x0>` (identity, 16 GiB). GENET thus reaches all RAM
with bus address = physical address and has 40-bit descriptors (Linux sets a
40-bit mask). The area is allocated below 4 GiB (keeps `ADDRESS_HI` = 0); the
0xc0000000 limit of PCIe/emmc2 does not apply.
**Note:** `fdt_device_module_info::get_dma_window()` only returns the first
"dma-ranges" entry — for `/scb` the peripheral window — so it must not be used
for GENET (or any other `/scb` device) until it learns to pick the RAM range.

### Cache coherency

GENET does not snoop the CPU caches. **Update 2026-10-19:** the receive buffers are
cacheable now and each frame's lines are invalidated before the copy (TCP download
250 → 735 Mbit/s); what follows describes the transmit buffers and the original design.
The buffers are mapped
**non-cacheable** (`arm64_dcache_flush_range()` then
`vm_set_area_memory_type(B_WRITE_COMBINING_MEMORY)` = Normal-NC, the pattern
of `usb/PhysicalMemoryAllocator.cpp`). This needs no per-frame cache
maintenance and cannot suffer the classic streaming-DMA bugs. Cost: the
copies run uncached. Phoenix measured cacheable RX + per-frame `dc civac` at
~2.4x NFS throughput later; that is the obvious optimisation once the driver
is proven.

Ordering: buffers are Normal-NC, registers/descriptors are Device memory,
which are not ordered against each other:
- TX: `dsb sy` after filling the buffer, before the descriptor and
  `TDMA_PROD_INDEX` writes.
- RX: `dmb ld` after reading `RDMA_PROD_INDEX`, before reading the
  descriptor and buffer; `dsb sy` after the copy, before `RDMA_CONS_INDEX`
  returns the buffer.

## Interrupts and blocking

Ring 16 reports completions on **INTRL2_0** (line 0, IRQ 189):
`RXDMA_MBDONE` (bit 13) and `TXDMA_MBDONE` (bit 16). INTRL2_1 (line 1) is for
priority rings 0–15; it stays fully masked and its handler only acks strays.

NAPI-like scheme: a reader that finds the ring empty registers a
`ConditionVariableEntry`, clears + unmasks `RXDMA_MBDONE`, re-checks the
producer index (closing the lost-wakeup window) and sleeps. The handler masks
and clears whatever fired and `NotifyAll()`s. So a burst costs one
interrupt. Writers do the same with `TXDMA_MBDONE`, but only when the TX ring
is full (255 in flight); normally `write()` returns as soon as the frame is
queued and completions are reclaimed lazily through `TDMA_CONS_INDEX`.

Backstops against a missing interrupt (Phoenix saw frames sitting in the
ring without an interrupt at gigabit): `DMA_RING16_TIMEOUT` = 7 ticks
(~57 µs, Linux default) and a 10 ms timeout on the reader's wait. Writers
also wait in 10 ms slices and fail only if `TDMA_CONS_INDEX` has not moved
for 1 s: the RX bit is HW-proven by Phoenix, the TX bit (16) only comes from
Linux/FreeBSD, so a wrong TX bit degrades to polling, not to failure.

`close()` of the last handle clears `fRunning` under the RX/TX locks and
notifies both condition variables with `B_FILE_ERROR`, which is how the
ethernet module's reader blocked in `read()` gets out on `ifconfig down`.

## Link management

On demand: the ethernet module calls `ETHER_GET_LINK_STATE` at interface up
and every second (`ethernet.cpp` `kLinkCheckInterval`), so no timer thread.
The ioctl reads BMSR twice (latched link-loss) and, for the BCM54213PE, the
AUXSTAT HCD field (speed/duplex; Phoenix-proven), otherwise the 802.3
ADVERTISE∧LPA / CTRL1000∧STAT1000 resolution. Only on a **change** is the MAC
reprogrammed: `RGMII_LINK`, `UMAC_CMD` speed/duplex, pause ignored both ways
(none advertised); the first link-up takes the UniMAC out of `CMD_SW_RESET`
and sets `TX_EN | RX_EN` (Linux `bcmgenet_mac_config()`). Rewriting UMAC_CMD
needlessly drops an in-flight frame (Phoenix), so writes are change-only.
The link-state semaphore is released on changes.

## PHY bring-up

- Address 1 from the DT (`ethernet-phy@1`), verified by reading the PHY ID;
  scan 0–31 if nothing answers. (Following `phy-handle` would need the PHY's
  FDT device node initialized, which nothing guarantees.)
- MDIO via `UMAC_MDIO_CMD` (0xe14): write command, write again with
  `START_BUSY`, poll ≤ 20 ms, `READ_FAIL` → error (`mdio-bcm-unimac.c`).
- No PHY reset (Linux has no soft reset for this PHY either).
- BCM54213PE (ID 0x600d84a2; mask also matches CM4's BCM54210PE):
  AutogrEEEn off, EEE LPI off (MMD7 0x803d), EEE advertisement 0 (MMD7 0x3c),
  auto power down off (shadow 0x0a). Phoenix proved these low-power modes
  drop the first frame after idle at gigabit. Linux *enables* APD because of
  the DT's `brcm,powerdown-enable`; we deliberately do not.
- Advertise 10/100 HD+FD and 1000 FD, no pause; restart autonegotiation.

### RGMII delays (`phy-mode` = "rgmii-rxid" on the Pi 4)

MAC side: `SYS_PORT_CTRL` = EXT_GPHY, `RGMII_MODE_EN`, `OOB_DISABLE` cleared
(link from in-band status), `ID_MODE_DIS` cleared → MAC delays TX clock.
PHY side: RXC-RXD skew on (AUXCTL MISC shadow), GTXCLK delay off (shadow
0x03). This reproduces Linux including its "two mistakes cancel" quirk in
`bcmgenet_mii_probe()`: "rgmii" → MAC no delay, PHY both; "rgmii-txid" and
"rgmii-rxid" → MAC TX delay, PHY RX delay.

## Init sequence (open)

1. Mask interrupts; disable TDMA/RDMA (all 17 rings, poll `DMA_STATUS`).
2. `SYS_RBUF_FLUSH_CTRL` bit 1 pulse; then 0; `UMAC_CMD` = `SW_RESET`.
3. MIB reset; `UMAC_MAX_FRAME_LEN` = 1536 (reset value drops everything);
   TBUF/RBUF/CHK as above; `RBUF_TBUF_SIZE_CTRL` = 1; MAC-side EEE off
   (`RBUF_ENERGY_CTRL`, `UMAC_EEE_CTRL`); HFB off.
4. MAC address → `UMAC_MAC0/1`.
5. `UMAC_TX_FLUSH` pulse, `SYS_RBUF_FLUSH_CTRL` bit 0 pulse.
6. RX ring 16: descriptor addresses, burst 8 (BCM2711 value), PROD/CONS 0,
   `BUF_SIZE` = 256<<16 | 2048, XON/XOFF 5/16, START 0, END 767,
   MBUF_DONE 1, ring timeout 7; `RING_CFG` bit 16, `DMA_CTRL` bit 17.
7. TX ring 16 likewise (MBUF_DONE 1, FLOW_PERIOD 0); then `DMA_EN` on both.
8. MAC destination filters (broadcast, own, ≤15 multicast; else promiscuous).
9. RGMII + PHY configuration, autonegotiation restart.

## MAC address

Order: DT `local-mac-address` / `mac-address` (firmware fills these at boot)
→ `UMAC_MAC0/1` as left by a network boot loader (read before the UniMAC
reset) → VideoCore mailbox tag `0x00010003` (GET_BOARD_MAC_ADDRESS, via
`generic/bcm2835_mailbox`; the tag is defined locally because
`bcm2835_mailbox.h` lacks it) → random locally administered address.

## ioctls

`ETHER_INIT`, `ETHER_GETADDR`, `ETHER_GETFRAMESIZE` (1514), `ETHER_NONBLOCK`,
`ETHER_SETPROMISC`, `ETHER_ADDMULTI`/`ETHER_REMMULTI` (MDF filters, 17
entries; overflow → promiscuous), `ETHER_SET_LINK_STATE_SEM`,
`ETHER_GET_LINK_STATE`. `ETHER_SEND/RECEIVE_NET_BUFFER` are not implemented,
so the ethernet module uses `read()`/`write()` of whole frames.

## Sources

- Linux `drivers/net/ethernet/broadcom/genet/bcmgenet.c`, `bcmgenet.h`,
  `bcmmii.c`, `../unimac.h`; `drivers/net/mdio/mdio-bcm-unimac.c`;
  `drivers/net/phy/broadcom.c`, `bcm-phy-lib.c`, `include/linux/brcmphy.h`.
- Phoenix-RTOS `phoenix-rtos-lwip/drivers/bcm-genet.c`, `bcm-genet-regs.h`,
  `ephy.c` (HW-proven on this board, incl. gigabit lessons); see also
  `docs/knowledge/from-phoenix/ethernet-genet-non-linux.md`.

## Open risks

- Never run: register sequences are cross-checked against Linux and Phoenix
  but unverified on Haiku.
- Non-cacheable buffers: the kernel's physical map still aliases them as
  cacheable (same situation as the USB stack on this port).
- The 10 ms RX poll costs ~100 wakeups/s while the interface is idle and up.
- The 1 MiB contiguous area is allocated at first open, not at boot; late
  in uptime fragmentation could make that fail.
- If the device manager unloads and reloads the driver, a random fallback
  MAC address (only used when DT, registers and mailbox all fail) changes.
- `ETHER_NONBLOCK` with a nonzero value means non-blocking here, the
  opposite of `virtio_net.cpp` (which looks inverted).
- Missing: checksum offload, scatter/gather, jumbo frames, stats, WoL, select().
