# Known open issues

Every issue we know about and have **not** fixed, in one short register.

- **Open only.** A fixed issue leaves this file; its story stays in the weekly log ([log/](log/)), where
  each row below points ("tracked").
- **Short.** Each row says what is wrong, how often, the workaround, and where it is tracked. Measurements
  and investigations live in the log entries named.
- What works and how well: [HARDWARE-SUPPORT.md](HARDWARE-SUPPORT.md). The bench the rates were measured
  on: [LAB-SETUP.md](LAB-SETUP.md).

Checked against the weekly logs up to **2026-10-21 00:40**.

## 1. Correctness: crashes and hangs

| # | Issue | How often | Workaround | Tracked |
|---|---|---|---|---|
| C1 | **The network-boot wedge.** A network-booted Pi stops at about 54 s, while the network drivers load and first-boot package processing reads the remote disk. Everything stops at once: the serial line, the HDMI picture and the remote disk's requests; the kernel debugger does not answer its break key. No panic, no report. SD boots have never shown it. The kernel-stack fix of 10-20 23:50 ("arm64: map kernel stacks accessed and dirty from the start") removed a way for a CPU to fault inside the exception vector with interrupts off, which matched the shape of this wedge, but **it did not cure it**: the 17th network boot after it wedged (10-21 00:00, at 51 s, same phase). In all four captured wedges the serial output stops in the middle of a line: the CPU writing to the UART stopped between two characters, which points to a peripheral access that never completes and blocks the bus behind it. RAM does not survive a reset on the Pi 4 (checked 10-20), so there is no post-mortem; `scripts/netboot-cycle.sh` types the debugger's per-CPU dumps into a boot that goes quiet and logs the remote disk's request count every 5 s. | About 1 in 8 network boots (10-20, 13:30), then 3 in ~55 (10-20, 17:45), about 1 in 45 by 21:40 (the "Next" list says ~1 in 18). 1 in 17 network boots after the kernel-stack fix (10-21). | Boot from the SD card. Earlier: block the WiFi driver in network-booted test images (`mkimage-pi4.sh --block-entry` of `broadcomfmac`) | W43: 10-20 07:30, 08:05, 13:30, 14:45, 17:45, 20:40, 23:50 |
| C2 | **An early-boot hang**: the serial output stops after `reserve_io_interrupt_vectors`, and the boot splash stays with no icon lit. One sample, on a network boot (`qperf1`); the same image booted on the next try. | 1 of ~20 boots on 10-20; not seen in the 15 SD boots that followed | Power-cycle | W43: 10-20 04:10, 05:10 |
| C3 | **ioquake3 (OpenArena) does not exit on SIGTERM**: its signal handler shuts the renderer down from inside the interrupted frame, and the process stays. A normal quit is clean. | About 1 in 4 kills | SIGKILL | W43: 10-20 14:20 |
| C4 | **The media kit's audio time source published nothing for 16 s** under the 15-minute application soak (Firefox + SuperTuxKart + 1080p HEVC). This used to crash MediaPlayer's video producer; the crash is fixed (time conversions in double precision), the stall itself is unexplained. | Once, in the first soak run | — | W43: 10-20 10:00 |

## 2. Graphics and UI

