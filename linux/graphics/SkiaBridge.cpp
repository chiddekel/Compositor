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
#include "include/core/SkPath.h"
#include "include/core/SkPathBuilder.h"
#include "include/core/SkShader.h"
#include "include/core/SkMatrix.h"
#include "include/core/SkColor.h"
#elif __has_include(<skia/core/SkCanvas.h>)
#define COMPOSITOR_HAS_SKIA 1
#include <skia/core/SkCanvas.h>
#include <skia/core/SkSurface.h>
#include <skia/core/SkImage.h>
#include <skia/core/SkPixmap.h>
#include <skia/core/SkPaint.h>
#include <skia/core/SkBlendMode.h>
#include <skia/core/SkSamplingOptions.h>
#include <skia/core/SkPath.h>
#include <skia/core/SkPathBuilder.h>
#include <skia/core/SkShader.h>
#include <skia/core/SkMatrix.h>
#include <skia/core/SkColor.h>
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

// ── Stage 4/5: Canvas C ABI (CoreGraphics-shaped Skia Bridge) ────────────

#if defined(COMPOSITOR_HAS_SKIA)
static SkBlendMode map_cg_blend_mode(int cg_mode) {
    switch (cg_mode) {
        case 0:  return SkBlendMode::kSrcOver;     // normal
        case 1:  return SkBlendMode::kMultiply;    // multiply
        case 2:  return SkBlendMode::kScreen;      // screen
        case 3:  return SkBlendMode::kOverlay;     // overlay
        case 4:  return SkBlendMode::kDarken;      // darken
        case 5:  return SkBlendMode::kLighten;     // lighten
        case 6:  return SkBlendMode::kColorDodge;  // colorDodge
        case 7:  return SkBlendMode::kColorBurn;   // colorBurn
        case 8:  return SkBlendMode::kSoftLight;   // softLight
        case 9:  return SkBlendMode::kHardLight;   // hardLight
        case 10: return SkBlendMode::kDifference;  // difference
        case 11: return SkBlendMode::kExclusion;   // exclusion
        case 12: return SkBlendMode::kHue;         // hue
        case 13: return SkBlendMode::kSaturation;  // saturation
        case 14: return SkBlendMode::kColor;       // color
        case 15: return SkBlendMode::kLuminosity;  // luminosity
        case 16: return SkBlendMode::kClear;       // clear
        case 17: return SkBlendMode::kSrc;         // copy
        case 18: return SkBlendMode::kSrcIn;       // sourceIn
        case 19: return SkBlendMode::kSrcOut;      // sourceOut
        case 20: return SkBlendMode::kSrcATop;     // sourceAtop
        case 21: return SkBlendMode::kDstOver;     // destinationOver
        case 22: return SkBlendMode::kDstIn;       // destinationIn
        case 23: return SkBlendMode::kDstOut;      // destinationOut
        case 24: return SkBlendMode::kDstATop;     // destinationAtop
        case 25: return SkBlendMode::kXor;         // xor
        case 26: return SkBlendMode::kDarken;      // plusDarker
        case 27: return SkBlendMode::kPlus;        // plusLighter
        default: return SkBlendMode::kSrcOver;
    }
}

static SkSamplingOptions map_cg_sampling(int quality) {
    switch (quality) {
        case 1:  // none / nearest
            return SkSamplingOptions(SkFilterMode::kNearest, SkMipmapMode::kNone);
        case 2:  // low
            return SkSamplingOptions(SkFilterMode::kLinear, SkMipmapMode::kNone);
        case 3:  // medium
            return SkSamplingOptions(SkFilterMode::kLinear, SkMipmapMode::kNearest);
        case 4:  // high
            return SkSamplingOptions(SkCubicResampler::CatmullRom());
        default: // default / low
            return SkSamplingOptions(SkFilterMode::kLinear, SkMipmapMode::kNone);
    }
}

struct CompCanvasState {
    float alpha = 1.0f;
    SkBlendMode blendMode = SkBlendMode::kSrcOver;
    SkSamplingOptions sampling = SkSamplingOptions(SkFilterMode::kLinear);
    bool antialias = true;
};

