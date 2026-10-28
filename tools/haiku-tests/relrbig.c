/*
 * relrbig.c — a library with as many relative relocations as Firefox's libxul.so has (about half a
 * million pointers in a table), for timing the runtime loader's relocation with plain RELA entries
 * against packed DT_RELR ones (dlopentime.c):
 *
 *   g="$CROSS/bin/aarch64-unknown-haiku-gcc --sysroot=artifacts/sysroot-arm64 -O2 -fPIC -shared"
 *   $g -o librelrbig-rela.so tools/haiku-tests/relrbig.c
 *   $g -Wl,-z,pack-relative-relocs -o librelrbig-relr.so tools/haiku-tests/relrbig.c
 *   dlopentime /boot/home/librelrbig-rela.so 20; dlopentime /boot/home/librelrbig-relr.so 20
 *
 * The table is 4 MiB either way (and is written either way); the RELA one adds 12 MiB of relocation
 * entries, the DT_RELR one 65 KiB (one 8-byte bitmap per 63 words). relrbig_check() returns the
 * number of wrong pointers.
 */
static char t[4096];

#define R4(b) t + ((b) & 4095), t + (((b) + 1) & 4095), t + (((b) + 2) & 4095), t + (((b) + 3) & 4095)
#define R16(b) R4(b), R4((b) + 4), R4((b) + 8), R4((b) + 12)
#define R64(b) R16(b), R16((b) + 16), R16((b) + 32), R16((b) + 48)
#define R256(b) R64(b), R64((b) + 64), R64((b) + 128), R64((b) + 192)
#define R1K(b) R256(b), R256((b) + 256), R256((b) + 512), R256((b) + 768)
#define R4K(b) R1K(b), R1K((b) + 1024), R1K((b) + 2048), R1K((b) + 3072)
#define R16K(b) R4K(b), R4K((b) + 4096), R4K((b) + 8192), R4K((b) + 12288)
#define R64K(b) R16K(b), R16K((b) + 16384), R16K((b) + 32768), R16K((b) + 49152)

#define COUNT (8 * 65536)

char* relrbig_table[COUNT] = { R64K(0), R64K(65536), R64K(131072), R64K(196608), R64K(262144),
	R64K(327680), R64K(393216), R64K(458752) };


int
relrbig_check(void)
{
	int bad = 0;
	int i;
	for (i = 0; i < COUNT; i++)
		bad += relrbig_table[i] != t + (i & 4095);
	return bad;
}
