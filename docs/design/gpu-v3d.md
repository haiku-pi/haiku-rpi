# GPU acceleration for Haiku on the Raspberry Pi 4 (V3D 4.2 + firmware display) — milestone H12

Status: design only (2026-10-18). Nothing here has been built or run on hardware.
Goal (`docs/PLAN.md` H12): accelerated OpenGL (GLES 3.1 and desktop GL, HW-proven on Phoenix) through Mesa's `v3d` gallium
driver on the BCM2711's V3D 4.2, a real display driver with vblank, modes, hardware cursor and planes, then
Vulkan (`v3dv`). The desktop today runs on the EFI GOP framebuffer handed over by U-Boot.

Citation keys (file:line):
- **[H]** `sources/haiku/` (our `rpi4` branch, hrev60262 base).
- **[U]** `sources/u-boot/`. **[DTS]** `artifacts/pi-firmware/bcm2711-rpi-4-b.dts` (firmware `6c87074`).
- **[PX]** `/home/houp/phoenix-rpi/sources/phoenix-rtos-devices/gpu/rpi4-v3d-async/` — the Phoenix-RTOS
  V3D render server, HW-proven on this board (STK at Raspberry Pi OS parity).
- **[PR]** `/home/houp/phoenix-rpi/docs/research/2026-09-26-gpu-drm-architecture.md` (Phoenix GPU architecture study).
- **[PL]** `/home/houp/phoenix-rpi/docs/gpu-new-lane/` (`M1-async-render-server.md`, `E3-firmware-planes-vblank.md`,
  `M3-libdrm-phoenix.md`, `PLAN.md`).
- **[PB]** `/home/houp/phoenix-rpi/docs/done/2026-06-10-v3d-direct-power-bringup-draft.md`.
- **[PN]** `/home/houp/.claude/projects/-home-houp-phoenix-rpi/memory/<note>.md` (Phoenix project notes).
- **[M]** `/home/houp/phoenix-rpi/external/mesa` — Mesa 26.2.0 (`9f0a761020b`) + 22 Phoenix commits (HEAD
  `51c5ee977ba`); "(up:N)" = line in the upstream tag. No Haiku file is touched by the Phoenix commits.
- **[L]** `/home/houp/phoenix-rpi/external/linux` (raspberrypi/linux rpi-6.18.y). Facts only — GPL.
- **[G]** libglvnd `src/HGL/` (github.com/NVIDIA/libglvnd mirror of gitlab.freedesktop.org/glvnd, master).
- **[HP]** HaikuPorts `sys-libs/mesa/mesa-25.3.6.recipe` (fetched 2026-10-18 with `gh api`).
- **[X]** `/home/houp/phoenix-rpi/external/haiku-{libdrm2,radeongfx,nvidia}` (X512's community DRM work).

## 0. Key findings

1. **The hard part has been done once on this exact board, and the knowledge transfers.** Phoenix-RTOS runs
   upstream Mesa `v3d` (GL/GLES 3.1) and `v3dv` (Vulkan) on V3D 4.2 under a self-written implementation of the
   Linux v3d uAPI ([PR]:170-172, [PL] `PLAN.md`:44-48). Its register-level bring-up (power, MMU, caches, IRQs,
   OUTOMEM, wedge reset) is ~7 k lines in [PX] and is the spec for our kernel driver. What does *not*
   transfer: Phoenix's userspace-server/IPC/libdrm-rewrite shape, which existed because Phoenix is a
   microkernel. Haiku has real kernel drivers, so the Linux model (kernel driver + unmodified libdrm/Mesa)
   fits directly.
2. **Mesa's Haiku support is software-only, and the gap is small and well located.** `egl_haiku` hard-codes
   `hgl_create_sw_winsys()` + `sw_screen_create()` ([M] `src/egl/drivers/haiku/egl_haiku.cpp:345-347`);
   meson excludes Haiku from `system_has_kms_drm` ([M] `meson.build:162`), so `with_gallium_drm`, kmsro and
   libdrm are off (`:260-268`, `:343`, `:1920-1935`). The `v3d` driver itself is not OS-gated (`:224`) and
   needs no LLVM (NIR→QPU; LLVM is forced only for llvmpipe/radeonsi/r300/i915, `:247-251`). Present goes
   through `screen->flush_frontbuffer` (`egl_haiku.cpp:234`), which **v3d does not implement** — so the work
   is a hardware screen + a present path in `egl_haiku`, plus a Haiku libdrm.
3. **How GL reaches the screen on Haiku today:** the in-tree OpenGL kit is gone (removed in `eb45d168e1`,
   2013); `BGLView`/`libGL` now live in libglvnd's `src/HGL` ([G] `GLView.cpp`, "HGL: add Haiku libGL.so
   implementation based on EGL", 2022-05-21). `BGLView` creates an EGL window surface whose native window is a
   `BitmapHook` ([G] `GLView.cpp:248-249`); Mesa hands each finished frame over as a `BBitmap`
   (`SetBitmap` → `B_INVALIDATE`, `GLView.cpp:212-219`) and `BGLView::Draw` calls `DrawBitmap`
   (`:420-425`). app_server then composites in software and memcpy's dirty rects back→front
   ([H] `src/servers/app/drawing/HWInterface.cpp:339-402`). `DirectConnected` is empty (`GLView.cpp:461-463`).
   **So every GL frame costs up to three CPU copies of the window**, and the design has to remove them in
   stages.
4. **The community DRM-on-Haiku work is a pattern, not a dependency.** X512's `libdrm2` routes the real
   path through a private `AccelerantRoster` interface and its generic `drmIoctl` is a fake amdgpu stub
   ([X] `haiku-libdrm2/stub/libdrmStub.cpp:566-659`); RadeonGfx is a userland server whose generic
   `DrmIoctl` returns `ENOSYS` (`haiku-radeongfx/.../RadeonGfxAccelerant.cpp:93-98`) and depends on a patched
   Haiku (`_kern_dup_foreign`, `drm/DrmInterface.cpp:525-541`); the NVIDIA work does not use the DRM uAPI at
   all. Reusable ideas: area-clone mapping of BOs (`nvidia/BaseDevice.cpp:127-206` `NV_HAIKU_MAP`), a
   syncobj/fence model (`haiku-radeongfx/Sync/`, ~530 lines, MIT headers), and zero-copy flip of a GPU buffer
   by pointing scanout at it (`display/DisplayConsumer.cpp:400-412`). **Shortest path: an in-kernel Haiku
   driver that speaks the Linux v3d uAPI over `ioctl()`, upstream libdrm with a thin Haiku backend, Mesa
   `v3d` called directly (no kmsro).**
5. **Display does not need native HVS code.** The VideoCore firmware offers KMS semantics over the mailbox:
   `SET_PLANE` (8 planes per display incl. cursor, scaling, YUV) and a vblank interrupt raised on the SMI
   block (GIC SPI 112). Phoenix measured it on this board: 60.01 Hz vblank IRQ, 0 missed vsynced flips,
   `SET_PLANE` p50 78–100 µs, but **planes scan out only from the low 1 GiB** ([PL]
   `E3-firmware-planes-vblank.md`:411-430). Native HVS/pixelvalve/HDMI has only a GPL reference
   ([PR]:300-307) and stays out of scope.
6. **app_server itself cannot be "GPU accelerated" cheaply.** It draws everything with Painter/AGG into a
   malloc'd back buffer and never calls the accelerant's 2D hooks or `B_MOVE_DISPLAY`
   ([H] `AccelerantHWInterface.cpp:638-659`, `:1395-1420` dead code). H12 delivers accelerated GL/Vulkan
   applications, a hardware cursor, overlay planes and vsync; a GL-composited app_server is a separate,
   upstream-scale project (§2.4).
7. **H14 does not block H12.** The arm64 bootstrap repo has expat/zlib/python3.10 but no meson, ninja or mako
   ([H] `build/jam/repositories/HaikuPorts/arm64`), so a native Mesa build needs H14. A cross build on the
   Linux host with the jam-built sysroot needs nothing from H14. The minimal Mesa is
   `-Dgallium-drivers=v3d,softpipe -Dllvm=disabled -Dplatforms=haiku -Degl=enabled -Dglvnd=enabled
   -Dglx=disabled -Dvulkan-drivers=` — no LLVM, unlike HaikuPorts' `llvmpipe` build ([HP]: `llvmMajor=21`,
   `-Dgallium-drivers=llvmpipe`).

