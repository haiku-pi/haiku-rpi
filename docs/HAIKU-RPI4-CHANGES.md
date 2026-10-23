# What this fork changes in Haiku

**Audience:** Haiku developers, and anyone deciding what to take from this port. **Purpose:** to show,
without reading every commit, what the Raspberry Pi 4 fork changes in Haiku and which of those changes
apply beyond this board.

The fork is [haiku-pi/haiku](https://github.com/haiku-pi/haiku), branch `rpi4` (cloned into
`sources/haiku` by `scripts/bootstrap.sh`). Its remote `upstream` is official Haiku and `origin` is
haiku-pi/haiku. The branch starts from upstream **hrev60262** (committed 2026-10-17). Upstream was
merged into it on 2026-10-19 (`29b623181d`, 21 upstream commits), so the merge base is now
`hrev60262-21` (`af754c7c26`). Upstream is merged again every weekend; see [log/](log/).

On top of that base the fork carries **114 commits of its own** (2026-10-18 to 2026-10-21). To list
them, in `sources/haiku`:

```
git log --no-merges $(git merge-base rpi4 upstream/master)..rpi4
```

The commit messages are detailed and are the authority; this document summarises them. Hashes below
are the 10-character short hashes from that list.

## Scope

The raw diff against the merge base is **156 files, +33 053 / −869 lines**. Two blocks in it were not
written here:

| excluded | lines | what it is |
|---|---|---|
| `headers/private/drivers/drm/` | +3 562 | Mesa's MIT copies of the Linux DRM and v3d uAPI headers, so Mesa's v3d driver can be used unchanged |
| `drivers/network/wlan/broadcomfmac/dev/` | ~+6 400 | OpenBSD's bwfm driver, ported (the Haiku glue around it is ours) |

The hand-written surface is therefore roughly **23 000 lines**, most of it new drivers in new
directories. Of the 114 commits, 21 are changes to the list of binary packages the arm64 build uses
(`build/jam/repositories/HaikuPorts/arm64`); they are collected in one table at the end.

The changes fall into three kinds:

1. **Fixes to existing Haiku code that are not Pi-specific.** They are marked **★** and listed
   together directly below.
2. **Changes that let existing code run on this SoC**: EFI loader at EL2 under U-Boot, device tree
   address translation, a non-coherent DMA world, a GICv2.
3. **New drivers** for the Pi 4's on-board hardware.

Where a later commit replaced an earlier one, only the surviving state is described, and the entry
says so.

## ★ Start here: fixes that are not Pi-specific

Each of these is a defect or gap in code upstream ships, found because this port exercised it. The
section for its area gives the detail.

| # | defect | commit | effect |
|---|---|---|---|
| 1 | **arm64 spin-waits livelock on cores without LSE atomics** | `0db3ca639d` | `cpu_wait()` polled a cache line that another CPU was updating with load/store-exclusive loops, so the other CPU's store-exclusive kept failing. Two CPUs with interrupts off stalled for 10 ms to over a minute. Fixed as Linux does it: wait in WFE, bounded by the timer event stream. Any Cortex-A72-class core is affected. |
| 2 | **`ASSERT()` with side effects** | `55348c5c46` | arm and arm64 fetched the signal handler's address inside `ASSERT()`, and the FDT bus manager fetched each device's node and bus driver inside `ASSERT()` (9 places). At `KDEBUG_LEVEL` < 2 every signal handler and every FDT device would have used garbage. |
| 3 | **arm64 kernel stacks could fault inside the exception vector** | `dc849a150b` | The access flag and dirty state are managed in software. A fresh kernel stack page whose first access was the exception entry code storing an iframe faulted inside the vector, recursively. |
| 4 | **arm64 counted user time as kernel time** | `24b4e36dcf` | Only system calls ran `thread_at_kernel_entry()`. A pure Python loop showed user 0.013 s, sys 4.32 s; now user 4.17 s, sys 0.19 s. |
| 5 | **arm64 had no in-kernel stack traces** | `4413675f5c` | `arch_get_stack_trace()` was a stub, so `profile -k` put every tick in the commpage. |
| 6 | **Spinlock deadlock detection counted iterations** | `a46a16641e` | 100 million iterations; once an iteration waits in WFE the check fired after hours. Now 5 s (100 s for `_nocheck`), and a stuck synchronous ICI panics after 10 s. |
| 7 | **`device_manager` `get_next_child_node()` returned only the first child** | `81deb24f8c` | The skip loop never stopped at the previous child, so iterating past the first always gave `B_ENTRY_NOT_FOUND`. |
| 8 | **SDHCI acknowledged interrupts with `\|=` on a write-1-to-clear register** | `23f6235b0d` | A "transfer complete" arriving right after "command complete" was cleared unseen and the read waited forever. Plus a 5-bit timeout field that has 6 bits, a card scanned twice, and a clock divider rounded the wrong way. |
| 9 | **FDT `reg` addresses were not translated through `ranges`** | `1c9c78289e` | Only nodes directly under the root got CPU physical addresses. |
| 10 | **GICv2 inter-CPU messages were not ordered against the SGI** | `4eb785f652`, `aa7da3b827` | No write barrier before sending and no read barrier after acknowledging, and SGI targets assumed to be `1 << cpu`. GICv3 and Linux already had the barriers. |
| 11 | **EFI loader at EL2 without VHE set up EL1, then overwrote it** | `022ca91504` | `_arch_transition_EL2_EL1()` replaced TTBR0/MAIR/VBAR_EL1 with the EL2 values, and secondaries started with `TTBR0_EL1 = 0`. |
| 12 | **EFI `ip=` parsing looped forever** on any other load-option key | `d8dfb51d8d` | Only an `ip=` alone worked. The net mask and (`f316d4920e`) the gateway are now passed on. |
| 13 | **`remote_disk` could not open its partitions** | `a082ab4d4e` | No file system on a remote disk was ever identified, so booting from one panicked. |
| 14 | **Network boot deadlocked when a network module was loaded from the boot volume** | `cea07d5468` | Fixed by keeping the network modules loaded. |
| 15 | **`BTimeSource` conversions in `float`** | `c41702df18` | A time more than 2^24 µs from the last published one stopped the program in the debugger. |
| 16 | **The arm64 debug console read 0xff forever** | `b3a08271be` | "No input" (-1) became 255 because `char` is unsigned on AArch64. |
| 17 | **PL011 output could hang the system** | `f5650324d6`, `80a6e1f2fb` | The loopback test left the line at 5 data bits when the clock was unknown, and `PutChar()` waited for FIFO room without a limit. |

