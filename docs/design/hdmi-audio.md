# HDMI audio on the Raspberry Pi 4 (BCM2711): register-level design note

Status: research note, 2026-10-24. No code exists yet. Target: a Haiku hmulti driver
`bcm2711_hdmi_audio` for HDMI0, reusing the DMA model of `drivers/audio/bcm2711_pwm`.

Sources. Hardware facts come from the Raspberry Pi Linux tree at
`/home/houp/phoenix-rpi/external/linux` (branch rpi-6.18.y, HEAD `57083d8cf8f0`). That code is GPL.
This note restates facts (offsets, bits, values, order of operations) in its own words and contains
no Linux code. Paths below are relative to that tree unless they start with `sources/` (the Haiku
fork) or `tools/`/`scripts/` (this repository). Other sources:

- the firmware DTB the Pi actually boots, `artifacts/pi-firmware/bcm2711-rpi-4-b.dtb` (firmware commit
  `6c87074190d5`), decompiled with `dtc`;
- alsa-lib `src/pcm/pcm_iec958.c` (LGPL, github.com/alsa-project/alsa-lib, master as fetched on
  2026-10-24) for
  the IEC958 subframe layout that the Linux driver expects user space to produce;
- `/usr/share/alsa/cards/vc4-hdmi.conf` on the bench host (same file as in alsa-lib).

Where a fact could not be established from these sources, the text says **not established**.

---

## Result (2026-10-24): implemented and measured

The plan below was followed and works: haiku rpi4 `6965caeb07`, driver `bcm2711_hdmi_audio` (in
images from image-2026-10-24e). Bench facts that settled the open points:

- The HSM clock (firmware clock 13) reports a **set rate of 0 but measures 150 MHz**: the driver checks
  the measured rate (`GET_CLOCK_MEASURED`).
- The firmware uses packet slots 0, 2 and **4 — slot 4 holds its own SPD InfoFrame** ("BroadcomVideocore"),
  so the Audio InfoFrame goes into **slot 1**, not 4 as Linux's numbering suggests.
- SCHEDULER_CONTROL 0x000cb00b (HDMI mode), packet RAM on, the DVP audio clock ungated, MAI_SMP and N/CTS
  unset by the firmware: the firmware does not program audio itself.
- Legacy DMA channel 4 with DREQ 10 into MAI_DATA at bus 0x7ef2001c streams at exactly 48000.000 Hz.
- Recorded back through the capture card (tools/media-tests/hmultitone.cpp directly on the device,
  tone.cpp through the media kit, tools/media-tests/wavtone.py on the host): 1 kHz at the level played,
  both channels, no glitch over 20 s, 0 underruns.

Not done: 44.1 kHz, HDMI1, following a hotplug or mode change after boot (KNOWN-ISSUES P3).

## 0. Answer first: is direct MAI programming viable under the firmware-owned display?

Short answer: **probably yes, but it is unproven and has no precedent in the sources.** It must be
settled on the bench with a read-only probe before any driver is written (§6, step 1).

What the sources show:

1. No Linux configuration drives the MAI path while the firmware owns HDMI.
   - With full KMS (`vc4-kms-v3d-pi4` overlay), Linux's `vc4_hdmi` owns the whole HDMI block and the
     overlay turns the firmware audio path off with `snd_bcm2835.enable_hdmi=0`
     (`arch/arm/boot/dts/overlays/vc4-kms-v3d-pi4-overlay.dts:145`).
   - With fkms (`vc4-fkms-v3d-pi4`), HDMI audio is played **by the firmware**, which Linux asks to do
     over VCHIQ: the `bcm2835-audio` staging driver opens the VCHIQ service `AUDS`
     (`drivers/staging/vc04_services/bcm2835-audio/bcm2835-vchiq.c:135`) and routes to
     destination 2 (HDMI0) or 3 (HDMI1) (`bcm2835-audio/bcm2835.h:37-38`). The firmware DTB's `audio`
     parameter enables exactly that (`snd_bcm2835.enable_hdmi=1`, decompiled DTB, `__overrides__`).
   - Haiku's setup is closer to fkms than to KMS: the firmware sets the mode and keeps HDMI; Haiku's
     `bcm2711_display` only talks to it by mailbox (`tools/overlays/haiku-fkms.dts` only enables the
     firmware KMS node for vblank interrupts).
2. The audio registers are separate from the video registers. The MAI FIFO and its controls sit in
   the "hd" block, the audio packet, clock regeneration and packet RAM registers sit in the HDMI core
   block next to (but distinct from) the timing registers (§1, §3). The audio sample clock on the
   BCM2711 comes from a fixed 108 MHz source, not from the video clocks (§4). Nothing in audio
   programming requires touching the PHY PLL, the pixel clock, the timing registers or the resets.
3. Three registers are shared with the firmware's video setup and must be handled with care:
   `HDMI_RAM_PACKET_CONFIG` (it also holds the global packet RAM enable and the firmware's own
   InfoFrame enables), `HDMI_TX_PHY_POWERDOWN_CTL` (one bit only), and, to be checked on the bench,
   the DVP 108 MHz clock gate (§4).
4. The firmware is closed. Whether it rewrites the audio registers on its own (at a mode set, on
   hotplug, at display blank/unblank, or when nobody uses `AUDS`) is **not established**. What is
   established is Linux's own behaviour: its enable path writes `HDMI_RAM_PACKET_CONFIG` from
   scratch on every mode set (`drivers/gpu/drm/vc4/vc4_hdmi.c:1646-1647`), which would drop an
   Audio InfoFrame enable. If the firmware does the same, our setup is wiped. The driver is designed
   for that case anyway: it checks its state every period and re-arms it (§5).
5. A hard hazard: if the firmware has not initialised the HDMI state machine clock (boot with no
   monitor), any access to the HDMI registers stalls the CPU silently
   (`vc4_hdmi.c:3131-3144`, `drivers/clk/bcm/clk-raspberrypi.c:104-136`). The driver must check the
   clock rate by mailbox before its first register read (§4.2).

The alternative that cannot conflict with the firmware is the firmware's own audio service over
VCHIQ (`AUDS`). Haiku has no VCHIQ driver (no match for "vchiq" in
`sources/haiku/src/add-ons/kernel`), and Linux's VCHIQ core alone is about 7,200 lines
(`drivers/staging/vc04_services/interface/vchiq_arm/*.c`). That is a much larger job than the
direct path, so the direct path is worth trying first, with VCHIQ as the fallback.

Recommendation: do step 1 of §6 (read-only probe). If the probe shows HDMI mode active, packet RAM
enabled, a non-zero HSM clock and an ungated 108 MHz audio clock, write the driver. If audio
setup does not survive a hotplug cycle, re-arm it from the driver (cheap). Only if the firmware
actively fights the audio registers during steady playback should VCHIQ be considered.

