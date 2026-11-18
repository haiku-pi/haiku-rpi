/*
 * blender-vkprobe — would Blender's Vulkan backend accept this device (docs/design/blender.md, track B)?
 * Checks the first physical device against the lists Blender refuses to start without
 * (source/blender/gpu/vulkan/vk_backend.cc missing_capabilities_get()) in 4.5 and in 5.3, and prints the
 * limits that the analysis flags as likely trouble beyond those lists (storage buffers per stage, colour
 * attachments, compute invocations, push constants). Headless: no surface is created.
 *
 *   blender-vkprobe
 *
 * Lines start with "BVK ". Exit status 0 when the 5.3 list is complete, 1 when something is missing,
 * 2 when there is no Vulkan device.
 */

#include <vulkan/vulkan.h>

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SAY(...) do { printf("BVK " __VA_ARGS__); printf("\n"); fflush(stdout); } while (0)

static VkExtensionProperties *sExtensions;
static uint32_t sExtensionCount;

static bool
has_extension(const char *name)
{
	for (uint32_t i = 0; i < sExtensionCount; i++) {
		if (strcmp(sExtensions[i].extensionName, name) == 0)
			return true;
	}
	return false;
}

static int sMissing45, sMissing53;

static void
need(bool ok, const char *what, bool in45, bool in53)
{
	SAY("%-4s %s%s%s", ok ? "yes" : "NO", what, in45 ? " [4.5]" : "", in53 ? " [5.3]" : "");
	if (!ok && in45)
		sMissing45++;
	if (!ok && in53)
		sMissing53++;
}

