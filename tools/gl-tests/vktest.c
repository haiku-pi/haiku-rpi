/*
 * vktest — headless Vulkan smoke test for the Haiku GPU bring-up (V3DV on the Pi 4's V3D): no window
 * system, no surface. Lists the instance and the physical devices (vulkaninfo's essentials), then on
 * the first device that has a graphics + compute queue:
 *
 *   render     a triangle into a 64x64 RGBA8 image (render pass clear + draw), copied into a host
 *              buffer by a second submission that waits for the first on a semaphore; checks pixels
 *              inside and outside the triangle and its area. Fences: vkWaitForFences.
 *   timestamp  vkCmdResetQueryPool + two vkCmdWriteTimestamp around the render pass, results copied by
 *              vkCmdCopyQueryPoolResults (with availability) and read by vkGetQueryPoolResults
 *              (the kernel driver's CPU jobs).
 *   compute    a compute shader fills a storage buffer (vkCmdDispatch), checked word by word.
 *   indirect   the same through vkCmdDispatchIndirect with a smaller grid: the kernel driver's
 *              indirect dispatch CPU job sets up the dispatch and patches gl_NumWorkGroups.
 *   frames     -n N: N more render submissions, timed.
 *
 * Every line starts with "VK " so a boot script can send it to the serial console (> /dev/dprintf).
 * Exit status 0 = PASS.
 *
 *   vktest [-n FRAMES] [-i]       -i: only list the devices (vulkaninfo-style), no tests
 *
 * The shaders are SPIR-V in vk-shaders/<name>.spv.h, made from the GLSL next to them by vk-shaders/regen.sh.
 */

#include <vulkan/vulkan.h>

#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "vk-shaders/fill.comp.spv.h"
#include "vk-shaders/tri.frag.spv.h"
#include "vk-shaders/tri.vert.spv.h"

#define SAY(...) do { printf("VK " __VA_ARGS__); printf("\n"); fflush(stdout); } while (0)

#define CHECK_VK(call) \
	do { \
		VkResult result_ = (call); \
		if (result_ != VK_SUCCESS) { \
			SAY("call %s failed: %s (%d) BAD", #call, result_name(result_), result_); \
			return false; \
		} \
	} while (0)

enum {
	kSize = 64,
	kComputeGroups = 64,
	kComputeLocalSize = 64,
	kComputeWords = kComputeGroups * kComputeLocalSize,
	kIndirectGroups = 32,
	kDirectSalt = 7,
	kIndirectSalt = 1234,
	kUntouched = 0xdeadbeef,
};

static const uint8_t kClearColor[4] = { 0, 0, 64, 255 };
static const uint8_t kTriangleColor[4] = { 255, 0, 255, 255 };

static int sFailures = 0;

struct buffer {
	VkBuffer buffer;
	VkDeviceMemory memory;
	void *map;
	VkDeviceSize size;
};

struct context {
	VkInstance instance;
	VkPhysicalDevice physical;
	VkPhysicalDeviceProperties properties;
	VkPhysicalDeviceMemoryProperties memory;
	uint32_t family;
	uint32_t timestamp_bits;
	VkDevice device;
	VkQueue queue;
	VkCommandPool pool;
};


static const char *
result_name(VkResult result)
{
	switch (result) {
		case VK_SUCCESS: return "VK_SUCCESS";
		case VK_NOT_READY: return "VK_NOT_READY";
		case VK_TIMEOUT: return "VK_TIMEOUT";
		case VK_INCOMPLETE: return "VK_INCOMPLETE";
		case VK_ERROR_OUT_OF_HOST_MEMORY: return "VK_ERROR_OUT_OF_HOST_MEMORY";
		case VK_ERROR_OUT_OF_DEVICE_MEMORY: return "VK_ERROR_OUT_OF_DEVICE_MEMORY";
		case VK_ERROR_INITIALIZATION_FAILED: return "VK_ERROR_INITIALIZATION_FAILED";
		case VK_ERROR_DEVICE_LOST: return "VK_ERROR_DEVICE_LOST";
		case VK_ERROR_MEMORY_MAP_FAILED: return "VK_ERROR_MEMORY_MAP_FAILED";
		case VK_ERROR_EXTENSION_NOT_PRESENT: return "VK_ERROR_EXTENSION_NOT_PRESENT";
		case VK_ERROR_FEATURE_NOT_PRESENT: return "VK_ERROR_FEATURE_NOT_PRESENT";
		case VK_ERROR_INCOMPATIBLE_DRIVER: return "VK_ERROR_INCOMPATIBLE_DRIVER";
		default: return "?";
	}
}


static double
now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}


static void
check(bool ok, const char *name, const char *format, ...)
	__attribute__((format(printf, 3, 4)));

static void
check(bool ok, const char *name, const char *format, ...)
{
	char text[256];
	va_list args;
	va_start(args, format);
	vsnprintf(text, sizeof(text), format, args);
	va_end(args);
	SAY("check %s %s %s", name, text, ok ? "ok" : "BAD");
	if (!ok)
		sFailures++;
}


