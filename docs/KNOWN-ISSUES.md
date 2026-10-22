# Known open issues

Every issue we know about and have **not** fixed, in one short register.

- **Open only.** A fixed issue leaves this file; its story stays in the weekly log ([log/](log/)), where
  each row below points ("tracked").
- **Short.** Each row says what is wrong, how often, the workaround, and where it is tracked. Measurements
  and investigations live in the log entries named.
- What works and how well: [HARDWARE-SUPPORT.md](HARDWARE-SUPPORT.md). The bench the rates were measured
  on: [LAB-SETUP.md](LAB-SETUP.md).

Checked against the weekly logs up to **2026-10-23 00:30**.

## 1. Correctness: crashes and hangs

| # | Issue | How often | Workaround | Tracked |
|---|---|---|---|---|
| C1 | **The network-boot wedge.** A network-booted Pi stops at about 51–54 s, while the network drivers load and first-boot package processing reads the remote disk. Everything stops at once: the serial line, the HDMI picture and the remote disk's requests; the kernel debugger does not answer its break key, and nothing more arrives in the following 10 minutes. No panic, no report. **It strikes a Pi that was powered off for minutes** (10-21): of the network boots since 10-20, 1 in 139 wedged after ≤ 2 min off, but every captured wedge came after 5–24 min off, and in series with 6 min off before each boot it struck 1 in 8, then 0 in 15 (3 in 31 cold altogether). A cold SoC is the suspect. **Cold SD first boots did not show it**: 12 of 12 clean (10-21, each card written, then 6 min off, then booted) — the wedge is so far a network-boot problem. Not cured by the kernel-stack fix of 10-20 23:50. RAM does not survive a reset on the Pi 4, so there is no post-mortem. | About 1 in 10 network boots of a Pi off for minutes (3 in 31, 10-21); about 1 in 250 warm | Power-cycle: the warm Pi boots | W43: 10-20 07:30–23:50; 10-21 00:50, 03:30 |
| C2 | **An early-boot hang**: the serial output stops after `reserve_io_interrupt_vectors`, and the boot splash stays with no icon lit. One sample, on a network boot (`qperf1`); the same image booted on the next try. | 1 of ~20 boots on 10-20; not seen in the 15 SD boots that followed | Power-cycle | W43: 10-20 04:10, 05:10 |
| C3 | **ioquake3 (OpenArena) does not always exit on SIGTERM.** Its signal handler shut the renderer down from inside the interrupted frame. Fixed in the source (patches/ioq3/0002: the main loop quits between frames): a kill in the running game exits within 1 s, 11 of 11; a kill in the first seconds of start-up hung once in 5. The published `openarena` package (rev 2) does not have the fix yet; a normal quit is clean. | SIGTERM only | SIGKILL; quit from the menu | W43: 10-20 14:20; 10-23 |
| C4 | **The media kit's audio time source published nothing for 16 s** under the 15-minute application soak (Firefox + SuperTuxKart + 1080p HEVC). This used to crash MediaPlayer's video producer; the crash is fixed (time conversions in double precision), the stall itself is unexplained. | Once, in the first soak run | — | W43: 10-20 10:00 |

## 2. Graphics and UI

| # | Issue | How often | Workaround | Tracked |
|---|---|---|---|---|
| G1 | **"Speckles" in HDMI captures while a GL program runs**: about 0.2 % of the desktop's pixels off-colour (dark, cyan, green dots), at different places in consecutive frames of a static desktop, so transient (not memory being overwritten). None without GL, none with a small 300² GL window. Whether a real monitor shows them (an HVS underrun under memory load) or only the capture card (which delivers YUYV, likely from its own MJPEG) is not known. | Every capture with GLTeapot, a 1000² GL window or Quake | — | W43: 10-19 22:10 |
| G2 | **Firefox drops video frames in the first seconds after it starts.** The first clip played after Firefox starts loses many frames (H.264 720p 121–226 of 300 on network boots, 61 from the SD card with logging on); the same clip played again loses almost none (14 on a network boot, **0 from the SD card**), and VP9 played first loses as much as H.264 does (137). Firefox's logs: no frame is skipped for late decoding; the decoder process stalls for up to 1.8 s at a time while it warms up, and the frames it then delivers late are discarded by the video sink. The earlier "H.264 drops most" was the test's order (H.264 played first). A cold start, worse on network boots, where code pages come from the remote disk. | First playback after Firefox starts | Play it again; boot from the SD card | W43: 10-20 18:20, 19:40; 10-21 01:00 |

