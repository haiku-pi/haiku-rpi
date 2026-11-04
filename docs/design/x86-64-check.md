# x86-64 still builds and works (H22)

Phase 1 of H22 (PLAN.md row 6c, owner 2026-11-04): analysis and plan only. Written 2026-11-04 from the
sources, without builds, VMs or Pi time. Phases 2 (builds), 3 (KVM tests) and 4 (fixes, report) follow
this document; §7 is the checklist for them.

The owner's words: "analysis and test if our Haiku source tree builds and still works correctly on x86-64 …
some of our changes touch common code of Haiku. We don't want to break x86-64 version and if possible, we want
at least some of our improvements to be passed along towards general use-cases … test it under virtualization
(this is an AMD host). Start this from analysis and planning, then builds and finally testing and fixes."

Trees (all local, nothing fetched for this note):

| what | ref | date |
|---|---|---|
| our tree | haiku `rpi4` **a779571e90** | 2026-11-04 |
| baseline | haiku **hrev60314** = `c9859af553` = `git merge-base rpi4 upstream/master` | 2026-10-22 (commit), merged 10-31 |
| upstream toolchain | buildtools `upstream/master` **33d46bf5c3** (GCC 13.3.0, binutils 2.46.1) | 2026-10-11 |
| our toolchain | buildtools `master` **c2213226f9** (GCC 16.2.0, binutils 2.46.1, our 4 commits) | 2026-11-01 |
| our 13.3 toolchain | buildtools tag `gcc13-baseline` = fc2ad25b8b (13.3.0 + our 4 commits) | 2026-10-28 |

## 1. Inventory: our commits against x86-64

`git log --no-merges hrev60314..rpi4` lists **268 commits** (HAIKU-RPI4-CHANGES.md "Scope"). Four GCC 16 build
fixes appear twice (`3c641a2b01`/`775c2e8a5e`, `2d0aac976e`/`b0ac75ce1f`, `f21e11d138`/`271cec9635`,
`29a820de6e`/`5c7f4579c5`: the `gcc16` branch was merged and the same fixes were rebased onto `rpi4`), so 264
distinct changes. No commit touches x86 architecture code: nothing under `*/arch/x86*`,
`boot/platform/bios_ia32`, `boot/platform/efi/arch/x86_64` or `headers/*/arch/x86*`.

Classes:

- **(a)** arch-neutral code that an x86-64 build compiles and that can behave differently there.
- **(b)** x86-relevant architecture code. Generic arch headers (`arch/generic/debug_uart.h`, `user_memory.h`)
  are counted in (a) or (c) by what their change does on x86.
- **(c)** no effect on an x86-64 build: files only compiled for arm/arm64/riscv (arm64 arch code, the FDT bus,
  the Pi drivers), code behind `#ifdef __aarch64__`, jam/package entries gated `@arm64` or
  `$(TARGET_ARCH) = arm64`, and the arm64 package list `build/jam/repositories/HaikuPorts/arm64`.
- **(d)** build system, jam rules and image definitions that change what the x86-64 build compiles, links or
  puts into the image.

| class | commits | of which |
|---|---:|---|
| (a) | **122** | 2 duplicates; 5 not in an x86-64 image (remote_disk ×4, a test program) |
| (b) | **0** | |
| (c) | **132** | 64 touch only arm64/Pi paths; 36 only the arm64 package list; 32 touch common files with arm64-only effect |
| (d) | **14** | 2 duplicates; 4 expected to leave the x86-64 image unchanged (to be confirmed in the build log) |

The x86-64 package list (`build/jam/repositories/HaikuPorts/x86_64`) is unchanged
(`git diff hrev60314 rpi4 -- build/jam/repositories/HaikuPorts/x86_64` is empty). `RepositoryRules` takes a per-arch
repository-info template only where `src/data/repository_infos/haikuports_<arch>` exists, which is arm64 only
(`b258d90d71`), so the x86-64 image's repository config is upstream's.

### 1.1 Test IDs used in the risk notes

| ID | what (details in §4) |
|---|---|
| BOOT | boot to the desktop, UEFI and BIOS, AHCI / NVMe / virtio-scsi / IDE, SMP 4; serial log clean; screendump |
| USB | boot from `usb-storage` on `qemu-xhci`; a data disk on `usb-ehci`; 1 GB copy + MD5; keyboard and tablet |
| SD | `sdhci-pci` + `sd-card` data disk: mount, 200 MB copy + MD5 |
| NET | virtio-net and e1000: DHCP, ping, DNS, HTTPS fetch, `pkgman refresh`, net_server restart, resolver without DNS |
| THR | threadstress, threadbench, forkbench, killrace, exitthread, rw_lock_interrupt_test, spread |
| TLS | tlsstatic (incl. the alignment check), tlsreload, tlsunload, tlsbench |
| LIBC | strtold (x87 table), strtest, polltest, usercopy, relrtest, membarrier, castest |
| VM | tools/kernel-tests: mmap-shared-mprotect, fault-signal-blocked, mprotect-unprotect-retry |
| FS | bfsmeta, fragwrite, bfsbits; power cut (QMP `quit` mid-write) then `checkfs`; package read timing |
| APP | launchtime (Terminal, StyledEdit, ShowImage, DeskCalc, Devices, WebPositive, MediaPlayer); pmexit loop; bitmapcheck, drawbench |
| DBG | Debugger CLI on dbgtarget (break/step/next/finish/bt), DWARF 4 and 5 targets; `profile -a`, `profile` of a team |
| PWR | `shutdown` (ACPI power-off: QEMU exits), `shutdown -r`, registrar shutdown (shutdown-test.sh) |
| RNG | /dev/urandom: 100 MB rate and sanity, getentropy |
| MEDIA | intel-hda: media_server up, a sound played, tswatch |
| PERF | the A/B timing set of §4.6 |

### 1.2 (a) — arch-neutral code x86-64 compiles and runs

Risk: **H** = a fault would hit every x86-64 boot or every user, or data; **M** = a common subsystem or a
behaviour change users can see; **L** = narrow, additive, or a plain bug fix. "★n" = row n of HAIKU-RPI4-CHANGES
"Start here" (a defect upstream also has); "gen" = also an improvement for x86-64 without a ★ row.

**Kernel: VM, threads, signals, scheduler, SMP, I/O**

| commit | change | risk | what could break on x86-64 / how a test shows it | gen |
|---|---|---|---|---|
| `ecab951764` | reuse the user stack areas of exited threads (4 per team, ≤ 2 MiB) | **H** | every thread creation; a new thread gets a stack with old contents (programs reading uninitialised stack). On arm64 it exposed two latent bugs (★42, ★43). THR, APP, PERF (threadbench) | gen |
| `e09cfa1d9e` | keep an exited thread's stack while its team goes down | M | memory held until the team is gone; killrace (upstream expected to fail), THR | ★43 |
| `dbae37b2cb` | caller-provided stack not placed a guard size too high | L | pthread_attr_setstack users; THR | gen |
| `a000d5d6cc` | clear all TLS slots of a new thread | L | THR, TLS | gen |
| `f0a1d5f5cf` | setrlimit() accepts the current value of a fixed limit | L | LIBC (a 3-line check in the test set) | ★40 |
| `894c4abe7f` | MAP_SHARED file mappings stay shared across mprotect() | **H** | changes `vm_set_area_protection()` and `_user_set_memory_protection()` for every area; a mistake there breaks copy-on-write after fork(). VM (mmap-shared-mprotect), THR (forkbench), BOOT | ★21 |
| `6e517bb52c` | a page fault whose SIGSEGV is blocked or ignored ends the team | M | programs that ignore SIGSEGV on purpose now die (Linux does the same); VM (fault-signal-blocked, mprotect-unprotect-retry) | ★22 |
| `6f810ed2d7` | lock_memory_etc(): unwire what was wired when a page fails | L | usercopy (read() into a range ending in PROT_NONE) | ★20 |
| `797972f727` | map a clone of a B_CONTIGUOUS area in full | L | drivers that clone contiguous areas; BOOT, MEDIA | gen |
| `67b8a53cbe` | prefetch at most 1 MB of a mapped file (was 10 MB) | M | app start times change either way; PERF (launchtime, boot time) | gen |
| `1539d29eee` | page writer writes what there is after its 3 s wait | M | more frequent small writes; FS (bfsmeta timing, data on disk 5 s after a write, power cut) | ★18 |
| `90fa3bc401` | IORequest iterates in a loop, not by recursion | **H** | the I/O path of every block device (AHCI, NVMe, virtio, usb_disk): a hang or a lost completion shows as a stuck copy or bad MD5. FS (fragwrite), USB, BOOT | ★19 |
| `8edea64c6b` | DMA bounce buffers up to 128 kB (were 16 kB) | M | each DMAResource allocates bigger contiguous bounce buffers (IDE/AHCI/usb_disk); low-memory boots (`-m 512M` run), BOOT, USB | gen |
| `c82925eeb9` | device_manager keeps driver modules loaded while reprobing at boot | L | boot time, memory at boot; BOOT, PERF | gen |
| `cafef4f9bb` | PCI: an I/O-port BAR's host address is the port itself | M | unconditional; on x86 `pci_ram_address()` of an I/O BAR was already the port, so nothing should change, but every x86 driver with I/O BARs (legacy virtio, e1000, IDE, AC97) goes through it. BOOT (`-machine pc` IDE), NET (e1000, rtl8139), one boot with `virtio-scsi-pci,disable-modern=on` (legacy virtio, I/O BAR) | ★24 |
| `81deb24f8c` | get_next_child_node() returned only the first child | L | callers that iterate children (ACPI/PCI drivers); BOOT | ★7 |
| `bce76d6e73` | wait up to 10 s for a boot device that is published late; strict match first | M | a boot whose boot device only matches non-strictly (BIOS disk identification by checksum, CD boot) now waits 10 s before the fallback. BOOT: serial must not show `get_boot_partitions(): waiting for the boot device`; boot time vs upstream | gen |
| `8f0df61a1c` | boot method kept as a boot item (`main.cpp`); remote_disk only on network boots | L | every boot parses the boot volume message once more; BOOT | ★28 |
| `a46a16641e` | spinlock / ICI deadlock detection by time (5 s, 100 s, ICI 10 s) | M | a new panic if a synchronous ICI is not processed in 10 s: under KVM a long-descheduled vCPU could trip it (the timer restarts after a 1 s gap). THR, SMP soak with the host loaded | ★6 |
| `0db3ca639d` | test-and-test-and-set in `try_acquire_spinlock()`; WFE wait arm64-only | L | contention behaviour on x86 (reads before the exchange: usually faster); THR, PERF | ★1 (arm64) |
| `1582c223b0` | new syscall `_kern_team_memory_barrier`; two full barriers per context switch | M | the syscall table gains an entry at the end (existing numbers unchanged); two `mfence` per `switch_thread()` cost context-switch time on x86. LIBC (membarrier), PERF (threadbench, a ping-pong) | gen |
| `2486477fab` | scheduler: a core's own load uncapped when rebalancing | M | thread placement on every SMP machine; with SMT (2 CPUs per core) the uncapped load is divided by the CPU count. THR (spread with `-smp 4` and `-smp 4,cores=2,threads=2`) | gen |
| `5180e96119` | profiling timer not left behind on a CPU | L | DBG (`profile` of a team, and of one that loses its debugger) | ★23 |
| `40adafebe9` | breakpoints flag updated when continuing installs a hardware breakpoint | L | DBG (break + continue on x86) | ★35 |
| `09b7e81388` | sync the icache after the debugger writes team memory | L | no-op on x86 (`arch_cpu_sync_icache`); DBG | gen |
| `f6c52282df` | image notifications: 256-byte buffer (pointer did not fit on 64-bit) | L | DBG (`profile -a` resolves programs started after it) | ★44 |
| `127fb34239` | poll() leaves the caller's `events` alone | L | LIBC (polltest; upstream expected to fail) | gen |
| `55348c5c46` | NULL check in `dec_vnode_ref_count()` (sdhci include) | L | BOOT | (★2 arm) |
| `8eca4824c9`, `aa1366f629` | serial-console emergency keys (Ctrl-] ×3 + key) | L | off by default outside arm/riscv (`debug.cpp:100-102`); nothing runs on x86 unless `serial_emergency_keys` is set. BOOT | gen |
| `5ec650bbb0`, `7a2282df3c` | `DebugUART` gains default no-op virtuals | L | included by the x86-64 EFI loader's `serial.cpp`; BOOT (UEFI) | — |
| `cea07d5468`, `f316d4920e` | network boot: wait for the link, keep network modules, a gateway route | L | only on a network boot (x86-64 can EFI-net-boot in principle; not tested here) | ★14 |
| `d8dfb51d8d` | EFI `ip=` load option parsing (looped forever with another key) | L | x86-64 EFI loader compiles `efi/network.cpp`; BOOT (UEFI), plus one run with `-append`-style load options if practical | ★12 |
| `e1fe4f62bd` | boot loader remote disk: 8 requests in flight | L | loader net boot only | gen |
| `850a1d7e52` | `TRACE_PARTITIONS` off in the loader | L | less loader output on the serial line; BOOT | — |
| `b23e7264c0` | loader skips subdirectories of `boot/` and loads `boot/network` on network boots | L | the loader opens and stats every boot module once more (BIOS and EFI); BOOT, boot time. The arm64-only parts are gated | — |
| `daaaf7a848` | loader/packagefs: cache the last 8 decompressed heap chunks (512 KiB) | M | `PackageFileHeapReader` runs in the BIOS and EFI loaders and in the package kit; the 512 KiB buffer is a large allocation from the loader's heap regions (falls back to no cache when it fails). BOOT (BIOS and UEFI), `-m 512M` | gen |

