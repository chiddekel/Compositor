#include "include/VulkanRaster.h"
#include "shaders/raster_spv.h"
#include "shaders/raster_fused_spv.h"
#include <vulkan/vulkan.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstring>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <vector>
namespace {
void check(VkResult result) { if (result != VK_SUCCESS) throw std::runtime_error("Vulkan raster operation failed"); }
/// A graph beyond the retained-memory budget: refused, while the device stays usable. (A buffer beyond the device's
/// storage range is still a device failure, as callers and tests rely on.)
struct TooLarge : std::runtime_error { using std::runtime_error::runtime_error; };
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

struct CompositorVulkanRaster {
    std::atomic<uint32_t> references{1};
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
    VkCommandPool commandPool=VK_NULL_HANDLE;
    VkCommandBuffer command=VK_NULL_HANDLE;
    VkFence fence=VK_NULL_HANDLE;
    VkPhysicalDeviceProperties properties{};
    VkPhysicalDevice physical=VK_NULL_HANDLE;
    std::array<std::unique_ptr<Buffer>,5> buffers;
    bool usable=true;
    uint64_t submissions=0;
    uint64_t uploadBytes=0;
    uint64_t generation=0;
    uint64_t readbackBytes=0;
    uint64_t residentBytes=0;
    uint64_t bokehSubmissions=0;
    std::array<size_t,3> inputBytes{};
    VkDescriptorPool graphPool=VK_NULL_HANDLE;
    uint32_t graphPoolCapacity=0;
    std::vector<std::unique_ptr<Buffer>> graphInputs,graphOutputs,graphParameters;
    std::vector<size_t> graphInputBytes;
    // The fused graph pass: all inputs in one buffer, steps as data, intermediates in registers.
    static constexpr uint32_t fusedRegisters=16;
    struct FusedStep { uint32_t header[4]; uint32_t slots[4]; float values[20]; };
    VkDescriptorSetLayout fusedLayout=VK_NULL_HANDLE;
    VkPipelineLayout fusedPipelineLayout=VK_NULL_HANDLE;
    VkShaderModule fusedShader=VK_NULL_HANDLE;
    VkPipeline fusedPipeline=VK_NULL_HANDLE;
    VkDescriptorPool fusedPool=VK_NULL_HANDLE;
    VkDescriptorSet fusedSet=VK_NULL_HANDLE;
    std::unique_ptr<Buffer> fusedInputs,fusedOutput,fusedSteps;
    std::vector<size_t> fusedInputBytes;
    // Which graph path filled its retained inputs last: switching paths uploads everything again.
    int lastGraphPath=-1;
    uint64_t fusedSubmissions=0;
    ~CompositorVulkanRaster() {
        if (device) vkDeviceWaitIdle(device);
        if (fence) vkDestroyFence(device,fence,nullptr);
        if (commandPool) vkDestroyCommandPool(device,commandPool,nullptr);
        if (fusedPipeline) vkDestroyPipeline(device,fusedPipeline,nullptr);
        if (fusedShader) vkDestroyShaderModule(device,fusedShader,nullptr);
        if (fusedPipelineLayout) vkDestroyPipelineLayout(device,fusedPipelineLayout,nullptr);
        if (fusedPool) vkDestroyDescriptorPool(device,fusedPool,nullptr);
        if (fusedLayout) vkDestroyDescriptorSetLayout(device,fusedLayout,nullptr);
        fusedInputs.reset(); fusedOutput.reset(); fusedSteps.reset();
        if (pipeline) vkDestroyPipeline(device,pipeline,nullptr);
        if (shader) vkDestroyShaderModule(device,shader,nullptr);
        if (pipelineLayout) vkDestroyPipelineLayout(device,pipelineLayout,nullptr);
        if (descriptorPool) vkDestroyDescriptorPool(device,descriptorPool,nullptr);
        if (graphPool) vkDestroyDescriptorPool(device,graphPool,nullptr);
        if (descriptorLayout) vkDestroyDescriptorSetLayout(device,descriptorLayout,nullptr);
        graphInputs.clear(); graphOutputs.clear(); graphParameters.clear();
        for (auto &buffer: buffers) buffer.reset();
        if (device) vkDestroyDevice(device,nullptr);
        if (instance) vkDestroyInstance(instance,nullptr);
    }
    void initialize(bool allowSoftware) {
        VkApplicationInfo application{VK_STRUCTURE_TYPE_APPLICATION_INFO};
        application.pApplicationName="Compositor raster"; application.apiVersion=VK_API_VERSION_1_2;
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
            VkPhysicalDeviceFeatures features{};
            vkGetPhysicalDeviceFeatures(candidate,&features);
            if (!features.shaderFloat64) continue;
            if (!allowSoftware && props.deviceType!=VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU && props.deviceType!=VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU) continue;
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
        VkPhysicalDeviceFeatures enabled{}; enabled.shaderFloat64=VK_TRUE; deviceInfo.pEnabledFeatures=&enabled;
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
        shaderInfo.codeSize=sizeof(compositor_raster_spv); shaderInfo.pCode=compositor_raster_spv;
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
        VkDescriptorSetLayoutBinding fusedBindings[3]{};
        for (uint32_t i=0;i<3;++i) {
            fusedBindings[i].binding=i; fusedBindings[i].descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            fusedBindings[i].descriptorCount=1; fusedBindings[i].stageFlags=VK_SHADER_STAGE_COMPUTE_BIT;
        }
        VkDescriptorSetLayoutCreateInfo fusedLayoutInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
        fusedLayoutInfo.bindingCount=3; fusedLayoutInfo.pBindings=fusedBindings;
        check(vkCreateDescriptorSetLayout(device,&fusedLayoutInfo,nullptr,&fusedLayout));
        VkPushConstantRange fusedConstants{VK_SHADER_STAGE_COMPUTE_BIT,0,16};
        VkPipelineLayoutCreateInfo fusedPipelineInfo{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
        fusedPipelineInfo.setLayoutCount=1; fusedPipelineInfo.pSetLayouts=&fusedLayout;
        fusedPipelineInfo.pushConstantRangeCount=1; fusedPipelineInfo.pPushConstantRanges=&fusedConstants;
        check(vkCreatePipelineLayout(device,&fusedPipelineInfo,nullptr,&fusedPipelineLayout));
        VkShaderModuleCreateInfo fusedShaderInfo{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
        fusedShaderInfo.codeSize=sizeof(compositor_raster_fused_spv); fusedShaderInfo.pCode=compositor_raster_fused_spv;
        check(vkCreateShaderModule(device,&fusedShaderInfo,nullptr,&fusedShader));
        VkComputePipelineCreateInfo fusedCompute{VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};
        fusedCompute.stage.sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        fusedCompute.stage.stage=VK_SHADER_STAGE_COMPUTE_BIT; fusedCompute.stage.module=fusedShader; fusedCompute.stage.pName="main";
        fusedCompute.layout=fusedPipelineLayout;
        check(vkCreateComputePipelines(device,VK_NULL_HANDLE,1,&fusedCompute,nullptr,&fusedPipeline));
        VkDescriptorPoolSize fusedPoolSize{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,3};
        VkDescriptorPoolCreateInfo fusedPoolInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};
        fusedPoolInfo.maxSets=1; fusedPoolInfo.poolSizeCount=1; fusedPoolInfo.pPoolSizes=&fusedPoolSize;
        check(vkCreateDescriptorPool(device,&fusedPoolInfo,nullptr,&fusedPool));
        VkDescriptorSetAllocateInfo fusedAllocate{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
        fusedAllocate.descriptorPool=fusedPool; fusedAllocate.descriptorSetCount=1; fusedAllocate.pSetLayouts=&fusedLayout;
        check(vkAllocateDescriptorSets(device,&fusedAllocate,&fusedSet));
    }
    void render(uint32_t width,uint32_t height,uint32_t operation,uint32_t channel,
                const float *source,const float *background,const float *mask,const float *parameters,float *output,
                uint32_t uploadMask) {
        const size_t bytes=size_t(width)*height*16;
        const size_t sourceBytes=operation==10?size_t(parameters[16])*size_t(parameters[17])*16:bytes;
        const std::array<VkDeviceSize,5> sizes{sourceBytes,bytes,mask?bytes:16,background?bytes:16,80};
        for (uint32_t i=0;i<5;++i) {
            if (sizes[i]>properties.limits.maxStorageBufferRange) throw std::runtime_error("Raster buffer too large");
            if (buffers[i] && buffers[i]->capacity>=sizes[i]) continue;
            auto next=std::make_unique<Buffer>(); next->create(device,physical,sizes[i],i==1);
            buffers[i]=std::move(next);
            if (i==0) inputBytes[0]=0;
            if (i==3) inputBytes[1]=0;
            if (i==2) inputBytes[2]=0;
        }
        VkDescriptorBufferInfo info[5]{}; VkWriteDescriptorSet writes[5]{};
        for (uint32_t i=0;i<5;++i) {
            info[i]={buffers[i]->buffer,0,buffers[i]->capacity};
            writes[i].sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET; writes[i].dstSet=descriptorSet;
            writes[i].dstBinding=i; writes[i].descriptorCount=1;
            writes[i].descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER; writes[i].pBufferInfo=&info[i];
        }
        vkUpdateDescriptorSets(device,5,writes,0,nullptr);
        const float *inputs[3]{source,background,mask};
        const uint32_t bindings[3]{0,3,2};
        for (uint32_t i=0;i<3;++i) {
            if (!inputs[i]) { inputBytes[i]=0; continue; }
            const size_t count=i==0?sourceBytes:bytes;
            if (!(uploadMask&(1u<<i)) && inputBytes[i]==count) continue;
            auto &buffer=buffers[bindings[i]];
            std::memcpy(buffer->mapped,inputs[i],count);
            buffer->flush();
            inputBytes[i]=count;
            uploadBytes+=count;
        }
        if (parameters) {
            std::memcpy(buffers[4]->mapped,parameters,(operation==3 || operation==10)?80:operation==9?48:operation==7?16:32);
            buffers[4]->flush();
        }
        const uint32_t u[4]{width,height,operation,channel};
        dispatch(width,height,pipeline,u,sizeof(u));
        buffers[1]->invalidate();
        std::memcpy(output,buffers[1]->mapped,bytes);
        readbackBytes+=bytes;
        ++submissions;
        ++generation;
    }
    void graph(uint32_t width,uint32_t height,const float *const *inputs,uint32_t inputCount,
               const CompositorVulkanRasterStep *steps,uint32_t stepCount,const uint8_t *uploads,
               bool forceUploads,float *output) {
        const size_t bytes=size_t(width)*height*16;
        if (bytes>properties.limits.maxStorageBufferRange) throw std::runtime_error("Raster buffer too large");
        // A node's result stays alive until its final consumer has been recorded.
        std::vector<uint32_t> lastUse(inputCount+stepCount,0),slots(stepCount),available;
        for (uint32_t i=0;i<stepCount;++i) lastUse[inputCount+i]=i;
        for (uint32_t i=0;i<stepCount;++i) {
            const auto &s=steps[i]; lastUse[s.source]=i;
            if (s.operation<=2) lastUse[s.background]=i;
            if (s.operation==2) lastUse[s.mask]=i;
        }
        uint32_t slotCount=0;
        for (uint32_t i=0;i<stepCount;++i) {
            for (uint32_t j=0;j<i;++j) if (lastUse[inputCount+j]+1==i) available.push_back(slots[j]);
            if (available.empty()) slots[i]=slotCount++;
            else { slots[i]=available.back(); available.pop_back(); }
        }
        if (slotCount<=fusedRegisters && uint64_t(bytes)*inputCount<=properties.limits.maxStorageBufferRange
            && bytes*(inputCount+1)<=512ull*1024*1024) {
            fused(width,height,inputs,inputCount,steps,stepCount,slots,uploads,forceUploads || lastGraphPath!=1,output);
            lastGraphPath=1;
            return;
        }
        if (lastGraphPath!=0) forceUploads=true;
        lastGraphPath=0;
        // Bound retained graph allocations; larger graphs fall back without host input reads.
        if (bytes*(inputCount+slotCount)>512ull*1024*1024) throw TooLarge("Raster graph too large");
        graphInputs.resize(inputCount); graphInputBytes.resize(inputCount);
        graphOutputs.resize(slotCount); graphParameters.resize(stepCount);
        auto ensure=[&](std::unique_ptr<Buffer> &buffer,size_t size,bool readback) {
            if (buffer && buffer->capacity>=size) return false;
            auto next=std::make_unique<Buffer>(); next->create(device,physical,size,readback);
            buffer=std::move(next); return true;
        };
        for (uint32_t i=0;i<inputCount;++i) {
            if (ensure(graphInputs[i],bytes,false)) graphInputBytes[i]=0;
            if (!forceUploads && uploads && !uploads[i] && graphInputBytes[i]==bytes) continue;
            std::memcpy(graphInputs[i]->mapped,inputs[i],bytes); graphInputs[i]->flush();
            graphInputBytes[i]=bytes; uploadBytes+=bytes;
        }
        for (auto &buffer:graphOutputs) ensure(buffer,bytes,true);
        for (uint32_t i=0;i<stepCount;++i) {
            ensure(graphParameters[i],80,false);
            std::memcpy(graphParameters[i]->mapped,steps[i].parameters,80); graphParameters[i]->flush();
        }
        if (graphPoolCapacity<stepCount) {
            if (graphPool) vkDestroyDescriptorPool(device,graphPool,nullptr);
            graphPool=VK_NULL_HANDLE; graphPoolCapacity=0;
            VkDescriptorPoolSize size{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,stepCount*5};
            VkDescriptorPoolCreateInfo info{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};
            info.maxSets=stepCount; info.poolSizeCount=1; info.pPoolSizes=&size;
            check(vkCreateDescriptorPool(device,&info,nullptr,&graphPool)); graphPoolCapacity=stepCount;
        } else check(vkResetDescriptorPool(device,graphPool,0));
        std::vector<VkDescriptorSetLayout> layouts(stepCount,descriptorLayout);
        std::vector<VkDescriptorSet> sets(stepCount);
        VkDescriptorSetAllocateInfo allocate{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
        allocate.descriptorPool=graphPool; allocate.descriptorSetCount=stepCount; allocate.pSetLayouts=layouts.data();
        check(vkAllocateDescriptorSets(device,&allocate,sets.data()));
        auto node=[&](uint32_t index)->Buffer* {
            return index<inputCount?graphInputs[index].get():graphOutputs[slots[index-inputCount]].get();
        };
        for (uint32_t i=0;i<stepCount;++i) {
            const auto &s=steps[i];
            Buffer *bound[5]{node(s.source),graphOutputs[slots[i]].get(),
                node(s.operation==2?s.mask:s.source),node(s.operation<=2?s.background:s.source),graphParameters[i].get()};
            VkDescriptorBufferInfo info[5]{}; VkWriteDescriptorSet writes[5]{};
            for (uint32_t j=0;j<5;++j) {
                info[j]={bound[j]->buffer,0,bound[j]->capacity};
                writes[j].sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET; writes[j].dstSet=sets[i];
                writes[j].dstBinding=j; writes[j].descriptorCount=1;
                writes[j].descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER; writes[j].pBufferInfo=&info[j];
            }
            vkUpdateDescriptorSets(device,5,writes,0,nullptr);
        }
        check(vkResetFences(device,1,&fence)); check(vkResetCommandBuffer(command,0));
        VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO}; begin.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        check(vkBeginCommandBuffer(command,&begin));
        VkMemoryBarrier barrier{VK_STRUCTURE_TYPE_MEMORY_BARRIER}; barrier.srcAccessMask=VK_ACCESS_HOST_WRITE_BIT;
        barrier.dstAccessMask=VK_ACCESS_SHADER_READ_BIT|VK_ACCESS_SHADER_WRITE_BIT;
        vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_HOST_BIT,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,0,1,&barrier,0,nullptr,0,nullptr);
        vkCmdBindPipeline(command,VK_PIPELINE_BIND_POINT_COMPUTE,pipeline);
        for (uint32_t i=0;i<stepCount;++i) {
            if (i) {
                barrier.srcAccessMask=VK_ACCESS_SHADER_READ_BIT|VK_ACCESS_SHADER_WRITE_BIT;
                barrier.dstAccessMask=VK_ACCESS_SHADER_READ_BIT|VK_ACCESS_SHADER_WRITE_BIT;
                vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,0,1,&barrier,0,nullptr,0,nullptr);
            }
            const uint32_t u[4]{width,height,steps[i].operation,steps[i].channel};
            vkCmdBindDescriptorSets(command,VK_PIPELINE_BIND_POINT_COMPUTE,pipelineLayout,0,1,&sets[i],0,nullptr);
            vkCmdPushConstants(command,pipelineLayout,VK_SHADER_STAGE_COMPUTE_BIT,0,sizeof(u),u);
            vkCmdDispatch(command,(width+15)/16,(height+15)/16,1);
        }
        barrier.srcAccessMask=VK_ACCESS_SHADER_WRITE_BIT; barrier.dstAccessMask=VK_ACCESS_HOST_READ_BIT;
        vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,1,&barrier,0,nullptr,0,nullptr);
        check(vkEndCommandBuffer(command));
        VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO}; submit.commandBufferCount=1; submit.pCommandBuffers=&command;
        check(vkQueueSubmit(queue,1,&submit,fence)); check(vkWaitForFences(device,1,&fence,VK_TRUE,UINT64_MAX));
        auto &result=graphOutputs[slots.back()]; result->invalidate();
        std::memcpy(output,result->mapped,bytes); readbackBytes+=bytes;
        ++submissions; ++generation;
    }
    void fused(uint32_t width,uint32_t height,const float *const *inputs,uint32_t inputCount,
               const CompositorVulkanRasterStep *steps,uint32_t stepCount,const std::vector<uint32_t> &slots,
               const uint8_t *uploads,bool forceUploads,float *output) {
        const size_t bytes=size_t(width)*height*16;
        auto ensure=[&](std::unique_ptr<Buffer> &buffer,size_t size,bool readback) {
            if (buffer && buffer->capacity>=size) return false;
            auto next=std::make_unique<Buffer>(); next->create(device,physical,size,readback);
            buffer=std::move(next); return true;
        };
        if (ensure(fusedInputs,bytes*inputCount,false)) fusedInputBytes.assign(inputCount,0);
        fusedInputBytes.resize(inputCount,0);
        bool uploaded=false;
        for (uint32_t i=0;i<inputCount;++i) {
            if (!forceUploads && uploads && !uploads[i] && fusedInputBytes[i]==bytes) continue;
            std::memcpy(static_cast<char *>(fusedInputs->mapped)+bytes*i,inputs[i],bytes);
            fusedInputBytes[i]=bytes; uploadBytes+=bytes; uploaded=true;
        }
        if (uploaded) fusedInputs->flush();
        ensure(fusedOutput,bytes,true);
        ensure(fusedSteps,sizeof(FusedStep)*stepCount,false);
        auto *packed=static_cast<FusedStep *>(fusedSteps->mapped);
        for (uint32_t i=0;i<stepCount;++i) {
            FusedStep step{};
            step.header[0]=steps[i].operation; step.header[1]=steps[i].channel;
            step.header[2]=steps[i].source; step.header[3]=steps[i].background;
            step.slots[0]=steps[i].mask; step.slots[1]=slots[i];
            std::memcpy(step.values,steps[i].parameters,sizeof(step.values));
            packed[i]=step;
        }
        fusedSteps->flush();
        Buffer *bound[3]{fusedInputs.get(),fusedOutput.get(),fusedSteps.get()};
        VkDescriptorBufferInfo info[3]{}; VkWriteDescriptorSet writes[3]{};
        for (uint32_t j=0;j<3;++j) {
            info[j]={bound[j]->buffer,0,bound[j]->capacity};
            writes[j].sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET; writes[j].dstSet=fusedSet;
            writes[j].dstBinding=j; writes[j].descriptorCount=1;
            writes[j].descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER; writes[j].pBufferInfo=&info[j];
        }
        vkUpdateDescriptorSets(device,3,writes,0,nullptr);
        check(vkResetFences(device,1,&fence)); check(vkResetCommandBuffer(command,0));
        VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO}; begin.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        check(vkBeginCommandBuffer(command,&begin));
        VkMemoryBarrier barrier{VK_STRUCTURE_TYPE_MEMORY_BARRIER}; barrier.srcAccessMask=VK_ACCESS_HOST_WRITE_BIT;
        barrier.dstAccessMask=VK_ACCESS_SHADER_READ_BIT|VK_ACCESS_SHADER_WRITE_BIT;
        vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_HOST_BIT,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,0,1,&barrier,0,nullptr,0,nullptr);
        vkCmdBindPipeline(command,VK_PIPELINE_BIND_POINT_COMPUTE,fusedPipeline);
        vkCmdBindDescriptorSets(command,VK_PIPELINE_BIND_POINT_COMPUTE,fusedPipelineLayout,0,1,&fusedSet,0,nullptr);
        const uint32_t u[4]{width,height,inputCount,stepCount};
        vkCmdPushConstants(command,fusedPipelineLayout,VK_SHADER_STAGE_COMPUTE_BIT,0,sizeof(u),u);
        vkCmdDispatch(command,(width+15)/16,(height+15)/16,1);
        barrier.srcAccessMask=VK_ACCESS_SHADER_WRITE_BIT; barrier.dstAccessMask=VK_ACCESS_HOST_READ_BIT;
        vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,1,&barrier,0,nullptr,0,nullptr);
        check(vkEndCommandBuffer(command));
        VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO}; submit.commandBufferCount=1; submit.pCommandBuffers=&command;
        check(vkQueueSubmit(queue,1,&submit,fence)); check(vkWaitForFences(device,1,&fence,VK_TRUE,UINT64_MAX));
        fusedOutput->invalidate();
        std::memcpy(output,fusedOutput->mapped,bytes); readbackBytes+=bytes;
        ++submissions; ++fusedSubmissions; ++generation;
    }
    void dispatch(uint32_t width,uint32_t height,VkPipeline selected,const void *parameters,uint32_t bytes) {
        check(vkResetFences(device,1,&fence)); check(vkResetCommandBuffer(command,0));
        VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO}; begin.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        check(vkBeginCommandBuffer(command,&begin));
        VkMemoryBarrier upload{VK_STRUCTURE_TYPE_MEMORY_BARRIER}; upload.srcAccessMask=VK_ACCESS_HOST_WRITE_BIT|VK_ACCESS_SHADER_WRITE_BIT;
        upload.dstAccessMask=VK_ACCESS_SHADER_READ_BIT|VK_ACCESS_SHADER_WRITE_BIT;
        vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_HOST_BIT|VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,0,1,&upload,0,nullptr,0,nullptr);
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
extern "C" CompositorVulkanRaster *compositor_vulkan_raster_create(int allowSoftware) {
    try { auto c=std::make_unique<CompositorVulkanRaster>(); c->initialize(allowSoftware!=0); return c.release(); }
    catch (...) { return nullptr; }
}
extern "C" void compositor_vulkan_raster_destroy(CompositorVulkanRaster *c) {
    if (c && c->references.fetch_sub(1)==1) delete c;
}
extern "C" const char *compositor_vulkan_raster_device(CompositorVulkanRaster *c) { return c?c->properties.deviceName:"unavailable"; }
extern "C" uint32_t compositor_vulkan_raster_device_type(CompositorVulkanRaster *c) { return c?c->properties.deviceType:0; }
extern "C" int compositor_vulkan_raster_available(CompositorVulkanRaster *c) {
    if (!c) return 0;
    std::lock_guard<std::mutex> guard(c->lock);
    return c->usable?1:0;
}
extern "C" uint64_t compositor_vulkan_raster_submissions(CompositorVulkanRaster *c) {
    if (!c) return 0;
    std::lock_guard<std::mutex> guard(c->lock);
    return c->submissions;
}
extern "C" int compositor_vulkan_raster_render(CompositorVulkanRaster *c,uint32_t width,uint32_t height,
    uint32_t operation,uint32_t channel,const float *source,const float *background,
    const float *mask,const float *parameters,float *output) {
    return compositor_vulkan_raster_render_cached(c,width,height,operation,channel,source,background,
        mask,parameters,output,7,nullptr);
}
extern "C" uint64_t compositor_vulkan_raster_fused_submissions(CompositorVulkanRaster *c) {
    if (!c) return 0;
    std::lock_guard<std::mutex> guard(c->lock);
    return c->fusedSubmissions;
}
extern "C" uint64_t compositor_vulkan_raster_upload_bytes(CompositorVulkanRaster *c) {
    if (!c) return 0;
    std::lock_guard<std::mutex> guard(c->lock);
    return c->uploadBytes;
}
extern "C" uint64_t compositor_vulkan_raster_readback_bytes(CompositorVulkanRaster *c) {
    if (!c) return 0;
    std::lock_guard<std::mutex> guard(c->lock);
    return c->readbackBytes;
}
extern "C" int compositor_vulkan_raster_render_graph(CompositorVulkanRaster *c,uint32_t width,uint32_t height,
    const float *const *inputs,uint32_t inputCount,const CompositorVulkanRasterStep *steps,uint32_t stepCount,
    const uint8_t *uploads,uint64_t *generation,float *output) {
    if (!width || !height || width>65536 || height>65536 || !inputs || !inputCount || inputCount>64 ||
        !steps || !stepCount || stepCount>128 || !output) return -1;
    for (uint32_t i=0;i<inputCount;++i) if (!inputs[i]) return -1;
    for (uint32_t i=0;i<stepCount;++i) {
        const auto &s=steps[i]; const uint32_t limit=inputCount+i;
        if (s.operation<1 || s.operation>9 || s.source>=limit || (s.operation<=2 && s.background>=limit) ||
            (s.operation==2 && (s.mask>=limit || (s.channel!=0 && s.channel!=3 && s.channel!=4)))) return -1;
    }
    if (!c) return -2;
    std::lock_guard<std::mutex> guard(c->lock);
    if (!c->usable) return -2;
    if ((width+15)/16>c->properties.limits.maxComputeWorkGroupCount[0] ||
        (height+15)/16>c->properties.limits.maxComputeWorkGroupCount[1]) return -1;
    try {
        c->graph(width,height,inputs,inputCount,steps,stepCount,uploads,!generation || *generation!=c->generation,output);
        if (generation) *generation=c->generation;
        return 0;
    } catch (const TooLarge &) { return -3; }
    catch (...) { c->usable=false; return -2; }
}
extern "C" int compositor_vulkan_raster_render_cached(CompositorVulkanRaster *c,uint32_t width,uint32_t height,
    uint32_t operation,uint32_t channel,const float *source,const float *background,
    const float *mask,const float *parameters,float *output,uint32_t uploadMask,uint64_t *generation) {
    if (!width || !height || width>65536 || height>65536 || !source || !output || operation<1 || operation>10 ||
        ((operation==1 || operation==2) && !background) || (operation==2 && (!mask || (channel!=0 && channel!=3 && channel!=4))) ||
        ((operation==3 || operation==4 || operation==7 || operation==8 || operation==9 || operation==10) && !parameters)) return -1;
    if (operation==10 && (!(parameters[16]>=1 && parameters[16]<=65536) ||
                         !(parameters[17]>=1 && parameters[17]<=65536))) return -1;
    if (!c) return -2;
    std::lock_guard<std::mutex> guard(c->lock);
    if (!c->usable) return -2;
    if ((width+15)/16>c->properties.limits.maxComputeWorkGroupCount[0] ||
        (height+15)/16>c->properties.limits.maxComputeWorkGroupCount[1]) return -1;
    if (!generation || *generation!=c->generation) uploadMask=7;
    try {
        c->render(width,height,operation,channel,source,background,mask,parameters,output,uploadMask);
        if (generation) *generation=c->generation;
        return 0;
    }
    catch (const TooLarge &) { return -3; }
    catch (...) { c->usable=false; return -2; }
}

