# GCC 16.2 build: early panic right after ExitBootServices (2026-11-02)

Context: [gcc16.md](gcc16.md). On the Pi, image B (GCC 16.2, haiku `gcc16` de1a4a439d, hrev60299+233) panicked
twice in about 13 boots right after the loader's "Calling ExitBootServices. So long, EFI!"; image A (GCC 13.3,
haiku `rpi4` f593b2ae43, hrev60299+232, same sources otherwise) had none in about 13. Host-only analysis (no Pi).

## Verdict

**A loader cache-coherency bug that GCC 16's register allocation exposes, not a GCC 16 miscompile.** A secondary
CPU, released from the spin table with its MMU and caches off, stores its CPU number on its stack, turns its caches
on, and reads the number back. The boot CPU had zeroed that stack with caches on and only *cleaned* the caches
afterwards, so a stale zero line can still be in L2: the read returns 0, and the secondary enters the kernel as
a second "CPU 0" on CPU 0's kernel stack. The two CPUs then corrupt each other's stack frames. GCC 13.3 keeps the
CPU number in a register (x19) across the cache switch, so it never reads that memory. Upstream Haiku has the same
latent bug.

Confidence: high. Every register in the SD crash's iframe is accounted for, and QEMU reproduces the same signature when a secondary is forced to CPU 0 (last section). Medium
for the netboot crash (garbled output, but it fits). It is not shown on hardware yet; the experiment below does
that in about 10 Pi boots.

## The evidence

### 1. The B-only difference on the secondary-CPU path

`src/system/boot/platform/efi/arch/arm64/arch_smp.cpp`: a released CPU runs `arm64_secondary_startup()` (asm: find
its `sCpus` entry by MPIDR, `mov sp` to `sSecondaryStacks[id]`), then
`arm64_secondary_startup2(cpu)` → `arm64_common_cpu_startup()` (EL2→EL1 drop, `arm64_mmu_setup()`, and at the end
`arch_cache_enable()`: SCTLR_EL1 |= M|C|I) → `arch_enter_kernel(..., cpu_kstack[cpu] top, cpu)`.

```
B (GCC 16.2) arch_smp.o                          A (GCC 13.3) arch_smp.o
arm64_secondary_startup2:                        arm64_secondary_startup2:
  stp  x29, x30, [sp, #-32]!                       stp  x29, x30, [sp, #-32]!
  mov  x29, sp                                     mov  x29, sp
  str  w0, [sp, #28]      <- caches OFF: to DRAM   str  x19, [sp, #16]
  bl   arm64_common_cpu_startup  (turns C on)      mov  w19, w0            <- cpu kept in a register
  ldr  w0, [sp, #28]      <- caches ON: may hit    bl   arm64_common_cpu_startup
                             a stale zero line     ... ubfiz x1, x19, #4, #32 / mov w3, w19
  ... ubfiz x2, x0, #4, #32  (cpu_kstack[cpu])     ...
  mov  w3, w0                (currentCPU)          b    arch_enter_kernel
  b    arch_enter_kernel
```

Why the line can be stale: `arch_smp_init_other_cpus()` runs `memset(stack, 0, size)` on each secondary stack with
caches **on**. `arch_smp_boot_other_cpus()` then calls `_arch_cache_clean_poc()`, which is `DC CSW`: clean by
set/way. That writes the zeros back to DRAM but leaves the lines valid in the cache. The secondary's
`str w0, [sp, #28]` runs with SCTLR.C=0. It is a non-cacheable store, so it goes to DRAM and leaves the cached copy
alone. Once the secondary turns its caches on, its `ldr w0, [sp, #28]` is cacheable. If the line for the top of
the stack is still in the shared L2, or in CPU 0's L1 and found by snooping, the load returns the stale 0 instead
of the CPU number in DRAM. This is the mismatched-attribute case of the Arm ARM, and Linux guards against it in
the same situation: `set_cpu_boot_mode_flag` does `dc ivac` after its MMU-off store ("Invalidate potentially stale
cache line"). The crash is intermittent because it only happens when that one line survives in the cache between
the memset and the release. In between, the loader generates the post-EFI page tables, runs ExitBootServices and
so on, which evicts it most of the time.

A cpu of 0 sends the secondary to `arch_enter_kernel(args, entry, cpu_kstack[0].start + size, 0)`: **the boot
CPU's stack, as CPU 0**. `smp_cpu_rendezvous()` still sees 4 arrivals (CPU 0, the fake CPU 0 and the other two), so
both "CPU 0"s run the boot path of `_start` together, on the same stack (top 0xffff000002462000).

Neither the loader binary nor the kernel differs in anything else that matters on this path. The images'
`EFI/BOOT/BOOTAA64.EFI` files are byte-identical to the build trees' `haiku_loader.efi` (A: except the revision
string), and the kernels were taken from the images' haiku packages. In both builds `arm64_common_cpu_startup()`
and `arch_cache_enable()` pop their own frames *before* the SCTLR write, because of how the tail calls happen to be
compiled, so those reads are still non-cacheable and safe. That is luck, not design.

