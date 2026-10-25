# Photocraft on Haiku arm64 (Raspberry Pi 4) — plan

Owner request 2026-10-25: run [Photocraft](https://github.com/storytold/photocraft) on Haiku on the Pi 4.
A big port, scheduled on top of the backlog (the performance work continues alongside).

## What Photocraft is

A photo editor in pure Rust (Apache-2.0/MIT, ~32 MB of Rust, edition 2024, **rust-version 1.95**).
Workspace of ~25 crates (`crates/*`: engine, raster, compose, color/cms, codecs, raw, heif, psd, text,
vector, paint, gpu, ui-egui, …) and apps `photocraft` (GUI), `photocraft-cli`, two web builds.

| layer | what it uses | on Haiku today |
|---|---|---|
| UI | egui 0.36 through eframe (winit) with features `wgpu`, `accesskit`, `wayland`, `x11`, `persistence` | winit has no Haiku backend; its **Wayland** backend can talk to Haiku's `wayland_server` (already used by our Wine) |
| GPU | wgpu 30 (`crates/gpu`, WGSL shaders; compositing and filters) | wgpu's Vulkan backend → Mesa V3DV (Vulkan 1.3 on the Pi); a Wayland surface needs VK_KHR_wayland_surface on Haiku, or the GL backend through EGL |
| files, clipboard | rfd (dialogs), arboard (clipboard, wayland-data-control) | rfd: xdg-portal/GTK or a fallback; arboard: Wayland or none |
| network | ureq + rustls + rustls-platform-verifier | needs a certificate store path for Haiku |
| threads | rayon | std threads work (Rust 1.90 tests on the Pi) |

## Phases

| phase | exit criterion |
|---|---|
| P0 toolchain | rustc/cargo **1.95** for `aarch64-unknown-haiku` with std (update `scripts/build-rust.sh`, `patches/rust`, `patches/rust-libc` from 1.90) |
| P1 CLI | `photocraft-cli` cross-built (all core crates: codecs, raw, color, engine) and running on the Pi on test images; output equal to the host's |
| P2 GPU headless | `crates/gpu` tests (wgpu on V3DV, headless) pass on the Pi |
| P3 window | the GUI app opens a window through winit's Wayland backend on `wayland_server`, wgpu presenting (Vulkan Wayland WSI, or GL/EGL) |
| P4 desktop integration | file open/save dialogs, clipboard, fonts, HiDPI/scaling, keyboard and mouse, tablet crate stubbed |
| P5 package + perf | a `photocraft` package in our repository, a desktop entry; responsive on 1080p photos on the Pi; profiled |

Risks: crates without Haiku support (`libc` gaps for arm64 Haiku; anything with OS-specific code paths:
sys-locale, open, platform-verifier, rfd, arboard); wgpu's Vulkan requirements beyond V3DV (limits,
features); winit's Wayland backend on `wayland_server` (protocol coverage: xdg-shell, seat, cursor,
fractional scale); build time and memory (a 32 MB workspace cross-built on the host).

## Status

### P0 — toolchain (done 10-25)
- **rustc + cargo 1.99.1** (the newest stable, 2026-10-13; ≥ 1.95 with headroom for Photocraft's next
  rust-version bumps): `scripts/build-rust.sh --version 1.99.1` → `artifacts/rust-1.99.1/` (`env.sh`);
  stage0 1.98.0, LLVM built from the tarball, ~25 min. 1.90.0 stays the default and stays in
  `artifacts/rust/` (Firefox and SpiderMonkey build with it).
- `patches/rust/<version>/`: the target patch rebased (1.99 types the spec's `arch` as `Arch::AArch64`;
  data layout unchanged). `patches/rust-libc/` applies unchanged to libc 0.2.189 (std's and Photocraft's).
- Host checks of the `tests` step pass: libc layout vs the Haiku headers, rust-smoke, the C program with the
  staticlib/cdylib, PIE and no COPY/TLSDESC/TPREL relocations (`artifacts/rust-tests-1.99.1/`).

### P1 — CLI (done 10-25: on the Pi 13/13 MD5s equal the host's)
- `scripts/build-photocraft.sh`: commit **486afd82cce9** (main of 10-24, 0.15.1) in `sources/photocraft`;
  `cargo vendor --versioned-dirs` of the whole lock into `artifacts/photocraft/vendor`, patched in place
  (file checksums cleared, package checksums kept), so the build is `--frozen` against the untouched
  Cargo.lock: no `[patch]` section, no change in the Photocraft tree. Patches: `patches/rust-libc/` (libc) and
  `patches/photocraft/<crate>-<version>/*.patch`.
