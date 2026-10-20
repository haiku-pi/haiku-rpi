# Building and flashing Haiku for the Raspberry Pi 4

This guide takes you from an empty directory on an x86-64 Linux machine to a Raspberry Pi 4 that boots
Haiku from its SD card. Nothing beyond the Pi, an SD card, an HDMI monitor and a USB keyboard and mouse
is needed. The bench tools (serial console, power switch, HDMI capture card, a private Pi LAN) are
optional and are covered in [TRY-IT.md](TRY-IT.md) and the
[network boot tutorial](../TUTORIAL-NETBOOT.md).

The end result is `artifacts/images/haiku-pi4-regular.img` (1.09 GB): an SD card image with a FAT
partition (the Pi firmware, U-Boot and Haiku's EFI loader) and a BFS partition holding the regular Haiku
system — the desktop, Haiku's applications, the media kit, this port's drivers, the OpenGL/Vulkan stack,
WebPositive, NetSurf, Firefox and Python.

All numbers below were measured on the project's build host (AMD Ryzen 7 PRO 250, 8 cores / 16 threads,
29 GB RAM, Ubuntu 26.04) and its bench Pi (Raspberry Pi 4 Model B, 4 GB) between 2026-10-17 and
2026-10-21. Progress and the measurements behind them are in the weekly logs in [log/](log/).

## Contents