struct CompCanvas {
    sk_sp<SkSurface> surface;
    SkCanvas* canvas = nullptr;
    std::vector<CompCanvasState> states;
    uint8_t* pixels = nullptr;
    size_t width = 0;
    size_t height = 0;
    size_t stride = 0;

    CompCanvasState& current_state() {
        if (states.empty()) states.push_back(CompCanvasState{});
        return states.back();
    }
};

struct CompPath {
    SkPathBuilder builder;
    SkPath get_path(bool even_odd) const {
        SkPath p = builder.snapshot();
        p.setFillType(even_odd ? SkPathFillType::kEvenOdd : SkPathFillType::kWinding);
        return p;
    }
};
#else
struct CompCanvas {};
struct CompPath {};
#endif

CompCanvas *compositor_canvas_create(uint8_t *pixels, size_t width, size_t height, size_t stride) {
    if (!pixels || width == 0 || height == 0) return nullptr;
#if defined(COMPOSITOR_HAS_SKIA)
    if (stride == 0) stride = width * 4;
    SkImageInfo info = SkImageInfo::Make(static_cast<int>(width),
                                         static_cast<int>(height),
                                         kRGBA_8888_SkColorType,
                                         kPremul_SkAlphaType);
    sk_sp<SkSurface> surface = SkSurfaces::WrapPixels(info, pixels, stride);
    if (!surface) return nullptr;
    SkCanvas* canvas = surface->getCanvas();
    if (!canvas) return nullptr;

    CompCanvas* c = new (std::nothrow) CompCanvas();
    if (!c) return nullptr;
    c->surface = surface;
    c->canvas = canvas;
    c->pixels = pixels;
    c->width = width;
    c->height = height;
    c->stride = stride;
    c->states.push_back(CompCanvasState{});
    return c;
#else
    (void)stride;
    return nullptr;
#endif
}

void compositor_canvas_destroy(CompCanvas *canvas) {
    if (!canvas) return;
    delete canvas;
}

void compositor_canvas_save(CompCanvas *canvas) {
#if defined(COMPOSITOR_HAS_SKIA)
    if (!canvas || !canvas->canvas) return;
    canvas->canvas->save();
    canvas->states.push_back(canvas->current_state());
#else
    (void)canvas;
#endif
}

void compositor_canvas_restore(CompCanvas *canvas) {
#if defined(COMPOSITOR_HAS_SKIA)
    if (!canvas || !canvas->canvas) return;
    canvas->canvas->restore();
    if (canvas->states.size() > 1) {
        canvas->states.pop_back();
    }
#else
    (void)canvas;
#endif
}

void compositor_canvas_translate(CompCanvas *canvas, float dx, float dy) {
#if defined(COMPOSITOR_HAS_SKIA)
    if (!canvas || !canvas->canvas) return;
    canvas->canvas->translate(dx, dy);
#else
    (void)canvas; (void)dx; (void)dy;
#endif
}

void compositor_canvas_scale(CompCanvas *canvas, float sx, float sy) {
#if defined(COMPOSITOR_HAS_SKIA)
    if (!canvas || !canvas->canvas) return;
    canvas->canvas->scale(sx, sy);
#else
    (void)canvas; (void)sx; (void)sy;
#endif
}

void compositor_canvas_rotate(CompCanvas *canvas, float radians) {
#if defined(COMPOSITOR_HAS_SKIA)
    if (!canvas || !canvas->canvas) return;
    float degrees = radians * (180.0f / 3.14159265358979323846f);
    canvas->canvas->rotate(degrees);
#else
    (void)canvas; (void)radians;
#endif
}

void compositor_canvas_concat(CompCanvas *canvas, float a, float b, float c, float d, float tx, float ty) {
#if defined(COMPOSITOR_HAS_SKIA)
    if (!canvas || !canvas->canvas) return;
    SkMatrix m;
    m.setAll(a, c, tx, b, d, ty, 0.0f, 0.0f, 1.0f);
    canvas->canvas->concat(m);
#else
    (void)canvas; (void)a; (void)b; (void)c; (void)d; (void)tx; (void)ty;
#endif
}