Also generally useful, though new code rather than fixes: serial-console emergency keys
(`8eca4824c9`, `aa1366f629`), FDT `get_dma_window()` (`08e65e6449`, `f2e5b2fab8`), SD high speed /
UHS-I / SDIO in the MMC stack, ADMA2 in sdhci, a pipelined `remote_disk` in both the loader and the
kernel, WPA-personal joins without the wpa_supplicant in openbsd_wlan, and the CPU clock measured
with the PMU on arm64.

---

## 1. Boot chain: EFI loader, early serial, finding the boot volume

The Pi 4 boots firmware → U-Boot (EFI) → `haiku_loader.efi`. U-Boot enters the loader at **EL2
without VHE** and releases secondary CPUs from a **spin table**. Neither case had been exercised by
Haiku's arm64 loader before. All entries here are ★ except the first, which is generic code that only
this board's console layout happened to reach.

| commit | change | what and why |
|---|---|---|
| `9678b4cd65` | Map a debug UART that is not page-aligned | The BCM2835 mini UART's registers sit at offset 0x40 of the AUX block. `map_region()` needs page alignment, so the loader panicked with "Too many levels at mapping". It now maps the containing pages and keeps the offset. |
| `022ca91504` ★ | Set up EL1 after dropping from EL2; flush the spin-table release | The EL1 translation regime was programmed and then overwritten by the EL2→EL1 transition. The boot CPU kept U-Boot's MAIR (different attribute indices), and a secondary enabled its MMU with `TTBR0_EL1 = 0` and hung `smp_cpu_rendezvous()`. The loader now drops to EL1 first. The release address is also cleaned to the point of coherency, because spinning CPUs read it with caches off. |
| `d3c5064bd0` ★ | Clean the data cache before releasing secondaries | Secondaries start with caches off and read `sCpus`/`sSecondaryStacks`, which the boot CPU wrote with caches on. |
| `9148d14cac` ★ | `CNTKCTL_EL1` after the EL2 drop | It was set only for EL1 or VHE entry. Its reset value traps EL0 counter reads, so `launch_daemon` died at its first `system_time()`. |
| `a6502fab74` ★ | Keep the firmware's UART setup when its clock is unknown | The Pi's PL011 clock comes from a clock controller, so `dtb_get_clock_frequency()` returns −1. The loader then programmed a divisor from 0xffffffff (about 1300 baud), garbling everything after `ExitBootServices()`. |
| `bce76d6e73` ★ | Wait for a boot device that is published late | SD (the MMC bus scans in its own thread) and USB disks could appear after the boot partitions were searched, so boot failed with "did not find any boot partitions". The kernel now rescans for up to 10 s for a strict match before falling back to a looser one. |
| `daaaf7a848` | The loader caches the last decompressed package chunks | The loader has no file cache, and an ELF image is read in many small pieces (headers, segments, symbols). Each piece read its compressed 64 KiB chunk again and decompressed all of it. The package heap reader now keeps its last eight chunks (boot mode only). Loading the kernel and boot modules from SD went from 2185 device reads (15.4 MB) and 666 decompressions to 728 reads (4.7 MB) and 180. Together with U-Boot's EMMC2 fix ([../patches/u-boot/](../patches/u-boot/)), the loader's part of an SD boot fell from 3.1 s to 1.2 s. Not Pi-specific. |

### Network boot (remote disk)

Haiku boots from the network by mounting a **block device served over UDP** (`remote_disk`), not an
NFS root. U-Boot loads the EFI loader by TFTP and passes `ip=`; the loader and the kernel then read
the image from the host's `remote_disk_server`. See [design/netboot.md](design/netboot.md). This
path was broken in several places on arm64. After these commits a Pi 4 reaches the desktop in about
55–60 s, with nothing written to the SD card. All are ★ except `b294857151`.

| commit | change | what and why |
|---|---|---|
| `b294857151` | Boot modules for an arm64 remote-disk boot | `remote_disk`, `genet` and the whole network stack become boot modules on arm64. All network modules are included, because one loaded later from the remote disk can deadlock (next-but-one entry). |
| `a082ab4d4e` ★ | `remote_disk` opens partitions | devfs opens `disk/virtual/remote_disk/0/1` under its own name, which the driver did not recognise. No file system on a remote disk was ever identified. Also fixes tracing format strings that did not compile on 64-bit. |
| `cea07d5468` ★ | Wait for the link; keep network modules loaded | (1) A PHY starts negotiating only when the device is opened, so the remote disk's first request failed with "Network is down". The kernel now waits up to 20 s for link. (2) Unused boot modules are unloaded after mount. A module needed later was then read through the stack while the stack held the lock the read needed: `getaddrinfo()` held an interface lock, the stack loaded a datalink module from the remote disk, and the disk's reader waited for the interface. The desktop never came up. |
| `cb0f2f9884` ★ | net_server leaves a network-boot interface alone | It started DHCP on the interface the boot volume is reached through, which can take that address away. An interface that already has IPv4 at start is left as it is. |
| `d8dfb51d8d` ★ | EFI `ip=` parsing; pass the net mask | Any load-option key not two characters long made the search for `ip=` loop forever. The fourth field (net mask) now reaches the kernel; without it the mask was chosen by address class. |
| `f316d4920e` ★ | Default route through the gateway | The network-boot default route had no gateway, so every off-link address was treated as on-link. The loader takes the gateway from `ip=` and the kernel routes through it. |
| `b1ddc00b1f` ★ | Kernel `remote_disk`: 16 requests in flight | It sent one 1 KiB request and waited for the reply before the next, so the boot volume read at round-trip time. Requests are told apart by ID, resent every 0.5 s while overdue, and given up after 25 s. Desktop ~90 s → ~70–80 s, 8/8 boots, package checksums equal to the host's. |
| `e1fe4f62bd` ★ | Loader remote disk: 8 requests in flight | The same for the loader, capped at 8 because the firmware's network driver buffers few frames. The loader's part 25 s → ~5.5 s; desktop ~60 s. |

**Open:** about 1 in 45 network boots wedges silently (every CPU stops; SD boots do not show it).
`a46a16641e` and `80a6e1f2fb` (section 2) were written while hunting it. It is not fixed; see
[log/WEEK-2026-W43.md](log/WEEK-2026-W43.md).

---

## 2. Kernel: arm64 core

Nearly everything here applies to any arm64 board. The Pi 4 found it because its Cortex-A72 has no
LSE atomics and no hardware access/dirty flags, and because it is real hardware with real interrupt
load, which QEMU did not provide.

### Memory management and caches

| commit | change | what and why |
|---|---|---|
| `9e2efe1eff` | `arm64_dcache_clean_range()` / `arm64_dcache_flush_range()` | Helpers to write back (and discard) a virtual range, for drivers of devices that do not snoop the CPU caches. On the Pi 4 that is every device on the VideoCore bus, PCIe included. |
| `dc849a150b` ★ | Map kernel stacks accessed and dirty from the start | The A72 manages neither flag in hardware, so a fresh page faults on first access and on first write. On a kernel stack that first access can be the exception entry storing an iframe; the fault then happens inside the vector, and each nested exception stores to the same page again. A `KDEBUG_LEVEL` 1 build (smaller frames) panicked at boot with it. Kernel stacks are never paged out, so the flags carry no information there. It matched the shape of the network-boot wedge but did not cure it (a wedge 17 network boots later). |

