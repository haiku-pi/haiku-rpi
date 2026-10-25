/*
 * vkf32 — headless Vulkan check of large 128-bit-per-pixel colour attachments on the Pi 4's V3D (V3DV):
 * for each size N (default 512 1024 1536 2048 4096), an N×N VK_FORMAT_R32G32B32A32_SFLOAT image is
 * cleared by a render pass (loadOp CLEAR, storeOp STORE, no draw), copied into a host buffer, and every
 * pixel compared with the clear colour; then the same with VK_FORMAT_R8G8B8A8_UNORM. Photocraft's GPU
 * compositor read zeros from part of a 2048×2048 Rgba32Float target; this tells whether the driver's
 * tile store of such a target is at fault.
 *
 * Every line starts with "VKF " (for a boot script's serial console). Exit status 0 = all sizes PASS.
 *
 *   vkf32 [N...]
 *
 * Build (cross; only the Vulkan headers are needed, libvulkan is linked):
 *   g="sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc --sysroot=artifacts/sysroot-arm64"
 *   $g -O2 -I artifacts/sysroot-arm64/boot/system/non-packaged/develop/headers -o vkf32 tools/gl-tests/vkf32.c -lvulkan
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <vulkan/vulkan.h>


#define CHECK(call) \
	do { \
		VkResult checkResult = (call); \
		if (checkResult != VK_SUCCESS) { \
			printf("VKF %s failed: %d\n", #call, checkResult); \
			return false; \
		} \
	} while (0)


static VkInstance sInstance;
static VkPhysicalDevice sPhysical;
static VkDevice sDevice;
static VkQueue sQueue;
static uint32_t sQueueFamily;
static VkCommandPool sPool;


static bool
setup(void)
{
	VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
		.pApplicationName = "vkf32", .apiVersion = VK_API_VERSION_1_1 };
	VkInstanceCreateInfo instanceInfo = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
		.pApplicationInfo = &app };
	CHECK(vkCreateInstance(&instanceInfo, NULL, &sInstance));

	uint32_t count = 1;
	VkResult result = vkEnumeratePhysicalDevices(sInstance, &count, &sPhysical);
	if ((result != VK_SUCCESS && result != VK_INCOMPLETE) || count == 0) {
		printf("VKF no physical device\n");
		return false;
	}
	VkPhysicalDeviceProperties properties;
	vkGetPhysicalDeviceProperties(sPhysical, &properties);
	printf("VKF device: %s, max framebuffer %u x %u\n", properties.deviceName,
		properties.limits.maxFramebufferWidth, properties.limits.maxFramebufferHeight);

	VkQueueFamilyProperties families[8];
	count = 8;
	vkGetPhysicalDeviceQueueFamilyProperties(sPhysical, &count, families);
	sQueueFamily = UINT32_MAX;
	for (uint32_t i = 0; i < count; i++) {
		if ((families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) != 0) {
			sQueueFamily = i;
			break;
		}
	}
	if (sQueueFamily == UINT32_MAX) {
		printf("VKF no graphics queue\n");
		return false;
	}

	float priority = 1.0f;
	VkDeviceQueueCreateInfo queueInfo = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
		.queueFamilyIndex = sQueueFamily, .queueCount = 1, .pQueuePriorities = &priority };
	VkDeviceCreateInfo deviceInfo = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
		.queueCreateInfoCount = 1, .pQueueCreateInfos = &queueInfo };
	CHECK(vkCreateDevice(sPhysical, &deviceInfo, NULL, &sDevice));
	vkGetDeviceQueue(sDevice, sQueueFamily, 0, &sQueue);

	VkCommandPoolCreateInfo poolInfo = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
		.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = sQueueFamily };
	CHECK(vkCreateCommandPool(sDevice, &poolInfo, NULL, &sPool));
	return true;
}


static int32_t
memory_type(uint32_t bits, VkMemoryPropertyFlags flags)
{
	VkPhysicalDeviceMemoryProperties memory;
	vkGetPhysicalDeviceMemoryProperties(sPhysical, &memory);
	for (uint32_t i = 0; i < memory.memoryTypeCount; i++) {
		if ((bits & (1u << i)) != 0
			&& (memory.memoryTypes[i].propertyFlags & flags) == flags)
			return i;
	}
	return -1;
}


/*!	Clears an N×N image of \a format by a render pass, copies it to a host
	buffer and compares each pixel with the clear colour. */
