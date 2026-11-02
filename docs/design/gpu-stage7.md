# GPU stage 7 — asynchronous per-unit V3D job queues

Status (2026-11-02): implemented and built on the host (haiku branch `stage7`: `b1e9782267` driver,
`ec706b6a3b` v3dtest), **not run on the Pi yet**. The new mode is behind a driver setting and **off by
default** (`queues serial`): nothing in it has met hardware, and the one new hardware risk (maintenance of one
unit while another runs, §4) can only be answered by the bench. Test image and plan: §7.

Part of KNOWN-ISSUES F2; [gpu-v3d.md](gpu-v3d.md) §2.5 (submission model) and §3 stage 7 (exit: a GL
benchmark ≥ stage 6 throughput, 0 wedges over a 30-minute soak, boot-bench unaffected).

Citation keys as in gpu-v3d.md: **[H]** `sources/haiku` (`rpi4` 46a18aecb4 unless noted, the driver in
`src/add-ons/kernel/drivers/graphics/v3d/`), **[M]** `sources/mesa` (branch `rpi4`), **[L]**
`<phoenix-rpi>/external/linux` `drivers/gpu/drm/v3d/` (rpi-6.18.y; facts only, GPL), **[PL]**
`<phoenix-rpi>/docs/gpu-new-lane/` (the Phoenix-RTOS async V3D server).

## 1. Today's model (rpi4, stages 1–5)

- **One queue, one job on the GPU** ([H] `jobs.cpp`:9-24): SUBMIT_CL/TFU/CSD/CPU append to one FIFO
  and return; a worker thread kicks the head, the interrupt handler records FLDONE/FRDONE/TFUC/CSDDONE/
  OUTOMEM, the worker completes the job and kicks the next. A control list runs bin then render back to back;
  nothing overlaps on the GPU. Completion is asynchronous to the client (the CPU∥GPU overlap is already there).
- **Fences are sequence numbers**: `completed_seqno` is set to the finished job's number; since jobs finish
  in order, `seqno <= completed_seqno` means done. Syncobjs, sync files (merge = max), `WAIT_BO`
  (`bo->last_seqno`), the BO quarantine (`release_after = submitted_seqno`) and CPU-job query availability
  all compare against it.
- **In-syncs are ignored**: every job a new job could depend on was submitted earlier and so has completed
  when the new job starts ([H] `jobs.cpp`:19-24) — true only because everything is serialised.
- Watchdog on the one active job (500 ms without progress of CTnCA/CTnRA, TFU count or CSD batches; 10 s
  hard limit), reset = GMP stop, power reset, core registers, TLB flush, drop the job.
- The proven maintenance sequence per job (gpu-v3d.md §1.3): `dsb`, `SLCACTL` invalidate, MMU flush + TLB
  clear, waited L2T flush twice ("fix-A"), the waited bin→render hand-off flush + `SLCACTL`, an unwaited L2T
  clean after render, TMUWCF + waited clean for `FLUSH_CACHE` and after CSD.

## 2. Target model

### 2.1 Queues

| Queue | Unit / kick | Done bit | Watchdog progress | Notes |
|---|---|---|---|---|
| BIN (`V3D_BIN` = 0) | CT0: `CT0QMA/QMS/QTS`, `CT0QBA`, `CT0QEA` kicks | core FLDONE (bit 1) | `CT0CA`, `CT0RA` | `PTB_BPOS = 0` before the kick; OUTOMEM (bit 2) served from the staged chunk |
| RENDER (1) | CT1: `CT1QBA`, `CT1QEA` kicks | core FRDONE (bit 0) | `CT1CA`, `CT1RA` | starts only after its own bin stage |
| TFU (2) | hub `TFU_*`, `ICFG` kicks | hub TFUC (bit 1) | TFU `CS` (conversion count) | |
| CSD (3) | `CSD_QUEUED_CFG1..6`, `CFG0` kicks | core CSDDONE (bit 7) | `CSD_CURRENT_CFG4` (batches left) | epilogue TMUWCF + clean |
| CPU (internal 4; uAPI `V3D_CPU` = 5) | the worker, synchronously | — | — | timestamp/reset/copy queries, indirect-dispatch set-up |

