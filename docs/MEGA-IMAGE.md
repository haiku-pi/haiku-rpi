# The test image ("mega" image)

One SD image with everything this port covers, for testing the whole system by hand: built from the
current sources, by you, on your machine. **It is never published or archived**: the game data and the
Windows programs in it are copyrighted. They are not in this repository; `scripts/build-mega-image.sh`
downloads each from its publisher's public location (or the Internet Archive's copy of a freely
distributed demo or shareware release) into your own cache, checking its SHA-256
([tools/mega/assets.txt](../tools/mega/assets.txt)).

## Build it

```sh
scripts/build-mega-image.sh            # ~1 h from a built tree; artifacts/images/haiku-pi4-mega.img (16 GB)
scripts/pi-test.sh --flash artifacts/images/haiku-pi4-mega.img
```

Options: `--size MB` (default 16000: a 32 GB card or larger), `--no-build` (use the last jam build as it
is), `--out IMG`, `--cache DIR`. It needs the trees of a full build of this repository (see
[BUILD.md](BUILD.md)); where something is missing it builds it when a script exists, and leaves the
launcher out when it cannot.

## What is in it

| | |
|---|---|
| System | the current Haiku `rpi4` branch, the current Mesa (OpenGL ES 3.1 / OpenGL 2.1, Vulkan 1.3) and libglvnd: every performance change, also those not yet in a release |
| Applications | Firefox, WebPositive, MediaPlayer, Photocraft (photo editor), glmark2, GLTeapot, vkcube |
| Games | OpenArena, SuperTuxKart; QuakeSpasm and vkQuake (Quake shareware), Yamagi Quake II (demo), Quake III Arena (demo) |
| Windows programs (Wine 11.20; x86 via Box64, x86-64 via FEX) | Minesweeper, Notepad, PuTTY, Notepad++, SumatraPDF, 7-Zip (console) — each as x86 and x86-64 where both exist |
| Windows games | Heroes of Might and Magic III (demo), SimCity 3000 (demo), StarCraft (shareware), Half-Life Uplink (demo), Fallout (demo) |

Everything starts from the **Test Apps** folder on the Desktop with a double-click (small launcher
programs, [tools/mega/apps.txt](../tools/mega/apps.txt); each program's output in `~/mega-logs/`). The
first boot creates that folder and sets Wine up (about two minutes, a notification says when it is done:
[tools/mega/first-boot.sh](../tools/mega/first-boot.sh)).

## On the bench

`scripts/pi-test.sh` boots the card with a DHCP server on the Pi LAN (the host is the gateway and DNS
server; the firmware's network boot requests are ignored), so the network, `pkgman` and the browsers work.