---

## 1. Addresses

### 1.1 Address spaces

| View | Peripheral window | Source |
|---|---|---|
| CPU physical (Pi 4 "low peripheral" mode) | 0xfe000000 = bus 0x7e000000 | `arch/arm/boot/dts/broadcom/bcm2711.dtsi:41` (soc `ranges`) |
| Legacy DMA (channels 0-10) | peripherals at their bus address 0x7exxxxxx; RAM at 0xc0000000 + phys, first 1 GiB only | `bcm2711.dtsi:45`, `bcm2711-rpi-ds.dtsi:86-87` (soc `dma-ranges`) |
| DMA4 / "dma40" (channels 11-14) | peripherals at 0x4_7c000000 + (phys - 0xfc000000); RAM at its physical address (35 bits) | `bcm2711-rpi-ds.dtsi:123-124` (scb `dma-ranges`) |

So a peripheral at bus address 0x7ef2001c is CPU physical 0xfef2001c and DMA4 address
0x4_7ef2001c.

### 1.2 HDMI register blocks (bus addresses)

Both the mainline DT (`bcm2711.dtsi:329-401`) and the firmware's DTB list the same ranges. The
firmware DTB and the downstream `bcm2711-rpi-ds.dtsi:375-435` add a tenth range, `intr2`. The block
the task calls "ram" is named `packet` in these DTs; there is also a `metadata` block.

| reg-name | HDMI0 | HDMI1 | Size | Linux use (`vc4_hdmi.c` `vc5_hdmi_init_resources`, 2986-3105) | Needed for audio? |
|---|---|---|---|---|---|
| hdmi (core) | 0x7ef00700 | 0x7ef05700 | 0x300 | core registers (`VC4_HDMI`) | **yes** |
| dvp | 0x7ef00300 | 0x7ef05300 | 0x200 | clock stop, VEC interface | no |
| phy | 0x7ef00f00 | 0x7ef05f00 | 0x80 | TX PHY | **one bit** (RNG power-down) |
| rm | 0x7ef00f80 | 0x7ef05f80 | 0x80 | rate manager (pixel clock) | no |
| packet | 0x7ef01b00 | 0x7ef06b00 | 0x200 | InfoFrame packet RAM (`VC5_RAM`) | **yes** |
| metadata | 0x7ef01f00 | 0x7ef06f00 | 0x400 | (HDR metadata) | no |
| csc | 0x7ef00200 | 0x7ef00280 | 0x80 | colour space converter | no |
| cec | 0x7ef04300 | 0x7ef09300 | 0x100 | CEC | no |
| hd | 0x7ef20000 | 0x7ef20000 (shared) | 0x100 | MAI FIFO and controls (`VC4_HD`) | **yes** |
| intr2 | 0x7ef00100 | 0x7ef00100 | 0x30 | always-on interrupt controller | no |

Separate node, also needed (read only): the DVP clock/reset controller `clock@7ef00000`, size 0x10
(`bcm2711.dtsi:313-319`). Its offsets: 0x04 = `DVP_HT_RPI_SW_INIT` (HDMI resets, **never write**),
0x08 = `DVP_HT_RPI_MISC_CONFIG` (bit 3: HDMI0 108 MHz gate, bit 4: HDMI1, both "set to disable")
(`drivers/clk/bcm/clk-bcm2711-dvp.c:10-11, 52, 61-75`). In the firmware DTB this node is
`status = "disabled"`, so the gate state is whatever the firmware left.

Note that the "hd" block is shared: both HDMI controllers have their MAI registers in it, at
different offsets (§1.3). Linux maps it with a plain `ioremap` for that reason (`vc4_hdmi.c:2999-3010`).

### 1.3 Registers the audio driver uses (HDMI0)

Offsets from `drivers/gpu/drm/vc4/vc4_hdmi_regs.h`, table `vc5_hdmi_hdmi0_fields` (lines 245-336);
HDMI1 from `vc5_hdmi_hdmi1_fields` (338-429). Access: R = read only from our side, W = we write.

| Register | Block + offset | HDMI0 CPU phys | HDMI1 offset | Access |
|---|---|---|---|---|
| MAI_CTL | hd + 0x10 | 0xfef20010 | hd + 0x30 | W |
| MAI_THR | hd + 0x14 | 0xfef20014 | hd + 0x34 | W |
| MAI_FMT | hd + 0x18 | 0xfef20018 | hd + 0x38 | W |
| **MAI_DATA** | hd + 0x1c | 0xfef2001c | hd + 0x3c | DMA target |
| MAI_SMP | hd + 0x20 | 0xfef20020 | hd + 0x40 | W |
| VID_CTL | hd + 0x44 | 0xfef20044 | hd + 0x48 | R (diagnostic) |
| FRAME_COUNT | hd + 0x60 | 0xfef20060 | hd + 0x64 | R (refresh measurement) |
| MAI_CHANNEL_MAP | core + 0x09c | 0xfef0079c | same offsets in HDMI1 core | W |
| MAI_CONFIG | core + 0x0a0 | 0xfef007a0 | | W |
| AUDIO_PACKET_CONFIG | core + 0x0b8 | 0xfef007b8 | | W |
| RAM_PACKET_CONFIG | core + 0x0bc | 0xfef007bc | | read-modify-write of bit 4 only |
| RAM_PACKET_STATUS | core + 0x0c4 | 0xfef007c4 | | R |
| CRP_CFG | core + 0x0c8 | 0xfef007c8 | | W |
| CTS_0 | core + 0x0cc | 0xfef007cc | | W |
| CTS_1 | core + 0x0d0 | 0xfef007d0 | | W |
| SCHEDULER_CONTROL | core + 0x0e0 | 0xfef007e0 | | R |
| HORZA, HORZB | core + 0x0e4, 0x0e8 | 0xfef007e4, 0xfef007e8 | | R |
| VERTA0, VERTB0 | core + 0x0ec, 0x0f0 | 0xfef007ec, 0xfef007f0 | | R |
| MISC_CONTROL | core + 0x100 | 0xfef00800 | | R (pixel repetition) |
| DEEP_COLOR_CONFIG_1 | core + 0x170 | 0xfef00870 | | R (bits per component) |
| HOTPLUG | core + 0x1a8 | 0xfef008a8 | | R |
| Packet RAM slot 4 | packet + 4 × 0x24 = + 0x90 | 0xfef01b90-0xfef01bb3 | packet + 0x90 | W |
| TX_PHY_POWERDOWN_CTL | phy + 0x004 | 0xfef00f04 | | read-modify-write of bit 4 only |

