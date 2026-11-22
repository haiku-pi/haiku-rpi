# axibw — BCM2711 system AXI bandwidth monitor

`axibw` counts the memory-fabric transactions of chosen bus masters on the Pi 4 (HVS scan-out, the CPUs,
the network DMA, ...) over time windows. It is a root-only user program: the monitor's registers (physical
`0xfe009800`) are read and written through Haiku's `/dev/misc/mem`, one 4-byte access per register.

## Build

On the host (cross):

    g=sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc
    $g --sysroot=artifacts/sysroot-arm64 -O2 -Wall -Wextra -o axibw tools/haiku-tests/axibw/axibw.c

A host-only check of the parsing and the window arithmetic against a simulated register file:

    cc -O2 -Wall -Wextra -DAXIBW_SIMULATE -o axibw-sim tools/haiku-tests/axibw/axibw.c && ./axibw-sim selftest

## Use

    axibw [-i MS] [-d SECS] [-q] SEL [SEL [SEL]]   # up to 3 watchers; a line per watcher per MS-ms window
    axibw scan [-i MS] [-f ID] [FROM [TO]]         # every bus selector FROM..TO (0..63), three at a time
    axibw selftest                                 # idle vs memcpy on arm_uc/arm_l2/hvs

`SEL` is a bus selector (number or name) with an optional AXI ID filter: `hvs`, `10`, `system_l2/v3d0`.
Bus names (BCM2711): 0 dma_l2, 1 trans, 2 jpeg, 3 vpu_uc, 4 dma_uc, 5 system_l2, 6 hvs, 7 argon (rpivid),
8 h264, 9 peripheral (GENET), 10 arm_uc, 11 arm_l2. ID filter names: v3d0..v3d2 (25–27), hvs (10), arm (30),
gige (23), usb (24), argon (8), pcie (9), ... (the 32-entry list in the source).

Output: `AXB <t> <dt_ms> <sel> R <reads> W <writes> A <address>` per window (t = CLOCK_MONOTONIC seconds at
the window's end, the same clock as Python's `time.monotonic()` on Haiku), then
`AXB total <sel> <secs> s: R <n>/s W <n>/s A <n>/s`.

## Method

- **Counts are transactions, not bytes.** Bytes per transaction depends on the master; calibrate it with a
  workload of known size (`selftest` for the CPUs; `tools/gl-tests/glbw.c` for the GPU: render passes that
  store, or load and store, a known W×H buffer).
- **Hold time fixed and toggle the workload**: an idle window and a work window, each rate-normalised (divided
  by its own length), then the difference. The HVS reads the scan-out buffer continuously (~0.5 GB/s at
  1920×1080), so anything that grows with time also grows with a "bigger" workload; a size dose-response
  cannot separate them.
- Each window resets and re-arms the watchers (the counters are 31 bits wide; a window of ≤1 s cannot fill
  them at the fabric's bandwidth).
- The enable sequence is: reset the monitor, reset the watcher, configure it, enable the monitor **with the
  WATCH bit** (without it every counter reads 0).

## Pi 4 findings (docs/design/blender.md §7.17)

- V3D: bus 7 (`argon`, the vendor's name for the rpivid port, which V3D shares) with ID filter `v3d1`:
  `axibw argon/v3d1 hvs arm_uc`. With nothing rendering it reads 0.
- 16 bytes per transaction for the CPUs (`selftest`), the HVS (31.11 M reads/s = 1920×1080×4×60) and V3D (glbw,
  within 3 %).
- Selectors 37–42 read as 5–10 (32+n aliases n). Unnamed selectors are not understood: in a scan under GPU load
  23, 31, 45, 57 and 61 counted exactly 500 M writes/s (V3D's clock), but 23 alone later read V3D's traffic.
  Use the named buses.
