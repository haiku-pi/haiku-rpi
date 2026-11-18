/*
 * swapfloat: B_SWAP_FLOAT / B_SWAP_DOUBLE return the byte-swapped value (arm64 __swap_float/__swap_double returned
 * their input unchanged before RenkuOS PR #477). Prints "SWAPFLOAT PASS" or "SWAPFLOAT FAIL ...".
 * Build: aarch64-unknown-haiku-gcc -O2 -o swapfloat swapfloat.c
 */
#include <ByteOrder.h>
#include <stdio.h>
#include <string.h>

int
main(void)
{
	volatile float f = 1.0f;		/* 0x3f800000 */
	volatile double d = 1.0;		/* 0x3ff0000000000000 */
	float sf = B_SWAP_FLOAT(f);
	double sd = B_SWAP_DOUBLE(d);
	uint32 fb;
	uint64 db;
	memcpy(&fb, &sf, sizeof(fb));
	memcpy(&db, &sd, sizeof(db));
	int ok = fb == 0x0000803fu && db == 0x000000000000f03full;
	printf("SWAPFLOAT %s float %#010x (want 0x0000803f) double %#018llx (want 0x000000000000f03f)\n",
		ok ? "PASS" : "FAIL", (unsigned)fb, (unsigned long long)db);
	return ok ? 0 : 1;
}
