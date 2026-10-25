Haiku on the Raspberry Pi 4 — the test image ("mega" image)

Everything the port covers, in one image built from the current sources (scripts/build-mega-image.sh).
Not a release: built locally, for testing.

Test Apps (this folder): double-click to start. Each program's output goes to ~/mega-logs/.
  Quake (QuakeSpasm, OpenGL), Quake (vkQuake, Vulkan), Quake II (demo), Quake III Arena (demo)
  glmark2 in a window / full screen, vkcube (Vulkan), GLTeapot
  Photocraft (photo editor), Firefox, WebPositive, MediaPlayer
  OpenArena, SuperTuxKart (also in the Applications menu)
  Windows programs through Wine (x86 via Box64, x86-64 via FEX): Minesweeper, Notepad, PuTTY,
    Notepad++, SumatraPDF, 7-Zip (console)
  Windows games: Heroes of Might and Magic III (demo), SimCity 3000 (demo), StarCraft (shareware),
    Half-Life Uplink (demo, in a window or full screen), Fallout (demo)

The first boot sets Wine up (about 2 minutes); a notification says when it is ready. Windows programs
started before that wait for it.

Network: Ethernet with DHCP. Keyboard shortcuts in Wayland programs (Photocraft) use the Command key
(left Alt on a PC keyboard), as everywhere in Haiku.

When something goes wrong: /var/log/syslog, ~/mega-logs/<program>.log, a screenshot (Print Screen),
and Haiku's crash dialog's "Save report".
