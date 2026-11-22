# MediaPlayer crashes opening a URL (KNOWN-ISSUES C16, MP3)

Status: **fixed on branch `mp3-url-crash`** of haiku-pi/haiku (from `rpi4` 519adfacb3), **not merged**.
Two commits, pushed: 2d4241482f (BUrl, support kit, libbe) and fb3d9ac1bd (MediaPlayer's Controller). Numbers are
**measured** unless marked. Pi: 15 of 114 URL opens crashed before the fix, 0 of 120 after; the seek or Play after a
failed open crashed 5 of 5 before, 0 of 9 after.

## 0. Answer in one screen

| Crash | Cause | Fix |
|---|---|---|
| Debugger entry (`double free`, `bogus pointer`) in ~1 of 8 URL opens (15 of 114), under `BUrl::UrlString()` ← `UrlPlaylistItem::GetAttribute()` | `BUrl::UrlString()`, `Authority()` and `UserInfo()` are `const` but build their strings lazily into `mutable` members. MediaPlayer's **two window threads** (main window: the playlist menu; playlist window: the list view) both handle the same "item added" notification and ask the new item for its name at the same time; both append to the same `BString`, both `realloc()` its buffer. The controller thread copies the same `BUrl` meanwhile (`BMediaFile(fUrl)` → `MediaStreamer`). | libbe: the three strings are built by every **modifier** (`_UpdateStrings()`); the const accessors only read. A `BUrl` is now safe to read from several threads, like a `BString`. |
| Segment violation in `PlaybackManager::PlaylistFrameAtFrame()` on a seek after the first file failed to open | The playback manager has no playing state until `NodeManager::Init()`, which only the first file that opens calls. `Controller::SetFramePosition()` (every seek: `set Position`, `Seek`, the seek keys) and `Play()` did not check `InitCheck()`, while `Stop()` and `TogglePlaying()` do. | MediaPlayer: check `InitCheck()` in `SetFramePosition()` and `Play()` (`Play()` still sets autoplay for the next file). |

## 1. The URL-open crash

### 1.1 Evidence from the code

- Every WP4 stack (`artifacts/wp4/syslog-wp4.txt`, 5 double frees and 1 bogus pointer) dies **inside the string build**:
  `realloc` ← `BString::_Resize` ← `_MakeWritable` ← `_DoAppend` ← `operator<<` ← `BUrl::UrlString() + 0xdc`. The append
  branch only runs while `fUrlStringValid` is false, i.e. on the **first** `UrlString()` of that `BUrl`:
  `UrlPlaylistItem` never changes its `fUrl`, and `BUrl(BMessage*)` (how `Playlist::AppendItems()` makes the URL) ends in
  `_ResetFields()`, which clears the flag; the copy into the item keeps it clear. One thread appending to its own string
  cannot double-free; a second writer to the same `BString` can.
- The threads: `Playlist::_NotifyItemAdded()` posts `MSG_PLAYLIST_ITEM_ADDED` with the raw item pointer to each listener's
  looper. Two listeners are windows with their own threads — `MainWin` (`_AddPlaylistItem()` → `item->Name()` for the
  menu item) and `PlaylistWindow` (created hidden in the `MainWin` constructor; `PlaylistListView::_AddItem()` →
  `Item::Item()` → `item->Name()`). The WP4 stacks show **both** as the crashing thread (2 × `MainWin`, 3 ×
  `PlaylistListView`). No lock is common to them. The third reader is the `Controller` looper: `SetToAsync()` →
  `SetTo()` → `GetTrackSupplier()` → `new BMediaFile(fUrl)` → `MediaStreamer(url)` copy-constructs the `BUrl`, reading
  `fUrlStringValid` and `fUrlString` while a window thread rebuilds them — that explains the one `bogus pointer` in
  `~BUrl` at quit (the heap was already corrupt).
- So it is **not** the window-versus-loader pair first suspected: the main pair is two window threads, with the loader
  (controller) as a third reader.
- The two flags also share a byte with the `fHas*` bitfields, so even `fUrlStringValid = true` is a read-modify-write
  that races with other flag writes.

### 1.2 Host reproduction (no Pi)

The host build of libbe (`generated.arm64/objects/linux/lib/libbe_build.so`) contains `Url.cpp` and `String.cpp`, so the
race reproduces on the Linux host. `urlrace N THREADS` (`tools/host-burl/`, `run.sh TREE` builds and runs it): THREADS threads wait at
a barrier, then read one fresh `BUrl("http://user:pw@10.42.0.1:8080/…?a=1#t")` at once — `UrlString()`, `Authority()` +
`UserInfo()`, or a copy — N times; the test's own `Url.cpp` object is linked ahead of `libbe_build.so`.

| `Url.cpp` | 1 thread | 2 threads | 3 threads |
|---|---|---|---|
| stock (rpi4) | 3 × 200 000 rounds, 0 wrong | **3 of 3 runs abort** (glibc: `realloc(): invalid old size`, `malloc(): unaligned tcache chunk detected`) | **3 of 3 abort** |
| fixed | 3 × 200 000, 0 wrong | 3 × 200 000, 0 wrong | 3 × 200 000, 0 wrong |

### 1.3 The fix (libbe, `src/kits/support/Url.cpp`)

- New private `_UpdateStrings()` builds `fUserInfo`, `fAuthority` and `fUrlString` from the fields, with the same code
  the getters had. Every modifier calls it: `SetProtocol/UserName/Password/Host/Port/Request/Fragment`,
  `_SetPathUnsafe()` (so `SetPath()`), `SetAuthority()`, `_ResetFields()`, `_ExplodeUrlString()` (so `SetUrlString()`,
  the constructors, `operator=`), `IDNAToAscii/Unicode()`, the deprecated `UrlEncode/Decode(bool)`. The copy
  constructor and `operator=` copy the three strings. `UrlString()`, `Authority()`, `UserInfo()` and `operator==` only read.
- `_ExplodeUrlString()` and `SetAuthority()` parse a **copy** of their argument (a `BString` copy shares the buffer):
  the argument may be the object's own `UrlString()`/`Authority()`, which the modifiers now rebuild mid-parse
  (`url.SetUrlString(url.UrlString())`).
- The three `mutable bool f…Valid : 1` flags and the `mutable` keywords go. **ABI:** `sizeof(BUrl)` is unchanged (the
  bitfields stay within the same trailing bytes) and no accessor is inline, so binaries built against the old header
  keep working; only private members moved. One new private non-virtual method.
- Cost: a few small string appends per modifier (a parse calls ~6 modifiers) instead of one lazy build; nothing in the
  measurements below showed it.
- Behaviour: identical output on Haiku's own `UrlTest` (581 checks on the host with a small CppUnit shim: stock and fixed
  print the same; only the 10 `IDNTest` checks fail on both, as the host build has no ICU) and on a 144-line field dump
  (13 URLs × parse, copy, assign, self-`SetUrlString`, self-`SetAuthority`, setter chains, two relative resolutions),
  except one intended difference: `SetAuthority("")` on a URL whose string had **already** been built kept the stale
  string (`mailto:a@b.c`) while the same call before the first `UrlString()` gave `mailto://a@b.c`; now always the
  latter. `IDNAToAscii()`/`IDNAToUnicode()` likewise left a built string stale.

