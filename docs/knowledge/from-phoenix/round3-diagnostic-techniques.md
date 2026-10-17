# Round 3: Concrete Diagnostic Techniques for Early-Boot Cache/MMU Debug

Status: research notes; not policy. Goal: replace "flip a bit, observe brick"
with **observability-first** debugging on the Phoenix-RTOS Pi 4 bring-up.

Scope is the BCM2711 cache-coherency class problem (TD-04) and the syspage
relocate failure that follows MMU/cache enable in `_init.S`. Techniques below
are ordered cheapest-first.

---

## 1. JTAG on Pi 4 — what UART can't tell you

UART markers tell us *what code reached*. JTAG tells us *what state the CPU is
in when it stops*. The difference matters when SCTLR.M flips and execution
either (a) silently advances on stale instructions, (b) faults into a vector
we haven't installed, or (c) loops on a bad TLB walk. A well-placed `b .` plus
JTAG halt gives us all of: PC, ESR_EL?, FAR_EL?, SPSR_EL?, every TTBR, SCTLR,
TCR, MAIR, and the live page-table walk — none of which we can print over
UART when the CPU is wedged.

### Hardware path (lowest-friction, no Lauterbach budget)

The SO3 RPi4 guide and danmc.net 2024 walkthrough are both reproducible with
$30–$60 of hardware:

- **Adapter**: Olimex ARM-USB-OCD-H or an FT232H breakout (Adafruit / UM232H).
  Both are tested working; J-Link Base/EDU also works but costs more.
- **Pins**: Pi 4 routes JTAG via Alt4 of GPIO22–27. **Critical for BCM2711**:
  the SoC has default pull-downs on all GPIO at reset, so config.txt must
  contain `gpio=22-27=np` *and* `enable_jtag_gpio=1`. Without the `np`
  override TDI/TDO float low and the scan chain looks dead.
- **No nRESET**: the Pi 4 header does not break out a system-reset line.
  Practical workaround is `init reset halt` after power-cycle, or using
  `reset_config none` and halting on the first BL31 entry.

### What to attach with

Build OpenOCD with `--enable-ftdi`, run with the rpi4-specific config (rpi4
target file based on rpi3.cfg with the second-stage core SMPID change). After
`openocd` is listening, `aarch64-phoenix-elf-gdb plo.elf` plus
`target remote :3333` gives full source-level debug.

### Concrete recipe for the cache-enable hang

```gdb
(gdb) target remote :3333
(gdb) monitor halt
(gdb) load                         # only if we're flashing via JTAG
(gdb) hbreak _init.S:<line of msr SCTLR_EL1, x0>
(gdb) c
... halts before the SCTLR write
(gdb) info registers sctlr_el1 tcr_el1 mair_el1 ttbr0_el1 ttbr1_el1
(gdb) monitor mmw 0x... 0x...      # poke a known marker
(gdb) si                           # step the SCTLR write
(gdb) info registers sctlr_el1     # confirm M, C, I bits
(gdb) si                           # step ISB
(gdb) si                           # step the next load — this is the one
                                   # that historically wedges
(gdb) info registers far_el1 esr_el1 elr_el1
```

The single-step *across* the SCTLR write is the moment we currently can't
observe via UART. JTAG turns it into a printable diff.

