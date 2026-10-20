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

| ID | Milestone | Exit criterion | State (2026-10-19) |
|---|---|---|---|
| H0 | Infrastructure | coord repo + forks on GitHub, bench scripts (flash lane, SD cycle, QEMU), crons | ✅ |
| H1 | Build + reference boot | `@minimum-mmc` arm64 image boots to Tracker on QEMU virt | ✅ 10-17 |
| H2 | Pi boot chain | Pi SD image: U-Boot starts `haiku_loader.efi`, loader menu/log on UART | ✅ 10-18 |
| H3 | Kernel early boot on Pi | kernel reaches the kernel debugger / init on Pi UART (GIC-400, arch timer, PL011, memory map, caches) | ✅ 10-18 |
| H4 | SD boot volume → Desktop | emmc2 SDHCI attached via FDT, BFS boot volume mounted, app_server on the EFI GOP framebuffer, Tracker on HDMI. **First testable build → tell the owner** | ✅ 10-18 (owner told); the regular image since 10-19 |
| H5 | SMP | 4 cores via PSCI/spin-table, stable under load | ✅ 4 cores; the CPU stall under load (an LL/SC livelock) fixed 10-19, 20-min soak clean |
| H6 | PCIe + USB | brcmstb PCIe host + VL805 xHCI (firmware reset via mailbox); keyboard + mouse | ✅ drivers, USB 3 storage ~90 MB/s; keyboard/mouse by hand: owner |
| H7 | Ethernet | BCM2711 GENET v5 driver (BSD-derived via Haiku's FreeBSD compat layer) | ✅ 603 up / 757 down Mbit/s |
| H8 | NFS | NFSv4 client (Haiku `nfs4`) mounting the bench export; netboot-to-NFS-root optional | ✅ client; network boot 10-20: boot volume over the network as a remote disk, no SD card writing (an NFS root does not fit Haiku's boot, [design/netboot.md](design/netboot.md)) |
| H9 | SD performance | ADMA2, high-speed modes, correct DMA addressing (bus vs CPU physical) | ✅ UHS-I DDR50, 31 MB/s |
| H10 | GPIO + thermal + mailbox | `/dev` interfaces for GPIO, SoC temperature/clocks via VideoCore mailbox | ✅ (+ cpufreq: ARM 1.5 GHz held; hardware RNG feeds the random pool) |
| H11 | WiFi | BCM43455 over SDIO (brcmfmac-style, firmware load) via the FreeBSD/OpenBSD-derived stack | ✅ 10-18 WPA2 + DHCP; 37 up / 46 down Mbit/s |
| H12 | GPU | KMS-like modesetting via firmware + V3D 4.2 via Mesa (`v3d` gallium) — accelerated OpenGL | ✅ GL 2.1 / GLES 3.1 on the V3D; QuakeSpasm 30–43 fps at 1080p, Quake II 81–89 at 720p; plane flips / async queues open |
| H13 | Stability + performance | soak tests, boot time, I/O and graphics benchmarks vs the Phoenix port | ✅ boot bench 10/10, 20-min load soak; ongoing |
| H14 | arm64 package farm | There is no official HaikuPorts repository for arm64 (only riscv64/x86_64/x86_gcc2, checked 2026-10-18), and the build references 71 bootstrap packages. Build HaikuPorts with haikuporter natively (QEMU virt with many CPUs, or the Pi itself) into our own repo: Mesa, WebPositive/HaikuWebKit, SDL2, games, dev tools — what the GPU and showcase work need | 🔶 81 packages of ours incl. HaikuWebKit (WebPositive in the image); our repo works with pkgman on the bench; public hosting: owner |

Also done beyond the list: Vulkan (V3DV, a Haiku WSI, SDL2's Vulkan path, vkQuake), HEVC decoding on the
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
