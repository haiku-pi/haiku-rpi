/*
 * sdlvk — SDL2's Vulkan path on Haiku: an SDL_WINDOW_VULKAN window, its surface from
 * SDL_Vulkan_CreateSurface (SDL's Haiku video driver: a VK_EXT_headless_surface with Mesa's
 * VkHaikuSurfaceCreateInfoMESA on the window's view), a swapchain, and N seconds of frames: a
 * clear colour that changes over time and a magenta triangle. Prints "SVK " lines: the instance
 * extensions SDL asks for, the surface's extent against SDL_Vulkan_GetDrawableSize, frames per
 * second every 2 s, the total, and PASS or FAIL.
 *
 *   sdlvk [-s seconds] [-W width] [-H height] [-m fifo|mailbox|immediate] [-r]
 *         -r: the window grows by a quarter halfway through (the swapchain is made again)
 *
 * Relative mouse mode is switched on and off once (what games do; it used to dereference the
 * window's OpenGL view, which a Vulkan window does not have).
 *
 * Built by scripts/build-games.sh (it needs the SDL2 that script builds), not by this directory's
 * meson.build; run on the Pi by tools/pi-tests/sdl-vulkan.sh.
 */

#include <SDL.h>
#include <SDL_vulkan.h>
#include <vulkan/vulkan.h>

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "vk-shaders/tri.frag.spv.h"
#include "vk-shaders/tri.vert.spv.h"

#define SAY(...) do { printf("SVK " __VA_ARGS__); printf("\n"); fflush(stdout); } while (0)
#define CHECK_VK(call) do { \
		VkResult result_ = (call); \
		if (result_ != VK_SUCCESS) { \
			SAY("%s failed: %d BAD", #call, (int)result_); \
			return false; \
		} \
	} while (0)

enum { kMaxImages = 8, kFramesInFlight = 2 };

static double sSeconds = 10;
static int sWidth = 640, sHeight = 480;
static VkPresentModeKHR sPresentMode = VK_PRESENT_MODE_FIFO_KHR;
static bool sResize = false;

static SDL_Window* sWindow;
static VkInstance sInstance;
static VkSurfaceKHR sSurface;
static VkPhysicalDevice sPhysical;
static uint32_t sQueueFamily;
static VkDevice sDevice;
static VkQueue sQueue;
static VkFormat sFormat;
static VkColorSpaceKHR sColorSpace;
static VkRenderPass sRenderPass;
static VkPipelineLayout sPipelineLayout;
static VkPipeline sPipeline;
static VkCommandPool sCommandPool;
static VkCommandBuffer sCommandBuffers[kFramesInFlight];
static VkSemaphore sAcquired[kFramesInFlight];
static VkSemaphore sRendered[kMaxImages];
static VkFence sInFlight[kFramesInFlight];

static VkSwapchainKHR sSwapchain;
static VkExtent2D sExtent;
static uint32_t sImageCount;
static VkImageView sViews[kMaxImages];
static VkFramebuffer sFramebuffers[kMaxImages];
static int sSwapchains;


static bool
create_instance(void)
{
	unsigned count = 0;
	if (!SDL_Vulkan_GetInstanceExtensions(sWindow, &count, NULL)) {
		SAY("SDL_Vulkan_GetInstanceExtensions: %s BAD", SDL_GetError());
		return false;
	}
	const char** names = calloc(count, sizeof(char*));
	SDL_Vulkan_GetInstanceExtensions(sWindow, &count, names);
	char list[256] = "";
	for (unsigned i = 0; i < count; i++) {
		strncat(list, " ", sizeof(list) - strlen(list) - 1);
		strncat(list, names[i], sizeof(list) - strlen(list) - 1);
	}
	SAY("instance extensions from SDL (%u):%s", count, list);

	VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
		.pApplicationName = "sdlvk", .apiVersion = VK_API_VERSION_1_1 };
	VkInstanceCreateInfo info = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
		.pApplicationInfo = &app, .enabledExtensionCount = count,
		.ppEnabledExtensionNames = names };
	VkResult result = vkCreateInstance(&info, NULL, &sInstance);
	free(names);
	CHECK_VK(result);

	if (!SDL_Vulkan_CreateSurface(sWindow, sInstance, &sSurface)) {
		SAY("SDL_Vulkan_CreateSurface: %s BAD", SDL_GetError());
		return false;
	}
	SAY("SDL_Vulkan_CreateSurface ok");
	return true;
}


