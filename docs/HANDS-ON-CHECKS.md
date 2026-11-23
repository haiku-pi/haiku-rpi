# Hands-on checks

What only a person at the Pi can check: things you hear, type, click or see on a real monitor. Each check
says what to do, what should happen, and what to send back when it does not. Everything else is tested by the
bench without a person ([LAB-SETUP.md](LAB-SETUP.md)).

**Newest release: image-2026-11-23** (2026-11-23): image-2026-11-22 plus **programs started from the Desktop's Test
Apps folder or the Deskbar's Applications menu open their window** (was KNOWN-ISSUES C18, [design/tracker-launch.md](design/tracker-launch.md); found by the owner on mega36:
Blender, OpenArena, the Quakes, glmark2 and others started through a launcher or a link never showed a window; a Haiku
fix, any program started through a wrapper), with **Blender 3.6.23-11 and SuperTuxKart 1.5-4** in the package
repository (they found no data when started through a link); release checks 0 problems, booted twice from a card,
mega smoke test 34 of 34 and **every one of the 39 Test Apps and Deskbar entries showing its window when opened the
way a double-click does**. New to try with it: double-click each Test Apps entry and the Deskbar's Blender, OpenArena
and SuperTuxKart (Blender by hand passed from a Terminal on mega36, check 13; now it starts from the Deskbar and Test
Apps too).

**The card holds mega38** (2026-11-23: image-2026-11-23's sources plus the libsdl2 2.32.10-9 list bump, every test app,
and the packages published the same day: libsdl2 2.32.10-9, wayland_server 0.1.20251004-11, wine 11.21-4; smoke test
34 of 34 and 39 of 39 through Tracker, no crash). **New since mega37** — the fixes for what the owner found on mega36:
- **Wine games' cursor:** Warcraft III and Diablo II (Test Apps) show only the game's own cursor, no Haiku arrow over
  it; after quitting, the normal cursor is back; windowed Windows programs (Notepad++, PuTTY) keep their cursor.
- **Notepad++'s menu:** one row (was about eight); its ▼ and ✕ at the right are drawn (the ＋ before them is still a box).
- **Blender's render window:** F12 opens it with its tab on the screen (it was above the top edge).
- **Blender's zoom button:** zooms and un-zooms like other windows (un-zooming no longer gives a tab-less window that
  looks like full screen); Window ▸ Toggle Window Fullscreen goes to full screen and back.

On image-2026-11-23 itself `pkgman update` brings the same packages.

**Owner's results on mega36 (2026-11-22), all passed:** typing in Firefox; keys and mouse in a game; the USB keyboard
and mouse across the system; Terminal; ActivityMonitor; Expander (Blender demo scenes downloaded with Firefox and
unpacked in ~/Downloads); **Firefox YouTube in a window and full screen: smooth**; **Blender by hand** (started from a
Terminal: the "Classroom" demo scene loaded quickly, the viewport preview correct, an F12 render started and its first
iterations looked fine — not waited for to the end). Defects found: Test Apps and Deskbar
entries without a window (C18, fixed in image-2026-11-23) and, in full-screen Windows games under Wine (Warcraft III,
Diablo II), Haiku's mouse cursor drawn over the game's own cursor (was KNOWN-ISSUES W14: fixed in the published
wayland_server 0.1.20251004-11, on mega38).

