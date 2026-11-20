# Upstream bug reports (drafts)

**Status: draft, not submitted.** Nothing in this file has been sent to any upstream project: no ticket, issue,
merge request, Gerrit change or mailing-list post. Each entry is written as a draft of a real submission, in the
project's own format, for the owner to review and send.

**Purpose.** Bugs we found **and fixed in our fork** that upstream also has, plus a few upstream bugs we found but
did not fix (we kept our own code). General bugs come first, Haiku before the other projects; Raspberry Pi 4 /
BCM2711-specific items are in a short section near the end.

**How it was compiled (2026-11-20).** Starting from [HAIKU-RPI4-CHANGES.md](HAIKU-RPI4-CHANGES.md) (the ★ rows),
[KNOWN-ISSUES.md](KNOWN-ISSUES.md), the design notes in [design/](design/) and the weekly logs in [log/](log/), each
candidate was traced to its commit or patch file and read. Its upstream status was then decided **from the code**:
the buggy lines were looked up in current upstream sources (Haiku `upstream/master` at **hrev60450**, fetched
2026-11-20; Mesa `main`; Wine `master`; the other projects' current default branches), and a fix that upstream made
meanwhile moves the entry to [Already fixed upstream](#already-fixed-upstream-no-report-needed). Trackers were
searched only where an entry says so; "not searched" means just that, not "no ticket exists".

**What counts.** Only defects: crashes, hangs, data corruption, wrong output, security holes, performance bugs (a
wrong computation, an O(n²) walk) and build failures. New drivers, features and plain speed-ups in our fork are not
reports, even where they are useful upstream (see the "Also generally useful" paragraph of HAIKU-RPI4-CHANGES).
Code that only exists in our port (Haiku glue in Wine, Firefox, FFmpeg, Box64, FEX; our new Pi drivers) is not an
upstream bug. Fixes we took from RenkuOS are listed only when upstream still has the bug, credited to their
authors, and marked "not ours to attach".

**Scope tiers.** *All architectures* (generic code, x86_64 included: argued from the code in each entry);
*arm64* (any arm64 board); *non-snooping DMA* (platforms whose devices do not snoop CPU caches); *Pi 4* (BCM2711
hardware only).

**Two forms.** 80 entries are full reports in the project's format. 54 are in **short form** (what, severity,
our fix, upstream status, and why it is short): fixes found by others (RenkuOS), findings from code reading that
were never reproduced, bugs latent at upstream's default settings or exposed only by our fork's code, entries for
an archived repository, duplicates of existing upstream reports, and minor items. The summary table's "Form"
column says which.

**Tracker searches.** Haiku's Trac put a bot check in front of automated reads during most of this work (Mesa's
GitLab web pages too, though its API answered and the Mesa entries were searched), and winehq.org was unreachable
from our network, so many Haiku and all Wine entries say "not searched" or "blocked". Search for duplicates by hand
before sending anything.

**AI-assisted text.** These drafts were compiled by an AI agent from our commits, patches and logs. Several
projects restrict AI-generated contributions or reports (Mesa, SDL, FEX, Box64, Blender, OpenImageIO; see the
checklist at the end): rewrite in your own words where they ask for it, and disclose as they require.

**Start here: the ten most valuable general bugs.**

1. [HK-03](#hk-03) — Haiku VM: `mprotect()` moves every `MAP_SHARED` mapping of a file onto an anonymous cache
   when the file also has a private mapping: writes stop reaching the file (all architectures).
2. [HK-04](#hk-04) — Haiku page writer: a device's last modified pages (up to 1 MB) stay unwritten until a sync;
   a power cut loses them (regression since hrev59865).
3. [HK-01](#hk-01) — Haiku arm64: any user program can panic the kernel with an undefined instruction or
   `__builtin_trap()` (since hrev60333).
4. [HK-51](#hk-51) — BFS: `rm -rf` deadlocks against a concurrent `sync`.
5. [HK-52](#hk-52) — BFS: mounting a damaged volume panics the kernel instead of failing.
6. [HK-50](#hk-50) — Bluetooth L2CAP: a remote device can panic the kernel with an unexpected response.
7. [HK-53](#hk-53) — runtime_loader: after any `dlclose()` of a library with TLS, new threads lose their
   `thread_local` values.
8. [HK-07](#hk-07) — Haiku arm64: spin-waits livelock on cores without LSE atomics (Cortex-A53/A72): multi-second
   to minute-long freezes.
9. [MESA-01](#mesa-01) — V3DV: a render pass whose area starts inside a supertile overwrites pixels outside it
   (tiled uploads lose data; Pi 4 and Pi 5 on any OS).
10. [WINE-01](#wine-01) — wineserver: `cancel_process_async()` uses an async that the cancel may already have
    freed (use-after-free, wineserver spins at 100 %).

**How to read an entry.** The heading is `ID — component: title`. The bullet block at the top holds the tracker's
own fields (Trac, GitLab, Bugzilla, GitHub…) and our triage: severity, scope, our fix (repository + commit, or a
patch file in this repository), whether the patch can be attached as it is, and the upstream status with the date it
was checked. The prose follows the project's report template: environment, description, steps to reproduce,
expected / actual, root cause (with `file:line` in **upstream** terms, at the stated revision), the fix, and our
evidence. Haiku hashes are 10-character short hashes on the `rpi4` branch of
[haiku-pi/haiku](https://github.com/haiku-pi/haiku); Mesa hashes are on `rpi4` of
[haiku-pi/mesa](https://github.com/haiku-pi/mesa). Paths of test tools (`tools/...`) are in this repository.

**Haiku environment used in every Haiku entry.** Our branch's merge base with upstream is **hrev60431**
(`ae995ad339`, 2026-11-17); the hardware is a Raspberry Pi 4 Model B, 4 GB (4× Cortex-A72, no LSE atomics, no
hardware access/dirty flags), booted by the Pi firmware → U-Boot (EFI) → `haiku_loader.efi`. Several entries were
also checked on x86_64 under KVM ([design/x86-64-check.md](design/x86-64-check.md)).

## Summary

134 entries: 80 full reports and 54 in short form (see "Form"). Severity uses six classes (crash, hang, data corruption, wrong output, performance, build); "(security)" marks entries an unprivileged program or a remote peer can trigger. Scope: *general* = all architectures or any OS; *arm64* = any arm64 board; *non-snooping* = DMA without cache snooping; *weak-memory* = weakly ordered CPUs; *Haiku-platform* = code that only runs on Haiku but ships upstream. Upstream status was checked on 2026-11-20; "open" means the faulty code is unchanged in current upstream sources.

| ID | Project | Component | Title | Severity | Scope | Our fix | Upstream | Patch | Form |
|---|---|---|---|---|---|---|---|---|---|
| [HK-03](#hk-03) | Haiku | System/Kernel | vm: mprotect() of a file mapping detaches all MAP_SHARED mappings when a private mapping exists | data corruption | general | haiku 894c4abe7f | open | notes | full |
| [HK-04](#hk-04) | Haiku | System/Kernel | vm: page writer leaves a device's last modified pages unwritten until a sync | data corruption | general | haiku 1539d29eee | open | notes | full |
| [HK-51](#hk-51) | Haiku | File Systems/BFS | `rm -rf` of fresh files deadlocks against `sync` | hang | general | haiku 44cc183c0c | open | yes | full |
| [HK-52](#hk-52) | Haiku | File Systems/BFS | Failed mount of a damaged volume panics in block_cache | crash | general | haiku 9799738757 | open | yes | full |
| [HK-50](#hk-50) | Haiku | Network & Internet/Bluetooth | L2CAP connection/disconnection response with unknown ident panics the kernel (remote) | crash (security) | general | haiku b0ea06deaf | open | yes | full |
| [HK-53](#hk-53) | Haiku | System/runtime_loader | New thread's TLS generation 0 discards its thread_local values after dlclose() | data corruption | general | haiku 5db923abc6 | open | yes | full |
| [HK-55](#hk-55) | Haiku | Kits/Application Kit | BMessage cache freed at exit under a running looper | crash | general | haiku a779571e90 | open | yes | full |
| [HK-11](#hk-11) | Haiku | System/Kernel | thread: dying team deletes an exited thread's stack while others run | crash | general | haiku e09cfa1d9e | open | notes | full |
| [HK-10](#hk-10) | Haiku | System/Kernel | debug: profiler leaves a timer armed on a CPU | hang | general | haiku 5180e96119 | open | yes | full |
| [HK-57](#hk-57) | Haiku | Drivers/Disk/MMC | SDHCI read-modify-write acks on W1C status lose transfer complete; RecoverError, timeout field, double scan, divider | hang | general | haiku 23f6235b0d | open | notes | full |
| [HK-15](#hk-15) | Haiku | System/Kernel | IORequest iteration recursion overflows the kernel stack with synchronous drivers | crash | general | haiku 90fa3bc401 | open | yes | full |
| [HK-54](#hk-54) | Haiku | System/Kernel | Caller-provided stack placed a guard size (16 KiB) past the buffer | data corruption | general | haiku dbae37b2cb | open | yes | full |
| [HK-61](#hk-61) | Haiku | System/runtime_loader | fork() does not lock the runtime_loader heap | crash / hang | general | haiku 634dd24886 | open | notes | full |
| [HK-60](#hk-60) | Haiku | System/Kernel | poll() modifies the caller's `events`; event loops spin | performance | general | haiku 127fb34239 | open | yes | full |
| [HK-12](#hk-12) | Haiku | System/Kernel | vfs: no wait for a late boot device ("did not find any boot partitions") | crash | general | haiku bce76d6e73 | open | yes | full |
| [HK-19](#hk-19) | Haiku | System/Kernel | vm: clone of a B_CONTIGUOUS area not mapped, lock_memory assumes it is | crash | general | haiku 797972f727 | open | yes | full |
| [HK-16](#hk-16) | Haiku | System/Kernel | image notifications lose their pointer on 64-bit (profile -a "unknown") | wrong output | general | haiku f6c52282df | open | yes | full |
| [HK-27](#hk-27) | Haiku | System/Kernel | block_cache: sub-transaction start walks the whole transaction (O(n²)) | performance | general | haiku a9db442988 | open | yes | full |
| [HK-68](#hk-68) | Haiku | Servers/launch_daemon | Shutdown check always fails; services restarted during shutdown | performance | general | haiku f49813a540 | open | notes | full |
| [HK-65](#hk-65) | Haiku | System/libroot | strtold() is strtod() | wrong output | general | haiku 12eb998a63 | open | yes | full |
| [HK-66](#hk-66) | Haiku | System/libroot | strtod family: lost signs, NaN end, EDOM on underflow, no ERANGE on rounding overflow | wrong output | general | haiku 73ba44df00 | open | yes | full |
| [HK-67](#hk-67) | Haiku | System/runtime_loader | Dynamic TLS blocks ignore the segment alignment | wrong output | general | haiku 4d433669a8 | open | notes | full |
| [HK-69](#hk-69) | Haiku | System/Kernel | setrlimit() EINVAL for the current value of a fixed limit | wrong output | general | haiku f0a1d5f5cf | open | yes | full |
| [HK-70](#hk-70) | Haiku | Kits/Media Kit | BTimeSource float conversion calls debugger() after 16.7 s | crash | general | haiku c41702df18 | open | yes | full |
| [HK-78](#hk-78) | Haiku | Drivers/USB/XHCI | Physical transfers >384 KiB built over all vectors | wrong output | general | haiku e1d69f100f | open | yes | full |
| [HK-62](#hk-62) | Haiku | System/Boot Loader/EFI | Any load option key not 2 characters long hangs the loader | hang | general | haiku d8dfb51d8d | open | notes | full |
| [HK-74](#hk-74) | Haiku | System/Kernel | Net boot: no link wait; module unload deadlock | hang | general | haiku cea07d5468 | open | yes | full |
| [HK-75](#hk-75) | Haiku | Drivers/Disk | remote_disk cannot open partitions | crash | general | haiku a082ab4d4e | open | yes | full |
| [HK-76](#hk-76) | Haiku | Servers/net_server | DHCP started on the network-boot interface | hang | general | haiku cb0f2f9884 | open | notes | full |
| [HK-81](#hk-81) | Haiku | Network & Internet/Bluetooth | bluetooth_server NULL deref on unknown handle; PIN windows never closed | crash | general | haiku 3cad4e2996 | open | yes | full |
| [HK-71](#hk-71) | Haiku | Applications/Debugger | CLI `bt` waits for the stack trace with the team locked | hang | general | haiku 8a65ea1c6d | open | notes | full |
| [HK-72](#hk-72) | Haiku | Applications/Debugger | v5 line table headers off by one (files, directories), byte counts | wrong output | general | haiku 65cae45a13 | open | notes | full |
| [HK-64](#hk-64) | Haiku | Applications/Debugger | DWARF 5 units rejected though GCC writes DWARF 5 by default | wrong output | general | haiku d2d2349f2c | open | notes | full |
| [HK-86](#hk-86) | Haiku | Network & Internet/IPv6 | New icmp6_error_reply(): MTU/pptr byte order, plen, RFC 4443 e.3/e.6 | wrong output | general | none (our 25c9881600) | open | no | full |
| [HK-33](#hk-33) | Haiku | Build System | build fails with GCC 16; FileTypes _Frame() on unconstructed object | build | general | haiku 3c641a2b01 | open | notes | full |
| [HK-63](#hk-63) | Haiku | Drivers/PCI | I/O BARs get host address 0 outside x86 | data corruption | arm64 | haiku cafef4f9bb | open | yes | full |
| [HK-77](#hk-77) | Haiku | System/Kernel | FDT "reg" not translated through "ranges" | wrong output | arm64 | haiku 1c9c78289e | open | yes | full |
| [HK-80](#hk-80) | Haiku | Drivers/USB/XHCI | No cache maintenance for physical transfers | data corruption | non-snooping | haiku eabad7a921 | open | no | full |
| [HK-01](#hk-01) | Haiku | System/Kernel | arm64: undefined instruction / BRK / SP-alignment fault in a user program panics the kernel | crash (security) | arm64 | haiku cdd63d4b62 | open | notes | full |
| [HK-02](#hk-02) | Haiku | System/Kernel | arm64: sigreturn restores the whole SPSR from the user's signal frame | crash (security) | arm64 | haiku 4cd6f504f8 | open | yes | full |
| [HK-06](#hk-06) | Haiku | System/Kernel | arm64: empty TTBR0 table not cleared: freezes after cold boot | hang | arm64 | haiku d1a616afac | open | yes | full |
| [HK-07](#hk-07) | Haiku | System/Kernel | arm64: spin-waits livelock on cores without LSE atomics | hang | arm64 | haiku 0db3ca639d | open | notes | full |
| [HK-08](#hk-08) | Haiku | System/Kernel | arm64: failed fork() panics (map without a table freed/walked at PA 0) | crash | arm64 | haiku c8f3757b45 | open | notes | full |
| [HK-09](#hk-09) | Haiku | System/Kernel | arm64: mmap(PROT_WRITE) mapping faults forever | hang | arm64 | haiku 8a7946ae00 | open | yes | full |
| [HK-17](#hk-17) | Haiku | System/Kernel | arm64: arch_cpu_sync_icache() line size computed as 4 bytes | performance | arm64 | haiku 0fe465e233 | open | yes | full |
| [HK-18](#hk-18) | Haiku | System/Kernel | arm64: user time counted as kernel time | wrong output | arm64 | haiku 24b4e36dcf | open | yes | full |
| [HK-22](#hk-22) | Haiku | System/Boot Loader | efi/arm64: secondary CPU reads a stale stack line, enters as a second CPU 0 | crash | arm64 | haiku eb4bdd0ea4 | open | notes | full |
| [HK-23](#hk-23) | Haiku | System/Boot Loader | PL011 with clock-controller clock: garbled serial output | wrong output | arm64 | haiku a6502fab74 | open | yes | full |
| [HK-21](#hk-21) | Haiku | System/Kernel | arm64: serial KDL reads endless 0xff | wrong output | arm64 | haiku b3a08271be | open | yes | full |
| [HK-58](#hk-58) | Haiku | Network & Internet/IPv6 | IPv6: possible kernel crash in a send path (unconfirmed; details held for a private report) | crash (security) | general | none | open | no | short |
| [HK-05](#hk-05) | Haiku | System/Kernel | vm: a team can shrink an area another team maps (RenkuOS) | crash (security) | general | haiku 2dcb0bb814 | open | no | short |
| [HK-13](#hk-13) | Haiku | System/Kernel | vm: page writer may write a page that left its cache (RenkuOS) | crash | general | haiku 4d35669d1d | open | no | short |
| [HK-14](#hk-14) | Haiku | System/Kernel | scheduler: power-saving pack_irqs() spins forever on an IRQ that stays (RenkuOS) | hang | general | haiku 8ed6c7589b | open | no | short |
| [HK-24](#hk-24) | Haiku | System/libroot.so | atomic_test_and_set() uses a weak CAS (RenkuOS) | data corruption | general | haiku 88be53559b | open | no | short |
| [HK-20](#hk-20) | Haiku | System/libroot.so | arm64: B_SWAP_FLOAT/B_SWAP_DOUBLE return a wrong value (RenkuOS) | wrong output | arm64 | haiku 55671c28c9 | open | no | short |
| [HK-32](#hk-32) | Haiku | System/Kernel | module: pre-loaded file-system modules keep a bare name (RenkuOS) | wrong output | general | haiku 93a0d0e23e | open | no | short |
| [HK-56](#hk-56) | Haiku | Network & Internet | Notifications module get_module() from its own syscall deadlocks boot | hang | general | haiku e24ddebb42 | open | no (RenkuOS #476) | short |
| [HK-59](#hk-59) | Haiku | Network & Internet/TCP | ~TCPEndpoint() waits for timers holding the lock the hooks need | hang | general | haiku 0c2354bf59 | open | no (RenkuOS bdecbeb5b5) | short |
| [HK-73](#hk-73) | Haiku | Drivers/Network/wlan | openbsd_wlan never sends scan done; no auto-join | wrong output | general | haiku fbd46ca58b | open | no (RenkuOS #471) | short |
| [HK-79](#hk-79) | Haiku | Drivers/Disk/USB | uninit deletes I/O schedulers under the device lock (weak evidence) | hang | general | haiku d3cc8e3fd1 | open | yes | short |
| [HK-25](#hk-25) | Haiku | System/Kernel | GICv2: ICI message not ordered against the SGI; SGI targets assume 1 << cpu | hang | arm64 | haiku 4eb785f652 | open | notes | short |
| [HK-26](#hk-26) | Haiku | System/Kernel | arm64: new thread enters userland with a signal pending | hang | arm64 | haiku 5d9132a49c | open | notes | short |
| [HK-28](#hk-28) | Haiku | System/Kernel | side effects inside ASSERT() (signal frame, fdt bus manager) | crash | arm64 | haiku 55348c5c46 | open | notes | short |
| [HK-29](#hk-29) | Haiku | System/Kernel | arm64: fresh kernel stack page can fault inside the exception vector | crash | arm64 | haiku dc849a150b | open | yes | short |
| [HK-30](#hk-30) | Haiku | System/Kernel | debug: continuing from a sw breakpoint leaves its hw replacement unloaded | wrong output | general | haiku 40adafebe9 | open | yes | short |
| [HK-31](#hk-31) | Haiku | System/Kernel | debug: no icache sync after writing team memory | wrong output | general | haiku 09b7e81388 | open | yes | short |
| [HK-82](#hk-82) | Haiku | System/Kernel | TLS slots 8-63 not cleared for a new thread | wrong output | general | haiku a000d5d6cc | open | yes | short |
| [HK-83](#hk-83) | Haiku | Network & Internet/Bluetooth | libbluetooth prints CALLED() traces in release builds | wrong output | general | haiku d226612219 | open | yes | short |
| [HK-84](#hk-84) | Haiku | Network & Internet/Bluetooth | bt_discovery does not build/never ends; bt tools print garbage | build | general | haiku 02e02d4ba3 | open | notes | short |
| [HK-85](#hk-85) | Haiku | Network & Internet | Own host name does not resolve | wrong output | general | haiku 58022c954a | open | yes | short |
| [MESA-01](#mesa-01) | Mesa | v3dv | Supertiles partly before the render area's offset are stored whole (tiled uploads lose data) | data corruption | general | mesa be833ed6d67 | open | notes (rebase: conflicts) | full |
| [MESA-02](#mesa-02) | Mesa | v3d | TFU mipmap generation mistiles levels ≥ 1 of NPOT textures | wrong output | general | mesa a4516893497 | open | notes (move check below devinfo + goto fallback; reword; Haiku check pending) | full |
| [MESA-03](#mesa-03) | Mesa | mesa core | MESA_map_buffer_client_pointer usage enums don't match the decoding arithmetic | wrong output | general | none | open | no | full |
| [MESA-04](#mesa-04) | Mesa | broadcom/compiler | Liveness and copy propagation scale as blocks × temps (3.6× on 26.2) | performance | general | mesa f55f89ccad9, baaaeaef308, 76543fafdfc | open (partly by af333031d54) | notes (2 clean, 1 conflicts; remeasure) | full |
| [MESA-05](#mesa-05) | Mesa | egl/haiku | eglTerminate with a current context frees the display, then release uses it | crash | Haiku-platform | mesa db2eac33c13 | open | notes (DriverDisplay also dangling) | full |
| [MESA-06](#mesa-06) | Mesa | hgl | hgl_get_st_visual leaves the visual uninitialised (random MSAA) | wrong output | Haiku-platform | mesa 1724b112520 | open | notes (one line; not built) | full |
| [MESA-07](#mesa-07) | Mesa | v3d | Variant cache runs BLAKE3 per lookup | performance | general | mesa ebf1ee1ff1b | open | notes (not built) | full |
| [MESA-08](#mesa-08) | Mesa | v3dv | timestampPeriod from clock_getres while the kernel writes ns | wrong output | general (latent) | mesa 640e69292c3 (Haiku-only hunk) | open | no | short |
| [WINE-01](#wine-01) | Wine | wineserver | cancel_process_async() use-after-free when the cancel completes inline | crash / hang | general | patches/wine-11.21/0026 | open | yes | full |
| [WINE-02](#wine-02) | Wine | wineserver | shared session objects misaligned, STLR alignment fault on arm64 | crash | general | patches/wine-11.21/0029 | open | yes | full |
| [WINE-03](#wine-03) | Wine | directx-d3d | CS queue indices read without acquire | data corruption / crash | weak-memory | patches/wine-11.21/0018 | open | notes | full |
| [WINE-04](#wine-04) | Wine | opengl | WoW64 copies whole flush-explicit buffer mappings | performance | general | patches/wine-11.21/0028 | open | yes | full |
| [WINE-05](#wine-05) | Wine | comdlg32 | item dialog does not select the proposed file name | wrong output | general | patches/wine-11.21/0022 | open | yes | full |
| [WINE-06](#wine-06) | Wine | directx-d3d | GLSL blitter declines P8 to drawable on GL 2.1, endless recursion | crash | general | patches/wine-11.21/0017 | open | yes | full |
| [WINE-07](#wine-07) | Wine | wineserver | free_async_queue() double release at server exit | crash | general | patches/wine-11.21/0014 | open | yes | full |
| [WINE-08](#wine-08) | Wine | winsock | get_local_ips() puts loopback first | wrong output | general | patches/wine-11.21/0033 | open | yes | full |
| [WINE-09](#wine-09) | Wine | directx-d3d | sysmem evicted under a live DC | data corruption / crash | general | patches/wine-11.21/0013 | open | yes | full |
| [WINE-10](#wine-10) | Wine | directx-d3d | GDI full-screen front buffer lost when its window is hidden | wrong output | general | patches/wine-11.21/0012 | open | notes | short |
| [WINE-11](#wine-11) | Wine | directx-ddraw | screen-DC front buffer invisible on winewayland | wrong output | general | patches/wine-11.21/0016 | open | notes | short |
| [WINE-12](#wine-12) | Wine | directx-ddraw | SetDisplayMode leaves a stale present rect | performance | general | patches/wine-11.21/0010 | open | notes | short |
| [WINE-13](#wine-13) | Wine | winewayland | emulated-mode full screen stretched and cut | wrong output | general | patches/wine-11.21/0008 | open | notes | short |
| [WINE-14](#wine-14) | Wine | opengl | framebuffer surfaces use glFramebufferTexture (GL 3.2) | wrong output | general | patches/wine-11.21/0003 | open | notes | short |
| [WINE-15](#wine-15) | Wine | win32u | scaled surface stretches with HALFTONE every frame | performance | general | patches/wine-11.21/0015 | open | notes | short |
| [WINE-16](#wine-16) | Wine | setupapi | prefix update rewrites identical DLLs | performance | general | patches/wine-11.21/0021 | open | notes | short |
| [FFMPEG-01](#ffmpeg-01) | FFmpeg | avcodec/mmaldec | Drain never sends EOS; last frames lost | wrong output | general | `patches/ffmpeg6/0002-mmal-haiku.patch` | open | notes | full |
| [FFMPEG-02](#ffmpeg-02) | FFmpeg | avcodec/mmaldec | MMAL_EVENT_ERROR only logged; blank frames / loop | wrong output | general | `patches/ffmpeg6/0002-mmal-haiku.patch` | open | notes | full |
| [FFMPEG-03](#ffmpeg-03) | FFmpeg | avcodec/mmaldec | framerate overwritten with 24000/1001 echo | wrong output | general | `patches/ffmpeg6-next/0007-mmal-frame-rate.patch` | open | notes | short |
| [BLENDER-01](#blender-01) | Blender | GHOST_SDL | Contexts made with none current don't share objects | wrong output | general | `patches/blender/0013-ghost-sdl-share-with-first-context.patch` | open | notes | full |
| [BLENDER-02](#blender-02) | Blender | Movie output | CRF ignored by encoders without `crf` (#61708) | wrong output | general | `patches/blender/0010-ffmpeg-bitrate-from-crf-for-encoders-without-crf.patch` | open | notes | short |
| [BLENDER-03](#blender-03) | Blender | GPU/OpenGL | Unknown GL vendor matches every vendor's workarounds | wrong output | general | `patches/blender/0004-gpu-classify-v3d.patch` | open | no | short |
| [OIDN-01](#oidn-01) | OpenImageDenoise | core | No ThreadAffinity outside Win/Linux/macOS | build | general (non-Linux) | `tools/recipes/media-libs/oidn/patches/oidn-2.5.1.patchset` | open | yes | full |
| [BOX64-01](#box64-01) | Box64 | wowbox64 | FS reload with the TEB selector gives base 0 | crash | general | patches/box64/0001 | open | yes | full |
| [BOX64-02](#box64-02) | Box64 | wowbox64 | every write fault retried forever | hang | general | patches/box64/0002 | open | notes | short |
| [BOX64-03](#box64-03) | Box64 | wowbox64 | no cooperative suspend doorbell, stale GetThreadContext | wrong output | general | patches/box64/0003 | open | notes | short |
| [FEX-01](#fex-01) | FEX | Windows OvercommitTracker | failed commit reported as handled, endless fault loop | hang | general | patches/fex/0001 | open | notes | short |
| [HAIKUPORTS-01](#haikuports-01) | HaikuPorts | dev-libs/wayland-server | Pinned rev fails with wayland_protocols 1.49 | build | Haiku | `patches/wayland_server/wayland_server-0.1.20251004-text-input-v2.patch` | open | notes | full |
| [HAIKUPORTS-02](#haikuports-02) | HaikuPorts | dev-libs/wayland | Pinned libwayland-client spins in wl_display_dispatch_queue | performance | Haiku | `patches/wayland/wayland-1.21.0~git-dispatch-blocks.patch` | open | notes | short |
| [HAIKUPORTS-03](#haikuports-03) | HaikuPorts | dev-util/gperf | gperf 3.1 fails with GCC ≥ 15 (C23) | build | Haiku | recipe change (`-std=gnu17`), `docs/design/native-gcc.md` | open | notes | short |
| [HAIKUPORTS-04](#haikuports-04) | HaikuPorts | dev-libs/gmp | gmp 6.3.0 configure fails with GCC ≥ 15 (C23) | build | Haiku | `scripts/build-blender.sh` (gmp step) | open | notes | short |
| [HAIKUPORTS-05](#haikuports-05) | HaikuPorts | media-gfx/blender | rdef B_SINGLE_LAUNCH: second instance quits | wrong output | Haiku | `tools/recipes/media-gfx/blender/additional-files/blender.rdef.in` | open | yes | short |
| [SDL-01](#sdl-01) | SDL | video/haiku events | Window-event handlers on looper thread race app thread (double free in SDL_AddDisplayMode) | crash | Haiku | `patches/libsdl2/libsdl2-2.32.10-haiku-event-thread.patch` | open | notes | full |
| [SDL-02](#sdl-02) | SDL | video/haiku GL | Process-wide current GL context; MakeCurrent on a 2nd thread unlocks another thread's BGLView | crash | Haiku | `patches/libsdl2/libsdl2-2.32.10-haiku-gl-thread-context.patch` | open | notes | full |
| [SDL-03](#sdl-03) | SDL | video/haiku modes | Mode data points into freed GetModeList() array (SDL3: stack) | crash | Haiku | `patches/libsdl2/libsdl2-2.32.10-haiku-modes.patch` | open | yes | full |
| [SDL-04](#sdl-04) | SDL | video/haiku GL | SDL_GL_SetSwapInterval refused; never vsync | performance | Haiku | `patches/libsdl2/libsdl2-2.32.10-haiku-swap-interval.patch` | open | notes | short |
| [WAYLAND-01](#wayland-01) | wayland_server (X547) | HaikuXdgToplevel | NULL fToplevel deref in WindowActivated/FrameResized | crash | Haiku | `patches/wayland_server/wayland_server-0.1.20251004-window-without-toplevel.patch` | open | yes | full |
| [WAYLAND-02](#wayland-02) | wayland_server (X547) | exit handling | Loopers run during exit() static destructors (crash/hang) | crash | Haiku | `patches/wayland_server/…-wl-window-hold-at-exit.patch`, `…-wl-window-stop-at-exit.patch` | open | no | full |
| [WAYLAND-03](#wayland-03) | wayland_server (X547) | xdg fullscreen | Smaller fullscreen surface not centered | wrong output | Haiku | `patches/wayland_server/wayland_server-0.1.20251004-fullscreen-center.patch` | open | notes | short |
| [WAYLAND-04](#wayland-04) | wayland_server (X547) | meson | build_machine arch + absolute private headers break cross builds | build | Haiku | `patches/wayland_server/wayland_server-0.1.20251004-cross.patch` | open | yes | short |
| [LIBGLVND-01](#libglvnd-01) | libglvnd | HGL | Build fails on current Haiku: PTHREAD_RECURSIVE_MUTEX_INITIALIZER now _NP | build | Haiku | haiku-pi/libglvnd 33d3b66 | open | yes | full |
| [LIBGLVND-02](#libglvnd-02) | libglvnd | HGL | Exit with live BGLViews stops in debugger (BReferenceable) | crash | Haiku | haiku-pi/libglvnd ed01b68 | open | yes | full |
| [LIBGLVND-03](#libglvnd-03) | libglvnd | HGL | BGLView::SwapBuffers(bool vSync) ignores vSync | performance | Haiku | haiku-pi/libglvnd be20124 (vSync part) | open | no | short |
| [UBOOT-01](#uboot-01) | U-Boot | efi_loader | Copy SizeOfHeaders bytes of PE headers | wrong output | general | `patches/u-boot/0004-efi_loader-copy-SizeOfHeaders-bytes-of-PE-headers.patch` | open | notes | full |
| [USERLAND-01](#userland-01) | raspberrypi/userland | mmal_vc_client | Port disable frees pool with buffers outstanding | crash | general (Pi) | `tools/recipes/media-libs/raspberrypi_userland/patches/raspberrypi_userland-20241223.patchset` (10) | open (archived) | no | short |
| [USERLAND-02](#userland-02) | raspberrypi/userland | mmal_vc_client | sendwait waits forever (#687, #639) | hang | general (Pi) | same patchset (8) | open (archived) | notes | short |
| [USERLAND-03](#userland-03) | raspberrypi/userland | vcos | Thread key destructor survives library unload | crash | general | same patchset (9) | open (archived) | yes | short |
| [USERLAND-04](#userland-04) | raspberrypi/userland | mmal_vc_shm | Unlock without lock in mmal_vc_shm_exit | data corruption | general | same patchset (7) | open (archived) | yes | short |
| [USERLAND-05](#userland-05) | raspberrypi/userland | vchiq_arm | Shadowed vchiq_lib_mutex never created | crash | general | same patchset (2) | open (archived) | yes | short |
| [USERLAND-06](#userland-06) | raspberrypi/userland | vchiq_arm | vchiq_dump_phys_mem casts handle to pointer | crash | general | same patchset (4) | open (archived) | yes | short |
| [BUILDTOOLS-01](#buildtools-01) | Haiku buildtools | gcc/config/haiku.h | Cross gcc links only static libgcc: every C++ throw → terminate() | crash | Haiku | buildtools 85273c9ba6 + 393b4ec7a4 (haiku-pi fork) | open | notes | full |
| [BUILDTOOLS-02](#buildtools-02) | Haiku (build system) | build_cross_tools_gcc4 | Stale libstdc++.la after libstdc++.a rename | build | Haiku | workaround in `scripts/build-blender.sh` | open | no | short |
| [GCC-01](#gcc-01) | GCC | libstdc++ `<bitset>` | Freestanding `<bitset>` fails: `__throw_logic_error` undeclared (PR 128880) | build | general | buildtools c2213226f9 (haiku-pi fork) | open | notes | short |
| [CMAKE-01](#cmake-01) | CMake | Utilities/cmlibuv | Bundled libuv CMakeLists has no Haiku branch (link fails) | build | Haiku | `patches/cmake-4.4.5/0001-cmlibuv-build-the-Haiku-platform-sources.patch` | open | yes | short |
| [IOQ3-01](#ioq3-01) | ioquake3 | sys_main.c | Shutdown inside SIGTERM/SIGINT handler can hang | hang | general | `patches/ioq3/0002-quit-signal-from-main-loop.patch` | open | notes | short |
| [VKQUAKE-01](#vkquake-01) | vkQuake | common.c | Shareware: + commands ignored (cmdline cvar not set) | wrong output | general | `patches/vkquake/0002-shareware-command-line.patch` | open | notes | short |

No entries for Firefox, OpenUSD, OpenImageIO, Vulkan-Loader, libdrm or CPython: every patch we carry there is Haiku port glue or already fixed upstream (see [Checked and not reported](#checked-and-not-reported) and [Already fixed upstream](#already-fixed-upstream-no-report-needed)).

## 1. Haiku

Checked against upstream `master` at **hrev60450** (2026-11-20); our merge base is hrev60431. Every
`file:line` is from hrev60450. Trac (dev.haiku-os.org) put a bot check in front of its search during this work:
some kernel entries were searched with plain HTTP requests before it did, the rest say "not searched" or
"blocked". Version field: the newest release is R1/beta5; the hrev is what matters. Test tools named
`tools/...` are in this repository.

### 1.1 All architectures

<a id="hk-03"></a>

#### HK-03 — kernel/vm: mprotect() of a file mapping detaches every MAP_SHARED mapping of the file when the file also has a private mapping

- **Trac fields:** Component: `System/Kernel` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug
- **Severity:** data corruption (writes through MAP_SHARED mappings stop reaching the file)
- **Scope:** all architectures; generic VM code (`vm.cpp`)
- **Our fix:** haiku-pi/haiku `rpi4` `894c4abe7f` — "kernel/vm: keep MAP_SHARED file mappings shared across mprotect()"
- **Patch:** with notes: upstream af99ec6c14 already fixed the protection-flag half differently, so the patch does not apply. Only the copy-on-write half is needed: the helper `protection_change_needs_copy_on_write()` (`!cache->consumers.IsEmpty() && cache->type != CACHE_TYPE_VNODE`), used at the two call sites. That is about 15 lines.
- **Upstream status (2026-11-20):** open (the remaining half): `src/system/kernel/vm/vm.cpp:3260-3264` (`vm_set_area_protection()`) and `:6075`/`:6118` (`_user_set_memory_protection()`) call `vm_copy_on_write_area()` on any cache with consumers, a file's (vnode) cache included. A private mapping makes the file's cache gain a consumer at `vm.cpp:1279`. The fork-based path in our reproducer was closed by af99ec6c14 (hrev60370, ticket #20479). Trac: searched "mprotect shared": only #20479 (closed, fixed: the flag half).

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB; also x86_64 under KVM (hrev60314: the fork variant failed).

**Description.** When an area's cache has consumers, a protection change inserts a copy-on-write cache above it and moves every area of the cache onto the new anonymous cache. That is right for anonymous memory. For a file's cache it moves all shared mappings of the file, in every team, away from the file. Their writes then go to private pages, and later mappings and `read()` do not see them. Wine's wineserver depends on such a mapping ("Session object id doesn't match", a prefix never finished).

**Steps to reproduce.**
1. Create a 16 KiB file `fd`.
2. `p = mmap(NULL, 16384, PROT_READ, MAP_SHARED, fd, 0)`.
3. `q = mmap(NULL, 16384, PROT_READ, MAP_PRIVATE, fd, 0)`. This gives the file's cache a consumer.
4. `mprotect(p, 16384, PROT_READ | PROT_WRITE)`, then `p[0] = 0x55`.
5. `pread(fd, &c, 1, 0)`.

The steps above were derived from the code and not run on hrev60450. Our `tools/kernel-tests/mmap-shared-mprotect.c` runs the original fork + mprotect variant.

**Expected.** `c == 0x55`.
**Actual.** `c` keeps the old value: the shared mapping now sits on an anonymous cache.

**Root cause.** `vm.cpp:3260` and `:6075` test `!cache->consumers.IsEmpty()` without excluding `CACHE_TYPE_VNODE`. `vm_copy_on_write_area()` (`:2838`) then moves all areas of the file's cache.

**Fix.** Never insert a copy-on-write cache above a vnode cache. Its areas are shared mappings, and private mappings of the file see its changes anyway, as they do after `write()`.

**Evidence.** `tools/kernel-tests/mmap-shared-mprotect.c`: BROKEN on upstream hrev60314 x86_64, PASS with the fix (Pi and x86_64 KVM). A new Wine prefix finishes on the Pi only with the fix. The MAP_PRIVATE variant is from code inspection.

<a id="hk-04"></a>

#### HK-04 — kernel/vm: the page writer leaves a device's last modified pages unwritten until a sync

- **Trac fields:** Component: `System/Kernel` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug
- **Severity:** data corruption (data written long ago is lost on power cut)
- **Scope:** all architectures; generic VM code
- **Our fix:** haiku-pi/haiku `rpi4` `1539d29eee` — "kernel/vm: page writer: write what there is after the wait times out"
- **Patch:** with notes: the hunk conflicts with upstream's under-quota condition (599236b8ef). On hrev60450 the whole fix is to drop the `continue` after the timed-out `fPageWriterCondition.Wait()`, keeping the `sUnderQuotaCondition` test. That is how our tree has it since the 11-17 merge.
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/system/kernel/vm/vm_page_writer.cpp:567-570`. Regression from the per-device page writers, 3bfaa91290b (hrev59865, 2026-04-14). Trac: searched "page writer unwritten" and "page writer power": no matching ticket.

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB, BFS on SD card.

**Description.** Each device's page writer waits up to `PAGES_FLUSH_DURATION_LOCAL_QUOTA` (3 s) for a trigger while it holds fewer than `kNumPages` modified pages. On a timeout it goes straight back to waiting, so those pages (up to 1 MB of a file) are written only by an explicit sync, by memory pressure, or by more writes. A power cut loses them.

**Steps to reproduce.**
1. On an otherwise idle volume, write a file of about 100 kB (e.g. `dd if=/dev/urandom of=f bs=1k count=111`), without `sync`.
2. Wait 60 s.
3. Cut the power (or read the file's blocks from the raw device).

**Expected.** The data is on the disk within a few seconds.
**Actual.** The file's data is not on the disk after 60 s.

**Root cause.** `vm_page_writer.cpp:567-570`:
```
if (queue.Count() < kNumPages && sUnderQuotaCondition.EntriesCount() == 0) {
	if (!fPageWriterCondition.Wait(PAGES_FLUSH_DURATION_LOCAL_QUOTA, true))
		continue;
}
```

**Fix.** After the wait, timed out or not, fall through and write what is queued. An idle writer finds no pages (`:574`) and waits again.

**Evidence.** Pi 4: a 111 kB file was still not on the disk after 60 s; with the fix it was written within 5 s. A package installed just before a power-off lost its last 163 kB.

<a id="hk-51"></a>

#### HK-51 — BFS: `rm -rf` of freshly written files deadlocks against `sync`

- **Trac fields:** Component: `File Systems/BFS` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug
- **Severity:** hang (the volume hangs until reboot)
- **Scope:** all architectures; generic BFS/VFS/I/O code; reproduced on x86_64 under KVM
- **Our fix:** haiku-pi/haiku `rpi4` `44cc183c0c` — "bfs: leave the last put of an I/O's vnode to the undertaker"
- **Patch:** attachable as-is; `bfs/kernel_interface.cpp` differs from upstream only by this fix
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/add-ons/kernel/file_systems/bfs/kernel_interface.cpp:111-116`; Trac: searched `q=bfs+rm+deadlock+sync`: blocked by the bot check (no result)

**Environment.** x86_64 under KVM (q35, UEFI, AHCI, 4 CPUs): our tree and an upstream hrev60314 image. The
call chains and lock dumps come from our arm64 tree at hrev60431.

**Description.** `bfs_io()` keeps a vnode reference until `iterative_io_finished_hook()`. `IORequest::NotifyFinished()`
wakes the request's waiters before it runs that hook, so the hook can drop the last reference of a file that has been
unlinked. `put_vnode(fs_volume*, ...)` is a re-entrant put and frees the vnode at once (`src/system/kernel/fs/vfs.cpp:3945`, `:1095-1096`).
That runs `bfs_remove_vnode()`, and so `Transaction::Start()`, in the I/O notifier thread. The notifier then waits for
the journal, which `rm` holds. `rm` in turn waits in `Inode::Remove()` → `WriteLockInTransaction()` for the inode's read
lock, which only that notifier can release. After that, nothing on the volume progresses.

**Steps to reproduce.** (`tools/x86-tests/bfsrm.sh`, with `tools/haiku-tests/bfsmeta.c`)
1. On a fresh 2 GB scratch BFS volume, run `bfsmeta /scratch/metaN 4000`, which writes 4×512 bytes and 2 attributes per file.
2. Start `rm -rf /scratch/metaN` in the background.
3. Run `sync` while it runs. On the first boot, PostInstallScript's own `sync` overlaps the first round; a plain sync loop did not reproduce it as reliably.
4. Count it as a hang if `rm` has not finished after 60 s.

**Expected.** `rm` finishes in a few seconds.
**Actual.** `rm` never finishes; CPUs are idle and every later operation on the volume blocks.

**Root cause.** `kernel_interface.cpp:115-116`: `rw_lock_read_unlock(&inode->Lock());
put_vnode(inode->GetVolume()->FSVolume(), inode->ID());`. This is a re-entrant final put from the I/O completion
context. It was introduced by 551a9b9a01 ("BFS: Keep references to vnodes during asynchronous I/O.", hrev58351).

**Fix.** The hook takes a normal (non-re-entrant) reference via `vfs_lookup_vnode()`/`vfs_put_vnode()`, so the last put
goes to the vnode undertaker (bc46fb3e9a, hrev59944) instead of freeing in the notifier (44cc183c0c). Design note:
coordination repo `docs/design/bfs-rmrf-hang.md`.

**Evidence.**
- x86_64 KVM, our tree: 6 of 25 runs hung without the fix, 0 of 50 with it (Fisher p ≈ 8.8·10⁻⁴).
- Upstream hrev60314 image: 2 of 6 runs did not finish. No KDL capture was taken on that image.
- Not reproduced on the Pi 4: 0 of 20 runs without the fix.

<a id="hk-52"></a>

#### HK-52 — BFS: mounting a damaged volume panics in block_cache ("FreeBlock(): 1 ... parent 0x0")

- **Trac fields:** Component: `File Systems/BFS` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug
- **Severity:** crash (kernel panic from removable media; mount_server mounts removable disks automatically)
- **Scope:** all architectures; generic BFS code; reproduced in the host `bfs_shell` too
- **Our fix:** haiku-pi/haiku `rpi4` `9799738757` — "bfs: end the journal before failing a mount"
- **Patch:** attachable as-is; `bfs/Volume.cpp` differs from upstream only by this fix
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/add-ons/kernel/file_systems/bfs/Volume.cpp:227-292` (error returns after line 227 do not delete `fJournal`); Trac: searched `q=FreeBlock+mount+bfs`: blocked by the bot check (no result)

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB, USB stick; also the host `bfs_shell` built from the same tree.

**Description.** The volume's preconditions: an unreadable root inode, and a block bitmap that does not reserve the
bitmap/log area. Mount then repairs the bitmap in a `Transaction` (`BlockAllocator.cpp:830`), which the journal leaves
open for batching. The root-node failure path returns without deleting `fJournal`. `DeviceOpener` then deletes the
block cache while that transaction is still open, and the block cache panics. The leaked journal also leaves its
log-flusher thread running, and the `publish_vnode()` failure path skips `fBlockAllocator.Uninitialize()`.

**Steps to reproduce.**
1. `truncate -s 64M c14.img && bfs_shell --initialize c14.img test`
2. `python3 tools/diagnostics/bfs-corrupt.py c14.img --bitmap --root` (corrupts the root inode and clears the bitmap's reserved area).
3. Mount it in `bfs_shell`, or write it to a USB stick, plug it in and `mount -t bfs <dev> /c14`.
   Controls: `--root` alone fails cleanly; `--bitmap` alone mounts with the bitmap repaired.

**Expected.** The mount fails with an error.
**Actual.** `PANIC: block_cache::FreeBlock(): 1, original ..., parent 0x0`, from `block_cache_delete` ← `~DeviceOpener` ← `Volume::Mount`. `bfs_shell` exits with SIGSEGV.

**Root cause.** `Volume::Mount()`: `fJournal` is created at `Volume.cpp:227`. The error returns after it do not
delete it: allocator failure at `:251`, `publish_vnode()` failure at `:283-284` (which also skips the allocator's
`Uninitialize()`), and root node failure at `:289-292`. Only `Unmount()` deletes it (`:310`); `~Volume()` does not.

**Fix.** End and delete the journal (and uninitialize the allocator) on every mount failure path (9799738757).

**Evidence.**
- `bfs_shell`: stock tree "FreeBlock(): 1", exit 139; fixed "Mounting FS failed: Invalid argument", exit 1.
- Pi 4: 5 mounts plus one `mountvolume -all` of the stick, all failing cleanly, no panic.
- Not run on an unmodified upstream image.

<a id="hk-50"></a>

#### HK-50 — Bluetooth/L2CAP: a connection or disconnection response with an unknown identifier panics the kernel (remote)

- **Trac fields:** Component: `Network & Internet/Bluetooth` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug
- **Severity:** crash, remotely triggerable (security)
- **Scope:** all architectures; the L2CAP signalling code is generic and independent of the HCI transport (USB h2generic as well as UART), and l2cap is in the regular image
- **Our fix:** haiku-pi/haiku `rpi4` `b0ea06deaf` — "l2cap: ignore connection and disconnection responses to unknown requests"
- **Patch:** attachable as-is
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/add-ons/kernel/network/protocols/bluetooth/l2cap/l2cap_signal.cpp:79, 250`; Trac: Trac search blocked (bot check); a web search restricted to dev.haiku-os.org found no ticket

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB, on-board Bluetooth controller over UART; the peer was a Linux laptop running BlueZ.

**Description.** The L2CAP signalling layer matches a response to its endpoint through the command identifier,
using `lookup_command_ident()`. For an identifier the stack does not know, the lookup returns NULL. The
command-reject and configuration-response handlers check for NULL; the connection-response and
disconnection-response handlers do not, and they call a method on the NULL endpoint. Any peer with an ACL link can
send such a response. No pairing or authentication is needed, because bluetooth_server accepts every incoming
connection (`src/servers/bluetooth/LocalDeviceImpl.cpp:1293`, `if (true) { // Check Preferences ...`).

**Steps to reproduce.**
1. Start bluetooth_server on Haiku and make the adapter connectable.
2. From a Linux/BlueZ host, pair with Haiku by PIN.
3. Remove the pairing on the Linux host. BlueZ then sends an L2CAP connection response for which Haiku has no request.
   (A crafted CONNECTION_RSP or DISCONNECTION_RSP with an unused identifier does the same.)

**Expected.** The response is ignored.
**Actual.** Kernel panic: a page fault at 0x6c in `L2capEndpoint::_HandleConnectionRsp()`, in the RX assembly thread.

**Root cause.** `l2cap_signal.cpp:79` (`endpoint->_HandleConnectionRsp(ident, response);`) and `:250`
(`endpoint->_HandleDisconnectionRsp(ident, dcid, scid);`) are called with the endpoint from
`btCoreData->lookup_command_ident()` (`:473`), dispatched at `:501` and `:519` without a NULL check.

**Fix.** Both handlers log and drop a response whose endpoint is NULL (b0ea06deaf). RenkuOS's Bluetooth series
(#252) contains the same checks.

**Evidence.** Pi 4: 2 panics in 2 attempts before the fix, 0 panics in 3 attempts after.

<a id="hk-53"></a>

#### HK-53 — runtime_loader: a new thread's TLS generation starts at 0, so its thread_local values are discarded after any dlclose()

- **Trac fields:** Component: `System/runtime_loader` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug
- **Severity:** data corruption (thread_local values silently reset; crashes in callers)
- **Scope:** all architectures; generic `elf_tls.cpp`, reached from every architecture's `__tls_get_addr`; fails on upstream x86_64
- **Our fix:** haiku-pi/haiku `rpi4` `5db923abc6` — "runtime_loader: a new thread's TLS vector starts at the current generation"
- **Patch:** attachable as-is
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/system/runtime_loader/elf_tls.cpp:293`; Trac: searched `q=thread_local+TLS+dlclose`: blocked by the bot check (no result)

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB; also upstream hrev60314 on x86_64 (KVM).

**Description.** `DynamicThreadVector::_ResizeVector()` creates a thread's `Generation` with counter 0. The first
`get_tls_address()` on the new thread skips the staleness check because `_Generation()` is still -1. Once any TLS
image has been unloaded, the global generation is 1 or more. On the next access, counter 0 is below it, so the
thread destroys every block whose module generation is above 0, including the block it has just created. The
thread_local value it just stored reads back as 0. In Mesa, `call_once` state was lost this way, and a second
`vkCreateInstance()` on a new thread jumped to address 0.

**Steps to reproduce.** (`tools/haiku-tests/tlsreload/`: `tlsreload.c` + `libtlsr.c`)
1. On the main thread, `dlopen()` then `dlclose()` a library with a `__thread` variable, and `dlopen()` it again.
2. On a new thread, set the variable to 1234 and read it back.

**Expected.** 1234.
**Actual.** `round 1: read 0 after setting 1234`.

**Root cause.** `elf_tls.cpp:293`: `fGeneration = new Generation;`. No `SetCounter()` follows; the only caller is `:248`.

**Fix.** Initialize the new vector's generation to the current global generation (5db923abc6, 7 lines).

**Evidence.** Upstream hrev60314 on x86_64: tlsreload fails as above. Our tree on the Pi 4 and on x86_64 passes.

<a id="hk-55"></a>

#### HK-55 — Application Kit: programs crash at exit because the BMessage cache is freed while a looper still runs

- **Trac fields:** Component: `Kits/Application Kit` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug
- **Severity:** crash (at quit; a Tracker crash alert stopped a system shutdown)
- **Scope:** all architectures; generic libbe; any program with a looper that outlives `exit()`, such as BPathMonitor's "PathMonitor looper" (Tracker, Deskbar…)
- **Our fix:** haiku-pi/haiku `rpi4` `a779571e90` — "libbe: keep the message cache when the library terminates"
- **Patch:** attachable as-is (the fix intentionally leaves the cache to die with the team)
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/kits/app/InitTerminateLibBe.cpp:84`, `src/kits/app/Message.cpp:2124-2125`; Trac: Trac search blocked (bot check); a web search restricted to dev.haiku-os.org found no ticket

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB; also QEMU arm64 virt.

**Description.** `terminate_after()` runs from `exit()` while the team's other threads are still running, and it deletes
BMessage's static block cache (`StaticCacheCleanup()`). A looper that was never quit then allocates or frees a message
through `BBlockCache::Get()` / `Save()` on the NULL cache and faults at 0x34. Tracker hit this while the system was
shutting down. Its crash alert then stopped the shutdown.

**Steps to reproduce.**
1. Build `tools/haiku-tests/pmexit.cpp`, which starts watching a path with BPathMonitor, waits briefly and returns from main.
2. Run `tools/pi-tests/pmexit-loop.sh`. It keeps creating and deleting the watched path's parent directories while running pmexit N times.
3. Count faults. A fault at exit often leaves no exit status and no debug_server entry; we counted them with a kernel that logs user faults.

**Expected.** Clean exits.
**Actual.** About 1% of exits fault at 0x34 in `BBlockCache::Get()` / `Save()` from the PathMonitor looper thread.

**Root cause.** `InitTerminateLibBe.cpp:84` calls `BMessage::Private::StaticCacheCleanup()`, which does `delete sMsgCache;
sMsgCache = NULL;` (`Message.cpp:2124-2125`). Other threads still go through `sMsgCache->Get(size)` (`:249`) and
`sMsgCache->Save(...)` (`:275`).

**Fix.** Do not delete the cache at library termination (a779571e90).

**Evidence.**

| Test | Without the fix | With the fix |
|---|---|---|
| pmexit, Pi 4 | 11/1000 | 0/1000 |
| pmexit, QEMU arm64 | 6/400 | 0/400 |
| Tracker first-boot shutdowns, QEMU | 2/6 | 0/18 |
| Tracker first-boot shutdowns, Pi 4 | 1/23 | 0/10 |

x86_64 not tested.

<a id="hk-11"></a>

#### HK-11 — kernel/thread: a dying team deletes an exited thread's stack while its other threads still run

- **Trac fields:** Component: `System/Kernel` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug
- **Severity:** crash (segment violation in a team that is already going down; a crash dialog)
- **Scope:** all architectures; generic `thread.cpp`
- **Our fix:** haiku-pi/haiku `rpi4` `e09cfa1d9e` — "kernel/thread: keep an exited thread's stack while its team goes down"
- **Patch:** with notes: our commit is written on top of our user-stack reuse (`ecab951764`) and does not apply. Against hrev60450 the whole change is to skip `vm_delete_area(teamID, userStackArea, true)` when `team->state >= TEAM_STATE_SHUTDOWN || team->exit.initialized` (the address space deletion frees it).
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/system/kernel/thread.cpp:2453-2463`. Trac: searched "thread stack SIGTERM segment violation": none.

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB.

**Description.** A signal whose default action ends the team (SIGTERM) is handled by one thread, which exits at once. The main thread kills the others only later, and until then they run. Deleting the exited thread's stack area at that point makes any thread that touches an object on it fault. A pool's idle list keeps an entry on each idle thread's stack, for example.

**Steps to reproduce.** Use `tools/haiku-tests/killrace.cpp` (as `kill_race2`, driven by `tools/pi-tests/kill-race-loop.sh`):
1. A victim thread links a node on its own stack into a list.
2. Walker threads read the list in a loop.
3. Send the team SIGTERM.

**Expected.** The team ends by SIGTERM with no fault.
**Actual.** "debug_server: Thread N entered the debugger: Segment violation".

**Root cause.** `thread.cpp:2453-2463` deletes the stack of any non-last thread, including while the team is shutting down.

**Fix.** While the team is going down, leave the area to the deletion of the team's address space (as Linux keeps a dying thread group's memory).

**Evidence.** `killrace`: 20/20 runs faulted before the fix, 0/30 after. Firefox content processes: about 1 in 60 SIGTERM ends crashed before, none after.

<a id="hk-10"></a>

#### HK-10 — kernel/debug: the profiler can leave a timer armed on a CPU (self-linked timer list hang, or NULL dereference in profiling_event())

- **Trac fields:** Component: `System/Kernel` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug
- **Severity:** hang / crash (interrupts-off spin, or kernel panic)
- **Scope:** all architectures; generic `user_debugger.cpp` and `scheduler.cpp`
- **Our fix:** haiku-pi/haiku `rpi4` `5180e96119` — "kernel/debug: do not leave a profiling timer behind on a CPU"
- **Patch:** attachable as-is
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450. `src/system/kernel/scheduler/scheduler.cpp:294` (unschedules through the debugger code only while `THREAD_FLAGS_DEBUGGER_INSTALLED` is set); `src/system/kernel/debug/user_debugger.cpp:1331` (`ASSERT(timer->hook == NULL)` instead of cancelling) and `:1500` (`profiling_event()` trusts the current thread's `installed_timer`). Trac: searched "profiling_event": only #17531 (closed, unrelated).

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB.

**Description.** When a team's debugger (the profiler) goes away, `THREAD_FLAGS_DEBUGGER_INSTALLED` is cleared on all its threads, including one running on another CPU with its profiling timer armed. `switch_thread()` then skips `user_debug_thread_unscheduled()`, and the per-CPU timer stays scheduled after the thread has gone. Two outcomes follow:
- When the next profiled thread on that CPU adds the timer again, the timer is linked to itself, and the next walk of the timer list spins with interrupts off.
- When the timer fires, `profiling_event()` dereferences the current thread's NULL `installed_timer` (FAR 0x20).

**Steps to reproduce.**
1. Run `profile -i 1000 -f -k <multi-threaded program that runs for a while>`. We used `wineboot -i`.
2. Let the profiled team end while its threads are on other CPUs.

**Expected.** The profile report is written and the system continues.
**Actual.** A system hang, or `PANIC: unhandled pagefault … profiling_event + 0x30`, each on the first run.

**Root cause.** `scheduler.cpp:294`, `user_debugger.cpp:1327-1335`, `:1500-1510`.

**Fix.** Unschedule through the debugger code whenever the thread has `installed_timer`. Cancel the timer before re-adding it and when a profiled thread exits. Ignore in `profiling_event()` a timer that is not the current thread's.

**Evidence.** Pi 4: `profile -i 1000 -f -k wineboot -i` 3 times in a row; before the fix it hung or panicked on the first run. Reports are complete (1768 of 1771 expected ticks for a busy python3).

<a id="hk-57"></a>

#### HK-57 — SDHCI: interrupts acknowledged with `|=` on the write-1-to-clear status register lose "transfer complete" (I/O hangs); other generic bugs

- **Trac fields:** Component: `Drivers/Disk/MMC` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug
- **Severity:** hang (a read waits forever); the sub-bugs below are wrong output
- **Scope:** all architectures; `sdhci.cpp` / `sdhci.h` are the common core behind `sdhci_pci` and `sdhci_acpi` on x86 too; the lost interrupt needs a fast controller
- **Our fix:** haiku-pi/haiku `rpi4` `23f6235b0d` — "sdhci: fixes found on real hardware; 32-bit access, platform clock and DMA"
- **Patch:** with notes: needs splitting. The commit also adds Pi hardware support: 32-bit register access, a platform-supplied base clock, a DMA window and cache maintenance. The generic fixes below are small separate hunks.
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/add-ons/kernel/busses/mmc/sdhci.cpp:334, 682-683, 720-786`, `sdhci.h:331, 172-175`; Trac: searched `q=sdhci+interrupt`: blocked by the bot check (no result)

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB, SD card on emmc2 (brcm,bcm2711-emmc2).

**Description.** The normal/error interrupt status register is write-1-to-clear. The driver acknowledges interrupts with
`fRegisters->interrupt_status |= bits`. That reads the register and writes back every bit that is set at that
moment, including bits that latched after the handler sampled the status. If "transfer complete" arrives right after
"command complete" (a 512-byte read on a fast controller), it is cleared unseen, and the read waits forever.

Other generic bugs in the same code:
- **RecoverError() acknowledges the wrong bits.** `int16_t error_status = fRegisters->interrupt_status;
  fRegisters->interrupt_status &= ~(error_status);` (`sdhci.cpp:682-683`). The status is truncated to 16 bits, and the
  value written is the current status *minus* the snapshot, so the snapshot bits are never acknowledged and newer bits
  are cleared instead. When bit 15 (error summary) is set, sign extension also drops bits 31:16.
- **Timeout clock frequency read from 5 bits, not 6.** `uint32_t frequency = (fBits >> 0) & 0x1F;` (`sdhci.h:331`). A
  48 MHz timeout clock reads as 16 MHz, so the data timeout set at `sdhci.cpp:133` is about 3× shorter than intended.
- **A card present at start-up is scanned twice.** The insertion that latched earlier is still pending when
  `SetScanSemaphore()` releases the semaphore (`sdhci.cpp:581`) and then enables CARD_INS (`:585`). The interrupt fires
  at once and releases it again (`:730`).
- **Clock divider rounded down.** `int divider = base_clock * 1000 / kilohertz;` (`sdhci.cpp:425`; halving in
  `sdhci.h:172-175`). The card clock can exceed the request: a 50 MHz base gives 403 kHz for the 400 kHz
  identification clock.
- Noise: `sdhci.cpp:393` logs every successful command with `ERROR()`.

**Steps to reproduce.** Boot from or read heavily from an SD card on a fast SDHCI controller (on the Pi 4's emmc2 it
happened during SD boot). For the divider: read the card clock against a base clock that is not a power-of-two multiple of 400 kHz.

**Expected.** Every command and transfer completes.
**Actual.** A data read never completes: no "transfer complete" is ever seen and the I/O waits without end.

**Root cause.** The `interrupt_status |=` acknowledgements at `sdhci.cpp:334, 720, 734, 743, 752, 759, 781, 786`, plus the lines listed above.

**Fix.** Write exactly the bits being acknowledged; read the 32-bit status in RecoverError(); use a 6-bit mask; clear
the latched insertion before enabling the interrupt; round the divider up (23f6235b0d, generic hunks).

**Evidence.** Found as a hang during SD boot on the Pi 4; with the fix, SD boots and SD soaks run without a lost
completion. No rate was measured before the fix, and nothing was tried on x86 SDHCI hardware.

<a id="hk-15"></a>

#### HK-15 — kernel/device_manager: IORequest iteration recurses once per round of file vecs: kernel stack overflow with synchronous drivers

- **Trac fields:** Component: `System/Kernel` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug
- **Severity:** crash (kernel stack overflow and panic in the page writer)
- **Scope:** all architectures; generic `IORequest.cpp`. Any driver that completes I/O synchronously inside the iteration callback: a device without an `io()` hook, such as `remote_disk`.
- **Our fix:** haiku-pi/haiku `rpi4` `90fa3bc401` — "kernel/device_manager: IORequest: iterate in a loop, not by recursion"
- **Patch:** attachable as-is
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/system/kernel/device_manager/IORequest.cpp:950-960` (`NotifyFinished()` calls the iteration callback directly). Upstream fixed one instance per driver: #19505 ("Stack overflow - nvme_disk, VMVnodeCache PageWriter", same stack `do_iterative_fd_io_iterate` / `NotifyFinished` repeated) was fixed in hrev59132 by making nvme_disk use IORequestOwners. Other synchronous paths keep the recursion. Trac: searched "IORequest stack overflow": #19505 (closed, fixed for nvme_disk).

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB, network boot (`remote_disk`).

**Description.** When the sub-requests an iteration callback schedules finish before it returns, the last one notifies the parent. The parent's `NotifyFinished()` then runs the callback again, adding one stack level per round of up to 8 file vecs. A fragmented file overflows the kernel stack.

**Steps to reproduce.**
1. On a volume served by a driver without an `io()` hook (`remote_disk`), nearly full, write back a large fragmented file through the page writer. In our case: a Wine Mono install.

**Expected.** The write-back completes.
**Actual.** Kernel stack overflow and a panic (`do_iterative_fd_io_iterate` / `NotifyFinished` / `synchronous_io` / `vfs_vnode_io` repeated).

**Root cause.** `IORequest.cpp:950-960`.

**Fix.** A notification that arrives while the callback runs only records that the I/O finished. The caller's loop then goes on to the next round. Asynchronous completions are unchanged.

**Evidence.** Weak: not reproduced synthetically (a 30 MB file written into 4 KiB holes did not crash the old kernel). The Wine case on the full network disk passes with the fix. Upstream's #19505 shows the same recursion on x86_64 NVMe.

<a id="hk-54"></a>

#### HK-54 — kernel: a thread with a caller-provided stack (pthread_attr_setstack) gets its stack top and TLS 16 KiB past the buffer

- **Trac fields:** Component: `System/Kernel` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug
- **Severity:** data corruption (writes past the caller's buffer) or a thread that silently never runs
- **Scope:** all architectures; generic `thread.cpp`; on both x86 and arm64 `user_local_storage = user_stack_base + user_stack_size`; fails on upstream x86_64
- **Our fix:** haiku-pi/haiku `rpi4` `dbae37b2cb` — "kernel/thread: Don't place a caller-provided stack a guard size too high."
- **Patch:** attachable as-is (1 line)
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/system/kernel/thread.cpp:911, 956`; Trac: not searched

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB; also upstream hrev60314 on x86_64 (KVM).

**Description.** Guard pages are ignored for a caller-provided stack, but `guardSize` is still added to the stack base.
libpthread passes its default guard (`USER_STACK_GUARD_SIZE`, 16 KiB) even after `pthread_attr_setstack()`, which leaves
`guard_size` as it is (`pthread_attr.c:238`). The kernel therefore puts the stack top and the TLS block 16 KiB beyond
the end of the caller's buffer. Writing the TLS block either corrupts whatever follows the buffer or faults, and in
the second case the new thread never runs.

**Steps to reproduce.**
1. `malloc()` a 128 KiB buffer and call `pthread_attr_setstack(&attr, buf, 131072)`.
2. `pthread_create()` a thread that sets a flag, then join it.
   Alternatively run `tools/haiku-tests/threadstress.c` (`threadstress 1000`).

**Expected.** The thread runs inside the buffer.
**Actual.** On upstream x86_64: `user: stack ... not in the user's ...+131072`, "did not run", and threadstress hangs until its 900 s timeout.

**Root cause.** `thread.cpp:911` handles a given stack (`stackSize -= TLS_SIZE;`) but does not zero `guardSize`, and
`thread.cpp:956` then sets `thread->user_stack_base = (addr_t)stackBase + guardSize;`.

**Fix.** Set `guardSize = 0` for a caller-provided stack (dbae37b2cb).

**Evidence.** Upstream hrev60314 x86_64: threadstress hangs as above. Our tree passes on x86_64 and on the Pi 4.

<a id="hk-61"></a>

#### HK-61 — fork(): the runtime_loader heap is not locked, so the child can inherit a half-updated heap and crash or hang

- **Trac fields:** Component: `System/runtime_loader` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug
- **Severity:** crash or hang (in the child of a multithreaded program)
- **Scope:** all architectures; generic `fork.c` and runtime_loader `heap.cpp`
- **Our fix:** haiku-pi/haiku `rpi4` `634dd24886` — "runtime_loader: Keep the heap consistent across fork()."
- **Patch:** with notes: the `fork.c`, `heap.cpp` and `export.cpp` hunks apply as-is. The `headers/private/runtime_loader/runtime_loader.h` hunk sits next to our own `tls_generation` member of the rld export struct, so the new members have to be rebased onto upstream's struct end.
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/system/libroot/posix/unistd/fork.c:152-154`, `src/system/runtime_loader/heap.cpp:102`; Trac: searched `q=fork+runtime_loader+heap`: blocked by the bot check (no result)

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, QEMU virt (4 CPUs) and Raspberry Pi 4 Model B 4 GB.

**Description.** `fork()` takes libroot's malloc locks (`__heap_before_fork()`) but not the runtime_loader heap's
`sLock`. In the child, the runtime_loader only re-initializes that lock (`heap.cpp:102`, `recursive_lock_init`). If
another thread of the parent was inside the runtime_loader allocator at the moment of the fork (a TLS vector
allocated or freed by a new or exiting thread, dlopen()…), the child inherits a free-chunk tree in the middle of an
update. Its next allocation crashes or loops.

**Steps to reproduce.** Run `threadstress <N> fork` (`tools/haiku-tests/threadstress.c`, "fork-busy" test). It forks 40
times while 4 threads keep creating threads that touch TLS, and each child allocates and exits.

**Expected.** All children exit normally.
**Actual.** Without the fix, 10 of 40 children crashed (another run: 3 crashed, then one hung).

**Root cause.** `fork.c:152` `__heap_before_fork();` then `:154` `thread = _kern_fork();`. Nothing between them takes the
runtime_loader heap lock.

**Fix.** Export lock/unlock hooks from the runtime_loader heap and take them around `_kern_fork()` in parent and child (634dd24886).

**Evidence.** QEMU arm64: 10 of 40 children crashed without the fix, 0 of 40 with it. fork+exit is about 4% slower (1.13 → 1.18 ms).
Not run on an upstream image: there, threadstress hangs earlier on HK-54.

<a id="hk-60"></a>

#### HK-60 — kernel: poll() ORs POLLNVAL|POLLERR|POLLHUP into the caller's `events`, so event loops spin

- **Trac fields:** Component: `System/Kernel` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug
- **Severity:** performance (busy loop: a CPU spins in libevent-based programs)
- **Scope:** all architectures; generic `wait_for_objects.cpp`; fails on upstream x86_64
- **Our fix:** haiku-pi/haiku `rpi4` `127fb34239` — "kernel: poll() must not change the caller's events"
- **Patch:** attachable as-is
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/system/kernel/events/wait_for_objects.cpp:580`; Trac: searched `q=poll+events+POLLNVAL`: blocked by the bot check (no result)

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB; also upstream hrev60314 on x86_64 (KVM).

**Description.** `common_poll()` adds `POLLNVAL | POLLERR | POLLHUP` to `fds[i].events`, and `_user_poll()` copies the
whole array back to the caller. POSIX makes `events` an input. libevent's poll back end decides whether an fd is still
wanted from `events == 0`. After poll() has changed the field, a closed fd is never removed, so every later poll()
returns POLLNVAL at once and the loop spins. Firefox's IPC thread made about 2000 poll() calls per second at quit.

**Steps to reproduce.** (`tools/haiku-tests/polltest.c`)
1. `struct pollfd p = { fd, POLLIN, 0 };`
2. `poll(&p, 1, 0);`
3. Print `p.events`.

**Expected.** `events` is still `POLLIN` (0x1).
**Actual.** `events` is 0x1085 (`POLLIN|POLLERR|POLLHUP|POLLNVAL`).

**Root cause.** `wait_for_objects.cpp:580` `fds[i].events |= POLLNVAL | POLLERR | POLLHUP;`, then `:581`
`sync->set[i].selected_events = fds[i].events;`.

**Fix.** Add those bits only to `selected_events`, leaving `fds[i].events` alone (127fb34239).

**Evidence.** Upstream hrev60314 on x86_64: polltest fails ("events unchanged … (0x1085)"). Firefox's IPC thread at quit made about 2000 polls/s before the fix and 141 polls in total after it.

<a id="hk-12"></a>

#### HK-12 — kernel/fs: boot fails with "did not find any boot partitions" when the boot disk is published late (SD/MMC)

- **Trac fields:** Component: `System/Kernel` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug
- **Severity:** crash (boot panic)
- **Scope:** all architectures; generic `vfs_boot.cpp`. Affects disks on buses probed asynchronously, such as the MMC bus, which scans in its own thread (any SD/eMMC boot). Upstream explores a new USB bus in `Start()`, so USB disks are there in time; our tree moved that to the explore thread (`afb2823bb5`) and relies on this wait.
- **Our fix:** haiku-pi/haiku `rpi4` `bce76d6e73` — "kernel/vfs: wait for a boot device that is published late"
- **Patch:** attachable as-is
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/system/kernel/fs/vfs_boot.cpp:404-422` (one strict pass, then one less strict pass, no waiting) and `:481` (panic). Trac: searched "did not find any boot partitions SD": several tickets show this panic, but none attributes it to a late MMC device.

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB, booting from SD.

**Description.** `get_boot_partitions()` runs `InitialDeviceScan()` and looks for the boot partition once, strictly, then once less strictly. An SD card, published by the MMC bus thread, can appear after that, so the boot panics. Worse, the less strict pass can pick another disk that happened to be found first.

**Steps to reproduce.**
1. Boot from an SD card on a board whose boot medium is on the MMC bus.

**Expected.** The boot volume is found once the disk appears.
**Actual.** `PANIC: did not find any boot partitions!`

**Root cause.** `vfs_boot.cpp:404-422`.

**Fix.** Rescan for up to 10 s until a strictly matching partition appears; only then fall back to the less strict match.

**Evidence.** Pi 4 SD boots failed with this panic before the fix and boot with it; no failure counts were recorded.

<a id="hk-19"></a>

#### HK-19 — kernel/vm: a clone of a B_CONTIGUOUS area is mapped lazily, but lock_memory_etc() assumes it is mapped

- **Trac fields:** Component: `System/Kernel` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug
- **Severity:** crash (`PANIC: get_memory_map() called on unmapped memory!`)
- **Scope:** all architectures; generic `vm.cpp`
- **Our fix:** haiku-pi/haiku `rpi4` `797972f727` — "kernel/vm: map a clone of a B_CONTIGUOUS area in full, as one of a B_FULL_LOCK area"
- **Patch:** attachable as-is
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/system/kernel/vm/vm.cpp:2566` (`if (newArea->wiring == B_FULL_LOCK)` only) vs `:5148` (`lock_memory_etc()` skips `B_FULL_LOCK` and `B_CONTIGUOUS` areas). Trac: not searched.

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB.

**Description.** `vm_clone_area()` maps the source's pages in the clone only for `B_FULL_LOCK`, although a clone of a `B_CONTIGUOUS` area gets the same wiring. `lock_memory_etc()` skips both kinds as "already mapped", so `get_memory_map()` on such a clone's unfaulted pages panics.

**Steps to reproduce.**
1. A driver creates a `B_CONTIGUOUS` area.
2. A team clones it.
3. A driver calls `lock_memory()` + `get_memory_map()` on the clone before the clone's pages have been touched.

Derived from the code; on our tree the v3d driver did this.

**Expected.** The physical map is returned.
**Actual.** `PANIC: get_memory_map() called on unmapped memory!`

**Root cause.** `vm.cpp:2566`.

**Fix.** Map in full for `B_FULL_LOCK || B_CONTIGUOUS`.

**Evidence.** The v3d driver's import of a cloned overlay (scan-out) buffer hit this panic; it imports with the fix. No counts recorded.

<a id="hk-16"></a>

#### HK-16 — kernel/image: image notifications lose their pointer on 64-bit: `profile -a` cannot resolve programs started after it

- **Trac fields:** Component: `System/Kernel` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug
- **Severity:** wrong output (profiler ticks counted as "unknown")
- **Scope:** every 64-bit architecture (x86_64 included): two int32 fields and a pointer need 132 bytes in a KMessage with 64-bit pointers.
- **Our fix:** haiku-pi/haiku `rpi4` `f6c52282df` — "kernel/image: room for the pointer in image notifications"
- **Patch:** attachable as-is
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/system/kernel/image.cpp:63` (`char eventBuffer[128];`). Trac: searched "profile unknown image": no matching ticket.

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB.

**Description.** `ImageNotificationService::Notify()` builds its event in 128 bytes. The `imageStruct` pointer field does not fit, and `AddPointer()` fails silently. Listeners that need the pointer drop the event: the system profiler does, so every image loaded after `profile -a` started is unknown to it.

**Steps to reproduce.**
1. `profile -a -k` (system-wide).
2. One second later, start `python3 -c 'while 1: pass'`.
3. Stop the profiler and look at the report.

**Expected.** python3/libpython symbols are resolved.
**Actual.** The program's ticks count as "unknown".

**Root cause.** `image.cpp:61-71`.

**Fix.** A 256-byte buffer.

**Evidence.** Pi 4: unknown ticks 14.13 % → 0.01 %. In a desktop session, 65 % of busy ticks were "unknown" before. x86_64 follows from the same arithmetic; it was not measured there.

<a id="hk-27"></a>

#### HK-27 — kernel/cache: every BFS sub-transaction start walks the whole open transaction (O(n²) per transaction)

- **Trac fields:** Component: `System/Kernel` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug
- **Severity:** performance
- **Scope:** all architectures; every journaled `block_cache` user (BFS)
- **Our fix:** haiku-pi/haiku `rpi4` `a9db442988` — "block_cache: only look at changed blocks when starting a sub transaction"
- **Patch:** attachable as-is (with notes: a 152-line change; the `BLOCK_CACHE_CHECK_SUB_TRANSACTIONS` debug option compares with the full walk)
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/system/kernel/cache/block_cache.cpp:3466` (`cache_start_sub_transaction()`, full walk from `transaction->first_block` at `:3484-3486`). Trac: not searched.

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB.

**Description.** BFS starts a sub-transaction for every file system operation and batches them into one transaction of up to half its log (2043 blocks with a 4096-block log). Each start visits every block of the transaction, which is O(n) per operation and O(n²) per transaction.

**Steps to reproduce.**
1. Run many small metadata operations in one BFS transaction (e.g. create a new Firefox profile, or untar many small files).
2. Profile with `profile -k`.

**Expected.** Negligible time in `cache_start_sub_transaction()`.
**Actual.** 0.6–1.1 s of CPU in it for a Firefox first start.

**Root cause.** `block_cache.cpp:3466-3530`.

**Fix.** Keep a per-transaction list of blocks made writable or discarded since the last sub-transaction start, and walk only those. The full walk remains for the first start and after an abort/detach.

**Evidence.** Pi 4, Firefox first start: walk CPU 616–1055 → 26–59 ms. Power-cut and disk-full tests show the same disk writes in the same order.

<a id="hk-68"></a>

#### HK-68 — launch_daemon: the "shutdown in progress" check always fails in the system launch_daemon, so services are restarted during shutdown

- **Trac fields:** Component: `Servers/launch_daemon` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug
- **Severity:** performance (a respawn storm while a shutdown waits, e.g. on a crash alert)
- **Scope:** all architectures; reproduced on x86_64 under KVM
- **Our fix:** haiku-pi/haiku `rpi4` `f49813a540` — "launch_daemon: don't restart system services during a shutdown"
- **Patch:** with notes: the logic hunks apply as-is; the include block needs a trivial rebase (upstream replaced `<syscalls.h>` there with `<drivers/safemode_settings.h>`)
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/servers/launch/LaunchDaemon.cpp:585-589`. The check was added by 0749734769 ("launch_daemon: don't relaunch when a shutdown is in progress", 2019-12-21, hrev53643) but has never worked in the system launch_daemon. Trac: not searched.

**Environment.** Haiku nightly at hrev60431 (merge base), x86_64 under KVM and arm64 on the Raspberry Pi 4 Model B 4 GB.

**Description.** Before restarting a service that ended, the launch_daemon asks the registrar, through a `BRoster`,
whether a shutdown is in progress. In the system launch_daemon this question always fails:
1. `BRoster` finds the registrar by asking the launch_daemon for its data.
2. `get_launch_daemon_port()` refuses to let the launch_daemon's own main thread wait on itself, and returns -1 (`src/system/libroot/os/launch.cpp:24`).
3. The roster therefore has no messenger, and `IsShutDownInProgress()` returns an error, which `status != B_OK` counts as "not shutting down".

Most of the time this is invisible, because the shutdown ends soon. When the shutdown waits after the system-app phase
(on a crash alert, say), a service the registrar asked to quit, such as package_daemon, is restarted continuously.
The registrar refuses to register it (B_SHUTTING_DOWN), it exits, and it is started again.

**Steps to reproduce.** `tools/x86-tests/shutdown-respawn.sh guard` (uses `tools/haiku-tests/teamcrash.c` to hold a crash alert during shutdown), or by hand:
1. Start a program that crashes and leaves its alert open during a shutdown.
2. Start a shutdown.
3. Count package_daemon starts in the syslog.

**Expected.** No service is restarted after the shutdown has begun.
**Actual.** package_daemon is restarted every 25 ms (x86_64 KVM) to 110 ms (Pi 4) for as long as the alert stays open: 3043 times in one stall.

**Root cause.** `LaunchDaemon.cpp:585-589`: `BRoster roster; ... status_t status = rosterPrivate.IsShutDownInProgress(inProgress);
if (status != B_OK || !inProgress) { /* relaunch */ }`

**Fix.** The system launch_daemon started the registrar itself and knows its port; it asks the registrar there directly,
with a timeout. The user launch_daemon keeps using BRoster, which works for it (f49813a540).

**Evidence.** x86_64 KVM: guard test relaunched in 4 of 4 runs before, 0 of 2 after; shutdown loop 5 of 8 before, 0 of 6 after.

<a id="hk-65"></a>

#### HK-65 — libroot: strtold() is strtod(), so long double parsing has double precision and range

- **Trac fields:** Component: `System/libroot` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug
- **Severity:** wrong output
- **Scope:** all architectures with a long double wider than double: x86 and x86_64 (x87 80-bit), arm64 and riscv64 (binary128). The same `stdlib/strtold.c` is built for every architecture.
- **Our fix:** haiku-pi/haiku `rpi4` `12eb998a63` — "libroot: implement strtold() for long double formats wider than double"
- **Patch:** attachable as-is; attach it together with c8c59043a7 (HK-66), whose ERANGE checks the x87 path uses
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/system/libroot/posix/glibc/stdlib/strtold.c:25, 31`; Trac: not searched

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, QEMU and Raspberry Pi 4 Model B 4 GB; also upstream hrev60314 on x86_64 (KVM).

**Description.** `strtold()` and `__strtold_internal()` are a 1999 glibc stub that returns `__strtod_internal()`. The
result is rounded to double precision; `strtold("1e4000")` returns inf with ERANGE and `strtold("1e-4950")` returns 0,
although both are in range for x87 and binary128. `wcstold()` and `scanf("%Lf")` inherit this.

**Steps to reproduce.** `tools/haiku-tests/strtold.c` (glibc's test tables for binary128 and x87; Pi:
`tools/pi-tests/strtold.sh`, x86_64: `tools/x86-tests/libc.sh`), or simply `printf("%Lg\n", strtold("1e4000", NULL));`.

**Expected.** `1e+4000`, and full long double precision.
**Actual.** `inf`, and double precision.

**Root cause.** `strtold.c:25` / `:31`: `return __strtod_internal (nptr, endptr, ...);`

**Fix.** Instantiate glibc's strtod template for long double with `mpn2ldbl.c` (already built on x86_64, arm64, riscv64) (12eb998a63).

**Evidence.** QEMU arm64: 221 of 221 against glibc's expectations (99 failures before). Upstream hrev60314 on x86_64 fails dozens of checks (precision, `inf` for 1e4000, lost signs).

<a id="hk-66"></a>

#### HK-66 — libroot: strtod() family edge cases: lost signs, wrong NaN end, EDOM on underflow, no ERANGE on rounding overflow

- **Trac fields:** Component: `System/libroot` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug
- **Severity:** wrong output
- **Scope:** all architectures; the generic glibc strtod template behind strtod, strtof, strtold and the wcsto* versions
- **Our fix:** haiku-pi/haiku `rpi4` `73ba44df00` — "libroot: strtod: sign of -0 and -nan, nan() end, subnormal ties"; `69c0374b42` — "libroot: strtod: ERANGE and a signed zero on underflow to zero"; `c8c59043a7` — "libroot: strtod() family sets ERANGE when rounding overflows"
- **Patch:** attachable as-is, applied in that order
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/system/libroot/posix/glibc/stdlib/strtod.c:46, 218-219, 291-292, 625-633, 710, 857, 1036`, `stdlib/strtof.c:17`, `wcsmbs/wcstof.c:38`; Trac: not searched

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, QEMU and Raspberry Pi 4 Model B 4 GB; also upstream hrev60314 on x86_64 (KVM).

**Description.** Haiku's copy of the glibc template predates several glibc fixes:
- `strtod("-0")` and `strtod("-nan")` lose the sign.
- `nan(...)` leaves `*endptr` on the `)`.
- The NaN payload setter (`SET_MANTISSA`, `:46`) can produce a signalling NaN.
- `0x1p-1075` rounds up instead of to even.
- Underflow to zero sets EDOM, which C requires to be ERANGE, and drops the sign (`:218-219`).
- An overflow that happens only by rounding returns inf with errno 0 (`:291-292`). Example: `strtod("1.7976931348623159e308")`.

**Steps to reproduce.** `tools/haiku-tests/strtold.c` (strtod/strtof part), or `tools/x86-tests/libc.sh` on x86_64. Example:
`errno = 0; d = strtod("1.7976931348623159e308", NULL);`

**Expected.** `inf` with `errno == ERANGE`; `-0.0` for "-0"; ERANGE and a signed zero for "-1e-400".
**Actual.** `inf` with errno 0; `+0.0`; EDOM and `+0.0`.

**Root cause.** The lines listed above, for example `strtod.c:218` `__set_errno (EDOM);` and `:291` `if (exponent > MAX_EXP) return ...HUGE_VAL;` with no errno.

**Fix.** The three commits port the corresponding glibc behaviour.

**Evidence.** Upstream hrev60314 on x86_64 fails `-0`, `-nan`, `nan(0x123)`, `0x1p-1075` and the rounding-overflow checks; our tree passes them on x86_64 and arm64.

<a id="hk-67"></a>

#### HK-67 — runtime_loader: dynamic TLS blocks ignore the TLS segment's alignment (alignas(64) thread_local is misaligned)

- **Trac fields:** Component: `System/runtime_loader` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug
- **Severity:** wrong output (misaligned objects; undefined behaviour for SIMD and over-aligned atomic types)
- **Scope:** all architectures; generic `elf_tls.cpp`; fails on upstream x86_64
- **Our fix:** haiku-pi/haiku `rpi4` `4d433669a8` — "runtime_loader: align TLS blocks to their segment's alignment"
- **Patch:** with notes: it builds on our earlier static-TLS-block commit (c6cab6cc9e, arm64-motivated), whose alignment field it uses. For upstream it needs a short rewrite: record `p_align` in `elf_load_image.cpp`, then over-allocate and align in `TLSBlockTemplate::CreateBlock()` / `Destroy()`.
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/system/runtime_loader/elf_tls.cpp:88`, `elf_load_image.cpp:201-202`; Trac: not searched

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB; also upstream hrev60314 on x86_64 (KVM).

**Description.** A dynamic TLS block is allocated with `malloc()` from the runtime_loader heap, which aligns to 16
bytes. The PT_TLS segment's `p_align` is never recorded. A library's `alignas(64) thread_local` variable lands at an
offset of 16, 32 or 48 modulo 64.

**Steps to reproduce.** `tools/haiku-tests/tlsstatic.c`: a library with an `alignas(64) __thread` variable; print its
address modulo 64 from a thread.

**Expected.** 0.
**Actual.** `library aligned address % 64: 16, expected 0`.

**Root cause.** `elf_tls.cpp:88` `void* pointer = malloc(fMemorySize + TLS_DTV_OFFSET);`. `elf_load_image.cpp:201-202`
constructs the `TLSBlockTemplate` from `p_vaddr`, `p_filesz` and `p_memsz` only, without `p_align`.

**Fix.** Keep the segment's alignment in the template and align the block (4d433669a8).

**Evidence.** Upstream hrev60314 on x86_64: tlsstatic fails as above. Our tree passes on x86_64 and arm64.

<a id="hk-69"></a>

#### HK-69 — kernel: setrlimit() returns EINVAL when asked to set a limit to the value getrlimit() reports

- **Trac fields:** Component: `System/Kernel` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug
- **Severity:** wrong output (POSIX conformance; test suites and tools fail)
- **Scope:** all architectures; generic `thread.cpp`; fails on upstream x86_64
- **Our fix:** haiku-pi/haiku `rpi4` `f0a1d5f5cf` — "kernel: setrlimit() accepts the current value of a fixed limit"
- **Patch:** attachable as-is
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/system/kernel/thread.cpp:1487-1488`; Trac: not searched

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB; also upstream hrev60314 on x86_64 (KVM).

**Description.** `common_setrlimit()` handles only RLIMIT_NOFILE and RLIMIT_NOVMON. Every other resource returns EINVAL,
even when the caller asks for exactly the value `getrlimit()` reports (for example RLIMIT_CORE 0/0). Python's and
numpy's crash tests (which disable core dumps first) fail, and coreutils `timeout` warns "disabling core dumps failed".

**Steps to reproduce.** `tools/haiku-tests/setrlimit.c`, or:
1. `getrlimit(RLIMIT_CORE, &r);`
2. `setrlimit(RLIMIT_CORE, &r);`

**Expected.** 0.
**Actual.** -1, EINVAL. The same happens for RLIMIT_AS, DATA, FSIZE and STACK (6 failures in the test).

**Root cause.** `thread.cpp:1487-1488`: `default: return EINVAL;`

**Fix.** For the fixed limits, accept a request equal to the current value; anything else stays EINVAL (f0a1d5f5cf).

**Evidence.** Upstream hrev60314 on x86_64: setrlimit test fails with "EINVAL ×6". Our tree passes; numpy's test suite passes with the fix.

<a id="hk-70"></a>

#### HK-70 — Media Kit: BTimeSource conversions use a float and call debugger() when a time is more than 16.7 s from the last published one

- **Trac fields:** Component: `Kits/Media Kit` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug
- **Severity:** crash (the program stops in the debugger)
- **Scope:** all architectures; generic `TimeSource.cpp`
- **Our fix:** haiku-pi/haiku `rpi4` `c41702df18` — "media kit: time source conversions in double precision"
- **Patch:** attachable as-is
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/kits/media/TimeSource.cpp:173-178, 202-207`; Trac: not searched

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB.

**Description.** `BTimeSource::PerformanceTimeFor()` and `RealTimeFor()` scale the time since the last published time
by the drift in single precision. A float holds 2^24 µs (16.7 s) exactly. When the difference is larger than that and
the drift is not exactly 1.0, the code calls `debugger("... too large")`. This happens whenever a time source has
published nothing for 16.7 s, because it stalled or was restarted.

**Steps to reproduce.** Run a media producer (MediaPlayer playing a video) against a time source with drift ≠ 1.0 and
stall the time source's publishing for more than 16.7 s (e.g. heavy system load).
`tools/haiku-tests/tswatch.cpp` detects such stalls but does not trigger the call.

**Expected.** The conversion is computed.
**Actual.** "BTimeSource::PerformanceTimeFor: real time too large" in the debugger; the producer's team stops.

**Root cause.** `TimeSource.cpp:173` `if (real_time_difference >= (1 << FLT_MANT_DIG)) {` … `:178`
`debugger("BTimeSource::PerformanceTimeFor: real time too large");` and the same at `:202-207` in `RealTimeFor()`.

**Fix.** Do the conversion in double precision, which holds any span; drop the debugger() calls (c41702df18).

**Evidence.** MediaPlayer's video producer hit it once in a 15-minute soak (Firefox + SuperTuxKart + HEVC playback) on the Pi 4. That is a single occurrence, with no rate.

<a id="hk-78"></a>

#### HK-78 — xHCI: a physical transfer longer than 384 KiB is built over all vectors, not the current fragment ("Babble detected")

- **Trac fields:** Component: `Drivers/USB/XHCI` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug
- **Severity:** wrong output (the transfer fails with babble and transaction errors)
- **Scope:** all architectures and any xHCI controller (generic TRB construction). Reachable with usb_disk on media with 2048- or 4096-byte logical blocks (USB optical drives, 4Kn disks), where `MAX_IO_BLOCKS * block_size` exceeds `USB_MAX_FRAGMENT_SIZE`. Not reached with 512-byte media.
- **Our fix:** haiku-pi/haiku `rpi4` `e1d69f100f` — "xhci: Build a physical transfer's TDs from the current fragment only."
- **Patch:** attachable as-is
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/add-ons/kernel/busses/usb/xhci.cpp:1012, 1018, 1041`; Trac: not searched

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB (VL805), USB 3 stick, with usb_disk's I/O size raised to 1 MiB (not stock).

**Description.** A transfer longer than `USB_MAX_FRAGMENT_SIZE` (384 KiB) is submitted one fragment at a time.
`AdvanceByFragment()` sets the vectors used up to a length of 0, and the transfer is submitted again. For physical
vectors, `SubmitNormalRequest()` counts and builds TRBs over all vectors, not just the fragment. The first TD asks the
device for the whole transfer, and in the next TD each emptied vector becomes a 0-byte TRB. The device's data no longer
fits the TDs.

**Steps to reproduce.** On a USB disk with 4096-byte logical sectors (or a USB CD/DVD drive with 2048-byte blocks), read
the raw device with `dd bs=1M`. On a 512-byte stick this needs usb_disk's `MAX_IO_BLOCKS` raised to 2048
(`tools/pi-tests/usbcheck.sh`).

**Expected.** The data is read.
**Actual.** "Babble detected" and "USB transaction" errors; the read returns 0 bytes.

**Root cause.** `xhci.cpp:1012` `for (size_t i = 0; i < transfer->VectorCount(); i++) {` counts TRBs over every vector,
and `:1041` `trbLength = transferVec->length - transferVecOffset;` builds them the same way, instead of covering
`FragmentLength()` bytes.

**Fix.** Build the TRBs from the first vector that is not used up, for `FragmentLength()` bytes (e1d69f100f).

**Evidence.** Pi 4 (1 MiB I/O): failed at once before; 97.2 MB/s sequential, 88.3 MB/s random after, no errors. Not reproduced on stock upstream media or on x86.

<a id="hk-62"></a>

#### HK-62 — EFI boot loader: any load option whose key is not two characters long hangs the loader in an endless loop

- **Trac fields:** Component: `System/Boot Loader/EFI` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug
- **Severity:** hang (at boot)
- **Scope:** all EFI architectures (x86_64, arm64, riscv64, arm). It runs on every EFI boot whose firmware offers the
  Simple Network Protocol, not only network boots: `platform_add_boot_device()` always calls `net_stack_init()` (`efi/devices.cpp:153`).
- **Our fix:** haiku-pi/haiku `rpi4` `d8dfb51d8d` — "boot/efi: "ip=": skip other load options, pass the net mask on"
- **Patch:** with notes: the loop fix is a one-line hunk that applies as-is. The same commit also passes the net mask from `ip=` (a feature), so split it.
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/system/boot/platform/efi/network.cpp:182-183`; Trac: not searched

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB, U-Boot `bootefi` (it passes `bootargs` as the load options).

**Description.** `EFIEthernetInterface::Init()` scans the loader's load options for `ip=`. On every `=` it checks the
key's length, and if the length is not 2 it executes `continue`. That skips the `ptr++` at the end of the loop body, so
the loop stays on the same `=` forever. A load option string with no `=` at all, or only `ip=...`, works. Anything
like `console=ttyAMA0` or `foo=bar` hangs the boot.

**Steps to reproduce.**
1. Use firmware with a network device (SNP), e.g. QEMU + OVMF with a NIC, or U-Boot.
2. From the UEFI shell run `haiku_loader.efi foo=bar`. With U-Boot: `setenv bootargs console=ttyAMA0`, then `bootefi`.
   (The x86 procedure is inferred from the code and was not run.)

**Expected.** The option is ignored and the loader continues.
**Actual.** The loader hangs after "EFI reports network available".

**Root cause.** `network.cpp:182-183`: `if (ptr - base != 2) continue;`, inside `while (*ptr != '\0')`, whose `ptr++` is at `:196`.

**Fix.** Advance past the `=` before continuing (d8dfb51d8d).

**Evidence.** Pi 4 with U-Boot: before the fix only `ip=` alone in the load options worked, and any other key made the loader loop forever. With the fix it boots with a full `bootargs`. Not tried on x86.

<a id="hk-74"></a>

#### HK-74 — network boot: no wait for the link, and unloading unused boot modules deadlocks when one is needed later

- **Trac fields:** Component: `System/Kernel` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug
- **Severity:** hang (the desktop never comes up on a network boot) / boot failure ("Network is down")
- **Scope:** all architectures that boot from the network (x86 PXE, EFI); generic VFS and module code
- **Our fix:** haiku-pi/haiku `rpi4` `cea07d5468` — "kernel/vfs: net boot: wait for the link, keep the network modules loaded"
- **Patch:** attachable as-is
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/system/kernel/fs/vfs_net_boot.cpp:346` (no link wait after `initializer.Init()`), `src/system/kernel/module.cpp:1851-1868` (unused pre-loaded modules dropped); Trac: not searched

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB booting over TFTP + remote_disk.

**Description.** There are two problems:
- **No wait for the link.** Once the boot interface is configured, the remote disk's first request goes out at once.
  An Ethernet PHY that only starts negotiating when the device is opened has no link yet, so the request fails with
  "Network is down" and the boot volume is not found.
- **Deadlock after module unload.** After the boot volume is mounted, `module_init_post_boot_device()` drops the image of
  every pre-loaded module that is not in use. A network module needed later then has to be read from the boot volume,
  that is, through the network stack. Each step holds a lock the next one needs:
  1. `getaddrinfo()` (from Time) held an interface's lock while the stack loaded a datalink protocol for another domain.
  2. That load read the module from the remote disk.
  3. The remote disk's current reader waited for the interface.

**Steps to reproduce.** Network-boot an image (remote_disk) on hardware whose NIC renegotiates the link when opened, and
let the desktop start (Time and other network clients run at once). Coordination repo: `scripts/netboot-cycle.sh`.

**Expected.** The boot volume is found, and the desktop comes up.
**Actual.** "Network is down" on the first remote disk read, or a boot that stops with the desktop never shown (three threads blocked as above).

**Root cause.** `vfs_net_boot.cpp:346` `status = initializer.Init();` is not followed by a wait for `IFF_LINK`;
`module.cpp:1867-1869` clears `module_image` for every unused pre-loaded module, the network modules included.

**Fix.** Wait up to 20 s for the link; keep the pre-loaded network modules (cea07d5468).

**Evidence.** Pi 4 network boot: both failures were observed (first-read "Network is down"; desktop never up, with the three threads blocked as described) and are gone with the fix. They were found one after another during bring-up; neither was shown to fail alone on an upstream image.

<a id="hk-75"></a>

#### HK-75 — remote_disk: partitions cannot be opened, so no file system on a remote disk is ever found

- **Trac fields:** Component: `Drivers/Disk` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug
- **Severity:** crash (booting from a partitioned remote disk panics: "did not find any boot partitions")
- **Scope:** all architectures; generic driver, shipped upstream in the net boot archive
- **Our fix:** haiku-pi/haiku `rpi4` `a082ab4d4e` — "remote_disk: open the partitions of the disk too"
- **Patch:** attachable as-is (also fixes trace format strings that do not compile on 64-bit when `TRACE_REMOTE_DISK` is enabled)
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/add-ons/kernel/drivers/disk/virtual/remote_disk/remote_disk.cpp:127`; Trac: not searched

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB booting over the network.

**Description.** devfs opens a partition through the disk's driver, under the partition's own name, e.g.
`disk/virtual/remote_disk/0/1`. remote_disk's `open` hook only accepts its exact published names (`.../0/raw`), so
every partition open fails. No file system on a partitioned remote disk is identified, and a network boot from one
panics. An unpartitioned BFS image works.

**Steps to reproduce.** Serve a partitioned Haiku image with the remote disk server and network-boot it (coordination repo: `scripts/netboot-server.sh`, `scripts/netboot-cycle.sh`).

**Expected.** The BFS partition is found and booted.
**Actual.** "did not find any boot partitions" panic.

**Root cause.** `remote_disk.cpp:127` `if (strcmp(name, kPublishedNames[i]) == 0)`. That is an exact match, while a partition name only starts with the disk's name.

**Fix.** Everything up to the last `/` names the disk (a082ab4d4e).

**Evidence.** Pi 4 network boot: panicked before the fix, boots after.

<a id="hk-76"></a>

#### HK-76 — net_server: starts DHCP on the interface a network boot runs over, which can take its address away

- **Trac fields:** Component: `Servers/net_server` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug
- **Severity:** hang (the boot volume becomes unreachable when DHCP fails or gives another address)
- **Scope:** all architectures, network boots only
- **Our fix:** haiku-pi/haiku `rpi4` `cb0f2f9884` — "net_server: leave the interface of a network boot as it is"; `444704d5f1` — "net_server: leave a configured interface alone only on a network boot" (corrects a regression of the first on disk boots)
- **Patch:** with notes: send the two squashed; other commits of ours touch `NetServer.cpp`, so expect offsets
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/servers/net/NetServer.cpp:719-722, 765` (no check for a network boot); Trac: not searched

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB booting over the network; the second commit was checked on x86_64 under QEMU.

**Description.** On a network boot the kernel configures the boot interface itself. net_server then configures every
device again, and starts DHCP on that interface. If DHCP fails, `AutoconfigLooper::_ConfigureIPv4Failed()` assigns a
link-local address; a lease for a different address does the same damage. In both cases the address the boot volume
is reached through disappears.

**Steps to reproduce.** Network-boot with a statically assigned `ip=` address on a link without a DHCP server, or whose
DHCP server hands out a different address.

**Expected.** The boot interface keeps its address.
**Actual.** It gets a link-local or a different address, and every later read of the boot volume fails.

**Root cause.** `NetServer.cpp:719-722` and `:765` call `_ConfigureInterface()` for every device, without regard to the boot method.

**Fix.** On a network boot, leave an interface that already has an IPv4 address alone (cb0f2f9884 + 444704d5f1).

**Evidence.** Pi 4 network boots keep the boot address with the fix. The failure is derived from the code paths (DHCP failure → link-local); no count. The x86_64 QEMU disk boot still gets DHCP after a net_server restart (444704d5f1).

<a id="hk-81"></a>

#### HK-81 — bluetooth_server: NULL dereference on a disconnection event for an unknown handle; PIN windows never closed

- **Trac fields:** Component: `Network & Internet/Bluetooth` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug
- **Severity:** crash (bluetooth_server)
- **Scope:** all architectures, any HCI transport
- **Our fix:** haiku-pi/haiku `rpi4` `3cad4e2996` — "bluetooth_server: close a pairing's PIN code window when the pairing is over"
- **Patch:** attachable as-is (the NULL check could be split out)
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/servers/bluetooth/LocalDeviceImpl.cpp:1603-1607, 1619`; Trac: not searched

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB, on-board Bluetooth over UART; BlueZ peer.

**Description.** There are two problems:
- **NULL dereference.** `DisconnectionComplete()` looks up the remote device by handle and checks the result for NULL
  only around `AddData()`. It then sets `rd->conn_state` unconditionally, so a disconnection-complete event for a handle
  the server does not know crashes bluetooth_server.
- **PIN windows pile up.** Each PIN code request opens a new `PincodeWindow` and nothing closes it when the pairing ends
  or fails, so stale PIN windows accumulate.

**Steps to reproduce.**
1. Start a pairing from a BlueZ host and let it fail or time out: the PIN window stays open.
2. Repeat: one more window each time.
The NULL dereference needs a disconnection-complete event for a handle the server does not know about.

**Expected.** No crash; the PIN window closes when the pairing is over.
**Actual.** bluetooth_server crashes in `DisconnectionComplete()`; stale PIN windows remain open.

**Root cause.** `LocalDeviceImpl.cpp:1603` `if (rd != NULL)` covers only `AddData()`; `:1607` `rd->conn_state = RemoteDevice::DISCONNECTED;`. `:1619` `new PincodeWindow(...)`, never closed.

**Fix.** Guard the state change; keep the window per pairing and close it on completion (3cad4e2996).

**Evidence.** Pi 4 with a BlueZ peer: failed pairings left one window per attempt before the fix; with it, the window closes on pairing or disconnect (no count recorded). The NULL dereference was found by reading the code.

<a id="hk-71"></a>

#### HK-71 — Debugger (CLI): `bt` waits for the stack trace with the team locked, so it hangs right after a stop

- **Trac fields:** Component: `Applications/Debugger` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug
- **Severity:** hang (the CLI Debugger)
- **Scope:** all architectures; generic CLI code
- **Our fix:** haiku-pi/haiku `rpi4` `8a65ea1c6d` — "Debugger: The command line's stop waits for the stop; bt waits unlocked."
- **Patch:** with notes: applies as-is, but it also makes `stop` wait until the thread has stopped (a behaviour change). Split it if only the deadlock fix is wanted.
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/apps/debugger/user_interface/cli/commands/CliStackTraceCommand.cpp:34, 48-49`; Trac: not searched

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB.

**Description.** `bt` locks the team and then, while still holding the lock, waits for
`MSG_THREAD_STACK_TRACE_CHANGED`. Computing the stack trace needs the team lock: `GetStackTraceJob` takes
`AutoLocker<Team>` before `SetStackTrace()` (`GetStackTraceJob.cpp:71-74`), and so does
`ThreadHandler::HandleCpuStateChanged()`. If `bt` runs after the thread has stopped but before its stack trace exists,
it waits forever. A second problem: `stop` returns at once, so a scripted `bt` that follows it usually reports
"Current thread is not stopped".

**Steps to reproduce.** Run
`(echo "thread <tid>"; echo stop; echo bt; echo quit) | Debugger --cli <program in a busy loop>`
a few times.

**Expected.** A stack trace.
**Actual.** "Current thread is not stopped" or, when the timing hits the window, the Debugger hangs in `bt`.

**Root cause.** `CliStackTraceCommand.cpp:34` `AutoLocker<Team> teamLocker(team);` held across `:48-49`
`while (stackTrace == NULL) { context.WaitForEvent(CliContext::MSG_THREAD_STACK_TRACE_CHANGED);`

**Fix.** Wait with the team unlocked; make `stop` wait for the thread state change (8a65ea1c6d).

**Evidence.** Pi 4: a scripted `thread`/`stop`/`bt`/`quit` against a busy shell gave full stacks 3 of 3 times with the fix. No rate was measured before the fix.

<a id="hk-72"></a>

#### HK-72 — Debugger: version 5 line number program headers are read off by one (files and directories) and fail on more than 127 entries

- **Trac fields:** Component: `Applications/Debugger` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug
- **Severity:** wrong output (source shown from the wrong file or directory; declarations in the wrong file)
- **Scope:** code: all architectures. Shown on arm64, where GCC 13 and 16 write version 5 line tables inside DWARF 4 units of libstdc++ (215 of 216). Whether x86_64's libstdc++ has the same mix is unverified (`readelf --debug-dump=rawline` would settle it). On stock Haiku, DWARF 5 units are rejected before this code runs (HK-64).
- **Our fix:** haiku-pi/haiku `rpi4` `65cae45a13` — "Debugger: fix DWARF 5 line number program headers"
- **Patch:** with notes: it shares `DwarfFile.cpp` and `CompilationUnit.*` with d2d2349f2c (HK-64), so it probably needs a rebase if sent alone
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/kits/debugger/dwarf/DwarfFile.cpp:1540, 2141, 2184, 2242, 2287`, `src/kits/debugger/dwarf/DwarfUtils.cpp:284`, `src/kits/debugger/dwarf/LineNumberProgram.cpp:211`; Trac: searched "Debugger DWARF 5": blocked by the bot check (no result)

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, QEMU and Raspberry Pi 4 Model B 4 GB; host builds of the Debugger's DWARF reader on Linux.

**Description.** The v5 header code added by 006478bfce (2023) has these problems:
- **Files off by one.** Version 5 numbers file entries from 0, while versions 2–4 number them from 1. The reader stores
  them from index 0 and still resolves file N as `FileAt(N - 1)`, so every row's file and every `DW_AT_decl_file` names
  the entry before the right one.
- **Directories off by one.** `_FinishUnit` adds the compilation directory and the v5 header adds directory 0 (the same
  directory) again, so every directory index is shifted by one.
- **Counts read as single bytes.** The directory and file counts are read as one byte instead of ULEB128, which breaks
  at more than 127 entries (common in C++).
- **Unknown fields fail the table.** Any field other than path and MD5 makes the whole table fail.
- **Program size ignores padding.** The program size does not account for the header's padding.

Two smaller related defects are fixed on top of it:
- a36ea1ed3b, "Debugger: line number program directories relative to the compilation directory". Applies to clang
  output only. clang names include directories relative to the compilation directory; they are used as given, so the
  sources are not found.
- 1b4e49fd6c, "Debugger: one file for DWARF 4 line table entries with the same path". Applies only with
  `-fdebug-prefix-map`. GCC lists the primary file twice, and `_GetSourceFileIndex()` returns only the first match, so the
  function has no source lines.

**Steps to reproduce.** No Haiku needed: `tools/dwarf-host/run-tests.sh <tree> <base tree>` builds the Debugger's DWARF
reader as a host `dwarfdump` and compares every line-table row and every declaration with llvm-dwarfdump. Point the
base tree at upstream to see the failures. On Haiku: debug a program using `std::thread` and look at libstdc++'s `thread.cc` frame.

**Expected.** The rows and declarations match llvm-dwarfdump.
**Actual.** 4,758 of libstdc++'s 4,933 declarations are placed in the wrong file (359,695 differing row lines), and
`thread.cc` is shown one directory off (under `obj/`).

**Root cause.** `DwarfFile.cpp:2141` / `:2184` `uint8 dirCount = dataReader.Read<uint8>(0);` / `uint8 fileNameCount = ...`;
`:2242` `unit->AddFile(fileName, dirIndex)` for 0-based entries; `:1540` adds the compilation directory again;
`DwarfUtils.cpp:284` `unit->FileAt(file - 1, &directoryName)`; `LineNumberProgram.cpp:211` `state.file = 1;`;
`:2287` `programSize = unitLength - (readerOffset - unitOffset)`.

**Fix.** Map file numbers through the unit (`FileIndex()`), read the counts as ULEB128, skip unknown fields, and account for the padding (65cae45a13).

**Evidence.** Host: 0 differing rows and declarations against llvm-dwarfdump after the fix, for GCC 13, GCC 16 and clang, DWARF 4 and 5 (47 of 47 checks).

<a id="hk-64"></a>

#### HK-64 — Debugger: DWARF 5 compilation units are rejected, but the system GCC writes DWARF 5 by default (no source-level debugging)

- **Trac fields:** Component: `Applications/Debugger` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug
- **Severity:** wrong output (no source lines or variables for programs built with plain `gcc -g`)
- **Scope:** all architectures. Upstream buildtools' GCC 13.3.0 defaults to DWARF 5 (`gcc/gcc/defaults.h:1447` `#define DWARF_VERSION_DEFAULT 5`); Haiku's target headers (`config/haiku.h`, `i386/haiku64.h`, `aarch64/aarch64-haiku.h`) do not override it, and build/jam uses `-ggdb`, which does not lower it.
- **Our fix:** haiku-pi/haiku `rpi4` `d2d2349f2c` — "Debugger: read DWARF 5 units"
- **Patch:** with notes: a useful result needs the series d2d2349f2c + 4588cddb87 ("Debugger: DWARF 5 range and location lists") + b67b55acf7 ("Debugger: DWARF 5 expression operations") + 6c71603f62 ("Debugger: know the C and C++ language codes of DWARF 5") + 65cae45a13 (HK-72)
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/kits/debugger/dwarf/DwarfFile.cpp:1005, 1034-1037, 1119`; Trac: searched "Debugger DWARF 5": blocked by the bot check (no result)

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB and QEMU arm64; host checks of the Debugger's DWARF reader on Linux against llvm-dwarfdump.

**Description.** `DwarfFile` accepts only unit versions 2–4. A version 5 unit makes it log "Unsupported compilation
unit version: 5" and `break` out of the loop, which also drops every later unit in the file. A DWARF 5 unit of
another type than DW_UT_compile (partial, type) fails the whole file with `B_UNSUPPORTED`. Programs built on Haiku
with `gcc -g` get symbols only: stack frames as `function + offset`, no file:line and no variables.

**Steps to reproduce.**
1. `gcc -g -O0 -o dbgtarget tools/haiku-tests/dbgtarget.c`
2. Run it in the Debugger and stop it in `add3()` (GUI: set a breakpoint on the function; CLI: `Debugger --cli ./dbgtarget`, then `save-report` once it has stopped). Look at the stack frames and variables.

**Expected.** Frames with file:line and variables.
**Actual.** Frames `add3 + 0`, `twice + 0x10`, `main + 0x18`; "No variables available"; syslog: "Unsupported compilation unit version: 5".

**Root cause.** `DwarfFile.cpp:1034` `if (version < 2 || version > 4) {` … `break;`; `:1005` `return B_UNSUPPORTED;` for unit types other than DW_UT_compile; `:1119` `if (version > 4)` for type units.

**Fix.** Parse DWARF 5 unit headers and unit types, plus rnglists, loclists, the new forms and the new operations (the series above).

**Evidence.**
- Host: 47 of 47 checks against llvm-dwarfdump (GCC 13, GCC 16, clang; DWARF 4 and 5), with `tools/dwarf-host/run-tests.sh`.
- libstdc++: 216 of 216 units load, against 189 before.
- QEMU: Debugger sessions on `-gdwarf-4` and `-gdwarf-5` builds of the same program give identical output (C: 20/20 CLI lines).

<a id="hk-86"></a>

#### HK-86 — ICMPv6: the new icmp6_error_reply() writes the MTU and pointer in host byte order and misreads RFC 4443 2.4 (e.3, e.6)

- **Trac fields:** Component: `Network & Internet/IPv6` · Version: R1/beta5 (nightly hrev60450) · Platform: All · Type: bug
- **Severity:** wrong output (latent for the byte order: no IPv6 caller passes the data yet)
- **Scope:** all architectures; the byte-order mistakes show on every little-endian CPU (x86, x86_64, arm64)
- **Our fix:** none (we kept our own implementation, 25c9881600)
- **Patch:** no: our 25c9881600 is an alternative implementation of the same function, written before upstream's; the fixes are a line each against upstream's code
- **Upstream status (2026-11-20):** open: introduced by 5119a99783 ("icmp6: implement icmp6_error_reply() similar to icmp", committed 2026-11-19, hrev60438), unchanged at hrev60450, `src/add-ons/kernel/network/protocols/icmp6/icmp6.cpp:513-515, 547, 550, 562`; Trac: searched `q=icmp6`: blocked by the bot check (no result)

**Environment.** Code reading, while merging upstream into our tree (hrev60431). Not run.

**Description.** These are the problems in upstream's new `icmp6_error_reply()`:
1. **Packet Too Big MTU stored with `htons` into a 32-bit field:** `icmpHeader->icmp6_mtu = htons(errorData->mtu);`
   (`:550`; `icmp6_mtu` is `icmp6_data32[0]`, `headers/posix/netinet/icmp6.h:88`). An MTU of 1280 goes out as 83886080.
2. **Parameter Problem pointer not byte-swapped:** `icmpHeader->icmp6_pptr = errorData->error_offset;` (`:547`).
   Items 1 and 2 are latent: no IPv6 caller passes `errorData` yet.
3. **`ip6_plen` used in network byte order:** `std::min(sizeof(ip6_hdr) + 8, sizeof(ip6_hdr) + header.ip6_plen)` (`:562`).
   The header comes raw from `restore_header()`. The only effect: a payload shorter than 8 bytes makes the append fail
   instead of copying less.
4. **A code compared against the type:** `&& icmpType != ICMP6_PARAMPROB_OPTION` (`:515`). `ICMP6_PARAMPROB_OPTION` is the code 2,
   the same value as the type `ICMP6_PACKET_TOO_BIG`, so the test does nothing. RFC 4443 2.4 e.3 allows a Parameter
   Problem to a multicast destination only for code 2, but every one is sent.
5. **No source check (RFC 4443 2.4 e.6):** errors are sent to multicast and unspecified sources.
- The checksum without the pseudo-header (`:570`) is not a bug: `ipv6_send_routed_data()` recomputes ICMPv6 checksums with the pseudo-header (`ipv6.cpp:1326-1342`).

**Steps to reproduce.** Items 1 and 2: any caller that passes `B_NET_ERROR_MESSAGE_SIZE` or
`B_NET_ERROR_PARAMETER_PROBLEM` with `errorData`. Item 4: a datagram to a multicast group that triggers a Parameter
Problem. Item 5: not run.

**Expected.** `htonl()` values; no error for a multicast or unspecified source; Parameter Problem to multicast only for code 2.
**Actual.** As listed.

**Root cause.** The lines cited above.

**Fix.** `htonl()` for `icmp6_mtu` and `icmp6_pptr`; `ntohs(header.ip6_plen)`; compare the code within `ICMP6_PARAM_PROB`;
return early for a multicast or unspecified `ip6_src`. Our 25c9881600 does these (`htonl`, `ntohs`, `IN6_IS_ADDR_MULTICAST(&header.ip6_src)`).

**Evidence.** Code reading only. Our implementation has run since 2026-10-24.

<a id="hk-33"></a>

#### HK-33 — build: Haiku does not build with GCC 16 (C++20/C23 defaults); FileTypes calls a member function on an unconstructed object

- **Trac fields:** Component: `Build System` · Version: R1/beta5 (nightly hrev60431) · Platform: All · Type: bug. Haiku's bug-report guide says build problems go to the development mailing list, not Trac, so send it there or as Gerrit changes.
- **Severity:** build
- **Scope:** all architectures, with GCC ≥ 15/16 (upstream's buildtools currently ship GCC 13)
- **Our fix:** haiku-pi/haiku `rpi4` `3c641a2b01` — "build: compile C++ as C++17 with GCC"; `f21e11d138` — "kernel, boot: compile zlib as C17"; `2d0aac976e` — "headers: name structs with member functions that have a typedef name"; `29a820de6e` — "FileTypes: make the windows' _Frame() static"
- **Patch:** with notes: `f21e11d138`, `2d0aac976e` and `29a820de6e` apply as-is. `3c641a2b01` conflicts in `build/jam/ArchitectureRules` with our other build changes; the change itself adds `-std=gnu++17` for GCC ≥ 16 (not Clang or the legacy GCC).
- **Upstream status (2026-11-20):** open: unchanged at hrev60450: `build/jam/ArchitectureRules` has no `-std=` pin; `src/system/kernel/lib/zlib/Jamfile` and `src/system/boot/libs/Jamfile` have no `-std=gnu17` for zlib's K&R definitions; `headers/os/kernel/elf.h:49, 70, 238, …` keep unnamed `typedef struct {` with member functions; `src/preferences/filetypes/FileTypesWindow.h:47` (and the two ApplicationType windows) call a non-static `_Frame()` in the `BWindow` base initialiser. Trac: not searched (build issues do not belong there).

**Environment.** Cross build for arm64 (and x86_64) with GCC 16.2.

**Description.** GCC 16 defaults to C++20 and C23. About 420 compiles of the minimum image fail:
- enum arithmetic, `++` on volatiles, implicit `this` capture, reversed comparison operators, mixed designated initialisers, `requires` as a name;
- K&R zlib under C23;
- `-Wnon-c-typedef-for-linkage` on elf.h and USB_video.h structs.

Separately from the compiler, FileTypes calls `_Frame()` on an object not yet constructed (undefined behaviour). GCC 16 reports it with `-Wmaybe-uninitialized`.

**Steps to reproduce.**
1. Build `@minimum` with a GCC 16 cross compiler.

**Expected.** The image builds.
**Actual.** About 420 compile errors.

**Root cause.** The dialect defaults, plus the source issues above.

**Fix.** Pin `-std=gnu++17` for GCC; compile zlib as gnu17; give the typedef'd structs a tag of the same name (same linkage name, no ABI change); make `_Frame()` static (it uses nothing of the object).

**Evidence.** Our arm64 and x86_64 images build with GCC 16.2 (default toolchain of the fork since 2026-11-02).

### 1.2 Architectures other than x86, and DMA without cache snooping

<a id="hk-63"></a>

#### HK-63 — PCI: on non-x86, every I/O-space BAR gets host address 0, so devices with I/O BARs all drive port 0

- **Trac fields:** Component: `Drivers/PCI` · Version: R1/beta5 (nightly hrev60431) · Platform: arm64 · Type: bug
- **Severity:** data corruption (I/O errors: one device's register writes reach another device)
- **Scope:** arm64 (any board), and every other non-x86 architecture with PCI (riscv64). The x86 branch of `pci_ram_address()` already returns the port.
- **Our fix:** haiku-pi/haiku `rpi4` `cafef4f9bb` — "pci: an I/O port BAR's host address is its port"
- **Patch:** attachable as-is
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/add-ons/kernel/bus_managers/pci/pci.cpp:131-138, 1552`; Trac: searched `q=pci+I%2FO+BAR+arm64`: blocked by the bot check (no result)

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, QEMU `virt` with EDK2 (not the Pi).

**Description.** `PCI::_GetBarInfo()` passes I/O BARs through `pci_ram_address()` too. Outside x86 that function
looks only at `B_IO_MEMORY` ranges, finds none for an I/O-space address, and returns 0. Drivers that use
`read_io`/`write_io` (which map PCI I/O space through the controller's I/O window themselves) therefore all drive
port 0. On QEMU's arm64 virt machine, legacy virtio-blk-pci (I/O BAR at port 0) and virtio-net-pci (port 0x80) both
used port 0. virtio-net's reset stopped the disk, and every read after it failed with an I/O error.

**Steps to reproduce.**
1. Boot an arm64 image on `qemu-system-aarch64 -M virt` with EDK2, a virtio-blk-pci disk in legacy mode and the default virtio-net-pci NIC (coordination repo: `scripts/qemu-virt.sh --blk pci`).
2. Wait for the NIC driver to be published.

**Expected.** Both devices work.
**Actual.** Disk reads fail with I/O errors after virtio-net is published. With `-nic none` the boot is clean.

**Root cause.** `pci.cpp:1552` `uint64 ramAddress = pci_ram_address(pciAddress);` runs for I/O BARs as well (`:1531`).
`pci_ram_address()` (`:131-138`) starts from `hostAdr = 0` and only does a `LookupRange(B_IO_MEMORY, ...)` outside x86.

**Fix.** For an I/O BAR, the host address is the port itself (cafef4f9bb).

**Evidence.** QEMU arm64 virt: I/O errors on every boot with both devices before the fix; 0 errors and a boot to the desktop after it.
x86_64 is unchanged by the fix: legacy virtio-scsi plus virtio-net with I/O BARs passed under UEFI.

<a id="hk-77"></a>

#### HK-77 — FDT bus manager: "reg" addresses are not translated through the parent buses' "ranges"

- **Trac fields:** Component: `System/Kernel` · Version: R1/beta5 (nightly hrev60431) · Platform: arm64 · Type: bug
- **Severity:** wrong output (drivers map the wrong physical address)
- **Scope:** arm64 (any board), and every FDT platform (arm, riscv64). It is latent on upstream's current targets: QEMU virt puts devices directly under the root, and the riscv boards use identity `ranges;`.
- **Our fix:** haiku-pi/haiku `rpi4` `1c9c78289e` — "fdt: translate "reg" addresses through the parent buses' "ranges""
- **Patch:** attachable as-is
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/add-ons/kernel/bus_managers/fdt/fdt_module.cpp:443, 446` (`fdt_device_get_reg()` returns the address as written); Trac: not searched

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB (BCM2711 device tree).

**Description.** `fdt_device_get_reg()` returns a node's `reg` address as written. That is a CPU physical address only for
children of the root. On any SoC whose buses remap addresses, every driver maps the wrong address. On the Pi 4,
`/soc` maps VideoCore bus addresses 0x7exxxxxx to 0xfexxxxxx, and `emmc2bus` and `/scb` have their own windows.

**Steps to reproduce.** Boot with a device tree whose `/soc` (or any bus) has a non-identity `ranges` property and let a driver map its `reg`.

**Expected.** The CPU physical address (e.g. 0xfe340000 for the Pi 4's emmc2).
**Actual.** The bus address (0x7e340000); the driver reads unmapped or wrong memory.

**Root cause.** `fdt_module.cpp:443` / `:446` `*regs = fdt32_to_cpu(...)` / `fdt64_to_cpu(...)`, with no translation step. Nothing in the kernel parses `ranges` except the PCI host drivers, for their own children.

**Fix.** Walk up the tree and apply each memory-mapped bus's `ranges`; a bus without `ranges` (I2C, say) is not memory mapped, and its children's addresses are returned unchanged (1c9c78289e).

**Evidence.** Every Pi 4 peripheral driver of ours depends on it. There is no standalone reproducer.

<a id="hk-80"></a>

#### HK-80 — xHCI and usb_disk: no cache maintenance for physical (direct I/O) transfers on controllers that do not snoop

- **Trac fields:** Component: `Drivers/USB/XHCI` · Version: R1/beta5 (nightly hrev60431) · Platform: arm64 · Type: bug
- **Severity:** data corruption (stale reads, wrong data written)
- **Scope:** non-snooping DMA platforms only: arm64 SoCs whose PCIe/USB is not cache-coherent. Not x86, and not coherent arm64 such as QEMU virt. No upstream PCI host driver covers such a platform today.
- **Our fix:** haiku-pi/haiku `rpi4` `eabad7a921` — "xhci: cache maintenance for physical transfers on arm64"; `b90cb3f0d4` — "usb_disk: keep buffers cache-line aligned on arm64"
- **Patch:** no: needs rework. It assumes every arm64 system is non-coherent (`#if defined(__aarch64__)`; the coherency should come from the bus); it depends on our arm64 cache-maintenance helpers and on our non-cacheable USB buffers; and `b90cb3f0d4`'s context includes our `max_segment_count` change.
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/add-ons/kernel/busses/usb/xhci.cpp:1137` (no clean before `_LinkDescriptorForPipe`), `:3207` (`!transfer->IsPhysical()`: no invalidate for physical transfers), `usb_disk.cpp:956-961` (no alignment restriction); Trac: not searched

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB (BCM2711 PCIe → VL805, not cache-coherent).

**Description.** usb_disk passes the I/O request's own pages to the xHCI driver ("physical" transfers). Nothing cleans
the CPU caches before the controller reads those pages, or invalidates them after it writes. Buffers are also not
aligned to cache lines, so a neighbouring write in the same line can undo an invalidate. On a non-coherent platform:
- reads return stale data, 64 bytes at a time;
- writes store stale memory;
- the same 1 MiB read three times gave three different checksums;
- about 10% of written sectors were wrong;
- a freshly made BFS did not mount ("invalid superblock").

**Steps to reproduce.** On a non-coherent arm64 board with an xHCI controller: read a USB disk's raw device repeatedly and compare checksums (`tools/pi-tests/usb-integrity.sh`); `tools/haiku-tests/usbalign.c` (unaligned read while a neighbouring thread writes the same cache lines).

**Expected.** Identical checksums, matching another OS.
**Actual.** Different checksums each time; corrupted writes.

**Root cause.** The physical path in `xhci.cpp` (`:1137`, `:3207`) has no cache maintenance, and `usb_disk.cpp:956-961` sets no alignment restriction.

**Fix.** Clean before and invalidate after physical transfers; ask the DMA resource for cache-line alignment (eabad7a921, b90cb3f0d4). For upstream this should be driven by a bus "coherent DMA" property, not by `__aarch64__`.

**Evidence.** Pi 4 after the fix: repeated raw reads identical to what Linux reads; data written by Haiku verified under Linux; 329 MB of BFS files intact across a remount, and checkfs clean.

### 1.3 arm64 (any board)

<a id="hk-01"></a>

#### HK-01 — kernel/arm64: an undefined instruction, BRK or SP-alignment fault in a user program panics the kernel

- **Trac fields:** Component: `System/Kernel` · Version: R1/beta5 (nightly hrev60431) · Platform: arm64 · Type: bug
- **Severity:** security (any unprivileged program can panic the kernel: local denial of service)
- **Scope:** arm64 (any board); arm64 code only
- **Our fix:** haiku-pi/haiku `rpi4` `cdd63d4b62` — "arm64: classify unhandled user exceptions and log them"
- **Patch:** with notes: applies cleanly to hrev60450, but it only covers EC 0x00 (unknown/undefined instruction) and the `!known` data-abort path. Our tree handles BRK (EC 0x3c) and MSR/MRS traps (EC 0x18) in other fork commits (`f753f072d8` user debugging, `7225a5f244` ID-register emulation). It still panics on EL0 SP-alignment faults (EC 0x26) itself. The complete fix is to send SIGILL/SIGBUS to an EL0 thread for every class, not to call `panic()` in `default:` when `isUser`.
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/system/kernel/arch/arm64/arch_int.cpp:390-391` (`default: panic("unhandled exception: …")`, added by 1174518150, hrev60333) and `:319-320` (`if (!known) break;` with `signalNumber`/`signalCode` uninitialised, declared at `:262-264`). Trac: searched "unhandled exception" and "arm64 panic": no matching ticket.

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB (Cortex-A72, ARMv8.0).

**Description.** `do_sync_handler()` handles only PC-alignment, instruction/data aborts and SVC. Since hrev60333 every other exception class reaches `default: panic()`, whether it came from EL0 or EL1. Several are routine in user programs:
- undefined instruction (EC 0x00), including an `MRS` of an ID register on an ARMv8.0 core;
- `BRK` (EC 0x3c), which GCC emits for `__builtin_trap()`;
- SP-alignment fault (EC 0x26; SCTLR_EL1.SA0 is set by the loader).

Before hrev60333 the same exceptions fell through with `signalNumber` uninitialised, so the thread got whatever signal the register held. A data abort with a fault-status code the switch does not know (for example an alignment fault, DFSC 0x21) still does that today.

**Steps to reproduce.**
1. Build `int main(void) { __asm__ volatile("udf #0"); return 0; }` with the arm64 cross compiler.
2. Run it as an ordinary user.
3. Also try `__builtin_trap();`, or `tools/kernel-tests/id-regs.c` on a kernel without our ID-register emulation.

**Expected.** The program dies of SIGILL (SIGTRAP for BRK, SIGBUS for SP alignment) and the system keeps running.
**Actual.** `PANIC: unhandled exception: 0` (60 for BRK), and the kernel debugger is entered.

**Root cause.** `src/system/kernel/arch/arm64/arch_int.cpp:269-391`: the switch has no case for EC 0x00, 0x18, 0x26 or 0x3c. Its `default:` panics without checking `isUser` (`:267`). The `!known` path at `:319` leaves the signal variables uninitialised (`:262-264`).

**Fix.** `cdd63d4b62` initialises the defaults (SIGILL/ILL_ILLOPC at ELR), adds an `EXCP_UNKNOWN` case (B_INVALID_OPCODE_EXCEPTION), and maps unknown data-abort codes to SIGBUS/BUS_ADRALN (alignment) or SIGSEGV/SEGV_ACCERR. It also logs ESR/FAR/ELR when the signal ends the program.

**Evidence.** Derived from the code at hrev60450; it was not run on hrev60450 (our tree has had the EXCP_UNKNOWN case since 2026-10-18, before upstream added the panic). With the fix and the fork's emulation, `tools/kernel-tests/id-regs.c` prints PASS on the Pi. Without the emulation it dies of SIGILL instead of a random signal.

<a id="hk-02"></a>

#### HK-02 — kernel/arm64: sigreturn restores the whole SPSR from the user's signal frame

- **Trac fields:** Component: `System/Kernel` · Version: R1/beta5 (nightly hrev60431) · Platform: arm64 · Type: bug
- **Severity:** security (a program can make the kernel `eret` to EL1, with interrupts masked or a chosen single-step state)
- **Scope:** arm64 (any board); arm64 code only. x86_64 already masks the restored flags (`X86_EFLAGS_USER_FLAGS`, `src/system/kernel/arch/x86/64/thread.cpp:457-458`).
- **Our fix:** haiku-pi/haiku `rpi4` `4cd6f504f8` — "kernel/arm64: Restore only the user settable SPSR bits on sigreturn."
- **Patch:** attachable as-is
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/system/kernel/arch/arm64/arch_thread.cpp:228` (`frame->spsr = signalFrameData->context.uc_mcontext.spsr;`). Related upstream work: a705f5a713 (hrev60442, 2026-11-19) added `src/tests/system/kernel/sig_corrupt_frame_test.cpp` ("currently does cause crashes on various architectures"), and ticket #20515 ("Move more signal frame restoration logic to userspace", new) lists ARM64. Trac: searched "signal frame spsr": none; found #20515.

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB; review of the code.

**Description.** `arch_restore_signal_frame()` copies the saved SPSR from user memory into the iframe unchanged. A signal handler that edits its `vregs.spsr` returns through `eret` with the following bits under its control:
- `M` (exception level and stack, e.g. EL1h);
- the DAIF masks;
- `SS`, `IL` and the remaining reserved bits.

**Steps to reproduce.**
1. Install a SIGUSR1 handler (`void h(int, void*, vregs* r)`) that sets `r->spsr = 0x3c5` (EL1h, DAIF masked).
2. `raise(SIGUSR1)`.
3. Alternatively, run upstream's `sig_corrupt_frame_test` (all of `vregs` set to 0xAA…).

**Expected.** Only NZCV and the other EL0-settable bits are taken. The thread stays at EL0 (and the corrupt-frame test ends through its SIGSEGV handler).
**Actual.** The kernel returns to EL1 at the user-chosen ELR. From code inspection, the result is an illegal exception return or a kernel-mode fault and panic, and at worst kernel-mode execution at a user-chosen address.

**Root cause.** `src/system/kernel/arch/arm64/arch_thread.cpp:216-236`, line 228.

**Fix.** `4cd6f504f8` takes only `PSR_USER_SETTABLE` from the frame and keeps the rest of the kernel's SPSR:
```
frame->spsr = (frame->spsr & ~(uint64)PSR_USER_SETTABLE)
	| (signalFrameData->context.uc_mcontext.spsr & PSR_USER_SETTABLE);
```
`PSR_USER_SETTABLE` is NZCV, BTYPE, SSBS, DIT and TCO (new defines in `arm_registers.h`).

**Evidence.** Code review, found while adding arm64 user debugging; no exploit was written. RenkuOS fixed the same bug independently (0b02c0aca8, merged through security advisory GHSA-mmvg-3xfc-26p8; it keeps only NZCV).

<a id="hk-06"></a>

#### HK-06 — kernel/arm64: the empty TTBR0 table is never cleared: random freezes after a cold boot

- **Trac fields:** Component: `System/Kernel` · Version: R1/beta5 (nightly hrev60431) · Platform: arm64 · Type: bug
- **Severity:** hang (early-boot freeze, depends on RAM contents)
- **Scope:** arm64 (any board); arm64 code only
- **Our fix:** haiku-pi/haiku `rpi4` `d1a616afac` — "arm64: clear the empty TTBR0 table"
- **Patch:** attachable as-is
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/system/kernel/arch/arm64/arch_vm_translation_map.cpp:79`. This is a regression from 593f25d6f1e (hrev59509, 2026-03-17). That change replaced an allocation with `VM_PAGE_ALLOC_CLEAR` by `vm_allocate_early_physical_page()`, which does not clear (`src/system/kernel/vm/vm_init.cpp:260`). Trac: searched "TTBR0": #20211 (PinePhone crash, new) is the only arm64 boot-crash ticket, and its cause is not established. We do not claim it is this bug.

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB under U-Boot (EFI).

**Description.** The page installed in TTBR0_EL1 for every kernel-only thread is taken from the early allocator and never zeroed. TCR_EL1.EPD0 stays clear, so the MMU walks it. Whatever the RAM held becomes translation-table entries mapping random physical memory. After a long power-off the page holds garbage; after a warm restart it holds the previous boot's zeroed table. The resulting freezes therefore come only after cold starts.

**Steps to reproduce.**
1. Power the board off for 30 minutes, or fill RAM with random data before the loader runs. We used a U-Boot that does so.
2. Boot.

**Expected.** The board boots every time.
**Actual.** The kernel freezes early with three CPUs stuck, in up to 2 of 3 cold boots. Warm restarts boot fine.

**Root cause.** `arch_vm_translation_map.cpp:79`: `sEmptyTable = vm_allocate_early_physical_page(args) << PAGE_SHIFT;` without clearing.

**Fix.** `memset((void*)(KERNEL_PMAP_BASE + sEmptyTable), 0, B_PAGE_SIZE);` followed by `dsb ish`.

**Evidence.** With RAM filled with random data, 3 of 3 boots froze; a page bisect found this table's page. With the one-line fix: alive 3 of 3. 10 of 10 cold boots after 30 minutes off each (before the fix, up to 2 in 3 froze).

<a id="hk-07"></a>

#### HK-07 — kernel/arm64: spin-waits livelock on cores without LSE atomics (cpu_wait() polls a line another CPU updates with LL/SC)

- **Trac fields:** Component: `System/Kernel` · Version: R1/beta5 (nightly hrev60431) · Platform: arm64 · Type: bug
- **Severity:** hang (two CPUs with interrupts off stall for 10 ms to over a minute)
- **Scope:** arm64 cores without LSE atomics (ARMv8.0: Cortex-A53/A57/A72/A73), any board. The generic `cpu_wait()` only affects arm64 through `arch_cpu_pause()`.
- **Our fix:** haiku-pi/haiku `rpi4` `0db3ca639d` — "arm64: wait in WFE, not by polling: fixes the Pi 4's CPU stalls". Companion: `a46a16641e` — "kernel: spinlock and ICI deadlock detection by time, not iterations". It is needed once a wait iteration can last a WFE period, because otherwise the 100 M-iteration spinlock check fires only after hours.
- **Patch:** with notes: does not apply as-is. Take the `arch_cpu_wait()` (ldxr + wfe) in `arch_cpu.h`, the event stream and ISB in `arch_timer.cpp`, the `cpu.cpp` and `smp.cpp` hunks, and `a46a16641e`. Drop the `arch_int_gicv2.cpp`/`timer.cpp` hunks: they remove a fork-only watchdog. The `arch_cpu.h` context also depends on our WFI barrier, `5b2e85f498`.
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450: `src/system/kernel/cpu.cpp:355-361` (`cpu_wait()` → `arch_cpu_pause()` = `yield`, `headers/private/kernel/arch/arm64/arch_cpu.h:110-113`); the polling loop in `src/system/kernel/condition_variable.cpp:400-404`; `src/system/kernel/smp.cpp:267` (`try_acquire_spinlock()` exchanges without testing first); `src/system/kernel/arch/arm64/arch_timer.cpp:33-73` (no ISB after CNTV_CTL writes, no event stream). Trac: searched "arm64 hang": no matching ticket.

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB (Cortex-A72, no LSE).

**Description.** CPU 0 runs `ConditionVariable::_NotifyLocked()` from an SD interrupt and spins in `cpu_wait(&fEntriesCount, …)`. Meanwhile the waiter spins in `ConditionVariableEntry::_RemoveFromVariable()`, retrying `atomic_add()` on the same cache line. Without LSE, atomics are load/store-exclusive loops, and the notifier's tight polling loads keep clearing the waiter's exclusive monitor. The store-exclusive keeps failing, and both CPUs, with interrupts disabled, make no progress until something perturbs the timing. Their timers fire (CNTV_CTL 0x5) but are not taken.

**Steps to reproduce.**
1. On a Cortex-A72 or A53 board, boot repeatedly. About half of our boots froze for over a minute.
2. Or run sustained SD I/O together with a CPU load. A 10-minute QuakeSpasm + SD soak showed ~400 stalls of up to 760 ms.

**Expected.** No stalls.
**Actual.** Multi-second to minute-long freezes, often at boot.

**Root cause.** The polling `cpu_wait()` (`cpu.cpp:355-361`) on an LL/SC-contended line (`condition_variable.cpp:400-404`, `smp.cpp:267`).

**Fix.** As Linux's `__cmpwait()`: `cpu_wait()` waits in WFE on the variable's line (`sevl; wfe; ldxr; cmp; b.eq; wfe`). The generic timer's event stream (CNTKCTL_EL1.EVNTEN, bit 12, about 152 µs) bounds every WFE. `try_acquire_spinlock()` tests before it exchanges. An ISB follows timer register writes.

**Evidence.** Pi 4 boot bench: 10/10 clean without any watchdog (about half of all boots froze before). The 10-minute QuakeSpasm + SD soak had no stall left (it had ~400).

<a id="hk-08"></a>

#### HK-08 — kernel/arm64: a failed fork() panics: a user translation map without a table is freed or walked at physical 0

- **Trac fields:** Component: `System/Kernel` · Version: R1/beta5 (nightly hrev60431) · Platform: arm64 · Type: bug
- **Severity:** crash (kernel panic)
- **Scope:** arm64 (any board); arm64 code only
- **Our fix:** haiku-pi/haiku `rpi4` `e2aefd5d96` — "arm64: a failed fork() no longer panics; …" (destructor half) and `c8f3757b45` — "arm64: no page-table walk before a user map has a table"
- **Patch:** with notes: `c8f3757b45` applies as-is. From `e2aefd5d96` take only the `VMSAv8TranslationMap.cpp` hunk; its `arch_int.cpp` logging part is unrelated.
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/system/kernel/arch/arm64/VMSAv8TranslationMap.cpp:155` (destructor `FreeTable(fPageTable, …)` with `fPageTable == 0`) and `:440` (`ASSERT(ptPa != 0)` only). `UnmapPages()` (`:707`) and the other `ProcessRange()` callers do not check; only `Unmap()` does (`:635`). Trac: searched "arm64 fork": none.

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB.

**Description.** A user map allocates its top-level table at its first `Map()`. If `fork()` fails early (e.g. under memory pressure), `fork_team()` deletes the child's areas and its address space while the map has no table. `UnmapPages()` then walks from physical 0, faulting at `KERNEL_PMAP_BASE` (0xffffff0000000000), and the destructor frees "the table" at physical 0.

**Steps to reproduce.**
1. Exhaust memory (e.g. `tools/haiku-tests/memhog.c`).
2. Fork in a loop from a shell until `fork()` fails ("low resource memory: warning").

**Expected.** `fork()` returns ENOMEM.
**Actual.** `PANIC: unhandled pagefault` in `VMSAv8TranslationMap::UnmapPages` or `~VMSAv8TranslationMap`.

**Root cause.** `VMSAv8TranslationMap.cpp:134-158` and `:436-440`.

**Fix.** The destructor returns early when `fPageTable == 0`, and `ProcessRange()` returns when `ptPa == 0` (a map without a table is empty).

**Evidence.** Two panics on the Pi: a bash fork while Wine ran an x86-64 program (destructor), and a fork failing under memory pressure (`UnmapPages()`). With `c8f3757b45`, 500 fork+exec in 5 s ran without a panic. RenkuOS has an open PR for the destructor half (#478).

<a id="hk-09"></a>

#### HK-09 — kernel/arm64: an mmap(PROT_WRITE) (write-only) mapping faults forever

- **Trac fields:** Component: `System/Kernel` · Version: R1/beta5 (nightly hrev60431) · Platform: arm64 · Type: bug
- **Severity:** hang (the thread spins at 100 % CPU in page faults)
- **Scope:** arm64 (any board); arm64 code only
- **Our fix:** haiku-pi/haiku `rpi4` `8a7946ae00` — "arm64: a user write-only mapping is user-readable too"
- **Patch:** attachable as-is
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/system/kernel/arch/arm64/VMSAv8TranslationMap.cpp:533-534` (user access only for `B_READ_AREA | B_EXECUTE_AREA`). Trac: searched "PROT_WRITE": no matching ticket.

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB.

**Description.** AArch64 access permissions cannot express write-only. A `B_WRITE_AREA`-only mapping gets no `AP[1]` user access. Every user store faults, and the fault handler, finding writes allowed, returns to the same instruction.

**Steps to reproduce.**
1. `p = mmap(NULL, 4096, PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)`.
2. `p[0] = 1`.

Derived from the code; not run on hrev60450 (seen with Wine's wineserver on our tree).

**Expected.** The store succeeds (as on Linux, where write implies read on arm64).
**Actual.** The thread spins in page faults forever.

**Root cause.** `VMSAv8TranslationMap.cpp:533`.

**Fix.** Grant user access for `B_READ_AREA | B_WRITE_AREA | B_EXECUTE_AREA`.

**Evidence.** Wine's wineserver spun at 100 % CPU writing its shared data page; it works with the fix.

<a id="hk-17"></a>

#### HK-17 — kernel/arm64: arch_cpu_sync_icache() computes the I-cache line size wrongly (invalidates every 4 bytes)

- **Trac fields:** Component: `System/Kernel` · Version: R1/beta5 (nightly hrev60431) · Platform: arm64 · Type: bug
- **Severity:** performance (wrong computation; 16 invalidations per 64-byte line on every executable mapping)
- **Scope:** arm64 (any board); arm64 code only
- **Our fix:** haiku-pi/haiku `rpi4` `0fe465e233` — "kernel/arm64: fix the instruction cache line size in arch_cpu_sync_icache()"
- **Patch:** attachable as-is
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/system/kernel/arch/arm64/arch_cpu.cpp:91` (`uint64_t icache_line_size = 4 << (ctr_el0 << 0xF);`). Trac: searched "icache": none.

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB.

**Description.** The I-cache line size should be `4 << (CTR_EL0 & 0xf)`. `ctr_el0 << 15` has its low bits zero, and the shift count is taken modulo 64, so the line size is 4 bytes. Every page mapped executable is synchronised (every exec, every code page fault), so the cost is paid all the time. The function also ignores CTR_EL0.IDC/DIC.

**Steps to reproduce.**
1. Time fork + exec + wait of `/bin/true`, e.g. with `tools/haiku-tests/forkbench.c`.
2. Profile it with `profile -k`.

**Expected.** One `ic ivau` per cache line.
**Actual.** `arch_cpu_sync_icache()` takes 45 % of fork + exec time on a Cortex-A72.

**Root cause.** `arch_cpu.cpp:91`.

**Fix.** `4 << (ctr_el0 & 0xf)`. Skip the D-cache clean when IDC is set and the I-cache invalidate when DIC is set.

**Evidence.** Pi 4 (`forkbench`):
- fork + exec + wait: 7.8 → 4.7 ms
- posix_spawn: 7.4 → 3.4 ms
- fork + _exit: 2.2 → 1.1 ms

<a id="hk-18"></a>

#### HK-18 — kernel/arm64: user time is counted as kernel time (only syscalls run thread_at_kernel_entry())

- **Trac fields:** Component: `System/Kernel` · Version: R1/beta5 (nightly hrev60431) · Platform: arm64 · Type: bug
- **Severity:** wrong output (user/system CPU times, `time`, top, ProcessController)
- **Scope:** arm64 (any board); arm64 code only (x86's entry code accounts on every entry from user mode)
- **Our fix:** haiku-pi/haiku `rpi4` `24b4e36dcf` — "arm64: count user time on every exception from user mode"
- **Patch:** attachable as-is
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/system/kernel/arch/arm64/arch_int.cpp:209-215` (the `InterruptScope` constructor has no accounting) vs `:382` (only in the SVC path). The destructor runs `thread_at_kernel_exit()` on every return to EL0 (`:225-234`). Trac: searched "user time arm64": none.

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB.

**Description.** A thread interrupted by its timer or by a page fault has the whole preceding stretch of user mode billed as kernel time.

**Steps to reproduce.**
1. Run a pure Python loop (python3) for a few seconds under `time`.

**Expected.** User time ≈ elapsed time, system time small.
**Actual.** user 0.013 s, sys 4.32 s.

**Root cause.** `arch_int.cpp:209-215`, `:382`.

**Fix.** Call `thread_at_kernel_entry(system_time())` in `InterruptScope` for every exception taken from EL0, and drop the call from the SVC path.

**Evidence.** Pi 4: the same loop gives user 4.17 s, sys 0.19 s.

<a id="hk-22"></a>

#### HK-22 — boot/efi/arm64: a secondary CPU can read a stale zero from its stack and enter the kernel as a second "CPU 0"

- **Trac fields:** Component: `System/Boot Loader` · Version: R1/beta5 (nightly hrev60431) · Platform: arm64 · Type: bug
- **Severity:** crash (panic right after `ExitBootServices()`)
- **Scope:** arm64 (any board): secondaries start with caches off, both under a spin table and under PSCI. arm64 code only.
- **Our fix:** haiku-pi/haiku `rpi4` `eb4bdd0ea4` — "efi/arm64: no stale cache lines for the secondary CPUs' stacks"
- **Patch:** with notes: the patch does not apply as-is. Upstream now passes `cpu` to `arm64_common_cpu_startup(cpu)` (6df6939f4e), and our context includes `d3c5064bd0`. The two parts are small: clean+invalidate (`dc civac`) the secondary stacks before the release, and look the CPU index up again from MPIDR_EL1 after the caches are on.
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/system/boot/platform/efi/arch/arm64/arch_smp.cpp:108` (`memset(stack, 0, size)` with caches on; later only cleaned by `arm64_mmu_setup()`) and `:160-167` (`arm64_secondary_startup2()` uses `cpu` after enabling the caches). Trac: searched "arm64 panic": only #19713 (closed). Not found.

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB; GCC 16.2 build (GCC 13.3 hides it).

**Description.** A secondary CPU writes to its stack with caches off, enables them and reads back. The boot CPU zeroed those stacks with caches on and only cleaned them, so a zero line can still be cached and shadow what the secondary wrote. The `cpu` argument (or a callee-saved register spilled across `arm64_common_cpu_startup()`) then reads back 0, and a second "CPU 0" enters the kernel on CPU 0's stack.

**Steps to reproduce.**
1. Build the loader with a compiler that keeps `arm64_secondary_startup2()`'s `cpu` on the stack (GCC 16.2 does).
2. Boot an SMP arm64 board repeatedly.

**Expected.** Every CPU enters with its own index.
**Actual.** Panic after `ExitBootServices()`, about 2 boots in 13: ELR 0x24, FP/LR 1920/32 popped from a frame the other "CPU 0" overwrote.

**Root cause.** `arch_smp.cpp:108` and `:160-167`.

**Fix.** Clean and invalidate the stacks before releasing the CPUs; re-derive the index from MPIDR_EL1 after the caches are on.

**Evidence.** Pi 4 + GCC 16.2: 2 early panics in ~13 boots before, 0 in 24 after.

<a id="hk-23"></a>

#### HK-23 — arm/arm64: PL011 whose clock comes from a clock controller: garbled serial output from loader and kernel

- **Trac fields:** Component: `System/Boot Loader` · Version: R1/beta5 (nightly hrev60431) · Platform: arm64 · Type: bug
- **Severity:** wrong output (serial console unreadable)
- **Scope:** arm64 boards whose device tree gives the PL011 a `clocks` phandle without `clock-frequency` (Pi 4; any SoC with a clock controller). Shared arm/arm64 code.
- **Our fix:** haiku-pi/haiku `rpi4` `a6502fab74` — "efi: keep the firmware's UART setup when its clock is unknown" and `f5650324d6` — "arm/arm64: PL011: keep the firmware's line settings"
- **Patch:** attachable as-is (both)
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/system/boot/platform/efi/dtb.cpp:572` (`gUARTSkipInit` only from "skip-init"; `dtb_get_clock_frequency()` returns −1 at `:540`) and `src/system/kernel/arch/arm/arch_uart_pl011.cpp:164-166` (the loopback test sets FBRD 0, IBRD 1, LCRH 0 and nothing restores them unless `InitPort()` runs). Trac: not searched.

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB under U-Boot.

**Description.** With an unknown clock the loader programs the baud divisor from `Clock()` = 0xffffffff (about 1300 baud). Separately, the PL011 constructor's loopback test leaves the line at 5 data bits, no FIFO. Everything printed after `ExitBootServices()` is garbage.

**Steps to reproduce.**
1. Boot on a board whose PL011 node has `clocks = <&…>` and no `clock-frequency`.

**Expected.** Readable output at the firmware's settings.
**Actual.** Garbage after "Calling ExitBootServices".

**Root cause.** `dtb.cpp:572`; `arch_uart_pl011.cpp:149-185`.

**Fix.** Treat an unknown clock like "skip-init". Save IBRD/FBRD/LCRH before the loopback test and restore them after it.

**Evidence.** Pi 4: the serial console is unreadable without both changes and readable with them.

<a id="hk-21"></a>

#### HK-21 — kernel/arm64: the kernel debugger on the serial port reads endless 0xff characters

- **Trac fields:** Component: `System/Kernel` · Version: R1/beta5 (nightly hrev60431) · Platform: arm64 · Type: bug
- **Severity:** wrong output (KDL unusable over serial)
- **Scope:** arm64 (any board); arm64 code only (`char` is unsigned on AArch64)
- **Our fix:** haiku-pi/haiku `rpi4` `b3a08271be` — "arm64: fix reading from the debug serial port"
- **Patch:** attachable as-is
- **Upstream status (2026-11-20):** open: code unchanged at hrev60450, `src/system/kernel/arch/arm64/arch_debug_console.cpp:43-57`. Trac: searched "arm64 serial debugger": none.

**Environment.** Haiku nightly at hrev60431 (merge base), arm64, Raspberry Pi 4 Model B 4 GB (PL011).

**Description.** `arch_debug_serial_try_getchar()` (marked "TODO: Implement correctly!") calls `arch_debug_serial_getchar()`, which returns `char`. The UART's "no input" (−1) becomes 255. KDL then reads a stream of 0xff characters, and the blocking getchar does not block (`GetChar(false)`).

**Steps to reproduce.**
1. Enter KDL on an arm64 machine with a serial console.
2. Try to type a command.

**Expected.** An interactive prompt.
**Actual.** The prompt fills with 0xff characters and is unusable.

**Root cause.** `arch_debug_console.cpp:43-57`.

**Fix.** `try_getchar` returns `sArchDebugUART->GetChar(false)` (int, −1 for none). `getchar` calls `GetChar(true)`.

**Evidence.** KDL is interactive on the Pi's serial console with the fix. A RenkuOS contributor branch (linkslice `pi400/arm64-kdl-getchar`, unmerged) carries the same fix.

### 1.4 Short form

<a id="hk-58"></a>

#### HK-58 — IPv6: possible kernel crash in a send path (unconfirmed; details held for a private report)

- **Severity / scope:** possibly a remotely triggerable kernel crash; all architectures; **from code reading, not confirmed**.
- **Status:** not confirmed by us (no test-VM confirmation was done). To be passed to the Haiku developers privately
  for them to assess, not to the public tracker. The details are deliberately not in this public document.

<a id="hk-05"></a>

#### HK-05 — kernel/vm: a team can shrink an area that another team maps (resize_area on a clone)

- **What:** `resize_area()` on an area the team cloned from another team shrinks the shared RAM cache. That unmaps the end of every area of the cache, the owner's included.
- **Severity / scope:** security (an unprivileged client can crash another team, e.g. app_server, through shared bitmap memory); all architectures; generic VM code
- **Our fix:** haiku-pi/haiku `rpi4` `2dcb0bb814` — "kernel/vm: don't let a team shrink memory another team maps"
- **Patch:** not ours. Point to the RenkuOS change: RenkuOS/Source 5c9d81bd5b by Kevin Adams. Our port applies cleanly; we left out its test-file hunk.
- **Upstream status:** open: code unchanged at hrev60450, `src/system/kernel/vm/vm.cpp:4697-4711` (`vm_resize_area()` shrink path). It only checks that the *calling* area belongs to the team (`:4675`), not the other areas of the cache. Trac: searched "resize_area": no matching ticket.
- **Short form because:** found and fixed by RenkuOS developers; point upstream to their change, not ours; not reproduced by us.

<a id="hk-13"></a>

#### HK-13 — kernel/vm: vm_page_write_modified_page_range() can write a page that left the cache while the cache was unlocked

- **What:** The iterator already points past the current page when the cache is unlocked for the write. The next page can leave the cache meanwhile: the page daemon frees it, or the file shrinks.
- **Severity / scope:** crash (kernel panic in `PageWriteTransfer::Schedule()`, NULL cache); all architectures; generic VM code
- **Our fix:** haiku-pi/haiku `rpi4` `4d35669d1d` — "kernel/vm: look the next page up again after writing unlocked"
- **Patch:** not ours. Point to the RenkuOS change: RenkuOS/Source 1afc69569a by atomozero. Our port applies as-is.
- **Upstream status:** open: code unchanged at hrev60450, `src/system/kernel/vm/vm_page_writer.cpp:798-802` (iterator) and `:846-848` (`cache->Unlock(); transfer.Schedule(0); cache->Lock();` without re-seeking). Trac: not searched specifically ("page writer" results show no matching ticket).
- **Short form because:** found and fixed by RenkuOS developers; point upstream to their change, not ours; not reproduced by us.

<a id="hk-14"></a>

#### HK-14 — kernel/scheduler: power-saving mode spins forever with the scheduler lock held when an IRQ cannot be moved (pack_irqs)

- **What:** In power-saving mode a CPU going idle moves its IRQs, one at a time, to the small-task core until its list is empty. If an IRQ stays (`AssignToCpu()` returns the same CPU, or the IRQ is per-CPU), the loop never ends.
- **Severity / scope:** hang (system freeze when power-saving mode is selected); all architectures where `assign_io_interrupt_to_cpu()` can leave an IRQ in place. That is every ARM/ARM64 interrupt controller without `AssignToCpu()` (GICv3 and the base class return 0), and per-CPU interrupts anywhere.
- **Our fix:** haiku-pi/haiku `rpi4` `8ed6c7589b` — "kernel/scheduler: do not try forever to pack an IRQ that stays" and `c5be77821f` — "kernel/scheduler: check where the IRQ went, not where it is in the list". Related: `9495514a68` — "kernel/arm: SGIs and PPIs of the GIC are local interrupts". The GICv2 reserves IRQs 0-31 as I/O interrupts, so the scheduler tries to move per-CPU timers and IPIs.
- **Patch:** not ours. Point to the RenkuOS changes: RenkuOS/Source 5de6fe7fcb and f883abc582 (pack_irqs), and 4a763f815b (GIC local IRQs), all by atomozero. Our two scheduler commits apply in order. `9495514a68` needs rebasing (our GICv2 changes).
- **Upstream status:** open: code unchanged at hrev60450, `src/system/kernel/scheduler/power_saving.cpp:209-220` and `src/system/kernel/arch/arm/arch_int_gicv2.cpp:52` (`reserve_io_interrupt_vectors(32 * lineRegs, 0, INTERRUPT_TYPE_IRQ)`). Trac: searched "pack_irqs" (#18588 closed fixed, older) and "power saving freeze": no matching open ticket.
- **Short form because:** found and fixed by RenkuOS developers; point upstream to their change, not ours.

<a id="hk-24"></a>

#### HK-24 — headers/SupportDefs.h: atomic_test_and_set() uses a weak compare-and-swap (spurious failure reported as success)

- **What:** A weak CAS may fail spuriously on LL/SC machines. It then leaves `testAgainst` equal to the expected value, so the caller cannot tell the failure from success, although nothing was stored.
- **Severity / scope:** data corruption (two owners of a lock), latent; LL/SC architectures (arm, arm64, riscv64) where the inline builtin is used without outline atomics. x86 is not affected.
- **Our fix:** haiku-pi/haiku `rpi4` `88be53559b` — "SupportDefs: use a strong compare-and-swap in atomic_test_and_set()"
- **Patch:** not ours. Point to the RenkuOS change: RenkuOS/Source 8925cbc599 (PR #189) by atomozero. Our port applies as-is.
- **Upstream status:** open: code unchanged at hrev60450, `headers/os/support/SupportDefs.h:276-281` (`__atomic_compare_exchange_n(value, &testAgainst, newValue, 1, …)`, `weak = 1`, returns `testAgainst`); the 64-bit variant is alike. Trac: searched "atomic_test_and_set": no matching open ticket.
- **Short form because:** found and fixed by RenkuOS developers; point upstream to their change, not ours; latent in GCC builds with outline atomics.

<a id="hk-20"></a>

#### HK-20 — libroot/arm64: B_SWAP_FLOAT / B_SWAP_DOUBLE return a wrong value (fmov operands reversed)

- **What:** The two `fmov` instructions copy in the wrong direction. The first overwrites the argument in s0 with w0; `rev` then swaps w0, and the last `fmov` copies s0 (the caller's w0) back into w0.
- **Severity / scope:** wrong output (float byte-order conversions do nothing useful; `B_HOST_TO_BENDIAN_FLOAT/DOUBLE` and friends); arm64 (any board); arm64 code only
- **Our fix:** haiku-pi/haiku `rpi4` `55671c28c9` — "libroot/arm64: __swap_float and __swap_double return the swapped value"
- **Patch:** not ours. Point to the RenkuOS change: RenkuOS/Source PR #477 (60be83bacc) by rainygirl, unmerged there. Our port applies as-is.
- **Upstream status:** open: code unchanged at hrev60450, `src/system/libroot/os/arch/arm64/byteorder.S:13-15` and `:22-24` (`fmov s0, w0` … `fmov w0, s0`; the input is in s0/d0 per AAPCS64, so it is overwritten with w0/x0 before the swap). Trac: searched "B_SWAP_FLOAT": only #18958 (closed, unrelated build failure).
- **Short form because:** found and fixed by RenkuOS developers; point upstream to their change, not ours.

<a id="hk-32"></a>

#### HK-32 — kernel/module: file-system modules pre-loaded by the boot loader keep a bare name ("failed to normalize path of module image")

- **What:** `module_init_post_boot_device()` gives images still in use their full path, but it looks for them only under `kernel/boot`. A file system module in use that has no boot link (fat, when a FAT partition was mounted early) keeps its bare name.
- **Severity / scope:** wrong output (syslog warning; the module image keeps a relative path); all architectures; generic `module.cpp`
- **Our fix:** haiku-pi/haiku `rpi4` `93a0d0e23e` — "kernel: find the file system modules the boot loader pre-loaded"
- **Patch:** not ours. Point to the RenkuOS change: RenkuOS/Source 703ad85b51 by atomozero. Our port applies as-is.
- **Upstream status:** open: code unchanged at hrev60450, `src/system/kernel/module.cpp:1913` (looks only in `kernel/boot`). The boot loader also pre-loads `kernel/file_systems` and `kernel/partitioning_systems`. Trac: not searched.
- **Short form because:** found and fixed by RenkuOS developers; point upstream to their change, not ours; a log warning.

<a id="hk-56"></a>

#### HK-56 — network stack: the notifications module calls get_module() from its own syscall; deadlock with its unload at boot

- **What:** `NetNotificationService::FirstAdded()` calls `get_module()` on its own module from inside the module's generic syscall. If the module is being unloaded at that moment, the following happens: 1.
- **Severity / scope:** hang (net_server and launch_daemon deadlock at boot); all architectures; generic module/syscall code; reported by RenkuOS on x86 at about 1 boot in 20
- **Our fix:** haiku-pi/haiku `rpi4` `e24ddebb42` — "net notifications: keep the module loaded, no get_module() from its own syscall" (port of RenkuOS PR #476, d0f1661cdd, by rainygirl, for RenkuOS issue #308)
- **Patch:** not ours — point to the RenkuOS change (RenkuOS/Source PR #476, d0f1661cdd)
- **Upstream status:** open: code unchanged at hrev60450, `src/add-ons/kernel/network/notifications/notifications.cpp:81, 89` (module flags 0 at `:172`); Trac: not searched
- **Short form because:** found and fixed by RenkuOS developers; point upstream to their change, not ours.

<a id="hk-59"></a>

#### HK-59 — TCP: ~TCPEndpoint() holds the endpoint lock while waiting for its timers; a running timer hook deadlocks the stack's timer thread

- **What:** Since 2f2dd59e16 the destructor locks `fLock` (`:474`), cancels the timers, then calls `wait_for_timer()` for each of them while still holding the lock (`:488-491`), and destroys the lock last (`:493`). The timer thread may already have taken a hook off its list (`sCurrentTimer = timer`); `cancel_timer()` does not stop that hook, and the hook's first action is `MutexLocker locker(endpoint->fLock)` (`:2666/2680/2698/2716`).
- **Severity / scope:** hang (the single "net timer" thread stops: retransmits, delayed ACKs and TIME_WAIT expiry for the whole stack); all architectures; generic TCP code
- **Our fix:** haiku-pi/haiku `rpi4` `0c2354bf59` — "tcp: wait for in-flight timers before destroying the endpoint lock" (hand port of RenkuOS/Source bdecbeb5b5, by rainygirl)
- **Patch:** not ours — point to the RenkuOS change (RenkuOS/Source bdecbeb5b5)
- **Upstream status:** open: code unchanged at hrev60450, `src/add-ons/kernel/network/protocols/tcp/TCPEndpoint.cpp:474, 488-493`; this is a regression from upstream 2f2dd59e16 ("tcp: destroy the endpoint lock after the timers exited.", 2026-10-10, hrev60232, "should fix #20408"), so it is best reported on #20408; Trac: not searched
- **Short form because:** found and fixed by RenkuOS developers; point upstream to their change, not ours; code reading, not reproduced.

<a id="hk-73"></a>

#### HK-73 — openbsd_wlan: the scan-done notification is compiled out, so net_server never auto-joins a saved network

- **What:** net_server's auto-join starts only on `B_NETWORK_WLAN_SCANNED` (`src/servers/net/AutoconfigLooper.cpp:195`). The FreeBSD wlan layer sends it; the OpenBSD layer's notifier is inside `#if 0`.
- **Severity / scope:** wrong output (a saved WiFi network is not rejoined after boot); all architectures; affects every openbsd_wlan driver upstream ships (idualwifi7260, iaxwifi200, iprowifi3945)
- **Our fix:** haiku-pi/haiku `rpi4` `fbd46ca58b` — "openbsd_wlan: tell net_server when a scan is done; list the current AP" (port of RenkuOS/Source PR #471, af7c71aba8 + 9062ad2823, by Dru Satori)
- **Patch:** not ours — point to the RenkuOS change (RenkuOS/Source PR #471, af7c71aba8)
- **Upstream status:** open: code unchanged at hrev60450, `src/libs/compat/openbsd_wlan/net80211/ieee80211_haiku.cpp:499-515` (`#if 0` around `ieee80211_notify_scan_done()`); nothing calls it from `ieee80211_end_scan()` (`ieee80211_node.c:1472`); Trac: not searched
- **Short form because:** found and fixed by RenkuOS developers; point upstream to their change, not ours.

<a id="hk-79"></a>

#### HK-79 — usb_disk: uninit deletes the I/O schedulers while holding the device lock their threads need

- **What:** `usb_disk_uninit_driver()` takes `device->lock` and then `usb_disk_free_device_and_luns()` deletes each LUN's I/O scheduler. Deleting an `IOSchedulerSimple` waits for its scheduler thread (`IOSchedulerSimple.cpp:153`), and that thread runs `usb_disk_do_io()`, which takes the same lock.
- **Severity / scope:** hang (USB explore thread; every later driver registration blocks); all architectures; generic driver
- **Our fix:** haiku-pi/haiku `rpi4` `d3cc8e3fd1` — "usb_disk: delete the I/O schedulers before taking the device lock in uninit"
- **Patch:** attachable as-is
- **Upstream status:** open: code unchanged at hrev60450, `src/add-ons/kernel/drivers/disk/usb/usb_disk/usb_disk.cpp:1923, 1932` (lock, then free), `:138` (scheduler deleted), `:1790` (`usb_disk_do_io()` takes the same lock); Trac: not searched
- **Short form because:** the most consistent explanation of one stalled boot, never reproduced.

<a id="hk-25"></a>

#### HK-25 — arm/arm64 GICv2: inter-CPU messages are not ordered against the SGI; SGI targets assume `1 << cpu`

- **What:** **Send side.** The ICI message is stored to normal memory and the SGI is a device store, which is not ordered after it, so the target can take the interrupt before the message is visible. **Receive side.** The acknowledge is a device read that does not order the normal loads that follow it. **Targets.** A CPU's GIC interface bit need not equal its Haiku index.
- **Severity / scope:** hang (a lost or misdirected ICI), by inspection; arm/arm64 with a GICv2 (shared `arch/arm` code). GICv3 already has the barriers.
- **Our fix:** haiku-pi/haiku `rpi4` `4eb785f652` — "arm/arm64: GICv2: order inter-CPU messages before the SGI" and the barrier and CPU-map parts of `aa7da3b827` — "arm/arm64: GICv2 IPI ordering and CPU map; debug UART on every CPU"
- **Patch:** with notes: `4eb785f652` applies as-is. `aa7da3b827` also adds KDL commands, `RouteInterrupt()` and debug-UART routing. Extract only the read barrier after acknowledging an SGI and the per-CPU interface mask, read from the banked GICD_ITARGETSR0, as Linux's `gic_cpu_map`.
- **Upstream status:** open: code unchanged at hrev60450, `src/system/kernel/arch/arm/arch_int_gicv2.cpp:136-145` (`SendMulticastIci()`/`SendBroadcastIci()` without `memory_write_barrier()`; targets `cpuSet.Bits(0)`, i.e. `1 << cpu`) and `:119-133` (no read barrier after the IAR read). GICv3: `arch_int_gicv3.cpp:248/284/298` (write barriers present). Trac: not searched.
- **Short form because:** found by code review against the Arm memory model; no failure attributed to it.

<a id="hk-26"></a>

#### HK-26 — kernel/arm64: a new thread enters userland with a signal pending (no kernel exit work in arch_thread_enter_userspace())

- **What:** The `resume_thread()` that starts every thread leaves `SIGNAL_CONTINUE_THREAD` pending. On arm64 it stays pending until the thread's first exception.
- **Severity / scope:** hang (a thread's first interruptible wait returns `B_INTERRUPTED` at once; with libroot's `rw_lock_wait()` this became a frozen application). Latent upstream; arm64 (any board); arm64 code only (x86 does this in `x86_return_to_userland()`)
- **Our fix:** haiku-pi/haiku `rpi4` `5d9132a49c` — "kernel/arm64: kernel exit work when a thread first enters userland"
- **Patch:** with notes: the context differs; it calls `arm64_init_user_debug_at_kernel_exit()` from our user-debugging work. Upstream needs only the push iframe / `thread_at_kernel_exit()` / pop iframe block before `_eret_with_iframe()`.
- **Upstream status:** open: code unchanged at hrev60450, `src/system/kernel/arch/arm64/arch_thread.cpp:108-136` (`_eret_with_iframe()` at `:134` without exit work). Trac: not searched.
- **Short form because:** latent upstream; exposed only by stack reuse in our fork.

<a id="hk-28"></a>

#### HK-28 — kernel/fdt, arch/arm, arch/arm64: side effects inside ASSERT() (broken at KDEBUG_LEVEL < 2)

- **What:** With `ASSERT()` compiled out, the signal handler's address is never fetched, so every signal handler jumps to an uninitialised address. Every FDT device's node number and bus driver are garbage too.
- **Severity / scope:** crash (latent: only at a non-default `KDEBUG_LEVEL`); arm and arm64 (signal frame), and every FDT platform (fdt bus manager: arm, arm64, riscv64)
- **Our fix:** haiku-pi/haiku `rpi4` `55348c5c46` — "kernel, fdt: side effects out of ASSERT(); what a KDEBUG_LEVEL below 2 needs"
- **Patch:** with notes: the `fdt_module.cpp` hunk includes a ninth site in our own `fdt_device_get_dma_window()`; upstream has 8. The `sdhci.cpp`/`gicv3`/`vfs.cpp` hunks are include fixes and a warning fix for that configuration.
- **Upstream status:** open: code unchanged at hrev60450: `src/system/kernel/arch/arm64/arch_thread.cpp:201-203` and `src/system/kernel/arch/arm/arch_thread.cpp:296-298` (`ASSERT(user_memcpy(&signalHandlerAddr, …) >= B_OK)`); `src/add-ons/kernel/bus_managers/fdt/fdt_module.cpp:317, 361, 374, 423, 509, 549, 563, 580` (`ASSERT(gDeviceManager->get_attr_uint32(…"fdt/node"…))` / `get_driver(…)`); `headers/private/kernel/debug.h:69` defines `ASSERT(x)` as nothing below KDEBUG 2. Trac: not searched.
- **Short form because:** latent at the default KDEBUG_LEVEL 2.

<a id="hk-29"></a>

#### HK-29 — kernel/arm64: a fresh kernel stack page can fault inside the exception vector (software access/dirty flags)

- **What:** Pages start without AF and read-only, and the first access and first write fault. On a kernel stack, that first access can be the exception entry code storing an iframe.
- **Severity / scope:** crash (recursive faults in the vector, then a panic); seen only at `KDEBUG_LEVEL` 1; arm64 cores without hardware access-flag/dirty-state management (no FEAT_HAFDBS, e.g. Cortex-A53/A72); arm64 code only
- **Our fix:** haiku-pi/haiku `rpi4` `dc849a150b` — "arm64: map kernel stacks accessed and dirty from the start"
- **Patch:** attachable as-is
- **Upstream status:** open: code unchanged at hrev60450, `src/system/kernel/arch/arm64/VMSAv8TranslationMap.cpp:511-545` (`GetMemoryAttr()` gives `B_KERNEL_STACK_AREA` pages no AF and AP read-only, like any other page). Trac: not searched.
- **Short form because:** seen only at KDEBUG_LEVEL 1.

<a id="hk-30"></a>

#### HK-30 — kernel/debug: continuing from a software breakpoint can leave its replacement hardware breakpoint unloaded

- **What:** `PrepareToContinue()` replaces a software breakpoint at the continuation PC by a hardware one. If the team had no hardware breakpoint before, its threads' `THREAD_FLAGS_BREAKPOINTS_DEFINED` stays clear.
- **Severity / scope:** wrong output (the thread runs past every later hit of that breakpoint); generic `BreakpointManager`/`user_debugger.cpp` (all architectures); observed only with the fork's arm64 user-debugging back end
- **Our fix:** haiku-pi/haiku `rpi4` `40adafebe9` — "kernel/debug: Update the breakpoints flag when continuing installs one."
- **Patch:** attachable as-is
- **Upstream status:** open: code unchanged at hrev60450, `src/system/kernel/debug/BreakpointManager.cpp:426` (`PrepareToContinue()` returns nothing) and `src/system/kernel/debug/user_debugger.cpp:811` (the caller does not update `THREAD_FLAGS_BREAKPOINTS_DEFINED`). Trac: not searched.
- **Short form because:** observed only with our arm64 user-debugging back end.

<a id="hk-31"></a>

#### HK-31 — kernel/debug: no instruction-cache synchronisation after the debugger writes team memory

- **What:** `BreakpointManager::_WriteMemory()` copies into the team's code pages but does not make the instruction cache see the change.
- **Severity / scope:** wrong output (a written breakpoint or patched code may not be executed); architectures with incoherent instruction caches (arm, arm64, riscv64); a no-op on x86. On upstream arm64, user breakpoints are not usable (see HK-01), so the path is mainly `B_DEBUG_MESSAGE_WRITE_MEMORY` into code.
- **Our fix:** haiku-pi/haiku `rpi4` `09b7e81388` — "kernel/debug: Synchronize the instruction cache after writing team memory."
- **Patch:** attachable as-is
- **Upstream status:** open: code unchanged at hrev60450, `src/system/kernel/debug/BreakpointManager.cpp:750` (`user_memcpy()` without `arch_cpu_sync_icache()`; no call anywhere in `src/system/kernel/debug/`). Trac: searched "icache": none.
- **Short form because:** observed only with our arm64 user-debugging back end.

<a id="hk-82"></a>

#### HK-82 — kernel: TLS slots above the first eight are not cleared for a new thread on a caller-provided stack

- **What:** `enter_userspace()` writes only TLS slots 0–7 (`TLS_FIRST_FREE_SLOT`). Slots 8–63, which `tls_allocate()` hands out to libraries, rely on the stack area being freshly zeroed.
- **Severity / scope:** wrong output (stale values from `tls_get()` in a new thread); all architectures; upstream reaches it only with a caller-provided (reused) stack
- **Our fix:** haiku-pi/haiku `rpi4` `a000d5d6cc` — "kernel/thread: Clear all TLS slots of a new thread."
- **Patch:** attachable as-is (drop the comment's mention of stack reuse, which refers to a change of ours)
- **Upstream status:** open: code unchanged at hrev60450, `src/system/kernel/thread.cpp:763`; Trac: not searched
- **Short form because:** minor; no failure seen.

<a id="hk-83"></a>

#### HK-83 — libbluetooth: `debug.h` defaults DEBUG to 3, so release builds print every CALLED() trace to the program's stdout

- **What:** Release builds pass no `-DDEBUG` (build/jam defines it only for a debug level above 0). The private header then defines `DEBUG 3`, so all 67 `CALLED()` sites in libbluetooth print to the stdout of the calling program.
- **Severity / scope:** wrong output (trace lines mixed into the output of programs that use the Bluetooth Kit); all architectures
- **Our fix:** haiku-pi/haiku `rpi4` `d226612219` — "bluetooth: the kit traces errors only unless DEBUG is set"
- **Patch:** attachable as-is
- **Upstream status:** open: code unchanged at hrev60450, `headers/private/bluetooth/debug.h:5`; Trac: not searched
- **Short form because:** minor (stray output).

<a id="hk-84"></a>

#### HK-84 — bt_dev_info / bt_discovery: do not build, pass a BString through %s, and bt_discovery never sees its inquiry end

- **What:** There are three problems: **bt_discovery does not compile.** The public header `headers/os/bluetooth/RemoteDevice.h:12` includes the private `<bluetoothserver_p.h>`, which is not on `src/bin`'s include path. **Undefined behaviour and wrong arguments in both tools.** They pass `bdaddrUtils::ToString()` (a `BString`) to `%s`, use `%ld` for a uint32, and read the device number from `argv[0]` instead of `argv[1]`. **bt_discovery waits forever.** It overrides `InquiryCompleted()`, which nothing calls; the kit reports the end of an inquiry through `InquiryResponse()` (`DiscoveryListener.cpp:159-167`).
- **Severity / scope:** build (bt_discovery), wrong output, hang (bt_discovery waits forever); all architectures; the tools are not in any image, so the default build is not affected
- **Our fix:** haiku-pi/haiku `rpi4` `02e02d4ba3` — "bt_dev_info, bt_discovery: build and print the device address"; `0c12640aa2` — "bt_discovery: implement InquiryResponse(), so the tool sees its inquiry end"
- **Patch:** with notes: the upstream `.cpp` files use CRLF line endings and our commits rewrote them with LF; regenerate the diff keeping CRLF. The Jamfile hunk applies as-is.
- **Upstream status:** open: code unchanged at hrev60450, `src/bin/bt_discovery.cpp:35, 48, 77, 92, 115, 125`, `src/bin/bt_dev_info.cpp:17, 46, 56`, `src/bin/Jamfile:7`; Trac: not searched
- **Short form because:** small tool fixes.

<a id="hk-85"></a>

#### HK-85 — network: the system's own host name does not resolve (default hosts file lacks it), so lookups wait for DNS

- **What:** The default image names the host "shredder", but the hosts file lists only `localhost`. A lookup of the host's own name therefore goes to the name servers: it fails (NXDOMAIN) with a network, and waits for the resolver's time-outs without one.
- **Severity / scope:** wrong output / performance (`gethostbyname(hostname)` fails, or waits for name server time-outs); all architectures; generic libnetwork and the default image (`HAIKU_IMAGE_HOST_NAME ?= shredder`, absent from `data/settings/network/hosts`)
- **Our fix:** haiku-pi/haiku `rpi4` `58022c954a` — "libnetwork: answer the host's own name from the hosts file's localhost entries"
- **Patch:** attachable as-is (`#ifdef __HAIKU__` hunks in netresolv). An alternative is to write the image's host name into the hosts file.
- **Upstream status:** open: code unchanged at hrev60450, `src/system/libnetwork/netresolv/net/getaddrinfo.c:2456-2490` (`_files_getaddrinfo()`), `src/system/libnetwork/netresolv/net/sethostent.c:124` (`_hf_gethtbyname()`), `data/settings/network/hosts` (localhost entries only); Trac: searched `q=gethostbyname+hostname+hosts`: blocked by the bot check (no result)
- **Short form because:** closer to a missing feature (nss-myhostname behaviour) than a defect.

## 2. Mesa

Our fork is Mesa 26.2.7 plus 38 commits. Checked against Mesa `main` **901c006e67b** (2026-11-20) and the
`mesa-26.3.0`/`mesa-26.3.1` tags; every `file:line` refers to that commit. "Applies cleanly" or "conflicts" comes
from `git merge-tree` of our commit onto main; none of the patches was built against main. GitLab was searched
through its public API. **Before any merge request:** our commits end with a `Co-Authored-By:` trailer for the AI
tool; Mesa wants `Assisted-by:` instead (see the checklist).

Common system information: Haiku nightly (hrev60431), arm64, Raspberry Pi 4 Model B 4 GB (BCM2711, V3D 4.2); Mesa
26.2.7 + haiku-pi fork; GL renderer "V3D 4.2", OpenGL ES 3.1 and OpenGL 3.3 core (fork), Vulkan 1.3 (V3DV); kernel
side: Haiku's own v3d driver implementing the Linux v3d uAPI. Linux CI runs the same chip as "V3D 4.2.14".

### 2.1 Full reports

<a id="mesa-01"></a>

#### MESA-01 — v3dv: a render pass whose render area starts inside a supertile stores whole supertiles, overwriting pixels outside the area

- **GitLab labels:** `v3dv`, `Raspberry Pi` (broadcom)
- **Severity:** data corruption
- **Scope:** all users of V3DV on any OS. The code is shared by V3D 4.2 (Pi 4) and V3D 7.1 (Pi 5). Tested on Pi 4 only.
- **Our fix:** haiku-pi/mesa `rpi4` `be833ed6d67` — "v3dv: align the supertile grid to the render area"
- **Patch:** with notes. It conflicts in `src/broadcom/vulkan/v3dv_cmd_buffer.c` on main, because `job_compute_frame_tiling()` has changed since 26.2 (the `V3D_WEBGPU_OVERRIDE` warning, precomputed subpass tile sizes). It needs a rebase and a build. Fix the trailer.
- **Upstream status (2026-11-20):** open. Code unchanged on main 901c006e67b: `src/broadcom/vulkan/v3dv_cmd_buffer.c:421-445` sizes the supertiles for the frame only, and `src/broadcom/vulkan/v3dvx_cmd_buffer.c:781-799` emits every supertile from `render_area.offset / supertile_size`. GitLab: searched "supertile", "v3dv render area" and "v3dv copy buffer to image". Related: #13218 (closed 2025-05-22, "vkCmdCopyBufferToImage writes extra copies of the input buffer to unexpected locations", Pi 5), fixed by d30a6f81023 (!35257, Mesa 25.2) for the far edge only. No report of the remaining case.

**System information.** Haiku nightly (hrev60431), arm64, Raspberry Pi 4 Model B 4 GB (V3D 4.2); Mesa 26.2.7 + haiku-pi fork; Haiku's v3d kernel driver (Linux v3d uAPI). Vulkan: V3DV, Vulkan 1.3. Linux: the tiling code, the RCL emission and the `tile_aligned_render_area` load skip are all driver-side and OS-independent. The kernel only executes the control list, so Linux v3d behaves the same.

**Describe the issue.** The hardware renders and stores every tile of each supertile listed in the RCL. When the render area is tile-aligned, V3DV skips loading the attachments (`tile_aligned_render_area`, `v3dv_cmd_buffer.c:1152`). The tiles of a supertile that lie outside the render area are therefore stored with undefined contents.

Since d30a6f81023, the frame ends at the render area's far edge (`v3dv_cmd_buffer.c:1723`), which fixed #13218 on that side. The supertile grid still starts at pixel (0,0), though. So when the render area's offset is not a multiple of the supertile size, the first row or column of supertiles also covers pixels above or to the left of the area, and those pixels are overwritten.

An example: a 4096×4096 RGBA32F image and a meta copy of a 256×256 region to (2048, 256).
- The frame is 2304×512 with 32×32 tiles, so the supertiles are 2×3 tiles (64×96 px).
- The first supertile row emitted is 256/96 = 2, which is rows 192–287.
- That row is stored whole, so rows 192–255 of the region above are overwritten.

**How to reproduce.** Any sequence of `vkCmdCopyBufferToImage` regions into a large image works; this is how wgpu stages texture uploads.
- Our reproducer is `tools/gl-tests/vkf32.c` in the haiku-pi coordination repo. It is plain headless Vulkan and builds on Linux too. `vkf32 -o 192` copies 192 tiles of 256×256 from one staging buffer, each by its own region, into a 4096-wide image, then reads the image back and compares it.
- The #13218 demonstration can be adapted by copying to (2048, 256) instead of (0, 0).
- No CTS case is known to cover it.

**Expected / Actual.** Expected: only the copied region changes. Actual: 2.48 M wrong pixels with RGBA32F and 1.48 M with RGBA8. A single copy to (2048, 256) passes its own check but overwrites rows 192–255 of the tile above it.

**Regression.** Likely yes for this geometry, since d30a6f81023 (Mesa 25.2); older Mesa was not tested. Before that commit the frame was the whole framebuffer. Running the sizing loop by hand for a 4096×4096 RGBA32F frame (128×128 tiles of 32²) gives 8×8-tile (256 px) supertiles, so 256-aligned copies were supertile-aligned. With the frame cut to 2304×512 the supertiles become 2×3 tiles and lose that alignment. The defect class is older: #13218 was the far-edge form.

**Root cause.** `src/broadcom/vulkan/v3dv_cmd_buffer.c:421-445` chooses `supertile_width/height` only from the frame size. `src/broadcom/vulkan/v3dvx_cmd_buffer.c:781-799` starts at `min_x_supertile = offset.x / supertile_w_in_pixels`, so a supertile that is only partly inside the area is emitted, while the loads are skipped for a tile-aligned area.

**Fix.** be833ed6d67 records the render area's origin in `v3dv_frame_tiling` and chooses the smallest supertile size that fits the limits and whose grid is aligned to the origin (in tiles). If no such size exists, it falls back to the old sizing. An alternative for reviewers: treat such an area as not tile-aligned, so the outside tiles are loaded and stored back. That costs loads.

**Evidence.** On the Pi 4: `vkf32 -o 192` went from 2.48 M (RGBA32F) and 1.48 M (RGBA8) wrong pixels to 0. Photocraft's 2048×2048 float compositing now matches its CPU compositor (probe 4/4). The other `vkf32` modes (clears, `-u` round trip) pass before and after.

<a id="mesa-02"></a>

#### MESA-02 — v3d: TFU mipmap generation lays out levels ≥ 1 wrongly for non-power-of-two textures

- **GitLab labels:** `v3d`, `Raspberry Pi`
- **Severity:** wrong output
- **Scope:** all users of the gallium v3d driver (GL/GLES) on any OS. Seen on V3D 4.2; V3D 7.1 untested.
- **Our fix:** haiku-pi/mesa `rpi4` `a4516893497` — "v3d: generate mipmaps of non-power-of-two textures by rendering"
- **Patch:** with notes. It applies cleanly to main but is not built. On main, use `goto fallback` rather than `return false`: since !44500, v3d's own fallback calls `util_gen_mipmap()` with NEAREST for formats the TMU cannot filter linearly, and the state tracker's generic fallback filters linearly. The check must then move below the `devinfo` declaration (`v3d_blit.c:258`), which the `fallback:` code uses (`:278-287`); jumping from the current insertion point would skip that initialisation. Reword the commit message: drop its last paragraph. Fix the trailer. A test run on Haiku was not recorded when this was written (the fix was committed 2026-11-20).
- **Upstream status (2026-11-20):** open. Code unchanged on main 901c006e67b: `src/gallium/drivers/v3d/v3d_blit.c:241-276` (`v3d_generate_mipmap()` sends every non-3D texture to the TFU) and `src/gallium/drivers/v3d/v3dx_tfu.c:147-152` (`NUMMM`; the OPAD of the first level only, "miplevel 1+ tiling state is inferred"). GitLab: searched "v3d mipmap", "v3d npot", "non-power-of-two v3d", "v3d TFU" and "v3d mipmap generation": no matching issue.

**System information.** Seen on a Raspberry Pi 4 (V3D 4.2) with the same gallium v3d driver code (Quake II model skins at a distance). Not yet re-run on Haiku (hrev60431, Mesa 26.2.7 + haiku-pi fork). Linux: same driver and TFU job; the kernel only queues it.

**Describe the issue.** With `NUMMM > 0` the TFU takes the destination padding (OPAD) of the first level it writes and infers the tiling of the levels after it. That inferred layout matches `v3d_setup_slices()`, which is what the TMU samples, only for power-of-two base sizes. For other sizes the small UBLINEAR/LINEARTILE levels come out laid out differently. Near objects (level 0) look right, and distant objects with NPOT textures are drawn scrambled.

**How to reproduce.**
1. Create an RGBA8 texture of 260×195 (or 288×195, or 296×164).
2. Call `glGenerateMipmap`.
3. Sample levels ≥ 1, either with `textureLod` into an FBO or with `glGetTexImage` on desktop GL, and compare them with a CPU box filter.

In a real program: Quake II (yquake2 `ref_gl1`) model skins (banner 260×195, soldier 288×195, blaster 296×164) are scrambled at a distance. Upstream rpi4 CI (piglit `gpu` profile plus dEQP GLES mustpass) lists no failing NPOT mipmap test, so either no test exercises these sizes and levels or the tolerance hides the result. That should be checked against the piglit/dEQP mipmap tests before filing.

**Expected / Actual.** Expected: levels ≥ 1 are box-filtered images of the base. Actual: the small levels of NPOT textures read back mistiled.

**Regression.** Unknown. It is probably as old as TFU mipmap generation in v3d.

**Root cause.** `v3d_blit.c:241-276` does not check whether the inferred tiling matches the slice layout. See `v3dx_tfu.c:147-152`.

**Fix.** a4516893497 declines NPOT textures in `v3d_generate_mipmap()`, so they go to the render-based fallback, while power-of-two textures keep the TFU path. V3DV is not affected: nothing under `src/broadcom/vulkan` sets `NUMMM` (grep on main).

**Evidence.** The commit describes the Quake II symptom. We have no before/after numbers yet.

<a id="mesa-03"></a>

#### MESA-03 — mesa: GL_MESA_map_buffer_client_pointer's named `GL_CLIENT_POINTER_*_MESA` usages don't match the arithmetic Mesa (and Wine) use to decode them

- **GitLab labels:** `mesa` (core), `GL`
- **Severity:** wrong output. Six of the nine named usages give `GL_INVALID_ENUM` or the wrong usage hint.
- **Scope:** every driver that exposes the extension, on any OS (zink upstream; the fork's v3d).
- **Our fix:** none. Reported only; our tests use Wine's arithmetic.
- **Patch:** no. This needs a decision by the extension's owner: renumber the enums, or decode them with a table. See Fix.
- **Upstream status (2026-11-20):** open. On main 901c006e67b:
  - `include/GL/glext.h:9475-9483` defines the names densely, 0x9791…0x9799. The same values are in the registry copy `src/mesa/glapi/glapi/registry/gl.xml:7042-7050` and in `src/mesa/glapi/glapi/gen/MESA_map_buffer_client_pointer.xml:14-22`.
  - `src/mesa/main/bufferobj.c:212-224` (`buffer_usage_client_pointer()` / `buffer_arb_usage()`) decodes them by subtracting `GL_CLIENT_POINTER_STREAM_DRAW_MESA - GL_STREAM_DRAW` (0xEB1).
  - That decoded value is used for validation at `bufferobj.c:2455` and for the pipe usage at `:259`.
  - No spec text for the extension exists in the tree.
  - It shipped in 26.3.0 (c0bcffb1b0a, !43297). The 26.3.1 notes list only zink client-pointer fixes.
  - GitLab: searched "map_buffer_client_pointer" and "CLIENT_POINTER" (issues): none. MRs: !43297, !45553 and !45778 are zink fixes and do not touch the decoding. !40750 (radeonsi) is open.

**System information.** Haiku nightly (hrev60431), arm64, Raspberry Pi 4 Model B 4 GB (V3D 4.2); Mesa 26.2.7 + haiku-pi fork; Haiku's v3d kernel driver (Linux v3d uAPI). The fork's v3d exposes the extension. The defect is in core Mesa, so it is the same on Linux with zink.

**Describe the issue.** The GL buffer usages have gaps: 0x88E0–2, 0x88E4–6, 0x88E8–A. The named client-pointer usages are dense, but Mesa decodes them by a constant offset:

| Named constant | value | − 0xEB1 = | Mesa reads it as | correct? |
|---|---|---|---|---|
| `GL_CLIENT_POINTER_STREAM_DRAW_MESA` | 0x9791 | 0x88E0 | STREAM_DRAW | yes |
| `…_STREAM_READ_MESA` | 0x9792 | 0x88E1 | STREAM_READ | yes |
| `…_STREAM_COPY_MESA` | 0x9793 | 0x88E2 | STREAM_COPY | yes |
| `…_STATIC_DRAW_MESA` | 0x9794 | 0x88E3 | (none) → `GL_INVALID_ENUM` | no |
| `…_STATIC_READ_MESA` | 0x9795 | 0x88E4 | STATIC_DRAW | no |
| `…_STATIC_COPY_MESA` | 0x9796 | 0x88E5 | STATIC_READ | no |
| `…_DYNAMIC_DRAW_MESA` | 0x9797 | 0x88E6 | STATIC_COPY | no |
| `…_DYNAMIC_READ_MESA` | 0x9798 | 0x88E7 | (none) → `GL_INVALID_ENUM` | no |
| `…_DYNAMIC_COPY_MESA` | 0x9799 | 0x88E8 | DYNAMIC_DRAW | no |

Wine 11.21 encodes the usage the other way, with `usage + GL_CLIENT_POINTER_STREAM_DRAW_MESA - GL_STREAM_DRAW` (`dlls/opengl32/unix_wgl.c:1931-1932`). So Wine's round trip works for STREAM_\*, STATIC_\* and DYNAMIC_DRAW. Its DYNAMIC_READ and DYNAMIC_COPY become 0x979A and 0x979B, which are outside the range, so Mesa rejects them with `GL_INVALID_ENUM`. A WoW64 game that uses those usages gets GL errors.

**How to reproduce.** On a driver with the extension (zink, for example), call `glBufferData(GL_ARRAY_BUFFER, 4096, NULL, GL_CLIENT_POINTER_STATIC_DRAW_MESA)`. `glGetError()` returns `GL_INVALID_ENUM`. Also call `glBufferData(..., GL_DYNAMIC_READ + 0xEB1)`, which is Wine's encoding, and get `GL_INVALID_ENUM`. Our protocol test, `tools/gl-tests/clientptr.c` in the coordination repo, follows Wine's arithmetic and so does not trip on this.

**Expected / Actual.** Expected: each named constant is accepted and means its GL usage. Actual: see the table.

**Regression.** No. It has been present since the extension was added (c0bcffb1b0a, Mesa 26.3.0).

**Root cause.** `src/mesa/main/bufferobj.c:220-224` decodes by a constant offset, but the enum block (`include/GL/glext.h:9475-9483`, registry `gl.xml:7042-7050`) is dense.

**Fix (suggested, not written).** Two options:
- (a) Renumber the block to 0x9791 + (usage − 0x88E0), that is 0x9791–0x9793, 0x9795–0x9797, 0x9799–0x979B. Both implementations already use this arithmetic. It needs a registry `gl.xml` change, a `glext.h` update and possibly a dEQP change; Mesa CI already patches GL-CTS for this extension (`.gitlab-ci/container/build-deqp.sh:75-78`).
- (b) Keep the values and decode with a table in Mesa, with the matching change in Wine. The values stay stable, but every Wine already shipped keeps mis-encoding.

**Evidence.** Found by reading the code while porting the extension to v3d; it was not hit in our Warcraft III and d3dtest runs. See the design note `docs/design/gl-client-pointer.md` §8 and the KNOWN-ISSUES row W13.

<a id="mesa-04"></a>

#### MESA-04 — broadcom/compiler: register allocation and copy propagation scale as blocks × temps (large shaders compile slowly)

- **GitLab labels:** `v3d`, `v3dv`, `compiler`, `broadcom`
- **Severity:** performance
- **Scope:** all users of the V3D compiler (GL and Vulkan) on any OS.
- **Our fix:** haiku-pi/mesa `rpi4`:
  - `f55f89ccad9` — "broadcom/compiler: propagate defin/defout in program order"
  - `baaaeaef308` — "broadcom/compiler: liveness without passes over every temp of each block"
  - `76543fafdfc` — "broadcom/compiler: copy propagation keeps a list of the available MOVs"
- **Patch:** with notes. f55f89ccad9 and 76543fafdfc apply cleanly to main (not built). baaaeaef308 conflicts with upstream af333031d54 ("update liveness incrementally", !44177, fixes #16026, in 26.3.0), which removed most of the recomputations after spills. Rebase it or drop it. The gain on main is unmeasured: our 3.6× was measured on 26.2.x without af333031d54. Fix the trailers.
- **Upstream status (2026-11-20):** partly addressed. af333031d54 replaced the full liveness recomputation after each spill with an incremental update. Still on main 901c006e67b:
  - The forward defin/defout problem walks the blocks in reverse order: `src/broadcom/compiler/vir_live_variables.c:361`, iterated to a fixpoint at `:595`. That still runs in every full `vir_calculate_live_intervals()`: `vir_register_allocate.c:1582`, when the intervals are invalid at the start of an allocation, and `nir_to_vir.c:5352`.
  - Copy propagation's `apply_kills()` scans all temps for each instruction that writes a temp (`vir_opt_copy_propagate.c:236-247`) and clears the whole table for every block (`:265`), in every round of the VIR optimisation loop.
  - GitLab: searched "v3d compile time" and "v3d liveness". Found #16026 (closed 2026-08-07, a >30 s register-allocation ladder, fixed by af333031d54) and nothing about the remaining parts.

**System information.** Haiku nightly (hrev60431), arm64, Raspberry Pi 4 Model B 4 GB (V3D 4.2); Mesa 26.2.7 + haiku-pi fork; Haiku's v3d kernel driver (Linux v3d uAPI). Linux: the compiler is OS-independent.

**Describe the issue.** For a big shader (an unrolled WGSL loop: 667 blocks, 10.5k temps, 13k instructions) the compiler spent most of 33 s in three places:
1. The defin/defout dataflow is a forward problem visited in reverse block order. A definition moved one block per pass, so it took about as many passes as there are blocks in a row, each pass over all blocks and temps.
2. Liveness cleared per-block partial-update states and tested every temp's bits in every block on each recomputation.
3. Copy propagation's kills and per-block clears are O(temps).

**How to reproduce.** Compile a large shader with the shader cache disabled (`MESA_SHADER_CACHE_DISABLE=true`): the `issue-16026-pbr-uber` shader-db shader used in af333031d54, or Photocraft's compositor pipelines (`tools/photocraft-gpu-test`, `src/pipelines.rs`, in the coordination repo). Time the compile. `V3D_DEBUG=qpu,fs,vs,cs` output and shader-db stats show that the code is unchanged.

**Expected / Actual.** Expected: compile time grows roughly linearly with program size. Actual: about blocks × temps per recomputation.

**Regression.** No.

**Root cause.** `src/broadcom/compiler/vir_live_variables.c:361` (`vir_for_each_block_rev` for a forward problem); `src/broadcom/compiler/vir_opt_copy_propagate.c:236-247` and `:265`.

**Fix.**
- f55f89ccad9 visits the blocks in program order. The fixpoint is the same, and acyclic code reaches it in a couple of passes.
- baaaeaef308 tags states with their block, walks only the set words of `live_in & defin` and `live_out & defout`, and reuses one bitset allocation.
- 76543fafdfc keeps a list of the temps that have an available MOV, so kills and clears touch only those.

**Evidence.** Pi 4, cache off, on 26.2.x:
- the `fs_layerbatch` fragment shader went from 33.5 s to 6.6 s;
- Photocraft's 105 pipelines went from 43.1 s to 11.8 s (3.6×), and its first document now appears in 10 s instead of 30 s;
- the QPU code of all 105 shaders is identical and the shader-db stats are equal.

<a id="mesa-05"></a>

#### MESA-05 — egl/haiku: eglTerminate() with a context still current frees the display; releasing the context then uses it (crash)

- **GitLab labels:** `EGL`, `Haiku`
- **Severity:** crash
- **Scope:** Haiku platform code only (upstream `src/egl/drivers/haiku`), any gallium driver (llvmpipe/softpipe upstream).
- **Our fix:** haiku-pi/mesa `rpi4` `db2eac33c13` — "egl/haiku: a current context keeps its display; terminate releases resources"
- **Patch:** with notes. It applies cleanly to main but is not built. Fix the trailer. A second defect found by reading the code (below) is not fixed by it.
- **Upstream status (2026-11-20):** open. Code unchanged on main 901c006e67b: `src/egl/drivers/haiku/egl_haiku.cpp:416-420` (`haiku_terminate()` calls `haiku_display_destroy()` only), `:313-331` (it frees the screen and the display struct when the count reaches 0), `:471-512` (`haiku_make_current()` releases the old context through that display, `:507-508`). GitLab: searched "haiku egl" and "eglTerminate haiku" (issues), and "egl/haiku" (MRs: only older fixes, !30364 and !30372).

**System information.** Haiku nightly (hrev60431), arm64, Pi 4; the same with the upstream software path. Linux: not applicable. The DRI2 driver already holds a display reference for the current context and clears `DriverDisplay` (`src/egl/drivers/dri2/egl_dri2.c:1039`).

**Describe the issue.** The usual exit order `eglMakeCurrent(ctx)` → `eglTerminate()` → `eglReleaseThread()` crashes, as glmark2 does:
1. `eglTerminate` → `haiku_terminate` → `haiku_display_destroy`. The reference count goes from 1 to 0, so it runs `hgl_destroy_display()` and `screen->destroy()` and frees the struct, while the context is still bound.
2. `eglReleaseThread` → `Driver.MakeCurrent(disp, NULL, NULL, NULL)` (`src/egl/main/eglapi.c:1816`) → `haiku_make_current` → `haiku_destroy_context` → `hgl_destroy_context` → `st_context_flush` / `st_destroy_context` on a context whose `pipe_screen` has been destroyed.

**How to reproduce.** Run `tools/gl-tests/eglterm.c` in the coordination repo: pbuffer surface, GLES2 context, make current, `eglTerminate`, `eglReleaseThread`. It prints `EGLTERM ok` when both calls return.

**Expected / Actual.** Expected: both calls return. Actual: a crash in `eglReleaseThread()`.

**Regression.** Unknown. It is probably present since the gallium-based Haiku EGL driver (!21079, 2023).

**Root cause.** `egl_haiku.cpp:416-420` and `:471-512`: a bound context holds no reference to its display, and terminate does not release the display's resources first.

**Fix.** db2eac33c13 makes binding a context take a display reference and releasing the old context drop it, as egl_dri2 does. `haiku_terminate()` calls `_eglReleaseDisplayResources()` first.

**Also found by reading (not fixed, not reproduced).** `haiku_display_destroy()` (`:313-331`) never clears `disp->DriverDisplay`. A later `eglInitialize()` on the same display therefore finds the freed struct and only increments its count (`:383-392`, `if (hgl_dpy) { hgl_dpy->ref_count++; return EGL_TRUE; }`). Our fork has the same code. The fix is to set `disp->DriverDisplay = NULL` after `free()`.

**Evidence.** On the Pi 4 `eglterm` crashed before the fix and returns after it. GLTeapot is unchanged. The exit crash was first seen in glmark2.

<a id="mesa-06"></a>

#### MESA-06 — hgl: hgl_get_st_visual() leaves most of the caller's stack `st_visual` uninitialised (random sample count and buffer mask)

- **GitLab labels:** `Haiku`, `gallium` (frontend hgl)
- **Severity:** wrong output (undefined behaviour). With v3d, window buffers were 4× multisampled.
- **Scope:** Haiku platform code only (upstream `src/gallium/frontends/hgl`), every driver.
- **Our fix:** haiku-pi/mesa `rpi4` `1724b112520` — "hgl: zero the visual before filling it in"
- **Patch:** with notes: a one-line `memset`. It applies cleanly to main but is not built. Fix the trailer.
- **Upstream status (2026-11-20):** open. Code unchanged on main 901c006e67b: `src/gallium/frontends/hgl/hgl.c:294-337` sets the formats, ORs bits into `buffer_mask` and never sets `samples`. All callers pass an uninitialised stack struct (`src/egl/drivers/haiku/egl_haiku.cpp:111-112`, `:153-154`, `:432-433`). GitLab: searched "hgl visual" (issues) and "hgl" (MRs; !22512 is open but unrelated): none.

**System information.** Haiku nightly (hrev60431), arm64, Pi 4, v3d; the same on x86-64 with llvmpipe by construction. Linux: not applicable.

**Describe the issue.** `struct st_visual` (`src/gallium/include/frontend/api.h:150-165`) has `buffer_mask` and `samples`. `hgl_get_st_visual()` uses `|=` on the stack garbage in `buffer_mask` (`hgl.c:318-334`) and never writes `samples`. `samples` > 1 makes the state tracker create multisampled renderbuffers (`src/mesa/state_tracker/st_manager.c:510`, `:596-597`, `:650-651`). Stray `buffer_mask` bits make `hgl.c:110` allocate extra attachments.

**How to reproduce.** Any EGL window or pbuffer program on Haiku. With v3d, the default window's buffers were created 4× multisampled. In general the result depends on the stack contents, so `GL_SAMPLES` in a default window is unpredictable.

**Expected / Actual.** Expected: a single-sampled visual with the requested buffers. Actual: a random sample count and attachments.

**Regression.** Unknown.

**Root cause.** `hgl.c:294`: there is no initialisation of `*visual`.

**Fix.** `memset(visual, 0, sizeof(*visual))` at the top of `hgl_get_st_visual()`.

**Evidence.** On the Pi 4, v3d rendered window buffers as 4× MSAA before the fix and single-sampled after it.

<a id="mesa-07"></a>

#### MESA-07 — v3d: the shader-variant cache runs BLAKE3 at every hash-table lookup

- **GitLab labels:** `v3d`, `Raspberry Pi`
- **Severity:** performance (CPU cost per draw that changes state)
- **Scope:** all users of the gallium v3d driver on any OS.
- **Our fix:** haiku-pi/mesa `rpi4` `ebf1ee1ff1b` — "v3d: hash shader-variant cache keys without a BLAKE3 per lookup"
- **Patch:** with notes. It applies cleanly to main but is not built. Fix the trailer.
- **Upstream status (2026-11-20):** open. Code unchanged on main 901c006e67b: `src/gallium/drivers/v3d/v3d_program.c:1032-1043` (`cache_hash()` runs `_mesa_blake3_init/update/update/final` and then `_mesa_hash_data`). GitLab: searched "v3d cache_hash". Related: #2153 (closed 2019, "v3d: reduce shader cache lookup overhead", the same lookup with the older FNV hash). No open issue.

**System information.** Haiku nightly (hrev60431), arm64, Raspberry Pi 4 Model B 4 GB (V3D 4.2); Mesa 26.2.7 + haiku-pi fork; Haiku's v3d kernel driver (Linux v3d uAPI). Linux: the same driver code.

**Describe the issue.** `cache_hash()` computes a full BLAKE3 over the variant key and the shader's stored BLAKE3 digest on every `_mesa_hash_table` lookup, which happens on every draw that changes state. The table only needs a well-mixed 32-bit value, and `key->blake3` is already a digest.

**How to reproduce.** Profile any GL program with frequent texture or state changes (for example SuperTuxKart's menu) with `perf` or Haiku's `profile`. `_mesa_blake3_*` called from `cache_hash` shows up.

**Expected / Actual.** Expected: a negligible lookup cost. Actual: 5.1 % of SuperTuxKart's CPU time in its menu on a Pi 4.

**Regression.** Unknown. The commit that introduced BLAKE3 into `cache_hash()` was not identified.

**Root cause.** `v3d_program.c:1032-1043`.

**Fix.** `_mesa_hash_data(key->blake3, BLAKE3_KEY_LEN)` seeds `_mesa_hash_data_with_seed(key->key, key_size, …)`. Equality is unchanged.

**Evidence.** SuperTuxKart's menu profile on the Pi 4 (`docs/design/perf-round-h20.md`, finding N4): `cache_hash` → `blake3_compress_*_portable`, called from `_mesa_hash_table_search`, was 5.1 % of the game's CPU time. No profile after the change is recorded; the fix shipped in mesa 26.2.6-3.

### 2.2 Short form

<a id="mesa-08"></a>

#### MESA-08 — v3dv: timestampPeriod is taken from clock_getres(CLOCK_MONOTONIC), but the kernel writes timestamps in nanoseconds

- **What:** V3DV reports `VkPhysicalDeviceLimits::timestampPeriod` as the clock resolution in ns. The values written into query results are nanoseconds regardless of that resolution.
- **Severity / scope:** wrong output (timestamp queries scaled wrongly). It is latent on a standard Linux setup; all users of V3DV on any OS where `CLOCK_MONOTONIC`'s resolution is not 1 ns: Linux with low-resolution timers (`highres=off`, or a kernel without `CONFIG_HIGH_RES_TIMERS`), where `clock_getres` reports `TICK_NSEC` (for example 4 ms at HZ=250); — Haiku (1 µs).
- **Our fix:** part of haiku-pi/mesa `rpi4` `640e69292c3` — "v3dv: build and run on Haiku". In that commit it is guarded by `#if DETECT_OS_HAIKU`.
- **Patch:** no. Our change is Haiku-conditional and sits inside a port commit. The generic fix is one line, written fresh: `timestamp_period = 1.0f` unconditionally.
- **Upstream status:** open. Code unchanged on main 901c006e67b: `src/broadcom/vulkan/v3dv_device.c:1037-1040`. GitLab: searched "v3dv timestampPeriod": none.
- **Short form because:** latent on a standard Linux kernel; our fix is a Haiku-only hunk, the generic fix is one line still to write.

## 3. Wine

Wine `master` was read through the GitHub mirror `wine-mirror/wine` at **97027f879ba9** (2026-11-20), because
winehq.org was unreachable from our network; every Wine `file:line` is a master line number at that commit. For the
same reason **Bugzilla was not searched** for any entry: search it before filing, and check the component names
(our best guesses). Linux reproduction was tried only for WINE-01 (host build with AddressSanitizer). Our patches:
`patches/wine-11.21/`; test programs: `tools/wine-tests/`. Bug 59273 ("bad d3d streaming buffer flash range
tracking") may already cover WINE-04: read it first.

### 3.1 Full reports

<a id="wine-01"></a>

#### WINE-01 — server: cancel_process_async() uses an async that cancel_async() may already have freed (wineserver spins at 100 % or crashes)

- **Bugzilla fields:** Product: Wine · Component: `wineserver` · Version: 11.21 (development) · Hardware: All · OS: Other (Haiku) · Severity: major
- **Severity:** hang (wineserver busy loop, every client blocked); crash / heap use-after-free
- **Scope:** any OS where a completion APC cannot be queued: the bug is in generic code. On Linux it is latent. It is reachable only when no thread of the process takes the APC (`send_thread_signal()` fails). It was not reproduced with stock Linux signals (see Evidence).
- **Our fix:** `patches/wine-11.21/0026-server-cancel-async-keeps-reference.patch`
- **Patch:** MR-ready as-is. It is small, holds a reference across the cancel, and attaches the cancel object before cancelling.
- **Upstream status (2026-11-20):** open: the code is unchanged on master, `server/async.c:658-706`. Bugzilla: not searched (unreachable); web search "wineserver release_object refcount free_async_queue named pipe": no matching bug found.

**Environment.** Wine 11.21 (development) with our Haiku port patches; Haiku nightly hrev60431, arm64, Raspberry Pi 4 (Cortex-A72); x86 code under Box64 where relevant. Host reproduction: an x86-64 Linux wineserver built with AddressSanitizer whose `send_thread_signal()` is forced to fail.

**Description.** `cancel_process_async()` calls `cancel_async()` and then keeps using the async: it attaches the cancel object, does `list_remove()` and moves the async to the local `tracked` list. It does this without holding a reference of its own. `cancel_async()` → `fd_cancel_async()` → `async_terminate()` → `thread_queue_apc()` can fail. The APC is then destroyed at once, and `thread_apc_destroy()` (`server/thread.c:656-671`) calls `async_set_result()`. That function drops the queue's reference (`server/async.c:610-617`), which is often the last one, for example for an overlapped pipe read with no event. The async is freed inside `cancel_async()`. Afterwards it is written to and linked back into `process->asyncs`. Once its memory is reused for a new async, the list becomes a cycle. The next walk of it, `cancel_terminating_thread_asyncs()` at thread exit, never ends.

`async_terminate()` itself documents this hazard at `server/async.c:224-226` ("thread_queue_apc() may trigger async_set_result(), which may drop the last reference to the async, so grab a temporary reference here"). That temporary reference is released before `async_terminate()` returns, so it does not protect the caller.

A second effect: the cancel object is attached after the completion that should have released it. `NtCancelIoFile()`'s wait on it then never ends.

**Steps to reproduce.**
1. `tools/wine-tests/cancelio.c` runs overlapped named-pipe reads cancelled with `CancelIo()`, `CancelIoEx()` or both, for N rounds.
2. Run it on a wineserver where `send_thread_signal()` fails. On Linux, patch `send_thread_signal()` to return 0, which is what happens when the target thread's Unix TID is unknown or the thread is exiting.
3. Build the server with `-fsanitize=address`.
4. Without ASan, run `wineboot -i` on fresh prefixes in a loop (`WINEDEBUG=+server` shows the last request before the hang).

**Expected / Actual.**
- **Expected:** CancelIo completes, the overlapped I/O reports `STATUS_CANCELLED`, and the wineserver stays responsive.
- **Actual with ASan:** heap-use-after-free in `cancel_process_async()` (freed by `async_terminate()` ← `fd_cancel_async()` ← `cancel_async()`) at round 0.
- **Actual without ASan:** the client hangs in CancelIo, the server dies on CancelIoEx, or the wineserver spins at 100 % CPU with `process->asyncs` a two-element cycle.

**Root cause.** `server/async.c:681-691` (master, 2026-11-20): `cancel_async( async )` is followed by uses of `async` without `grab_object()`, and `cancel->count++` comes after the cancel.

**Fix.**
- `grab_object()` the async across the cancel and move it to the tracked list before `release_object()`.
- Attach `async_cancel` (and `count++`) before `cancel_async()`.
- Keep one count of the function's own on the cancel object. Allocate the wait handle only if `count > 1`, then drop that count.

**Evidence.**
- **Pi:** about one fresh prefix in 15 (`wineboot -i`) left the wineserver spinning. A core of the spinning server showed `process->asyncs` as a cycle of two freed asyncs (PC in `cancel_terminating_thread_asyncs()`).
- **Host, ASan + failing signals, unfixed:** 2 of 85 wineboot runs gave the use-after-free; `cancelio` hit it at round 0.
- **Host, fixed:** 0 of 75 wineboot runs; `cancelio` clean for 2000 rounds × io/ex/both.
- **Host, stock Linux signals:** 40 wineboots and `cancelio` 2000/2000 clean (latent there).
- **Pi with the fix:** `cancelio` 2000 rounds, 0 timeouts.

<a id="wine-02"></a>

#### WINE-02 — server: shared session objects can be misaligned, and the 64-bit store-release of their sequence number faults on arm64

- **Bugzilla fields:** Product: Wine · Component: `wineserver` · Version: 11.21 (development) · Hardware: ARM64 (aarch64) · OS: Other (Haiku) · Severity: major
- **Severity:** crash (the wineserver dies with an alignment fault and takes every Wine process with it)
- **Scope:** any OS on arm64. The faulting instruction is a misaligned `STLR`.
  - Linux arm64 on a Cortex-A72 (Armv8.0) should fault the same way. This is not tested.
  - Behaviour on cores with FEAT_LSE2 (Armv8.4+) was not checked.
  - On x86 the misaligned store is harmless.
- **Our fix:** `patches/wine-11.21/0029-server-align-shared-session-objects.patch`
- **Patch:** MR-ready as-is. It is one line: round the object size up to 8.
- **Upstream status (2026-11-20):** open: the code is unchanged on master, `server/mapping.c:1483-1499`. Bugzilla: not searched (unreachable); web search "wineserver arm64 alignment fault alloc_shared_object SHARED_WRITE_BEGIN": none found.

**Environment.** Wine 11.21 (development) with our Haiku port patches; Haiku nightly hrev60431, arm64, Raspberry Pi 4 (Cortex-A72); x86 code under Box64 where relevant.

**Description.**
- `alloc_shared_object()` carves each new object out of the session block right after the previous one: `block->used_size += size`.
- `size` includes the class or window extra bytes: `alloc_shared_object( offsetof(class_shm_t, extra[cls_extra]) )` at `server/class.c:69`, and `offsetof(window_shm_t, extra[extra_size])` at `server/window.c:744`. `cbClsExtra` / `cbWndExtra` can be any value.
- An object whose size is not a multiple of 8 therefore misaligns the next object.
- `SHARED_WRITE_BEGIN` (`server/file.h:198-205`) writes the next object's `seq` with `WriteRelease64()`, which is `STLR` on aarch64. A misaligned address raises an alignment fault and the wineserver dies.

**Steps to reproduce.**
1. **Observed case:** on the arm64 host, run the InstallShield setup of the *Need for Speed: Porsche Unleashed* demo.
2. **Minimal case (derived from the code, untested):** on an arm64 host (wineserver native arm64), run a program that registers a window class with `cbWndExtra` (or `cbClsExtra`) large enough that the object exceeds `sizeof(object_shm_t)` and is not a multiple of 8, for example 1001. Create a window of that class, then create further windows or classes.

**Expected / Actual.**
- **Expected:** windows are created.
- **Actual:** the wineserver gets SIGBUS (alignment exception) in `alloc_shared_object()` / `SHARED_WRITE_BEGIN`, and every client loses its server.

**Root cause.** `server/mapping.c:1486` (master, 2026-11-20) computes `size` without alignment, and `:1495-1498` places objects back to back.

**Fix.** `size = (size + sizeof(LONG64) - 1) & ~(mem_size_t)(sizeof(LONG64) - 1);` before the free-list lookup.

**Evidence.** The NFS: Porsche Unleashed demo setup killed the wineserver 2 of 2 times on the Pi. With the fix the setup completes.

<a id="wine-03"></a>

#### WINE-03 — wined3d: the command-stream queue indices are read without acquire, so the CS thread executes stale packets on weakly ordered CPUs

- **Bugzilla fields:** Product: Wine · Component: `directx-d3d` · Version: 11.21 (development) · Hardware: ARM64 (aarch64) · OS: Other (Haiku) · Severity: major
- **Severity:** crash / data corruption ("wined3d_cs_execute_next Invalid opcode", page faults in the CS thread)
- **Scope:** any OS on a weakly ordered CPU.
  - **Observed:** the i386 wined3d running under an x86 emulator that does not emulate x86 ordering for plain moves. That is Box64 with its default `BOX64_DYNAREC_STRONGMEM=0`, via WoW64 on arm64.
  - **Generic but not observed:** native arm64 builds also read `head` with a plain volatile load and no acquire, at `cs.c:3390`.
- **Our fix:** `patches/wine-11.21/0018-wined3d-cs-queue-index-barriers.patch`
- **Patch:** with notes:
  - The `ReadAcquire()` / `WriteRelease()` helpers for non-i386 are a plain correctness fix.
  - The `#ifdef __i386__` path uses `InterlockedCompareExchange` / `InterlockedExchange` so that an emulator translates them with barriers. That is an accommodation for emulators that relax x86 ordering, and maintainers may prefer to drop it.
  - The patch does not touch the volatile read of `tail` in `wined3d_cs_mt_finish()` (`cs.c:3503`). It should be converted too for consistency.
- **Upstream status (2026-11-20):** open: the code is unchanged on master. Volatile index reads are at `dlls/wined3d/cs.c:3390`, `:3458`, `:3503` and `dlls/wined3d/wined3d_private.h:3905`. Bugzilla: not searched (unreachable); web search "wined3d_cs_execute_next Invalid opcode box64 arm64 memory ordering": none found. Related on the emulator side: Box64 issue #4606 (STRONGMEM barriers), open.

**Environment.** Wine 11.21 (development) with our Haiku port patches; Haiku nightly hrev60431, arm64, Raspberry Pi 4 (Cortex-A72). The 32-bit program and the i386 wined3d run under Box64 v0.4.4 (wowbox64) in WoW64.

**Description.** The application thread writes a packet and then publishes it with `WriteRelease(&queue->head, …)`. The CS thread tests `wined3d_cs_queue_is_empty()` with `*(volatile ULONG *)&queue->head == queue->tail`, which has no acquire, and then reads the packet. On arm64 the packet loads may be satisfied before the `head` load. On i386 the acquire/release forms compile to plain `mov`, which is correct on x86 hardware. An x86 emulator that maps plain moves to unordered arm64 loads and stores (Box64's default) loses that ordering. The CS thread then decodes stale packet bytes.

**Steps to reproduce.**
1. Use arm64 Wine in WoW64 mode with Box64's `wowbox64.dll` as the x86 back end and default Box64 settings.
2. Run a 32-bit Direct3D or DirectDraw program on the OpenGL renderer, for example the SimCity 3000 demo.
3. Repeat starts with `WINEDEBUG=+d3d` or just stderr. Our start loop greps the output for "Invalid opcode".

**Expected / Actual.**
- **Expected:** the game renders.
- **Actual:** `err:d3d:wined3d_cs_execute_next Invalid opcode …` or a page fault in the CS thread, in 6 of 8 starts. With `BOX64_DYNAREC_STRONGMEM=1` it is 0 of 8.

**Root cause.**
- `dlls/wined3d/cs.c:3390` (`wined3d_cs_queue_is_empty`), `:3458` (`wined3d_cs_queue_require_space`, tail), `:3503` (`wined3d_cs_mt_finish`, tail) and `dlls/wined3d/wined3d_private.h:3905` (`wined3d_resource_wait_idle`, tail) use plain volatile loads where an acquire is needed.
- The release stores are at `cs.c:3401` and `:3603`.

**Fix.** Add `wined3d_cs_queue_read_index()` / `wined3d_cs_queue_write_index()` helpers that do an acquire load and a release store, and use them for every head/tail access. On i386 the helpers use locked instructions.

**Evidence.** On the Pi, the SimCity 3000 demo had 6/8 corrupted starts unfixed and 0/8 with the patched i386 `wined3d.dll`. After packaging, 8/8 starts were clean, and a short sweep of StarCraft, Half-Life, Heroes III and Fallout was unchanged.

<a id="wine-04"></a>

#### WINE-04 — opengl32: WoW64 copies a whole write-only flush-explicit buffer mapping in and out, instead of copying only the flushed ranges

- **Bugzilla fields:** Product: Wine · Component: `opengl` · Version: 11.21 (development) · Hardware: All · OS: Other (Haiku) · Severity: normal
- **Severity:** performance (a 32-bit Direct3D game at 3 fps, with memcpy at 53 % of the time)
- **Scope:** any OS in new-WoW64 mode whose GL driver lacks all three of the faster paths: `GL_MESA_map_buffer_client_pointer`, placed Vulkan memory mapping, and `GL_AMD_pinned_memory`. With those, maps go through the copy path at `unix_wgl.c:1689-1699`. The Pi 4's V3D with Mesa 26.2 is such a driver; Linux on the same hardware should behave the same.
- **Our fix:** `patches/wine-11.21/0028-opengl32-wow64-flush-explicit-copies-flushed-ranges.patch`
- **Patch:** MR-ready as-is. When the driver offers `GL_MESA_map_buffer_client_pointer`, upstream's own path takes over and this code is not reached.
- **Upstream status (2026-11-20):** open: the copy-path code is unchanged on master, `dlls/opengl32/unix_wgl.c:1689-1699` (copy in), `:1868-1873` (copy back at unmap) and `:1370-1386` (`flush_buffer`, Vulkan only). Bugzilla: not searched (unreachable). A web search for "wow64 glMapBufferRange GL_MAP_FLUSH_EXPLICIT_BIT 'Doing a copy of a mapped buffer'" listed a possibly related **bug 59273**, titled "bad d3d streaming buffer flash range tracking". According to the search engine's summary it is about Dungeon Keeper 2 and whole-buffer maps. It also pointed to a wine-gitlab thread that apparently says the unmap copy happens because flush ranges are not tracked. Neither page was opened, and the status of 59273 is unknown. Read 59273 before filing; it may be this bug.

**Environment.** Wine 11.21 (development) with our Haiku port patches; Haiku nightly hrev60431, arm64, Raspberry Pi 4 (Cortex-A72, V3D, Mesa 26.2.6 without `GL_MESA_map_buffer_client_pointer`); the 32-bit games under Box64.

**Description.** For every update of a dynamic buffer, wined3d maps the whole buffer object, `glMapBufferRange(0, size)`, with `GL_MAP_WRITE_BIT | GL_MAP_FLUSH_EXPLICIT_BIT | GL_MAP_UNSYNCHRONIZED_BIT`, and then flushes only the ranges it wrote. When the host pointer is above 4 GiB, `wow64_map_buffer()` allocates a low copy and handles it as follows:
- On map it copies the whole range in, because no invalidate bit is set.
- On unmap it copies the whole range back.

That is two full-buffer copies per update. Without `GL_MAP_READ_BIT` the mapping's initial contents are undefined. With `GL_MAP_FLUSH_EXPLICIT_BIT` only the flushed subranges are defined to reach the buffer. So such a mapping needs no copy in, and only the flushed ranges need to be copied back.

**Steps to reproduce.**
1. Use a GL driver without the three fast paths above, in new-WoW64 mode.
2. Run a 32-bit Direct3D 8/9 game that updates dynamic vertex buffers, for example the Warcraft III demo menu, with `WINEDEBUG=+fps`.
3. With `WINEDEBUG=+opengl`, the trace shows "Copying … from buffer … to wow64 buffer" for whole buffers on every map, and the fixme "Doing a copy of a mapped buffer (expect performance issues)".

**Expected / Actual.**
- **Expected:** the copy cost is proportional to the data written.
- **Actual:** the whole buffer is copied twice per map. The Warcraft III demo menu runs at 3 fps, with memcpy at 53 % of the profile, all under `wow64_ext_glMapBufferRange` and `wow64_glUnmapBuffer`.

**Root cause.**
- `dlls/opengl32/unix_wgl.c:1689` sets `copy_length = length` for any write mapping.
- `:1690-1699` copies in unless an invalidate bit is set.
- `flush_buffer()` (`:1370-1386`) only handles Vulkan-backed memory.

**Fix.**
- For a mapping with `GL_MAP_FLUSH_EXPLICIT_BIT` and without `GL_MAP_READ_BIT`, record `flush_explicit` and `map_length`, set `copy_length = 0`, and skip the copy-in.
- In `flush_buffer()`, copy `[offset, offset+length)` from the low copy to the host pointer, after a bounds check against `map_length`. Both pointers refer to the start of the mapped range, as in `glFlushMappedBufferRange()`.
- Clear the flag at unmap.

**Evidence.** Measured A/B on the same boot:

| Program (demo) | Before (fps) | After (fps) |
|---|---|---|
| Warcraft III, menu | 3 | 12 |
| Warcraft III, in game | 1–3 | 11–18 |
| NFS: Porsche Unleashed, menus | 2.5 | 26 |
| Unreal Tournament, Direct3D | 6 | 16 |
| Age of Empires II | 32 | 32 (unchanged) |

<a id="wine-05"></a>

#### WINE-05 — comdlg32: the item dialog (IFileDialog) does not select the proposed file name, so a typed name is inserted in front of it

- **Bugzilla fields:** Product: Wine · Component: `comdlg32` · Version: 11.21 (development) · Hardware: All · OS: All · Severity: normal
- **Severity:** wrong output (wrong file name saved)
- **Scope:** any OS; this is pure Win32 behaviour.
- **Our fix:** `patches/wine-11.21/0022-comdlg32-itemdlg-select-proposed-name.patch`
- **Patch:** MR-ready as-is (one `EM_SETSEL`). A conformance test in `dlls/comdlg32/tests/itemdlg.c` would help it land.
- **Upstream status (2026-11-20):** open: the code is unchanged on master, `dlls/comdlg32/itemdlg.c:2194-2195`. Bugzilla: not searched (unreachable); web search "IFileDialog save dialog file name not selected … Notepad++ itemdlg": none found.

**Environment.** Wine 11.21 (development) with our Haiku port patches; Haiku nightly hrev60431, arm64, Raspberry Pi 4 (Cortex-A72); Notepad++ (x86, under Box64).

**Description.** `on_wm_initdialog()` puts the proposed name (`IFileDialog::SetFileName`, e.g. Notepad++'s "new 1") into the name field and focuses it with `SetFocus()`. `SetFocus()` leaves the caret at the start with nothing selected; only the dialog manager's own initial focus selects an edit's text. On Windows the proposed name is selected, and typing replaces it.

**Steps to reproduce.**
1. In Notepad++ (or any program using `IFileSaveDialog` with `SetFileName`), open a new document.
2. Press Ctrl+S.
3. Type `mytest` and press Enter.

**Expected / Actual.**
- **Expected:** `mytest.txt` is saved.
- **Actual:** `mytestnew 1.txt` is saved.

**Root cause.** `dlls/comdlg32/itemdlg.c:2194-2195` (master, 2026-11-20): `SetFocus(hitem)` with no selection.

**Fix.** Send `SendMessageW(hitem, EM_SETSEL, 0, -1)` after `SetFocus()`.

**Evidence.** Notepad++ saved "nptestnew 1.txt" before the fix and "nptest.txt" after it. Wine's own Notepad uses the old-style dialog and was already right.

<a id="wine-06"></a>

#### WINE-06 — wined3d: the GLSL blitter declines a P8 → drawable blit on GL 2.1, which leads to endless recursion and a stack overflow

- **Bugzilla fields:** Product: Wine · Component: `directx-d3d` · Version: 11.21 (development) · Hardware: All · OS: Other (Haiku) · Severity: major
- **Severity:** crash (stack overflow)
- **Scope:** any OS whose GL driver lacks `ARB_texture_rg`, so that P8 is `GL_ALPHA8` and not FBO-attachable. That covers OpenGL 2.1 drivers such as Mesa V3D's desktop profile on the Pi 4. A Linux reproduction on the same driver should behave the same; this is not tested.
- **Our fix:** `patches/wine-11.21/0017-wined3d-glsl-blitter-p8-to-drawable.patch`
- **Patch:** MR-ready as-is.
- **Upstream status (2026-11-20):** open: the code is unchanged on master, `dlls/wined3d/glsl_shader.c:12881-12886` (in `glsl_blitter_supported()`, `:12815`). Bugzilla: not searched (unreachable); not web searched.

**Environment.** Wine 11.21 (development) with our Haiku port patches; Haiku nightly hrev60431, arm64, Raspberry Pi 4 (Cortex-A72, V3D, desktop OpenGL 2.1); 32-bit games under Box64; renderer=gl.

**Description.** `glsl_blitter_supported()` rejects any destination format that is neither FBO-attachable nor a render target. It does this even when the destination location is `WINED3D_LOCATION_DRAWABLE`, which renders into the window's framebuffer and never attaches the texture. For an 8-bit DirectDraw front buffer on GL 2.1 the blit therefore goes to the CPU blitter. The CPU blitter loads the drawable location again, which blits again, and the recursion never ends.

**Steps to reproduce.**
1. Use a GL 2.1 driver without `ARB_texture_rg`, `WINE_D3D_CONFIG=renderer=gl`.
2. Run StarCraft (640x480x8) or an 8 bpp DirectDraw test (`tools/wine-tests/ddtest.c` in 8 bpp mode), with `WINEDEBUG=+d3d_shader`.

**Expected / Actual.**
- **Expected:** the palette-converted frame is shown.
- **Actual:** the trace shows "Destination texture is not FBO attachable." repeatedly, followed by a stack overflow.

**Root cause.** `dlls/wined3d/glsl_shader.c:12881-12886` (master, 2026-11-20).

**Fix.** Apply the attachability check only when `dst_location != WINED3D_LOCATION_DRAWABLE`.

**Evidence.**
- 8 bpp ddtest on GL: the colour bars and grey ramp are exact.
- StarCraft shows its animated menu instead of crashing.
- An OpenGL-renderer sweep (StarCraft, SimCity 3000, Half-Life, Heroes III, Fallout) was clean.

<a id="wine-07"></a>

#### WINE-07 — server: free_async_queue() releases an async twice when it completes during termination (wineserver aborts at exit before saving the registry)

- **Bugzilla fields:** Product: Wine · Component: `wineserver` · Version: 11.21 (development) · Hardware: All · OS: Other (Haiku) · Severity: major
- **Severity:** crash (wineserver `release_object: obj->refcount` assertion) leading to data loss (the registry is not saved)
- **Scope:** latent in generic code; observed on Haiku only.
  - The double release needs `async_terminate()` to complete the async inline, which happens when no APC can be queued.
  - On Haiku this happened at every wineserver exit, on a named-pipe listen queue.
  - Why stock Linux does not hit it at exit is not established. Probably its process-exit path terminates those asyncs earlier.
- **Our fix:** `patches/wine-11.21/0014-server-async-queue-single-release.patch`
- **Patch:** MR-ready as-is: `list_remove()` and `async->queue = NULL` before `async_terminate()`.
- **Upstream status (2026-11-20):** open: the code is unchanged on master, `server/async.c:272-284`. Bugzilla: not searched (unreachable); web search "wineserver release_object refcount free_async_queue named pipe abort": only old, unrelated bugs (7286, 49889).

**Environment.** Wine 11.21 (development) with our Haiku port patches; Haiku nightly hrev60431, arm64, Raspberry Pi 4 (Cortex-A72); x86 code under Box64 where relevant.

**Description.** `free_async_queue()` calls `async_terminate( async, STATUS_HANDLES_CLOSED )` while the async is still on the queue with `async->queue` set. If the APC cannot be queued, `async_set_result()` runs inline (`server/async.c:610-617`). It does `list_remove()`, clears `async->queue` and releases the queue's reference. `free_async_queue()` then releases the same reference again at `:282`, and the object's refcount underflows. In our case it happened at the wineserver's exit, before the registry was saved. A value written shortly before the exit, for example with `reg add`, was lost.

**Steps to reproduce.**
1. Have a named-pipe server with a pending listen (any wineboot'ed prefix has some).
2. Arrange for the APC to fail at destruction, e.g. the owning process is gone.
3. Then `reg add HKCU\Software\Test /v x /d 1` followed by the wineserver's exit (`wineserver -w`).
4. Check with `reg query`.

**Expected / Actual.**
- **Expected:** the server exits cleanly and the value is saved.
- **Actual:** the server aborts with `server/object.c:566:release_object: obj->refcount` (as logged on 11.20; the line number differs on master), and the value is lost.

**Root cause.** `server/async.c:280-282` (master, 2026-11-20): `async_terminate()` runs before the async leaves the queue.

**Fix.** Do `list_remove( &async->queue_entry ); async->queue = NULL;` before `async_terminate()`, then `release_object()`.

**Evidence.**
- Before the fix, every Wine program run on Haiku ended with this abort at server exit.
- A debug server logging refcount-0 releases named the async on a named-pipe listen queue.
- The `reg add` then exit test: stock LOST, fixed saved (2 of 2).
- It also explained a Half-Life launcher setting that did not stick.

<a id="wine-08"></a>

#### WINE-08 — ws2_32: get_local_ips() can put the loopback address first: the default-route flag is lost, and the metric comparison wraps

- **Bugzilla fields:** Product: Wine · Component: `winsock` · Version: 11.21 (development) · Hardware: All · OS: Other (Haiku) · Severity: normal
- **Severity:** wrong output. `gethostbyname(gethostname())` returns `127.x` first, and a game then disables UDP play and crashes at race start.
- **Scope:** any OS (logic bug).
  - It is masked on a typical Linux host, because the default route is listed first in `GetIpForwardTable()`.
  - It is reachable wherever another direct route of the default-route interface comes before its default route.
  - The comparator wraps for metric differences of 2^31 or more.
  - It is not reproduced on Linux.
- **Our fix:** `patches/wine-11.21/0033-ws2_32-local-ips-default-route-first.patch`
- **Patch:** MR-ready as-is: two small hunks.
- **Upstream status (2026-11-20):** open: the code is unchanged on master, `dlls/ws2_32/protocol.c:829` (comparator) and `:882-892` (per-interface merge). Bugzilla: not searched (unreachable); not web searched.

**Environment.** Wine 11.21 (development) with our Haiku port patches; Haiku nightly hrev60431, arm64, Raspberry Pi 4 (Cortex-A72); the game under Box64.

**Description.**
- **Lost default-route flag:** `get_local_ips()` stores one entry per interface. `default_route` is set only from the first route seen for that interface (`:897-899`). A later default route on an interface that already has an entry only lowers the metric (`:884-889`). So when host or network routes come first, as in Haiku's table, no interface is marked default.
- **Wrapping comparison:** `compare_routes_by_metric_asc()` returns `a->metric - b->metric` on `DWORD`s. A metric near `~0` wraps and sorts first.
- **Result:** together these put the loopback entry first.

**Steps to reproduce.**
1. Use a host whose route table lists a non-default direct route of the uplink interface before its default route.
2. Run `tools/wine-tests/localip.c` (prints the `gethostbyname()` order and the IP Helper tables; "LOCALIP game-probe: PASS|FAIL").
3. Real case: the *Need for Speed: Porsche Unleashed* demo race start.

**Expected / Actual.**
- **Expected:** the default-route interface's address comes first (Windows behaviour, KB Q160215).
- **Actual:** `127.12.34.56` (the magic loopback) comes first. Porsche Unleashed offers no UDP play and crashes at `Porsche.exe+0x8ced6` on every race start.

**Root cause.** `dlls/ws2_32/protocol.c:829` and `:884-889` (master, 2026-11-20).

**Fix.**
- Set `default_route` when any route of the interface is a default route.
- Compare metrics with `(a > b) - (a < b)`.

**Evidence.** On the Pi, together with two Haiku-only nsiproxy fixes, `localip-x86.exe` PASS (the LAN address first) and the race starts and drives. The control run with the unfixed libraries crashed as before.

<a id="wine-09"></a>

#### WINE-09 — wined3d: system memory is evicted under a live DC, so the GDI swapchain front buffer draws freed memory

- **Bugzilla fields:** Product: Wine · Component: `directx-d3d` · Version: 11.21 (development) · Hardware: All · OS: Other (Haiku) · Severity: normal
- **Severity:** data corruption / crash (stripes on screen, then a read fault on freed memory)
- **Scope:** any OS with the no-3D adapter (`WINE_D3D_CONFIG=renderer=gdi`, or DirectDraw without 3D); observed on Haiku only. Nothing in the path is platform-specific.
- **Our fix:** `patches/wine-11.21/0013-wined3d-no-sysmem-eviction-under-dc.patch`
- **Patch:** MR-ready as-is. An alternative is to set `pin_sysmem` when a DC is created.
- **Upstream status (2026-11-20):** open: the code is unchanged on master, `dlls/wined3d/texture.c:122-147` (`wined3d_texture_evict_sysmem`, no DC check), called from `:160-163`. Bugzilla: not searched (unreachable); not web searched.

**Environment.** Wine 11.21 (development) with our Haiku port patches; Haiku nightly hrev60431, arm64, Raspberry Pi 4 (Cortex-A72); Half-Life (x86, Box64), `renderer=gdi`.

**Description.**
- `wined3d_texture_create_dc()` builds a DIB section over the texture's system memory, and the DC keeps using that memory.
- `wined3d_texture_evict_sysmem()` frees the memory when another location becomes valid, unless the texture is converted, pinned, or often downloaded. It does not check whether a DC exists.
- After `wined3d_swapchain_resize_buffers()` it freed the back buffer's memory under the GDI swapchain's DC.
- `swapchain_gdi_present()` (`dlls/wined3d/swapchain.c:1367-1400`) swaps front/back memory and DCs, so the front DC then drew from freed memory.

**Steps to reproduce.**
1. Set `WINE_D3D_CONFIG=renderer=gdi`.
2. Run a full-screen DirectDraw game that resizes its swapchain after taking exclusive mode (Half-Life software renderer, full screen), with `WINEDEBUG=+d3d`.
3. Look for "Evicting system memory for texture" right after `wined3d_swapchain_resize_buffers`.

**Expected / Actual.**
- **Expected:** the picture.
- **Actual:** vertical stripes and a black band. The DC's bits point to `0x073e0030` while the texture's memory is `0x0fb10030`, and reading them faults.

**Root cause.** `dlls/wined3d/texture.c:127-133` (master, 2026-11-20): the eviction guard does not consider `dc_info[i].dc`.

**Fix.** Do not evict while any sub-resource has a DC (`wined3d_texture_has_dc()`).

**Evidence.** Half-Life: Uplink full screen on the GDI renderer: stripes before the fix, the intro and first map after it (with WINE-10 also applied). A debug wined3d confirmed the DC-vs-memory mismatch.

### 3.2 Short form

<a id="wine-10"></a>

#### WINE-10 — wined3d: a full-screen GDI swapchain whose window is hidden presents into nothing

- **What:** On Windows the front buffer of an exclusive full-screen swapchain is the screen. wined3d's GDI swapchain instead blits it into the swapchain window's DC. Half-Life's launcher takes exclusive mode with its own window.
- **Severity / scope:** wrong output (white screen; game invisible); any OS with the no-3D adapter: win32u gives every hidden window the dummy surface, whatever the driver. Observed on Haiku only, not reproduced on Linux.
- **Our fix:** `patches/wine-11.21/0012-wined3d-gdi-fullscreen-hidden-window.patch`
- **Patch:** with notes. Using the process's foreground window is a heuristic. Maintainers may prefer presenting to the screen, i.e. the desktop DC, which matches Windows' "front buffer is the screen". That alone fails on drivers without a desktop surface (see WINE-11).
- **Upstream status:** open: the code is unchanged on master, `dlls/wined3d/swapchain.c:1327-1365` (`swapchain_gdi_frontbuffer_updated` blits to `swapchain->dc`). Bugzilla: not searched (unreachable); not web searched.
- **Short form because:** presentation detail seen with our Wayland-based window path.

<a id="wine-11"></a>

#### WINE-11 — ddraw: when the exclusive swapchain window is not the foreground window, the screen DC is drawn, which shows nothing on winewayland

- **What:** `ddraw_surface_update_frontbuffer()` draws to the screen DC (`GetDC(NULL)`) when the swapchain window is not in front. Half-Life hides that window and plays in its own popup. winewayland has no desktop surface, so drawing on the screen DC shows nothing.
- **Severity / scope:** wrong output (white screen); any OS with a window driver that has no desktop surface: winewayland is upstream, so Linux Wayland should behave the same. Not reproduced on Linux.
- **Our fix:** `patches/wine-11.21/0016-ddraw-hidden-swapchain-window-foreground.patch`
- **Patch:** with notes. It uses the same foreground-window heuristic as WINE-10. Maintainers may prefer a winewayland-side fix, for example a desktop surface.
- **Upstream status:** open: the code is unchanged on master, `dlls/ddraw/surface.c:180` (`GetDC(NULL)` in `ddraw_surface_update_frontbuffer()`, `:73`). Bugzilla: not searched (unreachable); not web searched.
- **Short form because:** shows on winewayland only.

<a id="wine-12"></a>

#### WINE-12 — ddraw: SetDisplayMode() leaves the exclusive window's present rect at the old mode, which makes an oversized window surface under emulated modes

- **What:** wined3d sets the exclusive window's present rect in `wined3d_swapchain_state_setup_fullscreen()` (`swapchain.c:2377-2390`) using the mode current at that moment. Half-Life calls SetCooperativeLevel at the desktop's 1920x1080 and then SetDisplayMode(640x480).
- **Severity / scope:** performance (a 4352x2688, 47 MB, surface copied every frame instead of 1536x1152); any OS with win32u's emulated display modes (winewayland always; other drivers when mode setting is emulated). Not reproduced on Linux.
- **Our fix:** `patches/wine-11.21/0010-ddraw-present-rect-follows-display-mode.patch`
- **Patch:** with notes. ddraw calls `D3DKMTEscape(D3DKMT_ESCAPE_SET_PRESENT_RECT_WINE)` and `SetWindowPos()` itself. Maintainers may prefer a wined3d helper, matching what wined3d already does for fullscreen→fullscreen mode changes (`dlls/wined3d/swapchain.c:2580`).
- **Upstream status:** open: master `ddraw7_SetDisplayMode()` (`dlls/ddraw/ddraw.c:1087`) sets the mode at `:1139` and does not update the present rect. Bugzilla: not searched (unreachable); not web searched.
- **Short form because:** performance under emulated modes.

<a id="wine-13"></a>

#### WINE-13 — winewayland: a full-screen window of an emulated mode is presented stretched to the visible rect (wrong aspect, right edge cut)

- **What:** For an emulated 640x480 mode on 1920x1080, win32u draws the window's contents into its window rect (240,0)-(1680,1080), at one scale for both axes, and stretches its visible rect over the monitor. winewayland presents the visible rect. The buffer is 1536 px wide (1440 drawn, rounded up to 128) and is scaled to 1920, so the picture is 1800 px wide with its right part cut off.
- **Severity / scope:** wrong output (picture stretched and cut off); winewayland on any OS (Linux Wayland compositors included). Not reproduced on Linux. It relies on the compositor centring a fullscreen surface smaller than the output, which xdg-shell allows. Haiku's server needed its own patch for that.
- **Our fix:** `patches/wine-11.21/0008-winewayland-fullscreen-emulated-mode-aspect.patch`
- **Patch:** with notes. Check the behaviour against mainstream compositors (GNOME, KDE, wlroots) before submitting.
- **Upstream status:** open: the code is unchanged on master, `dlls/winewayland.drv/window.c:141` (`conf->rect = data->rects.visible`). Bugzilla: not searched (unreachable); not web searched.
- **Short form because:** winewayland emulated modes only.

<a id="wine-14"></a>

#### WINE-14 — win32u: framebuffer surfaces attach colour textures with glFramebufferTexture (GL 3.2), so they are incomplete on OpenGL 2.1 drivers

- **What:** `create_framebuffer()` and the swap/blit code attach 2D colour textures with `glFramebufferTexture()`. That entry point is core only in GL 3.2 (or with geometry-shader extensions).
- **Severity / scope:** wrong output (incomplete framebuffer: `glCheckFramebufferStatus` ERR, nothing rendered); any OS with an OpenGL 2.1 driver that has `ARB_framebuffer_object` but not GL 3.2 / geometry shaders (e.g. Mesa V3D's desktop GL on the Pi 4). — Upstream reaches `framebuffer_surface_create()` for pbuffers the driver cannot create (`opengl.c:2510`) and for emulated mode setting (`:2351`). — We hit it through Haiku's surfaceless window path.
- **Our fix:** the `glFramebufferTexture` → `glFramebufferTexture2D` hunks of `patches/wine-11.21/0003-win32u-egl-gl21-window.patch`
- **Patch:** with notes: Extract only those hunks; the rest of 0003, the GDI present path for the surfaceless EGL driver, is Haiku glue. — Upstream also has `glFramebufferTexture` at `opengl.c:1030` and `:3958`, which our patch does not touch (they are not on our path) and which should be converted too.
- **Upstream status:** open: `dlls/win32u/opengl.c:878`, `:1030`, `:1191-1192`, `:1199-1200`, `:1206-1207`, `:3958`. Bugzilla: not searched (unreachable); not web searched.
- **Short form because:** OpenGL 2.1 drivers only; extracted from a Haiku glue patch.

<a id="wine-15"></a>

#### WINE-15 — win32u: the scaled window surface always stretches with HALFTONE on the CPU (full screen at 9.5 fps against 120 windowed)

- **What:** `scaled_surface_flush()` sets `STRETCH_HALFTONE` for every flush, and dibdrv computes it per pixel on the CPU. Each frame of an emulated 640x480 mode is stretched this way to the screen.
- **Severity / scope:** performance; any OS using win32u's scaled surfaces: emulated display modes, and DPI scaling when enlarging.
- **Our fix:** `patches/wine-11.21/0015-win32u-scaled-surface-enlarge-replicates.patch`
- **Patch:** with notes. This is a quality-versus-speed trade-off: nearest-pixel when enlarging, HALFTONE kept when shrinking. Upstream may prefer a faster HALFTONE in dibdrv, or a GPU scale. File it as an enhancement rather than an MR as-is.
- **Upstream status:** open: the code is unchanged on master, `dlls/win32u/dce.c:188`. Bugzilla: not searched (unreachable); not web searched.
- **Short form because:** performance.

<a id="wine-16"></a>

#### WINE-16 — setupapi: a prefix update rewrites every builtin DLL even when the file in the prefix is identical

- **What:** `wineboot -u` truncates and rewrites every builtin PE file in system32 and syswow64, about 0.9 GB for arm64 + i386. This happens even though, between two builds of one Wine version, most files are byte-identical (477 of 666 arm64 DLLs).
- **Severity / scope:** performance (prefix update time, disk wear); any OS; it matters most on slow storage and with large ARM64X builtins.
- **Our fix:** `patches/wine-11.21/0021-setupapi-skip-identical-fake-dlls.patch`
- **Patch:** with notes. It adds a read and compare of each existing file. On fast disks this may not pay off for a new Wine version, where most files differ. Measure it on Linux before an MR.
- **Upstream status:** open: master `install_fake_dll()` (`dlls/setupapi/fakedll.c:941`) and `delay_copy_files()` (`:983`) always call `create_dest_file()` (`:965`, `:1002`). Bugzilla: not searched (unreachable); not web searched.
- **Short form because:** performance of prefix updates.

## 4. FFmpeg

Checked against FFmpeg master `21c81303cb` and `release/6.1` `30e346c76f`. "Env" below means: Haiku nightly
hrev60431, arm64, Raspberry Pi 4 Model B 4 GB, firmware of 2026-10-15, `gpu_mem` 76 MB. FFmpeg asks for the full,
uncut output of `ffmpeg -v 9 -loglevel 99`: **none was captured** — run each command on the Pi with an unpatched
mmaldec and attach that output before filing.

### 4.1 Full reports

<a id="ffmpeg-01"></a>

#### FFMPEG-01 — avcodec/mmaldec: draining never sends end-of-stream, so the decoder's last frames are lost

- **Tracker fields:**
  - Summary: "mmaldec: last frames of a stream are lost at EOF (EOS buffer never sent since the receive_frame conversion)"
  - Component: avcodec
  - Version: git-master
  - Keywords: mmal h264_mmal
- **Severity:** wrong output (frames missing at the end of the output)
- **Scope:** Linux too (any MMAL host, i.e. 32-bit Raspberry Pi OS with the firmware decoders). The code path is OS-independent.
- **Our fix:** `patches/ffmpeg6/0002-mmal-haiku.patch`, the `AVERROR_EOF` and `eos_received` hunks. The same patch also carries Haiku glue (`#ifndef __HAIKU__`), the bsf, logging and tuning.
- **Patch:** with notes. Split out the two drain hunks (send EOS on `AVERROR_EOF`; return `AVERROR_EOF` once EOS has come back) and rebase onto master.
- **Upstream status (2026-11-20):** open. The code is unchanged at master `21c81303cb`, `libavcodec/mmaldec.c:788-793`.
  - Tracker: trac searched "h264_mmal", "mmal drain", "h264_mmal eof", "h264_mmal flush": none. code.ffmpeg.org searched "mmaldec", "h264_mmal": none.
  - Related, unmerged and older than the current code: patchwork "mmaldec: continue after receiving EOS without having sent one" (2021-02) and "mmaldec: fix decoder freeze when flushing" (2021-09).

**Environment.** FFmpeg 6.1.6 (HaikuPorts ffmpeg6) and Env. mmaldec's dataflow is the same on Linux. The bug was introduced by `b54377b3a7` ("avcodec/mmaldec: use decoupled dataflow"), which is in n5.0 and not in n4.4.

**Description.** With the receive_frame API, the end of input reaches the decoder as `AVERROR_EOF` from `ff_decode_get_packet()`, not as the empty packet the older decode callback received. `ffmmal_receive_frame()` returns any error other than EAGAIN at once. The end-of-stream buffer (`MMAL_BUFFER_HEADER_FLAG_EOS`, sent by `ffmmal_add_packet()` for an empty packet) is therefore never sent, and the frames the VideoCore still holds are dropped.

**Steps to reproduce.**
- Clip: `tools/media-tests/gen-h264-clips.sh` makes `h264-720p.mp4`, 300 frames (libx264 High, 3 B-frames). Any H.264 file will do.
- Command: `ffmpeg -v 9 -loglevel 99 -c:v h264_mmal -i h264-720p.mp4 -fps_mode passthrough -f framemd5 out.framemd5`
- Count the frames: `grep -vc '^#' out.framemd5`
- Our script for the same run: `tools/pi-tests/h264.sh ffmpeg`.

**Expected / Actual.** Expected: 300 frames. Actual: 290 (the last 5–10 frames are missing, varying with the stream's reorder depth).

**Root cause.** `libavcodec/mmaldec.c:788-793` (master `21c81303cb`):

```c
ret = ff_decode_get_packet(avctx, avpkt);
if (ret == 0) { ... }
else if (ret < 0 && !(ret == AVERROR(EAGAIN)))
    return ret;            /* AVERROR_EOF: EOS never sent, held frames never read */
```

**Fix.** On `AVERROR_EOF`, if no EOS has been sent yet, call `ffmmal_add_packet(avctx, avpkt, 0)` with the empty packet. That sends the EOS buffer and makes `ffmmal_read_frame()` wait for output. Return `AVERROR_EOF` only after the EOS has come back (`eos_received`), not EAGAIN.

**Evidence.** On the Pi, `ffmpeg -c:v h264_mmal` gave 290 of 300 frames before the fix. After it, 300 of 300 for both the 720p and the 1080p clip, every frame equal to the software decode except for the VideoCore's sub-black offset (documented in docs/design/vchiq.md §7.4 and §8.3).

<a id="ffmpeg-02"></a>

#### FFMPEG-02 — avcodec/mmaldec: an MMAL_EVENT_ERROR from the firmware is only logged, so the decoder outputs empty frames or loops

- **Tracker fields:**
  - Summary: "mmaldec: MMAL error event on the control port is ignored; decoder keeps returning blank frames / 'Did not get output frame from MMAL'"
  - Component: avcodec
  - Version: git-master
  - Keywords: mmal h264_mmal
- **Severity:** wrong output. With the firmware failed, it can lead to a hang (see USERLAND-02).
- **Scope:** Linux too. `control_port_cb()` is platform-independent; the trigger is a firmware error such as `MMAL_ENOSPC` when the VideoCore's memory is exhausted.
- **Our fix:** `patches/ffmpeg6/0002-mmal-haiku.patch`, the `ctx->error` and `stalls` hunks.
- **Patch:** with notes. Split from the Haiku glue. The 2 s stall limit (`MAX_STALLS` 20 × 100 ms) is a policy choice to discuss.
- **Upstream status (2026-11-20):** open. The code is unchanged at master `21c81303cb`, `libavcodec/mmaldec.c:237-239` and `:701-705`.
  - Tracker: trac searched "MMAL error 2", "MMAL error 2 on control port", "h264_mmal ENOSPC": none specific.
  - #8090 ("RPi 4 h264_mmal error", open, 2019, a hang after minutes) may be related but has no error-event log.

**Environment.** FFmpeg 6.1.6 and Env. The firmware, `gpu_mem` and the code path are the same on 32-bit Raspberry Pi OS.

**Description.**
- When the VideoCore's decoder fails (seen: `MMAL error 2 on control port`, i.e. `MMAL_ENOSPC`), mmaldec logs it and carries on. Packets are still sent, and frames come back grey and then green.
- At 1080p it loops on "Did not get output frame from MMAL." Each such 100 ms timeout returns `AVERROR_UNKNOWN` for that call only, so the caller never learns that the decoder is dead and cannot fall back to software.
- Conversely, a single 100 ms miss while the decoder is merely slow is reported as a hard error.

**Steps to reproduce.** On a Pi 4 with the default `gpu_mem` (76 MB):
- Command: `ffmpeg -v 9 -loglevel 99 -c:v h264_mmal -i play-1080p30.mp4 -f null -` (clip from `tools/media-tests/gen-h264-clips.sh`).
- The default `extra_buffers=10` exhausts the VideoCore's memory at 1080p.
- A second, concurrent `h264_mmal` decoder of a 1080p stream triggers the same error.

**Expected / Actual.** Expected: the decoder returns an error and stays in error, e.g. `AVERROR_EXTERNAL` from every later `receive_frame()`. Actual: `MMAL error 2 on control port` is logged, blank frames follow, and then "Did not get output frame from MMAL." repeats for every packet.

**Root cause.**
- `libavcodec/mmaldec.c:237-239` (master `21c81303cb`): `control_port_cb()` logs `MMAL_EVENT_ERROR` and drops it.
- `:701-705`: one `mmal_queue_timedwait(..., 100)` miss gives `AVERROR_UNKNOWN`.

**Fix.**
- Record the event's status in the context (an atomic, since the callback runs on the MMAL thread) and return `AVERROR_EXTERNAL` from `receive_frame()` from then on.
- Treat a single timed-out wait as "no frame yet". Only a run of misses (2 s) is a failure; while draining, such a run counts as end of stream.
- Related tuning, not a bug and not proposed here: the default `extra_buffers` 10 does not fit 1080p in 76 MB (we use 2).

**Evidence.**
- Before the fix: grey, then green frames; the Haiku media plugin never fell back to software.
- After it: the error reaches the caller, which falls back to the software decoder ("h264_mmal failed (…): h264 continues"). See docs/design/vchiq.md §8.2 and docs/design/firefox-video-overlay.md (the two-video page).

### 4.2 Short form

<a id="ffmpeg-03"></a>

#### FFMPEG-03 — avcodec/mmaldec: avctx->framerate is overwritten with the 24000/1001 placeholder sent to the firmware

- **What:** `ffmmal_init_decoder()` tells the VideoCore 24000/1001 frames/s for every stream. `ffmal_update_format()` then copies the output port's frame rate, which is that same number, into `avctx->framerate`, replacing the rate the caller or the container gave.
- **Severity / scope:** wrong output (stream metadata). An API user that trusts `avctx->framerate` plays at the wrong speed; Linux too. Platform-independent code.
- **Our fix:** `patches/ffmpeg6-next/0007-mmal-frame-rate.patch`
- **Patch:** attachable as-is after a rebase. The patch's own header says "`ffmpeg -c:v h264_mmal` showed 23.98 fps"; that was **not** reproduced in the CLI (docs/log/WEEK-2026-W47.md, 11-20 entry), so reword the commit message to the API-level effect before sending.
- **Upstream status:** open. The code is unchanged at master `21c81303cb`, `libavcodec/mmaldec.c:334-337` and `:406-407`. — Tracker: trac searched "h264_mmal 23.98", "mmal framerate": none. code.ffmpeg.org: none.
- **Short form because:** its test program is not written yet and the patch header overstates the symptom.

## 5. Blender

Checked against Blender `main` `597ee3aad0`; we patch Blender 3.6 (SDL backend, OpenGL 3.3). "Env": Haiku
nightly hrev60431, arm64, Raspberry Pi 4 Model B 4 GB. Blender declines reports reproducible only through
third-party software: reproduce on an official Linux build where the entry allows.

### 5.1 Full reports

<a id="blender-01"></a>

#### BLENDER-01 — GHOST_SDL: GPU contexts made with no context current do not share objects (Cycles viewport draws the icon atlas)

- **Tracker fields:** projects.blender.org issue.
  - System Information: Haiku arm64 (GHOST_SDL backend), Raspberry Pi 4 V3D 4.2 (Mesa); on Linux, any GPU with `-DWITH_GHOST_SDL=ON`.
  - Blender Version: Broken: 3.6.23 (verified); main `597ee3aad0` by code inspection. Worked: none known.
  - Short description: "GHOST_SDL: new contexts share with the *current* context only; contexts created while none is current get a private object namespace."
  - Exact steps: below.
  - Module: Platforms, Tools & Builds / GHOST. Patches go as a PR on projects.blender.org.
- **Severity:** wrong output (wrong texture shown)
- **Scope:** Linux too with `WITH_GHOST_SDL`, by code inspection; not reproduced on Linux. `SDL_GL_SHARE_WITH_CURRENT_CONTEXT` shares with the calling thread's current context on every SDL backend, and the code that creates a context with nothing current is generic (`RE_engine_gpu_context_create`).
- **Our fix:** `patches/blender/0013-ghost-sdl-share-with-first-context.patch`
- **Patch:** with notes. It is written against 3.6 and SDL2; main's GHOST_SDL is on SDL3 (`SDL_EVENT_*`, `context_` naming). The logic carries over: make `s_sharedContext` current (with its window) for `SDL_GL_CreateContext` when none is current, then restore.
- **Upstream status (2026-11-20):** open. The code is unchanged at main `597ee3aad0`, `intern/ghost/intern/GHOST_ContextSDL.cc:99` (`SDL_GL_SHARE_WITH_CURRENT_CONTEXT, 1`) and `:126-130` (`s_sharedContext` is recorded but never used for sharing). The caller is `source/blender/render/intern/engine.cc:1300-1301`.
  - Tracker: searched "GHOST_SDL", "SDL context share": none. #157126 (SDL build crash at start, archived) is unrelated.

**Environment.** Blender 3.6.23 (our build, GHOST_SDL over SDL 2) and Env. On Linux the same path is taken with `-DWITH_GHOST_SDL=ON`.

**Description.**
- `GHOST_ContextSDL::initializeDrawingContext()` asks SDL to share the new context with "the current one". GHOST's other backends (GLX, EGL, WGL, CGL) name the first context explicitly.
- `RE_engine_gpu_context_create()` first calls `DRW_gpu_context_release()` and then creates Cycles' display context, so nothing is current at that point.
- The new context therefore has its own textures and buffers. The texture name Cycles creates there means a different texture (Blender's icon atlas) in the window's context.

**Steps to reproduce.**
1. Build with `-DWITH_GHOST_SDL=ON` and start Blender.
2. Load the factory startup file.
3. Set the 3D viewport's shading to Rendered with Cycles as the engine.

Scripted run: `tools/pi-tests/blender-b7-view.sh` / `blender-b7-view.py`.

**Expected / Actual.** Expected: the progressive Cycles render. Actual: Blender's icon sheet is drawn in the viewport instead of the render.

**Root cause.** `intern/ghost/intern/GHOST_ContextSDL.cc:99` and `:126-130` (main `597ee3aad0`).

**Fix.** When `s_sharedContext` exists and `SDL_GL_GetCurrentContext()` is NULL, make the first context current on its window for the creation, then release it.

**Evidence.** Before the fix, the icon sheet appeared, also in the published blender-6 package. After it, the render appears, and denoised viewport renders work too (docs/design/blender.md §7.14; frames in `artifacts/blender-tests/`).

### 5.2 Short form

<a id="blender-02"></a>

#### BLENDER-02 — Movie output: "Output Quality" (CRF) is ignored by encoders without a `crf` option

- **What:** In CRF mode the writer sets `c->bit_rate = 0` and puts `crf` into the options dictionary. An encoder without that option leaves it unused and encodes at its own default (or treats the 0 rate as its own default), whatever the preset.
- **Severity / scope:** wrong output (every quality preset gives the same file); any platform where the encoder chosen for the codec has no `crf` AVOption: `avcodec_find_encoder(AV_CODEC_ID_H264)` in an FFmpeg built without libx264. FFmpeg master's `libopenh264` and `h264_v4l2m2m` have no `crf` option (checked in their option tables). — FFmpeg's native `mpeg4`, which `MOV_codec_supports_crf()` lists (#61708).
- **Our fix:** `patches/blender/0010-ffmpeg-bitrate-from-crf-for-encoders-without-crf.patch`
- **Patch:** with notes. It targets 3.6's `writeffmpeg.c`; main moved the logic to `source/blender/imbuf/movie/intern/movie_write.cc:743-810` (`set_quality_rate_options`). The CRF→bit-rate mapping (0.1 bit/pixel at CRF 23, ×2 per 6 steps) is a heuristic for maintainers to accept or replace, e.g. by falling back to the CBR fields.
- **Upstream status:** open. In `movie_write.cc:752` and `movie_util.cc:565-573` (main `597ee3aad0`), the decision is per codec id, not per encoder. — Tracker: searched "crf bitrate encoder" → #61708 (open, same root cause); "constant rate factor hardware encoder", "openh264 quality": none.
- **Short form because:** already reported upstream (#61708): comment there.

<a id="blender-03"></a>

#### BLENDER-03 — GPU (OpenGL): an unrecognised GL vendor is classified as every vendor, enabling all vendor workarounds

- **What:** An unknown vendor leaves `GPG.device = GPU_DEVICE_ANY`, so every `GPU_type_matches(GPU_DEVICE_INTEL…)`, `(…ATI…)` and similar rule is true. On V3D, Blender 3.6 enabled Intel's `clear_viewport_workaround`, turned `GL_ARB_texture_gather` off as for old NVIDIA GPUs, and `gpu.platform.device_type_get()` returned "APPLE".
- **Severity / scope:** wrong output (vendor workarounds applied to the wrong GPU); any OS, any OpenGL driver whose vendor/renderer string is not in the list. On main this needs a GL 4.3 driver with an unlisted vendor; V3D itself is below main's GL 4.3 minimum (`gl_backend.cc:223`). Not reproduced on main.
- **Our fix:** `patches/blender/0004-gpu-classify-v3d.patch`
- **Patch:** no. Ours adds only a V3D rule; the general fix is to use `GPU_DEVICE_UNKNOWN` (and an open-source or unknown driver type) in the final `else` branch.
- **Upstream status:** open. At main `597ee3aad0`, `source/blender/gpu/opengl/gl_backend.cc:135-137` initialises device and driver to `*_ANY`, and the `else` at `:211-216` only prints "Could not find a matching GPU name". `gpu_platform.cc:180` matches with a bitwise AND, so `ANY` matches every rule. Tracker: not searched beyond the issue search above.
- **Short form because:** affects only unrecognised GL vendors.

## 6. OpenImageDenoise

Checked against OpenImageDenoise `master` `6602ee2ca3`. "Env": Haiku nightly hrev60431, arm64, Raspberry Pi 4
Model B 4 GB.

<a id="oidn-01"></a>

#### OIDN-01 — core: does not compile on systems other than Windows, Linux and macOS (no ThreadAffinity fallback)

- **Tracker fields:** GitHub issue/PR on RenderKit/oidn.
  - Title: "core/thread.h: ThreadAffinity undefined on non-Windows/Linux/macOS systems (FreeBSD, Haiku)"
  - Environment: OIDN 2.5.1, CPU device.
  - Steps: build the CPU device on such a system.
- **Severity:** build
- **Scope:** every OS other than Windows, Linux and macOS (not Linux itself). FreeBSD ports carries the same kind of patch: `graphics/oidn/files/patch-core_thread.h` maps FreeBSD onto the Linux branch.
- **Our fix:** `tools/recipes/media-libs/oidn/patches/oidn-2.5.1.patchset`
- **Patch:** attachable as-is. It adds an `#else` no-op `ThreadAffinity` whose `getNumThreads()` returns 0, so the engine runs unpinned, as it does when detection fails on Linux.
- **Upstream status (2026-11-20):** open. At master `6602ee2ca3`, `core/thread.h:100/138/168` define `ThreadAffinity` for `_WIN32`, `__linux__` and `__APPLE__` only, while `devices/cpu/cpu_engine.cpp:26-33` instantiates it unless the target is macOS on ARM64.
  - Tracker: GitHub searched "ThreadAffinity" (issues and PRs): none. "FreeBSD" → #225 (a different build error).

**Environment.** OIDN 2.5.1 and Env (ISPC 1.32 `--arch=aarch64`). Equivalent: any POSIX OS without `__linux__`.

**Description.** `ThreadAffinity` is defined only for Windows, Linux and macOS, but the CPU engine uses it on every system except macOS on ARM64.

**Steps to reproduce.** Configure OIDN 2.5.1 with the CPU device for a non-Linux POSIX target (Haiku, or FreeBSD without the port's patch) and build. Compilation of `devices/cpu/cpu_engine.cpp` fails because `ThreadAffinity` is not declared.

**Expected / Actual.** Expected: builds, threads not pinned. Actual: compile error.

**Root cause.** `core/thread.h:100-195` (master `6602ee2ca3`): there is no `#else` branch before the `#endif` at :195.

**Fix.** Add a fallback class (no topology, `set`/`restore` no-ops).

**Evidence.**
- Builds with 0 warnings.
- `oidnBenchmark` RT hdr+alb+nrm at 1920×1080 on the Pi: 17.0 s per frame.
- Blender's Cycles denoiser works on top of it (docs/design/blender.md §7.14).

## 7. Box64 and FEX

Box64 `main` `3e5a0b598843` (2026-11-19; our base: v0.4.4) and FEX `main` `bce85d9941b2` (2026-11-20; our base:
FEX-2610). **Both projects restrict AI-generated contributions** (FEX: none at all): treat these entries as notes
for a report written by a person, not as patches to send.

### 7.1 Full reports

<a id="box64-01"></a>

#### BOX64-01 — wowbox64: GetSegmentBase() returns NULL for the TEB selector, so a program that reloads FS crashes on fs:[0x18]

- **GitHub issue fields:**
  - **Title:** `[WOWBOX64] Reloading FS with the TEB selector (0x53) gives base 0: fs:[0x18] reads address 0x18`
  - **Environment:** wowbox64.dll from Box64 v0.4.4 (main `3e5a0b598843` has the same code), Wine 11.21 arm64 WoW64, Haiku hrev60431 on Raspberry Pi 4 (Cortex-A72). The code path is host-independent: Linux arm64 Wine with wowbox64 should behave the same (not tested).
  - **Steps:** run a 32-bit program whose runtime does `mov fs, ax` with the selector it read from FS (Watcom C runtime, e.g. Fallout 1), then reads `fs:[0x18]`.
  - **Logs:** "GetSegmentBase does not apply to Wine dlls", then an access violation reading 0x00000018.
- **Severity:** crash
- **Scope:** any OS (WoW64 back end)
- **Our fix:** `patches/box64/0001-wowbox64-fs-selector.patch`
- **Patch:** MR-ready as-is (4 lines). It needs only a re-diff: the function moved from line 37 (v0.4.4) to 141 (main), and its body is unchanged.
- **Upstream status (2026-11-20):** open: `src/os/os_wine.c:141-145` on main still returns NULL. GitHub search for "GetSegmentBase wowbox64" and "wowbox64 fs selector": none.

**Environment.** Box64 v0.4.4 `wowbox64.dll` (also installed as `xtajit.dll`) with Wine 11.21 (development) and our Haiku port patches; Haiku nightly hrev60431, arm64, Raspberry Pi 4 (Cortex-A72).

**Description.** Under WoW64 a 32-bit thread starts with FS = 0x53, whose base is its 32-bit TEB. When translated code reloads FS, the base comes from `GetSegmentBase()`. In the Wine build that function prints a message and returns NULL, so the next `fs:[0x18]` (the TEB self pointer) reads address 0x18.

**Expected / Actual.**
- **Expected:** FS keeps the 32-bit TEB as its base.
- **Actual:** the program crashes. Fallout crashed at start-up.

**Root cause.** `src/os/os_wine.c:141-145` (main).

**Fix.** For selectors `0x53` (WoW64) and `0x3b` (32-bit Windows), masked with `~3`, return `calculate_fs()`, the thread's 32-bit TEB. Other selectors stay flat.

**Evidence.** Fallout (x86) goes on to Interplay's registration dialog and runs.

### 7.2 Short form

<a id="box64-02"></a>

#### BOX64-02 — wowbox64: every write access violation is treated as a write to translated code and retried, so a genuine write fault loops forever

- **What:** `BTCpuResetToConsistentState()` assumes that any write access violation hit a page the dynarec write-protected, because it holds translated code. It unprotects the page and continues.
- **Severity / scope:** hang; any OS (WoW64 back end)
- **Our fix:** the write-fault hunk of `patches/box64/0002-wowbox64-exception-state.patch`
- **Patch:** with notes: Rebase onto main: #4550 rewrote the rest of this function. — Keep only the `getProtection(addr) & (PROT_DYNAREC | PROT_DYNAREC_R)` condition. The x86-state hunk is already upstream (see section B), and the host-side fault log is optional diagnostics.
- **Upstream status:** open: `wine/wow64/wowbox64.c:322-329` on main still does `if (addr) { unprotectDB(addr, 1, 1); NtContinue(ctx, FALSE); }` for any write fault. Possibly related: Box64 issue #4380 (open), whose "freeze form" is a store into a PROT_NONE guard page that "loops forever at 100% CPU" under wowbox64.
- **Short form because:** Box64's AI policy: report only; partly fixed upstream.

<a id="box64-03"></a>

#### BOX64-03 — wowbox64: no cooperative suspend (CHPE SuspendDoorbell), so GetThreadContext() of a running 32-bit thread returns a stale x86 state

- **What:** Wine's SIGUSR1 suspend handler takes a cooperative path when `teb->ChpeV2CpuAreaInfo` is set and `InSimulation` is true: it rings `*SuspendDoorbell` and lets the emulator stop at a consistent x86 boundary. wowbox64 provides no CPU area. The thread is therefore suspended wherever SIGUSR1 finds it in translated code, and the WoW64 context in the CPU area is the one saved at the thread's last call into Wine.
- **Severity / scope:** wrong output (debuggers, anti-cheat/profilers, GC suspension and SetThreadContext-based code misbehave); any OS (WoW64 back end on arm64 Wine)
- **Our fix:** `patches/box64/0003-wowbox64-suspend-doorbell.patch`
- **Patch:** with notes: It is large (≈575 lines) and touches the arm64 dynarec only. It adds a doorbell check at block entries, secondary entries and loop heads; the RV64/LA64 dynarecs are not covered. — Needs a rebase past #4550 and current main. — Cost: +2.1 % on a CPU benchmark (out-of-line slow path). `BOX64_DYNAREC_PAUSE=3` falls back to yield in the WoW64 build. — Best proposed as a design issue first, pointing at FEX's WoW64 back end as the reference.
- **Upstream status:** open: no `SuspendDoorbell`/`InSimulation`/`ChpeV2CpuAreaInfo` use anywhere in main's `wine/wow64/wowbox64.c`, `src/emu/x64emu_private.h` or `src/include/emit_signals.h`. GitHub search "wowbox64 GetThreadContext", "wowbox64 suspend": none.
- **Short form because:** Box64's AI policy: report only.

<a id="fex-01"></a>

#### FEX-01 — Windows OvercommitTracker reports an overcommit fault as handled even when the commit fails, so the faulting access repeats forever

- **What:** FEX reserves large ranges, such as code buffers and allocator arenas, and commits them on first touch from its access-violation handler. Under Wine it commits the whole reservation at once.
- **Severity / scope:** hang; any OS. The failed-commit handling is generic. The Wine branch's whole-reservation commit (512 MiB per reservation) is what exhausts commit on hosts that account for it.
- **Our fix:** `patches/fex/0001-overcommit-bounded-commit-under-wine.patch`
- **Patch:** with notes. Split into two parts: **(1)** `return VirtualAlloc(...) != nullptr`. This is generic and MR-ready. — **(2)** Use the bounded 64 KiB commit under Wine too. This is a policy change. Upstream chose the whole-reservation commit deliberately in the Wine path (PR #4057 "Support for emulated overcommit on Windows", 1266a5a5ce3a; then f5decb5f839f "Fix overcommit size logic in the wine path"). Neither commit gives a reason; presumably Linux overcommit makes it free and it saves repeated faults. Offer it as an option, or only when commit accounting is strict.
- **Upstream status:** open: `Source/Windows/Common/OvercommitTracker.h` `HandleAccessViolation()` on main still ignores both `VirtualAlloc()` results and returns `true`. GitHub search "overcommit", "OvercommitTracker": only #3316 (Transistor OutOfMemoryException on Linux; unrelated).
- **Short form because:** FEX accepts no AI-assisted code: report only.

## 8. HaikuPorts recipes

Checked against haikuports `master` `cc013b4`.

### 8.1 Full reports

<a id="haikuports-01"></a>

#### HAIKUPORTS-01 — dev-libs/wayland-server: wayland_server-0.1.20251004 does not build against HaikuPorts' wayland_protocols 1.49

- **Tracker fields:** haikuports/haikuports issue or PR. Recipe: `dev-libs/wayland-server/wayland_server-0.1.20251004.recipe`. Title: "wayland_server: build fails with wayland_protocols 1.49 (text-input-v3 v2); bump srcGitRev".
- **Severity:** build
- **Scope:** all architectures.
- **Our fix:** `patches/wayland_server/wayland_server-0.1.20251004-text-input-v2.patch` (no-op handlers). Upstream's own fix is X547/wayland-server fb4e41650877.
- **Patch:** with notes. The preferred fix is to bump `srcGitRev` to fb4e41650877 or later (the current head is 8ede02e0e880); our patch is the minimal alternative for the pinned 0364da32.
- **Upstream status (2026-11-20):** open in HaikuPorts. The recipe at cc013b4 still pins `0364da32d1bf…`, and `dev-libs/wayland-protocols/wayland_protocols-1.49.recipe` is the protocols version in the tree. Fixed in X547/wayland-server fb4e41650877 ("fix build: add missing text-input-v3 protocol handler stubs", 2026-08-06). Tracker: searched "wayland_server" in haikuports issues: none about the build.

**Environment.** wayland_server 0.1.20251004 with wayland_protocols 1.49, standard environment (cross build).

**Description.** text-input-unstable-v3 version 2 adds `set_available_actions`, `show_input_panel` and `hide_input_panel`. The generated C++ interface declares them pure virtual, so `HaikuTextInput` is abstract and does not compile.

**Steps to reproduce.** `haikuporter wayland_server` against the current tree (not run as written; we hit it in our cross build of the same recipe).

**Expected / Actual.** Expected: a package. Actual: the compile fails in `HaikuTextInput.cpp`, because the abstract class cannot be instantiated.

**Root cause.** The pinned source predates wayland_protocols 1.49. Upstream added the three stubs in `HaikuTextInput.h` in fb4e41650877.

**Fix.** Bump `srcGitRev` (re-checksum), and test it together with HAIKUPORTS-02's `wayland` bump (X547 changed the in-process add-on interface in 93e19be64723). Alternatively, add our patch to the recipe.

**Evidence.** Our build failed without the patch and built with it (revision -1 onwards).

### 8.2 Short form

<a id="haikuports-02"></a>

#### HAIKUPORTS-02 — dev-libs/wayland: the pinned libwayland-client busy-spins in wl_display_dispatch_queue() (100 % CPU per event thread)

- **What:** On Haiku the client talks to the in-process server, whose looper enqueues events from its own thread. `wl_display_dispatch_queue()` has its socket-read path `#ifndef __HAIKU__`'d out.
- **Severity / scope:** performance. A CPU core spins for each dispatching thread, and roundtrips busy-wait; all architectures.
- **Our fix:** `patches/wayland/wayland-1.21.0~git-dispatch-blocks.patch`. It waits on the display's condition variable, which `display_enqueue()` broadcasts.
- **Patch:** with notes. It is attachable as a recipe patch for the pinned revision. X547 fixed it differently (fd5a7bff0454 enables the pipe-read path on Haiku). The X547 branch was rebased (149e9d7e is not an ancestor of `inproc-haiku`), so a bump is a re-pin and must go together with HAIKUPORTS-01.
- **Upstream status:** open in HaikuPorts (cc013b4 pins `149e9d7e1bab…`, REVISION 4). Fixed in X547/wayland fd5a7bff0454 ("wayland-client: fix `wl_display_dispatch` 100% CPU load", 2026-04-18). Tracker: not searched.
- **Short form because:** upstream (X547) fixed it; HaikuPorts only needs a newer pin.

<a id="haikuports-03"></a>

#### HAIKUPORTS-03 — dev-util/gperf: gperf-3.1 does not build with GCC ≥ 15 (C23 default)

- **What:** gperf 3.1's old gnulib `lib/getopt.c` declares `extern int strncmp ();` and `extern int getopt ();`. In C23, `()` means `(void)`.
- **Severity / scope:** build; all architectures, with HaikuPorts' `sys-devel/gcc/gcc-15.3.0_2026_10_11.recipe` or newer.
- **Our fix:** a recipe change in our test build (revision 2): `export CFLAGS="-O2 -std=gnu17"` before `runConfigure ./configure`. It is not carried as a file in this repository. The design note is in `docs/design/native-gcc.md`.
- **Patch:** with notes. It is a one-line BUILD() change, plus a REVISION bump.
- **Upstream status:** open. The recipe at cc013b4 has REVISION 1 and no `-std=` (`BUILD()` at line 41). GCC 15.3 is in the tree. Tracker: searched "gperf" in haikuports issues, none.
- **Short form because:** matters only once HaikuPorts builds with GCC 15 or later.

<a id="haikuports-04"></a>

#### HAIKUPORTS-04 — dev-libs/gmp: gmp-6.3.0's configure finds "no working compiler" with GCC ≥ 15

- **What:** GMP 6.3.0's configure probes the compiler with K&R-style test programs, which C23 rejects. Configure therefore decides that the compiler does not work.
- **Severity / scope:** build; all architectures, with GCC 15 or later (now in the tree).
- **Our fix:** `scripts/build-blender.sh` (step `gmp`) passes `CFLAGS="-O2 -std=gnu17"` to configure.
- **Patch:** with notes. Add `CFLAGS="-O2 -std=gnu17"` to `runConfigure`, plus a REVISION bump.
- **Upstream status:** open. The recipe at cc013b4 (REVISION 1, `runConfigure ./configure --enable-cxx …` at line 66) sets no `-std=`. Tracker: not searched (the GMP side is a known GCC 15 issue).
- **Short form because:** matters only once HaikuPorts builds with GCC 15 or later.

<a id="haikuports-05"></a>

#### HAIKUPORTS-05 — media-gfx/blender: blender.rdef.in marks Blender B_SINGLE_LAUNCH, so a second instance exits at once

- **What:** With `B_SINGLE_LAUNCH`, starting Blender while one instance runs hands the arguments to the running instance and quits the new one. Blender (through GHOST_SDL) ignores those messages, so nothing happens.
- **Severity / scope:** wrong output. A second Blender instance quits immediately; Haiku, all architectures. The HaikuPorts package is x86_64; we observed it with that rdef on arm64.
- **Our fix:** `tools/recipes/media-gfx/blender/additional-files/blender.rdef.in`: `resource app_flags B_MULTIPLE_LAUNCH | B_ARGV_ONLY;`
- **Patch:** attachable as a one-line change.
- **Upstream status:** open. `blender.rdef.in:2` has `resource app_flags B_SINGLE_LAUNCH | B_ARGV_ONLY;` at cc013b4. Tracker: not searched.
- **Short form because:** small recipe fix.

## 9. SDL (Haiku backend)

Checked against SDL's `SDL2` branch `fe30456e94e8`, `main` (SDL3) `db38c46d0ae0` and `release-2.32.10`. **SDL forbids
any use of generative AI in contributions, bug reports included**: these entries are research notes for the owner
to reproduce and write up in their own words, not text to paste.

### 9.1 Full reports

<a id="sdl-01"></a>

#### SDL-01 — SDL video/haiku: window-event handlers run on the BApplication looper thread, racing the app thread (double free in SDL_AddDisplayMode)

- **Tracker fields:** GitHub issue on libsdl-org/SDL. Title: "Haiku: window events are handled on the looper thread, racing SDL_CreateWindow (double free in SDL_AddDisplayMode)". Labels (suggested, not looked up): `Haiku`, `bug`.
- **Severity:** crash
- **Scope:** Haiku, all architectures. The backend code is architecture-independent. Any program whose window events arrive while its own thread changes SDL window or display state can hit the race.
- **Our fix:** `patches/libsdl2/libsdl2-2.32.10-haiku-event-thread.patch`
- **Patch:** with notes. It applies cleanly to the `SDL2` branch, on top of the SDL_BHandler change that is already there. SDL3 `main` still has a separate `SDL_BLooper`, so the patch needs a port there: queue in `SDL_BLooper::MessageReceived` and drain in `HAIKU_PumpEvents`.
- **Upstream status (2026-11-20):** open. The code is unchanged in `SDL2` fe30456e94e8 (`src/main/haiku/SDL_BApp.h:98-170`, `src/video/haiku/SDL_bevents.cc:31-33`) and in `main` db38c46d0ae0 (`src/core/haiku/SDL_BApp.h:97-168`, `src/video/haiku/SDL_bevents.cc:31-33`). Tracker: searched "haiku double free" and "haiku in:title". The only related hits are #14778/#14779 ("fix modelist double-free"), which fixed a different free (see SDL-03).

**Environment.** SDL 2.32.10 (HaikuPorts libsdl2 2.32.10 patchset, the same as the `SDL2` branch for these files), standard environment.

**Description.** `SDL_BHandler::MessageReceived()` handles the messages SDL's BWindows post for shown, hidden, resize, focus, mouse and keys. It calls SDL's handlers (`SDL_SendWindowEvent`, `SDL_OnWindowShown`, …) directly on the BApplication's looper thread. In SDL3 this runs on `SDL_BLooper`'s thread. Those handlers change SDL's video, window and display state, which has no lock.

A fullscreen window's "shown" event runs `SDL_OnWindowShown` → `SDL_UpdateFullscreenMode`, which sets the display mode. At the same moment `SDL_CreateWindow()` on the application thread does the same. Both fill and realloc the same display mode list, and one frees what the other already freed. `HAIKU_PumpEvents()` is empty, with the comment "Since the event thread is its own thread, this isn't really necessary". Every other SDL video driver handles its window-system events on the thread that pumps them.

**Steps to reproduce.**
1. Start a fullscreen OpenGL SDL2 program repeatedly, for example ioquake3/OpenArena with `+set r_fullscreen 1`, killing it after about 5 s.
2. Repeat this 20 or more times.

**Expected / Actual.**
- Expected: every start is clean.
- Actual: libroot aborts with "double free" in `SDL_AddDisplayMode()` within the first 2 s, or at the kill.
- Under Haiku's guarded heap (`LD_PRELOAD=libroot_debug.so MALLOC_DEBUG=g`) the crash disappears, which points to a race rather than a stray write.

**Root cause.** `src/main/haiku/SDL_BApp.h:98` (SDL2, fe30456e94e8) dispatches every `BAPP_*` message into SDL from the looper thread. `src/video/haiku/SDL_bevents.cc:31` does nothing.

**Fix.**
- `MessageReceived()` detaches the SDL messages (`BAPP_MOUSE_MOVED`..`BAPP_SCREEN_CHANGED`, `B_LOCALE_CHANGED`) into a `BMessageQueue`.
- `HAIKU_PumpEvents()` calls `SDL_Handler->DispatchQueuedMessages()`, which runs the existing handlers on the thread that pumps events.
- Input then reaches SDL when the application pumps, as on X11, Wayland and Windows.

**Evidence.** Before: 6 of 22 fullscreen starts crashed across five cycles (guarded heap: 0 of 17). After: 21 of 21 clean at 1080p. SuperTuxKart (race and benchmark, 762 frames in 133 s, unchanged) and vkQuake (52.8 fps, unchanged) were checked for regressions.

<a id="sdl-02"></a>

#### SDL-02 — SDL video/haiku: one process-wide "current" GL context, so SDL_GL_MakeCurrent on a second thread unlocks another thread's BGLView

- **Tracker fields:** GitHub issue on libsdl-org/SDL. Title: "Haiku: current OpenGL context is process-wide; SDL_GL_MakeCurrent from a worker thread unlocks the main thread's BGLView". Labels (suggested, not looked up): `Haiku`, `bug`.
- **Severity:** crash. HaikuPorts' x86_64 blender3 stops in the debugger. On our stack the symptom is "wrong thread" unlocks and context bindings that drift.
- **Scope:** Haiku, all architectures. The public crash report is on x86_64.
- **Our fix:** `patches/libsdl2/libsdl2-2.32.10-haiku-gl-thread-context.patch`
- **Patch:** with notes. It applies to the `SDL2` branch after `…-haiku-event-thread.patch`; on its own, its last hunk's context (the `_queue` member) needs adjusting. It uses SDL TLS (`SDL_TLSCreate`), not C++ `thread_local`, because Haiku's arm64 runtime loader has no TLSDESC relocation. SDL3 needs an equivalent port.
- **Upstream status (2026-11-20):** open. The code is unchanged: `SDL2` `src/main/haiku/SDL_BApp.h:203-215` (`_current_context`, `SetCurrentContext`) and `main` `src/core/haiku/SDL_BApp.h:202-214`. Tracker: searched "haiku thread context", no matching issue.

**Environment.** SDL 2.32.10, standard environment. Crash report from others: HaikuPorts blender3-3.3.21 on x86_64 (Haiku forum thread "Blender port", 2024).

**Description.** `SDL_BHandler` keeps a single `BGLView *_current_context`. `HAIKU_GL_MakeCurrent()` calls `UnlockGL()` on that view and `LockGL()` on the new one, whichever thread calls it. SDL's API, like EGL, GLX and WGL, makes contexts current per thread. A program that makes a context current on a job thread while the main thread draws therefore unlocks the main thread's view from the job thread, and the job thread's release unlocks it again. `BGLView::LockGL()` takes a BLocker owned by the locking thread.

**Steps to reproduce.**
1. Create two GL windows or contexts.
2. On thread A, `SDL_GL_MakeCurrent(w1, c1)` and draw in a loop.
3. On thread B, `SDL_GL_MakeCurrent(w2, c2)`, draw, then `SDL_GL_MakeCurrent(NULL, NULL)`. (Our `blender-glprobe -t` does this.)

For a real-world case, use Blender with GHOST_SDL: F12 render, or the Shading workspace.

**Expected / Actual.**
- Expected: each thread has its own current context, and no lock is touched by another thread.
- Actual: "UnlockGL is called from wrong thread" and "Unlocking BLocker … from wrong thread". HaikuPorts' x86_64 blender3 stops in `_kern_debugger`, via `GHOST_ContextSDL::activateDrawingContext` → `SDL_GL_MakeCurrent` → `HAIKU_GL_MakeCurrent` → `BGLView::UnlockGL`.

**Root cause.** `src/main/haiku/SDL_BApp.h:208-214` (SDL2, fe30456e94e8): `SetCurrentContext()` unlocks the process-wide `_current_context`.

**Fix.** Keep the current view in an SDL TLS slot. Each thread unlocks only the view it locked, then locks the new one. Single-threaded programs behave the same.

**Evidence.** Two probes:
- `blender-glprobe -t`: 2 "wrong thread" lines without the patch, 0 with it.
- Blender 3.6 GHOST_SDL probe (`sdlthread`): PASS, 0 cross-thread unlocks.

Quake II GL1/GL3 (60.0/60.0 and 58.5/58.6 fps), SuperTuxKart and our desktop GL test set are unchanged.

<a id="sdl-03"></a>

#### SDL-03 — SDL video/haiku: display modes keep pointers into BScreen::GetModeList()'s freed list (SDL3: a stack variable)

- **Tracker fields:** GitHub issue on libsdl-org/SDL. Title: "Haiku: SDL_DisplayModeData points into the freed GetModeList() array (use after free in HAIKU_SetDisplayMode)". Labels (suggested, not looked up): `Haiku`, `bug`.
- **Severity:** crash (potential: a use after free at every mode switch; no crash attributable to it was observed)
- **Scope:** Haiku, all architectures.
- **Our fix:** `patches/libsdl2/libsdl2-2.32.10-haiku-modes.patch`
- **Patch:** attachable as-is for the `SDL2` branch (applies cleanly). SDL3 needs the same change in `_BDisplayModeToSdlDisplayMode` and `_AddDisplay`.
- **Upstream status (2026-11-20):** open, in two places:
  - `SDL2` fe30456e94e8: `src/video/haiku/SDL_bmodes.cc:174-178` (`data->bmode = bmode`) with `:257` (`free(bmodes)`), read back at `:270-282`.
  - `main` db38c46d0ae0: `src/video/haiku/SDL_bmodes.cc:180-183` with `:260`. There `_AddDisplay()` (`:194-201`) also stores `&bmode`, the address of a stack local, as the desktop mode's data.
  - Tracker: #14778/#14779 ("Haiku: fix modelist double-free", closed 2026-01-07) only made the `free()` conditional on `GetModeList()` succeeding. The dangling pointer stays. Say so in the report, so that it is not closed as a duplicate.

**Environment.** SDL 2.32.10, standard environment.

**Description.**
- `HAIKU_GetDisplayModes()` builds each `SDL_DisplayMode` from `&bmodes[i]`. `_BDisplayModeToSdlDisplayMode()` stores that pointer in `driverdata` (`WRAP_BMODE`).
- The function then frees `bmodes`.
- `HAIKU_SetDisplayMode()` reads `bmode->space`, `virtual_width` and `virtual_height` through the stale pointer. The heap may already have reused that memory.
- In SDL3 the desktop mode's data points to a `display_mode` on `_AddDisplay()`'s stack.
- In SDL2, `_AddDisplay()` leaks the `SDL_calloc`ed `display_mode`.

**Steps to reproduce.** Call `SDL_GetDisplayMode(0, i, &m)` for every i, allocate and free some memory, then `SDL_SetWindowDisplayMode(w, &m)` and switch the window to `SDL_WINDOW_FULLSCREEN`. Run under `MALLOC_DEBUG=g` (libroot_debug) to see the freed-memory read (not run as written; found by code reading).

**Expected / Actual.**
- Expected: the mode data stays valid for as long as SDL holds the mode.
- Actual: the mode is read from freed (or out-of-scope) memory. The resolution that gets matched depends on whatever the heap holds.

**Root cause.** See the status line: the mode data does not own its `display_mode`.

**Fix.** `SDL_DisplayModeData` gets a `display_mode storage` member. `data->bmode = &data->storage` after copying. `_AddDisplay()` uses a stack `display_mode`, which is then copied.

**Evidence.** Found while chasing SDL-01. This defect did not cause SDL-01's crash. It is a code-level finding with a deterministic mechanism, not a crash measurement.

### 9.2 Short form

<a id="sdl-04"></a>

#### SDL-04 — SDL video/haiku: SDL_GL_SetSwapInterval is refused; frames are always swapped without vsync

- **What:** `HAIKU_GL_SetSwapInterval()` returns `SDL_Unsupported()` for every interval, and `SDL_BWin::SwapBuffers()` calls `BGLView::SwapBuffers()`, which means "don't wait". Haiku's GL kit API has `BGLView::SwapBuffers(bool vSync)`, so SDL can pass the request on.
- **Severity / scope:** performance. A vsync request is ignored, so games render unthrottled and app_server copies every frame; Haiku, all architectures.
- **Our fix:** `patches/libsdl2/libsdl2-2.32.10-haiku-swap-interval.patch`
- **Patch:** with notes. It applies to the `SDL2` branch (offsets only). It only has an effect with a GL kit whose `BGLView::SwapBuffers(bool vSync)` honours the flag. The upstream libglvnd HGL ignores it, so file LIBGLVND-03 together with this one.
- **Upstream status:** open. `SDL2` `src/video/haiku/SDL_bopengl.cc:157-165` (`SDL_Unsupported()`, `TODO`) and `src/video/haiku/SDL_BWin.h:221-223` (`SwapBuffers()` with no flag). `main` `src/video/haiku/SDL_bopengl.cc:164-173`. Tracker: searched "haiku swap interval", none.
- **Short form because:** minor, and SDL forbids AI-assisted reports: notes only.

## 10. Haiku's Wayland server (X547/wayland-server)

Haiku's in-process Wayland server is X547's project ([X547/wayland-server](https://github.com/X547/wayland-server),
packaged by HaikuPorts as `wayland_server`). Checked against its `master` `8ede02e0e880`.

### 10.1 Full reports

<a id="wayland-01"></a>

#### WAYLAND-01 — wayland_server (X547): NULL dereference in WaylandWindow::WindowActivated/FrameResized after the client destroys its xdg_toplevel

- **Tracker fields:** GitHub issue/PR on X547/wayland-server. Title: "Crash: WindowActivated/FrameResized dereference fToplevel after ~HaikuXdgToplevel cleared it".
- **Severity:** crash. The server runs in-process, so the client dies with it.
- **Scope:** Haiku, all architectures.
- **Our fix:** `patches/wayland_server/wayland_server-0.1.20251004-window-without-toplevel.patch`
- **Patch:** attachable as-is. It applies cleanly to `master` 8ede02e0e880.
- **Upstream status (2026-11-20):** open. `HaikuXdgToplevel.cpp:58-65` (`WindowActivated`) and `:76-97` (`FrameResized`) use `fToplevel` without the NULL check that `QuitRequested()` (`:49-55`) has. `~HaikuXdgToplevel` (`:283-294`) clears it and posts `B_QUIT_REQUESTED`. Tracker: searched "crash" in X547/wayland-server issues: #9, #12 and #16 are other exit and locking issues, none is this one.

**Environment.** wayland_server 0.1.20251004 (HaikuPorts revision, git 0364da32), standard environment.

**Description.** When a client destroys an xdg_toplevel, `~HaikuXdgToplevel` sets `fWindow->fToplevel = NULL` and posts `B_QUIT_REQUESTED`. Wine destroys a window's toplevel each time it hides the window. A `B_WINDOW_ACTIVATED` or `B_WINDOW_RESIZED` already in the window's queue is dispatched before the quit request. `WindowActivated()` and `FrameResized()` then read through the NULL `fToplevel`.

**Steps to reproduce.**
1. A client creates an xdg_toplevel and shows it.
2. It immediately activates or resizes another window, which generates `B_WINDOW_ACTIVATED`.
3. It destroys the toplevel in the same burst.
4. Loop this. (Not run as written; the real case is below.)

Real case: Wine (winewayland) running a fullscreen Half-Life, which hides and shows its launcher window every frame.

**Expected / Actual.**
- Expected: queued events for a window whose toplevel is gone are ignored.
- Actual: a segment violation in `WaylandWindow::WindowActivated+0x4c` (a load at 0x58, from `fToplevel` = NULL) kills the program.

**Root cause.** `HaikuXdgToplevel.cpp:61` and `:80` (master 8ede02e0e880).

**Fix.** Return early from both functions when `fToplevel == NULL`, as `QuitRequested()` does.

**Evidence.** The program crashed in the Half-Life session (the debugger report named `WindowActivated+0x4c`). With the patch (wayland_server -3) there was no crash in the following runs.

<a id="wayland-02"></a>

#### WAYLAND-02 — wayland_server (X547): server loopers keep running during exit() and use libbe state its static destructors already freed (crash or hang at client exit)

- **Tracker fields:** GitHub issue on X547/wayland-server. Title: "Client exit races the add-on's loopers: 'bogus pointer' in ~BWindow / BTokenSpace::RemoveToken, segment violation in BLooperList, hang on a full port".
- **Severity:** crash and hang at program exit
- **Scope:** Haiku, all architectures.
- **Our fix:**
  - `patches/wayland_server/wayland_server-0.1.20251004-wl-window-hold-at-exit.patch`
  - `patches/wayland_server/wayland_server-0.1.20251004-wl-window-stop-at-exit.patch`
- **Patch:** no, not as-is. Both sit on top of our `wl-output-modes` and `wl-surface-view` patches, which add APIs upstream does not have, and they would need a rebase onto `master`. The design (a `__cxa_atexit` handler registered after libbe's statics, then suspending the held loopers) can be offered as a reference.
- **Upstream status (2026-11-20):** open. `master` 8ede02e0e880 registers no exit handler (`WaylandServer.cpp`, 199 lines, no `atexit`/`__cxa_atexit`). Tracker: X547/wayland-server #9 ("looper must be locked before proceeding", closed 2024) is an earlier symptom of the same family. Not otherwise searched.

**Environment.** wayland_server 0.1.20251004. QEMU arm64 and the standard environment.

**Description.** The add-on's Wayland looper, the toplevels' BWindows and its BApplication keep running while `exit()` runs libbe's static destructors (token space, looper list, roster). A message handled in that window uses destroyed state.

**Steps to reproduce.** A client that destroys its xdg_toplevel and calls `exit()` right away. Our test client `wlexit` exits while it still commits.

**Expected / Actual.**
- Expected: a clean exit.
- Actual, one of:
  - "bogus pointer (double free?)" in `BTokenSpace::RemoveToken` from `~BWindow`;
  - "looper must be locked before proceeding";
  - a segment violation in `BLooperList::FindLooperPred` ← `BLooper::_Lock` ← `task_looper`;
  - a hang, with the sender blocked on a held looper's full port.

**Root cause.** No synchronisation between the server's threads and process teardown.

**Fix (ours).**
1. An exit handler, registered with `__cxa_atexit` when the server starts (so it runs before libbe's destructors), flushes pending requests.
2. It waits up to 1 s for quitting windows' threads.
3. It locks the Wayland looper, then the windows, then the application looper.
4. It suspends their threads.
5. Requests sent after that are dropped.

**Evidence.** These numbers were measured with our full patch set, including `wl-surface-view`, which makes every such window quit and so raises the rate:
- QEMU test client: 4 of 15 exits crashed (16 of 18 with an `__attribute__((destructor))` variant).
- Hold patch alone: 18 of 18 clean, but 5 of 40 hangs remained.
- With both patches: 200 of 200 clean (40 of each of 5 exit kinds), no debugger entries.

Upstream alone has not been measured.

### 10.2 Short form

<a id="wayland-03"></a>

#### WAYLAND-03 — wayland_server (X547): a fullscreen surface smaller than the output is left at the top-left instead of centered

- **What:** xdg-shell's `set_fullscreen` says a surface that does not cover the output is centered, and the rest is filled (for example black). The server instead makes the window screen-sized, then shrinks it to the surface's geometry at its next commit.
- **Severity / scope:** wrong output; Haiku, all architectures.
- **Our fix:** `patches/wayland_server/wayland_server-0.1.20251004-fullscreen-center.patch`
- **Patch:** with notes. It applies cleanly to `master`. Known cost: the black border view sits under the surface, and app_server refills it every frame (24 % of app_server's window thread in `FillRectNoClipping` at 1440×1080). A clipped border, or drawing it once, would be better. The window-lock follow-up for the border view lives in our `wl-output-modes` patch.
- **Upstream status:** open. `HaikuXdgToplevel.cpp:232-245` (`HandleSetFullscreen`) resizes the window to the screen, and the next commit resizes it back to the surface geometry (`HaikuXdgSurface.cpp:62-71`). Tracker: searched "fullscreen", none.
- **Short form because:** cosmetic.

<a id="wayland-04"></a>

#### WAYLAND-04 — wayland_server (X547): meson uses the build machine's CPU and absolute private-header paths (cross builds fail)

- **What:** `meson.build` takes the architecture of Haiku's private `system/arch/<arch>` headers from `build_machine` and the private header directories as absolute paths of the running system. In a cross build, the first names the build host's CPU and the second does not exist.
- **Severity / scope:** build (cross-compilation only; native builds are unaffected); Haiku, all architectures, when cross-compiled.
- **Our fix:** `patches/wayland_server/wayland_server-0.1.20251004-cross.patch`
- **Patch:** attachable as-is. It applies cleanly to `master`.
- **Upstream status:** open. `meson.build:11` has `arch = build_machine.cpu_family()`, and `:122-125` has absolute `/boot/system/develop/headers/private/...`. Tracker: not searched.
- **Short form because:** cross builds only.

## 11. libglvnd (Haiku HGL)

Upstream libglvnd (freedesktop GitLab) carries the Haiku OpenGL kit (HGL) in `src/HGL`. Checked against
libglvnd `master` `8731041`; our fixes are on `rpi4` of haiku-pi/libglvnd.

### 11.1 Full reports

<a id="libglvnd-01"></a>

#### LIBGLVND-01 — HGL (Haiku libGL): does not build against current Haiku headers (PTHREAD_RECURSIVE_MUTEX_INITIALIZER is now _NP-only)

- **Tracker fields:** freedesktop GitLab, glvnd/libglvnd issue or MR. Title: "HGL: build failure on current Haiku: PTHREAD_RECURSIVE_MUTEX_INITIALIZER undeclared". Also HaikuPorts `sys-libs/libglvnd/libglvnd-1.7.0.recipe` (its patchset does not cover this).
- **Severity:** build
- **Scope:** Haiku, all architectures, from Haiku commit 6e55e6942f (2026-03-30: "pthread: PTHREAD_RECURSIVE_MUTEX_INITIALIZER is non-POSIX", which renamed it to `PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP` as glibc spells it).
- **Our fix:** commit 33d3b66 on haiku-pi/libglvnd (`rpi4`). It adds an `#ifndef … _NP` fallback in `src/HGL/GLView.cpp`. Its second hunk makes `src/HGL/meson.build` take `private/shared` from meson's `sys_root` (for cross builds).
- **Patch:** attachable as-is (13 lines). The meson hunk can be split off if cross builds are out of scope.
- **Upstream status (2026-11-20):** open. libglvnd `master` 8731041 has `src/HGL/GLView.cpp:76` and `:111` (`= PTHREAD_RECURSIVE_MUTEX_INITIALIZER`) and `src/HGL/meson.build:36` (absolute private header path). v1.7.0 contains the same HGL code. Tracker: not searched.

**Environment.** libglvnd 1.7.0+git (master), Haiku headers from haiku `master`, standard environment (cross build).

**Description.** HGL initialises its mutexes with `PTHREAD_RECURSIVE_MUTEX_INITIALIZER`. Haiku now spells it only `PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP`, as glibc does. Separately, `src/HGL/meson.build` names `/boot/system/develop/headers/private/shared` as an absolute path, which a cross build does not have.

**Steps to reproduce.** Build libglvnd with `-Dhgl=true` (the `hgl` option, effective when `host_machine.system()` is haiku) against Haiku headers newer than 6e55e6942f, for example `haikuporter libglvnd` on a current nightly (not run as written; we hit it in our cross build).

**Expected / Actual.** Expected: it builds. Actual: the compile stops because `PTHREAD_RECURSIVE_MUTEX_INITIALIZER` is undeclared (`GLView.cpp:76` and `:111`).

**Root cause.** `src/HGL/GLView.cpp:76` and `:111` (master 8731041) use the non-POSIX name that Haiku removed.

**Fix.** Use `PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP` when the non-suffixed name is missing.

**Evidence.** Our cross build failed without it and builds with it. Every libglvnd since 10-18 carries it.

<a id="libglvnd-02"></a>

#### LIBGLVND-02 — HGL: a program that exits with BGLViews still alive stops in the debugger (BReferenceable destroyed with references)

- **Tracker fields:** freedesktop GitLab, glvnd/libglvnd issue or MR. Title: "HGL: static BGLView::Display destroyed with live renderer references at exit → debugger()".
- **Severity:** crash (hang at exit: the team stops in the debugger)
- **Scope:** Haiku, all architectures.
- **Our fix:** commit ed01b68 on haiku-pi/libglvnd (`rpi4`). `~Display()` zeroes `fReferenceCount`.
- **Patch:** attachable as-is (11 lines).
- **Upstream status (2026-11-20):** open. libglvnd `master` 8731041 `src/HGL/GLView.cpp:86` (`virtual ~Display() = default;`) and `:120` (`BGLView::Display BGLView::sDisplay;`). Tracker: not searched.

**Environment.** libglvnd HGL + Mesa EGL, SuperTuxKart 1.5 (SDL2), standard environment.

**Description.** `BGLView::sDisplay` is a static `BReferenceable` that each view's renderer references. A program that exits without deleting its BGLViews, as SuperTuxKart does on exit, destroys the static with references left. Haiku's `BReferenceable::~BReferenceable` calls `debugger("Deleting referenceable object … with reference count …")` in every non-boot build when the count is neither 0 nor 1 (`src/kits/support/Referenceable.cpp:30-35`). The count is 2 or more as soon as two or more views are left alive; SuperTuxKart creates several GL windows while probing GL versions.

**Steps to reproduce.** Create two BGLViews (or two SDL GL windows) and call `exit(0)` without deleting them (not run as written; the real case is SuperTuxKart's exit).

**Expected / Actual.** Expected: the process ends. Actual: the team stops in the debugger from `__cxa_finalize`, and the process stays alive.

**Root cause.** `src/HGL/GLView.cpp:86` and `:120` (master 8731041): a static `BReferenceable` with a defaulted destructor.

**Fix.** At static destruction the process is ending, so drop the count, or leak the static on purpose.

**Evidence.** SuperTuxKart stayed alive in the debugger after every race exit. Fixed with mesa 26.2.0-3, which carries this libglvnd.

### 11.2 Short form

<a id="libglvnd-03"></a>

#### LIBGLVND-03 — HGL: BGLView::SwapBuffers(bool vSync) ignores vSync

- **What:** The Haiku/BeOS GL kit API offers `BGLView::SwapBuffers(bool vSync)` so that a program can ask for a swap that waits for the vertical blank. HGL drops the flag, and every swap behaves like `SwapBuffers(false)`.
- **Severity / scope:** performance. Apps that ask for vsync through the BeOS/Haiku API run unthrottled; Haiku, all architectures.
- **Our fix:** commit be20124 on haiku-pi/libglvnd. `Renderer::SwapBuffers(bool vSync)` calls `eglSwapInterval(dpy, vSync ? 1 : 0)` when the value changes.
- **Patch:** no, not as-is. That commit also adds overlay-channel presentation that depends on our app_server. The vSync part (about 15 lines: the hook-list entry, an `fSwapInterval` member, `SwapBuffers(bool)`) has to be extracted. The pacing itself also needs the EGL driver to honour `eglSwapInterval` for window surfaces, which our Mesa fork does (1595aba36ec); stock Mesa behaviour is not verified here.
- **Upstream status:** open. libglvnd `master` 8731041 `src/HGL/GLView.cpp:363-369`: `SwapBuffers(bool vSync)` calls `fRenderer->SwapBuffers()` and never reads `vSync`. Tracker: not searched.
- **Short form because:** needs SDL-04 or similar callers to matter.

## 12. U-Boot

Checked against U-Boot `master` `ece349ade2` (through the GitHub mirror) and, for comparison, EDK2 `556dcfb466`.
The other U-Boot patches we carry are Pi-specific (see the Pi section) or not U-Boot bugs. "Env": Haiku nightly
hrev60431, arm64, Raspberry Pi 4 Model B 4 GB, Pi firmware of 2026-10-15.

<a id="uboot-01"></a>

#### UBOOT-01 — efi_loader: efi_load_pe() copies only the header structures, not SizeOfHeaders bytes

- **Tracker fields:** patch to u-boot@lists.u-boot-project.org, tracked on patchwork.
  - Subject: `efi_loader: copy SizeOfHeaders bytes of the PE headers`
  - CC (from `scripts/get_maintainer.pl`): Heinrich Schuchardt and Ilias Apalodimas (EFI LOADER), Tom Rini (THE REST).
- **Severity:** wrong output (non-deterministic image memory). Low impact.
- **Scope:** any architecture and OS booted through U-Boot's EFI loader. Not Pi-specific.
- **Our fix:** `patches/u-boot/0004-efi_loader-copy-SizeOfHeaders-bytes-of-PE-headers.patch`
- **Patch:** with notes. The code it touches is identical at master `ece349ade2` and our base `8d534cec0c`, but the patch file is a plain diff: regenerate it with `git format-patch` and add a Signed-off-by.
- **Upstream status (2026-11-20):** open. The code is unchanged at master `ece349ade2`, `lib/efi_loader/efi_image_loader.c:1012-1017`.
  - Tracker: patchwork (project uboot) searched "SizeOfHeaders", "efi_load_pe headers": none.

**Environment.** U-Boot master as of 2026-10-16 (`8d534cec0c`), `rpi_arm64` and Env. The EFI image was Haiku's loader, whose `SizeOfHeaders` is 0x1000. Equivalent on any board.

**Description.**
- `efi_load_pe()` copies `sizeof(*dos) + sizeof(*nt) + SizeOfOptionalHeader + num_sections * sizeof(IMAGE_SECTION_HEADER)` bytes.
- The rest of the image's header region, up to `OptionalHeader.SizeOfHeaders`, keeps whatever was in RAM. The pages come from `efi_alloc_aligned_pages()`, which does not clear them.
- EDK2's `PeCoffLoaderLoadImage()` reads all `SizeOfHeaders` bytes (`MdePkg/Library/BasePeCoffLib/BasePeCoff.c:1372-1380` at `556dcfb466`), so the two loaders give an image different memory below its first section.

**Steps to reproduce.**
1. Build an EFI application with `SizeOfHeaders` larger than its header structures (e.g. a linker that pads headers to 0x1000).
2. Fill RAM with a pattern before boot. We used a U-Boot build that fills DRAM with random data before booting; its exact fill code is not recorded in the repository. Any fill (e.g. `mw` over free DRAM) shows the effect.
3. Boot the application with `bootefi`.
4. From inside it, dump `ImageBase + <end of section table> … ImageBase + SizeOfHeaders`.

**Expected / Actual.** Expected: the file's bytes (zero padding), as under EDK2. Actual: the RAM pattern.

**Root cause.** `efi_image_loader.c:1012-1017` (master `ece349ade2`).

**Fix.** Copy `max(SizeOfHeaders, sum of the structures)`, bounded by the file size and the image size.

**Evidence.**
- The freeze that led here was root-caused in Haiku's kernel, not U-Boot: an uncleared page table that happened to be the loader's header page on SD boots (Haiku commit `d1a616afac`; docs/log/WEEK-2026-W45.md, 11-02).
- With the RAM randomly filled, U-Boot with this patch alone also avoided it: 3 of 3 boots alive vs 3 of 3 frozen.
- Present it as an EDK2-conformance and determinism fix, not as a fix for a crash.

## 13. raspberrypi/userland (archived)

raspberrypi/userland is **archived** ("Consider this repo closed"; final commit `a54a0dbb2b`): no issue or
pull request can be opened. These entries are kept for forks, distributions and the HaikuPorts recipe; our fixes
are in `tools/recipes/media-libs/raspberrypi_userland/patches/raspberrypi_userland-20241223.patchset`. "Env":
Haiku nightly hrev60431, arm64, Raspberry Pi 4 Model B 4 GB, Pi firmware of 2026-10-15, `gpu_mem` 76 MB.

<a id="userland-01"></a>

#### USERLAND-01 — mmal_vc_client: port disable frees the buffer pool while the VideoCore still holds buffers (abort in Debug, use-after-free in Release)

- **What:** After a decoder failed with `MMAL_ENOSPC` (two H.264 decoders open at once), the VideoCore did not answer the port disable and kept the port's buffers. In a build without `NDEBUG`, `vcos_assert` → `vcos_abort()` aborted the application at close.
- **Severity / scope:** crash; Linux too (32-bit Raspberry Pi OS with MMAL). Triggered when the firmware component has failed and does not return its buffers before the port disable completes.
- **Our fix:** `tools/recipes/media-libs/raspberrypi_userland/patches/raspberrypi_userland-20241223.patchset` (patch 10). — Its `NDEBUG` part is our own Haiku Makefile's mistake; upstream's CMake Release build already defines `NDEBUG` via CMake's default flags.
- **Patch:** no. Patch 10 builds on our patch 5 (32-bit handle table for 64-bit hosts), which upstream does not have. The idea (give the outstanding buffers back empty and invalidate their contexts) would need re-implementing on the pointer-based `client_context`.
- **Upstream status:** open (final state). At `a54a0dbb2b`: `interface/mmal/vc/mmal_vc_api.c:312` asserts `vcos_blockpool_available_count(&module->pool) == port->buffer_num`, then `:313` deletes the pool. — The callback at `:527-534` later dereferences `msg->drvbuf.client_context`, a pointer into that pool (`:603`, `:617`). — Tracker: GitHub searched "mmal_vc_port_disable" (issues and PRs) → #687 and #639, which are the reply hang (USERLAND-02), not this assert. Nothing about the assert or the freed pool.
- **Short form because:** the repository is archived; nothing can be filed.

<a id="userland-02"></a>

#### USERLAND-02 — mmal_vc_client: mmal_vc_sendwait_message() waits forever for a reply (hang)

- **What:** `mmal_vc_sendwait_message()` waits for the VideoCore's reply with no timeout (upstream's own FIXME), so a firmware that stops answering hangs its client.
- **Severity / scope:** hang; Linux too (the stacks in #687/#639 are from Raspbian).
- **Our fix:** `tools/recipes/media-libs/raspberrypi_userland/patches/raspberrypi_userland-20241223.patchset` (patch 8).
- **Patch:** with notes. It is written on top of our patch 5's waiter handling; the logic (timeout, abandoned flag, late reply dropped under the client lock) applies to the upstream waiter pool.
- **Upstream status:** open (final). At `a54a0dbb2b`, `interface/mmal/vc/mmal_vc_client.c:591-595`: "FIXME: we could do with a timeout here" followed by `vcos_semaphore_wait(&waiter->sem)`.
- **Short form because:** archived; existing issues #687 and #639.

<a id="userland-03"></a>

#### USERLAND-03 — vcos: the current-thread key's destructor stays registered after libvcos is unloaded (crash at thread exit)

- **What:** libvcos creates its current-thread key with a destructor inside libvcos and never deletes the key, so the destructor outlives the library.
- **Severity / scope:** crash; any POSIX system where libvcos is unloaded with `dlclose()` while threads that ran VCOS code live on, e.g. a plugin that links libavcodec built with MMAL. The pthread key semantics are the same on glibc. Not reproduced on Linux.
- **Our fix:** `tools/recipes/media-libs/raspberrypi_userland/patches/raspberrypi_userland-20241223.patchset` (patch 9).
- **Patch:** attachable as-is.
- **Upstream status:** open (final). At `a54a0dbb2b`, `interface/vcos/pthreads/vcos_pthreads.c:114` (`pthread_key_create(…, vcos_dummy_thread_cleanup)`); `vcos_platform_deinit()` at `:426-429` never deletes the key.
- **Short form because:** archived.

<a id="userland-04"></a>

#### USERLAND-04 — mmal_vc_shm: mmal_vc_shm_exit() unlocks refcount_lock without locking it

- **What:** `mmal_vc_shm_exit()` jumps to its `unlock:` label without ever locking `refcount_lock`, so the counter and the payload list are unprotected and every call unlocks an unlocked mutex.
- **Severity / scope:** data corruption (race on the refcount and the payload list); any platform. With glibc's default mutexes the unbalanced unlock goes unnoticed; error-checking mutexes refuse it.
- **Our fix:** `tools/recipes/media-libs/raspberrypi_userland/patches/raspberrypi_userland-20241223.patchset` (patch 7).
- **Patch:** attachable as-is.
- **Upstream status:** open (final). At `a54a0dbb2b`, `interface/mmal/vc/mmal_vc_shm.c:168-186` (the `unlock:` label unlocks a mutex that was never locked).
- **Short form because:** archived; code reading.

<a id="userland-05"></a>

#### USERLAND-05 — vchiq_arm: vchiq_lib_init() shadows the global vchiq_lib_mutex, which is therefore never created

- **What:** `vchiq_lib_init()` declares a function-local `static` `vchiq_lib_mutex` and creates that one. The file-scope mutex of the same name, which the rest of the file locks, is never created.
- **Severity / scope:** crash on libcs that check mutexes (Haiku's libroot asserted); latent on glibc, where a zeroed `pthread_mutex_t` happens to be a valid unlocked mutex; any platform; visible on libcs whose mutexes need initialisation.
- **Our fix:** `tools/recipes/media-libs/raspberrypi_userland/patches/raspberrypi_userland-20241223.patchset` (patch 2).
- **Patch:** attachable as-is (deletes one line).
- **Upstream status:** open (final). At `a54a0dbb2b`, `interface/vchiq_arm/vchiq_lib.c:80` (file scope) vs `:1423` (a function-local `static` of the same name); `:1747` and `:1760` lock the never-created global.
- **Short form because:** archived; code reading.

<a id="userland-06"></a>

#### USERLAND-06 — vchiq_arm: vchiq_dump_phys_mem() casts the service handle to a pointer

- **What:** `vchiq_dump_phys_mem()` casts its `VCHIQ_SERVICE_HANDLE_T` straight to `VCHIQ_SERVICE_T *` instead of mapping it with `find_service_by_handle()`.
- **Severity / scope:** crash (an invalid pointer dereference whenever the function is called); any platform. A `VCHIQ_SERVICE_HANDLE_T` is a handle that `find_service_by_handle()` maps (used everywhere else in the file), not a `VCHIQ_SERVICE_T *`.
- **Our fix:** `tools/recipes/media-libs/raspberrypi_userland/patches/raspberrypi_userland-20241223.patchset` (patch 4; the rest of that patch only fixes 64-bit trace format strings).
- **Patch:** attachable as-is.
- **Upstream status:** open (final). At `a54a0dbb2b`, `interface/vchiq_arm/vchiq_lib.c:1399`. It is exported in `vchiq_if.h:190`; no caller in the tree.
- **Short form because:** archived; code reading.

## 14. Haiku buildtools and GCC

Checked against Haiku buildtools `master` `33d46bf5c3`, haiku `master` `52912f5be3` and GCC (gcc-mirror)
`master` `4582d80bb1e8` / `releases/gcc-16` `71b1c265e9ae`.

### 14.1 Full reports

<a id="buildtools-01"></a>

#### BUILDTOOLS-01 — Haiku GCC config (haiku.h): a `--disable-shared` (cross) gcc links only the static libgcc, so every C++ `throw` ends in terminate()

- **Tracker fields:** a Gerrit change on Haiku's `buildtools` repository (review.haiku-os.org). Haiku asks for toolchain and build problems to go to the development mailing list, not Trac; if a ticket is wanted, use component "Build System". File: `gcc/gcc/config/haiku.h`. Title: "gcc/haiku: link libgcc_s as needed also for --disable-shared (cross) compilers". Not a GCC Bugzilla item: upstream GCC has no Haiku target (no `gcc/config/haiku.h` in gcc-mirror `master`).
- **Severity:** crash (`terminate()` on every throw)
- **Scope:** Haiku. Observed on arm64. On x86_64 the cross gcc has the same libgcc spec (`*libgcc: -lgcc`), and whether throws fail there depends on how the unwinder finds frames (not tested). It does not affect jam-built Haiku binaries (jam links `libgcc_s` explicitly with `-nostdlib`) or natively configured HaikuPorts gcc. It does affect anything linked with the plain cross driver: HaikuPorter cross/bootstrap builds and cross-built ports.
- **Our fix:** buildtools commits 85273c9ba6 and 393b4ec7a4 on the haiku-pi/buildtools fork (`master`/`gcc16`). 393b4ec7a4 adds `REAL_LIBGCC_SPEC "%{static|static-pie:-lgcc;:--push-state --as-needed -lgcc_s --pop-state -lgcc}"`.
- **Patch:** with notes. Squash the two commits: the second reverts half of the first. Both sit directly on buildtools `master` 33d46bf5c3 (GCC 13.3), so they apply there as-is.
- **Upstream status (2026-11-20):** open. buildtools `master` 33d46bf5c3 has `gcc/gcc/config/haiku.h:72-75` (`#ifdef HAVE_LD_AS_NEEDED` / `#define USE_LD_AS_NEEDED 1`). The pending GCC 15.3 Gerrit changes 12070/12071 are unchanged there. Tracker: not searched.

**Environment.** Haiku cross tools from buildtools (GCC 13.3 and 15.3/16.2) for aarch64-unknown-haiku, built by `configure --build-cross-tools` (`--disable-shared`), standard environment.

**Description.**
- `USE_LD_AS_NEEDED` depends on configure's `HAVE_LD_AS_NEEDED` probe, which fails while the cross gcc is configured before its binutils exist.
- In any case, a `--disable-shared` gcc builds no libgcc spec of its own, so the driver links only the static `libgcc`.
- A C++ program's unwind tables then register with that private copy of the unwinder, while libstdc++ throws through `libgcc_s`'s unwinder.

**Steps to reproduce.** `aarch64-unknown-haiku-g++ t.cpp` (our probe program, equivalent) with `int main(){ try { throw 42; } catch (int) { return 0; } }`. Run it on Haiku arm64. `readelf -d` shows no `libgcc_s`.

**Expected / Actual.** Expected: exit code 0. Actual: `terminate()` is called and the program aborts. The same happens for `std::runtime_error`.

**Root cause.** `gcc/gcc/config/haiku.h:72-75` (buildtools 33d46bf5c3).

**Fix.** Always define the libgcc spec: as-needed `libgcc_s`, then the static `libgcc`. Static links keep only `-lgcc`.

**Evidence.**
- With the fix, a throwing C++ program NEEDs `libgcc_s` and a C program does not, and the test catches `int` and `std::runtime_error` (2/2 on the Pi).
- A Haiku image rebuilt with the new tools is unaffected (rc 0).
- A scan of 85 packages found the affected ones: libGLU's NURBS error paths and libEGL_mesa's catch.

### 14.2 Short form

<a id="buildtools-02"></a>

#### BUILDTOOLS-02 — build_cross_tools_gcc4: renames libstdc++.a but leaves libstdc++.la pointing at it (libtool C++ links fail)

- **What:** The installed `aarch64-unknown-haiku/lib/libstdc++.la` keeps `old_library='libstdc++.a'` and `library_names=''`. libtool links C++ libraries with `-lstdc++` from `postdeps` and resolves it through this `.la` to a `libstdc++.a` that no longer exists.
- **Severity / scope:** build; Haiku cross tools, all architectures. Affects libtool-built C++ shared libraries linked with the cross tools.
- **Our fix:** a workaround only. `scripts/build-blender.sh` (step `gmp`) rewrites the generated libtool's `postdeps` `-lstdc++` → `-l:libstdc++.so`. libtiffxx was left out for the same reason.
- **Patch:** no. Proposal: after the `mv`, also delete `$installDir/$haikuMachine/lib/libstdc++.la`, or set its `old_library` to `libstdc++-static.a`.
- **Upstream status:** open. haiku `master` 52912f5be3, `build/scripts/build_cross_tools_gcc4:286-289` (`mv … libstdc++.a … libstdc++-static.a`), with no change to the `.la`. Tracker: not searched.
- **Short form because:** affects only our cross-toolchain use of libtool C++ links.

<a id="gcc-01"></a>

#### GCC-01 — libstdc++ `<bitset>`: GCC 16 freestanding build fails, `__throw_logic_error` undeclared (existing PR 128880)

- **What:** In GCC 16 the constructor `bitset(const _CharT*, …)` calls `__throw_logic_error` without the `_GLIBCXX_HOSTED` guard GCC 13 had. A freestanding compile does not declare that helper, and the call is non-dependent, so merely including `<bitset>` is an error.
- **Severity / scope:** build; any platform (any `-ffreestanding` user of `<bitset>`). We hit it with Haiku's kernel add-ons.
- **Our fix:** buildtools commit c2213226f9 on the haiku-pi fork (`gcc16`). It restores `#if _GLIBCXX_HOSTED` around the null check in `bitset(const _CharT*, …)`, as GCC 13 had it.
- **Patch:** with notes. It is a two-line guard. The PR's attachment instead declares the function for freestanding. Maintainers pick one.
- **Upstream status:** open. gcc-mirror `master` 4582d80bb1e8 `libstdc++-v3/include/std/bitset:1112-1113` and `releases/gcc-16` 71b1c265e9ae `:1068-1069` call `__throw_logic_error` unguarded. `bits/stdexcept_throwfwd.h` declares it only `#if _GLIBCXX_HOSTED`. Tracker: searched Bugzilla "bitset freestanding", which found PR 128880.
- **Short form because:** already reported (PR 128880): comment there.

## 15. Other ports: CMake, ioquake3, vkQuake

Checked against Kitware/CMake `master` `b3dfac925165`, ioquake/ioq3 `main` `52088b9eae24` and Novum/vkQuake
`master` `1e573d749014`.

<a id="cmake-01"></a>

#### CMAKE-01 — Utilities/cmlibuv: CMake's own CMakeLists for the bundled libuv has no Haiku branch (link fails)

- **What:** CMake builds its bundled libuv from its own `Utilities/cmlibuv/CMakeLists.txt`, not from libuv's. That file adds per-OS sources for every platform libuv supports except Haiku, so on Haiku the platform functions from `src/unix/haiku.c` and the POSIX helpers are never compiled.
- **Severity / scope:** build; Haiku, all architectures, when CMake is built with CMake using the bundled libuv (the default without `-DCMAKE_USE_SYSTEM_LIBUV=ON`). HaikuPorts uses the system libuv, so its package does not hit this.
- **Our fix:** `patches/cmake-4.4.5/0001-cmlibuv-build-the-Haiku-platform-sources.patch`. It adds an `if(CMAKE_SYSTEM_NAME STREQUAL "Haiku")` block with the sources, define (`_BSD_SOURCE`) and libraries (`bsd`, `network`) of upstream libuv's own CMakeLists.
- **Patch:** attachable as-is (made on 4.4.5; the context is the HP-UX block, which is unchanged on `master`).
- **Upstream status:** open. CMake `master` b3dfac925165 `Utilities/cmlibuv/CMakeLists.txt:134-340` has branches for AIX, OS400, Cygwin, Darwin, Linux, the BSDs, SunOS, HP-UX and QNX, but none for Haiku. `Utilities/cmlibuv/src/unix/haiku.c`, `posix-hrtime.c`, `posix-poll.c` and `bsd-ifaddrs.c` are all present. Tracker: searched GitLab issues for "haiku": #27186 and older closed ones, none about libuv.
- **Short form because:** build glue for a platform CMake does not list.

<a id="ioq3-01"></a>

#### IOQ3-01 — sys_main.c: Sys_SigHandler shuts client, renderer and server down inside the signal handler (processes left hung after SIGTERM)

- **What:** `Sys_SigHandler`, installed for SIGTERM and SIGINT among others, calls `CL_Shutdown`, `SV_Shutdown` and the VM unload inside the handler. These tear down the renderer and SDL, allocate memory and take locks.
- **Severity / scope:** hang; any platform in principle. The handler calls async-signal-unsafe code: `CL_Shutdown` → renderer and SDL teardown, malloc, `va()`. Observed on Haiku arm64.
- **Our fix:** `patches/ioq3/0002-quit-signal-from-main-loop.patch`. SIGTERM/SIGINT set a `sig_atomic_t` flag, and the main loop runs `quit` between frames through the command buffer. A second request, a request before the main loop starts, or any signal during that quit calls `_Exit()`.
- **Patch:** with notes. It removes `Q_NO_RETURN` from `Sys_SigHandler`'s declaration (`sys_local.h:64`). Keeping it while making the handler return lets the compiler drop the `ret`, and the handler then runs into the next function. That was a bug in our first version of this patch, not upstream's.
- **Upstream status:** open. ioq3 `main` 52088b9eae24 `code/sys/sys_main.c:754-778` (shutdown calls in the handler) and `:884-888` (installed for SIGTERM/SIGINT). Tracker: searched "SIGTERM" and "signal handler", none relevant.
- **Short form because:** evidence confounded with other changes.

<a id="vkquake-01"></a>

#### VKQUAKE-01 — common.c: "+command" arguments are ignored with the shareware data (cmdline cvar set only for the registered version)

- **What:** FitzQuake rewrote `Cmd_StuffCmds_f` to read the `cmdline` cvar instead of `com_argv`. `COM_CheckRegistered` sets that cvar only on the registered path, after the `gfx/pop.lmp` check.
- **Severity / scope:** wrong output (command-line commands silently ignored); any platform.
- **Our fix:** `patches/vkquake/0002-shareware-command-line.patch`. It sets the `cmdline` cvar before the `pop.lmp` check.
- **Patch:** with notes. It is written against 1.35.0 and needs a rebase onto `master`: the same code, at different lines.
- **Upstream status:** open. vkQuake `master` 1e573d749014 `Quake/common.c:2018-2049`: the shareware branch returns at `:2036` before `Cvar_SetROM ("cmdline", …)` at `:2047`. `Cmd_StuffCmds_f` (`Quake/cmd.c`, "rewritten to read the cmdline cvar") then finds nothing. QuakeSpasm's `COM_CheckRegistered` has the same structure, and QuakeSpasm 0.96.3 shows the same symptom (our games bench passes its shareware timedemo through `id1/autoexec.cfg` for that reason). Tracker: searched "shareware", "timedemo" and "stuffcmds" in vkQuake: only #551 ("Cannot play Shareware version after fresh compilation", closed, a different problem).
- **Short form because:** shareware data only.

## Already fixed upstream (no report needed)

Bugs we found and fixed that upstream has fixed since (often its own way), with the upstream commit. Where upstream fixed only part of a bug, the open part is an entry above.

### Haiku

- lock_memory_etc() partial-wire panic ("VMArea::Unwire(): no such range"): our 6f810ed2d7; upstream 1d78c5f430 (hrev60353, 2026-11-04, #20476) — the same fix, taken by our tree at the 11-17 merge.
- MAP_SHARED mapping loses B_SHARED_AREA across mprotect(): our 894c4abe7f (flag half); upstream af99ec6c14 (hrev60370, 2026-11-05, #20479) — keeps the non-user and invariant protection flags. The copy-on-write half is HK-03.
- A fault whose signal is blocked or ignored repeats forever: our 6e517bb52c; upstream 4197d30fc1 (hrev60381, 2026-11-04) — `send_signal_to_thread_forced()`, plus 52912f5be3 (hrev60450, write lock). Ours was dropped at the 11-17 merge.
- Scheduler: two busy threads share one core (capped core load in rebalance): our 2486477fab; upstream 98f2805e27 (hrev60327, 2026-11-03, #19828) — `GetLoad()` uncapped again; our `GetUncappedLoad()` is now redundant.
- CNTKCTL_EL1 not set after the EL2→EL1 drop (EL0 counter reads trap): our 9148d14cac; upstream 280e8d1ce6 (hrev60437, 2026-11-16) — the same move of the write.
- Debug UART not page-aligned ("Too many levels at mapping"): our 9678b4cd65; upstream 8098710239 (hrev60322, 2026-10-22) — maps the containing pages and keeps the offset.
- Spin-table release address not cleaned to PoC: our 022ca91504 (flush part) and d3c5064bd0; upstream b00f6a9170 (hrev60321, 2026-10-24) — `dc cvac` before `sev`. `sCpus`/`sSecondaryStacks` are already cleaned by the primary's `arm64_mmu_setup()` → `_arch_cache_clean_poc()` (`arch_mmu.cpp:135`).
- Secondary CPUs released at EL2 enable their MMU with `TTBR0_EL1 = 0`: our 022ca91504; upstream 6df6939f4e (hrev60404, 2026-10-28) — copies the primary's TTBR0/MAIR/VBAR_EL2 to secondaries, partly. `_arch_transition_EL2_EL1()` (`transition.S:49-53`) still replaces the EL1 TTBR0/MAIR/VBAR that `arm64_mmu_setup()` just wrote with the firmware's EL2 values. Under U-Boot, EL1 then runs on U-Boot's MAIR (no 0xbb entry), so a `B_WRITE_THROUGH_MEMORY` or `B_WRITE_PROTECTED_MEMORY` mapping would reach `panic("MAIR entry not found")` (`VMSAv8TranslationMap.cpp:504`). No in-tree caller requests one today, so it is not filed.
- device_manager `get_next_child_node()` returned only the first child: our 81deb24f8c; upstream 4aae8640c9 (hrev60379, committed 2026-11-07) — the skip loop now stops at the previous child.
- ICMPv6 error messages were stubs (no Destination Unreachable sent or delivered; resolver waits without DNS): our 25c9881600; upstream 5119a99783 (hrev60438, committed 2026-11-19) — `icmp6_error_reply()` implemented; it has the separate bugs in HK-86.
- launch_daemon environment pipe not close-on-exec (RenkuOS #231): our fb4e339ce8; upstream e039b9662a (hrev60329, committed 2026-11-03) — `pipe2(..., O_CLOEXEC)` in `_GetSourceFileEnvironment()`.
- freebsd_network `compat_send()` leaked the mbuf on early returns (RenkuOS PR #483): our 03f7a90189; upstream b96eb67dce (hrev60439, committed 2026-11-19) — the same fix (`m_free()`).
- libroot rw_lock spun after an interrupted block (lost hand-off, application freeze): our 2bf2f773ba; upstream cf3a20899c (hrev60391, committed 2026-11-10) — fixed at the root in the kernel (`block_thread` no longer leaves `B_INTERRUPTED` in `wait_status`); the libroot `rw_lock.cpp:43-44` loop is unchanged, and `src/tests/system/libroot/os/rw_lock_interrupt_test.cpp` has not been re-run on hrev60391 or later, so this rests on code reading.

### Mesa

- **broadcom/compiler: a vector `mov` moved only `.x`.** Fork fix `dee7e96cb04`. Fixed on main by **ec71bd60285** "broadcom/compiler: scalarize every phi" (!46417, 2026-11-18, `Backport-to: *`). Upstream takes a different route: every phi is lowered to scalar and a vector mov in the general case asserts. It is not in any release yet, including 26.3.1 (2026-11-18), and should arrive in a later 26.3.x. When the fork moves to 26.3.x, drop our commit or keep it as a belt-and-braces check.
- **v3d: the BO cache mutex was used without `mtx_init()`.** Fork `c99ef1d040c`. Upstream **6e976a340bc** (!43403), released in **Mesa 26.3.0**.
- **v3dv: the BO cache mutex was used without `mtx_init()`** (part of fork `640e69292c3`). Upstream **31ea25121e8** (!43403), released in **Mesa 26.3.0**.
- **v3dv: supertiles past the far edge of the render area** (#13218). Upstream **d30a6f81023** (!35257), released in **Mesa 25.2**. MESA-01 is the near-edge remainder.
- **GL_MESA_map_buffer_client_pointer itself.** Fork `ce682c7dafe`, `4b1b70b5c93` and `5319e6b330f` are backports of upstream 990bc5d6493, f4c2f1083a1 and c0bcffb1b0a (Mesa 26.3.0). They are not fixes; MESA-03 is a defect in that upstream code.

### Wine and Box64

- **0030 — ddraw: v1 primary surface without a render-target format** (`patches/wine-11.21/0030-ddraw-v1-primary-without-render-target-format.patch`).
  - **Cause:** a regression from 6b486ec7830a (first released in wine-11.11). It broke the Diablo II demo with "Error 22" on any GL driver, including x86-64 Linux with llvmpipe.
  - **Fix:** c209164dafff "ddraw: Do not force render target for surface formats which do not support it." (2026-11-06). It is in **wine-11.22**, not in 11.21.
  - **To do:** drop our patch when we move to 11.22. We have not re-tested upstream's fix.
- **Box64 0002 — the x86-state half** (`patches/box64/0002-wowbox64-exception-state.patch`: the x86 Eip and registers in the exception context for faults in JIT code).
  - **Fixed by:** Box64 PR #4550 / a489cfe7d03f "[WOWBOX64] Fix exceptions in JIT code above 4GB and pass the fault state to the guest" (2026-10-09; issue #4549), after our v0.4.4 base. Upstream fills `wctx->Eip`/registers/EFlags/FPU in `BTCpuResetToConsistentState`.
  - **Not checked:** our patch also sets `rec->ExceptionAddress`, which upstream does not. Whether Wine's WoW64 derives the 32-bit exception address from the context was not checked.
  - **Still open:** the write-fault half is BOX64-02.

### FFmpeg, Blender, OpenUSD

- **FFmpeg** mmaldec missing comma after `caps_internal` in `FFMMAL_DEC`, so 6.1 does not compile with `--enable-mmal` (part of `patches/ffmpeg6/0002-mmal-haiku.patch`).
  - Fixed in master by `e8a49b1424` (trac #10670, 2023-11-22), which is in 7.0.
  - Not backported: `release/6.1` (`30e346c76f`) still has the bug at `libavcodec/mmaldec.c:846`. A backport request to the 6.1 branch is the only action.
- **Blender** libmv `numeric.h` missing assert include (`patches/blender/0003-libmv-numeric-include-assert.patch`): main includes `<cassert>` since `7b19e74cad` (2025-12-14).
- **Blender** OpenImageDenoise on Linux/ARM64 (`patches/blender/0011-oidn-on-arm64.patch`): fixed by `45447e8b2f` (#122933, 2024-06-11, Blender 4.2). Windows ARM64 came in `3d5fa7698f`.
- **Blender** OIDN quality (`patches/blender/0012-oidn-balanced-quality.patch`): Cycles has a user "Quality" option since `2a0a6f18cc` (2024-05-06). Our patch only changes 3.6's hard default.
- **Blender** `usd_common.cc` SEP_STR include (`patches/blender/0015-usd-common-include-path-util.patch`): the code was removed by `ff7dc64234` ("remove unused USD plugin path registration", 2023-06-07), in 4.0.
- **Blender** GHOST_SDL `getCursorPosition` returned `y = yi + x_win` (noted in docs/design/blender.md §7.5; not patched): main has `y_win` (`GHOST_SystemSDL.cc:699`); commit not identified.
- **Blender** BLI recursive delete/copy NULL path element (`patches/blender/0016-blenlib-haiku-recursive-operation.patch`): Haiku-only (`#ifdef __HAIKU__` block). Main already uses `lstat(src_buf->str, …)` (`fileops_c.cc:1073-1078`); commit not identified.
- **OpenUSD** `SdfChildrenProxy::_ValueProxy::operator=` calling the non-existent `_Set` (rejected by GCC 16; `usd-24.08.patchset` patch 2): removed by `5a6437e442` (2024-11-23), first in v25.02.
- **OpenUSD** oneTBB 2022 `m_wait_vertex` (`usd-24.08.patchset` patch 3, a backport of PR #3392): in v25.05.

### SDL, Wayland, Rust and others

- **Rust std `File::lock`/`try_lock`/`unlock` on Haiku** (`patches/rust/1.99.1/0002-haiku-file-locking.patch`): `target_os = "haiku"` is in the flock cfg lists on rust-lang/rust `main`, `library/std/src/sys/fs/unix.rs:1325-1460` (PR #164031 "Adding File Lock Support for Haiku", closed 2026-10-12).
- **X547/wayland `wl_display_dispatch_queue` 100 % CPU** (`patches/wayland/…-dispatch-blocks.patch`): fixed in X547/wayland fd5a7bff0454 (2026-04-18). HaikuPorts still pins the old revision, see HAIKUPORTS-02.
- **X547/wayland-server text-input-v3 v2 build failure** (`patches/wayland_server/…-text-input-v2.patch`): fixed in fb4e41650877 (2026-08-06). HaikuPorts still pins the old revision, see HAIKUPORTS-01.
- **SDL Haiku: `free()` of an unset mode list when `GetModeList()` fails**: fixed by SDL #14778/#14779 (2026-01). The dangling-pointer defect is separate and still open, see SDL-03.
- **SDL2 Haiku: BHandler on the existing BApplication instead of a separate BLooper** (HaikuPorts patchset): already in the `SDL2` branch.

## Pi 4 / BCM2711-specific items

Short notes on upstream code that only this board (or boards like it) reaches. None needs a full report; they are listed so that another Pi 4 or BCM2711 port can find them.

### Haiku

- PL011 `PutChar()` waits for FIFO room without a limit (`arch_uart_pl011.cpp:277`): our 80a6e1f2fb bounds it (~200 000 status reads). Hardening for a UART whose clock is gated; written while hunting a Pi network-boot wedge that it did not fix. Not filed as a bug.
- MDCR_EL2 is never set when the EFI loader drops from EL2 (`transition.S` `drop_to_el1`): our e944a1ab38 clears the debug/PMU traps and sets HPMN = PMCR_EL0.N, as Linux does. U-Boot on the Pi leaves it at its partly unknown reset value. It only matters once EL1 uses the debug or PMU registers, which upstream does not yet do on arm64.
- GICv2 spurious interrupt (1023) printed and EOI'd (`arch_int_gicv2.cpp:124-125`): our 70e77d8c29 returns silently. It is only frequent when SPIs are routed to several CPUs, which our tree does; upstream routes all SPIs to CPU 0 (`arch_int_gicv2.cpp:44`, `0x01010101`).
- xHCI ring entries of completed TDs are left valid and nothing pads against TRB overfetch: the VIA VL805 (also sold as PCIe add-in cards; Linux sets `XHCI_TRB_OVERFETCH` for it) replays stale Link TRBs and the root hub stops answering until reboot. `src/add-ons/kernel/busses/usb/xhci.cpp:1374-1378, 2803-2804`; our c65ac5a2e6 (generic ring clearing + VL805 padding; split before sending). Pi 4: 59 of 623 boots before, 0 of 40 after.
- usb_disk fixes its DMA high address at 4 GiB (`usb_disk.cpp:957`) and ignores a lower `B_DMA_HIGH_ADDRESS` published by an ancestor bus (BCM2711 PCIe reaches only the first 3 GiB): our 61fe84cd93. Latent upstream, as no upstream bus publishes a lower limit on a USB ancestor. `tools/haiku-tests/usbhigh.c`: 866 of 3392 slices wrong before, 0 after.
- SDHCI core uses 8- and 16-bit register accesses; controllers that accept only 32-bit accesses (brcm,bcm2711-emmc2) do not work, and a base clock from the platform is not supported: our 23f6235b0d (hardware-support part; see HK-57 for the generic bugs).
- openbsd_wlan's Haiku join ioctl sends three settings that each return ENETRESET, so the interface is restarted three times per join (`src/libs/compat/openbsd_wlan/net80211/ieee80211_haiku.cpp:439, 445, 452`; the Intel drivers restart the same way): our f43d42c93b. Failed joins were seen only with our own WiFi driver (1 of 2 joins failed before, 3 of 3 succeeded after).

### U-Boot

- `0001-video-bcm2835-request-BGR-pixel-order.patch` (**Pi-specific**): U-Boot draws `0x00RRGGBB` and its GOP reports BGRA8 but requests RGB order from the firmware (`drivers/video/bcm2835.c:27` at `ece349ade2`, unchanged). Check against the firmware's `framebuffer_swap` setting before sending. Patchwork "bcm2835 pixel order": none. CC Brugger/Robinson (BCM283X), Gustschin (VIDEO).
- `0002-net-bcmgenet-delay-transmit-clock-for-rgmii-rxid.patch` (**Pi-specific**): `ID_MODE_DIS` is set for `rgmii-rxid` too (`drivers/net/bcmgenet.c:464-466` at `ece349ade2`, unchanged). Linux sets it only for `rgmii` (`bcmmii.c:246-263`). Our symptom: no TX at 1000 Mbit/s. Reverses part of the accepted 2020 patch "bcmgenet: Add support for rgmii-rxid", so expect discussion. CC Forissier (NETWORK).
- `0003-mmc-bcm2835-no-command-wait-on-emmc2.patch` (**Pi-specific**, performance): `SDHCI_QUIRK_WAIT_SEND_CMD` (1 ms per command) is also applied to the BCM2711 EMMC2 (`drivers/mmc/bcm2835_sdhci.c:213-214`, unchanged). Linux's sdhci-iproc has no such quirk for bcm2711. Cost: 2.5 s per 728 block reads. A similar drop for msm_sdhci is pending on patchwork (2026-10-30). CC Brugger/Robinson, Fan/Chung (MMC).

## Checked and not reported

Candidates that were read and left out, with the reason: new features, tuning, Haiku port glue, code that exists only in our fork. Kept so that the selection can be reviewed.

### Haiku

- `4413675f5c` (`arch_get_stack_trace()`/`arch_debug_get_interrupt_pc()` stubs, `arch_debug.cpp:370-381`) and `c7509f4229` (`arch_cpu_shutdown()` stub, `arch_cpu.cpp:78-82`; PSCI off/reset, RenkuOS #160): missing features, not defects.
- `7225a5f244` (emulating EL0 `MRS` of ID registers, as Linux): a compatibility feature. Its upstream symptom, a kernel panic, is HK-01.
- `a46a16641e` (deadlock detection by time): needed only together with HK-07; folded there.
- `3a0be104e3` (`IOOperation::fSavedVecLength` is `uint16`, `IORequest.h:187-188`): unreachable upstream. The shortened vec is a bounce vec, at most `kMaxBounceBufferSize` = 4 pages = 16 KiB with 4 KiB pages (`dma_resources.cpp:29`). It broke only with our 128 KiB bounce buffers (`8edea64c6b`, fork-only). With 16 KiB pages it would be 64 KiB, which also truncates to 0.
- `67b8a53cbe` (prefetch 1 MB instead of 10 MB of a mapped file): tuning, not a defect.
- `70e77d8c29`, `80a6e1f2fb`, `e944a1ab38`: see the Pi 4 list.
- 88b487e15b (Debugger step-out compared the frame pointer register with the frame's CFA): the compare in `ThreadHandler.cpp:1029-1030` is generic, but the failure was shown only with our arm64 Debugger back end, which upstream does not have; send it with that back end.
- 68293c40a1: `mmc_disk`'s disabled `TRACE()` breaks an if/else, but only when tracing is turned off; upstream builds with tracing on (`TRACE_MMC_DISK`, `MMCBUS_TRACE`, `TRACE_SDHCI`), which slows an SD boot on a serial console by over a minute (policy, not a defect).
- d20bc8fa87: ACPI init failure messages and a search for the missing ps2 bus manager on device-tree arm64 boots; log noise only.
- 8f0df61a1c, b689ed27d7, bf33dc5c29, a6ca113d55, 444704d5f1 (folded into HK-76), f2e5b2fab8: change code that exists only in our tree. Upstream's `NetBootArchive` also lacks the network notifications module (unverified at run time).
- 289d8095c0 (usb_disk 256 DMA segments), 13a39894c2 (app_server font precache thread), ea305c7a9c (JPEG translator decodes straight to BGRA): speed-ups, no defect.
- 7e6832e359 / 6b28c8b68a / 49ddfe1e9e (ffmpeg add-on encoder timestamps, H.264 in the encoder table): the timestamp guess is reachable only with an encoder that returns several packets per frame (h264_mmal); H.264 encoding is a feature.
- 77d28ba987, d6b719aac9: upstream persists networks through wpa_supplicant's "Store this configuration"; the auto-join retry is an enhancement.
- d8dfb51d8d / f316d4920e net mask and gateway from `ip=`: missing feature (the parse loop itself is HK-62).

### Mesa, libdrm, libglvnd

- **mesa `447abaea964`** "egl/haiku: a signal must not end the presenter thread": the presenter thread exists only in the fork (`a7a7ee816bc`). Upstream `egl_haiku.cpp` has no thread or semaphore.
- **mesa `9fbf45c0374`** "hgl: allow the compressed-format fallback": no symptom upstream. Haiku's upstream drivers (llvmpipe/softpipe) sample RGTC natively; only the fork's v3d on Haiku lacks it. Offer it together with Haiku v3d support if that is ever proposed.
- **mesa `9623a96e522`** "egl: link libEGL with a build ID": only our Haiku build links gallium v3d into libEGL. On Linux, libgallium has a build ID. `v3d_disk_cache.c:55-57` only `assert`s the note; turning that assert into a NULL check would be hardening, not a reported bug.
- **mesa `4b9cd0bc85b`, `3de858c34bf`, `364a5ec8c79`** (depth-clamp emulation and seamless cube maps on V3D 4.x, which give GL 3.3): features, not defects. They could be offered as an MR on their own.
- **mesa `1986798cb22`** "st/pbo: keep depth clipping on": no effect on upstream drivers. It only avoids work with the fork's emulated clamping.
- **mesa `640e69292c3`** (rest), `95f718e9dbc`, `f2d6a5f9e39`, `c36c62edfc0`, `986628c45fc`, `648f7de69d9`, `2e5fc430445`, `54f4a3f2edc`, `a7a7ee816bc`, `cf4704211f9`, `3f1ab3f8289`, `f56bf64ac2b`, `1595aba36ec`, `0d66dfb91fb`, `b691443f2cd`, `8eca0a3889a`, `99a38801af0`: Haiku v3d/v3dv winsys, the Haiku Vulkan WSI, presentation, the disk-cache location, and headers. These are new platform code with no upstream counterpart.
- **mesa `4ff42d768c2`** "renderdoc: Add Haiku platform support": an upstream commit that upstream later reverted (f009ee9bfdf); it is carried in the fork.
- **libdrm `62107104`, `a3ac76e6`, `bd858a24`**: Haiku port glue. `bd858a24` exists because `-errno` is positive on Haiku, where errno values are negative; Linux is unaffected. No generic libdrm defect.
- **libglvnd `33d3b66`, `9bbfec4`, `ed01b68`, `536f5c1`, `7cc03c3`, `be20124`, `83d9cc2`**: all in `src/HGL`, Haiku-only code. `ed01b68` is reported as [LIBGLVND-02](#libglvnd-02), `33d3b66` as LIBGLVND-01 and the vSync part of `be20124` as LIBGLVND-03; the rest is port glue.

### Wine

- `0001-haiku-arm64`: the Haiku/arm64 port itself (configure, ntdll, nsiproxy, serial …).
- `0002-winehaiku-audio`: new Haiku Media Kit audio driver.
- `0003-win32u-egl-gl21-window`, except the GL 2.1 hunks in WINE-14: the GDI present path for the surfaceless EGL driver (no Wayland EGL on Haiku).
- `0004-ntdll-haiku-arm64-fault-write`: synthesises an ESR because Haiku's signal frame has none.
- `0005-kernelbase-crash-report`: a diagnostic feature (stderr crash report because winedbg cannot attach on Haiku); not a bug.
- `0006-win32u-framebuffer-resize-keeps-contents`: not reported. We saw it only through Haiku's surfaceless window framebuffer. Upstream's emulated-modeset framebuffer surface (`dlls/win32u/opengl.c:2351`, logged as "experimental") runs the same `resize_framebuffer()` and could show it, but we have no upstream reproduction. GL does not guarantee a buffer's contents across a resize, and the patch's main user, DirectDraw drawing once to the front buffer, is better reported with a reproduction on an upstream driver. Revisit it if that path becomes the default.
- `0007-ntdll-haiku-arm64ec-map-noreserve`: Haiku commits readable private mappings; Linux does not.
- `0009-ntdll-haiku-processor-info-id-regs`: the Haiku `create_logical_proc_info` and ID registers.
- `0011-ntdll-haiku-arm64-foreign-thread-signal`: Haiku's own non-Wine threads inside Wine processes.
- `0019-winewayland-haiku-display-modes`: real mode setting through Haiku's in-process Wayland server.
- `0020-server-kqueue-on-haiku`: kqueue via libbsd, specific to Haiku's kqueue semantics.
- `0023-winewayland-haiku-popup-no-activate`: a Haiku Wayland server extension.
- `0024-ntdll-server-dotnet-native-arm64`: an opt-in feature (`WINE_DOTNET_NATIVE=1`) that changes upstream's deliberate choice to run IL-only images as x86-64. Not a bug.
- `0025-ntdll-haiku-flush-process-write-buffers`: `NtFlushProcessWriteBuffers` through a haiku-pi kernel syscall.
- `0027-ntdll-server-haiku-thread-signals`: the Unix thread ID on Haiku (no `gettid`).
- `0031-nsiproxy-haiku-ipv4-routes`: IPv4 route table on Haiku.
- `0032-nsiproxy-haiku-find-interface-by-index`: reverts an older Haiku-only stub.

### FFmpeg, Firefox, Blender, OpenUSD, OpenImageIO, raspberrypi/userland, U-Boot

**FFmpeg**
- `patches/ffmpeg6/0001-hevc-rpivid.patch`, `patches/ffmpeg6-next/0006-rpivid-out.patch`: Pi-only HEVC hwaccel, not upstream code.
- `patches/ffmpeg6/0003-h264-vc.patch`: our own wrapper decoder (h264_vc).
- `patches/ffmpeg6/0004-h264-mmal-encoder.patch`: new encoder. Upstream has no `mmalenc.c` (404 on master).
- `patches/ffmpeg6/0002-mmal-haiku.patch`, parts not covered by FFMPEG-01/02:
  - configure without bcm_host and `#ifndef __HAIKU__`: Haiku glue.
  - logging: ours.
  - `MIN_BUFFERED_PACKETS` (keep 8 packets queued; it removed 70–90 ms output gaps at 1080p for Haiku's media plugin, which sends a packet only when no frame is ready): tuning. Upstream's comments at `mmaldec.c:684-694` (master `21c81303cb`) describe the lockstep feeding as intended, and the evidence comes from one caller. At most an enhancement request.
  - `extra_buffers` 10→2: tuning for gpu_mem 76; mention only as a note in FFMPEG-02.
  - `.bsfs = "h264_mp4toannexb"`: no failure was shown without it, and upstream dropped the BSF on purpose (`f290e48d86`, 2015: "We can send mp4-style data directly").
- `patches/ffmpeg6/0005-mmal-one-decoder.patch`: system-wide flock on `/tmp` limiting the VideoCore to one decoder. A policy workaround for firmware memory; the error handling it compensates for is FFMPEG-02.

**Firefox**: no qualifying entries.
- `patches/firefox/0001`–`0008` are Haiku glue: arm64 xptcall, NSPR/NSS, headless and widget for Haiku; BGL/libGL runtime name; ES context in BGLView; `getentropy()` in a Haiku branch; SWGL with clang under a GCC build (upstream always builds with clang); the video overlay in `widget/haiku` and its WebRender hooks.
- The empty-dirty-rect change in 0007 only occurs with our plane path.
- The SIGILL at SIGTERM (`MOZ_RELEASE_ASSERT(mFrameLoader)`) noted in docs/design/firefox-quit-crash.md is a known Firefox issue, not patched by us.

**Blender**
- `0001-ghost-sdl-request-core-profile`: Haiku-only. GLX/WGL default to the core profile when no profile is asked for, and main needs GL 4.3 anyway.
- `0002-cmake-import-host-generators`: cross-compiling feature, not a bug.
- `0005`/`0007` (fewer than 8 colour attachments) and `0008` (blit instead of `glCopyImageSubData` on v3d): V3D-only. GL 3.0 requires 8 attachments, and main requires GL 4.3 (`gl_backend.cc:223`).
- `0009-ghost-sdl-unicode-text-input`: a feature. Upstream's own TODO is still at `GHOST_SystemSDL.cc:656`, and main uses SDL3, so the SDL2 patch does not apply. Could be offered as a PR later.
- `0014-draco-on-haiku`: Haiku glue.

**OpenUSD**
- `usd-24.08.patchset` patch 1 (arch: Haiku support), including the plug-in lookup (`ArchGetAddressInfo()` uses `dladdr()` only `#if defined(_GNU_SOURCE) || defined(ARCH_OS_DARWIN)`, `pxr/base/arch/symbols.cpp:31` at dev `80c23ad590`): Haiku-only.
- On Linux, g++ predefines `_GNU_SOURCE` (checked: `g++ -dM -E -x c++ /dev/null` → `#define _GNU_SOURCE 1`), so Plug finds its plug-ins there.

**OpenImageIO**
- `openimageio2.4-2.4.15.0-physical-memory.patch`: Haiku-only. Upstream main has no `__HAIKU__` code at all (`src/libutil/sysutil.cpp:214-218` asserts on unknown platforms).
- `openimageio2.4-2.4.15.0.patchset`: HaikuPorts' Haiku patches.

**raspberrypi/userland**
- Patch 1 (`VCOS_ONCE_INIT` for zero-initialised `pthread_once_t`): portability only; correct on glibc and musl.
- Patches 3/6 (Haiku support, Makefile) and 5 (64-bit message layout): MMAL is not built for ARM64 upstream (`CMakeLists.txt`, `BUILD_MMAL`).
- The `NDEBUG` part of patch 10: our Makefile only.

**U-Boot**
- `0005-efi_loader-hand-out-cleared-pages.patch`: not a U-Boot bug. The UEFI spec leaves `AllocatePages`/`AllocatePool` contents undefined, EDK2 does not clear them either, and the reader of the garbage was Haiku's kernel (`d1a616afac`). Kept as hardening.
- `0001-video-bcm2835-request-BGR-pixel-order.patch` (**Pi-specific**): U-Boot draws `0x00RRGGBB` and its GOP reports BGRA8 but requests RGB order from the firmware (`drivers/video/bcm2835.c:27` at `ece349ade2`, unchanged). Check against the firmware's `framebuffer_swap` setting before sending. Patchwork "bcm2835 pixel order": none. CC Brugger/Robinson (BCM283X), Gustschin (VIDEO).
- `0002-net-bcmgenet-delay-transmit-clock-for-rgmii-rxid.patch` (**Pi-specific**): `ID_MODE_DIS` is set for `rgmii-rxid` too (`drivers/net/bcmgenet.c:464-466` at `ece349ade2`, unchanged). Linux sets it only for `rgmii` (`bcmmii.c:246-263`). Our symptom: no TX at 1000 Mbit/s. Reverses part of the accepted 2020 patch "bcmgenet: Add support for rgmii-rxid", so expect discussion. CC Forissier (NETWORK).
- `0003-mmc-bcm2835-no-command-wait-on-emmc2.patch` (**Pi-specific**, performance): `SDHCI_QUIRK_WAIT_SEND_CMD` (1 ms per command) is also applied to the BCM2711 EMMC2 (`drivers/mmc/bcm2835_sdhci.c:213-214`, unchanged). Linux's sdhci-iproc has no such quirk for bcm2711. Cost: 2.5 s per 728 block reads. A similar drop for msm_sdhci is pending on patchwork (2026-10-30). CC Brugger/Robinson, Fan/Chung (MMC).

**HaikuPorts recipe candidates**
- `media-libs/openimageio/openimageio2.5-2.5.12.0.recipe` + `patches/openimageio-2.5.12.0.patchset`: no `Sysutil::physical_memory()` for Haiku, so every OIIO user prints "Need to implement Sysutil::physical_memory" and gets 0 bytes. Our `tools/recipes/media-libs/openimageio/patches/openimageio2.4-2.4.15.0-physical-memory.patch` (via `get_system_info()`) ports directly.
- `dev-libs/gmp/gmp-6.3.0.recipe`: reported as [HAIKUPORTS-04](#haikuports-04).
- The `libstdc++.la` trap (libgmpxx, libtiffxx): reported as [BUILDTOOLS-02](#buildtools-02). Haiku's `build/scripts/build_cross_tools_gcc4:286-289` renames `libstdc++.a` to `libstdc++-static.a` and leaves the `.la` pointing at it.

### SDL, Vulkan-Loader, Wayland, ports, toolchain

- **Vulkan-Loader** `vulkan-loader-1.4.311-haiku-view-surface.patch`: teaches the loader an unregistered Mesa-private sType (1000256900, `VkHaikuSurfaceCreateInfoMESA`). The loader's dropping of unknown chained structs is by design.
- **SDL** `…-haiku-vulkan.patch`: a feature, Vulkan on Haiku (SDL #7798 is open as a feature request).
- **SDL** `…-haiku-gles.patch` and `…-haiku-glview-core.patch`: depend on the `BGL_CONTEXT_ES`/`BGL_CONTEXT_CORE` flags, which exist only in our libglvnd fork.
- **wayland_server** `wl-output-modes`, `wl-surface-no-activate`, `wl-surface-view`: new exported APIs for Wine and wgpu.
- **glmark2:**
  - 0001: Haiku native state.
  - 0002: no `RTLD_NODELETE` on Haiku.
  - 0004: sonames first, cosmetic.
  - 0005: experiment.
  - 0003 (release the EGL context before `eglTerminate`) works around a Mesa Haiku-EGL defect; glmark2's call order is legal EGL.
- **ioq3** 0001 (Haiku platform) and 0003 (no zenity/kdialog on Haiku). **vkQuake** 0001 (Haiku platform). **yquake2** 0001 (Haiku default renderer). **SuperTuxKart** 0001/0002 (build-script FreeType, Haiku legacy-renderer default).
- **numpy** 0001: the cause is Haiku's `<ctype.h>` function-like macros in C++. HaikuPorts' numpy patchset already carries the same change; any report belongs to Haiku.
- **CPython** 0001 (configure cross builds for Haiku), **HaikuWebKit** and **SpiderMonkey** (arm64 JSC/JIT/wasm support): new-platform glue. CPython does not support Haiku officially.
- **Rust** `aarch64-unknown-haiku` target and **rust-libc** `0001-haiku-aarch64-module.patch`: rustc has no such target (only i686/x86_64-unknown-haiku), so this is glue rather than a build bug. rust-libc `main` `src/unix/haiku/mod.rs:1979-1983` has a `// TODO mod aarch64;` stub, so offer it with the target.
- **gcc_syslibs patchsets:** HaikuPorts' gcc_bootstrap patchset, ported to 16.2.
- **Buildtools:**
  - 4883922086 and 662fd8ac0b: GCC 15/16 port glue.
  - fc2ad25b8b (`--hash-style=both`) and 1cad3a62fa (DT_RELR on arm64): enhancements.
  - gfortran's harmless `-Wno-multichar` warning: cosmetic.
- **libdrm fork** (62107104, a3ac76e6, bd858a24): libdrm has no Haiku support. bd858a24 handles Haiku's negative errno values.
- **libglvnd fork:**
  - 9bbfec4 (ES contexts), 83d9cc2 (core profile), 7cc03c3 (async draw) and the overlay part of be20124: features tied to our app_server and Mesa.
  - 536f5c1 (`SetBitmap` sends `B_INVALIDATE` with an infinite timeout under the lock): a plausible exit deadlock from code reading, but its A/B (2/24 vs 1/24) is inconclusive and the hangs were explained elsewhere, so it is not reported.
- **Photocraft crate patches** (arboard, calloop, cap-primitives, craft-update, fontdb, rfd, rustix, wayland-backend, wayland-client, wgpu, wgpu-core, wgpu-core-deps, wgpu-hal, winit): Haiku backends and cfg additions for crates without Haiku support.
- **tools/recipes** (cmake 4.4.5 = HaikuPorts' patchset on a newer version; pkgconf bump; new recipes for sse2neon, c_blosc 1.21, imath, openvdb, usd, oidn, openimageio 2.4, raspberrypi_userland, blender 3.6): bumps and new ports. Exception: Blender's rdef flag is reported as HAIKUPORTS-05.

## How to submit (checklist for the owner)

Read 2026-11-20. Some trackers blocked automated reading (Haiku's Trac and Mesa's GitLab sit behind a bot
filter; winehq.org was unreachable from this host), so the field lists marked *unverified* come from secondary
sources: check them on the form itself. **Several projects restrict AI-generated contributions** (noted per
project below). These drafts were compiled with an AI agent; before sending, rewrite each report and commit message
in your own words where the project asks for that, review every line, and disclose as the project requires.

General, for every project:

- [ ] Re-check the upstream status on the day you send: pull the project's current main and look at the code named
  in "Root cause"; search the tracker for duplicates.
- [ ] Reproduce on the newest upstream build you can run (Haiku nightly, Mesa main, Wine's latest development
  release); say what you tested on. Where an entry argues "also affects x86_64/Linux" from the code only, say so
  in the report or test it first.
- [ ] One bug per report; one logical change per patch.
- [ ] Strip anything local: host names, IP addresses of the lab network, user names, paths.

### Haiku (Trac + Gerrit)

Guides: [Reporting bugs](https://www.haiku-os.org/docs/welcome/en/bugreports.html),
[Gerrit / submitting patches](https://www.haiku-os.org/community/getting-involved/developing/),
[coding guidelines](https://www.haiku-os.org/development/coding-guidelines/).

- [ ] Trac account at <https://dev.haiku-os.org> with a verified e-mail address.
- [ ] Ticket fields: Summary, Description, Component, Version, Platform, Keywords (field list *unverified*; the
  component in each entry is our best guess — pick the closest one the form offers). Give the hrev and the build
  type (arm64; x86_64 where tested), test environment (real hardware: Raspberry Pi 4), steps, expected vs actual.
- [ ] Attach logs as plain text: `/boot/system/var/log/syslog` (review it for personal data), KDL `bt` output for
  panics, a Debugger report for crashes. Do not zip the syslog.
- [ ] Build problems (the GCC 16 entry) go to the development mailing list, not Trac.
- [ ] Patches go to Gerrit, not as Trac attachments and not as GitHub pull requests: GitHub login, ed25519 SSH key,
  the `commit-msg` hook (Change-Id), `git push origin HEAD:refs/for/master -o topic=…`. Rebase each of our commits
  onto current `master` first: several touch files that also carry other fork changes ("Patch: with notes").
- [ ] Commit subject `component: summary` (< 64 chars), then a body; refer to the ticket as `#NNNNN` and to commits
  by hrev. Run `haiku-format` / `checkstyle.py`. Don't mix style fixes into a fix.
- [ ] RenkuOS-derived fixes: point upstream at the RenkuOS change and its author; don't submit them as ours.
- [ ] Security-relevant entries (HK-01, HK-02, HK-05, HK-50, HK-58): ask the Haiku developers how they want them
  reported before opening public tickets; HK-58 is unconfirmed and must be confirmed on a test VM first.
- [ ] AI policy: none found on the pages read.

### Mesa (GitLab)

Guides: [bugs.html](https://docs.mesa3d.org/bugs.html), [submittingpatches.html](https://docs.mesa3d.org/submittingpatches.html),
the issue template `.gitlab/issue_templates/Bug Report.md`.

- [ ] Issue at <https://gitlab.freedesktop.org/mesa/mesa/-/issues/new> with the template headings: System
  information (OS, GPU, kernel, Mesa version), Describe the issue, Regression, Log files as attachment. Title:
  short description + driver (`v3d`/`v3dv`) + application.
- [ ] A Linux reproduction (Raspberry Pi OS on a Pi 4/5 with Mesa main) makes a v3d/v3dv report much stronger
  than a Haiku one; try the named piglit/dEQP test there.
- [ ] Fixes as merge requests from a fork; title and commit subject prefixed `v3d:`/`v3dv:`/`broadcom/compiler:`,
  ≤ 75 chars; `Closes: <issue URL>`, `Fixes: <sha> ("subject")` where a commit introduced the bug; `Backport-to:`
  for stable. Allow maintainers to push. Run `meson test`.
- [ ] **AI policy (explicit):** AI must not write code comments, commit messages or GitLab comments; no autonomous
  tools may interact with issues or MRs; disclose with `Assisted-by: LLM` (no model name, no `Co-authored-by` for
  tools). Write the issue and commit text yourself.
- [ ] Our Mesa commits end with a `Co-Authored-By:` trailer for the AI tool: replace it with `Assisted-by: LLM`
  and rewrite the commit messages before opening any merge request.

### Wine (Bugzilla + GitLab)

Guides (*unverified from this host*): <https://wiki.winehq.org/Bugs>, <https://wiki.winehq.org/Submitting_Patches>.

- [ ] Bugzilla at <https://bugs.winehq.org>: Product Wine, the component named in the entry, version, hardware,
  OS, one problem per bug; attach full terminal output and `WINEDEBUG` logs as text attachments.
- [ ] Upstream Wine has no Haiku port, so reproduce on Linux where the entry says it is possible (aarch64 Linux
  for the memory-ordering entries; any Linux for the server and ddraw ones), and report that environment.
- [ ] Bugzilla was not searched for any entry (unreachable from our network): search it first; bug 59273 may
  already cover WINE-04.
- [ ] Patches as merge requests on <https://gitlab.winehq.org> (needs the user-verification issue first).
- [ ] AI policy: a claim that Wine refuses LLM-generated code could not be checked against Wine's own pages; check
  "Submitting Patches" and the Clean Room Guidelines before sending code.

### FFmpeg

Guides: [bugreports.html](https://ffmpeg.org/bugreports.html), [developer.html § Submitting patches](https://ffmpeg.org/developer.html).

- [ ] Run every FFmpeg command first with an unpatched mmaldec and keep the full `-v 9 -loglevel 99` output:
  none was captured for these drafts.
- [ ] Bugs go to the Forgejo tracker <https://code.ffmpeg.org/FFmpeg/FFmpeg/issues> (no longer trac): exact command
  line and the full uncut output of `ffmpeg -v 9 -loglevel 99 …`, reproduced on current git master.
- [ ] Patches as Forgejo pull requests or `git format-patch`/`git send-email` to ffmpeg-devel, one patch per mail,
  `area: short description`, `Signed-off-by`; run `patcheck` and `make fate`.
- [ ] AI policy: none found.

### Firefox (Bugzilla + Phabricator)

Guides: [bug-writing guidelines](https://bugzilla.mozilla.org/page.cgi?id=bug-writing.html),
[contributing code](https://firefox-source-docs.mozilla.org/setup/contributing_code.html),
[AI coding policy](https://firefox-source-docs.mozilla.org/contributing/ai-coding.html).

- [ ] Summary (< 60 chars, the problem not the fix), Product/Component, Version, OS, Steps to reproduce, Actual
  results, Expected results; Build ID from about:support.
- [ ] Patches via `moz-phab` on Phabricator after a try run.
- [ ] AI policy: allowed, but you must understand and be able to explain every change.

### Blender (projects.blender.org)

Guides: [bug reports](https://developer.blender.org/docs/handbook/bug_reports/),
[contributing](https://developer.blender.org/docs/handbook/contributing/),
[AI contributions policy](https://developer.blender.org/docs/handbook/contributing/ai_contributions/).

- [ ] Issue template fields: System Information, Blender Version (Broken: … / Worked: …), Description of the Issue,
  Steps to Reproduce the Issue (from the default startup file or a small .blend). Reports reproducible only through
  third-party software are declined: reproduce on a Linux official build where the entry allows it.
- [ ] Pull request on projects.blender.org after accepting the contributor agreement; commit subject `Fix #NNNNN: …`.
- [ ] **AI policy:** write descriptions and comments yourself; only humans may be authors or `Co-authored-by`;
  mark verbatim tool output.

### OpenUSD, OpenImageIO, OpenImageDenoise (GitHub)

- [ ] OpenUSD: issue template sections Description of Issue / Steps to Reproduce / System Information / Package
  Versions / Build Flags; PRs against `dev` need a signed Pixar CLA; disclose AI use in the PR description
  ([contributing](https://openusd.org/release/contributing_to_usd.html)).
- [ ] OpenImageIO: bug template (`oiiotool --buildinfo`), PRs need the ASWF CLA and an `Assisted-by:` line; no
  autonomous submissions ([AI policy](https://github.com/AcademySoftwareFoundation/OpenImageIO/blob/main/docs/dev/AI_Policy.md)).
- [ ] OpenImageDenoise: plain GitHub issue/PR (no template or policy published).

### Box64 and FEX (GitHub)

- [ ] Box64: no issue template; PRs must pass `ctest`. **AI policy (explicit):** no fully or predominantly
  AI-generated pull requests; disclose assistance. Describe the bug in an issue and let the maintainers or a
  human-written patch fix it.
- [ ] FEX: issue template "Potential Game Bug" (system information, `FEXGetConfig --version`). **AI policy
  (explicit): "No AI/ML/LLM/etc code contributions."** Report the bug; do not send our patch.

### SDL (GitHub)

- [ ] Issue with OS, SDL version and a minimal reproducer. **AI policy (explicit, absolute):** generative AI "should
  not be used in any way when contributing to SDL", including bug reports. Only a report you write yourself, from
  your own reproduction, is acceptable; do not send these drafts or our patches as they are.

### HaikuPorts (GitHub)

- [ ] Issues or PRs on <https://github.com/haikuports/haikuports>; PR checklist: recipe builds on your Haiku
  machine, licence correct, recipe follows the haikuporter templates and field order, "You are not a robot".

### wayland_server, libglvnd, CMake, ioquake3, vkQuake

- [ ] Their reporting guidelines were not read for these drafts. wayland_server (X547) and vkQuake take GitHub
  issues; libglvnd is on freedesktop GitLab; check each project's README/CONTRIBUTING before sending.

### U-Boot (mailing list)

Guide: [sending patches](https://docs.u-boot.org/en/latest/develop/sending_patches.html).

- [ ] Bug reports and patches go to the U-Boot mailing list (the guide names u-boot@lists.u-boot-project.org);
  Patchwork tracks them. Plain-text mail via `b4` / `patman` / `git send-email`; `Signed-off-by` (DCO); Cc the
  custodians from `scripts/get_maintainer.pl`; base fixes on `main`; run `scripts/checkpatch.pl`.

### raspberrypi/userland

- [ ] The repository is **archived and deprecated** ("Consider this repo closed"): no bugs or patches are taken.
  Our entries are kept for the record and for downstream packagers (HaikuPorts recipe); nothing to submit.

### GCC / buildtools

- [ ] GCC bugs: <https://gcc.gnu.org/bugzilla/> with `gcc -v`, the full command line and the preprocessed source.
  Haiku's buildtools changes go through Haiku's Gerrit (`buildtools` repository).
