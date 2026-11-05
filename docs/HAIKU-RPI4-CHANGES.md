# What this fork changes in Haiku

**Audience:** Haiku developers, and anyone deciding what to take from this port. **Purpose:** to show,
without reading every commit, what the Raspberry Pi 4 fork changes in Haiku and which of those changes
apply beyond this board.

The fork is [haiku-pi/haiku](https://github.com/haiku-pi/haiku), branch `rpi4` (cloned into
`sources/haiku` by `scripts/bootstrap.sh`). Its remote `upstream` is official Haiku and `origin` is
haiku-pi/haiku. The branch starts from upstream **hrev60262** (committed 2026-10-17). Upstream was
merged into it on 2026-10-19 (`29b623181d`, 21 upstream commits), on 2026-10-24 (`2a0cb4ac45`, 20 more)
and on 2026-10-31 (`e500bbf968`, 22 more), so the merge base is now **hrev60314** (`c9859af553`, 2026-10-30).
Upstream is merged again every weekend; see [log/](log/).

On top of that base the fork carries **294 commits of its own** (2026-10-18 to 2026-11-05; counted
2026-11-05 at `rpi4` f032832df7). To list them, in `sources/haiku`:

```
git log --no-merges $(git merge-base rpi4 upstream/master)..rpi4
```

The commit messages are detailed and are the authority; this document summarises them. Hashes below
are the 10-character short hashes from that list.

## Scope

The raw diff against the merge base is **363 files, +51 345 / −1 624 lines** (2026-11-04). Three blocks in it were
not written here:

| excluded | lines | what it is |
|---|---|---|
| `headers/private/drivers/drm/` | +3 594 | Mesa's MIT copies of the Linux DRM and v3d uAPI headers, so Mesa's v3d driver can be used unchanged |
| `drivers/network/wlan/broadcomfmac/dev/` | ~+6 400 | OpenBSD's bwfm driver, ported (the Haiku glue around it is ours) |
| `libroot/posix/string/arch/arm64/arm-optimized-routines/` | +2 488 | Arm Optimized Routines' memory and string functions, vendored unmodified with their licence (`2c93aeea48`) |

The hand-written surface is therefore roughly **39 000 lines**, most of it new drivers in new
directories. Of the 254 commits, 37 change the list of binary packages the arm64 build uses
(`build/jam/repositories/HaikuPorts/arm64`), 34 of them changing nothing else; they are collected in
one table at the end. The GCC 16.2 work (§13) appears twice in `git log`: its branch was merged once
and its four build fixes were also rebased onto rpi4 (`3c641a2b01`/`775c2e8a5e` and so on), the same
changes under two hashes.

**x86-64.** About 120 of these commits change code that x86-64 also compiles and runs (kernel, VM, runtime loader,
libroot, BFS, block cache, kits, servers). On 2026-11-04 the tree was built for x86_64 (`@nightly-anyboot`, GCC 13.3)
next to upstream hrev60314 and tested under KVM ([design/x86-64-check.md](design/x86-64-check.md)): it builds without
new warnings, boots by UEFI and BIOS, and four regressions it caused there were fixed (`3a0be104e3`, `444704d5f1`,
`c8c59043a7`, `a2cf89efd1`). Fourteen tests that fail on upstream x86-64 pass with our fixes (★ rows 20–22, 32, 33,
38–41, 43, 45, 52 and others: a kernel panic on `read()` into a guard page, MAP_SHARED after mprotect+fork, rw_lock,
the kill race, TLS alignment, strtod/strtold, setrlimit, poll, own-hostname lookups, BFS metadata writes), and it boots
and starts programs faster under KVM (kernel → desktop 4.3 vs 5.2 s).

The changes fall into three kinds:

1. **Fixes to existing Haiku code that are not Pi-specific.** They are marked **★** and listed
   together directly below.
2. **Changes that let existing code run on this SoC**: EFI loader at EL2 under U-Boot, device tree
   address translation, a non-coherent DMA world, a GICv2.
3. **New drivers** for the Pi 4's on-board hardware.

Where a later commit replaced an earlier one, only the surviving state is described, and the entry
says so.

## ★ Start here: fixes that are not Pi-specific

Each of these is a defect or gap in code upstream ships, found because this port exercised it. The
section for its area gives the detail.

