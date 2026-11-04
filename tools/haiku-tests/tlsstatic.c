/*
 * tlsstatic.c — thread-local variables in every place a program can have them: in the program itself, in a
 * library it links (loaded at start), in a dlopen()ed library, and one variable of the linked library used
 * from all three. Since haiku n5-tls, the runtime loader puts the TLS of the images loaded at program start
 * into one block per thread (TLS_STATIC_TLS_SLOT) and gives their DTPMOD relocations TLS_STATIC_MODULE |
 * offset; images loaded later keep the dynamic thread vector. Checks, on the main thread and on new threads:
 * initial values (.tdata, .tbss, a 64-byte aligned variable, a pointer in .tdata that needs a relocation),
 * per-thread separation and persistence, local-dynamic accesses, the same address for the shared variable
 * from every image, a dlopen()ed library unloaded and loaded again on a new thread (as tlsreload), fork(),
 * many short threads, and a library of the program's start unloaded by an extra dlclose() before a new
 * thread's first TLS access (the block's initial image must not be read from the unmapped library).
 *
 *   tlsstatic [-p]      prints "tlsstatic: PASS" or the first mismatch and exits 1
 *                       -p: also checks the add-on's TLS (run as LD_PRELOAD_ADDONS=./libtlsp.so ./tlsstatic -p:
 *                       the add-on's init routine uses its TLS before the program is loaded)
 *
 * Build (cross): the same file is the libraries and the program:
 *   g="sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc --sysroot=artifacts/sysroot-arm64"
 *   $g -O2 -fPIC -shared -DTLSSTATIC_LIB=1 -o libtlss.so tools/haiku-tests/tlsstatic.c
 *   $g -O2 -fPIC -shared -DTLSSTATIC_LIB=2 -o libtlsd.so tools/haiku-tests/tlsstatic.c -L. -ltlss
 *   $g -O2 -fPIC -shared -DTLSSTATIC_LIB=3 -o libtlsp.so tools/haiku-tests/tlsstatic.c
 *   $g -O2 -o tlsstatic tools/haiku-tests/tlsstatic.c -L. -ltlss
 * Run it from the directory holding the libraries (LIBRARY_PATH=%A:... finds libtlss.so there).
 */
#include <stdint.h>

#if TLSSTATIC_LIB == 1
/* libtlss.so: linked by the program, loaded at its start */

long tlss_global = 1;
__thread long tlss_shared = 5;
__thread long tlss_value = 11;
__thread long tlss_aligned __attribute__((aligned(64))) = 7;
__thread long* tlss_pointer = &tlss_global;
__thread char tlss_zero[100];

/* local-dynamic: one __tls_get_addr() call for the module, then link-time offsets */
static __thread int sA __attribute__((tls_model("local-dynamic"))) = 3;
static __thread int sB __attribute__((tls_model("local-dynamic"))) = 4;

long* tlss_value_address(void) { return &tlss_value; }
long* tlss_aligned_address(void) { return &tlss_aligned; }
long** tlss_pointer_address(void) { return &tlss_pointer; }
char* tlss_zero_address(void) { return tlss_zero; }
long* tlss_shared_address(void) { return &tlss_shared; }
long* tlss_global_address(void) { return &tlss_global; }

/* sets both variables from value unless it is 0; returns their sum */
int
tlss_ld_sum(int value)
{
	if (value != 0) {
		sA = 3 + value;
		sB = 4 + value;
	}
	return sA + sB;
}

#elif TLSSTATIC_LIB == 2
/* libtlsd.so: dlopen()ed */

extern __thread long tlss_shared;
__thread long tlsd_value = 22;
__thread char tlsd_big[4096] = { 33 };

long* tlsd_value_address(void) { return &tlsd_value; }
char* tlsd_big_address(void) { return tlsd_big; }
long* tlsd_shared_address(void) { return &tlss_shared; }

#elif TLSSTATIC_LIB == 3
/* libtlsp.so: LD_PRELOAD_ADDONS; its init routine uses its TLS first */

__thread long tlsp_value = 44;
long tlsp_seen;

__attribute__((constructor)) static void
tlsp_init(void)
{
	tlsp_seen = tlsp_value;
	tlsp_value = 45;
}

long* tlsp_value_address(void) { return &tlsp_value; }

#else

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern __thread long tlss_shared;
long* tlss_value_address(void);
long* tlss_aligned_address(void);
long** tlss_pointer_address(void);
char* tlss_zero_address(void);
long* tlss_shared_address(void);
long* tlss_global_address(void);
int tlss_ld_sum(int add);

__thread long sMainValue = 66;
__thread char sMainZero[64];

static int sFailures;
static pthread_mutex_t sPrintLock = PTHREAD_MUTEX_INITIALIZER;


