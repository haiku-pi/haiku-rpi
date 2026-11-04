/*
 * strtold.c — long double conversions of libroot: strtold(), wcstold(), sscanf("%Lf"/"%Lg") and
 * printf("%Lg"/"%Le"/"%Lf") against expected values taken from glibc (the tables below), for
 * IEEE 754 binary128 long double (arm64, riscv64) and for the x87 80-bit extended format (x86_64:
 * 10 value bytes in a 16-byte long double, the 6 padding bytes masked off); plus a round trip
 * printf("%.36Lg") (x87: "%.21Lg") -> strtold() and printf("%La") -> strtold() of 20000
 * pseudo-random finite values (normal and subnormal), and strtod()/strtof() spot checks with their
 * own round trip.
 *
 *   strtold [-v]       prints "strtold: ok (N checks)" or one "strtold: FAIL ..." line per failure
 *                      and "strtold: N failures"; exit 0 when ok. -v: every case.
 *   strtold --gen      prints the expected-value table rows from this libc (generate on a reference:
 *                      aarch64 Linux glibc, e.g. under qemu-aarch64 -L /usr/aarch64-linux-gnu, for
 *                      binary128; x86_64 Linux glibc for x87)
 *
 * Whether errno is ERANGE after an underflow is implementation-defined (C11 7.22.1.3): it must be 0 or
 * ERANGE; after an overflow it must be ERANGE.
 *
 * Build: aarch64-unknown-haiku-gcc --sysroot=artifacts/sysroot-arm64 -O2 -o strtold strtold.c
 *        aarch64-linux-gnu-gcc -O2 -static -o strtold-linux strtold.c    (the reference)
 *        x86_64-unknown-haiku-gcc --sysroot=artifacts/sysroot-x86_64 -O2 -o strtold strtold.c
 *        gcc -O2 -o strtold-linux strtold.c                              (x87 reference, x86_64 host)
 */
#include <errno.h>
#include <float.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#if LDBL_MANT_DIG == 113
	/* binary128: hi = sign, 15-bit exponent, top 48 fraction bits; lo = low 64 fraction bits */
#	define LD_HI_MASK 0xffffffffffffffffULL
#	define LD_DIG "36"		/* decimal digits that round-trip every value */
#elif LDBL_MANT_DIG == 64
	/* x87: lo = the 64-bit significand with its explicit integer bit; hi = sign and 15-bit exponent
	   in the low 16 bits, the rest is padding */
#	define LD_HI_MASK 0xffffULL
#	define LD_DIG "21"
#else
#	error "this test expects binary128 or x87 extended long double"
#endif

static int sFailures, sChecks, sVerbose;

typedef struct {
	uint64_t hi, lo;
} bits128;

static bits128
ld_bits(long double x)
{
	bits128 b;
	uint64_t w[2];
	memcpy(w, &x, sizeof(w));
	b.lo = w[0];
	b.hi = w[1] & LD_HI_MASK;
	return b;
}

static long double
ld_from_bits(uint64_t hi, uint64_t lo)
{
	uint64_t w[2] = { lo, hi };
	long double x;
	memcpy(&x, w, sizeof(x));
	return x;
}

static void
check(int ok, const char *what, const char *fmt, ...)
	__attribute__((format(printf, 3, 4)));

#include <stdarg.h>

static void
check(int ok, const char *what, const char *fmt, ...)
{
	va_list ap;
	sChecks++;
	if (ok && !sVerbose)
		return;
	if (!ok)
		sFailures++;
	printf("strtold: %s %s: ", ok ? "ok" : "FAIL", what);
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	printf("\n");
}

enum { E_NONE = 0, E_RANGE = 1, E_UNDERFLOW = 2 };

struct strtold_case {
	const char *input;
	uint64_t hi, lo;	/* the result's bits */
	int end;			/* *endptr - input */
	int err;			/* E_RANGE: errno must be ERANGE; E_UNDERFLOW: report errno */
};

