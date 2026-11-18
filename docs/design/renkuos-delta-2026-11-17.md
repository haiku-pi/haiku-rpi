# RenkuOS since 2026-11-04: what our Haiku Pi 4 port could use

Read-only analysis, 2026-11-17. Their tree: RenkuOS/Source `main` `b2dd07cd0374784547b2f4bfd33d95ed541ae983` (merge of
PR #433, 2026-11-17 15:31 -0700), compared with the 11-04 baseline `fe12fcdd3a`. Our tree: haiku `rpi4`
`90619c2102871b4abd8e18334e7b078ac2156474` (hrev60337+436, upstream merged 11-17). Nothing was built, run, pushed or
posted, and our repository was not modified.

Markers: **[V]** verified (in their tree, on GitHub, or in ours); **[C]** their claim, not checked; **[I]** my inference
from reading code, not tested. "Applies" means `git apply --check` of their patch against our `rpi4` copy of the same
files, done in a scratch directory. It says the text applies; nothing was compiled.

## Executive summary

1. **They added no Raspberry Pi 4 hardware support since 11-04 [V].** `git diff --name-only fe12fcdd3a b2dd07cd03` (611
   files) contains no path matching bcm, brcm, rpi, raspberry, vc4, v3d, genet, emmc2, vl805, videocore, mailbox or
   pi400. linkslice, who wrote their Pi 400 series, has merged nothing since #159 (11-01), and his fork
   `linkslice/RenkuOSSource` was last pushed on 2026-10-30. Their Pi drivers (bcm2711_emmc2, genet, brcmfmac, xHCI-ACPI)
   are unchanged. There is still no camera, CSI, DSI, I2C/SPI, RTC or PoE driver for the Pi.
2. **Activity:** 130 PRs merged from 11-04 to 11-17, 68 open [V]; the `gh` PR list is the complete record. Of the 335
   non-merge commits since `fe12fcdd3a` (a lower bound: the clone was `--shallow-since=2026-10-25`), 107 are
   upstream Haiku imports (#310, #406) that our tree already has (same subject) [V]. The 228 of their own are mostly x86
   laptops (Bay Trail, Alder Lake, radeon_hd, HDA, PS/2, SMBus), app_server compositing and UI, media, the Bluetooth HID
   series, the ARM32 AC100 port, and an arm64 nightly running in QEMU.
3. **Their value to us is in generic kernel and arm64 fixes**, mostly from atomozero (who hits them on ARM32 with SMP) and
   rainygirl. Several are latent in our tree and small:
   - **power-saving scheduler livelock**, `pack_irqs()`. On arm64 no IRQ ever moves, so CPU 0's list never empties [I].
     Our user guide documents the Power saving mode (USER-GUIDE §12, TRY-IT).
   - **page writer** uses a page that may have left its cache [V that we lack it].
   - **TCP endpoint teardown**: our current code waits for the timers while holding the lock that a timer hook needs [I].
   - **net notifications module deadlock at boot** (open PR #476).
   - **arm64 `__swap_float` / `__swap_double`** do nothing useful (open PR #477) [V the bug is in ours].
   - **GICv2 SGIs/PPIs typed as routable I/O IRQs**: the file is shared with our arm64 build [V].
   - **openbsd_wlan never sends scan-done**, so net_server never auto-joins a saved WiFi network (open PR #471) [V ours is
     `#if 0`].
4. **Already covered by us, skip:**
   - the arm64 sigreturn SPSR fix (`0b02c0a`, which came in through security-advisory merge `14e215e`, GHSA-mmvg-3xfc-26p8, with no PR number; ours is `4cd6f504f8`)
   - the I-cache line size (#417; ours `0fe465e233`)
   - the failed-fork page-table free (open #478; ours `e2aefd5d96`)
   - `setrlimit(RLIMIT_CORE)` (#368; ours `f0a1d5f5cf`)
   - shadowed MODIFIED pages (#343; covered by upstream `85b1dea534`, which we have)
   - the user-wait signal fix (#393; superseded by upstream `cf3a20899c`, which we have)
   - the uncapped-load rebalance (open #430; ours `2486477fab`)
5. **Bluetooth HID** (keyboards, mice, gamepads; our KNOWN-ISSUES F3) is coming as a nine-PR series by atomozero. Merged so
   far: the kernel stack (#252), two smaller fixes (#314, #315) and the `bluetooth_hid` driver (#396). The
   bluetooth_server HID profile is not merged yet [V from the PR text], so it does not work end to end on their `main`.
   It does not depend on the transport, so it should run over our `bcm2711_bt` H4 driver [I]. Of the 15 stack/kit
   commits, 12 apply in order to our tree; 3 L2CAP ones conflict with our `b0ea06deaf`, and theirs contain the same NULL
   checks [V]. Recommendation: watch, and port it once the server PRs land.
6. Recommended now (small, generic, each applies or needs only a trivial hand merge): the `pack_irqs` pair, the page
   writer re-lookup, the TCP teardown (hand port), #476 notifications `B_KEEP_LOADED`, #477 `__swap_float`, and #471
   scan-done (with #472 after a check of how passphrases are stored). Then optionally the GICv2 local-IRQ change, the
   `resize_area` guard and the module-path log fix. Ranked list at the end.

## 1. What changed in their project since 11-04

- **Pi 4 / BCM2711:** none (see summary 1) [V].
- **arm64 kernel:**
  - #403: GICv3 SGIs/PPIs become local. Not our controller: the Pi 4 has a GIC-400 (GICv2).
  - #417: I-cache line shift. We have it.
  - `0b02c0a` (security-advisory merge `14e215e`, no PR number): sigreturn context validation. We have the arm64 part.
  - Imported upstream: DigitalBox98's EL2 setup for secondary CPUs, the UART alignment and the spin-table cache clean.
    We have all three (subject match) [V].
- **Generic kernel:**
  - #392: scheduler `pack_irqs`.
  - #394: GICv2 local IRQs (`arch/arm/arch_int_gicv2.cpp`, which our arm64 build uses).
  - #322: page writer.
  - #343: anonymous-cache merge.
  - #427 (`5c9d81b`): `resize_area`.
  - #448: module paths.
  - #393: user wait.
  - #368: setrlimit.
  - #416: TCP teardown.
- **CI / packages:**
  - #345, #410, #457, #469: an arm64 nightly `@nightly-mmc` image, built from their own arm64 package release and booted
    in `qemu-system-aarch64 -M virt -cpu cortex-a72`. Their tree has no Pi 4 image or Pi 4 CI.
  - The RenkuOSPorts `arm64-packages` release: `renkuosports-arm64-repo.tar`, 931 MB [V], about 336–347 packages [C, from the PR text].
  - Issue #480: that image hangs on the splash from its second boot onward, in QEMU [C].
  - None of this is Pi hardware. It is a possible source of arm64 packages we lack, but their packages are built from
    upstream HaikuPorts recipes for `virt`.
- **New repository:** `RenkuOS/RenkuRemoteDesktop` (created 11-11, MIT), an RDP server for Haiku/RenkuOS, with #428
  (app_server screen observer). Not Pi-specific. It might work on our image [I]; not checked.
- **Other ARM boards** (not Pi):
  - open #486–#492: StarFive JH7110 (riscv64), including a DesignWare MMC driver (#488) and debug-UART `reg-shift`
  - open #459–#465: Hyper-V arm64
  - open #475: upstreaming the AC100 (ARM32)
- **Governance** (PlanAndGovernance, 4 commits): the two-subsystem cap was dropped (#364, 11-10). The DCO
  (`Signed-off-by`) and `Assisted-by` rules are unchanged.

## 2. Candidate table

Order: port, then watch, then skip. "Ours" = the equivalent in our `rpi4`.

| Their commit / PR | Subsystem | What | Ours | Benefit | Risk | Applies? | Rec. |
|---|---|---|---|---|---|---|---|
| `5de6fe7fcb` + `f883abc582` (#392, atomozero, 11-16) | scheduler (power_saving) | `pack_irqs()` moves a CPU's IRQs to the small-task core until its list is empty. When the arch keeps an IRQ where it is, the list never empties, and the scheduler spins with its lock held. They saw it freeze an AC100 within a second, and QEMU arm64 virt during boot [C]. | none. Our `power_saving.cpp:210-221` has the old loop [V], and our arm64 `arch_int_assign_to_cpu()` always returns 0 [V], so no IRQ ever leaves CPU 0. | High if it triggers: a hard freeze in a mode our USER-GUIDE §12 and TRY-IT document. On our tree it is [I]: we have no report of it, and our W43 tests did run Power saving. | Very low: two early returns. | Yes, in sequence [V] | **port** |
| `1afc69569a` (#322, atomozero, 11-16) | VM / page writer | `vm_page_write_modified_page_range()` unlocks the cache for each transfer, but its iterator already holds the next page. That page may leave the cache meanwhile, and the next round then faults in `PageWriteTransfer::Schedule()` on a NULL cache. Seen as a panic in `fsync()` while copying files on ARM [C]. The fix looks the next page up again after each write. | none. Our function (`vm_page_writer.cpp:794ff`) has the same iterator loop [V]. Our `1539d29eee` and `72ea4b2993` change other parts of the file. | Medium: a kernel panic under copy plus `fsync` with memory pressure. | Low. It adds a tree lookup per transfer, which is cheap. | Yes [V] | **port** |
| `bdecbeb5b5` (#416, rainygirl, 11-16) | network / TCP | `~TCPEndpoint()` marks the endpoint `FLAG_DELETING`, *unlocks* `fLock`, waits for the four timers, then destroys the lock. The hooks return when they see the flag. | Partly. Upstream `2f2dd59e16` (which we have) moved `mutex_destroy` after the waits. But our destructor takes `fLock` at the top and still holds it across `wait_for_timer()` (`TCPEndpoint.cpp:472-492`) [V]. A hook the timer thread has already dequeued blocks on `fLock`, while `wait_for_timer()` waits for `sCurrentTimer` to change. That is a deadlock of the stack's single "net timer" thread. From reading, our `timer_thread()` (`stack/utility.cpp:341-352`) runs the hook with `sCurrentTimer` set and `sTimerLock` released [V]; that the race happens in practice is [I]. | Medium: a rare hang of all network timers when a connection is torn down while its timer fires. | Low–medium: a hand port. Our flag enum ends at `FLAG_USER_CLOSED = 0x400`, so use 0x800. | No: the enum context differs (their 0x800/0x1000 flags). The rest is mechanical. | **port (by hand)** |
| PR #476 `d0f1661cdd` (rainygirl, **open**, 11-17) | network notifications | `NetNotificationService::FirstAdded()` called `get_module()` from inside the module's own generic syscall. If the module is being unloaded, `put_module()` holds the module lock while it waits for the syscall to return, and the syscall waits for that lock. Issue #308: net_server and launch_daemon deadlock at boot, splash forever, about 1 in 20 boots on x86 [C]. Fix: `B_KEEP_LOADED`, and drop the self-reference. | none. Our `notifications.cpp` is identical [V] (clean apply). | Medium: a boot hang. Same code path on ours; no Pi report [I]. | Very low (−21/+8). | Yes [V] | **port** (unmerged PR) |
| PR #477 `60be83bacc` (rainygirl, **open**, 11-17) | libroot arm64 | `__swap_float`/`__swap_double` had the `fmov` operands reversed: they swap the general register and return the input unchanged. | none. Our `byteorder.S` has the bug [V]: the same pre-image, and by reading, a float argument arrives in `s0`. | Low–medium: wrong `B_SWAP_FLOAT`/`B_HOST_TO_BENDIAN_FLOAT/DOUBLE` on arm64 (flattened data, media formats). | Very low (4 lines). | Yes [V] | **port** (unmerged PR) |
| PR #471 `af7c71aba8`, `9062ad2823`, `a9d0b81e21` (DruSatori, **open**, 11-16) | openbsd_wlan (under our bwfm) | (1) Enable `ieee80211_notify_scan_done()` and send `B_NETWORK_WLAN_SCANNED` at the end of each scan, which net_server's auto-join waits for. (2) List the current BSS in the scan results. (3) Ignore deauth/disassoc from other BSSIDs. | none. Ours has the notifier under `#if 0` (`ieee80211_haiku.cpp:549-565`) [V]. Our USER-GUIDE §9.2 says "whether a joined network is remembered across reboots is untested". | Medium: WiFi auto-join after boot. Parts 1–2 matter for FullMAC bwfm; part 3 probably not, because firmware handles management frames [I]. | Low | 3 of 4 files apply; 1 hunk in `ieee80211_input.c` is next to our own `__HAIKU__` disassoc block (trivial merge) [V] | **port 1–2**; part 3 optional |
| PR #472 `844755ddcd`, `11e9abe4a5` (DruSatori, **open**) | net_server | Remember networks joined interactively; retry auto-join 30 s after a failed attempt. | none [V] | Medium together with #471. | Medium: it stores a name-only entry and expects wpa_supplicant's keystore to hold the passphrase. We have no supplicant (our `584742feec` passes the passphrase itself), so auto-join may fail without a passphrase [I]. Check before porting. | Yes [V] | **port after check** |
| `4a763f815b` (#394, atomozero, 11-16) | GICv2 (shared by our arm64) | SGIs/PPIs 0–31 reserved as `INTERRUPT_TYPE_LOCAL_IRQ`, only SPIs as I/O IRQs, so the scheduler stops trying to move per-CPU interrupts. | none. Our `arch_int_gicv2.cpp:100` reserves all of them as IRQ [V]. | Low on our board, because no IRQ moves anyway. It fixes accounting (`irq_time`) and keeps the generic timer (PPI 30, `arch_timer.cpp:111`) off `cpu->irqs`. It complements #392. | Low–medium: changes the type of vectors our timer installs on. `reserve_io_interrupt_vectors()` sets `assigned_cpu` for every type [V], and install does no balancing for non-IRQ types, as on x86 for the APIC timer. Needs a boot plus a KDL `ints` check. | With `-C1` (our extra comment line in the context) [V] | **port (optional, test)** |
| `5c9d81bd5b` (#427, Kevin Adams, 11-16) | VM (security) | `resize_area()` refuses to shrink an area when another team maps the same cache unless the caller is the kernel. Any client could crash app_server by shrinking a cloned bitmap area [C]. Adds `resize_area_tests.cpp`. | none [V] | Medium (security / robustness). | Medium: a legitimate shrink of shared memory by its owner now fails with `B_NOT_ALLOWED` while others map it. Our in-tree callers shrink only private areas (malloc `PagesAllocator`, `brk`) [V]. Wine, Box64 and Mesa shared memory were not checked. | Yes [V] | **port after a Wine/GL smoke** |
| Bluetooth kernel/kit: `dbdf8a3e4a`, `2847572aa5`, `9f69945935`, `db6d61f40c`, `3383b431d8`, `823649eb6e`, `1bdaf62e8f`, `b394fc71d6`, `2f5f5c1a1b` (plus the h2generic commits `ef86c20`, `cf018bd`, `b95df95` in the skip row); conflicting: `c53c2abd7e`, `2ceaec5e3b`, `53776c395c` (#252, #314, #315; atomozero) | Bluetooth stack, L2CAP, HCI, SDP, libbluetooth, bluetooth_server | The ident is no longer reused, so devices answer L2CAP requests. SDP string and length bounds (remote input). Connections are dropped when a controller goes away. Pending L2CAP connections and close fixed. Users of a channel on a lost link are woken. Connection state from the right controller (Preferences no longer showed every device as connected). | Partly: `b0ea06deaf` (the L2CAP NULL endpoint, which their `c53c2ab` also contains) [V]. The rest: none. | Medium: needed for any Bluetooth profile beyond pairing (F3). `3383b43` bounds data from a remote device. | Medium as a set; each is small. | 12 of 15 apply in order (the 9 listed here plus the 3 h2generic ones) [V]; `c53c2ab`, `2ceaec5`, `53776c3` conflict in `l2cap_signal.cpp` / `L2capEndpoint.cpp` against our `b0ea06deaf` (manual merge) | **watch**, port as one batch with HID. Optionally now: `3383b43` + `2847572` (SDP bounds), `b394fc7` + `2f5f5c1` (clean, user-visible) |
| `c7ae9ae1a0`, `b9b917168d`, `e0f35c5d75` (#252 part, #396; atomozero) | input: `bluetooth_hid` driver | Bluetooth HID keyboards, mice and gamepads published like USB ones through the shared HID handlers. bluetooth_server opens `input/bluetooth_hid/control`. | none | High for F3 once the server side lands. | Medium | `b9b9171` fails at least in the Jamfile/package-list hunks (the output was cut off at two errors); `c7ae9ae` was not checked | **watch** (needs their unmerged bluetooth_server HID PRs; open #481 SSP is next) |
| `703ad85b51` (#448, atomozero, 11-16) | kernel modules | `module_init_post_boot_device()` normalises the paths of preloaded modules also in `kernel/file_systems` and `kernel/partitioning_systems`. | none. Our Pi logs show exactly `module_init_post_boot_device() failed to normalize path of module image …, "fat"` (tmp `pitest.out`, `sl-ts.txt`, `cl-window2.txt`) [V]. | Low (log noise; the module keeps a bare name). | Low | Yes [V] | **port (low priority)** |
| PR #449 `8ecbe9c930`, `22ca5d0ad6` (atomozero, **open**) | file_cache | Look for the `launch_speedup` cache module only when the kernel settings name one. | none. Our logs show `module: Search for file_cache/launch_speedup/v1 failed.` [V]. | Low (log noise) | Low | not checked | **watch** |
| `864479ca29` (#409, idumych, 11-16) | launch_daemon | A service whose start failed (for example because it was already running) can be launched again; the launching flag is cleared. | none [V] | Low | Low | Yes [V] | port (optional) |
| `1a7296bccb` (#400, atomozero, 11-14) | freebsd_network | `struct cv` aligned like the `ConditionVariable` it holds. A misaligned one faulted on ARM32 `stmib`. | none [V] | Low on arm64: plain unaligned stores are fine there, but the spinlock inside needs alignment for exclusives [I]. Latent. | Very low (it changes struct layout; rebuild all freebsd_network drivers) | Yes [V] | port (optional) |
| PR #275 `1969248962`, `9851112edc` (12akakor, **open draft**) | xHCI | Set the Max ESIT Payload for low/full-speed periodic endpoints too (it was 0). Recover interrupt endpoints after a USB transaction error, at most 3 times per second. | none. Ours sets it only in the high-speed path (`xhci.cpp:2382-2391`) [V]. | Unknown: it might relate to our intermittent HID-endpoint TRB error on the VL805 (`1d44b00380`) [I]. | Medium (draft; incomplete on their own device [C]) | No (our xHCI differs) | **watch / test idea** |
| PR #483 `7518319217` (DruSatori, **open**, 11-17) | freebsd_network | `compat_send()` frees its mbuf on two early returns (`read()` failed, device closed). | none. Our bwfm links `libfreebsd_network.a` (broadcomfmac Jamfile) and sends through `compat_send()` [V]; our GENET is native and is not affected. | Low: an mbuf leak on WiFi send errors or close. | Very low (+6/−2) | Yes [V] | **port** (unmerged PR) |
| PR #482 `2891b08580`, `29ba7a959a` (DruSatori, **open**) | freebsd_network | `if_detach()` frees multicast entries, `if_addr` and driver-queued mbufs; non-WLAN NICs are stopped in `compat_close`. | none | Low: it only matters when a compat driver is unloaded (bwfm rarely is). | Low | No (`if.c` conflicts) | watch |
| PR #479 `70a4f67c6e` (rainygirl, **open**) | usb_disk | Reset recovery after a timed-out bulk transfer; bounded retries for block I/O. | Partly different: our `eabad7a921`/`b90cb3f0d4` are cache fixes, not retries. | Low–medium (flaky sticks) | Medium (retries can hide errors) | No (conflicts with our usb_disk changes) | watch |
| SDIO series: `c0f90ccb19`, `a98be551a7`, `c8839d9d44`, `fdcc1418f8`, `752600f196`, `c77c503487`, `01b398753b`, `d431cfbf17` (#276, #277; 12akakor) | mmc / sdhci / freebsd_network SDIO | Their own SDIO in the MMC bus manager and SDHCI (CMD52/53, card IRQ, 4-bit/HS, ADMA2 multi-block, no CMD12/13 after SDIO errors), plus an `sdio` bus for FreeBSD drivers (RTL8723BS on Bay Trail). | Our own SDIO design (`ec55b68bfe` et al.). Checked: our card-IRQ path is already spinlocked with `InterruptsSpinLocker` (`sdhci.cpp:1319-1343, 1484-1494`) [V]; our poller never calls `HandleInterrupt()`, so `01b3987` does not apply [V]; byte-mode CMD53 tails are handled (`sdhci.cpp:742`) [V]; our `ExecuteCommand` still returns `B_BUSY` at once on command inhibit, where theirs waits up to 50 ms (`c8839d9`) [V]. | Low for us (bwfm works); the inhibit wait is the only idea we lack. | High as a port (a parallel design) | No (all conflict) [V] | **skip** (watch the inhibit-wait idea) |
| PR #431 `f291b07427` (atomozero, **open**) | debug_server | ARM register dump; a plain-text crash report on the desktop when Debugger is missing. | Partly: we have an arm64 Debugger back end (F9). | Low | Low | not checked | watch |
| `0b02c0aca8` (security-advisory merge `14e215e`, no PR) | arm64 sigreturn | Only NZCV taken from the user SPSR. | **have** `4cd6f504f8` (also keeps BTYPE, SSBS, DIT, TCO) [V] | — | — | — | skip |
| `e44005d48c` (#417) | arm64 I-cache | `ctr_el0 & 0xF` | **have** `0fe465e233` (also honours IDC/DIC) [V] | — | — | — | skip |
| PR #478 `7a6c763791` (open) | arm64 translation map | Do not free page table 0 of a map that never mapped anything. | **have** `e2aefd5d96` + `c8f3757b45` [V] | — | — | — | skip |
| `7363e52aaa` (#343) | VM | Shadowed MODIFIED pages moved to CACHED in the anonymous-cache merge. | **covered** by upstream `85b1dea534` (RemovePage does it for every caller), which we have [V] | — | — | — | skip |
| `f01a6f3680` (#393) | kernel user wait | Do not store `B_INTERRUPTED` in `wait_status`. | **superseded** by upstream `cf3a20899c` (stores nothing), which we have [V]; our `2bf2f773ba` fixes the rw_lock side | — | — | — | skip |
| `fdc000f31a`, `8feb31e` (#368) | setrlimit | `RLIMIT_CORE 0/0` succeeds | **have** `f0a1d5f5cf` [V] | — | — | — | skip |
| PR #430 `cee91ce95b` (open) | scheduler | `rebalance()` on the uncapped load | **have** `2486477fab` [V] | — | — | — | skip |
| `5f6748f9c5` (#403) | GICv3 | local SGIs/PPIs | n/a (the Pi 4 is GICv2) | — | — | yes | skip |
| `ef86c20`, `cf018bd`, `b95df95`, `e28b91f`, `925977a`, `6b86d78`, `92ff37a`, `b701997` | h2generic (USB BT), EHCI, freebsd_network USB | USB Bluetooth dongles, EHCI, run(4) USB WiFi | n/a: we use UART Bluetooth, xHCI, and no USB WiFi | — | — | mostly yes | skip |
| `5c1beea0b5` (#432) | virtio | Lost completions while a queue's IRQ is masked | none | Only our QEMU runs | Low | not checked | skip / optional |
| `a73baea`, `7076789`, `ab4c90d`, `a370d26`, cpuidle, radeon, intel, HDA, PS/2, app_server, media alignment (`4b157fb`, `cf12459`, `3a943f4`, `10e0df5`) | ARM32 / x86 / UI / media | — | — | The media alignment fixes matter for ARM32. arm64 allows unaligned plain loads and stores [I]. | — | — | skip |

## 3. Pi 4 hardware they have and we don't

None new since 11-04 [V]. What they had on 11-04 is unchanged:
- **Boot:** UEFI/ACPI boot, with ACPI attach for xHCI, SD, GENET and SDIO.
- **SD:** a polled-PIO SD driver.
- **GENET:** RX copied out of uncached buffers.
- **WiFi:** a native brcmfmac FullMAC driver.

All of these are weaker than or different from ours (see the 11-04 analysis §2–3). No camera/CSI, DSI, I2C, SPI, RTC, PoE,
display, GPU, audio or HEVC driver exists in their tree.

## 4. Licence and trailers to keep when porting

Their code is MIT like Haiku's (`License.md` unchanged; D3 requires MIT-compatible code). The trailers to carry over,
plus our `Ported-from: RenkuOS/Source <merge> (PR #n), MIT` line, as in renkuos-fixes.md:

| Commit(s) | Author | Trailers in the commit |
|---|---|---|
| `5de6fe7`, `f883abc`, `4a763f8`, `1afc695`, `703ad85`, `1a7296b`, all Bluetooth commits above | atomozero <bernardi.andrea@gmail.com> | `Signed-off-by` only (no `Assisted-by`) |
| `bdecbeb`, PR #476 `d0f1661cdd`, PR #477 `60be83bacc` | rainygirl <rainygirl@gmail.com> | `Signed-off-by` only (the PR bodies say "drafted by Claude") |
| `5c9d81b` | Kevin Adams <kevinadams05@gmail.com> | `Assisted-by: claude-opus-5-5`, `Co-Authored-By: Claude Opus 5.5`, `Signed-off-by` |
| `864479c` | Ian (idumych) <idumych@gmail.com> | `Assisted-by`, `Co-Authored-By`, `Claude-Session: https://claude.ai/code/session_01PoWUVRRtq76Ffr3wkNXK5V`, `Signed-off-by` |
| PR #471 / #472 | Dru Satori <dru@druware.com> | `Assisted-by: Claude Opus 5.5`, `Co-Authored-By`, `Signed-off-by` |
| `0b02c0a` (not needed) | Kevin Adams | `Co-authored-by: rations`, `Assisted-by`, `Signed-off-by`; advisory GHSA-mmvg-3xfc-26p8 |

`f01a6f3` and `fdc000f` (not needed) are themselves ports from `airos-works/haiku` (`Ported-from`, MIT). Open PRs (#471,
#472, #476, #477) are not reviewed or merged on their side yet: take the commit as it is in the PR and note "unmerged PR".

## 5. Ranked candidates

1. **`5de6fe7` + `f883abc` (#392)**: the `pack_irqs()` livelock in Power saving mode. Port now. Freeze on ours is [I].
   Pi test: select Power saving in ProcessController, run one busy thread per core on CPUs 1–3 (`tools/haiku-tests/spread.c`)
   while CPU 0 idles, and watch for a freeze, before and after.
2. **`1afc695` (#322)**: page writer re-lookup after an unlocked write (panic in `fsync`). Port now.
3. **`bdecbeb` (#416)**: TCP endpoint teardown. Our code holds `fLock` across `wait_for_timer()`, so the net timer thread
   can deadlock [I]. Hand port with `FLAG_DELETING = 0x800`.
4. **PR #476**: net notifications `B_KEEP_LOADED` (boot deadlock, their issue #308). Port; unmerged PR.
5. **PR #477**: arm64 `__swap_float`/`__swap_double` (bug in ours [V]). Port; unmerged PR. Also **PR #483**, an mbuf leak in
   `compat_send()`, which our bwfm uses [V] (+6/−2, applies; unmerged PR).
6. **PR #471** (parts 1–2), then **#472** after checking where our passphrase lives. Lets WiFi auto-join saved networks.
7. **`4a763f8` (#394)**: GICv2 SGIs/PPIs as local IRQs. Optional; test boot plus KDL `ints`.
8. **`5c9d81b` (#427)**: the `resize_area` shrink guard. Port after a Wine/GL/MediaPlayer smoke.
9. **Bluetooth series** (#252/#314/#315/#396, next #481): watch; port as one batch when bluetooth_server's HID profile
   merges. That would close F3 for keyboards and mice. `3383b43` (SDP bounds) and `b394fc7` + `2f5f5c1` (correct
   connection state) can come earlier.
10. **`703ad85` (#448)** and **PR #449**: remove two boot log lines we see on every boot. Low priority.
11. **`864479c` (#409)**, **`1a7296b` (#400)**: small, optional.
12. **Watch:** PR #275 (xHCI low/full-speed ESIT payload, possibly related to our VL805 HID TRB error), PR #479
    (usb_disk retries), PR #431 (debug_server ARM report), the SDIO inhibit-wait idea from `c8839d9`, their arm64 package
    release, issue #480 (arm64 image hangs from its second boot, QEMU).

## Method and housekeeping

- **Clone:** a blob-less shallow clone of RenkuOS/Source (since 2026-10-25) into a scratch directory, deleted
  after the analysis. Their code was never built or run.
- **Lists:** PR and issue lists via `gh`. RenkuOSPorts, PlanAndGovernance and RenkuRemoteDesktop were read through the
  GitHub API only.
- **"Do we have it":** an exact subject match against our `rpi4` log since 2026-09-01 (107 hits, all upstream imports),
  then reading our code for each candidate.
- **Apply checks:** `git apply --check` against scratch copies of our `rpi4` files, made with `git -C … show rpi4:<path>`.
  The Bluetooth series was also applied in order.
- **After the analysis:** the candidate patches were kept only in the session's scratch directory (untrusted
  data) until ported; not in this repository.
