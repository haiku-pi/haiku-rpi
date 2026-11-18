# GL_MESA_map_buffer_client_pointer for WoW64 OpenGL (v3d)

Status (2026-11-18 10:14): **implemented on branches `clientptr`** (mesa haiku-pi, haiku origin), Pi-tested in a
network session: native test PASS, no GL/Vulkan regressions, **Warcraft III demo menu 13.6 → 22.9 fps (+67 %)**
under WoW64 — not from fewer copies but because the extension lets wined3d use persistent buffer mapping (§8).
Not merged; recommendation in §9. Owner (11-18): "try the GL_MESA_map_buffer_client_pointer path, assess how
complex it is and approach an implementation in Haiku". H20 C7 (perf-round-h20.md) had dropped the item (memcpy
3.1 % after Wine 0028); the assessment below (§1–6) was written before any code.

Citation keys: **[M]** `sources/mesa` (branch `rpi4` 2c620cecbf2 = 26.2.7 + our work; upstream `origin/main`
18879c94176 for the commits named), **[H]** `sources/haiku` (`rpi4` fbd46ca58b), **[W]**
`sources/wine/wine-wine-11.21` (read-only upstream source).

## 1. What the extension does

Wine's WoW64 thunks run 32-bit Windows code against a 64-bit host GL. A host `glMapBufferRange()` pointer can
be above 4 GiB, which the 32-bit side cannot address. Without help Wine maps a copy below 4 GiB and copies in and
out ([W] `dlls/opengl32/unix_wgl.c` `wow64_map_buffer`; our 0028 cut that to the flushed ranges). The extension
lets the *client* hand the driver address space, and the driver maps the buffer's storage straight there:

1. Buffers are created "client pointer": `glBufferData(usage + GL_CLIENT_POINTER_*_MESA)` or
   `glBufferStorage(flags | GL_MAP_CLIENT_POINTER_BIT_MESA)`. Wine does that for **every** buffer once the
   extension is there ([W] unix_wgl.c:1747, 1761, 1940, 1969). With it Wine also stops capping GL at 4.3 and
   stops hiding ARB_buffer_storage on WoW64 (:479).
2. `glMapBufferRange(..., access | GL_MAP_CLIENT_POINTER_BIT_MESA)`: if the driver already has the buffer's
   storage in client memory it returns the pointer. Otherwise it fails with `GL_OUT_OF_MEMORY` and sets
   `GL_BUFFER_CLIENT_POINTER_SIZE_MESA` to the size it needs ([W] :1537-1602 `map_buffer_client_pointer`).
3. Wine then allocates that size below 4 GiB (`NtAllocateVirtualMemory(zero_bits, MEM_COMMIT, PAGE_READWRITE)`),
   passes it with `glAddClientPointerRangeMESA(ptr, size)` and maps again; the driver consumes the range (maps
   the storage there) and returns a pointer inside it.
4. After every map and unmap Wine loops `glReleaseClientPointerRangeMESA(0, &size)` and frees whatever comes
   back (`NtFreeVirtualMemory(MEM_RELEASE)`); at context delete and thread detach it does so with
   `GL_CLIENT_POINTER_RELEASE_ALL_MESA` (:512-547, :2001). A range the driver returns must be plain memory again
   — the driver no longer uses it.

So the driver must: report the exact size of a buffer's backing, map that backing at an exact client address
(replacing the memory Wine committed there), keep it there across map/unmap, and, when the backing dies or a
release-all asks, put normal memory back at that address and give the range back.

## 2. Upstream Mesa (what we take)

| Commit | Content | Take? |
|---|---|---|
| 990bc5d6493 | GL headers (`glext.h` enums, entry points) | yes (cherry-pick -x) |
| f4c2f1083a1 | glapi XML, dispatch, `bufferobj.c` stubs | yes |
| c0bcffb1b0a | core: `bufferobj.c` map protocol, `ClientPointerHeap` in shared state, `AddClientPointerRange` in the context; gallium interface: `pipe_screen::clientptr_heap_create/destroy`, `clientptr_range_reclaim`; `pipe_context::transfer_map_clientptr_range/transfer_unmap_clientptr_range`; `PIPE_MAP_CLIENT_POINTER` (the map returns `PIPE_TRANSFER_CLIENT_POINTER` = (void *)-1); `PIPE_RESOURCE_FLAG_MAP_CLIENT_POINTER`; `pipe_resource::clientptr_heap`; `caps->map_client_pointer` → extension | yes |
| 55bb2f51161, d8ea238ae0a | threaded_context + u_upload_mgr support, `PIPE_MAP_SHORT_LIVED` | **no**: v3d has no threaded context ([M] no `u_threaded` in `src/gallium/drivers/v3d`) |
| d6325988849 | zink driver side (725 lines: per-heap slabs, staging forced for non-client maps, VK_EXT_map_memory_placed) | model only |
| 05bb93970e0 | CI expectations | no |