## 1. What exists vs what is missing

### 1.1 Haiku (our tree)

| Piece | State | Where |
|---|---|---|
| Display driver on the Pi | `framebuffer` driver + accelerant over the GOP buffer: one mode (the boot mode), no retrace semaphore, no cursor, no overlay | [H] `drivers/graphics/framebuffer/driver.cpp:51-60`, `framebuffer.cpp:62-78`; `accelerants/framebuffer/mode.cpp:41-44,97-104`, `accelerant.cpp:210-212` |
| Who allocates the GOP buffer | U-Boot, via mailbox `ALLOCATE_BUFFER`, **single-buffered** (virtual = physical size), BGR order (our patch) | [U] `arch/arm/mach-bcm283x/msg.c:160-205`; `patches/u-boot/0001-video-bcm2835-request-BGR-pixel-order.patch` |
| app_server device choice | walks `/dev/graphics/`, skips only `vesa` and `framebuffer`, so **any new node is preferred**; falls back to framebuffer | [H] `servers/app/drawing/interface/local/AccelerantHWInterface.cpp:212-245,273-285` |
| app_server rendering | CPU only; back buffer (`MallocBuffer`), dirty-rect memcpy to front; no flips | `AccelerantHWInterface.cpp:638-659`; `HWInterface.cpp:339-402` |
| Overlay + cursor hooks | supported by app_server (overlay hooks fetched per mode; cursor hooks `0x200..`) | `AccelerantHWInterface.cpp:416-437`; [H] `headers/os/add-ons/graphics/Accelerant.h:59-62`; `headers/private/graphics/video_overlay.h:21-29` |
| vblank semaphore pattern | create sem, `set_sem_owner` to the caller's team, release from IRQ | [H] `drivers/graphics/intel_extreme/intel_extreme.cpp:427-440` |
| Model for a scanout-copy driver | `virtio_gpu`: device-manager driver, shared-info area, 50 Hz full-screen upload thread | [H] `drivers/graphics/virtio/virtio_gpu.cpp:394-410,582-607,771-793` |
| OpenGL kit / EGL | **not in tree**; comes from HaikuPorts (`libglvnd` HGL + `mesa`). arm64 has neither, so GLTeapot & co. are dropped from arm64 images | [H] `build/jam/BuildFeatures:184-197`; `src/apps/glteapot/Jamfile:3,16,24` |
| FDT attach | every DT node is registered, **including `status = "disabled"`** (the V3D node is disabled in the base DTB) | [H] `bus_managers/fdt/fdt_module.cpp:85-154`; [DTS]:2461-2473 |
| Mailbox | `generic/bcm2835_mailbox/v1`, `property_tag(tag, values, bufferSize, requestSize, &responseSize)`, **mutex-serialised**, one page buffer | [H] `headers/private/drivers/bcm2835_mailbox.h:16,28-29`; `generic/bcm2835_mailbox/bcm2835_mailbox.cpp:68,254-300` |
| Memory | `create_area_etc` with `physical_address_restrictions` (high_address, alignment, boundary); pages **cleared by default** (`CREATE_AREA_DONT_CLEAR` to skip); `vm_set_area_memory_type` → Normal-NC (WC) or Device; dcache helpers | [H] `headers/private/kernel/vm/vm.h:32,75-79`, `vm_types.h:51-59`; `system/kernel/vm/vm.cpp:1563-1564,4528-4555`; `arch/arm64/VMSAv8TranslationMap.cpp:543-568`; `headers/private/kernel/arch/arm64/arch_cpu.h:91-121` |
| `mmap()` of a device fd | **not possible**: `_vm_map_file` needs a vnode file cache ("only works for file systems that use the file cache") | [H] `vm.cpp:2363-2366` |
| Clone memory type | a clone of a RAM-backed area does **not** inherit the source's memory type (only device areas do) | [H] `vm.cpp:2566-2610` |
| ioctl ABI | `ioctl(fd, op, arg)` passes `size = 0`; the driver must size user copies itself (`_IOC_SIZE(op)` for DRM numbers) | [H] `headers/posix/unistd.h:380-390`; `libroot/posix/unistd/ioctl.c:25-37` |
| Kernel console | `frame_buffer_update()` re-points the KDL console after a mode change | [H] `headers/private/kernel/frame_buffer_console.h:34`; used at `framebuffer.cpp:68` |