Before it, **image-2026-11-22** (2026-11-22): image-2026-11-21b plus **no kernel panic "Failed to unwire
page"** (it could stop the Pi a moment after MediaPlayer started an H.264 video), **MediaPlayer opening URLs without
a crash** (about 1 in 8 opens crashed), **WebPositive video on the YUV plane** with **seeks that land on their time**
and **no crash when WebPositive is quit during playback** (haikuwebkit 1.10.0-3 in the image), **web video to its
last frame** (no 10 s freeze at the end of a URL's video; MP4s with the index at the end open from a URL), and
**MediaPlayer's full screen keeping the video while it plays**; release checks 0 problems, the VQ1 gate items and
MediaPlayer URL opens without a debugger entry, booted twice from a card, mega smoke test 34 of 34. New to try then: WebPositive on a page with a video (check 11: play,
seek with the slider, quit while it plays); MediaPlayer ▸ File ▸ Open network stream with an `http://` video, played
to its end; MediaPlayer to full screen while a video plays and back.

Before it, **image-2026-11-21b** (2026-11-21): image-2026-11-21 plus **HEVC shown without a copy** (the display plane scans out the decoder's pictures: 1080p30 at ~4 % of a core, **8-bit 4K HEVC on the plane**), **1080p60 H.264 in MediaPlayer with every frame shown** (decoded on the CPU; 1080p30 and below stay on the VideoCore), **screenshots that include video and full-screen games**, and **MediaPlayer's full screen keeping the video** (paused or after the clip ended it left the picture behind on a green screen); release checks 0 problems, H.264 play/two/kill/rate 0 problems, HEVC 1080p/10-bit/4K on the plane, booted twice from a card, mega smoke test 34 of 34. New to try then: MediaPlayer on a 4K HEVC clip and on 1080p60 H.264 (smooth, no dropped frames); MediaPlayer to full screen while paused or after the end and back; a screenshot (Print Screen) while a video plays.

Before it, **image-2026-11-21** (2026-11-21): image-2026-11-19b plus **Firefox video on the display's YUV
plane** (firefox 157.0.1-11: a playing `<video>` is scaled and converted by the display, 720p drawn at about a tenth of
the CPU; captions, controls or scrolling bring it back into Firefox's own drawing), **video in its own colours**
(the stream's colour encoding reaches the plane, MediaPlayer and Firefox), **no Firefox crash when a page with two
H.264 videos is closed** (one VideoCore H.264 stream at a time in the whole system; a second one decodes on the CPU),
and the upstream Haiku of 2026-11-20; release checks 0 problems, H.264 play/two/kill 0 problems, booted twice from
a card, mega smoke test 34 of 34. New to try then:
play a video in Firefox (a local file or a web page) — it should look the same as before, with smooth playback;
hover the controls (the video switches to software while they show, then back); a page with two videos; colours of a
BT.601 SD clip and an HD clip in MediaPlayer.

**The image:** the SD card is shared with the other project on the bench (from 11-23 08:35 it holds **mega38**: image-2026-11-23's sources with libsdl2 2.32.10-9, wayland_server 0.1.20251004-11, wine 11.21-4, Blender 3.6.23-11 and SuperTuxKart 1.5-4; if the other project has reflashed it, reflash `artifacts/images/haiku-pi4-mega.img` before a hands-on session — `scripts/sd-cycle.sh --flash IMG --until 'MEGA end'`) — mega38 is release image-2026-11-23's sources (plus the libsdl2 list bump) plus every program and game we test, started from the Test Apps folder on the Desktop ([MEGA-IMAGE.md](MEGA-IMAGE.md)); smoke test 34 of 34 and 39 of 39 entries with a window when opened through Tracker, no crash. New to try (mega38): Wine games' cursor, Notepad++'s menu, Blender's render window and zoom button (above); (image-2026-11-23): double-clicking Test Apps and Deskbar entries, Blender from the Deskbar; (image-2026-11-22): WebPositive video (check 11), MediaPlayer on a URL and full screen while playing, above; (image-2026-11-21b): 4K HEVC and 1080p60 H.264 in MediaPlayer, its full screen, screenshots of a playing video, above; (image-2026-11-21): Firefox video on the YUV plane. Before (image-2026-11-19b): Blender (`pkgman install blender`, then Deskbar ▸ Applications ▸ Blender: orbit, Tab into edit mode, F12 renders with EEVEE; from 2026-11-20 `pkgman update blender` gives 3.6.23-9 with Cycles denoising, USD import/export, OpenVDB volumes and voxel remesh, the Exact boolean, Alembic, Ocean, fluids, 38 interface languages and a working Rendered viewport; from 2026-11-22 it gives 3.6.23-10, whose viewport orbits ~50 % faster: no anti-aliasing while you navigate, anti-aliased again when you stop — mega36 has 3.6.23-10); H.264 videos in Firefox (now decoded by the VideoCore). Also (image-2026-11-19): videos in MediaPlayer now shown as YUV on a display plane (1080p at a quarter of a core; change the screen mode while one plays); desktop OpenGL 3.3 (Quake II's GL3 renderer: `+set vid_renderer gl3`); WiFi joined once from Network preferences is joined again after a reboot. Earlier: H.264 videos in MediaPlayer (decoded by the VideoCore); Unreal Tournament with its OpenGL renderer (it crashed at its first frame before; KNOWN-ISSUES W10); Shut down and Restart from the Deskbar's leaf menu (a restart comes back by itself; after a shutdown the board is halted — unplug it); USB disks keep their data (copy files to and from a USB stick and compare); SuperTuxKart and Quake II now run at the display's 60 fps in a window with their default vsync setting (turn vsync off in the game for more); full-screen GL games and MediaPlayer videos go on display planes. Before them, **image-2026-11-18**: image-2026-11-17 plus **faster 32-bit Windows OpenGL/Direct3D games** (GL_MESA_map_buffer_client_pointer: the Warcraft III demo menu 13.6 → 22.9 fps; try the Windows games in Test Apps) and eleven fixes from RenkuOS (power-saving scheduling, a TCP deadlock, a boot deadlock, saved WiFi networks re-joined after boot, …); release checks 0 problems, booted twice from a card, mega smoke test 33 of 33. Before it, **image-2026-11-17**: image-2026-11-05c plus the upstream Haiku of 2026-11-17 (164 commits merged), Mesa 26.2.7, and WebPositive's video at the right speed (KNOWN-ISSUES F11); release checks 0 problems, booted twice from a card, mega smoke test 33 of 33. Before it, **image-2026-11-05c**: image-2026-11-05b plus **H.264 decoded by the VideoCore** in MediaPlayer and WebPositive (1080p30 at 88 % of a core with every frame on time; one 1080p stream at a time; Firefox still on the CPU — KNOWN-ISSUES P2) and the BFS rm -rf deadlock fix; release checks 0 problems, booted twice from a card. Before it, **image-2026-11-05b**: image-2026-11-05 plus SD card writes about 50 % faster and large reads faster (card commands, page writer and file cache up to 512 KiB: raw writes 24 → 35.6 MB/s, BFS 1 GiB + sync 26 → 34) and no service restart storm during a held shutdown; release checks 0 problems, booted twice from a card. Before it, **image-2026-11-05**: image-2026-11-04c plus programs from a plain disk starting much faster the first time (page faults read 64 KiB around the page: Firefox from a BFS folder 14.0 → 8.4 s), Firefox 157.0.1-6 (DT_RELR), no Tracker crash at shutdown, WiFi using a third less CPU, a usb_disk teardown deadlock fixed, and the fixes from the x86-64 check; release checks 0 problems, booted twice from a card. Before it, **image-2026-11-04c**: image-2026-11-04b plus working Shut down and Restart (Deskbar's leaf menu; a restart comes back by itself, a shutdown halts the board — then unplug it), no kernel panic when a damaged BFS volume is mounted, USB disk buffers kept below the PCIe 3 GiB window, faster thread-local data, and two fixes from RenkuOS; release checks 0 problems, booted twice from a card. Before it, **image-2026-11-04b**: image-2026-11-04 plus correct data on USB disks (every older image corrupts files copied to or from a USB disk on the Pi 4 — KNOWN-ISSUES C13; update before trusting a USB disk) and faster BFS writes in large transactions; release checks 0 problems, booted twice from a card. Before it, **image-2026-11-04**: image-2026-11-03c (GCC 16.2, GPU stages 6 and 7, DWARF 5 Debugger) plus windowed GL paced to the display (SDL games with vsync on — SuperTuxKart, Quake II — run at 60 fps and use about a third of the CPU), short programs starting at full clock speed again, and `profile -a` seeing new programs; release checks 0 problems. image-2026-11-03 was the last GCC 13.3 build. Earlier notes on what changed:
everything of `image-2026-10-23d` plus a 3 s faster boot, faster memory/string functions, thread-local variables
and file reads, two kernel panics fixed (C5, C8), and the onboard USB hub no longer dropping out in ~1 boot in 10
(C9) — relevant for the keyboard and mouse checks below. Plug the HDMI monitor, the USB keyboard and mouse, headphones in the 3.5 mm jack and the
Ethernet cable; power on. The desktop comes up a little over a minute after power-on, most of it the bench Pi's
firmware trying the network first (the release cards on 2026-11-03: U-Boot at ~58 s, the desktop ~6.5 s later). Wine: `pkgman install wine wine_x86 wine_x86_64 wine_mono` (wine 11.21-3, Wine
Mono: .NET programs run, no Mono question).

**When something is wrong**, the most useful things to send back are:
- the system log: `/var/log/syslog` (Terminal: `cp /var/log/syslog ~/Desktop/` and copy it off on a USB
  stick, or `scp` it), and the time it happened;
- a screenshot (the Print Screen key opens Screenshot, which saves where you choose), or a phone photo of
  the monitor;
- for a program that crashed: Haiku's crash dialog offers "Save report" — save it and send it too.

**Done so far** (owner, 2026-10-25, image-2026-10-25e): checks 1 and 2 — keyboard and mouse work, everyday
desktop use is fine, the system feels fast. (owner, 2026-11-22, mega36): checks 1 and 2 again across the system,
4 in Firefox, 5, 12, 13 (Blender, started from a Terminal) and 14 passed; still open: 3 (audio by ear), 7 (WiFi),
9 (Bluetooth), 11 (WebPositive video); not reported: 4 in WebPositive, 6 (a real monitor with GL), 8 (Wine by hand:
the owner saw the cursor defect above in full-screen games), 10 (shutting down). Since then a card-booted Pi also gets an address from the bench
(`scripts/pi-test.sh` runs a DHCP server that leaves the firmware alone), so the network checks below can be done.

| # | Check | Do | Expected |
|---|---|---|---|
| 1 | **Keyboard** ✅ 10-25, 11-22 | Open Terminal (Applications → Terminal) and type `ls -l /boot/system`; try Shift, Ctrl+C, the arrow keys, Backspace | Every key appears once, no repeats or lost keys; Ctrl+C interrupts |
| 2 | **Mouse** ✅ 10-25, 11-22 | Move the pointer, open the Deskbar menu, drag a window, scroll in a Terminal or in WebPositive with the wheel, right-click the desktop | The pointer follows smoothly (hardware cursor), clicks land where the pointer is, the wheel scrolls |
| 3 | **Audio by ear** | Image-2026-10-24e and later: sound goes to the HDMI monitor by default if it takes audio — listen there first; then choose "Raspberry Pi headphones" in Preferences → Media and plug headphones into the 3.5 mm jack. Open MediaPlayer and play `/boot/system/data/sounds/Burg's Sparkly Tones/Burg's Sparkly Tones - Startup.ogg` (drag it onto MediaPlayer); then any music file you have (MP3/OGG/FLAC on a USB stick) | Clean sound at the right pitch and speed, no crackling or gaps; the volume control in the Deskbar works |
| 4 | **Typing in browsers** ✅ Firefox 11-22 (WebPositive open) | WebPositive and Firefox (Applications menu): type a search into a web page's text field (e.g. duckduckgo.com) and in the address bar | Every character arrives; Backspace, Shift and the arrow keys work |
| 5 | **Keys and mouse in an SDL game** ✅ 11-22 | `pkgman install supertuxkart openarena`, then Applications → SuperTuxKart: steer a race with the arrow keys; Applications → OpenArena: look around with the mouse, fire with the button | Steering and mouse look respond without delay; no keys stuck |
| 6 | **A real monitor while a GL program runs** | Run GLTeapot (`/boot/system/demos/GLTeapot`) and look closely at the desktop around it | No sparkling dots ("speckles") on the desktop. The capture card shows some; whether a real monitor does is the question |
| 7 | **WiFi from Network preferences** | Unplug the Ethernet cable. Deskbar → Network status (or Preferences → Network) → choose your WPA2 network, enter its password | Joins and gets an address; WebPositive loads a page |
| 8 | **Windows programs (Wine)** | `pkgman install wine wine_x86 wine_x86_64` (~1.5 min), then `wine winemine` in Terminal (the first start makes `~/.wine`: ~3 min from the SD card, Cancel the Wine Mono question), then `wine notepad` | Minesweeper takes mouse clicks (left and right); Notepad takes typing, capitals with Shift too; in File → Save As, typing a name replaces the proposed one (fixed in wine 11.20-17). A 32-bit x86 Windows game you own can be tried too (e.g. a 1990s demo: `wine game.exe` in its folder) |
| 9 | **Bluetooth (optional)** | Terminal: `/boot/system/servers/bluetooth_server &`, then `bt_dev_info`; with a phone or laptop set discoverable, `bt_discovery` | `bt_dev_info` prints the controller: `BCM43455 ... DC:A6:32:3C:DD:F5`; `bt_discovery` lists the other device with its class and name after ~13 s. Pairing from the other device works by PIN (a "PIN Code Request" window opens on the Pi; the Pi must be connectable first, which only the port's test tool `btscan` sets — optional) |
| 10 | **Shutting down** | Deskbar → Shut down | The Pi powers down cleanly; the next boot is normal (no disk check) |
| 11 | **WebPositive video** (image-2026-11-22 and later and mega36/37 have haikuwebkit 1.10.0-3; on older images `pkgman update haikuwebkit` first, then restart WebPositive) | Open a page with an H.264 or HEVC video (e.g. a test-video site, or a local file: `file:///boot/home/clip.mp4`), play it, scroll the page, hover the video's controls, open another tab and come back, resize the window; quit WebPositive (Window → Quit) while it plays, several times; drag the video's position slider (paused and playing) | The picture is smooth and in the right colours, never a flat green or magenta area where the video should be (a short switch to slightly softer software drawing while scrolling or with the controls showing is expected); quitting never brings up the crash dialog; a seek shows the picture of the chosen time and plays on from there |
| 12 | **Firefox video (YouTube)** ✅ 11-22: passed (owner, 2026-11-22) | Firefox (Applications menu): play a YouTube video in the window, then full screen | Smooth playback in both |
| 13 | **Blender by hand** ✅ 11-22: passed (owner, 2026-11-22: "Classroom" scene loaded, viewport correct, F12 render started; started from a Terminal — from the Deskbar or Test Apps it needs image-2026-11-23 / mega37, C18) | Deskbar → Applications → Blender (or Test Apps → Blender 3.6): orbit the default cube with the middle mouse button, Tab into edit mode and back, F12 to render with EEVEE, open a .blend file | The window opens within ~20 s; orbiting is fluid; the render window shows the cube; no crash dialog |
| 14 | **Everyday applications** ✅ 11-22: passed (owner, 2026-11-22) | Terminal; ActivityMonitor; download a zip with Firefox and unpack it with Expander (double-click it in ~/Downloads) | Each works; Expander unpacks into the folder |

Known limits you may run into ([KNOWN-ISSUES.md](KNOWN-ISSUES.md)): HDMI audio only when the monitor is connected at boot; the first
video played after Firefox starts drops frames (play it again); a full-screen Windows game switches the screen
to its own resolution (the monitor shows it scaled, with black bars at the sides) until it ends; Bluetooth devices
(keyboards, mice, audio) are untested; after a screen-mode change while a video plays in MediaPlayer, the video stays
black until it is restarted.
