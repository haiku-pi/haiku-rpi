/*
 * tlsreload.c — a thread-local variable of a shared library keeps its value on a new thread after an
 * earlier copy of the library was unloaded. The library (libtlsr.so) is loaded and unloaded once on
 * the main thread, then loaded again and used on a new thread: a value set there must read back.
 * Haiku's runtime loader gave a new thread's TLS vector generation 0 instead of the current one, so
 * after any unload its second TLS access threw the block away (Mesa's call_once() then jumped to 0
 * on the second vkCreateInstance of a process, Photocraft's GPU tests).
 *
 *   tlsreload [LIBRARY]        (default ./libtlsr.so); prints "tlsreload: PASS" or "tlsreload: FAIL ..."
 *
 * Build (cross):
 *   g="sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc --sysroot=artifacts/sysroot-arm64"
 *   $g -O2 -shared -fPIC -o libtlsr.so tools/haiku-tests/tlsreload/libtlsr.c
 *   $g -O2 -o tlsreload tools/haiku-tests/tlsreload/tlsreload.c
 */
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>


static const char* sLibrary = "./libtlsr.so";
static int sFailed = 0;


static void*
use_library(void* round)
{
	void* library = dlopen(sLibrary, RTLD_NOW | RTLD_LOCAL);
	if (library == NULL) {
		printf("tlsreload: FAIL dlopen: %s\n", dlerror());
		sFailed = 1;
		return NULL;
	}
	void (*set)(long) = (void (*)(long))dlsym(library, "tlsr_set");
	long (*get)(void) = (long (*)(void))dlsym(library, "tlsr_get");
	set(1234);
	long value = get();
	if (value != 1234) {
		printf("tlsreload: FAIL round %ld: read %ld after setting 1234\n", (long)round, value);
		sFailed = 1;
	}
	dlclose(library);
	return NULL;
}


int
main(int argc, char** argv)
{
	if (argc > 1)
		sLibrary = argv[1];

	// once on the main thread: load, use, unload
	use_library((void*)0);

	// then twice more, each on a new thread
	for (long round = 1; round <= 2; round++) {
		pthread_t thread;
		pthread_create(&thread, NULL, use_library, (void*)round);
		pthread_join(thread, NULL);
	}

	if (!sFailed)
		printf("tlsreload: PASS\n");
	return sFailed;
}
