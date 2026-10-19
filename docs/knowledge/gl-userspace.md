# GL userspace for Haiku on the Pi 4 (GPU stage 2)

The OpenGL stack is cross-built on the Linux host (no native meson/ninja/mako on arm64 Haiku yet, H14) against
a sysroot made from the jam build's packages, and copied into the image as a plain directory tree. Design:
`docs/design/gpu-v3d.md` §1.2, §2.1, stage 2.

## Pieces

| What | Where | Branch / state |
|---|---|---|
| Sysroot (headers + libs of `haiku`, `haiku_devel`, `gcc_syslibs(_devel)`, `zlib(_devel)` hpkgs) | `artifacts/sysroot-arm64/boot/system/` | `scripts/haiku-sysroot.sh` |
| Meson cross file | `tools/meson/haiku-arm64.cross` | paths relative to the checkout (`root = '@DIRNAME@' / '..' / '..'`) |
| libdrm 2.4.134 | `sources/libdrm` | `rpi4`: builds on Haiku; `drmIoctl` passes the size (4th `ioctl()` argument); no device enumeration |
| libglvnd master (1.7.0 + HaikuPorts' HGL patch, upstreamed) | `sources/libglvnd` | `rpi4`: builds against current Haiku headers / cross |
| Mesa 26.2.0 | `sources/mesa` | `rpi4`: v3d + softpipe; `egl_haiku` uses v3d on `/dev/dri/renderD128` |
| Tests | `tools/gl-tests/` | `gltri` (headless GLES FBO render + readback), `glview` (BGLView window, desktop GL) |

The three source repos are local clones (origin = freedesktop.org); nothing is pushed.

### Mesa changes (branch `rpi4`, on `mesa-26.2.0`)

- HaikuPorts `mesa-25.3.6.patchset` 1/2 (renderdoc on Haiku); 2/2 is already in 26.2.
- `meson.build`: on Haiku with the v3d driver, libdrm is used (`with_haiku_drm_render`) — no KMS, kmsro, DRI or
  GBM; `src/egl/meson.build` links `driver_v3d` + libdrm + xmlconfig into `libEGL_mesa`.
- `v3d_bufmgr.c` (Haiku): `MMAP_BO.offset` is the mapping's address (the driver clones the BO area into the
  team); `munmap()` on free removes it.
- `v3d_context.c` (Haiku): no sync-file export → wait for the context's out-sync before returning no fence
  (submission is asynchronous; a NULL fence counts as signalled).
- `egl_haiku`: `egl_haiku_hw.c` opens `/dev/dri/renderD128` and makes a v3d screen (driconf defaults built in);
  softpipe when the node is missing, the screen fails, or `LIBGL_ALWAYS_SOFTWARE=1`. Contexts get the requested
  API/version (ES contexts were desktop-GL compat contexts before); configs are renderable for every client API;
  pbuffers no longer call `BitmapHook::GetSize` on NULL. Hardware window present = copy the back buffer into a
  `BBitmap` on swap (design tier P1; two bitmaps alternate).
- `hgl`: `hgl_create_context()` takes API/version/flags; front-buffer flush is skipped on screens without
  `flush_frontbuffer`.
- `util/libsync.h` (and libdrm's): `<sys/ioccom.h>` on Haiku.

## Build

```
scripts/build.sh @minimum-mmc                 # Haiku (provides haiku_devel.hpkg + the image)
scripts/build-gl-stack.sh                     # sysroot if missing, libdrm, libglvnd, Mesa, tests, stage
scripts/build-gl-stack.sh --sysroot --reconfigure   # from scratch (~1.5 min on this host)
scripts/build-gl-stack.sh --only mesa          # one step: libdrm|libglvnd|mesa|gl-tests|stage
```

Output: `artifacts/gl-stack/non-packaged/` (stripped; libraries as files named by soname):

```
lib/libEGL.so.1 libGLESv2.so.2 libGL.so.1 libGLdispatch.so.0 libOpenGL.so.0 libGLESv1_CM.so.1 libdrm.so.2
add-ons/opengl/egl_vendor.d/libEGL_mesa.so.0 50_mesa.json   (libglvnd's EGL vendor search path)
add-ons/opengl/gl-stack-versions.txt                        (source versions)
bin/gltri bin/glview
```

## Image and test

```
scripts/mkimage-pi4.sh --add-tree artifacts/gl-stack/non-packaged --bootscript tools/pi-tests/gl-test.sh \
	--out artifacts/images/haiku-pi4-gl.img
```

`--add-tree` copies the tree into `/boot/system/non-packaged/` (on `PATH` / library path). The bootscript runs,
20 s after boot: `gltri -n 100` (GPU), `LIBGL_ALWAYS_SOFTWARE=1 gltri` (softpipe), `glview -s 10`,
`LIBGL_ALWAYS_SOFTWARE=1 glview -s 5`; output on the serial console. By hand: `gltri [-n frames] [-s size]`.

Grade by positive markers: `GLT renderer: V3D 4.2…`, `GLT version: OpenGL ES 3.1 Mesa 26.2.0…`,
four `GLT check … ok` + `GLT check coverage … ok`, `GLT PASS`, `GLT hw-exit 0`; `GLW … PASS`.

QEMU `virt` (no V3D → softpipe), 2026-10-18: `gltri` PASS (renderer softpipe, OpenGL ES 3.1, GL 3.3 compat),
`glview` PASS at ~100 fps, and its window shows the rotating triangle (QEMU screendump).

Not run anywhere yet (needs the GPU): `egl_haiku_hw.c` (driconf set-up, `v3d_drm_screen_create`), the v3d
MMAP_BO-address and fence-wait patches, and the hardware window present (`haiku_present_copy`).
First-run knobs: `V3D_DEBUG=sync` (every submit waits), `LIBGL_ALWAYS_SOFTWARE=1` (softpipe).

## Known gaps

- libdrm's `-errno` returns are positive on Haiku (negative errno values): callers testing the sign are wrong.
  Hit once (`drmGetDevices2`, fixed); the v3d path only compares `-errno` with `-ETIME`, which is consistent.
- The driver has no TFU/CSD yet but GET_PARAM says it does: TFU blits/mipmaps log "Failed to submit TFU job"
  and fall back; compute dispatches fail (GLES 3.1 is still advertised).
- No `mesa`/`libglvnd` hpkg yet, so GLInfo/GLTeapot stay out of the arm64 build (`BuildFeatures`).
- The driver ignores SUBMIT_CL's in-syncs: correct while it runs one file's jobs in submission order.
- Phoenix's NPOT-mipmap fix (TFU) is not carried: unreachable while TFU is missing.