### 1.2 Mesa ([M])

- **v3d's kernel surface** (all through `v3d_ioctl` → `drmIoctl`, `src/broadcom/common/v3d_util.h:114-121`):
  `GET_PARAM`, `CREATE_BO`, `MMAP_BO`, `GET_BO_OFFSET`, `WAIT_BO`, `SUBMIT_CL`, `SUBMIT_TFU`, `SUBMIT_CSD`,
  `SUBMIT_CPU` (timestamp queries), `PERFMON_*` (only if `MAX_PERF_COUNTERS` ≠ 0); `GEM_CLOSE/OPEN/FLINK`,
  PRIME both ways; **syncobjs are mandatory**: context creation fails without `drmSyncobjCreate`
  (`src/gallium/drivers/v3d/v3d_context.c:450-455`), every submit chains `in_sync_rcl = out_sync`
  (`v3d_job.c:666-674`), fences are sync-file fds (`v3d_context.c:70`; the Phoenix fork tolerates a failed
  export, `:71-77`). The uAPI numbers are `include/drm-uapi/v3d_drm.h:33-46`.
- **Required GET_PARAMs:** CORE0_IDENT0/1, HUB_IDENT3; the version must decode to 42 or 71
  (`v3d_device_info.c:54-104`). SUPPORTS_TFU/CSD/CACHE_FLUSH are optional for gallium, but without
  CACHE_FLUSH SSBOs/images are off (`v3d_screen.c:172-178`). **v3dv refuses the device** without TFU, CSD,
  CACHE_FLUSH, MULTISYNC_EXT **and** CPU_QUEUE ((up) `src/broadcom/vulkan/v3dv_device.c:854-861`).
- **GPU VAs are the kernel's**: `bo->offset = create.offset` is written straight into control lists, no
  relocations (`v3d_bufmgr.c:181`, `v3dx_draw.c:55`, `v3d_job.c:702-706`) — BOs stay mapped at a fixed V3D
  address for life. CPU maps go through `WAIT_BO` (implicit per-BO fencing, (up) `v3d_bufmgr.c:531-535`).
- **MMAP_BO + `mmap(fd)`** cannot work on Haiku (§1.1); the Phoenix fork already carries the fix shape —
  `MMAP_BO.offset` is the CPU VA (`v3d_bufmgr.c:602-605`).
- **Fake-device references (MIT):** `src/broadcom/drm-shim/v3d_noop.c:59-65,140-202` (V3D 4.2 idents,
  GET_PARAM answers) and the simulator ioctl wrapper `src/broadcom/simulator/v3d_simulator.c:1092-1145` —
  a permissive description of exactly the kernel driver's job ([PR]:338-342).
- **No Haiku Vulkan WSI** in `src/vulkan/wsi`; headless WSI is always built; `wsi_common_display` needs
  `system_has_kms_drm`.
- **Phoenix Mesa fixes worth carrying** (fork commits): NPOT mip generation via TFU mistiles → fall back to
  render-based mipmaps (`e4be1163240`, [PN] `project_v3d_npot_mip_fix.md`). Phoenix's `should_tile`
  RASTER hack and its SAMPLER_VIEW follow-up were Phoenix-present workarounds and caused two regressions
  ([PN] `project_quake3_lightmap_uif_xor.md`) — **do not carry**.

### 1.3 Hardware facts from the Phoenix port (BCM2711, V3D 4.2)