### Exceptions and time accounting

| commit | change | what and why |
|---|---|---|
| `cdd63d4b62` ★ | Classify unhandled user exceptions | An undefined instruction, an alignment fault or another unhandled class left the exception type and signal number uninitialised, so a crashing thread got whatever signal was in the register. Each class now gets its proper signal, and the syndrome, fault address and PC are logged. |
| `24b4e36dcf` ★ | Count user time on every exception from EL0 | `thread_at_kernel_entry()` ran only on system calls, while `thread_at_kernel_exit()` ran on every return. Timer and page-fault entries therefore billed the preceding user time as kernel time. It now works as on x86. |

### Interrupt controller (GICv2) and the CPU stall

This is the longest story in the fork. About half of all Pi 4 boots froze for over a minute, and
under SD load CPUs stalled for up to 760 ms. It first looked like the GIC: an SPI left active, and
CPU 0 taking nothing until another CPU touched the GIC. `5b2e85f498` added a watchdog that sent the
stuck CPU an SGI, and `f2bf1c9e87` moved the GIC setup to Linux's and tightened that watchdog to
25 ms. Neither removed the stall. **`0db3ca639d` found the real cause, an LL/SC livelock in kernel
spin-waits, and removed the watchdog and its diagnostics.** What survives:

| commit | change | what and why |
|---|---|---|
| `4eb785f652` ★ | Write barrier before sending an SGI | The message goes to normal memory and the SGI is a device store, which is not ordered after it, so the target could find no message. GICv3 and Linux already did this. |
| `aa7da3b827` ★ | GICv2 IPI ordering and CPU map; debug UART on every CPU | After acknowledging an SGI, read the message only behind a read barrier, because the acknowledge is a device read that does not order the normal loads that follow. Address SGIs by each CPU's interface bit, read from the banked target register, rather than `1 << cpu`. `RouteInterrupt()` lets a set of CPUs take an SPI. KDL commands `gic` and `arm64_timer`. The debug UART's interrupt goes to every CPU, so the emergency keys work while one CPU is stuck. (Its Ctrl-T freeze probe was removed by `5b2e85f498`.) |
| `5b2e85f498` | Barrier before WFI | Outstanding writes complete before WFI, as in Linux's `cpu_do_idle`. The stall watchdog this commit added was later removed. |
| `f2bf1c9e87` | GIC setup as Linux's GIC-400 code | Every interrupt at one priority (0xa0), set once: enabling an interrupt no longer read-modify-writes the priority word it shares with three others, one of which may be active. Priority mask 0xf0, active state cleared, the firmware's bypass bits kept. The watchdog part is gone. |
| `0db3ca639d` ★ | **Wait in WFE, not by polling** | CPU 0, notifying a condition variable from the SD interrupt, polled `fEntriesCount` while the waiter retried an atomic on the same cache line. With no LSE atomics, the atomics are LL/SC loops, and the polling loads kept clearing the waiter's exclusive monitor. As Linux does it: `cpu_wait()` waits in WFE on the line (`ldxr` + `wfe`); the generic timer's event stream (every ~152 µs) bounds every WFE; `try_acquire_spinlock()` tests before it exchanges; and an ISB follows timer register writes. Boot bench 10/10 without any watchdog, and a 10-minute QuakeSpasm + SD soak with no stall (it had ~400 before). `c805c1822d` removes a disproved rationale from the `arch_cpu_idle()` comment. |

### SMP, spinlocks and deadlock detection

| commit | change | what and why |
|---|---|---|
| `a46a16641e` ★ | Deadlock detection by time | `acquire_spinlock()` and its read/write variants panicked after 100 million failed iterations. With WFE waits an iteration can take a fraction of a millisecond, so a stuck lock hung the system silently for hours. Now 5 s (the `_nocheck` variants 100 s). A synchronous ICI left unprocessed for 10 s panics too (there was no check). A gap of over a second between clock readings, for example a CPU halted in KDL, restarts the measurement. |

### CPU clock

| commit | change | what and why |
|---|---|---|
| `a669f3070c` ★ | Measure the CPU clock with the PMU cycle counter | `arch_get_frequency()` returned 0, so About and sysinfo said "@ 0 MHz". It now counts cycles over 100 µs of the generic timer on the CPU asked about (a cross-CPU call for another CPU) and keeps the result for a second. The core's default frequency is that measurement until SMBIOS or the device tree give one. Pi 4: "ARM Cortex-A72 @ 1.50 GHz". The same commit names the board in the thermal driver (section 11). |

### Serial console and kernel debugging

| commit | change | what and why |
|---|---|---|
| `f5650324d6` ★ | PL011: keep the firmware's line settings | The constructor's loopback test sets IBRD=1, FBRD=0 and LCRH=0 (5 data bits, no FIFO). Nothing restored them unless `InitPort()` ran, which needs the clock. Everything printed was garbage. |
| `b3a08271be` ★ | Fix reading the arm64 debug serial port | `arch_debug_serial_try_getchar()` went through a function returning `char`, so −1 became 255 and KDL read endless 0xff. The blocking variant did not block. |
| `8eca4824c9` ★ | Emergency keys on the serial console | Three Ctrl-] followed by a key act as Alt-SysRq+key, so `d` enters KDL on a board with no working keyboard. On by default on arm, arm64 and riscv64; the `serial_emergency_keys` setting overrides it. |
| `aa1366f629` ★ | Serve the emergency keys from the UART interrupt | The polling daemon stopped along with the threads it shares. The keys now feed one state machine from their own thread and, where the platform supports it (PL011), from the receive interrupt, which works even when no thread can run. |
| `80a6e1f2fb` ★ | PL011 output: bounded wait for FIFO room | A UART that stopped sending stopped the system: the first CPU spun in `PutChar()` holding the debug-output lock, every other printing CPU spun behind it, and `panic()` prints the same way. It now gives up after ~200 000 status reads and does not wait again until the FIFO accepts a character. Written for the network-boot wedge; 12/12 network boots clean with it, but that wedge is not fixed. |
| `4413675f5c` ★ | `arch_get_stack_trace()` and `arch_debug_get_interrupt_pc()` | Both were stubs, so the profiler and tracing saw no kernel frames on arm64. They now walk frame records across iframes (ELR plus the interrupted FP); user frames are read via `user_memcpy()`, as on x86. `profile -k -S` of a TCP sender now names memcpy, the object cache, mutexes and the checksum. |
| `55348c5c46` ★ | Side effects out of `ASSERT()`; what `KDEBUG_LEVEL` < 2 needs | Found by building at level 1. arm and arm64 `arch_setup_signal_frame()` fetched the handler address inside `ASSERT()`. The FDT bus manager fetched node and driver inside `ASSERT()` (9 places, now `ASSERT_ALWAYS()`). Missing includes in `arch_int_gicv3` and sdhci, and a NULL guard in `dec_vnode_ref_count()` for a GCC `-Wstringop-overflow` false positive. |
| `18e0d2a9db` | **`KDEBUG_LEVEL` 1** (was 2) | Level 2 (paranoid malloc/free, debug mutexes, `ASSERT()`s, block-cache checks) cost ~30 % of a TCP sender's kernel profile in the slab allocator and ~15 % in mutexes. Level 1 keeps the debug syslog, interrupt statistics and KDL commands; the spinlock and ICI checks do not depend on the level. Pi 4: TCP upload 600 → 914 Mbit/s, download 660 → 918; network boot to desktop 56.2 → 54.8 s (15/15); a 15-minute Firefox + SuperTuxKart + HEVC soak with 0 crashes. A fork configuration choice, not a fix (`build/config_headers/kernel_debug_config.h`). |

