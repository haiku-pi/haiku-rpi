# VCHIQ on Haiku (H21 step 1): `/dev/vchiq` from FreeBSD's BSD-3 port

Status (2026-11-05): **step 1 works on the Pi** — branch `vchiq` (worktree `sources/haiku-vchiq`, pushed, not
merged): `/dev/vchiq`, the firmware handshake, message round trips (gencmd), the ioctl ABI driven by Broadcom's
unchanged libvchiq, bulk transfers both ways (functional test and echo up to 1 MiB, misaligned), clients killed
mid-transfer. §6 has the results and what step 2 starts from.
Plan: `PLAN.md` row 7 (H21); the licence survey is `hw-video-decode.md` §0a.

Citation keys:
- **[F]** FreeBSD `sys/contrib/vchiq` at `7806832f23fb` (last change to the directory `97e24b41d2d2`, 2026-08-21;
  arm64 support `aa6b871ea77e`, 2025-11-15). Broadcom/Raspberry Pi files dual BSD-3-Clause or GPL-2.0, used
  under BSD-3; `compat/vchi_bsd.[ch]` and `vchiq_kmod.c` BSD-2 (Khon, Tymoshenko, McNeill); `compat/list.h` BSD-2
  (NetBSD Foundation). Clone: `external/freebsd-src` (sparse).
- **[U]** raspberrypi/userland at `a54a0dbb2b8d` (2024-12-23; the repository is archived): `interface/vchiq_arm`
  (libvchiq), `interface/vmcs_host/vc_vchi_gencmd.c` (the GCMD client), BSD-3-Clause. Clone: `external/userland`.
- **[DTS]** the firmware's `bcm2711-rpi-4-b.dtb` (`artifacts/pi-firmware/`).
- **[H]** `sources/haiku` (`rpi4`).
- Linux (raspberrypi/linux `vchiq_arm.c`, `vchiq-mmal`, `bcm2835-codec`, `vc-sm-cma`): facts about behaviour
  only. No Linux code is used; the GPL-only pieces are not read for code.

## 0. Summary

- VCHIQ is a pair of message queues in shared memory between the ARM and the VideoCore (VC) firmware, plus a
  doorbell in each direction. Services (4-character codes: `GCMD` gencmd, `mmal` the multimedia components,
  `KEEP` keep-alive, `AUDS` audio, `TVCH`, `smem`...) are opened over it; small messages travel in the slots,
  large payloads as bulk transfers that the VC's DMA copies to or from page lists.
- The ARM side is the "slave": it allocates the slot memory, initialises slot zero, then tells the firmware the
  slots' bus address with the mailbox property tag **`VCHIQ_INIT` (0x00048010)**. From then on the firmware owns
  part of that memory for good: it is never freed.
- The port keeps [F]'s core unchanged except where Haiku needs it (`#ifdef __HAIKU__`), and replaces FreeBSD's
  OS layer with Haiku code. The ioctl ABI is that of [F]/Linux (`vchiq_ioctl.h`) with Linux's return
  conventions, so step 2 can build Broadcom's libvchiq/libmmal [U] with no change other than the ioctl
  encoding header (§4).
- First proof: the kernel opens `GCMD` and asks `version`; the reply text is in the device's `read()`
  (`cat /dev/vchiq`). Second proof: a small userland test drives the same round trip through the ioctls.

## 1. How VCHIQ starts on the Pi 4

From [DTS], [F] and Linux's documented behaviour:

