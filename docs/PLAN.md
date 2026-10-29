# Haiku on the Raspberry Pi 4 — plan

Goal (owner, 2026-10-17): Haiku on the Pi 4 at least as complete as the Phoenix-RTOS port on the same
bench: desktop on HDMI with GPU acceleration, SMP, SD card, USB keyboard/mouse, Ethernet, WiFi, NFS,
GPIO, thermal readouts — stable and fast. Fully autonomous work; progress pushed to github.com/haiku-pi.

## Starting point (upstream hrev60262, 2026-10-17)

- arm64 is a working Haiku port on QEMU `virt`: EFI loader, GICv2/v3, PL011, FDT, PCI ECAM,
  virtio, xHCI, SMP (PSCI and spin-table in the loader). Our build boots to Tracker there.
- Nothing Pi-specific exists: no board in `build/jam/board`, SDHCI attaches only via PCI/ACPI,
  no BCM2711 GENET, PCIe (brcmstb), mailbox, VC4/V3D, GPIO or thermal drivers.
- `docs/develop/kernel/arch/arm/rpi4.rst` sketches the boot chain we use.

## Boot chain

Pi firmware (`start4.elf`, `config.txt`) → U-Boot (`rpi_4_defconfig`, provides UEFI + the DTB) →
`EFI/BOOT/BOOTAA64.EFI` = `haiku_loader.efi` → kernel + modules from the BFS partition.
SD layout: MBR, p1 FAT32 (type 0x0c/0xef, firmware + U-Boot + EFI), p2 BFS (0xeb).

## Milestones