**File systems and storage**

| commit | change | risk | what could break / test | gen |
|---|---|---|---|---|
| `a9db442988` | block cache: a sub-transaction start visits only the changed blocks | **H** | BFS journal on every volume: a missed block = a corrupted journal after a crash. FS (bfsmeta, power cut + checkfs, 3×), BOOT | ★45 |
| `9799738757` | BFS: delete the journal before failing a mount | L | already tested on the host with `bfs_shell`; FS | ★50 |
| `6f53989b14` | packagefs reads ahead when a heap is read in order | M | all package reads (every program start); FS (package read timing), PERF, BOOT | gen |
| `e1d69f100f` | xHCI: a physical transfer's TDs from the current fragment only | M | usb_disk on every xHCI controller (x86's normal USB 3 path): wrong TRBs = data corruption. USB (1 GB copy + MD5 both ways) | gen |
| `c65ac5a2e6` | xHCI: clear completed TDs' ring entries; 4 TRBs of padding | M | every xHCI endpoint ring (keyboard, mouse, disks); USB, BOOT (usb-kbd, usb-tablet) | ★31 |
| `1d44b00380` | xHCI: dump the ring on a TRB error | L | diagnostics only | — |
| `afb2823bb5` | USB: a new bus is explored in the explore thread, not in `Start()` | M | USB devices appear later in the boot on every x86 machine; a USB boot disk relies on `bce76d6e73`'s wait. USB (boot from `usb-storage`), BOOT (keyboard works at the boot menu and on the desktop), boot time | gen |
| `289d8095c0` | usb_disk: 256 DMA segments per transfer | M | larger scatter lists to EHCI/UHCI/OHCI too; USB (data disk on `usb-ehci`) | gen |
| `61fe84cd93` | usb_disk honours `B_DMA_HIGH_ADDRESS` | L | no x86 bus publishes it lower than 4 GiB; USB | ★51 |
| `23f6235b0d`, `af82a8ca4d`, `890f468bf4`, `1cccf09635`, `c283f50c5b`, `f0578116b8`, `6018671453` | sdhci: W1C interrupt acknowledge, 32-bit register access, ADMA2 + PIO, one command per ADMA2 transfer, brief busy-wait, interrupt-storm guard, SDIO data in the interrupt handler; `sdhci_fdt.cpp` now compiled on every arch | M | x86 laptops' SD readers use `sdhci_pci`/`sdhci_acpi`; never run on x86 since. `sdhci_fdt.cpp` is new to the x86 build (its Pi parts are `#ifdef __aarch64__`): a compile risk. SD | ★8 |
| `68293c40a1`, `bf3a1d0bdb`, `ec55b68bfe`, `c5f52af56b`, `1be86daecf`, `4d12fd3908`, `d018d9dfe1`, `e29c5b7c65` | MMC bus: tracing off, 50 MHz high speed, SDIO enumeration and transfers, card interrupt, UHS-I (1.8 V, DDR50/SDR50); `sdhci_pci`/`sdhci_acpi` hooks | M | the 1.8 V switch and higher clocks on real x86 readers are untested anywhere but the Pi; QEMU's sdhci exercises enumeration and data but not signalling. SD | gen |
| `e26850ef57` | freebsd_network: an `sdio` root bus (`driver.c`, `device.h`) | L | additive; every FreeBSD-compat NIC/WLAN driver links `driver.c`. NET (e1000 is native; also boot with `-nic user,model=rtl8139`, a compat driver) | — |

**Runtime loader, libroot, headers**