| What | Value |
|---|---|
| DT node | `/soc/mailbox@7e00b840`, `compatible = "brcm,bcm2711-vchiq"` (older boards: `"brcm,bcm2835-vchiq"`) |
| Registers | `reg = <0x7e00b840 0x3c>` → CPU 0xfe00b840 through `/soc` "ranges" |
| Doorbells | at the node's base: **+0x00 BELL0** (VC → ARM; reading returns the status and clears it; bit 2 = rung), **+0x08 BELL2** (ARM → VC; writing 0 rings it). [F] uses offsets 0x40/0x48 with `regs_offset = -0x40` for every compatible but the old `"broadcom,bcm2835-vchiq"` |
| Interrupt | `interrupts = <0 0x22 4>`: GIC SPI 34, level (VC rings BELL0) |
| DMA | `/soc dma-ranges = <0xc0000000 0x0 0x0 0x40000000 ...>`: the VC sees ARM RAM below 1 GiB at bus 0xC0000000 + physical. The slots, fragments and page lists must be below 1 GiB; every address the VC is given for them is the 0xC alias |
| Bulk page addresses | bcm2711 ("long bulk space", [F] `g_long_bulk_space`): page list entries hold the **physical** address >> 4 with the run length (pages − 1) in the low 8 bits — 36-bit physical addresses, no alias; older SoCs: bus address | run, 4 KiB runs |
| Cache line | 64 bytes on arm64 ([F] `g_cache_line_size`); fragments are 2 × 64 bytes |
| Init | property tag `0x00048010`, one value: the slots' bus address; the firmware answers 0 when it accepted the slots. [F] writes the same address to mailbox channel 3 instead; we use the property interface (`generic/bcm2835_mailbox` already does it) and keep channel 3 as a fallback if the tag is refused |

**Coherency.** The VC does not snoop the ARM caches. Linux allocates the slots with `dma_alloc_coherent`, i.e. a
non-cacheable mapping; we map them `B_WRITE_COMBINING_MEMORY` (Normal non-cacheable on arm64), as `rpivid` does
for its DMA memory, after writing back and dropping the lines the clearing left. The core's `wmb()/rmb()/dsb`
calls are the ordering. No atomic instruction ever touches the shared memory (the core's atomics are on local
state only), so non-cacheable memory without a global exclusive monitor is fine.

**Order** ([F] `vchiq_platform_init`): allocate slots + fragments → `vchiq_init_slots()` (slot zero: magic,
version, slot ranges, and `platform_data[]` = fragments' bus address and count) → `vchiq_init_state()` (threads:
slot handler, recycle, sync) → `VCHIQ_INIT` → the firmware fills in its half (`remote->initialised = 1` by the
time the synchronous property call returns). Then a client's `CONNECT` queues a CONNECT message; the VC answers
CONNECT and the state becomes CONNECTED; then `OPEN` of a service by fourcc.

## 2. The Haiku pieces

Directory `src/add-ons/kernel/drivers/misc/vchiq/` (new-style FDT driver like `video/rpivid`):

```
vchiq_haiku.cpp              driver + device modules (replaces [F] vchiq_kmod.c): FDT attach, doorbell
                             interrupt, remote_event_signal(), the VCHIQ_INIT property call, DMA memory
                             helpers, page locking for bulks, device hooks → vchiq_arm.c
vchiq_haiku.h                the C interface between the C++ glue and the C core
interface/compat/vchi_haiku.{h,cpp} Linux-flavoured primitives on Haiku's (replaces [F] vchi_bsd.[ch])
interface/compat/list.h      [F] (NetBSD), unchanged
interface/vchiq_arm/*        [F] core, ported in place (#ifdef __HAIKU__ where needed)
interface/vchi/vchi_mh.h     [F], unchanged
```

- **Attach**: `support()` matches `fdt/compatible` against both compatibles; `init_driver()` reads `reg`, the
  interrupt and the DMA window (`fdt_device_module_info::get_dma_window`: offset 0xC0000000, end 0x40000000 — logged)
  and does nothing else. **The firmware handshake happens at the first `open()`**, not at boot: a system that
  never opens `/dev/vchiq` only has the driver loaded (~130 kB of code, a few hundred bytes of data; the core's
  state, ~460 kB with a semaphore per possible service, is allocated at the first open), and nothing the firmware
  does with the slots can disturb a boot. Once initialised, the state is permanent (`B_KEEP_DRIVER_LOADED`, no
  uninit path that frees the slots: the VC keeps writing them).
- **Device**: published as `vchiq` (`/dev/vchiq`, Linux's and FreeBSD's path). One `open()` = one
  `VCHIQ_INSTANCE_T` ([F] `vchiq_open`), freed in `free()` ([F] `instance_dtr`).
- **Interrupt**: `install_io_interrupt_handler()` on the node's interrupt, after the handshake (the level
  interrupt stays pending until BELL0 is read). The handler reads BELL0; if bit 2 is set it calls
  `remote_event_pollall()`, which only flips flags in the shared memory and `up()`s semaphores (a spinlock and a
  condition variable notification, safe in an interrupt), and returns `B_INVOKE_SCHEDULER`.