The packet RAM stride is 0x24 bytes (9 words) per packet (`vc4_hdmi_regs.h:8`); the packet id is
the InfoFrame type minus 0x80, so the Audio InfoFrame (type 0x84) is slot 4 (`vc4_hdmi.c:653-658`).

### 1.4 The MAI data register for DMA

Linux takes the DMA address from the `hd` range plus the MAI_DATA offset
(`vc4_hdmi_audio_init`, `vc4_hdmi.c:2274-2288`).

| Engine | HDMI0 MAI_DATA | HDMI1 MAI_DATA |
|---|---|---|
| Legacy DMA channel (as the PWM driver uses) | **0x7ef2001c** | 0x7ef2003c |
| DMA4 channel: DEST = low 32 bits, DESTI bits 7:0 = high bits | 0x7ef2001c, high byte 0x4 | 0x7ef2003c, high byte 0x4 |
| CPU physical | 0xfef2001c | 0xfef2003c |

Downstream Linux passes the physical address and lets the DMA driver translate it
(commit `b4feb87c2ac0`, "drm/vc4: Use phys addresses for slave DMA config"); mainline used the DT bus
address directly. The PWM driver's equivalent is its FIFO at 0x7e20c818
(`sources/haiku/.../bcm2711_pwm.cpp`, `kPwm1BusAddress` + `PWM_FIF1`).

---

## 2. DMA

### 2.1 DREQ numbers

| Output | DREQ | Source |
|---|---|---|
| HDMI0 audio | **10** | `bcm2711.dtsi:357` `dmas = <&dma 10>`; `bcm2711-rpi-ds.dtsi:400`; firmware DTB `dmas = <… 0x41fa000a>` |
| HDMI1 audio | **17** | `bcm2711.dtsi:398`; `bcm2711-rpi-ds.dtsi:433`; firmware DTB `0x41fa0011` |

The DREQ is the same number for both engines: the legacy engine puts it in TI bits 20:16
(`drivers/dma/bcm2835-dma.c:167`), the DMA4 engine in TI bits 13:9 (`bcm2835-dma.c:266, 376`).

### 2.2 Which engine Linux uses, and with what settings

- **Mainline**: the legacy engine, `<&dma 10>`, no flags (`bcm2711.dtsi:357`, added by commit
  `4564363351e2`, "ARM: dts: bcm2711: Enable the display pipeline", 2020-09-03). The control block
  then gets: wait for write response, destination DREQ, source increment, PERMAP 10, interrupt per
  period. No burst, no wide reads (`bcm2835_dma_prep_dma_cyclic`, `bcm2835-dma.c:1064-1113`).
- **Downstream and the firmware DTB** (what the Pi boots): a DMA4 channel, cell value
  `10 | 1<<30 | 1<<24 | 10<<16 | 15<<20` (`bcm2711-rpi-ds.dtsi:400`). Decoded with
  `bcm2835-dma.c:141-189, 248-259`:

  | Cell bits | Meaning in the Linux DMA driver |
  |---|---|
  | 4:0 = 10 | DREQ (PERMAP) |
  | 19:16 = 10 | channel CS priority / DMA4 QOS = 10 |
  | 23:20 = 15 | panic priority / DMA4 PANIC_QOS = 15 |
  | 24 | "wide source": 128-bit source reads |
  | 30 | "burst": burst length field = 3 in both SRCI and DSTI |

  Linux also records `maxburst = 2` and a 4-byte bus width (`vc4_hdmi.c:2287-2288`), but the
  bcm2835 DMA driver takes its burst setting from the DT cell, not from `maxburst`
  (`bcm2835-dma.c:1064-1065`).

Why downstream moved HDMI audio from the legacy engine to DMA4 is **not established**: the history
in this clone is squashed into "BCM2708: Add core Device Tree support" commits. Mainline shows that
the legacy engine with single-beat transfers works, so reusing the PWM driver's legacy-channel code
is sound as a first step. If the MAI reports underruns (`MAI_CTL` DLATE / ERRORE), raise the channel
priority first (CS bits 19:16 = 10, 23:20 = 15, as downstream does), then consider bursts.

### 2.3 Channel constraints

| Engine | Channels free for the ARM | Notes |
|---|---|---|
| Legacy, normal | mask 0x7f5 → 0, 2, 4, 5, 6 | firmware DTB and `bcm2711.dtsi:106`. **5 is taken by `bcm2711_pwm`.** Use **4** (GIC SPI 84) or 6 (SPI 86). |
| Legacy, lite | 7, 8, 9, 10 | 64 KiB − 4 maximum per control block (`bcm2835-dma.c:222`); 7/8 share SPI 87, 9/10 share SPI 88 (`bcm2711.dtsi:89-93`). Avoid. |
| DMA4 (40-bit) | mask 0x7000 → 12, 13, 14 | 11 is used by the firmware for VCHIQ (`bcm2711-rpi-ds.dtsi:166-169`). Different register layout (`bcm2835-dma.c:225-305`) and 32-byte-aligned control blocks addressed as `addr >> 5` (`bcm2835-dma.c:393-397`). |

The legacy engine reaches only the first 1 GiB of RAM (dma-ranges, §1.1). The PWM driver already
allocates below 1 GiB (`kDmaMemoryLimit`) and reads the channel mask and interrupt from the live FDT
(`find_dma_interrupt`). The same code works for channel 4. Long term, a small shared DMA channel
allocator would be better than two drivers with hard-coded channel numbers.

### 2.4 MAI FIFO thresholds

`MAI_THR` (hd + 0x14), as Linux writes it for the BCM2711 (`VC4_GEN_5`, `vc4_hdmi.c:2126-2133`;
fields `vc4_regs.h:1003-1010`):

| Field | Bits | Value |
|---|---|---|
| PANICHIGH | 29:24 | 0x10 |
| PANICLOW | 21:16 | 0x10 |
| DREQHIGH | 13:8 | 0x1c |
| DREQLOW | 5:0 | 0x1c |

Register value: **0x10101c1c**. The FIFO depth and the exact meaning of each threshold are **not
established** (no comment in the source; 6-bit fields suggest a depth of at most 64 words).

---

## 3. Programming sequence: 2-channel, 16-bit PCM at 44.1 or 48 kHz

### 3.1 What the MAI expects: IEC958 subframes, not raw PCM

The Linux DAI accepts only `SNDRV_PCM_FMTBIT_IEC958_SUBFRAME_LE` (`vc4_hdmi.c:2190-2203`). User
space converts PCM to subframes with alsa-lib's `iec958` plugin, configured by
`/usr/share/alsa/cards/vc4-hdmi.conf`. So our driver must do that conversion itself (in
`buffer_exchange`, where the PWM driver converts PCM to duty words). Each audio sample becomes one
32-bit word written to MAI_DATA. One frame = two words, left then right.

