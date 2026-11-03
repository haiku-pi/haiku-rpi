# gcc16-main-switch — 2026-11-03T01:14:43+01:00

| repo | branch | sha | dirty |
|---|---|---|---|
| coordination | main | 3cfabbe34caf682ee127bd4e6ab7d073739ab6ae | 0 |
| buildtools | master | fc2ad25b8bd846c4847d317b88279c6b26256eb5 | 8 |
| haiku | rpi4 | 38bc4de5d72ea20996751240f64593fb06a7c1a0 | 0 |
| haikuports | master | c17ec5a8d2f0a48b3dc2da9118ce11957cef6ba4 | 0 |
| libdrm | rpi4 | bd858a245ba94125d9d762752d14963a4f0678c9 | 0 |
| libglvnd | rpi4 | 7cc03c3236a1f0e8b88c08cff7467b5f692a222e | 0 |
| mesa | rpi4 | f64c84cae97c66fb945b02461f106c36eef56f3c | 0 |
| optimized-routines | master | 0b5e3775c6c04761a2ecda8218eb45958c28be02 | 0 |
| photocraft | main | 486afd82cce99255e999224bcfe28de00fd766aa | 0 |
| u-boot | main | 8d534cec0cc0109a37c0ded8854da03f1526dc0e | 5 |

Cross tools: `sources/haiku/generated.arm64/cross-tools-arm64` = GCC 16.2.0 + binutils 2.46.1, configured with
`--build-cross-tools arm64 --cross-tools-source /home/houp/haiku-rpi-gcc16/sources/buildtools -j12`: buildtools
branch **gcc16 c2213226f9ec81db54b2fdf9a2913abbdc80414a** (the parallel tree's worktree;
`sources/buildtools` above is still on master, the 13.3 source, tag gcc13-baseline). The 13.3 tools:
`cross-tools-arm64-gcc13`. gcc_syslibs / gcc_syslibs_devel 16.2.0_2026_11_01-1 in `generated.arm64/download/`;
13.3's in `artifacts/gcc-syslibs/13.3/`. See docs/design/gcc16.md "Main build switched".
