# Hands-on checks

What only a person at the Pi can check: things you hear, type, click or see on a real monitor. Each check
says what to do, what should happen, and what to send back when it does not. Everything else is tested by the
bench without a person ([LAB-SETUP.md](LAB-SETUP.md)).

**The image:** the SD card of the bench Pi holds `haiku-pi4-2026-10-23.img` (hrev60262+146: the 10-22
release plus the kernel's fault-signal fix, `remote_disk` only on network boots, the fixed Bluetooth tools in the image).
Plug the HDMI monitor, the USB keyboard and mouse, headphones in the 3.5 mm jack and the Ethernet cable;
power on. The desktop comes up in about 80 s.

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
| 3 | **Audio by ear** | Headphones in the 3.5 mm jack. Open MediaPlayer and play `/boot/system/data/sounds/Burg's Sparkly Tones/Burg's Sparkly Tones - Startup.ogg` (drag it onto MediaPlayer); then any music file you have (MP3/OGG/FLAC on a USB stick) | Clean sound at the right pitch and speed, no crackling or gaps; the volume control in the Deskbar works |
| 4 | **Typing in browsers** | WebPositive and Firefox (Applications menu): type a search into a web page's text field (e.g. duckduckgo.com) and in the address bar | Every character arrives; Backspace, Shift and the arrow keys work |
| 5 | **Keys and mouse in an SDL game** | `pkgman install supertuxkart openarena`, then Applications → SuperTuxKart: steer a race with the arrow keys; Applications → OpenArena: look around with the mouse, fire with the button | Steering and mouse look respond without delay; no keys stuck |
| 6 | **A real monitor while a GL program runs** | Run GLTeapot (`/boot/system/demos/GLTeapot`) and look closely at the desktop around it | No sparkling dots ("speckles") on the desktop. The capture card shows some; whether a real monitor does is the question |
| 7 | **WiFi from Network preferences** | Unplug the Ethernet cable. Deskbar → Network status (or Preferences → Network) → choose your WPA2 network, enter its password | Joins and gets an address; WebPositive loads a page |
| 8 | **Windows programs (Wine)** | `pkgman install wine wine_x86 wine_x86_64` (~1.5 min), then `wine winemine` in Terminal (the first start makes `~/.wine`: ~7 min, Cancel the Wine Mono question), then `wine notepad` | Minesweeper takes mouse clicks (left and right); Notepad takes typing. A 32-bit x86 Windows game you own can be tried too (e.g. a 1990s demo: `wine game.exe` in its folder) |
| 9 | **Bluetooth (optional)** | Terminal: `/boot/system/servers/bluetooth_server &`, then `bt_dev_info` | It prints the controller: `BCM43455 ... DC:A6:32:3C:DD:F5` (pairing is not expected to work yet) |
| 10 | **Shutting down** | Deskbar → Shut down | The Pi powers down cleanly; the next boot is normal (no disk check) |

Known limits you may run into ([KNOWN-ISSUES.md](KNOWN-ISSUES.md)): no HDMI audio (use the jack); the first
video played after Firefox starts drops frames (play it again); full-screen Windows games are slower than
windowed ones; Bluetooth pairing is untested.