Word layout (alsa-lib `pcm_iec958.c`, `iec958_subframe`):

| Bits | Content |
|---|---|
| 3:0 | preamble: **0x8** ("Z", left channel of frame 0 of each 192-frame block), **0x2** ("X", left channel of other frames), **0x4** ("Y", right channel) |
| 27:4 | the audio sample, MSB at bit 27. A 16-bit sample goes in bits 27:12; bits 11:4 are 0 |
| 28 | validity: 0 |
| 29 | user data: 0 |
| 30 | channel status bit for this frame (same bit in both channels) |
| 31 | parity: set so that bits 4-31 contain an even number of ones |

Channel status: a 192-bit block, one bit per frame. Frame k carries bit (k mod 8) of byte (k div 8).
The frame counter wraps at 192 and advances once per frame, not per subframe. Bytes for consumer
2-channel 16-bit PCM (vc4-hdmi.conf defaults; values from `include/sound/asoundef.h:17-136`; the
plugin fills in the rate and word length):

| Byte | Value | Meaning |
|---|---|---|
| 0 | 0x04 | consumer, linear PCM, not copyrighted, no emphasis |
| 1 | 0x82 | category "PCM coder", original |
| 2 | 0x00 | source and channel number unspecified |
| 3 | **0x00** at 44.1 kHz, **0x02** at 48 kHz | sample frequency |
| 4 | 0x02 | word length 16 bits (field "20 or 16", max 20) |
| 5-23 | 0x00 | |

The B-frame identifier in `AUDIO_PACKET_CONFIG` (§3.3) is set to 8, matching the Z preamble value
0x8 (`vc4_hdmi.c:2107-2111`). The two must agree.

Consequences for the driver design:

- The 192-frame block must stay continuous across ring segments. Make each segment a multiple of
  192 frames: **960 frames** (5 blocks; 20.0 ms at 48 kHz, 21.8 ms at 44.1 kHz) or 1152. Then every
  segment starts with a Z preamble, and the preamble and status bit of each word depend only on its
  position in the segment. The driver can precompute a template of `preamble | status bit << 30`
  per position and only add the sample and the parity bit.
- Silence is not zero words. A silent word still needs its preamble, status bit and parity. The
  "silence after a played segment" trick of the PWM driver therefore fills with the template, not
  with 0.
- `MAI_CTL` bit 8 (PAREN) makes the MAI generate the parity bit itself (`vc4_regs.h:989-992`).
  Linux does not set it. Compute parity in software first (proven path); try PAREN later.

### 3.2 Sample clock: MAI_SMP

On the BCM2711 the MAI sample clock is derived from the `"audio"` clock of the HDMI node
(`vc4_hdmi_audio_set_mai_clock`, `vc4_hdmi.c:1839-1866`, using `audio_clock` set at
`vc4_hdmi.c:3054`). In the DT that clock is `<&dvp 0>` (`bcm2711-rpi-ds.dtsi:398`), a gate in the
DVP block on the fixed **108 MHz** clock `clk_108MHz` (`bcm2711.dtsi:27-32, 316`;
`clk-bcm2711-dvp.c:61-66`). It is **not** the HSM clock. (On the older BCM2835 the audio clock was
the HSM clock, `vc4_hdmi.c:2980`.)

Linux finds the best fraction n/m for 108 MHz / fs with n up to 2^24 − 1 and m up to 256, then
writes `MAI_SMP = n << 8 | (m − 1)` (fields N = bits 31:8, M = bits 7:0, `vc4_regs.h:1024-1027`).
From this, fs = 108 MHz × m / n (inferred; the hardware semantics are not documented in the source).

| fs | 108 MHz / fs | n | m | MAI_SMP |
|---|---|---|---|---|
| 48000 | 2250 | 2250 | 1 | **0x0008ca00** |
| 44100 | 2448.979… = 120000/49 | 120000 | 49 | **0x01d4c030** |

Both fractions are exact, so the HDMI sample rate is exactly 44100 or 48000 Hz relative to the
108 MHz source (its parentage is not in the sources) (unlike the PWM jack's 44117.647 Hz).

### 3.3 Format, configuration and channel map

Values for 2 channels, PCM, from `vc4_hdmi_audio_prepare` (`vc4_hdmi.c:2054-2153`); bit fields from
`vc4_regs.h` (line numbers given).

| Register | Fields set | Value |
|---|---|---|
| MAI_CTL (prepare) | CHNUM (7:4) = 2, WHOLSMP (12), CHALIGN (13), ENABLE (3) (`vc4_regs.h:982-1001`) | **0x00003028** |
| MAI_FMT | AUDIO_FORMAT (23:16) = 2 (PCM), SAMPLE_RATE (15:8) = 8 (44.1 kHz) or 9 (48 kHz) (`vc4_regs.h:788-816`) | 44.1 kHz **0x00020800**, 48 kHz **0x00020900** |
| MAI_THR | §2.4 | **0x10101c1c** |
| MAI_CONFIG | FORMAT_REVERSE (27), BIT_REVERSE (26), CHANNEL_MASK (15:0) = 0x3 (`vc4_regs.h:770-773`) | **0x0c000003** |
| MAI_CHANNEL_MAP | BCM2711 layout: 4 bits per channel, channel i → i (`vc5_hdmi_channel_map`, `vc4_hdmi.c:1807-1817`) | **0x00000010** |
| AUDIO_PACKET_CONFIG | ZERO_DATA_ON_SAMPLE_FLAT (29), ZERO_DATA_ON_INACTIVE_CHANNELS (24), B_FRAME_IDENTIFIER (13:10) = 8, CEA_MASK (7:0) = 0x3; AUDIO_LAYOUT (9) = 0 = 2-channel layout (`vc4_regs.h:775-786`) | **0x21002003** |

The meaning of WHOLSMP, CHALIGN, FORMAT_REVERSE and BIT_REVERSE beyond their names is **not
established**; copy them as Linux does.

### 3.4 Audio clock regeneration: N and CTS

`vc4_hdmi_set_n_cts` (`vc4_hdmi.c:1868-1893`):

- N = 128 × fs / 1000 (integer division);
- CTS = pixel clock in Hz × N / (128 × fs), truncated. Linux uses the mode's pixel clock
  (`mode->clock`, in kHz, × 1000), not a deep-colour TMDS rate;
- `CRP_CFG = EXTERNAL_CTS_EN (bit 24) | N (bits 19:0)`; `CTS_0 = CTS_1 = CTS`.

Register comments (`vc4_regs.h:820-831`): bit 24 "generates CTS values based on N, audio clock and
video clock. N must be divisible by 128". Bit 25 disables clock regeneration packets entirely; bit 26
counts the CTS period from the MAI bus sync instead of the pixel clock. CTS_0 and CTS_1 are
alternated by "period fields" (`vc4_hdmi.c:1886-1890`); where those period fields are is **not
established**.

**Discrepancy.** For 44.1 kHz Linux computes N = 5644, which is not divisible by 128, against the
register comment. The HDMI specification's recommended N for 44.1 kHz is 6272 (= 49 × 128); for
48 kHz Linux's 6144 (= 48 × 128) is the specification value. Recommendation: use **N = 6144 at
48 kHz and N = 6272 at 44.1 kHz**, and keep Linux's 5644 as the fallback if 6272 misbehaves (Linux's
value is what ships and works on Pi 4 monitors). Whether the hardware uses our CTS at all when bit 24
is set is **not established**; write CTS anyway, as Linux does.