One job per queue on the GPU at a time (Linux `credit_limit = 1`, [L] `v3d_sched.c`:858). The numbering
follows the uAPI's `enum v3d_queue`, which the multisync extension's `wait_stage` uses. Each queue is one
FIFO in submission order **across all clients** (Linux has one scheduler entity per file and queue): a
control list sits on BIN for its bin stage and on RENDER from submission to completion, so render lists keep
submission order — Mesa relies on it ("the RCL will implicitly depend on the last RCL", [M]
`src/gallium/drivers/v3d/v3d_job.c`:666-670). The price: client B's render list waits behind client A's
render list even when they are unrelated. Accepted (a per-file round robin is a later refinement; there is one
GL client most of the time).

Job state machine (`v3d_job.stage`):

```
control list:  QUEUED --kick CT0--> BIN --FLDONE--> BINNED --(RENDER head, deps)--> RENDER --FRDONE--> done
  render-only: QUEUED --(RENDER head, deps)--> RENDER --FRDONE--> done
TFU / CSD:     QUEUED --kick--> TFU|CSD --TFUC|CSDDONE--> done        (an empty indirect CSD: done at once)
CPU:           QUEUED --(head, all earlier jobs done)--> run on the worker --> done
reset:         guilty job --> done (dropped);  other running jobs --> back to QUEUED/BINNED, once
```

**Modes** (driver setting, §6): `serial` — at most one hardware job, the oldest ready queue head first;
that reproduces today's order exactly (bin N, render N, then N+1; a CPU job when the GPU is idle).
`concurrent` — the head of every idle queue starts as soon as it is ready.

### 2.2 Dependencies and fences