//	#pragma mark - device listing


static const char *
device_type_name(VkPhysicalDeviceType type)
{
	switch (type) {
		case VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU: return "integrated-gpu";
		case VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU: return "discrete-gpu";
		case VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU: return "virtual-gpu";
		case VK_PHYSICAL_DEVICE_TYPE_CPU: return "cpu";
		default: return "other";
	}
}


static void
list_device(uint32_t index, VkPhysicalDevice physical)
{
	VkPhysicalDeviceProperties properties;
	vkGetPhysicalDeviceProperties(physical, &properties);
	const uint32_t api = properties.apiVersion;
	SAY("device %u: %s, %s, Vulkan %u.%u.%u, driver version %#x, vendor %#x, device %#x", index,
		properties.deviceName, device_type_name(properties.deviceType), VK_API_VERSION_MAJOR(api),
		VK_API_VERSION_MINOR(api), VK_API_VERSION_PATCH(api), properties.driverVersion,
		properties.vendorID, properties.deviceID);

	if (api >= VK_API_VERSION_1_2) {
		VkPhysicalDeviceDriverProperties driver = {
			.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES,
		};
		VkPhysicalDeviceProperties2 properties2 = {
			.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
			.pNext = &driver,
		};
		vkGetPhysicalDeviceProperties2(physical, &properties2);
		SAY("device %u driver: %s (%s), conformance %u.%u.%u.%u", index, driver.driverName,
			driver.driverInfo, driver.conformanceVersion.major, driver.conformanceVersion.minor,
			driver.conformanceVersion.subminor, driver.conformanceVersion.patch);
	}

	const VkPhysicalDeviceLimits *limits = &properties.limits;
	SAY("device %u limits: image2D %u, viewports %u, color attachments %u, push constants %u, "
		"compute invocations %u, compute groups %u x %u x %u, timestamp period %.3f ns, "
		"min uniform alignment %llu, min storage alignment %llu", index,
		limits->maxImageDimension2D, limits->maxViewports, limits->maxColorAttachments,
		limits->maxPushConstantsSize, limits->maxComputeWorkGroupInvocations,
		limits->maxComputeWorkGroupCount[0], limits->maxComputeWorkGroupCount[1],
		limits->maxComputeWorkGroupCount[2], limits->timestampPeriod,
		(unsigned long long)limits->minUniformBufferOffsetAlignment,
		(unsigned long long)limits->minStorageBufferOffsetAlignment);

	VkPhysicalDeviceMemoryProperties memory;
	vkGetPhysicalDeviceMemoryProperties(physical, &memory);
	for (uint32_t i = 0; i < memory.memoryHeapCount; i++) {
		SAY("device %u heap %u: %llu MiB, flags %#x", index, i,
			(unsigned long long)(memory.memoryHeaps[i].size >> 20), memory.memoryHeaps[i].flags);
	}
	for (uint32_t i = 0; i < memory.memoryTypeCount; i++) {
		SAY("device %u memory type %u: heap %u, flags %#x", index, i,
			memory.memoryTypes[i].heapIndex, memory.memoryTypes[i].propertyFlags);
	}

	uint32_t familyCount = 0;
	vkGetPhysicalDeviceQueueFamilyProperties(physical, &familyCount, NULL);
	VkQueueFamilyProperties families[16];
	if (familyCount > 16)
		familyCount = 16;
	vkGetPhysicalDeviceQueueFamilyProperties(physical, &familyCount, families);
	for (uint32_t i = 0; i < familyCount; i++) {
		SAY("device %u queue family %u: %u queues, flags %#x, timestamp bits %u", index, i,
			families[i].queueCount, families[i].queueFlags, families[i].timestampValidBits);
	}

	uint32_t extensionCount = 0;
	vkEnumerateDeviceExtensionProperties(physical, NULL, &extensionCount, NULL);
	VkExtensionProperties *extensions = calloc(extensionCount, sizeof(VkExtensionProperties));
	if (extensions != NULL) {
		vkEnumerateDeviceExtensionProperties(physical, NULL, &extensionCount, extensions);
		SAY("device %u: %u device extensions", index, extensionCount);
		for (uint32_t i = 0; i < extensionCount; i++)
			SAY("device %u extension %s %u", index, extensions[i].extensionName,
				extensions[i].specVersion);
		free(extensions);
	}
}