| # | Issue | How often | Workaround | Tracked |
|---|---|---|---|---|
| G1 | **"Speckles" in HDMI captures while a GL program runs**: about 0.2 % of the desktop's pixels off-colour (dark, cyan, green dots), at different places in consecutive frames of a static desktop, so transient (not memory being overwritten). None without GL, none with a small 300² GL window. Whether a real monitor shows them (an HVS underrun under memory load) or only the capture card (which delivers YUYV, likely from its own MJPEG) is not known. | Every capture with GLTeapot, a 1000² GL window or Quake | — | W43: 10-19 22:10 |
| G2 | **Firefox drops video frames**, most with H.264: dropped of 300 frames, H.264 720p 121–211, H.264 1080p 148–271 (149 with `media.ffmpeg.customized-buffer-allocation` off), VP9 and AV1 720p 10–16; HEVC 720p 2–32 of 150. Where they are lost (10-21, Firefox's own logs): no frame was skipped for late decoding; most are frames the video sink discards because they reach it after their display time (H.264 720p 169 of 202, VP9 10 of 16), the rest the compositor. Decoding keeps up (7.8 ms mean per frame); the drops come after it: presentation (software compositing; Firefox has no GPU compositor on Haiku), and for H.264 a new image buffer for nearly every frame. | Every playback | MediaPlayer plays the same clips; HEVC goes to the decoder block in both | W43: 10-20 18:20, 19:40 |

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
| F3 | **Bluetooth beyond inquiry is untested**: pairing and profiles have not been tried; `bluetooth_server` is not started at boot (as on other Haiku systems); Haiku's own command-line tools are broken upstream (`bt_dev_info` prints a BString with `%s`; `bt_discovery` does not compile). | — | Start `bluetooth_server` by hand; the port's `tools/bt-tests/btinquiry` | W43: 10-19 14:10 |
| F4 | **WiFi throughput is modest**: 37.4 up / 46.0 down Mbit/s, close to what the bench's 2.4 GHz access point gives; SDIO runs PIO and is CPU-bound. No wpa_supplicant on arm64: the kernel joins WPA2-PSK networks itself, and an unscanned network is assumed to be WPA2-PSK. | — | Ethernet | W43: 10-19 12:30; "Next" item 6 |
| F5 | **Native package builds (H14)**: haikuporter has built one port (hoedown) natively in QEMU; the packages in our repository are cross-built on the host. Haiku has no official arm64 HaikuPorts repository. | — | Cross-builds (`scripts/cross-port.sh`, `scripts/package-port.py`) | W43: 10-19 05:45; "Next" item 4 |
| F6 | **Some packages are not published**: Firefox (in the image; waits for the owner's decision on the official branding) and the games OpenArena and SuperTuxKart (over GitHub's 100 MB file limit). The Quake engines stay unpackaged (their game data is not free). | — | Build the image with `-sHAIKU_PI_GAMES=1`; Firefox is in the regular image | W43: 10-20 09:20, 15:55; "Next" item 1 |
| F7 | **WebPositive**: the user agent says "Intel Haiku" (hard-coded upstream); the Web Inspector's resources are not installed. | — | — | W43: 10-19 23:40; "Next" item 6 |
| F8 | **Network boot reads 1 KiB per request** (16 requests in flight in the kernel, 8 in the loader), and is not an NFS root: Haiku boots from a block device. | — | — | [design/netboot.md](design/netboot.md) |

## 5. Debt and cleanup

| # | Issue | How often | Workaround | Tracked |
|---|---|---|---|---|
| D1 | **devfs reloads `remote_disk` from /boot on a network boot**, and the reloaded instance's server search fails ("Network is unreachable"). Harmless so far; it must never replace the boot disk's driver. | Every network boot | — | W43: 10-20 08:05; "Next" item 3 |
| D2 | **The `remote_disk` driver is in every image**, so an SD boot also probes for a remote disk server (it fails at once with no network; with a server on the LAN an SD-booted Pi would show that disk too). Limiting it to network boots needs a boot-method flag that outlives the kernel arguments. | Every SD boot | — | [design/netboot.md](design/netboot.md) "Limits" |
| D3 | **The `ncurses6_bootstrap` shim package**: upstream's ncurses6 bootstrap package looks for terminfo under a package name it is not activated under; an empty package of that name (`scripts/make-bootstrap-shim.sh`) makes the path exist. Remove once ncurses6 is rebuilt for arm64 (as ICU was). | — | The shim | W43: 10-20 16:40 |
| D4 | **QEMU `virt` with virtio-blk-pci**: block I/O stalls and then fails in userland; virtio-blk over MMIO is clean. PCI interrupt delivery on arm64 is the suspect. Affects the reference platform only. | Every run with that device | `scripts/qemu-virt.sh` uses virtio-MMIO | W42: 10-17 |
