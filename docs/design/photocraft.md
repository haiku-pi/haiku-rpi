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

### P2 — GPU headless (built 10-25; host and QEMU checked; the Pi run pending; one Haiku defect found)
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

### P3 — window (groundwork 10-25: the app builds and reaches Haiku's Wayland server in QEMU; presenting is next)
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
- **QEMU `virt`** (`tools/pi-tests/photocraft-gui.sh` on an image with `artifacts/wayland-stage` +
  `gui-non-packaged`): the app connects to the in-process server (`wl_ips_client_connected`), binds wl_compositor,
  wl_subcompositor, wl_output, wl_seat, wl_shm, xdg_wm_base and zwp_text_input_manager_v3, creates the toplevel
  (`set_title("PhotoCraft")`, min 760×480), gets `xdg_surface.configure` (1024×768) and its CSD subsurfaces —
  then **stops: `Vulkan driver does not support VK_KHR_wayland_surface`** (eframe's wgpu surface). Our Vulkan
  loader is built without Wayland WSI and Mesa with `-Dplatforms=haiku`; the app's crash guard relaunches it with
  `--safe-gpu`, which stops the same way (it still needs a wgpu surface for the window). A Pi run would stop at
  the same call (the surface is made before the adapter is chosen): worth one after the bridge below.
- **Next (decided): present through Haiku's existing Vulkan WSI**, not a Wayland one (a Mesa Wayland WSI on a
  hardware driver needs linux-dmabuf, which wayland_server cannot offer). Haiku's WSI is
  VK_EXT_headless_surface + `VkHaikuSurfaceCreateInfoMESA { view: BView* }` (mesa `wsi_common_haiku.cpp`,
  `patches/vulkan-loader` keeps the struct in the chain; vkcube/SDL use it). Plan: (1) wayland_server exports
  `wl_ips_haiku_surface_view(uint32 surfaceId)` → the wl_surface's BView (`HaikuSurface::View()`), as Wine's
  `wl_ips_haiku_surface_no_activate` is exported; (2) a wgpu-hal patch: on Haiku, a `RawWindowHandle::Wayland`
  surface is made by `wl_proxy_get_id(wl_surface)` → dlsym of that export → `vkCreateHeadlessSurfaceEXT` with the
  Haiku struct chained (the instance enables VK_EXT_headless_surface). Open points: the view's size versus the
  configure, wayland_server drawing (CSD subsurfaces) into the same view, resize.
- Also seen: std's `File::try_lock` is unsupported on Haiku (the app's GPU-crash marker lock only warns); the
  xkbcommon Compose table for "en.UTF-8" is missing (a warning).
- **Pi test** (after the bridge; ~10 min, bench): `scripts/build-photocraft.sh --only gui`,
  `scripts/stage-packages.sh --wine-runtime`, `scripts/mkimage-pi4.sh --out artifacts/images/photocraft-gui.img
  --add-tree artifacts/wayland-stage --add-tree artifacts/photocraft/gui-non-packaged --bootscript
  tools/pi-tests/photocraft-gui.sh`, `scripts/netboot-cycle.sh --image artifacts/images/photocraft-gui.img --secs 420
  --label photocraft-gui --until 'PCW end'`; read the `PCW ` lines and the HDMI capture (markers in the script's
  header). Runs: `window` (45 s, the JPEG test image), `trace` (WAYLAND_DEBUG=client, 25 s), `safe` (`--safe-gpu`,
  30 s), each with a fresh PHOTOCRAFT_CONFIG_DIR and a screenshot in /boot/home.