int
main(void)
{
	VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
		.pApplicationName = "blender-vkprobe", .apiVersion = VK_API_VERSION_1_2 };
	VkInstanceCreateInfo instanceInfo = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
		.pApplicationInfo = &app };
	VkInstance instance;
	if (vkCreateInstance(&instanceInfo, NULL, &instance) != VK_SUCCESS) {
		SAY("no Vulkan instance");
		return 2;
	}
	uint32_t count = 1;
	VkPhysicalDevice device;
	if (vkEnumeratePhysicalDevices(instance, &count, &device) < 0 || count == 0) {
		SAY("no Vulkan device");
		return 2;
	}

	VkPhysicalDeviceDriverProperties driver = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES };
	VkPhysicalDeviceProperties2 properties = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
		.pNext = &driver };
	vkGetPhysicalDeviceProperties2(device, &properties);
	const VkPhysicalDeviceProperties *p = &properties.properties;
	SAY("device \"%s\", API %u.%u.%u, driver \"%s\" \"%s\", conformance %u.%u.%u.%u", p->deviceName,
		VK_API_VERSION_MAJOR(p->apiVersion), VK_API_VERSION_MINOR(p->apiVersion),
		VK_API_VERSION_PATCH(p->apiVersion), driver.driverName, driver.driverInfo,
		driver.conformanceVersion.major, driver.conformanceVersion.minor,
		driver.conformanceVersion.subminor, driver.conformanceVersion.patch);

	vkEnumerateDeviceExtensionProperties(device, NULL, &sExtensionCount, NULL);
	sExtensions = calloc(sExtensionCount, sizeof(*sExtensions));
	vkEnumerateDeviceExtensionProperties(device, NULL, &sExtensionCount, sExtensions);

	VkPhysicalDeviceVulkan13Features f13 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES };
	VkPhysicalDeviceVulkan12Features f12 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		.pNext = &f13 };
	VkPhysicalDeviceVulkan11Features f11 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
		.pNext = &f12 };
	VkPhysicalDeviceFeatures2 features = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
		.pNext = &f11 };
	vkGetPhysicalDeviceFeatures2(device, &features);
	const VkPhysicalDeviceFeatures *f = &features.features;

	/* the two required lists: [4.5] and [5.3] mark where each item is checked */
	need(has_extension(VK_KHR_SWAPCHAIN_EXTENSION_NAME), "VK_KHR_swapchain", true, true);
	need(has_extension(VK_EXT_PROVOKING_VERTEX_EXTENSION_NAME), "VK_EXT_provoking_vertex", true, false);
	need(has_extension(VK_KHR_DYNAMIC_RENDERING_EXTENSION_NAME), "VK_KHR_dynamic_rendering", false, true);
	need(has_extension(VK_KHR_TIMELINE_SEMAPHORE_EXTENSION_NAME), "VK_KHR_timeline_semaphore", false, true);
	need(has_extension(VK_KHR_BUFFER_DEVICE_ADDRESS_EXTENSION_NAME), "VK_KHR_buffer_device_address",
		false, true);
	need(has_extension(VK_KHR_SEPARATE_DEPTH_STENCIL_LAYOUTS_EXTENSION_NAME),
		"VK_KHR_separate_depth_stencil_layouts", false, true);
	need(f->geometryShader, "geometryShader", true, true);
	need(f->logicOp, "logicOp", true, false);
	need(f->dualSrcBlend, "dualSrcBlend", true, true);
	need(f->imageCubeArray, "imageCubeArray", true, true);
	need(f->multiDrawIndirect, "multiDrawIndirect", true, false);
	need(f->multiViewport, "multiViewport", true, false);
	need(f->shaderClipDistance, "shaderClipDistance", true, false);
	need(f->drawIndirectFirstInstance, "drawIndirectFirstInstance", true, true);
	need(f->fragmentStoresAndAtomics, "fragmentStoresAndAtomics", true, true);
	need(f12.timelineSemaphore, "timelineSemaphore (feature)", true, false);
	need(f12.bufferDeviceAddress, "bufferDeviceAddress (feature)", true, false);
	SAY("Blender 4.5 list: %d missing; Blender 5.3 list: %d missing", sMissing45, sMissing53);

	/* information: what the lists do not check but the draw engines use */
	SAY("info dynamicRendering %u, shaderDrawParameters %u, vertexPipelineStoresAndAtomics %u, "
		"shaderStorageImageWriteWithoutFormat %u, depthClamp %u, textureCompressionBC %u, wideLines %u",
		f13.dynamicRendering, f11.shaderDrawParameters, f->vertexPipelineStoresAndAtomics,
		f->shaderStorageImageWriteWithoutFormat, f->depthClamp, f->textureCompressionBC, f->wideLines);
	const char *const optional[] = {
		VK_KHR_DYNAMIC_RENDERING_LOCAL_READ_EXTENSION_NAME,
		VK_EXT_DYNAMIC_RENDERING_UNUSED_ATTACHMENTS_EXTENSION_NAME,
		VK_KHR_FRAGMENT_SHADER_BARYCENTRIC_EXTENSION_NAME, VK_EXT_SHADER_VIEWPORT_INDEX_LAYER_EXTENSION_NAME,
		VK_EXT_SHADER_STENCIL_EXPORT_EXTENSION_NAME, VK_KHR_MAINTENANCE_4_EXTENSION_NAME,
		VK_EXT_LINE_RASTERIZATION_EXTENSION_NAME, VK_EXT_EXTENDED_DYNAMIC_STATE_EXTENSION_NAME,
		VK_EXT_VERTEX_INPUT_DYNAMIC_STATE_EXTENSION_NAME, VK_EXT_GRAPHICS_PIPELINE_LIBRARY_EXTENSION_NAME,
		VK_EXT_HEADLESS_SURFACE_EXTENSION_NAME,
	};
	for (size_t i = 0; i < sizeof(optional) / sizeof(optional[0]); i++)
		SAY("info %s %s", optional[i], has_extension(optional[i]) ? "yes" : "no");
	const VkPhysicalDeviceLimits *l = &p->limits;
	SAY("limit maxPerStageDescriptorStorageBuffers %u (Blender's GL path needs 12; the 5.x draw manager "
		"binds slots 8-11 in vertex shaders)", l->maxPerStageDescriptorStorageBuffers);
	SAY("limit maxPerStageDescriptorUniformBuffers %u", l->maxPerStageDescriptorUniformBuffers);
	SAY("limit maxPerStageDescriptorSampledImages %u", l->maxPerStageDescriptorSampledImages);
	SAY("limit maxPerStageDescriptorStorageImages %u", l->maxPerStageDescriptorStorageImages);
	SAY("limit maxPerStageResources %u", l->maxPerStageResources);
	SAY("limit maxBoundDescriptorSets %u", l->maxBoundDescriptorSets);
	SAY("limit maxColorAttachments %u", l->maxColorAttachments);
	SAY("limit maxPushConstantsSize %u", l->maxPushConstantsSize);
	SAY("limit maxComputeWorkGroupInvocations %u", l->maxComputeWorkGroupInvocations);
	SAY("limit maxComputeSharedMemorySize %u", l->maxComputeSharedMemorySize);
	SAY("limit maxStorageBufferRange %u", l->maxStorageBufferRange);
	SAY("limit maxUniformBufferRange %u", l->maxUniformBufferRange);
	SAY("limit maxImageDimension2D %u", l->maxImageDimension2D);
	SAY("limit maxImageArrayLayers %u", l->maxImageArrayLayers);
	SAY("limit maxTexelBufferElements %u", l->maxTexelBufferElements);
	SAY("limit maxVertexOutputComponents %u", l->maxVertexOutputComponents);
	SAY("limit maxViewports %u", l->maxViewports);

	free(sExtensions);
	vkDestroyInstance(instance, NULL);
	return sMissing53 == 0 ? 0 : 1;
}
