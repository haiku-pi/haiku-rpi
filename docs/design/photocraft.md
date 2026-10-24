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