The cherry-picks shift bit numbers (`PIPE_MAP_DRV_PRV` 14→15, `PIPE_RESOURCE_FLAG_DRV_PRIV` 12→13,
`MESA_MAP_*` up one); no v3d or Haiku code uses them by value. 26.2.7 has flags 9–11 as the commit assumes.

### What of zink does *not* carry over

zink forces a staging copy for every non-client map of a client-pointer buffer and suballocates from per-heap
slabs because Vulkan allows one mapping per `VkDeviceMemory`. Haiku allows any number of clones of a BO's area,
and v3d gives every buffer its own BO. So on v3d the client mapping simply **becomes the BO's CPU mapping**
(`bo->map`): internal maps (glBufferSubData, vbo) use the same pointer, no staging, no slabs.

## 3. Haiku primitives

### 3.1 How Mesa maps a BO today

Haiku cannot mmap() a device. `DRM_IOCTL_V3D_MMAP_BO` ([H] `v3d/bo.cpp`:180 `mmap_bo`) calls
`vm_clone_area(team, ..., B_ANY_ADDRESS, B_READ_AREA | B_WRITE_AREA, REGION_NO_PRIVATE_MAP, bo->area, true)`,
sets write-combining on the clone, flushes the BO's lines, and returns the clone's address in `offset`; Mesa keeps
it as `bo->map` for the BO's life and munmap()s it at `v3d_bo_free()` ([M] `v3d_bufmgr.c`:512, 199).

### 3.2 What Wine's range is on Haiku

Wine reserves its address space with `mmap(PROT_NONE, MAP_NORESERVE)` ([W] `ntdll/unix/virtual.c` `reserve_area`);
`NtAllocateVirtualMemory(MEM_COMMIT)` inside a reserved region is `anon_mmap_fixed()` = `mmap(MAP_PRIVATE |
MAP_ANON | MAP_FIXED)` (:273, :1813); `MEM_RELEASE` is `unmap_area()`: `mmap(MAP_FIXED, PROT_NONE,
MAP_NORESERVE)` back over it, or munmap where Wine has no reservation (:1395). On Haiku each such mmap() is an
anonymous area (or cuts one: libroot's mmap passes `unmapAddressRange = true` for MAP_FIXED, [H]
`libroot/posix/sys/mman.cpp`:150, and `vm_unmap_address_range()` cuts or deletes whatever was there, [H]
`vm.cpp`:1096). Wine never touches a committed range it handed to GL until GL gives it back.

### 3.3 Placing a BO into the range (the map side)

Needed: replace `[addr, addr + size)` of the calling team with a clone of the BO's area, **atomically** (no
moment where the range is a hole another thread's mmap() could take — Wine's other threads map with MAP_FIXED
only inside ranges it believes free, but any library mmap(NULL) or a Box64 32-bit allocation could land in a
hole below 4 GiB).

- `vm_clone_area()` has no unmap option: B_EXACT_ADDRESS fails on an occupied range. Doing munmap() first in
  Mesa and cloning after is the race above.
- The VM has the mechanism: `vm_map_cache()` with `CREATE_AREA_UNMAP_ADDRESS_RANGE` unmaps the range under the
  address space's write lock before inserting the new area ([H] `vm.cpp`:1305); `_vm_map_file()` and
  `vm_create_anonymous_area()` use it. `vm_clone_area()` just never passes it.

