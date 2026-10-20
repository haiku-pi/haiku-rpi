# H15: Windows programs on Haiku arm64 (Wine + x86 translation): plan

**Status: scheduled, not started.** The owner asked for this on 2026-10-20 (23:50 CEST), to begin once the queued and planned work
is done (the weekly log's Next list). This page holds the plan and the questions to settle at the start. The facts
marked *(check)* are from memory and must be verified against the then-current releases before anything is built
on them.

## Goal

Run Windows x86-64 (and 32-bit x86) programs on Haiku on the Raspberry Pi 4: ordinary applications and some
GPU-accelerated games. The Pi 4 is no gaming machine; the point is to show that it works, and to make it as complete
and as fast as the hardware allows. Use the newest **stable releases and tags** of every component (Wine, the
translator, the toolchains), never a rolling master branch. Test only with **legal, free-to-use Windows binaries**.

## Approach to evaluate first: Wine's own ARM64 path

Wine for arm64 can run x86 code without a separate emulator process: on Windows-on-ARM's model, x86-64 code runs
through **ARM64EC** and 32-bit x86 through **WoW64**, with the instruction translator loaded into Wine as a DLL
*(check: the Wine version where ARM64EC and the WoW64 translator interface became usable; Hangover, which packages
Wine with these translators for Linux arm64, shows the combinations that work)*. Two translators provide such DLLs:

- **FEX** (FEX-Emu): an x86/x86-64 → arm64 binary translator with an ARM64EC build and a WoW64 one *(check: the
  release that ships them)*.
- **Box64/Box32**: dynamic recompilers with a WoW64 DLL for 32-bit x86 *(check: ARM64EC status)*.

Why this suits Haiku better than the usual Linux setup (Box64 or FEX running a whole x86-64 *Linux* Wine): those
translators run Linux x86 programs and translate Linux system calls, which Haiku does not have. Inside Wine, the
translator only turns x86 code into arm64 code; the system underneath is Wine's arm64 build, which can be ported
to Haiku once. The likely choice: FEX for x86-64 (ARM64EC) and FEX or Box for 32-bit x86 (WoW64), whichever is
faster on the Cortex-A72 (benchmarks decide).

## The work

1. **Survey** (first step, a day at most): the state of Wine on Haiku *(check: the existing x86-64 port effort —
   HaikuPorts' Wine recipe and its Haiku patches, the window/graphics driver it uses)*; the latest stable Wine and
   its ARM64EC/WoW64 state; the FEX and Box releases; what Hangover patches. Record the decision here.
2. **Toolchain**: Wine's PE side for arm64/ARM64EC needs an LLVM-MinGW cross toolchain (clang); the Unix side is
   built with the Haiku arm64 cross compiler, like the other ports (`scripts/cross-port.sh`).
3. **Wine on Haiku arm64**, native arm64 Windows programs first: port the Haiku-specific parts of the x86-64 effort
   to arm64 (signals and exception contexts, thread and TLS setup, the loader, the window driver). Test with arm64
   Windows builds of free programs.
4. **x86-64 through ARM64EC + the translator DLL**, then **32-bit x86 through WoW64**.
5. **Graphics**: Wine's OpenGL on Mesa (V3D, GL 2.1 / GLES 3.1); Direct3D through WineD3D on that; DXVK on
   Vulkan (V3DV 1.3) only where V3DV has the features *(check)*. Audio through the media kit.
6. **Speed**: translator settings (the code cache, multi-core), large pages, the CPU clock; measured with the same
   discipline as the rest of the port (`docs/log/`).
7. **Packages and docs**: `wine` (+ the translator) as packages in our repository, a user guide section, and
   screenshots for the showcase.

## Test programs (to be chosen and license-checked at the start)

Only freely redistributable or freely downloadable software whose license allows this use, kept outside git (like
the Quake data): e.g. open-source Windows builds of 7-Zip, Notepad++, PuTTY, and games with free Windows builds and
data such as OpenTTD (+ OpenGFX), Freedoom on a Windows engine, SuperTuxKart's Windows release (to compare with our
native build), and freeware classics whose authors allow redistribution. The list, with each license, goes here
before any download.

## Risks

- Wine on Haiku is incomplete even on x86-64; the arm64 port may need much Haiku-side work (exception handling,
  memory layout, the window driver).
- ARM64EC/WoW64 maturity varies between Wine and translator releases; the newest stable pair may need patches.
- Performance on a Cortex-A72 at 1.5 GHz is modest: small 2D and older 3D games are the realistic target.