- Only one crate needed a patch: **cap-primitives 4.0.3** (via cap-std, the automation layer's sandboxed
  file access): Haiku's dirent has no `d_type` (stat the entry, as on illumos), no `O_PATH`, no `O_RSYNC`, and
  `ino_t`/`nlink_t` are signed. Everything else (tokio/mio, rustix 1.1, socket2, getrandom 0.3/0.4, memmap2,
  fontdb, blake3's NEON C through the cross gcc, rayon) builds as is.
- `photocraft-cli` for arm64 Haiku: 37 MB stripped, PIE, needs libroot, libnetwork, libbsd, libgcc_s;
  ~4 min (thin LTO) per target. `tools/pi-tests/photocraft-cli.sh` (13 operations: info, convert between
  JPEG/PNG/WebP/TIFF, invert, Gaussian blur, unsharp mask, a new document): in QEMU `virt` **all 13 MD5s equal
  the x86_64 Linux build's** (`scripts/build-photocraft.sh compare LOG`).

### P2 — GPU headless (10-25: on the Pi 4 of 4 probe cases and 91 of 91 integration tests pass; two driver defects found and fixed)
- **Pi, 10-25 (with mesa be833ed6d67)**: probe 4 of 4 (blend-f32-2048 max 0.19/255), the `--bisect` cases and
  quadrants all within tolerance (blend-u16-2048 4.9/255, the same as on the host: the probe's Hue/Luminosity at 16 bits,
  not the GPU); photocraft-gpu-it **90 of 91**: `parity::blend_if` failed on V3D only ("U8 gray this hard
  adjustment, clipped") — **91 of 91 with mesa dee7e96cb04** (below).
- **Fixed (V3D compiler, upstream bug): a vector `mov` moved only its first channel.** In the Blend If pass
  (`fs_lerp`), `var this_px = b; if (op.p4.y < 0.5) { this_px = textureLoad(tex_c, …) }` is a vec4 phi; out of SSA
  the other branch copies `b`'s register into the phi's with a vec4 `mov` (`nir_trivialize_registers`), and
  `ntq_emit_alu` emitted only .x, so an adjustment layer's `this_px.yzw` were stale registers. Reduced with
  `photocraft-shader-repro` (tools/photocraft-gpu-test, `shaders/blend-if-min.wgsl`); **mesa dee7e96cb04** moves
  every channel. GL (v3d) shares the compiler. Upstreamable.
- **Fixed (V3DV, upstream bug): partial supertiles stored over neighbouring pixels.** blend-f32-2048 rendered zeros in
  parts of its right half: wgpu stages each layer tile's upload as its own vkCmdCopyBufferToImage region, V3DV copies
  them with a render pass per region whose frame ends at the region's far edge (upstream d30a6f81023), and the
  supertile grid of that frame (e.g. 2×3 tiles = 64×96 px for a 2304×512 frame) need not start at the region: the
  hardware stores every tile of a supertile, and a tile-aligned render area skips the loads, so the copy to (2048, 256)
  overwrote rows 192–255 of the tile above. Reproduced without Photocraft by `tools/gl-tests/vkf32.c -o` (192 tiled
  copies into a 4096² image: 2.48 M wrong RGBA32F pixels, 1.48 M RGBA8). **mesa be833ed6d67** chooses the smallest
  supertiles whose grid is aligned to the render area: 0 wrong. Upstreamable.
- **wgpu had no Vulkan backend on Haiku**: wgpu, wgpu-core and wgpu-core-deps-windows-linux-android enable
  it only on Windows/Linux/Android/FreeBSD (cfg aliases + a target-specific dependency that turns on
  wgpu-hal's backends). Three patches (`patches/photocraft/wgpu-30.0.1`, `wgpu-core-30.0.1`,
  `wgpu-core-deps-windows-linux-android-30.0.1`) add `target_os = "haiku"` for Vulkan only (GL stays off: wgpu-hal's
  GL code compiles,
  unused); the lock is unchanged (target-specific dependencies are locked for every target). wgpu-hal's Vulkan code
  itself builds as is. ash loads **`libvulkan.so.1`** (the plain-unix name), which is the mesa package's
  Khronos loader in `/boot/system/lib`; the loader finds V3DV through
  `/boot/system/add-ons/vulkan/icd.d/broadcom_icd.cortex-a72.json` (shipped by mesa since 26.2.0-5). Nothing
  else is needed on the Pi: no LIBRARY_PATH, no VK_DRIVER_FILES.
- **V3DV is below wgpu's default limits**: 4096 px textures (default 8192) and 4 colour attachments (default 8),
  so `DeviceDescriptor::default()` — what every crates/gpu test asks for — gets no device on the Pi, and the
  tests would all print "skipping … no device" and pass. The app itself asks for the defaults lowered to the
  adapter's (`ui-egui` `gpu_canvas::device_limits`, which already has a V3D test case), so P3 is not affected.
- `tools/photocraft-gpu-test/` (outside the Photocraft tree, its own Cargo.lock = a subset of Photocraft's,
  built `--frozen` against the same vendor directory): **photocraft-gpu-probe** (adapters, limits under wgpu's
  defaults, Rgba32Float/Rgba16Float/Rgba8 usages, the app's device; four documents — 8 blend modes U8, six
  adjustments U16, a drop shadow U8, 8 separable modes on 2048² F32 — composited on the GPU and on the CPU
  compositor, max premultiplied difference against parity.rs's tolerance of 1/255, a second render on a fresh
  compositor must be bit-identical, raw results written out for an MD5; `--thread`: all on a second thread) and
  **photocraft-gpu-it**: crates/gpu's integration tests copied by its build.rs with the device requests rewritten to the app's (6 counted rewrites;
  anything new upstream fails the build). Plus crates/gpu's unit tests (**photocraft-gpu-unit**, CPU, built in
  the Photocraft workspace). `scripts/build-photocraft.sh gpu` builds all three for both targets (~1 min each,
  release; staged in `artifacts/photocraft/gpu-non-packaged/bin/`, 6.8/8.1/4.4 MB stripped, PIE, the same
  four libraries as the CLI), then `gpuhost` runs `tools/pi-tests/photocraft-gpu.sh` on the host.
- **Oracle** (decided): the CPU compositor on the same machine. GPU results are not bit-identical across drivers
  (RADV and lavapipe differ in all four MD5s, both within tolerance), so GPU MD5s are only per-driver
  fingerprints; the CPU results' MD5s must equal the host's (they are plain Rust f32 code), and every test
  run must pass as many tests as on the host. `scripts/build-photocraft.sh gpucompare LOG` grades that and
  lists any skip.
- Host (x86_64, Radeon 780M RADV, Vulkan): probe 4/4 (max 0.24/255), unit 41, integration 79 + device-loss 12
  passed; the same 4/4 on lavapipe and on wgpu's GL backend.
- QEMU `virt` (Haiku arm64, no GPU): the chain works up to the device — wgpu loads libvulkan.so.1, the loader
  reads the V3DV manifest, Mesa reports `Opening /dev/dri/renderD128 failed`, the probe ends "no adapter" (on the
  main thread and with `--thread`); unit tests 41 passed.
- **Defect (Haiku arm64, not Photocraft): a second Vulkan instance on a new thread jumps to NULL.** The first
  instance is fine; after vkDestroyInstance (the loader unloads the driver; ash also closes libvulkan.so.1) the
  next vkCreateInstance made **on a thread other than the one that loaded the driver first** stops at PC 0
  (`user instruction abort, FAR 0`) in V3DV: `vk_instance_init → glsl_type_singleton_init_or_ref →
  util_call_once_data_slow → call_once → pthread_once@plt` (tail calls: the trace cannot tell an unresolved
  `pthread_once` slot from Mesa's thread-local once-context read back empty). The same instances on one thread
  work; with the driver preloaded (`LD_PRELOAD=/boot/system/lib/libvulkan_broadcom.so`, never unloaded) they work.
  Reproduced without Rust: **`tools/haiku-tests/vkloop.c`** (`vkloop`: 3 instances on the main thread PASS, `-k`
  keeping the loader PASS; `-t`, a thread per instance: crash at the second, with or without `-k`). A TLS +
  pthread_once library reloaded across threads (a plain C test) did not reproduce it. Suspects for the
  runtime_loader: TLS of a reloaded image in a new thread (the 10-24 `__tls_get_addr` fast path, haiku
  076da9813a, is the newest change there), or symbol binding on the reload. Every crates/gpu test creates its own
  instance on its own test thread, so the Pi script preloads the driver for them and runs three tests without
  the preload as a control (`reload`, reported only). **P3**: the app makes one Vulkan instance per process
  (its extra DX12-only instance is Windows-only), so it should not hit this — unless device-loss recovery or
  eframe recreates the instance on another thread.
- Pi run (bench), ~45 min: `scripts/mkimage-pi4.sh --out artifacts/images/photocraft-gpu.img --add-tree
  artifacts/photocraft/gpu-non-packaged --bootscript tools/pi-tests/photocraft-gpu.sh`, then
  `scripts/netboot-cycle.sh --image artifacts/images/photocraft-gpu.img --secs 2700 --label photocraft-gpu
  --until 'PCG end'`, `scripts/build-photocraft.sh gpucompare <uart log>`. Expected: `chosen: Vulkan "V3D 4.2…"`,
  limits below the defaults `max_texture_dimension_1d/2d 4096 (8192)`, `max_color_attachments 4 (8)` (maybe
  more), `compositor: Rgba32Float` (V3DV: RGBA32F renders, does not blend), probe 4 of 4, unit 41, it 79,
  device-loss 12, the 4 CPU MD5s equal the host's; the reload control crashing (exit 137) on its second test.

### P3 — window (10-25: Photocraft's GUI runs on the Pi — eframe/winit on Haiku's Wayland server, wgpu presenting through Mesa's Haiku WSI into the server's views)
- **`photocraft` links for arm64 Haiku**: `scripts/build-photocraft.sh --only gui` (release, ~6 min) →
  `artifacts/photocraft/gui-non-packaged/bin/photocraft`, 63 MB stripped, PIE, NEEDED only libroot, libnetwork,
  libbsd, libgcc_s. libwayland-client/-cursor, libxkbcommon and libvulkan.so.1 are **dlopened** (wayland-sys's
  `dlopen` feature, which wgpu-hal turns on; xkbcommon-dl; ash), so pkg-config is not involved (the 10-25 check's
  "wayland-sys finds no wayland-client" did not reproduce: its build script returns early with `dlopen`).
- Six vendored-crate patches, the Photocraft tree untouched (`patches/photocraft/<crate>-<version>/`):
  - **rustix 0.38.44**: `pipe_with()` on Haiku (pipe() + fcntl for CLOEXEC/NONBLOCK; the libc crate has no
    `pipe2` binding though libroot has it) — calloop's ping and smithay-client-toolkit's clipboard offers.
  - **calloop 0.13.0** and **winit 0.30.13**: no `AsFd`/`AsRawFd` for `EventLoop` on Haiku (polling 3.11 uses its
    poll(2) backend there, which has no poller fd; nothing in the graph uses them). winit also: `is_main_thread()`
    as on NetBSD (the Rust main thread's name), and **Wayland is chosen without `WAYLAND_DISPLAY`** on Haiku.
    winit's `free_unix` alias already includes Haiku: its Wayland and X11 backends build as they are.
  - **wayland-backend 0.3.17**: `Backend::connect_default()` = `wl_display_connect(NULL)`. X547's
    libwayland-client has no socket: only `wl_display_connect()` creates its event pipe and loads
    `wayland-server-inproc.so`, while `wl_display_connect_to_fd()` (what `Backend::connect(stream)` calls) leaves
    the pipe's write end unset. The Rust server backend (epoll/kqueue only) is compiled out on Haiku; the Rust
    socket code sets FD_CLOEXEC itself (no MSG_CMSG_CLOEXEC), as on macOS.
  - **wayland-client 0.31.15**: `Connection::connect_to_env()` uses it on Haiku (WAYLAND_DISPLAY,
    WAYLAND_SOCKET and XDG_RUNTIME_DIR mean nothing there).
  - **rfd 0.17.2**: a stub backend — file dialogs return None (as if cancelled), message dialogs the answer that
    changes nothing, each noted on stderr (replaced by the native backend in P4).
  - Not needed: accesskit_unix (not in the Haiku graph: accesskit_winit gates it to Linux/BSD), x11rb/x11-dl
    (build; X11 is only used with `DISPLAY` set), arboard + wl-clipboard-rs, sctk (beyond rustix), egui-winit,
    eframe.
- The vendor step now records each patched crate's patches (`artifacts/photocraft/patches.md5`) and, when they
  change, cleans that crate's Haiku artifacts in both target directories (dev and release): cargo never rebuilds a
  registry crate because its files changed (a winit patch was silently not picked up once).
- **QEMU `virt`, before the bridge** (`tools/pi-tests/photocraft-gui.sh` on an image with `artifacts/wayland-stage` +
  `gui-non-packaged`): the app connects to the in-process server (`wl_ips_client_connected`), binds wl_compositor,
  wl_subcompositor, wl_output, wl_seat, wl_shm, xdg_wm_base and zwp_text_input_manager_v3, creates the toplevel
  (`set_title("PhotoCraft")`, min 760×480), gets `xdg_surface.configure` (0×0: the client picks; winit sets the geometry 1024×768, its size fitted to the
  screen) and creates its CSD subsurfaces (hidden: no buffers) —
  then **stops: `Vulkan driver does not support VK_KHR_wayland_surface`** (eframe's wgpu surface). Our Vulkan
  loader is built without Wayland WSI and Mesa with `-Dplatforms=haiku`; the app's crash guard relaunches it with
  `--safe-gpu`, which stops the same way (it still needs a wgpu surface for the window). A Pi run would stop at
  the same call (the surface is made before the adapter is chosen).
- **The presenting bridge (built 10-25, host + QEMU)**: Haiku's own Vulkan WSI, not a Wayland one (a Mesa Wayland WSI
  on a hardware driver needs linux-dmabuf, which wayland_server cannot offer). Haiku's WSI is
  VK_EXT_headless_surface + `VkHaikuSurfaceCreateInfoMESA { view: BView* }` (mesa `wsi_common_haiku.cpp`,
  `<vulkan/vk_haiku_surface.h>`; `patches/vulkan-loader` keeps the struct in the chain; vkcube/SDL use it).
  - **wayland_server 0.1.20251004-8** (`patches/wayland_server/...-wl-surface-view.patch`, `scripts/build-wayland.sh
    --only wayland_server`): exports **`wl_ips_haiku_surface_view(uint32 surfaceId)`** → the wl_surface's BView (a
    synchronous message to the server's thread, after the client's earlier requests; NULL without a view). It marks
    the surface *presented externally*: it never gets a buffer, so its size is its xdg window geometry — on each
    commit the view and (client-side decorations, as winit's) the window take it, and commits do not invalidate the
    view (Draw has nothing to draw; the view colour is already B_TRANSPARENT_COLOR). It **runs the window**: until
    its first Show() a BWindow stays locked by the thread that made it (the server's), and the WSI must lock it to
    read the view's size and to draw (found by wlview hanging on the lock in QEMU). And it **shows a toplevel at
    once** when its window geometry is already set (winit sets it before it makes its Vulkan surface), else at
    the first commit with one — see the Pi runs below for why.
  - **wayland_server: the loopers held at exit** (`...-wl-window-hold-at-exit.patch`): exit() runs libbe's static
    destructors (token space, looper list, roster) while the add-on's loopers still run; a client exiting right after
    destroying its toplevel had the window delete itself meanwhile — `bogus pointer (double free?)` in
    `BTokenSpace::RemoveToken` from `~BWindow`, or `looper must be locked before proceeding` (4 of 15 test exits in
    QEMU; the windows that run since the export made it common). An exit handler registered via `__cxa_atexit` when
    the server starts (so it runs before libbe's static destructors — an `__attribute__((destructor))` runs after
    them and made it worse) lets the server handle pending requests, waits ≤ 1 s for the quitting windows' threads,
    then locks the Wayland looper, the remaining windows and its application looper for good. QEMU: 18 of 18 clean.
  - **wgpu-hal 30.0.1** (`patches/photocraft/wgpu-hal-30.0.1/`, new `src/vulkan/haiku.rs`): on Haiku a Wayland window
    handle → `wl_proxy_get_id` → `wl_ips_haiku_surface_view` (dlopen of `wayland-server-inproc.so`, as Wine) →
    `vkCreateHeadlessSurfaceEXT` with the Haiku struct (32 bytes, asserted: the loader patch copies that size);
    VK_EXT_headless_surface is enabled on Haiku. **Each present commits the wl_surface** (`wl_proxy_marshal_flags`,
    opcode 6), as a Wayland WSI does: winit relies on that commit to apply its `set_window_geometry` and to deliver
    the frame callback it waits for before the next redraw (without it: a hidden 0×0 window and a stalled app).
    Logs `Haiku Wayland surface: wl_surface@N, view 0x…, <VkSurfaceKHR>` (target `wgpu_hal::vulkan::haiku`).
  - **`tools/haiku-tests/wlview.cpp`** (built into the GUI stage by `--only gui`): the server's half without a GPU —
    an xdg_toplevel drawn into its view by the client (as Mesa's presenter), checks the export, the window lockable
    and hidden before the first commit, shown at 640×400 on the first buffer-less commit, resized to 800×500 by a new
    geometry, 7 of 7 frame callbacks. **QEMU virt: 0 bad.**
  - **QEMU virt** (no GPU; photocraft-gui.sh): the app now gets past the surface — `Haiku Wayland surface:
    wl_surface@16, view 0x…` (wl_surface@16 is the toplevel's: `get_xdg_surface(…, wl_surface@16)` in the trace) —
    and stops at the adapter: `MESA: Opening /dev/dri/renderD128 failed`, `No suitable graphics adapter found`;
    the same for `--safe-gpu`. That is all QEMU can show of the app: no adapter → eframe exits before a frame.
  - Size: the swapchain is configured to winit's inner size (1024×768 on QEMU's screen; the app asks 1440×900 and
    shrinks to the monitor) while the view is still 0×0 (no geometry committed yet): the first acquire is SUBOPTIMAL
    by design (Mesa's swapchain takes any extent and scales); egui-wgpu presents that frame anyway and reconfigures
    before the next (`needs_reconfigure`), and the first present's commit gives the view that size. (Were the view's
    size ever to differ from winit's for good, every frame would be SUBOPTIMAL and reconfigure the swapchain.) Resizing: a configure from the server (move/resize tracking,
    fullscreen) → winit resizes, sets the geometry, eframe reconfigures, the next present's commit resizes the view
    and window. Between them a frame is drawn scaled.
  - Limitations: Mesa reads the view's size
    with the window locked (timeouts of 0.5 s while the window is busy); the server has no copy of a frame, so a
    view uncovered by another window stays as it was until the app presents again (egui redraws on input or
    animation only); frame callbacks come from the view's Pulse, at the BWindow default (~2 Hz) until the window is
    activated (then the screen's rate); several Wayland connections in one process: the export takes the first
    surface of that id with a view; the view pointer must not outlive the toplevel (eframe drops the surface first;
    Mesa locks through a BMessenger, which fails safely once the view is gone).
- Also seen: std's `File::try_lock` is unsupported on Haiku (the app's GPU-crash marker lock only warns); the
  xkbcommon Compose table for "en.UTF-8" is missing (a warning).
- **Pi run 1** (10-25, main session; `artifacts/uart/20261025-045807-photocraft-gui.log`): presenting works — the
  `trace` and `safe` runs show the whole PhotoCraft UI on HDMI — but the boot's first GPU run (`window`) showed a
  blank 1440×900 window for ~45 s.
- **Pi run 2** (diagnostics, `artifacts/uart/20261025-055359-photocraft-gui2.log`, HDMI every 5 s): wgpu-hal's trace
  showed the cause, two things together: (1) the first frame (present #0 at +1.46 s, SUBOPTIMAL: view 0×0) was drawn
  while the window was still hidden — it was shown only at that frame's commit — and so lost; (2) the next frame came
  only at **+44.2 s**: with Mesa's shader cache cold, the document's GPU compositor pipelines take ~43 s to compile
  on V3D (the main thread blocked; the UI showed "Opening … Decoding 2%" frozen meanwhile). Warm cache (`window2`):
  frames flow from +0.27 s, no gap. `noimport` (HAIKU_VK_NO_IMPORT) changed nothing. `early` (the window shown when
  wgpu asks for its view, cache disabled): the UI chrome on screen at once, the document after the same ~44 s compile.
  No SUBOPTIMAL after the first frame, swapchain extent = view size (1440×900), no dropped frames
  (`wsi_haiku: … 0 dropped`). Fix: the early showing became the server's behaviour; the diagnostics were removed.
  Open (performance): the ~43 s cold compile of Photocraft's compositor shaders on V3D (each boot's first document
  on a fresh shader cache; the cache keeps it afterwards) — find the expensive pipeline(s).
- **Pi test** (~8 min, bench): `scripts/build-wayland.sh --only wayland_server`
  (revision 8, built 10-25), `scripts/build-photocraft.sh --only gui` (photocraft + wlview), `scripts/stage-packages.sh
  --wine-runtime`, `scripts/mkimage-pi4.sh --out artifacts/images/photocraft-gui.img --add-tree artifacts/wayland-stage
  --add-tree artifacts/photocraft/gui-non-packaged --bootscript tools/pi-tests/photocraft-gui.sh`,
  `scripts/netboot-cycle.sh --image artifacts/images/photocraft-gui.img --secs 480 --hdmi-every 5 --label
  photocraft-gui3 --until 'PCW end'`; read the `PCW ` lines and the HDMI frames (markers in the script's header).
  Runs: `wlview` (`WLV result: 0 bad`), `window` (60 s, cold shader cache: the window with the UI at once, the
  document after the compile), `trace` (WAYLAND_DEBUG=client, 25 s, plus commit counts per wl_surface), `close` (asked
  to quit after 20 s with `hey <team> quit`: must exit by itself, no `DEBUGGER` line on the UART), `safe`
  (`--safe-gpu`, 30 s). wayland_server 8 is in `artifacts/packages` (rev 7 removed there) but not in the image's
  repository (`build/jam/repositories/HaikuPorts/arm64` in sources/haiku) and not published: the test stages it as
  a tree.

### P4 — desktop integration (10-25: built; host + QEMU checked; the Pi run pending)
- **File dialogs: rfd's Haiku backend** (`patches/photocraft/rfd-0.17.2/0001-haiku-backend.patch`, replaces the stub):
  the Tracker's file panel (BFilePanel) for open (one or several files), pick folder and save, BAlert for message
  dialogs, through a C++ shim (`src/backend/haiku/rfd_haiku.cpp`) that the crate's build.rs compiles with the
  target's g++ (`CXX_aarch64_unknown_haiku`/`AR_…` from env.sh; no `cc` crate, so the lock is unchanged) and links
  with libtracker, libbe, libstdc++. Photocraft uses only `AsyncFileDialog` (`services.rs::show_file_dialog`:
  `set_parent`, `set_directory`, `add_filter`, `set_file_name`; pick_file/pick_files/pick_folder/save_file,
  awaited on a helper thread); the sync API and MessageDialog work too.
  - **The BApplication is the Wayland server's**: wayland-server-inproc.so creates one when the client connects
    (`wl_ips_client_connected`) and later casts `be_app` to its own class, so the shim never makes one; without
    `be_app` (no Wayland connection yet) a dialog answers "cancelled" at once with `rfd: no BApplication …` on
    stderr. In Photocraft the connection always comes first.
  - The panel's answer goes to a BLooper of the shim; the panel sends B_CANCEL whenever it hides (after an answer
    too), which ends the wait. Async: a thread per dialog, rfd's oneshot channel. With a parent window (the app
    always gives one) the panel is app-modal.
  - Filters: the panel has no type menu; all filters merge into one BRefFilter (extension in any case, folders
    always shown, `*` = all). The Tracker's type-ahead also matches hidden entries (Haiku's `FindBestMatch`
    walks the unfiltered pose list) — a Tracker quirk, not ours.
  - The Save button: BFilePanel enables it for the name when it shows the folder, so the shim sets the name
    first (name after folder left Save disabled until the first key press: found in QEMU, Return did nothing).
- **Clipboard: arboard's Haiku backend** (`patches/photocraft/arboard-3.6.1/0001-haiku-backend.patch`), BClipboard
  through a C++ shim (same build.rs scheme; libbe, libstdc++; no BApplication needed). **What the Haiku build used
  before**: egui-winit's clipboard and Photocraft's image copy/paste both go through arboard (egui-winit's
  smithay-clipboard is cfg'd to Linux/BSD); arboard took its Linux backend, which needs WAYLAND_DISPLAY
  (wlr-data-control) or X11 — the Pi log of P3 shows `Failed to initialize arboard clipboard: … X11 server
  connection timed out` at every start, so egui fell back to a clipboard inside the program and Photocraft's
  Copy/Paste of pixels failed. **Why arboard, not the server**: wayland_server has wl_data_device (bridged to
  BClipboard) but not the data-control protocol arboard speaks, and egui-winit would still not use
  wl_data_device on Haiku; images would need BBitmap↔PNG conversion in the server too. One patch covers both
  users, needs no wayland_server change and no revision bump, and reaches the system clipboard directly.
  - Formats as Haiku's applications use them: text `text/plain` (also read `text/plain;charset=utf-8`, which the
    server's data offers keep), HTML `text/html`; images written as `image/bitmap` (an archived B_RGBA32 BBitmap
    as ShowImage/Screenshot copy, built as a message: no app_server needed) plus `image/png`, read from
    `image/bitmap`/`image/x-be-bitmap` (RGBA32, RGB32, RGB24, GRAY8) or any `image/*` the image crate decodes;
    files as the Tracker copies them (entry_ref `r<dev>_<node>` + copy mode `m<dev>_<node>`) plus
    `text/uri-list` — Photocraft's "paste a copied file" (#338) then works with the Tracker's Copy.
- **Compose** (libxkbcommon **1.13.2-2**, `scripts/build-wayland.sh` step libxkbcommon, `x11_locale`): Haiku's
  `LC_CTYPE` is `locale --message` (`en.UTF-8`), libxkbcommon finds Compose files through libX11's locale
  database (`/boot/system/data/X11/locale`: compose.dir, locale.alias), which Haiku does not have, and its
  en_US fallback is compiled out (no `newlocale`) → `[XKB-679] couldn't find a Compose file` and no dead
  keys/Compose in any Wayland client. The package now ships that database, generated from the HaikuPorts libX11
  1.6.9 source as libX11's nls/Makefile does (cpp -traditional + its sed): the 16 UTF-8 Compose files (1 MB;
  includes as `%S/…`, so XLOCALEDIR copies work), plus 106 aliases for Haiku's language-only names
  (`en.UTF-8 → en_US.UTF-8`, `pt.UTF-8 → pt_PT.UTF-8`, …). Host check (the host's libxkbcommon on the generated
  tree): en/de/pt/fi/C give a table, `dead_acute e → é`.
- **Fonts** (`patches/photocraft/fontdb-0.23.0`): fontdb's `load_system_fonts()` took the Linux path on Haiku
  (fontconfig files, /usr/share/fonts: nothing) — Photocraft's text tool and SVG text had no system font. Now
  Haiku's folders: /boot/system/data/fonts, …/non-packaged/data/fonts, ~/config/(non-packaged/)data/fonts.
- HiDPI: wayland_server's wl_output has scale 1 and no fractional-scale; winit's scale factor is 1 — right for
  the Pi's 1080p, no work. Keyboard/mouse: keys reach egui through the server's xkb keymap (Wine's typing tests
  use the same path); the Pi run checks Ctrl shortcuts (Ctrl+O, Ctrl+A, Ctrl+C) in Photocraft itself. Tablet:
  photocraft-tablet has backends for macOS, Windows and Linux only and builds on Haiku without one (a pen is a
  mouse, pressure 1): "stubbed" already, nothing to do.
- photocraft now NEEDs libtracker, libbe and libstdc++ besides libroot, libnetwork, libbsd, libgcc_s (all in the
  base system); `--only gui` checks that BFilePanel and BClipboard are linked.
- **`tools/photocraft-desktop-test`** (own Cargo.lock, a subset of Photocraft's; built by `--only gui` or
  `--only desktop`): rfd, arboard and fontdb as the app uses them, without the app's window (QEMU has no GPU for
  Photocraft): connects to the Wayland server first (be_app, as the app), then one command (clip-text/html/
  image/files set+get, clear, open/save/folder via AsyncFileDialog on a helper thread, sync-open, alert, fonts).
  `tools/haiku-tests/keyinject.cpp` gained Escape (`^[`) and Up/Down (`^<`, `^>`) and is built into the GUI stage.
- **QEMU virt** (`tools/pi-tests/photocraft-desktop.sh`, 10-25 09:25): all checks pass — text both ways with
  Haiku's `clipboard` as the second tool (UTF-8 intact); HTML + alternative; a 64×48 image read back with the same
  FNV hash, `clipboard -d` lists `image/bitmap` (`_cspace` B_RGBA32, `_frame` 63×47) and `image/png`;
  `screenshot -c` read as 1024×768; two files as Tracker refs (`r3_262240 = entry_ref(…)`, mode 'Tcsl') and read
  back; clear → ContentNotAvailable. Panels (screenshots in the image): open by type-ahead → photocraft-masks.jpg;
  filter jpg / png + Down + Return → the jpg / the png (the panel lists only the filter's files); Escape →
  cancelled; save → `<tmp>/pcd saved.png`; folder → the panel's folder; sync open; alert Return → Yes, Escape →
  Cancel; without Wayland → cancelled at once. Fonts: 12 faces, 6 Noto families. Compose: `xkbcli-compile-compose
  --locale en.UTF-8` 5897 sequences, `<dead_acute> <e> : "é"`. `photocraft-gui.sh` in QEMU: the XKB-679 error
  gone (it was in every earlier run), the app unchanged up to its surface (no adapter, as before).
- **Pi test** (bench; not run by the agent): (1) `scripts/stage-packages.sh --wine-runtime` (takes libxkbcommon
  1.13.2-2), `scripts/mkimage-pi4.sh --out artifacts/images/photocraft-desktop.img --add-tree artifacts/wayland-stage
  --add-tree artifacts/photocraft/gui-non-packaged --bootscript tools/pi-tests/photocraft-desktop.sh`,
  `scripts/netboot-cycle.sh --image artifacts/images/photocraft-desktop.img --secs 300 --hdmi-every 5 --label
  photocraft-desktop --until 'PCD end'` — the same `PCD` lines as in QEMU (screen size 1920×1080 for
  `image-screen`). (2) Photocraft itself: `scripts/mkimage-pi4.sh --out artifacts/images/photocraft-gui.img
  --add-tree artifacts/wayland-stage --add-tree artifacts/photocraft/gui-non-packaged --bootscript
  tools/pi-tests/photocraft-gui.sh`, `scripts/netboot-cycle.sh --image artifacts/images/photocraft-gui.img --secs 600
  --hdmi-every 5 --label photocraft-gui4 --until 'PCW end'`: the new `desktop` run — Ctrl+O → `panel "Open": yes`
  (modal over the app, HDMI), type-ahead + Return opens photocraft-masks.jpg, Ctrl+A Ctrl+C → `clipboard -d` lists
  image/bitmap + image/png and `PDT clip-image-get` gives the JPEG's size; no `Failed to initialize arboard`, no
  `couldn't find a Compose file` anywhere in the log.
- Publishing (after the Pi check): libxkbcommon + libxkbcommon_devel **1.13.2-2** are in `artifacts/packages` (-1
  moved to `artifacts/packages-old`); the other two parts of the bump (the copy in `generated.arm64/download/`, the
  version in `build/jam/repositories/HaikuPorts/arm64`) are left for the publish. wayland_server **-10** (the exit
  fix below) is in `artifacts/packages` (-9 moved to `artifacts/packages-old`), not published. Note for the publish: the package now carries libX11's nls files
  (MIT/X11 licence, libX11's copyright holders) under libxkbcommon's; and anyone's next `publish-repo.sh` ships -2
  (the mesa #71 fix is waiting), with or without the Pi check.
- **Pi runs (main session, 10-25 ~09:45)**: photocraft-desktop.sh passes everything on the Pi (as in QEMU; screen
  copy 1920×1080). photocraft-gui4 (`artifacts/uart/20261025-094150-photocraft-gui4.log`): wlview, window, trace,
  close, safe fine, no Compose or arboard errors — but the `desktop` run's Ctrl+O never opened the panel.
- **Why Ctrl+O did nothing: wayland_server gives clients Haiku's *shortcut* key as Control.** `FromHaikuModifiers`
  (HaikuSeat.cpp, X547's) sends B_COMMAND_KEY as xkb Control, B_CONTROL_KEY as Mod1 (Alt; plus a bit 18 the
  keymap does not have, which xkbcommon ignores) and B_OPTION_KEY as Mod5 (AltGr). `tools/haiku-tests/wlkeys`
  (a toplevel made as Photocraft's, the keyboard read through libxkbcommon as winit does) in QEMU, keys through
  QEMU's USB keyboard and input_server (`tools/pi-tests/wayland-keys.sh`, host: `qmp-hmp.py SOCK "sendkey …"`):
  physical **Ctrl+O → `Control_L` key but mods `Mod1` → ctrl 0 alt 1**; physical **Alt+O → ctrl 1 alt 0** (Haiku's
  default keymap makes left Alt the Command key); Win+O → Mod5, "ó". keyinject's `^o` (B_CONTROL_KEY) gives the
  same as physical Ctrl: egui saw Alt+O. So nothing was lost — the test pressed the wrong key for Haiku.
  **Decided: keep the mapping** (no server change, wayland_server stays -9). It is Haiku's convention: every Haiku
  application's shortcuts are on Command (Alt+C copies, Alt+O opens), Qt on Haiku maps Command to Control the same
  way, Wine's verified keyboard behaviour (10-23/25 sweeps) rests on it, and a user who wants the Ctrl key for
  shortcuts switches it in the Keymap preferences ("Switch shortcut keys to Windows/Linux mode"), which then reaches
  Wayland clients as Control too. On Haiku, Photocraft's Ctrl shortcuts are therefore on the Command key, as in any
  Haiku app. keyinject gained `%x` (Command+x, as input_server sends it); photocraft-gui.sh's desktop run uses
  `%o`, `%a%c`.
- **Pi run photocraft-gui5** (main session, `artifacts/uart/20261025-100534-photocraft-gui5.log`): Command+O → the panel
  at once; open + Command+A/C → image/bitmap + image/png on the clipboard. Two problems, both fixed 10-25 (11:51):
  - **The wrong file opened**: the panel starts in /boot/home (no document yet), where the script had saved
    photocraft-desktop-panel.png — "photocraft-m" matched the screenshot. Now the test image is copied to
    /boot/home/pcw-open-test.jpg and typed in full, and the copied image's size is checked against the JPEG's
    (`photocraft-desktop-test jpeg-size`): "copied image 2400x1500 = the document's: ok".
  - **A crash at quit**: "Segment violation" in BLooperList::FindLooperPred ← IsLooperValid ← BLooper::Lock ←
    task_looper on thread 911 — the **"wayland" looper** (in QEMU the same client's threads: wayland = app looper − 3,
    914 − 3), not an rfd panel (the shim deletes its panel and target before the dialog returns). The exit hold
    (wayland_server -8/-9) locks the server's loopers, but their threads still wake for every later message and
    then look themselves up in libbe's looper list, which libbe's static destructors free right after.
    **wayland_server 0.1.20251004-10** (`patches/wayland_server/...-wl-window-stop-at-exit.patch`): a held looper's
    thread is suspended while it waits (a suspended thread runs no user code again; the team's exit kills it; a
    running one gets ≤ 50 ms to wait again, so none is stopped inside malloc); requests sent once the server is
    held are dropped (they filled the held looper's port and the sender, possibly the exiting thread, waited
    forever); and the Wayland looper is held before the windows (stopped first, a window left the Wayland looper
    blocked on its full port with its lock held, and the add-on's `gServerHandler` destructor then waited for that
    lock forever — found by the first version of the fix, 5 of 40 hangs). rfd's shim also holds the loopers of a
    dialog still open at exit (an exit handler registered with the first dialog; an alert's Quit() and a closing
    panel coordinate with it).
  - **QEMU A/B** (`tools/pi-tests/wayland-exit.sh`: `tools/haiku-tests/wlexit` — a toplevel as Photocraft's, a thread
    committing every ms, exit() after 50-450 ms plus a request from a later exit handler — and
    photocraft-desktop-test exiting right after a panel or alert closed, or with one still open): server **-9: a
    window thread crashed in 1 of 20 wlexit runs** (`thread_hit_serious_debug_event … w>wlexit`) **and another run
    of 30 logged `debug_server: … Segment violation`**; **-10: 40/40 for each of the five kinds (200 exits), no
    debugger entry in the syslog**. Tools: `tools/haiku-tests/wlexit.cpp`, built into the GUI stage.
- Not verified yet: a native application reading our `image/bitmap` (ShowImage's paste instantiates a BBitmap from
  it; the fields are BBitmap::Archive's, one for one), and Command shortcuts work end to end (gui5). **Pi test (rerun of the GUI part)**:
  `scripts/build-photocraft.sh --only gui`, `scripts/stage-packages.sh --wine-runtime`, `scripts/mkimage-pi4.sh
  --out artifacts/images/photocraft-gui.img --add-tree artifacts/wayland-stage --add-tree
  artifacts/photocraft/gui-non-packaged --bootscript tools/pi-tests/photocraft-gui.sh`, `scripts/netboot-cycle.sh
  --image artifacts/images/photocraft-gui.img --secs 600 --hdmi-every 5 --label photocraft-gui6 --until 'PCW end'`
  (stage-packages takes wayland_server -10 now; expect "copied image 2400x1500 = the document's: ok", "desktop: exit 0",
  no "entered the debugger"); optionally the exit stress `scripts/mkimage-pi4.sh --out artifacts/images/wayland-exit.img
  --add-tree artifacts/wayland-stage --add-tree artifacts/photocraft/gui-non-packaged --bootscript
  tools/pi-tests/wayland-exit.sh`, `scripts/netboot-cycle.sh --image artifacts/images/wayland-exit.img --secs 900
  --label wayland-exit --until 'PEX end'` (expect "0 stuck" five times and no "PEX syslog:" line).

### P5 — package + performance (10-25: package built, not published; the V3D compile 3.5× faster, Pi-checked)
- **The `photocraft` package**: `scripts/build-photocraft.sh --only package` (after `--only gui`; `--revision N`)
  → `artifacts/packages/photocraft-0.15.1-1-arm64.hpkg` (29.5 MB). Layout: `apps/PhotoCraft/PhotoCraft` — a small
  launcher (`tools/photocraft-package/launcher.cpp`), what the Deskbar (`data/deskbar/menu/Applications/PhotoCraft`)
  and the Tracker start; `apps/PhotoCraft/bin/PhotoCraft` — the program; `bin/photocraft` → the program (Terminal);
  `documentation/packages/photocraft/` (README, both licences). Requires haiku, lib:libgcc_s, lib:libstdc++,
  `mesa >= 26.2.5-6`, `libxkbcommon >= 1.13.2-2`, `wayland_server >= 0.1.20251004-10`, lib:libwayland_client,
  lib:libwayland_cursor, xkeyboard_config. Runs without environment variables (no WGPU_BACKEND: the only backend
  built in on Haiku is Vulkan; the XKB and X11 locale data at the packages' own paths). Settings in
  `~/.config/photocraft` (Photocraft's Linux rule, `$XDG_CONFIG_HOME` or `~/.config`; not patched).
  - **Why a launcher**: the Tracker hands documents to an application as a B_REFS_RECEIVED message — "Open with", a
    double click, a drop — never as arguments (`BRoster::Launch` drops the messages for a B_ARGV_ONLY application,
    found on the Pi: the window opened, no document). Photocraft takes documents as arguments and has no
    BApplication of its own (the Wayland server makes one later). The launcher collects refs and arguments,
    starts `bin/PhotoCraft` with the paths, quits (B_MULTIPLE_LAUNCH).
  - **Resources and attributes** (`tools/photocraft-package/PhotoCraft.rdef.in`, `photocraft-bin.rdef.in`, host rc +
    xres): launcher `application/x-vnd.storyteller-photocraft` with the image types it opens (the Linux desktop
    entry's list plus Haiku's image/x-bmp, image/x-targa) and the icon; the program
    `application/x-vnd.storyteller-photocraft-app` (no types; the Deskbar shows it by name and icon). The registrar
    makes an application's MIME entry from its *attributes* (`create_app_meta_mime` reads BEOS:APP_SIG as an
    attribute), so the host `mimeset` copies the resources to attributes before `package create` — with jam's MIME
    database (`objects/common/data/mime_db/mime_db`; another path sniffs the ELF as octet-stream and copies
    nothing); this host keeps attributes per inode in `generated.arm64/attributes`, cleared first and removed with
    `rm_attrs`.
  - **Icon**: HVIF from the Linux 256 px icon by `tools/haiku-icon/png2hvif.py` (blurred so the engraving's hatching
    becomes tone, 4 colours, pixel-edge outlines simplified: 996 bytes, 39 paths). The SVG (329 kB of engraving
    paths) is far beyond HVIF's limits.
  - QEMU (release image 25e + the packages in /boot/system/packages, `tools/pi-tests/photocraft-package.sh`):
    activated; launcher, program, command, Deskbar entry in place; `env -i` start reaches its Wayland surface and the
    adapter (no GPU there); "Open with" (`tools/haiku-tests/mimeapps --launch`, BRoster::Launch with refs as the
    Tracker) → `bin/PhotoCraft /boot/home/pck.jpg`; the launcher's MIME entry (META:FILE_TYPES) is made at its
    first start, after which image/jpeg, png, tiff, x-targa list it among their supporting applications. On the Pi
    (session, 10-25 13:05-13:20): the packages activated live, "Open with" on a JPEG opened the document.
    Not tested by hand: the Deskbar menu entry with a mouse.
  - Known gaps: the app's MIME entry (so "Open with") exists only after its first start (the registrar does not
    run mimeset on package activation); `.pcraft` has no Haiku MIME type; Photocraft's single-instance lock needs
    `File::try_lock`, unsupported in Rust's std on Haiku ("starting a separate PhotoCraft" — each launch its own
    window).
- **The ~43 s first-start compile** — measured on the Pi (session on image-2026-10-25e, mesa 26.2.5-6, shader cache
  off: MESA_SHADER_CACHE_DISABLE=true), new tool `photocraft-pipeline-time` (tools/photocraft-gpu-test, built by
  `--only gpu`: each compositor pipeline built alone, timed; `--threads N`):
  - all 33 pipelines one after the other **56.5 s**, of which **fs_layerbatch 33.5 s** (13k VIR instructions,
    10.5k temps, 667 blocks: an unrolled loop; register allocation fails at 4 threads and ends at 2) and fs_atop,
    fs_fxmerge, fs_adjust, fs_fxpaint 3.4-4.5 s each; the probe's parallel build (rayon, 4 CPUs) **41-43 s** —
    fs_layerbatch is the critical path.
  - Haiku `profile` on it: 63 % `vir_calculate_live_intervals` + 13 % memset + 7 % `vir_opt_copy_propagate`.
    Liveness is recomputed after every spill (81 times for this shader); per call 225 ms of it was
    `vir_live_variables_defin_defout_dataflow` — a forward problem iterated in reverse block order, so one block per
    pass (upstream Mesa has the same code).
  - **Fix (haiku-pi/mesa rpi4, 3 commits on dee7e96cb04, upstream-quality, pushed)**: f55f89ccad9 defin/defout
    in program order; baaaeaef308 liveness without per-block passes over all temps (no per-block clear of the
    partial-update states, start/end from set bits only, one bitset allocation kept across calls); 76543fafdfc copy
    propagation keeps a list of the available MOVs (kills and clears no longer scan every temp).
  - **Result (Pi)**: fs_layerbatch **33.5 → 6.6 s**, all pipelines sequential **56.5 → 17.5 s**, the probe's build
    **43.1 → 11.8 s**; Photocraft itself (from the package, Open with on a 2400×1500 JPEG, cache off): document on
    screen after **30 s → 10 s**. Same output: V3D_DEBUG=qpu,fs,vs,cs dumps of all 105 shaders identical (931k
    lines, same MD5), shader-db identical, the probe's 4 GPU results bit-identical (4/4 within tolerance),
    photocraft-gpu-it **79 passed, 0 failed** (device_loss skipped) with the new driver.
  - Left: register allocation (~1.5 s), NIR (~2.5 s) of fs_layerbatch; compiling in the background so the UI is not
    frozen would be a Photocraft change (its tree stays untouched here). The warm cache still gives 0.26 s.
  - **For the mesa package** (not built here): `scripts/build-gl-stack.sh --only mesa`, `--only stage`,
    `scripts/package-gl-stack.sh --revision 7` (mesa 26.2.5-7; the three-part bump), then Photocraft's
    `requires` can name `mesa >= 26.2.5-7`.
- Pi steps prepared (bench needed): (1) the package on a fresh image: `scripts/image-add.sh
  artifacts/images/haiku-pi4-2026-10-25e.img artifacts/images/photocraft-pkg.img` with the five packages
  (photocraft, wayland, wayland_server, libxkbcommon, xkeyboard_config from artifacts/packages) as
  `…:/boot/system/packages/<name>`, mimeapps (`aarch64-unknown-haiku-g++ … tools/haiku-tests/mimeapps.cpp -lbe`)
  as `…:/boot/home/mimeapps`, a JPEG as `…:/boot/home/pck.jpg`, `tools/pi-tests/photocraft-package.sh` as
  `…:/boot/home/config/settings/boot/UserBootscript`; `scripts/sd-cycle.sh --flash artifacts/images/photocraft-pkg.img
  --secs 240 --label photocraft-pkg --until 'PCK end'`. (2) After mesa -7: the same with the new mesa package,
  `PCK open with: program: … pck.jpg` and the document in `photocraft-package-open.png`.