---

## 3. Device and bus managers

The FDT changes are ★: any board whose devices sit behind remapping buses needs them. The mailbox
module and the PCIe driver are Pi-specific.

| commit | change | what and why |
|---|---|---|
| `1c9c78289e` ★ | FDT: translate `reg` through the parent buses' `ranges` | `get_reg()` returned the node's address as written, which is a CPU physical address only directly under the root. On the Pi 4, `/soc` maps 0x7exxxxxx to 0xfexxxxxx, and `emmc2bus` and `/scb` have their own windows. A bus without `ranges` (I2C, say) is not memory-mapped, and its children's addresses are returned unchanged. |
| `08e65e6449` ★ | FDT: `get_dma_window()` | From the nearest `dma-ranges`: the offset between physical and DMA addresses and the end of reachable RAM. VideoCore-bus devices see the first GiB of RAM at 0xc0000000. |
| `f2e5b2fab8` ★ | `get_dma_window()`: the RAM window, not the first one | `/scb` lists the peripheral window first, so its devices got a 56 MiB window. RAM's window is the largest one; use that. |
| `81deb24f8c` ★ | `device_manager`: `get_next_child_node()` | Returned only the first child (see the shortlist). |
| `eafa824d33` | `generic/bcm2835_mailbox`: VideoCore firmware property interface | Clock rates, temperature, power domains, board information and GPIO-expander lines via the ARM-to-VideoCore mailbox, with one request buffer inside the VideoCore's DMA window and the cache maintenance it needs. A boot module, because the SD card's base clock comes from the firmware. Later commits add tags (GPIO state, V3D power and clocks, planes, clock IDs, turbo). |
| `5cb3a2d215` | `busses/pci/brcmstb`: Broadcom STB PCIe root complex | The BCM2711's single-lane PCIe, which connects the VIA VL805 USB 3 controller. U-Boot shuts the controller down, so it does the full bring-up as Linux's `brcm_pcie_setup()`/`brcm_pcie_start_link()`: reset, inbound and outbound windows, PERST# for 100 ms, link training. Haiku's PCI bus manager does not program bridges here, so the root port is set up as a bridge to bus 1. Boards without a VL805 EEPROM get its firmware loaded by the VideoCore (`NOTIFY_XHCI_RESET`). Legacy interrupts go through `interrupt-map`, devices behind it inherit the 3 GiB DMA limit, and MSI is not supported yet. Gen 2 x1 link. See [design/brcmstb-pcie.md](design/brcmstb-pcie.md). |

---

## 4. Storage: SDHCI, the MMC bus, SDIO

Haiku's MMC stack was written against PCI and ACPI SDHCI controllers at default speed. The Pi 4 has
two FDT-described controllers: `emmc2` for the SD card and an Arasan controller wired to the WiFi
chip. They share one interrupt line, and `emmc2` ignores 8- and 16-bit register accesses. Everything
in the bus manager, the disk driver and `sdhci.cpp` itself is ★. `sdhci_fdt.cpp`'s quirk table is
Pi-specific.

