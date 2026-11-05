# BFS: `rm -rf` hangs beside a `sync` (task 122)

Found by the x86-64 re-check (`x86-64-check.md` §10.3 item 4): `rm -rf` of a directory of 4000 freshly written files
on a scratch BFS volume hung in about a third to half of the runs, on our tree and on upstream hrev60314. Written
2026-11-05, from KVM runs only (no Pi time: the bench was held by C4b).

**Result.** A deadlock between `rm`, the scratch disk's I/O notifier thread and a concurrent `sync`, caused by
upstream's BFS finished hook dropping the last reference of a removed inode from the I/O notifier thread. Upstream bug
(`551a9b9a01`, 2024-11-20, still in upstream master); none of our commits is involved, `a9db442988` included. Fixed on
branch **`bfs-rmrf-hang`** (`9ff372a378`, one commit, pushed, not merged): fixed **0 hangs in 50 runs** against
**6 hangs in 25** on the unfixed image in the same alternated sessions (one-sided Fisher exact p ≈ 0.0009; with the
unfixed rate of 24 %, 0 of 50 has a chance of 1 in 900 000).

## 1. Reproducing

- Probe: `tools/x86-tests/bfsrm.sh` (new; `bfsrep.sh` with a hang detector): `bfsmeta /scratch/metaN 4000` (4 writes
  of 512 bytes and 2 attributes per file), then `rm -rf` of the directory in the background, then `sync`, five rounds.
  When `rm` is not done after 60 s it enters KDL with `kdl "bfsrm hang team <id>"` (`tools/haiku-tests/kdl.c`, new:
  `_kern_kernel_debugger()`, root only).
