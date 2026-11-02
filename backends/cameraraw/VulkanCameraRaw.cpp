#include "include/CameraRawLookup.h"
#include "shaders/lookup_spv.h"
#include <vulkan/vulkan.h>
#include <algorithm>
#include <array>
#include <cstring>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <vector>

namespace {
void checked(VkResult result) {
    if (result != VK_SUCCESS) throw std::runtime_error("Vulkan Camera Raw operation failed");
}
struct Buffer {
    VkDevice device = VK_NULL_HANDLE;
    VkBuffer buffer = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    void *mapped = nullptr;
    VkDeviceSize capacity = 0;
    bool coherent = false;
    ~Buffer() {
        if (mapped) vkUnmapMemory(device, memory);
        if (buffer) vkDestroyBuffer(device, buffer, nullptr);
        if (memory) vkFreeMemory(device, memory, nullptr);
    }
    void create(VkDevice owner, VkPhysicalDevice physical, VkDeviceSize bytes) {
        device = owner;
        VkBufferCreateInfo info{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
        info.size = bytes; info.usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
        checked(vkCreateBuffer(device, &info, nullptr, &buffer));
        VkMemoryRequirements requirements{};
        vkGetBufferMemoryRequirements(device, buffer, &requirements);
        VkPhysicalDeviceMemoryProperties properties{};
        vkGetPhysicalDeviceMemoryProperties(physical, &properties);
        uint32_t type = UINT32_MAX;
        int best = -1;
        for (uint32_t i = 0; i < properties.memoryTypeCount; ++i) {
            const auto flags = properties.memoryTypes[i].propertyFlags;
            if (!(requirements.memoryTypeBits & (1u << i)) || !(flags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)) continue;
            const int score = (flags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT ? 8 : 0)
                + (flags & VK_MEMORY_PROPERTY_HOST_CACHED_BIT ? 4 : 0);
            if (score > best) { type = i; best = score; }
        }
        if (type == UINT32_MAX) throw std::runtime_error("No host-visible Camera Raw memory");
        coherent = properties.memoryTypes[type].propertyFlags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        VkMemoryAllocateInfo allocation{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
        allocation.allocationSize = requirements.size; allocation.memoryTypeIndex = type;
        checked(vkAllocateMemory(device, &allocation, nullptr, &memory));
        checked(vkBindBufferMemory(device, buffer, memory, 0));
        checked(vkMapMemory(device, memory, 0, VK_WHOLE_SIZE, 0, &mapped));
        capacity = bytes;
    }
    void synchronize(bool upload) {
        if (coherent) return;
        VkMappedMemoryRange range{VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE};
        range.memory = memory; range.size = VK_WHOLE_SIZE;
        checked(upload ? vkFlushMappedMemoryRanges(device, 1, &range) : vkInvalidateMappedMemoryRanges(device, 1, &range));
    }
};
}

struct CompositorCameraRawLookup {
    std::mutex lock;
    VkInstance instance = VK_NULL_HANDLE;
    VkPhysicalDevice physical = VK_NULL_HANDLE;
    VkPhysicalDeviceProperties properties{};
    VkDevice device = VK_NULL_HANDLE;
    VkQueue queue = VK_NULL_HANDLE;
    VkDescriptorSetLayout layout = VK_NULL_HANDLE;
    VkPipelineLayout pipelineLayout = VK_NULL_HANDLE;
    VkShaderModule shader = VK_NULL_HANDLE;
    VkPipeline pipeline = VK_NULL_HANDLE;
    VkDescriptorPool pool = VK_NULL_HANDLE;
    VkDescriptorSet descriptors = VK_NULL_HANDLE;
    VkCommandPool commands = VK_NULL_HANDLE;
    VkCommandBuffer command = VK_NULL_HANDLE;
    VkFence fence = VK_NULL_HANDLE;
    std::array<std::unique_ptr<Buffer>, 3> buffers;
    uint64_t submissions = 0;
    bool failed = false;

