# H15: Windows programs on Haiku arm64 (Wine + x86 translation): plan

**Status: started 2026-10-21** (the owner asked for it on 2026-10-20, 23:50 CEST, to begin once the backlog was
done). The survey is done and the decisions below are made; step 1 is next.

## Goal

Run Windows x86-64 (and 32-bit x86) programs on Haiku on the Raspberry Pi 4: ordinary applications and some
GPU-accelerated games. The Pi 4 is no gaming machine; the point is to show that it works, and to make it as complete
and as fast as the hardware allows. Use the newest **stable releases and tags** of every component (Wine, the
translator, the toolchains), never a rolling master branch. Test only with **legal, free-to-use Windows binaries**.

## Decisions (2026-10-21, from the survey)

The survey, [wine-x86-survey.md](wine-x86-survey.md), answers every open question of this plan's first draft
with sources. What it settles:

| Question | Answer | Consequence |
|---|---|---|
| Wine version | **Wine 11.0** (2026-01-13) is the newest stable release; 11.x after it are development releases | Build on **11.0**; move to 12.0 when it ships (January 2027) |
| Translator for x86-64 (ARM64EC) | **FEX** is the only one (`libarm64ecfex.dll`); Box64 has no ARM64EC DLL yet | **FEX-2601**, the release Hangover 11.0 paired with Wine 11.0 |
| Translator for 32-bit x86 (WoW64) | Box64's `wowbox64.dll` (Hangover's default, a Pi 4 build target) or FEX's `libwow64fex.dll` | **Box64 v0.4.0** first, FEX's as the alternative; benchmarks decide |
| Does FEX run on the Pi 4's Cortex-A72 (ARMv8.0)? | Yes: ARMv8.0 + FP + CRC32 minimum; LSE/LRCPC optional, detected at run time | Expect slow x86 memory-ordering emulation without LSE/LRCPC; per-program TSO settings will matter |
| PE-side toolchain | mstorsjo **llvm-mingw**, a pinned release | **20260826** (LLVM 23.1.0), which Hangover built Wine with |
| Wine on Haiku today | HaikuPorts: Wine 11.8, **x86_64 only**, 64-bit programs only, the Wayland driver over X512's in-process Wayland server; ~330 lines of Haiku code | The Haiku patches move to 11.0 and to arm64; Wine's arm64 signal code has Linux/macOS branches only — Haiku needs its own |
| Direct3D | **DXVK cannot run on V3D 4.2** (Vulkan 1.3, no depth clip/clamp, no BC textures, no transform feedback); WineD3D on OpenGL; no GLES backend in Wine | **Direct3D ≤ 9 through WineD3D on desktop GL**; DirectDraw and OpenGL games are the natural targets |
| Test games | Free demos, AppDB-rated: StarCraft demo (Platinum), Diablo II demo 1.04 (Gold), Half-Life: Uplink (retail Platinum); Unreal Tournament GOTY (free since 2024; 469f adds a 64-bit build) | Almost all 32-bit: **the WoW64 path is the critical path**, not an extra |

## The work