#if LDBL_MANT_DIG == 113
/* Expected values: generated with "strtold --gen" from aarch64 glibc 2.43. */
static const struct strtold_case kCases[] = {
	{ "1.2", 0x3fff333333333333ULL, 0x3333333333333333ULL, 3, E_NONE },
	{ "1.0000000000000000000000000000000002", 0x3fff000000000000ULL, 0x0000000000000001ULL, 36, E_NONE },
	{ "1.0000000000000000000000000000000001", 0x3fff000000000000ULL, 0x0000000000000001ULL, 36, E_NONE },
	{ "0.1", 0x3ffb999999999999ULL, 0x999999999999999aULL, 3, E_NONE },
	{ "-0.1", 0xbffb999999999999ULL, 0x999999999999999aULL, 4, E_NONE },
	{ "3.141592653589793238462643383279502884197", 0x4000921fb54442d1ULL, 0x8469898cc51701b8ULL, 41, E_NONE },
	{ "2.718281828459045235360287471352662497757", 0x40005bf0a8b14576ULL, 0x95355fb8ac404e7aULL, 41, E_NONE },
	{ "123456789012345678901234567890123456789", 0x407d7383a6958057ULL, 0xfb16ab7e8ca2b8e6ULL, 39, E_NONE },
	{ "1e4000", 0x73e6a3750647fcabULL, 0x18c21ab905450cc3ULL, 6, E_NONE },
	{ "-1e4000", 0xf3e6a3750647fcabULL, 0x18c21ab905450cc3ULL, 7, E_NONE },
	{ "1e-4950", 0x0000000000000000ULL, 0x00057c9647e1a018ULL, 7, E_UNDERFLOW },
	{ "1e4932", 0x7ffeae596552b8fdULL, 0xed99d037e3d04b75ULL, 6, E_NONE },
	{ "1e4933", 0x7fff000000000000ULL, 0x0000000000000000ULL, 6, E_RANGE },
	{ "-1e5000", 0xffff000000000000ULL, 0x0000000000000000ULL, 7, E_RANGE },
	{ "1e-5000", 0x0000000000000000ULL, 0x0000000000000000ULL, 7, E_UNDERFLOW },
	{ "1e-4966", 0x0000000000000000ULL, 0x0000000000000000ULL, 7, E_UNDERFLOW },
	{ "-1e-4966", 0x8000000000000000ULL, 0x0000000000000000ULL, 8, E_UNDERFLOW },
	{ "-1e-5000", 0x8000000000000000ULL, 0x0000000000000000ULL, 8, E_UNDERFLOW },
	{ "-0x1p-16495", 0x8000000000000000ULL, 0x0000000000000000ULL, 11, E_UNDERFLOW },
	{ "4e-4966", 0x0000000000000000ULL, 0x0000000000000001ULL, 7, E_UNDERFLOW },
	{ "6.475175119438025110924438958227646552e-4966", 0x0000000000000000ULL, 0x0000000000000001ULL, 44, E_UNDERFLOW },
	{ "3.3621031431120935062626778173217526e-4932", 0x0001000000000000ULL, 0x0000000000000000ULL, 42, E_UNDERFLOW },
	{ "1.18973149535723176508575932662800702e4932", 0x7ffeffffffffffffULL, 0xffffffffffffffffULL, 42, E_NONE },
	{ "1.18973149535723176508575932662800703e4932", 0x7ffeffffffffffffULL, 0xffffffffffffffffULL, 42, E_NONE },
	{ "inf", 0x7fff000000000000ULL, 0x0000000000000000ULL, 3, E_NONE },
	{ "-Infinity", 0xffff000000000000ULL, 0x0000000000000000ULL, 9, E_NONE },
	{ "nan", 0x7fff800000000000ULL, 0x0000000000000000ULL, 3, E_NONE },
	{ "-nan", 0xffff800000000000ULL, 0x0000000000000000ULL, 4, E_NONE },
	{ "nan(0x123)", 0x7fff800000000000ULL, 0x0000000000000123ULL, 10, E_NONE },
	{ "0x1.8p1", 0x4000800000000000ULL, 0x0000000000000000ULL, 7, E_NONE },
	{ "0x1p-16494", 0x0000000000000000ULL, 0x0000000000000001ULL, 10, E_UNDERFLOW },
	{ "0x1p-16495", 0x0000000000000000ULL, 0x0000000000000000ULL, 10, E_UNDERFLOW },
	{ "0x1.ffffffffffffffffffffffffffffp16383", 0x7ffeffffffffffffULL, 0xffffffffffffffffULL, 38, E_NONE },
	{ "0x1.ffffffffffffffffffffffffffff8p0", 0x4000000000000000ULL, 0x0000000000000000ULL, 35, E_NONE },
	{ "0x1.ffffffffffffffffffffffffffff7p0", 0x3fffffffffffffffULL, 0xffffffffffffffffULL, 35, E_NONE },
	{ "0x1.0000000000000000000000000000ep0", 0x3fff000000000000ULL, 0x0000000000000001ULL, 35, E_NONE },
	{ "  +12.5e-1xyz", 0x3fff400000000000ULL, 0x0000000000000000ULL, 10, E_NONE },
	{ "1e", 0x3fff000000000000ULL, 0x0000000000000000ULL, 1, E_NONE },
	{ "0x", 0x0000000000000000ULL, 0x0000000000000000ULL, 1, E_NONE },
	{ ".5", 0x3ffe000000000000ULL, 0x0000000000000000ULL, 2, E_NONE },
	{ "-.5e+2,", 0xc004900000000000ULL, 0x0000000000000000ULL, 6, E_NONE },
	{ "abc", 0x0000000000000000ULL, 0x0000000000000000ULL, 0, E_NONE },
	{ "0", 0x0000000000000000ULL, 0x0000000000000000ULL, 1, E_NONE },
	{ "-0", 0x8000000000000000ULL, 0x0000000000000000ULL, 2, E_NONE },
	{ "1e-400", 0x3ace2bfcfc0f923dULL, 0xf5f4726370a1be12ULL, 6, E_NONE },
	{ "1e400", 0x452fb4ec7f91973fULL, 0xf3cb1ccf26fbc178ULL, 5, E_NONE },
	{ "0.30000000000000000000000000000000001", 0x3ffd333333333333ULL, 0x3333333333333333ULL, 37, E_NONE },
	{ "9007199254740993", 0x4034000000000000ULL, 0x0800000000000000ULL, 16, E_NONE },
	{ "10384593717069655257060992658440193", 0x4070000000000000ULL, 0x0000000000000000ULL, 35, E_NONE },
};
#else
/* Expected values: generated with "strtold --gen" from x86_64 glibc 2.43. */
static const struct strtold_case kCases[] = {
	{ "1.2", 0x0000000000003fffULL, 0x999999999999999aULL, 3, E_NONE },
	{ "1.0000000000000000000000000000000002", 0x0000000000003fffULL, 0x8000000000000000ULL, 36, E_NONE },
	{ "1.0000000000000000000000000000000001", 0x0000000000003fffULL, 0x8000000000000000ULL, 36, E_NONE },
	{ "0.1", 0x0000000000003ffbULL, 0xcccccccccccccccdULL, 3, E_NONE },
	{ "-0.1", 0x000000000000bffbULL, 0xcccccccccccccccdULL, 4, E_NONE },
	{ "3.141592653589793238462643383279502884197", 0x0000000000004000ULL, 0xc90fdaa22168c235ULL, 41, E_NONE },
	{ "2.718281828459045235360287471352662497757", 0x0000000000004000ULL, 0xadf85458a2bb4a9bULL, 41, E_NONE },
	{ "123456789012345678901234567890123456789", 0x000000000000407dULL, 0xb9c1d34ac02bfd8bULL, 39, E_NONE },
	{ "1e4000", 0x00000000000073e6ULL, 0xd1ba8323fe558c61ULL, 6, E_NONE },
	{ "-1e4000", 0x000000000000f3e6ULL, 0xd1ba8323fe558c61ULL, 7, E_NONE },
	{ "1e-4950", 0x0000000000000000ULL, 0x0000000000000003ULL, 7, E_UNDERFLOW },
	{ "1e4932", 0x0000000000007ffeULL, 0xd72cb2a95c7ef6cdULL, 6, E_NONE },
	{ "1e4933", 0x0000000000007fffULL, 0x8000000000000000ULL, 6, E_RANGE },
	{ "-1e5000", 0x000000000000ffffULL, 0x8000000000000000ULL, 7, E_RANGE },
	{ "1e-5000", 0x0000000000000000ULL, 0x0000000000000000ULL, 7, E_UNDERFLOW },
	{ "1e-4966", 0x0000000000000000ULL, 0x0000000000000000ULL, 7, E_UNDERFLOW },
	{ "-1e-4966", 0x0000000000008000ULL, 0x0000000000000000ULL, 8, E_UNDERFLOW },
	{ "-1e-5000", 0x0000000000008000ULL, 0x0000000000000000ULL, 8, E_UNDERFLOW },
	{ "-0x1p-16495", 0x0000000000008000ULL, 0x0000000000000000ULL, 11, E_UNDERFLOW },
	{ "4e-4966", 0x0000000000000000ULL, 0x0000000000000000ULL, 7, E_UNDERFLOW },
	{ "6.475175119438025110924438958227646552e-4966", 0x0000000000000000ULL, 0x0000000000000000ULL, 44, E_UNDERFLOW },
	{ "3.3621031431120935062626778173217526e-4932", 0x0000000000000001ULL, 0x8000000000000000ULL, 42, E_NONE },
	{ "1.18973149535723176508575932662800702e4932", 0x0000000000007fffULL, 0x8000000000000000ULL, 42, E_RANGE },
	{ "1.18973149535723176508575932662800703e4932", 0x0000000000007fffULL, 0x8000000000000000ULL, 42, E_RANGE },
	{ "inf", 0x0000000000007fffULL, 0x8000000000000000ULL, 3, E_NONE },
	{ "-Infinity", 0x000000000000ffffULL, 0x8000000000000000ULL, 9, E_NONE },
	{ "nan", 0x0000000000007fffULL, 0xc000000000000000ULL, 3, E_NONE },
	{ "-nan", 0x000000000000ffffULL, 0xc000000000000000ULL, 4, E_NONE },
	{ "nan(0x123)", 0x0000000000007fffULL, 0xc000000000000123ULL, 10, E_NONE },
	{ "0x1.8p1", 0x0000000000004000ULL, 0xc000000000000000ULL, 7, E_NONE },
	{ "0x1p-16494", 0x0000000000000000ULL, 0x0000000000000000ULL, 10, E_UNDERFLOW },
	{ "0x1p-16495", 0x0000000000000000ULL, 0x0000000000000000ULL, 10, E_UNDERFLOW },
	{ "0x1.ffffffffffffffffffffffffffffp16383", 0x0000000000007fffULL, 0x8000000000000000ULL, 38, E_RANGE },
	{ "0x1.ffffffffffffffffffffffffffff8p0", 0x0000000000004000ULL, 0x8000000000000000ULL, 35, E_NONE },
	{ "0x1.ffffffffffffffffffffffffffff7p0", 0x0000000000004000ULL, 0x8000000000000000ULL, 35, E_NONE },
	{ "0x1.0000000000000000000000000000ep0", 0x0000000000003fffULL, 0x8000000000000000ULL, 35, E_NONE },
	{ "  +12.5e-1xyz", 0x0000000000003fffULL, 0xa000000000000000ULL, 10, E_NONE },
	{ "1e", 0x0000000000003fffULL, 0x8000000000000000ULL, 1, E_NONE },
	{ "0x", 0x0000000000000000ULL, 0x0000000000000000ULL, 1, E_NONE },
	{ ".5", 0x0000000000003ffeULL, 0x8000000000000000ULL, 2, E_NONE },
	{ "-.5e+2,", 0x000000000000c004ULL, 0xc800000000000000ULL, 6, E_NONE },
	{ "abc", 0x0000000000000000ULL, 0x0000000000000000ULL, 0, E_NONE },
	{ "0", 0x0000000000000000ULL, 0x0000000000000000ULL, 1, E_NONE },
	{ "-0", 0x0000000000008000ULL, 0x0000000000000000ULL, 2, E_NONE },
	{ "1e-400", 0x0000000000003aceULL, 0x95fe7e07c91efafaULL, 6, E_NONE },
	{ "1e400", 0x000000000000452fULL, 0xda763fc8cb9ff9e6ULL, 5, E_NONE },
	{ "0.30000000000000000000000000000000001", 0x0000000000003ffdULL, 0x999999999999999aULL, 37, E_NONE },
	{ "9007199254740993", 0x0000000000004034ULL, 0x8000000000000400ULL, 16, E_NONE },
	{ "10384593717069655257060992658440193", 0x0000000000004070ULL, 0x8000000000000000ULL, 35, E_NONE },
	{ "0x1p-16445", 0x0000000000000000ULL, 0x0000000000000001ULL, 10, E_UNDERFLOW },
	{ "0x1p-16446", 0x0000000000000000ULL, 0x0000000000000000ULL, 10, E_UNDERFLOW },
	{ "0x1.8p-16446", 0x0000000000000000ULL, 0x0000000000000001ULL, 12, E_UNDERFLOW },
	{ "3.64519953188247460253e-4951", 0x0000000000000000ULL, 0x0000000000000001ULL, 28, E_UNDERFLOW },
	{ "3.36210314311209350626e-4932", 0x0000000000000001ULL, 0x8000000000000000ULL, 28, E_NONE },
	{ "1.18973149535723176502e4932", 0x0000000000007ffeULL, 0xffffffffffffffffULL, 27, E_NONE },
	{ "1.18973149535723176508e4932", 0x0000000000007fffULL, 0x8000000000000000ULL, 27, E_RANGE },
	{ "0x1.fffffffffffffffep16383", 0x0000000000007ffeULL, 0xffffffffffffffffULL, 26, E_NONE },
	{ "0x1.fffffffffffffffep0", 0x0000000000003fffULL, 0xffffffffffffffffULL, 22, E_NONE },
	{ "0x1.ffffffffffffffffp0", 0x0000000000004000ULL, 0x8000000000000000ULL, 22, E_NONE },
	{ "0x1.fffffffffffffffe8p0", 0x0000000000003fffULL, 0xffffffffffffffffULL, 23, E_NONE },
	{ "1.0000000000000000001", 0x0000000000003fffULL, 0x8000000000000001ULL, 21, E_NONE },
	{ "18446744073709551617", 0x000000000000403fULL, 0x8000000000000000ULL, 20, E_NONE },
};
#endif

