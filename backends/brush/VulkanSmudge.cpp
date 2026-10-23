#include "include/CompositorBrushBackend.h"
#include <cmath>
#include "shaders/warp_smudge_spv.h"
#include "shaders/warp_liquify_spv.h"
#include "shaders/warp_smudge_packed_spv.h"
#include "shaders/warp_liquify_packed_spv.h"
#include <vulkan/vulkan.h>
#include <algorithm>
#include <array>
#include <cstring>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <vector>

namespace {
void check(VkResult result) { if (result != VK_SUCCESS) throw std::runtime_error("Vulkan smudge operation failed"); }
struct Buffer {
    VkDevice device = VK_NULL_HANDLE;
    VkBuffer buffer = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    void *mapped = nullptr;
    bool coherent = false;
    bool cached = false;
    VkDeviceSize capacity = 0;
    ~Buffer() {
        if (mapped) vkUnmapMemory(device,memory);
        if (buffer) vkDestroyBuffer(device,buffer,nullptr);
        if (memory) vkFreeMemory(device,memory,nullptr);
    }
    void create(VkDevice dev, VkPhysicalDevice physical, VkDeviceSize bytes,bool readback=false) {
        device = dev;
        VkBufferCreateInfo info{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
        info.size=bytes; info.usage=VK_BUFFER_USAGE_STORAGE_BUFFER_BIT; info.sharingMode=VK_SHARING_MODE_EXCLUSIVE;
        check(vkCreateBuffer(device,&info,nullptr,&buffer));
        VkMemoryRequirements requirements{}; vkGetBufferMemoryRequirements(device,buffer,&requirements);
        VkPhysicalDeviceMemoryProperties properties{}; vkGetPhysicalDeviceMemoryProperties(physical,&properties);
        uint32_t type = UINT32_MAX;
        int best = -1;
        for (uint32_t i=0;i<properties.memoryTypeCount;++i) {
            const auto flags=properties.memoryTypes[i].propertyFlags;
            if ((requirements.memoryTypeBits&(1u<<i)) && (flags&VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)) {
                const int score=readback
                    ? ((flags&VK_MEMORY_PROPERTY_HOST_CACHED_BIT)?16:0)+((flags&VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)?4:0)
                    : ((flags&VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)?8:0)+((flags&VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)?4:0);
                if (score>best) { type=i; best=score; }
            }
        }
        if (type==UINT32_MAX) throw std::runtime_error("No host-visible Vulkan memory");
        coherent=(properties.memoryTypes[type].propertyFlags&VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)!=0;
        cached=(properties.memoryTypes[type].propertyFlags&VK_MEMORY_PROPERTY_HOST_CACHED_BIT)!=0;
        VkMemoryAllocateInfo allocation{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
        allocation.allocationSize=requirements.size; allocation.memoryTypeIndex=type;
        check(vkAllocateMemory(device,&allocation,nullptr,&memory));
        check(vkBindBufferMemory(device,buffer,memory,0));
        check(vkMapMemory(device,memory,0,VK_WHOLE_SIZE,0,&mapped));
        capacity=bytes;
    }
    void flush() {
        if (coherent) return;
        VkMappedMemoryRange range{VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE}; range.memory=memory; range.size=VK_WHOLE_SIZE;
        check(vkFlushMappedMemoryRanges(device,1,&range));
    }
    void invalidate() {
        if (coherent) return;
        VkMappedMemoryRange range{VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE}; range.memory=memory; range.size=VK_WHOLE_SIZE;
        check(vkInvalidateMappedMemoryRanges(device,1,&range));
    }
};
}

struct CompositorVulkanSmudge {
    std::mutex lock;
    VkInstance instance=VK_NULL_HANDLE;
    VkDevice device=VK_NULL_HANDLE;
    VkQueue queue=VK_NULL_HANDLE;
    VkDescriptorSetLayout descriptorLayout=VK_NULL_HANDLE;
    VkDescriptorPool descriptorPool=VK_NULL_HANDLE;
    VkDescriptorSet descriptorSet=VK_NULL_HANDLE;
    VkPipelineLayout pipelineLayout=VK_NULL_HANDLE;
    VkPipeline pipeline=VK_NULL_HANDLE;
    VkShaderModule shader=VK_NULL_HANDLE;
    VkPipeline liquifyPipeline=VK_NULL_HANDLE;
    VkShaderModule liquifyShader=VK_NULL_HANDLE;
    VkPipeline packedSmudgePipeline=VK_NULL_HANDLE,packedLiquifyPipeline=VK_NULL_HANDLE;
    VkShaderModule packedSmudgeShader=VK_NULL_HANDLE,packedLiquifyShader=VK_NULL_HANDLE;
    VkCommandPool commandPool=VK_NULL_HANDLE;
    VkCommandBuffer command=VK_NULL_HANDLE;
    VkFence fence=VK_NULL_HANDLE;
    VkPhysicalDeviceProperties properties{};
    std::array<std::unique_ptr<Buffer>,5> buffers;
    std::unique_ptr<Buffer> original;
    std::unique_ptr<Buffer> radial;
    uint32_t radialRadius=UINT32_MAX;
    uint32_t originalWidth=0,originalHeight=0;
    bool usable=true;
    VkPhysicalDevice physical=VK_NULL_HANDLE;