**Decision**: a small VM change — `vm_clone_area_etc()` with a `flags` argument (`vm_clone_area()` calls it
with 0) that, for `B_EXACT_ADDRESS | CREATE_AREA_UNMAP_ADDRESS_RANGE`, checks under the target address space's
write lock that no area in the range is a kernel area (`B_KERNEL_AREA`, as user munmap() would refuse — the clone
itself runs with `kernel = true` because its source is a kernel area, so this must not widen what a client may
unmap) and that no page in it is wired (`B_BUSY`, no waiting: a committed Wine range is never wired), then passes
the flag to `vm_map_cache()`. The v3d driver gets a placed variant of MMAP_BO: `flags =
DRM_V3D_HAIKU_MMAP_BO_PLACED` with the address in `offset` (page-aligned, user, the whole BO); the old path is
unchanged (`flags == 0`). Detection: `DRM_V3D_PARAM_HAIKU_MMAP_BO_PLACED` (a Haiku-only number far from
Linux's); an older kernel answers B_BAD_VALUE and Mesa leaves the extension off.

Consequence: this touches the kernel proper, not only the driver add-on, so the test image needs a kernel built
from the branch — a full build of a worktree (its own `generated.arm64`, configured with the main tree's cross
tools, `download/` hard-linked; precedent: stage7, relr; ~40–70 min, ~12 GB), not the "driver add-on into a base
image" shortcut.

### 3.4 Giving a range back (the unmap side)

zink unmaps with `VK_MEMORY_UNMAP_RESERVE_BIT_EXT` (leaves PROT_NONE) and mprotect()s it RW. On Haiku Mesa can do
it in one step with no kernel change: `mmap(addr, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS |
MAP_FIXED)` atomically replaces the BO's clone (an area of the client team, not a kernel area, so the
`vm_unmap_address_range()` check passes; deleting the clone is what munmap() of `bo->map` does today) with fresh
anonymous memory, which is exactly what Wine committed there. Then the range goes on the heap's free list.

## 4. The v3d driver side (Mesa)

- **Cap**: `caps->map_client_pointer` when the kernel answers the new param (and not under the simulator).
- **Heap**: `struct v3d_clientptr_heap { pipe_clientptr_heap b; mtx; list free_ranges; }`; created per GL
  share group by the frontend; a resource with `PIPE_RESOURCE_FLAG_MAP_CLIENT_POINTER` holds a reference
  (`pipe_resource::clientptr_heap`), and so does every BO placed in it (so a BO in the screen cache can outlive
  the context and still return its range).
- **BO**: `bo->clientptr_heap` (non-NULL while `bo->map` is a client range), `bo->clientptr_maps` (client maps
  open). Placing: if the BO already has a normal mapping (glBufferData with data maps it internally first), the
  placed clone is made first and the old clone munmap()ed after — `bo->map` changes under nobody, as all v3d
  maps are made and used on the context's thread.
- **`buffer_map` with `PIPE_MAP_CLIENT_POINTER`**: the usual `v3d_map_usage_prep()` (flush, or BO swap on
  DISCARD_WHOLE_RESOURCE) and the wait (unless UNSYNCHRONIZED) — but no map; return `PIPE_TRANSFER_CLIENT_POINTER`.
- **`transfer_map_clientptr_range(trans, range, &size)`**: BO placed → `bo->map + offset`. Not placed and no range,
  or a range of another size → `*size = bo->size` (the page-aligned size *including* v3d's +4 padding page —
  the frontend consumes the range only if its size is exactly this), NULL. Range of the right size → place, take it.
- **`transfer_unmap_clientptr_range`**: `clientptr_maps--` only. The placement stays for the BO's life: the clone
  + dcache flush of `mmap_bo` per map would cost more than 0028's copies.