| Pixel clock | 48 kHz (N 6144) CTS | 44.1 kHz N 6272 CTS | 44.1 kHz N 5644 (Linux) CTS |
|---|---|---|---|
| 25.175 MHz (640×480@60) | 25175 | 27972 | 25171 |
| 27.000 MHz (480p/576p) | 27000 | 30000 | 26996 |
| 74.250 MHz (720p60, 1080i) | 74250 | 82500 | 74239 |
| 148.500 MHz (1080p60) | 148500 | 165000 | 148478 |
| 148.352 MHz (1080p59.94) | 148352 | 164835 | 148330 |
| 297.000 MHz (2160p30) | 297000 | 330000 | 296957 |

CRP_CFG values: 48 kHz **0x01001800**; 44.1 kHz **0x01001880** (N 6272) or 0x0100160c (N 5644).

### 3.5 Audio InfoFrame

Linux builds it with the HDMI codec defaults: coding type, sample size and sample frequency
"refer to stream header", channel count from the stream, channel allocation from the sink's ELD
(`sound/soc/codecs/hdmi-codec.c:538-548`). Packing: `drivers/video/hdmi.c:392-411` (payload) and
`35-52` (checksum = 256 − sum of all bytes, mod 256).

For 2-channel PCM (channel allocation 0 = front left/right):

| Byte | HB0 | HB1 | HB2 | PB0 (checksum) | PB1 | PB2 | PB3 | PB4 | PB5 | PB6-PB10 |
|---|---|---|---|---|---|---|---|---|---|---|
| Value | 0x84 | 0x01 | 0x0a | **0x70** | 0x01 (CC = channels − 1, CT = 0) | 0x00 | 0x00 | 0x00 | 0x00 | 0x00 |

Check: 0x84 + 0x01 + 0x0a + 0x01 = 0x90; 0x100 − 0x90 = 0x70.

Writing it (`vc4_hdmi_write_infoframe`, `vc4_hdmi.c:647-724`; `vc4_hdmi_stop_packet`, 620-645):

1. Packet RAM must be enabled: `RAM_PACKET_CONFIG` bit 16 (`vc4_regs.h:818`). Under the firmware
   this bit is the firmware's; we only check it (§5).
2. Clear `RAM_PACKET_CONFIG` bit 4 (read-modify-write) and wait until `RAM_PACKET_STATUS` bit 4
   reads 0 (Linux waits up to 100 ms).
3. Write the 14 bytes into slot 4 (packet base + 0x90), alternating 3-byte and 4-byte words, low
   byte first: word 0 = HB0 | HB1 << 8 | HB2 << 16 = **0x000a0184**; word 1 = PB0..PB3 =
   **0x00000170**; word 2 = PB4..PB6 = 0; word 3 = PB7..PB10 = 0.
4. Write 0 to the rest of the slot, up to 9 words (offsets 0x90-0xb3). Linux notes that stale bytes
   there cause checksum errors on an HDMI analyser.
5. Set `RAM_PACKET_CONFIG` bit 4 (read-modify-write) and wait until `RAM_PACKET_STATUS` bit 4
   reads 1 (up to 100 ms).

### 3.6 HDMI mode and "audio enable"

Audio packets are data islands; they exist only in HDMI mode. Linux:

- refuses audio when the sink is DVI (`vc4_hdmi_audio_can_stream`, `vc4_hdmi.c:1902-1916`);
- puts the encoder in HDMI mode with `SCHEDULER_CONTROL` bit 0 (MODE_HDMI), waits for bit 1
  (HDMI_ACTIVE), then enables packet RAM with `RAM_PACKET_CONFIG` bit 16
  (`vc4_hdmi.c:1613-1653`; bits at `vc4_regs.h:861-865, 818`). In DVI mode it clears both.

There is no separate "audio enable" bit in the sources beyond MAI_CTL ENABLE, the audio packet
configuration, the clock regeneration packets (enabled unless `CRP_CFG` bit 25 is set) and the
Audio InfoFrame enable. Under the firmware we must **not** change `SCHEDULER_CONTROL`; we only read
it. If bit 0 or bit 1 is 0, the firmware drives DVI and HDMI audio is impossible without fighting it.

### 3.7 Full start sequence (our driver)

Preconditions (all must hold, §4 and §5): HSM clock rate non-zero; `HOTPLUG` bit 0 = 1;
`SCHEDULER_CONTROL` bits 0 and 1 = 1; `RAM_PACKET_CONFIG` bit 16 = 1; DVP `MISC_CONFIG` bit 3 = 0.

1. Startup (`vc4_hdmi_audio_startup`, `vc4_hdmi.c:1918-1958`): write `MAI_CTL` = RESET (0) | ERRORF
   (1) | ERRORE (2) | FLUSH (9) | DLATE (15) = **0x00008207**. This resets the MAI, flushes the FIFO
   and clears the sticky error bits. Then clear bit 4 (RNDGEN_PWRDN) of `TX_PHY_POWERDOWN_CTL`
   (`vc5_hdmi_phy_rng_enable`, `vc4_hdmi_phy.c:583-592`, bit at line 20). Why audio needs the PHY's
   random generator is **not established**; Linux powers it up for every audio stream and down when
   the stream ends.
2. `MAI_SMP` (§3.2).
3. `MAI_CTL` = **0x00003028** (§3.3).
4. `MAI_FMT`, `MAI_THR`, `MAI_CONFIG`, `MAI_CHANNEL_MAP`, `AUDIO_PACKET_CONFIG` (§3.3), in that order.
5. `CRP_CFG`, `CTS_0`, `CTS_1` (§3.4).
6. Audio InfoFrame (§3.5).
7. Fill the ring with silence subframes, then start the DMA channel. In Linux the DMA starts after
   `prepare`, when ALSA triggers the stream.

### 3.8 Stop and reset

Shutdown (`vc4_hdmi_audio_shutdown`, `vc4_hdmi.c:1982-2013`, then `vc4_hdmi_audio_reset`,
1960-1980):

