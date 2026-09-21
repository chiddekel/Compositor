// SkiaBridge.cpp — C ABI bridge between the Swift core and Skia render backends
// (plan §9, Stage 5/8). Implements CompRenderer for Raster (CPU) and Vulkan backends.
//
// The Swift core owns document pixels (PortableImage/PixelBuffer, CPU-addressable).
// The Skia backends own the SkCanvas/SkSurface and the GPU device.
// Swift calls through this C ABI to render a CPU RGBA8 buffer into a destination
// buffer of the canonical contract (premultiplied RGBA8, stride == width*4).
//
// Backend contract (plan §6):
//   RendererDeviceFactory.create() tries Vulkan, falls back to Raster.
//   Both backends implement the same render contract (LSP):
//     - compositor_render_rgba(src, dst, w, h) composites src over dst
//       at opacity 1.0, source-over, returning the result in dst.
//     - A backend that cannot initialize returns NULL; the caller uses
//       the existing pure-Swift DocumentRenderer as the ultimate fallback.
//
// Status codes: 0 success, -1 invalid argument, -2 backend lost (try Raster).

#include "SkiaBridge.h"
#include <stdlib.h>
#include <string.h>
#include <iostream>
#include <vector>

// Include Skia headers — search in Skia source include/core layout or system /app layout.
#if defined(__has_include)
#if __has_include("include/core/SkCanvas.h")
#define COMPOSITOR_HAS_SKIA 1
#include "include/core/SkCanvas.h"
#include "include/core/SkSurface.h"
#include "include/core/SkImage.h"
#include "include/core/SkPixmap.h"
#include "include/core/SkPaint.h"
#include "include/core/SkBlendMode.h"
#include "include/core/SkSamplingOptions.h"
#elif __has_include(<skia/core/SkCanvas.h>)
#define COMPOSITOR_HAS_SKIA 1
#include <skia/core/SkCanvas.h>
#include <skia/core/SkSurface.h>
#include <skia/core/SkImage.h>
#include <skia/core/SkPixmap.h>
#include <skia/core/SkPaint.h>
#include <skia/core/SkBlendMode.h>
#include <skia/core/SkSamplingOptions.h>
#endif
#if __has_include(<vulkan/vulkan.h>)
#define COMPOSITOR_HAS_VULKAN 1
#include <vulkan/vulkan.h>
#endif
#endif

// ── CompRenderer ────────────────────────────────────────────────────────

// Opaque handle owning one Skia backend context.
struct CompRenderer {
    void* ctx = nullptr;

#if defined(COMPOSITOR_HAS_VULKAN)
    VkInstance vk_instance = VK_NULL_HANDLE;
    VkPhysicalDevice vk_physical_device = VK_NULL_HANDLE;
    VkDevice vk_device = VK_NULL_HANDLE;
    VkQueue vk_queue = VK_NULL_HANDLE;
    uint32_t vk_queue_family = 0;
    VkFormat vk_format = VK_FORMAT_R8G8B8A8_UNORM;
#endif

    bool is_raster = false;
    bool is_device_lost = false;
    CompRendererKind last_executed = COMP_RENDERER_RASTER;

    CompRenderer() = default;
    ~CompRenderer() = default;
};

// ── Forward declarations ────────────────────────────────────────────────

static void raster_device_create(CompRenderer* r, int width, int height);
static void raster_device_destroy(CompRenderer* r);
static int raster_render_rgba(CompRenderer* r,
                              const uint8_t* src_rgba,
                              uint8_t* dst_rgba,
                              size_t width, size_t height);

static void vulkan_device_create(CompRenderer* r, int force_raster);
static void vulkan_device_destroy(CompRenderer* r);
static int vulkan_render_rgba(CompRenderer* r,
                              const uint8_t* src_rgba,
                              uint8_t* dst_rgba,
                              size_t width, size_t height);

// ── Availability and Kind Queries ──────────────────────────────────────

int compositor_skia_available(void) {
#if defined(COMPOSITOR_HAS_SKIA)
    return 1;
#else
    return 0;
#endif
}

CompRendererKind compositor_renderer_last_executed(const CompRenderer *renderer) {
    if (!renderer) return COMP_RENDERER_RASTER;
    return renderer->last_executed;
}