static void
check(const char* where, const char* what, long got, long expected)
{
	if (got == expected)
		return;
	pthread_mutex_lock(&sPrintLock);
	if (sFailures++ == 0)
		printf("tlsstatic: FAIL: %s: %s: %ld, expected %ld\n", where, what, got, expected);
	pthread_mutex_unlock(&sPrintLock);
}


/* the initial values of the program's and the linked library's TLS, as a new thread sees them */
static void
check_initial(const char* where)
{
	check(where, "program value", sMainValue, 66);
	check(where, "program .tbss", sMainZero[0] | sMainZero[63], 0);
	check(where, "library value", *tlss_value_address(), 11);
	check(where, "library aligned value", *tlss_aligned_address(), 7);
	check(where, "library aligned address % 64", (uintptr_t)tlss_aligned_address() % 64, 0);
	check(where, "library pointer in .tdata", (long)(uintptr_t)*tlss_pointer_address(),
		(long)(uintptr_t)tlss_global_address());
	check(where, "library .tbss", tlss_zero_address()[0] | tlss_zero_address()[99], 0);
	check(where, "shared variable", tlss_shared, 5);
	check(where, "shared address, program = library", (long)(uintptr_t)&tlss_shared,
		(long)(uintptr_t)tlss_shared_address());
	check(where, "local-dynamic sum", tlss_ld_sum(0), 7);
}


/* set this thread's values from a seed, then read them back after the others have done the same */
static void
set_values(long seed)
{
	sMainValue = seed;
	*tlss_value_address() = seed + 1;
	*tlss_aligned_address() = seed + 2;
	tlss_zero_address()[50] = (char)seed;
	tlss_shared = seed + 3;
	tlss_ld_sum((int)seed);
}


static void
check_values(const char* where, long seed)
{
	check(where, "own program value", sMainValue, seed);
	check(where, "own library value", *tlss_value_address(), seed + 1);
	check(where, "own aligned value", *tlss_aligned_address(), seed + 2);
	check(where, "own .tbss byte", tlss_zero_address()[50], (char)seed);
	check(where, "own shared value", tlss_shared, seed + 3);
	check(where, "own local-dynamic sum", tlss_ld_sum(0), 7 + 2 * seed);
}


struct dynamic_library {
	void* handle;
	long* (*value)(void);
	char* (*big)(void);
	long* (*shared)(void);
};

static struct dynamic_library sDynamic;


static void
load_dynamic(void)
{
	sDynamic.handle = dlopen("./libtlsd.so", RTLD_NOW | RTLD_LOCAL);
	if (sDynamic.handle == NULL) {
		printf("tlsstatic: FAIL: dlopen ./libtlsd.so: %s\n", dlerror());
		exit(1);
	}
	sDynamic.value = (long* (*)(void))dlsym(sDynamic.handle, "tlsd_value_address");
	sDynamic.big = (char* (*)(void))dlsym(sDynamic.handle, "tlsd_big_address");
	sDynamic.shared = (long* (*)(void))dlsym(sDynamic.handle, "tlsd_shared_address");
	if (sDynamic.value == NULL || sDynamic.big == NULL || sDynamic.shared == NULL) {
		printf("tlsstatic: FAIL: dlsym in ./libtlsd.so\n");
		exit(1);
	}
}


static void
check_dynamic_initial(const char* where)
{
	check(where, "dlopened value", *sDynamic.value(), 22);
	check(where, "dlopened array", sDynamic.big()[0] + sDynamic.big()[4095], 33);
	check(where, "shared address, dlopened = program", (long)(uintptr_t)sDynamic.shared(),
		(long)(uintptr_t)&tlss_shared);
}


/* a worker: checks the initial values, sets its own, waits for all the others, checks its own again */
static pthread_barrier_t sBarrier;
static int sUseDynamic;


static void*
worker(void* seedPointer)
{
	long seed = (long)(intptr_t)seedPointer;
	char where[32];
	snprintf(where, sizeof(where), "thread %ld", seed);

	check_initial(where);
	if (sUseDynamic)
		check_dynamic_initial(where);
	set_values(seed);
	if (sUseDynamic) {
		*sDynamic.value() = seed + 4;
		sDynamic.big()[100] = (char)seed;
	}
	pthread_barrier_wait(&sBarrier);
	check_values(where, seed);
	if (sUseDynamic) {
		check(where, "own dlopened value", *sDynamic.value(), seed + 4);
		check(where, "own dlopened array", sDynamic.big()[100], (char)seed);
		check(where, "shared value seen by the dlopened library", *sDynamic.shared(), seed + 3);
	}
	return NULL;
}


static void
run_workers(int count, long firstSeed)
{
	pthread_t threads[16];
	pthread_barrier_init(&sBarrier, NULL, count);
	for (int i = 0; i < count; i++)
		pthread_create(&threads[i], NULL, worker, (void*)(intptr_t)(firstSeed + i));
	for (int i = 0; i < count; i++)
		pthread_join(threads[i], NULL);
	pthread_barrier_destroy(&sBarrier);
}