| Fact | Detail | Source |
|---|---|---|
| MMIO | hub `0xfec00000` (+0x4000 = core0), 64 KiB; DT `reg-names = "hub", "core0"` under `v3dbus` | [PX] `v3da_regs.h:24-27`; [DTS]:2453-2473 |
| IRQ | **one** line for hub + core: GIC SPI 74, level → Haiku IRQ **106** (SPI+32); Linux's `single_irq_line` path; read both status words every time | [PL] `M1-async-render-server.md`:126-141; [PX] `v3da_regs.h:29-31` |
| Identity (this board) | core0 `0x04443356 / 0x81001422 / 0x40078121`, hub UIFCFG `0x45`, IDENT1-3 `0x000e1124 / 0x100 / 0xe00` = V3D 4.2, 1 core, TFU/TSY/MSO | [PX] `v3da_regs.h:182-190`; [PB]:7-10 |
| Unpowered read | `0xdeadbeef`; an **unclocked** V3D MMIO read *never completes* (Phoenix: silent forever-hang, SError masked there) | [PB]:7-10; [PN] `project_v3d_clock_race_mmio_hang.md` |
| Power-on (HW-proven) | mailbox `SET_QPU_ENABLE(1)` (0x30012), `SET_DOMAIN_STATE(10,on)` (0x38030), `SET_CLOCK_STATE(5,on)`; clock on → 50 µs → off; `PM_GRAFX(0x10c) \|= PM_V3DRSTN(bit 6)` with password `0x5a000000`; **clock on + read-back** (`GET_CLOCK_STATE` bit 0, ≤ 20 tries); ASB master (+0x0c) and slave (+0x08) on `rpivid_asb`: clear `REQ_STOP`, poll `ACK`→0; 2 ms | [PX] `v3da_hw.c:42-63,176-219`; [PL] `M1…`:408-414 |
| The PM island sequence | POWUP/ISPOW… is a **no-op on BCM2711**; mailbox calls + overlay alone are **not** sufficient — the PM_V3DRSTN + ASB writes are load-bearing | [PB]:12-20 |
| PM/ASB addresses | DT `watchdog@7e100000` (`brcm,bcm2711-pm`), `reg-names = "pm", "asb", "rpivid_asb"` (`0x7ec11000` → CPU `0xfec11000`); it is the V3D node's `power-domains`/`resets` provider | [DTS]:1526-1536,2466-2467 |
| Config | Phoenix boots with `dtoverlay=vc4-fkms-v3d` ("fake-KMS so the firmware ungates V3D — its MMIO reads 0xdeadbeef otherwise"); the overlay sets cma 256 MiB, disables `/soc/fb`, enables `firmwarekms`, `v3d`, `vc4` | `/home/houp/phoenix-rpi/docs/PHOENIX-RTOS-RPI4-CHANGES.md:1617`; decompiled `vc4-fkms-v3d.dtbo` |
| Core register set-up | `MMU_PT_PA_BASE = pt_pa>>12`; `MMU_CTL = ENABLE\|PTI_ENABLE` + abort/int on PTI, write-violation, cap-exceeded; `MMU_ILLEGAL_ADDR = scratch>>12 \| bit31`; `MMUC_CONTROL = ENABLE`; `L2CACTL = L2CCLR\|L2CENA`; L2T flush range 0..~0; `HUB_AXICFG = 0xf` (GFXH-1383); `MISCCFG = QRMAXCNT(2)<<1 \| OVRTMUOUT` (proven, keep) | [PX] `v3da_hw.c:251-265`; [PL] `M1…`:293-296 |
| MMU | one flat page table for all clients (as Linux), PTE = `PA>>12 \| VALID(28) \| WRITE(29)`; flush = `dsb sy`, `MMUC_CONTROL = FLUSH\|ENABLE` (wait `FLUSHING`), `MMU_CTL \|= TLB_CLEAR` (wait `TLB_CLEARING`). PA width is read by Linux from `MMU_DEBUG_INFO` | [PX] `v3da_hw.c:303-316`, `v3da_regs.h:74-98`; [L] `drivers/gpu/drm/v3d/v3d_drv.c:409-416`, `v3d_mmu.c:27-30` |
| DMA window | `v3dbus dma-ranges = <0x0 0x0 0x4 0x0>`: identity, 16 GiB — **no `0xC0000000` alias** (unlike emmc2/soc) | [DTS]:2453-2460 |
| Per-job maintenance (proven default) | `dsb sy`; `SLCACTL = 0x0f0f0f0f` (**dropping it = stale uniforms forever**); MMU flush + TLB clear; L2T flush wait-old / issue / wait-new, **twice** ("fix-A", removal regressed); clear INT; `PTB_BPOS = 0`; `CT0QMA/QMS/QTS`; kick `CT0QBA/QEA`; bin→render handoff = waited L2T flush + SLCACTL; kick CT1; post-render `L2TFLS\|FLM_CLEAN` | [PL] `M1…`:269-291; [PN] `project_pi4_v3d_scout.md` (update 25ak); [PX] `v3da_regs.h:108-118` |
| Interrupts | storm-proof order: mask all (`INT_MSK_SET = ~0` core + hub), clear all, install handler, unmask `OUTOMEM\|FLDONE\|FRDONE\|CSDDONE\|GMPV` and hub `MMU_WRV\|PTI\|CAP\|TFUC`; W1C `MMU_CTL` after MMU faults; **ack QPU bits (27:16) too** (collapsed a render wedge 330→0) | [PL] `M1…`:143-200; [PX] `v3da_hw.c:370-444,484-503`, `v3da_regs.h:119-135` |
| OUTOMEM | binner stalls until `PTB_BPOA/BPOS` get memory; the handler writes a **pre-staged** chunk (no allocation in IRQ context); a chunk belongs to bin(N) until **render(N)** completes | [PL] `M1…`:239-265; [PX] `v3da_hw.c:389-403` |
| Wedge recovery | watchdog 500 ms, extended while `CTnCA/CTnRA` move; reset = mask IRQs → GMP stop (`idle_axi`) → ASB stop + `PM_V3DRSTN` assert → full power-on → core regs → TLB flush; drop the frame (resubmitting re-hangs) | [PL] `M1…`:379-399; [PX] `v3da_hw.c:224-243,270-280,524-547` |
| BO lifetime (C1 lesson) | free = clear PTEs → TLB flush → wait until every job submitted before the free has completed → only then reuse the pages; never return a GPU-visible page while the GPU may still write it | [PL] `M1…`:440-461 |
| Zeroing | a garbage binner BO wedged CT1 — every BO must be zero when the GPU first sees it | [PL] `M1…`:442-443 |
| Scan-out | HVS scans LINEAR, VC4 T-tiled or SAND only — **never UIF**; GPU rendering into the buffer being scanned out wedged ~40% of boots | [PR]:161-163,184-186 |
| Firmware KMS | `SET_PLANE` tag `0x48015`, 60-byte struct (display id, plane id = `i + display_index*8`, 0 primary/1-6 overlay/7 cursor, vc_image_type, layer, 16.16 src rect, dst rect, alpha, `planes[4]` bus addresses, transform); unset = only display + plane id; `GET_DISPLAY_ID`, `GET_EDID_BLOCK_DISPLAY`, `SET_VSYNC` 0x4800e (blocks to vsync) | [PL] `E3…`:44-82 |
| Vblank | SMI `0x7e600000` (CPU `0xfe600000`), SPI 112 → Haiku IRQ **144**; handler writes `SMICS = 0`, reads `SMIDSW0`; if its top half is `0xabcd`, bit 0 of `SMIDSW0/1` = display 0/1, ack by writing `0xabcd0000`. The DT node `firmwarekms@7e600000` is `disabled` in the base DTB and plausibly gates the firmware's "fake vsync" | [PL] `E3…`:84-95,145-161; [DTS]:1910-1917 |
| Plane timing | update point ~1.6 ms before vblank, never blocks, last call wins (no tearing); 12 443 flips/s unsynced | [PL] `E3…`:418-427 |
| Plane memory | **only the low 1 GiB** scans out (firmware keeps 30 address bits); raw PA or `0xC0000000\|PA` both work there | [PL] `E3…`:421-425 |
| Mailbox race (retired on Haiku) | Phoenix lost a `SET_CLOCK_STATE` answer to a concurrent mailbox client → clock off → forever-hang. Haiku's module serialises every call under one mutex, so the race cannot occur — the read-back stays as cheap insurance | [PN] `project_v3d_clock_race_mmio_hang.md`; [H] `bcm2835_mailbox.cpp:68,262` |
| Clocks | V3D 500 MHz; `core_freq=500` (the Pi 4 default) gave +13% over Phoenix's old 250 MHz pin. Our `config.txt` pins nothing | [PL] `PLAN.md`:63,66; `scripts/mkimage-pi4.sh:45-53` |
| Performance reference | Phoenix async server: STK 12.1 fps = Pi OS 11.7; synchronous submit was the biggest cost (8.3 fps) | [PL] `PLAN.md`:44,64; [PN] `project_gpu_drm_architecture_2026_09_26.md` |