    ~CompositorVulkanSmudge() {
        if (device) vkDeviceWaitIdle(device);
        if (fence) vkDestroyFence(device,fence,nullptr);
        if (commandPool) vkDestroyCommandPool(device,commandPool,nullptr);
        if (pipeline) vkDestroyPipeline(device,pipeline,nullptr);
        if (shader) vkDestroyShaderModule(device,shader,nullptr);
        if (liquifyPipeline) vkDestroyPipeline(device,liquifyPipeline,nullptr);
        if (liquifyShader) vkDestroyShaderModule(device,liquifyShader,nullptr);
        if (packedSmudgePipeline) vkDestroyPipeline(device,packedSmudgePipeline,nullptr);
        if (packedLiquifyPipeline) vkDestroyPipeline(device,packedLiquifyPipeline,nullptr);
        if (packedSmudgeShader) vkDestroyShaderModule(device,packedSmudgeShader,nullptr);
        if (packedLiquifyShader) vkDestroyShaderModule(device,packedLiquifyShader,nullptr);
        if (pipelineLayout) vkDestroyPipelineLayout(device,pipelineLayout,nullptr);
        if (descriptorPool) vkDestroyDescriptorPool(device,descriptorPool,nullptr);
        if (descriptorLayout) vkDestroyDescriptorSetLayout(device,descriptorLayout,nullptr);
        for (auto &buffer: buffers) buffer.reset();
        original.reset();
        radial.reset();
        if (device) vkDestroyDevice(device,nullptr);
        if (instance) vkDestroyInstance(instance,nullptr);
    }
    void initialize() {

        static_assert(sizeof(CompositorLiquifyUniforms)==48,"Liquify push constant layout mismatch");
        static_assert(sizeof(CompositorLiquifyPackedUniforms)==64,"Packed Liquify layout mismatch");
        static_assert(sizeof(CompositorSmudgePackedUniforms)==48,"Packed Smudge layout mismatch");
        VkApplicationInfo application{VK_STRUCTURE_TYPE_APPLICATION_INFO};
        application.pApplicationName="Compositor warp"; application.apiVersion=VK_API_VERSION_1_2;
        VkInstanceCreateInfo info{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO}; info.pApplicationInfo=&application;
        check(vkCreateInstance(&info,nullptr,&instance));
        uint32_t count=0; check(vkEnumeratePhysicalDevices(instance,&count,nullptr));
        std::vector<VkPhysicalDevice> devices(count); check(vkEnumeratePhysicalDevices(instance,&count,devices.data()));
        VkPhysicalDevice chosen=VK_NULL_HANDLE; uint32_t family=0; int best=-1;
        for (auto candidate: devices) {
            VkPhysicalDeviceFloatControlsProperties floats{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FLOAT_CONTROLS_PROPERTIES};
            VkPhysicalDeviceProperties2 details{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2}; details.pNext=&floats;
            vkGetPhysicalDeviceProperties2(candidate,&details);
            const auto &props=details.properties;
            if (props.apiVersion<VK_API_VERSION_1_2 || !floats.shaderDenormPreserveFloat32 ||
                !floats.shaderSignedZeroInfNanPreserveFloat32 || !floats.shaderRoundingModeRTEFloat32) continue;
            if (props.limits.maxComputeWorkGroupInvocations<256 || props.limits.maxComputeWorkGroupSize[0]<16 ||
                props.limits.maxComputeWorkGroupSize[1]<16 || props.limits.maxStorageBufferRange<256*256*4 ||
                props.limits.maxPerStageDescriptorStorageBuffers<5 || props.limits.maxDescriptorSetStorageBuffers<5) continue;
            uint32_t families=0; vkGetPhysicalDeviceQueueFamilyProperties(candidate,&families,nullptr);
            std::vector<VkQueueFamilyProperties> queues(families); vkGetPhysicalDeviceQueueFamilyProperties(candidate,&families,queues.data());
            const int score=props.deviceType==VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU?3:
                props.deviceType==VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU?2:props.deviceType==VK_PHYSICAL_DEVICE_TYPE_CPU?0:1;
            for (uint32_t i=0;i<families;++i) if (queues[i].queueCount && (queues[i].queueFlags&VK_QUEUE_COMPUTE_BIT) && score>best) {
                chosen=candidate; family=i; best=score; properties=props;
            }
        }
        if (!chosen) throw std::runtime_error("No Vulkan compute queue");
        physical=chosen;
        float priority=1;
        VkDeviceQueueCreateInfo queueInfo{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
        queueInfo.queueFamilyIndex=family; queueInfo.queueCount=1; queueInfo.pQueuePriorities=&priority;
        VkDeviceCreateInfo deviceInfo{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO}; deviceInfo.queueCreateInfoCount=1; deviceInfo.pQueueCreateInfos=&queueInfo;
        check(vkCreateDevice(chosen,&deviceInfo,nullptr,&device)); vkGetDeviceQueue(device,family,0,&queue);
        VkDescriptorSetLayoutBinding bindings[5]{};
        for (uint32_t i=0;i<5;++i) {
            bindings[i].binding=i; bindings[i].descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            bindings[i].descriptorCount=1; bindings[i].stageFlags=VK_SHADER_STAGE_COMPUTE_BIT;
        }
        VkDescriptorSetLayoutCreateInfo layoutInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
        layoutInfo.bindingCount=5; layoutInfo.pBindings=bindings;
        check(vkCreateDescriptorSetLayout(device,&layoutInfo,nullptr,&descriptorLayout));
        VkPushConstantRange constants{VK_SHADER_STAGE_COMPUTE_BIT,0,64};
        VkPipelineLayoutCreateInfo pipelineInfo{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
        pipelineInfo.setLayoutCount=1; pipelineInfo.pSetLayouts=&descriptorLayout;
        pipelineInfo.pushConstantRangeCount=1; pipelineInfo.pPushConstantRanges=&constants;
        check(vkCreatePipelineLayout(device,&pipelineInfo,nullptr,&pipelineLayout));
        VkShaderModuleCreateInfo shaderInfo{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
        shaderInfo.codeSize=sizeof(compositor_smudge_spv); shaderInfo.pCode=compositor_smudge_spv;
        check(vkCreateShaderModule(device,&shaderInfo,nullptr,&shader));
        VkComputePipelineCreateInfo compute{VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};
        compute.stage.sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        compute.stage.stage=VK_SHADER_STAGE_COMPUTE_BIT; compute.stage.module=shader; compute.stage.pName="main";
        compute.layout=pipelineLayout;
        check(vkCreateComputePipelines(device,VK_NULL_HANDLE,1,&compute,nullptr,&pipeline));
        VkDescriptorPoolSize poolSize{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,5};
        VkDescriptorPoolCreateInfo poolInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};
        poolInfo.maxSets=1; poolInfo.poolSizeCount=1; poolInfo.pPoolSizes=&poolSize;
        check(vkCreateDescriptorPool(device,&poolInfo,nullptr,&descriptorPool));
        VkDescriptorSetAllocateInfo allocate{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
        allocate.descriptorPool=descriptorPool; allocate.descriptorSetCount=1; allocate.pSetLayouts=&descriptorLayout;
        check(vkAllocateDescriptorSets(device,&allocate,&descriptorSet));
        VkCommandPoolCreateInfo commandInfo{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
        commandInfo.flags=VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT; commandInfo.queueFamilyIndex=family;
        check(vkCreateCommandPool(device,&commandInfo,nullptr,&commandPool));
        VkCommandBufferAllocateInfo commandAllocate{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
        commandAllocate.commandPool=commandPool; commandAllocate.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY; commandAllocate.commandBufferCount=1;
        check(vkAllocateCommandBuffers(device,&commandAllocate,&command));
        VkFenceCreateInfo fenceInfo{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO}; check(vkCreateFence(device,&fenceInfo,nullptr,&fence));
    }
    void reserve(const std::array<VkDeviceSize,5> &sizes,bool liquify=false,bool radialWeights=false) {
        for (uint32_t i=0;i<5;++i) {
            if (sizes[i]>properties.limits.maxStorageBufferRange) throw std::runtime_error("Warp buffer too large");
            if (buffers[i] && buffers[i]->capacity>=sizes[i]) continue;
            // CPU reads carried colors, packed pixels and offsets. Uncached mappings make those reads expensive.
            auto next=std::make_unique<Buffer>(); next->create(device,physical,sizes[i],i==1 || i>=3);
            buffers[i]=std::move(next);
        }
        VkDescriptorBufferInfo info[5]{}; VkWriteDescriptorSet writes[5]{};
        for (uint32_t i=0;i<5;++i) {
            Buffer *buffer=liquify && i==0?original.get():radialWeights && i==2?radial.get():buffers[i].get();
            info[i]={buffer->buffer,0,buffer->capacity};
            writes[i].sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET; writes[i].dstSet=descriptorSet;
            writes[i].dstBinding=i; writes[i].descriptorCount=1;
            writes[i].descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER; writes[i].pBufferInfo=&info[i];
        }
        vkUpdateDescriptorSets(device,5,writes,0,nullptr);
    }
    void render(uint32_t width,uint32_t height,float strength,const float *under,
                const float *carried,const float *weights,float *output) {
        const size_t pixels=size_t(width)*height;
        reserve({pixels*16,pixels*16,pixels*4,16,16});
        struct Parameters { uint32_t width,height; float strength; uint32_t padding; } u{width,height,strength,0};
        std::memcpy(buffers[0]->mapped,under,pixels*16);
        std::memcpy(buffers[1]->mapped,carried,pixels*16);
        std::memcpy(buffers[2]->mapped,weights,pixels*4);
        for (auto &buffer: buffers) buffer->flush();
        dispatch(width,height,pipeline,&u,sizeof(u));
        buffers[1]->invalidate();
        std::memcpy(output,buffers[1]->mapped,pixels*16);
    }
    void setOriginal(uint32_t width,uint32_t height,const float *rgba) {
        const VkDeviceSize bytes=VkDeviceSize(width)*height*16;
        if (bytes>properties.limits.maxStorageBufferRange) throw std::runtime_error("Liquify source too large");
        auto next=std::make_unique<Buffer>(); next->create(device,physical,bytes);
        std::memcpy(next->mapped,rgba,bytes); next->flush();
        original=std::move(next); originalWidth=width; originalHeight=height;
    }
    void setWeights(uint32_t radius,const float *weights,size_t count) {
        const VkDeviceSize bytes=count*sizeof(float);
        if (bytes>properties.limits.maxStorageBufferRange) throw std::runtime_error("Warp falloff too large");
        auto next=std::make_unique<Buffer>(); next->create(device,physical,bytes);
        std::memcpy(next->mapped,weights,bytes); next->flush();
        radial=std::move(next); radialRadius=radius;
    }
    void makePipeline(const uint32_t *words,size_t size,VkShaderModule &module,VkPipeline &result) {
        if (result) return;
        VkShaderModuleCreateInfo info{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO}; info.codeSize=size; info.pCode=words;
        check(vkCreateShaderModule(device,&info,nullptr,&module));
        VkComputePipelineCreateInfo compute{VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};
        compute.stage.sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        compute.stage.stage=VK_SHADER_STAGE_COMPUTE_BIT; compute.stage.module=module; compute.stage.pName="main";
        compute.layout=pipelineLayout;
        check(vkCreateComputePipelines(device,VK_NULL_HANDLE,1,&compute,nullptr,&result));
    }
    void smudgePacked(const CompositorSmudgePackedUniforms &u,const void *under,const float *carried,
                      float *outCarried,void *outPixels) {
        makePipeline(compositor_smudge_packed_spv,sizeof(compositor_smudge_packed_spv),packedSmudgeShader,packedSmudgePipeline);
        const size_t count=size_t(u.width)*u.height, bytes=count*(u.format==0?4:8);
        reserve({bytes,count*16,16,bytes,16},false,true);
        std::memcpy(buffers[0]->mapped,under,bytes);
        std::memcpy(buffers[1]->mapped,carried,count*16);
        buffers[0]->flush(); buffers[1]->flush();
        dispatch(u.width,u.height,packedSmudgePipeline,&u,sizeof(u));
        buffers[1]->invalidate(); buffers[3]->invalidate();
        std::memcpy(outCarried,buffers[1]->mapped,count*16);
        std::memcpy(outPixels,buffers[3]->mapped,bytes);
    }
    void liquifyPacked(const CompositorLiquifyPackedUniforms &u,const float *prior,float *outOffsets,void *outPixels) {
        makePipeline(compositor_liquify_packed_spv,sizeof(compositor_liquify_packed_spv),packedLiquifyShader,packedLiquifyPipeline);
        const size_t count=size_t(u.base.width)*u.base.height, bytes=count*(u.base.padding0==0?4:8);
        reserve({16,count*8,16,count*8,bytes},true,true);
        std::memcpy(buffers[1]->mapped,prior,count*8); buffers[1]->flush();
        dispatch(u.base.width,u.base.height,packedLiquifyPipeline,&u,sizeof(u));
        buffers[3]->invalidate(); buffers[4]->invalidate();
        std::memcpy(outOffsets,buffers[3]->mapped,count*8);
        std::memcpy(outPixels,buffers[4]->mapped,bytes);
    }
    void liquify(const CompositorLiquifyUniforms &u,const float *prior,const float *weights,float *offsets,float *pixels) {
        if (!liquifyPipeline) {
            VkShaderModuleCreateInfo shaderInfo{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
            shaderInfo.codeSize=sizeof(compositor_liquify_spv); shaderInfo.pCode=compositor_liquify_spv;
            check(vkCreateShaderModule(device,&shaderInfo,nullptr,&liquifyShader));
            VkComputePipelineCreateInfo compute{VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};
            compute.stage.sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
            compute.stage.stage=VK_SHADER_STAGE_COMPUTE_BIT; compute.stage.module=liquifyShader; compute.stage.pName="main";
            compute.layout=pipelineLayout;
            check(vkCreateComputePipelines(device,VK_NULL_HANDLE,1,&compute,nullptr,&liquifyPipeline));
        }
        const size_t count=size_t(u.width)*u.height;
        reserve({16,count*8,count*4,count*8,count*16},true);
        std::memcpy(buffers[1]->mapped,prior,count*8);
        std::memcpy(buffers[2]->mapped,weights,count*4);
        buffers[1]->flush(); buffers[2]->flush();
        dispatch(u.width,u.height,liquifyPipeline,&u,sizeof(u));
        // Validate visibility of both outputs before changing either caller buffer.
        buffers[3]->invalidate(); buffers[4]->invalidate();
        std::memcpy(offsets,buffers[3]->mapped,count*8);
        std::memcpy(pixels,buffers[4]->mapped,count*16);
    }
    void dispatch(uint32_t width,uint32_t height,VkPipeline selected,const void *parameters,uint32_t bytes) {
        check(vkResetFences(device,1,&fence)); check(vkResetCommandBuffer(command,0));
        VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO}; begin.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        check(vkBeginCommandBuffer(command,&begin));
        VkMemoryBarrier upload{VK_STRUCTURE_TYPE_MEMORY_BARRIER}; upload.srcAccessMask=VK_ACCESS_HOST_WRITE_BIT;
        upload.dstAccessMask=VK_ACCESS_SHADER_READ_BIT|VK_ACCESS_SHADER_WRITE_BIT;
        vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_HOST_BIT,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,0,1,&upload,0,nullptr,0,nullptr);
        vkCmdBindPipeline(command,VK_PIPELINE_BIND_POINT_COMPUTE,selected);
        vkCmdBindDescriptorSets(command,VK_PIPELINE_BIND_POINT_COMPUTE,pipelineLayout,0,1,&descriptorSet,0,nullptr);
        vkCmdPushConstants(command,pipelineLayout,VK_SHADER_STAGE_COMPUTE_BIT,0,bytes,parameters);
        vkCmdDispatch(command,(width+15)/16,(height+15)/16,1);
        VkMemoryBarrier download{VK_STRUCTURE_TYPE_MEMORY_BARRIER}; download.srcAccessMask=VK_ACCESS_SHADER_WRITE_BIT; download.dstAccessMask=VK_ACCESS_HOST_READ_BIT;
        vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,1,&download,0,nullptr,0,nullptr);
        check(vkEndCommandBuffer(command));
        VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO}; submit.commandBufferCount=1; submit.pCommandBuffers=&command;
        check(vkQueueSubmit(queue,1,&submit,fence));
        check(vkWaitForFences(device,1,&fence,VK_TRUE,UINT64_MAX));
    }
};
extern "C" CompositorVulkanSmudge *compositor_vulkan_smudge_create() {
    try { auto context=std::make_unique<CompositorVulkanSmudge>(); context->initialize(); return context.release(); }
    catch (...) { return nullptr; }
}
extern "C" void compositor_vulkan_smudge_destroy(CompositorVulkanSmudge *context) { delete context; }
extern "C" int compositor_vulkan_smudge_render(CompositorVulkanSmudge *context,
    uint32_t width,uint32_t height,float strength,const float *under,const float *carried,const float *weights,float *output) {
    if (!width || !height || width>65536 || height>65536 || !std::isfinite(strength) || strength<0 || strength>1 ||
        !under || !carried || !weights || !output) return -1;
    if (!context) return -2;
    std::lock_guard<std::mutex> guard(context->lock);
    if (!context->usable) return -2;
    if ((width+15)/16>context->properties.limits.maxComputeWorkGroupCount[0] ||
        (height+15)/16>context->properties.limits.maxComputeWorkGroupCount[1]) return -1;
    try { context->render(width,height,strength,under,carried,weights,output); return 0; }
    catch (...) { context->usable=false; return -2; }
}
extern "C" const char *compositor_vulkan_smudge_device(CompositorVulkanSmudge *c) { return c?c->properties.deviceName:"unavailable"; }
extern "C" uint32_t compositor_vulkan_smudge_device_type(CompositorVulkanSmudge *c) { return c?c->properties.deviceType:0; }
extern "C" uint32_t compositor_vulkan_warp_cached_buffers(CompositorVulkanSmudge *c) {
    if (!c) return 0;
    std::lock_guard<std::mutex> guard(c->lock);
    uint32_t flags=0;
    for (uint32_t i=0;i<5;++i) if (c->buffers[i] && c->buffers[i]->cached) flags|=1u<<i;
    return flags;
}
extern "C" int compositor_vulkan_liquify_original(CompositorVulkanSmudge *c,uint32_t width,uint32_t height,const float *rgba) {
    if (width<2 || height<2 || width>65536 || height>65536 || !rgba) return -1;
    if (!c) return -2;
    std::lock_guard<std::mutex> guard(c->lock);
    if (!c->usable) return -2;
    try { c->setOriginal(width,height,rgba); return 0; }
    catch (...) { c->usable=false; return -2; }
}
extern "C" int compositor_vulkan_liquify_render(CompositorVulkanSmudge *c,
    const CompositorLiquifyUniforms *u,const float *prior,const float *weights,float *offsets,float *pixels) {
    if (!u || !prior || !weights || !offsets || !pixels || u->width<2 || u->height<2 ||
        u->width>65536 || u->height>65536 || !std::isfinite(u->move_x) || !std::isfinite(u->move_y) ||
        uint64_t(u->origin_x)+u->width>u->source_width || uint64_t(u->origin_y)+u->height>u->source_height) return -1;
    if (!c) return -2;
    std::lock_guard<std::mutex> guard(c->lock);
    if (!c->usable) return -2;
    if (!c->original || u->source_width!=c->originalWidth || u->source_height!=c->originalHeight ||
        (u->width+15)/16>c->properties.limits.maxComputeWorkGroupCount[0] ||
        (u->height+15)/16>c->properties.limits.maxComputeWorkGroupCount[1]) return -1;
    try { c->liquify(*u,prior,weights,offsets,pixels); return 0; }
    catch (...) { c->usable=false; return -2; }
}
extern "C" int compositor_vulkan_warp_weights(CompositorVulkanSmudge *c,uint32_t radius,const float *weights,size_t count) {
    if (!weights || radius>32767 || count!=size_t(radius)*radius*2+1) return -1;
    if (!c) return -2;
    std::lock_guard<std::mutex> guard(c->lock);
    if (!c->usable) return -2;
    try { c->setWeights(radius,weights,count); return 0; }
    catch (...) { c->usable=false; return -2; }
}
namespace {
bool validCenter(int32_t x,int32_t y) {
    return x>=INT32_MIN+65536 && y>=INT32_MIN+65536 && x<=INT32_MAX-65536 && y<=INT32_MAX-65536;
}
bool validDispatch(CompositorVulkanSmudge *c,uint32_t width,uint32_t height) {
    return (width+15)/16<=c->properties.limits.maxComputeWorkGroupCount[0] &&
           (height+15)/16<=c->properties.limits.maxComputeWorkGroupCount[1];
}
}
extern "C" int compositor_vulkan_smudge_packed(CompositorVulkanSmudge *c,const CompositorSmudgePackedUniforms *u,
    const void *under,const float *carried,float *outCarried,void *outPixels) {
    if (!u || !under || !carried || !outCarried || !outPixels || u->radius>32767 || u->format>2 ||
        u->width!=u->radius*2+1 || u->height!=u->width || !u->canvas_width || !u->canvas_height ||
        u->canvas_width>65536 || u->canvas_height>65536 || !std::isfinite(u->strength) || u->strength<0 || u->strength>1 ||
        !validCenter(u->center_x,u->center_y)) return -1;
    if (!c) return -2;
    std::lock_guard<std::mutex> guard(c->lock);
    if (!c->usable) return -2;
    if (!c->radial || c->radialRadius!=u->radius || !validDispatch(c,u->width,u->height)) return -1;
    try { c->smudgePacked(*u,under,carried,outCarried,outPixels); return 0; }
    catch (...) { c->usable=false; return -2; }
}
extern "C" int compositor_vulkan_liquify_packed(CompositorVulkanSmudge *c,const CompositorLiquifyPackedUniforms *u,
    const float *prior,float *outOffsets,void *outPixels) {
    if (!u || !prior || !outOffsets || !outPixels || u->radius>32767 || u->base.padding0>2 ||
        u->base.width<2 || u->base.height<2 || u->base.width>65536 || u->base.height>65536 ||
        !std::isfinite(u->base.move_x) || !std::isfinite(u->base.move_y) || !validCenter(u->center_x,u->center_y) ||
        uint64_t(u->base.origin_x)+u->base.width>u->base.source_width ||
        uint64_t(u->base.origin_y)+u->base.height>u->base.source_height) return -1;
    if (!c) return -2;
    std::lock_guard<std::mutex> guard(c->lock);
    if (!c->usable) return -2;
    if (!c->radial || c->radialRadius!=u->radius || !c->original ||
        u->base.source_width!=c->originalWidth || u->base.source_height!=c->originalHeight ||
        !validDispatch(c,u->base.width,u->base.height)) return -1;
    try { c->liquifyPacked(*u,prior,outOffsets,outPixels); return 0; }
    catch (...) { c->usable=false; return -2; }
}
