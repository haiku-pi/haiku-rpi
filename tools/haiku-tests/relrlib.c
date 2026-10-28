/*
 * relrlib.c — the library half of relrtest.c: pointers that the linker turns into relative
 * relocations, in runs and gaps that exercise every shape of a DT_RELR table (address entries,
 * full and partial bitmaps, a gap of exactly one bitmap's 63 words, larger gaps), in .data and in
 * .data.rel.ro, and a check that each one points where the code (PC-relative) says it should.
 *
 * Built twice by relrtest.c's commands: librelr.so (linked) and librelrdl.so (-DCHECK=relrdl_check,
 * dlopen()ed).
 */
#include <string.h>

#ifndef CHECK
#	define CHECK relrlib_check
#endif

static int t[1024];

#define R4(b) &t[b], &t[(b) + 1], &t[(b) + 2], &t[(b) + 3]
#define R16(b) R4(b), R4((b) + 4), R4((b) + 8), R4((b) + 12)
#define R64(b) R16(b), R16((b) + 16), R16((b) + 32), R16((b) + 48)

/* a dense run: full bitmaps */
__attribute__((visibility("hidden"))) int* dense[320] = { R64(0), R64(64), R64(128), R64(192), R64(256) };

/* every other word; every 63rd (one bitmap's span); every 64th; every 100th */
struct gap1 { int* p; long pad[1]; };
struct gap62 { int* p; long pad[62]; };
struct gap63 { int* p; long pad[63]; };
struct gap99 { int* p; long pad[99]; };
__attribute__((visibility("hidden"))) struct gap1 s1[40] = { {&t[400]}, {&t[401]}, {&t[402]}, {&t[403]}, {&t[404]}, {&t[405]},
	{&t[406]}, {&t[407]}, {&t[408]}, {&t[409]}, {&t[410]}, {&t[411]}, {&t[412]}, {&t[413]},
	{&t[414]}, {&t[415]}, {&t[416]}, {&t[417]}, {&t[418]}, {&t[419]}, {&t[420]}, {&t[421]},
	{&t[422]}, {&t[423]}, {&t[424]}, {&t[425]}, {&t[426]}, {&t[427]}, {&t[428]}, {&t[429]},
	{&t[430]}, {&t[431]}, {&t[432]}, {&t[433]}, {&t[434]}, {&t[435]}, {&t[436]}, {&t[437]},
	{&t[438]}, {&t[439]} };
static struct gap62 s62[5] = { {&t[500]}, {&t[501]}, {&t[502]}, {&t[503]}, {&t[504]} };
static struct gap63 s63[5] = { {&t[510]}, {&t[511]}, {&t[512]}, {&t[513]}, {&t[514]} };
static struct gap99 s99[5] = { {&t[520]}, {&t[521]}, {&t[522]}, {&t[523]}, {&t[524]} };

/* relocated, then read-only (.data.rel.ro): strings and functions */
static int f0(void) { return 0; }
static int f1(void) { return 1; }
static int f2(void) { return 2; }
static int (* const kFunctions[])(void) = { f0, f1, f2, f0, f1, f2, f0, f1, f2 };
static const char* const kNames[] = { "alpha", "beta", "gamma", "delta", "epsilon", "zeta",
	"eta", "theta", "iota", "kappa", "lambda", "mu" };

/* a pointer to a pointer: both relocated */
static int** indirect = &dense[7];


int
CHECK(void)
{
	static const char* const expected = "alpha beta gamma delta epsilon zeta eta theta iota kappa "
		"lambda mu ";
	char joined[128] = "";
	int bad = 0;
	int i;

	for (i = 0; i < 320; i++)
		bad += dense[i] != &t[i];
	for (i = 0; i < 40; i++)
		bad += s1[i].p != &t[400 + i];
	for (i = 0; i < 5; i++) {
		bad += s62[i].p != &t[500 + i];
		bad += s63[i].p != &t[510 + i];
		bad += s99[i].p != &t[520 + i];
	}
	for (i = 0; i < 9; i++)
		bad += kFunctions[i]() != i % 3;
	for (i = 0; i < 12; i++) {
		strcat(joined, kNames[i]);
		strcat(joined, " ");
	}
	bad += strcmp(joined, expected) != 0;
	bad += *indirect != &t[7];
	return bad;
}