### 2. The SD crash's iframe is one CPU returning through a frame record the other CPU wrote

Log `artifacts/uart/20261102-180932-boot16-3.log`: `PANIC: unhandled exception! FAR=0 ELR=24 ESR=2000000 (EC=0)`,
ELR=0x24, LR=0x20, FP=0x780, SP=ffff000002461ee0, SPSR=0x200003c5 (EL1h, DAIF masked), "Thread 1 on CPU 0",
nothing printed by the kernel before it.

- **Where in the kernel:** good B boots print "Welcome to kernel debugger output!" right after "So long, EFI!",
  and the panic could only print after `arch_debug_console_init()`. So it happened inside `debug_init()`
  (`frame_buffer_console_init`, `blue_screen_init_early`) or just after it. A static stack walk of B's
  `_start` up to that dprintf (boot stack = 0x245d000 + 0x5000) finds code that runs at SP 0xffff000002461ee0
  only under `debug_init → frame_buffer_console_init →(tail call) frame_buffer_update → _mutex_unlock/_mutex_lock`.
  Those are the console mutex's slow paths. They only run when two CPUs contend for `sConsole.lock`, which cannot
  happen in a correct boot (only CPU 0 runs `debug_init`).
- **The exact collision** (B kernel, frame sizes from the disassembly):
  - CPU X: `frame_buffer_update` (SP 0x2461f10) → `mutex_unlock` sees count -2 → `_mutex_unlock` (frame 48, SP
    0x2461ee0) → `acquire_spinlock` → `acquire_spinlock.part.0` (frame 80): its frame record {x29, x30} is at
    **0x2461e90**. Its epilogue `ldp x29, x30, [sp], #80; ret` leaves **SP = 0x2461ee0**.
  - CPU Y, a little behind: `frame_buffer_update` → `mutex_lock` sees count -1 → `_mutex_lock` (frame 80, SP
    0x2461ec0) → `acquire_spinlock.part.0` (frame 80, SP 0x2461e70): `stp x21, x22, [sp, #32]` writes to
    **0x2461e90**. Neither `_mutex_lock` nor `acquire_spinlock` touches x21/x22, so they still hold
    `frame_buffer_update`'s values: in B it does `mov w21, w1` (width) and `mov w22, w3` (depth), and keeps them
    until its `sdiv`s.
  - The console mode is 1920×1080, 32 bpp (`bcm2711_display: 1920x1080, 32 bits` in good boots), so CPU X pops
    **x29 = 0x780 = 1920, x30 = 0x20 = 32**: the iframe's FP and LR exactly.
- **Why ELR=0x24 and EC=0:** TTBR0 still holds the loader's identity map of low RAM, so `ret` to 0x20 runs the
  firmware armstub at physical 0. Disassembled from the card's `start4.elf` (all three armstub copies in it are the
  same): `+0x20: ldr x0, =54000000` (OSC_FREQ), `+0x24: msr cntfrq_el0, x0`. Writing CNTFRQ_EL0 is UNDEFINED at
  EL1, which gives EC=0 with ELR=0x24. The debugger's frame 7 ("/serial@" and "7e201a00") is the stack walker
  following FP=0x780 into the device tree the firmware put in low memory (the Pi 4 DTB has `/soc/serial@7e201a00`
  in its aliases about 0x680 bytes in). SPSR with DAIF masked fits being inside `InterruptsSpinLocker`.

### 3. The netboot crash fits the same picture

Log `artifacts/uart/20261102-144657-gm2-16-1.log`: two CPUs printed "PANIC: unhandled pagefault" interleaved
character by character, so two CPUs panicked at the same moment, which fits two "CPU 0"s. The readable
`ELR=ffff00000022b0e0` is in .bss: it is `sConsole+0x10` = **`&sConsole.lock.lock`**, the spinlock
`frame_buffer_update`'s mutex slow paths pass to `acquire_spinlock` (`add x0, x0, #0x10`). `acquire_spinlock.part.0`
keeps it in x19 (`mov x19, x0`) and its callees save x19 on the stack. So this is again a return through a frame
record overwritten by the other CPU, this time landing on the lock's address: an instruction abort on non-executable
.bss. FAR and ESR are garbled in the interleaved output.

## Answers

1. **What jumps to (near) 0?** A `ret` in `acquire_spinlock.part.0` on CPU 0's stack whose frame record
   {x29, x30} was overwritten by a second CPU running the same boot path on the same stack. That CPU saved
   {x21 = width 1920, x22 = depth 32} there. The second CPU is a secondary that took CPU number 0 from a stale
   cache line in the loader. It is not a codegen bug in `_arch_transition_EL2_EL1`, `arch_enter_kernel` or the
   kernel entry: those are the same in A and B, and the loader uses no PLT/GOT call, jump table or literal pool
   there that could go wrong. BTI/PAC play no part (neither the loader nor the kernel enables them; A's libgcc
   outline atomics start with `bti c`, B's don't, and that changes nothing). The only GCC 16 change that matters
   is that it spills a live-across-call argument to the stack where GCC 13 used a callee-saved register.
