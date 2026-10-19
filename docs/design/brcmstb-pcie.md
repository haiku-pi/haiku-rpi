# BCM2711 PCIe host controller driver for Haiku (`brcm,bcm2711-pcie`)

Status: design only (2026-10-18). Nothing here has been built or run on hardware.
Goal: Haiku's existing xHCI driver drives the on-board VIA VL805 (USB keyboard and mouse).

Citation keys (file:line):
- **[L]** `<phoenix-rpi>/external/linux/drivers/pci/controller/pcie-brcmstb.c`
- **[U]** `sources/u-boot/drivers/pci/pcie_brcmstb.c`
- **[DTS]** `artifacts/pi-firmware/bcm2711-rpi-4-b.dts`
- **[PX]** `<phoenix-rpi>/sources/phoenix-rtos-devices/usb/xhci/bcm2711-pcie.c`
- **[PG]** `docs/knowledge/from-phoenix/rpi4-os-development-guide.md`
- **[FB]** FreeBSD `sys/arm/broadcom/bcm2835/bcm2838_pci.c` (fetched from GitHub; no line numbers available)
- Haiku paths are relative to `sources/haiku/`.

## 0. Key findings

1. **There is no "minimal" path. Haiku inherits a dead controller.** The U-Boot driver is flagged
   `DM_FLAG_OS_PREPARE` ([U]:881-891). `ExitBootServices` calls `dm_remove_devices_active()`
   (`u-boot/lib/efi_loader/efi_boottime.c:2244-2248`; `booti` does the same at `boot/bootm.c:1455`).
   `DM_REMOVE_ACTIVE_ALL` includes `DM_REMOVE_OS_PREPARE` (`u-boot/include/dm/device.h:106,112`).
   `brcm_pcie_remove()` then does three things ([U]:791-818). It asserts PERST#. It sets `SERDES_IDDQ`. It leaves the bridge in
   `SW_INIT` reset (it de-asserts the reset only on 2712, [U]:814-815). `xhci_pci` is removed first
   (`u-boot/drivers/usb/host/xhci-pci.c:92-117`, also `OS_PREPARE`).
   - **While U-Boot runs, it sets up:** the link, outbound window 0, RC_BAR2 from `dma-ranges` ([U]:494-556), bus numbers 0/1,
     VL805 BAR0, the VL805 firmware load (`reset_assert` → `bcm2711_notify_vl805_reset`,
     `xhci-pci.c:64-72`, `reset-raspberrypi.c:20-29`), and a started-then-halted xHCI.
   - **At hand-off, all of that is torn down.** PERST# wipes the VL805, including its firmware SRAM on boards without an EEPROM.
2. **The controller driver must do the root port's job.** Haiku's bus manager does not number buses on
   arm64: `fBusEnumeration` is true only on PPC/M68K (`bus_managers/pci/pci.cpp:590-600`). It follows the
   bridge's existing `PCI_secondary_bus` (`pci.cpp:1364-1390`). It never assigns bridge windows (`pci.cpp:1282-1330`
   skips bridges). It hands a bridge's window to the child bus only when `limit > base` (`pci.cpp:1182-1279`).
   It recurses only into class 06/04 type-1 headers (`pci.cpp:1380-1388`), and the RC defaults to
   endpoint class ([L]:1501-1506).

   So `InitDriver` must do four things before returning: set the RC class, program bus numbers 0/1/1, open the memory
   window, and load the VL805 firmware. `AddController` runs `InitBus` (including BAR assignment) right after
   `InitDriver` and only then calls `finalize` (`pci.cpp:693-746`). **This is where the design departs from DW/ECAM.**
3. **Two blockers sit outside this driver, in the USB stack.**
   - **3 GiB DMA limit.** The USB stack allocates `B_32_BIT_CONTIGUOUS` (below 4 GiB, `bus_managers/usb/Stack.cpp:316-317`,
     `PhysicalMemoryAllocator.cpp:78-80`). The PCIe inbound path reaches only the lower 3 GiB (§4).
   - **Cache coherency.** The `pcie` node has no `dma-coherent` property ([DTS]:2187-2203). Haiku's xHCI does no cache maintenance.

## 1. Register map

The block is at `reg = <0x0 0x7d500000 0x0 0x9310>` in the `scb` address space ([DTS]:2189). `scb` `ranges` maps `0x7c000000`→CPU `0xfc000000` ([DTS]:2183),
so the CPU address is **`0xfd500000`**, size `0x9310`. The FDT bus `get_reg` already does this translation.

