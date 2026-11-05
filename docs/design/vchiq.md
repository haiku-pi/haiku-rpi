# VCHIQ on Haiku (H21 step 1): `/dev/vchiq` from FreeBSD's BSD-3 port

Status (2026-11-05): **step 3 works on the Pi** (§8: H.264 through the media kit on the VideoCore — MediaPlayer and
WebPositive, `h264_mmal` with the plugin's software fallback, the H.264 clock held; branch `h264-mmal`, not merged).
Step 2 (§7: Broadcom's libmmal on Haiku, H.264 decoded by the VideoCore,
1080p at 53–72 fps for ~4 % of the system's CPU, frames equal to ffmpeg's but for a firmware footroom quirk).
Step 1 — branch `vchiq` (worktree `sources/haiku-vchiq`, pushed, not
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

## 7. Step 2: libmmal on Haiku and H.264 decoded by the VideoCore

Status (2026-11-05): **works on the Pi** (network boot of the `vchiq` branch image, `6e8be068c5`; no driver change
was needed for step 2). Broadcom's MMAL, libvchiq and VCOS [U] run on arm64 Haiku; `vc.ril.video_decode` decodes
H.264 Annex-B streams to I420 frames that come back by VCHIQ bulk transfers; every frame of three test streams is
checked against ffmpeg's software decode (§7.4).

### 7.1 Packaging

- Recipe `tools/recipes/media-libs/raspberrypi_userland/raspberrypi_userland-20241223.recipe` ([U] at
  `a54a0dbb2b8d`, BSD-3-Clause, `ARCHITECTURES="arm64"`), patchset beside it. Two packages:
  `raspberrypi_userland` (libvcos, libvchiq_arm, libmmal_core, libmmal_util, libmmal_vc_client, libmmal: the
  CMake build's names and sonames) and `raspberrypi_userland_devel` (headers under
  `develop/headers/raspberrypi_userland`, `mmal.pc`).
- Not built: vcsm (zero-copy buffers need the GPL vc-sm kernel driver), the ARM-side MMAL components, the
  containers, OpenMAX IL, bcm_host, the Linux host programs. [U]'s CMake build leaves MMAL out on 64-bit hosts; the
  patchset's `makefiles/haiku/Makefile` builds only the libraries.
- `scripts/build-mmal.sh` cross-builds it (`scripts/cross-port.sh ... script`, into the sysroot's `non-packaged/`),
  fails on any compiler warning but [U]'s own two (`vchiq_use_service`/`vchiq_release_service` declared with
  `VCHIQ_STATUS_T` and `int32_t`), runs the ABI check (§7.2), builds `tools/haiku-tests/mmal-h264.c` and copies the
  libraries to `artifacts/mmal/lib` for a test session; `--package` makes the two hpkgs
  (`scripts/package-port.py`; moved to `artifacts/mmal/packages/`, **not** left in the published
  `artifacts/packages/` while the driver is on an unmerged branch; package-port.py also extracts both into the
  sysroot's `boot/system/`, so later cross-builds find libmmal there as well as in `non-packaged/`); `--clips` makes the test streams and ffmpeg's reference hashes.

### 7.2 The patches (`raspberrypi_userland-20241223.patchset`, 7 commits on [U])

1. **vcos: `VCOS_ONCE_INIT`** for `current_thread_key_once` (`vcos_pthreads.c`) and `cmd_globals.initialized`
   (`vcos_cmd.c`): zeroed `pthread_once_t`s, which are `PTHREAD_ONCE_INIT` only on glibc (Haiku: `{ -1 }`; the
   thread key was never made and `vcos_init()` aborted).
2. **vchiq_arm: no shadowed `vchiq_lib_mutex`**: `vchiq_lib_init()`'s function-local static hid the file-scope
   mutex that `alloc_msgbuf()`, `vchiq_close_service()` etc. lock, so that one was never created (a zeroed
   `pthread_mutex_t` works on glibc; libroot asserts).
3. **Haiku support**: `vchiq_ioctl.h` takes `<sys/ioccom.h>` (the driver's BSD ioctl encoding, §4), HZ from
   `<sys/param.h>`, VCOS thread names by `rename_thread()`, the pid in the component-create message.
4. **vchiq_arm: 64-bit clean**: `vchiq_dump_phys_mem()` cast a handle to a pointer; trace formats.
5. **mmal: the VideoCore's message layout on 64-bit hosts** (the big one, ~400 lines). The firmware parses
   `mmal_vc_msgs.h` with the layout of a 32-bit ARM host. Pointers the VC passes back (the reply's waiter, the
   event's client component, a buffer's client context, a delayed event buffer) become 32-bit handles
   (`mmal_vc_handle_alloc/_get/_free`, a 1024-entry table; a waiter's handle is its pool index + 1); embedded
   structures with pointers (`MMAL_PORT_T`, `MMAL_ES_FORMAT_T`, `MMAL_BUFFER_HEADER_T`, `MMAL_DRIVER_BUFFER_T`)
   become `mmal_worker_*` copies with 32-bit fields; a format-changed event is converted from the VC's layout
   to the host's, which is larger (the control port's buffers get the difference); `MMAL_VC_COMP_STATS_T.comp` is a
   `uint32_t`. Static assertions pin every size. `tools/haiku-tests/mmal-abi-check.py` (run by build-mmal.sh)
   dumps clang's record layouts of the unpatched header for 32-bit ARM and of the patched one for 32-bit ARM and
   arm64 and compares size, field offsets and names: `37 structures, all equal`. Linux's kernel MMAL client
   (`vchiq-mmal`) uses the same idea (u32 context handles); no code taken from it.
6. **A Makefile** (`makefiles/haiku/Makefile`) and `mmal.pc`.
7. **mmal: `mmal_vc_shm_exit()` takes `refcount_lock`** — it unlocked a mutex it never locked (an upstream
   race on the count; libroot's mutex refuses the unlock). Added after the first Pi runs.

**The zero-initialised synchronisation objects, all of them** (`grep` of `interface/{vcos,vchiq_arm,mmal}` for
`static` `VCOS_*_T` / `pthread_*_t`): beyond 1 and 2, every other one is created before its first use —
`printf_lock`, the named-semaphore `lock` and the logging `lock` by `vcos_platform_init()` (from `vcos_init()`,
a constructor of libvcos); `mmal_core_lock` (`mmal_component.c`) and `refcount_lock` (`mmal_vc_shm.c`) in a
`vcos_once()` with `VCOS_ONCE_INIT`; `client.lock`/`handles.lock` (`mmal_vc_client.c`) in `init_once()`; all
others are members of allocated objects created by their constructors. `vcos_pthreads.c`'s `lock` uses
`PTHREAD_MUTEX_INITIALIZER`.

### 7.3 The test: `mmal-h264`

`tools/haiku-tests/mmal-h264.c`: reads an Annex-B stream into memory, creates `vc.ril.video_decode`
(`MMAL_COMPONENT_DEFAULT_VIDEO_DECODER`), input H.264 with no size, output I420; feeds the stream in input-port
sized buffers (20 × 80 KiB, unframed) and an end-of-stream buffer; handles the format-changed event (disable the
output port, take the new format, new pool, enable); runs until the output buffer flagged end of stream. `-m`
prints the MD5 of each frame's visible part (crop rectangle, Y then U then V: what `ffmpeg -f framemd5 -pix_fmt
yuv420p` hashes), `-q` only the summary (frames/s; CPU of the team and of the whole system, i.e. including the
kernel's VCHIQ threads), `-f FOURCC` another output encoding (`-f OPQV`: opaque, frames stay on the VideoCore),
`-r N:FILE` writes frame N's raw buffer. `tools/pi-tests/mmal.sh` runs everything ("MMAL result: N problems").

Streams (`build-mmal.sh --clips`, the host's ffmpeg + libx264, High profile, 3 B-frames, CABAC, 300 frames at
30 fps of `testsrc2` + temporal noise): `h264-720p` (1280×720, 6 Mbit/s), `h264-1080p` (1920×1080, 12 Mbit/s;
coded 1920×1088, cropped), `h264-1080p-inrange` (1080p without noise, every source sample clipped to 32–224).

### 7.4 Results (Pi 4, firmware Oct 15 2026, `tools/pi-tests/mmal.sh`: 0 problems)

Sessions `20261105-103359-session-mmal` (the first agent: run 2 = 0 problems), `20261105-192557-session-mmal2`
(patch 7 builds: the whole script again, 0 problems, the same numbers within 1 %; the format dumps) and
`20261105-193208-session-mmal3` (the clock, below). Raw output: `artifacts/mmal/results/`. The table is with the
H.264 block at **250 MHz**, its clock from ~2 minutes after power-on (see "The H.264 clock"):

| Stream | MMAL → I420 copied out | CPU (team / all 4 CPUs) | opaque (no copy) | ffmpeg 1 thread | ffmpeg 4 threads |
|---|---|---|---|---|---|
| 720p | **111 fps** (2.70 s) | 0.21 s = 7.7–9 % of one CPU / 3.6–4.1 % | 112 fps, 1.7 % | 61 fps, 4.9 s CPU | 137 fps, 6.3 s CPU |
| 1080p | **53.0 fps** (5.66 s) | 0.43 s = 7.6–8.3 % of one CPU / 3.6 % | 53.5 fps, 1.4 % | 28 fps, 10.7 s CPU | 66 fps, 14.5 s CPU |
| 1080p in-range | 51.1 fps (5.87 s) | 0.45 s = 7.3–8.1 % / 3.4–3.9 % | 51.5 fps, 1.3 % | 41 fps, 7.3 s CPU | 102 fps, 9.4 s CPU |

- Three timed runs each, within 0.1 %. First frame 44 ms (720p) / 74–89 ms (1080p) after the start. The rates
  with `-m` (15 fps at 1080p, 80 % of a CPU) are the MD5 of every frame, computed in the test's main loop before
  the (single) output buffer goes back to the decoder, not the decoder.
- **The decoder is the limit, not the copies**: the opaque output (no bulk transfer) runs at the same rate. The
  bulk copy of a 3.1 MB frame costs ~166 MB/s of frames at 4 % of the system's CPU (step 1's bulk echo: 4 MiB in
  27.5 ms per round trip). The decoder asks for one output buffer (`buffer_num_recommended` 1, 3 133 440 bytes:
  1920×1088 I420).
- **The H.264 clock.** The first ~2 minutes after power-on (the firmware's boot-time turbo period, the same one
  perf-round-h20.md C0b saw on the ARM) the H.264 block runs at **500 MHz** and the decoder is 1.36–1.4× faster:
  720p **155 fps** (1.93 s), 1080p **72 fps** (4.17 s), measured twice on a fresh boot with `measure_clock h264`
  sampled during each decode; minutes later, same boot, 250 MHz and 111 / 53 fps again (`get_throttled` 0x0,
  52 °C: not heat). Our `bcm2835_cpufreq` never requests turbo, so the firmware runs the block at its minimum. An
  output buffer count of 3 (`-o 3`) or SAND output change nothing (2.697 s either way): the block's clock is the
  limit. At 500 MHz MMAL beats ffmpeg on 4 threads at 1080p (72 vs 66 fps).
- Against ffmpeg on 4 threads: ffmpeg is 23–25 % faster on the noisy clips and 2× on the in-range one, for
  **15–18× the CPU time** of the whole system during the MMAL decode (6.3 s vs 0.42 s at 720p, 14.5 s vs 0.81 s at
  1080p); MMAL is 1.8× (720p) / 1.9× (1080p) faster than one software thread.
- No kernel messages but the handshake; `get_mem gpu` 76 MiB before and after; 55–64 °C over the script.

**Bit-exactness.** Every frame is decoded (300 of 300 in each stream) and the crop (1088 → 1080) and plane
offsets/pitches (`buffer->type->video`: pitch 1920/960/960, offsets 0/2088960/2611200) are right. The I420 frames
equal ffmpeg's **exactly where no decoded sample is below 16** (297 of 300 frames of the in-range clip; the three
others and every frame of the noisy clips have such samples); with every ffmpeg sample `v` in 1…15 replaced by
`v − 1` (0 stays 0, 16…255 unchanged), **all 900 frames are equal**. So the decoded picture is the same; the
I420 output differs by one code value in the footroom below video black.

**Where: the firmware's output stage, not the decoding.** Frame 0 of the 720p stream written by the decoder as
SAND (`-f SAND`: the column format the VideoCore decodes into, 128-byte columns of 1080 lines — 720 of Y, then
360 of interleaved UV —, `pitch[0]` 138240 = the column stride, UV at 92160), as NV12 and as I420, compared with
ffmpeg's frame 0 on the host: Y identical in all three (no Y sample below 16 in that frame); U and V differ in
exactly the samples whose value is 1…15 (17 542 and 18 415 of them), each by −1, identically in all three formats.
So the mapping is there in the decoder's own format already, and it is not in the reconstruction: a −1 in the
reference pictures would drift through the P and B frames, and every frame of the three streams is otherwise
exact. The firmware clamps/offsets the footroom when it writes a picture out; no MMAL parameter for it is known.
For playback it is invisible (values below 16 are blacker than black and clipped on display).

**The packages, on the Pi**: `pkgman install` of both hpkgs (from `artifacts/mmal/packages/`) on the session's
disk puts the libraries in `/boot/system/lib` and the headers in `develop/headers/raspberrypi_userland`;
`mmal-h264` then runs on them without the test's `LIBRARY_PATH` (720p 111 fps, PASS). The image has no compiler, so
the devel package was not built against on the Pi (it is what the host build uses).

### 7.5 Limits and open points

- Copies only: every frame crosses by a VCHIQ bulk transfer into the client's memory (no vcsm/vc-sm-cma, GPL).
  At 1080p that is ~4 % of the system's CPU; fine for playback, the zero-copy route is our own buffer import.
- `exec()` with bulks queued (§6) still open; a client killed mid-decode is step 1's "dying team" path (not
  re-tested with MMAL).
- Patch 5's handle table is process-wide (1024 handles: components, buffers in flight, delayed events); beyond
  that `mmal_port_send_buffer()` fails with `MMAL_ENOSPC`.
- The H.264 block at 250 MHz outside the boot-time turbo period (§7.4): a decoder should ask for its clock while it
  runs (property `SET_CLOCK_RATE` 0x38002 with clock id 6, H264 in the firmware's mailbox property documentation, not
  yet in `bcm2835_mailbox.h` — as `v3d` and `bcm2835_cpufreq` set the core clock to its maximum; or turbo),
  measured gain 1.36–1.4×.
- The footroom −1 of the output stage (§7.4): unavoidable on this path; a check against a software decoder must
  map it (as `mmal.sh` does) or use streams without such samples.

### 7.6 What step 3 (a media-kit decoder add-on) needs

- **Build**: the add-on links `-lmmal -lmmal_core -lmmal_util -lmmal_vc_client -lvchiq_arm -lvcos` (`mmal.pc`)
  from `raspberrypi_userland_devel`; the image needs `raspberrypi_userland` (jam: the hpkg in
  `generated.arm64/download/` + `build/jam/repositories/HaikuPorts/arm64` + the image's package list) and the
  `vchiq` driver merged into `rpi4`. Both stay off the published repository until then.
- **Shape**: a `Decoder` add-on (`src/add-ons/media/plugins/`) for `B_MEDIA_ENCODED_VIDEO` H.264 (and MPEG-2 /
  MJPEG / VC-1 if the firmware has the licences: the input port lists H264, MVC, MJPG only on this board) that
  creates `vc.ril.video_decode` per stream, passes the container's packets (with pts) as input buffers, sets the
  extradata (avcC → Annex-B parameter sets: the test feeds Annex-B only), takes the format-changed event, returns
  I420 (or NV12/YV12) frames copied by VCHIQ bulk into the media kit's buffers. The test program's loop
  (`mmal-h264.c`) is the skeleton; it must become callback-driven with timeouts, seek = port flush.
- **Clock**: ask for the H.264 clock (or turbo) while decoding (above), else 1080p is 53 fps, not 72.
- **Zero-copy later**: `OPQV` output keeps frames on the VideoCore (1.3 % CPU at 1080p) but only a firmware
  component (`vc.ril.video_render`) can show them, outside the app_server's planes; our own buffer
  import (stage-6 planes, `gpu-stage6.md` §5) is the route to zero-copy display.
- **Robustness**: a media player killed or crashing mid-decode exercises the driver's dying-team path with MMAL
  (step 1 tested it with vchiq_test only); several decoders at once share the 1024-handle table and the
  firmware's component limit (untested).

## 8. Step 3: H.264 in the media kit (MediaPlayer, WebPositive)

Status (2026-11-05): **works on the Pi** (network boots of the `h264-mmal` image). Haiku branch `h264-mmal` (off
`vchiq`, pushed, not merged): `27a0c0d75b` the H.264 clock · `dd03227336` the plugin prefers the hardware decoder
· `f1cdfb5723` the fallback whenever it fails · `0a7fa72b63`, `8a9829b9ab`, `f032832df7` the packages in the
arm64 repository. This repository: `patches/ffmpeg6/0002-mmal-haiku.patch` (ffmpeg6 6.1.6-4), raspberrypi_userland
revision 3 (patches 8 and 9), `tools/build/UserBuildConfig` (raspberrypi_userland in the regular image when the
tree's repository lists it), tests `tools/pi-tests/h264.sh`, `tools/media-tests/vdecode.cpp`,
`tools/media-tests/gen-h264-clips.sh`, `tools/haiku-tests/teamstat.c`. Raw results: `artifacts/mmal/step3/`.

### 8.1 How it plugs in

The HEVC hardware path (`hw-video-decode.md` §0, §3) is **not** a media-kit add-on: it is a second libavcodec
decoder (`hevc_rpivid`) inside the ffmpeg6 port, registered ahead of `hevc`, which the media kit's ffmpeg plugin
gets from `avcodec_find_decoder()`; it falls back to the CPU inside itself and hands out ordinary `yuv420p` frames
that the plugin converts (swscale) to `B_RGB32`. H.264 goes the same way, with two differences:

- FFmpeg already has the decoder: `libavcodec/mmaldec.c`, `h264_mmal` (LGPL like the rest of the ffmpeg6 patches;
  the BSD/MIT rule of H21 is about Linux's GPL pieces). ffmpeg6 revision 4 is built `--enable-mmal` against
  raspberrypi_userland's headers (`scripts/build-ffmpeg.sh`), and libavcodec links `libmmal_core`, `libmmal_util`,
  `libmmal_vc_client` (the package then requires them: `lib:libmmal_*`).
- `h264_mmal` cannot become the CPU decoder the way `hevc_rpivid` does (the VideoCore parses the whole stream), so
  the fallback is in the plugin: `AVCodecDecoder` takes `h264_mmal` for H.264 when FFmpeg has it and keeps `h264`;
  when `h264_mmal` does not open (no `/dev/vchiq`, the VideoCore's memory taken by another decoder) or fails later
  (any error but EAGAIN/EOF), the stream goes to `h264` in place — from the start if the hardware decoder had not
  given a frame yet (the packets it was given are kept, at most 300, and given again), else from the next key
  frame. It prints `AVCodecDecoder: video decoder h264_mmal` or `AVCodecDecoder: h264_mmal failed (REASON): h264
  continues ...`. `FFMPEG_H264_MMAL=0` in the environment keeps the software decoder (the A/B of §8.3).
- Frames: `yuv420p` (I420 copied out of the VideoCore's buffer by mmaldec), converted by the plugin to `B_RGB32`
  like every other decoder's. MediaPlayer shows them on a display plane (stage 6), WebPositive draws them.
- Priority: by name in the plugin (`avcodec_find_decoder_by_name("h264_mmal")`), not by libavcodec's registration
  order, so `avcodec_find_decoder(AV_CODEC_ID_H264)` — what other FFmpeg users get — stays the software decoder
  (the ffmpeg command line uses the hardware one with `-c:v h264_mmal`, without a fallback).

### 8.2 What had to be fixed on the way

| Where | Problem (found on the Pi) | Fix |
|---|---|---|
| mmaldec.c (FFmpeg 6.1) | does not compile (a comma missing in `FFMMAL_DEC`) | patch 0002 |
| mmaldec.c | default `extra_buffers` 10: the VideoCore's memory (76 MB `gpu_mem`) holds no more than ~8 1080p buffers → `ENOSPC` on the control port, mmaldec only logs it and outputs empty frames (grey, then green), at 1080p it loops on "Did not get output frame"; such a failed decoder plus a killed client left the firmware's MMAL service not answering until a reboot | `extra_buffers` 2 (3 output buffers: 79 fps at 1080p with the clock held, §8.3); after an error event, or 2 s without a frame it owed, `receive_frame()` returns `AVERROR_EXTERNAL` from then on (→ the plugin's fallback); one 100 ms wait without a frame is no error |
| mmaldec.c | since FFmpeg 5 the end of a stream comes as `AVERROR_EOF` from `ff_decode_get_packet()`, not as the empty packet mmaldec waited for: the end-of-stream buffer was never sent, the last 5–10 frames the decoder held were lost (290/300) | EOS sent on `AVERROR_EOF`; while draining it waits for the decoder's frames instead of returning EAGAIN |
| mmaldec.c | the media plugin sends a packet only when no frame is ready, so the decoder ran dry, and with B-frames it needs several packets before its next frame: a 70–90 ms gap every 15–30 frames at 1080p (MediaPlayer dropped 143 frames in 25 s) | the decoder is kept supplied with 8 packets (`receive_frame()` asks for more before it returns a frame): no gap over 40 ms (`vdecode`) |
| mmaldec.c | avcC (MP4) | `.bsfs = "h264_mp4toannexb"`; the parameter sets go to the decoder as the filter outputs them (Annex-B) |
| libmmal (patch 8) | `mmal_vc_sendwait_message()` waited for the VideoCore's reply for good (upstream's FIXME): a VideoCore that stops answering hung its client, also at close | 5 s at most, then `MMAL_EIO`; the waiter is abandoned and the reply handler drops a late reply (decided under the client's lock) |
| VCOS (patch 9) | libvcos's current-thread key keeps its destructor in libvcos; when the media plugin unloads libavcodec (and with it libvcos), the next thread that ran VCOS code and exits calls into the unmapped library: **MediaPlayer crashed on every quit** (also with `FFMPEG_H264_MMAL=0`, as libavcodec loads the library) | `vcos_platform_deinit()` (the library's destructor) deletes the key |

### 8.3 Results (Pi 4, network boot of the `h264-mmal` image, firmware Oct 15 2026)

**The H.264 clock** (`tools/pi-tests/h264.sh clock`, step 2's `mmal-h264` on the Annex-B clips, the clock held by
the driver vs left to the firmware with `video_clock false`; `measure_clock h264` during each decode: 500 000 992 Hz
vs 250 000 496 Hz):

| Clip (300 frames, noise) | firmware (250 MHz) | held (500 MHz), 1 output buffer | held, 3 output buffers (mmaldec's) |
|---|---|---|---|
| 720p | 111 fps | 114 fps | **171 fps** (1.54×) |
| 1080p | 53 fps | 51 fps | **79 fps** (1.49×) |

With one output buffer the VideoCore waits for each frame's copy (a 3 MB bulk transfer), so the clock gains only
with several buffers. Every MMAL client raises and lowers it: `vchiq: H.264 clock maximum: 250 -> 500 MHz` /
`minimum: 500 -> 250 MHz` in the syslog.

**Bit-exactness through libavcodec** (`h264.sh ffmpeg`: `ffmpeg -c:v h264_mmal` on the MP4 clips, i.e. avcC +
length-prefixed NAL units through the bitstream filter): 300 of 300 frames of the 720p and the 1080p clip equal to
ffmpeg's software decode with the samples below 16 lowered by one (§7.4's firmware quirk). Times: 720p 2.16 s
(h264 on 4 threads 2.19 s, 6.3 s of CPU vs 2.4 s), 1080p 4.47 s (4.50 s, 14.3 s of CPU vs 4.7 s).

**MediaPlayer** (`h264.sh play`: 20 s measured from 5 s after the start, 60-s clips, testsrc2 with light noise,
High profile, B-frames; frames shown = the display plane's updates per 10 s in the display driver's statistics):

| Clip | decoder | MediaPlayer's CPU (of one CPU) | system (of 4 CPUs) | shown per 10 s | dropped (producer) |
|---|---|---|---|---|---|
| 720p30 4 Mbit/s | h264_mmal | 40 % | 11 % | 301–302 (all) | 0 |
| | h264 (CPU) | 65 % | 17 % | 301–302 | 0 |
| 1080p30 8 Mbit/s | h264_mmal | 88 % | 24 % | 301–302, 1–6 late | 1 |
| | h264 (CPU) | 159 % | 41 % | 301–302, ~285 late | 0 |
| 1080p60 12 Mbit/s | h264_mmal | 70 % | 19 % | 240 (24 fps) | 0 |
| | h264 (CPU) | 103 % | 27 % | 7–8 (collapses) | 288–353 |

- What remains of the CPU with the hardware decoder is the copy out of MMAL's buffer and mostly the plugin's
  conversion to `B_RGB32` (swscale has no NEON path for yuv420p → bgra: "No accelerated colorspace conversion");
  `vdecode` (media kit, as fast as it goes, frames to RGB32): 720p 107 fps at 134 % of a CPU (software: 122 fps at
  284 %), 1080p 50 fps at 121 % (software: 57 fps at 313 %, its conversion overlapping the decode threads). That
  conversion is why 1080p60 shows 24 fps.
- **Seek** (`h264.sh seek`, 1080p30): pause holds the position (5.70 s = 5.70 s 2 s later); a seek to 40 s plays on
  from there (43.8 s after 4 s), back to 10 s too (13.7 s); six seeks in a row; no error. **Close and reopen** five
  times: each decodes on the VideoCore (172 frames in 6 s).
- **Killed mid-decode** (`h264.sh kill`, `kill -9` of MediaPlayer playing 1080p, three times): the driver's
  dying-team path with MMAL (`vchiq: team 3049 went away with a bulk transfer queued: its 3133440 bytes are kept
  until the transfer ends` — one 1080p frame), the clock goes back to 250 MHz, only GCMD/KEEP remain, and the next
  player decodes on the VideoCore at full rate.
- **Two players** (`h264.sh two`): one 1080p decoder takes ~45 MB of the VideoCore's relocatable memory (`get_mem
  reloc` 47 M free → 2 M), so a second H.264 stream does not open on it: the second MediaPlayer window prints
  `h264_mmal failed (does not open): h264 continues from the start` and plays on the CPU; no crash. ffmpeg's
  `-c:v h264_mmal` in another team at the same time fails to open (the command line has no fallback). Two 720p
  decodes fit (step 2's test: 85 fps each). Memory back to 47 M after both quit.
- **5.5-minute play** (`h264.sh long`, 720p30, 330 s): 9875 frames, 13 dropped; MediaPlayer 88.3 → 90.5 MB in RAM
  between 15 s and 295 s, the VideoCore's free memory 47 M before and after; a second check over 105 s: 83.2 → 83.3
  MB with the hardware decoder (software: 103.7 → 104.6 MB). No leak.
- **HEVC** (`h264.sh hevc`): MediaPlayer still decodes `hd.mp4`/`fhd.mp4` on rpivid ("rpivid: hardware HEVC decode,
  1920x1080 8-bit, clock 500 MHz").
- **WebPositive** (`h264.sh web`, `file:///boot/home/h264/video.html`): `<video>` goes through the media kit
  (`MediaPlayerPrivateHaiku`, `BMediaFile`), so through `h264_mmal`: 1769 frames from the VideoCore, the picture
  right (screenshot). Two things that are not the decoder's: WebKit's Haiku media player runs ahead of real time
  (the 60-s clip ends after ~25 s; with the software decoder too: 44.7 s of video after 25 s), and it crashed once
  when quit during playback with the software decoder (`memcpy` in `BMediaTrack::ReadFrames` from WebKit's
  `videoThread`). At the end of the stream the plugin saw an `AVERROR_INVALIDDATA` from `h264_mmal` and switched to
  the software decoder (harmless there; not explained).
- **With an audio track** (`h264.sh audio`, the play clips with a 440 Hz AAC track: MediaPlayer's time source then
  comes from the audio path): 720p30 hardware 46 % of one CPU / 14 % of the system, every frame shown, software
  67 % / 18 %; 1080p30 hardware 101 % / 29 %, all shown (4–11 late per 10 s), software 168 % / 44 %, all shown but
  ~215 of 300 late per 10 s. 0 dropped in all four.
- **Firefox** decodes H.264 with the system's FFmpeg (its FFmpeg platform decoder module dlopens libavcodec and
  asks `avcodec_find_decoder()`), so it keeps the software `h264`: with ffmpeg6 revision 4 it still plays the H.264
  test clips (`firefox-video.sh`'s page: 720p 300 frames, 25 dropped; 1080p 300 frames, 60 dropped — as before),
  no debugger entry, and no MMAL client appears. Hardware H.264 in Firefox would need its decoder module to ask for
  `h264_mmal` (and its own fallback): open.
- **No regression**: `scripts/release-check.sh` on the branch image (`f032832df7`, ffmpeg6 6.1.6-4,
  raspberrypi_userland 20241223-3): `REL result: 0 problems` (24 launch cycles, 0 debugger entries;
  `artifacts/relcheck/h264-mmal.txt`). Manifest `manifests/2026-11-05-h21-step3-h264-mmal.md`.
- A trap met on the way: MediaPlayer resumes a file where it was last quit (its `Media:Frame` attribute), so
  repeated test plays of one file started near its end and seemed to stall; `h264.sh` clears the attribute.

Screenshots: `artifacts/mmal/step3/shots/` (MediaPlayer 720p/1080p hardware and software, seeks, the long play,
WebPositive).

### 8.4 Limits and open points

- One H.264 stream at 1080p on the VideoCore at a time (its memory: `gpu_mem` 76 MB); others fall back to the CPU.
  A larger `gpu_mem` would take RAM from the ARM — not changed.
- The firmware's I420 output is one code value off for samples below video black (§7.4): invisible in playback.
- Profiles: what the firmware decodes (High profile 8-bit 4:2:0 up to level 4.2, 1920×1088; no High 10 / 4:2:2,
  no 4K). A stream the firmware refuses fails (an error event) and goes to the CPU through the fallback; not
  tested with such a stream.
- The plugin's conversion to RGB32 (no NEON yuv420p → bgra in swscale) is now the cost of video playback: a NEON
  path or a YCbCr display plane (KNOWN-ISSUES F2: YCbCr overlays show black) would remove most of it. Zero-copy of
  the VideoCore's frames (no `vc-sm-cma`) and handing frames to the plane without the copy are later work.
- ffmpeg's command line and other direct FFmpeg users get the software decoder unless they ask for `h264_mmal`
  (which then has no fallback).
- `exec()` with bulk transfers queued (§6) still open.

### 8.5 To ship

1. Merge `vchiq` and `h264-mmal` into `rpi4` (h264-mmal contains vchiq).
2. Publish `raspberrypi_userland-20241223-3` (+ `_devel`) and `ffmpeg6-6.1.6-4` (+ `_devel`) from
   `artifacts/mmal/packages/` (`scripts/build-ffmpeg.sh --publish` / move them into `artifacts/packages/`; the
   three parts of a revision bump: the hpkgs, the copies in `generated.arm64/download/`, the versions in
   `build/jam/repositories/HaikuPorts/arm64` — on the branch).
3. The regular image then carries `raspberrypi_userland` (UserBuildConfig adds it when the repository lists it)
   and the vchiq driver; nothing else changes in the image lists.