void compositor_canvas_get_ctm(const CompCanvas *canvas, float *a, float *b, float *c, float *d, float *tx, float *ty) {
#if defined(COMPOSITOR_HAS_SKIA)
    if (!canvas || !canvas->canvas) {
        if (a) *a = 1; if (b) *b = 0; if (c) *c = 0; if (d) *d = 1; if (tx) *tx = 0; if (ty) *ty = 0;
        return;
    }
    SkMatrix m = canvas->canvas->getTotalMatrix();
    if (a) *a = m.getScaleX();
    if (b) *b = m.getSkewY();
    if (c) *c = m.getSkewX();
    if (d) *d = m.getScaleY();
    if (tx) *tx = m.getTranslateX();
    if (ty) *ty = m.getTranslateY();
#else
    if (a) *a = 1; if (b) *b = 0; if (c) *c = 0; if (d) *d = 1; if (tx) *tx = 0; if (ty) *ty = 0;
    (void)canvas;
#endif
}

void compositor_canvas_clip_rect(CompCanvas *canvas, float x, float y, float w, float h, int antialias) {
#if defined(COMPOSITOR_HAS_SKIA)
    if (!canvas || !canvas->canvas) return;
    canvas->canvas->clipRect(SkRect::MakeXYWH(x, y, w, h), SkClipOp::kIntersect, antialias != 0);
#else
    (void)canvas; (void)x; (void)y; (void)w; (void)h; (void)antialias;
#endif
}

void compositor_canvas_clip_rect_difference(CompCanvas *canvas, float x, float y, float w, float h) {
#if defined(COMPOSITOR_HAS_SKIA)
    if (!canvas || !canvas->canvas) return;
    canvas->canvas->clipRect(SkRect::MakeXYWH(x, y, w, h), SkClipOp::kDifference, false);
#else
    (void)canvas; (void)x; (void)y; (void)w; (void)h;
#endif
}

void compositor_canvas_clip_path(CompCanvas *canvas, const CompPath *path, int even_odd, int antialias) {
#if defined(COMPOSITOR_HAS_SKIA)
    if (!canvas || !canvas->canvas || !path) return;
    SkPath p = path->get_path(even_odd != 0);
    canvas->canvas->clipPath(p, SkClipOp::kIntersect, antialias != 0);
#else
    (void)canvas; (void)path; (void)even_odd; (void)antialias;
#endif
}

void compositor_canvas_clip_mask(CompCanvas *canvas, const uint8_t *mask_pixels, size_t mask_w, size_t mask_h, size_t mask_stride, float x, float y, float w, float h, int is_alpha_only) {
#if defined(COMPOSITOR_HAS_SKIA)
    if (!canvas || !canvas->canvas || !mask_pixels || mask_w == 0 || mask_h == 0) return;
    if (mask_stride == 0) mask_stride = is_alpha_only ? mask_w : mask_w * 4;

    SkColorType ct = is_alpha_only ? kAlpha_8_SkColorType : kRGBA_8888_SkColorType;
    SkAlphaType at = is_alpha_only ? kPremul_SkAlphaType : kPremul_SkAlphaType;
    SkImageInfo maskInfo = SkImageInfo::Make(static_cast<int>(mask_w), static_cast<int>(mask_h), ct, at);
    SkPixmap maskPixmap(maskInfo, mask_pixels, mask_stride);
    sk_sp<SkImage> maskImg = SkImages::RasterFromPixmap(maskPixmap, nullptr, nullptr);
    if (!maskImg) return;

    SkMatrix m;
    m.setRectToRect(SkRect::MakeWH(mask_w, mask_h), SkRect::MakeXYWH(x, y, w, h), SkMatrix::kFill_ScaleToFit);
    sk_sp<SkShader> shader = maskImg->makeShader(SkTileMode::kDecal, SkTileMode::kDecal, SkSamplingOptions(SkFilterMode::kLinear), m);
    if (shader) {
        canvas->canvas->clipShader(shader, SkClipOp::kIntersect);
    }
#else
    (void)canvas; (void)mask_pixels; (void)mask_w; (void)mask_h; (void)mask_stride; (void)x; (void)y; (void)w; (void)h; (void)is_alpha_only;
#endif
}