    ~CompositorCameraRawLookup() {
        if (device) vkDeviceWaitIdle(device);
        for (auto &buffer : buffers) buffer.reset();
        if (fence) vkDestroyFence(device, fence, nullptr);
        if (commands) vkDestroyCommandPool(device, commands, nullptr);
        if (pool) vkDestroyDescriptorPool(device, pool, nullptr);
        if (pipeline) vkDestroyPipeline(device, pipeline, nullptr);
        if (shader) vkDestroyShaderModule(device, shader, nullptr);
        if (pipelineLayout) vkDestroyPipelineLayout(device, pipelineLayout, nullptr);
        if (layout) vkDestroyDescriptorSetLayout(device, layout, nullptr);
        if (device) vkDestroyDevice(device, nullptr);
        if (instance) vkDestroyInstance(instance, nullptr);
    }
    void initialize() {
        VkApplicationInfo application{VK_STRUCTURE_TYPE_APPLICATION_INFO}; application.apiVersion = VK_API_VERSION_1_0;
        VkInstanceCreateInfo info{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO}; info.pApplicationInfo = &application;
        checked(vkCreateInstance(&info, nullptr, &instance));
        uint32_t count = 0; checked(vkEnumeratePhysicalDevices(instance, &count, nullptr));
        std::vector<VkPhysicalDevice> devices(count); checked(vkEnumeratePhysicalDevices(instance, &count, devices.data()));
        uint32_t family = 0; int best = -1;
        for (auto candidate : devices) {
            VkPhysicalDeviceProperties props{}; vkGetPhysicalDeviceProperties(candidate, &props);
            const int score = props.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU ? 2
                : props.deviceType == VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU ? 1 : -1;
            if (score <= best || props.limits.maxComputeWorkGroupInvocations < 256
                || props.limits.maxComputeWorkGroupSize[0] < 16 || props.limits.maxComputeWorkGroupSize[1] < 16
                || props.limits.maxPushConstantsSize < 12 || props.limits.maxPerStageDescriptorStorageBuffers < 3
                || props.limits.maxDescriptorSetStorageBuffers < 3) continue;
            uint32_t queueCount = 0; vkGetPhysicalDeviceQueueFamilyProperties(candidate, &queueCount, nullptr);
            std::vector<VkQueueFamilyProperties> queues(queueCount);
            vkGetPhysicalDeviceQueueFamilyProperties(candidate, &queueCount, queues.data());
            for (uint32_t i = 0; i < queueCount; ++i) if (queues[i].queueCount && (queues[i].queueFlags & VK_QUEUE_COMPUTE_BIT)) {
                physical = candidate; properties = props; family = i; best = score; break;
            }
        }
        if (!physical) throw std::runtime_error("No hardware Camera Raw compute queue");
        float priority = 1;
        VkDeviceQueueCreateInfo queueInfo{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
        queueInfo.queueFamilyIndex = family; queueInfo.queueCount = 1; queueInfo.pQueuePriorities = &priority;
        VkDeviceCreateInfo deviceInfo{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
        deviceInfo.queueCreateInfoCount = 1; deviceInfo.pQueueCreateInfos = &queueInfo;
        checked(vkCreateDevice(physical, &deviceInfo, nullptr, &device)); vkGetDeviceQueue(device, family, 0, &queue);
        VkDescriptorSetLayoutBinding bindings[3]{};
        for (uint32_t i = 0; i < 3; ++i) {
            bindings[i].binding = i; bindings[i].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            bindings[i].descriptorCount = 1; bindings[i].stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
        }
        VkDescriptorSetLayoutCreateInfo layoutInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
        layoutInfo.bindingCount = 3; layoutInfo.pBindings = bindings;
        checked(vkCreateDescriptorSetLayout(device, &layoutInfo, nullptr, &layout));
        VkPushConstantRange constants{VK_SHADER_STAGE_COMPUTE_BIT, 0, 12};
        VkPipelineLayoutCreateInfo pipelineInfo{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
        pipelineInfo.setLayoutCount = 1; pipelineInfo.pSetLayouts = &layout;
        pipelineInfo.pushConstantRangeCount = 1; pipelineInfo.pPushConstantRanges = &constants;
        checked(vkCreatePipelineLayout(device, &pipelineInfo, nullptr, &pipelineLayout));
        VkShaderModuleCreateInfo shaderInfo{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
        shaderInfo.codeSize = sizeof(compositor_camera_raw_lookup_spv); shaderInfo.pCode = compositor_camera_raw_lookup_spv;
        checked(vkCreateShaderModule(device, &shaderInfo, nullptr, &shader));
        VkComputePipelineCreateInfo compute{VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};
        compute.stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        compute.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT; compute.stage.module = shader; compute.stage.pName = "main";
        compute.layout = pipelineLayout; checked(vkCreateComputePipelines(device, VK_NULL_HANDLE, 1, &compute, nullptr, &pipeline));
        VkDescriptorPoolSize size{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 3};
        VkDescriptorPoolCreateInfo poolInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};
        poolInfo.maxSets = 1; poolInfo.poolSizeCount = 1; poolInfo.pPoolSizes = &size;
        checked(vkCreateDescriptorPool(device, &poolInfo, nullptr, &pool));
        VkDescriptorSetAllocateInfo allocation{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
        allocation.descriptorPool = pool; allocation.descriptorSetCount = 1; allocation.pSetLayouts = &layout;
        checked(vkAllocateDescriptorSets(device, &allocation, &descriptors));
        VkCommandPoolCreateInfo commandInfo{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
        commandInfo.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT; commandInfo.queueFamilyIndex = family;
        checked(vkCreateCommandPool(device, &commandInfo, nullptr, &commands));
        VkCommandBufferAllocateInfo commandAllocation{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
        commandAllocation.commandPool = commands; commandAllocation.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; commandAllocation.commandBufferCount = 1;
        checked(vkAllocateCommandBuffers(device, &commandAllocation, &command));
        VkFenceCreateInfo fenceInfo{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO}; checked(vkCreateFence(device, &fenceInfo, nullptr, &fence));
    }
    bool apply(const uint8_t *input, uint8_t *output, uint8_t *repair, uint32_t width, uint32_t height,
               uint32_t stride, const float *table, uint32_t grid) {
        const uint64_t count = uint64_t(width) * height, bytes = count * 4;
        if (!input || !output || !repair || !table || !width || !height || grid != 33 || uint64_t(stride) < uint64_t(width) * 4
            || uint64_t(stride) * height > UINT32_MAX || bytes > properties.limits.maxStorageBufferRange
            || (uint64_t(width) + 15) / 16 > properties.limits.maxComputeWorkGroupCount[0]
            || (uint64_t(height) + 15) / 16 > properties.limits.maxComputeWorkGroupCount[1]) return false;
        std::lock_guard<std::mutex> guard(lock);
        if (failed) return false;
        try {
            const std::array<VkDeviceSize, 3> sizes{bytes, bytes, uint64_t(grid) * grid * grid * 3 * sizeof(float)};
            for (size_t i = 0; i < 3; ++i) if (!buffers[i] || buffers[i]->capacity < sizes[i]) {
                auto made = std::make_unique<Buffer>(); made->create(device, physical, sizes[i]); buffers[i] = std::move(made);
            }
            for (uint32_t y = 0; y < height; ++y)
                memcpy(static_cast<uint8_t *>(buffers[0]->mapped) + size_t(y) * width * 4, input + size_t(y) * stride, size_t(width) * 4);
            memcpy(buffers[2]->mapped, table, sizes[2]); buffers[0]->synchronize(true); buffers[2]->synchronize(true);
            VkDescriptorBufferInfo infos[3]{}; VkWriteDescriptorSet writes[3]{};
            for (uint32_t i = 0; i < 3; ++i) {
                infos[i] = {buffers[i]->buffer, 0, sizes[i]};
                writes[i].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
                writes[i].dstSet = descriptors; writes[i].dstBinding = i; writes[i].descriptorCount = 1;
                writes[i].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER; writes[i].pBufferInfo = &infos[i];
            }
            vkUpdateDescriptorSets(device, 3, writes, 0, nullptr);
            checked(vkResetCommandBuffer(command, 0)); checked(vkResetFences(device, 1, &fence));
            VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO}; begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
            checked(vkBeginCommandBuffer(command, &begin));
            VkMemoryBarrier barrier{VK_STRUCTURE_TYPE_MEMORY_BARRIER};
            barrier.srcAccessMask = VK_ACCESS_HOST_WRITE_BIT; barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
            vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_HOST_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &barrier, 0, nullptr, 0, nullptr);
            vkCmdBindPipeline(command, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
            vkCmdBindDescriptorSets(command, VK_PIPELINE_BIND_POINT_COMPUTE, pipelineLayout, 0, 1, &descriptors, 0, nullptr);
            const uint32_t parameters[3]{width, height, grid};
            vkCmdPushConstants(command, pipelineLayout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(parameters), parameters);
            vkCmdDispatch(command, (width + 15) / 16, (height + 15) / 16, 1);
            barrier.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT; barrier.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
            vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &barrier, 0, nullptr, 0, nullptr);
            checked(vkEndCommandBuffer(command));
            VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO}; submit.commandBufferCount = 1; submit.pCommandBuffers = &command;
            checked(vkQueueSubmit(queue, 1, &submit, fence)); checked(vkWaitForFences(device, 1, &fence, VK_TRUE, UINT64_MAX));
            buffers[0]->synchronize(false); buffers[1]->synchronize(false);
            memcpy(output, input, size_t(stride) * height);
            for (uint32_t y = 0; y < height; ++y)
                memcpy(output + size_t(y) * stride, static_cast<uint8_t *>(buffers[0]->mapped) + size_t(y) * width * 4, size_t(width) * 4);
            const auto flags = static_cast<const uint32_t *>(buffers[1]->mapped);
            for (size_t i = 0; i < count; ++i) repair[i] = flags[i] != 0;
            ++submissions;
            return true;
        } catch (...) { failed = true; return false; }
    }
};

extern "C" CompositorCameraRawLookup *compositor_camera_raw_lookup_create() {
    try { auto value = std::make_unique<CompositorCameraRawLookup>(); value->initialize(); return value.release(); }
    catch (...) { return nullptr; }
}
extern "C" void compositor_camera_raw_lookup_destroy(CompositorCameraRawLookup *c) { delete c; }
extern "C" void compositor_camera_raw_lookup_discard(CompositorCameraRawLookup *c) {
    if (!c) return;
    std::lock_guard<std::mutex> guard(c->lock); for (auto &buffer : c->buffers) buffer.reset();
}
extern "C" const char *compositor_camera_raw_lookup_device(CompositorCameraRawLookup *c) { return c ? c->properties.deviceName : "unavailable"; }
extern "C" uint64_t compositor_camera_raw_lookup_submissions(CompositorCameraRawLookup *c) {
    if (!c) return 0;
    std::lock_guard<std::mutex> guard(c->lock); return c->submissions;
}
extern "C" uint64_t compositor_camera_raw_lookup_max_pixels(CompositorCameraRawLookup *c) { return c ? c->properties.limits.maxStorageBufferRange / 4 : 0; }
extern "C" int compositor_camera_raw_lookup_apply(CompositorCameraRawLookup *c, const uint8_t *input,
    uint8_t *output, uint8_t *repair, uint32_t width, uint32_t height, uint32_t stride, const float *table, uint32_t grid) {
    return c && c->apply(input, output, repair, width, height, stride, table, grid) ? 1 : 0;
}
