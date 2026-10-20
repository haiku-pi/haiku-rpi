# A browser beyond WebPositive on Haiku arm64: feasibility

Status: research note, 2026-10-20. Nothing here has been built, except two single-file compile probes (§2.3).
Facts are cited (file path or URL). Estimates and untested ideas are marked **[guess]** or **[unverified]**.

Paths: `ports/` = `sources/haikuports` (shallow clone, HEAD c17ec5a, 2026-10-18).

Short answer: **Firefox is the realistic target.** A current Gecko port to Haiku exists (Firefox 157, with a native
Haiku widget backend), but only for x86_64. Taking it to arm64 is a cross-build plus a short list of arm64-specific
patches. The Chromium route (QtWebEngine) is Qt5 on a 2020 Chromium, has no arm64 history, and costs more for an
older engine.

---

## 1. Gecko on Haiku today

- **HaikuPorts ships Firefox 157.0.1**: `ports/www-client/firefox/firefox-157.0.1.recipe`, `ARCHITECTURES="x86_64"`.
  - One patch, `patches/firefox-157.0.1.patchset`: 18.5k lines, 245 files, ~12.2k added lines. Author Gerasim
    Troeglazov (3dEyes), dated 2026-10-12, "Based on patches sourced from https://github.com/kenz-gelsoft/gecko-dev/".
  - Not in upstream Mozilla. It is an out-of-tree patch that has to be rebased for every Firefox release (every 4 weeks).