| ID | Milestone | Exit criterion | State (2026-10-29) |
|---|---|---|---|
| H0 | Infrastructure | coord repo + forks on GitHub, bench scripts (flash lane, SD cycle, QEMU), crons | ✅ |
| H1 | Build + reference boot | `@minimum-mmc` arm64 image boots to Tracker on QEMU virt | ✅ 10-17 |
| H2 | Pi boot chain | Pi SD image: U-Boot starts `haiku_loader.efi`, loader menu/log on UART | ✅ 10-18 |
| H3 | Kernel early boot on Pi | kernel reaches the kernel debugger / init on Pi UART (GIC-400, arch timer, PL011, memory map, caches) | ✅ 10-18 |
| H4 | SD boot volume → Desktop | emmc2 SDHCI attached via FDT, BFS boot volume mounted, app_server on the EFI GOP framebuffer, Tracker on HDMI. **First testable build → tell the owner** | ✅ 10-18 (owner told); the regular image since 10-19 |
| H5 | SMP | 4 cores via PSCI/spin-table, stable under load | ✅ 4 cores; the CPU stall under load (an LL/SC livelock) fixed 10-19, 20-min soak clean |
| H6 | PCIe + USB | brcmstb PCIe host + VL805 xHCI (firmware reset via mailbox); keyboard + mouse | ✅ drivers, USB 3 storage ~80–90 MB/s; the onboard hub's ring replays (VL805) fixed 10-24; keyboard/mouse by hand: owner |
| H7 | Ethernet | BCM2711 GENET v5 driver (BSD-derived via Haiku's FreeBSD compat layer) | ✅ ~915 Mbit/s each way (KDEBUG level 1, 10-20) |
| H8 | NFS | NFSv4 client (Haiku `nfs4`) mounting the bench export; netboot-to-NFS-root optional | ✅ client; network boot 10-20: boot volume over the network as a remote disk, no SD card writing (an NFS root does not fit Haiku's boot, [design/netboot.md](design/netboot.md)) |
| H9 | SD performance | ADMA2, high-speed modes, correct DMA addressing (bus vs CPU physical) | ✅ UHS-I DDR50, 43 MB/s (bus 50) |
| H10 | GPIO + thermal + mailbox | `/dev` interfaces for GPIO, SoC temperature/clocks via VideoCore mailbox | ✅ (+ cpufreq: ARM 1.5 GHz held; hardware RNG feeds the random pool) |
| H11 | WiFi | BCM43455 over SDIO (brcmfmac-style, firmware load) via the FreeBSD/OpenBSD-derived stack | ✅ 10-18 WPA2 + DHCP; 37 up / 46 down Mbit/s |
| H12 | GPU | KMS-like modesetting via firmware + V3D 4.2 via Mesa (`v3d` gallium) — accelerated OpenGL | ✅ GL 2.1 / GLES 3.1 on the V3D; QuakeSpasm 30–43 fps at 1080p, Quake II 81–89 at 720p; plane flips / async queues open |
| H13 | Stability + performance | soak tests, boot time, I/O and graphics benchmarks vs the Phoenix port | ✅ boot bench 10/10, 20-min load soak, 15-min application soak (10-24: 0 crashes); SD boot U-Boot → desktop 21.3 → ~11 s (10-23/24), loader → desktop 7.4 → 5.6 s (10-29: serial output from the UART interrupt); memory/string routines 2–15×, TLS 2×, user-copy 3.7× (10-24); threads 75 → 50 µs (10-29); ongoing; scheduler: busy threads no longer stuck on one single-CPU core (10-29, haiku 2486477fab) |
| H14 | arm64 package farm | There is no official HaikuPorts repository for arm64 (only riscv64/x86_64/x86_gcc2, checked 2026-10-18), and the build references 71 bootstrap packages. Build HaikuPorts with haikuporter natively (QEMU virt with many CPUs, or the Pi itself) into our own repo: Mesa, WebPositive/HaikuWebKit, SDL2, games, dev tools — what the GPU and showcase work need | 🔶 129 packages published (haiku-pi.github.io/packages: Firefox, the games, WebKit, Mesa, git/vim/openssh, ...); haikuporter builds ports natively on the Pi itself (10-21: hoedown 37 s, gperf 52 s); the farm still cross-builds |
| H15 | Windows programs: Wine + x86 translation | Wine 11.20 (ARM64X) + Box64 v0.4.4 (32-bit x86) + FEX-2610 (x86-64, ARM64EC) on Haiku arm64: arm64, x86 and x86-64 Windows programs, sound, OpenGL on the V3D, full-screen games at their aspect; Heroes III, Half-Life: Uplink, SimCity 3000, StarCraft, Chocolate Doom x64, OpenTTD x64 run; published as `wine wine_x86 wine_x86_64` (11.20-22, + `wine_mono` for .NET; `WINE_DOTNET_NATIVE=1` runs "Any CPU" .NET programs as Arm code; a full-screen game's display mode is a real one, scaled by the display hardware; the wineserver on kqueue; a prefix update rewrites only changed libraries; FlushProcessWriteBuffers on the kernel's team memory barrier; the wineserver signals Wine threads). Five kernel fixes on the way (shared mappings, ID registers, failed-fork panic, ...) ([design/wine-x86.md](design/wine-x86.md), [design/wine-debugging.md](design/wine-debugging.md)). Newest numbered releases only (owner, 10-21). Open: x86 memory ordering under Box64's defaults (KNOWN-ISSUES W6), ARM64EC call transitions (~0.8 µs) | 🔶 working, published |
| H16 | Photocraft (owner 10-25) | The Rust photo editor [Photocraft](https://github.com/storytold/photocraft) running on the Pi: CLI, then the egui/wgpu GUI through winit's Wayland backend on wayland_server and wgpu on V3DV; packaged. Plan: [design/photocraft.md](design/photocraft.md) | ✅ 0.17.0-1 published (10-28; upstream's newest): CLI equal to the host, GPU compositing on V3DV (unit 41, integration 97), the GUI on Haiku's Wayland server with Haiku file panels, clipboard, Open with, `.pcraft`, single instance |

Also done beyond the list: **Firefox 157** (HaikuPorts' native Haiku port, cross-built for arm64: renders the web on the Pi), SuperTuxKart, OpenArena, Python 3.14, Vulkan (V3DV, a Haiku WSI, SDL2's Vulkan path, vkQuake), HEVC decoding on the
BCM2711's decoder block (FFmpeg's `hevc_rpivid`, MediaPlayer), audio on the 3.5 mm jack (media kit), media playback (ffmpeg 6.1), HTTPS
and the WebPositive and NetSurf browsers, Bluetooth through Haiku's stack (BCM43455 over UART). See
[TRY-IT.md](TRY-IT.md) and the weekly logs in [log/](log/).

Order is flexible after H4. H5–H7 can overlap; H12 is the longest.

## Reference material

- `docs/knowledge/from-phoenix/` — the BCM2711 bring-up notes from the earlier port (caches/DMA,
  mailbox, PCIe/VL805, GENET, V3D, UART, firmware handoff).
- Other OSes: Linux (`drivers/mmc/host/sdhci-iproc.c`, `drivers/pci/controller/pcie-brcmstb.c`,
  `drivers/net/ethernet/broadcom/genet/`), FreeBSD (`sys/arm/broadcom/bcm2835/`, `bcm2838_pci.c`,
  `if_genet.c`), NetBSD (`sys/arch/arm/broadcom/`), OpenBSD (`bcmgenet`, `bwfm`).