static bool
check_size(uint32_t size, VkFormat format, const char* formatName)
{
	const bool isFloat = format == VK_FORMAT_R32G32B32A32_SFLOAT;
	const uint32_t pixelSize = isFloat ? 16 : 4;
	const VkClearColorValue clearColor = { .float32 = { 0.25f, 0.5f, 0.75f, 1.0f } };

	VkImageCreateInfo imageInfo = { .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
		.imageType = VK_IMAGE_TYPE_2D, .format = format, .extent = { size, size, 1 },
		.mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT,
		.tiling = VK_IMAGE_TILING_OPTIMAL,
		.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
		.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED };
	VkImage image;
	CHECK(vkCreateImage(sDevice, &imageInfo, NULL, &image));
	VkMemoryRequirements requirements;
	vkGetImageMemoryRequirements(sDevice, image, &requirements);
	VkMemoryAllocateInfo allocInfo = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
		.allocationSize = requirements.size,
		.memoryTypeIndex = memory_type(requirements.memoryTypeBits,
			VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) };
	VkDeviceMemory imageMemory;
	CHECK(vkAllocateMemory(sDevice, &allocInfo, NULL, &imageMemory));
	CHECK(vkBindImageMemory(sDevice, image, imageMemory, 0));

	VkDeviceSize bufferSize = (VkDeviceSize)size * size * pixelSize;
	VkBufferCreateInfo bufferInfo = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
		.size = bufferSize, .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT };
	VkBuffer buffer;
	CHECK(vkCreateBuffer(sDevice, &bufferInfo, NULL, &buffer));
	vkGetBufferMemoryRequirements(sDevice, buffer, &requirements);
	allocInfo.allocationSize = requirements.size;
	allocInfo.memoryTypeIndex = memory_type(requirements.memoryTypeBits,
		VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
	VkDeviceMemory bufferMemory;
	CHECK(vkAllocateMemory(sDevice, &allocInfo, NULL, &bufferMemory));
	CHECK(vkBindBufferMemory(sDevice, buffer, bufferMemory, 0));
	void* mapped;
	CHECK(vkMapMemory(sDevice, bufferMemory, 0, bufferSize, 0, &mapped));
	memset(mapped, 0xa5, bufferSize);

	VkImageViewCreateInfo viewInfo = { .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
		.image = image, .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = format,
		.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
	VkImageView view;
	CHECK(vkCreateImageView(sDevice, &viewInfo, NULL, &view));

	VkAttachmentDescription attachment = { .format = format, .samples = VK_SAMPLE_COUNT_1_BIT,
		.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
		.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
		.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
		.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
		.finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL };
	VkAttachmentReference reference = { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
	VkSubpassDescription subpass = { .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
		.colorAttachmentCount = 1, .pColorAttachments = &reference };
	VkRenderPassCreateInfo passInfo = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
		.attachmentCount = 1, .pAttachments = &attachment, .subpassCount = 1,
		.pSubpasses = &subpass };
	VkRenderPass pass;
	CHECK(vkCreateRenderPass(sDevice, &passInfo, NULL, &pass));
	VkFramebufferCreateInfo framebufferInfo = { .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
		.renderPass = pass, .attachmentCount = 1, .pAttachments = &view, .width = size,
		.height = size, .layers = 1 };
	VkFramebuffer framebuffer;
	CHECK(vkCreateFramebuffer(sDevice, &framebufferInfo, NULL, &framebuffer));

	VkCommandBufferAllocateInfo commandInfo = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
		.commandPool = sPool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
	VkCommandBuffer commands;
	CHECK(vkAllocateCommandBuffers(sDevice, &commandInfo, &commands));
	VkCommandBufferBeginInfo beginInfo = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
		.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
	CHECK(vkBeginCommandBuffer(commands, &beginInfo));
	VkClearValue clearValue = { .color = clearColor };
	VkRenderPassBeginInfo passBegin = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
		.renderPass = pass, .framebuffer = framebuffer, .renderArea = { { 0, 0 }, { size, size } },
		.clearValueCount = 1, .pClearValues = &clearValue };
	vkCmdBeginRenderPass(commands, &passBegin, VK_SUBPASS_CONTENTS_INLINE);
	vkCmdEndRenderPass(commands);
	VkBufferImageCopy region = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
		.imageExtent = { size, size, 1 } };
	vkCmdCopyImageToBuffer(commands, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buffer, 1,
		&region);
	VkMemoryBarrier barrier = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
		.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT };
	vkCmdPipelineBarrier(commands, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0,
		1, &barrier, 0, NULL, 0, NULL);
	CHECK(vkEndCommandBuffer(commands));

	VkFenceCreateInfo fenceInfo = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
	VkFence fence;
	CHECK(vkCreateFence(sDevice, &fenceInfo, NULL, &fence));
	VkSubmitInfo submit = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1,
		.pCommandBuffers = &commands };
	CHECK(vkQueueSubmit(sQueue, 1, &submit, fence));
	CHECK(vkWaitForFences(sDevice, 1, &fence, VK_TRUE, 10000000000ull));

	// compare
	uint64_t bad = 0;
	uint32_t firstX = 0, firstY = 0, lastX = 0, lastY = 0;
	for (uint32_t y = 0; y < size; y++) {
		for (uint32_t x = 0; x < size; x++) {
			bool ok;
			if (isFloat) {
				const float* pixel = (const float*)mapped + ((size_t)y * size + x) * 4;
				ok = pixel[0] == 0.25f && pixel[1] == 0.5f && pixel[2] == 0.75f
					&& pixel[3] == 1.0f;
			} else {
				const uint8_t* pixel = (const uint8_t*)mapped + ((size_t)y * size + x) * 4;
				ok = pixel[0] == 64 && pixel[1] == 128 && pixel[2] == 191 && pixel[3] == 255;
			}
			if (!ok) {
				if (bad == 0) {
					firstX = x;
					firstY = y;
				}
				lastX = x;
				lastY = y;
				bad++;
			}
		}
	}
	if (bad == 0)
		printf("VKF %s %ux%u: PASS\n", formatName, size, size);
	else {
		printf("VKF %s %ux%u: FAIL %llu of %llu pixels wrong, first (%u,%u), last (%u,%u)\n",
			formatName, size, size, (unsigned long long)bad,
			(unsigned long long)size * size, firstX, firstY, lastX, lastY);
	}

	vkDestroyFence(sDevice, fence, NULL);
	vkFreeCommandBuffers(sDevice, sPool, 1, &commands);
	vkDestroyFramebuffer(sDevice, framebuffer, NULL);
	vkDestroyRenderPass(sDevice, pass, NULL);
	vkDestroyImageView(sDevice, view, NULL);
	vkUnmapMemory(sDevice, bufferMemory);
	vkDestroyBuffer(sDevice, buffer, NULL);
	vkFreeMemory(sDevice, bufferMemory, NULL);
	vkDestroyImage(sDevice, image, NULL);
	vkFreeMemory(sDevice, imageMemory, NULL);
	return bad == 0;
}


int
main(int argc, char** argv)
{
	static const uint32_t kDefaultSizes[] = { 512, 1024, 1536, 2048, 4096 };
	if (!setup())
		return 1;

	int failures = 0;
	int count = argc > 1 ? argc - 1 : (int)(sizeof(kDefaultSizes) / sizeof(kDefaultSizes[0]));
	for (int i = 0; i < count; i++) {
		uint32_t size = argc > 1 ? (uint32_t)atoi(argv[i + 1]) : kDefaultSizes[i];
		if (!check_size(size, VK_FORMAT_R32G32B32A32_SFLOAT, "RGBA32F"))
			failures++;
		if (!check_size(size, VK_FORMAT_R8G8B8A8_UNORM, "RGBA8"))
			failures++;
	}
	printf("VKF %s\n", failures == 0 ? "PASS" : "FAIL");
	return failures != 0;
}
