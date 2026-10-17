# Pi 4 GPU/Display: Non-Linux Forward Research (Round 2)

Companion to `gpu-vc6.md` (Linux-centric). This round excludes Linux source as
primary citation; Linux is referenced only where another non-Linux project
explicitly mirrors it. Goal: identify approaches that fit a microkernel like
Phoenix-RTOS without dragging in DRM/KMS/Mesa stack assumptions.

## 1. FreeBSD VC4/VC6 support

FreeBSD's BCM283x port lives in `sys/arm/broadcom/bcm2835/`. The video-relevant
files are `bcm2835_fb.c` (vt framebuffer driver), `bcm2835_fbd.c`,
`bcm2835_mbox.c`/`.h`, and `bcm2835_mbox_prop.h`. There is **no** dedicated
`bcm2711_hdmi.c` or HVS driver in tree — display is firmware-mediated through
the mailbox property interface, identical in shape to what hobby OSes do
([freebsd-src bcm2835 dir](https://github.com/freebsd/freebsd-src/tree/main/sys/arm/broadcom/bcm2835)).
Pi 4-specific code (`bcm2838_pci.c`, `bcm2838_xhci.c`) covers PCIe and XHCI but
not display.

For 3D acceleration, FreeBSD's `drm-kmod` out-of-tree port currently ships
amdgpu, i915, and radeon ([freshports drm-kmod](https://www.freshports.org/graphics/drm-kmod);
[freebsd/drm-kmod](https://github.com/freebsd/drm-kmod)) — vc4/v3d is **not**
ported. The FreeBSD forums note that "someone would have to port drm/vc4 to
FreeBSD" and that 3D on Pi runs on llvmpipe (software)
([FreeBSD forums thread 86341](https://forums.freebsd.org/threads/what-about-2d-3d-hardware-acceleration-and-audio-support-on-raspberry-pi.86341/)).
Vincent Vadot's BSDCan 2019 talk "Adventure in DRMland" describes the general
pattern for porting Linux DRM drivers to FreeBSD via linuxkpi
([papers.freebsd.org](https://papers.freebsd.org/2019/bsdcan/vadot-adventure_in_drmland/)),
but it has not been applied to vc4/v3d.

**Mainline-ready in FreeBSD:** mailbox-allocated framebuffer (Tier 1 path).
**Missing:** any direct HVS/HDMI/PV driver, V3D 3D, KMS modesetting on Pi.

## 2. NetBSD evbarm Pi 4 graphics

NetBSD/evbarm follows the same firmware-mediated approach. The wiki
([wiki.netbsd.org/ports/evbarm/raspberry_pi](https://wiki.netbsd.org/ports/evbarm/raspberry_pi/))
documents `genfb` (generic framebuffer) attached via `simple-framebuffer` in
the device tree — no native HVS driver. Practical bring-up notes
([mdwarfgeek gist](https://gist.github.com/mdwarfgeek/0e2f8d5928f6ad4fdbe47c7e7e1298ea))
report two facts directly relevant to Phoenix:

- The framebuffer doesn't auto-attach without DTB patching; one must add a
  `framebuffer` node so that `genfb` matches.
- The mailbox `set_pixel_order` tag (0x00048006) is **broken on Pi 4** — the
  firmware ignores it and always returns BGR. NetBSD users compensate by
  swapping channels in software.

That second point is a load-bearing lesson: a Tier 1 implementation cannot
trust every property tag the firmware advertises; it must verify post-allocate
state (pitch, depth, byte order) and adapt.

## 3. OpenBSD arm64 Pi 4 graphics

OpenBSD/arm64 supports BCM2837/2711/2712 ([openbsd.org/arm64](https://www.openbsd.org/arm64.html))
but explicitly relies on UEFI firmware (commonly Pi UEFI EDK2) to bring up the
display, then attaches `efifb` to the resulting framebuffer. There is X11
without acceleration on top of `efifb`. There is no in-tree HVS or vc4 driver.
This is essentially a Tier 0 approach: let an upstream firmware blob do all
display init, consume the resulting linear framebuffer.

For Phoenix this is interesting only as a "what if we bypassed the property
mailbox entirely and used UEFI GOP" thought experiment. Today Phoenix boots
via `plo`, not UEFI, so this path is not directly applicable.

## 4. Bare-metal HDMI/HVS bring-up tutorials

The active community of Pi 4 bare-metal authors converges on the property
mailbox, not direct HVS programming.

- **rpi4-osdev part 5** ([rpi4os.com/part5-framebuffer](https://www.rpi4os.com/part5-framebuffer/);
  [babbleberry/rpi4-osdev part5-framebuffer/io.c](https://github.com/babbleberry/rpi4-osdev/blob/master/part5-framebuffer/io.c))
  by Adam Greenwood-Byrne. Sequence: build a single 16-byte-aligned property
  buffer containing tags `SET_PHYS_WH` (0x48003), `SET_VIRT_WH` (0x48004),
  `SET_VIRT_OFFSET` (0x48009), `SET_DEPTH` (0x48005), `SET_PIXEL_ORDER`
  (0x48006), `ALLOCATE_BUFFER` (0x40001), `GET_PITCH` (0x40008); send via
  channel 8; consume returned base address (mask `& 0x3FFFFFFF` to convert
  GPU-bus to ARM-physical).
- **bztsrc/raspi3-tutorial 09_framebuffer**
  ([github.com/bztsrc/raspi3-tutorial/blob/master/09_framebuffer/README.md](https://github.com/bztsrc/raspi3-tutorial/blob/master/09_framebuffer/README.md))
  is the same recipe, written for Pi 3 but directly portable to Pi 4 with no
  HVS-level changes — strong evidence that the firmware ABI is what matters,
  not the silicon revision.
- **PeterLemon/RaspberryPi**
  ([github.com/PeterLemon/RaspberryPi](https://github.com/PeterLemon/RaspberryPi))
  ARM64 assembly framebuffer demos. Same property-mailbox flow.
- **LdB-ECM/Raspberry-Pi**
  ([github.com/LdB-ECM/Raspberry-Pi](https://github.com/LdB-ECM/Raspberry-Pi))
  is the outlier — Leon de Boer has been working on bare-metal GLES that goes
  *direct to V3D* through a VCOS shim, leveraging Eric Anholt's reverse-
  engineering of the VC4/V5 graphics pipeline. The OSDev wiki entry
  ([wiki.osdev.org/Raspberry_Pi_4](https://wiki.osdev.org/Raspberry_Pi_4))
  links to this work but it is research-grade, not production.
- **OSDev wiki: Raspberry Pi**
  ([wiki.osdev.org/Raspberry_Pi](https://wiki.osdev.org/Raspberry_Pi)) collects
  these recipes; documents the 16-byte mailbox alignment and channel-8 property
  protocol.
- **The Property Mailbox Channel** ([jsandler18.github.io/extra/prop-channel.html](https://jsandler18.github.io/extra/prop-channel.html))
  walks the protocol byte by byte.

Common thread: nobody at the bare-metal layer programs HVS/PV/HDMI registers
directly on Pi 4 in the open-source community outside of LdB-ECM's
experiments. The firmware does it.

## 5. Circle (rsta2/circle)

Circle's `lib/bcmframebuffer.cpp`
([github.com/rsta2/circle/blob/master/lib/bcmframebuffer.cpp](https://github.com/rsta2/circle/blob/master/lib/bcmframebuffer.cpp))
is the most mature bare-metal C++ implementation. Init steps (per the source):

1. Build a `CBcmPropertyTags` request and append the canonical tags:
   `SET_PHYS_WH`, `SET_VIRT_WH`, `SET_DEPTH`, optional pixel-order, optional
   palette for 8-bpp, `ALLOCATE_BUFFER`, `GET_PITCH`.
2. Send all tags in a single mailbox transaction (single round-trip is
   meaningfully faster than per-tag calls and the firmware honors the order).
3. Mask the returned base address with `0x3FFFFFFF` (legacy bus→ARM-phys
   conversion; on Pi 4 with `arm_64bit=1` the firmware returns ARM physical
   directly but masking is harmless).
4. Pi 4 only: optionally call `SET_DISPLAY_NUM` first to pick HDMI0/HDMI1, and
   `GET_NUM_DISPLAYS` to enumerate (multi-display is a Pi 4 firmware feature
   absent on earlier silicon).
5. Optional `SET_BACKLIGHT` for DSI panels.

Circle has no HVS driver, no PV driver, no EDID parser of its own — the
firmware handles all of that. This is the cleanest reference for what
Phoenix's existing fbcon path should look like at maturity.

## 6. Ultibo

Ultibo (Free Pascal, [ultibo.org](https://ultibo.org/wiki/Main_Page);
[github.com/ultibohub/Core](https://github.com/ultibohub/Core)) implements a
full RTL with a `Framebuffer` unit. Per the Pi 4 platform notes
([Unit BCM2711](https://ultibo.org/wiki/Unit_BCM2711)), Ultibo also goes
through the property mailbox. It exposes a richer device class hierarchy
(framebuffer device, console device, font/glyph services) layered on top —
useful API design inspiration for Phoenix's user-space console server, but no
new low-level technique.

## 7. Other custom RPi OSes with display

Most hobby kernels (Sergey Matyukevich's bare-metal series, Jake Sandler's
"Building an OS for the Pi" tutorials, the various Rust experiments like
kerla/redshirt, xv6-rpi ports) all use the same Tier 1 property-mailbox
framebuffer. None of the public hobby Pi 4 OSes program HVS directly.

## 8. VPU-side firmware framebuffer alloc

Primary source: [raspberrypi/firmware Mailbox property interface
wiki](https://github.com/raspberrypi/firmware/wiki/Mailbox-property-interface).
Relevant tag values, all firmware-side (the VC6 VPU executes them):

| Tag | Name | Request | Response |
|---|---|---|---|
| 0x00040001 | Allocate buffer | u32 alignment | u32 base, u32 size |
| 0x00048003 | Set physical W/H | u32 w, u32 h | u32 w, u32 h |
| 0x00048004 | Set virtual W/H | u32 w, u32 h | u32 w, u32 h |
| 0x00048005 | Set depth | u32 bpp | u32 bpp |
| 0x00048006 | Set pixel order | u32 (0=BGR, 1=RGB) | u32 |
| 0x00040008 | Get pitch | — | u32 bytes/line |

The legacy [Mailbox framebuffer interface](https://github.com/RaspberryPI/firmware/wiki/Mailbox-framebuffer-interface)
(channel 1, single struct) is Pi 1 only — Pi 2+ uses the property channel
(channel 8).

## 9. DispmanX vs KMS

DispmanX is the Broadcom-firmware-side compositor: VPU-resident, used by the
closed-source `vcos`/`vchiq` userland on legacy Raspberry Pi OS. Most non-Linux
Pi OSes don't use DispmanX directly — they bypass it entirely via the property
mailbox to allocate a single primary framebuffer, which DispmanX then displays
as a single layer. KMS is Linux-only (vc4/v3d kernel modules + Mesa userland).
DispmanX is deprecated and removed on Bookworm; Pi 5 dropped it entirely
([Raspberry Pi forums thread 365082](https://forums.raspberrypi.com/viewtopic.php?t=365082);
[transitioning Bullseye→Bookworm whitepaper](https://pip-assets.raspberrypi.com/categories/1261-transitioning/documents/RP-006519-WP-1-Transitioning%20from%20Bullseye%20to%20Bookworm.pdf)).
For Phoenix the relevance is bounded: the mailbox path Phoenix uses is
DispmanX-adjacent (the firmware composites our buffer) but not exposed as
DispmanX API.

## 10. 3D acceleration in non-Linux contexts

Effectively none in production. FreeBSD: llvmpipe software path
([FreeBSD forum 86341](https://forums.freebsd.org/threads/what-about-2d-3d-hardware-acceleration-and-audio-support-on-raspberry-pi.86341/)).
NetBSD/OpenBSD: same. Circle/Ultibo: no V3D. The only non-Linux V3D effort is
LdB-ECM's research prototype. Mesa's V3D backend
([docs.mesa3d.org/drivers/v3d.html](https://docs.mesa3d.org/drivers/v3d.html))
depends on the Linux v3d DRM uAPI; porting it to Phoenix would require
implementing a DRM-shaped uAPI shim — months of work for a microkernel that
doesn't otherwise need DRM.

## Synthesis: what fits Phoenix-RTOS

**Tier 1 — property mailbox (current Phoenix path).** Every non-Linux OS
surveyed above does this. It is the de facto ABI for Pi 4 display in
non-Linux environments. Cost: a single `vchiq`-free mailbox driver plus the
six property tags listed in section 8. Robust, well-trodden, upstream-friendly
because it requires no copyleft Linux code. Caveats: NetBSD's
`set_pixel_order` warning means we must verify byte order post-allocate, and
Circle's experience suggests batching all tags in one call.

**Tier 2 — direct HVS/PV programming.** Nobody outside LdB-ECM's experiments
does this on Pi 4 for HDMI. The HVS register layout has no public datasheet
beyond what the BCM2711 peripherals doc
([bcm2711-peripherals.pdf](https://datasheets.raspberrypi.com/bcm2711/bcm2711-peripherals.pdf))
covers (which is partial); the only complete reference is `drivers/gpu/drm/vc4`
in Linux, which is GPL-2.0 — not safely upstreamable into Phoenix. The HDMI
controller on BCM2711 was redesigned (split into HDMI0/HDMI1 with separate
register banks, EDID via a dedicated BSC, CEC clock changes) per the Linux
patchset cover letter
([drm/vc4: Support BCM2711 Display Pipeline LWN summary](https://lwn.net/Articles/813166/)),
so any direct driver would be Pi-4-specific and Pi 5 needs another rewrite.

**Tier 3 — UEFI GOP.** OpenBSD's path. Not applicable to Phoenix today (we
boot through `plo`, not EDK2), and would mean importing a separate firmware.

**Recommendation.** Stay on Tier 1. Adopt Circle's batched-tag pattern; copy
NetBSD's lesson on verifying pixel order post-allocate. Defer Tier 2
indefinitely — there is no non-GPL reference, the silicon API churns between
Pi 4 and Pi 5, and the firmware-mediated path is proven across every other
non-Linux Pi OS. 3D acceleration is out of scope until someone implements a
DRM-shaped uAPI; that is research, not bring-up.