- [Prerequisites](#prerequisites)
- [Step 1 — Clone and bootstrap](#step-1--clone-and-bootstrap)
- [Step 2 — Build Haiku's jam and U-Boot](#step-2--build-haikus-jam-and-u-boot)
- [Step 3 — The first Haiku build](#step-3--the-first-haiku-build)
- [Step 4 — Our packages](#step-4--our-packages)
- [Step 5 — Firefox (optional, but part of the regular image)](#step-5--firefox-optional-but-part-of-the-regular-image)
- [Step 6 — The regular image](#step-6--the-regular-image)
- [Image profiles and options](#image-profiles-and-options)
- [What the image contains](#what-the-image-contains)
- [Making images: `mkimage-pi4.sh`](#making-images-mkimage-pi4sh)
- [The separate builds](#the-separate-builds)
- [Flash the SD card](#flash-the-sd-card)
- [Boot and verify](#boot-and-verify)
- [The package repository](#the-package-repository)
- [Rebuilding and updating](#rebuilding-and-updating)
- [Troubleshooting](#troubleshooting)

## Prerequisites

- **Host:** x86-64 Linux; Ubuntu 26.04 is what the project builds on, and the from-scratch build was
  verified there. The build runs directly on the host, no container or VM.
- **A systemd user session.** The memory-heavy steps (the Haiku build, Mesa, WebKit, Firefox, Rust) run
  through `scripts/heavy-build.sh`, which starts them in a memory-capped `systemd-run --user` scope.
  `systemctl --user status` must answer in the shell you build from.
- **`sudo`** only for installing packages, writing the SD card and (for network boot) starting dnsmasq.
  The build itself runs as your user.
- **A network connection** during the build: the bootstrap clones the sources, and several steps
  download pinned source tarballs, packages and firmware (each checked against a SHA-256).
- **A Raspberry Pi 4 Model B** and a microSD card of at least 2 GB (the regular image is 1.09 GB; the
  games image 1.8 GB). Only the 4 GB board has been tested.

### Disk space, memory and time

| What | Disk (reference host, 2026-10-20) | Time (reference host) |
|---|---|---|
| Sources: Haiku with its build output (5.6 GB), cross tools source (2.3 GB), Mesa (1.0 GB), U-Boot, HaikuPorts recipes | ~10 GB | clones: minutes |
| Our packages: cross-built ports (6.2 GB, the WebKit tree 2.6 GB of it), the sysroot, the packages | ~8 GB | see the steps |
| One image | 1.1 GB (games image 1.8 GB) | — |
| Firefox (optional): Rust 12 GB, Firefox sources 5.6 GB, Firefox objdir and stage 4.3 GB | ~22 GB | ~1.5 h |

Budget **30 GB** free for the regular image without Firefox and **55 GB** with it. Every image you make
adds 1–2 GB under `artifacts/images/`; delete old ones.

The from-scratch build (Steps 1–4 and 6, without WebKit and Firefox) took **about 28 minutes** on
2026-10-19: the bootstrap about 16 of them, `build-packages.sh` about 8. WebKit, which
`build-packages.sh` has built since then, adds **about an hour**; Firefox with its Rust toolchain about
**an hour and a half**.

Memory: `heavy-build.sh` runs as many jobs as fit into the available memory (1 GB per job for the Haiku
build, 2 GB by default, about 3 GB per WebKit compile job) and caps the whole build at 22 GB, so that a
build that still runs out of memory is killed rather than your desktop session. The Firefox build on the
29 GB host left about 4 GB available at its peak. Smaller hosts work with fewer jobs; nothing was measured
below 29 GB.

### Host packages

```sh
sudo apt-get update
sudo apt-get install -y git curl xz-utils gcc g++ make bison flex texinfo autoconf automake libtool \
  pkgconf nasm zlib1g-dev perl ruby unifdef gperf libssl-dev libgnutls28-dev uuid-dev \
  gcc-aarch64-linux-gnu meson ninja-build cmake python3-mako python3-yaml \
  mtools fdisk device-tree-compiler unzip
```

This is the list from [TRY-IT.md](TRY-IT.md), with which the from-scratch build was verified, plus
`gperf`, which the NetSurf and WebKit builds name as a host tool. Optional extras, by what needs them:

| Packages | Needed by |
|---|---|
| `glslang-tools spirv-tools` | vkQuake (`scripts/build-vkquake.sh`, from `build-games.sh`): its shaders are compiled on the host |
| `clang nodejs` (libclang 21) | Firefox (`scripts/build-firefox.sh`): bindgen reads the headers through the host's libclang, default `/usr/lib/llvm-21/lib`, or set `LIBCLANG_PATH` |
| `qemu-system-arm qemu-efi-aarch64` | `scripts/qemu-virt.sh`, `scripts/qemu-raspi.sh` (checking an image without a Pi) |
| `dnsmasq-base python3-serial` | network boot and the bench scripts (`scripts/netboot-server.sh`, the serial capture) |
| `ffmpeg` (with libx264, libvpx, libsvtav1) or `mpv` | `scripts/make-web-video-clips.sh`; the live HDMI preview of `scripts/pi-test.sh` |

## Step 1 — Clone and bootstrap

```sh
git clone https://github.com/haiku-pi/haiku-rpi.git
cd haiku-rpi
scripts/bootstrap.sh
```

The repository can live anywhere: every script finds the repository root from its own location. Run
everything below from the repository root.

`scripts/bootstrap.sh` is safe to re-run; it skips what is already there. It:

1. Clones the sources into `sources/` (git-ignored; each is its own git repository):

   | Directory | Repository | Branch / commit |
   |---|---|---|
   | `sources/haiku` | [haiku-pi/haiku](https://github.com/haiku-pi/haiku) — the Haiku fork with this port | `rpi4` |
   | `sources/buildtools` | [haiku-pi/buildtools](https://github.com/haiku-pi/buildtools) — Haiku's cross tools (gcc, binutils, jam) | default branch |
   | `sources/mesa` | [haiku-pi/mesa](https://github.com/haiku-pi/mesa) — Mesa 26.2 with the V3D/V3DV changes for Haiku | `rpi4` |
   | `sources/libdrm` | [haiku-pi/libdrm](https://github.com/haiku-pi/libdrm) | `rpi4` |
   | `sources/libglvnd` | [haiku-pi/libglvnd](https://github.com/haiku-pi/libglvnd) — libGL with Haiku's BGLView | `rpi4` |
   | `sources/haikuports` | [haikuports/haikuports](https://github.com/haikuports/haikuports) — the recipes the cross-built packages follow | pinned `c17ec5a8d2f0` |
   | `sources/u-boot` | [U-Boot](https://source.denx.de/u-boot/u-boot) | pinned `8d534cec` |

2. Fetches Haiku's `hrev*` tags from Haiku's own repository (review.haiku-os.org). The build names its
   revision after the newest tag, and neither the fork nor the GitHub mirror carries them.
3. Configures the Haiku arm64 build in `sources/haiku/generated.arm64` and builds the cross tools
   (gcc and binutils from `sources/buildtools`) under `heavy-build.sh`.
4. Downloads the upstream arm64 build packages (gcc_syslibs, zlib, ...) into jam's download directory
   (`scripts/fetch-build-packages.sh`). jam cannot fetch them itself here: our repository definition also
   lists our own packages, so its checksum names no directory on Haiku's server.
5. Fetches the Raspberry Pi firmware (`start4.elf`, `fixup4.dat`, the `bcm2711-rpi-4-b.dtb` device tree,
   two overlays) from [raspberrypi/firmware](https://github.com/raspberrypi/firmware), pinned to commit
   `6c87074190d5`, into `artifacts/pi-firmware/` (`scripts/fetch-pi-firmware.sh`).

The other downloads happen where they are needed: the WiFi and Bluetooth firmware when an image is made
(`scripts/fetch-wifi-firmware.sh`: linux-firmware tag `20260810` and RPi-Distro's bluez-firmware, pinned
by SHA-256 and never committed, since their licences differ from the source tree's), the HaikuPorts
recipes' sources and the "any"-architecture packages (fonts, sounds, the user guide) from Haiku's x86_64
repository in Step 4.

## Step 2 — Build Haiku's jam and U-Boot

Haiku builds with its own `jam`, which is in `sources/buildtools`:

```sh
make -C sources/buildtools/jam
export PATH="$PWD/sources/buildtools/jam/bin.linuxx86:$PATH"
```

The directory is called `bin.linuxx86` on x86-64 too. The `export` holds for the current shell only:
repeat it in every new shell, or put the directory on your `PATH` permanently.

Then U-Boot, which the Pi's firmware starts and which provides the UEFI environment Haiku's loader runs
in:

```sh
scripts/build-uboot.sh
```

It applies `patches/u-boot/*.patch` to a clean `sources/u-boot` tree (it discards any local change there
first) and builds two variants: `sources/u-boot/u-boot.bin` for SD cards, and
`artifacts/uboot/u-boot-netboot.bin` for [network boot](../TUTORIAL-NETBOOT.md). The two patches: the
frame buffer's pixel order (without it the colours are swapped), and the Ethernet controller's transmit
clock delay (without it U-Boot sends no frame at gigabit).

## Step 3 — The first Haiku build

```sh
scripts/build.sh @minimum-mmc
```

This builds Haiku's minimum image and, on the way, what the next step needs: `haiku_devel` (headers and
libraries), the host tools (`package`, `bfs_shell`, `package_repo`) and the libraries the ports link.
`scripts/build.sh`:

- links [`tools/build/UserBuildConfig`](../tools/build/UserBuildConfig) into the Haiku tree (the port's
  build options, below);
- runs `jam -q -sHAIKU_NO_DOWNLOADS=1 <your arguments>` in `sources/haiku/generated.arm64` under
  `heavy-build.sh` (`@minimum-mmc` when you give no arguments);
- writes the whole output to `artifacts/build/<timestamp>.log` and prints the error lines it finds, then
  `build: jam rc=<rc> log=<log>`;
- for an image target, turns jam's image into a Pi SD image with `scripts/mkimage-pi4.sh`; for
  `@minimum-mmc` that is `artifacts/images/haiku-pi4.img`.

`build.sh` takes any jam target, not only images: `scripts/build.sh remote_disk_server` builds the
network boot's disk server for the host, `scripts/build.sh rpivid` a single driver.

## Step 4 — Our packages

```sh
scripts/build-packages.sh --sysroot
```

Haiku has no official arm64 package repository for the software outside the base system, so this port
cross-builds what the image needs on the host, from the HaikuPorts recipes, as ordinary Haiku packages
(`.hpkg`). `--sysroot` first creates the arm64 cross sysroot in `artifacts/sysroot-arm64`
(`scripts/haiku-sysroot.sh`); later runs can leave it out. The script then builds, in order:

| Packages | Built by |
|---|---|
| mesa, mesa_devel, glu, glu_devel (libdrm, libglvnd, Mesa with the V3D OpenGL and V3DV Vulkan drivers, the Vulkan loader, GLU) | `scripts/build-gl-stack.sh` + `scripts/package-gl-stack.sh` |
| libogg, libvorbis, fluidlite, libsdl2 (with `patches/libsdl2`), zstd, libedit | `scripts/cross-port.sh` + `scripts/package-port.py` |
| ffmpeg6 (with HEVC on the Pi's decoder block) | `scripts/build-ffmpeg.sh` |
| gzip, tar, bzip2, unzip | `scripts/build-base-ports.sh` |
| NetSurf, OpenSSL 3, curl and their libraries | `scripts/build-netsurf.sh` |
| HaikuWebKit (WebPositive's engine) and its libraries | `scripts/build-webkit.sh` (about an hour) |
| python3.14 | `scripts/build-python.sh` |
| icu74 | `scripts/build-icu.sh` |
| fonts, sounds, the MIDI soundfont, the user guide, the WiFi drivers' firmware ("any" packages) | `scripts/fetch-any-packages.sh` (Haiku's x86_64 repository, SHA-256 pinned) |
| ncurses6_bootstrap (gives the ncurses bootstrap package its terminfo database) | `scripts/make-bootstrap-shim.sh` |

The packages land in `artifacts/packages/`, and the script copies all of them into jam's download
directory, `sources/haiku/generated.arm64/download/`, where the image build takes them from. It ends
with `build-packages: staged <N> packages in ...`.

If the WebKit build is interrupted, `scripts/build-webkit.sh` continues where it stopped; run it on its
own, then `cp artifacts/packages/*.hpkg sources/haiku/generated.arm64/download/` (or re-run
`build-packages.sh`).

## Step 5 — Firefox (optional, but part of the regular image)

The regular image profile includes Firefox 157, but `build-packages.sh` does not build it: it needs its
own Rust toolchain and takes much longer. **Without this step the image builds anyway and simply has no
Firefox** — jam only warns `AddHaikuImagePackages: package firefox not available!`. To include it:

```sh
scripts/build-rust.sh                  # rustc 1.90.0 for aarch64-unknown-haiku, ~21 min; ~12 GB of disk
scripts/build-firefox.sh               # Firefox 157.0.1, ~1 h of compiling; resumable
```

`build-firefox.sh` fetches and patches the Firefox source and builds `cbindgen` itself (through
`build-spidermonkey.sh`'s `source` and `hosttools` steps). It writes its package to
`artifacts/firefox/`, not to `artifacts/packages/` (so the public repository does not pick it up:
and copies it into `artifacts/packages/` (published) and `sources/haiku/generated.arm64/download/`, where
the image build takes it from (since 2026-10-21; before, that copy was a manual step). It is
zstd-compressed: 102 MB, under GitHub's 100 MiB file limit. The `-3` is the package revision, which must match
the one in `sources/haiku/build/jam/repositories/HaikuPorts/arm64`; see
[the package-bump rule](#the-package-bump-rule).

## Step 6 — The regular image

```sh
scripts/build.sh -sHAIKU_PI_GL=1 @pi-mmc
```

The result is `artifacts/images/haiku-pi4-regular.img` (1 086 324 736 bytes on 2026-10-20). Set
`PI_IMAGE_OUT` to write it elsewhere:

```sh
PI_IMAGE_OUT=artifacts/images/my-build.img scripts/build.sh -sHAIKU_PI_GL=1 @pi-mmc
```

After the first build, a rebuild after a source change takes 30–60 seconds (the regular-image builds of
2026-10-20).

The last lines of a good build look like this:

```
build: jam rc=0 log=artifacts/build/20261020-222709.log
mkimage-pi4: .../artifacts/images/haiku-pi4-regular.img (1086324736 bytes, firmware 6c87074190d5, u-boot 8d534cec)
::/EFI/
::/uEnv.txt
...
```

followed by the listing of the image's FAT partition. Check the log for `not available` (see
[Troubleshooting](#troubleshooting)): eleven such lines are expected, any other is a package of ours
that did not make it into the image.

## Image profiles and options

The image's content is chosen on the `build.sh` command line: a jam build profile and the port's options,
all defined in [`tools/build/UserBuildConfig`](../tools/build/UserBuildConfig).

| Profile | Image | Output |
|---|---|---|
| `@minimum-mmc` | Haiku's minimum image (also the default target of `build.sh`) | `artifacts/images/haiku-pi4.img` |
| `@pi-mmc` | **the regular image**: the regular build type (media kit and servers, MediaPlayer, the full set of applications and preferences, NetSurf, WebPositive) without the nightly profile's packages arm64 does not have yet (the Development and Git bundles, nano, openssh, ...), plus the packages listed in the next section; a 1000 MB volume | `artifacts/images/haiku-pi4-regular.img` |

| Option | Adds |
|---|---|
| `-sHAIKU_PI_GL=1` | the OpenGL stack (`mesa`, `glu` packages) and what jam builds once it is there: GLTeapot, GLInfo, libglut, the GL screen savers (Flurry, GLife, Gravity), and libmedia/libgame for SDL2. Always use it with `@pi-mmc` |
| `-sHAIKU_PI_GAMES=1` | OpenArena and SuperTuxKart as packages, in the Applications menu; a 1700 MB volume. Needs `-sHAIKU_PI_GL=1` and the game packages (see [the games](#the-games)) |
| `-sHAIKU_PI_DEV=1` | a development image: the arm64 build packages Haiku's servers carry (gcc, binutils, make, python3.10, haikuporter, ...) and `haiku_devel`; a 1800 MB volume. Used to build ports natively on the Pi or in QEMU ([design/package-farm-plan.md](design/package-farm-plan.md)) |

Options combine, e.g. the games image:

```sh
scripts/build.sh -sHAIKU_PI_GL=1 -sHAIKU_PI_GAMES=1 @pi-mmc
```

`build.sh` always passes `-sHAIKU_NO_DOWNLOADS=1`: our arm64 repository definition lists packages only
our download directory has, so jam builds the image's repository from that directory instead of
downloading.

## What the image contains

**The FAT partition** (partition 1, MBR type 0x0c), written by `scripts/mkimage-pi4.sh`:

- the pinned Pi firmware: `start4.elf`, `fixup4.dat`, `bcm2711-rpi-4-b.dtb`, `overlays/`;
- `u-boot.bin` and this `config.txt`:

  ```
  arm_64bit=1
  kernel=u-boot.bin
  # PL011 (uart0) on GPIO14/15 = the console; Bluetooth gets no UART.
  enable_uart=1
  dtoverlay=disable-bt
  # Lets the ARM side power the V3D GPU on (tools/overlays/haiku-v3d.dts)
  dtoverlay=haiku-v3d
  # The firmware's KMS node: vertical blanks as SMI interrupts (tools/overlays/haiku-fkms.dts)
  dtoverlay=haiku-fkms
  disable_overscan=1
  ```

  The two `haiku-*` overlays are compiled from `tools/overlays/` with `dtc` at image time;
- from Haiku's own image: `EFI/BOOT/BOOTAA64.EFI` (Haiku's EFI loader), which U-Boot's boot flow starts.

**The BFS partition** (partition 2) is the Haiku system jam built. For `@pi-mmc` it has, besides the
regular build type's content:

| | |
|---|---|
| Packages | `libogg libvorbis libsdl2 ffmpeg6`, the system sounds and the MIDI soundfont, `netsurf ca_root_certificates openssl3` (and TLS in Haiku's network kit), WebPositive (with `haikuwebkit`), `python3.14 libedit ncurses6 ncurses6_bootstrap`, `firefox`, `icu74`; with `HAIKU_PI_GL` also `mesa glu` |
| Settings | the user `user` ("Yourself"), host name `shredder`; Locale settings (English, so no first-boot language prompt) and Time settings that set the clock by NTP at boot (the Pi has no battery clock, and HTTPS needs a correct one) — generated by `tools/build/flatten-message.py`, in `tools/build/data/` |
| Firmware | the WiFi chip's firmware in `/boot/system/non-packaged/data/firmware/broadcomfmac/` and the Bluetooth patch file in `.../firmware/brcm/`, with their licences (added by `mkimage-pi4.sh`) |
| Package repositories | Haiku's arm64 system repository and, as "HaikuPorts", ours at https://haiku-pi.github.io/packages/arm64 |

What works on the Pi, with measured numbers, is in [TRY-IT.md](TRY-IT.md#what-works).

## Making images: `mkimage-pi4.sh`

`scripts/build.sh` calls `scripts/mkimage-pi4.sh` itself. You call it directly to make a variant of the
image jam built last, for example with extra programs, a test script or other boot settings, without
rebuilding:

```sh
scripts/mkimage-pi4.sh --out artifacts/images/haiku-pi4-games.img --add-tree artifacts/games/non-packaged
```

The input is jam's last image (`--in`, default `sources/haiku/generated.arm64/haiku-mmc.image`; the
`@pi-mmc` profile writes that file too), so it needs a finished jam image build, the host `bfs_shell` jam
built, and U-Boot (Step 2). Each option may be repeated; every file it writes is checked afterwards.

| Option | Effect |
|---|---|
| `--in IMAGE` | jam's image to start from |
| `--out IMG` | the SD image to write (default `artifacts/images/haiku-pi4.img`) |
| `--add-tree DIR` | DIR's files and symlinks, with their relative paths, into `/boot/system/non-packaged/`, e.g. the staging trees of the separate builds below |
| `--add-bin FILE` | FILE into `~/config/non-packaged/bin` (e.g. a test tool built by jam) |
| `--bootscript FILE` | installed as `~/config/settings/boot/UserBootscript`, run at every boot; what it writes to `/dev/dprintf` appears on the serial console (the project's test channel: `tools/pi-tests/`) |
| `--kernel-setting "name value"` | a line in the kernel settings file, e.g. `--kernel-setting "disable_smp true"` |
| `--config LINE` | a line appended to `config.txt`, e.g. `--config force_turbo=1` |
| `--block-entry PATH` | hides PATH of the `haiku` package (`BlockedEntries` in `/boot/system/settings/packages`), e.g. `--block-entry add-ons/kernel/drivers/graphics/v3d` to boot without a driver |
| `--no-v3d` | leaves out the `haiku-v3d` overlay: the V3D GPU stays off |
| `--no-fkms` | leaves out the `haiku-fkms` overlay: no vertical-blank interrupt, the display driver waits on the firmware instead |

## The separate builds

These are not part of the regular image's sequence. Each runs on its own, documents its usage in its
header comment, and runs its heavy part under `heavy-build.sh`. Times are as measured on the reference
host.

| Script | What | Output |
|---|---|---|
| `scripts/build-gl-stack.sh [--sysroot] [--reconfigure] [--only NAME]` | libdrm, libglvnd, Mesa (from `sources/`), GLU, the Vulkan loader, the GL test programs | `artifacts/gl-stack/non-packaged/` (for `--add-tree`); also installed into the sysroot |
| `scripts/package-gl-stack.sh [--revision N]` | the GL stack as `mesa`, `mesa_devel`, `glu`, `glu_devel` packages | `artifacts/packages/` |
| `scripts/build-webkit.sh [STEP]` | HaikuWebKit 1.10 and the libraries it needs; resumes an interrupted compile (`rm -rf artifacts/cross-ports/haikuwebkit-1.10.0/src` starts over); about an hour | `artifacts/packages/` |
| `scripts/build-netsurf.sh [PORT]` | NetSurf 3.11, OpenSSL 3, curl and NetSurf's libraries | `artifacts/packages/` |
| `scripts/build-python.sh [--no-host]` | CPython 3.14.8 (ssl, sqlite3, ctypes, readline on libedit, curses, ...); builds a host Python of the same version first | `artifacts/packages/` |
| `scripts/build-icu.sh [--revision N]` | ICU 74.1 with its data inside libicudata | `artifacts/packages/` |
| `scripts/build-ffmpeg.sh` | ffmpeg 6.1 with the `hevc_rpivid` hardware decoder | `artifacts/packages/` |
| `scripts/build-rust.sh [STEP]` | rustc 1.90.0 + cargo that cross-compile for `aarch64-unknown-haiku` (no Rust runs on Haiku); ~21 min; resumable; `source artifacts/rust/env.sh` to use it | `artifacts/rust/` |
| `scripts/build-spidermonkey.sh [STEP]` | Firefox's JavaScript shell `js` (JIT on); ~7 min at 10 jobs. Not needed for Firefox: `build-firefox.sh` runs this script's `source` and `hosttools` steps itself | `artifacts/spidermonkey-tests/non-packaged/` |
| `scripts/build-firefox.sh [STEP] \| --only STEP` | Firefox 157.0.1 (HaikuPorts' native Haiku port + our arm64 patches); ~1 h; resumable (the objdir is kept) | `artifacts/firefox/firefox-157.0.1-<rev>-arm64.hpkg`, `artifacts/firefox/non-packaged/` |
| `scripts/build-games.sh [--quake-data DIR] [--quake2-data DIR]` | SDL2 with Vulkan windows, QuakeSpasm, Yamagi Quake II, and (through the next two) vkQuake and ioquake3/OpenArena; needs Quake's shareware `id1/pak0.pak` and Quake II's demo `baseq2/pak0.pak` (not in git; `QUAKE_DATA`, `QUAKE2_DATA` in `local.conf`) and stops without them | `artifacts/games/non-packaged/` |
| `scripts/build-vkquake.sh [--quake-data DIR]` | vkQuake 1.35.0 on Vulkan | `artifacts/games/non-packaged/apps/vkQuake` |
| `scripts/build-q3.sh [--quake3-data DIR] [--no-openarena]` | ioquake3 with OpenArena 0.8.8's free data; Quake III when you have its data (`QUAKE3_DATA`) | `artifacts/games/non-packaged/apps/{OpenArena,Quake3}` |
| `scripts/build-stk.sh [--no-data] [--gles]` | SuperTuxKart 1.5 with the release's mobile-sized data (~180 MB); `--gles` adds the OpenGL ES build | `artifacts/stk/non-packaged/` |
| `scripts/package-games.sh [--revision N]` | `openarena` and `supertuxkart` packages from the two staging trees above; also copies them into jam's download directory | `artifacts/packages/` |
| `scripts/build-llama2.sh` | llama2.c with the TinyStories models | `artifacts/llama2/non-packaged/` |
| `scripts/build-bootstrap-tools.sh`, `scripts/build-python-modules.sh` | the tools haikuporter needs on a `-sHAIKU_PI_DEV=1` image | `artifacts/bootstrap-tools/`, `artifacts/python-modules/` |
| `scripts/make-web-video-clips.sh` | test clips (H.264, VP9, AV1, HEVC) for the browsers | `artifacts/media-tests/web/non-packaged/` |

A `non-packaged/` output goes into a test image with `mkimage-pi4.sh --add-tree DIR/non-packaged`. A
package goes into the image through jam: see [the package-bump rule](#the-package-bump-rule).

`scripts/cross-port.sh` and `scripts/package-port.py` are the general tools behind most of these: the
first cross-builds a HaikuPorts recipe on the host (`cmake`, `meson`, `autotools` or a `script`), the
second packages the result as `<port>` and `<port>_devel` hpkgs. Their headers explain the options.

### The games

OpenArena and SuperTuxKart are packages in the public repository; whole, both would be over GitHub's
100 MiB file limit, so `package-games.sh` puts their data in parts (`openarena_data_1..5`,
`supertuxkart_data_1..3`, each under the limit, zstd) that the game package requires. To build them and
an image with them, once:

```sh
scripts/build-games.sh          # needs the Quake data above; builds OpenArena too
scripts/build-stk.sh
scripts/package-games.sh
```

then build the games image with `-sHAIKU_PI_GAMES=1` ([above](#image-profiles-and-options), about 1.8 GB).
The engines without free data (QuakeSpasm, vkQuake, Yamagi Quake II) are not packaged: put them into a
test image with `--add-tree artifacts/games/non-packaged` as shown in
[Making images](#making-images-mkimage-pi4sh); they land in `/boot/system/non-packaged/apps`
([TRY-IT.md](TRY-IT.md#the-games) shows how to start them).

## Flash the SD card

The image is a whole disk (partition table and both partitions): write it to the card device, not to a
partition. **Writing to the wrong device destroys that disk.**

### Option A — `dd`

Insert the card and find its device:

```sh
lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINTS
```

The card is e.g. `/dev/sdX` (a USB reader) or `/dev/mmcblk0` (a built-in reader); use the device, not
`/dev/sdX1`. Unmount whatever the desktop mounted from it, then write (replace `/dev/sdX`):

```sh
sudo umount /dev/sdX?* 2>/dev/null
sudo dd if=artifacts/images/haiku-pi4-regular.img of=/dev/sdX bs=4M conv=fsync status=progress
sync
```

To check what was written, compare the card with the image (the card is larger; `-n` limits the
comparison to the image's size):

```sh
sudo cmp -n "$(stat -c %s artifacts/images/haiku-pi4-regular.img)" \
  artifacts/images/haiku-pi4-regular.img /dev/sdX && echo "card matches the image"
```

### Option B — Raspberry Pi Imager

Open [Raspberry Pi Imager](https://www.raspberrypi.com/software/), choose **Use custom** as the
operating system, select `artifacts/images/haiku-pi4-regular.img`, pick the card and write.

## Boot and verify

1. Put the card into the Pi, connect HDMI, a USB keyboard and mouse and, for the network, Ethernet. Power
   on.
2. The firmware's rainbow screen, U-Boot and Haiku's boot screen pass by; **the desktop appears after
   about 80 seconds** (the first boot is a little longer: the package daemon processes the packages
   once).
3. On a 3.3 V USB-serial adapter on GPIO 14/15 (115200 8N1) you see U-Boot, the loader and the kernel's
   log.

If the Pi seems to wait for a long time first: its EEPROM may try the network before the SD card. With
no DHCP server answering, the bench Pi spent about 58 s on that before it booted the card (2026-10-18).
The [network boot tutorial](../TUTORIAL-NETBOOT.md#5-the-pis-eeprom-boot-order) explains the boot order.

**Without a Pi**, `scripts/qemu-virt.sh` boots jam's last image on QEMU's generic arm64 machine (the
reference platform: what fails there is not a Pi problem). `--secs N` stops it after N seconds and
saves a screenshot to `artifacts/qemu/`:

```sh
scripts/qemu-virt.sh --secs 150
```

`scripts/qemu-raspi.sh --image IMG` boots a Pi SD image on QEMU's `raspi4b` model, which is good for the
boot chain only (it has no PCIe, Ethernet or GPU).

**Reading files from an image after a boot:** `scripts/image-cat.sh IMAGE PATH` prints a file from an
image's BFS partition (e.g. `/boot/system/var/log/syslog`), for a card read back on the bench
(`scripts/sd-cycle.sh --read-back`) or a network boot's disk (`artifacts/netboot/disk.img`).

## The package repository

### Using it on the Pi

The image's "HaikuPorts" repository is this port's: https://haiku-pi.github.io/packages/arm64 (source
repository [haiku-pi/packages](https://github.com/haiku-pi/packages)), arm64 builds of the HaikuPorts
recipes: Mesa, SDL2, ffmpeg, HaikuWebKit, NetSurf, OpenSSL, curl and the libraries they need. Haiku's
own arm64 system repository is configured too. With the network up, in Terminal:

```sh
pkgman refresh
pkgman install sqlite_devel
```

On another arm64 Haiku installation, add it first:

```sh
pkgman add-repo https://haiku-pi.github.io/packages/arm64
```

The packages are unsigned (nothing in Haiku checks a signature today). Firefox (zstd, 102 MB) and the
games (data in parts) are in it since 2026-10-21.

### A local repository for testing

```sh
scripts/make-repo.sh        # artifacts/repo/arm64: repo.info, repo, repo.sha256, packages/ from artifacts/packages
scripts/serve-repo.sh       # HTTP on 10.42.0.1:8090 until killed (bind it to a private LAN only)
```

On the Pi: `pkgman add-repo http://10.42.0.1:8090/arm64 && pkgman refresh`. `make-repo.sh` takes
`--packages DIR --out DIR --url BASEURL --name NAME --identifier ID`; `serve-repo.sh` takes the address
to listen on.

### Publishing

```sh
scripts/publish-repo.sh --dry-run     # show what would change
scripts/publish-repo.sh               # commit and push to github.com/haiku-pi/packages
```

It clones the packages repository into `artifacts/publish/packages`, rebuilds `arm64/` with
`make-repo.sh` from `artifacts/packages/*.hpkg`, and commits and pushes what changed (never a force
push). It needs push access; for your own fork set `PACKAGES_REMOTE` (the git URL) and `PACKAGES_URL`
(where it will be served). Packages over 100 MiB (GitHub's file limit) are skipped with a message; split or recompress them
(zstd: `package create -z zstd`, as `build-firefox.sh` and `package-games.sh` do). The published site must also stay under GitHub Pages' 1 GB limit (about 700 MB on 2026-10-21). A package already
published keeps its published bytes: **a rebuilt package is only published when its version or revision
changes** — bump the revision to publish a fix. `package_repo` only accepts packages whose vendor is
"Haiku Project"; `package-port.py` and the other packaging scripts set it.

### The package-bump rule

From [AGENTS.md](../AGENTS.md). A new revision of one of our packages has **three parts**:

1. the `.hpkg` in `artifacts/packages/` — only the newest revision (`publish-repo.sh` refuses two);
2. the same file copied into `sources/haiku/generated.arm64/download/` (jam builds the image's
   repository from there);
3. the version in `sources/haiku/build/jam/repositories/HaikuPorts/arm64` (a commit in the Haiku fork).

Miss the copy and the image build only warns `AddHaikuImagePackages: package X not available!` and ships
without the package. Search the build log for it after every bump:

```sh
grep -a 'not available' artifacts/build/<timestamp>.log
```

## Rebuilding and updating

- After a change in `sources/haiku`, re-run Step 6; jam rebuilds only what changed (30–60 s).
- After a change in Mesa, libdrm or libglvnd: `scripts/build-gl-stack.sh`, then
  `scripts/package-gl-stack.sh --revision N` with the next revision, then the bump rule.
- `scripts/bootstrap.sh` never updates a clone that exists. To update, pull in the clone itself, e.g.
  `git -C sources/haiku pull`, and rebuild. (The maintainers merge Haiku upstream into the fork weekly
  with `scripts/upstream-sync.sh`.)
- Machine-specific settings (the serial device, a power switch, the capture card, the Pi LAN address,
  data paths such as `QUAKE_DATA`, `WIFI_SSID`) go into `local.conf`, which git ignores. Start from
  [`local.conf.example`](../local.conf.example): `cp local.conf.example local.conf`. Every setting can
  also come from the environment. Nothing in git names a path on one machine, and no secret (a WiFi
  passphrase) goes into git: `scripts/wifi-join-image.sh` puts the passphrase only into the
  git-ignored test image.

## Troubleshooting

**`jam: command not found`.** Build it and put it on `PATH`
([Step 2](#step-2--build-haikus-jam-and-u-boot)); the `export` is per shell.

**Expected noise in a good build** (every step still exits 0):
- while fetching tar and libiconv, a GNU mirror's certificate error; the fetch falls back to
  ftp.gnu.org;
- three `arm64/Jamfile: No such file` lines (hyperv, disasm, ltrace);
- in the regular build, `jpeglib.h`/`png.h` and WonderBrush's `bitmap_compression.h`/`blending.h`
  "No such file" lines from catalog extraction;
- linker warnings about orphan sections (`_haiku_revision`, `.rela.*`, `.comment`) in the kernel link;
- exactly eleven `AddHaikuImagePackages: package X not available!` lines in a `@pi-mmc` build, for
  packages of the nightly set that arm64 does not have: `bc diffutils gutenprint9 lame mesa_swpipe
  netcat sharutils tcpdump wget which zip` (2026-10-20).

**Any other `package X not available!`** means one of our packages is not in
`sources/haiku/generated.arm64/download/` at the version the repository definition names, and the image
was built without it. On 2026-10-20 two image builds shipped without SDL2 this way (a new revision was
listed but not copied). Copy the package there ([bump rule](#the-package-bump-rule)), or re-run
`scripts/build-packages.sh`, which stages everything; for `firefox` see
[Step 5](#step-5--firefox-optional-but-part-of-the-regular-image); for `openarena` and `supertuxkart`,
`scripts/package-games.sh`.

**`heavy-build: waiting for another heavy build (...)` and nothing happens.** Heavy builds wait for
each other on a lock (`HEAVY_BUILD_LOCK`, default `/tmp/heavy-build.lock`). Another build may really be
running; otherwise a failed image step left Haiku's `bfs_shell -n` server running, holding the lock it
inherited. `build.sh` now stops it after a failed jam run; if one is left from an older run, find it with
`ps -eo pid,args | grep '[b]fs_shell'` and stop it.

**The build or your desktop session was killed for lack of memory.** Run memory-heavy builds only
through the scripts (they use `heavy-build.sh`, one at a time, at most 22 GB), never two of them in
parallel by hand: on 2026-10-02 two parallel WebKit builds on this host made systemd-oomd kill the whole
terminal session at 26.4 of 29 GB.

**A heavy build fails at once in `systemd-run`:** there is no systemd user session in this shell; log
in to a session that has one (`systemctl --user status` must work).

**jam cannot download a package on a fresh clone.** jam never downloads here (`HAIKU_NO_DOWNLOADS`);
the bootstrap puts the upstream build packages into the download directory. Re-run
`scripts/fetch-build-packages.sh` (or `scripts/bootstrap.sh`).

**The image boots, but the package daemon reports `nothing provides noto_sans_cjk_jp needed by
haiku`.** The packages from Haiku's servers are zstd-compressed and packagefs reads them only when
jam's zstd feature is on, which needs our `zstd`, `zstd_devel` and `zstd_source` packages.
`scripts/build-packages.sh` builds them; rebuild the image afterwards.

**HTTPS fails with "certificate not yet valid" on the Pi.** The Pi has no battery clock and starts in
1970; the image sets the clock by NTP when the network comes up. Wait for the network to come up
(`Time --update` in Terminal syncs the clock by hand).

**A package copied onto the Pi by hand does not activate** (`failed to init package`): it was still
being copied when packagefs saw it. Copy it under another name and rename it into
`/boot/system/packages/` (or use `pkgman`).

**`mkimage-pi4: build U-Boot first (scripts/build-uboot.sh)`** — Step 2. **`mkimage-pi4: WiFi firmware
not written`** or similar `... not written` — the BFS write failed; the message is preceded by
`bfs_shell`'s output. Check that jam's build finished (`bfs_shell` is a host tool of the build) and that
the disk is not full.

**The Pi shows nothing, or boots something else.** Check that you wrote the whole device (not a
partition) and that the card is seated. If a DHCP/TFTP server answers on the Pi's Ethernet (for example
the network boot server of this project), a Pi whose EEPROM tries the network first boots from the
network instead of the card: unplug Ethernet or stop the server (`scripts/netboot-server.sh down`).

**A stuck boot:** on the serial console, three Ctrl-] followed by `d` drop a running Haiku into the kernel
debugger (`threads`, `teams`, `bt` show what it is doing). The bench scripts use this to capture a hang.