### 1.4 Missing

Kernel: a V3D render driver; a firmware-display driver (modes, vblank, planes, cursor). Userspace: a Haiku
libdrm, Mesa built with v3d, a hardware path in `egl_haiku`, libglvnd (BGLView) for arm64, packages for all
three. Bench: a GL test app and a `config.txt` that ungates V3D.

## 2. Architecture options

### 2.1 Render path

| Option | What | Verdict |
|---|---|---|
| **A. Kernel driver implementing the Linux v3d uAPI** (pick) | `drivers/graphics/v3d` (device manager, FDT `brcm,2711-v3d`), publishes **`dri/renderD128`**; `ioctl()` takes the `struct drm_v3d_*` / `drm_syncobj_*` directly; unmodified Mesa `v3d` via `v3d_drm_screen_create(fd)` | Mesa and libdrm stay upstream except for small, Haiku-only seams. IRQ, sleeping waits, team-death cleanup (`close`/`free` hooks) and areas are native kernel facilities. Same shape as Linux and as FreeBSD's drm-subtree Panfrost ([PR]:357-361) |
| B. Userland GPU server (RadeonGfx / Phoenix shape) | server maps MMIO, Mesa talks to it over ports | Every submit struct needs marshalling ([X] `RadeonServerDrm.cpp:187-258`); fd passing needs a patched kernel; IRQs reach userland only through a kernel stub. Phoenix chose it because a microkernel has nothing else. **Rejected** |
| C. In-process "winsys" (Phoenix's old lane) | each app maps MMIO and owns the GPU | Two GPU apps corrupt each other; synchronous; needs user MMIO. **Rejected** ([PR]:194-195) |
| D. Port Linux `v3d.ko` through a LinuxKPI-style layer | | GPL-2.0 driver; no such layer in Haiku; [X] has none either. **Rejected** |
| E. Software only (llvmpipe) | HaikuPorts default | Needs LLVM on arm64 (H14) and is the baseline we measure against, not the goal |

Seams of option A:
- **Device node name**: not under `/dev/graphics/`, or app_server's scan opens it and asks for an accelerant
  signature ([H] `AccelerantHWInterface.cpp:212-245`).
- **ioctl sizing**: the driver derives the size from `_IOC_SIZE(op)` and copies with `user_memcpy`, including
  nested user pointers (`bo_handles`, syncs, extension chains).
- **MMAP_BO**: the driver clones the BO's area into the calling team (`vm_clone_area`, `B_CLONEABLE_AREA`),
  **sets the clone's memory type explicitly** ([H] `vm.cpp:2566-2610` does not propagate it) and returns the
  user VA in `offset`; Mesa uses it as the map (the Phoenix patch, [M] `v3d_bufmgr.c:602-605`, guarded by
  `__HAIKU__`). Mesa's `munmap(bo->map)` on free then deletes the clone.
- **libdrm**: upstream libdrm (MIT) with a Haiku backend for the few things v3d gallium calls —
  `drmIoctl`, `drmGetVersion`, `drmSyncobj*`, `drmPrime*`. Device enumeration is not needed:
  `egl_haiku` opens `/dev/dri/renderD128` by path. (Phoenix rewrote libdrm because it lacks POSIX ioctl;
  Haiku has it.)
- **sync_file**: Haiku has no sync-file fd type. First stage: syncobj ioctls only and Mesa's fence export
  tolerating failure (Phoenix fork `v3d_context.c:71-77`); a real sync-file (an fd opened on a second driver
  node and bound to a fence) only when Vulkan or cross-process sharing needs it.
- **BO backing**: V3D has an MMU, so BOs are ordinary `B_FULL_LOCK` areas (not contiguous); PTEs come from
  `get_memory_map`. Write-combining (Normal-NC) by default, as Phoenix's uncached BOs: CPU writes (CLs,
  uniforms, vertices) need no maintenance. **Clean the cache after the kernel's zero-fill**: the clear goes
  through the cacheable physical map, so `arm64_dcache_flush_range` comes before the type change (the GENET
  pattern, `docs/design/genet-driver.md`:65-74). Readback-heavy BOs get a `CACHEABLE` flag with explicit
  clean/invalidate around jobs.
- **Page table**: 4 MiB contiguous, the full 4 GiB VA (Linux), instead of Phoenix's 1 GiB STK-sized window
  ([PX] `v3da_hw.c:65-67`).

### 2.2 Display