2. **Uninitialised memory?** It is the same broad class, stale memory, but the stale copy is in the *cache*, not
   in an uncleared page. The memory B reads and A doesn't is the 4 bytes at the top of each secondary stack,
   `[sp, #28]` in `arm64_secondary_startup2`'s frame, read after `arch_cache_enable()`.
   **d1a616afac (clear the empty TTBR0 table) is irrelevant here.** The crash happens in `debug_init`, long
   before `vm_init`, and TTBR0 is still the loader's identity map: that is why `ret` to 0x20 ran the armstub and
   FP=0x780 read device-tree strings. Cherry-picking it onto `gcc16` would only use up Pi boots.
3. **Fix** (loader, `arch_smp.cpp`, a few lines):
   - (a) In `arch_smp_boot_other_cpus()`, after `_arch_cache_clean_poc()`, clean and invalidate each secondary
     stack by VA (`dc civac` over `[sSecondaryStacks[i] - size, sSecondaryStacks[i])`, then `dsb sy`), the way
     the release address is already handled. This removes the stale lines before the CPUs are released. Not
     airtight on its own: a speculative fetch or prefetch on the boot CPU could bring a line back in.
   - (b) The robust part, Linux's pattern: carry no value in memory across the cache switch. Either
     `arm64_secondary_startup2()` looks up `cpu` again from MPIDR in `sCpus` after `arm64_common_cpu_startup()`
     (`sCpus` was written with caches on and cleaned, so it is coherent), or the secondary invalidates
     (`dc ivac`) the stack lines it has written, from SP to the top of its stack, just before it turns its caches on.
   - Recommended: (b), plus (a) as a belt. It goes in `rpi4` too, since A has the same latent bug and only
     its register allocation hides it. It is also an upstream bug (spin-table and PSCI secondaries both start with
     caches off).

## Discriminating experiment (Pi)

- Naive approach: with p ≈ 2/13 ≈ 15 %, a fixed B needs about 19-20 clean boots in a row to show improvement
  at 95 % ((0.85)^n < 0.05). 2/13 against 0/13 is itself not significant (Fisher p ≈ 0.48), so the A/B difference
  so far is suggestive, not proven.
- **Amplified approach (recommended, about 10 boots in all):**
  1. Positive control: an unfixed B loader with a *priming* step in `arch_smp_boot_other_cpus()` that reads the
     top cache line of each secondary stack right before the release (`sev` / PSCI call), so the stale line is
     sure to be in the cache. Expected: almost every boot fails in 3-5 boots.
  2. Fix + priming: 0 failures in 3-5 boots.
  3. A detector, so that a stale read is counted even when the crash looks different: in the loader, after
     `arm64_common_cpu_startup()`, the secondary looks up its number again from MPIDR and compares it with the
     reloaded `cpu`, recording a mismatch in a word the boot CPU or kernel prints. Or in kernel `_start`, an
     atomic count of arrivals with `currentCPU == 0`, with a message if it reaches 2.
- QEMU (TCG) has no cache model, so the stale line itself **cannot be reproduced in QEMU**. QEMU can only show the
  consequence (a secondary entering as CPU 0); see the next section.

## QEMU consequence control: the SD crash, reproduced

The test used image B unchanged except for one instruction in its `BOOTAA64.EFI`: the reload in
`arm64_secondary_startup2` (file offset 0x21a4, `ldr w0, [sp, #28]` = `b9401fe0`) became `mov w0, #0`
(`52800000`). This is the value a stale line delivers, made certain. It ran on `scripts/qemu-virt.sh` (virt,
cortex-a72, `-smp 4`, ramfb at 1024×768 × 32 bpp), on a throwaway copy of the image. Logs are in `artifacts/qemu/`
(not in git).

| Run | Loader | Result |
|---|---|---|
| 183825 | unchanged B | normal boot: "Welcome to kernel debugger output!" right after ExitBootServices, through to the first-login scripts |
| 183945 | B, secondaries get cpu 0 | `PANIC: unhandled pagefault! FAR=20 ELR=20 ESR=86000006`, Thread 1 on CPU 0, iframe 0xffff000002461ba8, **SP=ffff000002461ee0, LR=0x20, FP=0x400**, then the other CPUs panic with their output interleaved |
| 184053 | same | `unhandled pagefault! FAR=600 ELR=ffff0000000b1a5c` (in `thread_block`, which `_mutex_lock`'s slow path calls) |
| 184123 | same | same as 183945: SP=ffff000002461ee0, LR=0x20, FP=0x400 |

3 of 3 runs crashed before the first kernel message, and 2 of 3 with **the Pi SD crash's signature**: the same
iframe address, the same SP and LR=0x20 (depth 32), with FP = 0x400, QEMU's 1024-pixel width where the Pi has
0x780 = 1920. QEMU maps nothing at physical 0x20, so the jump ends as an instruction abort (ESR 0x86000006)
instead of the armstub's UNDEF. The several CPUs panicking at once match the netboot crash. So "a secondary
enters as CPU 0" is enough to produce the observed crash, down to the register values. Only the cause on the
Pi, the stale cache line, cannot be shown under QEMU (TCG has no caches). That needs the primed Pi experiment above.