1. Stop the DMA channel (in Linux the stream is stopped before shutdown).
2. `MAI_CTL` = DLATE | ERRORE | ERRORF = **0x00008006** (clears the error bits; ENABLE is now 0).
3. Set bit 4 of `TX_PHY_POWERDOWN_CTL` again (`vc5_hdmi_phy_rng_disable`, `vc4_hdmi_phy.c:594-603`).
4. Clear `RAM_PACKET_CONFIG` bit 4 (no wait for the status bit in this path).
5. Write `MAI_CTL` three times: 0x00000001 (RESET), 0x00000002 (ERRORF), 0x00000200 (FLUSH).

Leave `CRP_CFG`, `AUDIO_PACKET_CONFIG` and the other configuration as they are, as Linux does.

---

## 4. Clocks and power

### 4.1 What audio needs

| Clock | What it is | Who owns it under the firmware | Source |
|---|---|---|---|
| HSM ("hdmi") | HDMI state machine clock. DT: firmware clock 13 (named "m2mc" in Linux's firmware clock driver) | firmware. When Linux owns it, it asks for at least 120 MHz and at least 101 % of the TMDS character rate | `bcm2711-rpi-ds.dtsi:396`; `clk-raspberrypi.c:34, 104-136`; `vc4_hdmi.c:113, 1458-1477` |
| pixel BVB ("bvb") | firmware clock 14, "pixel-bvb" | firmware | `bcm2711-rpi-ds.dtsi:397`; `clk-raspberrypi.c:35` |
| audio | DVP gate (`MISC_CONFIG` bit 3 for HDMI0) on fixed 108 MHz | **not established** whether the firmware leaves it ungated | `clk-bcm2711-dvp.c:61-66` |
| CEC | fixed 27 MHz | not needed | `bcm2711-rpi-ds.dtsi:399` |
| pixel / TMDS clock | generated by the HDMI PHY PLL, programmed by the firmware | firmware; we need its value only for CTS | `vc4_hdmi_phy.c` (`vc5_hdmi_phy_init`) |

Power domain: the BCM2711 HDMI nodes have no `power-domains` property. Linux keeps the HDMI power
domain and the HSM/pixel clocks running and only powers the HDMI logic and packet RAM on and off
(`vc4_hdmi.c` header comment, lines 25-28). With the firmware showing a picture, the domain and the
HSM and pixel clocks are on. The fkms overlay adds `clk_ignore_unused`
(`overlays/vc4-fkms-v3d-pi4-overlay.dts:44`) so that Linux does not gate the firmware's clocks; we
do not gate anything either.

The DVP audio clock gate is the one clock that may be off. Read `MISC_CONFIG` (0xfef00008) bit 3 at
start. If it is set, clearing it is the only clock write the driver would make. Do that only if the
bench probe shows the firmware leaves it set; record it as a known deviation.

### 4.2 The no-monitor stall and how to read clock rates

If the Pi boots without an HDMI cable, the firmware skips HSM initialisation and leaves its rate at
0; then any HDMI register access locks the bus (`clk-raspberrypi.c:107-116`; `vc4_hdmi.c:3131-3144`).

Before touching any HDMI register:

1. Mailbox `GET_CLOCK_RATE` (tag 0x00030002) for clock id **13**: must be non-zero. Optionally
   `GET_CLOCK_MEASURED` (0x00030047) for id 13. Haiku's `bcm2835_mailbox.h` lacks ids 13 and 14; add
   `BCM2835_CLOCK_M2MC 13` (HSM) and `BCM2835_CLOCK_PIXEL_BVB 14`. Tag numbers:
   `include/soc/bcm2835/raspberrypi-firmware.h:51-160`; clock ids: same file, 166-182.
2. Mailbox `GET_DISPLAY_ID` (0x00040016): display id **2** is HDMI0, **7** is HDMI1
   (`bcm2835-audio/bcm2835.c:316-330`). The `bcm2711_display` driver already asks for display 0.

A monitor unplugged at runtime may bring the same state back. Whether the firmware then stops the
HSM clock is **not established**. The driver should re-read the HSM rate before re-arming after a
hotplug event, and should not touch registers while the rate reads 0.

### 4.3 Getting the pixel clock for CTS

Options, best first:

1. **Mailbox `GET_DISPLAY_TIMING` (0x00040017)**, with the firmware display id (2 for HDMI0) in the
   first byte. The response is the `set_timings` layout of `vc4_firmware_kms.c:129-174`: display
   (u8), padding (u8), VIC (u16), **clock in kHz (u32)**, hdisplay, hsync_start, hsync_end, htotal,
   hskew, vdisplay, vsync_start, vsync_end, vtotal, vscan, vrefresh (u16 each), padding (u16), flags
   (u32: bit 9 = DVI, bit 10 = double clock, bit 2 = interlaced). Linux treats a zero clock as "no
   mode returned" (`vc4_fkms_get_fw_mode`, 1391-1438). When the firmware returns a zero clock (for
   example, perhaps, when it chose the mode from the EDID itself) is **not established**.
2. **Read the mode back from the core registers and measure the refresh rate.** BCM2711 fields
   (`vc4_hdmi.c:66-91`, `vc4_regs.h:866-873`): HORZA: HAP = bits 13:0 (active pixels × pixel
   repetition), HFP = bits 28:16; HORZB: HBP = 26:16, HSP = 10:0; VERTA0: VAL = 12:0, VFP = 22:16,
   VSP = 28:24; VERTB0: VBP = 8:0; MISC_CONTROL bits 3:0 = pixel repetition. Then htotal = HAP + HFP
   + HSP + HBP, vtotal = VAL + VFP + VSP + VBP. Count frames over about 1 s with `FRAME_COUNT`
   (hd + 0x60) or with the display driver's vblank semaphore, and compute pixel clock = htotal ×
   vtotal × frame rate. Snap to the nearest standard clock (table in §3.4) when within 0.5 %.
3. Cross-check with the EDID preferred detailed timing (block 0, bytes 54-55, units of 10 kHz).

Mailbox `GET_CLOCK_RATE` for id 9 ("pixel") is unlikely to give the TMDS rate on the BCM2711 (the
PHY PLL makes it), and id 14 is the BVB clock, which Linux sets to 75, 150 or 300 MHz independently
of the mode. Not usable for CTS; whether id 9 reports anything meaningful is **not established**.

Deep colour: `DEEP_COLOR_CONFIG_1` bits 3:0 give the colour depth. Linux computes CTS from the pixel
clock regardless. If the firmware ever selects deep colour, check that audio still locks.

---

## 5. Risks

### 5.1 What the firmware may do underneath us

