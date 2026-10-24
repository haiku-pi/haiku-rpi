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

### P1 — CLI (built, equal to the host in QEMU 10-25; the Pi run pending)
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

### GUI crates on Haiku (input for P3; `cargo check -p photocraft --target aarch64-unknown-haiku`)
- **wayland-sys**: its build script finds no `wayland-client` through pkg-config for the target (needs
  `PKG_CONFIG_*` pointed at our wayland port's .pc files in the sysroot, or its `dlopen` feature).
- **calloop 0.13** (winit's Wayland event loop): rustix 0.38's `pipe_with` is compiled out on Haiku (no
  `pipe2`), and polling 3.11's `Poller` lacks `AsFd`/`AsRawFd` there (its poll(2) backend).
- **rfd 0.17**: no backend for Haiku (its xdg-portal/GTK3 backends are cfg'd for Linux and the BSDs):
  every dialog trait is unimplemented — needs a Haiku backend (BFilePanel) or the portal cfg widened.
- Blocked behind those (not checked): wayland-client, smithay-client-toolkit, winit, egui-winit, eframe,
  arboard, accesskit_unix, photocraft-ui-egui. **Check clean for Haiku:** wgpu, wgpu-core, wgpu-hal,
  **photocraft-gpu** (so P2 can start), egui, sys-locale, rustls-platform-verifier, ureq, x11rb
  (`artifacts/photocraft/gui-check.log`, rustc 1.99.1).
