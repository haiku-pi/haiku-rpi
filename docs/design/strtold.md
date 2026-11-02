# strtold(): long double that is really long double (libroot)

Found through numpy (`docs/design/numpy.md`): its longdouble tests (str round trip, dragon4 longdouble,
quantile with longdouble) failed on the Pi.

## What was wrong

- `src/system/libroot/posix/glibc/stdlib/strtold.c` was a 1999 glibc stub ("There is no `long double' type"):
  `strtold()` returned `__strtod_internal()`, a **double**, on every architecture. On arm64 and riscv64 long double
  is IEEE 754 binary128 (113-bit significand, exponent to ±16383), on x86/x86_64 the x87 80-bit format. So on the
  Pi `strtold("0.1")` had 53 significant bits, `strtold("1e4000")` was `inf` and `strtold("1e-4950")` was 0.
- `scanf("%Lf")` (`stdio-common/vfscanf.c`, `__ldbl_is_dbl` is 0) calls `__strtold_internal`: same defect.
- `wcstold()` (`wcsmbs/wcstold.c`) already built the real template with `FLOAT = long double`, but with the x87
  NaN-payload setter, which writes 32-bit values into binary128's 16-bit `mantissa0` field.
- `printf("%Lg")` was **not** affected: `printf_fp.c` uses `ldbl2mpn.c` (`arch/generic/ldbl-128` on arm64)
  and printed `1.0L/3` and `1 + LDBL_EPSILON` to all 36 digits before the fix too. It only looked wrong when
  fed by strtold().
- Shared by strtod/strtof/strtold and the wide versions (all one template, `stdlib/strtod.c`, glibc of 2001),
  found by the same test against current glibc: `"-0"` gave +0 and `"-nan"` a positive NaN; `"nan(...)"` left
  `*endptr` on the `)`; the float and double NaN-payload setters could clear the quiet bit
  (`strtod("nan(0x123)")` was a signalling NaN); and a value exactly half the smallest subnormal
  (`0x1p-1075`) rounded up instead of to even (0), because the round bit itself was counted as a lower bit;
  an underflow to zero returned +0 for a negative input (`strtod("-1e-400")`), and one of the three
  underflow paths set `EDOM` instead of `ERANGE`.

## The fix (sources/haiku, branch rpi4)

- `12eb998a63` libroot: implement strtold() for long double formats wider than double — `strtold.c` configures
  the strtod.c template the way glibc's `sysdeps/ieee754/ldbl-128/strtold_l.c` and `ldbl-96` do:
  `FLOAT long double`, `FLT LDBL`, `MPN2FLOAT __mpn_construct_long_double`, `FLOAT_HUGE_VAL HUGE_VALL`, and a
  `SET_MANTISSA` chosen by `LDBL_MANT_DIG` (113: binary128, 64: x87; anything else is an `#error`). Targets
  that define `__NO_LONG_DOUBLE_MATH` (arm, ppc, m68k: long double is double or unsupported) keep the old
  wrappers. `wcstold.c` is now `#define USE_WIDE_CHAR 1` + `#include <stdlib/strtold.c>` (as `wcstod.c` does
  with strtod.c), so the two share one configuration.
- `73ba44df00` libroot: strtod: sign of -0 and -nan, nan() end, subnormal ties — the four template fixes
  above, as in later glibc (`RETURN (negative ? -0.0 : 0.0, ...)`, `negative ? -retval : retval`, `++cp`
  past the `)`, the `shift == MANT_DIG` loop to `RETURN_LIMB_SIZE - 1`, payload setters through the
  `ieee_nan` view of the unions).
- `69c0374b42` libroot: strtod: ERANGE and a signed zero on underflow to zero.

What the template needed, checked: `fpioconst.c`'s power-of-ten table goes to 10^(2^12) when
`__NO_LONG_DOUBLE_MATH` is not defined, and `LDBL_MAX_10_EXP` is 4932 for both binary128 and x87
(floor(log2 4932) = 12 = `LDBL_MAX_10_EXP_LOG`); `RETURN_LIMB_SIZE` = howmany(113, 64) = 2, a case the
template's `#if RETURN_LIMB_SIZE <= 2` branches handle; arm64 and riscv64 have the binary128
`ieee854_long_double` union (`include/arch/{arm64,riscv64}/ieee754.h` → `generic/ldbl-128`) and build
`arch/generic/ldbl-128/{ldbl2mpn,mpn2ldbl}.c`; x86_64 and x86 have their own x87 `mpn2ldbl.c`.