Alternatives not taken: a lock (no room in the object without changing `sizeof(BUrl)`, which apps embed by value;
a global lock in every getter costs every reader); building into a local and assigning (the `BString` assignment is
itself not atomic, and readers hold a reference to the member); priming the cache in `UrlPlaylistItem`'s constructors
(fixes MediaPlayer only; every other program sharing a `BUrl` between threads keeps the bug).

## 2. The seek after a failed open

`Controller::SetTo()` calls `NodeManager::Init()` → `PlaybackManager::Init()` (which pushes the first `PlayingState`)
only after a file opened; until then `fStates` is empty, and `_StateAtFrame()`/`_LastState()` return NULL.
`SetFramePosition()` → `CurrentFrame()` → `PlaylistFrameAtFrame()` dereferenced it (WP4: `+0x20`, `state->activation_frame`);
`Play()` → `StartPlaying()` → `SetPlayMode()` copies `*_LastState()`. Entry points: `set Position` and `set Seek`
(scripting), the seek keys and the position slider (`_Wind()`, `SetTimePosition()`), `do Play`, the Play menu item.
`Stop()` and `TogglePlaying()` already checked `InitCheck()`; `Pause()` is safe (`PlayMode()` handles no state). A
later failed file after a good one is not affected (the states stay).

## 3. Pi results (network sessions `mp3` 12:44–12:48, 12:49–13:21, 13:23–13:36 on 2026-11-22; the card untouched)

Image: `sources/haiku-mp3/generated.arm64/haiku-pi4-regular.img` (jam `@pi-mmc` with `HAIKU_PI_GL=1`, from the branch on
`rpi4` 519adfacb3; its `libbe.so` and `MediaPlayer` are the fixed ones, md5 6bdb3b13… / d97febbf…). The baseline
(stock) is the same tree's `libbe.so` and `MediaPlayer` built from 519adfacb3's sources. They are **byte-identical to
the main tree's rpi4 build** (ee555f7b… / 55dcbe0a…), copied to `/boot/home/mp3/stock` and run with `APP=` /
`LIB=` (`LIBRARY_PATH` first); `listimage` shows which `libbe.so` was loaded. The URL is a **404 on the host's
`wp4-httpd.py`**. The crash comes before any request, and a 404 decodes nothing, which keeps the VideoCore out of
it (below).