static bool
create_device(void)
{
	uint32_t count = 0;
	CHECK_VK(vkEnumeratePhysicalDevices(sInstance, &count, NULL));
	VkPhysicalDevice physicals[8];
	if (count > 8)
		count = 8;
	CHECK_VK(vkEnumeratePhysicalDevices(sInstance, &count, physicals));
	for (uint32_t i = 0; i < count && sPhysical == VK_NULL_HANDLE; i++) {
		uint32_t families = 0;
		vkGetPhysicalDeviceQueueFamilyProperties(physicals[i], &families, NULL);
		VkQueueFamilyProperties props[8];
		if (families > 8)
			families = 8;
		vkGetPhysicalDeviceQueueFamilyProperties(physicals[i], &families, props);
		for (uint32_t f = 0; f < families; f++) {
			VkBool32 present = VK_FALSE;
			vkGetPhysicalDeviceSurfaceSupportKHR(physicals[i], f, sSurface, &present);
			if ((props[f].queueFlags & VK_QUEUE_GRAPHICS_BIT) != 0 && present) {
				sPhysical = physicals[i];
				sQueueFamily = f;
				break;
			}
		}
	}
	if (sPhysical == VK_NULL_HANDLE) {
		SAY("no device presents to the surface BAD");
		return false;
	}
	VkPhysicalDeviceProperties props;
	vkGetPhysicalDeviceProperties(sPhysical, &props);
	SAY("device %s, Vulkan %u.%u", props.deviceName, VK_VERSION_MAJOR(props.apiVersion),
		VK_VERSION_MINOR(props.apiVersion));

	const float priority = 1.0f;
	VkDeviceQueueCreateInfo queue = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
		.queueFamilyIndex = sQueueFamily, .queueCount = 1, .pQueuePriorities = &priority };
	const char* extension = VK_KHR_SWAPCHAIN_EXTENSION_NAME;
	VkDeviceCreateInfo info = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
		.queueCreateInfoCount = 1, .pQueueCreateInfos = &queue, .enabledExtensionCount = 1,
		.ppEnabledExtensionNames = &extension };
	CHECK_VK(vkCreateDevice(sPhysical, &info, NULL, &sDevice));
	vkGetDeviceQueue(sDevice, sQueueFamily, 0, &sQueue);

	uint32_t formatCount = 0;
	CHECK_VK(vkGetPhysicalDeviceSurfaceFormatsKHR(sPhysical, sSurface, &formatCount, NULL));
	VkSurfaceFormatKHR formats[32];
	if (formatCount > 32)
		formatCount = 32;
	CHECK_VK(vkGetPhysicalDeviceSurfaceFormatsKHR(sPhysical, sSurface, &formatCount, formats));
	sFormat = formats[0].format;
	sColorSpace = formats[0].colorSpace;
	for (uint32_t i = 0; i < formatCount; i++) {
		if (formats[i].format == VK_FORMAT_B8G8R8A8_UNORM) {
			sFormat = formats[i].format;
			sColorSpace = formats[i].colorSpace;
		}
	}
	uint32_t modeCount = 0;
	CHECK_VK(vkGetPhysicalDeviceSurfacePresentModesKHR(sPhysical, sSurface, &modeCount, NULL));
	VkPresentModeKHR modes[8];
	if (modeCount > 8)
		modeCount = 8;
	CHECK_VK(vkGetPhysicalDeviceSurfacePresentModesKHR(sPhysical, sSurface, &modeCount, modes));
	bool haveMode = false;
	for (uint32_t i = 0; i < modeCount; i++)
		haveMode |= modes[i] == sPresentMode;
	if (!haveMode) {
		SAY("present mode %d not offered, using FIFO", (int)sPresentMode);
		sPresentMode = VK_PRESENT_MODE_FIFO_KHR;
	}
	SAY("surface formats %u (using %d), present modes %u (using %d)", formatCount, (int)sFormat,
		modeCount, (int)sPresentMode);
	return true;
}