| Offset | Name | Bits / use | Source |
|---|---|---|---|
| 0x0000-0x0fff | RC (root port) type-1 config header | bus 0 config = `base + offset`. Only 0:0.0 exists | [L]:915-916 |
| 0x00ac | `BRCM_PCIE_CAP_REGS` | PCIe capability of the RC: LNKSTA at +0x12, RTCTL at +0x1c | [L]:40, [L]:1853-1864 |
| 0x0188 | `RC_CFG_VENDOR_SPECIFIC_REG1` | bits 3:2 = BAR2 endian. Write 0 for little-endian | [L]:43-45, [L]:1540-1545 |
| 0x043c | `RC_CFG_PRIV1_ID_VAL3` | [23:0] class code. Write `0x060400` (P2P bridge) | [L]:47-48, [L]:1503-1506 |
| 0x04dc | `RC_CFG_PRIV1_LINK_CAPABILITY` | [11:10] ASPM support. U-Boot clears it. [8:4] max width | [L]:50-51, [U]:785-786, `mach/acpi/bcm2711.h:46` |
| 0x4008 | `MISC_MISC_CTRL` | 0x80 RCB_64B, 0x400 RCB_MPS, 0x1000 SCB_ACCESS_EN, 0x2000 CFG_READ_UR_MODE, [21:20] MAX_BURST (**0 = 128 B on 2711**), [31:27] SCB0_SIZE = log2(size)-15 | [L]:95-104, [L]:1409-1444, [L]:1452-1464 |
| 0x400c + 8w / 0x4010 + 8w | `CPU_2_PCIE_MEM_WIN{w}_LO/HI` | PCI-side base of outbound window w (0..3) | [L]:107-113, [L]:620-631 |
| 0x4070 + 4w | `MEM_WIN{w}_BASE_LIMIT` | [15:4] CPU base MB[11:0], [31:20] CPU limit MB[11:0] | [L]:150-154, [L]:633-643 |
| 0x4080 + 8w / 0x4084 + 8w | `MEM_WIN{w}_BASE_HI / LIMIT_HI` | [7:0] = MB >> 12 | [L]:156-164, [L]:648-661 |
| 0x402c / 0x4034 / 0x403c (+4 = HI) | `RC_BAR1/2/3_CONFIG_LO` (inbound) | [4:0] size code (log2 64 KiB..64 GiB → log2-15; 0 = off). LO[31:12] / HI = PCI offset | [L]:123-124, [L]:509-521, [L]:1308-1348 |
| 0x4044 / 0x4048 | `MSI_BAR_CONFIG_LO/HI` | MSI target address. **LO bit 0 = MSI enable** | [L]:129-130, [L]:825-832 |
| 0x404c | `MSI_DATA_CONFIG` | `0xffe06540` (32 vectors) / `0xfff86540` (legacy 8) | [L]:132-134 |
| 0x4060 | `MSI_EOI` | FreeBSD writes 1 after draining. Linux does not | [FB] `REG_MSI_EOI` |
| 0x4068 | `MISC_PCIE_STATUS` | 0x80 PORT (1 = RC mode), 0x20 DL_ACTIVE, 0x10 PHYLINKUP. **Link up = both** | [L]:140-144, [L]:899-906 |
| 0x406c | `MISC_REVISION` | ≥ 0x0303 → MSI block at 0x4500, else legacy | [L]:146-147, [L]:2546, [L]:860 |
| 0x4204 | `HARD_DEBUG` | 0x08000000 SERDES_IDDQ. CLKREQ mask = 0x2\|0x10000\|0x100000\|0x200000 | [L]:166-177, [L]:2211 |
| 0x4300 | `INTR2_CPU` (legacy MSI, shift 24, 8 vectors) | +0 STATUS, +8 CLR, +0x10 MASK_SET, +0x14 MASK_CLR | [L]:2212, [L]:868-871 |
| 0x4500 | `MSI_INTR2` (32 vectors) | same layout as above | [L]:183-189, [L]:873-876 |
| 0x8000 | `EXT_CFG_DATA` | 4 KiB window onto the selected downstream function | [L]:2210 |
| 0x9000 | `EXT_CFG_INDEX` | `bus<<20 \| dev<<15 \| fn<<12` | [L]:2209, [L]:924-926, [U]:269-273 |
| 0x9210 | `RGR1_SW_INIT_1` | bit 0 PERST# (1 = asserted), bit 1 bridge SW_INIT | [L]:191-195, [L]:2208, [L]:1018-1026 |

### Config-space rules