- **Slots**: one physically contiguous area below the DMA end, `TOTAL_SLOTS * 4 KiB` + fragments
  (`VCHIQ_SLOT_ZERO_SLOTS + 2 × 32` slots = ~ 288 KiB), write-combining.
- **Threads**: the core's slot handler (`VCHIQ-n`, Linux nice −19 → `B_URGENT_DISPLAY_PRIORITY`), recycle
  (`VCHIQr-n`), sync (`VCHIQs-n`) and the keep-alive thread (`VCHIQka-n`, after the first connection) are kernel
  threads (`spawn_kernel_thread`, started by `wake_up_process()` = `resume_thread()`).
- **Bulk transfers** (needed by MMAL, not by GCMD): `vchiq_prepare_bulk_data()` locks the user buffer
  (`lock_memory_etc(team, B_READ_DEVICE)` for a receive), takes its physical runs (`get_memory_map_etc`),
  writes a page list into a small non-cacheable contiguous allocation below 1 GiB, cleans (transmit) or flushes
  (receive) the buffer's lines through the kernel's physical map (`KERNEL_PMAP_BASE + physical`);
  `vchiq_complete_bulk()` (called from the slot handler, another address space) flushes a receive again, copies
  the head/tail fragments of a receive that is not cache-line aligned, and unlocks the memory. This mirrors
  [F]'s arm64 code, which keeps the cache lines of a receive invalidated twice for the same reason (speculative
  fills while the VC writes). A bulk buffer must lie in one area (a `malloc()`ed one does).