| commit | change | what and why |
|---|---|---|
| `68293c40a1` ★ | Turn MMC debug tracing off | Per-command tracing on a serial console slowed an SD boot by more than a minute. The disabled `TRACE()` of `mmc_disk` was not empty and broke an if/else chain. |
| `23f6235b0d` ★ | sdhci: fixes found on hardware; 32-bit access, platform clock, DMA window | Generic fixes: write-1-to-clear acknowledge (see the shortlist), `RecoverError()` truncating status to 16 bits, the 6-bit timeout-clock field, double scan of a card present at start, a clock divider rounded down so the card clock could exceed the request (now rounded up), missing-completion reporting without tracing. Hardware support: registers narrower than 32 bits accessed through their 32-bit word, with transfer mode and command written in one store; a platform base clock; a DMA offset plus non-snooping cache maintenance. |
| `af82a8ca4d` | sdhci: FDT attachment (`brcm,bcm2711-emmc2`) | Registers and interrupt from the device tree (through `ranges`), base clock from `clock-frequency` or the VideoCore firmware, DMA window from `dma-ranges`. |
| `890f468bf4` ★ | sdhci: ADMA2 and PIO | ADMA2 with 32-bit descriptors when supported and a DMA window is known; descriptors cover at most 32 KiB, so no length encodes as 0. PIO via the buffer data port without SDMA (QEMU's model of the Pi controllers). CRC, end-bit and ADMA errors now end a transfer with an I/O error instead of leaving it waiting. |
| `bf3a1d0bdb` ★ | High speed (50 MHz) | Cards ran at 25 MHz. Adds `execute_data_command()` (a command with a short data phase) and `set_clock()`, and `mmc_disk` sends `SWITCH_FUNC` after going to 4-bit mode. Sequential reads 10.5 → 18.9 MB/s. |
| `e29c5b7c65` ★ | UHS-I: 1.8 V signalling, DDR50/SDR50 | S18R in ACMD41, CMD11 and the controller's voltage switch, then the fastest common mode (DDR50, SDR50 without tuning, or high speed). New hooks `supported_timings()`, `switch_signal_voltage()` and `set_timing()`. On the Pi the regulator is line 4 of the firmware's GPIO expander. 1 MiB reads 17.4 → 31.7 MB/s (DDR50). |
| `1cccf09635` ★ | ADMA2: one command for all segments of a transfer | `DoIO` issued one command per I/O vector and the bus allowed one segment per transfer, so page-cache I/O into scattered pages became many small commands. One descriptor table now covers the vectors and the FDT bus allows 32 segments. Raw reads 32.3 → 42.6 MB/s; a 112 MB package through the file cache at 44 MB/s; md5 equal to the host's. |
| `c283f50c5b` ★ | Spin up to 50 µs for command completion before sleeping | A command completes in microseconds, faster than a thread wakes. WiFi ~14 → ~25 Mbit/s up, ~38 → ~45 down. It also showed that Command Inhibit can still be set just after the completion interrupt; it now gets 1 ms to clear. |
| `f0578116b8` ★ | Report and stop an interrupt storm | More than 20 000 interrupts in 100 ms (a level nobody clears): report status, enabled signals and present state once, and mask the controller so the system stays alive. Added while hunting the network-boot wedge. |

### SDIO (for the WiFi chip)

| commit | change | what and why |
|---|---|---|
| `ec55b68bfe` ★ | Attach the Pi's WiFi SDIO controller; enumerate SDIO cards | `sdhci_fdt` gets a compatible table with quirks; the Arasan `brcm,bcm2835-mmc` gets the firmware EMMC clock, no High Speed Enable bit, PIO only, and 3.3 V despite reporting no voltage. `non-removable` is honoured and disabled nodes are skipped. sdhci claims an interrupt only when an enabled status bit is set, because the two controllers share a line. It adds R4/R5 replies, a data timeout derived from the base clock, and a probe timeout that is not an error. `mmc_bus` probes CMD5 before the memory sequence and initialises SDIO cards (OCR, RCA, CCCR, CIS manufacturer tuple) as `CARD_TYPE_SDIO`. |
| `c5f52af56b` ★ | SDIO data transfers; power-cycle the WiFi chip | CMD53 through the buffer port, any block size up to 2048. Block size and count go in one 32-bit write, because the Arasan controller can lose a write closely following another to the same register (Linux shadows them too). Errors reset the CMD/DAT lines, a busy command line is an error rather than a panic, and CMD52 may be sent while DAT is busy. `mmc_bus` gets CMD52/CMD53 operations for function drivers (block mode plus byte remainder), function block sizes and enable, and a 4-bit bus with high-speed timing. The card is power-cycled through the firmware GPIO expander (`WL_ON`). The mailbox gains `GET_GPIO_STATE` and accepts unmarked responses. |
| `1be86daecf` | SDIO card attributes as `uint16` | Vendor and device IDs are published as `uint16`, like other buses. (The masking of the card interrupt in this commit was superseded by the next.) |
| `4d12fd3908` ★ | Deliver the SDIO card interrupt | sdhci signals the card interrupt to a semaphore and keeps it masked until the function driver has serviced the card (only the card can clear the level). The MMC bus manager and the compat `sdio` bus pass it through. broadcomfmac waits on it instead of polling every 10 ms; a 100 ms poll remains as a safety net. WiFi round trip ~13 → ~9 ms. |
| `d018d9dfe1` | SDIO high speed up to 50 MHz | The Pi's WiFi controller gets 41.67 MHz (250 MHz ÷ 6). The chip's RAM still reads back intact. WiFi downloads ~29 → ~38 Mbit/s. |

---

## 5. USB (xHCI behind the VL805)

The xHCI driver works behind the PCIe driver above with only a diagnostic added. USB keyboards, mice and disks enumerate.

| commit | change | what and why |
|---|---|---|
| `71bc709601` | USB stack DMA below 3 GiB and non-cacheable on arm64 | The VL805 reaches only the first 3 GiB and does not snoop. This is applied to the stack's DMA areas on all of arm64 for now, **until the limits are taken from the host controller itself**. That makes it a stopgap, not upstreamable as is. |
| `1d44b00380` ★ | xHCI: show the endpoint ring on a TRB error | Prints the event's TRB pointer and the ring, which identify the rejected TRB. Seen intermittently on a HID interrupt endpoint of the VL805. |

---

## 6. Networking: GENET Ethernet, WiFi, the net stack

GENET and broadcomfmac are Pi-specific drivers. The SDIO bus in the FreeBSD compat layer and the
WPA join path in `openbsd_wlan`/net_server are ★ and apply to any board.

| commit | change | what and why |
|---|---|---|
| `4ff857683f` | `drivers/network/ether/genet`: Broadcom GENET v5 + BCM54213PE PHY (RGMII) | One RX and one TX ring of 256 descriptors, interrupt-driven with timeouts as a backstop. MDIO through the UniMAC, link polling with speed/duplex reprogrammed on change. MAC address from the device tree, the UniMAC registers or the firmware. A device-manager driver publishing `net/genet/<n>`, because the FreeBSD compat layer cannot attach to device tree nodes. Register sequences follow Linux's bcmgenet/bcmmii/broadcom/mdio-bcm-unimac. Deliberately without status blocks, PHY low-power modes or EEE, after an earlier Pi 4 driver traced gigabit receive losses and dropped first frames to them. See [design/genet-driver.md](design/genet-driver.md). |
| `06356adcc0` | GENET: cacheable receive buffers, invalidated per frame | Copying out of non-cacheable buffers capped receive at 250 Mbit/s. The CPU never writes RX buffers, so they hold no dirty lines; each frame is invalidated before the copy. TX stays write-combining. TCP download 250 → 735 Mbit/s (918 after `18e0d2a9db`). |
| `fb1b33e488` | NFSv4 client in the arm64 minimum image | The Pi has only SD and USB storage. The NFSv4 client and its idmapper make shares reachable over GENET. |
| `e26850ef57` ★ | freebsd_network: an `sdio` bus | `HAIKU_FBSD_WLAN_SDIO_DRIVER_GLUE` drivers are offered the SDIO cards the MMC bus manager found, as a `haiku_sdio_device` in ivars, with a small C interface (`dev/sdio/haiku_sdio.h`) to the bus manager's SDIO operations. |
| `3fcf7b6035` | `broadcomfmac`: OpenBSD's bwfm over SDIO | A port of OpenBSD's `bwfm.c` and `if_bwfm_sdio.c` (as of 2026-09-25) to the openbsd_wlan stack, attached through a small sdmmc shim (`sdmmc_haiku.c`). Firmware comes from `/boot/system/non-packaged/data/firmware/broadcomfmac/` (`brcmfmac43455-sdio.{bin,txt,clm_blob}`). One Haiku-specific fix: firmware event messages carry a 16-byte interface name, not `IFNAMSIZ` (32 on Haiku). BCM43455 firmware 7.45.234. In the arm64 minimum image. Interrupt delivery came with `4d12fd3908`. See [design/wifi-bcm43455.md](design/wifi-bcm43455.md). |
| `86122fc522` | broadcomfmac: unmask the card interrupt only after servicing it | Before the driver enabled its handler, the interrupt thread unmasked an uncleared level after every wake. The real-time thread spun and starved net_server, and the boot stopped at WiFi bring-up. |
| `584742feec`, `00004aa2ff` ★ | Join WPA personal networks without the wpa_supplicant | The wpa_supplicant is not built for every architecture. net_server passes the passphrase via `IEEE80211_IOC_HAIKU_JOIN` with the new flag `IEEE80211_HAIKU_JOIN_PASSPHRASE`. openbsd_wlan derives the PMK itself (PBKDF2-HMAC-SHA1, 4096 rounds, SSID as salt) and its in-kernel supplicant does the handshake. SSID and key lengths are now checked. |
| `a6ca113d55` ★ | Plain PSK when PSK-SHA256 is also offered | SHA-256 key management needs PMF, which bwfm does not negotiate. APs offering both (hostapd's default with optional PMF) are joined with plain PSK, as the wpa_supplicant would. Result: 4-way handshake, DHCP lease, ping. |
| `bf33dc5c29` ★ | Unscanned networks with a passphrase are WPA2-PSK | A network not yet in the scan results was taken to be open, so joining it with a passphrase failed. It is now tried as WPA2/CCMP/PSK. |
| `f43d42c93b` ★ | openbsd_wlan: join with one interface restart, not three | Name, PSK and WPA parameters went through the driver's ioctl one by one; each returned `ENETRESET`, and bwfm restarted the interface three times. The last scan sometimes never finished (1 join in 2 failed). Name and key now go to net80211 directly. Result: 3/3 joins, each with one restart. |

Section 1 covers the network-boot changes to net_server and the kernel.

---

## 7. Graphics: display driver and V3D GPU

Both are new Pi-specific drivers. The V3D driver implements the **Linux v3d DRM ioctl interface** on
`/dev/dri/renderD128`, so that Mesa's v3d (OpenGL/GLES) and v3dv (Vulkan) drivers can run with little
change. The Mesa side lives in the haiku-pi/mesa fork, outside this repository. See
[design/gpu-v3d.md](design/gpu-v3d.md).

### `bcm2711_display` (kernel driver + accelerant)

| commit | change | what and why |
|---|---|---|
| `c9b4bfe234` | Display driver and accelerant | The display as the VideoCore firmware drives it: the boot loader's frame buffer (write-combining), the monitor's EDID from the firmware, and a retrace semaphore released at each vertical blank. The vblank comes from the SMI interrupt (with the firmware KMS node enabled) or from a thread waiting on the firmware's `SET_VSYNC`. app_server prefers it over the generic framebuffer driver. Retrace 60.00 Hz (gaps 16 655–16 677 µs). |
| `716633f51b` | Modes up to the native one, scaled by a firmware plane | The HDMI link stays in the firmware's mode. A smaller mode gets its own contiguous frame buffer below 1 GiB (the only range the firmware scans out from), which the primary plane (`SET_PLANE`) scales up, aspect kept and centred. The KDL console follows the frame buffer. Tested at 1280×720 and 1024×768 (pillarboxed). |
| `7a37185fe7` | Hardware cursor on a firmware plane | A 64×64 ARGB8888 buffer on the top plane (7). B_RGBA32 or converted BeOS monochrome shapes. A move is one `SET_PLANE` call, scaled with the mode and clipped at the edges. |
| `8af6f08b0b` | app_server's clone of a RAM frame buffer is write-combining | A clone of physical memory inherits its memory type, but the RAM frame buffer of a non-native mode was cloned cacheable, so the firmware could scan out lines still in the CPU cache. |

### `v3d` (V3D 4.2 render node)

| commit | change | what and why |
|---|---|---|
| `cb92912c6b` | Power on and identify the GPU | Attaches via the device tree and finds the power-management block that provides the GPU's power domain. The first `open()` powers it on: QPU enable, power domain and clock through the mailbox. The clock is trusted only once the firmware reports it on, because an access to an unclocked V3D never completes. Then the reset line and the two bus bridges. The firmware allows the clock only when its device tree enables the V3D node. 500 MHz. |
| `e01ad66e7c` | GPU memory, jobs and synchronisation (Linux v3d interface) | One 4 MiB page table for the 4 GiB GPU address space, plus a scratch page for stray accesses. Buffer objects are wired, zeroed and write-combining; `MMAP_BO` clones them into the caller, and freed pages are quarantined until every earlier job completes. `SUBMIT_CL` with per-job cache/TLB maintenance, run one at a time in order by a worker thread. The IRQ handler serves binner memory from a pre-staged pool and has storm guards. `WAIT_BO`, syncobjs, a watchdog and a full GPU reset. Per-client handles, so a dying client leaks nothing. Test program `v3dtest`: 41/41 checks. |
| `f337b7e167` | Do not read a dropped job after releasing it | The reset message took the sequence number of a job it had just released. |
| `2ff9130439` | List a wedged job's buffers in its dump | Diagnostic. |
| `f6ae60bfbb` | Statistics: bin and render time, GPU busy | `v3d_stats` splits a control list's GPU time into its two stages and shows how busy the GPU is. Measured with QuakeSpasm at 1080p: bin ~0.45 ms, render ~10 ms per list, so overlapping them (asynchronous queues, stage 7) could gain at most ~4 %. |
| `bf6e4efdd2` | Import client memory as a GPU buffer | `DRM_V3D_HAIKU_IMPORT_MEMORY` wires a team's pages into the GPU page table so Mesa can render or blit straight into a `BBitmap` without a copy. `DRM_V3D_HAIKU_SYNC_BO` does the cache maintenance, since the pages stay cacheable for the CPU. These two ioctls are Haiku-specific extensions. |
| `4a8412437e` | Texture formatting unit jobs (`SUBMIT_TFU`) | `GET_PARAM` already advertised the TFU, so Mesa used it for texture uploads and mipmaps, and every submission failed. TFU jobs now share the queue with control-list jobs. |
| `d5a14e2c9b` | Wire imported memory in a kernel clone of the client's area | Killing GLTeapot panicked in `vm_delete_areas` (`!area->IsWired()`): a team's address space goes away before its files close, while the BO still held the pages wired. The BO now wires a kernel clone of the area. |
| `1ff35fa767` | Job statistics behind the kernel setting `v3d_stats` | Every 5 s: jobs by kind, GPU time, submit-to-done latency, and client wait time. |
| `def8419f84` | What Mesa's Vulkan driver (V3DV) needs | V3DV in Mesa 26.2 has no fallback for older kernels. Adds `SUBMIT_CSD` (compute), `SUBMIT_CPU` (timestamp, reset and copy queries, indirect dispatch), the multisync extension on every submit kind (a chain is queued atomically), and sync files (`SYNCOBJ_HANDLE_TO_FD`/`FD_TO_HANDLE`, `SYNC_IOC_MERGE`, `SYNC_IOC_FILE_INFO`, select/poll). Deliberately simpler than Linux: in-syncs are not tracked (jobs still run in order), no opaque syncobj fds, no perfmon. |

With these changes and the haiku-pi Mesa, the Pi 4 runs OpenGL, OpenGL ES 3.1 and Vulkan in Haiku
windows. The V3D driver also holds the core clock at maximum while the GPU is on (section 11).

---

## 8. Video decode: `rpivid` (HEVC)

A new Pi-specific driver for the BCM2711's HEVC decoder block, which is MMIO plus firmware clock 11
and needs no VCHIQ. H.264 decoding stays with the VideoCore firmware and is not reachable. The
userspace half is a `hevc_rpivid` hwaccel in FFmpeg 6.1, carried as
[../patches/ffmpeg6/](../patches/ffmpeg6/). See [design/hw-video-decode.md](design/hw-video-decode.md).

| commit | change | what and why |
|---|---|---|
| `e98b67a5bd` | `/dev/video/rpivid/0` | The clock goes on at first open and the version register is checked (0x202). Decodes one picture at a time, interrupt-driven through its two phases. The driver owns the memory the block reads and writes (bitstream, pictures, scratch), maps it into the client, and checks every command entry (register whitelist, bitstream bounds) while rebasing addresses. 5 test streams (intra, IPB, weighted prediction, Main 10, 720p), 223 pictures, all bit-exact against the CPU decoder; MediaPlayer decodes HEVC on the block. Also bumps the repository's ffmpeg6 to 6.1.6-2. |
| `be395e19f4` | Interface 2: a decode pipeline | `RPIVID_SUBMIT` queues and `RPIVID_WAIT` collects (`RPIVID_DECODE` remains as both). Phase 1 of picture N+1 runs into a second scratch set while phase 2 reconstructs picture N, as in Linux's driver, in strict FIFO order so references are complete. Buffers are reference-counted per job, and close waits for the file's pictures. With ffmpeg6 6.1.6-3: 1080p 20 Mbit/s at 115 fps using 0.46 cores (the CPU decoder manages 25 fps on 4), 2160p at 38 fps, bit-exact. |

---

## 9. Audio

| commit | change | what and why |
|---|---|---|
| `c536a518b2` | `bcm2711_pwm`: hmulti driver for the 3.5 mm jack | PWM1 on GPIO 40/41, fed by legacy DMA channel 5 (paced by the PWM1 DREQ) from a two-period ring. Each period's end interrupts, and the handler silences the played half and completes one buffer exchange. 54 MHz ÷ 2 with a range of 612 gives 44 117.647 Hz, advertised as 44 100 (frame counts come from the hardware). Addresses and interrupt from the device tree. media_server picks it as default output ("Raspberry Pi headphones"); measured 44 117.657 Hz with no underrun. In the regular image. |

---

## 10. Bluetooth

| commit | change | what and why |
|---|---|---|
| `865c648344` | `bcm2711_bt`: on-board BCM43455 Bluetooth over UART | An H4 transport driver for Haiku's Bluetooth stack, like `h2generic` for USB: `/dev/bluetooth/h4/bcm2711_bt/0`. The controller sits on the AUX mini-UART, which the driver routes to GPIO 30–33 (ALT5) itself (`config.txt` disables the firmware's Bluetooth UART). Every open resets it through the firmware's `BT_ON` line, patches it from `BCM4345C0.hcd` (Download_Minidriver, records, Launch_RAM), resets it again, then registers it with the HCI module. Receive is interrupt-driven, with polling as a fallback. The baud divisor derives from the core clock. 323/323 patch records acknowledged; bluetooth_server reads features, name and class, and an inquiry completes. In the regular image. |

---

## 11. Power, sensors, random numbers

All Pi-specific. The firmware owns the sensors and the clocks, so these drivers talk to it through
the mailbox module.

| commit | change | what and why |
|---|---|---|
| `426ee96c2e` | `drivers/power/bcm2835_thermal` | `power/bcm2835_thermal/<n>` for `brcm,bcm2711-thermal` (or `-2835-`), like the other thermal drivers. `read()` gives the SoC temperature, the firmware's throttling limit and whether it throttles (heat, under-voltage); `drvOpGetThermalType` returns them too. `8f69771aea` adds measured ARM, core and V3D clocks, and `a669f3070c` adds the board name from the firmware revision code. |
| `8f69771aea` | `power/cpufreq/bcm2835_cpufreq` (first version) | The firmware runs the ARM at maximum only for its boot-time turbo period. About two minutes after power-on it drops the ARM from 1500 to 600 MHz and the core clock from 500 to 200 MHz for good, unless the OS asks for a rate (Linux's cpufreq does). Everything after two minutes therefore ran at 40 % CPU clock. This first version pinned the maximum in low-latency mode; QuakeSpasm demo1 at 1920×1080 went 19–27 → 30–43 fps. The V3D driver asks for the maximum core clock while the GPU is on. **The policy was replaced by the next entry.** |
| `5d8bcb1171` | cpufreq: the ARM clock follows the load; no firmware turbo | The scheduler's per-CPU performance requests move a level, as `intel_pstates` does. A thread checks every 50 ms and asks for the lowest of minimum/750/1000/1200 MHz/maximum that covers it, lowering only after four agreeing checks. With turbo on, the firmware answers every ARM rate with the maximum, so turbo is switched off at start and never requested (v3d, rpivid and bcm2711_bt skip it too). Turbo had also held the core clock at maximum, and at 200 MHz HEVC lost a fifth of its rate, so the core clock is set to maximum once. A 0.7 s burst from idle runs 7 % slower than at full speed; games and HEVC are unchanged. |
| `fb4461ed54` | `busses/random/bcm2711_rng200` | The RNG200 (`brcm,bcm2711-rng200`) feeds the random module's pool like the other random controllers. It is reset and enabled at attach (as Linux's `iproc_rng200_restart()`) and checked to produce words. A periodic timer then queues a DPC that drains up to 16 FIFO words, and a failed health test restarts it. |

---

## 12. Media Kit

| commit | change | what and why |
|---|---|---|
| `c41702df18` ★ | `BTimeSource` conversions in double precision | `RealTimeFor()` and `PerformanceTimeFor()` converted with a `float`, which holds 2^24 µs exactly. With a drift other than 1.0 they stopped the program in the debugger whenever a time lay more than 16.7 s from the last published one, as with a stalled or restarted time source. MediaPlayer's video producer hit it once in a 15-minute soak. |

---

## 13. Build system, image profiles, package repository

Image-profile edits (`build/jam/images/definitions/minimum` and `regular`) and boot-module lists
(`build/jam/packages/Haiku`) come with the drivers that need them and are listed in their sections.
Changes of their own:

| commit | change | what and why |
|---|---|---|
| `b258d90d71` | arm64 images use the haiku-pi package repository | Haiku's servers carry no arm64 HaikuPorts repository. `RepositoryRules` now takes an architecture's own repository-info template where there is one (`src/data/repository_infos/haikuports_arm64`, pointing at <https://haiku-pi.github.io/packages>, which [../scripts/publish-repo.sh](../scripts/publish-repo.sh) publishes). `pkgman refresh` and `install` work out of the box over HTTPS. The mechanism is generic; the URL is the fork's. |
| `59b38453cc` | `libmidi.so` in the regular image only with fluidlite | As in the test image already. (The same commit lists the audio packages; see the table below.) |
| `18e0d2a9db` | `KDEBUG_LEVEL` 1 | See section 2. |

Since the arm64 repository is not upstream's, building an image needs `-sHAIKU_NO_DOWNLOADS=1` with
the packages staged in `download/`. [TRY-IT.md](TRY-IT.md) has the build steps.

---

## 14. Other

| commit | change | what and why |
|---|---|---|
| `0ef01f9d31` | `drivers/gpio/bcm2835_gpio` | `gpio/bcm2835/<n>` for `brcm,bcm2711-gpio`. Reading lists each pin's function, level and pull; writing text commands (`in <pin>`, `out <pin> <0\|1>`, `alt <pin> <0-5>`, `pull <pin> <none\|up\|down>`) changes them, so shell scripts can use it. Haiku has no GPIO framework yet, so this is a stopgap interface. |
| `8a10e472dc` ★ | `tests/system/network/tcp_throughput` | Sends or receives TCP data against a sink or source (socat) and reports the rate; used to measure network drivers. |

---

## Outside this repository

Some of the port lives in other trees: the haiku-pi/mesa fork (the Haiku winsys for v3d/v3dv,
OpenGL ES contexts in `BGLView`, a Vulkan WSI for Haiku windows) and patches the coordination repo
carries in [../patches/](../patches/). Those patches are for U-Boot (GENET transmit delay for
`rgmii-rxid`, BGR pixel order, no 1 ms wait after each EMMC2 command), FFmpeg (the rpivid hwaccel), SDL2, the Vulkan loader, Firefox,
HaikuWebKit, CPython, Rust and the game ports. They reach the Haiku image as the binary packages in
the table below.

---

## Appendix: arm64 package-repository changes

`build/jam/repositories/HaikuPorts/arm64` lists the binary packages an arm64 image is built from.
Upstream lists only a bootstrap set. Each row below adds or bumps packages that the coordination
repo builds and publishes. The notes say what a bump fixed, where it fixed something.

| commit | packages | note |
|---|---|---|
| `2cd8e0172d` | mesa, glu | Enables jam's mesa and glu features (GLTeapot, GLInfo, libglut, the GL screen savers). |
| `59b38453cc` | libogg, libvorbis, fluidlite; any-arch fonts, sounds, soundfont, user guide, welcome | Enables the libvorbis and fluidlite features, so libmidi and the Media preferences build. |
| `8863edb50b` | bzip2, gzip, tar, unzip; any-arch intel/ralink/realtek WiFi firmware | Required by the regular `haiku` package. |
| `fb08bb7851` | libsdl2 | |
| `a5c947c552` | ffmpeg6 | Enables the ffmpeg media plugin. |
| `0c7a0c1d0b` | zstd | Without the zstd feature packagefs could not read the zstd-compressed any-arch packages, and package_daemon reported their dependents unsatisfiable. |
| `568ddfe0ec` | NetSurf and its libraries; curl 8.22 with OpenSSL 3 | Replaces the bootstrap curl, which has no TLS. |
| `391b5c1504` | HaikuWebKit 1.10 and its libraries (brotli, dav1d, lcms, libavif, libwebp, libxml2, libxslt, sqlite, woff2, …) | Enables WebPositive and the WebP and AVIF translators. |
| `03fa563d38` | icu74_bootstrap shim | **Superseded** by `5f8581cdae`. |
| `cdec11abc7` | libsdl2 2.32.10-2 | Vulkan windows on Haiku ([../patches/libsdl2/](../patches/libsdl2/)). |
| `08d48f271e` | python3.14 3.14.8 | |
| `6b8ae096fb` | mesa 26.2.0-2, libsdl2 2.32.10-3 | `BGLView` makes OpenGL ES contexts, and SDL asks for them. |
| `1fa21827b6` | mesa 26.2.0-3 | Programs may exit with GL views still alive. |
| `0c39179030` | firefox 157.0.1-1 | |
| `415b160d18` | libsdl2 2.32.10-5 | SDL's Haiku looper thread ran window-event handlers concurrently with the application thread, so fullscreen starts crashed with "double free" in `SDL_AddDisplayMode()`. The handlers now run in `SDL_PumpEvents()`, and display modes keep their own copy. |
| `167ad048f9` | openarena 0.8.8-1, supertuxkart 1.5-1 | Added to images only with `-sHAIKU_PI_GAMES=1`. |
| `88fd22f669` | python3.14 3.14.8-2, libedit, ncurses6_bootstrap shim | readline on libedit, `_curses`/`_curses_panel`. The shim makes the terminfo path the ncurses6 bootstrap package expects exist. |
| `da96c5cde3` | firefox 157.0.1-3 | Firefox's GL provider loaded `libGL.so` (the `_devel` link) and created a desktop GL 2.1 context, too old for WebGL. It now loads `libGL.so.1` and creates an OpenGL ES context when desktop GLSL is older than 1.50. WebGL 1 and 2 on the V3D ([../patches/firefox/](../patches/firefox/)). |
| `5f8581cdae` | icu74 74.1-1 | ICU with its data in libicudata, as Linux distributions build it, replacing the bootstrap ICU and its shim. |
| `6aa2792481` | mesa 26.2.0-5, glu 9.0.3-5 | Rebuilt with a toolchain that links libgcc_s: libEGL_mesa and libGLU had private unwinders for the C++ exceptions they throw and catch. The package now also ships the V3DV ICD manifest (`add-ons/vulkan/icd.d`); before, Vulkan worked only from a staging tree. |
| `a4f0d50da1` | firefox 157.0.1-4 (zstd), openarena 0.8.8-2 + openarena_data_1..5, supertuxkart 1.5-2 + supertuxkart_data_1..3 | Firefox zstd-compressed (112 → 102 MB) and the games' data split into parts, each under GitHub's 100 MiB file limit: all three published (owner, 10-21). |
| `0c09391cfc` | ncurses6 6.6-1 | Built with the packaged prefix ([../scripts/build-ncurses.sh](../scripts/build-ncurses.sh)), so the terminfo database is `/boot/system/data/terminfo`. It replaces the bootstrap ncurses6 and the shim that gave it its database path. |

`e98b67a5bd` and `be395e19f4` (section 8) also bump ffmpeg6, to 6.1.6-2 and 6.1.6-3.
