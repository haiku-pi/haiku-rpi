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

| ID | Milestone | Exit criterion | State (2026-11-04) |
|---|---|---|---|
| H0 | Infrastructure | coord repo + forks on GitHub, bench scripts (flash lane, SD cycle, QEMU), crons | ✅ |
| H1 | Build + reference boot | `@minimum-mmc` arm64 image boots to Tracker on QEMU virt | ✅ 10-17 |
| H2 | Pi boot chain | Pi SD image: U-Boot starts `haiku_loader.efi`, loader menu/log on UART | ✅ 10-18 |
| H3 | Kernel early boot on Pi | kernel reaches the kernel debugger / init on Pi UART (GIC-400, arch timer, PL011, memory map, caches) | ✅ 10-18 |
| H4 | SD boot volume → Desktop | emmc2 SDHCI attached via FDT, BFS boot volume mounted, app_server on the EFI GOP framebuffer, Tracker on HDMI. **First testable build → tell the owner** | ✅ 10-18 (owner told); the regular image since 10-19 |
| H5 | SMP | 4 cores via PSCI/spin-table, stable under load | ✅ 4 cores; the CPU stall under load (an LL/SC livelock) fixed 10-19, 20-min soak clean |
| H6 | PCIe + USB | brcmstb PCIe host + VL805 xHCI (firmware reset via mailbox); keyboard + mouse | ✅ drivers, USB 3 storage ~80–90 MB/s; the onboard hub's ring replays (VL805) fixed 10-24; keyboard and mouse checked by hand (owner, 10-25) |
| H7 | Ethernet | BCM2711 GENET v5 driver (BSD-derived via Haiku's FreeBSD compat layer) | ✅ ~915 Mbit/s each way (KDEBUG level 1, 10-20) |
| H8 | NFS | NFSv4 client (Haiku `nfs4`) mounting the bench export; netboot-to-NFS-root optional | ✅ client; network boot 10-20: boot volume over the network as a remote disk, no SD card writing (an NFS root does not fit Haiku's boot, [design/netboot.md](design/netboot.md)) |
| H9 | SD performance | ADMA2, high-speed modes, correct DMA addressing (bus vs CPU physical) | ✅ UHS-I DDR50, 43 MB/s (bus 50) |
| H10 | GPIO + thermal + mailbox | `/dev` interfaces for GPIO, SoC temperature/clocks via VideoCore mailbox | ✅ (+ cpufreq: ARM 1.5 GHz held; hardware RNG feeds the random pool) |
| H11 | WiFi | BCM43455 over SDIO (brcmfmac-style, firmware load) via the FreeBSD/OpenBSD-derived stack | ✅ 10-18 WPA2 + DHCP; 37 up / 46 down Mbit/s |
| H12 | GPU | KMS-like modesetting via firmware + V3D 4.2 via Mesa (`v3d` gallium) — accelerated OpenGL | ✅ GL 2.1 / GLES 3.1 on the V3D, Vulkan 1.3; timedemos 11-03: QuakeSpasm 41 fps at 1080p, Quake II 102 at 720p; concurrent queues (stage 7, image-2026-11-03b) and plane flips (stage 6, image-2026-11-03c) done |
| H13 | Stability + performance | soak tests, boot time, I/O and graphics benchmarks vs the Phoenix port | ✅ boot bench 10/10, 20-min load soak, 15-min application soak (10-24: 0 crashes); SD boot U-Boot → desktop 21.3 → ~11 s (10-23/24), loader → desktop 7.4 → 5.6 s (10-29: serial output from the UART interrupt; 5.4–5.6 s on the 11-03 release cards); the freeze after a long power-off fixed (11-02, d1a616afac; 10 of 10 cold SD boots 11-03); memory/string routines 2–15×, TLS 2×, user-copy 3.7× (10-24); threads 75 → 50 µs (10-29); ongoing; scheduler: busy threads no longer stuck on one single-CPU core (10-29, haiku 2486477fab) |
| H14 | arm64 package farm | There is no official HaikuPorts repository for arm64 (only riscv64/x86_64/x86_gcc2, checked 2026-10-18), and the build references 71 bootstrap packages. Build HaikuPorts with haikuporter natively (QEMU virt with many CPUs, or the Pi itself) into our own repo: Mesa, WebPositive/HaikuWebKit, SDL2, games, dev tools — what the GPU and showcase work need | 🔶 154 packages published (11-03; haiku-pi.github.io/packages: Firefox, the games, WebKit, Mesa, Wine, GCC 16.2, numpy, git/vim/openssh, ...); haikuporter builds ports natively on the Pi itself (10-21: hoedown 37 s, gperf 52 s); the farm still cross-builds |
| H15 | Windows programs: Wine + x86 translation | Wine 11.21 (ARM64X; 11.20 until 11-01) + Box64 v0.4.4 (32-bit x86) + FEX-2610 (x86-64, ARM64EC) on Haiku arm64: arm64, x86 and x86-64 Windows programs, sound, OpenGL on the V3D, full-screen games at their aspect; Heroes III, Half-Life: Uplink, SimCity 3000, StarCraft, Chocolate Doom x64, OpenTTD x64 run; published as `wine wine_x86 wine_x86_64` (11.21-2 since 11-02, + `wine_mono` for .NET; `WINE_DOTNET_NATIVE=1` runs "Any CPU" .NET programs as Arm code; a full-screen game's display mode is a real one, scaled by the display hardware; the wineserver on kqueue; a prefix update rewrites only changed libraries; FlushProcessWriteBuffers on the kernel's team memory barrier; the wineserver signals Wine threads). Five kernel fixes on the way (shared mappings, ID registers, failed-fork panic, ...) ([design/wine-x86.md](design/wine-x86.md), [design/wine-debugging.md](design/wine-debugging.md)). Newest numbered releases only (owner, 10-21). Open: x86 memory ordering under Box64's defaults (KNOWN-ISSUES W6), ARM64EC call transitions (~0.8 µs) | 🔶 working, published |
| H16 | Photocraft (owner 10-25) | The Rust photo editor [Photocraft](https://github.com/storytold/photocraft) running on the Pi: CLI, then the egui/wgpu GUI through winit's Wayland backend on wayland_server and wgpu on V3DV; packaged. Plan: [design/photocraft.md](design/photocraft.md) | ✅ 0.17.0-1 published (10-28; upstream's newest): CLI equal to the host, GPU compositing on V3DV (unit 41, integration 97), the GUI on Haiku's Wayland server with Haiku file panels, clipboard, Open with, `.pcraft`, single instance |

Also done beyond the list: **Firefox 157** (HaikuPorts' native Haiku port, cross-built for arm64: renders the web on the Pi), SuperTuxKart, OpenArena, Python 3.14, Vulkan (V3DV, a Haiku WSI, SDL2's Vulkan path, vkQuake), HEVC decoding on the
BCM2711's decoder block (FFmpeg's `hevc_rpivid`, MediaPlayer), audio on the 3.5 mm jack (media kit), media playback (ffmpeg 6.1), HTTPS
and the WebPositive and NetSurf browsers, Bluetooth through Haiku's stack (BCM43455 over UART). See
[TRY-IT.md](TRY-IT.md) and the weekly logs in [log/](log/).

Order is flexible after H4. H5–H7 can overlap; H12 is the longest.

## Backlog, in order (owner 2026-11-01)

| # | Item | Why this place | Done when |
|---|---|---|---|
| 1 | **C1 boot freeze** (KNOWN-ISSUES C1) — DONE 11-03: 10 of 10 cold SD boots of image-2026-11-03 alive | Stability first: up to 2 in 3 cold SD boots freeze | the cold SD rate of the fixed image is 0 in a series long enough to tell (≥ 10 cold boots) |
| 2 | **Quick wins already built**: Wine 11.21 (patches rebased), DT_RELR, thread-stack reuse, boot-log cleanups (ACPI on a device-tree board, PS/2 driver) → a release with the W15 fix | Each needs only a warm Pi session; they fill the gaps between cold-boot runs | measured on the Pi, published, released |
| 3 | **H17 Toolchain to GCC 16.2** — DONE: first 16.2 release image-2026-11-03b (11-03); image-2026-11-03 was the last 13.3 build (upstream Haiku stays on 13.3.0) | Before native packages, so the native compiler is built once, on the new version | buildtools fork: Haiku's GCC patches on 16.2 (+ binutils to its newest release); the image, kernel, the GL stack and our packages rebuilt with it; Pi gates (boot bench, gpu-it, mega-smoke) equal to 13.3's; the delta from upstream Haiku's toolchain recorded (the weekly buildtools merge then goes onto it); **last step (owner 11-01): a GCC 13.3 vs 16.2 performance comparison** on the same Pi and scenes, both builds measured fresh in one series — Quake timedemos (QuakeSpasm, Yamagi Quake II, vkQuake, OpenArena), SuperTuxKart, glmark2, boot time, Firefox start, a Wine game, CPU microbenchmarks — written into the docs (design/gcc16.md, HARDWARE-SUPPORT) |
| 3b | **H17b LTO study** (owner 11-01) — DONE 11-02: no gain, dropped (owner); design/lto.md | After 3, on GCC 16.2, so the LTO effect is measured on one compiler | feasibility (jam and the ports build with `-flto`: libroot, libbe, app_server, Tracker, the add-ons that matter, then Mesa, ffmpeg, SDL2, Python, the Quakes, SuperTuxKart; Firefox's own LTO option; the kernel and boot loader last, if at all) and a Pi A/B of the same image with and without LTO — Quake timedemos, glmark2, SuperTuxKart, boot time, app start, Firefox start and Speedometer, Python/SQLite microbenchmarks, binary sizes, build time and memory; adopted where it measurably helps; written up in design/gcc16.md |
| 4 | **H18 Developing on the Pi** — 11-03: build tools and native gcc 16.2 published, Pi 23/23 and 24/24 (design/dev-tools.md, native-gcc.md); `haiku_devel` published with each release since image-2026-11-03b; **11-04: haikuporter recipes (hoedown 53 s, gperf 45 s with a C17 recipe fix) built on the Pi with gcc 16.2.0** (native-gcc.md); the repository holds `gcc`, `binutils`, `make`, `cmake`, `ninja`, `pkgconfig`, `meson`, the `_devel` packages as arm64 packages | Software can be compiled inside Haiku (haikuporter builds on the Pi with gcc 16.2) | `pkgman install gcc make cmake` on a fresh image; hello-world C/C++, a CMake project and a haikuporter recipe build natively on the Pi |
| 5 | **H19 Python: numpy** — DONE 11-03: package 2.5.4-2 published; native pip build on the Pi 24 min, 20969 tests 0 failed (design/numpy.md) | Needs item 4 to build from source on the Pi (`pip install numpy`: meson-python, a C/C++ compiler; BLAS optional) | numpy built two ways — natively with pip on the Pi and as a cross-built `numpy_python314` package — imports and passes `numpy.test()` (or its documented subset) on the Pi |
| 6 | **H20 Performance, next round** — ranked 11-03 ([design/perf-round-h20.md](design/perf-round-h20.md)): C0 desktop-session profile (done 11-03; fixes on rpi4/mesa, not yet released: `profile -a` f6c52282df, the ARM clock under spread loads 83db805485, the v3d shader cache hash ebf1ee1ff1b), C1 DT_RELR Firefox cold A/B, C2 cold-start prefetch, C4 SD write path, C3 boot phases | Standing (owner 10-23/24): system-wide, boot and runtime | a measured list ranked by gain/effort, then done in that order; candidates so far: WiFi SDIO DMA (F4: SDIO is PIO, CPU-bound), GPU scanout planes for full-screen GL (stage 6, ≤ 15 %), GL_MESA_map_buffer_client_pointer for Wine's 32-bit OpenGL, Firefox's first-video warm-up (G2), app start (DT_RELR, prelinking/prefetch), Box64/FEX settings per game, a profile of a desktop session with `profile`/`pmustat` |
| 6b | **F2 GPU stages 6 + 7** (owner 11-02) — DONE: stage 7 in image-2026-11-03b, stage 6 in image-2026-11-03c (haiku db79f7850d, keying only under overlays) | Full-screen GL flips on firmware planes + YCbCr overlays (stage 6), async per-unit V3D queues (stage 7); implemented on branches `stage6`/`stage7` 11-02 | the Pi gates of design/gpu-stage6.md and design/gpu-stage7.md pass; merged into `rpi4`, rebased on the GCC 16.2 build |
| 7 | **H21 VideoCore services over VCHIQ, BSD-licensed route** (owner 11-02: last in the queue) | H.264 hardware decode, then H.264 encode, camera (CSI) + ISP, JPEG, through the firmware's MMAL components; only non-GPL code: FreeBSD's VCHIQ port (Broadcom BSD-3/GPL-2 dual licence, taken as BSD-3) and Broadcom's BSD-3 libmmal/libvchiq/VCOS from raspberrypi/userland; Linux's GPL-only vchiq-mmal/bcm2835-codec/vc-sm-cma as behaviour reference only | design/hw-video-decode.md §0a: (1) VCHIQ kernel driver with `/dev/vchiq`; (2) libmmal ported; (3) media-kit H.264 decoder add-on (MediaPlayer/WebPositive use it), copies first, zero-copy + stage-6 overlays later; (4) encode, camera/ISP, JPEG as follow-ups. Estimated 2.5–4 weeks for (1)–(3) |

## Reference material

- `docs/knowledge/from-phoenix/` — the BCM2711 bring-up notes from the earlier port (caches/DMA,
  mailbox, PCIe/VL805, GENET, V3D, UART, firmware handoff).
- Other OSes: Linux (`drivers/mmc/host/sdhci-iproc.c`, `drivers/pci/controller/pcie-brcmstb.c`,
  `drivers/net/ethernet/broadcom/genet/`), FreeBSD (`sys/arm/broadcom/bcm2835/`, `bcm2838_pci.c`,
  `if_genet.c`), NetBSD (`sys/arch/arm/broadcom/`), OpenBSD (`bcmgenet`, `bwfm`).