static const char *const kInputs[] = {
	"1.2",
	"1.0000000000000000000000000000000002",
	"1.0000000000000000000000000000000001",
	"0.1",
	"-0.1",
	"3.141592653589793238462643383279502884197",
	"2.718281828459045235360287471352662497757",
	"123456789012345678901234567890123456789",
	"1e4000",
	"-1e4000",
	"1e-4950",
	"1e4932",
	"1e4933",
	"-1e5000",
	"1e-5000",
	"1e-4966",
	"-1e-4966",
	"-1e-5000",
	"-0x1p-16495",
	"4e-4966",
	"6.475175119438025110924438958227646552e-4966",
	"3.3621031431120935062626778173217526e-4932",
	"1.18973149535723176508575932662800702e4932",
	"1.18973149535723176508575932662800703e4932",
	"inf",
	"-Infinity",
	"nan",
	"-nan",
	"nan(0x123)",
	"0x1.8p1",
	"0x1p-16494",
	"0x1p-16495",
	"0x1.ffffffffffffffffffffffffffffp16383",
	"0x1.ffffffffffffffffffffffffffff8p0",
	"0x1.ffffffffffffffffffffffffffff7p0",
	"0x1.0000000000000000000000000000ep0",
	"  +12.5e-1xyz",
	"1e",
	"0x",
	".5",
	"-.5e+2,",
	"abc",
	"0",
	"-0",
	"1e-400",
	"1e400",
	"0.30000000000000000000000000000000001",
	"9007199254740993",
	"10384593717069655257060992658440193",
#if LDBL_MANT_DIG == 64
	/* the x87 format's own limits and rounding */
	"0x1p-16445",
	"0x1p-16446",
	"0x1.8p-16446",
	"3.64519953188247460253e-4951",
	"3.36210314311209350626e-4932",
	"1.18973149535723176502e4932",
	"1.18973149535723176508e4932",
	"0x1.fffffffffffffffep16383",
	"0x1.fffffffffffffffep0",
	"0x1.ffffffffffffffffp0",
	"0x1.fffffffffffffffe8p0",
	"1.0000000000000000001",
	"18446744073709551617",
#endif
};