| commit | change | risk | what could break / test | gen |
|---|---|---|---|---|
| `5db923abc6` | a new thread's TLS vector starts at the current generation | L | TLS (tlsunload; upstream expected to fail) | ★33 |
| `c6cab6cc9e` | static TLS block (arm64 only, `TLS_STATIC_BLOCK`) | M | on x86: `TLS_STATIC_TLS_SLOT` shifts `TLS_FIRST_FREE_SLOT` by one (`tls.h:26`), one fewer `tls_allocate()` slot; TLS templates unregistered on load-failure paths. TLS, APP | — |
| `4d433669a8` | TLS blocks aligned to the segment's alignment | M | every dynamic TLS block is allocated with a header word now; TLS (tlsstatic alignment check; upstream expected to fail), APP | ★52 |
| `076da9813a` | `rld_export` gains `tls_generation` | L | runtime_loader ↔ libroot struct, built together; TLS | — |
| `634dd24886` | runtime loader heap locked across fork() | L | fork() from a multithreaded program; THR (forkbench), APP | gen |
| `4539cd2f00`, `e30b8928d6` | DT_RELR support; `elf.h` defines | L | only images with DT_RELR; x86-64 binutils can emit it: LIBC (relrtest; upstream expected to fail) | gen |
| `2bf2f773ba` | rw_lock waits again after an interrupted block (+ `rw_lock_interrupt_test`) | M | every BLooperList/BRoster user; THR (rw_lock_interrupt_test; upstream expected to fail), APP | ★41 |
| `12eb998a63` | strtold()/wcstold() for long double (x87 80-bit on x86) | M | x87 path never compiled or run here (W45 11-02: "x86_64 not built here"); scanf("%Lf"). LIBC (strtold with an x87 table) | ★38 |
| `73ba44df00`, `69c0374b42` | strtod edge cases, ERANGE on underflow | L | LIBC (strtold's double part) | ★39 |
| `46a18aecb4` | `strtod_l()`, `strtof_l()`, `strtold_l()` in `<stdlib.h>` | L | new public declarations; configure scripts of ports may now find them. LIBC | gen |
| `88be53559b` | `atomic_test_and_set()` strong CAS (`SupportDefs.h`) | L | x86 `cmpxchg` is always strong: same code. LIBC (castest) | ★47 |
| `2d0aac976e` (+dup `b0ac75ce1f`) | struct tags in `elf.h`, `USB_video.h`, `mmc_disk.h` | L | same linkage names; build only | — |
| `a779571e90` | libbe keeps BMessage's cache at exit | L | APP (pmexit loop; upstream expected to fail at some rate) | ★53 |

**Servers, kits, apps**

| commit | change | risk | what could break / test | gen |
|---|---|---|---|---|
| `e246cf4b9d` | app_server copies a plain bitmap to back and front buffer in one pass | M | double-buffered drawing on VESA/framebuffer/virtio_gpu; APP (bitmapcheck, drawbench), screendumps | gen |
| `42d6d09b3a`, `4279c0fda2`, `bf0e7f37e6`, `fe0a165e1c` | overlay keying by alpha; overlay channel release | L–M | only with `B_OVERLAY_KEYING_USES_ALPHA` (no x86 accelerant sets it), but every front-buffer row now goes through `_WriteFrontRow()`; overlay channel logic affects real Intel/Radeon overlays (MediaPlayer). APP (MediaPlayer on VESA: no overlay), drawbench | — |
| `13a39894c2` | app_server precaches fonts in a low-priority thread | M | text drawn before the cache is warm reads font files at once (slower, not wrong); BOOT, APP | gen |
| `be81b338fa` | frame buffer console palette opaque in 32 bits | L | KDL on the EFI/VESA frame buffer (one forced KDL entry in BOOT) | — |
| `c41702df18` | BTimeSource conversions in double | L | MEDIA (tswatch, playback) | ★15 |
| (SavedClock) | the launch job and script | M | counted and described under (d) | — |
| `fb4e339ce8` | launch_daemon environment pipe close-on-exec | L | BOOT (launch-pipes.sh) | ★48 |
| `584742feec`, `00004aa2ff`, `a6ca113d55`, `bf33dc5c29`, `f43d42c93b` | WPA-personal joins without wpa_supplicant (openbsd_wlan, net_server); join with one interface restart | M | x86 WiFi drivers on openbsd_wlan (`idualwifi7260`, `iaxwifi200`) share the changed join code; the no-supplicant path only runs when the supplicant cannot be launched. Not testable in QEMU (no WiFi); review only, plus a real-hardware check later | gen |
| `cb0f2f9884` | net_server leaves an interface alone if it has an IPv4 address when net_server configures it | **M** | meant for network boots, but it runs on every boot: if net_server is restarted while DHCP has configured an interface, that interface is skipped and no DHCP client watches it any more (lease never renewed). NET (restart net_server with `launch_roster restart`, then check the DHCP client still runs) | — |
| `25c9881600`, `58022c954a` | ICMPv6 errors sent and delivered; own host name from the hosts file | M | IPv6 stack behaviour; name resolution order. NET (resolvetime without DNS: expect ≪ 14 s; upstream expected slow) | ★32 |
| `67b972b5e1` | random: ChaCha20 output keyed from the yarrow pool | **H** (security) | /dev/random, /dev/urandom, getentropy on every x86 machine. RNG (rate, no repeated 16-byte window in 100 MB, compressibility, chi-square against the host's /dev/urandom) | gen |
| `02e02d4ba3`, `0c12640aa2`, `d226612219`, `b0ea06deaf`, `3cad4e2996` | Bluetooth tools build and work; kit tracing; L2CAP NULL; bluetooth_server PIN window | L | no Bluetooth controller in QEMU: build + `bt_dev_info` prints "no device" | ★29, ★30 |
| `ad9b5551c8`, `721732e47f` | Debugger: arm64 back end and disassembler, compiled into the Debugger kit on every arch (as the x86 back ends already are) | L | new code in the x86-64 build (compile risk); core files of arm64 programs become readable on x86-64. DBG | gen |
| `88b487e15b` | Debugger "step out" compares frame addresses | M | changes stepping on x86 too (CFA vs frame pointer). DBG (finish/step out on x86-64) | ★36 |
| `3c4a73f4dd`, `8a65ea1c6d` | Debugger CLI: break, step, next, finish; stop/bt waits | L | additive; DBG | gen |
| `b67b55acf7`, `6c71603f62`, `d2d2349f2c`, `65cae45a13`, `4588cddb87`, `a36ea1ed3b`, `1b4e49fd6c` | Debugger reads DWARF 5 (and a DWARF 4 line-table fix) | M | GCC 13 emits DWARF 5 by default, so this matters on x86-64 too; DBG (dbgtarget-cxx built with -gdwarf-4 and -gdwarf-5) | gen |
| `29a820de6e` (+dup `5c7f4579c5`) | FileTypes `_Frame()` static | L | APP (FileTypes opens) | — |

**Not in an x86-64 image** (remote_disk is packaged `@arm64` only, `packages/Haiku`; the x86 PXE loader is 32-bit):
`a082ab4d4e` ★13, `b1ddc00b1f`, `84fd3835a4`, `13f5af2f89` (remote_disk), `8a10e472dc` (tcp_throughput test
program). Build only.

### 1.3 (d) — build changes that reach the x86-64 build or image

| commit | change | risk | what could break on x86-64 / how to see it |
|---|---|---|---|
| `18e0d2a9db` | `KDEBUG_LEVEL` 2 → 1 (`build/config_headers/kernel_debug_config.h:8`) | **H** | every kernel object: ASSERT()s off, paranoid malloc off, debug mutexes off. Upstream's release branches build x86-64 this way (r1beta5 and r1beta6 have `KDEBUG_LEVEL 1`, upstream `103df455af` "per the ReleaseCookbook", `3aa6bdccbd`), but master's x86 code at level 1 is not built anywhere: unused-variable `-Werror` failures or ASSERT() side effects (as `55348c5c46` found on arm). Build log; BOOT. It also makes a timing A/B against upstream master (level 2) unfair: see §4.6 |
| `3e8577af06` | `-Bsymbolic-functions` for every jam shared library except libroot (`MainBuildRules:443`) | **H** | calls inside libbe, libtracker, libnetwork, libmedia, translators' libs … bind locally: a program or add-on that replaces such a function (interposition) is no longer called from inside the library. Data and libroot stay interposable. APP (desktop, Tracker add-ons, translators, WebPositive), PERF (launchtime, dlopentime) |
| `91012322ef` | `--hash-style=both` for every link (`ArchitectureRules:165`) | M | every x86-64 binary gains DT_GNU_HASH; the runtime loader already reads it upstream (`elf_load_image.cpp` `DT_GNU_HASH`), so lookups switch to the Bloom-filter path on x86-64 too. APP, PERF (dlopentime) |
| `0ce0612c25` | SavedClock: a launch job (`data/launch/system:27`) and `/system/boot/SavedClock` in the haiku package | M | a new `sh` process on every x86 boot that `touch`es `/boot/system/settings/saved_clock` every 5 min (disk writes; never moves the clock back). A clock deliberately set back is moved forward at the next boot. BOOT (process list, date = RTC time), PWR (the job ends cleanly at shutdown) |
| `a7535eab9d` | regular image ships `bt_dev_info`, `bt_discovery` | L | two more binaries in the x86-64 image; build log |
| `59b38453cc` | `libmidi.so@fluidlite` in the regular image | L | x86-64 has fluidlite (`HaikuPorts/x86_64:74`), so libmidi stays; confirm `libmidi.so` in the image |
| `865c648344` | `AddDriversToPackage bluetooth h4 : $(SYSTEM_ADD_ONS_DRIVERS_BT_H4)` | L | empty list on x86-64; check no empty directory is created |
| `3c641a2b01` (+dup `775c2e8a5e`) | `-std=gnu++17` for GCC C++ (`ArchitectureRules:72`) | L | GCC 13's default already; matters for GCC 16 only |
| `f21e11d138` (+dup `271cec9635`) | kernel and loader zlib as `-std=gnu17` | L | build only |
| `2c93aeea48` | runtime_loader's string objects listed through variables (arm64 filters them) | L | same object list on x86-64; a jam mistake fails the runtime_loader link |
| `b258d90d71` | per-arch repository-info template | L | no `haikuports_x86_64`: unchanged |
| `2df3b18b92` | optional `-z pack-relative-relocs` (`HAIKU_PACK_RELATIVE_RELOCS`) | L | off by default |

### 1.4 (c) — no x86-64 effect (132)

- **64 commits touching only arm64/Pi paths**: arm64 kernel and EFI arch code, `kernel/arch/arm` (GIC, PL011), the
  FDT bus manager, bcm2711_display, v3d, genet, brcmstb, bcm2835_cpufreq. Among them ★ fixes that only exist on
  arm64 (★3, ★4, ★5, ★9, ★10, ★11, ★16, ★17, ★25, ★26, ★27, ★34, ★37, ★42, ★49).
- **36 commits changing only `build/jam/repositories/HaikuPorts/arm64`** (`git log --no-merges hrev60314..rpi4 --
  build/jam/repositories/HaikuPorts/arm64`).
- **32 commits touching common files with arm64-only effect**: Jam `SubInclude`s gated by `$(TARGET_ARCH) = arm64` or
  entries `@arm64` (`eafa824d33`, `5cb3a2d215`, `426ee96c2e`, `0ef01f9d31`, `4ff857683f`, `fb1b33e488`,
  `3fcf7b6035`, `cb92912c6b`, `e01ad66e7c`, `c9b4bfe234`, `c536a518b2`, `8f69771aea`, `b294857151`, `e98b67a5bd`,
  `fb4461ed54`, `6965caeb07`, `cdb7601f17`, `9b9b2a3bba`, `d6580d9550`, `a6db106d27`, `0b22f22f5b`, `d6a85764d9`,
  `86122fc522`, `d20bc8fa87`); code behind `#ifdef __aarch64__` (`71bc709601`, `3a0ccc321f`, `eabad7a921`,
  `b90cb3f0d4`); FDT-only (`a6502fab74`, `08e65e6449`, `f2e5b2fab8`); and `aa7da3b827`'s `timer.cpp` diagnostic,
  removed again by `0db3ca639d` (net zero).

Note for upstreaming, not a break: several Pi driver directories are `SubInclude`d unconditionally
(`accelerants/bcm2711_display`, `busses/random/bcm2711_rng200`, `drivers/graphics/{bcm2711_display,v3d}`,
`network/wlan/broadcomfmac`, `drivers/video/rpivid`, `power/cpufreq/bcm2835_cpufreq`, `bin/pmustat`). Their targets
are defined on x86-64 but nothing in an x86-64 image depends on them, so a profile build never compiles them; a
plain `jam` of everything would. Gating them like `genet` and `brcmstb` is a small cleanup (§5).

### 1.5 Top risks

1. **`KDEBUG_LEVEL 1`** (`18e0d2a9db`): the x86 kernel has not been built at level 1 on master; first place a build
   can fail, and it changes behaviour and speed against upstream master.
2. **`-Bsymbolic-functions`** (`3e8577af06`): a silent semantic change in every jam-built shared library.
3. **User stack reuse** (`ecab951764`) and the VM protection change (`894c4abe7f`): every thread, every fork.
4. **Block cache sub-transactions** (`a9db442988`) and **IORequest iteration** (`90fa3bc401`): data integrity on
   every disk.
5. **ChaCha20 RNG** (`67b972b5e1`): security-relevant, all x86 machines.
6. **net_server `_IsBootInterface()`** (`cb0f2f9884`, `NetServer.cpp:425`): applies to every boot, not just network
   boots; a net_server restart would leave DHCP interfaces unmanaged.
7. **xHCI ring and fragment changes** (`c65ac5a2e6`, `e1d69f100f`) and the MMC/SDHCI stack: never run on x86 hardware
   since; QEMU covers xHCI and part of SDHCI.
8. **Boot-device wait** (`bce76d6e73`): a 10 s delay where only the non-strict match finds the boot volume.

A correction found on the way: HAIKU-RPI4-CHANGES row 53 and the W45 11-04 16:10 entry say pmexit was measured
"6/400 → 0/400 on x86-64 QEMU". design/tracker-shutdown-crash.md §"QEMU virt" shows it was QEMU `virt`, i.e.
arm64 (TCG on this x86-64 host), not an x86-64 guest. Phase 3 gives the first real x86-64 number.

## 2. Toolchain

### 2.1 Can our buildtools fork build x86-64 cross tools?

Yes, by its sources: GCC 16.2's `gcc/config.gcc:2078` and `libgcc/config.host:801` keep the `x86_64-*-haiku*`
targets (with `config/i386/haiku64.h`, `t-haiku64`), and binutils' `ld/configure.tgt:954` has `elf_x86_64_haiku`.
Our four buildtools commits: two are arm64-only (`aarch64-haiku.h` hash style `fc2ad25b8b`, `aarch64haiku.sh`
DT_RELR `1cad3a62fa`); two change the common `gcc/config/haiku.h` (`85273c9ba6` libgcc_s as needed,
`393b4ec7a4` `REAL_LIBGCC_SPEC`) and so also the x86-64 driver's default link line. Haiku's jam links with
`-nostdlib` and explicit libraries, so they matter for programs cross-built outside jam (our tests), not for the image.
GCC 16's x86-64 libgcc unwinder has not been built here (arm64 needed `4883922086`; x86 has its own
`md_unwind_def_header`), so a 16.2 x86-64 cross build is likely but unproven.

`configure --build-cross-tools x86_64 --cross-tools-source <buildtools>` is the same path `scripts/bootstrap.sh:50`
uses for arm64; `--cross-tools-prefix` lets a second output directory use the first one's tools (the gcc16.md A/B
did that for arm64).

### 2.2 Decision

**Primary: upstream buildtools `33d46bf5c3` (GCC 13.3.0, binutils 2.46.1) for both x86-64 trees.**

- It is what upstream builds x86-64 nightlies with at hrev60314 (committed 10-11, before the baseline), so a failure
  or a difference between our tree and hrev60314 is our source change, not the compiler.
- The x86-64 HaikuPorts repository ships `gcc_syslibs`/`gcc_syslibs_devel` **13.3.0** (`HaikuPorts/x86_64:88-89`):
  the jam build compiles C++ against that package's libstdc++ headers (`-nostdinc`) and the image runs its
  libstdc++. With 16.2 we would need an x86-64 gcc_syslibs 16.2 (`scripts/build-gcc-syslibs.sh` is arm64-only) or
  the header swap gcc16.md step 1 used, i.e. a hybrid nobody ships.
- A third reference becomes possible: upstream's own `hrev60314` x86-64 nightly anyboot (if still on the nightly
  server) was built with the same toolchain; booting it next to our upstream build checks the build setup itself.
- Our GCC 16 *source* fixes are build-only and already proven on arm64; 13.3 compiles them (gnu++17 is its default).

**Secondary, optional (phase 2b): our buildtools `master` (GCC 16.2) for `rpi4` only, build-only.** Purpose: find
x86-specific GCC 16 errors in code the arm64 build never compiles (x86 arch code, x86-only drivers, the BIOS loader)
before anyone switches x86-64 to 16.2. Target: the image (`@nightly-anyboot`) with the gcc16.md header swap; a boot
is a bonus, not a gate. Only if §3.4's disk budget allows after the primary pair.

Not chosen: our `gcc13-baseline` tools (fc2ad25b8b) — they differ from upstream only in the two `haiku.h` link specs
above, which adds a variable without testing anything of ours that matters.

## 3. Builds (phase 2)

### 3.1 Layout

Worktrees, not the shared checkout: other agents build arm64 in `sources/haiku/generated.arm64` and commit on
`rpi4` meanwhile; `sources/haiku-usbstall` belongs to the USB-stall work and is not touched.

| dir | what |
|---|---|
| `sources/buildtools-x86` | worktree of buildtools at `33d46bf5c3` (detached) |
| `sources/haiku-x86` | worktree of haiku at the `rpi4` SHA of the day (detached; recorded in the report) |
| `sources/haiku-x86-up` | worktree of haiku at `hrev60314` (detached) |
| `…/generated.x86_64` | each haiku worktree's output directory |

### 3.2 Commands

```
git -C sources/buildtools worktree add --detach ../buildtools-x86 33d46bf5c3
git -C sources/haiku worktree add --detach ../haiku-x86 rpi4
git -C sources/haiku worktree add --detach ../haiku-x86-up hrev60314

# rpi4 tree: build the cross tools (binutils + GCC 13.3, ~10-15 min)
mkdir sources/haiku-x86/generated.x86_64 && cd sources/haiku-x86/generated.x86_64
<root>/scripts/heavy-build.sh --mem-per-job 1 -- ../configure \
    --build-cross-tools x86_64 --cross-tools-source ../../buildtools-x86 -j{JOBS}

# upstream tree: the same tools, by prefix
mkdir sources/haiku-x86-up/generated.x86_64 && cd sources/haiku-x86-up/generated.x86_64
../configure --cross-tools-prefix \
    ../../haiku-x86/generated.x86_64/cross-tools-x86_64/bin/x86_64-unknown-haiku-

# each tree (rpi4 first, its download/ then hard-linked into the other: cp -al)
<root>/scripts/heavy-build.sh --mem-per-job 1 -- jam -q -j{JOBS} @nightly-anyboot
```