// ── compositor_renderer_create ─────────────────────────────────────────

CompRenderer *compositor_renderer_create(int force_raster, CompRendererKind *kind_out) {
    CompRenderer* r = new (std::nothrow) CompRenderer();
    if (!r) return nullptr;

    if (force_raster) {
        raster_device_create(r, 0, 0);
        if (kind_out) *kind_out = COMP_RENDERER_RASTER;
        return r;
    }

    // Try Vulkan first.
    vulkan_device_create(r, force_raster);
    if (r->vk_device != VK_NULL_HANDLE) {
        if (kind_out) *kind_out = COMP_RENDERER_VULKAN;
        return r;
    }

    // Vulkan failed — fall back to Raster.
    raster_device_create(r, 0, 0);
    if (kind_out) *kind_out = COMP_RENDERER_RASTER;
    return r;
}

// ── compositor_renderer_close ──────────────────────────────────────────

void compositor_renderer_close(CompRenderer *renderer) {
    if (!renderer) return;
    CompRenderer* r = (CompRenderer*)renderer;
    if (r->is_raster) {
        raster_device_destroy(r);
    } else {
        vulkan_device_destroy(r);
    }
    delete r;
}

// ── compositor_renderer_kind ───────────────────────────────────────────

CompRendererKind compositor_renderer_kind(const CompRenderer *renderer) {
    if (!renderer) return COMP_RENDERER_RASTER;
    const CompRenderer* r = (const CompRenderer*)renderer;
    return r->is_raster ? COMP_RENDERER_RASTER : COMP_RENDERER_VULKAN;
}

void compositor_renderer_simulate_device_lost(CompRenderer *renderer) {
    if (renderer) {
        renderer->is_device_lost = true;
    }
}

// ── compositor_renderer_activate / deactivate ──────────────────────────

void compositor_renderer_activate(CompRenderer *renderer) {
    if (!renderer) return;
    // No-op on the C side; the Swift shim (CGContextCompat) checks
    // compositor_compat_set_render_fn which the host sets once at startup.
    // Activation is a signal for the Swift side to route through Skia.
    (void)renderer;
}

void compositor_renderer_deactivate(void) {
    // Swift side will fall back to pure-Swift LayerRenderer on device loss.
    (void)0;
}

// ── compositor_render_rgba ─────────────────────────────────────────────

int compositor_render_rgba(CompRenderer *renderer,
                           const uint8_t *src_rgba,
                           uint8_t *dst_rgba,
                           size_t width, size_t height) {
    if (!renderer || !src_rgba || !dst_rgba) return -1;
    if (width == 0 || height == 0) return -1;

#if !defined(COMPOSITOR_HAS_SKIA)
    return -3;
#else
    CompRenderer* r = (CompRenderer*)renderer;
    if (r->is_raster) {
        return raster_render_rgba(r, src_rgba, dst_rgba, width, height);
    } else {
        int rc = vulkan_render_rgba(r, src_rgba, dst_rgba, width, height);
        if (rc == -2) {
            // Plan §6 runtime loss failsafe: automatic dynamic fallback to Raster CPU
            vulkan_device_destroy(r);
            raster_device_create(r, static_cast<int>(width), static_cast<int>(height));
            rc = raster_render_rgba(r, src_rgba, dst_rgba, width, height);
        }
        return rc;
    }
#endif
}

// ── compositor_skia_raster_surface ─────────────────────────────────────

int compositor_skia_raster_surface(const uint8_t *src_rgba,
                                   uint8_t *dst_rgba,
                                   size_t width, size_t height) {
    if (!src_rgba || !dst_rgba) return -1;
    if (width == 0 || height == 0) return -1;

#if !defined(COMPOSITOR_HAS_SKIA)
    return -3;
#else
    const size_t stride = width * 4;
    SkImageInfo info = SkImageInfo::Make(static_cast<int>(width),
                                         static_cast<int>(height),
                                         kRGBA_8888_SkColorType,
                                         kPremul_SkAlphaType);

    SkPixmap srcPixmap(info, src_rgba, stride);
    sk_sp<SkImage> srcImage = SkImages::RasterFromPixmap(srcPixmap, nullptr, nullptr);
    if (!srcImage) return -1;

    sk_sp<SkSurface> surface = SkSurfaces::WrapPixels(info, dst_rgba, stride);
    if (!surface) return -1;

    SkCanvas* canvas = surface->getCanvas();
    if (!canvas) return -1;

    SkPaint paint;
    paint.setBlendMode(SkBlendMode::kSrcOver);
    canvas->drawImage(srcImage, 0, 0, SkSamplingOptions(), &paint);
    return 0;
#endif
}

