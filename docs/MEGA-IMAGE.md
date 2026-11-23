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
launcher out when it cannot. Host tools it uses: `curl`, `unzip`, `7z`, `unshield`. Half-Life Uplink, the
StarCraft shareware and the Diablo II and Warcraft III demos are set up by their own installers, which only run
under Wine: they come from an installed tree of an earlier build (`artifacts/wine-games/tree`), and are left out
of the image otherwise.

## What is in it

| | |
|---|---|
| System | the current Haiku `rpi4` branch, the current Mesa (OpenGL ES 3.1 / OpenGL 3.3 core, Vulkan 1.3) and libglvnd: every performance change, also those not yet in a release |
| Applications | Firefox, WebPositive, MediaPlayer, Photocraft (photo editor), glmark2, GLTeapot, vkcube |
| Games | OpenArena, SuperTuxKart; QuakeSpasm and vkQuake (Quake shareware), Yamagi Quake II (demo), Quake III Arena (demo) |
| Windows programs (Wine 11.21; x86 via Box64, x86-64 via FEX) | Minesweeper, Notepad, PuTTY, Notepad++, SumatraPDF, 7-Zip (console) — each as x86 and x86-64 where both exist |
| Windows games | Heroes of Might and Magic III (demo), SimCity 3000 (demo), StarCraft (shareware), Half-Life Uplink (demo), Fallout (demo), Age of Empires II (demo), Unreal Tournament (demo, OpenGL renderer), Diablo II (demo), Warcraft III (demo) |

Everything starts from the **Test Apps** folder on the Desktop with a double-click (small launcher
programs, [tools/mega/apps.txt](../tools/mega/apps.txt); each program's output in `~/mega-logs/`). The
first boot creates that folder and sets Wine up (about two minutes, a notification says when it is done:
[tools/mega/first-boot.sh](../tools/mega/first-boot.sh)).

## On the bench

`scripts/pi-test.sh` boots the card with a DHCP server on the Pi LAN (the host is the gateway and DNS
server; the firmware's network boot requests are ignored), so the network, `pkgman` and the browsers work.

The bench card holds **mega38** (2026-11-23): image-2026-11-23's sources plus the libsdl2 2.32.10-9 list bump (haiku
`db1f8f465f`, hrev60450+376) and the content above, with wayland_server 0.1.20251004-11, wine 11.21-4, Blender
3.6.23-11 and SuperTuxKart 1.5-4; smoke test 34 of 34, and 39 of 39 entries with a window through Tracker (mega37 was
release image-2026-11-23 itself, with wayland_server -10, wine 11.21-3 and libsdl2 -8). The mega images are numbered in the weekly logs, one per card write; what the owner should try
on it: [HANDS-ON-CHECKS.md](HANDS-ON-CHECKS.md).

## Check it

`scripts/mega-smoke.sh` boots the image from the network on the bench Pi (the card is not touched), sets it up
as its first boot would, then starts every Test Apps entry for 25 s and screenshots it: one line per entry with
whether it still runs and how much of the screen it changed (artifacts/mega-smoke/, with the programs' logs). That part starts each program by exec from a shell; then it
opens every Test Apps entry and the Deskbar entries the image adds the way a double-click does (through Tracker and the
roster: `tools/pi-tests/ta1-sweep.sh` with `tools/haiku-tests/trackeropen.cpp`) and requires each to show a window and
keep it 10 s ("TRACKER result", exit 3 otherwise; `--no-tracker` leaves it out). On mega36, 13 of those entries never
showed a window (fixed in image-2026-11-23, blender 3.6.23-11 and supertuxkart 1.5-4: design/tracker-launch.md);
the exec-only smoke test had passed 34 of 34.
