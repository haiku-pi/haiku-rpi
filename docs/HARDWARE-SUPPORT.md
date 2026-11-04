# Haiku on the Raspberry Pi 4 (BCM2711): hardware support matrix

**Updated 2026-11-04** (the weekly logs to 2026-11-03 23:15; the newest release is image-2026-11-03c). Each
row keeps the date of its measurement; a number not measured again since keeps its old date. This is the reference for "what works, how
well, and what is missing", one table per area. How to build and boot the image is in [TRY-IT.md](TRY-IT.md),
open defects are in [KNOWN-ISSUES.md](KNOWN-ISSUES.md), and the test bench behind every number below is
described in [LAB-SETUP.md](LAB-SETUP.md). Day-by-day progress is in [log/](log/), and the milestones are in
[PLAN.md](PLAN.md).

All measurements come from one board, a Raspberry Pi 4 Model B with 4 GB (rev 1.1), unless a row says
otherwise. Since 2026-10-20 (23:50) the kernel is built with `KDEBUG_LEVEL 1`; numbers taken earlier ran at level
2, Haiku's development setting, and some of them (Ethernet in particular) are lower for that reason. From
image-2026-11-03b the system is built with GCC 16.2 (13.3 before); a 13.3/16.2 A/B on 2026-11-02 found it
performance-neutral ([design/gcc16.md](design/gcc16.md)).

