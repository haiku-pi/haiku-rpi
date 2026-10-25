# Hands-on checks

What only a person at the Pi can check: things you hear, type, click or see on a real monitor. Each check
says what to do, what should happen, and what to send back when it does not. Everything else is tested by the
bench without a person ([LAB-SETUP.md](LAB-SETUP.md)).

**The image:** the SD card of the bench Pi holds release **image-2026-10-25d** (hrev60295+173, Mesa 26.2.5, Firefox 157.0.1-5; sound over HDMI; the clock is kept across reboots; programs start twice as fast):
everything of `image-2026-10-23d` plus a 3 s faster boot, faster memory/string functions, thread-local variables
and file reads, two kernel panics fixed (C5, C8), and the onboard USB hub no longer dropping out in ~1 boot in 10
(C9) — relevant for the keyboard and mouse checks below. Plug the HDMI monitor, the USB keyboard and mouse, headphones in the 3.5 mm jack and the
Ethernet cable; power on. The desktop comes up in about 70 s, most of it the bench Pi's firmware trying the
network first. Wine: `pkgman install wine wine_x86 wine_x86_64 wine_mono` (wine 11.20-19, Wine Mono: .NET
programs run, no Mono question).

**When something is wrong**, the most useful things to send back are:
- the system log: `/var/log/syslog` (Terminal: `cp /var/log/syslog ~/Desktop/` and copy it off on a USB
  stick, or `scp` it), and the time it happened;
- a screenshot (the Print Screen key opens Screenshot, which saves where you choose), or a phone photo of
  the monitor;
- for a program that crashed: Haiku's crash dialog offers "Save report" — save it and send it too.

| # | Check | Do | Expected |
|---|---|---|---|
| 1 | **Keyboard** | Open Terminal (Applications → Terminal) and type `ls -l /boot/system`; try Shift, Ctrl+C, the arrow keys, Backspace | Every key appears once, no repeats or lost keys; Ctrl+C interrupts |
| 2 | **Mouse** | Move the pointer, open the Deskbar menu, drag a window, scroll in a Terminal or in WebPositive with the wheel, right-click the desktop | The pointer follows smoothly (hardware cursor), clicks land where the pointer is, the wheel scrolls |
| 3 | **Audio by ear** | Image-2026-10-24e and later: sound goes to the HDMI monitor by default if it takes audio — listen there first; then choose "Raspberry Pi headphones" in Preferences → Media and plug headphones into the 3.5 mm jack. Open MediaPlayer and play `/boot/system/data/sounds/Burg's Sparkly Tones/Burg's Sparkly Tones - Startup.ogg` (drag it onto MediaPlayer); then any music file you have (MP3/OGG/FLAC on a USB stick) | Clean sound at the right pitch and speed, no crackling or gaps; the volume control in the Deskbar works |
| 4 | **Typing in browsers** | WebPositive and Firefox (Applications menu): type a search into a web page's text field (e.g. duckduckgo.com) and in the address bar | Every character arrives; Backspace, Shift and the arrow keys work |
| 5 | **Keys and mouse in an SDL game** | `pkgman install supertuxkart openarena`, then Applications → SuperTuxKart: steer a race with the arrow keys; Applications → OpenArena: look around with the mouse, fire with the button | Steering and mouse look respond without delay; no keys stuck |
| 6 | **A real monitor while a GL program runs** | Run GLTeapot (`/boot/system/demos/GLTeapot`) and look closely at the desktop around it | No sparkling dots ("speckles") on the desktop. The capture card shows some; whether a real monitor does is the question |
| 7 | **WiFi from Network preferences** | Unplug the Ethernet cable. Deskbar → Network status (or Preferences → Network) → choose your WPA2 network, enter its password | Joins and gets an address; WebPositive loads a page |
| 8 | **Windows programs (Wine)** | `pkgman install wine wine_x86 wine_x86_64` (~1.5 min), then `wine winemine` in Terminal (the first start makes `~/.wine`: ~3 min from the SD card, Cancel the Wine Mono question), then `wine notepad` | Minesweeper takes mouse clicks (left and right); Notepad takes typing, capitals with Shift too; in File → Save As, typing a name replaces the proposed one (fixed in wine 11.20-17). A 32-bit x86 Windows game you own can be tried too (e.g. a 1990s demo: `wine game.exe` in its folder) |
| 9 | **Bluetooth (optional)** | Terminal: `/boot/system/servers/bluetooth_server &`, then `bt_dev_info`; with a phone or laptop set discoverable, `bt_discovery` | `bt_dev_info` prints the controller: `BCM43455 ... DC:A6:32:3C:DD:F5`; `bt_discovery` lists the other device with its class and name after ~13 s. Pairing from the other device works by PIN (a "PIN Code Request" window opens on the Pi; the Pi must be connectable first, which only the port's test tool `btscan` sets — optional) |
| 10 | **Shutting down** | Deskbar → Shut down | The Pi powers down cleanly; the next boot is normal (no disk check) |

Known limits you may run into ([KNOWN-ISSUES.md](KNOWN-ISSUES.md)): HDMI audio only when the monitor is connected at boot; the first
video played after Firefox starts drops frames (play it again); a full-screen Windows game switches the screen
to its own resolution (the monitor shows it scaled, with black bars at the sides) until it ends; Bluetooth pairing is untested.