- **Where every range comes back** (Wine gets its 32-bit address space back only through Release):
  1. *BO death*: `v3d_bo_last_unreference()` of a placed BO — via the resource's destruction (glBufferData
     re-specifying a buffer makes a new resource; glDeleteBuffers), or the `DISCARD_WHOLE_RESOURCE` swap in
     `v3d_map_usage_prep()` (the old BO dies when its last job does). The BO is unplaced (§3.4) and its range goes
     on the heap's free list **before** it enters the screen-wide BO cache, so a cached BO never sits in client
     memory and a cache hit can never hand a client range to a non-client resource or another heap.
  2. *Release-all*: `clientptr_range_reclaim(release_all)` also unplaces BOs of the heap that are placed but have no
     client map open (tracked on a per-heap list of placed BOs); their next internal map is a normal MMAP_BO.
  3. *Heap destroy with ranges left*: they stay mapped as plain memory (Wine still counts them as committed; a
     munmap() would punch a hole in Wine's view, which is what zink does — not copied), logged once.
- **Locking**: the heap's mutex guards its lists; BO placement state is changed on the GL thread; the free-list
  push from `v3d_bo_last_unreference()` may run with the BO-cache lock held — the heap mutex is a leaf lock.

## 5. Effort and risks

| Layer | Work | Estimate |
|---|---|---|
| Mesa core | 3 cherry-picks onto 26.2.7, conflicts in bufferobj.c/glapi probable but small | 1 h |
| Mesa v3d | cap, heap, placement, reclaim, BO-death hook, uapi defines | 3–4 h |
| Haiku VM | `vm_clone_area_etc()` + kernel-area/wired checks | 1 h |
| Haiku v3d | placed MMAP_BO flag + param | 0.5 h |
| Build | GL stack branch build; worktree full build + image | 0.5 h + 1–1.5 h (machine) |
| Tests | native test program; Pi: test, gltri/vktest/photocraft-gpu-it, Wine A/B | 2 h + 2–3 h bench |
| **Total** | | **~10–12 h** (≈ the "L" of perf-round-h20 C7) |

Risks:
- **Address-space churn in Wine**: every first map of a buffer costs one NtAllocateVirtualMemory + one placed
  map ioctl, every buffer death one mmap + one NtFreeVirtualMemory. wined3d (no ARB_buffer_storage on v3d) maps
  whole buffers WRITE | FLUSH_EXPLICIT | UNSYNCHRONIZED without DISCARD ([W] `wined3d/context_gl.c`:2835,
  `resource.c`:394) and renames by its own allocation, so per-frame cost should be ~zero once buffers are placed;
  a game that orphans buffers (BufferData every frame) would pay syscalls per frame where 0028 paid a memcpy.
  Measured in §7, not assumed.
- **Many small areas**: each placed buffer is an area in Wine's low memory (Haiku areas cost a VMArea +
  translation-map pages); hundreds of buffers are fine, tens of thousands would not be.
- **Unplacing a BO while another thread's internal map uses `bo->map`**: only with a release-all from one
  thread while a shared context maps on another; noted, not handled beyond the per-heap lock.
- **Write-combining**: the placed clone must get WC like today's clone (same code path), else the GPU reads stale
  cache lines.
- Extension is new upstream (Mesa 26.3) and shipped only by zink; the frontend code is upstream's, unchanged.

## 6. Test plan

1. **Native arm64 test** (`tools/gl-tests/clientptr.c`): follows Wine's protocol exactly — map with the bit, expect
   OOM + `GL_BUFFER_CLIENT_POINTER_SIZE_MESA`, mmap() a range below 4 GiB (a PROT_NONE reservation + MAP_FIXED
   commit, as Wine), Add, map again (pointer inside the range), write a pattern, unmap, Release(0) loop; draw
   from the buffer and/or `glGetBufferSubData` to check the data reached the BO; map again (same pointer, no OOM);
   glBufferData re-spec loop asserting the old ranges come back by Release; release-all at the end; munmap each
   returned range; area count before/after (no leak).
