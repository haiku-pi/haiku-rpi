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
| `07-mediaplayer-hevc-1080p-hardware.png` | MediaPlayer playing a 1080p HEVC test stream (20 Mbit/s) decoded by the BCM2711's HEVC block (`hevc_rpivid`): ~115 fps possible at under half a core, vs 25 fps on all four cores in software |
| `08-openarena-ioquake3.png` | OpenArena 0.8.8 on ioquake3 (the Quake III engine; SDL2 + OpenGL on the V3D) in a 1280×720 window: the timedemo runs at 46 fps |
| `09-supertuxkart.png` | SuperTuxKart 1.5 racing on Hacienda (4 karts) in a 1280×720 window: STK's OpenGL 2.1 renderer on the V3D, 28–38 frames/s |
| `10-firefox-window.png` | **Firefox 157** in a Haiku window on the Pi (HDMI capture): a local test page — JavaScript reports "Haiku aarch64" |
| `11-firefox-haiku-os-org.png` | Firefox 157 on the Pi rendering https://www.haiku-os.org/ (its own `--screenshot` of the page, top part) |
| `12-supertuxkart-gles-shaders.png` | SuperTuxKart with its **GLES 3.1 shader renderer** (lit, sky) — Haiku's GL view now makes OpenGL ES contexts (BGL_CONTEXT_ES); 16–18 fps at 1280×720 |
| `13-wine-winemine.png` | **Wine 11** on Haiku arm64: Wine's Minesweeper in a Haiku window (the Wayland driver over X547's in-process compositor) |
| `14-wine-simcity3000-title.png` | SimCity 3000's demo (32-bit x86, 1999) under Wine + Box64: its title screen (the city after it is garbled by wined3d's GDI renderer — the same on x86-64 Wine; its OpenGL renderer draws it right) |
| `15-wine-heroes3-menu.png` | **Heroes of Might and Magic III** demo (32-bit x86) under Wine (WoW64) + Box64: the main menu (DirectDraw 800×600×16, scaled to the HDMI height) |
| `16-wine-heroes3-adventure-map.png` | Heroes III in a game: the adventure map, the hero, the castle — an x86 Windows game playing on Haiku on the Pi |
| `17-wine-heroes3-welcome.png` | Heroes III: the demo scenario's welcome |
| `18-wine-opengl-v3d.png` | OpenGL in a Wine window on the V3D (`tools/wine-tests/gltest.c`): win32u's EGL driver on Mesa, ~290 fps, arm64 and x86 alike |
| `19-wine-halflife-uplink-opengl.png` | **Half-Life: Uplink** (Valve's free 1999 demo, 32-bit x86) under Wine + Box64: its main menu (the demo's default software renderer, `sw.dll`; New Game then faults at the map load under Box64, not on x86 Wine) |
| `20-wine-halflife-uplink-ingame.png` | **Half-Life: Uplink in a game** on Haiku on the Pi (Wine 11.20 + Box64, software renderer, a 320×240 window), after the fixes of [design/wine-debugging.md](../design/wine-debugging.md) |
| `21-wine-halflife-uplink-ingame-3x.png` | the same window, 3× |
| `22-wine-halflife-fullscreen-opengl.png` | Half-Life full screen through wined3d's **OpenGL renderer on the V3D** — with an experimental ddraw change (its picture drawn into the game's full-screen window) that is not in the build yet: it stretches DirectDraw games (Heroes III) wrongly, see the log of 10-22 |
| `23-wine-simcity3000-opengl.png` | **SimCity 3000** demo (1999, 32-bit x86, DirectDraw) on wined3d's **OpenGL renderer on the V3D**: the city right (the GDI renderer garbles it); Wine patch 0006 made DirectDraw show on the GL renderer |
| `24-wine-starcraft-intro.png` | **StarCraft** (1998 shareware) playing its intro under Box64's dynarec — it crashed before the Haiku write-fault fix; its main menu follows (cut off on the right: the full-screen scaling still to fix) |

How they are made: `tools/pi-tests/showcase.sh` (a boot script that opens and arranges the windows) with
`scripts/sd-cycle.sh --hdmi-every 15`; the Wine ones (2026-10-21, network boot) with `tools/pi-tests/wine-games.sh`
— the game demos are downloaded for the test only and are not part of this repository or our packages.
A clip: [`../video/wine-heroes3-pi4.mp4`](../video/wine-heroes3-pi4.mp4) (74 s: the intro, then the scenario's welcome and its map; the game area, from
`netboot-cycle.sh --record`).
