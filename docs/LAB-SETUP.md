# The test bench

> **None of this is needed to build or run Haiku on a Pi 4.** For an SD card and a monitor, follow
> [TRY-IT.md](TRY-IT.md). This document describes the bench the port is developed and measured on:
> a Pi 4 with no monitor, no keyboard at hand and no card swapping, driven entirely from the build
> host, so that every boot is scripted, logged and repeatable.

Every number in [HARDWARE-SUPPORT.md](HARDWARE-SUPPORT.md) and every rate in
[KNOWN-ISSUES.md](KNOWN-ISSUES.md) comes from this bench. The rules for using it are also in
[AGENTS.md](../AGENTS.md) ("The bench").

## What is on the bench

| Part | Connected to | Used for |
|---|---|---|
| Raspberry Pi 4 Model B, 4 GB | — | the board under test; its SD card stays in it permanently |
| USB serial adapter (3.3 V) | the Pi's GPIO 14 (TX), 15 (RX), GND; 115200 8N1 | the PL011 console: loader, kernel log, kernel debugger, test output |
| HDMI capture card (USB, V4L2) | the Pi's HDMI0 | snapshots during every cycle, and a live preview for a person |
| Switchable power (a smart plug) | the Pi's power supply | power-cycling between runs |
| A dedicated Ethernet link (a USB Ethernet adapter on the host, cabled straight to the Pi) | the Pi's Ethernet port | the Pi's private LAN, `10.42.0.0/24` with the host at `10.42.0.1`: DHCP + TFTP for the boot lanes, the remote disk of a network boot, the network tests |
| A WiFi access point (the host's soft-AP, 2.4 GHz) | — | WiFi tests (join, DHCP, throughput) |
| USB keyboard, USB mouse, a USB 3 stick | the Pi's USB ports | enumeration and storage tests; typing needs a person |

The Pi's EEPROM boot order tries the **network first**, then the SD card. So whatever answers DHCP on the Pi
LAN decides how the Pi boots: with nothing answering, it boots its card (the network attempt costs time
first: about 58 s on 2026-10-18).

## Configuration: `local.conf`

Machine-specific settings live in the git-ignored `local.conf`; start from
[local.conf.example](../local.conf.example). Every setting can also come from the environment, and an unset
setting disables what needs it. `scripts/lib/bench.sh` reads it for all bench scripts.

| Setting | Purpose | Default |
|---|---|---|
| `PI_UART` | the serial adapter (e.g. `/dev/ttyUSB0`) | `/dev/ttyUSB0` |
| `PI_PLUG` | a program that switches the Pi's power, called as `$PI_PLUG on` / `$PI_PLUG off` | unset: power cycles fail |
| `HDMI_GRABBER` | the capture card's V4L2 device (e.g. `/dev/video0`) | unset: no snapshots, no preview |
| `PI_LAN_HOST`, `PI_LAN_IFACE` | the host's address on the Pi LAN; the interface is found from the address unless given | `10.42.0.1` |
| `PI_BENCH_LOCK`, `PI_BENCH_LOCK_WAIT` | the lock every Pi cycle holds; how long to wait for it | `$HOME/.pi-bench.lock`, 3600 s |
| `PEER_ROOT`, `PEER_NETBOOT_UP`, `PEER_NETBOOT_DOWN`, `PEER_SD_IMAGE` | another project sharing the bench: its netboot server's start/stop scripts and its SD card image | unset: no peer |
| `HEAVY_BUILD_LOCK` | the lock heavy host builds (WebKit, Mesa, images) wait on | — |
| `WIFI_SSID`, `WIFI_PSK` or `WIFI_PSK_FILE`, `WIFI_GATEWAY` | the access point for WiFi test images | unset |
| `NETBOOT_DNS` | the DNS server a network-booted Pi is told about | `1.1.1.1` |
| `QUAKE_DATA`, `QUAKE2_DATA`, `QUAKE3_DATA` | game data for the game builds (not in git) | unset |

The WiFi passphrase only ever lands in a temporary file and the git-ignored test image.

## Serial console

The PL011 on GPIO 14/15 is Haiku's console: `config.txt` carries `enable_uart=1` and `dtoverlay=disable-bt`
(Bluetooth gets the mini-UART instead). All captures go through `scripts/uart-capture.py`:

```
uart-capture.py --log FILE [--dev /dev/ttyUSB0] [--secs N] [--until REGEX]... [--fail REGEX]...
                [--quiet-secs N] [--send SECS:TEXT]... [--echo]
                [--silence-after N --silence-send OFFSET:TEXT... [--silence-disarm REGEX]...]
```

- Every line gets a host timestamp prefix (`[  12.345] `, seconds since the capture began), so boot stages
  can be timed; the raw bytes are kept in `FILE.raw`.
- It stops after `--secs`, at the first line matching an `--until` (exit 0) or a `--fail` (exit 3), or
  after `--quiet-secs` of silence once something was received (exit 4). Exit 2: nothing was received.
- `--send SECS:TEXT` types into the Pi at a given time (Python escapes). Three Ctrl-] and then `d` drop a
  running Haiku into the kernel debugger (serial emergency keys, served from the UART's receive interrupt):
  `--send '150:\x1d\x1d\x1dd' --send '153:threads\n'`.
- `--silence-after N` with `--silence-send OFFSET:TEXT`: once the line has been quiet for N seconds, type
  those texts, each OFFSET seconds after that moment: the debugger's dumps of a boot that stopped,
  whenever it stops. A line matching `--silence-disarm` (the boot got past the dangerous part) disarms it.

**Tests talk over the same line.** A test is a shell script installed as the image's `UserBootscript`
(`scripts/mkimage-pi4.sh --bootscript tools/pi-tests/X.sh`), run at every boot. It writes lines with a fixed
prefix (`HWR `, `GPR `, `WFJ `, `NPF `, ...) to `/dev/dprintf`, which reaches the serial console, and the
cycle is graded by those **positive** markers, never by the absence of an error.

## HDMI capture

The capture card delivers 1920×1080 YUYV (converted as BT.709 limited range); MJPEG is the fallback.

- **Snapshots**: every cycle saves a frame every `--hdmi-every` seconds (default 20) to
  `artifacts/hdmi/<ts>-<label>-*.png`. They show whether the desktop came up when the serial line is quiet,
  and what a test drew. The screenshots in [screenshots/](screenshots/) are such frames.
- **Live preview**: `scripts/pi-test.sh` opens a window from the card (ffplay, or mpv);
  `PREVIEW_FORMAT=mjpeg` forces MJPEG.
- A capture card is not a monitor: dots seen in captures while a GL program runs (KNOWN-ISSUES G1) may be
  the card's.

## Power

`pi_power on|off` (in `scripts/lib/bench.sh`) runs `$PI_PLUG on|off` and retries three times, since a call
to a network plug can time out. Any program with that interface works: a smart plug, a relay, a switchable
USB hub. Every cycle powers the Pi off at its end, also when it fails.

## The Pi LAN and the boot lanes

The host runs DHCP and TFTP (dnsmasq) on the dedicated Pi LAN interface only. **Only one DHCP server may
answer there at a time, and none may ever run on another interface.** Which server answers selects the
lane:

| Lane | What answers on the Pi LAN | What the Pi does | Script |
|---|---|---|---|
| **Flash lane** | `scripts/flashlane-server.sh`: DHCP/TFTP with a Raspberry Pi Linux kernel and a busybox initramfs (`scripts/flashlane-build.sh`, `tools/flashlane/init`), and an HTTP server (`FLASHLANE_PORT`, default 8099) | fetches `job.txt`, streams the image onto its SD card, reads the written bytes back and compares the SHA-256 (or, in read mode, streams part of the card back to the host); prints `HFL ` lines ending with `HFL end`; powers off | `scripts/sd-cycle.sh --flash IMG` / `--read-back FILE` |
| **SD boot** | nothing | boots its card: firmware → U-Boot → Haiku loader → kernel | `scripts/sd-cycle.sh`, `scripts/boot-bench.sh` |
| **Network boot** | `scripts/netboot-server.sh up IMG`: DHCP + TFTP for the firmware, a netboot U-Boot and the Haiku loader; `remote_disk_server` serves a fresh copy of IMG as the boot volume | boots Haiku from the host, writing nothing to its card; desktop in about 55–60 s | `scripts/netboot-cycle.sh`, `scripts/pi-test.sh --netboot IMG` |

The flash lane takes about 14 s to write and 8 s to verify a 352 MB image (2026-10-18). The network boot
needs no card writing at all, so an image built a minute ago boots at once; what Haiku writes goes to
`artifacts/netboot/disk.img` and stays there until the next `up` (read it with `scripts/image-cat.sh`).
Why a remote disk and not an NFS root: [design/netboot.md](design/netboot.md).

## Sharing the bench

The bench may be shared with another project using the same Pi. The bench scripts assume it and keep both
sides safe:

- **One cycle at a time.** Every power cycle, UART capture and change to the Pi LAN's DHCP/TFTP server runs
  under an exclusive `flock` on `$PI_BENCH_LOCK` (`bench_lock` in `scripts/lib/bench.sh`, on fd 9). A second
  cycle waits up to `PI_BENCH_LOCK_WAIT` seconds, then exits 75; it also exits 75 if another program holds
  the serial device. `scripts/pi-test.sh` holds the lock for the whole interactive session, so automated
  cycles wait for the person.
- **The other project's netboot server is the bench's resting state.** A cycle stops it
  (`PEER_NETBOOT_DOWN`) when it needs the Pi LAN, and brings it back (`PEER_NETBOOT_UP`) on exit, also on
  failure.
- **The SD card.** By agreement, this project may overwrite the card and puts the other project's image
  back before it needs an SD boot: `scripts/restore-peer-sd.sh` (`PEER_SD_IMAGE`, verified by the flash
  lane's read-back).
- **Heavy host builds** (WebKit, Mesa, image builds) run under `scripts/heavy-build.sh`: one at a time on
  `HEAVY_BUILD_LOCK`, parallelism capped by free memory, in a memory-limited systemd user scope so that an
  out-of-memory build is killed instead of the session.

Without a second project nothing changes: the lock is uncontended and the `PEER_*` steps are skipped.

## Scripts

The cycle scripts take `--label L` and write `artifacts/uart/<ts>-<label>.log` and HDMI frames in
`artifacts/hdmi/`. A caller's own timeout must exceed the capture time (`--secs`) plus flashing plus
about 120 s.

| Script | What it does |
|---|---|
| `scripts/sd-cycle.sh [--flash IMG] [--no-boot] [--secs N] [--until RE]... [--fail RE]... [--send SECS:TEXT]... [--hdmi-every N]` | One SD cycle: optionally flash, then boot the card with no DHCP server answering, capture (default 120 s), power off, restore the peer. Exit: 0 ended on `--until` (or ran its full time without one), 1 flashing failed, 2 the UART stayed silent, 3 a `--fail` line, 4 the UART went quiet. `--read-back FILE [--read-mb N]` copies the card's first N MiB (default 400) instead of booting; `scripts/sd-syslog.sh` then prints Haiku's syslog from it |
| `scripts/netboot-cycle.sh [--image IMG] [--secs N] [--no-wedge-dump]` | One network-boot cycle (default image: the regular image, 200 s). Logs the remote disk's request count every 5 s (`<ts>-<label>-disk.txt`: a boot whose serial line is quiet but whose disk reads go on is alive). If the line goes quiet for 20 s before the display driver reports "hardware cursor shown", it enters the debugger and types each CPU's stack crawl, `ici` and `ints` (the network-boot wedge dump) |
| `scripts/boot-bench.sh N [IMG]` | Boot reliability: N trials of flash, SD boot, 200 s capture, the debugger at 158 s with each CPU's stack, ICIs, threads and timers. A trial passes when app_server set its mode and the thread list has `w>Deskbar` and `w>Desktop`. Nothing is typed before 158 s (an earlier key would revive a frozen boot and hide it). `--grade LOG...` grades existing logs |
| `scripts/pi-test.sh [--flash IMG \| --regular \| --netboot IMG] [--no-preview] [--no-power-off]` | The owner's interactive session: optionally write an image, boot (SD or network), show the serial console live in the terminal (logged), open the HDMI preview; closing the window powers the Pi off and restores the bench |
| `scripts/netboot-server.sh up IMG \| down \| status` | The network boot's servers (dnsmasq, TFTP root from IMG's FAT partition, `remote_disk_server`) |
| `scripts/flashlane-server.sh up \| down \| status` | The flash lane's servers |
| `scripts/mkimage-pi4.sh` | Builds the SD image; for tests: `--bootscript FILE`, `--add-bin FILE`, `--add-tree DIR` (into `/boot/system/non-packaged/`), `--block-entry PATH` (hide a file of the system package, e.g. a driver), `--kernel-setting "name value"`, `--config LINE` (into `config.txt`), `--no-v3d`, `--no-fkms` |
| `scripts/wifi-join-image.sh [--script tools/pi-tests/net-perf.sh]` | A test image whose boot script joins the access point from `local.conf` |
| `scripts/net-perf-server.sh` | TCP endpoints for `tools/pi-tests/net-perf.sh` (port 5001 receives, 5002 sends 64 MiB) |
| `scripts/serve-repo.sh [ADDRESS]` | Serves the local package repository on the Pi LAN (port 8090) for `pkgman` tests |
| `scripts/image-cat.sh IMAGE PATH`, `scripts/sd-syslog.sh` | Read a file (e.g. the syslog) from an image's BFS partition with the host's `bfs_shell` |
| `scripts/qemu-virt.sh`, `scripts/qemu-raspi.sh` | QEMU: the generic arm64 `virt` machine (the reference: if it fails there it is not a Pi problem) and the `raspi4b` model (boot chain and early kernel, with a gdb stub and QMP) |
| `scripts/snapshot-state.sh <step>` | Records every repository's SHA in `manifests/` after a validated step |

**Test boot scripts** in `tools/pi-tests/` cover each area: hardware report (`hw-report.sh`), storage speed
(`perf-report.sh`), GPU (`gpu-report.sh`, `v3d-test.sh`, `v3d-recovery.sh`, `gl-*.sh`, `vulkan.sh`,
`vkwindow.sh`), display (`display-test.sh`, `mode-test.sh`, `cursor-test.sh`, `kdl-mode-test.sh`), clocks
(`clocks.sh`, `cpufreq.sh`), audio and media (`audio.sh`, `media.sh`, `rpivid.sh`), network (`net-perf.sh`,
`wifi-join.sh`, `wifi-report.sh`, `web.sh`, `pkgman.sh`), Bluetooth (`bluetooth.sh`), applications and games
(`webpositive.sh`, `firefox*.sh`, `quake*.sh`, `vkquake.sh`, `openarena.sh`, `supertuxkart.sh`, `python.sh`,
`rust.sh`, `llama2.sh`), and load (`soak.sh`: 20 minutes of Quake, SD write/verify and pings;
`soak-apps.sh`: 15 minutes of Firefox, SuperTuxKart and 1080p HEVC at once). Tests that need Ethernet
without a DHCP server give the Pi a static address on the Pi LAN (`10.42.0.50`) with the host as gateway.

## Adapting it to your own bench

1. `cp local.conf.example local.conf` and set what you have. The minimum is `PI_UART`: with only a serial
   adapter you can capture boots (`uart-capture.py`) and power the Pi by hand.
2. **Power**: point `PI_PLUG` at any program that takes `on` / `off`. Without it, the cycle scripts cannot
   power-cycle the Pi.
3. **HDMI**: any UVC capture card; set `HDMI_GRABBER`. For a preview, install ffplay (ffmpeg) or mpv.
4. **Pi LAN**: a second Ethernet interface on the host, cabled straight to the Pi, with a static address.
   Set `PI_LAN_HOST` if it is not `10.42.0.1`. A different subnet also needs edits where `10.42.0.0/24` is
   written out: the DHCP ranges in `scripts/netboot-server.sh` and `scripts/flashlane-server.sh`, the default address of
   `scripts/serve-repo.sh`, and the static addresses in some test boot scripts (`web.sh`, `net-perf.sh`,
   `soak.sh`). Never let these scripts' DHCP server near your main network: dnsmasq binds
   only the Pi LAN interface.
5. **Boot order**: for the flash lane and network boot, set the Pi's EEPROM `BOOT_ORDER` to try the
   network before the SD card. Netboot also needs `scripts/build-uboot.sh` (it builds the netboot U-Boot)
   and `scripts/build.sh remote_disk_server`.
6. **WiFi tests**: any WPA2-PSK access point; set the `WIFI_*` settings.
7. **Shared bench**: if another project uses the same Pi, agree on one `PI_BENCH_LOCK` path and set the
   `PEER_*` settings to its netboot server's scripts; if not, leave them unset.