| Event | What may happen | Detection | Response |
|---|---|---|---|
| Hotplug (unplug/replug) | firmware re-initialises HDMI: MAI, CRP, audio packet config and packet RAM may be reset; HSM may drop to 0 | `HOTPLUG` bit 0; `RAM_PACKET_STATUS` bit 4; `MAI_CTL` ENABLE (bit 3); HSM rate by mailbox | stop DMA, wait for hotplug = 1 and HSM > 0, re-run §3.7 |
| Mode change (firmware or `SET_TIMING`) | `RAM_PACKET_CONFIG` rewritten; pixel clock changes, so CTS is stale | as above; re-read §4.3 | re-run §3.7 with new CTS |
| Display blank (`FRAMEBUFFER_BLANK`, used by `bcm2711_display`) | firmware may stop TMDS or power down the HDMI logic | **not established**; check on the bench | treat like hotplug |
| Firmware audio service (`AUDS`) | would program the same registers | only if someone opens VCHIQ; Haiku has no VCHIQ | none needed |
| Firmware decides DVI | `SCHEDULER_CONTROL` bit 0 = 0 | read at start and when re-arming | publish no stream; report "DVI sink" |

The checks in the middle column are cheap reads. Do them once per DMA period (in the interrupt
handler or the exchange path); a lost `RAM_PACKET_STATUS` bit 4 or a cleared MAI ENABLE triggers a
re-arm from thread context (the InfoFrame write may wait up to 100 ms).

### 5.2 Registers we must never write

These belong to the firmware's video setup; writing them would fight it:

- `DVP_HT_RPI_SW_INIT` (0xfef00004, HDMI resets) and the rest of the DVP clock block apart from the
  audio gate bit;
- anything in `vc5_hdmi_reset` (`vc4_hdmi.c:209-234`: `DVP_CTL` = 0, `CLOCK_STOP`, reset line);
- `SCHEDULER_CONTROL`, `VID_CTL`, the timing registers, CSC, scrambler, PHY registers other than bit
  4 of `TX_PHY_POWERDOWN_CTL`, the rate manager;