## 3. Platform limitations

| # | Issue | How often | Workaround | Tracked |
|---|---|---|---|---|
| P1 | **Desktop OpenGL is 2.1.** A BGLView gives a compatibility context only, and the V3D's desktop GL stops at 3.1. Programs that want more than 2.1 fall back or fail on desktop GL: Quake II's GL3 renderer (needs 3.2), SuperTuxKart's shader renderer ("OpenGL version is too old"), Firefox's WebGL (wants GLSL 1.50). | Always | OpenGL ES 3.1 contexts (`BGL_CONTEXT_ES`, SDL's ES profile): SuperTuxKart's GLES build, Firefox's WebGL | W43: 10-19 07:40; 10-20 08:30, 17:45 |
| P2 | **No H.264 hardware decoding.** On the Pi 4, H.264 is decoded by the VideoCore firmware behind MMAL/VCHIQ; only the HEVC block is directly programmable. | Always | CPU decoding (1080p several times real time on 4 threads) | [design/hw-video-decode.md](design/hw-video-decode.md) §0 |
| P3 | **No HDMI audio.** | Always | The 3.5 mm jack | [TRY-IT.md](TRY-IT.md) |
| P4 | **No battery clock.** Until NTP sets the time the date is 1970, and HTTPS fails certificate checks ("certificate not yet valid"). | Every boot without network | The image syncs by NTP when the network comes up | W43: 10-19 10:30 |
| P5 | **SD card speed is capped at 50 MB/s**: the EMMC2's base clock is 100 MHz, so SDR104 is out of reach; we measure 42.6 MB/s. | Always | USB 3 storage (78–90 MB/s) | W43: 10-20 11:00 |
| P6 | **Only one board has run the port**: a Pi 4 Model B, 4 GB. | — | — | [TRY-IT.md](TRY-IT.md) |

## 4. Incomplete features

| # | Issue | How often | Workaround | Tracked |
|---|---|---|---|---|
| F1 | **Not yet checked by hand** (needs a person at the bench): audio by ear (the driver measures 44117.657 Hz, 0 underruns); typing on the USB keyboard and pointing with the mouse (both enumerate); keyboard and mouse in SDL games (their events now go through SDL's event thread); the hardware cursor with a real mouse; joining WiFi from Network preferences. | — | — | W43 "Next" item 1 |
| F2 | **GPU stages 6 and 7 not done**: no page flips on firmware planes (full-screen GL presents by a GPU blit; at most ~15 % to gain at 1080p), no YCbCr overlays (MediaPlayer converts to B_RGB32), no asynchronous per-queue job FIFOs. rpivid frames are copied to the display. | — | — | [design/gpu-v3d.md](design/gpu-v3d.md) §3; W43 "Next" item 5 |
| F3 | **Bluetooth beyond the local device is untested**: pairing and profiles have not been tried; `bluetooth_server` is not started at boot (as on other Haiku systems). `bt_dev_info` works since 10-23 (the controller's name and address); `bt_discovery` now builds but waits forever for its inquiry's results through `bluetooth_server`. | — | Start `bluetooth_server` by hand; the port's `tools/bt-tests/btinquiry` | W43: 10-19 14:10; 10-23 |
| F4 | **WiFi throughput is modest**: 37.4 up / 46.0 down Mbit/s, close to what the bench's 2.4 GHz access point gives; SDIO runs PIO and is CPU-bound. No wpa_supplicant on arm64: the kernel joins WPA2-PSK networks itself, and an unscanned network is assumed to be WPA2-PSK. | — | Ethernet | W43: 10-19 12:30; "Next" item 6 |
| F5 | **Native package builds (H14)**: haikuporter builds ports on the Pi itself (hoedown 37 s, gperf 52 s, from the development image), but only with a trimmed recipe tree (the whole HaikuPorts tree costs ~9 min of recipe parsing per port); the packages in our repository are cross-built on the host. Haiku has no official arm64 HaikuPorts repository. | — | Cross-builds (`scripts/cross-port.sh`, `scripts/package-port.py`) | W43: 10-21 09:20 |
| F6 | **The Quake engines are not packaged** (QuakeSpasm, vkQuake, Yamagi Quake II, ioquake3 for Quake III): their game data is not free, and a packaged engine would find none in its read-only directory. | — | `scripts/build-games.sh` and friends with your own data files ([BUILD.md](BUILD.md)) | W43: 10-20 15:55 |
| F7 | **WebPositive**: the Web Inspector's resources are not installed — as on x86 Haiku: the HaikuPorts recipe does not install them either. (Its user agent, "Macintosh; Intel Haiku/…", is upstream's deliberate Safari-compatible string — Safari on Apple Silicon Macs also says "Intel" — so it stays.) | — | — | W43: 10-19 23:40; "Next" item 6 |
| F8 | **Network boot reads 1 KiB per request** (16 requests in flight in the kernel, 8 in the loader), and is not an NFS root: Haiku boots from a block device. | — | — | [design/netboot.md](design/netboot.md) |

## 5. Windows programs (Wine)

| # | Issue | How often | Workaround | Tracked |
|---|---|---|---|---|
| W1 | **Full-screen games are slower than in a window**: a game's display mode is scaled to the screen on the CPU every frame, and an OpenGL/Direct3D frame is read back from the GPU first. A 640x480 Direct3D 9 test: ~120 fps in a window, ~25 full screen (9.5 before wine 11.20-10). | Always | Run the game in a window | W43: 10-22 22:40; 10-23 00:00 |
| W2 | **A few Wine helper processes (`services.exe`) can stay alive after their wineserver was killed** (`wineserver -k`, or a crash before 11.20-9). | Seen once, 3 processes | `kill` them; a new start is not affected | W43: 10-22 22:40 |
| W3 | **SimCity 3000: wined3d's command stream gets corrupted now and then** — once a write through a garbage buffer pointer in the command-stream thread (crash), once an "Invalid opcode" in the stream (the game stays at its loading screen); i386 wined3d under Box64. | 2 in ~12 runs | Start it again | W43: 10-22 14:10; 10-23 |
| W4 | **StarCraft with Box64's "safe" settings** (`BOX64_DYNAREC_STRONGMEM=2`, no big blocks) stayed black for its first 2 minutes; with the default settings it plays. Slow or broken, not yet known. | The sweep's `starcraft-safe` run | Box64's default settings | W43: 10-22 22:00 |
| W5 | **After a Wine package update the prefix is updated at the next start** (about 7 minutes, and Wine asks again to install Wine Mono). | Every Wine update | `WINEDLLOVERRIDES="mscoree,mshtml=" wineboot -u` once; Cancel at the Mono question | W43: 10-23 00:00 |
| W6 | **`NtFlushProcessWriteBuffers` is a stub on Haiku**: Wine cannot make the other threads' stores visible on demand (the membarrier Linux has). Programs and the x86 emulators that rely on it for memory ordering between threads may misbehave; nothing has been traced to it yet. | — | — | the x86-64 build notes (10-22) |
| W7 | **Not checked by hand**: the mouse in full-screen games (emulated display mode), and sound through Wine by ear. | — | — | W43 "Next" item 7 |

## 6. Debt and cleanup

| # | Issue | How often | Workaround | Tracked |
|---|---|---|---|---|
| D1 | **devfs reloads `remote_disk` from /boot on a network boot**, and the reloaded instance's server search fails ("Network is unreachable"). Harmless so far; it must never replace the boot disk's driver. (On an SD boot the driver now declines to start: the kernel keeps the boot method, haiku 8f0df61a1c — no remote-disk search there since 10-23.) | Every network boot | — | W43: 10-20 08:05; 10-23 |
| D3 | **The `ncurses6_bootstrap` shim package**: upstream's ncurses6 bootstrap package looks for terminfo under a package name it is not activated under; an empty package of that name (`scripts/make-bootstrap-shim.sh`) makes the path exist. Remove once ncurses6 is rebuilt for arm64 (as ICU was). | — | The shim | W43: 10-20 16:40 |
| D4 | **QEMU `virt` with virtio-blk-pci**: block I/O stalls and then fails in userland; virtio-blk over MMIO is clean. PCI interrupt delivery on arm64 is the suspect. Affects the reference platform only. | Every run with that device | `scripts/qemu-virt.sh` uses virtio-MMIO | W42: 10-17 |