void compositor_canvas_get_clip_bounds(const CompCanvas *canvas, float *x, float *y, float *w, float *h) {
#if defined(COMPOSITOR_HAS_SKIA)
    if (!canvas || !canvas->canvas) {
        if (x) *x = 0; if (y) *y = 0; if (w) *w = 0; if (h) *h = 0;
        return;
    }
    SkIRect devBounds = canvas->canvas->getDeviceClipBounds();
    SkMatrix inv;
    SkRect localBounds;
    if (canvas->canvas->getTotalMatrix().invert(&inv)) {
        localBounds = inv.mapRect(SkRect::Make(devBounds));
    } else {
        localBounds = SkRect::Make(devBounds);
    }
    if (x) *x = localBounds.fLeft;
    if (y) *y = localBounds.fTop;
    if (w) *w = localBounds.width();
    if (h) *h = localBounds.height();
#else
    if (x) *x = 0; if (y) *y = 0; if (w) *w = 0; if (h) *h = 0;
    (void)canvas;
#endif
}

void compositor_canvas_set_alpha(CompCanvas *canvas, float alpha) {
#if defined(COMPOSITOR_HAS_SKIA)
    if (!canvas) return;
    canvas->current_state().alpha = alpha;
#else
    (void)canvas; (void)alpha;
#endif
}

void compositor_canvas_set_blend_mode(CompCanvas *canvas, int cg_blend_mode) {
#if defined(COMPOSITOR_HAS_SKIA)
    if (!canvas) return;
    canvas->current_state().blendMode = map_cg_blend_mode(cg_blend_mode);
#else
    (void)canvas; (void)cg_blend_mode;
#endif
}

void compositor_canvas_set_interpolation_quality(CompCanvas *canvas, int cg_quality) {
#if defined(COMPOSITOR_HAS_SKIA)
    if (!canvas) return;
    canvas->current_state().sampling = map_cg_sampling(cg_quality);
#else
    (void)canvas; (void)cg_quality;
#endif
}

void compositor_canvas_set_antialias(CompCanvas *canvas, int antialias) {
#if defined(COMPOSITOR_HAS_SKIA)
    if (!canvas) return;
    canvas->current_state().antialias = antialias != 0;
#else
    (void)canvas; (void)antialias;
#endif
}

void compositor_canvas_fill_rect(CompCanvas *canvas, float x, float y, float w, float h, float r, float g, float b, float a) {
#if defined(COMPOSITOR_HAS_SKIA)
    if (!canvas || !canvas->canvas) return;
    SkPaint paint;
    float finalAlpha = a * canvas->current_state().alpha;
    paint.setColor4f(SkColor4f{r, g, b, finalAlpha});
    paint.setBlendMode(canvas->current_state().blendMode);
    paint.setAntiAlias(canvas->current_state().antialias);
    canvas->canvas->drawRect(SkRect::MakeXYWH(x, y, w, h), paint);
#else
    (void)canvas; (void)x; (void)y; (void)w; (void)h; (void)r; (void)g; (void)b; (void)a;
#endif
}

void compositor_canvas_clear(CompCanvas *canvas, float x, float y, float w, float h) {
#if defined(COMPOSITOR_HAS_SKIA)
    if (!canvas || !canvas->canvas) return;
    SkPaint paint;
    paint.setBlendMode(SkBlendMode::kClear);
    canvas->canvas->drawRect(SkRect::MakeXYWH(x, y, w, h), paint);
#else
    (void)canvas; (void)x; (void)y; (void)w; (void)h;
#endif
}