static bool
create_instance(struct context *context)
{
	uint32_t version = VK_API_VERSION_1_0;
	vkEnumerateInstanceVersion(&version);
	SAY("instance version %u.%u.%u", VK_API_VERSION_MAJOR(version), VK_API_VERSION_MINOR(version),
		VK_API_VERSION_PATCH(version));

	uint32_t extensionCount = 0;
	vkEnumerateInstanceExtensionProperties(NULL, &extensionCount, NULL);
	VkExtensionProperties extensions[64];
	if (extensionCount > 64)
		extensionCount = 64;
	vkEnumerateInstanceExtensionProperties(NULL, &extensionCount, extensions);
	for (uint32_t i = 0; i < extensionCount; i++)
		SAY("instance extension %s %u", extensions[i].extensionName, extensions[i].specVersion);

	const VkApplicationInfo application = {
		.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
		.pApplicationName = "vktest",
		.apiVersion = version >= VK_API_VERSION_1_2 ? VK_API_VERSION_1_2 : version,
	};
	const VkInstanceCreateInfo info = {
		.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
		.pApplicationInfo = &application,
	};
	CHECK_VK(vkCreateInstance(&info, NULL, &context->instance));
	return true;
}


static bool
pick_device(struct context *context, bool listOnly)
{
	uint32_t count = 0;
	CHECK_VK(vkEnumeratePhysicalDevices(context->instance, &count, NULL));
	SAY("physical devices: %u", count);
	if (count == 0) {
		SAY("no Vulkan device: is the ICD found (VK_LOADER_DEBUG=all)? BAD");
		return false;
	}
	VkPhysicalDevice devices[8];
	if (count > 8)
		count = 8;
	CHECK_VK(vkEnumeratePhysicalDevices(context->instance, &count, devices));

	for (uint32_t i = 0; i < count; i++)
		list_device(i, devices[i]);
	if (listOnly)
		return true;

	for (uint32_t i = 0; i < count; i++) {
		uint32_t familyCount = 16;
		VkQueueFamilyProperties families[16];
		vkGetPhysicalDeviceQueueFamilyProperties(devices[i], &familyCount, families);
		for (uint32_t f = 0; f < familyCount; f++) {
			const VkQueueFlags wanted = VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT;
			if ((families[f].queueFlags & wanted) == wanted) {
				context->physical = devices[i];
				context->family = f;
				context->timestamp_bits = families[f].timestampValidBits;
				vkGetPhysicalDeviceProperties(devices[i], &context->properties);
				vkGetPhysicalDeviceMemoryProperties(devices[i], &context->memory);
				SAY("using device %u (%s), queue family %u", i, context->properties.deviceName, f);
				return true;
			}
		}
	}
	SAY("no device with a graphics + compute queue BAD");
	return false;
}


static bool
create_device(struct context *context)
{
	const float priority = 1.0f;
	const VkDeviceQueueCreateInfo queue = {
		.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
		.queueFamilyIndex = context->family,
		.queueCount = 1,
		.pQueuePriorities = &priority,
	};
	const VkDeviceCreateInfo info = {
		.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
		.queueCreateInfoCount = 1,
		.pQueueCreateInfos = &queue,
	};
	CHECK_VK(vkCreateDevice(context->physical, &info, NULL, &context->device));
	vkGetDeviceQueue(context->device, context->family, 0, &context->queue);

	const VkCommandPoolCreateInfo pool = {
		.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
		.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
		.queueFamilyIndex = context->family,
	};
	CHECK_VK(vkCreateCommandPool(context->device, &pool, NULL, &context->pool));
	SAY("device created");
	return true;
}


//	#pragma mark - helpers


static int32_t
find_memory_type(struct context *context, uint32_t typeBits, VkMemoryPropertyFlags flags)
{
	for (uint32_t i = 0; i < context->memory.memoryTypeCount; i++) {
		if ((typeBits & (1u << i)) != 0
			&& (context->memory.memoryTypes[i].propertyFlags & flags) == flags)
			return i;
	}
	return -1;
}


static bool
allocate(struct context *context, VkMemoryRequirements requirements, VkMemoryPropertyFlags flags,
	VkDeviceMemory *_memory)
{
	int32_t type = find_memory_type(context, requirements.memoryTypeBits, flags);
	if (type < 0) {
		SAY("no memory type with flags %#x BAD", flags);
		return false;
	}
	const VkMemoryAllocateInfo info = {
		.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
		.allocationSize = requirements.size,
		.memoryTypeIndex = type,
	};
	CHECK_VK(vkAllocateMemory(context->device, &info, NULL, _memory));
	return true;
}


/*!	A host-visible, coherent, mapped buffer. */
static bool
create_buffer(struct context *context, VkDeviceSize size, VkBufferUsageFlags usage,
	struct buffer *buffer)
{
	buffer->size = size;
	const VkBufferCreateInfo info = {
		.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
		.size = size,
		.usage = usage,
		.sharingMode = VK_SHARING_MODE_EXCLUSIVE,
	};
	CHECK_VK(vkCreateBuffer(context->device, &info, NULL, &buffer->buffer));
	VkMemoryRequirements requirements;
	vkGetBufferMemoryRequirements(context->device, buffer->buffer, &requirements);
	if (!allocate(context, requirements,
			VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
			&buffer->memory)) {
		return false;
	}
	CHECK_VK(vkBindBufferMemory(context->device, buffer->buffer, buffer->memory, 0));
	CHECK_VK(vkMapMemory(context->device, buffer->memory, 0, VK_WHOLE_SIZE, 0, &buffer->map));
	return true;
}