Wrap this as `scripts/build-x86.sh` (configure once, build one or both trees, log to `artifacts/build/x86-*.log`,
warnings count and jam rc as `scripts/build.sh` prints them) instead of typing it; `scripts/build.sh` stays arm64.
No `-sHAIKU_NO_DOWNLOADS=1` and no `UserBuildConfig` link: the x86-64 build downloads its packages like upstream's,
and the worktrees have no `build/jam/UserBuildConfig` (the main checkout's link to `tools/build/UserBuildConfig` only
defines the `pi-mmc` profile and opt-in variables, so it would be harmless too).

Image: **`@nightly-anyboot`** (`haiku-nightly-anyboot.iso`, `DefaultBuildProfiles:56`). It is the artifact upstream
publishes, it boots from BIOS (MBR / El Torito) and UEFI (its EFI system partition), as a disk or a CD, and the
nightly profile adds what the tests use: WebPositive (x86-64 only), the Development bundle (gcc, binutils: native
compiles in the guest as a fallback), Git, openssh. The default 650 MB BFS is kept on both sides (same as upstream's
artifact); tests and stress writes go to a second disk (§4.2). `@nightly-raw` would also do, but has no CD path.

Confirm in the rpi4 build log: the build ends with jam rc 0, `libmidi.so`, `bt_dev_info`, `bt_discovery`,
`SavedClock` in the image, no `AddHaikuImagePackages: package X not available!`, and the warning count against the
upstream tree's (new `-W` warnings in our files are phase-4 work).

### 3.3 Packages downloaded

Both trees use the unchanged `build/jam/repositories/HaikuPorts/x86_64`, from
`https://eu.hpkg.haiku-os.org/haikuports/master/build-packages`: the build-feature packages (gcc_syslibs_devel,
zlib, zstd, freetype, fontconfig, icu74, libpng16, libjpeg_turbo, libwebp, ffmpeg6, mesa (GL kits), openssl3,
curl, libsolv, haikuwebkit for WebPositive, …), the nightly profile's image packages (mandoc, noto, openssh, pe,
sounds_community_default, vision, wpa_supplicant, nano, p7zip, xz_utils, gcc, binutils, gmp/mpc/mpfr, autotools,
git, …) and their source packages. The exact list is `generated.x86_64/download/` after the first build; record it
in the report. Network access to that server is needed once; the second tree reuses the files (hard links).

### 3.4 Disk and time

Free now: **36 GB** on `/` (df, 2026-11-04 16:43). Estimates (the arm64 tree is 11 GB with its 4.5 GB image;
x86-64 nightly has more packages and a smaller image):

| item | size | time (16 threads, heavy-build) |
|---|---|---|
| buildtools worktree | ~2 GB | — |
| cross tools build (transient build dir) | ~0.4 GB kept, ~4 GB while building | 10–15 min |
| rpi4 tree: sources ~1 GB, objects 4–6 GB, build_packages ~1.5 GB, attributes 1–2.5 GB, download 2–3 GB, image ~1 GB | 10–14 GB | 40–70 min + download |
| upstream tree (download hard-linked) | 8–11 GB | 40–60 min |
| VM disk copies / overlays, scratch disks, logs | 2–4 GB | — |
| **total** | **~22–31 GB** | **~1.5–2.5 h** of build, queued behind other heavy builds |
| optional GCC 16.2 tree (2b) | +9–12 GB | +1 h |

With ≥ 12 GB to stay free, **at least ~10 GB must be freed before phase 2** (≥ 20 GB for 2b). Candidates, all our
own artifacts (check each is not referenced by a running task or a pending release first): `artifacts/qemu/raspi-disk.img`
(4.5 GB), `artifacts/images/h20-ffquit-diag-evt.img` (4.5 GB diag image), `artifacts/wine-11.20` (6.3 GB, superseded
by `wine-11.21` if its packages are published), one of `artifacts/rust` / `artifacts/rust-1.99.1` (7.7 / 7.9 GB),
old raw logs in `artifacts/uart` (12 GB; compress rather than delete). Never: `generated.arm64` (incl.
`cross-tools-arm64-gcc13`, the 13.3 baseline), `sources/haiku-usbstall`, the release images.

## 4. Tests under KVM (phase 3)

Host: AMD Ryzen 7 PRO 250 (8 cores / 16 threads), 29 GB RAM, `/dev/kvm` (the user is in group `kvm`), QEMU 11
(`qemu-system-x86_64` 11.0.0). Firmware: QEMU's own `share/qemu/edk2-x86_64-code.fd` with a per-run copy of
`edk2-i386-vars.fd` (or the distribution's `OVMF_CODE_4M.fd`/`OVMF_VARS_4M.fd`); SeaBIOS (QEMU's default) for BIOS.
New `local.conf` settings: `QEMU_X86` (the binary) and optionally `OVMF_CODE`/`OVMF_VARS`; the script finds the
firmware next to the QEMU binary otherwise.

### 4.1 `scripts/qemu-x86.sh` (new, modelled on `scripts/qemu-virt.sh`)

```
scripts/qemu-x86.sh [--image IMG] [--fw uefi|bios] [--disk ahci|nvme|virtio-scsi|usb|ide|cdrom] [--smp N]
                    [--topo cores=2,threads=2] [--mem 4G] [--nic virtio|e1000|rtl8139|none]
                    [--scratch IMG] [--sd IMG] [--audio] [--secs N] [--label L] [--vnc] [--gdb] [-- extra]
```

The command it builds (UEFI, AHCI, SMP 4):

```
qemu-system-x86_64 -machine q35,accel=kvm -cpu host -smp 4 -m 4G \
  -drive if=pflash,format=raw,readonly=on,file=<edk2-x86_64-code.fd> \
  -drive if=pflash,format=raw,file=<run>/vars.fd \
  -drive file=<run>/disk.qcow2,if=none,id=hd0 -device ide-hd,drive=hd0,bus=ide.0,bootindex=0 \
  -drive file=<scratch>,if=none,format=raw,id=sc0 -device ide-hd,drive=sc0,bus=ide.1 \
  -nic user,model=virtio-net-pci \
  -device qemu-xhci,id=xhci -device usb-kbd,bus=xhci.0 -device usb-tablet,bus=xhci.0 \
  -vga std -display none \
  -serial file:<run>/serial.log -monitor none -qmp unix:<run>/qmp.sock,server,nowait
```