- **Bus 0 (the RC itself).** Access goes directly to `base + offset`. The device and function must both be 0 ([L]:915-916). FreeBSD notes that probing other slots on bus 0 "will lock up the memory controller" [FB].
- **Bus 1.** Only device 0 is valid ([U]:252-257). The link is single-device, and the VL805 would otherwise answer type-0 config cycles for every device number.
- **Bus 1 and above.** Check that the link is up first: "An access to our HW w/o link-up will cause a CPU Abort" ([L]:919-922). Then write INDEX and access `0x8000 + (offset & 0xfff)`.
- **Native-width accesses are fine.** Linux uses `pci_generic_config_read/write` (byte, word and dword) for bcm2711. Only BCM7425 needs the `_32` variants ([L]:2328-2339).

### Interrupts (GIC-400, 3-cell, SPI base 32 in Haiku: `bus_managers/fdt/fdt_module.cpp:41,725-731`)

- **Lines on the controller node.** The node lists two lines: `interrupts = <0 0x93 4>, <0 0x94 4>` with names `"pcie","msi"` ([DTS]:2194-2195).
  So the MSI line is **index 1** (SPI 148 → Haiku IRQ 180). DW reads index 0 (`DWPCIController.cpp:268-270`), so don't copy that.
- **INTx.** `interrupt-map-mask = <0 0 0 7>` matches on the pin only. INTA..INTD map to SPI 0x8f..0x92 = Haiku IRQ **175..178**, level-high
  ([DTS]:2196-2197). `fdt_device_get_interrupt_map` parses the 3-cell GIC parent correctly (`fdt_module.cpp:653-735`).
  DW's hand-rolled 6-cell parser (`DWPCIController.cpp:159-172`) would mis-parse these 8-cell entries.
- **MSI** (Linux `brcm_msi_set_regs` [L]:817-834, compose [L]:706-713, ack [L]:715-721):
  - Target address is `0xffffffffc`. This is the "GT_4GB" target, chosen because the inbound viewport covers PCI 0..4 GiB ([L]:209-210, [L]:1466-1470). FreeBSD hardcodes the same value [FB].
  - Data is `0x6540 | vector`.
  - Ack a vector by writing its bit to `+0x08`. Unmask with `+0x14`.
  - VL805 MSI works on Linux with this 64-bit target. That implies, but does not prove, that its MSI capability is 64-bit. Check `PCI_msi_control_64bit` at bring-up.

## 2. Init sequence

**Recommendation: always run the full sequence, unconditionally.** The "assume U-Boot trained the link" variant is not
available (§0.1). Reading MISC registers while SerDes is in IDDQ does not fault cleanly: on Phoenix it stalled about 10 s per read and fed SError ([PG]:567-579).
So touch **only RGR1/HARD_DEBUG** until the bridge is out of reset, which is Linux's own order. A future variant that skips the
reset if the link is already up costs one register read. It is not worth the risk, and it would still need the VL805 steps.

The sequence below mirrors `brcm_pcie_setup()` ([L]:1368-1552) plus `brcm_pcie_start_link()` ([L]:1772-1868), BCM2711 paths only:

