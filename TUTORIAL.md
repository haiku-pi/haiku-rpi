# Haiku on the Raspberry Pi 4: First-Time Tutorial

This tutorial takes you from a fresh clone of this repository to the Haiku desktop on your Raspberry Pi 4, in one
pass. It covers the hardware you need, the build, flashing the SD card, the first boot and what to try first.
Afterwards, the [User Guide](docs/USER-GUIDE.md) describes everything in the image, and [docs/BUILD.md](docs/BUILD.md)
explains each build step in more depth, with all the options.

> **Hardware tested:** only a **Raspberry Pi 4 Model B with 4 GB RAM**. Haiku reads the memory size from the
> device tree the firmware passes it, so the 1, 2 and 8 GB models should work, but nobody has tried them. The
> Raspberry Pi 400 and the Compute Module 4 are untested as well. The Pi 5 is a different SoC and will not boot
> this image.

---

## 1. What you'll need

**Hardware**

- A Raspberry Pi 4 Model B (4 GB tested; see the note above).
- A microSD card of **2 GB or more**. The regular image is about 1.1 GB, and about 1.8 GB with the games.
  The partitions are as large as the image, so the rest of a bigger card stays unused for now.
- A USB-C power supply for the Pi 4 (the official 5 V / 3 A one or equivalent). A weak supply makes the
  firmware throttle the CPU.
- A display on **micro-HDMI**: the port nearest the USB-C jack (HDMI 0). The second HDMI port is not used.
- A **USB keyboard and mouse**. They are detected and get input devices, but this port's author (an AI agent)
  has no hands: typing and pointing have not been checked by a person yet. Please report what you find.
- **Ethernet** is recommended for `pkgman` and the browsers. WiFi works as well (section 6).
- *Optional:* a USB-to-serial (3.3 V UART) adapter on the GPIO header, to watch the boot log: GND on pin 6,
  adapter RX on pin 8 (GPIO 14, Pi TX), adapter TX on pin 10 (GPIO 15, Pi RX), **115200 8N1**.

**Build host**

- An **x86-64 Linux** machine. Ubuntu was used for this port; other distributions with the same packages
  should work. A systemd user session is needed, because the heavy build steps run in a memory-capped
  `systemd-run --user` scope.
- **Plan for at least 40 GB of free disk.** On the bench, `sources/` with its build trees takes about 20 GB, and
  the images and packages come on top. The optional Firefox and game builds need more (see
  [docs/BUILD.md](docs/BUILD.md)).
- **RAM:** the port is built on a 16-thread host with 32 GB. Less RAM works with fewer parallel jobs:
  `scripts/heavy-build.sh` caps the jobs at one per 2 GB available, because a WebKit compile job takes 1–2 GB.
- An internet connection: the bootstrap downloads the Haiku sources, the cross-compiler sources, upstream Haiku
  packages and the Pi firmware.

You do not need a Pi to build, only to run the result.

---

## 2. Prepare the build host

Install the host packages (Ubuntu names):

```sh
sudo apt install git curl xz-utils gcc g++ make bison flex texinfo autoconf automake libtool pkgconf nasm \
    zlib1g-dev perl ruby unifdef libssl-dev libgnutls28-dev uuid-dev gcc-aarch64-linux-gnu meson ninja-build \
    cmake python3-mako python3-yaml mtools fdisk device-tree-compiler unzip gperf
```

Clone this repository and fetch everything else:

```sh
git clone https://github.com/haiku-pi/haiku-rpi.git
cd haiku-rpi
scripts/bootstrap.sh
```

`bootstrap.sh` clones the Haiku fork (`haiku-pi/haiku`, branch `rpi4`), Haiku's buildtools, HaikuPorts and the
other sources into `sources/`, at the revisions this port pins. It also builds Haiku's arm64 cross compiler and
downloads the upstream Haiku packages and the Raspberry Pi firmware. On a 16-thread host it took about
16 minutes (measured on 2026-10-19).

Haiku builds with its own version of `jam`, which `bootstrap.sh` has now fetched. Build it and put it on your
`PATH`:

```sh
make -C sources/buildtools/jam
export PATH="$PWD/sources/buildtools/jam/bin.linuxx86:$PATH"   # the directory is called that on x86-64 too
```

---

## 3. Build the image

Run these four steps in order:

```sh
scripts/build-uboot.sh                     # U-Boot for the Pi 4 (the boot loader before Haiku's own)
scripts/build.sh @minimum-mmc              # a first, small Haiku build: haiku_devel and host tools
scripts/build-packages.sh --sysroot        # our arm64 packages: Mesa, SDL2, ffmpeg, WebKit, NetSurf, ...
scripts/build.sh -sHAIKU_PI_GL=1 @pi-mmc   # the regular image
```

The result is **`artifacts/images/haiku-pi4-regular.img`**, about 1.1 GB.

How long it takes: from a fresh clone to the image, about 28 minutes on a 16-thread host, measured on
2026-10-19. Since then WebKit has joined `build-packages.sh` and adds about an hour. If that step is interrupted,
run it again: `scripts/build-webkit.sh` resumes where it stopped.

Some messages look like errors but are expected. If every step exits with status 0, you can ignore them:

- a certificate error from a GNU mirror while fetching tar and libiconv (the fetch falls back to ftp.gnu.org);
- three `arm64/Jamfile: No such file` lines (hyperv, disasm, ltrace);
- in the regular build, "No such file" lines for `jpeglib.h`, `png.h` and WonderBrush's
  `bitmap_compression.h` / `blending.h`, which come from catalog extraction.

