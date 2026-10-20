# Screenshots

Haiku running on a Raspberry Pi 4 Model B (4 GB) from its SD card, 2026-10-20 — the regular image of this
port, grabbed from the Pi's HDMI output by a capture card (1920×1080, unedited).

| File | What it shows |
|---|---|
| `01-desktop-hardware.png` | WebPositive (HaikuWebKit) on https://www.haiku-os.org/, GLTeapot on the V3D GPU (OpenGL through Mesa, ~60 fps), ActivityMonitor (4 cores), About Haiku ("4 Processors: ARM Cortex-A72 @ 1.50 GHz", 3956 MiB, arm64) and a Terminal with the hardware: `sysinfo`, the board as the VideoCore firmware reports it ("Raspberry Pi 4 Model B rev 1.1, 4096 MB, BCM2711"), the SoC's temperature and clocks, the V3D 4.2 |
| `02-desktop-quake2.png`, `03-desktop-quake2-b.png` | The same desktop with Yamagi Quake II (OpenGL renderer on the V3D) playing its demo in a window; ActivityMonitor shows the four cores at work |
| `04-quakespasm-fullscreen-1080p.png` | QuakeSpasm full screen at 1920×1080 (30–42 frames/s) |
| `05-webpositive.png` | WebPositive alone, the page fully rendered over HTTPS |
| `06-vkquake-vulkan-window.png` | vkQuake 1.35 in a window at 1280×720 on **Vulkan** (Mesa's V3DV on the V3D, through our Haiku WSI and SDL2's Vulkan path), ~29 frames/s; booted over the network (`tools/pi-tests/vkquake.sh`) |

How they are made: `tools/pi-tests/showcase.sh` (a boot script that opens and arranges the windows) with
`scripts/sd-cycle.sh --hdmi-every 15`.