static void gen_printf(void);

static void
gen(void)
{
	for (size_t i = 0; i < sizeof(kInputs) / sizeof(kInputs[0]); i++) {
		char *end;
		errno = 0;
		long double v = strtold(kInputs[i], &end);
		int e = errno;
		bits128 b = ld_bits(v);
		const char *err = "E_NONE";
		if (e == ERANGE)
			err = (fabsl(v) == HUGE_VALL) ? "E_RANGE" : "E_UNDERFLOW";
		else if (fabsl(v) < LDBL_MIN && v != 0)
			err = "E_UNDERFLOW";
		else if (v == 0 && end != kInputs[i] && strpbrk(kInputs[i], "123456789") != NULL)
			err = "E_UNDERFLOW";
		printf("\t{ \"%s\", 0x%016llxULL, 0x%016llxULL, %d, %s },\n", kInputs[i],
			(unsigned long long)b.hi, (unsigned long long)b.lo, (int)(end - kInputs[i]), err);
	}
	gen_printf();
}

struct printf_case {
	const char *format;
	const char *input;	/* through strtold() */
	const char *output;
};

#if LDBL_MANT_DIG == 113
/* Expected printf output: generated from aarch64 glibc. */
#	define LD_THIRD "0.333333333333333333333333333333333317"
#	define LD_ONE_EPS "1.00000000000000000000000000000000019"
static const struct printf_case kPrintfCases[] = {
	{ "%.36Lg", "0.1", "0.100000000000000000000000000000000005" },
	{ "%.36Lg", "1.2", "1.19999999999999999999999999999999996" },
	{ "%.40Le", "3.141592653589793238462643383279502884197",
		"3.1415926535897932384626433832795027974791e+00" },
	{ "%Lf", "1e30", "1000000000000000000000000000000.000000" },
	{ "%.36Lg", "1e4000", "1.00000000000000000000000000000000004e+4000" },
	{ "%.36Lg", "0x1p-16494", "6.47517511943802511092443895822764655e-4966" },
	{ "%.36Lg", "1.18973149535723176508575932662800702e4932",
		"1.18973149535723176508575932662800702e+4932" },
	{ "%Lg", "-1e-4950", "-1e-4950" },
	{ "%Lg", "inf", "inf" },
	{ "%.3Lf", "-2.0005", "-2.000" },
	{ "%.33Lf", "0.1", "0.100000000000000000000000000000000" },
};
#else
/* Expected printf output: generated from x86_64 glibc. */
#	define LD_THIRD "0.333333333333333333342"
#	define LD_ONE_EPS "1.00000000000000000011"
static const struct printf_case kPrintfCases[] = {
	{ "%.21Lg", "0.1", "0.100000000000000000001" },
	{ "%.21Lg", "1.2", "1.20000000000000000004" },
	{ "%.40Le", "3.141592653589793238462643383279502884197", "3.1415926535897932385128089594061862044327e+00" },
	{ "%Lf", "1e30", "1000000000000000000024696061952.000000" },
	{ "%.21Lg", "1e4000", "9.99999999999999999997e+3999" },
	{ "%.21Lg", "0x1p-16445", "3.64519953188247460253e-4951" },
	{ "%.21Lg", "1.18973149535723176502e4932", "1.18973149535723176502e+4932" },
	{ "%Lg", "-1e-4950", "-1.09356e-4950" },
	{ "%Lg", "inf", "inf" },
	{ "%.3Lf", "-2.0005", "-2.001" },
	{ "%.33Lf", "0.1", "0.100000000000000000001355252715607" },
};
#endif

