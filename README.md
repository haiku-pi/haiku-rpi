# Haiku on the Raspberry Pi 4

This repository coordinates the port of [Haiku](https://www.haiku-os.org) to the **Raspberry Pi 4 Model B**. It holds
the build and test scripts, the bench tools, the documentation, the patches for third-party software and the
manifests that record which source revisions were tested together. The Haiku sources themselves are in the fork
[haiku-pi/haiku](https://github.com/haiku-pi/haiku), branch `rpi4`. `scripts/bootstrap.sh` clones that fork and
every other source into `sources/`.

The image boots from an SD card, or over the network from the build host, to the full Haiku desktop on HDMI. It
has GPU-accelerated OpenGL, OpenGL ES and Vulkan on the V3D, all four CPU cores, gigabit Ethernet, WiFi, Bluetooth,
USB 3, audio over HDMI and on the headphone jack, and hardware HEVC decoding. The image has two web browsers, WebPositive and Firefox 157
(Firefox is an optional build step), and a package repository built for arm64 works with `pkgman` out of the box.

![Haiku on a Raspberry Pi 4: WebPositive, GLTeapot on the V3D, ActivityMonitor, About Haiku, a Terminal with the hardware, Quake II](docs/screenshots/02-desktop-quake2.png)

*Haiku on a Raspberry Pi 4 Model B (4 GB), booted from its SD card. This is an HDMI capture, unedited. More
pictures are in [SHOWCASE.md](SHOWCASE.md) and [docs/screenshots/](docs/screenshots/).*

The port was done by an AI coding agent (Claude) working autonomously. The owner's first prompt went out on the
evening of 2026-10-17. The Haiku desktop ran on the real Pi 2.5 hours later. Up to the date of this page the owner
has written 27 prompts in all, and they are listed in [docs/OWNER-PROMPTS.md](docs/OWNER-PROMPTS.md). How the
work went is told in [docs/AI-DRIVEN-PORT-JOURNEY.md](docs/AI-DRIVEN-PORT-JOURNEY.md).

---

## Quick start

**Download** the SD card image (unofficial, built from these sources):
[releases/image-2026-10-24i](https://github.com/haiku-pi/haiku-rpi/releases/tag/image-2026-10-24i) — 341 MB,
`haiku-pi4-2026-10-24i.img.xz`, for an 8 GB or larger card:

```sh
xz -dc haiku-pi4-2026-10-24i.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

Or build the image yourself on an x86-64 Linux host and write it to a microSD card:

```sh
git clone https://github.com/haiku-pi/haiku-rpi.git && cd haiku-rpi
scripts/bootstrap.sh                       # sources, Haiku's arm64 cross tools, upstream packages, firmware
scripts/build-uboot.sh                     # U-Boot for the Pi 4
scripts/build.sh @minimum-mmc              # first Haiku build: haiku_devel + host tools for the next step
scripts/build-packages.sh --sysroot        # our arm64 packages: Mesa, SDL2, ffmpeg, WebKit, ...
scripts/build.sh -sHAIKU_PI_GL=1 @pi-mmc   # the regular image -> artifacts/images/haiku-pi4-regular.img
sudo dd if=artifacts/images/haiku-pi4-regular.img of=/dev/sdX bs=4M conv=fsync status=progress
```

Before `bootstrap.sh`, install the host packages and build Haiku's `jam`, as described in [docs/BUILD.md](docs/BUILD.md).
Check `/dev/sdX` before you run `dd`, because it overwrites the whole device. Then put the card in the Pi, connect
HDMI, a USB keyboard and mouse and Ethernet, and power on. The desktop appears after about 75 seconds.

- **First time?** Follow [TUTORIAL.md](TUTORIAL.md). It walks through the whole path: hardware, build, flashing,
  first boot and what to try.
- **Building in depth:** [docs/BUILD.md](docs/BUILD.md) covers host setup, image options, the heavy optional
  builds (Firefox, games, Rust), the package repository and troubleshooting.
- **Booting from the network** without writing cards: [TUTORIAL-NETBOOT.md](TUTORIAL-NETBOOT.md).
- **Short version:** [docs/TRY-IT.md](docs/TRY-IT.md) has what works and how to build, all on one page.

---

## What works

These numbers were measured on the bench Pi (4 GB) between 2026-10-18 and 2026-10-21. The full table, with drivers
and limits, is [docs/HARDWARE-SUPPORT.md](docs/HARDWARE-SUPPORT.md).

| Area | State |
|---|---|
| Boot | SD card → U-Boot → Haiku's EFI loader → kernel → desktop in about 75 s. Over the network (the boot volume served by the build host): about 55 s |
| CPU | 4 × Cortex-A72 (SMP). The clock follows the load from 600 to 1500 MHz. Temperature, throttling and clocks are in `/dev/power/bcm2835_thermal/0` |
| Display | HDMI at the monitor's native mode (1920×1080 on the bench), with lower modes scaled by the firmware. Hardware cursor and 60 Hz retrace |
| GPU | V3D 4.2 through Mesa 26.2: OpenGL 2.1, OpenGL ES 3.1 and **Vulkan 1.3** (V3DV), drawing into ordinary Haiku windows |
| Games | QuakeSpasm 56–70 fps at 1280×720 · Yamagi Quake II 81–89 fps · vkQuake (Vulkan) 52 fps · OpenArena 46 fps · SuperTuxKart 1.5 28–38 fps |
| Video | ffmpeg 6.1 codecs in the media kit. **HEVC is decoded by the SoC's decoder block**: 1080p at about 115 fps (bit-exact), 4K at about 38 fps |
| Audio | HDMI (48 kHz stereo, from image-2026-10-24e) and the 3.5 mm headphone jack (44.1 kHz stereo), through the media kit |
| Storage | SD card at UHS-I DDR50 (about 43 MB/s read); USB 3 storage through the VL805 (80–90 MB/s) |
| Network | Gigabit Ethernet (GENET), TCP about 915 Mbit/s each way; WiFi (BCM43455, WPA2); NFSv4 client |
| Bluetooth | The on-board controller works through Haiku's Bluetooth stack: firmware patching and inquiry. Pairing is untested |
| Web | WebPositive (HaikuWebKit, JavaScript JIT) and NetSurf; **Firefox 157** with WebGL 1/2 and H.264, VP9, AV1 and HEVC playback |
| Windows programs | **Wine 11.20** with x86 translation: 32-bit x86 programs through Box64, x86-64 programs through FEX (`pkgman install wine wine_x86 wine_x86_64`). Heroes III, StarCraft, SimCity 3000, Half-Life (also full screen; a game's display mode becomes the screen's, scaled by the display hardware), Chocolate Doom and OpenTTD (x86-64) play; Direct3D 9 on the V3D |
| Software | Python 3.14, Rust 1.90 (cross-compiled), SQLite, llama2.c, and the published arm64 package repository |

Known limits are collected in [docs/KNOWN-ISSUES.md](docs/KNOWN-ISSUES.md). The main ones: HDMI audio only with a monitor connected at boot, video in Firefox
drops frames for the first seconds after the browser starts, and the USB keyboard and mouse enumerate but have
not yet been tried by hand. Firefox and the games are in the public package repository (`pkgman install firefox`,
`pkgman install openarena`, `pkgman install supertuxkart`).

---

## Software and packages

`pkgman` works on the first boot. The image's HaikuPorts repository is this port's own arm64 build,
[haiku-pi.github.io/packages](https://github.com/haiku-pi/packages): Mesa, SDL2, ffmpeg, HaikuWebKit, NetSurf,
OpenSSL, curl, Python and more. Haiku's own arm64 system repository is configured as well:

```sh
pkgman install git vim openssh      # or firefox, openarena, supertuxkart, sqlite_devel, ...
```

How packages are built and published is covered in [docs/BUILD.md](docs/BUILD.md). The patches we apply to
third-party software are in `patches/`.

---

## Documentation

| Document | For |
|---|---|
| [TUTORIAL.md](TUTORIAL.md) | First-time users: from nothing to the desktop on your Pi |
| [docs/USER-GUIDE.md](docs/USER-GUIDE.md) | Everything in the image and how to use it: desktop, GPU, games, video, audio, browsers, network, packages, troubleshooting |
| [docs/BUILD.md](docs/BUILD.md) | Building every part, image options, flashing, the package repository, build troubleshooting |
| [TUTORIAL-NETBOOT.md](TUTORIAL-NETBOOT.md) | Booting the Pi from the build host over Ethernet (the fast development loop) |
| [docs/HARDWARE-SUPPORT.md](docs/HARDWARE-SUPPORT.md) | Which BCM2711 block has which driver, its state, measured speed and limits |
| [docs/KNOWN-ISSUES.md](docs/KNOWN-ISSUES.md) | Open problems, how often they happen and workarounds |
| [docs/HAIKU-RPI4-CHANGES.md](docs/HAIKU-RPI4-CHANGES.md) | Every change this fork makes to Haiku, grouped by area |
| [SHOWCASE.md](SHOWCASE.md) | Highlights and screenshots |
| [docs/LAB-SETUP.md](docs/LAB-SETUP.md) | The test bench: serial console, HDMI capture, power switch, netboot server, scripts |
| [docs/AI-DRIVEN-PORT-JOURNEY.md](docs/AI-DRIVEN-PORT-JOURNEY.md) | A field report on how an AI agent did this port |
| [docs/OWNER-PROMPTS.md](docs/OWNER-PROMPTS.md) | Every prompt the owner wrote, verbatim |
| [docs/PLAN.md](docs/PLAN.md) | Milestones and their state |
| [docs/log/](docs/log/) | The weekly work log: every step, measurement and decision |
| [docs/design/](docs/design/) | Design notes: GPU, PCIe, Ethernet, WiFi, network boot, video decode, packages, Wine |
| [AGENTS.md](AGENTS.md) | Rules for working in this repository (people and agents) |

---

## Repository layout

```
README.md, TUTORIAL*.md, SHOWCASE.md   start here
AGENTS.md, CLAUDE.md                   working rules (CLAUDE.md is the agent's boot sequence)
local.conf.example                     bench settings: serial port, power switch, capture card, Pi LAN interface
scripts/                               build, image, package, bench and test-cycle scripts (usage at the top of each)
tools/build/UserBuildConfig            the image definition: profiles, packages, options
tools/pi-tests/                        boot scripts that run one test on the Pi and print a verdict
tools/gl-tests/, media-tests/, ...     small test programs (GL, Vulkan, retrace, media, Bluetooth, Rust)
patches/                               our patches to third-party software (SDL2, Firefox, WebKit, ...)
manifests/                             tested combinations of source revisions
docs/                                  the documents above, design notes, the weekly log, screenshots
sources/                               (created by bootstrap.sh, not in git) the Haiku fork, buildtools, HaikuPorts, ...
artifacts/                             (not in git) build output: images, packages, UART logs, HDMI captures
```

---

## How the port is maintained

- Upstream Haiku is merged into the fork every weekend (`scripts/upstream-sync.sh`). Our changes are not sent
  upstream for now.
- Third-party components are pinned to stable releases (Mesa 26.2, ffmpeg 6.1, Firefox 157, ...), never to a
  rolling branch.
- Every change is tested on a real Pi 4 before it is called done, through the bench scripts described in
  [docs/LAB-SETUP.md](docs/LAB-SETUP.md).
- Windows programs run through Wine with x86 and x86-64 translation: how it is built and what is open is in
  [docs/design/wine-x86.md](docs/design/wine-x86.md).

## License

Haiku is distributed under the MIT license (some components under other open-source licenses; see the fork's
`License` directory). Third-party software keeps its own license, and our patches to it are under that same
license. Game data (Quake shareware, Quake II demo) is not in this repository, and the build scripts expect you
to supply it.