| `wp4-mpopen.sh` (start, 4 s, kill), same session | opens | debugger entries |
|---|---|---|
| stock MediaPlayer + stock libbe (S2, S3: before and after the fixed blocks) | 40 + 30 | **5 + 4** (every one `double free` under `BUrl::UrlString()` + 0xdc) |
| stock MediaPlayer + **fixed libbe** (F1) | 50 | **0** |
| fixed MediaPlayer + fixed libbe, the image's own (F2) | 50 | **0** |
| fixed, a real clip `play-720p30-15s.mp4` over http, `FFMPEG_H264_MMAL=0` (F3) | 20 | **0** |

The baseline rate is 9 of 70 (13 %); with WP4's 6 of 44, 15 of 114. With the fix, 0 of 120. At a rate of 1 in 8, 120
clean opens happen by chance with probability (7/8)^120 ≈ 1e-7. F1 shows that libbe alone fixes it; MediaPlayer needs
no change for this crash.

Seek after a failed open (`tools/pi-tests/mp3-failseek.sh MODE URL`, 404 URL, one scripted command after 6 s):

| | `set Position` 20 s | `set Seek` +5 s | `do Play` | all (seek, Seek, Play, Pause, Stop, seek) |
|---|---|---|---|---|
| stock | **crash** 1/1 (`PlaylistFrameAtFrame` + 0x20, WP4's stack) | no crash 0/1 | **crash** 4/4 (`SetPlayMode` + 0x30 ← `Controller::Play`) | — |
| fixed | 0 of 3 | 0 of 1 | 0 of 3 | 0 of 2 |

`set Seek` goes through `MainWin::_Wind()`, which does not reach `CurrentFrame()` without video (`fHasVideo`).

- **Pre-existing, not changed:** on a URL that does not open, MediaPlayer's window answers scripting only now and
  then, with the stock binaries too. `get Position` every 4 s for 2 minutes, with no other command: answered once
  (`A-stock-noplay`). So `hey` calls time out, and the script's last "does it answer" probe failed in the fixed
  `play`/`all` runs. The team was alive, there was no debugger entry, and a later `get Position` was answered
  (checked by hand). The likely cause is the Controller lock, which `SetTo()` holds while the media kit opens the
  URL; this was not examined further.
- **No regression:** the fixed image played and sought a local H.264 file (`wp4-mp.sh seek`: 40 → 42.67, 3 → 5.63,
  paused 20 → 19.47, play → 22.40, quit in 1 s, h264_mmal) and the same file over http (identical numbers), with 0
  problems and 0 debugger entries.
- **Two kernel PANICs, not caused by MP3 (handed to the main session):** `unlock_memory_etc(): Failed to unwire page`
  in `VCHIQ-0` (`vchiq_complete_bulk` → `vchiq_haiku_buffer_unlock`), each ~0.2 s after a **new** MediaPlayer's H.264
  decoder started on the VideoCore, ~1.2 s after the previous decoding MediaPlayer ended.
  - #1, uptime 121.6 s, at the 10th of a stock `wp4-mpopen.sh` run on a real H.264 clip: the previous team had been
    killed with `kill -9`.
  - #2, uptime 1921.4 s, at `wp4-mp.sh seek` on http right after the same on a local file: the previous team had
    quit cleanly through `hey quit`.
  - Logs: `artifacts/mp3/uart-session-mp3-{1,2}-panic.log`. No PANIC in the 210 opens of the 404 URL (no decoding),
    nor in session 3.

Host tools: `tools/host-burl/run.sh TREE` (§1.2–1.3). Pi tools: `tools/pi-tests/wp4-mpopen.sh` (now `APP=`, and it
prints the libraries loaded), `tools/pi-tests/mp3-failseek.sh`. Runs: `artifacts/mp3/runs/`.

## 4. Not checked

- WebPositive and other `BUrl` users with the new libbe. WebKit uses `BUrl` in its network layer. The host
  `UrlTest` and the field dump give the same results, but no browser session ran on this libbe.
- The cost of building the strings eagerly was not measured. It is a few appends per modifier.
- The Controller-lock stall on a URL that does not open (above).
- Opening a URL from the GUI (Open URL dialog) rather than from the command line. It takes the same
  `Playlist::AppendItems()` path, but that was not run.