// Resident handles own immutable storage independently of the scratch buffers used by graph/render_cached.
namespace { enum class ImageStorage { Float32, Half, RGBA8 }; }
struct CompositorVulkanImage {
    CompositorVulkanRaster *owner;
    uint32_t width, height;
    ImageStorage storage;
    std::unique_ptr<Buffer> pixels;
};
namespace {
constexpr uint64_t residentLimit=512ull*1024*1024;
std::unique_ptr<Buffer> residentBuffer(CompositorVulkanRaster *c,uint64_t bytes) {
    if (bytes>c->properties.limits.maxStorageBufferRange || bytes>residentLimit-c->residentBytes)
        throw TooLarge("Resident image budget exceeded");
    auto buffer=std::make_unique<Buffer>(); buffer->create(c->device,c->physical,bytes);
    return buffer;
}
CompositorVulkanImage *retainImage(CompositorVulkanRaster *c,uint32_t width,uint32_t height,std::unique_ptr<Buffer> pixels,
                                 ImageStorage storage=ImageStorage::Float32) {
    auto image=std::make_unique<CompositorVulkanImage>();
    image->owner=c; image->width=width; image->height=height; image->storage=storage; image->pixels=std::move(pixels);
    c->residentBytes+=image->pixels->capacity;
    c->references.fetch_add(1);
    return image.release();
}
void residentBindings(CompositorVulkanRaster *c,Buffer *source,Buffer *output,Buffer *mask,Buffer *background,Buffer *parameters) {
    Buffer *bound[5]{source,output,mask,background,parameters};
    VkDescriptorBufferInfo info[5]{}; VkWriteDescriptorSet writes[5]{};
    for (uint32_t j=0;j<5;++j) {
        info[j]={bound[j]->buffer,0,bound[j]->capacity};
        writes[j].sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET; writes[j].dstSet=c->descriptorSet;
        writes[j].dstBinding=j; writes[j].descriptorCount=1;
        writes[j].descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER; writes[j].pBufferInfo=&info[j];
    }
    vkUpdateDescriptorSets(c->device,5,writes,0,nullptr);
}
bool dimensions(uint32_t width,uint32_t height) { return width && height && width<=65536 && height<=65536; }
bool copiesHalf(uint32_t operation,const float *p) {
    if (operation==7 || operation==17) return true;
    if (operation!=13) return false;
    if (p[10]!=0) return true;
    const double x=double(p[4])+p[6]-p[8], y=double(p[5])+p[7]-p[9];
    return p[0]==1 && p[1]==0 && p[2]==0 && p[3]==1 && x==std::floor(x) && y==std::floor(y);
}
CompositorVulkanImage *uploadImage(CompositorVulkanRaster *c,uint32_t width,uint32_t height,
                                  const void *pixels,ImageStorage storage) {
    if (!c || !dimensions(width,height) || !pixels) return nullptr;
    std::lock_guard<std::mutex> guard(c->lock);
    if (!c->usable) return nullptr;
    try {
        const uint64_t bytes=uint64_t(width)*height*(storage==ImageStorage::RGBA8?4:16);
        auto buffer=residentBuffer(c,bytes);
        std::memcpy(buffer->mapped,pixels,bytes); buffer->flush(); c->uploadBytes+=bytes;
        return retainImage(c,width,height,std::move(buffer),storage);
    } catch (const TooLarge &) { return nullptr; }
    catch (...) { c->usable=false; return nullptr; }
}
}
extern "C" uint64_t compositor_vulkan_raster_resident_bytes(CompositorVulkanRaster *c) {
    if (!c) return 0;
    std::lock_guard<std::mutex> guard(c->lock); return c->residentBytes;
}
extern "C" uint64_t compositor_vulkan_raster_bokeh_submissions(CompositorVulkanRaster *c) {
    if (!c) return 0;
    std::lock_guard<std::mutex> guard(c->lock); return c->bokehSubmissions;
}
extern "C" CompositorVulkanImage *compositor_vulkan_image_upload(CompositorVulkanRaster *c,
    uint32_t width,uint32_t height,const float *pixels) {
    return uploadImage(c,width,height,pixels,ImageStorage::Float32);
}
extern "C" CompositorVulkanImage *compositor_vulkan_image_upload_rgba8(CompositorVulkanRaster *c,
    uint32_t width,uint32_t height,const uint8_t *pixels) {
    return uploadImage(c,width,height,pixels,ImageStorage::RGBA8);
}
extern "C" CompositorVulkanImage *compositor_vulkan_image_apply(CompositorVulkanRaster *c,
    uint32_t width,uint32_t height,uint32_t operation,uint32_t channel,
    const CompositorVulkanImage *source,const CompositorVulkanImage *background,
    const CompositorVulkanImage *mask,const float *parameters) {
    if (!c || !dimensions(width,height) || !source || source->owner!=c ||
        (background && background->owner!=c) || (mask && mask->owner!=c) ||
        !((operation>=1 && operation<=11) || (operation>=13 && operation<=18)) ||
        (operation<=2 && !background) || (operation==2 && (!mask || (channel!=0 && channel!=3 && channel!=4))) ||
        ((operation==16 || operation==18) && !background) ||
        ((operation>=3 && operation!=5 && operation!=6) && !parameters)) return nullptr;
    if (operation!=10 && operation!=11 && operation!=13 && (source->width!=width || source->height!=height)) return nullptr;
    if ((operation<=2 && (background->width!=width || background->height!=height)) ||
        (operation==18 && (background->width!=width || background->height!=height)) ||
        (operation==2 && (mask->width!=width || mask->height!=height))) return nullptr;
    if (parameters) for (int i=0;i<20;++i) {
        // Noise/grain carry bit-pattern integer seeds and signed coordinates, which may spell float NaNs.
        if (operation!=8 && operation!=9 && !std::isfinite(parameters[i])) return nullptr;
    }
    if (operation==11 && (!(parameters[0]>=0.5f && parameters[0]<=20) || parameters[1]<0 || parameters[1]>3 ||
        parameters[1]!=std::floor(parameters[1]) || parameters[5]<=0 || parameters[6]<=0)) return nullptr;
    if (operation==16 && (background->height!=1 || background->width<2)) return nullptr;
    if (operation==10 && (parameters[9]<1 || parameters[9]>4096 || parameters[10]<1 || parameters[10]>4096 ||
        parameters[8]<0 || parameters[8]>15 || std::abs(parameters[15])!=1 || parameters[18]<0 || parameters[18]>2)) return nullptr;
    std::lock_guard<std::mutex> guard(c->lock);
    if (!c->usable || (width+15)/16>c->properties.limits.maxComputeWorkGroupCount[0] ||
        (height+15)/16>c->properties.limits.maxComputeWorkGroupCount[1]) return nullptr;
    try {
        const bool half=operation==11 || operation==14 || (operation==10 && parameters[19]!=0) ||
            (source->storage==ImageStorage::Half && copiesHalf(operation,parameters));
        const uint64_t outputBytes=uint64_t(width)*height*(half?8:16);
        const uint64_t tableBytes=operation==11 && parameters[1]!=3
            ? (uint64_t(std::ceil(parameters[0]))*2+1)*(uint64_t(std::ceil(parameters[0]*(parameters[1]==2?1.62f:1)))*2+1)*16 : 0;
        if (outputBytes+tableBytes+80>residentLimit-c->residentBytes) throw TooLarge("Resident operation budget exceeded");
        auto output=residentBuffer(c,outputBytes);
        Buffer values; values.create(c->device,c->physical,80);
        float p[20]{}; if (parameters) std::memcpy(p,parameters,80);
        if (operation==10 || operation==11 || operation==13) { p[16]=float(source->width); p[17]=float(source->height); }
        if (operation==16) p[0]=float(background->width);
        std::memcpy(values.mapped,p,80); values.flush();
        std::unique_ptr<Buffer> table;
        if (operation==11 && p[1]!=3) {
            const uint32_t columns=uint32_t(std::ceil(p[0]))*2+1;
            const uint32_t rows=uint32_t(std::ceil(p[0]*(p[1]==2?1.62f:1)))*2+1;
            table=residentBuffer(c,uint64_t(columns)*rows*16);
            residentBindings(c,source->pixels.get(),table.get(),source->pixels.get(),source->pixels.get(),&values);
            const uint32_t u[4]{columns*rows,1,12,0};
            c->dispatch(u[0],1,c->pipeline,u,sizeof(u)); ++c->submissions;
        }
        residentBindings(c,source->pixels.get(),output.get(),table?table.get():mask?mask->pixels.get():source->pixels.get(),
                         background?background->pixels.get():source->pixels.get(),&values);
        // Format bits are private to this dispatch. Public operation values remain unchanged.
        const uint32_t formats=(source->storage==ImageStorage::Half?256u:0u)|(half?512u:0u)|
            (operation==2 && mask && mask->storage==ImageStorage::Half?1024u:0u)|
            (background && background->storage==ImageStorage::Half?2048u:0u)|
            (source->storage==ImageStorage::RGBA8?4096u:0u)|
            (operation==2 && mask && mask->storage==ImageStorage::RGBA8?8192u:0u)|
            (background && background->storage==ImageStorage::RGBA8?16384u:0u);
        const uint32_t u[4]{width,height,operation|formats,channel};
        c->dispatch(width,height,c->pipeline,u,sizeof(u)); ++c->submissions; ++c->generation;
        if (operation==11) ++c->bokehSubmissions;
        return retainImage(c,width,height,std::move(output),half?ImageStorage::Half:ImageStorage::Float32);
    } catch (const TooLarge &) { return nullptr; }
    catch (...) { c->usable=false; return nullptr; }
}
extern "C" int compositor_vulkan_image_read(const CompositorVulkanImage *image,float *output) {
    if (!image || !output) return -1;
    auto c=image->owner; std::lock_guard<std::mutex> guard(c->lock);
    if (!c->usable) return -2;
    try {
        image->pixels->invalidate();
        const size_t bytes=image->pixels->capacity;
        if (image->storage==ImageStorage::Half) {
            const auto *pixels=static_cast<const uint16_t *>(image->pixels->mapped);
            for (size_t i=0;i<size_t(image->width)*image->height*4;++i) {
                _Float16 value; std::memcpy(&value,pixels+i,sizeof(value)); output[i]=float(value);
            }
        } else if (image->storage==ImageStorage::RGBA8) {
            const auto *pixels=static_cast<const uint8_t *>(image->pixels->mapped);
            for (size_t i=0;i<size_t(image->width)*image->height*4;++i) output[i]=float(pixels[i])/255.0f;
        } else { std::memcpy(output,image->pixels->mapped,bytes); }
        c->readbackBytes+=bytes;
        return 0;
    } catch (...) { c->usable=false; return -2; }
}
extern "C" void compositor_vulkan_image_destroy(CompositorVulkanImage *image) {
    if (!image) return;
    auto c=image->owner;
    {
        std::lock_guard<std::mutex> guard(c->lock);
        c->residentBytes-=image->pixels->capacity;
        delete image;
    }
    compositor_vulkan_raster_destroy(c);
}