- **No virtio-blk on x86-64**: `virtio_block` is packaged and a boot module only `@arm,arm64,riscv64`
  (`build/jam/packages/Haiku:139`, `:380`, upstream's lines), so an x86-64 image cannot boot from `virtio-blk-pci` on
  either tree. The default is AHCI (q35's ICH9: `ide-hd` on `ide.N`, as above); virtio storage is `virtio-scsi`
  (`virtio_scsi` is a boot module on every arch).
- `--fw bios`: no pflash (SeaBIOS). Run BIOS with both `-machine q35` and `-machine pc` (i440FX, legacy IDE).
- `--disk nvme`: `-device nvme,drive=hd0,serial=h22`; `virtio-scsi`: `-device virtio-scsi-pci,id=vs -device
  scsi-hd,drive=hd0,bus=vs.0`;
  `usb`: `-device usb-storage,bus=xhci.0,drive=hd0,bootindex=0`; `ide`: `-machine pc` + `-device ide-hd`;
  `cdrom`: the anyboot image as `-cdrom` (BIOS El Torito; read-only, smoke only).
- `--sd IMG`: `-device sdhci-pci -device sd-card,drive=sd0` with IMG as a data disk (the MMC/SDHCI changes).
- `--audio`: `-audiodev none,id=snd -device intel-hda -device hda-duplex,audiodev=snd`.
- `--nic e1000` for the second NIC run; `rtl8139` uses a FreeBSD-compat driver (`driver.c` change).
- The image is never written: each run gets a qcow2 overlay (`qemu-img create -f qcow2 -b IMG -F raw`), deleted
  afterwards unless `--keep`.
- The serial log is copied to `artifacts/qemu-x86/<ts>-<label>.log` with host time stamps on each line (a small
  reader on a `-chardev socket` instead of `-serial file:` when timing is needed); `--secs` ends the run and saves
  `scripts/qmp-screendump.py` screenshots every 20 s and at the end, as `qemu-virt.sh` does.
- Haiku x86-64 writes its kernel log (and `/dev/dprintf`) to COM1 when the kernel setting `serial_debug_output`
  is on (the default; the first smoke boot confirms it, else image-add a `kernel` settings file), so the arm64
  tests' UserBootscript convention works unchanged: lines tagged per test, then `shutdown -q`, which powers QEMU off.

Heavy runs (many boots) take `$HEAVY_BUILD_LOCK` for timing runs only, so no build disturbs them; functional runs
need no lock. The Pi bench is not involved.

### 4.2 Putting tests into an image

- `scripts/image-add.sh` and `scripts/disk-add-tree.sh` hard-code `generated.arm64`'s `bfs_shell` and a partition
  index. Add `--bfs-shell PATH` (default unchanged) and find the BFS partition by type (`0xeb`) or offset, for the
  anyboot layout; the x86-64 trees build their own `bfs_shell` under `objects/linux/x86_64/release/tools/`.
- A **scratch disk** per run for tests and write stress: `truncate -s 2G` + `bfs_shell --initialize IMG scratch`
  on the host (as design/usb-storage-integrity.md did), mounted in the guest by the bootscript.
- **Cross-built tests**: generalise `scripts/haiku-sysroot.sh` with `--arch x86_64 --generated DIR` (sysroot from that
  tree's `haiku.hpkg`, `haiku_devel.hpkg` and the downloaded `gcc_syslibs*`, `zlib*`, `ncurses6*` x86-64 packages),
  and add `scripts/build-x86-tests.sh OUTDIR` that compiles the set below with the x86-64 cross gcc against the
  **rpi4** sysroot. One set of binaries runs on both images: a test that needs something only our tree has
  (`__team_memory_barrier`, DT_RELR) fails to load upstream, which the grader records as "n/a upstream", not a
  failure. Native compiles in the guest (nightly has gcc) are the fallback.

Portability edits the tests need (small, in `tools/haiku-tests`):
- `strtold.c` stops with `#error` unless `LDBL_MANT_DIG == 113`; add an x87 table (`LDBL_MANT_DIG == 64`)
  generated with `strtold --gen` from the host's x86-64 glibc (the reference, as aarch64 glibc is for arm64).
- `spread.c` uses `dmb ishst`/`yield`; add the x86 `pause` equivalent.
- `castest.c`: on x86 compare-and-swap cannot fail spuriously; keep it as a sanity run.
- `armdbg.c` and `kernel-tests/id-regs.c` are arm64-only: skip.

### 4.3 What "works" means (each on rpi4 and on hrev60314 unless marked)

| ID | run | pass |
|---|---|---|
| BOOT | UEFI × {AHCI, NVMe, virtio-scsi}, BIOS × {q35 AHCI, pc IDE}, CD (BIOS), SMP 4; one SMP 1 and one `-m 512M` boot | Tracker and Deskbar on the screendump; bootscript marker after `waitfor -m application/x-vnd.Be-TRAK`; no `PANIC`, no KDL, no `vm_page_fault` for system teams in the serial log; same driver set as upstream (`listdev`, `ps`) |
| USB | boot from `usb-storage` on xHCI; data disk on `usb-ehci` | boots; 1 GB written + read back, MD5 equal; keyboard and tablet events (keyinject) |
| SD | `--sd` data disk | `/dev/disk/mmc/...` appears; 200 MB copy + MD5 equal; no sdhci error lines |
| NET | virtio-net, then e1000, then rtl8139 | DHCP lease; ping 10.0.2.2; DNS lookup; HTTPS fetch (curl); `pkgman refresh`; net_server restarted (`launch_roster stop`/`start x-vnd.Haiku-net_server`) and the interface still gets its lease renewed (the `_IsBootInterface` risk); resolvetime with no DNS (`-nic user,dns=…` pointing nowhere) |
| THR | threadstress (QEMU-sized), threadbench, forkbench, killrace (30×), exitthread, rw_lock_interrupt_test (jam target `rw_lock_interrupt_test`), spread at `-smp 4` and `-smp 4,cores=2,threads=2` | all pass on rpi4; upstream expected to fail rw_lock_interrupt_test and killrace at some rate (it deletes an exited thread's stack at once too) |
| TLS | tlsstatic (+ `LD_PRELOAD_ADDONS`), tlsreload, tlsunload 200, tlsbench | rpi4 all pass; upstream expected to fail the alignment check (★52) and tlsunload (★33) |
| LIBC | strtold (x87), strtest, polltest, usercopy, relrtest (built with `-z pack-relative-relocs`), membarrier, castest | rpi4 all pass; upstream expected: strtold, polltest, relrtest fail; membarrier n/a |
| VM | mmap-shared-mprotect, fault-signal-blocked (with a time limit: upstream faults forever), mprotect-unprotect-retry | rpi4 pass; upstream expected to fail the first two (★21, ★22) |
| FS | bfsmeta, fragwrite, bfsbits on the scratch disk; 3 power cuts (QMP `quit` during bfsmeta) then `checkfs` and bfsbits | no checkfs errors, bitmap matches the superblock |
| APP | launchtime of Terminal, StyledEdit, ShowImage, DeskCalc, Devices, WebPositive, MediaPlayer, FileTypes; bitmapcheck; drawbench; pmexit 400× with the churn loop (pmexit-loop.sh) | all start; bitmapcheck clean; pmexit 0 faults on rpi4, counted upstream |
| DBG | Debugger CLI on dbgtarget (C, DWARF 4 and 5) and dbgtarget-cxx: break, run, bt, step, next, finish; `profile -a` over an app start | stops where expected; `finish` returns to the caller; profile names the started program |
| PWR | shutdown-test.sh (registrar restart, kernel restart, power-off) under UEFI and BIOS | QEMU restarts twice then exits; no crash reports; the SavedClock job ends |
| RNG | 100 MB from /dev/urandom: MB/s, `xz` ratio, no repeated 16-byte window, byte chi-square against the host's /dev/urandom (a host script on the copied file) | statistics as the host's; rate ≥ upstream |
| MEDIA | `--audio`: media_server and media_addon_server up; play a system sound; tswatch 60 s | no errors; time source monotonic |

A bootscript per group (`tools/x86-tests/*.sh`, reusing the existing `tools/pi-tests` scripts where they are
generic: tls-tests.sh, threadstack.sh, membarrier.sh, pmexit-loop.sh, shutdown-test.sh, launch-pipes.sh,
fragwrite.sh), each printing tagged serial lines and an `end` line; `scripts/x86-grade.sh LOG` grades by those
positive markers, as `scripts/usb-boot-grade.sh` does for the Pi.

Out of scope in QEMU (listed in the report as untested): WiFi (openbsd_wlan join changes), Bluetooth, real SD
readers' UHS-I signalling, overlays on real Intel/Radeon accelerants, the Pi-specific usbhigh/usbalign cases
(arm64 DMA window and cache-line alignment).

### 4.4 Order

1. Boot smoke of both images, UEFI + AHCI (if rpi4 fails here, phase 4 starts at once; the upstream image must
   boot or the build setup is wrong — check against upstream's own hrev60314 nightly).
2. BOOT matrix, PWR, NET.
3. THR, TLS, LIBC, VM (one combined bootscript, ~10 min per image).
4. FS, USB, SD.
5. APP, DBG, MEDIA, RNG.
6. PERF A/B (§4.6).

### 4.5 A/B rules

Same toolchain, same package set, same QEMU command line, same host state; images alternated A, B, A, B, A, B; each
result with its log. A failure upstream is a finding ("general improvement"), not a reason to stop.

### 4.6 Timing A/B

- Boot: QEMU start → bootscript marker after Tracker (host time stamps), 5 boots per side, median and spread; also
  first-boot vs later boots (the first boot does package activation work).
- App start: launchtime for six apps, 5 rounds each, second launch (warm cache) and first launch after a boot.
- dlopentime (libbe, libtracker, a translator), threadbench, forkbench, a context-switch ping-pong, resolvetime,
  /dev/urandom rate, package read (cat of the WebPositive package files, cold), bfsmeta duration.
- **KDEBUG fairness**: our tree is at `KDEBUG_LEVEL 1`, hrev60314 at 2 (a slower kernel). Timing compares rpi4
  against an upstream build with the one-line change to 1 (an uncommitted edit in the `haiku-x86-up` worktree, a
  third image; ~20 min incremental build). Functional results use upstream as shipped (level 2).

## 5. Fixes and the report (phase 4)

- A breakage found on x86-64 is fixed on `rpi4` in a normal small commit (Haiku style), with the x86-64 test that
  showed it and an arm64 check: `scripts/build.sh` image + `scripts/qemu-virt.sh` boot always, and a Pi run under the
  bench lock when the change touches a path the Pi uses. Nothing is gated on `__x86_64__` to hide a bug: fix it for
  all, or gate an arm64-only behaviour on arm64 (e.g. if the `_IsBootInterface()` skip should depend on the boot
  method — the kernel already has `BOOT_METHOD` as a boot item since `8f0df61a1c`).
- If a fix cannot be made in this round, it goes to KNOWN-ISSUES with the test that shows it.
- Cleanups found here (not breakages): gate the unconditional Pi `SubInclude`s on arm64 (§1.4).
- Re-run the affected test group on both images after each fix; the final rpi4 SHA gets a full BOOT + THR/TLS/LIBC/VM
  + FS + APP pass.

Report (a new section "Results" at the end of this file, plus a short summary in the weekly log and a column in
HAIKU-RPI4-CHANGES's "Start here" table):

1. Build: both trees' jam rc, warnings counts, time, disk; the downloaded package list; anything from §3.2's
   checklist.
2. Matrix: test ID × firmware/disk × {rpi4, hrev60314} → pass / fail / n/a, with log names.
3. **Our fixes that help x86-64**: each ★ row and "gen" change with x86-64 evidence (upstream fails or is slower,
   rpi4 passes or is faster), and the ones without an x86-64 test (stated as such).
4. Regressions found and their fix commits; anything left in KNOWN-ISSUES.
5. Timing table (§4.6) with medians and spreads.
6. Untested on x86-64 (§4.3 "out of scope").

## 6. Blockers for phase 2

1. **Disk**: free ≥ 10 GB first (§3.4); 2b needs ≥ 20 GB.
2. **Network** to `eu.hpkg.haiku-os.org` for the x86-64 build packages (both trees, once).
3. **The heavy-build lock** is shared: the x86-64 builds queue behind the other agents' builds.
4. Script work before phase 3 (not before the builds): `build-x86.sh`, `qemu-x86.sh`, `--bfs-shell` for
   image-add/disk-add-tree, `haiku-sysroot.sh --arch`, `build-x86-tests.sh`, the strtold x87 table, `spread.c`'s
   pause, `x86-grade.sh`.

Not blockers: the toolchain sources (buildtools `upstream/master` and tag `hrev60314` are local), KVM access, the
firmware files, QEMU 11, and `nasm` (needed by configure for x86 targets only, `configure:112`; NASM 3.01 is
installed).

## 7. Checklist

- [x] Phase 1: inventory, toolchain decision, build and test plan (this document)
- [x] Phase 2: free disk; worktrees; `build-x86.sh`; cross tools; rpi4 `@nightly-anyboot`; hrev60314 `@nightly-anyboot`
  (plus the hrev60314 `KDEBUG_LEVEL 1` image; §8)
- [ ] Phase 2b (optional): GCC 16.2 x86-64 build of rpi4
- [x] Phase 3 tooling: `qemu-x86.sh`, `image-add.sh --bfs-shell`, `haiku-sysroot.sh --arch x86_64`,
  `build-x86-tests.sh`, `spread.c` pause; §4.4 step 1 (smoke) done (§8.5)
- [x] Phase 3: strtold x87 table, `tools/x86-tests/*.sh` bootscripts, `x86-grade.sh`; §4.4 steps 2–6 (§9; SD, USB data
  disk, RNG, MEDIA, DBG not run)
- [x] Phase 4 (part): four fixes on branch `x86-fix` (§9.4), arm64 compile-checked, pushed, not merged
- [ ] Phase 4 rest: arm64 runtime check, merge into rpi4, KNOWN-ISSUES, HAIKU-RPI4-CHANGES column

## 8. Phase 2 results (2026-11-04)

Both x86-64 images build and boot to the desktop under KVM. **No build break, so no fix:** branch `x86-buildfix`
was not needed and does not exist. The top risk of §1.5 did not happen: the x86-64 kernel builds at
`KDEBUG_LEVEL 1` without errors, both in our tree and in upstream with the one-line change.

### 8.1 Trees and toolchain

| dir | ref |
|---|---|
| `sources/buildtools-x86` | buildtools `33d46bf5c3` (upstream master, GCC 13.3.0, binutils 2.46.1), detached worktree |
| `sources/haiku-x86` | haiku `rpi4` **a779571e90** (`hrev60314+275`), detached worktree |
| `sources/haiku-x86-up` | haiku **hrev60314** `c9859af553`, detached worktree |
| `sources/haiku-x86-up-kd1` | hrev60314 + an uncommitted `KDEBUG_LEVEL 2 → 1` (`build/config_headers/kernel_debug_config.h`), detached worktree (the timing baseline of §4.6) |

One set of cross tools, `sources/haiku-x86/generated.x86_64/cross-tools-x86_64` (325 MB). The other trees use it
through `--cross-tools-prefix`, so all three `BuildConfig`s name the same compiler.

### 8.2 Commands and times

```
git -C sources/buildtools worktree add --detach ../buildtools-x86 33d46bf5c3
git -C sources/haiku worktree add --detach ../haiku-x86 rpi4
git -C sources/haiku worktree add --detach ../haiku-x86-up c9859af553
scripts/build-x86.sh configure rpi4           # cross tools, heavy-build guarded
scripts/build-x86.sh configure up
scripts/build-x86.sh build rpi4               # @nightly-anyboot
scripts/build-x86.sh build up                 # hard-links rpi4's download/ first
git -C sources/haiku worktree add --detach ../haiku-x86-up-kd1 c9859af553   # + the KDEBUG_LEVEL edit
scripts/build-x86.sh configure sources/haiku-x86-up-kd1/generated.x86_64
scripts/build-x86.sh build sources/haiku-x86-up-kd1/generated.x86_64
```

| step | rc | time (16 jobs) | log (artifacts/build/) |
|---|---|---|---|
| cross tools (binutils + GCC 13.3) | 0 | 367 s | `x86-crosstools-20261104-165112.log` |
| rpi4 `@nightly-anyboot` (incl. download and a short heavy-build lock wait) | 0 | 309 s | `x86-rpi4-20261104-165740.log` |
| hrev60314 `@nightly-anyboot` | 0 | 252 s | `x86-up-20261104-170314.log` |
| hrev60314 + `KDEBUG_LEVEL 1` `@nightly-anyboot` | 0 | 263 s | `x86-haiku-x86-up-kd1-20261104-171023.log` |

Each image, `generated.x86_64/haiku-nightly-anyboot.iso`, is 690 814 976 bytes. It has two MBR partitions:
BFS (type `0xeb`, the first, bootable) and the EFI system partition (`0xef`). That is why `image-add.sh` now finds
the BFS partition by its type: the Pi image's BFS is its second partition.

### 8.3 Build-log checklist (§3.2)

- jam rc 0 on all three.
- In our tree's `haiku.hpkg`: `bt_dev_info`, `bt_discovery`, `libmidi.so` and `/system/boot/SavedClock`.
- `AddHaikuImagePackages: package mawk not available!` appears in **all three** logs: upstream's
  `OptionalPackages` names mawk and the x86_64 repository has none. Not ours.
- **Warnings** (normalised `../src|../headers` file + message, line numbers dropped):
  - rpi4: 1015 distinct (2270 lines). hrev60314 at level 2: 1022 (2263 lines). hrev60314 at level 1: 1015.
  - **rpi4 and upstream at level 1 have identical warning sets**, so our commits (`hrev60314+275`) add no warning to the
    x86-64 build.
  - Against upstream's level 2, there are 4 warnings more and 11 fewer, all `KDEBUG_LEVEL` effects in files our
    commits do not touch. New: unused variables only read by `ASSERT()`, in `nvmm_x86_svm.c`, `nvmm_x86_vmx.c`,
    `fat/vcache.cpp` and `ntfs/kernel_interface.cpp`. Gone: sign-compare/format warnings in the FreeBSD
    compat / realtekwifi / net80211 code and one `-Warray-bounds` in `kernel/interrupts.cpp`.
- The log's `fatal error: jpeglib.h …` (and png, tiff, webp, avif, icns, jasper, wonderbrush) lines come from
  catalog-key extraction, which preprocesses the translators without their build-feature headers. They are not
  failures, and upstream's log has them too. `build-x86.sh` leaves them out of its error summary.

### 8.4 Downloaded packages (§3.3)

148 files, 428 MB, from `eu.hpkg.haiku-os.org/haikuports/master/build-packages` (the CDN). The rpi4 build downloads
them; the other trees get them as hard links, so they take no extra space:

autoconf automake bash bc binutils bison brotli bzip2 ca_root_certificates cdrtools coreutils curl dav1d diffutils
expat(+devel) fdk_aac ffmpeg6(+devel) findutils flex fluidlite_devel fontconfig(+devel) freetype(+devel) fribidi
game_music_emu gawk gcc gcc_syslibs(+devel) gettext_libintl giflib git glu(+devel) gmp graphite2 grep
gutenprint9(+devel) gzip haikuwebkit(+devel) harfbuzz icu74(+devel) intel_wifi_firmwares jam jasper(+devel) lame
lcms less libass libavif1.0(+devel) libedit(+devel) libexecinfo libgpg_error libicns(+devel) libiconv libidn2
libjpeg_turbo(+devel) libogg libopenmpt libpcap libpcre libpcre2 libpng16(+devel) libpsl libraw(+devel) libssh2
libtheora libunibreak libunistring libvorbis(+devel) libvpx1.16 libwebp(+devel) libxml2 libxslt llvm12_libs m4
make mandoc mesa(+devel, swpipe) mkdepend mpc mpfr nano nasm ncurses6(+devel) netcat nghttp2 noto noto_sans_cjk_jp
openjpeg openssh openssl3(+devel) opus p7zip patch pe perl pkgconfig ralink_wifi_firmwares rav1e readline
realtek_wifi_firmwares sed sharutils snappy sounds_community_default soxr speex speexdsp sqlite tar tcpdump texinfo
tiff(+devel) unzip vision wget which woff2 wpa_supplicant xz_utils zip zlib(+devel, source) zstd(+devel, source).

### 8.5 Smoke boots (KVM, q35, AHCI, SMP 4, 4 GB, virtio-net)

`scripts/qemu-x86.sh --desktop --bootscript tools/x86-tests/smoke.sh --until 'SMOKE desktop up'`: the bootscript
waits for Tracker and Deskbar, prints uname, the CPU count and the team count, sleeps 10 s, then prints the
marker. Every run is a first boot on a fresh overlay.

| image | firmware | marker after | result | serial / screenshot (artifacts/qemu-x86/) |
|---|---|---|---|---|
| rpi4 | UEFI | 17 s | desktop, 4 CPUs, 28 teams | `20261104-170826-smoke-rpi4-uefi.{log,png}` |
| rpi4 | BIOS | 16 s | desktop | `20261104-170847-smoke-rpi4-bios.{log,png}` |
| hrev60314 | UEFI | 19 s | desktop, 4 CPUs, 27 teams | `20261104-170905-smoke-up-uefi.{log,png}` |
| hrev60314 | BIOS | 17 s | desktop | `20261104-170925-smoke-up-bios.{log,png}` |

- Every log is free of `PANIC`, KDL entry, `vm_page_fault` and `waiting for the boot device` (the `bce76d6e73`
  risk).
- The kernel writes its log to COM1 by default, so §4.1's bootscript convention works unchanged.
- UEFI's frame buffer comes up at 2048×2048 and VESA (BIOS) at 1280×800, the same on both trees.
- The first rpi4 UEFI run (`20261104-170336-*`) took 37 s because the upstream build ran beside it. These are
  single samples, not the timing A/B of §4.6.

Pipeline proof (`20261104-171515-pipe-proof-rpi4.log`): the rpi4 image with two cross-built tests added by `--add`
and a bootscript that runs them, prints to COM1 and calls `shutdown -q`:

- `mmap-shared-mprotect` **PASS** (★21 on x86-64, first sample).
- QEMU exits by itself on the ACPI power-off ("guest powered off").

### 8.6 Phase-3 tooling (committed, no VM matrix run yet)

- `scripts/build-x86.sh`:
  - `configure rpi4|up|all|DIR`;
  - `build rpi4|up|DIR [jam args]` (default `@nightly-anyboot`), heavy-build guarded; it hard-links rpi4's
    downloads into the other trees, logs `artifacts/build/x86-<tree>-<ts>.log`, prints rc and the warning count,
    and stops a stale image-builder `bfs_shell` after a failure.
- `scripts/qemu-x86.sh`:
  - KVM, q35 (or `pc`), UEFI (edk2-x86_64-code.fd + a per-run copy of edk2-i386-vars.fd) or BIOS;
  - `--disk ahci|nvme|virtio-scsi|usb|ide|cdrom`, `--smp/--topo/--mem`, `--nic virtio|e1000|rtl8139|none`,
    `--scratch`, `--sd` (sdhci-pci), `--audio` (intel-hda);
  - `--bootscript`, `--add FILE:PATH`, `--desktop` (ships `Locale settings`, so the first boot skips
    FirstBootPrompt);
  - a qcow2 overlay (the image is never written);
  - serial to `artifacts/qemu-x86/<ts>-<label>.log`, a QMP socket, screendumps every `--shot-every` s and at
    the end;
  - the run ends on guest power-off, `--until REGEX` or `--secs`; then a summary of the end reason, the time and
    PANIC/KDL lines.
- `scripts/image-add.sh`:
  - `--bfs-shell PATH`;
  - the BFS partition is found by type `0xeb` (the anyboot layout);
  - `bfs_shell` arguments are quoted, so names with blanks such as `Locale settings` work (they silently failed
    before);
  - re-tested on a synthetic Pi-layout image with the arm64 `bfs_shell`.
- `scripts/haiku-sysroot.sh --arch x86_64 [--generated DIR]` → `artifacts/sysroot-x86_64` (225 MB).
  `scripts/build-tls-tests.sh --arch x86_64`.
- `scripts/build-x86-tests.sh OUTDIR`:
  - builds all 45 files cleanly with GCC 13.3: THR, LIBC (incl. relrtest with DT_RELR, membarrier with `-lgnu`),
    VM, FS, APP/MEDIA/NET, DBG (DWARF 4 and 5), TLS;
  - leaves out `armdbg.c`, `id-regs.c` and `strtold.c`.
- `tools/haiku-tests/spread.c` uses `pause` on x86.

### 8.7 Disk

| item | size |
|---|---|
| `sources/haiku-x86` (sources, cross tools, objects, download, image) | 3.7 GB |
| `sources/haiku-x86-up`, `sources/haiku-x86-up-kd1` | 2.7 GB each (download hard-linked) |
| `sources/buildtools-x86` | 1.7 GB |
| `artifacts/sysroot-x86_64`, `artifacts/qemu-x86` | 0.23 GB |
| **phase 2 total** | **≈ 11 GB** (the plan estimated 22–31 GB) |

Free space on `/`: 52 GB at the start, 40 GB at the end. Another agent wrote at the same time, so that drop is not
all ours.

### 8.8 What phase 3 needs

1. `strtold.c` for x87 long double. A new table is not enough:
   - the 16-byte `long double` holds 10 value bytes and 6 padding bytes, so the bit comparisons must mask them;
   - the `%.36Lg` round trip becomes `%.21Lg`;
   - the random patterns need the explicit integer bit;
   - the expected values come from host glibc (`strtold --gen`).
2. The bootscripts for each test group (`tools/x86-tests/*.sh`) and `scripts/x86-grade.sh`.
   - Note from the proof run: `$?` after a pipeline is the last command's status, so a test's own exit code has
     to be captured before its output is filtered.
3. The §4.3 matrix on both images, in §4.4 order, with `qemu-x86.sh`:
   - BOOT: UEFI × {AHCI, NVMe, virtio-scsi}, BIOS × {q35, pc IDE}, CD, SMP 1, 512 MB; then PWR and NET;
   - THR/TLS/LIBC/VM, then FS/USB/SD, then APP/DBG/MEDIA/RNG.
4. Timing A/B (§4.6): rpi4 against `haiku-x86-up-kd1`, alternating, 5 boots each, under `$HEAVY_BUILD_LOCK` so that
   no build runs beside them.
5. Optional 2b (GCC 16.2 build of rpi4): there is disk for it (≈ 4 GB by this phase's numbers).

## 9. Phase 3 results (2026-11-04, KVM) and phase 4 fixes

All runs: KVM on the AMD host, QEMU 11.0, `-cpu host`, q35 unless noted, 4 GB, SMP 4, virtio-net (user mode), a
fresh qcow2 overlay per run (so every boot 1 is a first boot), UEFI = QEMU's edk2. Logs, screenshots and the row
file are in `artifacts/qemu-x86/` (`results.tsv`: one row per test and run; `perf.tsv`: the timing runs).
**No Pi time was used.**

| image | what |
|---|---|
| **ours** | `sources/haiku-x86` = rpi4 **a779571e90** (copy kept as `artifacts/x86-images/rpi4-a779571e90.iso`) |
| **up** | `sources/haiku-x86-up` = hrev60314, `KDEBUG_LEVEL` 2 as shipped: the functional baseline |
| **kd1** | `sources/haiku-x86-up-kd1` = hrev60314 at `KDEBUG_LEVEL` 1: the timing baseline only |
| **fix** | `sources/haiku-x86-fix` = branch **`x86-fix`** (a779571e90 + the four phase-4 commits, §9.4) |

### 9.1 Harness (committed with this section)

- `tools/x86-tests/*.sh` — one UserBootscript per group: `boot`, `pwr`, `net`, `nodns`, `core` (THR+TLS+LIBC+VM),
  `core2` (the part of core an image without our fixes never reaches), `libc`, `fs`, `pc1`/`pc2` (power cut),
  `bootio` (write integrity on the boot disk itself), `app`, `perf`; `lib.sh` holds the helpers. Each test runs as
  `timeout -k 5 SECS prog > file; rc=$?` — the exit status is taken **before** any filter — and prints
  `X86T <group> result <test> PASS|FAIL|N/A rc=<n> …`, the group ends with `X86T <group> end` and `shutdown -q`.
- `scripts/x86-test.sh GROUP IMAGE [qemu-x86 options]` (puts the cross-built tests, `lib.sh`, a debug_server
  `default_action kill` and the bootscript into the image), `scripts/x86-grade.sh LOG` (PASS/FAIL/N/A per test; a
  group without its end line is INCOMPLETE; PANIC/KDL; debugger entries and user faults; pmexit-window faults),
  `scripts/x86-matrix.sh` (BOOT configurations), `scripts/x86-powercut.sh`, `scripts/x86-perf.sh` +
  `scripts/x86-perf-table.py` (timing under the heavy-build lock), `scripts/kdl-x86.py` + `qemu-x86.sh
  --serial-sock` (type KDL commands into COM1), `qemu-x86.sh --legacy-virtio`,
  `scripts/arm64-compile-check.sh` (compile a worktree's files with the arm64 build's exact flags; the object goes to
  a temp file — checked: the main arm64 tree's objects of the touched files kept their 12:35/12:37 mtimes; it leaves
  `<worktree>/generated.arm64-check/` with two links into `sources/haiku/generated.arm64`).
- Tests: `strtold.c` now has an x87 branch (padding bytes masked, `%.21Lg` round trips, the explicit integer bit
  set exactly for normal random values, a table from x86_64 glibc 2.43 plus x87 limit cases) and checks of
  values that overflow only by rounding; new `setrlimit.c`, `systime.c`; `rw_lock_interrupt_test` comes from the
  x86 jam build; `forkbench.c` flushes each line (written to a file on Haiku, its lines after the first were lost
  on both images — not investigated further).
- Harness limits seen: two runs **started in the same second** sometimes lose one run's image-add (one
  upstream power cut and one rpi4 SMP-1 boot were lost that way and re-run); `qemu-x86.sh` must not be edited
  while a run uses it (one upstream core run was lost so).

### 9.2 Matrix: ours vs upstream

**BOOT** (`scripts/x86-matrix.sh rpi4 up`; desktop = Tracker and Deskbar running, then ACPI power-off):

| configuration | ours | up | note |
|---|---|---|---|
| UEFI, AHCI (q35) | PASS | PASS | |
| UEFI, **NVMe** | **FAIL**: desktop up, then `shutdown` never powers off | PASS | regression R1 (§9.4); **fix: PASS** (5 of 5 boots, `bootio`) |
| UEFI, virtio-scsi | PASS | PASS | |
| UEFI, virtio-scsi + virtio-net **legacy** (`disable-modern=on`, I/O BARs) | PASS | PASS | the `cafef4f9bb` I/O-BAR risk: none |
| UEFI, USB boot disk (usb-storage on xHCI) | PASS, but the kernel **waits** for the boot device | PASS, no wait | expected from `afb2823bb5` + `bce76d6e73` (§9.4 R4) |
| BIOS, AHCI (q35) | PASS | PASS | |
| BIOS, IDE (`-machine pc`) | PASS | PASS | |
| BIOS, CD (El Torito) | boots to the installer's Welcome window (bootscript not run on a CD) | same | both by screenshot, no panic |
| UEFI, SMP 1 | PASS | PASS | |
| UEFI, 512 MB | PASS | PASS | the 128 kB bounce buffers / 512 kB loader cache fit |
| UEFI, `-smp 4` as 2 cores × 2 threads | PASS | PASS | |
| UEFI, e1000 / rtl8139 (FreeBSD-compat driver) | PASS / PASS | PASS / PASS | |

Kernel module sets (`listimage 1`) and `listdev` device counts are the same on both for UEFI AHCI/NVMe/virtio-scsi and
BIOS AHCI/IDE; the USB boot differs only in `usb_raw` being loaded on ours by then. No panic, no KDL in any BOOT run.

**Functional groups** (UEFI, AHCI, SMP 4; "fix" = the `x86-fix` image):

| group | test | ours | up | fix | evidence (up) |
|---|---|---|---|---|---|
| PWR | `shutdown -r`, `shutdown -q -r`, `shutdown` (3 boots, power-off), UEFI and BIOS | PASS ×2 | PASS ×2 | — | |
| NET | DHCP, ping 10.0.2.2, DNS, HTTPS (curl), `pkgman refresh` | PASS | PASS | PASS | |
| NET | net_server restarted: the interface gets DHCP again | **FAIL** | PASS | PASS | regression R2 (§9.4) |
| NET | resolve own host name, `--nic none` (no name server) | PASS (3 ms) | **FAIL** (gethostbyname 7.0 s, getaddrinfo 28.0 s, both fail) | — | ★32 |
| THR | threadstress 1000 | PASS | **FAIL**: hangs (900 s timeout); `user: stack … not in the user's …+131072`, `did not run` | PASS | `dbae37b2cb` |
| THR | rw_lock_interrupt_test ×20 | PASS 20/20 | **FAIL 0/20**: `interrupted by a signal: FAIL (the writer never got the lock)` | PASS | ★41 |
| THR | killrace ×30 | PASS 0 faults | **FAIL 30/30** `Segment violation` | PASS | ★43 |
| THR | castest (3 variants) | PASS | PASS | PASS | x86 CAS is strong anyway |
| THR | threadbench, forkbench, spread | ran | ran | ran | timing in §9.3 |
| TLS | tlsstatic, and with `LD_PRELOAD_ADDONS` | PASS | **FAIL** `library aligned address % 64: 16, expected 0` | PASS | ★52 |
| TLS | tlsreload | PASS | **FAIL** `round 1: read 0 after setting 1234` | PASS | ★33 |
| TLS | tlsunload 200 | PASS | PASS | PASS | ★33's other case does not show on x86 |
| TLS | tlsbench | ran | ran | ran | §9.3 |
| LIBC | strtold (x87 table, 266 checks) | **FAIL**: 4 ERANGE checks (values that overflow by rounding) | **FAIL**: dozens (double precision, `inf` for 1e4000, lost signs) | PASS | ★38; ours: R3 (§9.4) |
| LIBC | strtod/strtof checks | **FAIL**: rounding overflow without ERANGE | **FAIL**: `-0`, `-nan`, `nan(0x123)`, `0x1p-1075`, rounding overflow | PASS | ★39 + R3 |
| LIBC | setrlimit (current value of a fixed limit) | PASS | **FAIL** EINVAL ×6 (coreutils `timeout` prints `disabling core dumps failed`) | PASS | ★40 |
| LIBC | strtest | PASS | PASS | PASS | |
| LIBC | polltest | PASS | **FAIL** `events unchanged … (0x1085)` | PASS | `127fb34239` |
| LIBC | usercopy | PASS | **kernel PANIC** `VMArea::Unwire(…, 0x1000, 1): no such range` (5 of 5 runs that reached it) | PASS | ★20 |
| LIBC | relrtest (DT_RELR) | PASS | FAIL (crashes, rc 149) | PASS | feature `4539cd2f00` (upstream has no DT_RELR) |
| LIBC | membarrier | PASS | N/A (no `_kern_team_memory_barrier`) | PASS | feature `1582c223b0` |
| VM | mmap-shared-mprotect | PASS | **FAIL** `after mprotect() of a new mapping … BROKEN` | PASS | ★21 |
| VM | fault-signal-blocked | PASS | **FAIL** `still faulting after 10 s` (both cases) | PASS | ★22 |
| VM | mprotect-unprotect-retry | PASS | PASS | PASS | arm64-only problem |
| FS | bfsmeta 4000 files on a scratch BFS | PASS, **74 µs/file** | PASS, **1527 µs/file** | PASS | ★45 (one run each, run side by side) |
| FS | copy apps+lib (2277 files, 613 MiB), MD5; unmount + mount, MD5 | PASS | PASS | PASS | |
| FS | fragwrite (30 MB in ~7500 holes) | PASS | PASS | PASS | |
| FS | checkfs: 0 not allocated, 0 already set | PASS (28 "could be freed") | PASS (28) | PASS (28) | same count on both; bfsbits S−U = 0 |
| FS | power cut (QMP quit after 20000 files of `bfsmeta --loop`), mount, checkfs, bfsbits, write | PASS 3/3 | PASS 3/3 | — | |
| FS | boot-disk write integrity (80 MB copy, MD5, restart, MD5), NVMe and AHCI | not run (`dd`/`sync` on NVMe hang, R1) | PASS (NVMe) | PASS (NVMe, AHCI) | |
| APP | launch Terminal, StyledEdit, ShowImage, DeskCalc, Devices, FileTypes, MediaPlayer, WebPositive | PASS | PASS | — | |
| APP | bitmapcheck (13 screen hashes) | identical | identical | — | |
| APP | drawbench | ran | ran | — | |
| APP | pmexit ×400 with path churn | 0 bad, 0 faults | 0 bad, 0 faults | — | ★53 does not reproduce on x86-64 |

The "up" column of THR/TLS/LIBC/VM comes from `core` (it panics in usercopy), `core2` and `libc` runs
(`20261104-180704-core-up`, `-185613-core2-up`, `-184138-libc-up` in `artifacts/qemu-x86/`). The fix image ran the
full `core` group (twice: before and after R5), `libc`, `net`, `fs`, `bootio` and the BOOT subset (AHCI, NVMe, BIOS
AHCI, BIOS IDE, USB): all PASS except the USB wait (R4).

### 9.3 Timing: ours vs upstream at `KDEBUG_LEVEL` 1

`scripts/x86-perf.sh 5 rpi4 kd1` under the heavy-build lock (`/tmp/phoenix-heavy-build.lock`), nothing else running on
the VM side, images alternated A, B, A, B (10 fresh-overlay runs, 19:06–19:20). Per run (`tools/x86-tests/perf.sh`):
boot 1 (a first boot) and boot 2 (after `shutdown -r`) times, then each application launched cold and warm, forkbench,
threadbench, tlsbench, dlopentime ×20. Two clocks for the boot: the kernel's `system_time()` at the desktop marker
(Tracker and Deskbar running), and the host's time from QEMU start (firmware and loader included) to that line in
the serial log, polled every 0.1 s. Rows: `artifacts/qemu-x86/perf.tsv`; table: `scripts/x86-perf-table.py rpi4 kd1`.

**KVM is not bare metal**, and "ours" is all 275 commits at once (same `KDEBUG_LEVEL` 1): the table says the tree
is faster, not which commit makes it so.

| metric | rpi4 median [min–max] (runs) | kd1 median [min–max] (runs) | kd1 / rpi4 |
|---|---|---|---|
| boot 1 (first boot), QEMU start to desktop, host s | 6.92 [6.81–10.38] (5) | 8.28 [8.18–8.28] (5) | 1.20 |
| boot 1 (first boot), kernel start to desktop, s | 4.51 [4.43–7.83] (5) | 5.47 [5.36–5.53] (5) | 1.21 |
| boot 2, kernel start to desktop, s | 4.34 [4.30–4.38] (5) | 5.23 [5.21–5.28] (5) | 1.21 |
| launch Terminal cold, ms | 35.00 [34.00–40.00] (5) | 37.00 [33.00–40.00] (5) | 1.06 |
| launch Terminal warm, ms | 25.00 [24.00–26.00] (5) | 28.00 [28.00–28.00] (5) | 1.12 |
| launch StyledEdit cold, ms | 26.00 [25.00–32.00] (5) | 29.00 [28.00–30.00] (5) | 1.12 |
| launch StyledEdit warm, ms | 24.00 [19.00–25.00] (5) | 28.00 [27.00–29.00] (5) | 1.17 |
| launch ShowImage cold, ms | 23.00 [22.00–27.00] (5) | 27.00 [26.00–34.00] (5) | 1.17 |
| launch ShowImage warm, ms | 25.00 [21.00–25.00] (5) | 30.00 [25.00–30.00] (5) | 1.20 |
| launch DeskCalc cold, ms | 10.00 [10.00–15.00] (5) | 11.00 [11.00–11.00] (5) | 1.10 |
| launch DeskCalc warm, ms | 8.00 [8.00–9.00] (5) | 10.00 [9.00–10.00] (5) | 1.25 |
| launch Devices cold, ms | 41.00 [40.00–47.00] (5) | 51.00 [48.00–58.00] (5) | 1.24 |
| launch Devices warm, ms | 24.00 [23.00–30.00] (5) | 30.00 [29.00–40.00] (5) | 1.25 |
| launch MediaPlayer cold, ms | 21.00 [21.00–22.00] (5) | 30.00 [29.00–31.00] (5) | 1.43 |
| launch MediaPlayer warm, ms | 18.00 [18.00–19.00] (5) | 25.00 [24.00–25.00] (5) | 1.39 |
| launch WebPositive cold, ms | 436 [418–454] (5) | 546 [534–560] (5) | 1.25 |
| launch WebPositive warm, ms | 129 [128–137] (5) | 168 [163–174] (5) | 1.30 |
| forkbench thread, us | 41.00 [37.00–43.00] (5) | 45.00 [44.00–47.00] (5) | 1.10 |
| forkbench fork+exit, us | 140 [133–148] (5) | 149 [145–161] (5) | 1.06 |
| forkbench fork+exec, us | 660 [616–670] (5) | 690 [661–752] (5) | 1.05 |
| forkbench posix_spawn, us | 574 [522–616] (5) | 578 [572–596] (5) | 1.01 |
| threadbench pthread, us | 39.60 [38.90–42.50] (5) | 41.90 [41.10–43.30] (5) | 1.06 |
| threadbench pthread-stack64k, us | 39.20 [38.90–39.90] (5) | 47.60 [46.70–49.70] (5) | 1.21 |
| threadbench spawn_thread, us | 39.70 [39.20–40.90] (5) | 43.00 [41.30–45.90] (5) | 1.08 |
| tlsbench global, ns | 2.01 [1.99–2.03] (5) | 1.99 [1.51–2.10] (5) | 0.99 |
| tlsbench thread-local (linked library), ns | 9.96 [9.44–10.37] (5) | 8.23 [7.88–8.43] (5) | 0.83 |
| tlsbench thread-local (dlopened), ns | 9.72 [9.25–9.78] (5) | 8.00 [7.97–8.51] (5) | 0.82 |
| dlopen libbe.so first, ms | 3.55 [3.46–6.31] (5) | 5.79 [5.48–7.99] (5) | 1.63 |
| dlopen libtracker.so first, ms | 4.94 [4.21–5.65] (5) | 8.13 [7.42–9.86] (5) | 1.65 |
| dlopen libtracker.so warm (median of the rest), ms | 0.88 [0.86–0.93] (5) | 2.56 [2.51–2.72] (5) | 2.91 |
| dlopen PNGTranslator first, ms | 4.29 [4.08–4.72] (5) | 6.74 [6.48–7.12] (5) | 1.57 |
| dlopen PNGTranslator warm (median of the rest), ms | 0.28 [0.26–0.29] (5) | 0.39 [0.35–0.41] (5) | 1.39 |

(`dlopen libbe.so` after the first round is 0.00 ms on both: libbe stays loaded after `dlclose()`; left out.)

- **Boot**: ours reaches the desktop ≈ 0.9 s earlier from the kernel's start (boot 2: 4.34 vs 5.23 s, spreads
  0.08 s and 0.07 s, no overlap); the host clock agrees (6.92 vs 8.28 s for boot 1). One ours run had a slow first
  boot (7.83 s kernel, 10.38 s host; round 5) — kept in the min–max.
- **Application starts**: upstream takes 6–43 % longer at the median, warm and cold; most ranges do not overlap
  (Terminal cold does). WebPositive cold 436 vs 546 ms, warm 129 vs 168 ms.
- **Libraries**: dlopen of libtracker 1.65× (first) and 2.9× (warm) faster, a translator 1.4–1.6×, libbe 1.6×
  (first). Candidates: `-Bsymbolic-functions` (`3e8577af06`; calls inside a library bind locally) and
  `--hash-style=both` (`91012322ef`; DT_GNU_HASH lookups). This is the only evidence for those two — no per-commit A/B.
- **fork/threads**: upstream's thread creation takes 6–21 % longer (pthread with a 64 kB stack 47.6 vs 39.2 µs: the
  stack reuse of `ecab951764`); fork+exit/exec 5–6 % (ranges overlap), posix_spawn equal.
- **TLS: ours was slower** — a library's thread-local access 9.96 vs 8.23 ns (+21 %, no overlap). Root cause and fix
  in §9.4 R5; with it, 8.1 ns (A/B below).

TLS A/B after the R5 fix (`tools/x86-tests/tlsperf.sh`: tlsbench ×5 per boot, 2 boots per image, alternated, under the
heavy-build lock; medians of 10 [min–max]):

| image | thread-local, linked library | thread-local, dlopened |
|---|---|---|
| ours a779571e90 | 10.09 [9.65–10.40] ns | 9.83 [9.11–10.09] ns |
| fix a2cf89efd1 | **8.12** [7.48–8.36] ns | **8.06** [7.28–8.25] ns |
| hrev60314 at KDEBUG 1 | 8.22 [7.17–8.59] ns | 8.13 [7.45–8.55] ns |

### 9.4 Regressions found, and the fixes (phase 4)

Branch **`x86-fix`** in `sources/haiku` (worktree `sources/haiku-x86-fix`), off rpi4 a779571e90, pushed to origin,
**not merged**. Each fix was compiled for arm64 with the arm64 build's own flags (`scripts/arm64-compile-check.sh`,
`-Werror`): ok. arm64 runtime (QEMU virt, Pi) was **not** tested.

**R1 — NVMe writes hang (our `8edea64c6b`, DMA bounce buffers 16 → 128 kB). Fixed: `3a0be104e3`.**
- Symptom: ours boots from NVMe, but the first larger write (a 13 MB `dd`, the BFS log flush, `sync`, `shutdown`)
  never finishes; 7 of 7 boots. Upstream and AHCI/virtio-scsi/IDE fine. Reverting the bounce size alone cured it.
- Found with KDL over the serial socket (`kdl-x86.py`): `sync` waits in `IORequest::Wait()` under
  `vfs_write_pages()` (BFS `_WriteTransactionToLog`); the kernel log says `nvme_disk: attempt to queue write I/O at
  LBA … of 256 blocks failed!`; a probe showed the request's one vec as `0x…+0x0`.
- Root cause: `IOOperation` saves and restores the vec it shortens for a partial write's read phase in
  `uint16 fSavedVecLength`. A 128 kB bounce vec came back as length 0. (16 kB vecs fitted, so upstream never hit it.)
- Fix: `fSavedVecLength` is `generic_size_t`, `fSavedVecIndex` `uint32`. NVMe boot: 5/5 finish and power off, `bootio` MD5s
  equal across a restart on NVMe and AHCI; `core` all PASS on the fix image.
- Left alone, deliberately: `nvme_disk_bounced_io()` notifies a request whose status is still "in progress" when
  queueing fails, so an I/O error becomes a hang instead of EIO (upstream code). And: the Pi's SD path uses the same
  128 kB bounce buffers, so a partial-block write there could have been shortened the same way — worth an FS run on
  the Pi with the fix.

**R2 — net_server leaves a DHCP interface unmanaged after a restart (our `cb0f2f9884`). Fixed: `444704d5f1`.**
- `_IsBootInterface()` skipped every interface with an IPv4 address, at every net_server start. After
  `launch_roster stop/start x-vnd.haiku-net_server` on a disk boot the syslog said
  `/dev/net/virtio/0 was configured for the network boot, leaving it as it is` and no DHCP client ran (lease never
  renewed); upstream re-ran DHCP (DISCOVER/OFFER/REQUEST/ACK).
- Fix: skip only when `/boot` is on `/dev/disk/virtual/remote_disk/`. Fix image: DHCP exchange after the restart.
  The network-boot branch is untested (no x86 network boot; no Pi run).

**R3 — x87 `strtold()`: no ERANGE for values that overflow by rounding (shows through our `12eb998a63`). Fixed:
`c8c59043a7`.**
- `round_and_return()` returned infinity with ERANGE only for `exponent > MAX_EXP`; at `== MAX_EXP` (a carry out of
  the largest mantissa, or a hex input) `MPN2FLOAT()` built infinity's bits without ERANGE. Upstream's own `strtod`
  and `strtof` have the same bug (both images fail `strtod("1.7976931348623159e308")` and
  `strtof("3.4028236e38")`), so the fix helps upstream code too. Now `exponent >= MAX_EXP` is the overflow, as in
  glibc. Fix image: strtold 268/268, strtod/strtof all pass.

**R5 — a library's thread-local access 21 % slower on x86-64 (our `c6cab6cc9e`, static TLS block). Fixed:
`a2cf89efd1`.**
- Found by the timing A/B (§9.3), not by a functional test. `get_tls_address()` looked the module up in the static
  TLS block on every call (a `TLS_STATIC_MODULE` test, then `TLSBlockTemplates::GetStaticOffset()`). Only arm64 has a
  static block, and there libroot's `__tls_get_addr()` reads the thread vector itself; x86_64's `__tls_get_addr()`
  calls the runtime loader for every access, and no module is ever static there.
- Fix: the lookup only where `TLS_STATIC_BLOCK` is defined (a constant, so arm64 compiles the same code as
  before). x86-64: 10.09 → 8.12 ns (upstream 8.22), §9.3; `core` all PASS on the fix image, TLS tests included.

**R4 — USB boot disk: the kernel waits for the boot device (our `afb2823bb5` + `bce76d6e73`). Not changed.**
- A new USB bus is explored in the explore thread now, so the usb_disk appears after the kernel first looks for
  the boot volume; `bce76d6e73` then waits (≤ 10 s) and finds it — the serial log has `get_boot_partitions(): waiting
  for the boot device` followed by `Mounted boot partition: /dev/disk/usb/0/0/0` two lines on. Boots fine on both;
  the delay is short but was not measured. It is the designed behaviour, not a failure.

### 9.5 Our fixes that help x86-64 (for general use)

Each: upstream hrev60314 fails on x86-64 under KVM, our tree passes (same test binary).

1. **★20 `6f810ed2d7` lock_memory_etc() unwire on failure** — any user program panics the upstream x86-64 kernel:
   `usercopy` (a `read()` into a buffer running into a PROT_NONE page) → `PANIC: VMArea::Unwire(…): no such range`,
   in all 5 upstream runs that reached it. Ours: PASS.
2. **★21 `894c4abe7f` MAP_SHARED survives mprotect()** — `mmap-shared-mprotect` BROKEN upstream after fork + mprotect.
3. **★22 `6e517bb52c` a fault with SIGSEGV blocked ends the team** — upstream still faulting after 10 s, both cases.
4. **`dbae37b2cb` caller-provided stack placement** — upstream threadstress: `user: stack … not in the user's …`
   then a hang (every threadstress test, 900 s / 180 s timeouts).
5. **★41 `2bf2f773ba` rw_lock waits again after an interrupted block** — upstream 0/20, the writer never gets the lock.
6. **★43 `e09cfa1d9e` dying team keeps exited threads' stacks** — upstream killrace 30/30 segment violations; ours 0/30.
7. **★52 `4d433669a8` TLS block alignment** — upstream `% 64: 16, expected 0` (with and without a preloaded add-on).
8. **★33 `5db923abc6` new thread's TLS vector at the current generation** — upstream tlsreload `read 0 after setting
   1234` (tlsunload passes upstream on x86).
9. **★38 `12eb998a63` real `strtold()`** (x87: 64-bit mantissa, range to 1e4932) — upstream had double precision.
   **With R3's fix `c8c59043a7`**, which also fixes upstream's strtod/strtof rounding-overflow errno.
10. **★39 `73ba44df00`, `69c0374b42` strtod edge cases** — upstream loses the sign of `-0`/`-nan`, ends `nan(0x123)`
    early, rounds `0x1p-1075` up.
11. **★40 `f0a1d5f5cf` setrlimit() of a fixed limit to its current value** — upstream EINVAL for 5 limits; visible
    even in coreutils (`timeout: warning: disabling core dumps failed`).
12. **`127fb34239` poll() keeps the caller's events** — upstream writes 0x1085 into `events`.
13. **★32 `25c9881600`, `58022c954a` own host name without DNS** — upstream: own name fails after 7 s
    (gethostbyname) / 28 s (getaddrinfo); ours 3 ms.
14. **★45 `a9db442988` block cache sub-transactions** — bfsmeta 74 vs 1527 µs per file (≈ 20×; one run each, side by
    side; the timing set did not repeat it).
15. Features x86-64 gains and upstream lacks: **DT_RELR** (`4539cd2f00`; upstream crashes on a DT_RELR binary) and
    the **team memory barrier** syscall (`1582c223b0`; N/A upstream).

16. **Speed, the tree as a whole** (§9.3, 5 runs each against upstream at the same `KDEBUG_LEVEL`): desktop ≈ 0.9 s
    sooner after the kernel starts; application starts and dlopen faster (dlopen of libtracker 1.65×, warm 2.9×;
    likely `-Bsymbolic-functions`/`--hash-style=both`); thread creation with stacks faster (`ecab951764`). Not
    attributed to single commits.

**Did not reproduce on x86-64** (no evidence either way for x86 users): ★53 pmexit (0/400 on both), tlsunload (★33's
other case), mprotect-unprotect-retry (★26 is arm64), castest (x86 CAS is strong), bitmapcheck (identical).

**Not run on x86-64** (still only arm64 evidence, or none): USB data disk on EHCI and the 1 GB USB copy (USB was
only a boot disk), SD (`--sd`, sdhci-pci), RNG statistics, MEDIA (intel-hda, tswatch), DBG (Debugger CLI, DWARF 5,
`profile`), the xHCI ring changes beyond booting from and typing on xHCI, WiFi, Bluetooth, real hardware of any kind,
an x86 network boot (R2's other branch), the GCC 16.2 x86-64 build (phase 2b).

### 9.6 Checklist state

- [x] strtold x87, bootscripts per group, `x86-grade.sh` (exit status before any pipe)
- [x] §4.4 steps 2–5 (BOOT/PWR/NET, THR/TLS/LIBC/VM, FS, APP) on ours and upstream; USB as boot disk only
- [x] step 6 timing (§9.3)
- [x] phase 4: four fixes on `x86-fix` (pushed, not merged), arm64 compile-checked
- [ ] not run: SD, USB data disk, RNG, MEDIA, DBG (§9.5)
- [ ] merge `x86-fix` into rpi4 after an arm64 run (QEMU virt + a Pi FS run for R1)
