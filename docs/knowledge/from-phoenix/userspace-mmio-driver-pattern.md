# Pi 4 userspace MMIO / mailbox device-driver pattern

**Status:** proven 4× on hardware — `rpi4-thermal` (mailbox), `rpi4-hwrng` (MMIO),
`rpi4-fb` (MMIO + platformctl), `rpi4-gpio` (MMIO). This is the canonical shape for
adding a small BCM2711 peripheral to the Pi 4 port as a userspace `/dev` server.
Reach for it before writing a kernel driver — the Pi 4 bring-up exposes nearly every
peripheral this way (caches are globally off, so uncached MMIO is coherent and simple).

## When it applies

- The peripheral is a memory-mapped register block (`mmap` the page uncached), or is
  owned by the VideoCore firmware and reached over the property mailbox.
- A handful of read/write/devctl operations is enough — no IRQ, no DMA, no shared
  framework. (IRQ-driven or DMA peripherals need more; see GENET / xHCI.)

## Skeleton (every driver is the same five steps)

```c
#include <sys/msg.h> <sys/mman.h> <sys/file.h> <sys/types.h> <posix/utils.h>

int main(void) {
    /* 1. Map the block uncached by physical address. */
    base = mmap(NULL, _PAGE_SIZE, PROT_READ | PROT_WRITE,
        MAP_DEVICE | MAP_UNCACHED | MAP_PHYSMEM | MAP_ANONYMOUS, -1, (off_t)BLOCK_PA);
    if (base == MAP_FAILED) return 1;

    /* 2. Acceptance canary: touch the hardware through the SAME helper read()
     *    uses, and refuse to register if it's dead. This line is the self-test
     *    scraped from the netboot UART log. */
    if (probe_failed(base)) { printf("drv: <reason> -- not registering\n"); return 1; }

    /* 3. portCreate + create_dev for each node. */
    portCreate(&port);
    dev.port = port; dev.id = 0;
    create_dev(&dev, "name");          /* targets the "devfs" port; strips /dev */

    /* 4. Print ONE acceptance line (the boot-log evidence). */
    printf("drv: <key state> ...; registered /dev/name\n");

    /* 5. Blocking message loop (never returns). */
    msg_loop(port);
}
```

Message loop dispatch (field names that actually work — verified against pl011-tty):

| op | fields |
|---|---|
| `mtOpen`/`mtClose` | reply `msg.o.err = EOK` |
| `mtRead` | offset `msg.i.io.offs`; write into `msg.o.data` (cap `msg.o.size`); return count via `msg.o.err`; return 0 for EOF past end |
| `mtWrite` | data `msg.i.data`, len `msg.i.size`, offset `msg.i.io.offs`; `-EROFS` for read-only devices |
| `mtGetAttr` | switch `msg.i.attr.type`: `atSize`→byte size, `atMode`→`S_IFCHR\|0666` (or `0444` read-only), into `msg.o.attr.val` |
| `mtDevCtl` | `ioctl_unpack(msg, &req, &id)` → input ptr; `ioctl_setResponse(msg, req, err, &out)` |
| default | `-ENOSYS` |

`atSize` (`<sys/file.h>` enum) matters: the file-backed `mmap` path queries it via
`proc_size`, and `cat` uses it. fb0 reports it; a pure snapshot device (gpio) can skip it.

## Registration (three edits, no build-system magic)

1. Driver dir `phoenix-rtos-devices/<category>/<name>/` with `rpi4-<name>.c` + a Makefile
   whose only content is `NAME := rpi4-<name>` / `LOCAL_SRCS := ...` / `include $(binary.mk)`.
   The top `Makefile` does `find -mindepth 2 -name Makefile`, so the dir is auto-discovered;
   the `NAME` is the component key.
2. `_targets/Makefile.aarch64a72-generic`: `DEFAULT_COMPONENTS += rpi4-<name>`.
3. `_projects/aarch64a72-generic-rpi4b/user.plo.yaml`: a launch line **after** the devfs
   bind at `/dev`. Guard `if: "{{ env.RPI4B_VARIANT | default('netboot') != 'sd' }}"`
   for non-essential devices to keep the `sd` exec-from-card path (#120) minimal.
   **Never list a program name twice** in a `*.plo.yaml` — alias collision bricks boot.

## Mailbox variant (firmware-owned peripherals)

For VideoCore-owned state (temperature, clocks, power, framebuffer geometry), copy the
property round-trip **verbatim** from `rpi4-thermal.c rpi4_mboxProp1in1out()`: map the
mailbox at `0xfe00b880` uncached + a `MAP_UNCACHED|MAP_CONTIGUOUS` property buffer,
`va2pa()` it, channel 8, spin-bounded wait. The same round-trip is currently duplicated
in 5 places (T1 in the upstream-readiness review) — **a shared mbox helper is the right
upstream factoring**; until then, any fix must be made everywhere.

Framebuffer geometry specifically comes from `platformctl(pctl_get, pctl_graphmode)`
(struct in `phoenix/arch/aarch64/generic/generic.h`, **not** `<sys/platform.h>`), which
works from any process; see `rpi4-fb.c`.

## Build + validate loop (autonomous-safe)

New component = core change → `rebuild-rpi4b-fast.sh --scope core --variant netboot`
(an `auto` rebuild ships a stale image). Verify the binary shipped:
`strings .../loader.disk | grep rpi4-<name>`. Then `test-cycle-netboot.sh` and confirm
the acceptance line + `0 faults` + boot reached psh via `uart-summary.sh` (use `grep -a`
on UART logs — they contain control bytes).

## What this pattern does NOT cover (deliberately)

- **Outputs that move physical state** (GPIO drive, display drawing): correct-by-
  construction is not validation — needs a bench rig / screen → attended. Ship read-only,
  defer the write path. (gpio `mtWrite`=`-EROFS`; fb0 reads-only at startup.)
- **Zero-copy `mmap(fd, 0)`**: there is no `mtMmap`; the device-fd mmap path demand-pages
  a private copy, not the peripheral. Clients map real MMIO via `MAP_PHYSMEM` at the PA
  (which the device can hand them through a devctl). A true file-backed FB mmap is kernel
  VM work, not a message handler.
- **devctl correctness**: the message-loop read/write paths get exercised by the startup
  canary + boot; a `GET*` devctl has no client at boot, so it stays correct-by-
  construction until a real client runs.

See also: `pi4-hardware-support-matrix.md` and the
`feedback_unattended_scoping` discipline (additive + self-log + cannot-silently-regress).
