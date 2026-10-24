# Try Haiku on a Raspberry Pi 4

The **regular Haiku image** for the Pi 4: the full desktop with Haiku's applications, preferences and
media kit, plus this port's drivers and the ported libraries. Everything below was measured on the
bench Pi (4 GB) on 2026-10-19/20 unless it says otherwise (last update: 2026-10-21).

**Download:** a ready-to-flash image is on the
[releases page](https://github.com/haiku-pi/haiku-rpi/releases/tag/image-2026-10-24d)
(`haiku-pi4-2026-10-24d.img.xz`, 340 MB; 8 GB card or larger; written with
`xz -dc haiku-pi4-2026-10-24d.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress` or Raspberry Pi
Imager's "Use custom"). It is this page's regular image, built 2026-10-23, booted from a card before publishing.
Wine (`pkgman install wine wine_x86 wine_x86_64`) needs this image or a newer one.

This page is the short version. The full documents: [TUTORIAL.md](../TUTORIAL.md) (first time, step by step),
[USER-GUIDE.md](USER-GUIDE.md) (using everything), [BUILD.md](BUILD.md) (building, all options),
[HARDWARE-SUPPORT.md](HARDWARE-SUPPORT.md), [KNOWN-ISSUES.md](KNOWN-ISSUES.md).

## What works

| Area | State |
|---|---|
| Boot | SD card → U-Boot → Haiku loader → desktop in about 75 s (first boot a little longer); or **from the network**, the boot volume served by the build host (below) |
| Display | HDMI at the monitor's native mode (1920×1080 here); lower modes in Screen preferences or from a fullscreen game (SDL), scaled to the monitor by the firmware; hardware cursor; 60 Hz retrace |
| GPU | V3D 4.2 through Mesa: OpenGL 2.1 (desktop) / OpenGL ES 3.1, and **Vulkan 1.3** (V3DV, presenting into Haiku windows; SDL2's Vulkan windows). GLTeapot, GLInfo and the GL screen savers (Flurry, GLife, Gravity) are in the image |
| Games (OpenArena + SuperTuxKart: packages, `-sHAIKU_PI_GAMES=1`; the Quakes: test images) | QuakeSpasm (demo1, in a window): 66–72 frames/s at 640×480, 56–70 at 1280×720, 30–43 at 1920×1080. Yamagi Quake II, GL1 renderer: 135–171 frames/s at 640×480, 81–89 at 1280×720. **vkQuake** (Vulkan): 52 fps at 1280×720. **OpenArena** (Quake III engine, ioquake3): 46 fps at 1280×720, 22–29 at 1920×1080. **SuperTuxKart 1.5**: 28–38 fps at 1280×720 (its OpenGL 2.1 renderer). A fullscreen game at 1280×720 switches the display mode (OpenArena: 46.8 fps, against 26 at 1920×1080) |
| Audio | 3.5 mm headphone jack through the media kit ("Raspberry Pi headphones", 44.1 kHz stereo); measured on the bench, **not yet listened to** |
| Media | ffmpeg 6.1 codecs for the media kit: MediaPlayer, Ogg/Vorbis, MP3, AAC, H.264, VP8/9, ...; **HEVC decoded by the SoC's decoder block** (bit-exact; 1080p at ~115 fps on under half a core, 4K at ~38 fps), the rest in software |
| CPU | 4 cores (SMP), 600–1500 MHz: the ARM clock follows the load (a cpufreq module; the minimum in the power saving scheduler mode), the core clock stays at 500 MHz; the firmware still throttles when hot. `cat /dev/power/bcm2835_thermal/0`: temperature, throttling, clocks. `time` and ProcessController tell user from kernel time |
| Storage | SD card at UHS-I DDR50 (~43 MB/s reads); USB 3 storage through the VL805 (~80–90 MB/s) |
| USB | keyboard, mouse, hubs, storage (VL805 xHCI over PCIe); the bench's Logitech K120 keyboard and Pixart mouse enumerate and get input devices (`/dev/input/keyboard/usb/0`, `/dev/input/mouse/usb/0`); typing and pointing still need a hands-on check |
| Network | Gigabit Ethernet (GENET, DHCP; TCP ~915 Mbit/s each way); WiFi (BCM43455: scan, WPA2, DHCP, verified by a boot script that joins through net_server, `scripts/wifi-join-image.sh`; joining from Network preferences takes the same path but has not been tried by hand); NFSv4 client |
| Web | **WebPositive** (HaikuWebKit 1.10, JavaScript JIT on) and NetSurf 3.11, both in the Applications menu: HTTPS through OpenSSL 3 and curl, CA certificates; the clock is set by NTP when the network comes up (the Pi has no battery clock). Verified: https://www.haiku-os.org/ renders in both |
| Bluetooth | The on-board controller (BCM43455) through Haiku's Bluetooth stack: patched at open, its address read, inquiries run. Start `bluetooth_server` (nothing starts it at boot, as on other Haiku systems); pairing devices is untested |
| Other | SoC temperature/throttling (`/dev` thermal driver), GPIO driver, the hardware random number generator (feeds `/dev/random`) |
| Software | **Python 3.14** in the image (ssl, sqlite3, ctypes, readline line editing, curses, ...); Rust 1.90 cross-compiles for it (`scripts/build-rust.sh`); llama2.c runs TinyStories models (46 tok/s on 4 cores); **Firefox 157** in the image (Applications menu; https://www.haiku-os.org/ in 8–10 s once started before; **WebGL 1 and 2** on the GPU; plays H.264, VP8/VP9, AV1 and HEVC — HEVC on the decoder block — frames drop only in the first seconds after the browser starts; `scripts/build-firefox.sh`) |

What still needs a person at the Pi (keyboard, mouse, audio by ear, a real monitor, WiFi from the preferences) is
listed step by step in [HANDS-ON-CHECKS.md](HANDS-ON-CHECKS.md).

Known limits: no HDMI audio; video in Firefox drops frames for the first seconds after the browser starts;
the first network boot of a Pi that was off for minutes stops at ~52 s about 1 time in 10 — power-cycle (SD boots are not affected; [KNOWN-ISSUES.md](KNOWN-ISSUES.md)).

**Software:** `pkgman` works out of the box: the image's HaikuPorts repository is ours,
[haiku-pi.github.io/packages](https://github.com/haiku-pi/packages) (arm64 builds of the HaikuPorts
recipes: Mesa, SDL2, ffmpeg, HaikuWebKit, NetSurf, OpenSSL, curl, ...), and Haiku's own arm64 system
repository is reachable too; e.g. `pkgman install sqlite_devel`.

## Build the image

On an x86-64 Linux host (Ubuntu or similar) with a systemd user session (the heavy build steps run
in a memory-capped `systemd-run --user` scope).

**Host prerequisites:** Haiku's own `jam` — after `bootstrap.sh`, `make -C sources/buildtools/jam` and
`export PATH="$PWD/sources/buildtools/jam/bin.linuxx86:$PATH"` (the directory is called that on x86-64
too) — and the packages
`git curl xz-utils gcc g++ make bison flex texinfo autoconf automake libtool pkgconf nasm zlib1g-dev
perl ruby unifdef libssl-dev libgnutls28-dev uuid-dev gcc-aarch64-linux-gnu meson ninja-build cmake python3-mako
python3-yaml mtools fdisk device-tree-compiler unzip gperf`.

```sh
git clone https://github.com/haiku-pi/haiku-rpi.git && cd haiku-rpi
scripts/bootstrap.sh            # sources (pinned), Haiku's arm64 cross tools, upstream packages, firmware
scripts/build-uboot.sh          # U-Boot for the Pi 4 (needs aarch64-linux-gnu-gcc)
scripts/build.sh @minimum-mmc   # first Haiku build: haiku_devel and the host tools the next step uses
scripts/build-packages.sh --sysroot   # our packages: Mesa, SDL2, ffmpeg, zstd, base tools, ...
scripts/build.sh -sHAIKU_PI_GL=1 @pi-mmc   # the regular image
```

The result is `artifacts/images/haiku-pi4-regular.img` (about 1.1 GB). Firefox is in it only if you ran
`scripts/build-rust.sh` and `scripts/build-firefox.sh` before the last step (about 1.5 hours more). With the games (OpenArena and
SuperTuxKart in the Applications menu; about 1.8 GB): `scripts/build-games.sh`, `scripts/build-stk.sh` and
`scripts/package-games.sh` once, then `scripts/build.sh -sHAIKU_PI_GL=1 -sHAIKU_PI_GAMES=1 @pi-mmc`. Or
install them on a running system: `pkgman install openarena supertuxkart` (their data comes in parts, each under
GitHub's 100 MiB file limit).

Verified from scratch in a fresh clone on 2026-10-19, NetSurf included: about 28 minutes on a 16-thread
host (bootstrap 16 of them, `build-packages.sh` 8). Since WebKit joined `build-packages.sh`, add about an
hour (its compile; `scripts/build-webkit.sh` resumes where an interrupted build stopped). Expected noise while every step still exits 0: a GNU
mirror's certificate error while fetching tar and libiconv (the fetch falls back to ftp.gnu.org), three
`arm64/Jamfile: No such file` lines (hyperv, disasm, ltrace), and in the regular build `jpeglib.h`/`png.h`
and WonderBrush's `bitmap_compression.h`/`blending.h` "No such file" lines from catalog extraction.

## Flash and boot

Write it to an SD card (all data on the card is lost; check the device name first):

```sh
sudo dd if=artifacts/images/haiku-pi4-regular.img of=/dev/sdX bs=4M conv=fsync status=progress
```

Put the card in the Pi, connect HDMI (and USB keyboard/mouse, Ethernet), power on. The rainbow
screen, U-Boot and the Haiku boot log pass by; the desktop appears after about 75 s. A serial console
(115200 8N1 on GPIO 14/15) shows the kernel log.

## Without a monitor: HDMI capture card + serial console

`scripts/pi-test.sh` runs an interactive session on a bench like ours (settings in `local.conf`, from
`local.conf.example`: serial device, a power switch command, the capture card): it can first write an
image to the card (`--regular`, or `--flash IMG`), powers the Pi on, shows the serial console live in the
terminal (and logs it) and opens a live window from the HDMI capture card; close the window to power the
Pi off.

```sh
scripts/pi-test.sh --regular        # write the regular image, then boot it and watch
scripts/pi-test.sh                  # boot whatever the card holds
```

## Boot from the network (no SD card writing)

For fast iteration the Pi can boot an image straight from the build host: the Pi's firmware loads its
boot files and a netboot U-Boot by TFTP, U-Boot loads the Haiku loader, and the loader and kernel read
the boot volume from the host as a remote disk (Haiku's `remote_disk`, served by
`remote_disk_server`). A freshly built image boots a minute later, without touching the card; whatever
Haiku writes goes to a copy of the image, made afresh each time. Desktop in about 90 s.

```sh
scripts/build-uboot.sh                    # also builds artifacts/uboot/u-boot-netboot.bin
scripts/build.sh remote_disk_server       # the server, built for the host
scripts/pi-test.sh --netboot artifacts/images/haiku-pi4-regular.img
```

Needs: the Pi LAN on its own host interface (`PI_LAN_HOST` in `local.conf`; the scripts run dnsmasq
for DHCP and TFTP on it) and a Pi whose boot order tries the network (the EEPROM's `BOOT_ORDER`; while
nothing answers on the network it boots from the card). Agents use `scripts/netboot-cycle.sh`. It is
not an NFS root: why, in [design/netboot.md](design/netboot.md).

## The games

```sh
scripts/build-games.sh          # needs Quake's shareware id1/pak0.pak and Quake II's demo baseq2/pak0.pak
scripts/mkimage-pi4.sh --add-tree artifacts/games/non-packaged --out artifacts/images/haiku-pi4-games.img
```

They land in `/boot/system/non-packaged/apps`. In Terminal:

```sh
cd /boot/system/non-packaged/apps/QuakeSpasm && ./quakespasm -basedir . -window -width 1280 -height 720
cd /boot/system/non-packaged/apps/quake2 && ./Quake2 +set vid_renderer gl1
```

## More

- Progress, measurements and decisions: [docs/log/](log/)
- Plan and milestones: [PLAN.md](PLAN.md)
- Design notes (GPU, Ethernet, package farm, ...): [design/](design/)