static void
gen_printf(void)
{
	char buf[512];
	for (size_t i = 0; i < sizeof(kPrintfCases) / sizeof(kPrintfCases[0]); i++) {
		snprintf(buf, sizeof(buf), kPrintfCases[i].format, strtold(kPrintfCases[i].input, NULL));
		printf("\t{ \"%s\", \"%s\", \"%s\" },\n", kPrintfCases[i].format,
			kPrintfCases[i].input, buf);
	}
	snprintf(buf, sizeof(buf), "%." LD_DIG "Lg", 1.0L / 3.0L);
	printf("#\tdefine LD_THIRD \"%s\"\n", buf);
	snprintf(buf, sizeof(buf), "%." LD_DIG "Lg", 1.0L + LDBL_EPSILON);
	printf("#\tdefine LD_ONE_EPS \"%s\"\n", buf);
}

static void
test_strtold(void)
{
	for (size_t i = 0; i < sizeof(kCases) / sizeof(kCases[0]); i++) {
		const struct strtold_case *c = &kCases[i];
		char *end;
		errno = 0;
		long double v = strtold(c->input, &end);
		int e = errno;
		bits128 b = ld_bits(v);
		int same = b.hi == c->hi && b.lo == c->lo;
		check(same && end - c->input == c->end, "strtold",
			"\"%s\" -> %016llx%016llx end %d (want %016llx%016llx end %d) %.36Lg",
			c->input, (unsigned long long)b.hi, (unsigned long long)b.lo,
			(int)(end - c->input), (unsigned long long)c->hi, (unsigned long long)c->lo,
			c->end, v);
		if (c->err == E_RANGE) {
			check(e == ERANGE, "strtold errno", "\"%s\": errno %d (want ERANGE %d)",
				c->input, e, ERANGE);
		} else if (c->err == E_UNDERFLOW) {
			check(e == 0 || e == ERANGE, "strtold errno", "\"%s\" underflows: errno %d (want 0 "
				"or ERANGE %d)", c->input, e, ERANGE);
			if (sVerbose)
				printf("strtold: note: \"%s\" underflows, errno %d (glibc: ERANGE)\n", c->input, e);
		} else {
			check(e == 0, "strtold errno", "\"%s\": errno %d (want 0)", c->input, e);
		}

		/* wcstold(): the same parser, wide */
		wchar_t w[128];
		size_t n = strlen(c->input);
		for (size_t k = 0; k <= n; k++)
			w[k] = (unsigned char)c->input[k];
		wchar_t *wend;
		long double wv = wcstold(w, &wend);
		bits128 wb = ld_bits(wv);
		check(wb.hi == c->hi && wb.lo == c->lo && wend - w == c->end, "wcstold",
			"\"%s\" -> %016llx%016llx end %d", c->input, (unsigned long long)wb.hi,
			(unsigned long long)wb.lo, (int)(wend - w));

		/* sscanf("%Lf") and "%Lg": decimal inputs that parse completely ("1e" is a
		   matching failure for scanf) */
		if (strpbrk(c->input, "xXnNiI") == NULL && c->end == (int)n) {
			long double sv = 0, gv = 0;
			int r1 = sscanf(c->input, "%Lf", &sv);
			int r2 = sscanf(c->input, "%Lg", &gv);
			bits128 sb = ld_bits(sv), gb = ld_bits(gv);
			check(r1 == 1 && r2 == 1 && sb.hi == c->hi && sb.lo == c->lo && gb.hi == c->hi
					&& gb.lo == c->lo, "sscanf %Lf",
				"\"%s\" -> %d %016llx%016llx / %d %016llx%016llx", c->input, r1,
				(unsigned long long)sb.hi, (unsigned long long)sb.lo, r2,
				(unsigned long long)gb.hi, (unsigned long long)gb.lo);
		}
	}
}

