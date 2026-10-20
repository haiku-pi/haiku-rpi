# Haiku on the Raspberry Pi 4 — working rules

This is the **coordination repository** for porting Haiku to the Raspberry Pi 4 (BCM2711, 4× Cortex-A72).
It holds scripts, tools, documentation and integration manifests. **No Haiku source code lives here.**

## Repositories

| Path | What | Remotes |
|---|---|---|
| `.` | coordination (this repo) | `origin` = github.com/haiku-pi/haiku-rpi |
| `sources/haiku` | Haiku, work branch **`rpi4`** | `origin` = github.com/haiku-pi/haiku (fork), `upstream` = review.haiku-os.org/haiku |
| `sources/buildtools` | Haiku cross tools | `origin` = haiku-pi/buildtools, `upstream` = review.haiku-os.org/buildtools |
| `sources/u-boot` | U-Boot (`rpi_4_defconfig`), the EFI layer under haiku_loader | source.denx.de (read-only) |

- We **pull** upstream into the fork (`scripts/upstream-sync.sh`); we do **not** send changes upstream for now.
- Push progress to the `haiku-pi` org often. Never force-push. Never rewrite `master` of a fork:
  it mirrors upstream; our work is on `rpi4`.
- Commits in `sources/haiku` are small and reviewable, written to Haiku's style
  (`docs/develop/` in the tree, tabs, `component: summary` subject lines). Code may be published;
  optimise for readability and upstreamability.

## The bench (shared!)

One Pi 4, driven over UART `/dev/ttyUSB0` (PL011 on GPIO14/15, 115200), power via a smart plug,
HDMI via a capture card (`/dev/video4`), and the Pi's private LAN `10.42.0.0/24` on the USB-C
adapter (`10.42.0.1`). **The bench is shared with another project on this host:**

- Every Pi power/UART cycle and every change to the Pi LAN's DHCP/TFTP server runs under
  `flock $PI_BENCH_LOCK` (local.conf) — `scripts/lib/bench.sh` `bench_lock` does it. One cycle at a time.
- That project's netboot server is the bench's default state; every cycle restores it on exit.
- Never run a DHCP server on any interface other than the Pi LAN adapter.
- Never commit secrets (WiFi PSKs, tokens). Never change the host soft-AP.

## Build / test loop

```
scripts/build.sh [target]                 # jam in sources/haiku/generated.arm64 (heavy-build guarded)
scripts/mkimage-pi4.sh                    # SD image: Pi firmware + U-Boot + haiku_loader.efi + Haiku BFS
scripts/qemu-virt.sh                      # arm64 QEMU virt + EDK2 reference boot
scripts/sd-cycle.sh --flash IMG --secs 180 --label x   # flash the Pi's card, boot it, capture UART+HDMI
```

- **Don't improvise alternate paths** — fix or extend the script. Encapsulate a repeated
  operation in a script before the third time you type it.
- Size captures to the stage you need, and set the Bash tool timeout above the capture
  (`--secs` + flash time + 120 s).
- Read results with `scripts/uart-grep.sh` / the log itself; grade by **positive** markers.
- **A package revision bump has three parts:** the `.hpkg` in `artifacts/packages/` (only the newest
  revision: `publish-repo.sh` refuses two), the same file copied into `sources/haiku/generated.arm64/download/`
  (jam builds the image's repository from there), and the version in `build/jam/repositories/HaikuPorts/arm64`.
  Miss the copy and the image build only warns `AddHaikuImagePackages: package X not available!` and ships
  without the package — grep the build log for it after every bump.

## Method (lessons carried over from an earlier Pi 4 OS port, see docs/knowledge/)

- Read `docs/knowledge/from-phoenix/rpi4-os-development-guide.md` before touching early boot,
  caches/DMA, the mailbox, PCIe/VL805, GENET or V3D. Those notes cost months to learn.
- Regression first: when something that worked breaks, find the first bad artifact and diff, before debugging.
- Answer runtime questions with QEMU + gdb before adding source probes. Remove diagnostics whose
  hypothesis was disproved.
- Measure with two tools; verify the measurement, not just the result.
- After each validated step, `scripts/snapshot-state.sh` writes `manifests/<date>-<step>.md` with
  every repo SHA; that is the rollback point.

## Planning

- `docs/PLAN.md` — milestones H0…H12 and their exit criteria.
- `docs/log/WEEK-<ISO week>.md` — the current weekly log: plan, progress, blockers, decisions
  needed from the owner. Single source of truth for "what now".
- `docs/knowledge/` — reference; `docs/knowledge/from-phoenix/` is imported reference material.
- `<phoenix-rpi>` in the design notes: a checkout of the Phoenix-RTOS Raspberry Pi 4 port (the earlier
  port on the same board), cited as reference.
- Machine-specific settings (UART, power switch, capture device, peer project, data paths) live in the
  git-ignored `local.conf` (`local.conf.example`); nothing in git names a path on one machine.
