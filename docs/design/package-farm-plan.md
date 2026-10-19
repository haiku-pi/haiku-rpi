# H14 — arm64 package farm: findings and plan

Status: research note, 2026-10-19. Nothing here has been built or run yet. Facts are cited (file path, with line
numbers, or URL). Estimates and untested ideas are marked **[guess]** or **[unverified]**.

Paths: `haiku/` = `sources/haiku` (branch `rpi4`, hrev60262-based); `gen/` = `sources/haiku/generated.arm64`;
`hp/` = a 2026-10-19 shallow clone of github.com/haikuports/haikuporter (HEAD 9ffc2d0, version 1.5.3);
`hpx/` = haikuports.cross (HEAD a6e2c64); `ports/` = haikuports (HEAD c17ec5a).

---

## 1. How `@minimum-mmc` gets its packages today

### 1.1 The repository definition

`haiku/build/jam/repositories/HaikuPorts/arm64` declares a `RemotePackageRepository HaikuPorts` with base URL
`https://eu.hpkg.haiku-os.org/haikuports/master/build-packages` (line 3). It lists:

- 3 "any" packages: `ca_root_certificates-2025_12_02-1`, `haikuporter-0_bootstrap-1`, `noto-20170202_bootstrap-7`
- 32 arm64 packages, all versioned `…_bootstrap-1`: bash, binutils 2.41, bison, coreutils, curl(+devel), expat(+devel),
  findutils, flex, freetype(+devel), gawk, **gcc 13.3.0_2026_03_29**, gcc_syslibs(+devel), grep, icu74(+devel,+tools),
  less, libffi(+devel), m4, **make 4.4.1**, ncurses6(+devel), **python3.10 3.10.19**, sed, texinfo, zlib(+devel)
- 23 source package names.

That's 58 entries, 35 of them versioned binaries. `HaikuPortsCross/arm64` (the `BootstrapPackageRepository`, used only
by `--bootstrap` builds) lists another 34 `*_bootstrap` packages. Together that matches PLAN.md's "71 bootstrap packages",
give or take how you count. **`openssl3` is not in the arm64 definition** (0 matches).

### 1.2 How jam fetches them

- `RemoteRepositoryFetchPackage` downloads `$(baseUrl)/<checksum>/packages/<file>` (`haiku/build/jam/RepositoryRules:117-131`).
  The repository index comes from `$(baseUrl)/<checksum>/repo` (`:191-195`). Here `<checksum>` is the sha256 of the
  definition file itself (`:161-168`). Today that is `e18c479d…ba2f42` (`gen/objects/haiku/arm64/packaging/repositories/HaikuPorts-checksum`).
- `eu.hpkg.haiku-os.org/haikuports/master/build-packages/<sha>/…` returns 302 to `haiku-buildpackages.cdn.haiku-os.org/<sha>/repo`
  (200) and to `haiku-buildpackages.cdn.haiku-os.org/packages/<file>` (one flat directory for all architectures).
- The downloaded index (`gen/objects/haiku/arm64/packaging/repositories/HaikuPorts`, read with the host `package_repo list`)
  is named `HaikuPorts-BuildPackages`, architecture arm64, and has **57 packages** (35 binaries plus 22 `_source`).
- `gen/download/` holds what this image actually pulled: 14 hpkgs, 45 MB. They are bash, coreutils, freetype(+devel),
  gcc_syslibs(+devel), icu74(+devel), ncurses6(+devel), noto, zlib(+devel), zlib_source. `gen/build_packages/` holds the
  extracted copies of those used as *build features* (headers and libs for linking Haiku itself).
- `DownloadLocatedFile1` uses wget, and only for files missing from `download/` (`haiku/build/jam/FileRules:455-469`).
  With `--no-downloads` (`HAIKU_NO_DOWNLOADS=1`), every download is an error. In that mode the repository index is
  built locally from the files in `download/` with `package_repo create` (`RepositoryRules:177-189`).
- `gen/build/BuildConfig`: `HAIKU_IS_BOOTSTRAP ?= 0`, `HAIKU_PORTS`/`HAIKU_PORTS_CROSS` empty. This is a regular
  (non-bootstrap) build configured with `--build-cross-tools arm64 --cross-tools-source ../../buildtools`.

### 1.3 Are prebuilt arm64 *build packages* (gcc, binutils…) on Haiku's servers?

