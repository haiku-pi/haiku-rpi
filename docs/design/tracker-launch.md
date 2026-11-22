# Programs that start from a shell but not from Tracker or the Deskbar (TA1, 2026-11-22)

Owner report on mega36 (image-2026-11-22 + Test Apps): Blender from the Desktop's Test Apps folder and from the
Deskbar's Applications menu never shows a window (the process stays, uses some CPU, only `kill` ends it); the
same from a Terminal works; OpenArena and some other Test Apps entries do the same; Firefox works.

## Verdict

**Two defects, both only on the Tracker / Deskbar path** (`mega-smoke` starts every entry by exec from a shell,
so its 34 of 34 never saw them):

1. **A (the hang): a team that the roster launched and that then exec()s another program.** When Tracker (or
   the Deskbar, which sends the same `B_REFS_RECEIVED` to Tracker) launches an executable, `BRoster::_LaunchApp()`
   pre-registers the new team, and the registrar creates the application's looper port and gives it to the team
   (`TRoster::HandleSetThreadAndTeam()`). The Test Apps entries are small launchers (`tools/mega/launcher.c`:
   `sh -c "... exec PROGRAM"`); OpenArena's packaged entry is a shell script that execs `ioquake3`. `exec()`
   deletes every port the team owns (`delete_owned_ports()` in `exec_team()`), with the roster's
   `B_ARGV_RECEIVED` and `B_READY_TO_RUN` queued in it. The new image's `BApplication::_InitData()` still finds
   the team pre-registered, deletes its own port, adopts the dead one and completes the registration with it.
   Its looper then spins on `read_port()` = `B_BAD_PORT_ID`, `ReadyToRun()` never comes, and SDL's
   `StartBeLooper()` waits for `!be_app->IsLaunching()` forever: no window, CPU in the "SDLApplication"
   thread.
   - A shell script reached through a **link** (the Test Apps and Deskbar entries are links) is pre-registered
     too: `_TranslateRef()` resolves the document ref in place but keeps the link as the app ref, so the
     `isScript` test (`*docRef == appRef`) is false. A script opened directly is not pre-registered, and its
     program registers itself — which is why `open /boot/system/apps/OpenArena/OpenArena` worked and the
     Test Apps link to it did not.
   - Upstream code, unchanged for years (exec port deletion 2008, the registrar's port 2015, the
     pre-registered branch 2004); not a regression of a merge. Every mega image since the launchers came
     (10-25) had it.