2. **No regression**: gltri, vktest, photocraft-gpu-it (as 11-17: 97 + 12 of 109).
3. **Wine** (Wine 11.21 package, which already has upstream's client-pointer path; 0028 then dead): Warcraft III
   demo menu `WINEDEBUG=+fps` + `profile -k -S`, NFS Porsche menu, UT (OpenGL), with the extension on and off in
   the **same** Mesa build (`MESA_EXTENSION_OVERRIDE=-GL_MESA_map_buffer_client_pointer`), so only the path differs.
   Baseline: 12.1 fps WC3 menu (11-03), memcpy 3.1 %.

## 7. Implementation (branches `clientptr`)

| Repo | Commit | What |
|---|---|---|
| mesa (haiku-pi) | ce682c7dafe, 4b1b70b5c93, 5319e6b330f | upstream 990bc5d6493, f4c2f1083a1, c0bcffb1b0a with `-x`; one conflict: `static_data.py` (our 26.2.7 has `RenderbufferStorageMultisampleEXT` at the end of the list: both kept, ours first) |
| mesa | b691443f2cd `v3d: implement MESA_map_buffer_client_pointer on Haiku` | `v3d_clientptr.c` (new, ~250 lines): heap, reclaim, `transfer_map/unmap_clientptr_range`, BO release; `v3d_bufmgr.c`: `v3d_bo_map_placed()` / `v3d_bo_unmap_placed()`, the release hook before the BO cache; `v3d_resource.c`: heap reference, the `PIPE_MAP_CLIENT_POINTER` branch of `transfer_map`; `v3d_screen.c`: `has_placed_map` (param), the cap |
| haiku (origin) | 3b68c0cf0e `kernel/vm: add vm_clone_area_etc() that can replace a mapped range` | §3.3 |
| haiku | f26a68c317 `v3d: map a BO at an address the client chooses` | `DRM_V3D_HAIKU_MMAP_BO_PLACED`, `DRM_V3D_PARAM_HAIKU_MMAP_BO_PLACED` |
| haiku-rpi | this repository | `tools/gl-tests/clientptr.c` (the native test, §6.1), `tools/pi-tests/clientptr-ab.sh` (the Wine A/B) |

Builds: Mesa with `build-gl-stack.sh` into a copy of the sysroot (GL_SYSROOT/GL_BUILD/GL_STAGE in the job's scratch,
GL_MESA_SRC = the worktree), packaged as `mesa-26.2.7-90` (PACKAGES_OUT, never published; kept in `artifacts/clientptr/`); Haiku in its worktree's
own `generated.arm64` (configured with the main tree's cross tools, `download/` hard-linked), `scripts/build.sh
--generated … -sHAIKU_PI_GL=1 -sHAIKU_IMAGE_SIZE=4500 @pi-mmc`: a full build from scratch took **5 min** on this
host (12 GB; the output directory was deleted after the test: `mkdir generated.arm64 && cd generated.arm64 &&
../configure --cross-tools-prefix <rpi4 tree>/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-`, `cp -al`
the rpi4 tree's `download/`, then the build line), so the "driver add-on only" shortcut was not needed. No new warnings in the touched files.

## 8. Results (2026-11-18, network session `clientptr1` 09:37–10:13)

Image: the worktree build above (hrev60337+447, kernel + v3d driver of `clientptr`), Wine 11.21-2 packages (with
0028) and their Wayland/xkb dependencies added to `system/packages`, `mesa-26.2.7-90` (the branch) installed with
pkgman over the image's 26.2.7-1. Serial log `artifacts/uart/20261118-093725-session-clientptr1.log`: 0 PANIC;
syslog: no VM or v3d complaints. Profiles and screenshots: `artifacts/clientptr/` (not in git).

**Native test** (`clientptr`, §6.1): with the image's stock Mesa 26.2.7-1 the extension is absent (the test says
so and fails, as it should); with the branch's Mesa **PASS, 4 of 4 runs** (−n 200 and 3 × −n 400): the pointer
lies in the range given, below 4 GiB, the range shows the BO and not the client's 0xa5 fill, the GPU draws what was
written through it and glGetBufferSubData reads it, a second map returns the same pointer with no new range,
glBufferData's initial data is visible, offset maps and wined3d's WRITE | FLUSH_EXPLICIT | UNSYNCHRONIZED pattern
work, 50 re-specifications and 50 invalidating maps each give every range back (≤ 1 out while the buffer lives,
0 after delete), release-all takes only the unmapped buffer's range and the re-placed buffer keeps its contents,
every returned range is zeroed plain memory, and no BO mapping is left in the reserved range. 105 ranges per run.
Map + 64 KiB write + flush + unmap: 21.0 µs plain, 22.3 µs with client pointers (native arm64 never copied; the
extra is the Release loop and the error checks the protocol needs).

**No regressions**: gltri PASS (ES 3.1 and GL 2.1 contexts), vktest PASS, photocraft-gpu-it **97 + 12 of 109**
(as 11-17).

**Wine** — the same Mesa build either way; *off* = `MESA_EXTENSION_OVERRIDE=-GL_MESA_map_buffer_client_pointer`
(checked by trace: 0 client-pointer ranges, 1096 0028 copies in 5 s of d3dtest), *on* = the extension (trace:
one range of 64 MiB + 4 KiB for the whole d3dtest run, no copies):

| Program (WoW64, Box64) | off (0028 copies) | on (client pointer) | |
|---|---|---|---|
| Warcraft III demo menu, mean fps 40–76 s (`clientptr-ab.sh`, `WINEDEBUG=+fps`) | 13.63, 13.73, 13.26 (profiled) | 22.91, 22.85, 21.30 (profiled) | **+67 %** (+61 % profiled) |
| Warcraft III, 300 s soak (on) | — | 21.8 → 23.9 → 23.4 fps at 60/180/300 s; BO mappings 86 → 87, no errors | stable |
| d3dtest-x86 (D3D9 dynamic VB, windowed 640×480) | 139.8, 138.7 fps | 139.8, 139.2 fps | none (present-bound) |

Same scene both ways (the menu, screenshots identical). 11-03's 12.1 fps (C0) agrees with *off*.

**Why +67 % when C0 measured memcpy at 3.1 %**: the copies were never the cost. With the extension, Wine stops
hiding `GL_ARB_buffer_storage` on WoW64 (`init_client_context`: "Disabling has_GL_ARB_buffer_storage extension on
wow64" appears only *off*; *on* the trace lists `++ GL_ARB_buffer_storage`), so wined3d switches to its
persistent, coherent allocator chunks: it maps each 64 MiB chunk once and writes into it for the rest of the run,
instead of a glMapBufferRange + glFlushMappedBufferRange + glUnmapBuffer round trip per buffer update — each a
call from Box64-translated x86 code through the WoW64 thunk and Wine's unix call into Mesa. The system profile shows
the shift, not a memcpy saving: CPUs ~48 % idle both ways (one latency-bound thread chain); non-idle ticks per
frame **~94 on vs ~155 off**; `wow64_glMapBufferRange` 531 ticks off, absent on; memcpy per frame the same
(~430–475 ticks/frame: app_server's and the GDI present's copies). So C7's gate was the wrong measure: the
expensive part was the number of GL calls per update, which only the persistent path removes.

**Upstream issue found** (not ours to fix in a fork-only tree, recorded): the extension's named usage enums are
dense (`GL_CLIENT_POINTER_STREAM_DRAW_MESA` 0x9791 … `_DYNAMIC_COPY_MESA` 0x9799) while Mesa and Wine both convert
by the offset from `GL_STREAM_DRAW` (0x88E0; the GL usages have gaps: 0x88E0-2, 0x88E4-6, 0x88E8-A). Wine's
round trip works for STREAM_*, STATIC_* and DYNAMIC_DRAW, but `GL_CLIENT_POINTER_STATIC_DRAW_MESA` passed by name is
rejected (`GL_INVALID_ENUM`: it maps to 0x88E3), and Wine's DYNAMIC_READ/DYNAMIC_COPY become 0x979A/0x979B, which
Mesa rejects as invalid usages (a WoW64 game using those usages would get GL errors). The native test uses Wine's
arithmetic.

Not tested: NFS Porsche (its data is not in this tree's cache), UT's OpenGL renderer (native GL without wined3d;
needs its ini + registry settings of the mega image), the mega-smoke set of 33 programs, the kernel's refusal paths
(unaligned address, a range holding a `B_KERNEL_AREA`, a wired range) — code-reviewed only.

## 9. Assessment

- **Effort**: ~2 h of work against the 10–12 h estimate: the frontend is upstream's unchanged, the v3d side is
  small because Haiku can map a BO many times (no zink-style staging), and a full worktree build takes 5 min.
- **Wine 0028** becomes dead code wherever the extension is present; it stays the path for a Mesa without it
  (softpipe via `LIBGL_ALWAYS_SOFTWARE=1`, or an older package), so keep it.
- **Recommendation: merge** both branches (kernel VM + v3d driver into haiku `rpi4`, Mesa into mesa `rpi4`, a
  mesa package revision) after a mega image of the branches passes `mega-smoke` (33 programs, several WoW64 GL
  games) — every WoW64 GL buffer becomes a client-pointer buffer, and only Warcraft III and d3dtest were run.
  Mesa 26.3 brings the three frontend commits anyway; then only our v3d commit remains to carry.