- `RAM_PACKET_CONFIG` bits other than bit 4, and packet RAM slots other than slot 4 (by the same numbering,
  the firmware's AVI InfoFrame, type 0x82, would be in slot 2; not verified);
- the MAI registers of the other HDMI port (the hd block is shared, §1.2).

The complete write set of the driver is: hd `MAI_CTL`, `MAI_THR`, `MAI_FMT`, `MAI_SMP` (and DMA to
`MAI_DATA`); core `MAI_CONFIG`, `MAI_CHANNEL_MAP`, `AUDIO_PACKET_CONFIG`, `CRP_CFG`, `CTS_0`,
`CTS_1`; `RAM_PACKET_CONFIG` bit 4; packet slot 4; `TX_PHY_POWERDOWN_CTL` bit 4; and possibly DVP
`MISC_CONFIG` bit 3.

Read-modify-write races: the firmware runs on the VideoCore, so a read-modify-write of
`RAM_PACKET_CONFIG` or `TX_PHY_POWERDOWN_CTL` can lose a concurrent firmware update. There is no lock
we can share. Keep these sequences short and re-check after writing.

### 5.3 DVI monitors and sink capability

HDMI audio needs (a) the firmware to drive HDMI, not DVI, and (b) a sink that accepts audio.

- The encoder mode: `SCHEDULER_CONTROL` bits 0 and 1 (§3.6). The firmware's `GET_DISPLAY_TIMING`
  flags bit 9 also reports DVI (meaning from `vc4_firmware_kms.c:170-171`; that the firmware sets it
  in its response is **not established**).
- The EDID: yes, the mailbox gives it. `GET_EDID_BLOCK` (0x00030020) takes a block number and returns
  block number, status (0 = success) and 128 bytes; `bcm2711_display`'s `read_edid` already uses it
  for block 0 (`sources/haiku/src/add-ons/kernel/drivers/graphics/bcm2711_display/bcm2711_display.cpp`,
  `read_edid`). `GET_EDID_BLOCK_DISPLAY` (0x00030023) takes block and display id
  (`vc4_firmware_kms.c:1440-1460`). Audio information is in the CEA-861 extension, block 1 (block 0
  byte 126 gives the number of extensions). In block 1 (tag 0x02):
  - byte 3 bit 6: basic audio supported;
  - the data block collection from byte 4 to byte (byte 2 − 1): each block starts with a byte whose
    bits 7:5 are the tag and bits 4:0 the length. Tag 1 = Audio Data Block: 3-byte Short Audio
    Descriptors; format code 1 (bits 6:3 of byte 0) = LPCM, channels − 1 in bits 2:0, byte 1 = rate
    bitmask (bit 0 32 kHz, bit 1 44.1 kHz, bit 2 48 kHz, …), byte 2 = sample sizes (bit 0 16-bit).
    Tag 3 with IEEE OUI 0x000c03 = HDMI Vendor-Specific Data Block, which marks an HDMI (not DVI)
    sink.
  (EDID/CEA-861 layout from the CEA-861 standard; it is not restated in the Linux files listed above.)
- Policy: publish the device only if the sink is HDMI and advertises LPCM 2 channels; advertise only
  the rates in its SAD (B_SR_44100 and/or B_SR_48000). If block 1 is missing, assume DVI and publish
  nothing (Linux treats such a sink as not audio-capable).
- config.txt: the firmware has options to force HDMI mode or EDID audio (`hdmi_drive`,
  `hdmi_force_edid_audio`, `hdmi_ignore_edid_audio` in the Raspberry Pi documentation). These cannot
  be verified from the Linux tree; do not rely on them in the driver. They may help on the bench.

---

## 6. Implementation plan: `bcm2711_hdmi_audio`

Location: `src/add-ons/kernel/drivers/audio/bcm2711_hdmi_audio/` with a Jamfile like
`bcm2711_pwm`'s. Device name `audio/hmulti/bcm2711_hdmi_audio/1`. HDMI0 only at first.

### Step 1 — read-only probe (settles §0)

A temporary driver (or a test mode of the new one) that, after the display is up:

1. gets `GET_CLOCK_RATE` for clock 13 and stops if it is 0;
2. maps the core, hd, packet and phy blocks and the DVP controller (from the FDT node
   `brcm,bcm2711-hdmi0`, by `reg-names`, and `brcm,brcm2711-dvp`) — read only;
3. logs `HOTPLUG`, `SCHEDULER_CONTROL`, `RAM_PACKET_CONFIG`, `RAM_PACKET_STATUS`, `MAI_CTL`,
   `MAI_SMP`, `MAI_FMT`, `MAI_CONFIG`, `AUDIO_PACKET_CONFIG`, `CRP_CFG`, `CTS_0/1`, `HORZA/B`,
   `VERTA0/B0`, `MISC_CONTROL`, `DEEP_COLOR_CONFIG_1`, `TX_PHY_POWERDOWN_CTL`, DVP `MISC_CONFIG`;
4. logs `GET_DISPLAY_TIMING` for display 2 and EDID block 1.

Run it at boot, after an unplug/replug of the HDMI cable, and after a screen blank/unblank. Expected
for go: HSM > 0, scheduler bits 0 and 1 set, packet RAM bit 16 set, DVP bit 3 clear, an EDID block 1
with LPCM. The values the firmware leaves in the audio registers are also informative (if the
firmware already programs CRP/N, it is aware of audio).

### Step 2 — register write test without DMA

Program §3.7 steps 1-6 and feed MAI_DATA from the CPU for one second (poll `MAI_CTL` FULL, bit 11,
and write subframes of a 1 kHz sine). Expect the capture card to report audio (§7). Also check that
the picture is undisturbed and that `MAI_CTL` shows no DLATE/ERRORE.

### Step 3 — the driver, reusing `bcm2711_pwm`

Copy these parts of `bcm2711_pwm.cpp` unchanged or nearly so:

- device-tree helpers (`read_cells`, `apply_ranges`, `node_registers`, `find_compatible`,
  `map_registers`, `find_dma_interrupt`, `dma_bus_address`); add a "register range by reg-name"
  variant, since the hd block is the 9th range of the HDMI node;
- `dma_control_block`, `allocate_buffers` (contiguous, below 1 GiB, write-combining), the two-segment
  ring with one control block per segment chained in a loop, `arm_dma`, `reset_dma`,
  `dma_interrupt`, the period semaphore, `buffer_exchange`, `buffer_force_stop` and all hmulti
  ioctls.

Change:

| Item | PWM driver | HDMI driver |
|---|---|---|
| DMA channel | 5 | **4** (check `brcm,dma-channel-mask`) |
| TI | INTEN, WAIT_RESP, D_DREQ, S_INC, PERMAP 1 | same with **PERMAP 10** (TI = 0x000a0149) |
| Destination | 0x7e20c818 | **0x7ef2001c** (hd bus address + 0x1c) |
| Ring word | duty cycle | **IEC958 subframe** (§3.1) |
| Frames per segment | 1024 | **960** (multiple of 192) |
| Silence | mid-scale duty | template subframes with sample 0 |
| Ramp on start/stop | yes (PWM clicks) | not needed: digital silence |
| Rates | B_SR_44100 | B_SR_48000 first, then B_SR_44100 (per EDID); `SET_GLOBAL_FORMAT` restarts the engine with new MAI_SMP, MAI_FMT, N/CTS and channel status byte 3 |
| Peripheral setup | `start_clock`, `start_pwm` | §3.7 (preconditions, startup, prepare, InfoFrame) |
| Stop | `stop_pwm` | §3.8 |
| Extra | — | per-period health check and re-arm (§5.1); mailbox for HSM rate, display timing, EDID |

`played_frames_count` stays hardware-paced (DMA interrupts), as in the PWM driver. The engine can
keep running over silence while open, as the PWM driver does; MAI underruns would otherwise set
DLATE.

Latency: 960 frames is 20 ms at 48 kHz; two segments give 40 ms of buffering, as now.

### Step 4 — robustness

- Hotplug and blank handling (§5.1), with a log line on every re-arm.
- Publish the device only when step 1's conditions hold at `init_driver`; otherwise return
  `B_DEVICE_NOT_FOUND`. (Late hotplug after boot: out of scope for the first version; note it in
  KNOWN-ISSUES.)
- Remove any probe-only code before committing; keep diagnostics behind `TRACE`.

---

## 7. Test plan

Bench: the HDMI capture card's audio input is ALSA card 3 ("C3-1 USB3 Video") on the Linux host.
Existing tools:

- `tools/media-tests/tone.cpp` plays a sine through the media kit (`tone [-s SECONDS] [-f HZ]`);
- `tools/pi-tests/audio.sh` is a UserBootscript that lists `/dev/audio`, runs `tone` and logs
  `AUD`/`TONE` lines to the serial console;
- `tools/media-tests/wavtone.py FILE.wav --expect HZ` measures level and frequency per channel and
  prints `WAVTONE PASS|FAIL` (pass: rms > 300 and > 80 % of the power within ±1 % of HZ).

Tests:

1. **Capture card format.** On the host: `arecord -D hw:3,0 --dump-hw-params -d 1 /dev/null`.
   Many USB capture cards record 48 kHz only. Test 48 kHz first. If the card supports only 48 kHz,
   a 44.1 kHz stream is resampled or dropped by the card; that tests the card, not our driver.
2. **Silence carries a stream.** Start the driver with silence. Record 5 s:
   `arecord -D hw:3,0 -f S16_LE -r 48000 -c 2 -d 5 silence.wav`. The file should be digital zero
   (rms near 0), not noise. Then close the device so that no audio packets are sent, and record
   again: some cards then deliver nothing or noise. This shows whether the card can tell "audio
   present" from "no audio", so that a later silent recording is not mistaken for a pass.
3. **Tone at 48 kHz.** `tone -s 10 -f 1000` on the Pi (through audio.sh or a serial command); on the
   host `arecord -D hw:3,0 -f S16_LE -r 48000 -c 2 -d 5 t48.wav` started a few seconds in, then
   `python3 tools/media-tests/wavtone.py t48.wav --expect 1000 --skip 1`. Expect PASS on both
   channels.
4. **Left/right.** A variant of `tone` with different frequencies per channel (e.g. 500 Hz left,
   1000 Hz right) checks the channel map and preambles (a swapped or shifted stream shows up here).
5. **Rate accuracy.** The driver logs its measured frame rate (as the PWM driver does after 128
   periods). Expect 48000.0 Hz ± crystal tolerance, not 44117 Hz. On the host, the recorded tone
   should sit within 0.01 % of 1000 Hz.
6. **44.1 kHz.** If the sink advertises it and the card accepts it: repeat 3 at 44.1 kHz with N 6272,
   then with N 5644, and compare (glitches show up as a low Goertzel share).
7. **Long run.** 10 minutes of tone; count `MAI_CTL` DLATE/ERRORE events and DMA underruns (driver
   log), and check the recording for gaps.
8. **Hotplug and blank.** Unplug and replug the HDMI cable during playback; blank and unblank the
   screen. Expect a re-arm log line and audio back within a second.
9. **A/B with the jack.** Run the same `tone` with the PWM jack as the default output. If the media
   kit misbehaves on both, the problem is not in the HDMI driver.
10. **DVI case.** If a DVI-only display or adapter is available: the driver must not publish a device
    and must not touch the registers.

Every Pi cycle runs under the shared bench lock (`scripts/lib/bench.sh`).