- Driver: `scripts/x86-bfsrm.sh IMAGE N` (new): N runs, each on a fresh 2 GB scratch BFS (`bfs_shell --initialize`)
  and a fresh qcow2 overlay; on a hang it types `bt <rm>` and `bt 29` (the scratch disk's notifier) through the serial
  socket and stops QEMU by its PID; one row per run in `artifacts/qemu-x86/bfsrm.tsv`.
- `scripts/kdl-x86.py` fixed: it typed whole commands at once right after a long output and KDL lost characters
  (`bt 295` arrived as `t 295`); it now drains the socket until the output has been quiet for 1 s and types one
  character every 20 ms.
- KVM, q35, UEFI, AHCI boot and scratch disks, SMP 4, 4 GB, image `artifacts/x86-images/r265.iso` (rpi4
  `265d2b03dd`). The first run hung (`20261105-063233-bfsrm-r265.iso-uefi-ahci.log`), the second too (`-063441-`,
  kept in KDL for the lock dumps below).

**Always round 1, because of the first boot.** Every run is a first boot (fresh overlay), and on a first boot
`/system/boot/PostInstallScript` runs the first-login scripts and then `sync` (`data/system/boot/PostInstallScript:37`).
That `sync` runs while round 1's `rm` does: the race below needs a synchronous writer of the files being removed. All
hangs, here and in §10.3 of the x86-64 check, are in round 1. The established FS group never hit it: its `rm -rf`
comes after a remount, long after the first-boot `sync`.

## 2. The state of the hang

CPU: idle. `running` lists only the idle threads and `kdl` itself; `rm` is blocked, not spinning. A deadlock, not a
livelock. Stacks (`bt`, run `-063441-`, the same in every hang caught since):

| thread | waits for | stack (top down) |
|---|---|---|
| 295 `rm` (team 295) | `rwlock` "bfs inode" `0x…8bacf728` (write) | `rw_lock_write_lock` ← `Inode::WriteLockInTransaction` ← `Inode::Remove` ← `bfs_unlink` ← `common_unlink` ← `_user_unlink` |
| 29 `scsi notifier 2` (the scratch disk's I/O notifier) | `mutex` "bfs journal" `0x…9d129c48` | `recursive_lock_lock` ← `Journal::Lock` ← `Transaction::Start` ← `bfs_remove_vnode` ← `free_vnode` ← `dec_vnode_ref_count` ← `put_vnode` ← **`iterative_io_finished_hook`** ← `do_iterative_fd_io_finish` ← `IORequest::NotifyFinished` ×2 ← `IOSchedulerSimple::_RequestNotifier` |
| 242 `sync` (team 242, parent: `sh /system/boot/PostInstallScript first login`) | `cvar:I/O` | `IORequest::Wait` ← `vfs_write_pages` ← `VMVnodeCache::Write` ← `PageWriteTransfer::Schedule` ← `vm_page_write_modified_page_range` ← `VMCache::WriteModified` ← `fs_sync` ← `_kern_sync` |
| 30 `page writer: /dev/disk/scsi/0/1` | `cvar` "page writer wait for I/O" | `PageWriterRun::Go` (its transfers also wait for the notifier) |
| 31 `bfs log flusher`, 18 `block notifier/writer`, 25/28 `scsi scheduler 1/2`, 26 `scsi notifier 1` | idle (their semaphores / no requests) | |

Locks:

```
kdebug> recursivelock 0xffffffff9d129c48         kdebug> rwlock 0xffffffff8bacf728
  name:            bfs journal                     name:            bfs inode
  holder:          295                             holder:          -1
  recursion:       1                               count:           0x10001
  waiting threads: 29                              active readers   1
                                                   waiting threads: 295/w
```

`io_request_owner` of the scratch scheduler: no pending, no completed requests. The I/O is done; only its
notification is outstanding. No `transaction`/`block_cache` command was needed: the block cache is not in any stack.

## 3. Root cause

`bfs_io()` (`src/add-ons/kernel/file_systems/bfs/kernel_interface.cpp:524-533`) read-locks the inode and takes its
own vnode reference (`acquire_vnode()`, upstream `551a9b9a01`, "BFS: Keep references to vnodes during asynchronous
I/O", 2024-11-20); `iterative_io_finished_hook()` (`:111-118`) drops both:

```
	rw_lock_read_unlock(&inode->Lock());
	put_vnode(inode->GetVolume()->FSVolume(), inode->ID());      // :116
```

The reference exists because `IORequest::NotifyFinished()` (`src/system/kernel/device_manager/IORequest.cpp`) wakes
the request's waiters first (`fFinishedCondition.NotifyAll()`) and only then calls the finished callbacks: a
synchronous caller (`vfs_write_pages()`, `vfs_read_pages()`) can return and drop *its* reference before the hook runs.
So the hook's reference can be the last one. If the file was unlinked meanwhile, the vnode is removed, and since the
vnode undertaker (`bc46fb3e9a`, 2026-08) a `put_vnode()` *from a file system* (`reenter = true`) still frees
synchronously (`dec_vnode_ref_count()`, `src/system/kernel/fs/vfs.cpp:1099-1107`): `free_vnode()` →
`bfs_remove_vnode()` → `Transaction::Start()` — a journal transaction started **in the I/O scheduler's notifier
thread**, the one thread that notifies every I/O of that device.

The cycle, with G and F two files of the directory being removed:

1. `sync` writes G synchronously (`bfs_io()`: G read-locked, reference taken). The write completes; the notifier
   wakes `sync` (`NotifyAll`) before calling the hook.
2. `sync` drops its reference to G (already unlinked by `rm`) and goes on to F: `bfs_io()` read-locks F and queues
   F's write.
3. `rm` unlinks F: `bfs_unlink()` starts a transaction (journal lock held) and `Inode::Remove()` asks for F's write
   lock (`Inode.cpp:3138` → `WriteLockInTransaction()`, `:657`): it waits for F's reader, the queued write.
4. The notifier runs G's hook: last reference → `bfs_remove_vnode()` → `Transaction::Start()` → waits for the journal
   lock, held by `rm`.
5. F's write completes, but only the notifier can notify it, and so release F's read lock: nobody moves again.

(Which of `Inode::Remove()`'s two `WriteLockInTransaction()` calls `rm` waits in is inferred: the directory's data is
in the block cache, not written through `bfs_io()`, so the reader is the file's. The stack offset `+0x99` fits the
second call.)

Even without the cycle, a transaction in the notifier is costly: only requests with callbacks go through the notifier
(`IOSchedulerSimple.cpp:421-431`; the block cache's plain writes are notified inline), so it cannot wait for itself,
but while it waits for the journal, or for a log flush when the log is full, every callback-bearing request of that
device (page writer transfers, file-cache reads and writes) waits behind it.

Why it is upstream's and not ours: the hook, the reference and the notification order are upstream code; none of our
commits touches `bfs/kernel_interface.cpp`, `IORequest::NotifyFinished()`'s order or `dec_vnode_ref_count()` (our
`vfs.cpp` change is a NULL check). `a9db442988` (block cache sub-transactions) is not in any stack. Rates (§5)
overlap between hrev60314, `a779571e90` and `265d2b03dd`.

## 4. The fix

Branch **`bfs-rmrf-hang`** off rpi4 `265d2b03dd`, worktree `sources/haiku-bfsrm`, commit **`9ff372a378`** "bfs: leave
the last put of an I/O's vnode to the undertaker", pushed to origin, not merged. The hook releases its reference
with the kernel's `vfs_put_vnode()` (looked up with `vfs_lookup_vnode()`; the reference keeps it valid), which is a
non-reentrant put: a removed vnode's deletion goes to the vnode undertaker thread, as the page writer's releases
(`VMVnodeCache::ReleaseStoreRef()`) already do. `bfs_shell` (`FS_SHELL`) keeps `put_vnode()`.

```
	rw_lock_read_unlock(&inode->Lock());
#ifdef FS_SHELL
	put_vnode(inode->GetVolume()->FSVolume(), inode->ID());
#else
	struct vnode* vnode;
	if (vfs_lookup_vnode(inode->GetVolume()->ID(), inode->ID(), &vnode) == B_OK)
		vfs_put_vnode(vnode);
#endif
```

With it, step 4 only queues G for the undertaker; the notifier goes on, F's hook releases F's read lock, `rm`
finishes its transaction, and the undertaker then gets the journal lock for G's removal.

Considered and not done:
- Changing `IORequest::NotifyFinished()` to call the callbacks before waking the waiters: global, and upstream's own
  commit message rules it out (a callback may delete the request).
- Making every file-system `put_vnode()` deferred: `bc46fb3e9a` says the reentrant direct free is needed for
  unmount, and BFS relies on it inside transactions (`Inode::RemovedFromTransaction()`).

What the change can affect: a removed vnode stays busy until the undertaker has run. A non-forced unmount that sees
it then returns `B_BUSY` — the same as for a vnode the page writer released a moment earlier, so no new class of
behaviour. The FS group's unmount/remount (§5) passed.

`exfat/kernel_interface.cpp:60` has the same hook (reference from the same upstream pattern). exFAT is read-only in
Haiku (no `remove_vnode` transaction), so it cannot deadlock this way; not changed.

## 5. Verification

Image `artifacts/x86-images/bfsfix.iso` (`scripts/build-x86.sh configure|build sources/haiku-bfsrm/generated.x86_64`,
heavy-build guarded, rc 0 in 266 s; `kernel_interface.o` imports `vfs_lookup_vnode`/`vfs_put_vnode`; revision
`hrev60314+286`). All runs: `scripts/x86-bfsrm.sh`, the fixed and unfixed images alternated (fix, fix, unfixed, …),
nothing else running on the host's VM side; rows in `artifacts/qemu-x86/bfsrm.tsv`.

| session | fixed `bfsfix.iso` (hung / runs) | unfixed `r265.iso` (hung / runs) |
|---|---|---|
| A/B 1, 06:59–07:08 (fix, fix, unfixed ×10) | 0 / 20 | 2 / 10 |
| A/B 2, 07:12–07:31 (fix, fix, unfixed ×15) | 0 / 30 | 4 / 15 |
| **total** | **0 / 50** | **6 / 25 (24 %)** |

- Every unfixed hang has the signature of §2 in its KDL output: `rm` in `Inode::WriteLockInTransaction()`, the
  notifier in `iterative_io_finished_hook()` → `Transaction::Start()` (logs in `bfsrm.tsv`, e.g.
  `20261105-070114-bfsrm-r265.iso-uefi-ahci.log`).
- Odds: one-sided Fisher exact test of 0/50 against 6/25: p = C(25,6)/C(75,6) ≈ 8.8·10⁻⁴. Taking the unfixed rate as
  24 %, 0 hangs in 50 by chance: 0.76⁵⁰ ≈ 1.1·10⁻⁶; even at the low end of its 95 % interval (≈ 9 %): 0.91⁵⁰ ≈ 0.009.
- The rate is lower than §10.3's `bfsrep` numbers (13 of 29 hung across three images): those runs had a busier host.
  Not in the table: the first two runs (both hung, `-063233-`, `-063441-`) and three unfixed runs while the fix image
  was building (1 hung), with an earlier driver version.

Regression checks on the fixed image (UEFI, AHCI, fresh scratch disk):

| test | result | log (artifacts/qemu-x86/) |
|---|---|---|
| FS group (bfsmeta, copy 2277 files + MD5, unmount + mount + MD5, fragwrite, checkfs, bfsbits) | PASS, twice | `20261105-073233-fs-bfsfix.iso-uefi-ahci.log`, `-074421-` |
| the same on the unfixed image, between the two (copy-time control) | PASS | `20261105-073834-fs-r265.iso-uefi-ahci.log` |
| 3 power cuts (QMP quit after 20000 files of `bfsmeta --loop`; mount = log replay, checkfs, bfsbits, a write) | PASS 3/3; checkfs 2/4/6 "blocks could be freed", the same counts as r265 in §10.1 | `20261105-074813-pc1-…` to `-074954-pc2-bfsfix.iso-uefi-ahci.log` |

The copy took 23 s on the first fixed run against 9 s for r265 in `x86-64-check.md` §10.1; back to back it was 21 s
(r265) then 7 s (fixed): host noise, not the change. No PANIC, KDL or user fault in any of these runs.

arm64: `scripts/arm64-compile-check.sh sources/haiku-bfsrm src/add-ons/kernel/file_systems/bfs/kernel_interface.cpp`:
ok (arm64 build flags, `-Werror`). No arm64 run: QEMU virt and the Pi not tried (bench held by C4b).

## 6. Open

- Merge `bfs-rmrf-hang` into rpi4 after an arm64 run (the code is arch-neutral; the Pi has the same notifier design).
  The branch is off `265d2b03dd`; rpi4 has since moved to `afd7f0590c` (C4b: page writer and file cache request
  sizes), which touches no BFS file, so the merge is clean. C4b does not change the race: the page writer holds its
  vnode references until all of its transfers are notified, so only synchronous writers and readers can lose the race.
- The Pi probe: run, see §7 (the hang did not reproduce on the Pi, fixed or not).
- Upstream: the same bug is in upstream master (`4f1074d5e1`, 2026-11-04: the hook is unchanged). We do not send
  changes upstream for now (AGENTS.md); the commit is written to be sendable.
- `scripts/x86-bfsrm.sh` catches the race only on a first boot (the first-login `sync`); a `sync` loop beside every
  `rm` did not reproduce it (0 of 3 unfixed runs, 15 rounds), so the probe stays first-boot only.

## 7. Pi check (2026-11-05, arm64, network boots only)

Images: **fixed** `artifacts/images/haiku-pi4-bfsfix.img` = rpi4 `44cc183c0c` (`scripts/build.sh -sHAIKU_PI_GL=1
-sHAIKU_IMAGE_SIZE=4500 @pi-mmc`, rc 0; its `bfs` add-on imports `vfs_put_vnode`); **unfixed**
`haiku-pi4-2026-11-05b.img` = `afd7f0590c` (the release, sha256 03c1aa51...). The SD card was never written or mounted;
the scratch volume is a BFS made by the probe on the USB disk `/dev/disk/usb/0/0/raw`, by that path only.

**The probe** (`tools/pi-tests/bfsrm.sh`, driver `scripts/pi-bfsrm.sh IMG N LABEL`): one network boot per run; the
netboot disk is a fresh copy of the image, so every run is a first boot and the first-login `PostInstallScript`'s
`sync` runs. The probe is the UserBootscript: mkfs + mount of the stick, then 2 rounds of `bfsmeta 4000` and
`rm -rf` in the background (a hang detector: after 60 s, `kdl` and the driver types `bt`/`threads`/`bt` of the
notifiers; never needed). Overlap: a once-a-second sample of the first-login script's processes. On the Pi that
script lives from ~48.5 s to ~58.5 s after power-on, a `sync` at its end (devices in id order: /boot's slow network
disk, then the stick), and round 1's `rm` (3-9 s) falls inside that window in 39 of 41 runs (`PIS seen=1`); in 5 of the 20
unfixed runs `rm` took 8-9 s and ended with the first-login script, i.e. it was held up by the sync.

| | hung / runs |
|---|---|
| fixed 44cc183c0c, first boot, 2 rounds | **0 / 20** |
| unfixed afd7f0590c, first boot, 2 rounds | **0 / 20** |
| unfixed, no first boot: 40 rounds of `bfsmeta` + `rm -rf` with a `sync` loop beside (`tools/pi-tests/bfsrm-loop.sh`, one session) | 0 / 40 |

The two alternated series (alternating unfixed, fixed; `artifacts/bfsrm-pi/bfsrm.tsv`) ran 09:00-12:45; two rows in it
are NOBOOT: the other project's session held the bench for 2 h and the cycles' lock wait ended; the pair was run again.
So: **the hang did not reproduce on the Pi**. With the x86-64 rate of 24 % per first boot, 0 in 20 would have a chance
of 0.76^20 = 0.4 %; the Pi's rate is therefore lower (slower `rm` and I/O, a different order of events), or the Pi's first-boot sync does not hit
the window the notifier race needs (it flushes /boot, over the network, first; the scratch volume at the very end).
Whatever the reason, **the fix is not shown to be needed on arm64, and is shown not to hurt**: no hang, no debugger
entry, no panic, no user fault in any of the 41 probe boots, the session or the relcheck.

Regression checks on the fixed image: `tools/pi-tests/usb-bfs.sh` ×2 (the stick, 323 MB in 72 files): md5 after copy
and after remount the same, `checkfs` 0 blocks not allocated / already set / could be freed, both runs (`artifacts/bfsrm-pi/usb-bfs-fixed.txt`);
`scripts/release-check.sh` (relcheck): **REL result: 0 problems**, 24 launch cycles clean, 0 debugger entries.

Odd, not chased: `bfsmeta 4000` took 1.4-8 s in round 1 and 17-20 s in later rounds (the write-back of the USB disk after the first
boot's sync is over); in two fixed runs the wall clock jumped during round 1 (`date +%s` differences of 1.79·10^9; the system clock set
during boot), so those rm times are meaningless, the hang detector is not affected (it counts seconds in a loop).
The merge of `bfs-rmrf-hang` is thus justified by the x86-64 evidence and by the code (the hook is arch-neutral); the Pi shows no regression.