void compositor_canvas_draw_image_rect(CompCanvas *canvas, const uint8_t *src_pixels, size_t src_w, size_t src_h, size_t src_stride, float dx, float dy, float dw, float dh, float opacity, int cg_blend_mode, int cg_sampling_quality) {
#if defined(COMPOSITOR_HAS_SKIA)
    if (!canvas || !canvas->canvas || !src_pixels || src_w == 0 || src_h == 0) return;
    if (src_stride == 0) src_stride = src_w * 4;

    SkImageInfo srcInfo = SkImageInfo::Make(static_cast<int>(src_w), static_cast<int>(src_h), kRGBA_8888_SkColorType, kPremul_SkAlphaType);
    SkPixmap srcPixmap(srcInfo, src_pixels, src_stride);
    sk_sp<SkImage> img = SkImages::RasterFromPixmap(srcPixmap, nullptr, nullptr);
    if (!img) return;

    SkPaint paint;
    float finalAlpha = opacity * canvas->current_state().alpha;
    paint.setAlphaf(finalAlpha);
    paint.setBlendMode(cg_blend_mode >= 0 ? map_cg_blend_mode(cg_blend_mode) : canvas->current_state().blendMode);
    paint.setAntiAlias(canvas->current_state().antialias);

    SkSamplingOptions sampling = (cg_sampling_quality >= 0) ? map_cg_sampling(cg_sampling_quality) : canvas->current_state().sampling;
    canvas->canvas->drawImageRect(img, SkRect::MakeXYWH(dx, dy, dw, dh), sampling, &paint);
#else
    (void)canvas; (void)src_pixels; (void)src_w; (void)src_h; (void)src_stride; (void)dx; (void)dy; (void)dw; (void)dh; (void)opacity; (void)cg_blend_mode; (void)cg_sampling_quality;
#endif
}

void compositor_canvas_begin_transparency_layer(CompCanvas *canvas, float opacity) {
#if defined(COMPOSITOR_HAS_SKIA)
    if (!canvas || !canvas->canvas) return;
    canvas->canvas->saveLayerAlphaf(nullptr, opacity);
    canvas->states.push_back(canvas->current_state());
#else
    (void)canvas; (void)opacity;
#endif
}

void compositor_canvas_end_transparency_layer(CompCanvas *canvas) {
#if defined(COMPOSITOR_HAS_SKIA)
    if (!canvas || !canvas->canvas) return;
    canvas->canvas->restore();
    if (canvas->states.size() > 1) {
        canvas->states.pop_back();
    }
#else
    (void)canvas;
#endif
}

/* Path Handle */
CompPath *compositor_path_create(void) {
#if defined(COMPOSITOR_HAS_SKIA)
    return new (std::nothrow) CompPath();
#else
    return nullptr;
#endif
}

void compositor_path_destroy(CompPath *path) {
    if (!path) return;
    delete path;
}

void compositor_path_move_to(CompPath *path, float x, float y) {
#if defined(COMPOSITOR_HAS_SKIA)
    if (path) path->builder.moveTo(x, y);
#else
    (void)path; (void)x; (void)y;
#endif
}

void compositor_path_line_to(CompPath *path, float x, float y) {
#if defined(COMPOSITOR_HAS_SKIA)
    if (path) path->builder.lineTo(x, y);
#else
    (void)path; (void)x; (void)y;
#endif
}

void compositor_path_add_rect(CompPath *path, float x, float y, float w, float h) {
#if defined(COMPOSITOR_HAS_SKIA)
    if (path) path->builder.addRect(SkRect::MakeXYWH(x, y, w, h));
#else
    (void)path; (void)x; (void)y; (void)w; (void)h;
#endif
}

void compositor_path_add_ellipse(CompPath *path, float cx, float cy, float rx, float ry) {
#if defined(COMPOSITOR_HAS_SKIA)
    if (path) path->builder.addOval(SkRect::MakeXYWH(cx - rx, cy - ry, rx * 2, ry * 2));
#else
    (void)path; (void)cx; (void)cy; (void)rx; (void)ry;
#endif
}

void compositor_path_close(CompPath *path) {
#if defined(COMPOSITOR_HAS_SKIA)
    if (path) path->builder.close();
#else
    (void)path;
#endif
}

void compositor_path_reset(CompPath *path) {
#if defined(COMPOSITOR_HAS_SKIA)
    if (path) path->builder.reset();
#else
    (void)path;
#endif
}