| Option | What | Verdict |
|---|---|---|
| **A. Keep the GOP framebuffer accelerant** | first GL demos run on it unchanged | Pick for stages 0–3; it has no vblank, one mode, no cursor |
| **B. Firmware-plane display driver + accelerant** (pick for stage 4) | kernel driver `drivers/graphics/bcm2711_display` publishing `graphics/bcm2711_display/0` (app_server prefers it automatically), accelerant `bcm2711_display.accelerant` | **Adopt** U-Boot's buffer as the primary (never re-allocate at attach: KDL and app_server hold it); modes = EDID (`GET_EDID_BLOCK_DISPLAY` → Haiku's `accelerants/common/decode_edid.c`) + plane-scaled lower modes (Phoenix M9: link stays native, the plane scales); retrace semaphore from the SMI IRQ (fallback: a thread doing `SET_VSYNC`); hardware cursor on plane 7; overlay hooks on planes 1-6 (MediaPlayer's `B_BITMAP_WILL_OVERLAY` YCbCr path gets HW scaling for free); `B_MOVE_DISPLAY`/flip for full-screen GL. All plane buffers below 1 GiB, contiguous, linear |
| C. Native HVS + pixelvalve + HDMI | real KMS | Only GPL reference; Pi-4-specific; HDMI clocks/PHY/SCDC are the bulk ([PR]:300-307). **Rejected** |
| D. Re-allocate the firmware framebuffer for mode changes | `FRAMEBUFFER_RELEASE` + `ALLOCATE_BUFFER` | Fallback for true HDMI mode changes only, with `frame_buffer_update()` + `vm_change_clones_to_null_areas` (the `framebuffer.cpp:68-70` pattern) |

### 2.3 Present path for GL (how a frame reaches HDMI)

| Tier | Path | Copies per frame | Stage |
|---|---|---|---|
| P1 | V3D renders into a linear BO → on swap, CPU copies it into the `BBitmap` → `SetBitmap` → `DrawBitmap` → back→front | 3 (the first reads WC/uncached memory, which is slow: Phoenix's glamor readback + swizzle cost 1.74 ms + 0.07 ms/row, 77 ms for 1080 rows, [PR]:132-133) | 3 |
| P2 | **The `BBitmap`'s own pages are imported into the V3D MMU** (a driver ioctl turns an `area_id` into a BO, exposed as a GEM name so `resource_from_handle(SHARED)` needs no Mesa surgery; the bitmap memory comes from app_server's shared areas, so the ioctl must `lock_memory_etc()` the range — wire and resolve it — before reading its pages; the A72 data cache is PIPT, so cache maintenance through the driver's own mapping also covers app_server's mapping); the GPU blits/renders linear into it, the driver cleans/invalidates the range around the job; `BitmapHook::SetBitmap` already returns the old bitmap, so double-buffering is native ([G] `GLView.cpp:212-219`) | 2 (app_server's) | 5 |
| P3 | Full-screen (`BWindowScreen`/`BDirectWindow`) or overlay: the surface's buffers are plane buffers (below 1 GiB) imported into V3D; swap = fence-gated `SET_PLANE` at the next update point | 0 | 6 |

### 2.4 app_server acceleration — scoped out of H12

app_server never calls the 2D hooks and copies dirty rectangles with the CPU (§1.1). Options measured later
(H13): hardware cursor (in stage 4), the overlay path (stage 4), and offloading `CopyBackToFront` to the DMA
engine or TFU (only if profiling shows it matters at 1080p). A GL/Vulkan-composited app_server is a redesign
of `HWInterface`/`DrawingEngine` comparable to Xorg's glamor, and is recorded as a follow-up, not H12 work.

### 2.5 Submission model

Stage 1–3: one job in flight across all queues ("serialise", Phoenix's `--serialize`, [PL] `M1…`:302-304),
but **asynchronous** to userland: the ioctl queues the job and returns; the IRQ completes it. Stage 7: bin,
render, TFU and CSD queues run concurrently, one job each (Linux `credit_limit = 1`); Phoenix's async server
gave STK +45% ([PL] `PLAN.md`:44). The per-job maintenance table (§1.3) is the spec for both.

## 3. Staged plan

All gates run on the bench via `scripts/sd-cycle.sh`; QEMU has no V3D. Without USB input, results are read
from `UserBootscript` → `tools/pi-tests/*` `HWR` lines on UART, plus HDMI snapshots.

**Stage 0a — firmware configuration (0.5 day).** Phoenix never booted *without* `vc4-fkms-v3d`: the overlay
stayed in its `config.txt` from before the PM/ASB discovery, and [PB]:12-20 says overlay + mailbox were not
sufficient, i.e. the PM_V3DRSTN + ASB writes are what is load-bearing. Whether the overlay is needed at all
is therefore open. Order, least regression risk first:
1. **No overlay** (today's image) — try stage 0b as is.
2. If V3D reads `0xdeadbeef`: a **minimal overlay** that only sets `v3d` (and `firmwarekms`, for the SMI
   vblank in stage 4) to `okay` and leaves `/soc/fb` alone.
3. The stock `vc4-fkms-v3d` last, and only after checking U-Boot: it **disables `/soc/fb`**, and with
   `hdmi@7ef00700` `disabled` in the base DTB ([DTS]:1784-1796) `/soc/fb` (`brcm,bcm2708-fb`, [DTS]:1971-1976)
   is the only node U-Boot's video driver can bind ([U] `drivers/video/bcm2835.c:66-72`) — the stock overlay
   would likely remove the GOP framebuffer and with it the H4 desktop.
Overlays are pinned by sha256 in `scripts/fetch-pi-firmware.sh`. The CMA node is size-only (no `reg`,
[DTS]:81-88), so it should not reserve RAM; verify.
*Exit:* `boot-bench.sh 3` → desktop 3/3 with the chosen configuration; reported RAM and GOP colours
unchanged; the DT Haiku receives shows the intended `status` values.

**Stage 0b — V3D power-on + identity from a kernel driver (2–3 days).** `drivers/graphics/v3d`: FDT attach,
`get_reg(0/1)` hub/core0, `get_interrupt(0)` (expect 106); PM/ASB from the `brcm,bcm2711-pm` node.
**Nothing touches PM, ASB or V3D in `init_driver`** (the boot-time device scan): power-on, ident read and
MMU set-up run in `init_device`/first `open()` of `/dev/dri/renderD128`, and for the first cycles only if a
driver settings file enables it. Phoenix's bring-up note warns why: a wrong PM/ASB write that hangs the SoC
becomes a boot-hang loop, and the PM block also holds the watchdog/reset controller ([PB]:134-140). An
unclocked V3D read is assumed to **hang the CPU** (no bus response — Phoenix saw it never complete), not to
raise a catchable SError, so the rule is: no V3D MMIO until `GET_CLOCK_STATE` reads back on. Sequence =
the proven power-on through the mailbox module; then log the seven ident words, `MMU_DEBUG_INFO`
(PA/VA width), clock rate and measured clock; mask and clear all interrupts.
*Exit:* in 3/3 cycles a test tool started from `UserBootscript` after the desktop is up opens the node and
UART shows `v3d: ident 0x04443356/0x81001422/0x40078121 uif 0x45 hub 0x000e1124/0x100/0xe00 clk 500 MHz`;
the desktop is unaffected; the overlay question (0a) is answered.

**Stage 1 — MMU, BOs, one control list (1.5–2.5 weeks).** Page table + scratch page, `apply_core_regs`,
`CREATE_BO`/`MMAP_BO`/`GET_BO_OFFSET`/`GEM_CLOSE`/`GET_PARAM` (live idents; TFU/CSD/CACHE_FLUSH = 1;
MULTISYNC/CPU_QUEUE/PERFMON = 0), `SUBMIT_CL` with the full maintenance sequence, IRQ handler (storm guard,
QPU ack, staged OUTOMEM chunk, 32 MiB pool), `WAIT_BO` + per-BO last-job fences, syncobj
create/destroy/wait/reset/signal, watchdog + reset, quarantine-on-free. Test with a userland tool that
replays a Mesa-generated clear-and-store CL (Phoenix's `cl-smoke` method, [PL] `M1…`:870).
*Exit:* `v3dtest clear` writes 4096/4096 pixels of the clear colour in 3/3 boots; an injected bad CL is
caught by the watchdog, the GPU resets and the next test passes; killing the test mid-job leaks no BOs
(area count back to baseline).

**Stage 2 — userspace stack, cross-built (1.5–2 weeks).** On the host: a meson cross file for
`aarch64-unknown-haiku` against the jam sysroot; build libdrm (Haiku backend), libglvnd (HGL → `libGL.so`
with `BGLView`, EGL loader) and Mesa (§0.7 options, `-Dzlib=disabled -Dxmlconfig=disabled
-Dshader-cache=disabled` at first). Mesa changes: `egl_haiku` creates `v3d_drm_screen_create(open(
"/dev/dri/renderD128"))` when the node exists (else softpipe, so the same build works on QEMU); add Haiku to
the libdrm-using paths without pulling in kmsro; carry the MMAP_BO-VA and fence-export patches. Package as a
local `mesa`/`mesa_devel` hpkg so `BuildFeatures` brings GLTeapot/GLInfo back ([H] `BuildFeatures:184-197`).
*Exit:* in QEMU the image runs `GLInfo` on softpipe; on the Pi, `GLInfo` reports
`renderer: V3D 4.2` and an `OpenGL ES 3.1` context (Phoenix's result on the same driver, [PN] `project_gles_bringup.md`).

**Stage 3 — GL on screen, P1 present (1 week).** In `egl_haiku`, a present step for hardware screens:
flush, wait the out-syncobj, copy the linear colour BO into the `BBitmap`, `SetBitmap`.
*Exit:* GLTeapot animates on HDMI (snapshot sequence shows motion) for 5 minutes with 0 GPU resets; fps
logged and compared with softpipe on the same image (expect a large gap even with 3 copies).
*Done 2026-10-18:* `glview` (BGLView, desktop GL, 256×256 window) for 300 s: 145 676 frames = **485.6 fps**,
PASS, 0 GPU resets, the rotating triangle on HDMI (`img-gl-stage3-hdmi.png`, two frames 20 s apart);
softpipe 125.5 fps (`tools/pi-tests/gl-screen.sh`). GLTeapot is not in the minimum image (H14).

**Stage 4 — firmware display driver (2–3 weeks).** §2.2 option B: adopt the boot buffer, SMI vblank →
retrace semaphore, EDID modes + plane-scaled modes, cursor plane, overlay hooks (RGB + YCbCr), flips.
*Exit:* `Screen` preferences lists ≥ 3 modes and switching works and reverts; retrace semaphore measures
59.9–60.1 Hz; hardware cursor follows the mouse (owner check) or a scripted `set_mouse_position`; MediaPlayer
plays a clip through an overlay; KDL still prints on HDMI after a mode change.
*Status 2026-10-19:* `drivers/graphics/bcm2711_display` + `bcm2711_display.accelerant` (haiku c9b4bfe234,
716633f51b, 7a37185fe7): retrace semaphore from the SMI interrupt (needs `tools/overlays/haiku-fkms.dts`,
now the default) at 60.00 Hz; modes up to native via a scaled primary plane (`screenmode` lists 40+, switch
and back verified on HDMI); hardware cursor on plane 7 (scripted moves, clipping, scaled modes); KDL prints
after a mode change. Open: overlays (needs MediaPlayer, i.e. H14), flips (stage 6), owner check with a mouse.

**Stage 5 — zero-copy into BBitmaps, P2 (1–1.5 weeks).** Area-import ioctl (pins pages, maps them into the
V3D MMU, quarantine on release), GPU blit into the imported bitmap, cache maintenance around the job.
*Exit:* GLTeapot fps at 1080p window ≥ 1.5× stage 3; `md5` of a readback equals the softpipe frame.
*Status 2026-10-19:* `DRM_V3D_HAIKU_IMPORT_MEMORY` (lock_memory_etc, pages wired into the V3D page
table, a BO handle back) and `DRM_V3D_HAIKU_SYNC_BO` (cache maintenance through the kernel's physical map)
in haiku bf6e4efdd2; Mesa 2e5fc430445: the v3d winsys opens `WINSYS_HANDLE_TYPE_KMS` handles, egl_haiku
imports the window's BBitmap once and presents with a GPU blit + `WAIT_BO` + sync (`HAIKU_EGL_NO_IMPORT=1`
= old copy path). `tools/pi-tests/gl-present.sh`, `glview` same binary, A/B by the environment variable:
**256² 1122 fps (copy 763), 800² 151.8 fps (copy 39.9) = 3.8×**, all PASS, triangle correct on HDMI.
Open: the md5 readback-vs-softpipe check; GLTeapot at 1080p needs H14 (not in the minimum image).

**Stage 6 — full-screen and overlay GL, P3 (1–1.5 weeks).** Full-screen: GL renders into plane buffers,
swap = fence-gated `SET_PLANE` flip (never render into the buffer on screen). Windowed overlay GL is optional
(firmware planes have alpha but no colour key, so occlusion needs app_server cooperation).
*Exit:* a full-screen GL demo runs vsynced at 60.00 fps with 0 missed flips over 1200 frames; the same demo
unsynced exceeds 60.

**Stage 7 — asynchronous queues (1–2 weeks).** Per-queue FIFOs, bin/render overlap, TFU/CSD concurrently;
watchdog per queue.
*Exit:* a GL benchmark (glmark2-es2 or a timedemo) ≥ stage 6 throughput, 0 wedges over a 30-minute soak,
`boot-bench` unaffected.

**Stage 8 — Vulkan (3–5 weeks, after H14 or with the cross build).** `MULTISYNC_EXT`, `CPU_QUEUE` jobs
(timestamps, queries, indirect CSD — net-new; Phoenix never implemented them, [PR]:454-463), sync-file fds;
v3dv with headless WSI first, then a Haiku WSI that presents through the stage 4/6 paths (X512's
VideoStreams WSI is a reference only).
*Exit:* `vkcube --wsi headless` renders N frames with correct readback; then vkcube on HDMI.

## 4. Risks

| Risk | Impact | Mitigation | Blocks? |
|---|---|---|---|
| V3D stays at `0xdeadbeef` even with the proven sequence (overlay or firmware difference vs Phoenix's firmware) | no GPU | stage 0a ladder (none → minimal → stock overlay); compare the firmware revision with Phoenix's; read `PM_GRAFX`/ASB states as [PB] did | blocks H12 |
| The stock `vc4-fkms-v3d` overlay disables `/soc/fb`, the only node U-Boot's video driver binds on our DTB | **H4 desktop lost** (no GOP) | try without an overlay first; minimal overlay that leaves `/soc/fb` alone | no, if ordered as in stage 0a |
| Unclocked or unpowered MMIO read, or a bad PM/ASB write, in the kernel | CPU/SoC hang; a boot-hang loop if done at boot | power-on only at first `open()`, opt-in via a settings file for the first cycles; read-back gate before any MMIO; ident check before serving | no (designed out) |
| SMI vblank needs `firmwarekms` okay, or never fires on our firmware | no retrace semaphore | `SET_VSYNC` thread fallback; HVS frame counter polling ([PL] `E3…`:349) | no |
| Plane buffers above 1 GiB scan garbage | wrong pixels | allocate plane buffers with `high_address = 0x40000000`, contiguous, at driver start (fragmentation) | no |
| Cache attribute aliasing (Normal-NC BO vs the kernel's cacheable physical map) | rare stale data | flush after zero-fill; never touch BOs through the physical map; same situation as USB/GENET today | no |
| Mesa `egl_haiku` hardware path not upstream | rebase cost per Mesa version | keep the patch small and `__HAIKU__`-guarded; HaikuPorts' own recipe already carries a patchset ([HP]) | no |
| GPU wedges on specific content (Phoenix: depth-heavy polys, q3dm7 binner wedge) | dropped frames | watchdog + reset + drop frame (proven); log CL dumps | no |
| BO freed while the GPU still writes (Phoenix C1 class) | heap/kernel corruption, hardest bugs | quarantine on free from day one; pages never return while a job submitted before the free is pending | no (designed out) |
| Present cost (P1: 3 copies at 1080p) makes the first demo look slow | perception | measure; P2/P3 stages exist for it | no |
| Licence of reused code: Phoenix driver files are Phoenix-RTOS licensed (`%LICENSE%`, © Phoenix Systems) | can't paste into MIT Haiku code | write the Haiku driver fresh in Haiku style; use [PX] and Mesa's MIT simulator as the hardware spec; Linux = facts only | no |
| No Haiku WSI, CPU-queue work | Vulkan late | headless first; stage 8 is last | Vulkan only |
| H14 slips | no native rebuilds/packages | cross build (stage 2) needs nothing from H14 | no |

## 5. Effort estimate

| Stage | Engineer-weeks |
|---|---|
| 0a + 0b config, power, ident | 0.5–0.7 |
| 1 kernel driver core (MMU, BOs, CL submit, IRQ, syncobjs, reset) | 1.5–2.5 |
| 2 cross-built libdrm + libglvnd + Mesa, `egl_haiku` HW screen | 1.5–2 |
| 3 GL on screen (P1) | 1 |
| 4 firmware display driver + accelerant | 2–3 |
| 5 zero-copy BBitmap (P2) | 1–1.5 |
| 6 full-screen/overlay GL (P3) | 1–1.5 |
| 7 async queues | 1–2 |
| 8 Vulkan | 3–5 |
| **Total** | **≈ 12.5–19** (stages 0–3, "accelerated GL on screen": ≈ 4.5–6) |

Anchors: Linux `v3d` is 6.7 k lines ([PR]:285-286); Phoenix's server is ~7 k lines + 1.4 k uAPI headers
([PX], `wc -l`); the Haiku driver should be ~3–4 k lines because syncobjs, waits and IRQs are kernel
primitives here. The Phoenix GPU estimate of 21–34 weeks ([PN] `project_gpu_drm_architecture_2026_09_26.md`)
included a KMS server, a libdrm rewrite, Xorg and Wayland — none of which H12 needs. At this project's
agent-driven pace (PCIe + USB, GENET and thermal/GPIO each took hours, `docs/log/WEEK-2026-W42.md`), stages
0–3 are plausibly days of calendar time; the risk is concentrated in stages 0b and 1, where only the bench
can answer.