static void
test_printf(void)
{
	char buf[512];
	for (size_t i = 0; i < sizeof(kPrintfCases) / sizeof(kPrintfCases[0]); i++) {
		const struct printf_case *c = &kPrintfCases[i];
		snprintf(buf, sizeof(buf), c->format, strtold(c->input, NULL));
		check(strcmp(buf, c->output) == 0, "printf", "%s of %s -> \"%s\" (want \"%s\")",
			c->format, c->input, buf, c->output);
	}
	/* a value strtold() cannot produce wrong: arithmetic */
	snprintf(buf, sizeof(buf), "%." LD_DIG "Lg", 1.0L / 3.0L);
	check(strcmp(buf, LD_THIRD) == 0, "printf", "%%." LD_DIG "Lg of 1.0L/3 -> \"%s\"", buf);
	snprintf(buf, sizeof(buf), "%." LD_DIG "Lg", 1.0L + LDBL_EPSILON);
	check(strcmp(buf, LD_ONE_EPS) == 0, "printf", "%%." LD_DIG "Lg of 1+LDBL_EPSILON -> \"%s\"",
		buf);
}

static uint64_t sRandom = 0x2545f4914f6cdd1dULL;

static uint64_t
next_random(void)
{
	/* xorshift64* */
	sRandom ^= sRandom >> 12;
	sRandom ^= sRandom << 25;
	sRandom ^= sRandom >> 27;
	return sRandom * 0x2545f4914f6cdd1dULL;
}

