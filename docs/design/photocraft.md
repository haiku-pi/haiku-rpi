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

### P2 — GPU headless (10-25: on the Pi 4 of 4 probe cases and 90 of 91 integration tests pass; two driver defects found, one fixed)
- **Pi, 10-25 (with mesa be833ed6d67)**: probe 4 of 4 (blend-f32-2048 max 0.19/255), the `--bisect` cases and
  quadrants all within tolerance (blend-u16-2048 4.9/255, the same as on the host: the probe's Hue/Luminosity at 16 bits,
  not the GPU); photocraft-gpu-it **90 of 91**: `parity::blend_if` fails on V3D only (the GPU result is about 1 − the
  CPU's: "U8 gray this hard adjustment, clipped"), open.
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
    changes nothing, each noted on stderr — until a native one (BFilePanel/BAlert, P4).
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