static void
destroy_buffer(struct context *context, struct buffer *buffer)
{
	if (buffer->map != NULL)
		vkUnmapMemory(context->device, buffer->memory);
	vkDestroyBuffer(context->device, buffer->buffer, NULL);
	vkFreeMemory(context->device, buffer->memory, NULL);
	memset(buffer, 0, sizeof(*buffer));
}


static bool
create_shader(struct context *context, const uint32_t *code, size_t size, VkShaderModule *_module)
{
	const VkShaderModuleCreateInfo info = {
		.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
		.codeSize = size,
		.pCode = code,
	};
	CHECK_VK(vkCreateShaderModule(context->device, &info, NULL, _module));
	return true;
}


static bool
begin_commands(struct context *context, VkCommandBuffer *_commands)
{
	const VkCommandBufferAllocateInfo info = {
		.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
		.commandPool = context->pool,
		.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
		.commandBufferCount = 1,
	};
	CHECK_VK(vkAllocateCommandBuffers(context->device, &info, _commands));
	// (the render commands are submitted again while pending: -n)
	const VkCommandBufferBeginInfo begin = {
		.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
		.flags = VK_COMMAND_BUFFER_USAGE_SIMULTANEOUS_USE_BIT,
	};
	CHECK_VK(vkBeginCommandBuffer(*_commands, &begin));
	return true;
}


/*!	Submits \a commands (waiting for \a wait at \a waitStage, signalling \a signal, either may be
	VK_NULL_HANDLE) and, if \a fence is given, waits for it.
*/
static bool
submit(struct context *context, VkCommandBuffer commands, VkSemaphore wait,
	VkPipelineStageFlags waitStage, VkSemaphore signal, VkFence fence)
{
	const VkSubmitInfo info = {
		.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
		.waitSemaphoreCount = wait != VK_NULL_HANDLE ? 1 : 0,
		.pWaitSemaphores = &wait,
		.pWaitDstStageMask = &waitStage,
		.commandBufferCount = 1,
		.pCommandBuffers = &commands,
		.signalSemaphoreCount = signal != VK_NULL_HANDLE ? 1 : 0,
		.pSignalSemaphores = &signal,
	};
	CHECK_VK(vkQueueSubmit(context->queue, 1, &info, fence));
	if (fence != VK_NULL_HANDLE) {
		CHECK_VK(vkWaitForFences(context->device, 1, &fence, VK_TRUE, 10ull * 1000 * 1000 * 1000));
		CHECK_VK(vkResetFences(context->device, 1, &fence));
	}
	return true;
}


//	#pragma mark - render + timestamps


struct render {
	VkImage image;
	VkDeviceMemory memory;
	VkImageView view;
	VkRenderPass pass;
	VkFramebuffer framebuffer;
	VkPipelineLayout layout;
	VkPipeline pipeline;
	VkQueryPool queries;
	VkCommandBuffer draw;
	VkCommandBuffer copy;
	struct buffer pixels;
	struct buffer times;
};