**Optional: the games.** OpenArena and SuperTuxKart can be added to the Applications menu. The image grows to
about 1.8 GB:

```sh
scripts/build-games.sh && scripts/build-stk.sh && scripts/package-games.sh   # once
scripts/build.sh -sHAIKU_PI_GL=1 -sHAIKU_PI_GAMES=1 @pi-mmc
```

**Optional: Firefox.** It is part of the regular image's package list, but it needs its own Rust toolchain and
about an hour and a half more, so the steps above leave it out (the build only warns
`package firefox not available!`). To include it, run these before the last step:

```sh
scripts/build-rust.sh       # Rust 1.90 for arm64 Haiku, ~21 min
scripts/build-firefox.sh    # Firefox 157, ~1 h; resumable
```

The Quake engines and other test programs are separate builds too. [docs/BUILD.md](docs/BUILD.md) has them all.

---

## 4. Flash the SD card

Put the card in the host's card reader and find its device name. Look for the size of your card:

```sh
lsblk -d -o NAME,SIZE,MODEL,TRAN
```

Write the image. **Everything on the card is lost, and a wrong device name destroys another disk**, so check the
name twice. Replace `/dev/sdX` with your card:

```sh
sudo umount /dev/sdX* 2>/dev/null
sudo dd if=artifacts/images/haiku-pi4-regular.img of=/dev/sdX bs=4M conv=fsync status=progress
sync
```

Raspberry Pi Imager works too: choose "Use custom" and select the `.img` file.

The card then holds a FAT boot partition, with the Pi firmware, U-Boot and Haiku's EFI loader, and the Haiku
system partition (BFS).

---

## 5. First boot

1. Put the card in the Pi. Connect HDMI (port 0, next to USB-C), the keyboard, the mouse and Ethernet.
2. Plug in the power. Things appear in this order:
   - the firmware's rainbow square, then U-Boot's text for a few seconds;
   - Haiku's boot splash, where the icons light up one by one as the kernel brings up its drivers;
   - **the desktop, after about 80 seconds**: the Deskbar in the top-right corner and Tracker's desktop icons.
     The first boot takes a little longer, because Haiku sets up its settings and grows its partition.
3. If a serial adapter is connected, the kernel log scrolls by at 115200 baud.

Nothing on the screen? Then go to [section 8](#8-troubleshooting).

---

## 6. Using the system

Haiku is a desktop operating system. If you have not used it before:

- The **Deskbar** (the panel in the top-right corner) holds the application menu (the leaf icon), the running
  applications and the clock.
- **Tracker** is the file manager and the desktop. Double-click "Haiku" on the desktop to open the system volume.
- **Terminal** is in Applications. The shell is bash.
- Preferences such as **Screen** (resolution), **Network** and **Sounds** are in the leaf menu under Preferences.

On the network:

- **Ethernet** gets its address by DHCP automatically. The clock is set by NTP once the network is up, because
  the Pi has no battery-backed clock.
- **WiFi:** open Preferences → Network, pick the wireless interface and join your network. The join path has been
  verified by a script; doing it by hand has not been tried yet. From Terminal it is
  `ifconfig /dev/net/broadcomfmac/0 join <SSID> <password>`. The [User Guide](docs/USER-GUIDE.md) has the details.

---

## 7. What to try

| Try | How |
|---|---|
| Browse the web | **WebPositive** (or **Firefox**, if you built it) in Applications. https://www.haiku-os.org/ renders in both |
| See the GPU at work | **GLTeapot** in Applications (OpenGL on the V3D); the GL screen savers in Preferences → ScreenSaver |
| Play a game | Images built with `-sHAIKU_PI_GAMES=1`: **OpenArena** and **SuperTuxKart** in Applications |
| Watch a video | **MediaPlayer**. HEVC (H.265) files are decoded by the SoC's hardware decoder |
| Look at the hardware | About Haiku (leaf menu) shows the 4 Cortex-A72 cores and the RAM. In Terminal, `cat /dev/power/bcm2835_thermal/0` shows temperature and clocks, `listusb` the USB devices |
| Install software | `pkgman install <package>`, e.g. `pkgman install sqlite_devel`, from our arm64 repository |
| Program | `python3` (3.14, with readline line editing) |

---

## 8. Troubleshooting

| Symptom | What to check |
|---|---|
| Black screen, no rainbow square | The card or the power. Re-flash the card and check that `dd` reported the full size. Use the HDMI port next to USB-C |
| The rainbow square stays | The firmware did not find its files. Was the image written to the whole device (`/dev/sdX`), not to a partition (`/dev/sdX1`)? |
| U-Boot text, then nothing | Connect a serial adapter and read the log: the last lines show where the boot stopped. Please report it with the log |
| The splash stops with some icons lit | A driver stopped the boot. Wait two minutes, then power-cycle. If it repeats, report it with the serial log |
| The desktop is very slow and the log mentions throttling | Under-voltage or heat. Use a 3 A supply. `cat /dev/power/bcm2835_thermal/0` shows the throttling flags |
| No network | Ethernet: check the cable and that your network has a DHCP server. `ifconfig` shows the address |
| `pkgman` fails with certificate errors | The clock was not set yet because NTP had not answered. Wait a minute after the network comes up |

More problems and their workarounds are in the [User Guide](docs/USER-GUIDE.md) and in
[docs/KNOWN-ISSUES.md](docs/KNOWN-ISSUES.md). To iterate quickly without writing cards, boot the image from your
build host over Ethernet: [TUTORIAL-NETBOOT.md](TUTORIAL-NETBOOT.md).