A job may start once `completed_seqno` reaches its wait number. **`completed_seqno` becomes a watermark**:
the newest job up to which *every* job has completed (`update_completed()`: one less than the oldest job
still on any queue; each queue's head is its oldest). So a fence — still a sequence number — never signals
early; with concurrent queues it may signal *later* than its own job completed (when an older job on another
unit is still running). Syncobjs, sync files, `WAIT_BO`, the quarantine and the CPU jobs keep their code and
their meaning; only the definition of `completed_seqno` changed.

What a job waits for (resolved at submission, before the out-syncs change — Mesa passes the same syncobj as
in- and out-sync):

| Source | Linux ([L] `v3d_submit.c`) | Here |
|---|---|---|
| `in_sync_bcl` | bin job (:978) | bin stage |
| `in_sync_rcl` | render job (:962) | render stage |
| TFU/CSD `in_sync` | the job (:1128, :312) | the job |
| multisync in-syncs | only the job whose queue == `wait_stage`; ignored otherwise (:198) | `wait_stage == V3D_BIN` → bin stage; anything else → the (render) job. Applying a mismatched stage instead of ignoring it is stricter, never wrong |
| implicit BO fences | `drm_sched_job_add_implicit_dependencies(..., true)` on the **last** job of a submission (render or clean job; TFU; CSD; CPU) (:36, :1009) | the job's (render) stage waits for `bo->last_seqno` of each of its BOs; not the bin stage |
| bin → render | render depends on bin's done fence (:1039) | stage `BINNED` required |
| jobs of one submission | CPU → indirect CSD → clean (:1376-1390) | each waits for the previous |
| CPU job | its in-syncs | everything submitted before it (as today) |
| unknown handle / no fence | ignored (ENOENT filtered) | no dependency |

**What Mesa relies on** (checked in [M]):
- gallium `v3d`: every CL gets `in_sync_rcl = out_sync` and `out_sync = out_sync` (`v3d_job.c`:666-674);
  `in_sync_bcl` only for an imported native fence (:655-662), a perfmon switch (:684-691), vertex texturing
  or indirect draws and after compute writes (`v3dx_draw.c`:1180-1198); TFU and CSD chain `in_sync =
  out_sync` (`v3dx_tfu.c`:103-104, `v3dx_draw.c`:1572-1573). So one context's jobs are chained except the
  bin stage — exactly what lets bin(N+1) overlap render(N). Bin-to-bin hazards cannot occur (one BIN FIFO).
- `v3dv`: multisync on every submit, `wait_stage = V3D_BIN` when `needs_bcl_sync` (barriers that reach
  the binner, or a wait whose stage mask includes vertex stages), else `V3D_RENDER`; TFU `V3D_TFU`, CPU jobs
  `V3D_CPU` (`src/broadcom/vulkan/v3dv_queue.c`:790-837, :877, :243-690). It needs Linux semantics, which
  this gives.
- `WAIT_BO` before CPU access waits for every job that listed the BO (`last_seqno`, conservative).
- Haiku's present path (egl_haiku: GPU blit into the imported BBitmap, `WAIT_BO`, `SYNC_BO`): unchanged.

**Deadlock freedom**: dependencies only point at older jobs (fences are assigned at submission). The oldest
job not completed therefore has all its dependencies met, is the head of each queue it is on (each queue is in
submission order), and that queue's unit can only be busy with it — so it can always run. Precision: exact for
one client (its jobs are chained anyway), conservative across clients (a TFU of client A after a long render
of client B signals late). Per-queue fence contexts (a vector of per-queue sequence numbers) would remove
that; not needed for the measured workloads.

### 2.3 Interrupts

The handler is unchanged: it reads and acknowledges both status words (one line, SPI 74), clears the raw
core status **including the QPU bits 27:16** (the render-wedge fix, kept), W1Cs `MMU_CTL` faults and hands
the binner its pre-staged overflow chunk on OUTOMEM. The worker now demultiplexes **every** bit of a batch to
its unit's running job (formerly `else if`, one job): FLDONE → BIN, FRDONE → RENDER, TFUC → TFU, CSDDONE
→ CSD, in one pass. Stale-bit draining at a kick (`drain_stale`) clears only the bit of the unit about to be
kicked, whose previous job is done — never another unit's completion (Phoenix's note: clearing FRDONE when
kicking a bin would lose render(N−1)'s completion, [PL] `M1-async-render-server.md`:281).

**OUTOMEM / overflow pool**: a chunk belongs to bin(N) until render(N) completes (as before and as Linux).
With overlap, bin(N+1) may find the 32 MiB pool empty while render(N) or a BINNED job still holds chunks. New
rule: then the binner **waits** (`oom_deferred`; its watchdog counts the wait as progress — the render job
has its own watchdog) and gets a chunk as soon as a render completes; only if no other job holds chunks is it
a reset (as before). In serial mode no other job can hold chunks, so the old behaviour is unchanged.

### 2.4 Cache maintenance between concurrent units

Only the worker thread writes the maintenance registers (`L2TCACTL`, `SLCACTL`, `MMUC_CONTROL`,
`MMU_CTL`), under the device lock, so **no two maintenance operations are ever issued at once** — the
condition Linux needs `cache_clean_lock` for ([L] `v3d_gem.c`:177-233) and GFXH-1897 ("never start an L2T
flush while one is pending") holds because every flush first waits for the previous one. The sequence of each
kick is the proven one, unchanged (fix-A's second waited L2T flush included). What is new is that one unit's
prologue now runs **while another unit works**:

| Operation | While another unit runs | Verdict |
|---|---|---|
| `SLCACTL = 0x0f0f0f0f` (vertex, TMU L1, uniform, instruction caches) | its QPUs refetch | safe: read-only caches; Linux invalidates them at every bin/render/CSD start ([L] `v3d_gem.c`:240-261, `v3d_sched.c`:238,292,382) |
| L2T flush (`L2TFLS`, mode 0 = clean + invalidate) | its TMU accesses stall until done; dirty lines are written back, not lost | safe: Linux issues it at every job start; the waits only cost time |
| MMU cache flush + TLB clear | its translations refetch PTEs | safe: Linux flushes on every PTE change while jobs run ([L] `v3d_mmu.c`); no running job uses a page whose PTE changed (a job holds its BOs; freed BOs are quarantined until every job submitted before the free completed) |
| bin→render hand-off flush + `SLCACTL` at a render kick | also serves as the render list's own invalidation | needed: another job may have written what render(N) reads after bin(N) started (Linux's comment, [L] `v3d_sched.c`:286-291) |
| post-render unwaited L2T clean; `FLUSH_CACHE`/CSD TMUWCF + waited clean | writes back other units' dirty lines too | harmless; the job is reported done only after its own data is written (as today) |

What must stay serialised: the register writes themselves (single worker), the L2T flush/clean ordering
(wait-old before every issue), and a job's start after its dependencies (§2.2). Phoenix flagged exactly this
— a prologue's flush or TLB clear during another unit's job — as "the one real new risk" of its async server
and brought it up serialised first ([PL] `M1-async-render-server.md`:298-304); its pipeline mode ran 0
wedges in the runs made, but never actually overlapped (§5). Hence the default stays `serial` until §7 runs.

### 2.5 Watchdog and reset with several jobs in flight

- **Per queue**: every running job has its own watchdog state (kick time, last progress, progress
  registers); `check_watchdog()` walks the four units each tick (125 ms) and acks latched QPU interrupt bits
  for every running render/CSD job (kept). A binner waiting for overflow memory is extended (§2.3).
- **Reset** (the proven sequence: mask, GMP stop, PM reset + power-on, core registers, clear interrupts,
  overflow staging returned, TLB flush) stops every unit. The job whose watchdog fired (or whose binner ran
  out of memory) is **dropped**: it completes, its fence signals, its frame is lost — resubmitting a job that
  wedged the GPU wedges it again. The **other running jobs start over** from the beginning (Linux resubmits
  them too, [L] `v3d_sched.c`:710-747): a bin stage gives back its overflow chunks and re-runs; a render
  stage re-reads its bin stage's tile lists (still in memory); TFU/CSD re-run. A job caught in a second reset
  is dropped (`restarts`), so a job that wedges only while overlapping cannot loop. BINNED jobs (between
  their stages) are untouched by a reset. Syslog: `job N starts over`; statistics: `jobs restarted`.
- A failed reset (clock does not come back) marks the GPU broken and completes everything, as before.
- Fixed on the way: after a reset from the overflow path, the worker now schedules the queued jobs (before,
  they waited for the next submission, as the worker slept with nothing active).

### 2.6 What stays as it was

Kick sequences, the IRQ handler, power-on, MMU set-up, BO creation/import/quarantine (only "is the GPU idle"
changed to "no unit busy" for the immediate TLB flush on free), sync files, syncobj ioctls, CPU job bodies,
the uAPI and GET_PARAM answers. Phoenix's other render-wedge lessons are all still in force: QPU-interrupt
ack (above), zeroed BOs, `SLCACTL` per job, fix-A, `MISCCFG`/`AXICFG` set-up. The "VA window" fix (Phoenix's
1 GiB page-table window, gpu-v3d.md §2.1 "Page table") does not apply: this driver maps the full 4 GiB.

## 3. Implementation (haiku `stage7`)

| Commit | What |
|---|---|
| `b1e9782267` v3d: a job queue per unit, optionally running concurrently | `v3d_private.h`: `kQueue*`, `device->queues[]` (head/tail/active), `hardware_busy`, `concurrent`, `oom_deferred`, per-job `queue_next[]`, `bin_wait_seqno`/`wait_seqno`, `restarts`, multisync in-syncs in `v3d_submit_ext`, busy/overlap statistics. `jobs.cpp`: queues, `update_completed()`, `schedule()` (both modes), per-unit completion, `serve_overflow()`, per-queue `check_watchdog()`, `reset_gpu()` with restart, `resolve_dependencies()`, `v3d_jobs_read_settings()`. `cpu_jobs.cpp`: the indirect-dispatch check. `bo.cpp`: `v3d_jobs_on_gpu()`. `v3d.cpp`: one call in `v3d_open()` |
| `ec706b6a3b` v3dtest: add burst, overlap and restart tests | §7 |

Built in a separate output directory (`sources/haiku-stage7/generated.arm64`, configured with the main tree's
13.3 cross tools, `download/` hard-linked; `scripts/build.sh --generated sources/haiku-stage7/generated.arm64
v3d v3dtest`): 0 warnings in the driver, `-Werror` confirmed in its compile line.

Statistics (kernel setting `v3d_stats true`, every 5 s): the existing lines (`GPU busy` is now the union of
the units' busy time, equal to the old figure in serial mode) plus
`v3d: stats: queues concurrent, two or more units busy N ms (P% of the busy time), K jobs restarted`.

## 4. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| A wedge caused by maintenance of one unit while another runs (L2T flush / TLB clear during a render) — Phoenix's "one real new risk" | GPU resets, dropped frames | default `serial`; the soak in §7 counts resets per mode; A/B knobs afterwards (Phoenix [PL] M1 §5: `--tlb-on-change`, `--no-handoff-wait`), never by default |
| Overflow pool contention (bin N+1 while render N holds chunks) | binner stalls | binner waits for returned chunks instead of a reset (§2.3); the pool stays 32 MiB; `serial` cannot hit it |
| Render wedges known from Phoenix (q3dm7 binner wedge, depth-heavy polys) appear more often with overlap | resets | same recovery; a job is restarted once at most; the restart path is new code → `v3dtest restart` |
| Restarting a CSD job that is not idempotent (atomics) | wrong compute result after an unrelated wedge | Linux does the same; only after a wedge of another job |
| Cross-client fences conservative (watermark) | some lost concurrency between two GL apps | acceptable; per-queue fences if a workload shows it |
| Global per-queue FIFO (not per client) | one client's unbinned job blocks another's render | acceptable for one GL client; per-file round robin later |
| Head-of-line: a CPU job waits for everything before it | Vulkan timestamp queries serialise as today | as today |
| Mode switch at `open()` | none: both directions safe at any time (serial only gates new kicks) | — |

## 5. Expected gain — honest numbers

- **Phoenix's +45 % (STK 8.34 → 12.12 fps) was CPU∥GPU, not unit overlap**: it came from making submission
  asynchronous; its `pipeline` mode measured `overlap=0` — bin∥render never happened ([PL] `PLAN.md`:44,
  `M1-async-render-server.md`:1374-1379; QuakeSpasm 38.2 serial vs 38.4 pipeline, :968-969). Haiku has had
  asynchronous submission since stage 1, so **that gain is already in today's numbers**.
- What stage 7 can add is the bin stage of one job hidden behind the render stage of the previous one, plus
  TFU uploads and compute beside rendering, plus two GPU clients at once. Our own statistics bound the first:
  bin ≈ **5–20 %** of a control list's GPU time (`artifacts/uart/20261021-091637-qperf-split.log`: bin 46–453 µs
  vs render 639–4937 µs per job; `20261025-090618-gpu-present-a.log`: 305–1479 vs 2153–14777 µs), and it only
  turns into frames when the GPU is the bottleneck (those logs: 80–99 % busy in the heavy phases, 11–35 % in
  others). A single GL app that waits for each frame (egl_haiku's present waits for the blit) overlaps only
  between the jobs *within* a frame (render-to-texture passes, the present blit's bin). Expect **0 to ~10 %**
  on GPU-bound single-app benchmarks, more with texture streaming (up to 188 TFU jobs / 5 s in the qperf log)
  or two GL clients, and nothing on CPU-bound ones.
- So the stage 7 exit criterion (≥ stage 6 throughput) is a no-regression gate; the overlap share in the
  statistics line is the evidence that concurrency happens at all.

## 6. The switch

Settings file `~/config/settings/kernel/drivers/v3d` (`/boot/home/config/settings/kernel/drivers/v3d`):

```
queues concurrent      # one job per unit at a time (stage 7)
queues serial          # one job on the GPU at a time (the default, also without the file)
```

Read at every `open()` of `/dev/dri/renderD128` (the boot loader's copy is dropped once /boot is mounted, so
edits are seen), logged once per change as `v3d: job queues: concurrent (one job per unit)` / `serial (one job
on the GPU)`. A GL application opens the device at start, so a test switches modes between runs without a
reboot. An unknown value logs an error and means serial.

## 7. Test plan (Pi; not run yet)

Image: `artifacts/images/gpu-queues.img` = release candidate `haiku-pi4-2026-11-03.img` (rpi4 46a18aecb4, the
branch's base) + the stage7 driver as a non-packaged add-on with the packaged one blocked, `v3dtest`,
glmark2 2023.01-2, QuakeSpasm + its SDL2, kernel settings + `v3d_stats true`, UserBootscript
`tools/pi-tests/gpu-queues.sh` ("GQ" lines). Rebuild:

```sh
scripts/build.sh --generated sources/haiku-stage7/generated.arm64 v3d v3dtest
scripts/gpu-queues-image.sh artifacts/images/haiku-pi4-2026-11-03.img artifacts/images/gpu-queues.img
```

QEMU (no V3D: the driver never attaches, image-level check only): `scripts/qemu-virt.sh --image
artifacts/images/gpu-queues.img --secs 200` reached the desktop (§9).

**Cycle A — everything, one network boot (~60 min of tests; the SD card is not touched):**

```sh
scripts/netboot-cycle.sh --image artifacts/images/gpu-queues.img --secs 4200 --label gq-all \
    --until 'GQ end' --retry-wedge
grep -a -E 'GQ |v3d: (stats|job queues|GPU reset|job [0-9]+ starts)' artifacts/uart/*-gq-all.log
```

Shorter cycles: `--add FILE:/boot/home/gpu-queues/phases` with a file holding e.g. `tests quake` (steps:
`tests glmark2 quake soak`) and `--add FILE:/boot/home/gpu-queues/soak-minutes`. From the SD card instead:
`scripts/sd-cycle.sh --flash artifacts/images/gpu-queues.img --secs 4200 --label gq-sd --until 'GQ end'`
(the card then holds this image: restore the owner's image afterwards).

What the steps do and the exit criteria:

| Step | Lines | Pass |
|---|---|---|
| 1 `v3dtest -d all burst overlap restart`, serial then concurrent | `GQ v3dtest <mode>: ...` | exit 0 both; serial: `overlap: ... did not run beside the hung render list: serial queues`; concurrent: `... ran after N us, beside the hung render list: concurrent queues`; `restart: GPU resets X -> X+2` both; concurrent also `v3d: job N starts over` once; `driver mode` = wanted |
| 2 glmark2-es2 800×600, S C S C | `GQ glmark2 <mode>: score ...` + per scene | concurrent mean ≥ serial mean − 2 % (reference: 329 in an 800×600 window on the 11-02 GCC 16 images, W45 log 11-02 21:20); 0 GPU resets; `two or more units busy` > 0 ms in concurrent windows, 0 in serial |
| 3 QuakeSpasm timedemo demo1 1280×720, S C S C | `GQ quakespasm <mode>: 969 frames ... fps` | concurrent ≥ serial − 2 %; 0 resets |
| 4 soak 30 min concurrent: QuakeSpasm demo loop + glmark2-es2 loop at once | `GQ soak i/30 min: quake running yes, glmark2 runs n; driver mode concurrent, 0 GPU resets, 0 jobs restarted` | **0 resets** over 30 min (the UART log's `v3d: GPU reset after` count is authoritative), Quake alive throughout, glmark2 runs increasing; `v3dtest clear after the soak: exit 0` |
| boot | — | `scripts/boot-bench.sh 3 artifacts/images/gpu-queues.img --label gq-boot` → 3/3 desktop (flashes the card; the driver does nothing before the first open and defaults to serial, so this is expected trivially) |

If all pass: make `concurrent` the default (one-line change in `v3d_jobs_read_settings()`, the `serial`
setting stays the fallback), then rerun step 4 on two more boots. If concurrent wedges and serial does not:
the A/B order is (1) TLB clear only when the page table changed (Phoenix `--tlb-on-change`), (2) keep the
TLB clear but skip the prologue for the render kick, (3) serialise TFU/CSD kicks against a running render —
each as a new setting, default off.

## 8. Merge with stage 6

The stage6 agent (branch `stage6`) may add an ioctl. This work stays in the job/queue/IRQ machinery; likely
textual conflicts, all small:

- `v3d_private.h`: struct `v3d_job`, `v3d_device` (the `// jobs` block), `v3d_submit_ext`, the jobs.cpp
  prototypes — a new ioctl's prototype next to them conflicts only by position.
- `v3d.cpp`: one added line in `v3d_open()` (`v3d_jobs_read_settings(device);`); a new ioctl touches the
  ioctl switch and the `data` union, not this.
- `bo.cpp`: the hunk in `bo_free()` (`v3d_jobs_on_gpu()`), if stage 6 changes BO freeing (scan-out buffers).
- Semantics to keep in mind: anything stage 6 adds that waits for a job (a fence-gated flip) should use
  `v3d_seqno_completed()` / `completed_seqno` — still correct, now a watermark; anything that checked
  `device->active` must use `v3d_jobs_on_gpu()`.

## 9. Results so far (host)

- Build: driver + v3dtest, `-Werror`, 0 warnings in the driver.
- QEMU virt boot of `gpu-queues.img` (`artifacts/qemu/20261102-220001-virt.log`, 200 s): desktop up, the
  UserBootscript ran (`GQ v3dtest serial: exit 1` — no `/dev/dri/renderD128` without a V3D node, as expected
  there; glmark2 then ran on softpipe, `-virt.png`). The driver's module fails to load on virt for want of the
  mailbox module, exactly as the packaged one does in earlier virt logs (94 lines each): image-level check only.
- Test image: `artifacts/images/gpu-queues.img` (sha256 `90dc56e9495bba81…`, base `haiku-pi4-2026-11-03.img`).
- Not run: everything in §7.

## 10. Open questions

1. Does the binner's output reach memory without an L2T flush (the `overlap` test polls a job's tile buffers
   from the CPU)? If not, the test prints "no verdict"/"serial" in concurrent mode — then grade concurrency by
   the statistics' overlap line instead.
2. Is a render-only replay or restart of a render list really idempotent on V3D 4.2 (Linux assumes so)?
   `v3dtest restart` exercises one case.
3. Is 32 MiB of overflow pool enough with two clients overlapping? Watch for `binner overflow pool ...
   exhausted` in the soak.
4. Per-file fairness and per-queue fences: only if a two-client workload shows the global FIFO or the watermark
   costing frames.