**Paths.** Driver paths are in the Haiku fork ([haiku-pi/haiku](https://github.com/haiku-pi/haiku),
branch `rpi4`, checked out as `sources/haiku`). A path starting with `drivers/`, `busses/`, `bus_managers/`,
`generic/` or `power/` is relative to `src/add-ons/kernel/`. "Upstream" means the code existed in Haiku
before this port, and the rpi4 branch carries fixes to it (named by their commit subjects).

**Status legend:**
- ✅ **works**: runs on the Pi, measured, in the regular image.
- 🟡 **partial**: works, but a named part is missing or has not been checked by hand.
- ⬜ **none**: no driver in the tree.

## 1. SoC, CPU, SMP and clocks

| Component | Haiku driver | Status | Measured (date) | Limitations / missing |
|---|---|---|---|---|
| 4 × Cortex-A72, EL2 → EL1 entry | upstream arm64 kernel (`src/system/kernel/arch/arm64/`) and EFI loader (`src/system/boot/platform/efi/arch/arm64/`); fixes: "efi/arm64: set up EL1 after dropping from EL2; flush spin-table release", "efi/arm64: let userland read the counters after dropping from EL2" | ✅ | About shows "4 Processors: ARM Cortex-A72 @ 1.50 GHz" (10-20) | The A72 has no LSE atomics. Kernel spin-waits sleep in WFE ("arm64: wait in WFE, not by polling"), which fixed a CPU livelock that stalled CPUs for up to 760 ms |
| SMP (spin-table release from the loader) | upstream, + "efi/arm64: clean the data cache before releasing secondary CPUs" | ✅ | boot bench 10/10 with no watchdog (10-19); 20-minute load soak with no stall (10-19) | — |
| CPU clock (ARM) | `power/cpufreq/bcm2835_cpufreq` | ✅ | 600–1500 MHz, follows the load (and, from image-2026-11-04, the cores' total load: short programs spread over the cores start at full clock, fork+exec 4.7 ms instead of 6.6–8.0): a thread asks the firmware every 50 ms for the lowest of 600/750/1000/1200/1500 MHz that covers the scheduler's request (10-20) | Turbo is never requested: with turbo on, the firmware answers every rate with 1500 MHz. The firmware still throttles when the chip is hot. Without the module, the firmware dropped the ARM to 600 MHz about 2 minutes after power-on (10-19). Up to image-2026-11-03c a load spread thinly over the four cores (a chain of short programs) kept the clock at 750–1200 MHz; fixed on rpi4 after that release (KNOWN-ISSUES F10) |
| Core (VPU/AXI) clock | `bcm2835_cpufreq`, `v3d`, `bcm2711_bt` | ✅ | set to its maximum (500 MHz) once at start; without that it idles at 200 MHz, which cost HEVC decoding a fifth of its rate (10-20) | — |
| CPU frequency report | "arm64: the CPU clock, measured with the PMU cycle counter" | ✅ | measured against the generic timer (10-20) | — |
| VideoCore property mailbox | `generic/bcm2835_mailbox` | ✅ | used by SD, thermal, display, V3D, rpivid, PCIe (VL805), cpufreq, WiFi/Bluetooth power lines | — |
| Board identification | `drivers/power/bcm2835_thermal` | ✅ | "Raspberry Pi 4 Model B rev 1.1, 4096 MB, BCM2711", from the firmware's revision code (10-20) | — |

## 2. Memory and MMU

| Component | Haiku driver | Status | Measured (date) | Limitations / missing |
|---|---|---|---|---|
| MMU, page tables | upstream (`VMSAv8TranslationMap`) + "arm64: map kernel stacks accessed and dirty from the start", "arm64: clear the empty TTBR0 table" (d1a616afac: the freeze in the first minutes after a long power-off, an upstream regression; from image-2026-11-02b) | ✅ | About reports 3956 MiB on the 4 GB board (10-20); 10 of 10 cold boots after 30 minutes off (11-03) | arm64 keeps the access flag and the dirty state in software (the A72 has no hardware support for them). Only the 4 GB board has run the port |
| Cache maintenance for non-coherent DMA | "arm64: add data cache range maintenance helpers" | ✅ | used by SDHCI, GENET, V3D, rpivid | — |
| DMA address windows | FDT bus manager: `get_dma_window()`, "fdt: translate "reg" addresses through the parent buses' "ranges"" | ✅ | SD/emmc2 window 0xC0000000 / 1 GiB from `dma-ranges` (10-18) | PCIe DMA is limited to below 3 GiB (USB buffers are allocated there) |
| Kernel debug level | "kernel: KDEBUG_LEVEL 1" | ✅ | default since 10-20 (23:50). Level 2 → 1: TCP upload 600 → 914 Mbit/s | — |

## 3. Interrupts and timers

| Component | Haiku driver | Status | Measured (date) | Limitations / missing |
|---|---|---|---|---|
| GIC-400 (GICv2) | upstream `src/system/kernel/arch/arm/arch_int_gicv2.cpp`; fixes: barriers ordering inter-CPU messages before the SGI, SGIs addressed by each CPU's interface mask, Linux's GIC-400 setup (priorities, active states cleared) | ✅ | boot bench 10/10 (10-19) | — |
| ARM generic timer | upstream `arch_timer.cpp`, + an ISB after timer writes and the event stream (every 152 µs) that bounds every WFE | ✅ | 20-minute soak, clocks and timers held (10-19) | — |
| Deadlock detection | "kernel: spinlock and ICI deadlock detection by time, not iterations" | ✅ | 5 s for a spinlock, 10 s for a synchronous ICI (10-20) | — |

## 4. Display (HDMI)

| Component | Haiku driver | Status | Measured (date) | Limitations / missing |
|---|---|---|---|---|
| Boot frame buffer | U-Boot's EFI GOP (`patches/u-boot/0001`: BGR pixel order) | ✅ | 1920×1080, correct colours (10-18) | — |
| Display driver (firmware planes) | `drivers/graphics/bcm2711_display` + `src/add-ons/accelerants/bcm2711_display` | ✅ | adopts the boot buffer (write-combining); EDID from the firmware; app_server prefers it over `framebuffer` (10-19) | Windowed programs present by copy or blit ([design/gpu-present.md](design/gpu-present.md)); full-screen GL and video on planes: the Overlay planes row below |
| Modes | same | ✅ | every mode up to the native one; `screenmode -l` lists 40+; a smaller mode is scaled up by the firmware's primary plane, aspect kept (10-19). SDL full screen switches modes: OpenArena at 1280×720, 46.8 fps (10-20) | The HDMI link stays at the native mode; smaller modes are scaled, not set on the link |
| Vertical retrace | same, `tools/overlays/haiku-fkms.dts` (image default) | ✅ | SMI interrupt (144): 60.00 Hz, gaps 16659–16668 µs (10-19) | Without the `haiku-fkms` overlay the firmware raises no SMI interrupt, and the driver falls back to a thread on the blocking `SET_VSYNC` call, which holds the mailbox ~16 ms per frame |
| Hardware cursor | same (firmware plane 7, 64×64 ARGB) | ✅ | scripted moves, corners (clipped), scaled modes, seen on HDMI (10-19); used with a real mouse by hand (owner, 10-25) | — |
| Overlay planes (GPU stage 6) | same (firmware planes 1–6, keyed by the desktop's alpha) | ✅ | from image-2026-11-03c: full-screen GL flipped on a plane (vsync 60.00 fps, 0 missed flips; unsynced ~130 fps), MediaPlayer's video on a plane (356 updates in 356 vblanks); games bench: off-plane cases within ±1 %, Quake II 1080p +3 %, QuakeSpasm/OpenArena 1080p −1…−2 % (11-03) | After a mode change an overlay stays black until shown again; YCbCr422 shows black (KNOWN-ISSUES F2). MediaPlayer's frames are still converted to RGB on the CPU (the ffmpeg plugin delivers B_RGB32; YCbCr output is a follow-up, [design/gpu-stage6.md](design/gpu-stage6.md) §4); rpivid's pictures are copied, not scanned out |
| Kernel debugger on HDMI | upstream `frame_buffer_update` | ✅ | KDL draws in the current mode after a mode change (10-19) | — |

## 5. GPU (V3D 4.2)

| Component | Haiku driver | Status | Measured (date) | Limitations / missing |
|---|---|---|---|---|
| Kernel driver | `drivers/graphics/v3d` (Linux v3d interface on `/dev/dri/renderD128`) | ✅ | MMU, BOs, control-list, TFU, CSD and CPU jobs, multisync, sync files, watchdog + reset (a hung job ends after 567 ms, 0 leaked BOs after a kill; 10-18); zero-copy present by importing the window bitmap (`HAIKU_IMPORT_MEMORY`); from image-2026-11-03b (GPU stage 7) the binning, render, TFU and compute queues run concurrently: 59/59 queue tests, a 30-minute soak with 0 GPU resets, +1–3 % in glmark2 and QuakeSpasm (11-03, [design/gpu-stage7.md](design/gpu-stage7.md)) | `queues serial` in the v3d driver settings is the fallback. Powered on at first open, not at boot. Needs `tools/overlays/haiku-v3d.dts` (the firmware never turns the V3D clock on without it) |
| OpenGL / OpenGL ES (Mesa `v3d`) | Mesa 26.2.6 (fork `haiku-pi/mesa`, branch `rpi4`; package 26.2.6-2 from image-2026-11-03c), libglvnd (HGL → BGLView) | ✅ | "OpenGL ES 3.1 Mesa 26.2.0", renderer V3D 4.2.14 (10-18). GL window 1000²: 105 fps (GPU blit) vs 39 (CPU copy) (10-19). glmark2-es2: 330–337 in a 800×600 window, 88–90 full screen (11-02). QuakeSpasm timedemo demo1 in a window: 202.5 fps at 640×480, 80.3 at 1280×720, 41.0 at 1920×1080 (11-03, games bench, screen saver off; a played demo stays on QuakeSpasm's 72 fps cap) | Desktop GL contexts are 2.1 (BGLView gives a compatibility context only; the V3D's desktop GL stops at 3.1, so programs that need GL 3.2, such as Quake II's GL3 renderer, do not run). ES 3.1 contexts via `BGL_CONTEXT_ES` (10-20). At 1080p QuakeSpasm is GPU-bound (~95 % busy) |
| Vulkan (Mesa `v3dv`) | same + Haiku WSI (`wsi_common_haiku.cpp`) | ✅ | Vulkan 1.3, 90 extensions; vkcube FIFO 403 fps at 640×480 (10-20); vkQuake timedemo 54.9 fps at 1280×720, 33.1 at 1920×1080 (11-03) | — |

## 6. Video decoder (rpivid, HEVC)

| Component | Haiku driver | Status | Measured (date) | Limitations / missing |
|---|---|---|---|---|
| HEVC decoder block (`codec@7eb10000`) | `drivers/video/rpivid` (`/dev/video/rpivid/0`) + libavcodec `hevc_rpivid` (ffmpeg6 6.1.6-3, `patches/ffmpeg6/`) | ✅ | 9 test streams, 2324 pictures, all bit-exact against FFmpeg's CPU decoder. 1080p 20 Mbit/s: **114.8 fps** at 4.0 ms of CPU per frame (CPU decoder on 4 threads: 25.5 fps, 127 ms). 1080p Main 10: 80.4 fps. 2160p 30 Mbit/s: **38.2 fps** (CPU: 6.0). 2160p Main 10: 23.7 fps (10-20, [design/hw-video-decode.md](design/hw-video-decode.md)) | HEVC only: Main and Main 10, 4:2:0, 32–4096 luma samples per side; anything else is decoded on the CPU. No zero-copy display (the media kit plugin converts to B_RGB32). MediaPlayer and Firefox use it with no change of their own |
| H.264 hardware decode | — | ⬜ | — | On the Pi 4, H.264 is decoded by the VideoCore firmware behind MMAL/VCHIQ; a BSD-licensed route is planned last in the backlog (PLAN H21). H.264 is decoded on the CPU (1080p, 300 frames: 6.0 s on one thread, 2.9 s on four; 10-20) |

## 7. Audio

| Component | Haiku driver | Status | Measured (date) | Limitations / missing |
|---|---|---|---|---|
| 3.5 mm jack (PWM1, GPIO 40/41) | `drivers/audio/bcm2711_pwm` (hmulti) | 🟡 | media_server's default output "Raspberry Pi headphones"; 27 MHz / 612 = 44117.647 Hz (advertised as 44100); measured 44117.657 Hz over 128 periods, 0 underruns; DMA channel 5 paced by DREQ 1 (10-19) | Not yet listened to: the measurement is the driver's, the audible check is the owner's |
| HDMI audio (HDMI0, MAI + DMA) | `drivers/audio/bcm2711_hdmi_audio` (hmulti) | 🟡 | "Raspberry Pi HDMI", 48 kHz stereo; recorded back through the capture card: 1 kHz at the level played, 48000.000 Hz, 0 underruns (10-24); the default output when present | Monitor must be connected at boot; HDMI1 not driven; [design/hdmi-audio.md](design/hdmi-audio.md) |

## 8. SD card

| Component | Haiku driver | Status | Measured (date) | Limitations / missing |
|---|---|---|---|---|
| EMMC2 SDHCI (boot card) | upstream `busses/mmc/sdhci.cpp` + `busses/mmc/sdhci_fdt.cpp` (FDT attach for `brcm,bcm2711-emmc2`), `bus_managers/mmc`, `drivers/disk/mmc` | ✅ | ADMA2, UHS-I DDR50 at 1.8 V: raw reads **42.6 MB/s**, a package through the file cache 44 MB/s (10-20); 4 KiB reads 7.1 MB/s (10-19). Writes: the bench card sustains only 6–8 MB/s (10-23, raw 1 MiB writes and BFS alike; 29–36 MB/s in 64 MiB samples on 10-20; 128 MB written and synced at 19–22 MB/s on 10-25), and reads measured 27 MB/s the same day — likely the card, much rewritten by the flash lane (the bus ran DDR50 at 1.8 V both days) | The controller's base clock is 100 MHz: SDR50 and DDR50 both top out at 50 MB/s, and SDR104 is out of reach. Fixes on the way: W1C interrupt status, 32-bit register access, one ADMA2 command per transfer, an interrupt-storm report |
| Legacy Arasan SDHCI (WiFi SDIO) | `busses/mmc/sdhci_fdt.cpp` (`brcm,bcm2835-mmc`) | ✅ | see WiFi | PIO only; shares a GIC interrupt with EMMC2 |

## 9. PCIe and USB

| Component | Haiku driver | Status | Measured (date) | Limitations / missing |
|---|---|---|---|---|
| PCIe root complex | `busses/pci/brcmstb` | ✅ | full reset + link training (U-Boot tears PCIe down), link gen 2 ×1 (10-18) | DMA below 3 GiB; USB DMA memory is non-cacheable on arm64 ("usb: on arm64, allocate DMA memory below 3 GiB and non-cacheable") |
| VL805 xHCI | upstream `busses/usb/xhci.cpp` (+ VL805 workarounds: completed ring entries cleared, TRB overfetch padding, firmware version logged — 0x0138c0 on the bench; cache maintenance for disk transfers from image-2026-11-04b); VL805 firmware check/notify through the mailbox in `brcmstb` | ✅ | USB 3 stick reads 60–81 MB/s, writes 49 MB/s with correct data (11-04; the earlier 78–90 MB/s (10-18) and 68–82 (10-24) moved corrupted data, KNOWN-ISSUES C13); 40/40 cold boots without a hub timeout (10-24; was ~1 in 10) | — |
| USB HID (keyboard, mouse) | upstream `usb_hid` | 🟡 | a Logitech K120 keyboard and a Pixart mouse enumerate and publish `/dev/input/keyboard/usb/0`, `/dev/input/mouse/usb/0` (10-20); typing and pointing checked by hand on the desktop (owner, 10-25) | Not yet checked by hand in SDL games |
| USB mass storage | upstream `usb_disk` (+ cache-line aligned buffers on arm64) | ✅ from image-2026-11-04b | raw reads repeatable and equal to Linux's on the same Pi; Haiku-written data verified under Linux (0 differing bytes in 64 MiB); BFS mkfs, mount, 329 MB copy, remount, checkfs clean; reads 60–81 MB/s, writes 49 MB/s (11-04) | **Images up to image-2026-11-04 corrupted USB disk data** (no cache maintenance in xHCI; KNOWN-ISSUES C13) |

## 10. Ethernet and network services

| Component | Haiku driver | Status | Measured (date) | Limitations / missing |
|---|---|---|---|---|
| GENET v5 + BCM54213PE PHY | `drivers/network/ether/genet` (native, `/dev/net/genet/0`) | ✅ | 1000 Mbit/s full duplex; TCP **914 up / 918 down Mbit/s** at KDEBUG level 1 (10-20, 23:50; gigabit's TCP payload ceiling is ~940). At level 2: 618 / 735 (10-19) | — |
| DHCP, DNS, NTP | upstream net_server, update-time job | ✅ | the image syncs the clock by NTP when the network comes up (10-19) | The Pi has no battery clock: before NTP the date is 1970 and HTTPS fails certificate checks |
| NFSv4 client | upstream `nfs4` | ✅ | `mount -t nfs4` of the bench export, correct `df` sizes (10-18) | A mount after boot; no NFS root (see the boot chain) |
| TLS | OpenSSL 3.5.9, curl 8.22.0 | ✅ | curl: TLS 1.3, HTTP 200, 27682 bytes in 0.25 s (10-19) | — |

## 11. WiFi

| Component | Haiku driver | Status | Measured (date) | Limitations / missing |
|---|---|---|---|---|
| BCM43455 over SDIO | `drivers/network/wlan/broadcomfmac` (OpenBSD `bwfm`) on `src/libs/compat/openbsd_wlan`, an `sdio` bus in `freebsd_network`, SDIO in `bus_managers/mmc` | ✅ | firmware 7.45.234 (linux-firmware 20260810, sha256-pinned); scan, WPA2-PSK join, DHCP; joins 3/3 (10-19); TCP **37.4 up / 46.0 down Mbit/s** (10-19), **49 / 46** (11-04; 2.4 GHz access point) | No wpa_supplicant on arm64: net_server joins WPA2-PSK through the kernel (`IEEE80211_IOC_HAIKU_JOIN`), and an unscanned network is assumed to be WPA2-PSK. SDIO runs PIO at 41.67 MHz; from the next image on, its data blocks are moved by the interrupt handler instead of a spinning thread (CPU per MiB −31/−34 %, rate the same, 11-04). Joining from Network preferences takes the same path but has not been tried by hand |

## 12. Bluetooth

| Component | Haiku driver | Status | Measured (date) | Limitations / missing |
|---|---|---|---|---|
| BCM43455 Bluetooth on the AUX mini-UART (GPIO 30–33) | `drivers/bluetooth/h4/bcm2711_bt` (`/dev/bluetooth/h4/bcm2711_bt/0`) | 🟡 | patch RAM 323/323 records acknowledged, address read, bluetooth_server registers the device; an inquiry through Haiku's DiscoveryAgent completes (10-19) and `bt_discovery` finds a discoverable laptop with its class and name (10-23); pairing by PIN from another computer works (BlueZ: bonded; 10-23); each open 7 s | `bluetooth_server` is not started at boot (as on other Haiku systems). Profiles (keyboards, mice, audio) are untested. Haiku's own command-line Bluetooth tools are broken upstream |

## 13. GPIO and buses

| Component | Haiku driver | Status | Measured (date) | Limitations / missing |
|---|---|---|---|---|
| GPIO | `drivers/gpio/bcm2835_gpio` | ✅ | pin table and text commands; pin 21 output high, low, input (10-18) | — |
| I²C, SPI, general-purpose PWM | — | ⬜ | — | No BCM2711 driver in the tree |

## 14. Thermal and power

| Component | Haiku driver | Status | Measured (date) | Limitations / missing |
|---|---|---|---|---|
| Shut down, restart | `drivers/power/bcm2835_pm` (the PM block's watchdog) | ✅ from image-2026-11-04c | restart: U-Boot again after 28–32 s, 11/11 (Deskbar's path and `shutdown -r`); shut down: board halted, 4/4 (11-04, network boots) | Before: "Shut down" ended in the kernel debugger, "Restart" did not restart. U-Boot offers no PSCI, so the firmware's watchdog does it (PSCI is used where a board has it). Power draw after the halt not measured |
| SoC temperature, throttling, clocks | `drivers/power/bcm2835_thermal` (`/dev/power/bcm2835_thermal/0`) | ✅ | 50–52 °C idle (10-18); 72–74 °C plateau in a 20-minute load soak, never throttled (10-19); 58–73 °C after the games bench's runs, throttle flags 0x0 (11-03); reports the measured ARM, core and V3D clocks | Read-out only: the firmware owns throttling |

## 15. Random numbers

| Component | Haiku driver | Status | Measured (date) | Limitations / missing |
|---|---|---|---|---|
| RNG200 | `busses/random/bcm2711_rng200` | ✅ | feeds the kernel's random pool ("9 words ready"); a health-test failure restarts it (10-20) | — |

## 16. Serial

| Component | Haiku driver | Status | Measured (date) | Limitations / missing |
|---|---|---|---|---|
| PL011 (GPIO 14/15, console) | upstream `src/system/kernel/arch/arm/arch_uart_pl011.cpp`; fixes: "PL011: keep the firmware's line settings", "PL011 debug output: bounded wait for room in the FIFO", "arm64: fix reading from the debug serial port" | ✅ | 115200 8N1; kernel log and kernel debugger; serial emergency keys (three Ctrl-] then `d` enters KDL) served from the receive interrupt | `config.txt` sets `dtoverlay=disable-bt` so that the PL011 is the console; Bluetooth uses the mini-UART |
| Mini-UART | used by `bcm2711_bt` | ✅ | — | Not a console |

## 17. Boot chain

| Component | Haiku driver | Status | Measured (date) | Limitations / missing |
|---|---|---|---|---|
| Firmware + `config.txt` | pinned `start4.elf` (`scripts/fetch-pi-firmware.sh`); overlays `haiku-v3d`, `haiku-fkms`, `disable-bt` (`scripts/mkimage-pi4.sh`) | ✅ | — | — |
| U-Boot (`rpi_4_defconfig`, EFI) | `sources/u-boot` + `patches/u-boot/` | ✅ | — | — |
| Haiku EFI loader → kernel | upstream `haiku_loader.efi`, with the loader fixes listed under SoC | ✅ | SD card: U-Boot → desktop 6.4–6.6 s, loader → desktop 5.4–5.6 s (four boots of the image-2026-11-03b/c release cards, 11-03); on the bench, whose EEPROM tries the network first, U-Boot starts ~58 s after power-on and the desktop is up at ~64 s. Cold SD boots after 30 minutes off: 10 of 10 (image-2026-11-03, 11-03); boot bench 10/10 (10-19) | SD layout: MBR, p1 FAT32 (firmware, U-Boot, EFI), p2 BFS |
| Network boot (no SD card) | dnsmasq + TFTP for firmware, U-Boot (netboot build) and loader; boot volume as a remote disk (`drivers/disk/virtual/remote_disk`, host `remote_disk_server`) | ✅ | U-Boot → desktop 16.3 and 17.3 s, the desktop ~45–47 s after power-on (two release checks, 11-03); cold network boots 3 of 3 (11-02). The freeze that stopped about 1 in 10 network boots of a Pi that had been off for minutes was fixed on 11-02 (haiku d1a616afac, in image-2026-11-02b and later: the kernel's empty TTBR0 table is cleared; loader f593b2ae43 and U-Boot patches 0004/0005 as hardening) | A remote disk, not an NFS root: Haiku boots from a block device ([design/netboot.md](design/netboot.md)). 1 KiB per request (16 in flight in the kernel, for reads and writes; 8 in the loader; KNOWN-ISSUES F8). devfs reloads `remote_disk` and the second instance's server search fails in the log, harmless (D1). Needs a dedicated LAN and the EEPROM's boot order to try the network |

## Ported libraries and applications

All are cross-built on the host for arm64 and, unless the notes say otherwise, published as packages
in our repository, [haiku-pi.github.io/packages](https://github.com/haiku-pi/packages) (154 packages on
2026-11-03). `pkgman` in the image uses it out of the box.

| Component | Version (package revision) | Notes |
|---|---|---|
| Mesa (v3d, v3dv, softpipe), libdrm, libglvnd, GLU | Mesa 26.2.6 (-2), GLU 9.0.3 (-6) | forks under `haiku-pi/`; stays on Mesa stable releases. GLTeapot, GLInfo and the GL screen savers build against it |
| SDL2 | 2.32.10 (-5) | OpenGL, OpenGL ES and Vulkan windows; window events handled on the event thread (`patches/libsdl2`) |
| FFmpeg | ffmpeg6 6.1.6 (-3) | media kit plugin (MediaPlayer); `hevc_rpivid` on the decoder block |
| zstd | 1.5.7 | lets packagefs read Haiku's zstd-compressed packages |
| ICU | icu74 74.1 (-1) | built properly (data in `libicudata`); replaces the bootstrap package |
| OpenSSL, curl | 3.5.9, 8.22.0 | TLS for the network kit and pkgman |
| NetSurf | 3.11 | in the image |
| WebPositive / HaikuWebKit | 1.10.0 | in the image; JavaScriptCore JIT (baseline/DFG/FTL/wasm) on |
| Wine, Box64, FEX | Wine 11.21 (-2; 11.20-24 before), Box64 v0.4.4, FEX-2610 | in our repository (`wine`, `wine_x86`, `wine_x86_64`): ARM64X build; Windows programs in Wayland windows over Haiku's (X547's in-process server); DirectDraw/Direct3D 9 through wined3d on the V3D |
| Firefox | 157.0.1 (-5) | in the image and published (zstd, 102 MB); its window in 3.1 s warm, 10.2 s the first time after a network boot (11-03), 8.2 s the first time after a card boot (10-25); WebGL 1 and 2 on an OpenGL ES 3.1 context; plays H.264, VP8/9, AV1, HEVC |
| SpiderMonkey `js` shell | 157.0.1 | 11/11 tests on the Pi, JIT on (10-20) |
| Rust | 1.90.0, target `aarch64-unknown-haiku` with std | a host cross toolchain; test programs 3/3 on the Pi |
| CPython | python3.14 3.14.8 (-2) | in the image; ssl, sqlite3, ctypes, lzma, zstd, readline (libedit), curses (ncurses 6.6) |
| numpy | 2.5.4 (-2) | published; NEON/ASIMD baseline, no BLAS; fast test suite 0 failures on the Pi (8 errors: tests that compile at run time); **built natively on the Pi** with pip + gcc 16.2 in 24 min, subset 20969 passed 0 failed (11-03) |
| Build tools | make 4.4.1, ninja 1.13.2, cmake 4.4.5, meson 1.12.1, pkgconf 3.0.10, binutils 2.46.1, pip 26.2.2, Cython 3.3.1, meson-python 0.22.1 | published 11-03; Pi 23/23 (make/CMake/Meson builds, pip installs) |
| Native compiler | gcc 16.2.0 (C, C++, Fortran: gcc, gcc_fortran) | published 11-03; Pi 24/24 (C, C++23, Haiku API, LTO, OpenMP, PCH, gcov, Fortran, CMake); needs the image's haiku_devel for Haiku headers |
| C++ runtime | gcc_syslibs 16.2.0 (libstdc++ 6.0.36) | in the image from image-2026-11-03b (the first GCC 16.2 build); published 11-03; on image-2026-11-03 (13.3-built system) the release checks pass with it: 0 problems |
| QuakeSpasm | 0.96.3 | timedemo 202.5 / 80.3 / 41.0 fps at 640×480 / 1280×720 / 1920×1080 (11-03); test images only (needs the game data) |
| Yamagi Quake II | 8.60 | GL1 renderer; timedemo 206.8 / 102.3 / 53.1 fps at 640×480 / 1280×720 / 1920×1080 (11-03); test images only |
| vkQuake | 1.35.0 | Vulkan; timedemo 54.9 fps at 1280×720, 33.1 at 1920×1080, with V3D-friendly defaults (11-03); test images only |
| OpenArena on ioquake3 | 0.8.8 (-4) | timedemo 53.3 fps in a 1280×720 window, 28.1 at 1920×1080 full screen (11-03); game code in ioq3's QVM interpreter; published, its data in 5 parts (each under GitHub's file limit) |
| SuperTuxKart | 1.5 (-2) | GL 2.1 renderer 37.6 fps at 1280×720 in a 60 s race (runs 35.1–41.2; 11-03); GLES 3.1 shader renderer 16–18 fps (10-20); published, data in 3 parts |
| llama2.c | — | stories15M 45.7 tok/s on 4 cores (10-20); test images only |
| Native build tools (dev image) | gcc 16.2 (since haiku b59f1c957f; 13.3 bootstrap before), binutils 2.46.1, make 4.4.1, python3.10, haikuporter (Haiku's arm64 build packages); patch 2.8, tar 1.35, gzip 1.13, xz 5.6.4, bzip2 1.0.8, diffutils 3.10 (ours) | haikuporter built a first port (hoedown 3.0.7) natively in QEMU (10-19) |

## Build and test infrastructure

- **Build**: `scripts/bootstrap.sh`, `scripts/build.sh` (jam, heavy steps under `scripts/heavy-build.sh`),
  `scripts/build-packages.sh` (our packages), `scripts/mkimage-pi4.sh` (the SD image). The from-scratch build
  in a fresh clone was verified on 2026-10-19 (about 28 minutes on a 16-thread host, plus about an hour for
  WebKit), with GCC 13.3; it has not been timed again since the toolchain moved to GCC 16.2 (11-03).
- **Bench**: SD-card cycles (`scripts/sd-cycle.sh`, flashing through a netbooted Linux "flash lane" with a
  SHA-256 read-back), network-boot cycles (`scripts/netboot-cycle.sh`), boot reliability benches
  (`scripts/boot-bench.sh`), an interactive session with a live HDMI preview (`scripts/pi-test.sh`); tests are
  boot scripts in `tools/pi-tests/` that print graded lines on the serial console. Details: [LAB-SETUP.md](LAB-SETUP.md).
- **Emulation**: `scripts/qemu-virt.sh` (the arm64 reference platform), `scripts/qemu-raspi.sh` (QEMU's
  raspi4b model, for the boot chain and early kernel, with gdb).
- **Packages**: `scripts/make-repo.sh`, `scripts/publish-repo.sh` (packages under GitHub's 100 MiB file limit: Firefox zstd-compressed, the games' data in parts).
- **Upstream**: `scripts/upstream-sync.sh` merges upstream Haiku into `rpi4` weekly (build, bench, push only
  when green).
- **Rollback**: `scripts/snapshot-state.sh` writes `manifests/<date>-<step>.md` with every repository's SHA.

## What full support still needs (priority order)

From the "Next" list of [log/WEEK-2026-W45.md](log/WEEK-2026-W45.md) (2026-11-03 evening), the backlog in
[PLAN.md](PLAN.md) and [KNOWN-ISSUES.md](KNOWN-ISSUES.md):

1. **Hands-on checks** (a person at the bench, [HANDS-ON-CHECKS.md](HANDS-ON-CHECKS.md); keyboard, mouse and
   everyday desktop use done 10-25): audio by ear; typing in Firefox and WebPositive; keys and mouse in an SDL
   game; whether the "speckles" seen in HDMI captures while a GL program runs are on a real monitor too; joining
   WiFi from Network preferences; Bluetooth devices.
2. **Display planes, follow-ups** (KNOWN-ISSUES F2): an overlay stays black after a mode change; YCbCr422 shows
   black; GL on a plane is 1–2 % slower than a copy at 1080p in QuakeSpasm and OpenArena; YCbCr output from the
   ffmpeg plugin; rpivid's pictures scanned out without a copy ([design/gpu-stage6.md](design/gpu-stage6.md) §4–5).
3. **Performance round H20** ([design/perf-round-h20.md](design/perf-round-h20.md)): the desktop-session
   profile is done (11-03; its fixes so far: `profile -a` sees new programs, the ARM clock under spread loads
   (F10), the V3D shader cache's hash); next: Firefox's cold start, the SD card's write path, boot phases.
4. **Firefox**: the first video after the browser starts drops frames (G2: a cold start; played again, from the
   SD card, 0 of 300); WebRTC later.
5. **Developing on the Pi (H18)**: GCC 16.2 and the build tools are published; left: a haikuporter recipe built
   with GCC 16.2 on the Pi, and native port builds without a trimmed recipe tree (F5).
6. **Windows programs (H15)**: Wine 11.21 runs arm64, x86 (Box64) and x86-64 (FEX) programs and is published;
   open: the items in KNOWN-ISSUES §5 (x86 memory ordering under Box64, two demos that crash)
   ([design/wine-x86.md](design/wine-x86.md)).
7. **Smaller items**: WiFi throughput (49/46 Mbit/s on the bench's 2.4 GHz AP; F4); WebPositive's Web Inspector data (F7);
   HDMI audio on the second port and after a hot-plug (P3).
8. **H.264 hardware decoding** (H21, last in the backlog): through the VideoCore firmware's MMAL over VCHIQ, by a
   BSD-licensed route ([design/hw-video-decode.md](design/hw-video-decode.md) §0a).

Not started: I²C, SPI.