- **A client that dies with transfers queued** (found on the Pi: a `kill -9` during `vchiq_test -b` panicked in
  `VMCache::Delete`, "page still has mappings"): Haiku deletes a team's areas (`team_delete_team` →
  `RemoveAndPut`) *before* its files are closed (`~Team` → `vfs_put_io_context`), and an area must not be wired
  when it goes, while the VC may still be writing the buffer and only the file's close ends the transfers. The
  driver listens to `TEAM_REMOVED` (sent before the areas go): each locked buffer of that team moves to a kernel
  clone of its area (`vm_clone_area(REGION_NO_PRIVATE_MAP)` shares the area's cache), locked there before the
  team's lock is dropped; the clone keeps the pages until the transfer ends — Linux keeps page references for the
  same reason. Not cloned at queue time: cloning marks the source area `B_SHARED_AREA`, which would make a
  client's heap shared with its children after a `fork()`. Not covered: `exec()` while transfers are queued
  (`exec_team` deletes the areas before any notification); an aborted bulk the VC never acknowledged (the core's
  dummy bulk drops `remote_data`) leaks its page list and lock, as in [F] and Linux.

## 3. The FreeBSD OS layer and its Haiku replacement

| [F] | Haiku |
|---|---|
| `vchiq_kmod.c`: simplebus probe/attach, `bus_alloc_resource`, `bus_setup_intr`, `bcm_vchiq_intr`, `remote_event_signal` (dsb + write BELL2) | `vchiq_haiku.cpp`: driver module (`support`/`register_device`/`init_driver`/`register_child_devices`), `map_physical_memory` of the registers, `install_io_interrupt_handler`, the same two functions |
| `vchiq_2835_arm.c`: `bus_dma` coherent allocation, `bcm_mbox_write(chan 3)`, `vm_fault_quick_hold_pages`, `pmap_quick_enter_page`, `cpu_dcache_*` | same file, ported: `vchiq_haiku_dma_alloc()` (`create_area_etc(B_CONTIGUOUS)` + `vm_set_area_memory_type`), the `VCHIQ_INIT` property tag, `lock_memory_etc`/`get_memory_map_etc`, `arm64_dcache_{clean,flush}_range` on the user VA and the physical map |
| `vchiq_arm.c` cdev: `make_dev`, `devfs_set_cdevpriv`, `d_ioctl` with the kernel's copyin of the argument | `vchiq_arm.c` with `#ifdef __HAIKU__`: `vchiq_haiku_open/free/ioctl` called from the device hooks; the hook copies the argument in and out by `IOCPARM_LEN(op)` (§4) |
| `vchi_bsd.h` `struct semaphore` (mtx + cv) | a count under a spinlock + a `ConditionVariable` kept inside the structure (`vchi_haiku.cpp`), **not** kernel semaphores: the core makes one per possible service (`VCHIQ_MAX_SERVICES` = 4096 quota events), which would hold 4096 of the system's 65536 kernel semaphores for good. `up()` is interrupt-safe (the doorbell handler); an interrupted waiter passes a wake-up it may have consumed on |
| `struct mutex` (sx) / `lmutex_*` | Haiku `mutex` (the same `struct mutex` name); `lmutex_lock_interruptible` = `mutex_lock_with_timeout(B_CAN_INTERRUPT, 0)` |
| `spinlock_t` (sleep mtx) | Haiku `mutex`, as in [F]: nothing takes one from the interrupt handler (the handler only `up()`s) |
| `rwlock_t` (rw) | `rw_lock` |
| `struct completion` (mtx + cv) | the same: a count (−1 after `complete_all`, every wait succeeds) under a spinlock + a `ConditionVariable`; only the keep-alive event and the (unused) suspend machinery use them |
| `struct timer_list` (callout) | stubs that log: the only timer is the suspend timer, and `vchiq_platform_use_suspend_timer()` is 0 |
| `kproc_create` (`vchiq_thread_create`) | `spawn_kernel_thread` (suspended until `wake_up_process`) |
| `current`, `current->p_pid` | `find_thread(NULL)`: Linux keys bulk waiters on the task, i.e. the thread |
| `fatal_signal_pending` | `thread_is_interrupted(thread_get_current_thread(), B_KILL_CAN_INTERRUPT)` |
| `flush_signals`, `set_user_nice` | no-op / `set_thread_priority` |
| `kmalloc`/`kzalloc`/`kfree` | `calloc`/`free` |
| `copy_from_user`/`copy_to_user` | `user_memcpy` (0 or `-EFAULT`) |
| `jiffies`, `HZ`, `msecs_to_jiffies`, `udelay`, `msleep` | `system_time() / 1000`, 1000, identity, `spin`, `snooze` |
| `wmb/rmb/mb`, `dsb(sy)` | `dsb st` / `dsb ld` / `dsb sy`, Linux's mandatory barriers on arm64 (the VC is outside the inner shareable domain; the shared memory is not cacheable) |
| Linux `-EINVAL` style returns | Haiku's POSIX errors are already negative: the core's `-EXXX` become `EXXX` (50 sites in `vchiq_arm.c`, 2 in `vchiq_core.c`, the rewritten `vchiq_2835_arm.c`), mechanically |
| `PHYS_TO_VCBUS`, `g_long_bulk_space` | the node's DMA window (`get_dma_window`); "long bulk space" for `brcm,bcm2711-vchiq` |

Not ported: `vchiq_debugfs.c`, `vchiq_version.c`, the `/proc` and `dump_phys_mem` stubs (`DUMP_PHYS_MEM` returns
`B_UNSUPPORTED`), the COMPAT_FREEBSD32 ioctls, suspend/resume (the VC is always wanted; FreeBSD and Linux on
the Pi do the same).

## 4. The ioctl ABI

- Numbers and structures: [F] `vchiq_ioctl.h` = [U] `vchiq_ioctl.h` (the structures are identical; LP64 on both
  sides). The numbers are built with `_IO/_IOW/_IOWR` from `<sys/ioccom.h>` (BSD layout, Haiku's
  `headers/compatibility/bsd`); [U] includes `<linux/ioctl.h>` instead. **Step 2 builds libvchiq with a
  `linux/ioctl.h` that includes `<sys/ioccom.h>`** — the only change libvchiq needs.
- Haiku's `ioctl(fd, op, ...)` takes a size argument libvchiq does not pass, so the driver ignores `length`: for
  `_IOW/_IOWR` it copies `IOCPARM_LEN(op)` bytes in, runs [F]'s handler on the kernel copy and copies the
  structure back for `_IOWR`; for `_IO` the argument is the value itself (a service handle or the library
  version) — [F] reads `LIB_VERSION`'s value from the argument pointer, which is the kernel copy's address there
  (a FreeBSD bug that always enables CLOSE_DELIVERED); Haiku uses the value.
- Return values follow Linux, which [U] relies on: `AWAIT_COMPLETION` returns the number of completions,
  `DEQUEUE_MESSAGE` the message size, `GET_CLIENT_ID` the id; errors are negative Haiku codes (`ioctl()` returns
  −1 with `errno`). A positive `status_t` from a driver's `control()` reaches the caller of `ioctl()` unchanged
  (`devfs_ioctl` → `fd_ioctl` → `RETURN_AND_SET_ERRNO`). [F] instead writes the counts into the structures and
  returns 0 (its userland is patched for that).

## 5. Test plan

Network boots only (`scripts/netboot-cycle.sh` / `scripts/pi-session.sh`, under the bench lock); the SD card is
never touched.

1. **Attach**: boot log `vchiq: registers ..., interrupt N, DMA offset 0xc0000000 below 0x40000000`,
   `publish device: ... path vchiq`. Nothing else happens at boot.
2. **Handshake** (first open): `vchiq: slots at bus 0x..., VCHIQ_INIT answered 0, remote initialised 1`.
3. **Connection + GCMD from the kernel**: reading `/dev/vchiq` opens an instance, connects, opens `GCMD`
   (version 1, as [U]'s gencmd client), queues `"version\0"` and waits for the reply: an int32 error code, then
   text ([U] `vc_gencmd_read_response`). `cat /dev/vchiq` prints the doorbell count, the connection state and the
   firmware's version text. Then `get_mem arm` / `get_mem gpu` / `measure_temp` as further commands (the text can
   be compared with the mailbox's answers: same memory split, same temperature).
4. **The ioctl ABI by hand**: `tools/haiku-tests/vchiq-gcmd.c`: a completion thread in `AWAIT_COMPLETION`
   answering `SERVICE_CLOSED` with `CLOSE_DELIVERED` (as libvchiq's), `LIB_VERSION`, `CONNECT`, `GET_CONFIG`,
   a VCHI-style `GCMD` service (`QUEUE_MESSAGE` + `DEQUEUE_MESSAGE`), a plain one (reply through
   `AWAIT_COMPLETION`), `CLOSE_SERVICE`, `SHUTDOWN`.
5. **Broadcom's libvchiq and `vchiq_test`** ([U], built by `scripts/build-vchiq-test.sh`): the firmware has
   vchiq_test's server services built in ("func", "echo"), so `-f` (functional), `-b` (bulk echo, with `-a`/`-A`
   client/server misalignment), `-c` (control) and `-p` (ping) run against it — the bulk path, both directions,
   fragments included, without MMAL. Then clients killed with transfers queued. All of it:
   `tools/pi-tests/vchiq.sh` ("VCHIQ result: N problems").
6. **No regression**: `scripts/release-check.sh` on an image of the branch (0 problems).
7. Later (step 2): MMAL components (`vc.ril.video_decode`) on libmmal.

## 6. Progress

### 2026-11-05: step 1 done on the Pi (network boots; branch `vchiq`)

Commits on `vchiq` (base `rpi4` 44cc183c0c): `6c2778b0b1` import of [F] (verbatim) · `2252a8dc97` the port ·
`34660bcc50` packaging · `10807a2f0c` semaphores without kernel semaphores · `a0ffe46806` state allocated at the
first connection · `f47b5639b5` buffers of a dying team · `6e8be068c5` a log line for that case.

- **Attach** (boot log): `vchiq: doorbells 0xfe00b840, interrupt 66, DMA offset 0xc0000000 below 0x40000000,
  36-bit bulk addresses` and `publish device: ... path vchiq` — `/dev/vchiq` at the root, as on Linux (the root
  scan at boot probes every driver directory).
- **Handshake** (first open): `VCHIQ_INIT with slots at bus 0xc1d79000: No error (answer 0x0)`, `local ver 8 (min
  3), remote ver 8`.
- **GCMD round trip, kernel side** (`cat /dev/vchiq`):
  `gencmd version: (0) Oct 15 2026 14:15:04 / Copyright (c) 2012 Broadcom / version
  df9569873467b7e6383f1073788144864249d65f (clean) (release) (start)`, `get_mem arm: arm=948M`, `get_mem gpu:
  gpu=76M`, `measure_temp: temp=48.7'C`; then the core's state dump (`State 0: CONNECTED`, services GCMD and KEEP).
- **ioctl ABI by hand** (`vchiq-gcmd`): every step ok, `DEQUEUE_MESSAGE` returns 129 / 13 (the sizes),
  `AWAIT_COMPLETION` delivers the plain service's reply (`temp=50.6'C`) and the `SERVICE_CLOSED` completions,
  answered by `CLOSE_DELIVERED`; `VCHIQTEST end: PASS`.
- **Broadcom's libvchiq + `vchiq_test`** (`tools/pi-tests/vchiq.sh`, `VCHIQ result: 0 problems`):
  `-f 1` functional test passes (all of it: bulk sizes 1–63 bytes at every client/server alignment, at the page
  boundary, 64 B–16 KiB with misalignment; three runs in a row, also after the kills); bulk echo: 1 KiB 196 µs,
  64 KiB 288 µs, 1 MiB 7.3 ms per round trip (sent and received back: ~140 MiB/s each way), misaligned (`-a 3 5`, `-a 31 1`, `-A 100 7`)
  all fine; `-c 1000` 50 µs per message; ping ok. Clients killed during 1 MiB bulks, 1 KiB bulks, pings and control
  floods: no clone left, the next bulk test passes, only GCMD and KEEP remain. 136 725 doorbell interrupts in one
  run.
- **Found and fixed on the Pi**: a client killed with bulks queued panicked the kernel (`VMCache::Delete`: page
  still has mappings): Haiku deletes a team's areas before closing its files (§2, "A client that dies").
- **The `-f` failure of the first session** ("no more listeners" at vchiq_test.c:833) came after a client was
  killed in the middle of a functional test by a VCOS assertion (below); on a fresh boot and after the kill matrix
  it passes every time.
- **The dying-team path, seen**: a client killed during a 1 MiB bulk — `vchiq: team 490 went away with a bulk
  transfer queued: its 1048576 bytes are kept until the transfer ends`; no clone left afterwards, the next tests pass
  (head `6e8be068c5`, `tools/pi-tests/vchiq.sh`: 0 problems).
- **No regression**: `scripts/release-check.sh` on the branch's image (regular `@pi-mmc` with GL, `f47b5639b5`):
  `REL result: 0 problems` (launch cycles 24, 0 debugger entries) — that check never opens `/dev/vchiq`, i.e. the
  driver as every user gets it.

### What step 2 (libmmal) starts from

- libvchiq and VCOS (pthreads) build for Haiku from [U] unchanged except: the `linux/ioctl.h` / `linux/param.h`
  shims (`tools/haiku-tests/vchiq-shim`), `-std=gnu11` (K&R prototypes vs C23), and **two zero-initialised objects
  that only Linux accepts**, patched by `scripts/build-vchiq-test.sh` and to be carried as patches:
  `vcos_pthreads.c`'s `current_thread_key_once` (Haiku's `PTHREAD_ONCE_INIT` is `{ -1 }`: the thread key is never
  made, `vcos_init()` aborts) and `vchiq_lib.c`'s function-local `static VCOS_MUTEX_T vchiq_lib_mutex` in
  `vchiq_lib_init()`, which shadows the global one that `alloc_msgbuf()` etc. lock (libroot asserts on a zeroed
  `pthread_mutex_t`). Expect more of the same kind in libmmal (grep for zeroed `VCOS_ONCE_T` / mutexes).
- The firmware has MMAL (`vc.ril.video_decode` strings in `start4.elf`), and the vchiq test server — use
  `vchiq_test -f` as the first regression check of any driver change.
- Next: libmmal (`interface/mmal`: core, vc client, util) as a Haiku package or port; `mmal_vc_api` opens the
  "mmal" service over this driver; a first `vc.ril.video_decode` H.264 decode to memory with bulk-copied buffers
  (no zero-copy: `vc-sm-cma` is GPL; our own buffer import later).
- Open: `exec()` while bulk transfers are queued still hits the wired-area assertion (no notification before
  `exec_team` deletes the areas); an aborted bulk the VC never acknowledged leaks its lock, as in [F]/Linux.