static void
test_round_trip(void)
{
	char buf[128];
	int bad = 0, badHex = 0, n = 20000;
	for (int i = 0; i < n; i++) {
		uint64_t hi = next_random(), lo = next_random();
		/* exponent field 0..0x7ffe: finite values, about 1 in 16 subnormal */
		uint64_t exponent = (i % 16 == 0) ? 0 : next_random() % 0x7fff;
#if LDBL_MANT_DIG == 113
		hi = (hi & 0x8000ffffffffffffULL) | (exponent << 48);
#else
		/* the explicit integer bit is set exactly for normal values (no pseudo-denormals or
		   unnormals: strtold() never returns those) */
		hi = (hi & 0x8000ULL) | exponent;
		if (exponent != 0)
			lo |= 1ULL << 63;
		else
			lo &= ~(1ULL << 63);
#endif
		long double x = ld_from_bits(hi, lo);

		snprintf(buf, sizeof(buf), "%." LD_DIG "Lg", x);
		long double y = strtold(buf, NULL);
		bits128 b = ld_bits(y);
		if (b.hi != hi || b.lo != lo) {
			if (bad++ < 5) {
				check(0, "round trip %." LD_DIG "Lg", "%016llx%016llx -> \"%s\" -> %016llx%016llx",
					(unsigned long long)hi, (unsigned long long)lo, buf,
					(unsigned long long)b.hi, (unsigned long long)b.lo);
			}
		}

		snprintf(buf, sizeof(buf), "%La", x);
		y = strtold(buf, NULL);
		b = ld_bits(y);
		if (b.hi != hi || b.lo != lo) {
			if (badHex++ < 5) {
				check(0, "round trip %La", "%016llx%016llx -> \"%s\" -> %016llx%016llx",
					(unsigned long long)hi, (unsigned long long)lo, buf,
					(unsigned long long)b.hi, (unsigned long long)b.lo);
			}
		}
	}
	check(bad == 0, "round trip %." LD_DIG "Lg", "%d of %d values differ", bad, n);
	check(badHex == 0, "round trip %La", "%d of %d values differ", badHex, n);
}