static bool
create_render(struct context *context, struct render *render)
{
	VkDevice device = context->device;

	const VkImageCreateInfo image = {
		.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
		.imageType = VK_IMAGE_TYPE_2D,
		.format = VK_FORMAT_R8G8B8A8_UNORM,
		.extent = { kSize, kSize, 1 },
		.mipLevels = 1,
		.arrayLayers = 1,
		.samples = VK_SAMPLE_COUNT_1_BIT,
		.tiling = VK_IMAGE_TILING_OPTIMAL,
		.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
		.sharingMode = VK_SHARING_MODE_EXCLUSIVE,
		.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
	};
	CHECK_VK(vkCreateImage(device, &image, NULL, &render->image));
	VkMemoryRequirements requirements;
	vkGetImageMemoryRequirements(device, render->image, &requirements);
	if (!allocate(context, requirements, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, &render->memory))
		return false;
	CHECK_VK(vkBindImageMemory(device, render->image, render->memory, 0));

	const VkImageViewCreateInfo view = {
		.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
		.image = render->image,
		.viewType = VK_IMAGE_VIEW_TYPE_2D,
		.format = VK_FORMAT_R8G8B8A8_UNORM,
		.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
	};
	CHECK_VK(vkCreateImageView(device, &view, NULL, &render->view));

	const VkAttachmentDescription attachment = {
		.format = VK_FORMAT_R8G8B8A8_UNORM,
		.samples = VK_SAMPLE_COUNT_1_BIT,
		.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
		.storeOp = VK_ATTACHMENT_STORE_OP_STORE,
		.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
		.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
		.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
		.finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
	};
	const VkAttachmentReference reference = { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
	const VkSubpassDescription subpass = {
		.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
		.colorAttachmentCount = 1,
		.pColorAttachments = &reference,
	};
	// the copy (a later submission) reads what the render pass wrote
	const VkSubpassDependency dependency = {
		.srcSubpass = 0,
		.dstSubpass = VK_SUBPASS_EXTERNAL,
		.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
		.dstStageMask = VK_PIPELINE_STAGE_TRANSFER_BIT,
		.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
		.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
	};
	const VkRenderPassCreateInfo pass = {
		.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
		.attachmentCount = 1,
		.pAttachments = &attachment,
		.subpassCount = 1,
		.pSubpasses = &subpass,
		.dependencyCount = 1,
		.pDependencies = &dependency,
	};
	CHECK_VK(vkCreateRenderPass(device, &pass, NULL, &render->pass));

	const VkFramebufferCreateInfo framebuffer = {
		.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
		.renderPass = render->pass,
		.attachmentCount = 1,
		.pAttachments = &render->view,
		.width = kSize,
		.height = kSize,
		.layers = 1,
	};
	CHECK_VK(vkCreateFramebuffer(device, &framebuffer, NULL, &render->framebuffer));

	VkShaderModule vertex, fragment;
	if (!create_shader(context, tri_vert_spv, sizeof(tri_vert_spv), &vertex)
		|| !create_shader(context, tri_frag_spv, sizeof(tri_frag_spv), &fragment)) {
		return false;
	}
	const VkPipelineShaderStageCreateInfo stages[2] = {
		{
			.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
			.stage = VK_SHADER_STAGE_VERTEX_BIT,
			.module = vertex,
			.pName = "main",
		},
		{
			.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
			.stage = VK_SHADER_STAGE_FRAGMENT_BIT,
			.module = fragment,
			.pName = "main",
		},
	};
	const VkPipelineVertexInputStateCreateInfo vertexInput = {
		.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
	};
	const VkPipelineInputAssemblyStateCreateInfo assembly = {
		.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
	};
	const VkViewport viewport = { 0, 0, kSize, kSize, 0, 1 };
	const VkRect2D scissor = { { 0, 0 }, { kSize, kSize } };
	const VkPipelineViewportStateCreateInfo viewportState = {
		.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		.viewportCount = 1,
		.pViewports = &viewport,
		.scissorCount = 1,
		.pScissors = &scissor,
	};
	const VkPipelineRasterizationStateCreateInfo rasterization = {
		.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		.polygonMode = VK_POLYGON_MODE_FILL,
		.cullMode = VK_CULL_MODE_NONE,
		.frontFace = VK_FRONT_FACE_CLOCKWISE,
		.lineWidth = 1.0f,
	};
	const VkPipelineMultisampleStateCreateInfo multisample = {
		.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT,
	};
	const VkPipelineColorBlendAttachmentState blendAttachment = {
		.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT
			| VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT,
	};
	const VkPipelineColorBlendStateCreateInfo blend = {
		.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		.attachmentCount = 1,
		.pAttachments = &blendAttachment,
	};
	const VkPipelineLayoutCreateInfo layout = {
		.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
	};
	CHECK_VK(vkCreatePipelineLayout(device, &layout, NULL, &render->layout));
	const VkGraphicsPipelineCreateInfo pipeline = {
		.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
		.stageCount = 2,
		.pStages = stages,
		.pVertexInputState = &vertexInput,
		.pInputAssemblyState = &assembly,
		.pViewportState = &viewportState,
		.pRasterizationState = &rasterization,
		.pMultisampleState = &multisample,
		.pColorBlendState = &blend,
		.layout = render->layout,
		.renderPass = render->pass,
		.subpass = 0,
	};
	const double start = now_ms();
	CHECK_VK(vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &pipeline, NULL,
		&render->pipeline));
	SAY("graphics pipeline compiled in %.1f ms", now_ms() - start);
	vkDestroyShaderModule(device, vertex, NULL);
	vkDestroyShaderModule(device, fragment, NULL);

	if (context->timestamp_bits > 0) {
		const VkQueryPoolCreateInfo queries = {
			.sType = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO,
			.queryType = VK_QUERY_TYPE_TIMESTAMP,
			.queryCount = 2,
		};
		CHECK_VK(vkCreateQueryPool(device, &queries, NULL, &render->queries));
	}

	if (!create_buffer(context, kSize * kSize * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT,
			&render->pixels)
		|| !create_buffer(context, 2 * 2 * sizeof(uint64_t), VK_BUFFER_USAGE_TRANSFER_DST_BIT,
			&render->times)) {
		return false;
	}
	memset(render->pixels.map, 0x55, render->pixels.size);
	memset(render->times.map, 0, render->times.size);

	// draw: reset the queries, time stamp, the render pass, time stamp
	if (!begin_commands(context, &render->draw))
		return false;
	if (render->queries != VK_NULL_HANDLE) {
		vkCmdResetQueryPool(render->draw, render->queries, 0, 2);
		vkCmdWriteTimestamp(render->draw, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, render->queries, 0);
	}
	const VkClearValue clear = { .color = { .float32 = { kClearColor[0] / 255.0f,
		kClearColor[1] / 255.0f, kClearColor[2] / 255.0f, kClearColor[3] / 255.0f } } };
	const VkRenderPassBeginInfo begin = {
		.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
		.renderPass = render->pass,
		.framebuffer = render->framebuffer,
		.renderArea = { { 0, 0 }, { kSize, kSize } },
		.clearValueCount = 1,
		.pClearValues = &clear,
	};
	vkCmdBeginRenderPass(render->draw, &begin, VK_SUBPASS_CONTENTS_INLINE);
	vkCmdBindPipeline(render->draw, VK_PIPELINE_BIND_POINT_GRAPHICS, render->pipeline);
	vkCmdDraw(render->draw, 3, 1, 0, 0);
	vkCmdEndRenderPass(render->draw);
	if (render->queries != VK_NULL_HANDLE) {
		vkCmdWriteTimestamp(render->draw, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, render->queries,
			1);
	}
	CHECK_VK(vkEndCommandBuffer(render->draw));

	// copy: the image into the host buffer, the query results next to it
	if (!begin_commands(context, &render->copy))
		return false;
	const VkBufferImageCopy region = {
		.imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
		.imageExtent = { kSize, kSize, 1 },
	};
	vkCmdCopyImageToBuffer(render->copy, render->image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
		render->pixels.buffer, 1, &region);
	if (render->queries != VK_NULL_HANDLE) {
		vkCmdCopyQueryPoolResults(render->copy, render->queries, 0, 2, render->times.buffer, 0,
			2 * sizeof(uint64_t), VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WAIT_BIT
				| VK_QUERY_RESULT_WITH_AVAILABILITY_BIT);
	}
	const VkMemoryBarrier toHost = {
		.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
		.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
		.dstAccessMask = VK_ACCESS_HOST_READ_BIT,
	};
	vkCmdPipelineBarrier(render->copy, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
		0, 1, &toHost, 0, NULL, 0, NULL);
	CHECK_VK(vkEndCommandBuffer(render->copy));
	return true;
}