// ── compositor_vulkan_enumerate_devices ────────────────────────────────

int compositor_vulkan_enumerate_devices(void) {
#if defined(COMPOSITOR_HAS_VULKAN)
    VkApplicationInfo appInfo{};
    appInfo.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    appInfo.pApplicationName = "Compositor";
    appInfo.applicationVersion = VK_MAKE_VERSION(1, 0, 0);
    appInfo.apiVersion = VK_API_VERSION_1_0;

    VkInstanceCreateInfo createInfo{};
    createInfo.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    createInfo.pApplicationInfo = &appInfo;

    VkInstance instance = VK_NULL_HANDLE;
    VkResult res = vkCreateInstance(&createInfo, nullptr, &instance);
    if (res != VK_SUCCESS || instance == VK_NULL_HANDLE) {
        return -1;
    }

    uint32_t device_count = 0;
    res = vkEnumeratePhysicalDevices(instance, &device_count, nullptr);
    vkDestroyInstance(instance, nullptr);

    if (res == VK_SUCCESS) {
        return (int)device_count;
    }
    return -1;
#else
    return -1;
#endif
}

// ── Internal: raster device ────────────────────────────────────────────

static void raster_device_create(CompRenderer* r, int width, int height) {
    (void)width; (void)height;
    r->is_raster = true;
    r->last_executed = COMP_RENDERER_RASTER;
}

static void raster_device_destroy(CompRenderer* r) {
    r->is_raster = false;
}

static int raster_render_rgba(CompRenderer* r,
                              const uint8_t* src_rgba,
                              uint8_t* dst_rgba,
                              size_t width, size_t height) {
    if (!r || !r->is_raster) return -1;
    if (!src_rgba || !dst_rgba) return -1;
    if (width == 0 || height == 0) return -1;

#if defined(COMPOSITOR_HAS_SKIA)
    r->last_executed = COMP_RENDERER_RASTER;
    const size_t stride = width * 4;
    SkImageInfo info = SkImageInfo::Make(static_cast<int>(width),
                                         static_cast<int>(height),
                                         kRGBA_8888_SkColorType,
                                         kPremul_SkAlphaType);

    SkPixmap srcPixmap(info, src_rgba, stride);
    sk_sp<SkImage> srcImage = SkImages::RasterFromPixmap(srcPixmap, nullptr, nullptr);
    if (!srcImage) return -1;

    sk_sp<SkSurface> surface = SkSurfaces::WrapPixels(info, dst_rgba, stride);
    if (!surface) return -1;

    SkCanvas* canvas = surface->getCanvas();
    if (!canvas) return -1;

    SkPaint paint;
    paint.setBlendMode(SkBlendMode::kSrcOver);
    canvas->drawImage(srcImage, 0, 0, SkSamplingOptions(), &paint);
    return 0;
#else
    return -3;
#endif
}

// ── Internal: Vulkan device ────────────────────────────────────────────

