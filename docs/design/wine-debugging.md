# Debugging Windows programs under Wine on the Pi

How to find out why a Windows program misbehaves under Wine + Box64 on Haiku arm64 — with evidence, in
minutes, instead of a reboot per guess. Written 2026-10-21, after the owner asked for proper
instrumentation; the first use of it found three port bugs in an hour (below).

## 1. Work on a running Pi (no reboot per test)

```
scripts/pi-session.sh start --image artifacts/images/haiku-pi4-wine1120.img --keep-disk   # ~70 s to ssh
scripts/pi-ssh.sh 'uname -a'                                  # a command (0.3 s)
scripts/pi-ssh.sh put LOCAL... /boot/home/                    # files to the Pi (scp)
scripts/pi-ssh.sh get /boot/home/hl.txt .                     # and back
scripts/pi-session.sh stop                                    # power off; the session also ends by itself (8 h)
```

The session's bootscript (`tools/pi-tests/session.sh`) installs OpenSSH with pkgman (a package only
copied into `system/packages` is activated without its `sshd` user, and sshd refuses to start) and starts
sshd with a key made for the bench (`artifacts/pi-session/`, never in git). Reboot only for the kernel or
the boot; for Wine, Box64 or a program, build on the host, `put` the changed files over the installed ones
(`/boot/system/non-packaged/lib/wine/...`) and run again. A screenshot of the Pi's screen:
`scripts/pi-ssh.sh 'screenshot -s /boot/home/s.png'` and `get` it.

A shell environment for Wine on the Pi (`/boot/home/wenv.sh`, sourced): `PATH`, `WINEPREFIX`,
`XKB_CONFIG_ROOT`, `WINEDEBUG=err+all,fixme-all`. Choose wined3d's renderer with
`WINE_D3D_CONFIG=renderer=gdi|gl` in the environment — a registry value can be lost when a wineserver is
killed (it once silently turned a DirectDraw test into an OpenGL one).

## 2. A crash names its instruction

Wine's debugger cannot attach to a process on Haiku (there is no ptrace; winedbg shows "Program Error …
unable to attach" and waits for a click — set `AeDebug\Debugger` to "" for unattended runs). Instead a
crashing process reports itself (Wine patch `0005-kernelbase-crash-report`), on stderr:

```
wine: Unhandled page fault on write access to 00000010 at address 00401509 (thread 0024), starting debugger...
crash: eip 00401509 esp 0026ff08 ebp 0026ff18 eflags 00000202 ...
crash: exception c0000005 at 00401509 (crash-x86.exe+0x1509), parameters 2: 1 10
crash: code at pc-16: ... [c7] 05 10 00 00 00 2a 00 00 00 ...          (mov dword [0x10], 42)
crash: frame  0 fp 0026FF18 return 4010db crash-x86.exe+0x10db
crash: stack sp+0x004 4014b5 crash-x86.exe+0x14b5
crash: module 00400000-00415000 D:\home\crash-x86.exe
```

Then on the host, `module+offset` → function and line with the module's DWARF: Wine's own DLLs are
linked with DWARF in the build tree (`artifacts/wine-<version>/cross/dlls/<dll>/i386-windows/<dll>.dll`,
before the install step strips them):

```
m=sources/wine/llvm-mingw-*/bin; f=artifacts/wine-11.20/cross/dlls/wined3d/i386-windows/wined3d.dll
base=$($m/llvm-objdump -p $f | awk '/ImageBase/ {print $2}')
printf '0x%x\n' $((0x$base + 0x9f6b1)) | $m/llvm-symbolizer --obj=$f
```

A program without symbols (a game): disassemble its module around the offset (`llvm-objdump -d
--start-address=...`) and read the code bytes the report printed. `tools/wine-tests/crash.c` (built with
DWARF as `crash-x86.exe`/`crash-arm64.exe`: `read`, `write`, `jump`, `readonly`) is the known fault to
check the instruments against — a report that does not name `inner` → `outer` → `main` is wrong.

## 3. The emulator's own instruments

Box64's environment variables work under WoW64 (`wowbox64.dll` prints those it took:
`BOX64ENV: Variables overridden`): `BOX64_LOG=1` (2: debug), `BOX64_SHOWSEGV=1`, `BOX64_DYNAREC_LOG=1`,
`BOX64_DYNAREC=0` (the interpreter: if a program works there and not with the dynarec, it is the
dynarec), the safe settings (`BOX64_DYNAREC_SAFEFLAGS=2 BOX64_DYNAREC_STRONGMEM=2
BOX64_DYNAREC_BIGBLOCK=0 BOX64_DYNAREC_CALLRET=0`) and `BOX64_DYNAREC_TEST=1` (each translated block
checked against the interpreter: names the first instruction they disagree on; very slow).

## 4. Wine's own traces

`WINEDEBUG=+seh` (exceptions), `+loaddll` (each module and its address), `+relay` (every call between
modules, with arguments — large), `+wgl,+opengl` (OpenGL), `+d3d,+ddraw` (DirectDraw/Direct3D), `+haiku`
(our audio driver). The host's reference Wine (`tools/wine-ref/run.sh`, x86-64, with `INPUT=` keys) runs
the same program for comparison: a fault there too is Wine's or the program's, not the port's.

## What it found first (2026-10-21)

1. **Every page fault on Haiku arm64 was a read** — Haiku's signal frame carries no ESR. Wine's write
   watches and copy-on-write pages, and Box64's protection of code it has translated, never saw a write:
   Half-Life's software renderer, which patches its own code, died at its first map. Fixed by deriving the
   access from the faulting A64 instruction (Wine `0004`).
2. **Box64 under WoW64 reported the host's view of a fault**: the host pc (truncated, outside every
   module) and the registers of the last syscall; and it took every write fault for one into translated
   code, retrying a write to an unmapped address forever. Fixed in Box64 `0003` (0.4.4: `0002`).
3. **wined3d's OpenGL renderer recurses forever on an 8-bit palette surface** on the V3D's GL 2.1 (the
   front-buffer update → blitter chain → CPU blitter → front-buffer update); the GDI renderer is right.
   Open (the GDI renderer is the default for DirectDraw games).

Half-Life: Uplink then played its first map, windowed
([screenshot](../screenshots/21-wine-halflife-uplink-ingame-3x.png)).