static bool
create_pipeline(void)
{
	VkAttachmentDescription color = { .format = sFormat, .samples = VK_SAMPLE_COUNT_1_BIT,
		.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
		.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
		.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
		.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
		.finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR };
	VkAttachmentReference reference = { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
	VkSubpassDescription subpass = { .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
		.colorAttachmentCount = 1, .pColorAttachments = &reference };
	VkSubpassDependency dependency = { .srcSubpass = VK_SUBPASS_EXTERNAL, .dstSubpass = 0,
		.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
		.dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
		.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT };
	VkRenderPassCreateInfo passInfo = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
		.attachmentCount = 1, .pAttachments = &color, .subpassCount = 1, .pSubpasses = &subpass,
		.dependencyCount = 1, .pDependencies = &dependency };
	CHECK_VK(vkCreateRenderPass(sDevice, &passInfo, NULL, &sRenderPass));

	VkShaderModule vert, frag;
	VkShaderModuleCreateInfo moduleInfo = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
		.codeSize = sizeof(tri_vert_spv), .pCode = tri_vert_spv };
	CHECK_VK(vkCreateShaderModule(sDevice, &moduleInfo, NULL, &vert));
	moduleInfo.codeSize = sizeof(tri_frag_spv);
	moduleInfo.pCode = tri_frag_spv;
	CHECK_VK(vkCreateShaderModule(sDevice, &moduleInfo, NULL, &frag));

	VkPipelineShaderStageCreateInfo stages[2] = {
		{ .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
			.stage = VK_SHADER_STAGE_VERTEX_BIT, .module = vert, .pName = "main" },
		{ .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
			.stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = frag, .pName = "main" },
	};
	VkPipelineVertexInputStateCreateInfo vertexInput = {
		.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
	VkPipelineInputAssemblyStateCreateInfo assembly = {
		.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
	VkPipelineViewportStateCreateInfo viewport = {
		.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .viewportCount = 1,
		.scissorCount = 1 };
	VkPipelineRasterizationStateCreateInfo raster = {
		.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		.polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE,
		.frontFace = VK_FRONT_FACE_CLOCKWISE, .lineWidth = 1.0f };
	VkPipelineMultisampleStateCreateInfo multisample = {
		.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT };
	VkPipelineColorBlendAttachmentState blendAttachment = { .colorWriteMask = 0xf };
	VkPipelineColorBlendStateCreateInfo blend = {
		.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		.attachmentCount = 1, .pAttachments = &blendAttachment };
	VkDynamicState dynamicStates[2] = { VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
	VkPipelineDynamicStateCreateInfo dynamic = {
		.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO, .dynamicStateCount = 2,
		.pDynamicStates = dynamicStates };
	VkPipelineLayoutCreateInfo layoutInfo = {
		.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
	CHECK_VK(vkCreatePipelineLayout(sDevice, &layoutInfo, NULL, &sPipelineLayout));
	VkGraphicsPipelineCreateInfo info = { .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
		.stageCount = 2, .pStages = stages, .pVertexInputState = &vertexInput,
		.pInputAssemblyState = &assembly, .pViewportState = &viewport,
		.pRasterizationState = &raster, .pMultisampleState = &multisample,
		.pColorBlendState = &blend, .pDynamicState = &dynamic, .layout = sPipelineLayout,
		.renderPass = sRenderPass };
	CHECK_VK(vkCreateGraphicsPipelines(sDevice, VK_NULL_HANDLE, 1, &info, NULL, &sPipeline));
	vkDestroyShaderModule(sDevice, vert, NULL);
	vkDestroyShaderModule(sDevice, frag, NULL);

	VkCommandPoolCreateInfo poolInfo = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
		.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
		.queueFamilyIndex = sQueueFamily };
	CHECK_VK(vkCreateCommandPool(sDevice, &poolInfo, NULL, &sCommandPool));
	VkCommandBufferAllocateInfo allocInfo = {
		.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = sCommandPool,
		.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = kFramesInFlight };
	CHECK_VK(vkAllocateCommandBuffers(sDevice, &allocInfo, sCommandBuffers));
	VkSemaphoreCreateInfo semaphoreInfo = { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
	VkFenceCreateInfo fenceInfo = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
		.flags = VK_FENCE_CREATE_SIGNALED_BIT };
	for (int i = 0; i < kFramesInFlight; i++) {
		CHECK_VK(vkCreateSemaphore(sDevice, &semaphoreInfo, NULL, &sAcquired[i]));
		CHECK_VK(vkCreateFence(sDevice, &fenceInfo, NULL, &sInFlight[i]));
	}
	for (int i = 0; i < kMaxImages; i++)
		CHECK_VK(vkCreateSemaphore(sDevice, &semaphoreInfo, NULL, &sRendered[i]));
	return true;
}


static void
destroy_swapchain_images(void)
{
	for (uint32_t i = 0; i < sImageCount; i++) {
		vkDestroyFramebuffer(sDevice, sFramebuffers[i], NULL);
		vkDestroyImageView(sDevice, sViews[i], NULL);
	}
	sImageCount = 0;
}


static bool
create_swapchain(void)
{
	VkSurfaceCapabilitiesKHR caps;
	CHECK_VK(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(sPhysical, sSurface, &caps));
	int drawableWidth = 0, drawableHeight = 0;
	SDL_Vulkan_GetDrawableSize(sWindow, &drawableWidth, &drawableHeight);
	const bool viewSized = caps.currentExtent.width != UINT32_MAX;
	SAY("swapchain %d: surface current extent %ux%u, SDL drawable %dx%d: %s", sSwapchains + 1,
		caps.currentExtent.width, caps.currentExtent.height, drawableWidth, drawableHeight,
		!viewSized ? "no extent: a plain headless surface, not the window BAD"
			: (int)caps.currentExtent.width == drawableWidth
				&& (int)caps.currentExtent.height == drawableHeight ? "match ok" : "differ BAD");
	if (!viewSized)
		return false;
	sExtent = caps.currentExtent;

	uint32_t images = caps.minImageCount + 1;
	if (caps.maxImageCount != 0 && images > caps.maxImageCount)
		images = caps.maxImageCount;
	VkSwapchainKHR old = sSwapchain;
	VkSwapchainCreateInfoKHR info = { .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
		.surface = sSurface, .minImageCount = images, .imageFormat = sFormat,
		.imageColorSpace = sColorSpace, .imageExtent = sExtent, .imageArrayLayers = 1,
		.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
		.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE, .preTransform = caps.currentTransform,
		.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR, .presentMode = sPresentMode,
		.clipped = VK_TRUE, .oldSwapchain = old };
	CHECK_VK(vkCreateSwapchainKHR(sDevice, &info, NULL, &sSwapchain));
	if (old != VK_NULL_HANDLE) {
		destroy_swapchain_images();
		vkDestroySwapchainKHR(sDevice, old, NULL);
	}
	sSwapchains++;

	VkImage swapImages[kMaxImages];
	sImageCount = 0;
	CHECK_VK(vkGetSwapchainImagesKHR(sDevice, sSwapchain, &sImageCount, NULL));
	if (sImageCount > kMaxImages) {
		SAY("%u swapchain images, more than %d BAD", sImageCount, kMaxImages);
		return false;
	}
	CHECK_VK(vkGetSwapchainImagesKHR(sDevice, sSwapchain, &sImageCount, swapImages));
	for (uint32_t i = 0; i < sImageCount; i++) {
		VkImageViewCreateInfo viewInfo = { .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
			.image = swapImages[i], .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = sFormat,
			.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
		CHECK_VK(vkCreateImageView(sDevice, &viewInfo, NULL, &sViews[i]));
		VkFramebufferCreateInfo fbInfo = { .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
			.renderPass = sRenderPass, .attachmentCount = 1, .pAttachments = &sViews[i],
			.width = sExtent.width, .height = sExtent.height, .layers = 1 };
		CHECK_VK(vkCreateFramebuffer(sDevice, &fbInfo, NULL, &sFramebuffers[i]));
	}
	SAY("swapchain %d: %ux%u, %u images", sSwapchains, sExtent.width, sExtent.height,
		sImageCount);
	return true;
}


// one frame; *recreate is set when the swapchain no longer matches the window, *presented when
// the frame reached vkQueuePresentKHR
static bool
frame(int slot, double time, bool* recreate, bool* presented)
{
	*presented = false;
	CHECK_VK(vkWaitForFences(sDevice, 1, &sInFlight[slot], VK_TRUE, UINT64_MAX));
	uint32_t index;
	VkResult result = vkAcquireNextImageKHR(sDevice, sSwapchain, UINT64_MAX, sAcquired[slot],
		VK_NULL_HANDLE, &index);
	if (result == VK_ERROR_OUT_OF_DATE_KHR) {
		*recreate = true;
		return true;
	}
	if (result != VK_SUCCESS && result != VK_SUBOPTIMAL_KHR) {
		SAY("vkAcquireNextImageKHR failed: %d BAD", (int)result);
		return false;
	}
	CHECK_VK(vkResetFences(sDevice, 1, &sInFlight[slot]));

	VkCommandBuffer cmd = sCommandBuffers[slot];
	CHECK_VK(vkResetCommandBuffer(cmd, 0));
	VkCommandBufferBeginInfo begin = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
		.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
	CHECK_VK(vkBeginCommandBuffer(cmd, &begin));
	VkClearValue clear = { .color = { .float32 = { 0.5f + 0.4f * sinf(time), 0.2f,
		0.5f + 0.4f * cosf(time * 0.7f), 1.0f } } };
	VkRenderPassBeginInfo pass = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
		.renderPass = sRenderPass, .framebuffer = sFramebuffers[index],
		.renderArea = { { 0, 0 }, sExtent }, .clearValueCount = 1, .pClearValues = &clear };
	vkCmdBeginRenderPass(cmd, &pass, VK_SUBPASS_CONTENTS_INLINE);
	vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, sPipeline);
	VkViewport viewport = { 0, 0, (float)sExtent.width, (float)sExtent.height, 0, 1 };
	VkRect2D scissor = { { 0, 0 }, sExtent };
	vkCmdSetViewport(cmd, 0, 1, &viewport);
	vkCmdSetScissor(cmd, 0, 1, &scissor);
	vkCmdDraw(cmd, 3, 1, 0, 0);
	vkCmdEndRenderPass(cmd);
	CHECK_VK(vkEndCommandBuffer(cmd));

	VkPipelineStageFlags waitStage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
	VkSubmitInfo submit = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .waitSemaphoreCount = 1,
		.pWaitSemaphores = &sAcquired[slot], .pWaitDstStageMask = &waitStage,
		.commandBufferCount = 1, .pCommandBuffers = &cmd, .signalSemaphoreCount = 1,
		.pSignalSemaphores = &sRendered[index] };
	CHECK_VK(vkQueueSubmit(sQueue, 1, &submit, sInFlight[slot]));
	VkPresentInfoKHR present = { .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
		.waitSemaphoreCount = 1, .pWaitSemaphores = &sRendered[index], .swapchainCount = 1,
		.pSwapchains = &sSwapchain, .pImageIndices = &index };
	result = vkQueuePresentKHR(sQueue, &present);
	*presented = true;
	if (result == VK_ERROR_OUT_OF_DATE_KHR || result == VK_SUBOPTIMAL_KHR)
		*recreate = true;
	else if (result != VK_SUCCESS) {
		SAY("vkQueuePresentKHR failed: %d BAD", (int)result);
		return false;
	}
	return true;
}