static void vulkan_device_create(CompRenderer* r, int force_raster) {
    if (force_raster) {
        r->is_raster = true;
        r->last_executed = COMP_RENDERER_RASTER;
        return;
    }
#if defined(COMPOSITOR_HAS_VULKAN)
    r->is_raster = false;
    r->is_device_lost = false;
    r->last_executed = COMP_RENDERER_VULKAN;

    VkApplicationInfo appInfo{};
    appInfo.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    appInfo.pApplicationName = "Compositor";
    appInfo.applicationVersion = VK_MAKE_VERSION(1, 0, 0);
    appInfo.apiVersion = VK_API_VERSION_1_0;

    VkInstanceCreateInfo createInfo{};
    createInfo.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    createInfo.pApplicationInfo = &appInfo;

    VkInstance instance = VK_NULL_HANDLE;
    VkResult res = vkCreateInstance(&createInfo, nullptr, &instance);
    if (res != VK_SUCCESS || instance == VK_NULL_HANDLE) {
        r->vk_device = VK_NULL_HANDLE;
        r->is_raster = true;
        r->last_executed = COMP_RENDERER_RASTER;
        return;
    }

    uint32_t device_count = 0;
    res = vkEnumeratePhysicalDevices(instance, &device_count, nullptr);
    if (res != VK_SUCCESS || device_count == 0) {
        vkDestroyInstance(instance, nullptr);
        r->vk_device = VK_NULL_HANDLE;
        r->is_raster = true;
        r->last_executed = COMP_RENDERER_RASTER;
        return;
    }

    std::vector<VkPhysicalDevice> devices(device_count);
    vkEnumeratePhysicalDevices(instance, &device_count, devices.data());

    VkPhysicalDevice chosenDevice = VK_NULL_HANDLE;
    uint32_t chosenQueueFamily = 0;
    bool foundQueue = false;

    for (const auto& dev : devices) {
        uint32_t qfCount = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(dev, &qfCount, nullptr);
        std::vector<VkQueueFamilyProperties> qfProps(qfCount);
        vkGetPhysicalDeviceQueueFamilyProperties(dev, &qfCount, qfProps.data());

        for (uint32_t i = 0; i < qfCount; ++i) {
            if (qfProps[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) {
                chosenDevice = dev;
                chosenQueueFamily = i;
                foundQueue = true;
                break;
            }
        }
        if (foundQueue) break;
    }

    if (!foundQueue) {
        vkDestroyInstance(instance, nullptr);
        r->vk_device = VK_NULL_HANDLE;
        r->is_raster = true;
        r->last_executed = COMP_RENDERER_RASTER;
        return;
    }

    float priority = 1.0f;
    VkDeviceQueueCreateInfo qci{};
    qci.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    qci.queueFamilyIndex = chosenQueueFamily;
    qci.queueCount = 1;
    qci.pQueuePriorities = &priority;

    VkDeviceCreateInfo dci{};
    dci.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &qci;

    VkDevice device = VK_NULL_HANDLE;
    res = vkCreateDevice(chosenDevice, &dci, nullptr, &device);
    if (res != VK_SUCCESS || device == VK_NULL_HANDLE) {
        vkDestroyInstance(instance, nullptr);
        r->vk_device = VK_NULL_HANDLE;
        r->is_raster = true;
        r->last_executed = COMP_RENDERER_RASTER;
        return;
    }

    r->vk_instance = instance;
    r->vk_physical_device = chosenDevice;
    r->vk_device = device;
    r->vk_queue_family = chosenQueueFamily;
    vkGetDeviceQueue(device, chosenQueueFamily, 0, &r->vk_queue);
    r->is_raster = false;
    r->last_executed = COMP_RENDERER_VULKAN;
#else
    r->is_raster = true;
    r->last_executed = COMP_RENDERER_RASTER;
    (void)r; (void)force_raster;
#endif
}

static void vulkan_device_destroy(CompRenderer* r) {
#if defined(COMPOSITOR_HAS_VULKAN)
    if (r->vk_device != VK_NULL_HANDLE) {
        vkDestroyDevice(r->vk_device, nullptr);
        r->vk_device = VK_NULL_HANDLE;
    }
    if (r->vk_instance != VK_NULL_HANDLE) {
        vkDestroyInstance(r->vk_instance, nullptr);
        r->vk_instance = VK_NULL_HANDLE;
    }
    r->vk_queue = VK_NULL_HANDLE;
    r->vk_physical_device = VK_NULL_HANDLE;
#else
    (void)r;
#endif
}

static int vulkan_render_rgba(CompRenderer* r,
                              const uint8_t* src_rgba,
                              uint8_t* dst_rgba,
                              size_t width, size_t height) {
    (void)r; (void)src_rgba; (void)dst_rgba; (void)width; (void)height;
    // Stage 8 will implement Vulkan rendering via Skia GrDirectContext.
    // Until then, return -2 to trigger dynamic fallback to Raster.
    return -2;
}