1. `RGR1_SW_INIT_1 |= 0x2` (bridge reset), then `|= 0x1` (PERST#). `snooze(200)` ([L]:1379-1393).
2. `RGR1_SW_INIT_1 &= ~0x2`. `HARD_DEBUG &= ~SERDES_IDDQ`. `snooze(200)` ([L]:1395-1406).
3. Program `MISC_CTRL`. Set SCB_ACCESS_EN, CFG_READ_UR_MODE, RCB_MPS_MODE and RCB_64B_MODE. Set MAX_BURST = 0 and SCB0_SIZE = 17 (4 GiB) ([L]:1409-1464).
4. Program the inbound windows.
   - The DT window is `dma-ranges` = PCI 0 → CPU 0, size `0xc0000000` ([DTS]:2201). It is rounded up to a power of two, 4 GiB, at offset 0 ([L]:1240-1304).
   - `RC_BAR1_LO = 0`, `RC_BAR2_LO = 0 | 0x11`, `RC_BAR2_HI = 0`, `RC_BAR3_LO = 0` ([L]:1328-1348; [U]:690-696 also clears BAR1/BAR3).
   - Do **not** write `UBUS_BAR2_CONFIG_REMAP` (0x40b4). Linux writes the UBUS remap only for 7712 ([L]:1355-1365), and U-Boot says it is unused before 2712 ([U]:553). Phoenix sets it ([PX]:624-637), so keep it as an experiment if DMA fails.
5. Verify `MISC_PCIE_STATUS & 0x80` (RC mode) ([L]:1441-1444).
6. Set `PRIV1_ID_VAL3` class to `0x060400`. Clear the ASPM bits in `PRIV1_LINK_CAPABILITY`, as U-Boot does ([U]:785-786).
7. Program outbound window 0. The DT range is `ranges = <0x02000000 0x0 0xc0000000 0x6 0x0 0x0 0x40000000>` ([DTS]:2200): PCI `0xc0000000` ← CPU `0x6_0000_0000`, 1 GiB.
   - The CPU address is in `scb` space. `scb` maps it identity ([DTS]:2183), so it needs no translation. The DW parser (`DWPCIController.cpp:191-240`) doesn't translate either, which happens to be harmless here.
   - Register values per [L]:620-662: `WIN0_LO=0xc0000000`, `WIN0_HI=0`, `BASE_LIMIT=(0x3ff<<20)|(0x000<<4)`, `BASE_HI=6`, `LIMIT_HI=6`.
   - Phoenix used PCI base 0xF8000000 ([PG]:479-481). That was Phoenix's own choice; use the DT values.
8. `VENDOR_SPECIFIC_REG1 &= ~0xc` (inbound little-endian) ([L]:1540-1545).
9. `HARD_DEBUG &= ~PCIE_CLKREQ_MASK` (CLKREQ# off, "safe" mode) ([L]:1787-1790).
10. Make sure PERST# has been held for **at least 100 ms** in total (`snooze` the remainder): [PG]:488-489, and Phoenix saw intermittent DMA failures with a 200 µs hold ([PX]:438-445). Then `RGR1_SW_INIT_1 &= ~0x1` (release PERST#). `snooze(100000)` ([L]:1821). Poll link-up in 5 ms steps for up to 100 ms ([L]:1828-1834).
    Skip SSC in v1 even though `brcm,enable-ssc` is present ([DTS]:2202, [L]:1838-1844). Leave `RTCTL.CRSSVE` **clear** ([L]:1858-1864): Haiku has no CRS handling, so the RC should retry internally.
11. Set up the root-port header through bus-0 config (Phoenix equivalent: [PX]:651-703):
    - Bus numbers: primary/secondary/subordinate = 0/1/1.
    - Memory window: `memory_base = 0xc000`, `memory_limit = 0xfff0`.
    - I/O window closed: base `0xf0`, limit `0x00`. Prefetchable window closed: base `0xfff0`, limit `0`, upper halves 0.
    - Command register: `PCI_command |= memory | master`.
12. VL805 firmware (§3). Then **re-write the RC_BAR1/2/3 registers** from step 4, because the mailbox handler can disturb the inbound state ([PG]:539-547, [PG]:1104-1112).
13. MSI controller (§5): read `MISC_REVISION`, choose the 0x4500 or 0x4300 block, program the MSI target and data, install the handler, call `msi_set_interface`.

After `InitDriver` returns, the bus manager takes over:
- It discovers 0:0.0 → bus 1 → 1:0.0.
- It reserves the bridge window 0xc0000000..0xffffffff from the `get_range` window. The `uint32` wrap is correct (`pci.cpp:1182-1279`).
- It assigns VL805 BAR0 (64-bit, 4 KiB) and translates it to `0x6_0000_0000` via `pci_ram_address` (`pci.cpp:129-141`).
  Checked: `AllocateResource` accepts a 64-bit BAR from a range below 4 GiB, and a non-prefetchable BAR matches the non-prefetchable window (`pci.cpp:2633-2657`). xHCI maps exactly the BAR size (`busses/usb/xhci.cpp:389-403`), which avoids the 0xDEADDEAD case A in [PG]:519-524.
- `finalize` then sets the INTx `interrupt_line`s.

## 3. VL805 handling

- **Why the notify is needed.** After a PCI reset, the VL805 loads its firmware either from its own SPI EEPROM or, if it has none, from the VideoCore.
  The OS triggers the VideoCore path with property tag **`0x00030058` `NOTIFY_XHCI_RESET`**. The value is `bus<<20 | slot<<15 | fn<<12` = **`0x100000`**.
  Sources: `linux/drivers/reset/reset-raspberrypi.c:33-58`, `linux/include/soc/bcm2835/raspberrypi-firmware.h:97`, `u-boot/arch/arm/mach-bcm283x/msg.c:207-248`.
  Linux waits 200-1000 µs afterwards (`reset-raspberrypi.c:57-58`). U-Boot waits 200 µs (`msg.c:246`).
- **When it is needed.** It is needed after every PERST# on boards whose VL805 has no EEPROM. Which board revisions those are is not recorded in any source at hand: from memory, later Pi 4B revisions, Pi 400 and CM4. **Decide at runtime instead of by revision.**
  - Read config `0x50` of 1:0.0, which is the VL805 firmware version (`linux/drivers/usb/host/xhci-pci.c:253-261`).
  - If it is 0, call the mailbox. If it is non-zero, skip the call (Phoenix does this, [PX]:915-923). Skipping matters because repeated notifies break things (firmware#1617, [PG]:503-507).
  - Haiku's PERST# already wiped what U-Boot loaded, so one call per Haiku boot is required. Linux also notifies again after U-Boot (`xhci-pci.c:633-638`).
- **Haiku call.**
  - `get_module(BCM2835_MAILBOX_MODULE_NAME)`, then `property_tag(0x00030058, &addr, 4, 4, NULL)` (`headers/private/drivers/bcm2835_mailbox.h:16-30`, usage pattern `busses/mmc/sdhci_fdt.cpp:72-79`). The call may sleep, which is fine in `InitDriver`.
  - The tag is not in the header yet. Add `BCM2835_TAG_NOTIFY_XHCI_RESET 0x00030058`.
  - Afterwards, poll the vendor ID of 1:0.0 until it reads `0x1106`, in 5 ms steps up to 300 ms. Phoenix observed 30-80 ms ([PX]:965-977).
  - The mailbox module is packaged for arm64 (`build/jam/packages/Haiku:85,325`).
- **xHCI quirks, graded against Haiku's `xhci.cpp`:**

| Quirk | Source | Haiku status |
|---|---|---|
| 64-bit register high half is garbage, so split into 32-bit accesses | [PG]:526-531 | Handled: LO/HI writes (`xhci.cpp:731-732,768-769,787-788`) |
| BAR is exactly 4 KiB, so map exactly that | [PG]:519-524 | Handled (`xhci.cpp:395-403`) |
| CRCR is not cleared by HCRST | memory `project_pi4_xhci_crcr_stale_after_hcrst.md` | Moot: Haiku's PERST# is a fundamental reset, and Haiku is the only user afterwards |
| `XHCI_TRB_OVERFETCH`: prefetches past the end of a segment | `linux/drivers/usb/host/xhci-pci.c:462`, `xhci-mem.c:2470-2476` | Benign without an IOMMU. Still, keep a mapped page after each ring |
| `XHCI_EP_CTX_BROKEN_DCS`, `XHCI_AVOID_DQ_ON_LINK` | `xhci-pci.c:463-464`, `xhci-ring.c:739,786-790` | Matters on Set TR Dequeue after a stall. Deferred |
| `XHCI_VLI_HUB_TT_QUIRK` when firmware < `0x0138C0` | `xhci-pci.c:30,466-467`, `xhci-ring.c:3683-3700` | Full-speed devices behind the internal hub TT can babble. Keyboards are FS. Medium priority |
| `XHCI_VLI_SS_BULK_OUT_BUG`, `XHCI_RESET_ON_RESUME` | `xhci-pci.c:448-465`, `xhci-mem.c:1500-1503` | Mass storage behind a hub only; resume. Out of scope |
| No BIOS hand-off on RPi | `linux/drivers/usb/host/pci-quirks.c:1276-1284` | Haiku's hand-off loop is harmless (no LEGSUP cap expected) |

xHCI matches by class 0c/03/30 (`xhci.cpp:205`), so no ID table change is needed.

## 4. DMA constraints

- **Bus address = physical address.** The `pcie` `dma-ranges` is PCI 0 → `scb` 0 ([DTS]:2201), and `scb` `dma-ranges` maps `0`→`0` for 16 GiB ([DTS]:2184).
- **Limit: physical < `0xc0000000` (3 GiB).**
  - The 4 GiB viewport overlaps the outbound window at PCI 3-4 GiB, which goes downstream ([L]:1270-1290).
  - Early BCM2711 steppings cannot access memory above 3 GiB at all ([L]:1262-1266; [PG]:360-363).
  - FreeBSD caps DMA even lower, at 960 MiB (`DMA_HIGH_LIMIT 0x3c000000`), and comments that data was corrupted above it [FB]. This is a warning sign. Use 3 GiB and test with buffers above 1 GiB.
- **Do not use `fdt->get_dma_window()` on the pcie node.** It starts at the *parent* (`fdt_module.cpp:794-822`) and returns `scb`'s first range (`0x4_7c000000`→`0xfc000000`, 56 MiB). That window is wrong for PCI children. The driver must parse its own `dma-ranges`: 3 child cells, 2 parent cells, 2 size cells.
- **How Haiku should express the limit:**
  - The driver computes `fDmaHighAddress = cpuBase + size` = `0xc0000000`. It publishes it as `B_DMA_HIGH_ADDRESS` (`headers/os/drivers/device_manager.h:162`) on its own node in `RegisterDevice`.
  - `pci_root_traverse` copies the attribute to every child PCI device node (`bus_managers/pci/pci_root.cpp:43-74`). The sdhci FDT glue shows the same pattern (`busses/mmc/sdhci_fdt.cpp:173-190`).
  - The USB `Stack`/PMA must honour it: `create_area_etc` with `physical_address_restrictions.high_address`, as in `generic/bcm2835_mailbox/bcm2835_mailbox.cpp:201-207`.
  - Until that lands, a 2 GiB board works by accident. 4 and 8 GiB boards have RAM in 3-4 GiB and will fail intermittently.
- **Coherency (blocker).** The node has no `dma-coherent`, and Phoenix found NoSnoop/stale-cache failures ([PX]:676-680, [PX]:927).
  - Map the USB DMA areas Normal-NC: `vm_set_area_memory_type(area, phys, B_WRITE_COMBINING_MEMORY)` (`headers/private/kernel/vm/vm.h:118`; NC mapping at `system/kernel/arch/arm64/VMSAv8TranslationMap.cpp:553-555`).
  - The alternative is `arm64_dcache_flush_range` around every ring and buffer handoff, as sdhci does (`busses/mmc/sdhci.cpp:545-556`).
  - MMIO via `map_physical_memory` is already Device-nGnRnE by default (`system/kernel/vm/vm.cpp:1989-1992`).

## 5. Code skeleton (`src/add-ons/kernel/busses/pci/brcmstb/`)

Files: `BrcmPCIController.h/.cpp`, `MsiInterruptCtrlBrcm.cpp`, `kernel_interface.cpp`. The `kernel_interface.cpp` is a copy of
`designware/kernel_interface.cpp:1-66` with renamed types, **plus `.finalize`**, which DW omits.
Jamfile: `KernelAddon <pci>brcmstb`. Add `<pci>brcmstb@arm64` next to `<pci>ecam` in `build/jam/packages/Haiku:47,345` and
`HaikuBootstrap:24,327`.

```cpp
#define BRCMSTB_PCI_DRIVER_MODULE_NAME "busses/pci/brcmstb/driver_v1"

enum {
	kBrcmVendorSpecificReg1	= 0x0188,	kBrcmPriv1IdVal3		= 0x043c,
	kBrcmPriv1LinkCap		= 0x04dc,	kBrcmMiscCtrl			= 0x4008,
	kBrcmMemWin0Lo			= 0x400c,	kBrcmMemWin0Hi			= 0x4010,
	kBrcmRcBar1ConfigLo		= 0x402c,	// BAR n: + 8 * (n - 1), HI = LO + 4
	kBrcmMsiBarConfigLo		= 0x4044,	kBrcmMsiBarConfigHi		= 0x4048,
	kBrcmMsiDataConfig		= 0x404c,	kBrcmPcieStatus			= 0x4068,
	kBrcmRevision			= 0x406c,	kBrcmMemWin0BaseLimit	= 0x4070,
	kBrcmMemWin0BaseHi		= 0x4080,	kBrcmMemWin0LimitHi		= 0x4084,
	kBrcmHardDebug			= 0x4204,	kBrcmIntr2CpuBase		= 0x4300,
	kBrcmMsiIntr2Base		= 0x4500,	kBrcmExtCfgData			= 0x8000,
	kBrcmExtCfgIndex		= 0x9000,	kBrcmRgr1SwInit1		= 0x9210,
};

enum {
	kBrcmStatusPort = 1 << 7, kBrcmStatusDlActive = 1 << 5, kBrcmStatusPhyLinkUp = 1 << 4,
	kBrcmSwInitPerst = 1 << 0, kBrcmSwInitBridge = 1 << 1,
	kBrcmHardDebugSerdesIddq = 1 << 27, kBrcmHardDebugClkreqMask = 0x00310002,
	kBrcmMiscCtrlRcb64B = 1 << 7, kBrcmMiscCtrlRcbMps = 1 << 10,
	kBrcmMiscCtrlScbAccess = 1 << 12, kBrcmMiscCtrlCfgReadUr = 1 << 13,
	kBrcmMiscCtrlBurstMask = 3 << 20, kBrcmMiscCtrlScb0SizeShift = 27,
	kBrcmVl805NotifyAddress = 0x100000,	// bus 1, slot 0, function 0
	kVl805FirmwareVersion = 0x50,
};


class MsiInterruptCtrlBrcm : public MSIInterface {
public:
			status_t			Init(addr_t regs, int32 msiIrq, uint32 revision);
			status_t			AllocateVectors(uint32 count, uint32& startVector,
									uint64& address, uint32& data) final;
			void				FreeVectors(uint32 count, uint32 startVector) final;
private:
	static	int32				_InterruptReceived(void* arg);
			addr_t				fIntr2Base = 0;		// regs + 0x4500, or + 0x4300 (legacy)
			uint32				fShift = 0;			// 0, or 24 (legacy)
			uint32				fVectorCount = 0;	// 32, or 8 (legacy)
			uint32				fAllocated = 0;		// DW leaves its bitmap uninitialised
			int32				fStartVector = 0;
			spinlock			fLock = B_SPINLOCK_INITIALIZER;
};


class BrcmPCIController {
public:
	static	float				SupportsDevice(device_node* parent);	// "brcm,bcm2711-pcie"
	static	status_t			RegisterDevice(device_node* parent);	// + B_DMA_HIGH_ADDRESS
	static	status_t			InitDriver(device_node* node, BrcmPCIController*& out);
			void				UninitDriver();

			status_t			ReadConfig(uint8 bus, uint8 device, uint8 function,
									uint16 offset, uint8 size, uint32& value);
			status_t			WriteConfig(uint8 bus, uint8 device, uint8 function,
									uint16 offset, uint8 size, uint32 value);
			status_t			GetMaxBusDevices(int32& count);	// 32; filtering is in _ConfigAddress
			status_t			ReadIrq(uint8, uint8, uint8, uint8, uint8&);	// B_UNSUPPORTED
			status_t			WriteIrq(uint8, uint8, uint8, uint8, uint8);	// B_UNSUPPORTED
			status_t			GetRange(uint32 index, pci_resource_range* range);
			status_t			Finalize();	// INTx: as ECAMPCIControllerFDT::Finalize

private:
			status_t			_InitDriverInt(device_node* node);
			status_t			_ReadResourceInfo();	// reg, ranges, own dma-ranges, irq 1
			status_t			_ResetAndStartLink();	// §2 steps 1-10
			void				_ProgramInboundWindows();	// §2 step 4, again in step 12
			void				_ProgramOutboundWindow(uint32 window, phys_addr_t cpu,
									phys_addr_t pci, uint64 size);
			void				_ConfigureRootPort();	// §2 step 11
			status_t			_LoadVl805Firmware();	// §3
			bool				_LinkUp() const
									{ uint32 s = _Read32(kBrcmPcieStatus);
									  return (s & kBrcmStatusDlActive) != 0
										&& (s & kBrcmStatusPhyLinkUp) != 0; }
			addr_t				_ConfigAddress(uint8 bus, uint8 device, uint8 function,
									uint16 offset);
			uint32				_Read32(uint32 offset) const
									{ return *(vuint32*)(fRegs + offset); }
			void				_Write32(uint32 offset, uint32 value)
									{ *(vuint32*)(fRegs + offset) = value; }

			spinlock			fLock = B_SPINLOCK_INITIALIZER;	// guards INDEX + DATA
			device_node*		fNode = NULL;
			AreaDeleter			fRegsArea;
			addr_t				fRegs = 0;
			Vector<pci_resource_range> fResourceRanges;	// one MMIO32 range from "ranges"
			phys_addr_t			fDmaCpuBase = 0;	// own dma-ranges: 0
			phys_addr_t			fDmaPciBase = 0;	// 0
			uint64				fDmaSize = 0;		// 0xc0000000 (rounded to 4 GiB for RC_BAR2)
			MsiInterruptCtrlBrcm fMsi;
};
```

Config access, written out:

```cpp
/*!	Returns the virtual address of the config register, or 0 when no function
	can live there. The caller holds fLock: the index register and the data
	window are one shared resource.
*/
addr_t
BrcmPCIController::_ConfigAddress(uint8 bus, uint8 device, uint8 function,
	uint16 offset)
{
	if (offset > 0xfff)
		return 0;

	if (bus == 0) {
		// The root port's header is the start of the register block. The RC
		// ignores the device number, so anything but 0:0.0 would alias it.
		if (device != 0 || function != 0)
			return 0;
		return fRegs + offset;
	}

	// Single-lane link: only device 0 behind the root port.
	if (bus == 1 && device != 0)
		return 0;

	// Config cycles without a link end in an external abort.
	if (!_LinkUp())
		return 0;

	_Write32(kBrcmExtCfgIndex, ((uint32)bus << 20) | ((uint32)device << 15)
		| ((uint32)function << 12));
	return fRegs + kBrcmExtCfgData + offset;
}


status_t
BrcmPCIController::ReadConfig(uint8 bus, uint8 device, uint8 function,
	uint16 offset, uint8 size, uint32& value)
{
	if (size != 1 && size != 2 && size != 4)
		return B_BAD_VALUE;

	InterruptsSpinLocker locker(fLock);

	addr_t address = _ConfigAddress(bus, device, function, offset);
	if (address == 0) {
		// Behave like a master abort. An error would make the bus manager log
		// one line per probed slot (pci.cpp:1806-1810).
		value = size == 4 ? 0xffffffff : (1u << (size * 8)) - 1;
		return B_OK;
	}

	switch (size) {
		case 1: value = *(vuint8*)address; break;
		case 2: value = *(vuint16*)address; break;
		case 4: value = *(vuint32*)address; break;
	}
	return B_OK;
}


status_t
BrcmPCIController::WriteConfig(uint8 bus, uint8 device, uint8 function,
	uint16 offset, uint8 size, uint32 value)
{
	if (size != 1 && size != 2 && size != 4)
		return B_BAD_VALUE;

	InterruptsSpinLocker locker(fLock);

	addr_t address = _ConfigAddress(bus, device, function, offset);
	if (address == 0)
		return B_OK;
			// writes to absent functions are dropped, like on real hardware

	// Native widths: no 32-bit read-modify-write as in DWPCIController.cpp:43-68.
	// A widened write of PCI_command would write back PCI_status and clear its
	// RW1C bits.
	switch (size) {
		case 1: *(vuint8*)address = (uint8)value; break;
		case 2: *(vuint16*)address = (uint16)value; break;
		case 4: *(vuint32*)address = value; break;
	}
	return B_OK;
}
```

How the other pieces map onto existing code:

- **`_InitDriverInt` order.**
  - `_ReadResourceInfo` maps `0xfd500000`/`0x9310`. Use `fdt->get_reg(dev, 0, ...)` as DW does at `DWPCIController.cpp:260-278`.
  - Then `_ResetAndStartLink` (returns `B_ERROR` if the link stays down; the domain then has no devices), `_ConfigureRootPort`, `_LoadVl805Firmware`, `_ProgramInboundWindows`, and `fMsi.Init(...)`.
  - `Init` failure is not fatal, because INTx still works.
- **`_ResetAndStartLink` waits** with `snooze()`. `InitDriver` runs in a thread, so sleeping is fine. Polls are bounded, with no unbounded loops like DW's `AtuMap` at `DWPCIController.cpp:427-430`.
- **`MsiInterruptCtrlBrcm::Init`** follows `MsiInterruptCtrlDW::Init` (`MsiInterruptCtrlDW.cpp:12-53`), but programs §1's registers:
  - `MSI_BAR_CONFIG_LO = 0xfffffffc | 1`, `HI = 0xf`, `MSI_DATA_CONFIG = 0xffe06540`.
  - Write all-ones to `+0x08` (clear) and `+0x10` (mask).
  - `install_io_interrupt_handler(irq180)`, `allocate_io_interrupt_vectors(32)`, `msi_set_interface`.
- **`AllocateVectors`** finds a free bit and unmasks it via `+0x14`. It returns `address = 0xffffffffc` and `data = 0x6540 | bit`.
- **`_InterruptReceived`** loops on `status = read(+0) >> fShift`. For each bit it writes `+0x08`, then calls `io_interrupt_handler(fStartVector + bit, B_EDGE_TRIGGERED)`.
- **`Finalize`**: copy `ECAMPCIControllerFDT::Finalize` (`ECAMPCIControllerFDT.cpp:97-156`), but scan only bus 0 dev 0 and bus 1 dev 0.

## 6. Risks and open items

1. **USB-stack DMA (§4).** The 3 GiB cap and non-coherent memory are both required for xHCI to work reliably, and both live outside this driver.
2. **Inbound DMA state after the notify** was not deterministic on Phoenix: intermittent HSE even with the BAR re-write ([PG]:1104-1112). Mitigations are step 12 and keeping Bus Master clear until after the notify; Phoenix used a two-stage `PCI_command` ([PX]:895-912).
3. **MSI register block.** The legacy (0x4300) vs 0x4500 choice depends on `MISC_REVISION`, which is not verified on our board. FreeBSD uses 0x4500 unconditionally [FB]. Log the revision. Linux and FreeBSD disagree on `MSI_EOI` (0x4060).
4. **FreeBSD's 960 MiB DMA cap** is unexplained ([FB]). Test xHCI with rings above 1 GiB before trusting 3 GiB.
5. **RC header BAR0/BAR1** at bus 0. Linux also sizes them by writing all-ones, so sizing them is not a new hazard. Whether they read non-zero is unverified. If `_ReserveBARs` finds a non-zero size there, it will carve them out of the window.
6. **Boot ordering.** Haiku's `PCI_command` enable plus BAR sizing happen after the notify. That matches Linux, where the firmware has no BAR dependency.