Sources:
- [Bare Metal Debugging on RPi4 with GDB & OpenOCD (danmc.net, 2024)](https://danmc.net/posts/2024/rpi4b-bare-metal-debugging/)
- [SO3 OS — Debugging SO3 with JTAG on RPi4](https://smartobject.gitlab.io/so3/so3_jtag_rpi4.html)
- [Setup OpenOCD with JTAG + UART on RPi4 (Mohd Noor Aman)](https://medium.com/@0xNoor/setup-openocd-with-jtag-uart-on-raspberry-pi-4-using-ft232h-da05ca01c693)

---

## 2. QEMU gdbstub — are we using it well?

AGENTS.md already prescribes "GDB-first". The gap is that we tend to use it
for *post-mortem* (attach, look, panic). The QEMU manual flags two
under-used capabilities:

- `qemu-system-aarch64 -s -S` halts before the first instruction. We can attach
  and step from `0x0` through every register write *before* `_init` even
  starts. This is the cheapest possible bisection of "where did our
  pre-MMU state diverge from expected".
- `info tlb` and `info mem` in the QEMU monitor (`-monitor stdio` alongside
  the gdbstub) print the active translation regime, which is the single
  fastest way to confirm "did SCTLR.M actually take effect, with the table
  I expected".

QEMU's default single-step masks IRQs (per the QEMU GDB doc) so stepping
across the cache flip won't be derailed by a timer. For Phoenix the relevant
recipe is:

```sh
# Term A
qemu-system-aarch64 -M raspi4b -kernel plo.elf -nographic \
    -serial mon:stdio -s -S
# Term B
aarch64-phoenix-elf-gdb plo.elf
(gdb) target remote :1234
(gdb) hb _init.S:<sctlr write>
(gdb) c
(gdb) display/i $pc
(gdb) si
(gdb) p/x $sctlr_el1
(gdb) maintenance packet qemu.PhyMemMode:1   # raw PA reads
(gdb) x/4xw 0x<syspage_pa>
```

The last two lines are the ones we should be exploiting more: with
`PhyMemMode:1` GDB reads bypass the guest MMU, so we can compare a PA read
against a VA read and *prove* whether the post-MMU view is stale.

QEMU's translation of Pi 4 cache attributes is imperfect, so this is a
hypothesis-narrowing tool, not a regression suite. But for "did I program
TCR/MAIR self-consistently" it is decisive.

Sources:
- [QEMU GDB usage](https://qemu-project.gitlab.io/qemu/system/gdb.html)
- [Debugging AArch64 using QEMU and GDB (krinkinmu)](https://krinkinmu.github.io/2020/12/26/position-independent-executable.html)
- [How to debug kernel using QEMU and aarch64 VM (Futurewei)](https://futurewei-cloud.github.io/ARM-Datacenter/qemu/aarch64-debug-kernel/)

---

## 3. ARMv8-A self-hosted debug — software step and watchpoints

Even without JTAG, ARMv8-A defines self-hosted debug exceptions that the
kernel can use to single-step itself. The two relevant pieces:

- **Software Step**: set `MDSCR_EL1.SS=1`, set `SPSR_ELx.SS=1`, `eret`. The PE
  raises a Software Step exception *immediately after* the next instruction
  retires. We can wire this into our existing exception vector and emit a
  one-line UART trace per step. Useful for "step the 6 instructions around
  the SCTLR write while keeping IRQs masked".
- **Watchpoints**: `DBGWVR<n>_EL1` + `DBGWCR<n>_EL1` arm a hardware watchpoint
  on a specific PA/VA. The PE raises a Watchpoint exception with `FAR_EL1` =
  the watched address. **Practical use for TD-04**: arm a watchpoint on the
  syspage struct *before* enabling the MMU. After enable, the first stale
  read trips the watchpoint and we capture `ELR_EL1` (= the PC of the load).
  That instantly localises the bad reader.

We cannot trigger a debug exception "on cache line fill" — there is no such
event in the ARMv8 self-hosted debug spec. The closest analogue is PMU event
counting (next section).

Sources:
- [Learn the architecture — AArch64 self-hosted debug v1.1 (Arm)](https://documentation-service.arm.com/static/63f75e6c7741343f18b6d44f)
- [Armv8-A Self-hosted debug v1.0 (Arm)](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/Learn%20the%20Architecture/V8A%20Self-hosted%20debug.pdf?revision=5eff4cc6-b4ca-4017-a07d-2957307058cb)
- [Arm Developer — Debug exceptions](https://developer.arm.com/documentation/102120/latest/Debug-exceptions)

---

## 4. PMU as cache diagnostic

The Cortex-A72 PMU has six programmable event counters plus a dedicated cycle
counter (PMCCNTR_EL0). For our cache-enable bring-up the high-value events
(TRM r0p3 §11.8) are:

| Event 0x## | Name | Meaning |
| --- | --- | --- |
| 0x01 | L1I_CACHE_REFILL | I-cache miss serviced |
| 0x03 | L1D_CACHE_REFILL | D-cache miss serviced |
| 0x04 | L1D_CACHE | D-cache access |
| 0x08 | INST_RETIRED | architecturally executed inst |
| 0x11 | CPU_CYCLES | (also PMCCNTR_EL0) |
| 0x16 | L2D_CACHE | L2 access |
| 0x17 | L2D_CACHE_REFILL | L2 miss / fill |
| 0x18 | L2D_CACHE_WB | L2 writeback |

Bring-up sequence (run-time, no JTAG needed):

```
1. PMCR_EL0   = E|P|C|D|X     enable, reset event regs, enable cycle counter
2. PMCNTENSET_EL0 = 0x8000003F      enable cycle + 6 event counters
3. PMSELR_EL0 = 0; PMXEVTYPER_EL0 = 0x08    counter 0 = INST_RETIRED
4. PMSELR_EL0 = 1; PMXEVTYPER_EL0 = 0x03    counter 1 = L1D refill
5. ... etc
6. read all counters at marker A
7. <code under test, e.g. SCTLR.M=1; ISB; load syspage>
8. read all counters at marker B; emit deltas over UART
```

The discriminating signal: if D-cache accesses (0x04) increment but L1D
refills (0x03) do *not*, the load was satisfied from L1 (good if we
populated it cleanly, bad if we expected it to come from DRAM). If the cycle
delta is huge but inst-retired delta is small, the CPU is stalling — likely
an external abort on a TLB walk.

Note: PMCR_EL0 access from EL1 is allowed, but EL0 access requires
`PMUSERENR_EL0.EN=1`. We're at EL1 so this is irrelevant for us.

Sources:
- [Cortex-A72 MPCore TRM r0p3 §11 (Stanford mirror PDF)](https://www.scs.stanford.edu/~zyedidia/docs/arm/cortex_a72.pdf)
- [Cortex-A72 PMU Event Count Retrieval (System on Chips)](https://www.systemonchips.com/arm-cortex-a72-pmu-event-count-retrieval-and-core-specific-performance-monitoring/)
- [Identifying L2 cache misses on A72 via PMU (System on Chips)](https://www.systemonchips.com/identifying-and-monitoring-l2-cache-misses-on-arm-cortex-a72-using-pmu-events/)

---

## 5. Deliberate-fault probing (FreeBSD pattern)

The FreeBSD arm64 boot path uses a "write a poison pattern, look for it
post-MMU" trick to distinguish *reading from cache* vs *reading from DRAM*.
For Phoenix-RTOS the recipe is:

1. Pre-MMU, with caches off, write `0xDEADBEEF` to the syspage at PA `P`.
2. Issue `dc cvac, P; dsb sy` to push the write to PoC.
3. Now overwrite `*P = 0xCAFEBABE` *via the cached path* (post-MMU enable).
4. Issue `ldr w0, [P_va]`. If we read `0xCAFEBABE` → caches participating
   correctly. If we read `0xDEADBEEF` → still reading PoC, caches not
   actually attached.
5. Without `dc cvac` between steps, we should see `0xDEADBEEF` from cache and
   `0xCAFEBABE` from DRAM via a `dc civac` + reload. The asymmetry tells us
   *which* of CPU-side or PoC-side is wrong.

This pattern was used in the FreeBSD ARM64 bring-up and is documented in the
"Stale data, or how we (mis-)manage modern caches" Linaro slide deck.

Sources:
- [Stale data, or how we (mis-)manage modern caches (Linaro / linuxfoundation.org)](http://events17.linuxfoundation.org/sites/events/files/slides/slides_17.pdf)
- [Debugging the FreeBSD Kernel (FreeBSD Foundation)](https://freebsdfoundation.org/wp-content/uploads/2019/01/Debugging-the-FreeBSD-Kernel.pdf)
- [FreeBSD forum thread — Debugging arm64 boot on Pi 4](https://forums.freebsd.org/threads/debugging-arm64-booting-of-freebsd-ghostbsd-kernel-for-raspberry-pi-4-what-tool-do-you-use-any-jtag-hardware-kernel-debug.90436/)

---

## 6. Bisection via UART timing

The Pi 4's CNTPCT_EL0 increments at a fixed rate (typically 54 MHz on
BCM2711, readable from CNTFRQ_EL0). Reading it costs one MRS — cheap enough
to sprinkle through `_init.S`:

```
mrs   x9, cntpct_el0          // marker A
... block under test ...
mrs   x10, cntpct_el0         // marker B
sub   x10, x10, x9
... format and emit "delta=%lu" over UART ...
```

What this catches:

- **Slowdown across MMU enable**: if cycles/instruction goes up by 5–10× from
  one marker to the next, the I-cache is not actually serving instructions —
  every fetch is going to DRAM.
- **Stall**: if marker B never prints but later markers do, the kernel
  recovered (reset, abort handler, whatever); if B never prints and nothing
  after it does, we wedged inside the block.
- **Speedup**: a sudden 25× speedup is the expected signature when caches
  *correctly* turn on (Circle docs cite ~25× from D-cache enable alone).

Note: CNTPCT_EL0 reads can return 0 until the timer is ungated — on Pi 4 the
Arm Generic Timer is started by the firmware before plo runs, so we should
be fine, but if a marker reads 0 that's itself a useful diagnostic.

Sources:
- [CNTPCT_EL0 register definition (Arm Developer)](https://developer.arm.com/documentation/ddi0601/latest/AArch64-Registers/CNTPCT-EL0--Counter-timer-Physical-Count-Register)
- [Circle README — caches give ~25× speedup](https://github.com/rsta2/circle)

---

## 7. Read-back probing of suspect memory

Concrete pattern when we suspect a specific PA is stale:

```
// post-MMU, suspect syspage at va = SYSPAGE_VA, pa = SYSPAGE_PA
dc    civac, SYSPAGE_VA       // clean+invalidate by VA-to-PoC
dsb   sy
isb
ldr   x0, [SYSPAGE_VA]
... print x0 ...
// now compare against a PA-side read via a temporary uncached mapping
```

The two reads must agree. If they differ, the cache held a different value
than DRAM — that's the stale-syspage signature directly.

To do the "temporary uncached mapping" without rewriting page tables, the
fastest path is to set up a second mapping for the syspage region at boot
with `MAIR` index pointing at `Device-nGnRnE`, and use that VA for the
control read. This is exactly the trick Zephyr / OP-TEE bring-ups use.

Sources:
- [OP-TEE issue 5403 — aarch64 MMU setup sequence](https://github.com/OP-TEE/optee_os/issues/5403)
- [Raspberry Pi forum — Updating/Changing MMU Page Tables](https://forums.raspberrypi.com/viewtopic.php?t=268543)
- [Zephyr issue 98351 — MMU mapping cache invalidation](https://github.com/zephyrproject-rtos/zephyr/issues/98351)

---

## 8. Symbol lookup from UART encoded register dumps

Phoenix-RTOS's "no-call exception dump" emits raw register values — PC, LR,
SP, ESR, FAR — over UART. The right toolchain workflow is:

```sh
# Given UART log "elr_el1 = 0x000000000020a4ec"
aarch64-phoenix-elf-addr2line -fipe /path/to/phoenix-kernel.elf 0x20a4ec
# -> hal_cacheFlushAll
#       at hal/aarch64/cache.S:142
```

`addr2line -e <elf> -f -i -p <hex>` gives function name, inline frame, file,
and line — all from the un-stripped ELF that the build emits to `_build/`.
The `-i` (inlines) flag matters because Phoenix's hot paths are heavily
inlined.

For a stack trace from a frame-pointer chain captured in the dump:

```sh
for fp in 0x... 0x... 0x...; do
  aarch64-phoenix-elf-addr2line -fipe phoenix-kernel.elf $fp
done
```

Where the dump only emits PC, this is enough. Where it emits an FP we can
walk back N frames manually using `nm --numeric-sort phoenix-kernel.elf`
to identify the surrounding function bracket.

Practical tip for the build: keep `-fno-omit-frame-pointer` on the kernel
build (it costs 1 register) until first-boot stabilises — the difference
between "PC = mystery" and "PC + 4 frames of unwind" is enormous when the
fault is several inlined layers deep. AGENTS.md's "remove diagnostic-only
code before closing a step" still applies: revert at TD close.

Sources:
- [addr2line documentation (Baeldung)](https://www.baeldung.com/linux/addr2line)
- [TizenRT — How to Debug a Crash with addr2line](https://github.com/Samsung/TizenRT/blob/master/docs/HowToDebugACrash.md)

---

## 9. How other projects debug arm64 early boot

**FreeBSD** uses an "early printf" path that pokes the PL011 directly before
the real console driver attaches; the same path is reused by DDB (the
in-kernel debugger) for very early panics. The recent fix `9fac39c63c12`
("arm64: fix the handling of DDB symbols in early boot") shows the team
actively maintaining symbol availability before pmap is up — exactly the
problem class we have. KGDB-over-serial is the production path; bhyve+kgdb
is the development path.

**NetBSD** prescribes a low-level `cn_putc` that writes the SoC UART register
directly, called from `printf -> kprintf -> KPRINTF_PUTCHAR -> putchar ->
v_putc -> cnputc`. The pattern: every level can be bypassed if the next one
isn't ready yet, so a panic during MMU bring-up still surfaces.

**seL4 elfloader** intentionally enters with caches off, expects U-Boot to
have flushed everything, and prints via a `plat_console_putchar` that the
platform overrides for very early debug. The Pi 3/4 docs explicitly call out
"U-Boot must disable caches before loading seL4" — which is the same hazard
we hit.

**Circle** (rsta2) hooks an `ExceptionHandler` very early and prints a stack
trace from the FP chain. Their `doc/debug.txt` documents `rpi_stub`
integration: an external GDB stub running at FIQ priority that takes over
exception vectors.

**rpi4-osdev / dwelch67 mmu** tutorials use the simplest possible technique:
poll-the-UART-byte after every step, with a one-letter marker per stage
(`A`, `B`, `C`...). When one letter prints and the next doesn't, the bug is
between them. This is the approach we should be much more aggressive with
before the first JTAG attempt.

Sources:
- [seL4 elfloader README](https://github.com/seL4/seL4_tools/blob/master/elfloader-tool/README.md)
- [seL4 docs — Raspberry Pi 4](https://docs.sel4.systems/Hardware/Rpi4.html)
- [Circle on GitHub](https://github.com/rsta2/circle)
- [NetBSD — Porting NetBSD to a new ARM SoC](https://www.netbsd.org/docs/kernel/porting_netbsd_arm_soc.html)
- [git: 9fac39c63c12 — arm64 DDB symbols in early boot (FreeBSD)](https://www.mail-archive.com/dev-commits-src-main@freebsd.org/msg28736.html)
- [dwelch67/raspberrypi mmu](https://github.com/dwelch67/raspberrypi/tree/master/mmu)

---

## 10. Live cycle telemetry to add to `_init.S`

Concrete change set proposal for the next cache-enable attempt:

```
ENTRY(_init):
    # ... existing setup ...

    # Telemetry stage: pre-MMU baseline
    mrs   x20, cntpct_el0
    bl    uart_emit_marker_A           // "A" + hex(x20)

    # Program TCR/MAIR/TTBR
    bl    _setup_pagetables

    mrs   x21, cntpct_el0
    bl    uart_emit_marker_B           // "B" + hex(x21-x20)

    # Arm PMU counters 0..3 = INST, L1D_REFILL, L1I_REFILL, L2_REFILL
    bl    _arm_pmu

    # The cache flip
    msr   sctlr_el1, x0
    isb

    mrs   x22, cntpct_el0
    bl    uart_emit_marker_C           // "C" + hex(x22-x21)
    bl    _emit_pmu_deltas             // counters 0..3

    # Suspect-load probe
    ldr   x9, [x_syspage]
    bl    uart_emit_marker_D           // "D" + hex(x9)

    # ... rest of init
```

Each marker is one byte plus 16 hex chars; total runtime overhead is
microseconds. If the kernel hangs between B and C, it's the SCTLR write
itself; between C and D, it's the first cached load — exactly the question
we're currently *guessing* about.

---

## 11. Specific plan for the syspage relocate failure

Hypothesis: after MMU+cache enable, the kernel reads stale syspage data
because plo wrote the syspage with caches off and the kernel reads it via a
new mapping that pulls a stale line into L1.

Diagnostic plan (executable in this order, each step adds confidence
incrementally):

1. **Telemetry marker** at the syspage read. Confirm it's reached at all.
2. **Dual-read probe** (§7): map the syspage page twice — once cached, once
   `Device-nGnRnE`. After cache enable, read both. Print both. Equal →
   coherency fine, look elsewhere. Unequal → confirmed stale.
3. **Poison probe** (§5): plo writes a known sentinel, calls `dc civac`,
   kernel reads via cached mapping. Sentinel mismatch → cache served stale.
4. **PMU deltas** (§4) across the syspage read. If L1D_REFILL > 0 we *did*
   pull from DRAM, which contradicts the staleness hypothesis. If
   L1D_REFILL == 0 and L1D_CACHE > 0, we hit L1 — and that L1 line came from
   somewhere; trace it.
5. **Watchpoint** (§3): arm `DBGWVR0_EL1` on the syspage PA *before* MMU
   enable. The first post-enable access trips it; ELR captures the
   reader.
6. **JTAG bisection** (§1): if all else equivocates, JTAG-step from SCTLR
   write through the syspage read with `info registers` between each `si`.
   This is decisive but slow.

Steps 1–4 are pure UART / source patches; step 5 needs a working exception
vector; step 6 needs hardware. We should not jump to step 6 before 1–4 have
narrowed the hypothesis.

---

## Closing notes

- None of the techniques above replace AGENTS.md's GDB-first rule. They
  augment it for the case where the bug is *between* GDB observations.
- Most of these patches are diagnostic-only and must be removed under TD
  cleanup discipline before the step closes.
- The `_init.S` patch in §10 is the cheapest first step: zero hardware, ~30
  LoC, and it converts our next "brick" event into a labelled UART trail
  that already names the offending interval.

Sources:
- [Bare Metal Debugging on RPi4 with GDB & OpenOCD (danmc.net)](https://danmc.net/posts/2024/rpi4b-bare-metal-debugging/)
- [SO3 OS — Debugging SO3 with JTAG on RPi4](https://smartobject.gitlab.io/so3/so3_jtag_rpi4.html)
- [QEMU GDB usage](https://qemu-project.gitlab.io/qemu/system/gdb.html)
- [Learn the architecture — AArch64 self-hosted debug v1.1 (Arm)](https://documentation-service.arm.com/static/63f75e6c7741343f18b6d44f)
- [Cortex-A72 MPCore TRM (Stanford mirror)](https://www.scs.stanford.edu/~zyedidia/docs/arm/cortex_a72.pdf)
- [Stale data slides (Linaro / linuxfoundation.org)](http://events17.linuxfoundation.org/sites/events/files/slides/slides_17.pdf)
- [seL4 docs — Raspberry Pi 4](https://docs.sel4.systems/Hardware/Rpi4.html)
- [Circle bare-metal environment](https://github.com/rsta2/circle)
- [FreeBSD Foundation — Debugging the FreeBSD Kernel](https://freebsdfoundation.org/wp-content/uploads/2019/01/Debugging-the-FreeBSD-Kernel.pdf)
- [config.txt — enable_jtag_gpio (Raspberry Pi docs)](https://www.raspberrypi.com/documentation/computers/config_txt.html)
- [CNTPCT_EL0 register (Arm Developer)](https://developer.arm.com/documentation/ddi0601/latest/AArch64-Registers/CNTPCT-EL0--Counter-timer-Physical-Count-Register)
- [addr2line documentation (Baeldung)](https://www.baeldung.com/linux/addr2line)