static void
test_double_float(void)
{
	static const struct {
		const char *input;
		uint64_t bits;
		int end;
	} kDoubles[] = {
		{ "0.1", 0x3fb999999999999aULL, 3 },
		{ "1.2", 0x3ff3333333333333ULL, 3 },
		{ "1e308", 0x7fe1ccf385ebc8a0ULL, 5 },
		{ "4.9406564584124654e-324", 0x0000000000000001ULL, 23 },
		{ "2.2250738585072011e-308", 0x000fffffffffffffULL, 23 },
		{ "0x1.8p1", 0x4008000000000000ULL, 7 },
		{ "9007199254740993", 0x4340000000000000ULL, 16 },
		{ "-0", 0x8000000000000000ULL, 2 },
		{ "-nan", 0xfff8000000000000ULL, 4 },
		{ "nan(0x123)", 0x7ff8000000000123ULL, 10 },
		{ "nan(0x123", 0x7ff8000000000000ULL, 3 },
		{ "0x1p-1075", 0x0000000000000000ULL, 9 },
		{ "0x1.8p-1074", 0x0000000000000002ULL, 11 },
		{ "0x1.0000000000001p-1075", 0x0000000000000001ULL, 23 },
		{ "-1e-400", 0x8000000000000000ULL, 7 },
		{ "-2e-324", 0x8000000000000000ULL, 7 },
	};
	for (size_t i = 0; i < sizeof(kDoubles) / sizeof(kDoubles[0]); i++) {
		char *end;
		double d = strtod(kDoubles[i].input, &end);
		uint64_t b;
		memcpy(&b, &d, sizeof(b));
		check(b == kDoubles[i].bits && end - kDoubles[i].input == kDoubles[i].end, "strtod",
			"\"%s\" -> %016llx end %d (want %016llx end %d)", kDoubles[i].input,
			(unsigned long long)b, (int)(end - kDoubles[i].input),
			(unsigned long long)kDoubles[i].bits, kDoubles[i].end);
	}
	errno = 0;
	double d = strtod("1e400", NULL);
	check(d == HUGE_VAL && errno == ERANGE, "strtod", "\"1e400\" -> %g errno %d", d, errno);
	/* values that overflow only when rounded (above the half-way point to 2^MAX_EXP) */
	errno = 0;
	d = strtod("1.7976931348623159e308", NULL);
	check(d == HUGE_VAL && errno == ERANGE, "strtod", "\"1.7976931348623159e308\" (rounds to "
		"overflow) -> %g errno %d (want inf, ERANGE)", d, errno);
	errno = 0;
	float f = strtof("3.4028236e38", NULL);
	check(f == HUGE_VALF && errno == ERANGE, "strtof", "\"3.4028236e38\" (rounds to overflow) -> %g "
		"errno %d (want inf, ERANGE)", f, errno);

	static const struct {
		const char *input;
		uint32_t bits;
	} kFloats[] = {
		{ "0.1", 0x3dcccccd },
		{ "1.2", 0x3f99999a },
		{ "3.4028235e38", 0x7f7fffff },
		{ "1.4e-45", 0x00000001 },
		{ "16777217", 0x4b800000 },
		{ "-0", 0x80000000 },
		{ "-nan", 0xffc00000 },
		{ "nan(0x123)", 0x7fc00123 },
		{ "0x1p-150", 0x00000000 },
		{ "0x1.8p-149", 0x00000002 },
	};
	for (size_t i = 0; i < sizeof(kFloats) / sizeof(kFloats[0]); i++) {
		float f = strtof(kFloats[i].input, NULL);
		uint32_t b;
		memcpy(&b, &f, sizeof(b));
		check(b == kFloats[i].bits, "strtof", "\"%s\" -> %08x (want %08x)", kFloats[i].input,
			(unsigned)b, (unsigned)kFloats[i].bits);
	}

	char buf[64];
	int bad = 0, n = 20000;
	for (int i = 0; i < n; i++) {
		uint64_t bits = next_random() & 0x7fefffffffffffffULL;
		if ((bits >> 52) == 0x7ff)
			continue;
		memcpy(&d, &bits, sizeof(d));
		snprintf(buf, sizeof(buf), "%.17g", d);
		double y = strtod(buf, NULL);
		uint64_t b;
		memcpy(&b, &y, sizeof(b));
		if (b != bits && bad++ < 5) {
			check(0, "round trip strtod", "%016llx -> \"%s\" -> %016llx",
				(unsigned long long)bits, buf, (unsigned long long)b);
		}
	}
	check(bad == 0, "round trip strtod", "%d of %d values differ", bad, n);
}

int
main(int argc, char **argv)
{
	if (argc > 1 && strcmp(argv[1], "--gen") == 0) {
		gen();
		return 0;
	}
	sVerbose = argc > 1 && strcmp(argv[1], "-v") == 0;

	test_strtold();
	test_printf();
	test_round_trip();
	test_double_float();

	if (sFailures == 0) {
		printf("strtold: ok (%d checks)\n", sChecks);
		return 0;
	}
	printf("strtold: %d failures (%d checks)\n", sFailures, sChecks);
	return 1;
}