/* tlsreload's case: a dlopen()ed library's TLS on a new thread after the library was unloaded once */
static void*
reload_on_thread(void* unused)
{
	(void)unused;
	load_dynamic();
	check("reload thread", "dlopened value", *sDynamic.value(), 22);
	*sDynamic.value() = 1234;
	check("reload thread", "dlopened value set", *sDynamic.value(), 1234);
	tlss_shared = 77;
	check("reload thread", "shared value seen by the dlopened library", *sDynamic.shared(), 77);
	dlclose(sDynamic.handle);
	return NULL;
}


static void*
short_thread(void* unused)
{
	(void)unused;
	sMainValue++;
	tlss_shared++;
	return (void*)(intptr_t)(sMainValue + tlss_shared);
}


/* an extra dlclose() of the linked library, then a new thread's first TLS access (in a child process:
   the library is unmapped afterwards) */
static int
unload_linked_library(void)
{
	void* handle = dlopen("libtlss.so", RTLD_NOW | RTLD_NOLOAD);
	if (handle == NULL) {
		printf("tlsstatic: FAIL: dlopen(libtlss.so, RTLD_NOLOAD): %s\n", dlerror());
		return 1;
	}
	dlclose(handle);
	dlclose(handle);
		// one more than the dlopen(): the program's own reference

	pthread_t thread;
	void* result;
	pthread_create(&thread, NULL, short_thread, NULL);
	pthread_join(thread, &result);
	return 0;
}


int
main(int argc, char** argv)
{
	int preloadAddOn = argc > 1 && strcmp(argv[1], "-p") == 0;
	setvbuf(stdout, NULL, _IOLBF, 0);

	// 1. the main thread's initial values, its own values
	check_initial("main");
	set_values(100);
	check_values("main", 100);

	if (preloadAddOn) {
		long* seen = (long*)dlsym(RTLD_DEFAULT, "tlsp_seen");
		long* (*value)(void) = (long* (*)(void))dlsym(RTLD_DEFAULT, "tlsp_value_address");
		if (seen == NULL || value == NULL) {
			printf("tlsstatic: FAIL: -p without LD_PRELOAD_ADDONS=./libtlsp.so\n");
			return 1;
		}
		check("main", "add-on value in its init routine", *seen, 44);
		check("main", "add-on value set in its init routine", *value(), 45);
	}

	// 2. four threads at once, before any dlopen()
	run_workers(4, 1);
	check_values("main after the threads", 100);

	// 3. a dlopen()ed library: its TLS and the linked library's variable, on the main thread and four threads
	load_dynamic();
	check_dynamic_initial("main");
	*sDynamic.value() = 200;
	sUseDynamic = 1;
	run_workers(4, 11);
	sUseDynamic = 0;
	check("main", "own dlopened value after the threads", *sDynamic.value(), 200);
	check_values("main after the dlopen threads", 100);
	dlclose(sDynamic.handle);

	// 4. unloaded, then loaded again on new threads
	for (int round = 0; round < 3; round++) {
		pthread_t thread;
		pthread_create(&thread, NULL, reload_on_thread, NULL);
		pthread_join(thread, NULL);
	}
	check_values("main after the reloads", 100);

	// 5. fork(): the child has the parent's values and a TLS of its own
	fflush(stdout);
	pid_t child = fork();
	if (child == 0) {
		check_values("fork child", 100);
		set_values(300);
		run_workers(2, 21);
		check_values("fork child after its threads", 300);
		_exit(sFailures != 0);
	}
	int status = 0;
	waitpid(child, &status, 0);
	check("main", "fork child exit status", WIFEXITED(status) ? WEXITSTATUS(status) : -1, 0);
	check_values("main after fork", 100);

	// 6. many short threads (each one's block is freed when it exits)
	for (int i = 0; i < 2000; i++) {
		pthread_t thread;
		void* result;
		pthread_create(&thread, NULL, short_thread, NULL);
		pthread_join(thread, &result);
		check("short thread", "program + shared value", (long)(intptr_t)result, 67 + 6);
		if (sFailures != 0)
			break;
	}

	// 7. the linked library unloaded before a new thread's first TLS access
	fflush(stdout);
	child = fork();
	if (child == 0)
		_exit(unload_linked_library());
	waitpid(child, &status, 0);
	check("main", "child unloading the linked library: exit status",
		WIFEXITED(status) ? WEXITSTATUS(status) : -1, 0);

	if (sFailures == 0)
		printf("tlsstatic: PASS%s\n", preloadAddOn ? " (with the preloaded add-on)" : "");
	return sFailures != 0;
}

#endif