static const uint8_t *
pixel(const struct render *render, int x, int y)
{
	return (const uint8_t *)render->pixels.map + (y * kSize + x) * 4;
}


static bool
same_color(const uint8_t *a, const uint8_t *b)
{
	for (int i = 0; i < 4; i++) {
		if (abs((int)a[i] - (int)b[i]) > 1)
			return false;
	}
	return true;
}


static void
check_pixel(const struct render *render, const char *name, int x, int y, const uint8_t *expected)
{
	const uint8_t *p = pixel(render, x, y);
	check(same_color(p, expected), name, "(%d,%d) = %u,%u,%u,%u want %u,%u,%u,%u", x, y, p[0],
		p[1], p[2], p[3], expected[0], expected[1], expected[2], expected[3]);
}


static bool
test_render(struct context *context, struct render *render, VkSemaphore rendered, VkFence fence)
{
	const double start = now_ms();
	if (!submit(context, render->draw, VK_NULL_HANDLE, 0, rendered, VK_NULL_HANDLE)
		|| !submit(context, render->copy, rendered, VK_PIPELINE_STAGE_TRANSFER_BIT,
			VK_NULL_HANDLE, fence)) {
		sFailures++;
		return false;
	}
	SAY("render + copy submitted and waited for in %.2f ms", now_ms() - start);

	check_pixel(render, "render-inside", kSize / 2, kSize * 5 / 8, kTriangleColor);
	check_pixel(render, "render-corner", 1, 1, kClearColor);
	check_pixel(render, "render-corner", kSize - 2, kSize - 2, kClearColor);
	check_pixel(render, "render-above-apex", kSize / 2, 2, kClearColor);
	int covered = 0, other = 0;
	for (int y = 0; y < (int)kSize; y++) {
		for (int x = 0; x < (int)kSize; x++) {
			if (same_color(pixel(render, x, y), kTriangleColor))
				covered++;
			else if (!same_color(pixel(render, x, y), kClearColor))
				other++;
		}
	}
	// apex (32,8), base y = 56 from x = 8 to 56: 0.5 * 48 * 48 pixels
	const int expected = 1152;
	check(abs(covered - expected) <= kSize, "render-area", "%d pixels, want %d +- %d", covered,
		expected, kSize);
	check(other == 0, "render-other", "%d pixels neither clear nor triangle colour", other);
	return true;
}