1. **Wine 11.0 on Haiku arm64, native arm64 Windows programs first** (no translator): the Unix side cross-built
   with the Haiku arm64 compiler (`scripts/cross-port.sh` style), the PE side with llvm-mingw; the HaikuPorts
   Haiku patches brought to 11.0 and arm64 (signals and exception contexts — Wine keeps per-thread data in x18:
   check that Haiku's compiler and libroot leave it alone — thread/TLS setup, the loader); a console program
   first, then a window through the Wayland driver (X512's server). *Exit:* an arm64 `hello.exe` and an arm64
   GUI program run on the Pi.
2. **32-bit x86 through WoW64 + Box64 v0.4.0** (`wowbox64.dll`), then FEX's `libwow64fex.dll` for comparison.
   *Exit:* the StarCraft demo plays.
3. **x86-64 through ARM64EC + FEX-2601**. *Exit:* a 64-bit x86 program (7-Zip x64, UT 469f's 64-bit build).
4. **Graphics:** WineD3D on Mesa's desktop GL (2.1 on the V3D): DirectDraw, Direct3D ≤ 9, OpenGL games. Audio
   through Wine's driver for Haiku's media kit, or through SDL/OpenAL.
5. **Speed:** translator settings (TSO modes per program, the code cache, multi-threading), the CPU clock;
   measured as the rest of the port.
6. **Packages, docs, a showcase:** `wine` and the translators as packages in our repository, a user-guide
   section, screenshots and a short video of the games.

### Status (2026-10-21)

- Step 1 done: arm64 console programs, and windows through the Wayland driver (WineMine on the Haiku desktop).
- Step 2: the WoW64 + Box64 path runs 32-bit x86 games on DirectDraw through wined3d's GDI renderer, which is
  exact at 8, 16 and 32 bpp (`tools/wine-tests/ddtest.c`). Heroes III's demo plays its intro video and shows its
  main menu and plays a game. SimCity 3000's demo shows its title, then a garbled city — exactly as the same Wine on
  x86-64 does with the GDI renderer (`tools/wine-ref/run.sh`); with Wine's OpenGL renderer it is right there, so the
  fault is wined3d's GDI renderer (blits from its 8-bit surfaces), not the port. Fallout's demo gets past its dialogs
  to a black screen; on x86-64 Wine it stops on a privileged instruction (0046bfd5), so it is not ours either (under
  Box64 the instruction is not trapped).
- Fixed on the way: libwayland-client's dispatch on Haiku (`patches/wayland`), FreeType for Wine, Box64's FS
  selector under WoW64 (`patches/box64/0002`), a mapping for user-write-only pages (kernel), drive D: = /boot for
  programs that check free space (Z:, Haiku's rootfs `/`, has none).
- Next: **audio** — Wine has no driver for Haiku (HaikuPorts' Wine uses OSS, whose drivers do not cover the Pi):
  a `winehaiku` mmdevapi driver on the Media Kit, modelled on `wineoss` (`patches/wine/0002`, to test). Then
  OpenGL (WineD3D on the V3D: SimCity 3000, Half-Life, UT), or the GDI renderer's 8-bit blits fixed; x86-64
  (FEX-2601 ARM64EC); packages.

## Test programs (to be chosen and license-checked at the start)

The owner's guidance (2026-10-21 00:13): test with older, very popular Windows games that are known to run under
Wine, from their **publicly available demo versions** or archives such as the Internet Archive's
[classicpcgames](https://archive.org/details/classicpcgames) collection. Nothing is hosted or redistributed
by this project: the binaries stay outside git and outside our packages, downloaded on the bench only to test,
and the result is shown as **screenshots or a short video**. Pick something that catches the eye.

Candidates, to be checked against Wine's application database (WineHQ AppDB ratings) and our GPU at the
start; nearly all are **32-bit x86**, so the WoW64 path (step 4) carries most of them:

| Game (demo) | Why | Graphics path on the V3D |
|---|---|---|
| Half-Life (Uplink / the demo) | iconic, rated well under Wine for years | its OpenGL renderer: fits OpenGL 2.1 |
| Unreal Tournament (1999 demo) | fast 3D, a good speed showcase | OpenGL renderer, or Direct3D 7 via WineD3D |
| Heroes of Might and Magic III (demo) | 2D, very popular, light on the CPU | DirectDraw (2D) |
| StarCraft / Warcraft II–III, Diablo II (demos) | Blizzard classics, well known under Wine | DirectDraw (2D); Warcraft III: Direct3D 8 |
| SimCity 3000 / 4, Need for Speed (demos) | broad recognition | DirectDraw / Direct3D 7–9 via WineD3D |
| Portal (and similar Direct3D 9 games) | stretch goal | Direct3D 9 shaders via WineD3D on GL 2.1 / GLES 3.1: probably beyond the V3D |

Applications, for completeness: open-source Windows builds of 7-Zip, Notepad++ and PuTTY (freely
redistributable). Each pick's source and license terms are recorded here before anything is downloaded.

## Risks

- Wine on Haiku is incomplete even on x86-64; the arm64 port may need much Haiku-side work (exception handling,
  memory layout, the window driver).
- ARM64EC/WoW64 maturity varies between Wine and translator releases; the newest stable pair may need patches.
- Performance on a Cortex-A72 at 1.5 GHz is modest: small 2D and older 3D games are the realistic target.
