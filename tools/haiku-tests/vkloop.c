/*
 * vkloop.c — several Vulkan instances in one process, one after another, each with the loader
 * dlopen()ed and dlclose()d around it, as a Rust program using wgpu/ash does (ash's Entry loads
 * libvulkan.so.1 and closes it when dropped; the loader unloads the driver at vkDestroyInstance).
 * Photocraft's GPU tests (one instance per test) crash in the second vkCreateInstance on Haiku arm64:
 * PC 0, called from V3DV's glsl_type_singleton_init_or_ref() (vk_instance_init) through
 * util_call_once_data_slow() -> call_once() -> pthread_once@plt. Preloading the driver avoids it.
 *
 *   vkloop [-t] [-k] [N]   N instances (default 3); -t: each on a new thread (like Rust's test
 *                          harness); -k: keep libvulkan.so.1 loaded (only the driver is reloaded)
 *                          prints "vkloop: instance I ..." per round and "vkloop: PASS", or crashes
 *
 * Build (cross; only the Vulkan headers are needed, the loader is dlopen()ed):
 *   g="sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc --sysroot=artifacts/sysroot-arm64"
 *   $g -O2 -I artifacts/sysroot-arm64/boot/system/non-packaged/develop/headers -o vkloop tools/haiku-tests/vkloop.c
 */
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <vulkan/vulkan.h>

static int sKeep;
static void* sKept;
static int sFailures;

static void*
instance_round(void* arg)
{
	int round = (int)(long)arg;
	void* lib = sKept != NULL ? sKept : dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
	if (lib == NULL) {
		printf("vkloop: instance %d: dlopen libvulkan.so.1: %s\n", round, dlerror());
		sFailures++;
		return NULL;
	}
	if (sKeep)
		sKept = lib;
	PFN_vkGetInstanceProcAddr getProc = (PFN_vkGetInstanceProcAddr)dlsym(lib, "vkGetInstanceProcAddr");
	PFN_vkCreateInstance create = (PFN_vkCreateInstance)getProc(NULL, "vkCreateInstance");
	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO };
	app.pApplicationName = "vkloop";
	app.apiVersion = VK_API_VERSION_1_1;
	VkInstanceCreateInfo info = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
	info.pApplicationInfo = &app;
	VkInstance instance;
	printf("vkloop: instance %d: vkCreateInstance...\n", round);
	fflush(stdout);
	VkResult result = create(&info, NULL, &instance);
	uint32_t devices = 0;
	if (result == VK_SUCCESS) {
		PFN_vkEnumeratePhysicalDevices enumerate
			= (PFN_vkEnumeratePhysicalDevices)getProc(instance, "vkEnumeratePhysicalDevices");
		enumerate(instance, &devices, NULL);
		PFN_vkDestroyInstance destroy = (PFN_vkDestroyInstance)getProc(instance, "vkDestroyInstance");
		destroy(instance, NULL);
	} else
		sFailures++;
	printf("vkloop: instance %d: result %d, %u physical devices\n", round, (int)result, devices);
	fflush(stdout);
	if (!sKeep)
		dlclose(lib);
	return NULL;
}

int
main(int argc, char** argv)
{
	int threads = 0, n = 3;
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "-t") == 0)
			threads = 1;
		else if (strcmp(argv[i], "-k") == 0)
			sKeep = 1;
		else
			n = atoi(argv[i]);
	}
	for (int i = 1; i <= n; i++) {
		if (threads) {
			pthread_t thread;
			pthread_create(&thread, NULL, instance_round, (void*)(long)i);
			pthread_join(thread, NULL);
		} else
			instance_round((void*)(long)i);
	}
	printf("vkloop: %s\n", sFailures == 0 ? "PASS" : "FAIL");
	return sFailures != 0;
}