static bool
run(void)
{
	if (!create_instance() || !create_device() || !create_pipeline() || !create_swapchain())
		return false;

	// what games do on focus; must not need an OpenGL view
	SAY("relative mouse mode on: %d", SDL_SetRelativeMouseMode(SDL_TRUE));

	const Uint64 frequency = SDL_GetPerformanceFrequency();
	const Uint64 start = SDL_GetPerformanceCounter();
	Uint64 reportStart = start;
	int frames = 0, reportFrames = 0, resizeEvents = 0;
	bool resized = false, recreate = false, quit = false;
	while (!quit) {
		SDL_Event event;
		while (SDL_PollEvent(&event)) {
			if (event.type == SDL_QUIT)
				quit = true;
			else if (event.type == SDL_WINDOWEVENT
				&& event.window.event == SDL_WINDOWEVENT_SIZE_CHANGED) {
				resizeEvents++;
				recreate = true;
			}
		}
		const Uint64 now = SDL_GetPerformanceCounter();
		const double time = (double)(now - start) / frequency;
		if (time >= sSeconds)
			break;
		if (sResize && !resized && time >= sSeconds / 2) {
			SDL_SetWindowSize(sWindow, sWidth + sWidth / 4, sHeight + sHeight / 4);
			resized = true;
			SAY("window resized to %dx%d", sWidth + sWidth / 4, sHeight + sHeight / 4);
		}
		if (recreate) {
			CHECK_VK(vkDeviceWaitIdle(sDevice));
			if (!create_swapchain())
				return false;
			recreate = false;
		}
		bool presented;
		if (!frame(frames % kFramesInFlight, time, &recreate, &presented))
			return false;
		if (!presented)
			continue;
		frames++;
		reportFrames++;
		if (now - reportStart >= 2 * frequency) {
			SAY("fps %.1f (%d frames in %.1f s)",
				reportFrames * (double)frequency / (now - reportStart), frames, time);
			reportFrames = 0;
			reportStart = now;
		}
	}
	const double total = (double)(SDL_GetPerformanceCounter() - start) / frequency;
	SAY("frames %d in %.2f s = %.1f fps, %d swapchain%s, %d resize event%s", frames, total,
		frames / total, sSwapchains, sSwapchains == 1 ? "" : "s", resizeEvents,
		resizeEvents == 1 ? "" : "s");
	SAY("relative mouse mode off: %d", SDL_SetRelativeMouseMode(SDL_FALSE));
	CHECK_VK(vkDeviceWaitIdle(sDevice));
	if (frames == 0) {
		SAY("no frames BAD");
		return false;
	}
	if (sResize && sSwapchains < 2) {
		SAY("the window grew, the swapchain was not made again BAD");
		return false;
	}
	return true;
}


