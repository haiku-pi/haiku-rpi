/*
 * relrtest.c — packed relative relocations (DT_RELR, ld -z pack-relative-relocs) in the runtime
 * loader: the program's own pointers (.data and .data.rel.ro), a linked library's (librelr.so) and a
 * dlopen()ed one's (librelrdl.so), each checked against its PC-relative address; and that the program
 * and both libraries really have a DT_RELR table (else the test would pass on plain RELA). If DIR has
 * relrbig.c's librelrbig-relr.so, its half a million pointers too.
 *
 *   relrtest [DIR]      (DIR: where librelrdl.so is, default the program's directory /boot/home)
 *
 * Prints "relrtest: ok" or "relrtest: FAIL ...", and whether the system's libbe.so has DT_RELR (for
 * information). Exit 0 on ok.
 *
 * Build (cross; an ld that supports -z pack-relative-relocs on aarch64-unknown-haiku: buildtools
 * 1cad3a62fa or later):
 *   g="$CROSS/bin/aarch64-unknown-haiku-gcc --sysroot=artifacts/sysroot-arm64 -O2 -Wl,-z,pack-relative-relocs"
 *   $g -fPIC -shared -o librelr.so tools/haiku-tests/relrlib.c
 *   $g -fPIC -shared -DCHECK=relrdl_check -o librelrdl.so tools/haiku-tests/relrlib.c
 *   $g -o relrtest tools/haiku-tests/relrtest.c -L. -lrelr -Wl,-rpath,'$ORIGIN'
 * Install all three in one directory (tools/pi-tests/relr.sh: /boot/home).
 */
#include <dlfcn.h>
#include <elf.h>
#include <image.h>
#include <stdio.h>
#include <string.h>

#ifndef DT_RELR
#	define DT_RELR 36
#endif

extern int relrlib_check(void);

static int t[200];
static int* const q[70] = { &t[0], &t[1], &t[2], &t[3], &t[4], &t[5], &t[6], &t[7], &t[8],
	&t[9], &t[10], &t[11], &t[12], &t[13], &t[14], &t[15], &t[16], &t[17], &t[18], &t[19],
	&t[20], &t[21], &t[22], &t[23], &t[24], &t[25], &t[26], &t[27], &t[28], &t[29], &t[30],
	&t[31], &t[32], &t[33], &t[34], &t[35], &t[36], &t[37], &t[38], &t[39], &t[40], &t[41],
	&t[42], &t[43], &t[44], &t[45], &t[46], &t[47], &t[48], &t[49], &t[50], &t[51], &t[52],
	&t[53], &t[54], &t[55], &t[56], &t[57], &t[58], &t[59], &t[60], &t[61], &t[62], &t[63],
	&t[64], &t[65], &t[66], &t[67], &t[68], &t[69] };
static const char* const kWords[] = { "packed", "relative", "relocations" };


/* whether the loaded image NAME (a path suffix) has a DT_RELR entry */
static int
has_relr(const char* name)
{
	image_info info;
	int32 cookie = 0;
	size_t length = strlen(name);
	while (get_next_image_info(0, &cookie, &info) == B_OK) {
		size_t pathLength = strlen(info.name);
		if (pathLength < length || strcmp(info.name + pathLength - length, name) != 0)
			continue;
		/* the text segment starts with the ELF header (link-time address 0) */
		{
			Elf64_Ehdr* header = (Elf64_Ehdr*)info.text;
			Elf64_Phdr* phdr = (Elf64_Phdr*)((char*)info.text + header->e_phoff);
			addr_t delta = (addr_t)info.text;
			int i;
			for (i = 0; i < header->e_phnum; i++) {
				Elf64_Dyn* d;
				if (phdr[i].p_type != PT_DYNAMIC)
					continue;
				for (d = (Elf64_Dyn*)(phdr[i].p_vaddr + delta); d->d_tag != DT_NULL; d++) {
					if (d->d_tag == DT_RELR)
						return 1;
				}
			}
		}
		return 0;
	}
	return -1;
}


int
main(int argc, char** argv)
{
	const char* dir = argc > 1 ? argv[1] : "/boot/home";
	char path[1024];
	void* handle;
	int (*check)(void);
	int bad = 0, i;

	static int* p0[] = { &t[100], &t[101], &t[102] };
	for (i = 0; i < 70; i++)
		bad += q[i] != &t[i];
	for (i = 0; i < 3; i++)
		bad += p0[i] != &t[100 + i];
	if (strcmp(kWords[0], "packed") != 0 || strcmp(kWords[2], "relocations") != 0)
		bad++;
	if (bad != 0)
		printf("relrtest: FAIL: %d bad pointers in the program\n", bad);

	i = relrlib_check();
	if (i != 0)
		printf("relrtest: FAIL: %d bad pointers in librelr.so\n", i);
	bad += i;

	snprintf(path, sizeof(path), "%s/librelrdl.so", dir);
	handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	if (handle == NULL) {
		printf("relrtest: FAIL: dlopen %s: %s\n", path, dlerror());
		return 1;
	}
	check = (int (*)(void))dlsym(handle, "relrdl_check");
	i = check != NULL ? check() : 1000;
	if (i != 0)
		printf("relrtest: FAIL: %d bad pointers in librelrdl.so\n", i);
	bad += i;

	/* information: whether the system was built with DT_RELR */
	{
		void* be = dlopen("libbe.so", RTLD_NOW | RTLD_LOCAL);
		printf("relrtest: libbe.so DT_RELR %d\n", be != NULL ? has_relr("/libbe.so") : -1);
		if (be != NULL)
			dlclose(be);
	}

	/* relrbig.c's library, if it is there: half a million pointers */
	snprintf(path, sizeof(path), "%s/librelrbig-relr.so", dir);
	{
		void* big = dlopen(path, RTLD_NOW | RTLD_LOCAL);
		if (big != NULL) {
			check = (int (*)(void))dlsym(big, "relrbig_check");
			i = check != NULL ? check() : 1000;
			printf("relrtest: librelrbig-relr.so: %d bad pointers, DT_RELR %d\n", i,
				has_relr("/librelrbig-relr.so"));
			bad += i + (has_relr("/librelrbig-relr.so") != 1);
			dlclose(big);
		}
	}

	if (has_relr("/relrtest") != 1 || has_relr("/librelr.so") != 1
			|| has_relr("/librelrdl.so") != 1) {
		printf("relrtest: FAIL: not linked with DT_RELR (%d %d %d)\n", has_relr("/relrtest"),
			has_relr("/librelr.so"), has_relr("/librelrdl.so"));
		bad++;
	}
	dlclose(handle);

	printf(bad == 0 ? "relrtest: ok\n" : "relrtest: FAIL: %d\n", bad);
	return bad != 0;
}
