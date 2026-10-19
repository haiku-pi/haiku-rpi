# Try Haiku on a Raspberry Pi 4

The **regular Haiku image** for the Pi 4: the full desktop with Haiku's applications, preferences and
media kit, plus this port's drivers and the ported libraries. Everything below was measured on the
bench Pi (4 GB, rev 1.4) on 2026-10-19 unless it says otherwise.

## What works

| Area | State |
|---|---|
| Boot | SD card → U-Boot → Haiku loader → desktop in about 80 s (first boot a little longer) |
| Display | HDMI at the monitor's native mode (1920×1080 here); lower modes in Screen preferences, scaled by the firmware; hardware cursor; 60 Hz retrace |
| GPU | V3D 4.2 through Mesa: OpenGL 2.1 (desktop) / OpenGL ES 3.1. GLTeapot, GLInfo and the GL screen savers (Flurry, GLife, Gravity) are in the image |
| Games (test images) | QuakeSpasm: 61–71 frames/s at 640×480. Yamagi Quake II, GL1 renderer: 80–148 frames/s at 640×480, 36–46 at 1280×720 |
| Audio | 3.5 mm headphone jack through the media kit ("Raspberry Pi headphones", 44.1 kHz stereo); measured on the bench, **not yet listened to** |
| Media | ffmpeg 6.1 codecs for the media kit: MediaPlayer, Ogg/Vorbis, MP3, AAC, H.264, VP8/9, ... (software decoding) |
| CPU | 4 cores (SMP) |
| Storage | SD card at UHS-I DDR50 (~32 MB/s reads); USB 3 storage through the VL805 (~80–90 MB/s) |
| USB | keyboard, mouse, hubs, storage (VL805 xHCI over PCIe); keyboard/mouse input still needs a hands-on check |
| Network | Gigabit Ethernet (GENET, DHCP); WiFi (BCM43455: scan, WPA2, DHCP, verified by a boot script that joins through net_server, `scripts/wifi-join-image.sh`; joining from Network preferences takes the same path but has not been tried by hand); NFSv4 client |
| Other | SoC temperature/throttling (`/dev` thermal driver), GPIO driver |

Known limits: no HDMI audio, no package repository for `pkgman` yet (software comes in the image), no
web browser yet (WebKit needs the package farm), the games are not packaged (see below), and a rare
boot-time stall of CPU 0 that the kernel's GIC watchdog recovers (about 1 boot in 20; the desktop still
comes up).

## Build the image

On an x86-64 Linux host (Ubuntu or similar) with a systemd user session (the heavy build steps run
in a memory-capped `systemd-run --user` scope).

**Host prerequisites:** Haiku's own `jam` — after `bootstrap.sh`, `make -C sources/buildtools/jam` and
`export PATH="$PWD/sources/buildtools/jam/bin.linuxx86:$PATH"` (the directory is called that on x86-64
too) — and the packages
`git curl xz-utils gcc g++ make bison flex texinfo autoconf automake libtool pkgconf nasm zlib1g-dev
libssl-dev libgnutls28-dev uuid-dev gcc-aarch64-linux-gnu meson ninja-build cmake python3-mako
python3-yaml mtools fdisk device-tree-compiler unzip`.

```sh
git clone https://github.com/haiku-pi/haiku-rpi.git && cd haiku-rpi
scripts/bootstrap.sh            # sources (pinned), Haiku's arm64 cross tools, upstream packages, firmware
scripts/build-uboot.sh          # U-Boot for the Pi 4 (needs aarch64-linux-gnu-gcc)
scripts/build.sh @minimum-mmc   # first Haiku build: haiku_devel and the host tools the next step uses
scripts/build-packages.sh --sysroot   # our packages: Mesa, SDL2, ffmpeg, zstd, base tools, ...
scripts/build.sh -sHAIKU_PI_GL=1 @pi-mmc   # the regular image
```

The result is `artifacts/images/haiku-pi4-regular.img` (about 1.1 GB).

Verified from scratch in a fresh clone on 2026-10-19: about 24 minutes on a 16-thread host (bootstrap
15 of them), same image. Expected noise while jam still exits 0: on a fresh tree the first build prints
a few `stdlib.h`/`math.h: No such file` lines (catalog extraction running before the toolchain packages
are unpacked), and the regular build prints WonderBrush's `bitmap_compression.h`/`blending.h` lines.

## Flash and boot

Write it to an SD card (all data on the card is lost; check the device name first):

```sh
sudo dd if=artifacts/images/haiku-pi4-regular.img of=/dev/sdX bs=4M conv=fsync status=progress
```

Put the card in the Pi, connect HDMI (and USB keyboard/mouse, Ethernet), power on. The rainbow
screen, U-Boot and the Haiku boot log pass by; the desktop appears after about 80 s. A serial console
(115200 8N1 on GPIO 14/15) shows the kernel log.

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