static void
cleanup(void)
{
	if (sDevice != VK_NULL_HANDLE) {
		vkDeviceWaitIdle(sDevice);
		destroy_swapchain_images();
		if (sSwapchain != VK_NULL_HANDLE)
			vkDestroySwapchainKHR(sDevice, sSwapchain, NULL);
		for (int i = 0; i < kFramesInFlight; i++) {
			vkDestroySemaphore(sDevice, sAcquired[i], NULL);
			vkDestroyFence(sDevice, sInFlight[i], NULL);
		}
		for (int i = 0; i < kMaxImages; i++)
			vkDestroySemaphore(sDevice, sRendered[i], NULL);
		vkDestroyCommandPool(sDevice, sCommandPool, NULL);
		vkDestroyPipeline(sDevice, sPipeline, NULL);
		vkDestroyPipelineLayout(sDevice, sPipelineLayout, NULL);
		vkDestroyRenderPass(sDevice, sRenderPass, NULL);
		vkDestroyDevice(sDevice, NULL);
	}
	// the surface before the window: its view belongs to the window
	if (sSurface != VK_NULL_HANDLE)
		vkDestroySurfaceKHR(sInstance, sSurface, NULL);
	if (sInstance != VK_NULL_HANDLE)
		vkDestroyInstance(sInstance, NULL);
}