| # | defect | commit | effect |
|---|---|---|---|
| 1 | **arm64 spin-waits livelock on cores without LSE atomics** | `0db3ca639d` | `cpu_wait()` polled a cache line that another CPU was updating with load/store-exclusive loops, so the other CPU's store-exclusive kept failing. Two CPUs with interrupts off stalled for 10 ms to over a minute. Fixed as Linux does it: wait in WFE, bounded by the timer event stream. Any Cortex-A72-class core is affected. |
| 2 | **`ASSERT()` with side effects** | `55348c5c46` | arm and arm64 fetched the signal handler's address inside `ASSERT()`, and the FDT bus manager fetched each device's node and bus driver inside `ASSERT()` (9 places). At `KDEBUG_LEVEL` < 2 every signal handler and every FDT device would have used garbage. |
| 3 | **arm64 kernel stacks could fault inside the exception vector** | `dc849a150b` | The access flag and dirty state are managed in software. A fresh kernel stack page whose first access was the exception entry code storing an iframe faulted inside the vector, recursively. |
| 4 | **arm64 counted user time as kernel time** | `24b4e36dcf` | Only system calls ran `thread_at_kernel_entry()`. A pure Python loop showed user 0.013 s, sys 4.32 s; now user 4.17 s, sys 0.19 s. |
| 5 | **arm64 had no in-kernel stack traces** | `4413675f5c` | `arch_get_stack_trace()` was a stub, so `profile -k` put every tick in the commpage. |
| 6 | **Spinlock deadlock detection counted iterations** | `a46a16641e` | 100 million iterations; once an iteration waits in WFE the check fired after hours. Now 5 s (100 s for `_nocheck`), and a stuck synchronous ICI panics after 10 s. |
| 7 | **`device_manager` `get_next_child_node()` returned only the first child** | `81deb24f8c` | The skip loop never stopped at the previous child, so iterating past the first always gave `B_ENTRY_NOT_FOUND`. |
| 8 | **SDHCI acknowledged interrupts with `\|=` on a write-1-to-clear register** | `23f6235b0d` | A "transfer complete" arriving right after "command complete" was cleared unseen and the read waited forever. Plus a 5-bit timeout field that has 6 bits, a card scanned twice, and a clock divider rounded the wrong way. |
| 9 | **FDT `reg` addresses were not translated through `ranges`** | `1c9c78289e` | Only nodes directly under the root got CPU physical addresses. |
| 10 | **GICv2 inter-CPU messages were not ordered against the SGI** | `4eb785f652`, `aa7da3b827` | No write barrier before sending and no read barrier after acknowledging, and SGI targets assumed to be `1 << cpu`. GICv3 and Linux already had the barriers. |
| 11 | **EFI loader at EL2 without VHE set up EL1, then overwrote it** | `022ca91504` | `_arch_transition_EL2_EL1()` replaced TTBR0/MAIR/VBAR_EL1 with the EL2 values, and secondaries started with `TTBR0_EL1 = 0`. |
| 12 | **EFI `ip=` parsing looped forever** on any other load-option key | `d8dfb51d8d` | Only an `ip=` alone worked. The net mask and (`f316d4920e`) the gateway are now passed on. |
| 13 | **`remote_disk` could not open its partitions** | `a082ab4d4e` | No file system on a remote disk was ever identified, so booting from one panicked. |
| 14 | **Network boot deadlocked when a network module was loaded from the boot volume** | `cea07d5468` | Fixed by keeping the network modules loaded. |
| 15 | **`BTimeSource` conversions in `float`** | `c41702df18` | A time more than 2^24 µs from the last published one stopped the program in the debugger. |
| 16 | **The arm64 debug console read 0xff forever** | `b3a08271be` | "No input" (-1) became 255 because `char` is unsigned on AArch64. |
| 17 | **PL011 output could hang the system** | `f5650324d6`, `80a6e1f2fb` | The loopback test left the line at 5 data bits when the clock was unknown, and `PutChar()` waited for FIFO room without a limit. |
| 18 | **The page writer left a device's last modified pages unwritten** | `1539d29eee` | Since the per-device page writers (`3bfaa91290b`), a timeout of the 3 s wait went straight back to waiting, so up to 1 MB of a file stayed unwritten until a sync, and a power cut lost it. A 111 kB file was not on the disk after 60 s; now within 5 s. |
| 19 | **`IORequest` iterated by recursion and overflowed the kernel stack** | `90fa3bc401` | With synchronous I/O (a device without an `io()` hook, such as `remote_disk`) each round of up to 8 file vecs added a stack level. The page writer panicked writing back a fragmented file. |
| 20 | **`lock_memory_etc()` panicked on a partly wirable range** | `6f810ed2d7` | Any program could panic the kernel ("VMArea::Unwire(...): no such range"), for example with a `read()` into a buffer that runs into a `PROT_NONE` page. |
| 21 | **`MAP_SHARED` file mappings lost their sharing across `mprotect()`** | `894c4abe7f` | `mprotect()` dropped `B_SHARED_AREA`. After a `fork()` and one more protection change, writes through every shared mapping of the file went to private pages and never reached the file. Wine's wineserver depends on such a mapping. |
| 22 | **A fault whose signal is blocked or ignored repeated for ever** | `6e517bb52c` | The thread returned to the faulting instruction and faulted again, millions of times a second; a fault inside a signal handler does this. The signal is now unblocked and reset to its default first, as Linux's `force_sig_fault()` does. |
| 23 | **The profiler left a timer armed on a CPU** | `5180e96119` | When a team's debugger went away while one of its threads ran on another CPU, that CPU's profiling timer stayed scheduled. The timer list then linked a timer to itself (a hang with interrupts off), or `profiling_event()` dereferenced NULL. `profile -f -k` of Wine did one or the other on its first run. |
| 24 | **PCI I/O BARs had host address 0 on every architecture but x86** | `cafef4f9bb` | `pci_ram_address()` translates memory ranges only. On QEMU's arm64 virt machine virtio-blk-pci and virtio-net-pci both drove port 0, and the disk stopped working. |
| 25 | **A failed `fork()` panicked on arm64** | `e2aefd5d96`, `c8f3757b45` | A user translation map gets its page table at its first mapping. Destroying, or unmapping from, a map that never had one freed or walked "the table" at physical address 0. |
| 26 | **arm64 `mmap(PROT_WRITE)` mappings faulted for ever** | `8a7946ae00` | The access permissions cannot express write-only, so every user store faulted and the handler returned to it. Write now implies user read, as on Linux. |
| 27 | **arm64 user reads of the ID registers raised SIGILL** | `7225a5f244` | Wine, Box64 and FEX read the CPU's features with `MRS`. The reads are now emulated as Linux does. |
| 28 | **`remote_disk` was published on every boot** | `8f0df61a1c` | An SD-booted system looked for a remote disk server too. The kernel now keeps the boot method as a boot item, and the driver loads only on a network boot. |
| 29 | **A Bluetooth L2CAP response to an unknown request panicked the kernel** | `b0ea06deaf` | The connection and disconnection response handlers called into a NULL endpoint, so a remote device could panic the kernel. A laptop unpairing (BlueZ) did it 2 times in 2. |
| 30 | **Bluetooth tools and kit** | `02e02d4ba3`, `0c12640aa2`, `d226612219`, `3cad4e2996` | `bt_discovery` did not compile, and then waited for ever for the end of its inquiry. Both tools printed a `BString` through `%s`. libbluetooth printed "CALLED ..." in every release build. bluetooth_server left a PIN code window open for each failed pairing, and dereferenced NULL on a disconnection with an unknown handle. |
| 31 | **xHCI left completed TDs' TRBs on the ring** | `c65ac5a2e6` | Haiku's rings never toggle the cycle bit (a cleared TRB marks the end), so old entries past the stop marker still look valid. A controller that prefetches TRBs, as the VL805 does, can replay them. Clearing completed entries is generic; the overfetch padding is for the VL805. On the Pi 4 the USB hub stopped answering in about 1 boot in 10; now 0 in 40. |
| 32 | **No ICMPv6 errors: lookups without DNS waited ~14 s** | `25c9881600`, `58022c954a` | IPv6 never sent Destination Unreachable (stubs) and dropped the ones it received, so the resolver's query to `[::]:53` on a machine without name servers ran into its time-outs; Firefox waited 14 s at every start. ICMPv6 errors are sent and delivered now, and the host's own name resolves from the hosts file's localhost entries. |
| 33 | **A new thread's thread-local variables reset after any library unload** | `5db923abc6` | The runtime loader gave a new thread's TLS vector generation 0, so after a dlclose() of any library with TLS its second TLS access threw the blocks away (Mesa crashed on a second Vulkan instance). |
| 34 | **arm64 sigreturn restored the whole SPSR from user memory** | `4cd6f504f8` | A program could return to EL1 (SPSR.M), with interrupts masked or with any step state, by editing its signal frame. Only the user settable bits are taken now. |
| 35 | **Continuing from a software breakpoint could disarm the breakpoints of a team** | `40adafebe9` | The hardware breakpoint `PrepareToContinue()` puts in place of a software one never got loaded when the team had none before (its threads' `THREAD_FLAGS_BREAKPOINTS_DEFINED` stayed clear): the thread ran past every later hit. |
| 36 | **The Debugger's "step out" never stopped on arm64** | `88b487e15b` | It compared the frame address (the CFA) with the frame pointer at the return address, equal on AArch64. |
| 37 | **A secondary CPU could start the kernel as a second CPU 0** | `eb4bdd0ea4` | The EFI loader zeroed the secondary CPUs' stacks with its caches on and only cleaned them; a secondary, writing its CPU index there with its caches off and reading it back with them on, could read the stale zero line: two "CPU 0"s on one stack, a panic right after `ExitBootServices()`. Latent in every arm64 build; GCC 16 (which keeps the index on the stack) hit it in ~1 boot in 5. |
| 38 | **`strtold()` was `strtod()` on every architecture** | `12eb998a63` | A 1999 glibc stub: long double parsing had double precision (binary128 on arm64, x87 on x86). Now glibc's template for long double; `wcstold()` and `scanf("%Lf")` follow. |
| 39 | **`strtod()` edge cases** | `73ba44df00`, `69c0374b42` | `"-0"`/`"-nan"` lost their sign, `nan(...)` left the end pointer on the `)`, a NaN payload cleared the quiet bit, an exact half-subnormal rounded up, underflow to zero set EDOM and dropped the sign. As current glibc. |
| 40 | **`setrlimit()` refused every fixed limit** | `f0a1d5f5cf` | Even a request equal to what `getrlimit()` reports (e.g. `RLIMIT_CORE` (0, 0) before a crash test) was EINVAL. |
| 41 | **libroot's `rw_lock` kept a lock it never noticed it got** | `2bf2f773ba` | `rw_lock_wait()` retried an interrupted `_kern_block_thread()` with the wait status the interruption left, so it returned at once for ever and missed the wake-up of the hand-off: the spinning waiter held the lock and every other thread waited (BLooperList: an application frozen at window creation). Any interruption of the wait does it, on every architecture; `rw_lock_interrupt_test` shows it. |
| 42 | **arm64 threads entered userland with a signal pending** | `5d9132a49c` | `arch_thread_enter_userspace()` skipped the kernel exit work x86 does: the `resume_thread()` that starts a thread leaves a signal pending, which interrupted the thread's first wait (hidden while its first stack touches faulted; exposed by stack reuse, `ecab951764`). |
| 43 | **A dying team deleted an exited thread's stack while its other threads still ran** | `e09cfa1d9e` | The thread that takes a team-ending signal (SIGTERM) exits at once; its stack area was deleted before the main thread had killed the others, which may still use objects on it (a pool's idle list with entries on each idle thread's stack): a segment violation in a team already going down. The area now goes with the team's address space while the team is going down; `killrace` test 20/20 faults → 0/30. |
| 44 | **Image notifications lost their pointer on 64-bit** | `f6c52282df` | The image monitor event was built in 128 bytes; two int32 fields and the `imageStruct` pointer need 132 with 64-bit pointers, so the pointer was left out and the system profiler dropped the event: `profile -a` could not resolve any program started after it (65 % of a desktop session's busy ticks "unknown"). Every 64-bit architecture. Pi: unknown ticks 14.13 % → 0.01 %. |
| 45 | **Each BFS write walked the whole open journal transaction** | `a9db442988` | `cache_start_sub_transaction()` visited every block of the combined transaction (up to half the log, 2043 blocks) at every sub-transaction start: O(n²) per combined transaction, 0.6–1.0 s of CPU in a Firefox first start on the Pi 4. It now visits only the blocks changed since the previous start; the same disk writes in the same order (power-cut and disk-full tests, a check build comparing with the full walk). Every architecture, every journaled block-cache user. |
| 46 | **xHCI did no cache maintenance for physical (disk) transfers** | `eabad7a921`, `b90cb3f0d4` | usb_disk hands the controller its callers' memory directly; on a controller that does not snoop the CPU caches (the Pi 4's VL805 behind PCIe) reads returned stale data and writes stored stale memory, silently. The xHCI driver now cleans and invalidates each fragment before the controller sees it and again after an IN transfer; usb_disk keeps buffers 64-byte aligned on arm64 (misaligned ones are bounced, a shared cache line would be overwritten). Assumes non-snooping on all arm64, as the stack's own DMA memory already does. |
| 47 | **`atomic_test_and_set()` used a weak compare-and-swap** | `88be53559b` | A spurious store-exclusive failure returned the expected value, as success, without storing: two owners of a lock. Latent with GCC's default outline atomics (their helper retries; no store-exclusive without a retry in our build), real without them (32-bit ARM, `-mno-outline-atomics`). From RenkuOS #189 ([design/renkuos-fixes.md](design/renkuos-fixes.md)). |
| 48 | **launch_daemon's environment pipe leaked into jobs started meanwhile** | `fb4e339ce8` | A job another worker thread started while an `env` script was being read inherited the pipe's write end, and the read waited until that job exited: for a server, for ever (no desktop). Now `pipe2(O_CLOEXEC)`. From RenkuOS #231. |
| 49 | **arm64 could not power off or restart** | `c7509f4229`, `0b22f22f5b` | `arch_cpu_shutdown()` was a stub: "Shut down" ended in the kernel debugger and "Restart" did not restart. Now PSCI `SYSTEM_OFF`/`SYSTEM_RESET` when the firmware offers PSCI (RenkuOS #160), else a platform driver's hook; on the Pi (no PSCI under U-Boot) the PM watchdog. |
| 50 | **A failed BFS mount panicked the kernel** | `9799738757` | When the root node of a damaged volume could not be read after the block allocator had repaired the bitmap in a transaction, `Volume::Mount()` returned without deleting its journal; the device opener then deleted the block cache under the open transaction and `block_cache_delete()` panicked in `FreeBlock()`. The mount now waits for the allocator and deletes the root node and journal on every failure path: "Invalid argument" instead of a panic (host `bfs_shell` and Pi). Every architecture; upstream master has the same code. |
| 51 | **usb_disk ignored the host controller's DMA limit** | `61fe84cd93` | usb_disk let the DMA resource use buffers up to 4 GiB; a controller behind a PCIe window that reaches less (the Pi 4: 3 GiB, published as `B_DMA_HIGH_ADDRESS` by the PCIe driver) received addresses it cannot reach — reads returned nothing, without an error, and a later write stopped the controller. It now takes `B_DMA_HIGH_ADDRESS` from the device node's ancestors, and the DMA resource bounces higher buffers. |
| 52 | **Thread-local variables with a large alignment were misaligned** | `4d433669a8` | The runtime loader allocated a dynamically created TLS block with plain `malloc()` (16-byte aligned) whatever alignment the PT_TLS segment asked for, so an `alignas(64)` `thread_local` landed at 32 or 48 modulo 64. Blocks are now allocated with room to align. Every architecture. |
| 53 | **Programs crashed while quitting: libbe freed its message cache under a running looper** | `a779571e90` | `terminate_after()` runs from `exit()` while the team's other threads still run; BPathMonitor's looper is never quit and keeps creating and deleting messages, so deleting `BMessage`'s block cache there made it fault on a NULL cache (Tracker during a shutdown, whose crash alert then stopped the shutdown). The cache is now left to go with the team. Reproducer `pmexit`: 11/1000 → 0/1000 on the Pi, 6/400 → 0/400 in QEMU (arm64 `virt`; x86-64 untested until H22). Every architecture; upstream master has the same code. |
| 54 | **usb_disk's teardown could deadlock with its own I/O thread** | `d3cc8e3fd1` | `usb_disk_uninit_driver()` deleted each LUN's I/O scheduler while holding the device lock; that waits for the scheduler thread, which needs the same lock in `usb_disk_do_io()`. With reads queued when a stick drops off its port, both wait forever, and on the USB explore thread every later driver registration blocks too — the most consistent explanation of one stalled boot (not reproduced: 40/40 + 20/20 clean). Schedulers are now deleted before the lock is taken, and I/O for a removed device fails at once. Upstream code. |
| 55 | **A page fault on a file read one 4 KiB page per disk request** | `a38b19efab` | Programs fault their pages in scattered over their files, so a cold start from a plain file system was bound by per-request cost (0.59 ms per 4 KiB on the Pi's card: 8–10 MB/s). A fault that misses the cache of a file on a disk partition now reads the run of missing pages around it within its 64 KiB cluster in one request (as FreeBSD's `vm_fault`), only with pages reservable without waiting, and re-reads the faulting page alone on error; packagefs keeps its own chunked read. Firefox from a BFS folder, cold: 14.05 → 8.36 s; x86-64 (KVM): a 108 MiB library 560 → 80 ms. Every architecture. |
| 56 | **The system launch_daemon restarted services during a shutdown** | `f49813a540` | Its "shutdown in progress?" check went through a BRoster, which finds the registrar by asking the launch_daemon — refused on its own main thread — so the check always failed and every service that ended during a shutdown was started again. When a shutdown waits (a crash alert), package_daemon was restarted, refused by the registrar and restarted again every 25–110 ms. Now the system launch_daemon asks its registrar job's port directly (1 s timeout). KVM: guard test 4/4 relaunched → 0/2, loop 5/8 → 0/6. Upstream since 0749734769 (2019). |
| 57 | **`rm -rf` could deadlock BFS against a running `sync`** | `44cc183c0c` | `bfs_io()`'s finished hook dropped the I/O's vnode reference with `put_vnode()` in the I/O scheduler's notifier thread; for a file unlinked meanwhile that deleted the inode there and started a transaction, waiting for the journal held by `rm`, which waited for an inode lock only the notifier could release. Now `vfs_put_vnode()` hands the deletion to the vnode undertaker. KVM: 6/25 hangs → 0/50 (p ≈ 9·10⁻⁴). Upstream since 551a9b9a01 (2024) ([design/bfs-rmrf-hang.md](design/bfs-rmrf-hang.md)). |

Also generally useful, though new code or speed-ups rather than fixes: serial-console emergency keys
(`8eca4824c9`, `aa1366f629`), FDT `get_dma_window()` (`08e65e6449`, `f2e5b2fab8`), SD high speed /
UHS-I / SDIO in the MMC stack, ADMA2 in sdhci, a pipelined `remote_disk` in both the loader and the
kernel (reads and writes), WPA-personal joins without the wpa_supplicant in openbsd_wlan, the CPU
clock measured with the PMU on arm64, an arm64 back end for the Debugger (`ad9b5551c8`) and user
debugging on arm64 — breakpoints, single-stepping, watchpoints, a disassembler (`f753f072d8`,
`721732e47f`), Arm
Optimized Routines in libroot (`2c93aeea48`) and for `user_memcpy()` (`3a0ccc321f`), a faster
`__tls_get_addr()` on arm64 (`076da9813a`), shorter boot-time device scans (`c82925eeb9`,
`afb2823bb5`), and SavedClock for boards without a real-time clock (`0ce0612c25`).

---

## 1. Boot chain: EFI loader, early serial, finding the boot volume

The Pi 4 boots firmware → U-Boot (EFI) → `haiku_loader.efi`. U-Boot enters the loader at **EL2
without VHE** and releases secondary CPUs from a **spin table**. Neither case had been exercised by
Haiku's arm64 loader before. All entries here are ★ except the first, which is generic code that only
this board's console layout happened to reach.

| commit | change | what and why |
|---|---|---|
| `9678b4cd65` | Map a debug UART that is not page-aligned | The BCM2835 mini UART's registers sit at offset 0x40 of the AUX block. `map_region()` needs page alignment, so the loader panicked with "Too many levels at mapping". It now maps the containing pages and keeps the offset. |
| `022ca91504` ★ | Set up EL1 after dropping from EL2; flush the spin-table release | The EL1 translation regime was programmed and then overwritten by the EL2→EL1 transition. The boot CPU kept U-Boot's MAIR (different attribute indices), and a secondary enabled its MMU with `TTBR0_EL1 = 0` and hung `smp_cpu_rendezvous()`. The loader now drops to EL1 first. The release address is also cleaned to the point of coherency, because spinning CPUs read it with caches off. |
| `d3c5064bd0` ★ | Clean the data cache before releasing secondaries | Secondaries start with caches off and read `sCpus`/`sSecondaryStacks`, which the boot CPU wrote with caches on. |
| `9148d14cac` ★ | `CNTKCTL_EL1` after the EL2 drop | It was set only for EL1 or VHE entry. Its reset value traps EL0 counter reads, so `launch_daemon` died at its first `system_time()`. |
| `a6502fab74` ★ | Keep the firmware's UART setup when its clock is unknown | The Pi's PL011 clock comes from a clock controller, so `dtb_get_clock_frequency()` returns −1. The loader then programmed a divisor from 0xffffffff (about 1300 baud), garbling everything after `ExitBootServices()`. |
| `bce76d6e73` ★ | Wait for a boot device that is published late | SD (the MMC bus scans in its own thread) and USB disks could appear after the boot partitions were searched, so boot failed with "did not find any boot partitions". The kernel now rescans for up to 10 s for a strict match before falling back to a looser one. |
| `daaaf7a848` | The loader caches the last decompressed package chunks | The loader has no file cache, and an ELF image is read in many small pieces (headers, segments, symbols). Each piece read its compressed 64 KiB chunk again and decompressed all of it. The package heap reader now keeps its last eight chunks (boot mode only). Loading the kernel and boot modules from SD went from 2185 device reads (15.4 MB) and 666 decompressions to 728 reads (4.7 MB) and 180. Together with U-Boot's EMMC2 fix ([../patches/u-boot/](../patches/u-boot/)), the loader's part of an SD boot fell from 3.1 s to 1.2 s. Not Pi-specific. |
| `850a1d7e52` | The loader's partition-scan trace and arm64 memory-map dump off the console | 52 of the loader's 85 serial lines, sent synchronously at 115200 baud: 0.6 s of its 1.0 s from banner to kernel on a Pi 4. |
| `e944a1ab38` ★ | Set up `MDCR_EL2` when dropping to EL1 | Its reset value is partly unknown and neither the firmware nor U-Boot sets it: EL1's accesses to the debug and PMU registers could trap to EL2 and debug exceptions be routed there. Now no traps, debug exceptions at EL1, all event counters for EL1 (HPMN = PMCR_EL0.N), as Linux sets it. Needed for user debugging. |
| `eb4bdd0ea4` ★ | No stale cache lines for the secondary CPUs' stacks | The secondaries start with caches off, write to their stacks, turn the caches on and read back: the boot CPU zeroed those stacks cached and only cleaned them, so a line could still be in the shared cache and shadow what a secondary wrote — with GCC 16, which keeps `arm64_secondary_startup2()`'s CPU index on the stack, a second "CPU 0" entered the kernel on CPU 0's stack (2 boots in ~13; FP/LR popped as 1920/32 from a frame record the other CPU overwrote). The stacks are now cleaned and invalidated before the release, and the index is looked up again from MPIDR_EL1 once the caches are on. 0 early panics in 24 boots since. |

### Network boot (remote disk)

Haiku boots from the network by mounting a **block device served over UDP** (`remote_disk`), not an
NFS root. U-Boot loads the EFI loader by TFTP and passes `ip=`; the loader and the kernel then read
the image from the host's `remote_disk_server`. See [design/netboot.md](design/netboot.md). This
path was broken in several places on arm64. After these commits a Pi 4 reaches the desktop in about
55–60 s, with nothing written to the SD card. All are ★ except `b294857151`.

| commit | change | what and why |
|---|---|---|
| `b294857151` | Boot modules for an arm64 remote-disk boot | `remote_disk`, `genet` and the whole network stack become boot modules on arm64. All network modules are included, because one loaded later from the remote disk can deadlock (next-but-one entry). |
| `a082ab4d4e` ★ | `remote_disk` opens partitions | devfs opens `disk/virtual/remote_disk/0/1` under its own name, which the driver did not recognise. No file system on a remote disk was ever identified. Also fixes tracing format strings that did not compile on 64-bit. |
| `cea07d5468` ★ | Wait for the link; keep network modules loaded | (1) A PHY starts negotiating only when the device is opened, so the remote disk's first request failed with "Network is down". The kernel now waits up to 20 s for link. (2) Unused boot modules are unloaded after mount. A module needed later was then read through the stack while the stack held the lock the read needed: `getaddrinfo()` held an interface lock, the stack loaded a datalink module from the remote disk, and the disk's reader waited for the interface. The desktop never came up. |
| `cb0f2f9884` ★ | net_server leaves a network-boot interface alone | It started DHCP on the interface the boot volume is reached through, which can take that address away. An interface that already has IPv4 at start is left as it is. |
| `444704d5f1` | net_server leaves a configured interface alone only on a network boot | After a net_server restart on a disk boot the DHCP client was never started again (found on x86-64, R2); the network-boot case is unchanged. |
| `d8dfb51d8d` ★ | EFI `ip=` parsing; pass the net mask | Any load-option key not two characters long made the search for `ip=` loop forever. The fourth field (net mask) now reaches the kernel; without it the mask was chosen by address class. |
| `f316d4920e` ★ | Default route through the gateway | The network-boot default route had no gateway, so every off-link address was treated as on-link. The loader takes the gateway from `ip=` and the kernel routes through it. |
| `b1ddc00b1f` ★ | Kernel `remote_disk`: 16 requests in flight | It sent one 1 KiB request and waited for the reply before the next, so the boot volume read at round-trip time. Requests are told apart by ID, resent every 0.5 s while overdue, and given up after 25 s. Desktop ~90 s → ~70–80 s, 8/8 boots, package checksums equal to the host's. |
| `e1fe4f62bd` ★ | Loader remote disk: 8 requests in flight | The same for the loader, capped at 8 because the firmware's network driver buffers few frames. The loader's part 25 s → ~5.5 s; desktop ~60 s. |
| `8f0df61a1c` ★ | `remote_disk` only on a network boot | The driver was published on every boot, so an SD-booted system looked for a remote disk server too (and showed its disk if one was on the LAN). The kernel arguments that say how the system booted are gone by then, so the kernel now keeps the boot method (`BOOT_METHOD_*`) as the boot item "boot method", and the driver's `init_hardware()` declines any other. |
| `84fd3835a4` ★ | Kernel `remote_disk`: writes pipelined too | A write sent one 1 KiB block and waited for its reply, so a network-booted system wrote at 2.9 MB/s over gigabit. Writes larger than a block now keep up to 16 requests in flight, as reads do, and are resent while overdue (a write at an offset can be repeated). 200 MiB written and synced in 3 s (was ~74 s); Wine's packages installed in 42 s (94); a new Wine prefix (~1 GB) in 61 s (387). |
| `13f5af2f89` ★ | `remote_disk` looks for its server with a 1 s reply timeout | The hello broadcast goes out as the link comes up; a lost one cost the 5 s request timeout. In about half of the Pi's network boots the boot volume came 5-9 s after the link; now within 40 ms (6 of 6). |

**Fixed (d1a616afac):** a Pi booted after being off for a while could freeze in its first minutes. The kernel's
empty TTBR0 table (installed for every kernel-only thread) came from the early page allocator, which does not clear,
so the CPU walked whatever the RAM held: garbage after a long power-off. Upstream regression 593f25d6f1e. The kernel
now clears it. The page is the first one above the loader's data: the loader's PE header page on an SD boot (which
U-Boot copies only 0x278 bytes of; the loader clears the rest at entry, f593b2ae43, and U-Boot patch 0004 copies it
all) and a U-Boot pool page on a network boot (U-Boot patch 0005 clears EFI pages); those stay as hardening. Found
with a U-Boot that fills RAM with random data before booting and a page bisect: warm boots froze 3 of 3, alive 3 of
3 with the kernel fix alone. `a46a16641e`, `80a6e1f2fb`, the `debug_heartbeat` setting (`775c21f7fb`) and the
brcmstb link options (`9cb5647ea4`) were written while hunting it; `a8daa2c23b` (the cpufreq driver's request
order) was taken for a fix and is not one. The hunt: [log/WEEK-2026-W44.md](log/WEEK-2026-W44.md), 10-29 to 11-02. Confirmed 11-03: 10 of 10 boots of image-2026-11-03 from the card after 30 minutes off each, alive (before the fixes up to 2 in 3 froze).

---

## 2. Kernel: arm64 core

Nearly everything here applies to any arm64 board. The Pi 4 found it because its Cortex-A72 has no
LSE atomics and no hardware access/dirty flags, and because it is real hardware with real interrupt
load, which QEMU did not provide. The last subsection is code that every architecture uses.

### Memory management and caches

| commit | change | what and why |
|---|---|---|
| `9e2efe1eff` | `arm64_dcache_clean_range()` / `arm64_dcache_flush_range()` | Helpers to write back (and discard) a virtual range, for drivers of devices that do not snoop the CPU caches. On the Pi 4 that is every device on the VideoCore bus, PCIe included. |
| `dc849a150b` ★ | Map kernel stacks accessed and dirty from the start | The A72 manages neither flag in hardware, so a fresh page faults on first access and on first write. On a kernel stack that first access can be the exception entry storing an iframe; the fault then happens inside the vector, and each nested exception stores to the same page again. A `KDEBUG_LEVEL` 1 build (smaller frames) panicked at boot with it. Kernel stacks are never paged out, so the flags carry no information there. It matched the shape of the network-boot wedge but did not cure it (a wedge 17 network boots later). |
| `8a7946ae00` ★ | A user write-only mapping is user-readable too | The access permissions cannot express write-only. Without user access an `mmap(PROT_WRITE)` mapping faulted on every user store, and the fault handler, finding writes allowed, returned to the same instruction: an endless fault loop (Wine's wineserver spun at 100 % CPU writing its shared data page). As execute already did, write now implies user read, as Linux maps it on arm64. |
| `e2aefd5d96` ★ | A failed `fork()` no longer panics | A user translation map gets its page table with its first mapping, but the destructor freed it unconditionally. Destroying an address space that never had a mapping (`fork_team()` failing early) freed "the table" at physical 0 and faulted at `KERNEL_PMAP_BASE`: a panic from a bash fork while Wine ran an x86-64 program. The same commit cuts user-exception logging (next table). |
| `c8f3757b45` ★ | No page-table walk before a user map has a table | `ProcessRange()` only asserted that the table address was not 0, which a release kernel does not check, and then walked from physical 0: `UnmapPages()` on a map that never mapped anything faulted at 0xffffff0000000000. It panicked when `fork()` failed under memory pressure and `fork_team()` deleted the child's areas. Every operation now treats a map without a table as empty. |
| `3a0ccc321f` ★ | `user_memcpy()` with Arm's memcpy | It used the kernel's generic C `memcpy()`, which copies one byte at a time when source and destination are not aligned alike, as for every `read()` at an odd file offset or into an odd buffer address. It now uses libroot's memcpy from Arm Optimized Routines (general-purpose registers only), built into the kernel as `arch_user_memcpy()`. It is not the kernel's `memcpy()`, because it makes unaligned accesses and that may touch device memory. `read()` of a cached file in 64 KiB pieces: into an aligned buffer 1718 → 2245 MB/s, into buffer + 1 630 → 2350, from file offset 1 630 → 2060. |
| `0fe465e233` ★ | The instruction cache line size in `arch_cpu_sync_icache()` | It computed the line size as `4 << (CTR_EL0 << 15)` instead of `4 << (CTR_EL0 & 0xf)`; the shift count wraps to 0, so the instruction cache was invalidated every 4 bytes, 16 times per 64-byte line, for every page mapped executable (every exec, every code page fault). It was 45 % of the time of starting a program. Also honours CTR_EL0.IDC and DIC. Pi 4: fork + exec 7.8 → 4.7 ms, posix_spawn 7.4 → 3.4 ms. |

### Exceptions and time accounting

| commit | change | what and why |
|---|---|---|
| `cdd63d4b62` ★ | Classify unhandled user exceptions | An undefined instruction, an alignment fault or another unhandled class left the exception type and signal number uninitialised, so a crashing thread got whatever signal was in the register. Each class now gets its proper signal, and the syndrome, fault address and PC are logged (since `e2aefd5d96` only when the signal ends the program). |
| `24b4e36dcf` ★ | Count user time on every exception from EL0 | `thread_at_kernel_entry()` ran only on system calls, while `thread_at_kernel_exit()` ran on every return. Timer and page-fault entries therefore billed the preceding user time as kernel time. It now works as on x86. |
| `7225a5f244` ★ | Emulate user reads of the ID registers, as Linux does | Programs read the CPU's features with `MRS` of the ID registers: Wine for the processor registry keys that Windows programs and x86 emulators read, Box64, FEX. An ARMv8.0 CPU makes such a read an undefined instruction, so the program got SIGILL. As in Linux (`cpu-feature-registers.rst`), MIDR_EL1 and the AArch64 feature registers are passed on, MPIDR_EL1 reads as on a uniprocessor, and every other register of the space reads as 0. |
| `e2aefd5d96` ★ | Log only the user exceptions that end the program | A program that handles its exceptions may take thousands (FEX's misaligned store-releases, Wine's write watches), and every logged line cost serial-console time. (The fork fix in the same commit is in the table above.) |
| `898d65974f` ★ | Log a user abort whose FAR is 0 | Diagnostic. A Box64 store to a valid address once reached Wine as a write fault at address 0. ESR and ELR are now logged when FAR is 0, which tells whether FAR was valid (ESR.FnV) and what the fault was. |
| `4cd6f504f8` ★ | Only the user settable SPSR bits from a signal frame | `arch_restore_signal_frame()` copied the saved SPSR into the iframe as it was: a program could return to EL1 or mask interrupts. NZCV, BTYPE, SSBS, DIT and TCO are taken from the frame, the rest stays the kernel's. |
| `f753f072d8` ★ | **User breakpoints, watchpoints and single-stepping** | The arm64 kernel had none of `arch_user_debugger.cpp`'s contract but reading registers. Software breakpoints are `brk #0` (PC at the brk; a `brk #0` the program wrote itself is hit, then continued after); 6 hardware breakpoints and 4 watchpoints (Cortex-A72; counts from ID_AA64DFR0_EL1; 1–8 bytes of a doubleword, reads, writes or both), matching at EL0 only; single-stepping with MDSCR_EL1.SS / SPSR.SS. MDSCR_EL1.KDE stays clear, so kernel entry is unchanged: a team's registers are loaded on the way back to userland when the CPU holds another set (a generation number; two loads and a compare otherwise). AArch64 has no resume flag, so a thread continuing at the PC it stopped at executes that instruction single-stepped with its break-/watchpoints off. CPU init unlocks the OS lock. BRK in a team without a debugger, other BRK immediates and kernel BRK behave as before. QEMU: tools/haiku-tests/armdbg.c 9/9 at EL1 and from EL2. |
| `5d9132a49c` ★ | **A new thread's pending signals are handled before it enters userland** | As x86's `x86_return_to_userland()`: `arch_thread_enter_userspace()` now does the kernel exit work (signals, debugger, core dump) before its `eret`. Without it the `resume_thread()` that starts every thread left a signal pending, so the thread's first interruptible wait returned `B_INTERRUPTED` — noticed only once threads reused the stacks of exited ones (`ecab951764`: no first faults any more), as SuperTuxKart's start hang ([design/stk-start-hang.md](design/stk-start-hang.md)). |
| `e09cfa1d9e` ★ | **An exiting thread's stack stays while its team goes down** | `keep_user_stack()` (was `put_cached_user_stack()`): when the team is shutting down or its exit status is set, an exited thread's stack area is left to the deletion of the team's address space, because the team's other threads still run until the main thread kills them (as Linux keeps a dying thread group's memory). Fixes a Firefox content process's segment violation at SIGTERM (~1 in 60 ends) ([design/firefox-contentproc-crash.md](design/firefox-contentproc-crash.md)). |
| `f6c52282df` ★ | Image notifications fit their pointer | 256-byte event buffer instead of 128: `profile -a` resolves programs started after it (design/perf-round-h20.md §6). |
| `a9db442988` ★ | **Sub-transaction starts look only at changed blocks** | The block cache keeps, per transaction, the blocks made writable or discarded since the current sub-transaction started; the start walks those (the full walk stays for the first start and after an abort/detach). `BLOCK_CACHE_CHECK_SUB_TRANSACTIONS` compares with the full walk. Walk CPU in a Firefox first start 616–1055 → 26–59 ms ([design/perf-round-h20.md](design/perf-round-h20.md) N6). |
| `9799738757` ★ | **BFS ends its journal before failing a mount** | A corrupt volume (unreadable root node, damaged bitmap) panicked the kernel in `block_cache_delete()` when its mount failed; now the mount fails with B_BAD_VALUE (was KNOWN-ISSUES C14, fixed in image-2026-11-04c). |
| `44cc183c0c` ★ | **BFS: the I/O finished hook leaves the vnode's last put to the undertaker** | Fixes a deadlock of `rm -rf` with a concurrent `sync` (row 57). |
| `a38b19efab` ★ | **Page faults read around the faulting file page** | Missing pages within the 64 KiB cluster are read in one request for files on a disk partition (not packagefs); mapped files fault in at 23–32 MB/s instead of 8–10, contents checked identical ([design/perf-round-h20.md](design/perf-round-h20.md) C2). |

### Interrupt controller (GICv2) and the CPU stall

This is the longest story in the fork. About half of all Pi 4 boots froze for over a minute, and
under SD load CPUs stalled for up to 760 ms. It first looked like the GIC: an SPI left active, and
CPU 0 taking nothing until another CPU touched the GIC. `5b2e85f498` added a watchdog that sent the
stuck CPU an SGI, and `f2bf1c9e87` moved the GIC setup to Linux's and tightened that watchdog to
25 ms. Neither removed the stall. **`0db3ca639d` found the real cause, an LL/SC livelock in kernel
spin-waits, and removed the watchdog and its diagnostics.** What survives:

| commit | change | what and why |
|---|---|---|
| `4eb785f652` ★ | Write barrier before sending an SGI | The message goes to normal memory and the SGI is a device store, which is not ordered after it, so the target could find no message. GICv3 and Linux already did this. |
| `aa7da3b827` ★ | GICv2 IPI ordering and CPU map; debug UART on every CPU | After acknowledging an SGI, read the message only behind a read barrier, because the acknowledge is a device read that does not order the normal loads that follow. Address SGIs by each CPU's interface bit, read from the banked target register, rather than `1 << cpu`. `RouteInterrupt()` lets a set of CPUs take an SPI. KDL commands `gic` and `arm64_timer`. The debug UART's interrupt goes to every CPU, so the emergency keys work while one CPU is stuck. (Its Ctrl-T freeze probe was removed by `5b2e85f498`.) |
| `5b2e85f498` | Barrier before WFI | Outstanding writes complete before WFI, as in Linux's `cpu_do_idle`. The stall watchdog this commit added was later removed. |
| `f2bf1c9e87` | GIC setup as Linux's GIC-400 code | Every interrupt at one priority (0xa0), set once: enabling an interrupt no longer read-modify-writes the priority word it shares with three others, one of which may be active. Priority mask 0xf0, active state cleared, the firmware's bypass bits kept. The watchdog part is gone. |
| `0db3ca639d` ★ | **Wait in WFE, not by polling** | CPU 0, notifying a condition variable from the SD interrupt, polled `fEntriesCount` while the waiter retried an atomic on the same cache line. With no LSE atomics, the atomics are LL/SC loops, and the polling loads kept clearing the waiter's exclusive monitor. As Linux does it: `cpu_wait()` waits in WFE on the line (`ldxr` + `wfe`); the generic timer's event stream (every ~152 µs) bounds every WFE; `try_acquire_spinlock()` tests before it exchanges; and an ISB follows timer register writes. Boot bench 10/10 without any watchdog, and a 10-minute QuakeSpasm + SD soak with no stall (it had ~400 before). `c805c1822d` removes a disproved rationale from the `arch_cpu_idle()` comment. |
| `70e77d8c29` ★ | Spurious interrupts are not reported | An SPI routed to several CPUs leaves the others the spurious ID 1023: normal, and each report went to the serial console (with buffered output, a self-feeding storm). Returns without an end of interrupt, as Linux. |

### SMP, spinlocks and deadlock detection

| commit | change | what and why |
|---|---|---|
| `a46a16641e` ★ | Deadlock detection by time | `acquire_spinlock()` and its read/write variants panicked after 100 million failed iterations. With WFE waits an iteration can take a fraction of a millisecond, so a stuck lock hung the system silently for hours. Now 5 s (the `_nocheck` variants 100 s). A synchronous ICI left unprocessed for 10 s panics too (there was no check). A gap of over a second between clock readings, for example a CPU halted in KDL, restarts the measurement. |

### CPU clock

| commit | change | what and why |
|---|---|---|
| `a669f3070c` ★ | Measure the CPU clock with the PMU cycle counter | `arch_get_frequency()` returned 0, so About and sysinfo said "@ 0 MHz". It now counts cycles over 100 µs of the generic timer on the CPU asked about (a cross-CPU call for another CPU) and keeps the result for a second. The core's default frequency is that measurement until SMBIOS or the device tree give one. Pi 4: "ARM Cortex-A72 @ 1.50 GHz". The same commit names the board in the thermal driver (section 11). |

### Hardware performance counters

| commit | change | what and why |
|---|---|---|
| `cdb7601f17` ★ | `arm64_pmu`: a driver for the PMUv3 counters, system-wide | `/dev/misc/pmu` programs the cycle counter and the event counters (6 on the Cortex-A72) and reads them on every CPU; the 32-bit counters wrap within a second at full rate, so a kernel thread samples them every 200 ms into 64-bit totals. The cycle counter stays shared with `arch_get_frequency()`; user-mode PMU access stays off; one opener at a time. Generic arm64, not Pi-specific. |
| `9b9b2a3bba` ★ | `pmustat`: count hardware events while a command runs | Like Linux's `perf stat -a`: cycles, instructions, L1D/L2 refills, branch mispredictions (or events by name; `-l` lists those the core implements), totals and rates with IPC, miss rates and the clock while busy; `-A` per CPU, `-u`/`-k` one mode, `-a SECONDS` without a command. |
| `d6580d9550` ★ | `arm64_pmu`: the cycle counter's filter cleared, sampling at urgent priority | PMCCFILTR_EL0 resets to an unknown value; cleared, the cycles are counted in user mode and the kernel. The sampler runs at `B_URGENT_PRIORITY`, so real-time threads cannot hold it off while a counter wraps twice. |
| `a6db106d27` ★ | `pmustat`: cycles counted in the measured mode for `-u` and `-k` | The cycle counter counts in every mode, so user- or kernel-only IPC was against all cycles (0.018 for `dd` in user mode). With a mode filter, `cpu_cycles` is counted on an event counter in that mode and IPC uses it. |

### Serial console and kernel debugging

| commit | change | what and why |
|---|---|---|
| `fdf54ce592` | Early page-table allocations traced only on request | 43 lines per boot on the Pi 4, printed with interrupts off before anything else ran; behind `TRACE_ARCH_VM_TRANSLATION_MAP` now. |
| `f5650324d6` ★ | PL011: keep the firmware's line settings | The constructor's loopback test sets IBRD=1, FBRD=0 and LCRH=0 (5 data bits, no FIFO). Nothing restored them unless `InitPort()` ran, which needs the clock. Everything printed was garbage. |
| `b3a08271be` ★ | Fix reading the arm64 debug serial port | `arch_debug_serial_try_getchar()` went through a function returning `char`, so −1 became 255 and KDL read endless 0xff. The blocking variant did not block. |
| `8eca4824c9` ★ | Emergency keys on the serial console | Three Ctrl-] followed by a key act as Alt-SysRq+key, so `d` enters KDL on a board with no working keyboard. On by default on arm, arm64 and riscv64; the `serial_emergency_keys` setting overrides it. |
| `aa1366f629` ★ | Serve the emergency keys from the UART interrupt | The polling daemon stopped along with the threads it shares. The keys now feed one state machine from their own thread and, where the platform supports it (PL011), from the receive interrupt, which works even when no thread can run. |
| `80a6e1f2fb` ★ | PL011 output: bounded wait for FIFO room | A UART that stopped sending stopped the system: the first CPU spun in `PutChar()` holding the debug-output lock, every other printing CPU spun behind it, and `panic()` prints the same way. It now gives up after ~200 000 status reads and does not wait again until the FIFO accepts a character. Written for the network-boot wedge; 12/12 network boots clean with it, but that wedge is not fixed. |
| `5ec650bbb0` ★ | **Serial output sent from the UART's interrupt** | `dprintf()` wrote each line to the UART with interrupts disabled and waited for it (87 µs a character). The output now goes into a 16 KiB ring drained by the transmit interrupt (`DebugUART::EnableTransmitInterrupt()`, PL011); KDL and fatal early messages flush it and write directly; `serial_debug_buffered false` keeps all output direct. Pi 4: boot volume → desktop 5.1 → 4.1 s. |
| `7a2282df3c` ★ | The debug UART's receive interrupt is cleared before its input is read | QEMU's PL011 keeps it raised with the FIFO read empty: with 5ec650bbb0 the CPUs livelocked on the vector's lock right after boot; before, the vector was given up as unhandled and the serial emergency keys did not work in QEMU. Cleared in UARTICR first, as Linux does. |
| `4413675f5c` ★ | `arch_get_stack_trace()` and `arch_debug_get_interrupt_pc()` | Both were stubs, so the profiler and tracing saw no kernel frames on arm64. They now walk frame records across iframes (ELR plus the interrupted FP); user frames are read via `user_memcpy()`, as on x86. `profile -k -S` of a TCP sender now names memcpy, the object cache, mutexes and the checksum. |
| `55348c5c46` ★ | Side effects out of `ASSERT()`; what `KDEBUG_LEVEL` < 2 needs | Found by building at level 1. arm and arm64 `arch_setup_signal_frame()` fetched the handler address inside `ASSERT()`. The FDT bus manager fetched node and driver inside `ASSERT()` (9 places, now `ASSERT_ALWAYS()`). Missing includes in `arch_int_gicv3` and sdhci, and a NULL guard in `dec_vnode_ref_count()` for a GCC `-Wstringop-overflow` false positive. |
| `18e0d2a9db` | **`KDEBUG_LEVEL` 1** (was 2) | Level 2 (paranoid malloc/free, debug mutexes, `ASSERT()`s, block-cache checks) cost ~30 % of a TCP sender's kernel profile in the slab allocator and ~15 % in mutexes. Level 1 keeps the debug syslog, interrupt statistics and KDL commands; the spinlock and ICI checks do not depend on the level. Pi 4: TCP upload 600 → 914 Mbit/s, download 660 → 918; network boot to desktop 56.2 → 54.8 s (15/15); a 15-minute Firefox + SuperTuxKart + HEVC soak with 0 crashes. A fork configuration choice, not a fix (`build/config_headers/kernel_debug_config.h`). |

### Not arm64-specific: VM, I/O, signals, profiling

These are in kernel code that every architecture uses. Most were found by running Wine on the Pi.

| commit | change | what and why |
|---|---|---|
| `894c4abe7f` ★ | Keep `MAP_SHARED` file mappings shared across `mprotect()` | `mprotect()` and `set_area_protection()` replaced an area's protection outright and dropped `B_SHARED_AREA` (and `B_OVERCOMMITTING_AREA`, `B_KERNEL_AREA`). The next `fork()` copied such a mapping as a private area, which made the child's cache a consumer of the file's cache. The next protection change of any mapping of that file then called `vm_copy_on_write_area()` on the file's cache, which moves every area of the file, writable shared mappings included, onto a new anonymous cache; their writes never reached the file again. The flags that say how an area was created are now kept, and no copy-on-write cache is inserted above a file's cache. Wine's wineserver writes the session's shared objects through such a mapping; once it was detached, new Wine processes read zeros and a new prefix never finished. |
| `6e517bb52c` ★ | A fault whose signal is blocked or ignored ends the team | A faulting thread returns to the faulting instruction. When it blocks or ignores the signal of that fault (SIGSEGV, SIGBUS, SIGILL, SIGFPE), the signal stays pending and the thread faults again, for ever. A fault inside a signal handler, which runs with its own signal blocked, does exactly that: Wine's SIGSEGV handler, entered on a thread Wine did not create, faulted on its missing thread data, and the team spent minutes in millions of faults a second. `send_fault_signal()` now unblocks such a signal and resets its action to the default before sending it, as Linux's `force_sig_fault()` does. `vm_page_fault()` and the arm64 synchronous exception handler use it. |
| `1539d29eee` ★ | Page writer: write what there is after the wait times out | Since the per-device page writers (`3bfaa91290b`), a timeout of the 3 s wait for a trigger went straight back to waiting, so a device's last modified pages, fewer than `kNumPages` (up to 1 MB of a file), stayed unwritten until a sync. A power cut lost them: a 111 kB file was not on the disk after 60 s (now within 5 s), and a package installed just before a power-off lost its last 163 kB. An idle writer still finds no pages and goes back to waiting. |
| `90fa3bc401` ★ | `IORequest`: iterate in a loop, not by recursion | When the sub-requests an iteration callback schedules finish before it returns (synchronous I/O, as for a device without an `io()` hook such as `remote_disk`), the last one notified the parent, whose `NotifyFinished()` ran the callback again: one stack level per round of up to 8 file vecs. A fragmented file overflowed the kernel stack; on a network boot the page writer panicked writing back a Wine Mono install on a nearly full disk. A notification that arrives while the callback runs now only records that the I/O has finished, and the caller's loop goes on to the next round. Asynchronous completions are unchanged. Not reproduced synthetically; the Wine case passes with the fix. |
| `6f53989b14` ★ | packagefs: read ahead when a package's heap is read in order | A heap read is one compressed chunk (~20 KiB for 64 KiB of data) from a file opened O_NOCACHE, so every chunk was a request to the disk. After two reads in order one page-aligned request of 256 KiB brings the next chunks; scattered reads (a program's pages) are unchanged. All of the Firefox package from the Pi's SD card 9.0 → 5.35 s, the boot unchanged. |
| `8edea64c6b` ★ | `DMAResource`: bounce buffers up to 128 kB, not 16 kB | A transfer that needs bouncing (an offset not block-aligned, or memory outside the device's DMA window — the Pi 4's SD controller reaches only the first GB) went 16 kB per command. Unaligned uncached 256 kB reads 16.5 → 7.3 ms; Firefox's first start 9.2 → 8.2 s. Aligned uncached 64-256 kB reads measure 8-25 % slower; not yet understood. |
| `265d2b03dd` ★ | `DMAResource`: bounce buffers up to 512 kB (never above the device's max transfer) | SD cards write much faster in 512 KiB commands than in 128 KiB ones; this board's EMMC2 reaches only the first 1 GiB, so most buffers are bounced and the 128 kB cap set the command size. Raw SD writes 24 → 35.6 MB/s (Linux on the same card 32–33), BFS 1 GiB+fsync 26 → 32 MB/s, 1 MiB reads 35 → 43 MB/s; usb_disk keeps 128 kB (its max transfer). 8 MiB of bounce memory below 1 GiB instead of 2 ([design/perf-round-h20.md](design/perf-round-h20.md) C4). |
| `72ea4b2993`, `afd7f0590c` ★ | **Page writer and file cache: disk requests up to 512 KiB** | Every file data write went out in page-writer transfers of at most 32 I/O vectors (~128 KiB of scattered pages), and a large cached `read()` was cut into 128 KiB synchronous reads. Transfers now take up to 128 vectors (a run still keeps ≤ 256 pages busy), reads over 32 pages go in chunks of up to 128 pages (one non-waiting 3 KiB allocation, old path when memory is low). Pi card: BFS 1 GiB+fsync 31.3 → 34.2 MB/s (93 % of raw), 128 MiB in 128 KiB writes 19.8 → 30.9, cold 1 GiB read 35.9 → 42.4, `cat`/`cp` 128 MiB +32–34 %; 66/66 content checks, power cuts on Pi and x86-64 clean ([design/perf-round-h20.md](design/perf-round-h20.md) C4b). |
| `3a0be104e3` ★ | `IOOperation` keeps a saved vec length wider than 16 bits | The partial-write path saved the length of the vec it shortens in a `uint16`; with the 128 kB bounce buffers above a bounce vec can be 64 kB or longer and came back as 0. Found on x86-64 (KVM, NVMe boot disk): every larger unaligned write hung, so shutdown never finished (7/7). Now `generic_size_t` ([design/x86-64-check.md](design/x86-64-check.md) R1). |
| `5db923abc6` ★ | runtime_loader: a new thread's TLS vector starts at the current generation | A new thread's dynamic thread vector started at generation 0; once any image with TLS had been unloaded, the thread's next TLS access destroyed the blocks it had just created, and a thread-local value written once read back as 0. Mesa's call_once() then jumped to address 0 on the second Vulkan instance of a process (Photocraft's GPU tests). Test: haiku-rpi `tools/haiku-tests/tlsreload`. |
| `6f810ed2d7` ★ | `lock_memory_etc()`: unwire what was wired when a page fails | When a page in the middle of an area could not be wired, the area's wired range stayed registered at its full size, and the revert for the part before that page looked for a range of the shorter size: "PANIC: VMArea::Unwire(...): no such range". A `read()` into a buffer that runs into a `PROT_NONE` page of the same area did it (`cache_io()` wires the buffer). The range is now shrunk to the wired pages first. `read()` and `write()` with buffers ending in a `PROT_NONE` page, at 64 offsets: an error return, no panic. |
| `5180e96119` ★ | No profiling timer left behind on a CPU | When a team's debugger goes away, `THREAD_FLAGS_DEBUGGER_INSTALLED` is cleared on all its threads, including one running on another CPU with its profiling timer armed. `switch_thread()` then skipped `user_debug_thread_unscheduled()` for it, and the CPU's timer stayed scheduled after the thread was gone. Adding it again linked it to itself in the timer list, and the next walk spun with interrupts off; or it fired and `profiling_event()` dereferenced the current thread's NULL `installed_timer`. A thread is now unscheduled through the debugger code whenever it has a profiling timer, whatever its flags say. The timer is also cancelled before it is added and when a profiled thread exits. `profile -i 1000 -f -k wineboot -i` 3 times in a row (was a hang or a panic on the first run). |
| `09b7e81388` ★ | Breakpoint manager: sync the instruction cache after writing team memory | Software breakpoints, their removal and code a debugger writes must reach the instruction cache, which ARM does not keep coherent. No-op on x86. |
| `40adafebe9` ★ | Breakpoint flag updated when continuing installs a hardware breakpoint | `PrepareToContinue()` replaces a software breakpoint at a continuing thread's PC by a hardware one; if the team had none before, its threads' `THREAD_FLAGS_BREAKPOINTS_DEFINED` stayed clear and the breakpoint was never loaded. It now says whether it replaced one, and the flags are updated. |
| `127fb34239` ★ | `poll()` leaves the caller's `events` alone | It ORed `POLLNVAL \| POLLERR \| POLLHUP` into each pollfd's `events` and copied the array back. `events` is input only (POSIX), and libevent's poll backend drops a descriptor once its `events` is 0 — which never happened, so a descriptor closed while still listed made every `poll()` return at once with `POLLNVAL`. Firefox's IPC thread spun like that at every quit (~2000 calls per second for two seconds) and while child processes came and went. `tools/haiku-tests/polltest.c` in haiku-rpi checks it. |
| `67b8a53cbe` ★ | Prefetch at most 1 MB of a mapped file | Mapping a file started an asynchronous read of up to 10 MB of it. The first program of a boot that uses libbe maps ICU's data library (a 30 MB segment of data nobody touches at start-up); reading and decompressing 10 MB of it delayed the page faults the program needed: the launch_daemon reached `main()` 1.2 s after being loaded, now 0.6 s. |
| `b23e7264c0` | The loader loads fewer modules on arm64; the network ones on network boots only | It loaded 139 images at every boot (~18 ms each): all boot module links, every file system and the partitioning systems. Boot module links can now go into a subdirectory; the remote disk driver, genet and the network stack are in `boot/network`, read only on network boots. On arm64 the SATA/IDE/UFS/OHCI/UHCI/EHCI/CD drivers are no boot modules and the file systems are not preloaded (BFS and packagefs are boot modules). 57 loads, the loader 2.0 → 1.2-1.4 s. |
| `13a39894c2` ★ | app_server precaches its default fonts in a thread | The font manager read the plain and bold font files in full in its constructor, before the screens were set up; a low-priority thread does it now. |
| `ecab951764` ★ | **A team reuses the stack areas of exited threads** | Every thread got a new stack area (created, faulted in, deleted again at exit: ~40 % of the kernel's part of a thread). A team now keeps up to 4 of them for new threads asking the same stack and guard size (kernel-made, ≤ 2 MiB; not across fork(), dropped at exec and team death). Pi 4: create+join of an empty thread 75 → 49.5 µs (CPU 67 → 41), of one using 64 KiB of stack 193 → 49 µs. |
| `dbae37b2cb` ★ | A stack from `pthread_attr_setstack()` is placed where it was given | It was placed a guard size (16 KiB) above the caller's memory: the TLS block went into whatever followed, or the thread never started. |
| `a000d5d6cc` ★ | A new thread's TLS slots are all cleared | Slots handed out by `tls_allocate()` could start with stale values. |
| `634dd24886` ★ | `fork()` holds the runtime loader's heap lock | Forking while other threads start or exit corrupted the child's loader heap: 10 of 40 children crashed (test `threadstress`); 0 of 40 now. fork+exit ~4 % slower (1.13 → 1.18 ms). |
| `1582c223b0` | `_kern_team_memory_barrier()`: a memory barrier for all threads of a team | Like Linux's `membarrier()`: every CPU running a thread of the calling team executes a full barrier (an ICI) before the call returns; `switch_thread()` has full barriers on both sides. libroot's private `__team_memory_barrier()`; Wine's `NtFlushProcessWriteBuffers` uses it (patch 0025). Pi: 0.9 µs per call, ~3 µs with three busy threads of the team; a store-buffering litmus 23 % → 0 natively, 8.2 % → 0 for 32-bit x86 code under Box64. |
| `88be53559b` ★ | `SupportDefs.h`: strong compare-and-swap in `atomic_test_and_set()` / `atomic_test_and_set64()` | From RenkuOS #189 (atomozero), MIT. The weak `__atomic_compare_exchange_n()` may fail spuriously on load/store-exclusive machines and then hands back the expected value, which callers take as success: a lock taken twice ("mutex was not actually locked!"). With GCC's default `-moutline-atomics` both forms call libgcc's `__aarch64_cas*`, which retries, so our arm64 build was not affected (a scan of all 566 binaries: no store-exclusive without a retry); without outline atomics the weak form has no retry, and on the Pi a lock built on it lost 54 % of the increments it guarded; the strong form 0 of 210 million (`tools/haiku-tests/castest.c`). Kernel and userland share the inline. |
| `2486477fab` ★ | Scheduler: move a busy thread off an overloaded single-CPU core | A thread that always runs needs `kMaxLoad`, and two of them on one core made its load 2000, but `CoreEntry::GetLoad()` caps it at `kMaxLoad`: low_latency's `rebalance()` saw at most 800 against an idle core, less than either thread's 1000, so both shared one CPU for as long as they ran while three cores idled (only single-CPU cores: arm64 boards, x86 without SMT). It now compares the uncapped load. Two spinning threads placed on one core: a barrier round 3.8–4.7 ms (the quantum) in 10 of 10 runs → 0.19–0.22 µs (`tools/haiku-tests/spread.c`). power_saving's `rebalance()` has the same shape, not changed. |
| `8a65ea1c6d` | Debugger command line: `stop` waits for the stop; `bt` waits unlocked | `bt` right after `stop` printed no stack (the thread had not stopped yet) and could then hang, holding the team lock while waiting for the stack trace the worker needed that lock to produce. |
| `f0a1d5f5cf` ★ | `setrlimit()` accepts the current value of a fixed limit | `RLIMIT_AS`, `CORE`, `DATA`, `FSIZE` and `STACK` cannot change, and any request returned EINVAL, also one equal to `getrlimit()`: programs disabling core files before a crash test (numpy's test suite; Python says "current limit exceeds maximum limit") failed. Such a request now succeeds; any other change is still EINVAL. |
| `797972f727` ★ | A clone of a `B_CONTIGUOUS` area is mapped in full when it is made | Only `B_FULL_LOCK` clones were; a contiguous one was mapped page by page on first touch, and `lock_memory_etc()` skips contiguous areas assuming they are mapped — so a driver walking such a clone met unmapped pages (the v3d import panic above). |

---

## 3. Device and bus managers

The FDT changes are ★: any board whose devices sit behind remapping buses needs them. So are the
`device_manager` and PCI bus manager changes. The mailbox module and the PCIe driver are
Pi-specific.

| commit | change | what and why |
|---|---|---|
| `d20bc8fa87` ★ | No ACPI without a root pointer outside x86; ps2_hid only on x86 | On a device-tree machine the loader passes no ACPI root pointer and the bus manager initialised ACPICA anyway ("AcpiInitializeTables failed AE_NOT_FOUND", "Could not remove SCI handler" at every boot); only x86 can find the tables by scanning memory, so elsewhere the module declines. ps2_hid is packaged for x86 only, like its bus manager. |
| `1c9c78289e` ★ | FDT: translate `reg` through the parent buses' `ranges` | `get_reg()` returned the node's address as written, which is a CPU physical address only directly under the root. On the Pi 4, `/soc` maps 0x7exxxxxx to 0xfexxxxxx, and `emmc2bus` and `/scb` have their own windows. A bus without `ranges` (I2C, say) is not memory-mapped, and its children's addresses are returned unchanged. |
| `08e65e6449` ★ | FDT: `get_dma_window()` | From the nearest `dma-ranges`: the offset between physical and DMA addresses and the end of reachable RAM. VideoCore-bus devices see the first GiB of RAM at 0xc0000000. |
| `f2e5b2fab8` ★ | `get_dma_window()`: the RAM window, not the first one | `/scb` lists the peripheral window first, so its devices got a 56 MiB window. RAM's window is the largest one; use that. |
| `81deb24f8c` ★ | `device_manager`: `get_next_child_node()` | Returned only the first child (see the shortlist). |
| `c82925eeb9` ★ | `device_manager`: keep driver modules loaded while reprobing at boot | After the boot volume is mounted, `device_manager_init_post_modules()` reprobes every node, and each node loaded, asked and (with the last reference gone) unloaded the same driver modules again. On the Pi 4 (about a hundred device tree nodes) that took 2.9 s with the device manager lock held. The modules the reprobe loads now keep a reference until it is done: 0.76 s, with the same devices and drivers found. |
| `cafef4f9bb` ★ | PCI: an I/O port BAR's host address is its port | `pci_ram_address()` translates memory addresses only, so for an I/O BAR it found no range and returned 0: on every architecture but x86, all I/O BARs read as "host 0". The `read_io`/`write_io` accessors take ports in PCI I/O space and map them through the controller's I/O window themselves, so the port is what drivers need. Found on QEMU's arm64 virt machine, not the Pi: virtio-blk-pci (port 0) and virtio-net-pci (port 0x80) both drove port 0 in legacy mode, virtio-net's reset stopped the disk, and every read after it failed. Both now work, and the system boots to the desktop. |
| `eafa824d33` | `generic/bcm2835_mailbox`: VideoCore firmware property interface | Clock rates, temperature, power domains, board information and GPIO-expander lines via the ARM-to-VideoCore mailbox, with one request buffer inside the VideoCore's DMA window and the cache maintenance it needs. A boot module, because the SD card's base clock comes from the firmware. Later commits add tags (GPIO state, V3D power and clocks, planes, clock IDs, turbo). |
| `5cb3a2d215` | `busses/pci/brcmstb`: Broadcom STB PCIe root complex | The BCM2711's single-lane PCIe, which connects the VIA VL805 USB 3 controller. U-Boot shuts the controller down, so it does the full bring-up as Linux's `brcm_pcie_setup()`/`brcm_pcie_start_link()`: reset, inbound and outbound windows, PERST# for 100 ms, link training. Haiku's PCI bus manager does not program bridges here, so the root port is set up as a bridge to bus 1. Boards without a VL805 EEPROM get its firmware loaded by the VideoCore (`NOTIFY_XHCI_RESET`). Legacy interrupts go through `interrupt-map`, devices behind it inherit the 3 GiB DMA limit, and MSI is not supported yet. Gen 2 x1 link. See [design/brcmstb-pcie.md](design/brcmstb-pcie.md). |

---

## 4. Storage: SDHCI, the MMC bus, SDIO

Haiku's MMC stack was written against PCI and ACPI SDHCI controllers at default speed. The Pi 4 has
two FDT-described controllers: `emmc2` for the SD card and an Arasan controller wired to the WiFi
chip. They share one interrupt line, and `emmc2` ignores 8- and 16-bit register accesses. Everything
in the bus manager, the disk driver and `sdhci.cpp` itself is ★. `sdhci_fdt.cpp`'s quirk table is
Pi-specific.

| commit | change | what and why |
|---|---|---|
| `68293c40a1` ★ | Turn MMC debug tracing off | Per-command tracing on a serial console slowed an SD boot by more than a minute. The disabled `TRACE()` of `mmc_disk` was not empty and broke an if/else chain. |
| `23f6235b0d` ★ | sdhci: fixes found on hardware; 32-bit access, platform clock, DMA window | Generic fixes: write-1-to-clear acknowledge (see the shortlist), `RecoverError()` truncating status to 16 bits, the 6-bit timeout-clock field, double scan of a card present at start, a clock divider rounded down so the card clock could exceed the request (now rounded up), missing-completion reporting without tracing. Hardware support: registers narrower than 32 bits accessed through their 32-bit word, with transfer mode and command written in one store; a platform base clock; a DMA offset plus non-snooping cache maintenance. |
| `af82a8ca4d` | sdhci: FDT attachment (`brcm,bcm2711-emmc2`) | Registers and interrupt from the device tree (through `ranges`), base clock from `clock-frequency` or the VideoCore firmware, DMA window from `dma-ranges`. |
| `890f468bf4` ★ | sdhci: ADMA2 and PIO | ADMA2 with 32-bit descriptors when supported and a DMA window is known; descriptors cover at most 32 KiB, so no length encodes as 0. PIO via the buffer data port without SDMA (QEMU's model of the Pi controllers). CRC, end-bit and ADMA errors now end a transfer with an I/O error instead of leaving it waiting. |
| `bf3a1d0bdb` ★ | High speed (50 MHz) | Cards ran at 25 MHz. Adds `execute_data_command()` (a command with a short data phase) and `set_clock()`, and `mmc_disk` sends `SWITCH_FUNC` after going to 4-bit mode. Sequential reads 10.5 → 18.9 MB/s. |
| `e29c5b7c65` ★ | UHS-I: 1.8 V signalling, DDR50/SDR50 | S18R in ACMD41, CMD11 and the controller's voltage switch, then the fastest common mode (DDR50, SDR50 without tuning, or high speed). New hooks `supported_timings()`, `switch_signal_voltage()` and `set_timing()`. On the Pi the regulator is line 4 of the firmware's GPIO expander. 1 MiB reads 17.4 → 31.7 MB/s (DDR50). |
| `1cccf09635` ★ | ADMA2: one command for all segments of a transfer | `DoIO` issued one command per I/O vector and the bus allowed one segment per transfer, so page-cache I/O into scattered pages became many small commands. One descriptor table now covers the vectors and the FDT bus allows 32 segments. Raw reads 32.3 → 42.6 MB/s; a 112 MB package through the file cache at 44 MB/s; md5 equal to the host's. |
| `c283f50c5b` ★ | Spin up to 50 µs for command completion before sleeping | A command completes in microseconds, faster than a thread wakes. WiFi ~14 → ~25 Mbit/s up, ~38 → ~45 down. It also showed that Command Inhibit can still be set just after the completion interrupt; it now gets 1 ms to clear. |
| `f0578116b8` ★ | Report and stop an interrupt storm | More than 20 000 interrupts in 100 ms (a level nobody clears): report status, enabled signals and present state once, and mask the controller so the system stays alive. Added while hunting the network-boot wedge. |

### SDIO (for the WiFi chip)

| commit | change | what and why |
|---|---|---|
| `b04df67eaf` | `sdhci_fdt`: 128 DMA segments per transfer | Buffers are mostly single pages, so 32 segments capped an SD command at 128 KiB; 128 allow 512 KiB as Linux's sdhci (C4, with the bounce-buffer change above it is what makes SD writes 35 MB/s). |
| `ec55b68bfe` ★ | Attach the Pi's WiFi SDIO controller; enumerate SDIO cards | `sdhci_fdt` gets a compatible table with quirks; the Arasan `brcm,bcm2835-mmc` gets the firmware EMMC clock, no High Speed Enable bit, PIO only, and 3.3 V despite reporting no voltage. `non-removable` is honoured and disabled nodes are skipped. sdhci claims an interrupt only when an enabled status bit is set, because the two controllers share a line. It adds R4/R5 replies, a data timeout derived from the base clock, and a probe timeout that is not an error. `mmc_bus` probes CMD5 before the memory sequence and initialises SDIO cards (OCR, RCA, CCCR, CIS manufacturer tuple) as `CARD_TYPE_SDIO`. |
| `c5f52af56b` ★ | SDIO data transfers; power-cycle the WiFi chip | CMD53 through the buffer port, any block size up to 2048. Block size and count go in one 32-bit write, because the Arasan controller can lose a write closely following another to the same register (Linux shadows them too). Errors reset the CMD/DAT lines, a busy command line is an error rather than a panic, and CMD52 may be sent while DAT is busy. `mmc_bus` gets CMD52/CMD53 operations for function drivers (block mode plus byte remainder), function block sizes and enable, and a 4-bit bus with high-speed timing. The card is power-cycled through the firmware GPIO expander (`WL_ON`). The mailbox gains `GET_GPIO_STATE` and accepts unmarked responses. |
| `1be86daecf` | SDIO card attributes as `uint16` | Vendor and device IDs are published as `uint16`, like other buses. (The masking of the card interrupt in this commit was superseded by the next.) |
| `4d12fd3908` ★ | Deliver the SDIO card interrupt | sdhci signals the card interrupt to a semaphore and keeps it masked until the function driver has serviced the card (only the card can clear the level). The MMC bus manager and the compat `sdio` bus pass it through. broadcomfmac waits on it instead of polling every 10 ms; a 100 ms poll remains as a safety net. WiFi round trip ~13 → ~9 ms. |
| `6018671453` | **SDIO data blocks moved by the interrupt handler** | CMD53 polled the Present State register with `spin(1)` per block and `spin(10)` for transfer complete: 37–58 % of the busy CPU time during WiFi transfers. Blocks of ≥ 256 bytes are now moved by the handler (acknowledge the latched bit, then move every block the level bit shows ready, so a lost edge cannot strand one); the caller sleeps until transfer complete and moves a block itself after 1 ms without its interrupt (never seen). Smaller blocks (firmware download, register windows) stay polled. CPU per MiB −34 % up / −31 % down, TCP rate unchanged ([design/perf-round-h20.md](design/perf-round-h20.md) N7). |
| `d018d9dfe1` | SDIO high speed up to 50 MHz | The Pi's WiFi controller gets 41.67 MHz (250 MHz ÷ 6). The chip's RAM still reads back intact. WiFi downloads ~29 → ~38 Mbit/s. |

---

## 5. USB (xHCI behind the VL805)

The xHCI driver works behind the PCIe driver above with a diagnostic and one ring fix (`c65ac5a2e6`). USB keyboards, mice and disks enumerate.

| commit | change | what and why |
|---|---|---|
| `eabad7a921`, `b90cb3f0d4` ★ | **Cache maintenance for USB disk transfers** | Before: every USB disk read stale data and wrote stale memory (Linux on the same Pi: correct). xHCI cleans/invalidates each physical fragment before submission and after IN completion; usb_disk 64-byte aligned buffers on arm64. Pi: repeated reads equal Linux's, Haiku-written data verified under Linux, BFS mkfs/copy/remount/checkfs clean ([design/usb-storage-integrity.md](design/usb-storage-integrity.md)). |
| `61fe84cd93` ★ | **usb_disk honours the host controller's DMA high address** | On a 4 GB Pi buffers above 3 GiB went to the controller as they were: `usbhigh` (fills ~3.4 GB, 1 MiB reads into every slice) 866/3392 slices wrong and a later "Host System Error" → 0/3392, 62–65 MB/s. Takes `B_DMA_HIGH_ADDRESS` from the parent nodes ([design/usb-storage-integrity.md](design/usb-storage-integrity.md) "Follow-ups"). |
| `d3cc8e3fd1` ★ | usb_disk: delete the I/O schedulers before taking the device lock in uninit | A teardown/I-O-thread deadlock when a stick vanishes with reads queued (row 54); port power-cycle test `usbport` 9 rounds clean ([design/usb-storage-integrity.md](design/usb-storage-integrity.md) "The enumeration stall"). |
| `71bc709601` | USB stack DMA below 3 GiB and non-cacheable on arm64 | The VL805 reaches only the first 3 GiB and does not snoop. This is applied to the stack's DMA areas on all of arm64 for now, **until the limits are taken from the host controller itself**. That makes it a stopgap, not upstreamable as is. |
| `1d44b00380` ★ | xHCI: show the endpoint ring on a TRB error | Prints the event's TRB pointer and the ring, which identify the rejected TRB. Seen intermittently on a HID interrupt endpoint of the VL805. |
| `afb2823bb5` ★ | USB: explore a new bus in the explore thread, not in its `Start()` | `BusManager::Start()` explored the new bus at once. On the Pi 4 the xHCI's `init_bus()` took 1.56 s of port resets and enumeration inside the device manager's initial scan, before the boot volume could be mounted. The explore thread does it now while the boot goes on; a USB boot disk published late is waited for by `get_boot_partitions()`, and other devices are hot-plugged as always. Boot volume mounted 5.8 s after the kernel starts, was 7.1 s. |
| `c65ac5a2e6` ★ | xHCI: clear completed TDs' ring entries; pad TRBs against overfetch | In about one boot in ten (59 of 623) the board's USB hub stopped answering a few seconds after usb_hid started: every control transfer to it timed out until the next boot. At the timeout the controller's dequeue pointer had run past the stop marker, over entries of the ring's previous lap. Haiku's rings never toggle the cycle bit (a cleared TRB marks the end), so old entries still look valid, and the VL805 prefetches TRBs past where it stops and may use those copies later without reading them again (Linux's `XHCI_TRB_OVERFETCH`). It then replayed stale Link TRBs into freed TDs. Each TD's two ring entries are now cleared when its Event Data completion arrives, whatever the completion code; that part is generic. Every endpoint ring and every TD's TRBs are followed by four unused TRBs, as Linux does for the VL805. The VL805's firmware version is logged, since its other errata depend on it. 40 of 40 cold boots without a USB error. |
| `e1d69f100f` ★ | xHCI: a physical transfer's TDs cover the current fragment only | A transfer over `USB_MAX_FRAGMENT_SIZE` (384 KiB) goes one fragment at a time, `AdvanceByFragment()` setting the used-up vectors to length 0. For physical vectors `SubmitNormalRequest()` built TRBs over all remaining vectors: the first TD asked for the whole transfer, the next ones had 0-byte TRBs and ended before their data — "Babble detected", "USB transaction", a failed read (why usb_disk's 1 MiB transfers failed on 10-25). Now `FragmentLength()` bytes from the first vector not used up: usb_disk at 1 MiB per command reads 97 MB/s, no errors; usb_disk itself stays at 128 KiB (+1 % only, writes untested). |
| `289d8095c0` ★ | `usb_disk`: 256 DMA segments per transfer | The DMA resource defaulted to 16 segments, so a buffer of scattered pages was cut into 64 kB transfers instead of the 128 kB (256 blocks) the driver allows, each a full bulk-only command round trip. USB 3 stick, raw reads: 128 kB 62 → 69.5 MB/s, 1 MB 78 → 87.5 MB/s. Transfers above 128 kB fail on this stack (transaction/babble errors); not changed. |

---

## 6. Networking: GENET Ethernet, WiFi, the net stack

GENET and broadcomfmac are Pi-specific drivers. The SDIO bus in the FreeBSD compat layer and the
WPA join path in `openbsd_wlan`/net_server are ★ and apply to any board.

| commit | change | what and why |
|---|---|---|
| `d6a85764d9` | `broadcomfmac` built without `BWFM_DEBUG` | The bring-up debug output (core list, bus states, firmware checks) went to the serial console at every boot; errors and the MAC address still print. |
| `4ff857683f` | `drivers/network/ether/genet`: Broadcom GENET v5 + BCM54213PE PHY (RGMII) | One RX and one TX ring of 256 descriptors, interrupt-driven with timeouts as a backstop. MDIO through the UniMAC, link polling with speed/duplex reprogrammed on change. MAC address from the device tree, the UniMAC registers or the firmware. A device-manager driver publishing `net/genet/<n>`, because the FreeBSD compat layer cannot attach to device tree nodes. Register sequences follow Linux's bcmgenet/bcmmii/broadcom/mdio-bcm-unimac. Deliberately without status blocks, PHY low-power modes or EEE, after an earlier Pi 4 driver traced gigabit receive losses and dropped first frames to them. See [design/genet-driver.md](design/genet-driver.md). |
| `06356adcc0` | GENET: cacheable receive buffers, invalidated per frame | Copying out of non-cacheable buffers capped receive at 250 Mbit/s. The CPU never writes RX buffers, so they hold no dirty lines; each frame is invalidated before the copy. TX stays write-combining. TCP download 250 → 735 Mbit/s (918 after `18e0d2a9db`). |
| `fb1b33e488` | NFSv4 client in the arm64 minimum image | The Pi has only SD and USB storage. The NFSv4 client and its idmapper make shares reachable over GENET. |
| `e26850ef57` ★ | freebsd_network: an `sdio` bus | `HAIKU_FBSD_WLAN_SDIO_DRIVER_GLUE` drivers are offered the SDIO cards the MMC bus manager found, as a `haiku_sdio_device` in ivars, with a small C interface (`dev/sdio/haiku_sdio.h`) to the bus manager's SDIO operations. |
| `3fcf7b6035` | `broadcomfmac`: OpenBSD's bwfm over SDIO | A port of OpenBSD's `bwfm.c` and `if_bwfm_sdio.c` (as of 2026-09-25) to the openbsd_wlan stack, attached through a small sdmmc shim (`sdmmc_haiku.c`). Firmware comes from `/boot/system/non-packaged/data/firmware/broadcomfmac/` (`brcmfmac43455-sdio.{bin,txt,clm_blob}`). One Haiku-specific fix: firmware event messages carry a 16-byte interface name, not `IFNAMSIZ` (32 on Haiku). BCM43455 firmware 7.45.234. In the arm64 minimum image. Interrupt delivery came with `4d12fd3908`. See [design/wifi-bcm43455.md](design/wifi-bcm43455.md). |
| `86122fc522` | broadcomfmac: unmask the card interrupt only after servicing it | Before the driver enabled its handler, the interrupt thread unmasked an uncleared level after every wake. The real-time thread spun and starved net_server, and the boot stopped at WiFi bring-up. |
| `584742feec`, `00004aa2ff` ★ | Join WPA personal networks without the wpa_supplicant | The wpa_supplicant is not built for every architecture. net_server passes the passphrase via `IEEE80211_IOC_HAIKU_JOIN` with the new flag `IEEE80211_HAIKU_JOIN_PASSPHRASE`. openbsd_wlan derives the PMK itself (PBKDF2-HMAC-SHA1, 4096 rounds, SSID as salt) and its in-kernel supplicant does the handshake. SSID and key lengths are now checked. |
| `a6ca113d55` ★ | Plain PSK when PSK-SHA256 is also offered | SHA-256 key management needs PMF, which bwfm does not negotiate. APs offering both (hostapd's default with optional PMF) are joined with plain PSK, as the wpa_supplicant would. Result: 4-way handshake, DHCP lease, ping. |
| `bf33dc5c29` ★ | Unscanned networks with a passphrase are WPA2-PSK | A network not yet in the scan results was taken to be open, so joining it with a passphrase failed. It is now tried as WPA2/CCMP/PSK. |
| `f43d42c93b` ★ | openbsd_wlan: join with one interface restart, not three | Name, PSK and WPA parameters went through the driver's ioctl one by one; each returned `ENETRESET`, and bwfm restarted the interface three times. The last scan sometimes never finished (1 join in 2 failed). Name and key now go to net80211 directly. Result: 3/3 joins, each with one restart. |
| `25c9881600` ★ | ipv6, icmp6: send ICMPv6 error messages; deliver Destination Unreachable | `ipv6_error_reply()` and `icmp6_error_reply()` were stubs: a datagram to a closed IPv6 port vanished and its sender waited for a time-out. With no name server configured the resolver asks `[::]:53` (loopback) as well as `0.0.0.0:53`, so every host name lookup without DNS settings waited ~14 s (Firefox's profile lock does one at every start: 17.1 → 3.1-3.7 s to its window on a Pi without a network). Now Destination Unreachable, Packet Too Big, Time Exceeded and Parameter Problem are sent (RFC 4443 2.4 rules), and Destination Unreachable and Time Exceeded are delivered on receive (they were dropped). |
| `58022c954a` ★ | libnetwork: the host's own name resolves to the hosts file's localhost entries | Haiku's default host name is not in the hosts file, so looking it up went to the name servers. As systemd's nss-myhostname does, a lookup of the host name the hosts file does not list gets the localhost addresses. |

Section 1 covers the network-boot changes to net_server and the kernel.

---

## 7. Graphics: display driver and V3D GPU

Both are new Pi-specific drivers. The V3D driver implements the **Linux v3d DRM ioctl interface** on
`/dev/dri/renderD128`, so that Mesa's v3d (OpenGL/GLES) and v3dv (Vulkan) drivers can run with little
change. The Mesa side lives in the haiku-pi/mesa fork, outside this repository. See
[design/gpu-v3d.md](design/gpu-v3d.md).

### `bcm2711_display` (kernel driver + accelerant)

| commit | change | what and why |
|---|---|---|
| `7c2be9652e` | One frame buffer for the scaled modes, kept from the start | Every change to a smaller mode allocated a new physically contiguous buffer below 1 GB (the scan-out limit) and freed it at the next change; late in a session that run was no longer free and the change failed with B_NO_MEMORY (Warcraft III: "unable to initialize DirectX", KNOWN-ISSUES W15). One native-size buffer is now allocated at the driver's start and reused; the full mega-smoke run (33 programs) then switches Warcraft III to 800×600. |
| `3286ff573d` | Clean scan-out buffers from the cache before they go write-combining | Stage 6 groundwork: a buffer the firmware scans out must not have dirty lines a later eviction would write over what the GPU or CPU wrote through the write-combining mapping. |
| `53e38a1534`, `f514ef1cb4` | **Overlay planes on the firmware's HVS planes 1–6, keyed by the desktop's alpha** | GPU stage 6 ([design/gpu-stage6.md](design/gpu-stage6.md)): the driver allocates overlay buffers below 1 GiB from a pool reserved at start, sets them on planes with `SET_PLANE`, counts updates per vblank; the accelerant implements Haiku's overlay hooks and reports `B_OVERLAY_KEYING_USES_ALPHA`, the desktop plane is scanned ARGB above the overlays while one is shown. Full-screen GL (Mesa flips its frames on a plane) and MediaPlayer (its video on a plane; the ffmpeg plugin still delivers B_RGB32, so the frames are still converted to RGB on the CPU) use it. |
| `885d250d3c` | SAND128 NV12 on an overlay plane (experimental) | The rpivid decoder's native format, for a future zero-copy HEVC path; not used by default. |
| `77df5bfd6e`, `0c7a4d1256` | Overlay buffers are physical mappings kept while the device is open; four reserved | Mesa imports them into the GPU (a clone of a contiguous area, mapped in full since 797972f727); four buffers for the unsynchronized mailbox (on screen, flipped, newest, rendering). |
| `42d6d09b3a`, `fe0a165e1c` | app_server: alpha keying (`B_OVERLAY_KEYING_USES_ALPHA`); a channel taken over leaves the other overlay without it | Haiku's overlay model paints a colour key; this display keys by alpha: front-buffer writes opaque except key pixels in an overlay rectangle. A deleted bitmap no longer releases a shared channel. |
| `4279c0fda2`, `bf0e7f37e6` | app_server keys only while an overlay is shown; 64-byte opaque row writer | With keying always on, every screen copy forced alpha: −1…−3 % in windowed GL and Wine. Now the first overlay makes the front buffer opaque once (~3.4 ms at 1080p) and keying ends 100 ms after the last one; off-plane cases at parity in the games bench. |
| `be81b338fa` | Kernel debugger's frame-buffer console writes opaque pixels | So KDL output stays visible over a plane. |
| `6706fcf5b0` | The vertical-blank probe stops at the third interrupt | It slept a fixed 100 ms before counting the SMI interrupts; three arrive within ~50 ms at 60 Hz, so the mode is set sooner at boot. |
| `c9b4bfe234` | Display driver and accelerant | The display as the VideoCore firmware drives it: the boot loader's frame buffer (write-combining), the monitor's EDID from the firmware, and a retrace semaphore released at each vertical blank. The vblank comes from the SMI interrupt (with the firmware KMS node enabled) or from a thread waiting on the firmware's `SET_VSYNC`. app_server prefers it over the generic framebuffer driver. Retrace 60.00 Hz (gaps 16 655–16 677 µs). |
| `716633f51b` | Modes up to the native one, scaled by a firmware plane | The HDMI link stays in the firmware's mode. A smaller mode gets its own contiguous frame buffer below 1 GiB (the only range the firmware scans out from), which the primary plane (`SET_PLANE`) scales up, aspect kept and centred. The KDL console follows the frame buffer. Tested at 1280×720 and 1024×768 (pillarboxed). |
| `7a37185fe7` | Hardware cursor on a firmware plane | A 64×64 ARGB8888 buffer on the top plane (7). B_RGBA32 or converted BeOS monochrome shapes. A move is one `SET_PLANE` call, scaled with the mode and clipped at the edges. |
| `8af6f08b0b` | app_server's clone of a RAM frame buffer is write-combining | A clone of physical memory inherits its memory type, but the RAM frame buffer of a non-native mode was cloned cacheable, so the firmware could scan out lines still in the CPU cache. |

### `v3d` (V3D 4.2 render node)

| commit | change | what and why |
|---|---|---|
| `b1e9782267`, `ec706b6a3b`, `118e315497`, `5c2aaee784` | **A job queue per unit, concurrent by default** (`v3dtest`: burst, overlap and restart tests) | One queue for everything and one job on the GPU at a time became a queue per unit (binner, renderer, TFU, CSD, CPU), each one job at a time in order, as Linux v3d (credit_limit 1): the binner works on job N+1 while the renderer draws job N. Linux's dependency rules (in_sync_bcl/rcl, implicit buffer fences), a watchdog per running job, a reset restarts the others once. `queues serial` in the v3d driver settings restores one job at a time. Pi: v3dtest 59/59 both modes, 30 min Quake + glmark2 with 0 GPU resets, glmark2/QuakeSpasm +1-3 %. |
| `978d166f24` ★ | An import whose pages are not mapped fails instead of panicking | `IMPORT_MEMORY` of a range the kernel had not mapped (a clone of a contiguous area) reached `get_memory_map()`, which panics: any program could panic the kernel. It now returns B_BAD_ADDRESS. |
| `cb92912c6b` | Power on and identify the GPU | Attaches via the device tree and finds the power-management block that provides the GPU's power domain. The first `open()` powers it on: QPU enable, power domain and clock through the mailbox. The clock is trusted only once the firmware reports it on, because an access to an unclocked V3D never completes. Then the reset line and the two bus bridges. The firmware allows the clock only when its device tree enables the V3D node. 500 MHz. |
| `e01ad66e7c` | GPU memory, jobs and synchronisation (Linux v3d interface) | One 4 MiB page table for the 4 GiB GPU address space, plus a scratch page for stray accesses. Buffer objects are wired, zeroed and write-combining; `MMAP_BO` clones them into the caller, and freed pages are quarantined until every earlier job completes. `SUBMIT_CL` with per-job cache/TLB maintenance, run one at a time in order by a worker thread. The IRQ handler serves binner memory from a pre-staged pool and has storm guards. `WAIT_BO`, syncobjs, a watchdog and a full GPU reset. Per-client handles, so a dying client leaks nothing. Test program `v3dtest`: 41/41 checks. |
| `f337b7e167` | Do not read a dropped job after releasing it | The reset message took the sequence number of a job it had just released. |
| `2ff9130439` | List a wedged job's buffers in its dump | Diagnostic. |
| `f6ae60bfbb` | Statistics: bin and render time, GPU busy | `v3d_stats` splits a control list's GPU time into its two stages and shows how busy the GPU is. Measured with QuakeSpasm at 1080p: bin ~0.45 ms, render ~10 ms per list, so overlapping them (asynchronous queues, stage 7) could gain at most ~4 %. |
| `bf6e4efdd2` | Import client memory as a GPU buffer | `DRM_V3D_HAIKU_IMPORT_MEMORY` wires a team's pages into the GPU page table so Mesa can render or blit straight into a `BBitmap` without a copy. `DRM_V3D_HAIKU_SYNC_BO` does the cache maintenance, since the pages stay cacheable for the CPU. These two ioctls are Haiku-specific extensions. |
| `be08654c68` | Cache maintenance of imported memory without the device lock | `SYNC_BO` walked a window's whole frame (8 MB at 1080p, 3–4 ms in a real frame) holding the device lock, which the worker thread needs to finish one job and start the next: the GPU idled twice per frame. The walk now runs with a reference on the BO instead; `v3d_stats` reports the syncs. With Mesa's matching change (one sync per bitmap, the present blit inside the frame's job): glmark2 233 → 304 windowed, 64 → 81 at 1080p full screen. |
| `e246cf4b9d` ★ | app_server: a plain bitmap copied to the back and front buffers in one pass | Not Pi-specific. Every frame of a GL or Vulkan window went bitmap → back buffer, then back buffer → frame buffer at the end of the drawing operation: two passes over 8 MB at 1080p. A large unscaled opaque copy is now written to both in one pass (in an update session, when the client drew it with `DrawBitmapAsync()`: at the end of the update, or earlier if anything else touches that area). Pi 4: DrawBitmap+Sync 6.92 → 6.04 ms, vkcube 117 → 132 fps; 12 drawing cases pixel-identical. With libglvnd's BGLView now drawing asynchronously over a transparent view colour: glmark2 304 → 337 windowed, 81 → 90 at 1080p. |
| `4a8412437e` | Texture formatting unit jobs (`SUBMIT_TFU`) | `GET_PARAM` already advertised the TFU, so Mesa used it for texture uploads and mipmaps, and every submission failed. TFU jobs now share the queue with control-list jobs. |
| `d5a14e2c9b` | Wire imported memory in a kernel clone of the client's area | Killing GLTeapot panicked in `vm_delete_areas` (`!area->IsWired()`): a team's address space goes away before its files close, while the BO still held the pages wired. The BO now wires a kernel clone of the area. |
| `1ff35fa767` | Job statistics behind the kernel setting `v3d_stats` | Every 5 s: jobs by kind, GPU time, submit-to-done latency, and client wait time. |
| `def8419f84` | What Mesa's Vulkan driver (V3DV) needs | V3DV in Mesa 26.2 has no fallback for older kernels. Adds `SUBMIT_CSD` (compute), `SUBMIT_CPU` (timestamp, reset and copy queries, indirect dispatch), the multisync extension on every submit kind (a chain is queued atomically), and sync files (`SYNCOBJ_HANDLE_TO_FD`/`FD_TO_HANDLE`, `SYNC_IOC_MERGE`, `SYNC_IOC_FILE_INFO`, select/poll). Deliberately simpler than Linux: in-syncs are not tracked (jobs still run in order), no opaque syncobj fds, no perfmon. |

With these changes and the haiku-pi Mesa, the Pi 4 runs OpenGL, OpenGL ES 3.1 and Vulkan in Haiku
windows. The V3D driver also holds the core clock at maximum while the GPU is on (section 11).

---

## 8. Video decode: `rpivid` (HEVC)

A new Pi-specific driver for the BCM2711's HEVC decoder block, which is MMIO plus firmware clock 11
and needs no VCHIQ. H.264 decoding stays with the VideoCore firmware and is not reachable. The
userspace half is a `hevc_rpivid` hwaccel in FFmpeg 6.1, carried as
[../patches/ffmpeg6/](../patches/ffmpeg6/). See [design/hw-video-decode.md](design/hw-video-decode.md).

| commit | change | what and why |
|---|---|---|
| `e98b67a5bd` | `/dev/video/rpivid/0` | The clock goes on at first open and the version register is checked (0x202). Decodes one picture at a time, interrupt-driven through its two phases. The driver owns the memory the block reads and writes (bitstream, pictures, scratch), maps it into the client, and checks every command entry (register whitelist, bitstream bounds) while rebasing addresses. 5 test streams (intra, IPB, weighted prediction, Main 10, 720p), 223 pictures, all bit-exact against the CPU decoder; MediaPlayer decodes HEVC on the block. Also bumps the repository's ffmpeg6 to 6.1.6-2. |
| `be395e19f4` | Interface 2: a decode pipeline | `RPIVID_SUBMIT` queues and `RPIVID_WAIT` collects (`RPIVID_DECODE` remains as both). Phase 1 of picture N+1 runs into a second scratch set while phase 2 reconstructs picture N, as in Linux's driver, in strict FIFO order so references are complete. Buffers are reference-counted per job, and close waits for the file's pictures. With ffmpeg6 6.1.6-3: 1080p 20 Mbit/s at 115 fps using 0.46 cores (the CPU decoder manages 25 fps on 4), 2160p at 38 fps, bit-exact. |

---

### H.264 on the VideoCore: VCHIQ + MMAL

The Pi 4's H.264 decoder sits behind the VideoCore firmware. VCHIQ (shared-memory queues and doorbells to the
firmware) is FreeBSD's BSD-3 core with a Haiku OS layer; Broadcom's BSD-3 libmmal/libvchiq/VCOS come as the
`raspberrypi_userland` package (recipe and patches in this repository, `scripts/build-mmal.sh`); FFmpeg's own
`h264_mmal` decoder drives it ([design/vchiq.md](design/vchiq.md)). Linux's GPL-only vchiq-mmal / bcm2835-codec /
vc-sm-cma were behaviour references only.

| commit | change | what and why |
|---|---|---|
| `6c2778b0b1` | vchiq: the VCHIQ core imported from FreeBSD | FreeBSD 7806832f23fb `sys/contrib/vchiq`, unchanged (Broadcom GPL-2.0 OR BSD-3, used as BSD-3), so later fixes merge |
| `2252a8dc97` | vchiq: the Haiku port | FDT driver for `brcm,bcm2711-vchiq` (doorbell GIC 66), `/dev/vchiq` with the Linux/FreeBSD ioctl ABI, slots below 1 GiB uncached at bus 0xC0000000 + phys, `VCHIQ_INIT` (0x48010) through the mailbox at the first open; bulk transfers on locked user pages with cache maintenance |
| `34660bcc50` | build: the driver in the arm64 Haiku package | |
| `10807a2f0c` | vchiq: semaphores and completions without kernel semaphores | the core makes one per possible service: 4096 kernel semaphores held for good; now spinlock + condition variable |
| `a0ffe46806` | vchiq: the core's state allocated at the first connection | nothing at boot |
| `f47b5639b5`, `6e8be068c5` | vchiq: keep a dying team's bulk buffers | Haiku deletes a dying team's memory before closing its files while the VideoCore may still be writing into it (a panic when a client was killed mid-transfer); such buffers move to kernel copies of their areas |
| `27a0c0d75b` | vchiq: the H.264 block at its maximum clock while MMAL is in use | the firmware drops it 500 → 250 MHz ~2 min after power-on; held: 720p 111 → 171 fps, 1080p 53 → 79 |
| `dd03227336`, `f1cdfb5723` | ffmpeg plugin: prefer hardware video decoders, fall back to software | `h264_mmal` (and `hevc_rpivid`) by name first; if it does not open or fails, `h264` takes over in place (from the start or the next key frame); kept fed with 8 packets (70–90 ms 1080p stalls gone); `FFMPEG_H264_MMAL=0` forces software. MediaPlayer 1080p30: 88 % of a core, all frames on time (software 159 %, mostly late) |
| `0a7fa72b63`, `8a9829b9ab`, `f032832df7` | repository: ffmpeg6 6.1.6-4 (with `h264_mmal`: 2 extra buffers instead of 10, the FFmpeg 6.1 compile fix, end-of-stream frames) and raspberrypi_userland 20241223-1…-3 (MMAL reply waits bounded at 5 s; VCOS's thread key deleted at unload — MediaPlayer crashed at every quit) | |

## 9. Audio

| commit | change | what and why |
|---|---|---|
| `c536a518b2` | `bcm2711_pwm`: hmulti driver for the 3.5 mm jack | PWM1 on GPIO 40/41, fed by legacy DMA channel 5 (paced by the PWM1 DREQ) from a two-period ring. Each period's end interrupts, and the handler silences the played half and completes one buffer exchange. 54 MHz ÷ 2 with a range of 612 gives 44 117.647 Hz, advertised as 44 100 (frame counts come from the hardware). Addresses and interrupt from the device tree. media_server picks it as default output ("Raspberry Pi headphones"); measured 44 117.657 Hz with no underrun. In the regular image. |
| `6965caeb07` | `bcm2711_hdmi_audio`: hmulti driver for HDMI audio | The first HDMI port's MAI (multichannel audio interface), fed by legacy DMA channel 4 (DREQ 10) with IEC 60958 subframes built in the driver, under the display the firmware set up: the audio clock (CTS/N) from the measured pixel clock, an audio InfoFrame in a packet slot the firmware leaves free. Published only when a monitor that takes audio is connected at boot; 48 kHz stereo. Design: [design/hdmi-audio.md](design/hdmi-audio.md). |

---

## 10. Bluetooth

The transport driver is Pi-specific. The fixes to the stack, the kit, bluetooth_server and the
command-line tools are ★.

| commit | change | what and why |
|---|---|---|
| `865c648344` | `bcm2711_bt`: on-board BCM43455 Bluetooth over UART | An H4 transport driver for Haiku's Bluetooth stack, like `h2generic` for USB: `/dev/bluetooth/h4/bcm2711_bt/0`. The controller sits on the AUX mini-UART, which the driver routes to GPIO 30–33 (ALT5) itself (`config.txt` disables the firmware's Bluetooth UART). Every open resets it through the firmware's `BT_ON` line, patches it from `BCM4345C0.hcd` (Download_Minidriver, records, Launch_RAM), resets it again, then registers it with the HCI module. Receive is interrupt-driven, with polling as a fallback. The baud divisor derives from the core clock. 323/323 patch records acknowledged; bluetooth_server reads features, name and class, and an inquiry completes. In the regular image. |
| `02e02d4ba3` ★ | `bt_dev_info`, `bt_discovery`: build and print the device address | `bt_discovery` did not compile: `<bluetooth/RemoteDevice.h>` includes the private `bluetoothserver_p.h`, which was not on `src/bin`'s include path. Both tools passed the `BString` of `bdaddrUtils::ToString()` through `%s` (garbage on arm64), printed a `uint32` with `%ld`, and read the device number from `argv[0]` instead of `argv[1]`. `bt_dev_info` now prints the BCM43455's name and address. |
| `a7535eab9d` | Regular image: ship `bt_dev_info` and `bt_discovery` | They were built but in no image, so the image's Bluetooth stack had no command to look at the local device. |
| `d226612219` ★ | The kit traces only errors unless `DEBUG` is set | `headers/private/bluetooth/debug.h` defaulted to `DEBUG` 3 when `DEBUG` was not defined, as in every release build, so each libbluetooth call printed "CALLED ..." on the standard output of the program using the kit. |
| `0c12640aa2` ★ | `bt_discovery` sees its inquiry end | The kit reports the end of an inquiry through `DiscoveryListener::InquiryResponse()`. `bt_discovery` overrode the old `InquiryCompleted()`, which nothing calls, and waited for ever. The callbacks are marked `override` now. |
| `b0ea06deaf` ★ | L2CAP: ignore connection and disconnection responses to unknown requests | A signalling response is matched to its endpoint by the command identifier; for an unknown identifier (no request of ours, or its endpoint is gone) the lookup gives NULL. The command-reject and configuration-response handlers checked for that; the connection- and disconnection-response handlers called into the NULL endpoint, so a remote device could panic the kernel. A laptop paired by PIN and then unpaired (BlueZ) sent such a connection response, and `L2capEndpoint::_HandleConnectionRsp()` faulted at 0x6c, 2 times in 2. Both handlers now log the response and drop it (0 panics in 3). |
| `3cad4e2996` ★ | bluetooth_server: close a pairing's PIN code window when the pairing is over | Each PIN code request opened a new window and nothing closed it, so every failed pairing left one more on the screen. The server keeps a messenger to the window of each remote address, sends a repeated request to the window already open, and closes it when the link key arrives or the link disconnects. `DisconnectionComplete()` also set the state of a remote device it may not have found (a NULL dereference for an unknown handle); now only when found. |

---

## 11. Power, sensors, random numbers

All Pi-specific except the random module's generator (★). The firmware owns the sensors and the clocks, so these drivers talk to it through
the mailbox module.

| commit | change | what and why |
|---|---|---|
| `426ee96c2e` | `drivers/power/bcm2835_thermal` | `power/bcm2835_thermal/<n>` for `brcm,bcm2711-thermal` (or `-2835-`), like the other thermal drivers. `read()` gives the SoC temperature, the firmware's throttling limit and whether it throttles (heat, under-voltage); `drvOpGetThermalType` returns them too. `8f69771aea` adds measured ARM, core and V3D clocks, and `a669f3070c` adds the board name from the firmware revision code. |
| `8f69771aea` | `power/cpufreq/bcm2835_cpufreq` (first version) | The firmware runs the ARM at maximum only for its boot-time turbo period. About two minutes after power-on it drops the ARM from 1500 to 600 MHz and the core clock from 500 to 200 MHz for good, unless the OS asks for a rate (Linux's cpufreq does). Everything after two minutes therefore ran at 40 % CPU clock. This first version pinned the maximum in low-latency mode; QuakeSpasm demo1 at 1920×1080 went 19–27 → 30–43 fps. The V3D driver asks for the maximum core clock while the GPU is on. **The policy was replaced by the next entry.** |
| `5d8bcb1171` | cpufreq: the ARM clock follows the load; no firmware turbo | The scheduler's per-CPU performance requests move a level, as `intel_pstates` does. A thread checks every 50 ms and asks for the lowest of minimum/750/1000/1200 MHz/maximum that covers it, lowering only after four agreeing checks. With turbo on, the firmware answers every ARM rate with the maximum, so turbo is switched off at start and never requested (v3d, rpivid and bcm2711_bt skip it too). Turbo had also held the core clock at maximum, and at 200 MHz HEVC lost a fifth of its rate, so the core clock is set to maximum once. A 0.7 s burst from idle runs 7 % slower than at full speed; games and HEVC are unchanged. |
| `83db805485` | cpufreq: follow the CPUs' total load as well | A chain of short programs (a shell script, a build, configure) spreads over all four cores at a quarter each, under the scheduler's per-CPU target, so every level stayed low and the shared ARM clock ran at 750–1200 MHz: fork+exec 6.6–8.0 ms instead of 4.7. The thread now also sums the cores' active time and asks for the maximum when they were together busy ≥ 55 % of one core. Slow state 1.4–1.7× → 1.03× of fresh; an idle desktop still drops to 750 MHz ([design/perf-round-h20.md](design/perf-round-h20.md) C0b). |
| `fb4461ed54` | `busses/random/bcm2711_rng200` | The RNG200 (`brcm,bcm2711-rng200`) feeds the random module's pool like the other random controllers. It is reset and enabled at attach (as Linux's `iproc_rng200_restart()`) and checked to produce words. A periodic timer then queues a DPC that drains up to 16 FIFO words, and a failed health test restarts it. |
| `c7509f4229` ★ | arm64: power-off and reboot through PSCI | From RenkuOS #160 (Bryan Irvine), MIT. The loader passes the PSCI conduit it found (ACPI FADT or the device tree's `/psci` node) in `arch_kernel_args`; `arch_cpu_shutdown()` calls PSCI 0.2 `SYSTEM_OFF`/`SYSTEM_RESET`. Our U-Boot boot path has no PSCI (no `/psci` node, spin-table CPUs, `CONFIG_ARMV8_PSCI` off), so it is skipped there. |
| `0b22f22f5b` | `drivers/power/bcm2835_pm`: reboot and power-off through the PM watchdog | `arch_cpu_shutdown()` falls back to a hook a platform driver installs (`arm64_set_shutdown_hook()`). This driver attaches to `brcm,bcm2711-pm`/`brcm,bcm2835-pm-wdt` and installs one: reboot starts the watchdog for a full reset after 10 ticks; power-off does the same with partition 63 in `PM_RSTS`, which the firmware takes as halt. Written from register facts (NetBSD/FreeBSD, BSD-2-Clause; Linux). Deskbar's Restart/Shut down, `shutdown [-q] [-r]` and the kernel debugger's `reboot`/`shutdown` all work on the Pi ([design/renkuos-fixes.md](design/renkuos-fixes.md)). |
| `67b972b5e1` ★ | `bus_managers/random`: ChaCha20 output keyed from the pool | Not Pi-specific. Every 32 bytes read reseeded the pool, which calls `thread_yield()` 257 times under the device lock: a 16-byte read took 145 µs, `/dev/urandom` gave 2.8 MB/s, and every `getentropy()`, TLS handshake and program start that wanted random bytes paid that. The output also was the mixer's internal state, not a cryptographic generator. Now a ChaCha20 keystream (OpenBSD's code, as libbsd's `arc4random`) keyed from the pool, with fast key erasure, stirred from the pool every 1 MiB, every 60 s, after a write and once 64 bytes of hardware entropy have arrived: 2.3 µs per read, 149 MB/s. |

---

## 12. Media Kit

| commit | change | what and why |
|---|---|---|
| `c41702df18` ★ | `BTimeSource` conversions in double precision | `RealTimeFor()` and `PerformanceTimeFor()` converted with a `float`, which holds 2^24 µs exactly. With a drift other than 1.0 they stopped the program in the debugger whenever a time lay more than 16.7 s from the last published one, as with a stalled or restarted time source. MediaPlayer's video producer hit it once in a 15-minute soak. |

---

## 13. Build system, image profiles, package repository

Image-profile edits (`build/jam/images/definitions/minimum` and `regular`) and boot-module lists
(`build/jam/packages/Haiku`) come with the drivers that need them and are listed in their sections.
Changes of their own:

| commit | change | what and why |
|---|---|---|
| `3c641a2b01`/`775c2e8a5e`, `f21e11d138`/`271cec9635`, `2d0aac976e`/`b0ac75ce1f`, `29a820de6e`/`5c7f4579c5` ★ | **Build with GCC 16** ([design/gcc16.md](design/gcc16.md)) | GCC 16 defaults to C++20 and C23: C++ is pinned to `-std=gnu++17` (C++20 breaks enum arithmetic, `++` on volatiles, implicit `this` capture, reversed comparison operators, mixed designated initialisers, `requires` as a name: ~420 failed compiles of the minimum image); the kernel's and loader's zlib (K&R definitions) as `-std=gnu17`; structs with member functions named for linkage (`-Wnon-c-typedef-for-linkage`: elf.h, USB video descriptors, mmc_disk; ABI unchanged); FileTypes' `_Frame()` static (it ran on an unconstructed object). Every architecture. |
| `2df3b18b92` | Optional `HAIKU_PACK_RELATIVE_RELOCS` | Links userland with `-z pack-relative-relocs` (DT_RELR) when set; off by default (needs the binutils option for the target and a runtime loader with DT_RELR). |
| `b258d90d71` | arm64 images use the haiku-pi package repository | Haiku's servers carry no arm64 HaikuPorts repository. `RepositoryRules` now takes an architecture's own repository-info template where there is one (`src/data/repository_infos/haikuports_arm64`, pointing at <https://haiku-pi.github.io/packages>, which [../scripts/publish-repo.sh](../scripts/publish-repo.sh) publishes). `pkgman refresh` and `install` work out of the box over HTTPS. The mechanism is generic; the URL is the fork's. |
| `59b38453cc` | `libmidi.so` in the regular image only with fluidlite | As in the test image already. (The same commit lists the audio packages; see the table below.) |
| `18e0d2a9db` | `KDEBUG_LEVEL` 1 | See section 2. |

Since the arm64 repository is not upstream's, building an image needs `-sHAIKU_NO_DOWNLOADS=1` with
the packages staged in `download/`. [TRY-IT.md](TRY-IT.md) has the build steps.

---

## 14. Other

| commit | change | what and why |
|---|---|---|
| `0ef01f9d31` | `drivers/gpio/bcm2835_gpio` | `gpio/bcm2835/<n>` for `brcm,bcm2711-gpio`. Reading lists each pin's function, level and pull; writing text commands (`in <pin>`, `out <pin> <0\|1>`, `alt <pin> <0-5>`, `pull <pin> <none\|up\|down>`) changes them, so shell scripts can use it. Haiku has no GPIO framework yet, so this is a stopgap interface. |
| `8a10e472dc` ★ | `tests/system/network/tcp_throughput` | Sends or receives TCP data against a sink or source (socat) and reports the rate; used to measure network drivers. |
| `ad9b5551c8` ★ | Debugger: an arm64 back end | The Debugger had x86 and x86-64 back ends only, so on arm64 attaching to a team failed ("Operation not supported") and the crash dialog's Debug and Save report did nothing. `ArchitectureArm64` and `CpuStateArm64` add the registers of the kernel's `arm64_debug_cpu_state` and their DWARF numbers; CFI unwinding, with lr as the return address column; frame-record unwinding without CFI, taking the return address from lr for a top frame not yet in its frame record; instruction info (bl/blr as calls) and statements; and `EM_AARCH64` core files. No disassembler and no watchpoints yet (the kernel has no arm64 debug registers yet). A crashed program's report lists its whole call chain with DWARF variables. |
| `721732e47f` ★ | Debugger: arm64 disassembly, watchpoints, PLT entries | NetBSD's AArch64 disassembler (`disasm.c` rev 1.17, 2-clause BSD, unchanged but for its includes: the whole base instruction set, FP and SIMD; unknown encodings as `.insn 0x…`) for the code views; b/br/ret classified as jumps; 4 watchpoints of up to 8 bytes for reads, writes or both; `ResolvePICFunctionAddress()` reads a PLT entry's GOT slot (adrp x16 / ldr x17). |
| `88b487e15b` ★ | Debugger: "step out" compares frame addresses | It compared the frame's address with the frame pointer register at the return address; on AArch64 a caller's x29 usually is its callee's CFA, so the frame never looked left and the thread ran on. Both sides are now a stack trace's frame address. |
| `3c4a73f4dd` ★ | Debugger CLI: `break`, `step`, `next`, `finish` | `break <function>\|<address>`; the step commands (one instruction each without loaded source, as in the CLI); a stopped thread becomes the current one when there is none; stops say why and where, once; output line-buffered into pipes and files, for scripts. |
| `d2d2349f2c`, `65cae45a13`, `4588cddb87`, `b67b55acf7`, `6c71603f62` ★ | **Debugger: DWARF 5** | Version 5 units were rejected ("Unsupported compilation unit version: 5") and stopped the parse of the whole file. Now: v5 unit headers (type units in .debug_info too), the str/addr/rnglists/loclists bases and their forms, .debug_rnglists/.debug_loclists, `DW_OP_addrx`/`constx`, the C11–C23 and C++03–23 language codes. 47 of 47 host checks against llvm-dwarfdump (GCC 13, GCC 16, clang; DWARF 4 and 5); on the Pi a DWARF 5 build debugs as its DWARF 4 build. |
| `65cae45a13`, `a36ea1ed3b`, `1b4e49fd6c` ★ | **Debugger: source files of GCC's line tables** | GCC writes version 5 line tables even in DWARF 4 units (215 of libstdc++'s 216); the reader numbered their files and directories off by one, so 4 758 of libstdc++'s 4 933 declarations pointed at the wrong file. Also clang's directories relative to the compilation directory, and DWARF 4 tables naming one file twice (`-fdebug-prefix-map`), whose functions had no lines. |
| `0ce0612c25` ★ | SavedClock: keep the time across boots without a battery-backed clock | The Pi 4 has no real-time clock, so every boot started in 1970 until network time synchronisation ran: files got 1970 dates, HTTPS certificates were "not yet valid", and without a network the date stayed wrong. A launch job runs `/system/boot/SavedClock` once the volumes are mounted. It sets the clock forward to the time it last saved (the modification time of `/boot/system/settings/saved_clock`) if the clock is behind it, then saves the time every five minutes and at shutdown. It never moves the clock back; network time synchronisation still corrects it later. After a shutdown the next boot starts from the shutdown's time. |
| `fb4e339ce8` ★ | launch_daemon: the environment pipe is close-on-exec | From RenkuOS #231 (Kevin Adams), MIT. `_GetSourceFileEnvironment()` reads an `env` script's output until end of file; a job another worker thread started meanwhile (`load_image()` passes on every descriptor that is not close-on-exec) kept the write end open, and the read, on launch_daemon's main thread for the user session's `desktop` target, waited until that job ended. `pipe2(O_CLOEXEC)`; the pipe is closed on two error paths too. |

### libroot and the runtime loader (arm64)

| commit | change | what and why |
|---|---|---|
| `e30b8928d6`, `4539cd2f00` ★ | **DT_RELR in the runtime loader** | Packed relative relocations (`-z pack-relative-relocs`) store relative relocations as addresses and bitmaps, 1–2 % of their RELA size (libxul: 492 734 entries, 11.8 MB as RELA); applied before the image's other relocations, for every architecture. elf.h gains DT_RELR/DT_RELRSZ/DT_RELRENT/SHT_RELR. |
| `2c93aeea48` ★ | Memory and string routines from Arm Optimized Routines | libroot on arm64 used generic C for memcpy and memset (8 bytes per iteration, one byte when source and destination are not aligned alike) and musl's or Haiku's C versions of the rest. It now uses the Armv8.0 + Advanced SIMD routines, vendored unmodified with their licence (MIT OR Apache-2.0 WITH LLVM-exception) and built under libroot's names: memcpy, memmove, memset, memchr, memrchr, memcmp, strchr, strchrnul, strrchr, strcmp, strncmp, strlen, strnlen, strcpy and stpcpy. The C versions are left out of libroot and the runtime loader on arm64; the kernel and the boot loader keep the generic ones (no SIMD there). MB/s: memcpy 1 KiB 5280 → 11 223, memcpy from source + 1 731 → 9036, memset 4 KiB 5805 → 11 598, strlen 4256 → 8091, memchr 2908 → 6419. app_server bitmap drawing 162 → 181 frames/s. 3.8 million checks against reference versions (every length up to 300, every alignment up to 16, strings ending at an unmapped page) pass. |
| `2bf2f773ba` ★ | **`rw_lock`: wait again after an interrupted block** | The waiter has a queued flag and a status set by whoever dequeues it (with the lock's mutex held) and blocks again with a fresh wait status until then, as `pthread_rwlock` does. Before, an interrupted wait spun and a hand-off to it was lost: the lock stayed held for ever (BLooperList: SuperTuxKart froze with an empty window in ~1 of 4 starts on images 10-29b to 11-03). Adds `rw_lock_interrupt_test`. |
| `076da9813a` ★ | `__tls_get_addr()` without the runtime loader | Every access to a thread-local variable of a shared library (general-dynamic TLS: all `-fPIC` code) called the runtime loader's `get_tls_address()`, and a busy python3 spent a third of its time there. The runtime loader now publishes its TLS generation (the count of unloaded TLS images) in `rld_export`, and `__tls_get_addr()` returns the address directly when the thread's dynamic thread vector is of that generation and already holds the block. Anything else still goes through `get_tls_address()`. A TLS access in a shared library 35 → 17.4 ns (a global: 7.3 ns); `python3 -m timeit "sum(i*i for i in range(1000000))"` 521 → 391 ms. A test reloading two TLS libraries that reuse one module ID 500 times, with a second thread, passes. |
| `c6cab6cc9e`, `4d433669a8` ★ | **Static TLS block for the images loaded at program start** | GCC's arm64 Haiku spec uses the traditional TLS dialect and every image is linked as a shared object, so every TLS access calls `__tls_get_addr()`, whose fast path still checked the module against the TLS generation (two chains of four dependent loads). The images loaded before the program's code runs are never unloaded: their TLS now lives in one block per thread (`TLS_STATIC_TLS_SLOT`), their DTPMOD relocations carry its offset, and the lookup is one load (9 instructions). Python loop: −9.9 % instructions, 1.5–3 % faster; no rebuild needed ([design/perf-round-h20.md](design/perf-round-h20.md) N5). Also: TLS blocks aligned to the segment's alignment. |
| `a2cf89efd1` | No static TLS lookup where there is no static block | On architectures without the static block (x86-64) every library TLS access paid for the static-block lookup: 10.1 vs upstream 8.2 ns; now 8.1 ns (R5). |
| `91012322ef` ★ | Link with `--hash-style=both` | The runtime loader reads DT_GNU_HASH since upstream `ffc1a5219d`, but nothing was built with it. With a Bloom filter per image, looking up a symbol in an image that does not define it is mostly one test instead of a hash-chain walk with string compares, and starting an application is mostly such lookups. Pi 4: Terminal opens in 80 ms instead of 95, MediaPlayer in 81 instead of 120. DT_HASH stays. |
| `3e8577af06` ★ | Shared libraries bind calls to their own functions (`-Bsymbolic-functions`) | Every reference a library made to one of its own exported functions needed a global symbol lookup at load time, because another image could interpose it; in a C++ library that is most of its relocations (its vtables): 7372 of libbe's 8953. They become relative relocations; data stays interposable. libroot opts out (`KEEP_FUNCTIONS_INTERPOSABLE`): programs may replace `malloc()` and libroot's own callers must then use the replacement. A Terminal start makes 12 700 lookups instead of 23 000; applications open 10-20 % sooner. |
| `12eb998a63` ★ | `strtold()` for long double formats wider than double | `strtold.c` was a 1999 stub returning `strtod()`. It now builds glibc's `strtod.c` template for long double, as glibc's ldbl-128/ldbl-96 files do (NaN payload setter chosen by `LDBL_MANT_DIG`); `wcstold.c` shares it. QEMU: 221 of 221 checks against aarch64 glibc (99 failures before), 20 000 `%.36Lg`/`%La` round trips exact. |
| `c8c59043a7` ★ | `strtod()` family sets ERANGE when rounding overflows | A value that overflows only by rounding returned ∞ without ERANGE — in `strtold` (x87, found on x86-64, R3) and in upstream's `strtod`/`strtof` too. |
| `73ba44df00`, `69c0374b42` ★ | `strtod()`: signs, `nan()`, ties, underflow | Fixes in the shared template found against glibc: sign of `-0` and `-nan`, `nan(...)` end pointer and quiet bit, half-subnormal ties to even, ERANGE and the sign on underflow to zero. |
| `46a18aecb4` | `strtod_l()`, `strtof_l()`, `strtold_l()` | The conversions with an explicit locale (the thread switches to it for the call). NumPy uses `strtold_l()` and falls back to `strtod()` without it: with it, numpy's longdouble tests pass on the Pi (6 failures → 0). |

---

## Outside this repository

Some of the port lives in other trees: the haiku-pi/mesa fork (the Haiku winsys for v3d/v3dv,
OpenGL ES contexts in `BGLView`, a Vulkan WSI for Haiku windows) and patches the coordination repo
carries in [../patches/](../patches/). Those patches are for U-Boot (GENET transmit delay for
`rgmii-rxid`, BGR pixel order, no 1 ms wait after each EMMC2 command), FFmpeg (the rpivid hwaccel), SDL2, the Vulkan loader, Firefox,
HaikuWebKit, CPython, Rust and the game ports. They reach the Haiku image as the binary packages in
the table below.

Mesa fixes found on the Pi that are bugs upstream too (haiku-pi/mesa `rpi4`, upstream-ready messages):
`be833ed6d67` (V3DV: a render pass's supertiles stored over pixels outside its area — tiled texture uploads
lost data), `dee7e96cb04` (V3D compiler: a vector `mov` copied only its first channel), `f55f89ccad9`,
`baaaeaef308`, `76543fafdfc` (V3D compiler: liveness and copy propagation in linear passes — large shaders
compile 3.6× faster, identical code).

---

## Appendix: arm64 package-repository changes

`build/jam/repositories/HaikuPorts/arm64` lists the binary packages an arm64 image is built from.
Upstream lists only a bootstrap set. Each row below adds or bumps packages that the coordination
repo builds and publishes. The notes say what a bump fixed, where it fixed something.

| commit | packages | note |
|---|---|---|
| `2cd8e0172d` | mesa, glu | Enables jam's mesa and glu features (GLTeapot, GLInfo, libglut, the GL screen savers). |
| `59b38453cc` | libogg, libvorbis, fluidlite; any-arch fonts, sounds, soundfont, user guide, welcome | Enables the libvorbis and fluidlite features, so libmidi and the Media preferences build. |
| `8863edb50b` | bzip2, gzip, tar, unzip; any-arch intel/ralink/realtek WiFi firmware | Required by the regular `haiku` package. |
| `fb08bb7851` | libsdl2 | |
| `a5c947c552` | ffmpeg6 | Enables the ffmpeg media plugin. |
| `0c7a0c1d0b` | zstd | Without the zstd feature packagefs could not read the zstd-compressed any-arch packages, and package_daemon reported their dependents unsatisfiable. |
| `568ddfe0ec` | NetSurf and its libraries; curl 8.22 with OpenSSL 3 | Replaces the bootstrap curl, which has no TLS. |
| `391b5c1504` | HaikuWebKit 1.10 and its libraries (brotli, dav1d, lcms, libavif, libwebp, libxml2, libxslt, sqlite, woff2, …) | Enables WebPositive and the WebP and AVIF translators. |
| `03fa563d38` | icu74_bootstrap shim | **Superseded** by `5f8581cdae`. |
| `cdec11abc7` | libsdl2 2.32.10-2 | Vulkan windows on Haiku ([../patches/libsdl2/](../patches/libsdl2/)). |
| `08d48f271e` | python3.14 3.14.8 | |
| `6b8ae096fb` | mesa 26.2.0-2, libsdl2 2.32.10-3 | `BGLView` makes OpenGL ES contexts, and SDL asks for them. |
| `1fa21827b6` | mesa 26.2.0-3 | Programs may exit with GL views still alive. |
| `0c39179030` | firefox 157.0.1-1 | |
| `415b160d18` | libsdl2 2.32.10-5 | SDL's Haiku looper thread ran window-event handlers concurrently with the application thread, so fullscreen starts crashed with "double free" in `SDL_AddDisplayMode()`. The handlers now run in `SDL_PumpEvents()`, and display modes keep their own copy. |
| `167ad048f9` | openarena 0.8.8-1, supertuxkart 1.5-1 | Added to images only with `-sHAIKU_PI_GAMES=1`. |
| `88fd22f669` | python3.14 3.14.8-2, libedit, ncurses6_bootstrap shim | readline on libedit, `_curses`/`_curses_panel`. The shim makes the terminfo path the ncurses6 bootstrap package expects exist. |
| `da96c5cde3` | firefox 157.0.1-3 | Firefox's GL provider loaded `libGL.so` (the `_devel` link) and created a desktop GL 2.1 context, too old for WebGL. It now loads `libGL.so.1` and creates an OpenGL ES context when desktop GLSL is older than 1.50. WebGL 1 and 2 on the V3D ([../patches/firefox/](../patches/firefox/)). |
| `5f8581cdae` | icu74 74.1-1 | ICU with its data in libicudata, as Linux distributions build it, replacing the bootstrap ICU and its shim. |
| `6aa2792481` | mesa 26.2.0-5, glu 9.0.3-5 | Rebuilt with a toolchain that links libgcc_s: libEGL_mesa and libGLU had private unwinders for the C++ exceptions they throw and catch. The package now also ships the V3DV ICD manifest (`add-ons/vulkan/icd.d`); before, Vulkan worked only from a staging tree. |
| `a4f0d50da1` | firefox 157.0.1-4 (zstd), openarena 0.8.8-2 + openarena_data_1..5, supertuxkart 1.5-2 + supertuxkart_data_1..3 | Firefox zstd-compressed (112 → 102 MB) and the games' data split into parts, each under GitHub's 100 MiB file limit: all three published (owner, 10-21). |
| `0c09391cfc` | ncurses6 6.6-1 | Built with the packaged prefix ([../scripts/build-ncurses.sh](../scripts/build-ncurses.sh)), so the terminfo database is `/boot/system/data/terminfo`. It replaces the bootstrap ncurses6 and the shim that gave it its database path. |
| `b59f1c957f` | gcc 16.2.0_2026_11_01-1, binutils 2.46.1-1, make 4.4.1-1 | The development image (`-sHAIKU_PI_DEV=1`) gets the native GCC 16.2 and released binutils and make instead of the bootstrap gcc 13.3, binutils 2.41 and make of the arm64 bring-up ([design/native-gcc.md](design/native-gcc.md)). |
| `461104856d` | mesa 26.2.6-2 (GCC 16.2) | GPU stage 6: full-screen GL frames flipped on an overlay plane (vsync'd flips with swap interval 1, a mailbox of four buffers with 0) and libglvnd's `hgl_native_window_shows_overlays()` ([design/gpu-stage6.md](design/gpu-stage6.md)). |
| `162164220d` | mesa 26.2.6-3, libsdl2 2.32.10-6 | Windowed GL frames paced to the display with swap interval 1 (mesa 1595aba36ec) and the v3d variant-cache hash without BLAKE3 (ebf1ee1ff1b); SDL2 passes the program's `SDL_GL_SetSwapInterval` on (it always swapped unsynchronised): games that ask for vsync run at the display rate ([design/perf-round-h20.md](design/perf-round-h20.md) N3). |
| `bb0cbab1f7` | mesa 26.2.0-6, glu 9.0.3-6, openarena 0.8.8-4 | mesa: the EGL driver's presenter thread no longer ends on an interrupted semaphore wait (a program whose signal handler ran on that thread then waited for it at its next frame for ever). openarena: ioq3's SIGTERM handler returns instead of running on into `Sys_Error()`. |
| `cb96327eec` | mesa 26.2.5-1 | |
| `f16c822de5` | mesa 26.2.5-3 | The on-disk shader cache (a GL program's shaders compile once, not at every start). |
| `45785f05b0` | mesa 26.2.5-4 | `eglTerminate()` with a context still current no longer crashes. |
| `cf29e72177` | mesa 26.2.5-5 | V3DV partial-supertile stores fixed; faster GL presents. |
| `92f6a1d35e` | mesa 26.2.5-6 | V3D compiler: vector movs copied whole (an upstream bug); BGLView draws asynchronously. |
| `c1b67144b7` | mesa 26.2.5-7 | V3D compiler: 3.6× faster compiles of large shaders. |
| `b97baf3706` | gcc_syslibs 13.3.0 bootstrap-2 | Rebuilt with GNU hash tables and `-Bsymbolic-functions`. |
| `821aaf239d` | mesa 26.2.6-1 | Mesa 26.2.6. |
| `d2fd8ddf8b` | gcc_syslibs 16.2.0 | The GCC 16.2 C++ runtime (libstdc++ 6.0.36), a superset of 13.3's. |
| `d7d6924a6e` | firefox 157.0.1-5 | getentropy() for random bytes, GNU hash tables |
| `b195a41e64` | firefox 157.0.1-6 | libxul.so linked with `-z pack-relative-relocs` (DT_RELR): 11.7 MB of relative relocations become 0.11 MB, so a start reads and applies far fewer (cold start from BFS −1.85 s, warm −0.8 %; [design/perf-round-h20.md](design/perf-round-h20.md) C1). The package `requires` `haiku >= r1~beta6_hrev60295_178`, the first with the DT_RELR runtime_loader (`4539cd2f00`). 102.4 → 100.9 MB. |

`e98b67a5bd` and `be395e19f4` (section 8) also bump ffmpeg6, to 6.1.6-2 and 6.1.6-3.