static bool
test_timestamps(struct context *context, struct render *render)
{
	if (render->queries == VK_NULL_HANDLE) {
		SAY("timestamps: none on this queue (timestampValidBits 0), skipped");
		return true;
	}
	// what vkCmdCopyQueryPoolResults wrote: value, availability per query
	const uint64_t *copied = render->times.map;
	check(copied[1] == 1 && copied[3] == 1, "timestamp-copy-available", "%llu %llu",
		(unsigned long long)copied[1], (unsigned long long)copied[3]);
	check(copied[0] != 0 && copied[2] >= copied[0], "timestamp-copy-order", "%llu -> %llu",
		(unsigned long long)copied[0], (unsigned long long)copied[2]);

	uint64_t values[2] = { 0, 0 };
	VkResult result = vkGetQueryPoolResults(context->device, render->queries, 0, 2,
		sizeof(values), values, sizeof(uint64_t), VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WAIT_BIT);
	check(result == VK_SUCCESS && values[0] == copied[0] && values[1] == copied[2],
		"timestamp-get", "%s, %llu %llu", result_name(result), (unsigned long long)values[0],
		(unsigned long long)values[1]);
	SAY("timestamps: render pass took %.3f us (period %.3f ns)",
		(values[1] - values[0]) * context->properties.limits.timestampPeriod / 1000.0,
		context->properties.limits.timestampPeriod);
	return true;
}


//	#pragma mark - compute