int
main(int argc, char** argv)
{
	int opt;
	while ((opt = getopt(argc, argv, "s:W:H:m:r")) != -1) {
		if (opt == 's')
			sSeconds = atof(optarg);
		else if (opt == 'W')
			sWidth = atoi(optarg);
		else if (opt == 'H')
			sHeight = atoi(optarg);
		else if (opt == 'm' && strcmp(optarg, "fifo") == 0)
			sPresentMode = VK_PRESENT_MODE_FIFO_KHR;
		else if (opt == 'm' && strcmp(optarg, "mailbox") == 0)
			sPresentMode = VK_PRESENT_MODE_MAILBOX_KHR;
		else if (opt == 'm' && strcmp(optarg, "immediate") == 0)
			sPresentMode = VK_PRESENT_MODE_IMMEDIATE_KHR;
		else if (opt == 'r')
			sResize = true;
		else {
			fprintf(stderr, "usage: %s [-s seconds] [-W width] [-H height] "
				"[-m fifo|mailbox|immediate] [-r]\n", argv[0]);
			return 2;
		}
	}

	if (SDL_Init(SDL_INIT_VIDEO) != 0) {
		SAY("SDL_Init: %s BAD", SDL_GetError());
		SAY("FAIL");
		return 1;
	}
	SDL_version version;
	SDL_GetVersion(&version);
	SAY("begin SDL %d.%d.%d, video driver %s, %dx%d, %.0f s%s", version.major, version.minor,
		version.patch, SDL_GetCurrentVideoDriver(), sWidth, sHeight, sSeconds,
		sResize ? ", resize" : "");
	sWindow = SDL_CreateWindow("sdlvk", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, sWidth,
		sHeight, SDL_WINDOW_VULKAN | SDL_WINDOW_RESIZABLE);
	bool ok = false;
	if (sWindow == NULL)
		SAY("SDL_CreateWindow(SDL_WINDOW_VULKAN): %s BAD", SDL_GetError());
	else
		ok = run();
	cleanup();
	if (sWindow != NULL)
		SDL_DestroyWindow(sWindow);
	SDL_Quit();
	SAY("%s", ok ? "PASS" : "FAIL");
	return ok ? 0 : 1;
}