**Yes.** All 35 binaries are downloadable. Probed 2026-10-19 with ranged GETs, every one returned 206: gcc, binutils,
make, python3.10, haikuporter, curl, sed, texinfo, bash. Sizes: gcc 57 MB, python3.10 29 MB, binutils 9 MB,
make 0.5 MB, haikuporter 0.1 MB. Inspected with the host `package list -i`:

- packager `The Haiku build system <build-system@haiku-os.org>`; files dated 2026-04-21…23
- the `_bootstrap` in the *version* (not the name) is exactly what `haiku/3rdparty/pulkomandy/unbootstrap.sh` produces.
  These are **cross-built bootstrap packages renamed into regular ones** ("unbootstrapped"). The script's own header
  warns: "Expect binary incompatibilities when trying to use them." This matches PulkoMandy on the forum: the
  nightlies are "unbootstrapped" ([forum, 2026-05-02](https://discuss.haiku-os.org/t/my-haiku-arm64-progress/19044?page=2)).
- `gcc` requires only `haiku`. It provides `cmd:gcc/g++/cc/cpp/gcov…` and is built from buildtools 850b249.
  `python3.10` requires libexpat, libffi, libncurses and libz, all in the set. `haikuporter-0_bootstrap` is haikuporter
  commit ebf0598, `requires: cmd:python`. At that commit `pyproject.toml` says `requires-python = ">=3.10"`, so it
  should run on python3.10. **haikuporter HEAD needs ≥ 3.12** (`hp/pyproject.toml:10`), so HEAD will not run on the
  image until we build python3.12+.
- `curl_bootstrap` is configured `--without-ssl` (`hpx/net-misc/curl_bootstrap/*.recipe:69`). The packaged curl
  requires only haiku and libz, so it has no TLS.

### 1.4 What is *not* on the servers

- **No arm64 HaikuPorts repository.** `https://eu.hpkg.haiku-os.org/haikuports/master/` lists
  `["riscv64", "x86_64", "x86_gcc2"]`. `…/haikuports/master/arm64/current/repo` returns a JSON `[]`, not a repo file.
  The Haiku *system* repository does exist for arm64 nightlies: `…/haiku/master/arm64/current/repo` →
  `haiku-repository.cdn.haiku-os.org/master/arm64/r1~beta6_hrev60263/repo` (200).
- So the image's own pkgman config points at nothing. `haiku/build/jam/images/definitions/minimum:448-459` installs
  each repository's config and cache. The HaikuPorts config's baseurl comes from `haiku/src/data/repository_infos/haikuports`
  (`…/haikuports/master/%HAIKU_PACKAGING_ARCH%/current`). The cache installed is the 57-package *build-packages* index.
- **No TLS on our image.** The `minimum-*` profile adds `openssl3` (`haiku/build/jam/DefaultBuildProfiles:187-189`),
  but it isn't in the arm64 definition. `AddHaikuImagePackages` prints "package … not available!" and continues
  (`haiku/build/jam/ImageRules:1126-1140`), and `BuildFeatures:18-22` leaves `HAIKU_BUILD_FEATURE_SSL` off. The network
  kit is then built without OpenSSL. The WebPositive-arm64 project hit the same problem: "Check whether this image's
  network kit has TLS at all — most do not"
  ([rainygirl/renkuos-rwebpositive-arm64 README](https://github.com/rainygirl/renkuos-rwebpositive-arm64)).
  **Consequence: until openssl3 is packaged and the image rebuilt with it, pkgman can only use an `http://` repository.**
- For comparison, the riscv64 HaikuPorts repo has 2,073 packages, packaged by `Builder mmlr_riscv64` (1,334) and
  `Builder kallisti5_riscv64` (676). It has *no* gcc, mesa, ffmpeg, libsdl2 or haikuwebkit. The x86_64 repo has
  9,992 packages, including gcc, mesa(+_devel), ffmpeg6, libsdl2, haikuwebkit, llvm17…21, qt5/qt6, quakespasm and
  dhewm3 (counted from both `repo` indexes downloaded 2026-10-19). Whether the riscv64 builders run on QEMU or on
  hardware: **[unverified]**.

---

## 2. Haiku's documented bootstrap procedure

Sources: `haiku/ReadMe.Compiling.md:233-275` and `haiku/docs/develop/packages/Bootstrapping.rst`.

### 2.1 Prerequisites

- The usual Haiku host prerequisites, plus **autoconf, automake, cmake** (for python_bootstrap) and **ncurses
  development headers** (for texinfo_bootstrap). Bash as `/bin/sh`-ish shell; mksh fails. The only host listed as
  "known to mostly work" is x86_64 Debian 12.
- Five sibling checkouts: haiku, buildtools, **haikuporter** (github.com/haikuports/haikuporter), **haikuports.cross**
  (github.com/haikuports/haikuports.cross) and **haikuports** (github.com/haikuports/haikuports).

### 2.2 Steps

1. Out-of-tree configure (in-tree is unsupported):
   ```
   mkdir generated.bootstrap && cd generated.bootstrap
   ../configure -j14 --build-cross-tools arm64 --cross-tools-source ../../buildtools \
     --bootstrap ../../haikuporter/haikuporter ../../haikuports.cross ../../haikuports
   ```
   `--bootstrap` also forces `HAIKU_NO_DOWNLOADS=1` (`haiku/configure:717-723`).
2. `jam -q -sHAIKU_PORTER_CONCURRENT_JOBS=N @bootstrap-raw`. **Not `jam -j`**: parallel haikuporter instances corrupt
   each other's package-info generation. `@bootstrap-mmc` also exists (`DefaultBuildProfiles:61`); any profile named
   `bootstrap-*` works.
   The build goes like this:
   - Jam makes `haiku_cross_devel_sysroot_stage1_arm64.hpkg`.
   - haikuporter cross-builds the stage-0/1 `*_bootstrap` recipes from haikuports.cross on Linux.
   - Jam makes the full cross-devel sysroot.
   - Jam builds "rigged" (pre-patched) source packages, from regular haikuports, for everything the
     `HAIKU_BOOTSTRAP_SOURCES_PROFILE` (default `@minimum-raw`) needs.
   - The image includes gcc, binutils, make, python3.10, haikuporter and the rest of `DefaultBuildProfiles:214-277`
     (20 GB image size). It also gets `/boot/home/haikuports/input-source-packages`, a `haikuports.config`, and
     `bootstrap_daemon.py`, a TCP:4242 remote shell for driving the build (`haiku/build/jam/images/definitions/bootstrap`).
3. Boot the image, set `PACKAGER` in `/boot/home/haikuports/haikuports.config`, then run
   `cd haikuports && haikuporter --do-bootstrap`. That builds the *real* versions of the bootstrap set natively from the
   rigged sources.
4. The resulting `packages/` plus the source packages from
   `objects/haiku/<arch>/packaging/repositories/HaikuPorts-sources-build/packages` make the first HaikuPorts repository.
   A regular Haiku is built against it, and further ports are built with haikuporter on that system.
5. For an arch whose userland doesn't run yet, `unbootstrap.sh` turns the bootstrap packages into regular-named ones.
   That's what the current arm64 build-packages are (§1.3).

### 2.3 Known arm64 status (2024–2026)

- haikuports.cross has a GitHub Actions workflow (`hpx/.github/workflows/bootstrap.yaml`). On ubuntu-latest it runs
  configure `--bootstrap` and `jam -q @bootstrap-raw` for `arm, arm64, riscv64, x86_64`. `gh run list` shows **no
  workflow runs**, so its pass/fail status is unknown.
- 2025-04: "Fix ARM and ARM64 bootstrap on modern Debian sid"
  ([haikuports.cross#39](https://github.com/haikuports/haikuports.cross/pull/39)).
- 2026-04: smrobtzz, "everywhere: update everything"
  ([haikuports.cross#41](https://github.com/haikuports/haikuports.cross/pull/41), merged 2026-04-23). The April report
  says smrobtzz and waddlesplash "cleaned up the bootstrapping procedure", then "upgraded the base ARM64 package set",
  and that ARM64 builds using the default binary packages now work out of the box on many QEMU setups
  ([Activity report, April 2026](https://www.haiku-os.org/blog/waddlesplash/2026-05-11-haiku_activity_contract_report_april_2026/)).
  That matches the 2026-04-21…23 dates inside our build-packages.
- 2026-08: przemub "did work to improve ARM64 bootstrapping, including porting some tools to Python 3 and adding
  missing packages to the bootstrap set"
  ([Activity report, August 2026](https://www.haiku-os.org/blog/waddlesplash/2026-09-10-haiku_activity_contract_report_august_2026/)).
- Forum, May 2026 ([My Haiku arm64 Progress, p.2](https://discuss.haiku-os.org/t/my-haiku-arm64-progress/19044?page=2)):
  - "There are no git, gcc or any development packages in the current nightly images" (KENZ).
  - "right now there is no haikuports builder", and a buildbot "will likely be set up later", possibly not for beta6
    (PulkoMandy).
  - pkgman "can't install any package"; PulkoMandy suspects the image was built without OpenSSL, the same issue as §1.4.
  - Native building would be easier on real ARM hardware than under slow CPU emulation (PulkoMandy).
- R1/beta6 (2026-08-26) is x86 only.
- Official guide: [Compiling Haiku for Arm64](https://www.haiku-os.org/guides/building/compiling-arm64), which calls
  the port early.
- HaikuPorts issue tracker: no open arm64-specific bootstrap issues found. The only hit is the 2021 #6138 "Add ?arm64
  to ports required for minimum-raw".
- Recipe coverage in `ports/` (3,957 recipes): about 3,270 declare `all` or `arm64`. Key ones:
  - gcc-13.3.0 `all !x86_gcc2 !riscv64`; gcc-15.3.0 `?all` (untested)
  - python3.14 and 3.15 `all`; git 2.56, cmake3 3.31, ninja, binutils 2.46, perl, patch, openssh: `all`
  - libsdl2 2.32.10 `all`; ffmpeg6 and ffmpeg8 `all`; quakespasm `all`
  - haikuwebkit-1.10.0 `all !x86_gcc2`; llvm22/23 `all`
  - mesa-25.3.6 `?all`; libglvnd-1.7.0 `?all`

  `all` means *declared*, not *built for arm64*. Nobody has built most of these on arm64.

---

## 3. Alternative and faster paths

### 3.1 Cross-build on Linux and package with the host `package` tool (no haikuporter) — fastest, already half there

The host tools are already built: `gen/objects/linux/x86_64/release/tools/package/package` and `…/package_repo/package_repo`
(run with `LD_LIBRARY_PATH=gen/objects/linux/lib`). We already cross-build libdrm, libglvnd and Mesa into
`artifacts/gl-stack/` (`scripts/build-gl-stack.sh`, sysroot from `scripts/haiku-sysroot.sh`). To turn a staged tree into
a real hpkg, write a `.PackageInfo` (name, version, architecture arm64, provides, requires) and run `package create`.
Such hpkgs are consumable by both jam (`AddHaikuImageSystemPackages`) and pkgman. This is how the third-party
WebPositive-arm64 packages were made: cross-compiled with a CMake toolchain file, no haikuporter, 11 packages / 94 MB,
served as a pkgman repo ([rainygirl/renkuos-rwebpositive-arm64](https://github.com/rainygirl/renkuos-rwebpositive-arm64)).

- Pros: no emulation, full host speed (16 threads, 29 GB), no dependency on the Pi's stability.
- Cons: every package is hand-written (provides/requires by hand); no HaikuPorts patches or recipes are reused
  automatically. That's fine for ~10 packages but not for hundreds. GUI apps packaged this way also miss
  haikuporter's `mimeset` step (app signature attributes), which doesn't matter for libraries.

### 3.2 Can haikuporter cross-build *ordinary* ports from Linux? No, not as shipped

- haikuporter treats a tree as cross-buildable only if it contains a `.cross` marker file (`hp/HaikuPorter/Configuration.py:494`).
- For a normal tree on a non-Haiku host, `_initGlobalShellVariables` exits with "Native building not supported on
  this platform" (`hp/HaikuPorter/Main.py:745-757`). Only lint/list/source-package commands work.
- In cross mode, `BuildPlatformUnix` builds against `haiku_cross_devel_sysroot` with a fixed set of implicit host
  provides (`hp/HaikuPorter/BuildPlatform.py:211-334`). Recipes have to be written for cross-building (the
  `*_bootstrap` style: `$buildMachineTriple`/`$targetMachineTriple`, no running of target binaries).
- Dropping a `.cross` file into a haikuports copy and cross-building ordinary recipes: **[guess] mostly fails.**
  Ordinary recipes use `BUILD_PREREQUIRES` like `cmd:gcc`, run configure scripts that execute test programs, and
  depend on activated packages. Untested.
- What *is* supported: writing extra `*_bootstrap` recipes for a few key tools (openssl3, wget, git, patch, xz, lzip)
  in a haikuports.cross fork. Jam (`--bootstrap`) or haikuporter in cross mode can build them.

### 3.3 Unofficial arm64 packages

Only one found: rainygirl's WebPositive/HaikuWebKit 1.10.0 + icu74, openssl3, sqlite3, dav1d and libavif1.0, plus a
Rust toolchain ([rainygirl/haiku-rust](https://github.com/rainygirl/haiku-rust)). Both now say "Haiku OS is no longer
supported", having moved to the RenkuOS fork. They target r1~beta6 + patches, and their ABI against master is
"unverified". They're useful as a reference (patches, CMake toolchain), not as a dependency.

### 3.4 Native builds in QEMU `virt`

- We already boot Haiku arm64 in QEMU virt with EDK2 (`scripts/qemu-virt.sh`: `-M virt -cpu cortex-a72 -smp 4 -m 2G`,
  `--smp N` exists). The upstream forum reports up to 8-core SMP working in QEMU.
- The host is an AMD Ryzen 7 PRO 250 (8C/16T), 29 GB RAM, x86_64. There's no KVM for aarch64 guests, so this is
  TCG (multi-threaded).
- **[guess]** TCG aarch64-on-x86 runs about 5–15× slower than native per vCPU. Twelve vCPUs on this host might be
  roughly as fast as the Pi 4's four A72s, maybe up to ~2× faster. Measure it: build one mid-size port (e.g. make or
  zlib) on both.
- Memory: `-m 8G` or more is possible on the host. **[unverified]** whether Haiku arm64 is happy with large RAM on virt.
- Networking: QEMU user-net works for HTTP fetches.
- Advantages over the Pi: no SD wear, snapshot/rollback of the disk image, no shared-bench lock, unattended overnight runs.
- **[guess]** Faster option: an arm64 cloud host (Ampere/Graviton) running QEMU with KVM would give near-native speed
  with 16–64 cores. Whether Haiku arm64 boots under KVM (rather than TCG) is unknown. Worth one experiment before any
  WebKit or LLVM build.

### 3.5 Native builds on the Pi

- 4× A72, 4 GB (rev c03111).
- Storage: the USB stick does 75–78 MB/s. It's a better build disk than the SD card.
- Blocker for now: the week log records a ~1-in-6 boot freeze and stalled timers (`docs/log/WEEK-2026-W42.md`).
  Multi-hour builds need a stable kernel under sustained SMP load and I/O.
- 4 GB RAM is tight for an LLVM or WebKit link at `-j4`. The haikuwebkit recipe already uses
  `--param ggc-min-expand=10` to save memory.
- Recommendation: treat the Pi as a *test* target and a later *second builder*, not the first build host.

---

## 4. Staged plan

### Stage 0 — Our own repository, served over HTTP (days) [host only]

Goal: an arm64 HaikuPorts-format repository we control, plus an image that knows about it.

1. Repository layout (what haikuporter's `--create-package-repository` produces, `hp/HaikuPorter/PackageRepository.py:225-290`):
   ```
   <base>/repo.info          (name, vendor, summary, priority, baseurl, identifier, architecture arm64)
   <base>/repo               (package_repo create repo.info packages/*.hpkg)
   <base>/repo.sha256        (sha256 hex of repo)
   <base>/repo.minisig       (optional; only if a minisign key is given, else "Warning: unsigned package repository")
   <base>/packages/*.hpkg
   ```
   pkgman fetches `<baseurl>/repo.sha256` (`haiku/src/kits/package/RefreshRepositoryRequest.cpp:67`). Nothing in
   `src/kits`/`src/servers`/`pkgman` reads `.minisig`, so signing is optional for us. Generate a minisign key anyway
   and keep it out of git, in case Haiku ever starts checking.
2. Hosting:
   - Bench and QEMU: a static HTTP server on the host (`10.42.0.1` for the Pi LAN, `10.0.2.2` from QEMU user-net).
   - Public: GitHub Pages or a release bucket under the `haiku-pi` org. **Plain `http://` until the image has TLS**
     (§1.4). GitHub Pages is HTTPS-only, so the Pi needs openssl3 first.
3. The image consumes it in two ways:
   - **pkgman at runtime**: on `rpi4`, change `haiku/src/data/repository_infos/haikuports`'s baseurl to our repo, or add a
     second repository_info so the build installs both configs (`images/definitions/minimum:448-459`). By hand:
     `pkgman add-repo http://10.42.0.1:<port>/arm64`.
   - **In the jam build**: the rule names are `AddHaikuImageSystemPackages` / `AddHaikuImageDisabledPackages`
     (`haiku/build/jam/ImageRules:1126-1181`). There is no `AddHaikuPortsPackagesToHaikuImage`. Put calls in
     `haiku/build/jam/UserBuildConfig` (absent today; see `UserBuildConfig.sample`). A package must also be *listed*
     in `repositories/HaikuPorts/arm64` to be resolvable. That leaves two options:
     - (a) host our packages under `<ourURL>/<sha256 of the arm64 definition file>/{repo,packages/}`. The sha changes on
       every edit of that file, so a small `scripts/` publisher must recompute it.
     - (b) **simpler for us**: pre-stage every hpkg the definition names into `gen/download/`. Jam never re-downloads
       an existing file (`FileRules:471-491` + `NoUpdate`). The `repo` index is still fetched, though, unless
       `--no-downloads` (then built locally, `RepositoryRules:177-189`). Use `--no-downloads` with a fully pre-staged
       `download/`, keeping the upstream build-packages there too. `gen/` was configured *without* it (see the `#a`
       line in `gen/build/BuildConfig`). Re-run configure with the stored arguments plus `--no-downloads`; don't
       hand-edit `BuildConfig`.
   - Build features only switch on when the `_devel` package is listed: `mesa_devel` (`BuildFeatures:185`) enables
     GLTeapot/GLInfo; `ffmpeg6_devel` (`:202`) enables the ffmpeg media plugin that MediaPlayer needs;
     `haikuwebkit_devel` (`:303`) enables WebPositive (`OptionalPackages:151-160`).
4. First contents, made with §3.1 (host cross-build + `package create`):
   - `libdrm`, `libglvnd`, `mesa` (our v3d + softpipe; no LLVM) — replacing `--add-tree` non-packaged staging
   - **`openssl3`** (+`_devel`), then rebuild the image so the network kit has TLS
   - `ca_root_certificates` is already in the set (any)
5. Exit: the Pi image boots, `pkgman refresh && pkgman install mesa` works from our repo, and GLInfo/GLTeapot build
   from `mesa_devel`.

### Stage 1 — A native toolchain on the image; haikuporter runs (1–2 weeks) [guess]

1. Add the existing build-packages to the image with `UserBuildConfig`: gcc, binutils, make, python3.10, haikuporter,
   m4, bison, flex, sed, grep, gawk, findutils, texinfo, less, curl, plus the `_devel` packages (gcc_syslibs, zlib,
   ncurses6, libffi, expat, freetype, icu74). Also add `haiku_devel`. Note that `DevelopmentMin` puts it in the
   *disabled* `_packages_` directory (`OptionalPackages:121-129`). haikuporter needs devel packages *active*
   (`DefaultBuildProfiles:243-249`), so add it with `AddPackageFilesToHaikuImage system packages : haiku_devel.hpkg`.
   All of these are already listed in the arm64 definition, so no repository work is needed. Grow the image size
   (the bootstrap profile uses 20 GB).
2. Smoke test on QEMU virt first, then the Pi: `gcc hello.c`, a C++ hello world, `make`, `python3 -c …`. This answers the
   "binary incompatibility" warning in `unbootstrap.sh` for our hrev60262 base.
3. Supply what haikuporter needs that the set lacks:
   - git, or patch: patching goes through `git am`, or `patch` without git (`hp/HaikuPorter/Source.py:282-320`)
   - wget (`SourceFetcher.py:209`)
   - xz and lzip (archive extraction)
   - dos2unix (some recipes)
   - openssh (only for a buildmaster)

   Order to get them:
   - Cross-build `patch` and `xz` on the host (§3.1, trivial autotools packages). Optionally do git, wget (with
     openssl3) and openssh the same way. Or add `*_bootstrap` recipes for them in a haikuports.cross fork.
   - **Pre-seed sources**: set `DOWNLOAD_IN_PORT_DIRECTORY=yes` (`Port.py:155-159`) and download each needed tarball
     on the host into `<port>/download/`. haikuporter skips the fetch when the file exists with the right checksum.
     The source mirror `https://haikuports-mirror.cdn.haiku-os.org/<port>/<file>` is HTTPS-only (http → 404), which
     confirms the no-TLS image cannot fetch on its own.
4. With the pinned haikuporter-0 (python ≥ 3.10) on a haikuports checkout:
   - build `patch`, `xz_utils`, `git`, `wget`, `openssl3`, `python3.14`, `cmake`, `ninja`, `meson`, `pkgconfig`, `perl`
     natively
   - then switch to haikuporter HEAD (needs python ≥ 3.12)
   - rebuild gcc/binutils/make/python natively to retire the cross-built bootstrap set
5. **Version-ordering trap [unverified, check first]**: `BPackageVersion::Compare` compares the micro part with
   `NaturalCompare` (`haiku/src/kits/package/PackageVersion.cpp:91-121`). By that reading:
   - `13.3.0_2026_03_29_bootstrap` sorts *above* a native `13.3.0_2026_03_29`.
   - The current HaikuPorts recipes give **lower** versions still: `gcc-13.3.0_2023_08_10` <
     `13.3.0_2026_03_29_bootstrap`, and `make-4.4.1` < `4.4.1_bootstrap`. A straight native rebuild of gcc or make
     would lose to the cross-built ones, so the solver keeps the bootstrap packages.
   - binutils 2.46.1 and python 3.14 do clear the bar.

   Options:
   - bump the date suffix in our fork's gcc recipe
   - use `gcc-15.3.0_2026_10_11` (`?all`, untested on arm64)
   - once native packages exist, drop the `_bootstrap` gcc and make from our repo and from the arm64 definition.
     A fresh image never sees them; pkgman will not downgrade an already-installed one.
6. Exit: on the image, `haikuporter -j8 make` and `haikuporter git` produce hpkgs, which are published to our repo.

### Stage 2 — Mesa as a proper port, SDL2, games (2–4 weeks) [guess]

- Mesa: fork the HaikuPorts `mesa-25.3.6` recipe into our overlay, pointing at our 26.2.0 `rpi4` branch:
  - Upstream builds `-Dgallium-drivers=llvmpipe -Dvulkan-drivers=swrast` and needs `devel:libLLVM` +
    `cmd:llvm_config`, `glslangValidator`, mako and pyyaml.
  - Ours: `v3d,softpipe`, no LLVM, no lavapipe. That keeps LLVM off the GPU critical path.
- libglvnd (`?all`), libdrm (no HaikuPorts recipe, so write one), libsdl2 (`all`; needs `devel:libgl`, `devel:libglu`,
  cmake, ninja), glu.
- Games: quakespasm (`all !x86_gcc2`, in x86_64), dhewm3. yquake2 and ioquake3 have no x86_64 package names found.
- Haiku image: list `mesa_devel` → GLTeapot/GLInfo built by jam.

### Stage 3 — Media (2–4 weeks) [guess]

- ffmpeg6 (what `BuildFeatures:202` wants) needs:
  - SDL2, openssl3, bz2, iconv, lame, ogg, opus, speex, theora, vorbis, zlib
  - on non-gcc2 builds also: libass, dav1d, fdk_aac, fontconfig, freetype, fribidi, gme, gmp, openjp2, openmpt,
    snappy, soxr, vpx, webp, xml2, lzma, ladspa
  - tools: yasm, texi2html, perl

  That's roughly 30–40 ports [guess], mostly plain autotools/cmake libraries.
- Then list `ffmpeg6_devel` in the arm64 definition: jam builds the ffmpeg media plugin and MediaPlayer plays real
  formats. libdvdread/libdvdnav/live555 are optional.

### Stage 4 — WebKit (4–8 weeks) [guess]

- haikuwebkit-1.10.0 needs:
  - icu74 ≥ 74, curl, sqlite3, openssl3, libpsl, libxml2/xslt, libwebp, libavif, woff2, lcms2, libjpeg, libpng16,
    libexecinfo, libgl
  - tools: **ruby, perl, gperf, cmake, ninja, `cmd:llvm_config >= 21`** (only for `llvm-ar`, per the recipe comment)

  `DISABLE_ASLR=1` is set in its build.
- LLVM is the single largest build in this plan. **Option [guess]**: patch the recipe to use `gcc-ar` and avoid
  building LLVM at all. Otherwise, build LLVM 21+ once, on the fastest builder available.
- Then list `haikuwebkit_devel` and add `AddOptionalHaikuImagePackages WebPositive`, so jam builds WebPositive from
  the Haiku tree.
- Reference: rainygirl cross-built HaikuWebKit 1.10.0 for arm64 (WebGL/WASM/FTL off). Their patches are worth reading.

### Scaling up: buildmaster

Once there are more than ~50 ports, use haikuporter's buildmaster (`hp/buildmaster/backend/README.md`, `hp/README.md`):

- A Linux container drives Haiku builders over SSH (paramiko). The container is `ghcr.io/haikuports/haikuporter/buildmaster`,
  run with `-e ARCH=arm64`. Configure builders with `createbuilder -n … -H …`, check them with `builderctl health`,
  then run `buildmaster everything`.
- Builders need sshd (`PermitRootLogin`), git, haikuporter and a haikuports checkout. The buildmaster `git fetch`es the
  tree on each builder (`RemoteBuilderSSH.py:190-216`). Builders download sources themselves and run
  `haikuporter --no-system-packages …` (`:341-348`).
- Builders also need xz_utils, lzip, patch and dos2unix.
- The buildmaster creates the repository, optionally signed with minisign (`buildmaster/backend/assets/bin/update_repo`).
- Builders can be several QEMU instances on the host and/or the Pi.

### Rough compute budget [all guesses — measure in Stage 1]

| Item | Native x86_64 reference | QEMU TCG on this host (12 vCPU) | Pi 4 (4 cores, 4 GB) |
|---|---|---|---|
| small autotools port (make, zlib, patch) | < 1 min | 5–15 min | 5–10 min |
| python3.14 | ~5 min | 1–2 h | 1–2 h |
| gcc 13 | ~30 min | 6–12 h | 6–12 h |
| Mesa (v3d+softpipe, no LLVM) | ~5 min | 1–2 h | 1–2 h |
| ffmpeg6 + ~35 deps | ~1 h | 10–20 h | 10–20 h |
| LLVM 21 | ~1–2 h | 1–2 days | 1–2 days, RAM-limited |
| HaikuWebKit | ~2–3 h | 2–4 days | likely infeasible at 4 GB without `-j1`/swap |

An arm64 KVM cloud host (if Haiku boots under KVM) would cut the QEMU column by about 5–10×.

### Risks

1. The cross-built ("unbootstrapped") gcc/python may misbehave natively (`unbootstrap.sh` warning). Mitigation: Stage 1
   smoke tests; fall back to a proper `@bootstrap-mmc` + `haikuporter --do-bootstrap` (§2).
2. No TLS and no wget/git/patch on the image: sources must be pre-seeded until Stage 1 lands.
3. Package version ordering against `_bootstrap` packages (Stage 1 item 5).
4. Kernel stability under multi-hour SMP + I/O load: the Pi's open freeze, and unknown behaviour on QEMU at 8–12 vCPUs.
5. ABI drift: our packages are built against the `rpi4` hrev60262 base. Upstream rebases that change libroot ABI
   force rebuilds; the riscv64/x86_64 HaikuPorts trees assume upstream Haiku.
6. HaikuPorts recipes marked `all` were never built on arm64: expect per-port patches (aarch64 asm, config.sub,
   `-mcpu`). Keep them in a haikuports fork under `haiku-pi` and upstream nothing for now (AGENTS.md policy).
7. Sustained builds on the shared bench: Pi-based builds must hold `/home/houp/.pi-bench.lock` for hours. That's
   another reason to build in QEMU.

### Sources (web)

- Compiling Haiku for Arm64 — https://www.haiku-os.org/guides/building/compiling-arm64
- Activity report April 2026 — https://www.haiku-os.org/blog/waddlesplash/2026-05-11-haiku_activity_contract_report_april_2026/
- Activity report August 2026 — https://www.haiku-os.org/blog/waddlesplash/2026-09-10-haiku_activity_contract_report_august_2026/
- Forum "My Haiku arm64 Progress" p.2 — https://discuss.haiku-os.org/t/my-haiku-arm64-progress/19044?page=2
- haikuports.cross PRs #39, #41 — https://github.com/haikuports/haikuports.cross/pulls
- HaikuPorter (README, buildmaster) — https://github.com/haikuports/haikuporter
- Unofficial arm64 WebPositive — https://github.com/rainygirl/renkuos-rwebpositive-arm64 ; Rust — https://github.com/rainygirl/haiku-rust
- Repository endpoints probed 2026-10-19: `https://eu.hpkg.haiku-os.org/haikuports/master/` (arch list),
  `…/haikuports/master/build-packages/<sha>/…` → `haiku-buildpackages.cdn.haiku-os.org`,
  `…/haiku/master/arm64/current/repo`, `https://haikuports-mirror.cdn.haiku-os.org/<port>/<file>`