static bool
test_compute(struct context *context, VkFence fence)
{
	VkDevice device = context->device;

	struct buffer data, args;
	if (!create_buffer(context, kComputeWords * sizeof(uint32_t),
			VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, &data)
		|| !create_buffer(context, sizeof(VkDispatchIndirectCommand),
			VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT, &args)) {
		sFailures++;
		return false;
	}
	const VkDispatchIndirectCommand indirect = { kIndirectGroups, 1, 1 };
	memcpy(args.map, &indirect, sizeof(indirect));

	const VkDescriptorSetLayoutBinding binding = {
		.binding = 0,
		.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
		.descriptorCount = 1,
		.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT,
	};
	const VkDescriptorSetLayoutCreateInfo setLayoutInfo = {
		.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		.bindingCount = 1,
		.pBindings = &binding,
	};
	VkDescriptorSetLayout setLayout;
	CHECK_VK(vkCreateDescriptorSetLayout(device, &setLayoutInfo, NULL, &setLayout));
	const VkPushConstantRange push = { VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(uint32_t) };
	const VkPipelineLayoutCreateInfo layoutInfo = {
		.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
		.setLayoutCount = 1,
		.pSetLayouts = &setLayout,
		.pushConstantRangeCount = 1,
		.pPushConstantRanges = &push,
	};
	VkPipelineLayout layout;
	CHECK_VK(vkCreatePipelineLayout(device, &layoutInfo, NULL, &layout));

	VkShaderModule module;
	if (!create_shader(context, fill_comp_spv, sizeof(fill_comp_spv), &module))
		return false;
	const VkComputePipelineCreateInfo pipelineInfo = {
		.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
		.stage = {
			.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
			.stage = VK_SHADER_STAGE_COMPUTE_BIT,
			.module = module,
			.pName = "main",
		},
		.layout = layout,
	};
	VkPipeline pipeline;
	CHECK_VK(vkCreateComputePipelines(device, VK_NULL_HANDLE, 1, &pipelineInfo, NULL,
		&pipeline));
	vkDestroyShaderModule(device, module, NULL);

	const VkDescriptorPoolSize poolSize = { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1 };
	const VkDescriptorPoolCreateInfo poolInfo = {
		.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
		.maxSets = 1,
		.poolSizeCount = 1,
		.pPoolSizes = &poolSize,
	};
	VkDescriptorPool pool;
	CHECK_VK(vkCreateDescriptorPool(device, &poolInfo, NULL, &pool));
	const VkDescriptorSetAllocateInfo setInfo = {
		.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
		.descriptorPool = pool,
		.descriptorSetCount = 1,
		.pSetLayouts = &setLayout,
	};
	VkDescriptorSet set;
	CHECK_VK(vkAllocateDescriptorSets(device, &setInfo, &set));
	const VkDescriptorBufferInfo bufferInfo = { data.buffer, 0, VK_WHOLE_SIZE };
	const VkWriteDescriptorSet write = {
		.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
		.dstSet = set,
		.dstBinding = 0,
		.descriptorCount = 1,
		.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
		.pBufferInfo = &bufferInfo,
	};
	vkUpdateDescriptorSets(device, 1, &write, 0, NULL);

	const VkMemoryBarrier toHost = {
		.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
		.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
		.dstAccessMask = VK_ACCESS_HOST_READ_BIT,
	};

	for (int pass = 0; pass < 2; pass++) {
		const bool isIndirect = pass == 1;
		const uint32_t salt = isIndirect ? kIndirectSalt : kDirectSalt;
		const uint32_t groups = isIndirect ? kIndirectGroups : kComputeGroups;
		const char *name = isIndirect ? "indirect" : "compute";

		uint32_t *values = data.map;
		for (uint32_t i = 0; i < kComputeWords; i++)
			values[i] = kUntouched;

		VkCommandBuffer commands;
		if (!begin_commands(context, &commands))
			return false;
		vkCmdBindPipeline(commands, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
		vkCmdBindDescriptorSets(commands, VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 1, &set, 0,
			NULL);
		vkCmdPushConstants(commands, layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(salt), &salt);
		if (isIndirect)
			vkCmdDispatchIndirect(commands, args.buffer, 0);
		else
			vkCmdDispatch(commands, groups, 1, 1);
		vkCmdPipelineBarrier(commands, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
			VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &toHost, 0, NULL, 0, NULL);
		CHECK_VK(vkEndCommandBuffer(commands));

		const double start = now_ms();
		if (!submit(context, commands, VK_NULL_HANDLE, 0, VK_NULL_HANDLE, fence)) {
			sFailures++;
			return false;
		}
		SAY("%s: %u x %u invocations in %.2f ms", name, groups, kComputeLocalSize,
			now_ms() - start);

		const uint32_t written = groups * kComputeLocalSize;
		uint32_t bad = 0, firstBad = 0;
		for (uint32_t i = 0; i < kComputeWords; i++) {
			const uint32_t want = i < written ? i * i + salt + groups : kUntouched;
			if (values[i] != want) {
				if (bad++ == 0)
					firstBad = i;
			}
		}
		check(bad == 0, name, "%u of %u words wrong (first %u: %#x want %#x)", bad,
			(uint32_t)kComputeWords, firstBad, values[firstBad],
			firstBad < written ? firstBad * firstBad + salt + groups : kUntouched);
		vkFreeCommandBuffers(device, context->pool, 1, &commands);
	}

	vkDestroyPipeline(device, pipeline, NULL);
	vkDestroyDescriptorPool(device, pool, NULL);
	vkDestroyPipelineLayout(device, layout, NULL);
	vkDestroyDescriptorSetLayout(device, setLayout, NULL);
	destroy_buffer(context, &data);
	destroy_buffer(context, &args);
	return true;
}


//	#pragma mark -


int
main(int argc, char **argv)
{
	int frames = 0;
	bool listOnly = false;
	int option;
	while ((option = getopt(argc, argv, "n:i")) != -1) {
		switch (option) {
			case 'n':
				frames = atoi(optarg);
				break;
			case 'i':
				listOnly = true;
				break;
			default:
				fprintf(stderr, "usage: %s [-n FRAMES] [-i]\n", argv[0]);
				return 2;
		}
	}

	struct context context;
	memset(&context, 0, sizeof(context));
	if (!create_instance(&context) || !pick_device(&context, listOnly)) {
		SAY("FAIL");
		return 1;
	}
	if (listOnly) {
		vkDestroyInstance(context.instance, NULL);
		SAY("PASS (list only)");
		return 0;
	}
	check(context.memory.memoryHeapCount > 0 && context.memory.memoryHeaps[0].size > 0,
		"heap", "%llu MiB", context.memory.memoryHeapCount > 0
			? (unsigned long long)(context.memory.memoryHeaps[0].size >> 20) : 0ull);
	if (!create_device(&context)) {
		SAY("FAIL");
		return 1;
	}

	VkSemaphore rendered;
	VkFence fence;
	const VkSemaphoreCreateInfo semaphoreInfo = { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
	const VkFenceCreateInfo fenceInfo = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
	if (vkCreateSemaphore(context.device, &semaphoreInfo, NULL, &rendered) != VK_SUCCESS
		|| vkCreateFence(context.device, &fenceInfo, NULL, &fence) != VK_SUCCESS) {
		SAY("semaphore/fence creation failed FAIL");
		return 1;
	}

	struct render render;
	memset(&render, 0, sizeof(render));
	if (!create_render(&context, &render))
		sFailures++;
	else if (test_render(&context, &render, rendered, fence))
		test_timestamps(&context, &render);

	test_compute(&context, fence);

	if (frames > 0 && render.draw != VK_NULL_HANDLE) {
		const double start = now_ms();
		for (int i = 0; i < frames; i++) {
			if (!submit(&context, render.draw, VK_NULL_HANDLE, 0, VK_NULL_HANDLE,
					i == frames - 1 ? fence : VK_NULL_HANDLE)) {
				sFailures++;
				break;
			}
		}
		const double elapsed = now_ms() - start;
		SAY("frames %d in %.1f ms = %.1f per second", frames, elapsed, frames * 1000.0 / elapsed);
	}

	VkResult idle = vkDeviceWaitIdle(context.device);
	check(idle == VK_SUCCESS, "device-idle", "%s", result_name(idle));

	vkDestroyFence(context.device, fence, NULL);
	vkDestroySemaphore(context.device, rendered, NULL);
	// (the rest goes with the device and the process)
	vkDestroyCommandPool(context.device, context.pool, NULL);
	vkDestroyDevice(context.device, NULL);
	vkDestroyInstance(context.instance, NULL);

	if (sFailures == 0) {
		SAY("PASS");
		return 0;
	}
	SAY("FAIL (%d)", sFailures);
	return 1;
}
