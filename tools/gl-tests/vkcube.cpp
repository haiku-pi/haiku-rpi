/*
 * vkcube — windowed Vulkan test for Haiku: a spinning cube in a BWindow, presented through Mesa's
 * Haiku window system integration (a VkHaikuSurfaceCreateInfoMESA chained to a headless surface,
 * <vulkan/vk_haiku_surface.h>; V3DV on the Pi 4). Renders for a few seconds with a changing clear
 * colour and rotation, prints the frame rate every 2 s, then presents a uniformly coloured cube and
 * reads the window back from the screen (what reached it): the corners must have the clear colour
 * and the centre the cube's.
 *
 *   vkcube [-s SECONDS] [-m fifo|mailbox|immediate] [-W WIDTH] [-H HEIGHT] [-w] [-r]
 *
 *   -s  seconds to render (default 10)
 *   -m  present mode (default fifo)
 *   -w  render and present from the window's own thread (the WSI draws in that thread) instead of a
 *       thread of ours (the WSI's presenter thread draws)
 *   -r  resize the window halfway through: the swapchain goes suboptimal and is made again
 *
 * Every line starts with "VKW " (send them to /dev/dprintf from a boot script). Exit status 0 = PASS.
 * The shaders are SPIR-V in vk-shaders/cube.*.spv.h, made by vk-shaders/regen.sh.
 */

#include <Application.h>
#include <Bitmap.h>
#include <OS.h>
#include <Screen.h>
#include <View.h>
#include <Window.h>

#include <vulkan/vulkan.h>
#include <vulkan/vk_haiku_surface.h>

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <vector>

#include "vk-shaders/cube.frag.spv.h"
#include "vk-shaders/cube.vert.spv.h"

#define SAY(...) do { printf("VKW " __VA_ARGS__); printf("\n"); fflush(stdout); } while (0)