Architectures: **arm64** (tested), **riscv64** (same headers and Jamfile sources as arm64), **x86_64 / x86**
(x87). There is no x86_64 Haiku cross compiler on this host, so the x87 branch is **not compiled for Haiku
here**; it is the configuration `wcstold.c` has compiled on x86_64 all along, minus `USE_WIDE_CHAR`. Its one
new piece, the `ieee_nan`-based payload setter, was checked on the (x87) host: the macro with Haiku's
`include/ieee754.h`, applied to `NAN`, gives the same 10 bytes as host glibc's `strtold("nan(0x…)")` for
payloads 0, 0x123, 0x3fffffff00000001 and all ones. arm (32-bit), ppc, m68k: unchanged — preprocessing
`strtold.c`/`wcstold.c` with `include/arch/arm` (which defines `__NO_LONG_DOUBLE_MATH`) selects the old
wrappers, and they pass `-fsyntax-only`.

## Test

`tools/haiku-tests/strtold.c` (221 checks): strtold of 49 inputs against bit patterns and `*endptr` offsets
generated from aarch64 glibc 2.43 (`strtold --gen` under `qemu-aarch64`; the 32 positive decimal ones also
checked independently with Python `fractions` round-to-nearest-even: 32 of 32 match), the same inputs through `wcstold()`
and `sscanf("%Lf")`/`"%Lg"`, 13 printf outputs (`%.36Lg`, `%.40Le`, `%Lf`, `%.33Lf`) against glibc's,
20000 pseudo-random finite binary128 values (1 in 16 subnormal) round-tripped through `%.36Lg` and through
`%La`, and strtod/strtof spot checks plus a 20000-value `%.17g` round trip. Whether errno is `ERANGE` after
an underflow is implementation-defined (C11 7.22.1.3): it must be 0 or `ERANGE`; after an overflow `ERANGE`.

Run without the Pi: QEMU virt (`scripts/qemu-virt.sh`) on `generated.arm64/haiku-mmc.image` with
`tools/pi-tests/strtold.sh` as UserBootscript and the test in `/boot/home` (`scripts/image-add.sh`); the
"after" image additionally has the rebuilt `haiku.hpkg` (`scripts/build.sh haiku.hpkg`) under the same file
name in `/boot/system/packages`. The same binary, the same boot:

| | before (rpi4 f0a1d5f5cf) | after (69c0374b42) |
|---|---|---|
| result | **99 failures** (231 checks) | **ok** (221 checks) |
| `strtold("0.1")` | `3ffb999999999999a000000000000000` (the double) | `3ffb999999999999999999999999999a` |
| `strtold("1.0000000000000000000000000000000002")` | 1 | 1 + 2^-112 |
| `strtold("1e4000")`, `("1e4932")`, `LDBL_MAX` | inf, `ERANGE` | finite, correctly rounded |
| `strtold("1e-4950")`, `("0x1p-16494")` (smallest subnormal) | 0 | `…057c9647e1a018`, `…0001` |
| `strtold("1e4933")` | inf, `ERANGE` | inf, `ERANGE` |
| `%.36Lg` → strtold round trip (20000 values) | 20000 differ | 0 differ |
| `%La` → strtold round trip (20000 values) | 20000 differ | 0 differ |
| `sscanf("%Lf")` | double precision | = strtold |
| `printf("%.36Lg", 1.0L/3)` | `0.333…333317` (already right) | same |
| `strtod("-0")`, `strtof("-0")` | +0 | -0 |
| `strtod("-nan")` | `7ff8000000000000` | `fff8000000000000` |
| `strtod("nan(0x123)")` | `7ff0000000000123` (signalling), end 9 | `7ff8000000000123`, end 10 |
| `strtod("0x1p-1075")`, `strtof("0x1p-150")` | smallest subnormal | 0 (tie to even) |
| `strtod("-1e-400")`, `strtold("-1e-5000")` | +0 | -0 |

(The check count differs because a failing round trip also prints its first five values as checks.)

Logs: `artifacts/qemu/20261102-143620-virt.log` (after) and `20261102-144123-virt.log` (before), serial
lines `STRTOLD ...`.

## Left

- Not run on x86_64 (no cross compiler here) or riscv64. The test itself is binary128-only (`#error` otherwise).
- `strtold_l`/`wcstold_l` (the `USE_IN_EXTENDED_LOCALE_MODEL` names) are not built in libroot, as before.
- Underflow errno: the template sets `ERANGE` when the result is 0, but not for a subnormal (or rounded-up
  `LDBL_MIN`) result, where current glibc sets it for every tiny inexact result. Allowed by C; not changed.
- With `group` set (`scanf("%'f")`), two grouping error paths still return +0 for "-0,000"-style input.