2. **B (an exit, no hang): `argv[0]` is the link's path.** The roster passes the link it was given as
   `argv[0]` (`*appRef = originalRef`, upstream 4eaa1f35e5 "in case its name or attributes are relevant").
   Blender (`where_am_i()` takes `argv[0]` on Haiku) and SuperTuxKart (`FileManager` looks next to the
   executable's path) then look for their data next to the link — `/boot/system/data/deskbar/menu/Applications/`, or
   `~/Desktop/Test Apps/` for SuperTuxKart's Test Apps entry (a link to the program too): Blender prints
   `No module named 'bpy'` and aborts within 2 s, SuperTuxKart exits 1 ("Could not find file
   'supertuxkart.1.5'"). This is what the Deskbar's Blender and SuperTuxKart entries and the Test Apps SuperTuxKart link did.

## Evidence (session ta1, mega36, 2026-11-22 20:15–20:50 Pi time)

- Roster launch the way a double-click does it: `tools/haiku-tests/trackeropen.cpp` sends Tracker a
  `B_REFS_RECEIVED` with the entry's ref (Tracker launches it with its own environment), then waits for a shown
  window in a new team. The Deskbar's menu items send the same message to Tracker (`TDeskbarMenu::DefaultTarget()`
  is Tracker's messenger; `BNavMenu(..., B_REFS_RECEIVED, ...)`). (`hey Tracker load with refs=file(...)` did nothing.)
- Test Apps "Blender 3.6": no window in 60 s; `ps -s`: main thread `zzz` (SDL's 10 ms poll), "SDLApplication"
  `run` with 39 s of CPU. `roster` lists the team under the **launcher's** path with port 1138; `listport` of the
  team has no port 1138 (only 1141–1146).
- OpenArena via the Test Apps link: the Debugger's saved report of "SDLApplication":
  `libroot (read_port) ← BLooper::task_looper() ← BApplication::Run() ← libSDL2 (StartBeApp)`, `x0 =
  0x80001200` = `B_BAD_PORT_ID`.
- The same launcher, changed to fork and exec in the child (the launched team keeps its port; the program is a
  new, unregistered team): Blender's window after 1.05 s. Mechanism confirmed before any Haiku change.
- Deskbar's Blender link run from a shell with the link as `argv[0]`: `bpy: couldn't find 'scripts/modules'`,
  `Abort`, exit 1 after 2 s; the Deskbar's SuperTuxKart link: exit 1, FileManager's error.

## Fix

- **A — libbe** (haiku branch `ta1-exec-preregistered`, 2c33b68742 on rpi4 eaeb21e6e6): in
  `BApplication::_InitData()`, a pre-registration whose port is gone or no longer the team's is dropped
  (`BRoster::Private().RemoveApp(team)`) and the application registers itself as one started from a shell —
  its own port, signature, entry_ref and flags, and its own `B_ARGV_RECEIVED`/`B_READY_TO_RUN`. General: any
  wrapper or launcher started from Tracker or the Deskbar. The registry then names the real program (Deskbar's
  team list, SDL's "change to the executable's folder"), not the launcher.
  - Not changed: `_TranslateRef()`'s `isScript` for a link to a script (with the fix the script's program
    registers itself correctly either way; an upstream report could name both).
  - A launched team that execs before the roster has sent its messages loses nothing it needs: the program
    gets its arguments as argv; a `B_REFS_RECEIVED` sent to a wrapper was lost before, too.
- **B — the two packages** (realpath of the program path on Haiku): blender **-11**
  (`patches/blender/0018-appdir-haiku-program-path-through-link.patch`), supertuxkart **1.5-4**
  (`patches/supertuxkart/0003-haiku-data-next-to-executable-through-link.patch`; both the legacy and the GLES
  executable; data packages unchanged at -2).
- Test packages: `artifacts/packages-test/ta1/` (haiku, haiku_datatranslators, haiku_loader hrev60450+374;
  blender-3.6.23-11; supertuxkart-1.5-4). Not published, not merged.

## Verification (session ta1 on a test image, 2026-11-22 21:53–23:04 CET)

Test image `artifacts/images/haiku-pi4-mega-ta1.img` = mega36 with haiku/haiku_datatranslators/haiku_loader
hrev60450+374 (the branch), blender -11 and supertuxkart -4 swapped in (`scripts/image-add.sh`); network session,
the card untouched; the image's first-boot setup run as `mega-smoke` does. `tools/pi-tests/ta1-sweep.sh` opens
every Test Apps entry and the Deskbar entries the mega image adds (plus Firefox as a control) through Tracker.
Before: mega36 (session ta1, 20:29–21:52 CET; 60 s per entry). After: the test image (90 s, then 10–20 s more:
the team still running with a window shown; then a quit). Raw lines: `artifacts/ta1/{before,after,shots}/`.

| Entry | Before (mega36) | After (test image; "kept": still running with a window 10–20 s later) | Quit (after): B_QUIT_REQUESTED to the application ("app") or to its shown windows ("window close") |
|---|---|---|---|
| Test Apps/7-Zip (console, x86) | **no window** in 60 s (Terminal hangs) | window 0.2 s, kept | app: still running 60 s; window close: still running 60 s (Terminal asks: its `read` waits) |
| Test Apps/Age of Empires II (demo) | window 2.9 s | window 3.2 s, kept | app: gone 0.1 s |
| Test Apps/Blender 3.6 | **no window** in 60 s (hang) | window 3.1 s, kept | app: no app messenger; window close: gone 0.6 s |
| Test Apps/Diablo II (demo) | window 4.7 s | window 4.7 s, kept | app: gone 0.5 s |
| Test Apps/Fallout (demo) | window 3.3 s | window 3.3 s, kept | app: still running 60 s; window close: still running 60 s (its registration dialog) |
| Test Apps/Firefox | window 8.7 s | window 6.6 s, kept | app: gone 2.4 s |
| Test Apps/GLTeapot | window 0.1 s | window 0.1 s, kept | app: gone 0.1 s |
| Test Apps/Half-Life Uplink (demo, full screen) | window 4.9 s | window 4.8 s, kept | app: still running 60 s; window close: still running 60 s |
| Test Apps/Half-Life Uplink (demo, window) | window 4.2 s | window 4.1 s, kept | app: still running 60 s; window close: still running 60 s |
| Test Apps/Heroes of Might and Magic III (demo) | window 8.9 s | window 8.9 s, kept | app: gone 0.3 s |
| Test Apps/MediaPlayer | window 0.1 s | window 0.1 s, kept | app: gone 0.0 s |
| Test Apps/Minesweeper (Wine) | window 2.3 s | window 2.3 s, kept | app: gone 0.0 s |
| Test Apps/Notepad (Wine) | window 2.3 s | window 2.3 s, kept | app: gone 0.0 s |
| Test Apps/Notepad++ (x86) | window 6.2 s | window 6.2 s, kept | app: gone 0.3 s |
| Test Apps/Notepad++ (x86-64) | window 7.1 s | window 5.7 s, kept | app: gone 0.3 s |
| Test Apps/OpenArena | **no window** in 60 s (hang) | window 0.4 s, kept | app: gone 0.1 s |
| Test Apps/PhotoCraft | window 0.5 s | window 0.4 s, kept | app: no app messenger; window close: gone 0.2 s |
| Test Apps/PuTTY (x86) | window 3.6 s | window 3.2 s, kept | app: gone 0.1 s |
| Test Apps/PuTTY (x86-64) | window 2.8 s | window 2.7 s, kept | app: gone 0.1 s |
| Test Apps/Quake (QuakeSpasm, OpenGL) | **no window** in 60 s (hang) | window 0.1 s, kept | app: gone 0.1 s |
| Test Apps/Quake (vkQuake, Vulkan) | **no window** in 60 s (hang) | window 0.2 s, kept | app: gone 0.1 s |
| Test Apps/Quake II (demo) | **no window** in 60 s (hang) | window 0.2 s, kept | app: gone 0.2 s |
| Test Apps/Quake III Arena (demo) | **no window** in 60 s (hang) | window 0.2 s, kept | app: gone 0.1 s |
| Test Apps/SimCity 3000 (demo) | window 5.0 s | window 4.3 s, kept | app: still running 60 s; window close: still running 60 s |
| Test Apps/StarCraft (shareware) | window 2.9 s | window 2.8 s, kept | app: still running 60 s; window close: gone 2.0 s |
| Test Apps/SumatraPDF (x86) | window 3.2 s | window 3.1 s, kept | app: still running 60 s; window close: still running 60 s |
| Test Apps/SumatraPDF (x86-64) | window 2.9 s | window 2.9 s, kept | app: still running 60 s; window close: gone 0.1 s |
| Test Apps/SuperTuxKart | **no window** in 60 s (exit 1, no data (link)) | window 0.7 s, kept | app: gone 0.5 s |
| Test Apps/Unreal Tournament (demo, OpenGL) | window 3.0 s | window 2.9 s, kept | app: still running 60 s; window close: gone 0.1 s |
| Test Apps/Warcraft III (demo) | window 4.0 s | window 3.8 s, kept | app: gone 1.4 s |
| Test Apps/WebPositive | window 1.8 s | window 1.7 s, kept | app: gone 0.1 s |
| Test Apps/glmark2 (full screen) | **no window** in 60 s (Terminal hangs) | window 0.1 s, kept | app: still running 60 s; window close: still running 60 s (Terminal asks: glmark2 runs) |
| Test Apps/glmark2 (window) | **no window** in 60 s (Terminal hangs) | window 0.1 s, kept | app: still running 60 s; window close: still running 60 s (Terminal asks: glmark2 runs) |
| Test Apps/vkcube (Vulkan) | window 0.1 s | window 0.1 s, kept | app: ends by itself |
| Deskbar/Blender | window 0.9 s, **gone** within 10 s (abort, no data) | window 1.0 s, kept | app: no app messenger; window close: gone 0.6 s |
| Deskbar/OpenArena | **no window** in 60 s (hang) | window 0.3 s, kept | app: gone 0.1 s |
| Deskbar/PhotoCraft | window 0.2 s | window 0.2 s, kept | app: no app messenger; window close: gone 0.1 s |
| Deskbar/SuperTuxKart | **no window** in 60 s (exit 1, no data (link)) | window 0.3 s, kept | app: gone 0.5 s |
| Deskbar/Firefox | window 3.5 s | window 3.0 s, kept | app: gone 0.9 s |

- **The shell path is unchanged:** `tools/mega/smoke-pi.sh 15` (each entry by exec, as `mega-smoke` does) on the test
  image: 32 running, PhotoCraft and vkcube "exited 0" — as in R1–R3.
- **The registry names the program:** a Test Apps Quake opened through Tracker is listed by `roster` as
  `.../QuakeSpasm/quakespasm` with its own signature (before: the launcher's path and the dead port).
- Every program of the table renders (screenshots at T+20 s, `artifacts/ta1/shots/`): Blender's UI and splash,
  the Quake demos, OpenArena's menu, SuperTuxKart's first-start notice, glmark2.
- 0 PANIC, 0 debugger entries in both sessions (serial logs `artifacts/uart/20261122-211448-session-ta1.log`,
  `20261122-215326-session-ta1.log`).
- Tools: `tools/haiku-tests/trackeropen.cpp` (`-q`: B_QUIT_REQUESTED to the application; `-w`: to its shown
  windows, as their close buttons — the only way for Blender, which is `B_ARGV_ONLY`), `tools/pi-tests/ta1-sweep.sh`.

## Not checked

- Started by a real mouse double-click on the desktop (the checks send Tracker the same message a double-click and a
  Deskbar menu item make Tracker act on).
- Other wrappers outside the mega image (a HaikuPorts package whose Deskbar entry is a script that execs a
  BApplication program): covered by the same libbe path, not run.
- The x86-64 build of the libbe change; an upstream bug report (none drafted).
- The five Wine entries that did not end on an application quit nor on a window close (Fallout's registration
  dialog, Half-Life ×2, SimCity 3000, SumatraPDF x86): no before data (the mega36 sweep had no quit step) and no
  shell-launched control; the fix does not touch their path (they showed windows before it); not investigated.
- SuperTuxKart-GLES (rebuilt with the patch, in -4) was not run; `release-check.sh` was not run on the libbe change
  (it touches every application's start; only the 39 entries and the shell smoke ran).
- A roster send that comes after the program has re-registered (the launcher exec'd before the roster's
  `_SendToRunning()`) would reach the new port: a second `B_READY_TO_RUN` is ignored, a launcher started with
  arguments would give the program a second `B_ARGV_RECEIVED`. Not seen; not tested.