#define CHECK_VK(call) \
	do { \
		VkResult result_ = (call); \
		if (result_ != VK_SUCCESS) { \
			SAY("call %s failed: %d BAD", #call, result_); \
			return false; \
		} \
	} while (0)

static const uint32 kMsgFrame = 'vkfr';
static const int kFramesInFlight = 2;
static const int kCheckFrames = 10;
// the screen check's colours (UNORM: exact), as B, G, R on the screen
static const float kCheckClear[3] = { 0.0f, 0.25f, 0.5f };
static const float kCheckCube[3] = { 1.0f, 0.5f, 0.0f };

static double sSeconds = 10;
static int sWidth = 640;
static int sHeight = 480;
static VkPresentModeKHR sPresentMode = VK_PRESENT_MODE_FIFO_KHR;
static bool sWindowThread = false;
static bool sResize = false;
static int sFailures = 0;


struct mat4 {
	float m[16]; // column-major, as GLSL

	static mat4 identity()
	{
		mat4 r = {};
		r.m[0] = r.m[5] = r.m[10] = r.m[15] = 1;
		return r;
	}

	mat4 operator*(const mat4& b) const
	{
		mat4 r = {};
		for (int c = 0; c < 4; c++) {
			for (int row = 0; row < 4; row++) {
				for (int k = 0; k < 4; k++)
					r.m[c * 4 + row] += m[k * 4 + row] * b.m[c * 4 + k];
			}
		}
		return r;
	}
};


static mat4
rotation(float angle, int axis)
{
	mat4 r = mat4::identity();
	const float c = cosf(angle), s = sinf(angle);
	const int a = (axis + 1) % 3, b = (axis + 2) % 3;
	r.m[a * 4 + a] = c;
	r.m[a * 4 + b] = s;
	r.m[b * 4 + a] = -s;
	r.m[b * 4 + b] = c;
	return r;
}


// a right-handed view space into Vulkan's clip space (y down, depth 0..1)
static mat4
perspective(float fovy, float aspect, float near, float far)
{
	mat4 r = {};
	const float f = 1.0f / tanf(fovy / 2);
	r.m[0] = f / aspect;
	r.m[5] = -f;
	r.m[10] = far / (near - far);
	r.m[11] = -1;
	r.m[14] = near * far / (near - far);
	return r;
}


struct PushConstants {
	mat4 mvp;
	float tint[4];
};


class Renderer {
public:
	bool Init(BView* view);
	// one frame: acquire, render, present (the swapchain is made again when it goes out of date)
	bool Frame(double time, const float* clear, const float* tint);
	void Finish();

	VkExtent2D Extent() const { return fExtent; }
	bool HostImport() const { return fHostImport; }

private:
	bool CreateSwapchain();
	void DestroySwapchainResources();
	bool RecreateSwapchain();
	bool CreatePipeline();
	uint32_t MemoryType(uint32_t bits, VkMemoryPropertyFlags flags);

	BView* fView = NULL;
	VkInstance fInstance = VK_NULL_HANDLE;
	VkSurfaceKHR fSurface = VK_NULL_HANDLE;
	VkPhysicalDevice fPhysical = VK_NULL_HANDLE;
	VkPhysicalDeviceMemoryProperties fMemory = {};
	uint32_t fFamily = 0;
	VkDevice fDevice = VK_NULL_HANDLE;
	VkQueue fQueue = VK_NULL_HANDLE;
	bool fHostImport = false;

	VkSwapchainKHR fSwapchain = VK_NULL_HANDLE;
	VkFormat fFormat = VK_FORMAT_B8G8R8A8_UNORM;
	VkExtent2D fExtent = {};
	uint32_t fImageCount = 0;
	VkImage* fImages = NULL;
	VkImageView* fViews = NULL;
	VkFramebuffer* fFramebuffers = NULL;
	VkSemaphore* fRendered = NULL; // per swapchain image
	VkImage fDepth = VK_NULL_HANDLE;
	VkDeviceMemory fDepthMemory = VK_NULL_HANDLE;
	VkImageView fDepthView = VK_NULL_HANDLE;

	VkRenderPass fRenderPass = VK_NULL_HANDLE;
	VkPipelineLayout fLayout = VK_NULL_HANDLE;
	VkPipeline fPipeline = VK_NULL_HANDLE;
	VkCommandPool fPool = VK_NULL_HANDLE;
	VkCommandBuffer fCommands[kFramesInFlight] = {};
	VkSemaphore fAcquired[kFramesInFlight] = {};
	VkFence fInFlight[kFramesInFlight] = {};
	int fFrame = 0;
	bool fSuboptimalSeen = false;
};


bool
Renderer::Init(BView* view)
{
	fView = view;

	uint32_t count = 0;
	CHECK_VK(vkEnumerateInstanceExtensionProperties(NULL, &count, NULL));
	std::vector<VkExtensionProperties> extensions(count);
	CHECK_VK(vkEnumerateInstanceExtensionProperties(NULL, &count, extensions.data()));
	bool haveSurface = false, haveHeadless = false;
	for (uint32_t i = 0; i < count; i++) {
		haveSurface |= strcmp(extensions[i].extensionName, VK_KHR_SURFACE_EXTENSION_NAME) == 0;
		haveHeadless |= strcmp(extensions[i].extensionName,
			VK_EXT_HEADLESS_SURFACE_EXTENSION_NAME) == 0;
	}
	SAY("instance extensions: %s %s, %s %s", VK_KHR_SURFACE_EXTENSION_NAME,
		haveSurface ? "yes" : "NO", VK_EXT_HEADLESS_SURFACE_EXTENSION_NAME,
		haveHeadless ? "yes" : "NO");
	if (!haveSurface || !haveHeadless) {
		SAY("no window surfaces BAD");
		return false;
	}

	const char* instanceExtensions[] = {
		VK_KHR_SURFACE_EXTENSION_NAME, VK_EXT_HEADLESS_SURFACE_EXTENSION_NAME };
	VkApplicationInfo app = {};
	app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
	app.pApplicationName = "vkcube";
	app.apiVersion = VK_API_VERSION_1_1;
	VkInstanceCreateInfo instanceInfo = {};
	instanceInfo.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
	instanceInfo.pApplicationInfo = &app;
	instanceInfo.enabledExtensionCount = 2;
	instanceInfo.ppEnabledExtensionNames = instanceExtensions;
	CHECK_VK(vkCreateInstance(&instanceInfo, NULL, &fInstance));

	// the window surface: the view, through the headless surface extension
	VkHaikuSurfaceCreateInfoMESA haikuInfo = {};
	haikuInfo.sType = VK_STRUCTURE_TYPE_HAIKU_SURFACE_CREATE_INFO_MESA;
	haikuInfo.view = view;
	VkHeadlessSurfaceCreateInfoEXT surfaceInfo = {};
	surfaceInfo.sType = VK_STRUCTURE_TYPE_HEADLESS_SURFACE_CREATE_INFO_EXT;
	surfaceInfo.pNext = &haikuInfo;
	PFN_vkCreateHeadlessSurfaceEXT createSurface = (PFN_vkCreateHeadlessSurfaceEXT)
		vkGetInstanceProcAddr(fInstance, "vkCreateHeadlessSurfaceEXT");
	if (createSurface == NULL) {
		SAY("no vkCreateHeadlessSurfaceEXT BAD");
		return false;
	}
	CHECK_VK(createSurface(fInstance, &surfaceInfo, NULL, &fSurface));

	CHECK_VK(vkEnumeratePhysicalDevices(fInstance, &count, NULL));
	if (count == 0) {
		SAY("no physical devices BAD");
		return false;
	}
	std::vector<VkPhysicalDevice> physicals(count);
	CHECK_VK(vkEnumeratePhysicalDevices(fInstance, &count, physicals.data()));
	for (uint32_t i = 0; i < count && fPhysical == VK_NULL_HANDLE; i++) {
		uint32_t families = 0;
		vkGetPhysicalDeviceQueueFamilyProperties(physicals[i], &families, NULL);
		std::vector<VkQueueFamilyProperties> properties(families);
		vkGetPhysicalDeviceQueueFamilyProperties(physicals[i], &families, properties.data());
		for (uint32_t f = 0; f < families; f++) {
			VkBool32 present = VK_FALSE;
			vkGetPhysicalDeviceSurfaceSupportKHR(physicals[i], f, fSurface, &present);
			if ((properties[f].queueFlags & VK_QUEUE_GRAPHICS_BIT) != 0 && present) {
				fPhysical = physicals[i];
				fFamily = f;
				break;
			}
		}
	}
	if (fPhysical == VK_NULL_HANDLE) {
		SAY("no device presents to the surface BAD");
		return false;
	}
	VkPhysicalDeviceProperties properties;
	vkGetPhysicalDeviceProperties(fPhysical, &properties);
	vkGetPhysicalDeviceMemoryProperties(fPhysical, &fMemory);

	CHECK_VK(vkEnumerateDeviceExtensionProperties(fPhysical, NULL, &count, NULL));
	std::vector<VkExtensionProperties> deviceExtensions(count);
	CHECK_VK(vkEnumerateDeviceExtensionProperties(fPhysical, NULL, &count,
		deviceExtensions.data()));
	bool haveSwapchain = false;
	for (uint32_t i = 0; i < count; i++) {
		haveSwapchain |= strcmp(deviceExtensions[i].extensionName,
			VK_KHR_SWAPCHAIN_EXTENSION_NAME) == 0;
		fHostImport |= strcmp(deviceExtensions[i].extensionName,
			VK_EXT_EXTERNAL_MEMORY_HOST_EXTENSION_NAME) == 0;
	}
	// with host memory import the WSI's GPU copy writes straight into the window's bitmap
	SAY("device %s, queue family %u, %s, present path: %s", properties.deviceName, fFamily,
		haveSwapchain ? "VK_KHR_swapchain" : "NO VK_KHR_swapchain",
		fHostImport ? "GPU copy into the bitmap" : "GPU copy + CPU copy");
	if (!haveSwapchain)
		return false;

	// the surface is the view's: its current extent is the view's size (a plain headless surface
	// has none, as when the loader drops the Haiku struct)
	VkSurfaceCapabilitiesKHR caps;
	CHECK_VK(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(fPhysical, fSurface, &caps));
	const bool viewSized = caps.currentExtent.width != UINT32_MAX;
	SAY("surface current extent %ux%u, images %u..%u: %s", caps.currentExtent.width,
		caps.currentExtent.height, caps.minImageCount, caps.maxImageCount,
		viewSized ? "the view's ok" : "none: a headless surface, not the view BAD");
	if (!viewSized)
		return false;

	const float priority = 1.0f;
	VkDeviceQueueCreateInfo queueInfo = {};
	queueInfo.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
	queueInfo.queueFamilyIndex = fFamily;
	queueInfo.queueCount = 1;
	queueInfo.pQueuePriorities = &priority;
	const char* swapchainExtension = VK_KHR_SWAPCHAIN_EXTENSION_NAME;
	VkDeviceCreateInfo deviceInfo = {};
	deviceInfo.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
	deviceInfo.queueCreateInfoCount = 1;
	deviceInfo.pQueueCreateInfos = &queueInfo;
	deviceInfo.enabledExtensionCount = 1;
	deviceInfo.ppEnabledExtensionNames = &swapchainExtension;
	CHECK_VK(vkCreateDevice(fPhysical, &deviceInfo, NULL, &fDevice));
	vkGetDeviceQueue(fDevice, fFamily, 0, &fQueue);

	VkCommandPoolCreateInfo poolInfo = {};
	poolInfo.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
	poolInfo.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
	poolInfo.queueFamilyIndex = fFamily;
	CHECK_VK(vkCreateCommandPool(fDevice, &poolInfo, NULL, &fPool));
	VkCommandBufferAllocateInfo commandInfo = {};
	commandInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
	commandInfo.commandPool = fPool;
	commandInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
	commandInfo.commandBufferCount = kFramesInFlight;
	CHECK_VK(vkAllocateCommandBuffers(fDevice, &commandInfo, fCommands));
	for (int i = 0; i < kFramesInFlight; i++) {
		VkSemaphoreCreateInfo semaphoreInfo = {};
		semaphoreInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
		CHECK_VK(vkCreateSemaphore(fDevice, &semaphoreInfo, NULL, &fAcquired[i]));
		VkFenceCreateInfo fenceInfo = {};
		fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
		fenceInfo.flags = VK_FENCE_CREATE_SIGNALED_BIT;
		CHECK_VK(vkCreateFence(fDevice, &fenceInfo, NULL, &fInFlight[i]));
	}

	uint32_t formatCount = 0;
	CHECK_VK(vkGetPhysicalDeviceSurfaceFormatsKHR(fPhysical, fSurface, &formatCount, NULL));
	std::vector<VkSurfaceFormatKHR> formats(formatCount);
	CHECK_VK(vkGetPhysicalDeviceSurfaceFormatsKHR(fPhysical, fSurface, &formatCount,
		formats.data()));
	fFormat = formats[0].format;
	for (uint32_t i = 0; i < formatCount; i++) {
		if (formats[i].format == VK_FORMAT_B8G8R8A8_UNORM)
			fFormat = formats[i].format;
	}

	uint32_t modeCount = 0;
	CHECK_VK(vkGetPhysicalDeviceSurfacePresentModesKHR(fPhysical, fSurface, &modeCount, NULL));
	std::vector<VkPresentModeKHR> modes(modeCount);
	CHECK_VK(vkGetPhysicalDeviceSurfacePresentModesKHR(fPhysical, fSurface, &modeCount,
		modes.data()));
	bool haveMode = false;
	char modeList[128] = "";
	for (uint32_t i = 0; i < modeCount; i++) {
		haveMode |= modes[i] == sPresentMode;
		snprintf(modeList + strlen(modeList), sizeof(modeList) - strlen(modeList), " %d",
			modes[i]);
	}
	SAY("surface formats %u (using %d), present modes%s (using %d)", formatCount, fFormat,
		modeList, sPresentMode);
	if (!haveMode) {
		SAY("present mode %d not supported BAD", sPresentMode);
		return false;
	}

	if (!CreatePipeline() || !CreateSwapchain())
		return false;
	return true;
}


uint32_t
Renderer::MemoryType(uint32_t bits, VkMemoryPropertyFlags flags)
{
	for (uint32_t i = 0; i < fMemory.memoryTypeCount; i++) {
		if ((bits & (1u << i)) != 0 && (fMemory.memoryTypes[i].propertyFlags & flags) == flags)
			return i;
	}
	return UINT32_MAX;
}


bool
Renderer::CreatePipeline()
{
	VkAttachmentDescription attachments[2] = {};
	attachments[0].format = fFormat;
	attachments[0].samples = VK_SAMPLE_COUNT_1_BIT;
	attachments[0].loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
	attachments[0].storeOp = VK_ATTACHMENT_STORE_OP_STORE;
	attachments[0].stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
	attachments[0].stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
	attachments[0].initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
	attachments[0].finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
	attachments[1].format = VK_FORMAT_D16_UNORM;
	attachments[1].samples = VK_SAMPLE_COUNT_1_BIT;
	attachments[1].loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
	attachments[1].storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
	attachments[1].stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
	attachments[1].stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
	attachments[1].initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
	attachments[1].finalLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
	VkAttachmentReference colorRef = { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
	VkAttachmentReference depthRef = { 1, VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL };
	VkSubpassDescription subpass = {};
	subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
	subpass.colorAttachmentCount = 1;
	subpass.pColorAttachments = &colorRef;
	subpass.pDepthStencilAttachment = &depthRef;
	// the acquire semaphore's wait (color output) comes before the attachments are written
	VkSubpassDependency dependency = {};
	dependency.srcSubpass = VK_SUBPASS_EXTERNAL;
	dependency.dstSubpass = 0;
	dependency.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
		| VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT;
	dependency.dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
		| VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
	dependency.srcAccessMask = VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
	dependency.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT
		| VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
	VkRenderPassCreateInfo passInfo = {};
	passInfo.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
	passInfo.attachmentCount = 2;
	passInfo.pAttachments = attachments;
	passInfo.subpassCount = 1;
	passInfo.pSubpasses = &subpass;
	passInfo.dependencyCount = 1;
	passInfo.pDependencies = &dependency;
	CHECK_VK(vkCreateRenderPass(fDevice, &passInfo, NULL, &fRenderPass));

	VkShaderModule modules[2];
	const uint32_t* code[2] = { cube_vert_spv, cube_frag_spv };
	const size_t size[2] = { sizeof(cube_vert_spv), sizeof(cube_frag_spv) };
	for (int i = 0; i < 2; i++) {
		VkShaderModuleCreateInfo moduleInfo = {};
		moduleInfo.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
		moduleInfo.codeSize = size[i];
		moduleInfo.pCode = code[i];
		CHECK_VK(vkCreateShaderModule(fDevice, &moduleInfo, NULL, &modules[i]));
	}
	VkPipelineShaderStageCreateInfo stages[2] = {};
	for (int i = 0; i < 2; i++) {
		stages[i].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
		stages[i].stage = i == 0 ? VK_SHADER_STAGE_VERTEX_BIT : VK_SHADER_STAGE_FRAGMENT_BIT;
		stages[i].module = modules[i];
		stages[i].pName = "main";
	}

	VkPushConstantRange range = { VK_SHADER_STAGE_VERTEX_BIT, 0, sizeof(PushConstants) };
	VkPipelineLayoutCreateInfo layoutInfo = {};
	layoutInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
	layoutInfo.pushConstantRangeCount = 1;
	layoutInfo.pPushConstantRanges = &range;
	CHECK_VK(vkCreatePipelineLayout(fDevice, &layoutInfo, NULL, &fLayout));

	VkPipelineVertexInputStateCreateInfo vertexInput = {};
	vertexInput.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
	VkPipelineInputAssemblyStateCreateInfo assembly = {};
	assembly.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
	assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
	VkPipelineViewportStateCreateInfo viewport = {};
	viewport.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
	viewport.viewportCount = 1;
	viewport.scissorCount = 1;
	VkPipelineRasterizationStateCreateInfo raster = {};
	raster.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
	raster.polygonMode = VK_POLYGON_MODE_FILL;
	raster.cullMode = VK_CULL_MODE_NONE;
	raster.lineWidth = 1.0f;
	VkPipelineMultisampleStateCreateInfo multisample = {};
	multisample.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
	multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
	VkPipelineDepthStencilStateCreateInfo depth = {};
	depth.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
	depth.depthTestEnable = VK_TRUE;
	depth.depthWriteEnable = VK_TRUE;
	depth.depthCompareOp = VK_COMPARE_OP_LESS;
	VkPipelineColorBlendAttachmentState blendAttachment = {};
	blendAttachment.colorWriteMask = 0xf;
	VkPipelineColorBlendStateCreateInfo blend = {};
	blend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
	blend.attachmentCount = 1;
	blend.pAttachments = &blendAttachment;
	const VkDynamicState dynamicStates[] = {
		VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
	VkPipelineDynamicStateCreateInfo dynamic = {};
	dynamic.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
	dynamic.dynamicStateCount = 2;
	dynamic.pDynamicStates = dynamicStates;

	VkGraphicsPipelineCreateInfo pipelineInfo = {};
	pipelineInfo.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
	pipelineInfo.stageCount = 2;
	pipelineInfo.pStages = stages;
	pipelineInfo.pVertexInputState = &vertexInput;
	pipelineInfo.pInputAssemblyState = &assembly;
	pipelineInfo.pViewportState = &viewport;
	pipelineInfo.pRasterizationState = &raster;
	pipelineInfo.pMultisampleState = &multisample;
	pipelineInfo.pDepthStencilState = &depth;
	pipelineInfo.pColorBlendState = &blend;
	pipelineInfo.pDynamicState = &dynamic;
	pipelineInfo.layout = fLayout;
	pipelineInfo.renderPass = fRenderPass;
	VkResult result = vkCreateGraphicsPipelines(fDevice, VK_NULL_HANDLE, 1, &pipelineInfo, NULL,
		&fPipeline);
	for (int i = 0; i < 2; i++)
		vkDestroyShaderModule(fDevice, modules[i], NULL);
	CHECK_VK(result);
	return true;
}


bool
Renderer::CreateSwapchain()
{
	VkSurfaceCapabilitiesKHR caps;
	CHECK_VK(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(fPhysical, fSurface, &caps));
	fExtent = caps.currentExtent;
	uint32_t images = caps.minImageCount + 1;
	if (caps.maxImageCount > 0 && images > caps.maxImageCount)
		images = caps.maxImageCount;

	VkSwapchainKHR old = fSwapchain;
	VkSwapchainCreateInfoKHR info = {};
	info.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
	info.surface = fSurface;
	info.minImageCount = images;
	info.imageFormat = fFormat;
	info.imageColorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;
	info.imageExtent = fExtent;
	info.imageArrayLayers = 1;
	info.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
	info.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
	info.preTransform = caps.currentTransform;
	info.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
	info.presentMode = sPresentMode;
	info.clipped = VK_TRUE;
	info.oldSwapchain = old;
	CHECK_VK(vkCreateSwapchainKHR(fDevice, &info, NULL, &fSwapchain));
	if (old != VK_NULL_HANDLE)
		vkDestroySwapchainKHR(fDevice, old, NULL);

	CHECK_VK(vkGetSwapchainImagesKHR(fDevice, fSwapchain, &fImageCount, NULL));
	fImages = new VkImage[fImageCount];
	fViews = new VkImageView[fImageCount]();
	fFramebuffers = new VkFramebuffer[fImageCount]();
	fRendered = new VkSemaphore[fImageCount]();
	CHECK_VK(vkGetSwapchainImagesKHR(fDevice, fSwapchain, &fImageCount, fImages));

	VkImageCreateInfo depthInfo = {};
	depthInfo.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
	depthInfo.imageType = VK_IMAGE_TYPE_2D;
	depthInfo.format = VK_FORMAT_D16_UNORM;
	depthInfo.extent = { fExtent.width, fExtent.height, 1 };
	depthInfo.mipLevels = 1;
	depthInfo.arrayLayers = 1;
	depthInfo.samples = VK_SAMPLE_COUNT_1_BIT;
	depthInfo.tiling = VK_IMAGE_TILING_OPTIMAL;
	depthInfo.usage = VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
	CHECK_VK(vkCreateImage(fDevice, &depthInfo, NULL, &fDepth));
	VkMemoryRequirements requirements;
	vkGetImageMemoryRequirements(fDevice, fDepth, &requirements);
	VkMemoryAllocateInfo allocation = {};
	allocation.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
	allocation.allocationSize = requirements.size;
	allocation.memoryTypeIndex = MemoryType(requirements.memoryTypeBits,
		VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
	CHECK_VK(vkAllocateMemory(fDevice, &allocation, NULL, &fDepthMemory));
	CHECK_VK(vkBindImageMemory(fDevice, fDepth, fDepthMemory, 0));
	VkImageViewCreateInfo viewInfo = {};
	viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
	viewInfo.image = fDepth;
	viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D;
	viewInfo.format = VK_FORMAT_D16_UNORM;
	viewInfo.subresourceRange = { VK_IMAGE_ASPECT_DEPTH_BIT, 0, 1, 0, 1 };
	CHECK_VK(vkCreateImageView(fDevice, &viewInfo, NULL, &fDepthView));

	for (uint32_t i = 0; i < fImageCount; i++) {
		viewInfo.image = fImages[i];
		viewInfo.format = fFormat;
		viewInfo.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
		CHECK_VK(vkCreateImageView(fDevice, &viewInfo, NULL, &fViews[i]));
		const VkImageView attachments[2] = { fViews[i], fDepthView };
		VkFramebufferCreateInfo framebufferInfo = {};
		framebufferInfo.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
		framebufferInfo.renderPass = fRenderPass;
		framebufferInfo.attachmentCount = 2;
		framebufferInfo.pAttachments = attachments;
		framebufferInfo.width = fExtent.width;
		framebufferInfo.height = fExtent.height;
		framebufferInfo.layers = 1;
		CHECK_VK(vkCreateFramebuffer(fDevice, &framebufferInfo, NULL, &fFramebuffers[i]));
		VkSemaphoreCreateInfo semaphoreInfo = {};
		semaphoreInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
		CHECK_VK(vkCreateSemaphore(fDevice, &semaphoreInfo, NULL, &fRendered[i]));
	}

	SAY("swapchain %ux%u, %u images", fExtent.width, fExtent.height, fImageCount);
	return true;
}


void
Renderer::DestroySwapchainResources()
{
	for (uint32_t i = 0; i < fImageCount; i++) {
		vkDestroyFramebuffer(fDevice, fFramebuffers[i], NULL);
		vkDestroyImageView(fDevice, fViews[i], NULL);
		vkDestroySemaphore(fDevice, fRendered[i], NULL);
	}
	delete[] fImages;
	delete[] fViews;
	delete[] fFramebuffers;
	delete[] fRendered;
	fImages = NULL;
	fViews = NULL;
	fFramebuffers = NULL;
	fRendered = NULL;
	fImageCount = 0;
	vkDestroyImageView(fDevice, fDepthView, NULL);
	vkDestroyImage(fDevice, fDepth, NULL);
	vkFreeMemory(fDevice, fDepthMemory, NULL);
	fDepthView = VK_NULL_HANDLE;
	fDepth = VK_NULL_HANDLE;
	fDepthMemory = VK_NULL_HANDLE;
}


bool
Renderer::RecreateSwapchain()
{
	vkDeviceWaitIdle(fDevice);
	DestroySwapchainResources();
	return CreateSwapchain();
}


bool
Renderer::Frame(double time, const float* clear, const float* tint)
{
	VkFence fence = fInFlight[fFrame];
	CHECK_VK(vkWaitForFences(fDevice, 1, &fence, VK_TRUE, UINT64_MAX));

	uint32_t index;
	VkResult result = vkAcquireNextImageKHR(fDevice, fSwapchain, UINT64_MAX, fAcquired[fFrame],
		VK_NULL_HANDLE, &index);
	if (result == VK_ERROR_OUT_OF_DATE_KHR) {
		SAY("acquire: out of date, making the swapchain again");
		return RecreateSwapchain();
	}
	if (result != VK_SUCCESS && result != VK_SUBOPTIMAL_KHR) {
		SAY("vkAcquireNextImageKHR failed: %d BAD", result);
		return false;
	}
	bool recreate = result == VK_SUBOPTIMAL_KHR;
	CHECK_VK(vkResetFences(fDevice, 1, &fence));

	PushConstants push;
	const float aspect = (float)fExtent.width / fExtent.height;
	mat4 model = rotation(time * 1.3f, 1) * rotation(time * 0.7f, 0);
	if (tint != NULL)
		model = rotation(0.5f, 1) * rotation(0.4f, 0);
	mat4 view = mat4::identity();
	view.m[14] = -5;
	push.mvp = perspective(45 * M_PI / 180, aspect, 0.1f, 20) * view * model;
	push.tint[0] = tint != NULL ? tint[0] : 0;
	push.tint[1] = tint != NULL ? tint[1] : 0;
	push.tint[2] = tint != NULL ? tint[2] : 0;
	push.tint[3] = tint != NULL ? 1 : 0;

	VkCommandBuffer commands = fCommands[fFrame];
	CHECK_VK(vkResetCommandBuffer(commands, 0));
	VkCommandBufferBeginInfo begin = {};
	begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
	begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
	CHECK_VK(vkBeginCommandBuffer(commands, &begin));
	VkClearValue clearValues[2] = {};
	clearValues[0].color.float32[0] = clear[0];
	clearValues[0].color.float32[1] = clear[1];
	clearValues[0].color.float32[2] = clear[2];
	clearValues[0].color.float32[3] = 1;
	clearValues[1].depthStencil.depth = 1;
	VkRenderPassBeginInfo pass = {};
	pass.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
	pass.renderPass = fRenderPass;
	pass.framebuffer = fFramebuffers[index];
	pass.renderArea.extent = fExtent;
	pass.clearValueCount = 2;
	pass.pClearValues = clearValues;
	vkCmdBeginRenderPass(commands, &pass, VK_SUBPASS_CONTENTS_INLINE);
	vkCmdBindPipeline(commands, VK_PIPELINE_BIND_POINT_GRAPHICS, fPipeline);
	VkViewport viewport = { 0, 0, (float)fExtent.width, (float)fExtent.height, 0, 1 };
	vkCmdSetViewport(commands, 0, 1, &viewport);
	VkRect2D scissor = { { 0, 0 }, fExtent };
	vkCmdSetScissor(commands, 0, 1, &scissor);
	vkCmdPushConstants(commands, fLayout, VK_SHADER_STAGE_VERTEX_BIT, 0, sizeof(push), &push);
	vkCmdDraw(commands, 36, 1, 0, 0);
	vkCmdEndRenderPass(commands);
	CHECK_VK(vkEndCommandBuffer(commands));

	const VkPipelineStageFlags waitStage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
		| VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
	VkSubmitInfo submit = {};
	submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
	submit.waitSemaphoreCount = 1;
	submit.pWaitSemaphores = &fAcquired[fFrame];
	submit.pWaitDstStageMask = &waitStage;
	submit.commandBufferCount = 1;
	submit.pCommandBuffers = &commands;
	submit.signalSemaphoreCount = 1;
	submit.pSignalSemaphores = &fRendered[index];
	CHECK_VK(vkQueueSubmit(fQueue, 1, &submit, fence));

	VkPresentInfoKHR present = {};
	present.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
	present.waitSemaphoreCount = 1;
	present.pWaitSemaphores = &fRendered[index];
	present.swapchainCount = 1;
	present.pSwapchains = &fSwapchain;
	present.pImageIndices = &index;
	result = vkQueuePresentKHR(fQueue, &present);
	fFrame = (fFrame + 1) % kFramesInFlight;
	if (result == VK_SUBOPTIMAL_KHR || result == VK_ERROR_OUT_OF_DATE_KHR)
		recreate = true;
	else if (result != VK_SUCCESS) {
		SAY("vkQueuePresentKHR failed: %d BAD", result);
		return false;
	}

	if (recreate) {
		if (!fSuboptimalSeen)
			SAY("the view's size changed: making the swapchain again");
		fSuboptimalSeen = true;
		return RecreateSwapchain();
	}
	return true;
}


void
Renderer::Finish()
{
	if (fDevice != VK_NULL_HANDLE) {
		vkDeviceWaitIdle(fDevice);
		DestroySwapchainResources();
		vkDestroySwapchainKHR(fDevice, fSwapchain, NULL);
		for (int i = 0; i < kFramesInFlight; i++) {
			vkDestroySemaphore(fDevice, fAcquired[i], NULL);
			vkDestroyFence(fDevice, fInFlight[i], NULL);
		}
		vkDestroyCommandPool(fDevice, fPool, NULL);
		vkDestroyPipeline(fDevice, fPipeline, NULL);
		vkDestroyPipelineLayout(fDevice, fLayout, NULL);
		vkDestroyRenderPass(fDevice, fRenderPass, NULL);
		vkDestroyDevice(fDevice, NULL);
	}
	if (fInstance != VK_NULL_HANDLE) {
		vkDestroySurfaceKHR(fInstance, fSurface, NULL);
		vkDestroyInstance(fInstance, NULL);
	}
	fDevice = VK_NULL_HANDLE;
	fInstance = VK_NULL_HANDLE;
}


// #pragma mark - the test


static bool
matches(const uint8_t* pixel, const float* rgb)
{
	for (int c = 0; c < 3; c++) {
		// the screen is B, G, R in memory
		if (abs(pixel[2 - c] - (int)lroundf(rgb[c] * 255)) > 3)
			return false;
	}
	return true;
}


// The window read back from the screen: the clear colour in the corners, the cube's in the centre.
static void
check_screen(BView* view)
{
	if (!view->LockLooper()) {
		SAY("screen: the window is gone BAD");
		sFailures++;
		return;
	}
	BRect frame = view->ConvertToScreen(view->Bounds());
	BScreen screen(view->Window());
	view->UnlockLooper();

	BBitmap* bitmap = NULL;
	status_t status = screen.GetBitmap(&bitmap, false, &frame);
	if (status != B_OK || bitmap == NULL) {
		SAY("screen: read back failed: %s BAD", strerror(status));
		sFailures++;
		return;
	}
	const int width = bitmap->Bounds().IntegerWidth() + 1;
	const int height = bitmap->Bounds().IntegerHeight() + 1;
	const struct { int x, y; const float* rgb; const char* name; } points[] = {
		{ 4, 4, kCheckClear, "top left" },
		{ width - 5, 4, kCheckClear, "top right" },
		{ 4, height - 5, kCheckClear, "bottom left" },
		{ width - 5, height - 5, kCheckClear, "bottom right" },
		{ width / 2, height / 2, kCheckCube, "centre" },
	};
	int bad = 0;
	for (const auto& point : points) {
		const uint8_t* pixel = (const uint8_t*)bitmap->Bits() + point.y * bitmap->BytesPerRow()
			+ point.x * 4;
		const bool ok = matches(pixel, point.rgb);
		if (!ok) {
			SAY("screen: %s (%d, %d) is %d %d %d, not %ld %ld %ld", point.name, point.x,
				point.y, pixel[2], pixel[1], pixel[0], lroundf(point.rgb[0] * 255),
				lroundf(point.rgb[1] * 255), lroundf(point.rgb[2] * 255));
			bad++;
		}
	}
	delete bitmap;
	SAY("screen %dx%d: corners clear colour, centre cube colour %s", width, height,
		bad == 0 ? "ok" : "BAD");
	if (bad != 0)
		sFailures++;
}


class Test {
public:
	Test(BWindow* window, BView* view) : fWindow(window), fView(view) {}

	// one step (a frame, mostly); false when done
	bool Step();

private:
	BWindow* fWindow;
	BView* fView;
	Renderer fRenderer;
	enum { kInit, kRun, kCheck, kDone } fPhase = kInit;
	bigtime_t fStart = 0;
	bigtime_t fReportStart = 0;
	int fFrames = 0;
	int fReportFrames = 0;
	int fCheckFrames = 0;
	bool fResized = false;
};


bool
Test::Step()
{
	switch (fPhase) {
		case kInit:
			if (!fRenderer.Init(fView)) {
				sFailures++;
				fPhase = kDone;
				break;
			}
			fStart = fReportStart = system_time();
			fPhase = kRun;
			break;

		case kRun: {
			const bigtime_t now = system_time();
			const double time = (now - fStart) / 1e6;
			if (time >= sSeconds) {
				SAY("frames %d in %.2f s = %.1f fps", fFrames, time, fFrames / time);
				fPhase = kCheck;
				break;
			}
			if (sResize && !fResized && time >= sSeconds / 2) {
				// (the window's thread when -w: its lock is held already)
				if (fWindow->LockLooper()) {
					fWindow->ResizeBy(sWidth / 4, sHeight / 4);
					fWindow->UnlockLooper();
				}
				fResized = true;
				SAY("window resized to %dx%d", sWidth + sWidth / 4, sHeight + sHeight / 4);
			}
			const float clear[3] = { 0.5f + 0.4f * sinf(time), 0.2f,
				0.5f + 0.4f * cosf(time * 0.7f) };
			if (!fRenderer.Frame(time, clear, NULL)) {
				sFailures++;
				fPhase = kDone;
				break;
			}
			fFrames++;
			fReportFrames++;
			if (now - fReportStart >= 2000000) {
				SAY("fps %.1f (%d frames in %.1f s)",
					fReportFrames * 1e6 / (now - fReportStart), fFrames, time);
				fReportFrames = 0;
				fReportStart = now;
			}
			break;
		}

		case kCheck:
			if (!fRenderer.Frame(0, kCheckClear, kCheckCube)) {
				sFailures++;
				fPhase = kDone;
				break;
			}
			if (++fCheckFrames < kCheckFrames)
				break;
			// the presenter thread draws the last frame after the present returned
			if (!sWindowThread)
				snooze(500000);
			check_screen(fView);
			fPhase = kDone;
			break;

		case kDone:
			fRenderer.Finish();
			SAY("%s (%d failure%s)", sFailures == 0 ? "PASS" : "FAIL", sFailures,
				sFailures == 1 ? "" : "s");
			be_app->PostMessage(B_QUIT_REQUESTED);
			return false;
	}
	return true;
}


static Test* sTest = NULL;


// -w: the test runs in the window's thread, one step per message
class CubeWindow : public BWindow {
public:
	CubeWindow(BRect frame)
		:
		BWindow(frame, "vkcube", B_TITLED_WINDOW, B_NOT_ZOOMABLE | B_QUIT_ON_WINDOW_CLOSE)
	{
	}

	void MessageReceived(BMessage* message) override
	{
		if (message->what == kMsgFrame) {
			if (sTest->Step())
				PostMessage(kMsgFrame);
			return;
		}
		BWindow::MessageReceived(message);
	}
};


static status_t
render_thread(void*)
{
	while (sTest->Step())
		;
	return B_OK;
}


int
main(int argc, char** argv)
{
	int opt;
	while ((opt = getopt(argc, argv, "s:m:W:H:wr")) != -1) {
		if (opt == 's')
			sSeconds = atof(optarg);
		else if (opt == 'm' && strcmp(optarg, "fifo") == 0)
			sPresentMode = VK_PRESENT_MODE_FIFO_KHR;
		else if (opt == 'm' && strcmp(optarg, "mailbox") == 0)
			sPresentMode = VK_PRESENT_MODE_MAILBOX_KHR;
		else if (opt == 'm' && strcmp(optarg, "immediate") == 0)
			sPresentMode = VK_PRESENT_MODE_IMMEDIATE_KHR;
		else if (opt == 'W')
			sWidth = atoi(optarg);
		else if (opt == 'H')
			sHeight = atoi(optarg);
		else if (opt == 'w')
			sWindowThread = true;
		else if (opt == 'r')
			sResize = true;
		else {
			fprintf(stderr, "usage: %s [-s seconds] [-m fifo|mailbox|immediate] [-W width] "
				"[-H height] [-w] [-r]\n", argv[0]);
			return 2;
		}
	}

	BApplication app("application/x-vnd.haiku-rpi-vkcube");
	SAY("begin %dx%d, %s, %s thread%s", sWidth, sHeight,
		sPresentMode == VK_PRESENT_MODE_FIFO_KHR ? "fifo"
			: sPresentMode == VK_PRESENT_MODE_MAILBOX_KHR ? "mailbox" : "immediate",
		sWindowThread ? "the window's" : "a render", sResize ? ", resize" : "");
	CubeWindow* window = new CubeWindow(BRect(100, 100, 100 + sWidth - 1, 100 + sHeight - 1));
	BView* view = new BView(window->Bounds(), "vulkan", B_FOLLOW_ALL_SIDES, 0);
	// app_server must not erase the frames
	view->SetViewColor(B_TRANSPARENT_COLOR);
	window->AddChild(view);
	sTest = new Test(window, view);
	window->Show();

	thread_id thread = -1;
	if (sWindowThread) {
		window->PostMessage(kMsgFrame);
	} else {
		thread = spawn_thread(render_thread, "vkcube render", B_NORMAL_PRIORITY, NULL);
		resume_thread(thread);
	}
	app.Run();

	if (thread >= 0) {
		status_t result;
		wait_for_thread(thread, &result);
	}
	return sFailures == 0 ? 0 : 1;
}