- **History**:
  - KENZ's fork [kenz-gelsoft/gecko-dev](https://github.com/kenz-gelsoft/gecko-dev) (branch `haiku128`) came first.
  - 3dEyes took the port over; the patches are also in [threedeyes/Gecko4Haiku](https://github.com/threedeyes/Gecko4Haiku).
  - 2026-07: Mozilla allowed the "Firefox" name on Haiku; the port was at 153.0 then
    ([forum](https://discuss.haiku-os.org/t/mozilla-officially-gave-us-permission-to-use-the-firefox-name-on-haiku/19582)).
  - 2026-10-05: Firefox 157 with the native backend was published on HaikuDepot
    ([Haiku Insider](https://www.haikuinsider.org/firefox-native)).
  - R1/beta6 coverage: Firefox is "only available on the x86-64 version of Haiku"
    ([The Register, 2026-09-03](https://www.theregister.com/os-platforms/2026/09/03/haiku-os-rises-/-beta-6-sails-open-web-/-virtual-winds-fly-fast/5294184)).
- **Forks give us nothing extra.** Iceweasel 157.0.1 and Iceweasel ESR 153 (`ports/www-client/iceweasel/`), plus
  LibreWolf, Floorp and Waterfox, all carry the same 3dEyes/KENZ patch. All are x86_64 or disabled
  (`iceweasel_esr-153.0.recipe`: `ARCHITECTURES="!x86_64"`, while the `_bin` variant repackages an x86_64 tarball).
  Porting any of them to arm64 is the same work as porting Firefox.
- **Status on x86_64**: usable, packaged, current release.
  - Rendering is software (Skia, double-buffered).
  - WebGL goes through a `BGLView` context provider; full compositor support is missing
    ([Haiku Insider](https://www.haikuinsider.org/firefox-native)).
- **No arm64 build of Gecko for Haiku was found anywhere** [searched: HaikuPorts, Gecko4Haiku, forum, news].

## 2. Toolchain: what has to exist for arm64

### 2.1 Cross-build, not native

- A native build on the Pi is out. The Pi has 4 GB of RAM, and a libxul link needs far more: even the x86_64 recipe
  runs `./mach build -j4` with `CARGO_BUILD_JOBS=1`.
- We already cross-build WebKit on the Linux host (`scripts/build-webkit.sh`, ~1 h compile), and Firefox should follow
  the same pattern.
- In a cross-build, these run on Linux x86_64 and **do not need to exist for Haiku arm64**: node.js, Python, cbindgen,
  clang, lld, nasm, gn, and all Rust host tools.
  - The host already has clang 21.1.8 and node v22.22.1.
  - Firefox 157 needs node ≥ 12.22.12 (`python/mozbuild/mozbuild/nodeutil.py`).
  - cbindgen can be installed with `cargo install`.
- Only two things must exist *for* `aarch64-unknown-haiku`: the target C/C++ libraries, and a **Rust standard library**.
- The HaikuPorts recipes for cbindgen, nodejs 20/22/24 and llvm 21–23 declare `all`. That means *declared*, not built
  for arm64 (same caveat as `package-farm-plan.md` §2.3). We don't need them anyway.

### 2.2 Rust

- **Upstream rustc has no aarch64 Haiku target.** [Platform support](https://doc.rust-lang.org/nightly/rustc/platform-support.html)
  lists only `i686-unknown-haiku` and `x86_64-unknown-haiku`, both Tier 3 with std.
- **The `libc` crate**: in [`src/unix/haiku/mod.rs`](https://github.com/rust-lang/libc/blob/main/src/unix/haiku/mod.rs)
  the aarch64 module is `// TODO`. The x86_64 module is 58 lines: fpu state, `mcontext_t` and `ucontext_t`. So the
  gap is small, but it hits twice: std's libc, and Firefox's vendored `third_party/rust/libc`.
- **HaikuPorts**:
  - `rust-1.79.0` is x86 only.
  - `rust_bin-1.94.1` repackages `dl.rust-on-haiku.com` tarballs for x86 and x86_64. The aarch64 tarball for 1.94.1
    returns 404 (probed 2026-10-20).
- **An out-of-tree arm64 target already works**: [rainygirl/renkuos-rust](https://github.com/rainygirl/renkuos-rust)
  (Apache-2.0, last push 2026-10-07).
  - It adds a 24-line `aarch64_unknown_haiku.rs` target spec (base `haiku::opts()`, `+v8a`, inline stack probes, PIE)
    and registers it in `spec/mod.rs`.
  - It builds Rust **1.90.0** with the Haiku arm64 cross gcc 13.3.0, and the libc crate is not patched.
  - It reports threads, atomics, unwinding, file I/O, TCP, child processes and proc-macros working on an arm64 guest.
  - Its target is RenkuOS (a Haiku fork), so the binaries are reference only. The target spec should carry over.
- **Version**: Firefox 157's `MINIMUM_RUST_VERSION` is **1.90.0**, the same as Firefox 158
  (`python/mozboot/mozboot/util.py` at tags `FIREFOX_157_0_1_RELEASE` and `release`).
- **Our step**: build upstream rustc ≥ 1.90 on the x86_64 host, with the target spec added and
  `target = ["x86_64-unknown-linux-gnu", "aarch64-unknown-haiku"]`. That gives a host compiler plus an arm64 **std
  only**, with no Haiku-hosted rustc or cargo. **[guess]** 1–2 h compile, 2–4 days including fixes.

### 2.3 C/C++ cross compiler

- Host clang 21 already targets `aarch64-unknown-haiku`. Probed 2026-10-20 against `artifacts/sysroot-arm64`:
  - A C file using `<OS.h>` and `<signal.h>` compiles to an AArch64 ELF object.
  - A C++20 file using `<vector>`, `<string>` and `<Window.h>` also compiles, once
    `-isystem …/develop/headers/c++ -isystem …/develop/headers/c++/aarch64-unknown-haiku` is added. Clang's Haiku
    driver does not find libstdc++ in this sysroot layout.
- **Linking with lld for Haiku: [unverified].**
- **The patch's `split_triplet()` accepts any `*-haiku` triple.** But `python/mozboot/mozboot/haiku.py` assumes a
  native Haiku host, and nobody is known to have cross-configured Gecko for Haiku. Whether mach accepts
  `--host=x86_64-pc-linux-gnu --target=aarch64-unknown-haiku`, with bindgen/libclang pointed at the Haiku sysroot,
  is **[unverified]**. It is the first thing to test.

### 2.4 Target libraries

- The recipe requires these, none of them in our sysroot yet: nspr, nss, libevent, libffi, fontconfig, harfbuzz,
  cairo, libvpx, gettext (`libintl`), and `media_helpers` (3dEyes' MediaKit helper,
  [threedeyes/media_helpers](https://github.com/threedeyes/media_helpers)).
- All of them have HaikuPorts recipes declared `all` (`ports/dev-libs/nspr`, `nss`, `libevent`, `media-libs/libvpx`,
  `harfbuzz`, `fontconfig`, `x11-libs/cairo`, `haiku-libs/media_helpers`).
- We already have: libwebp, libjpeg-turbo, zlib, freetype, Mesa (`libGL`), openssl3, sqlite.
- Firefox can also use its bundled copies: drop `--with-system-nspr/nss/libevent/libvpx` to cut the list.
  **[guess]** That costs 2–4 days with `scripts/cross-port.sh`.

## 3. Widget toolkit

- **Native backend**: `widget/haiku/`, ~6.2k added lines in the patch, selected with
  `--enable-default-toolkit=cairo-haiku` (`additional-files/mozconfig_native`; the recipe defaults to
  `UI_BACKEND="NATIVE"`).
  - Windows are BWindow/BView, drawn by Skia in software.
  - Native pieces: BFilePanel, BClipboard, BCursor, IME, drag and drop, BNotification, a native scrollbar theme, and
    `moz-icon:` HVIF icons.
  - Media and devices: a MediaKit cubeb backend (~1.4k lines), BJoystick gamepad, WebRTC capture, WebSerial.
  - WebGL goes through BGLView (patch header).
- **GTK3 alternative**: `mozconfig_gtk` uses `cairo-gtk3-wayland-only` over Haiku's Wayland layer. GTK3 3.24.52 is
  in HaikuPorts (`all !x86_gcc2`), but that path also needs glib, pango, atk, gdk-pixbuf, dbus and libnotify on arm64.
- **Use the native backend on arm64.** It needs fewer dependencies, and it is what upstream Haiku Firefox now ships.

## 4. QtWebEngine (Falkon, Otter, qutebrowser, Dooble)

- **Qt5 only, Chromium 87.** `ports/dev-qt/qtwebengine/qtwebengine-5.15.18.recipe` builds
  `qtwebengine-chromium/87-based`.
  - It has `ARCHITECTURES="!x86_gcc2 ?x86_64"`, with the comment "disabled: takes too long to compile on builder".
  - Users install `qtwebengine_bin-5.15.18` instead, an x86_64 hpkg prebuilt on GitHub releases.
  - Patches: 2 + 9 commits, 13.8k lines, including "fix build on Haiku x86_64" and "Fixes build for x86 arch".
  - The forum calls it crash-prone, with system-wide stalls
    ([Falkon thread, Dec 2023](https://discuss.haiku-os.org/t/falkon-ex-qupzilla/8916?page=5)).
- **No Qt6 WebEngine.** There is no `qt6-webengine` directory in `ports/dev-qt/`, and `qt6_webview-6.10.3.recipe`
  has its WebEngine build dependencies commented out. The 2023 forum hope of a Qt6 switch "in February 2024" has not
  landed (same thread).
- **The browsers**:
  - Falkon 23.08.5 and Dooble need Qt5 WebEngine. Falkon also needs ~20 KF5 frameworks.
  - qutebrowser needs `pyqtwebengine5_python310`.
  - Otter Browser uses **QtWebKit** (`lib:libQt5WebKit`), an older WebKit than our HaikuWebKit, so it would be a step
    backwards.
- **For arm64**, all of this would mean porting the Qt5 stack, then cross-building a 2020 Blink/V8 whose Haiku patches
  are x86-specific. V8 itself supports arm64 upstream; the Haiku pieces of V8 and Chromium `base` would need an arm64
  pass. **[guess]** Months, with Firefox-sized builds (the recipe gives no figures; nothing measured here), for an
  engine six years behind Chromium. **Not recommended.**

## 5. arm64-specific Gecko port work (the risk register)

These come from reading the 157.0.1 patch against Firefox 157.0.1 sources (`github.com/mozilla-firefox/firefox`,
tag `FIREFOX_157_0_1_RELEASE`).

| Item | Where | Fix |
|---|---|---|
| Wasm/JIT signal context | `js/src/wasm/WasmSignalHandlers.cpp`: the patch's `XP_HAIKU` block defines only x86 registers (`eip`, `rip`, …) | arm64 `PC/SP/FP/LR/R##_sig` from Haiku's `struct vregs` (`x[30]`, `lr`, `sp`, `elr`; `headers/posix/arch/arm64/signal.h`), as done for JavaScriptCore in `patches/haikuwebkit/haikuwebkit-1.10.0-arm64.patch` |
| JIT icache flush | `js/src/jit/arm64/vixl/MozCpu-vixl.cpp` `EnsureIAndDCacheCoherency`: aarch64 is only handled for Linux/Android/FreeBSD; any other OS hits `#error Please check/implement the cache invalidation code for your OS` | add `__HAIKU__` to that branch (user-mode `dc civac`/`ic ivau`; our loader sets SCTLR_EL1.UCI/UCT, already relied on by the WebKit patch) |
| Cross-core JIT flush | `js/src/jit/FlushICache.cpp`: on non-Linux, `CanFlushExecutionContextForAllThreads()` returns `true`, assuming "the syscall for flushing the icache will flush the execution context for other cores" | on Haiku the flush is done from user mode with no syscall, so other cores get no `isb`. Same situation as FreeBSD; low but real risk of rare stale-code crashes. Possible fix: a broadcast-`isb` syscall **[guess]** |
| XPCOM call stubs | `xpcom/reflect/xptcall/md/unix/moz.build`: the patch adds Haiku to the x86 OS list only; the aarch64 block is `("Linux", "FreeBSD", "NetBSD", "OpenBSD")` | add `"Haiku"` (the aarch64 stubs are OS-generic AAPCS64) |
| Rust `libc` | aarch64 Haiku module is `TODO` | write it (~60 lines), vendored in Firefox's `third_party/rust/libc` too |
| UA / oscpu strings | patch hard-codes `"Haiku x86_64"` | use the build arch |
| WebRTC | 770 patched lines in `third_party/libwebrtc`, needs `gn` | `--disable-webrtc` for the first builds |

**Other risks:**

- The cross-configure itself (§2.3).
- Pi memory under multi-process Gecko (e10s/Fission defaults are kept by the patch; how many processes and how much
  memory on 4 GB is **[unverified]**).
- Kernel stability under a multi-process, multi-threaded browser (open Pi freeze, `docs/log/`).
- Software Skia compositing at 1080p on four A72 cores: speed **[unverified]**.
- WebGL via BGLView on our Mesa v3d stack **[unverified]**.
- Upkeep: rebasing an 18.5k-line out-of-tree patch every 4 weeks. We can follow HaikuPorts' x86_64 patch and carry
  only a small arm64 delta on top.
- Host build RAM: the libxul link with lld, no LTO, is **[guess]** ~10–16 GB, so run it under `scripts/heavy-build.sh`
  (the host has 29 GB).

## 6. Recommendation

Port **Firefox 157 with the native toolkit (`cairo-haiku`)**, cross-built on the Linux host with the existing
`cross-port.sh` / `package-port.py` pipeline. Reuse the HaikuPorts patch as is, and add an arm64 delta of roughly
200–400 lines **[guess]**.

**First milestone (mirrors the `jsc` gate used for WebKit):**

1. A host rustc ≥ 1.90 with an `aarch64-unknown-haiku` std; a Rust hello-world and a std smoke test (threads, TCP)
   run on the Pi.
2. The standalone **SpiderMonkey shell** (`js/src`, which already needs Rust), cross-built with the Haiku patch and
   the arm64 hunks from §5, runs on the Pi with JIT and wasm enabled. It should pass a short benchmark loop with JIT
   on and off and give the same results.

This exercises Rust std, clang cross-compilation, the signal and icache patches, and the kernel's JIT behaviour,
before any work on libxul.

**Later milestones:** the full `mach build` cross for `aarch64-unknown-haiku` (`--disable-webrtc`); Firefox starts
and renders https://www.haiku-os.org/ on the Pi; then an hpkg in the haiku-pi repository, media (cubeb/MediaKit),
and WebGL.

**Effort, in engineer-days (all [guess], high variance):**

| Step | Days |
|---|---|
| Rust: target spec, libc module, host rustc + arm64 std, Pi smoke test | 2–4 |
| Target libraries (or switch to Firefox's bundled copies) | 2–4 |
| Cross-configure mach + arm64 patch hunks + SpiderMonkey shell on the Pi (milestone 1) | 3–5 |
| Full libxul cross-build iterations | 5–10 |
| Runtime bring-up on the Pi (startup, IPC, rendering, crashes) | 5–15 |
| **Total to "Firefox renders a page on the Pi"** | **~17–38 (3–6 weeks)** |

Packaging, media, WebGL and stability come on top of that. QtWebEngine is not worth pursuing. If a second engine is
ever wanted, the current WebKitGTK recipe (`ports/net-libs/webkit-gtk/webkit_gtk-2.52.5.recipe`, `all !x86_gcc2`)
would be the one to evaluate, but it needs the GTK3 stack.
