/*
 * SkiaBridge.h — C ABI seam between the Swift core and the Skia render
 * backends (plan §9, Stage 5/8). The Swift core owns document pixels
 * (PortableImage/PixelBuffer, CPU-addressable); the Skia backends own
 * the SkCanvas/SkSurface and the GPU device. Swift calls through this
 * header to render a CPU RGBA8 buffer into a destination buffer of the
 * same canonical contract (premultiplied RGBA8, stride == width*4).
 *
 * Backend contract (plan §6):
 *   RendererDeviceFactory.create() tries Vulkan, falls back to Raster.
 *   Both backends implement the same render contract (LSP):
 *     - compositor_render_rgba(src, dst, w, h) composites src over dst
 *       at opacity 1.0, source-over, returning the result in dst.
 *     - A backend that cannot initialize returns NULL; the caller uses
 *       the existing pure-Swift DocumentRenderer as the ultimate fallback.
 *
 * Status codes: 0 success, -1 invalid argument, -2 backend lost (try Raster).
 *
 * This header is the only Skia-facing C surface. Swift never imports Skia
 * or Qt headers; C++ never imports Swift types. The boundary is POD + C.
 */
#ifndef SKIABRIDGE_H
#define SKIABRIDGE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque render device handle. One handle owns one Skia backend context
 * (GrDirectContext for Vulkan, or a CPU raster context). Thread-unsafe;
 * the caller serializes. Close releases all GPU resources. */
typedef struct CompRenderer CompRenderer;

/* Backend kind, queried for diagnostics and failsafe decisions. */
typedef enum {
    COMP_RENDERER_RASTER = 0,
    COMP_RENDERER_VULKAN = 1,
} CompRendererKind;

/*
 * Create a render device. Try Vulkan first (plan §6 startup). On any
 * failure (no device, no queue family, bad ICD, device lost, no /dev/dri),
 * fall back to Raster. kind_out receives the chosen backend. Returns NULL
 * only if both backends fail to initialize (extremely rare; the Swift
 * DocumentRenderer remains the ultimate fallback in that case).
 *
 * force_raster: if nonzero, skip Vulkan and create a Raster device. Used
 * by tests and the forced-CPU mode (plan §6 DoD).
 */
CompRenderer *compositor_renderer_create(int force_raster, CompRendererKind *kind_out);
void compositor_renderer_close(CompRenderer *renderer);
CompRendererKind compositor_renderer_kind(const CompRenderer *renderer);

/*
 * Activate `renderer` as the Swift CoreGraphicsCompat backend. After this
 * call, CGCompat draws route through Skia until the renderer is closed or
 * a device-lost forces a fallback (plan §6 runtime loss). Paired with
 * compositor_renderer_deactivate. */
void compositor_renderer_activate(CompRenderer *renderer);
void compositor_renderer_deactivate(void);

/*
 * Composite a source RGBA8 tile over a destination RGBA8 tile in place,
 * premultiplied source-over, opacity 1.0, via the backend's SkCanvas.
 * Both buffers are canonical contract (stride == width*4, premultiplied).
 *
 * This is the Stage 5 headless raster surface smoke (plan §8.10 DoD):
 * prove Skia can ingest and emit the canonical buffer format. The full
 * LayerRenderer draw pipeline (transforms, masks, blend modes) stays in
 * Swift for now; this call validates the Skia bridge end-to-end.
 *
 * Returns 0 on success, -1 invalid argument, -2 device lost (caller should
 * close, recreate as Raster, and retry — plan §6 runtime loss).
 */
int compositor_render_rgba(CompRenderer *renderer,
                           const uint8_t *src_rgba,
                           uint8_t *dst_rgba,
                           size_t width, size_t height);

/*
 * Create a raster surface of the given size and fill it with the src pixels,
 * returning the result in dst. Equivalent to compositor_render_rgba for the
 * Raster backend; for Vulkan it exercises the GPU upload + readback path.
 * Used by the Stage 0 DoD smoke test (plan §8.10): create a Skia Raster
 * surface, write into it, read back, verify.
 */
int compositor_skia_raster_surface(const uint8_t *src_rgba,
                                   uint8_t *dst_rgba,
                                   size_t width, size_t height);

/*
 * Enumerate Vulkan physical devices. Returns the count, or -1 if the Vulkan
 * loader is unavailable (no ICD). Does not create a device. Used by the
 * Stage 0 DoD smoke (plan §8.10): "find the Vulkan loader and try to
 * enumerate devices." Also returns -1 if the Skia build has no Vulkan.
 */
int compositor_vulkan_enumerate_devices(void);

/*
 * Register a render function with the Swift CoreGraphicsCompat shim. The
 * Swift CGContextCompat draws route through this function when set; when
 * NULL (or on non-zero return), draws fall back to the pure-Swift
 * LayerRenderer (plan §6 failsafe). The host calls this once at startup
 * after creating a CompRenderer.
 *
 * fn signature matches compositor_render_rgba minus the renderer handle:
 *   fn(src, dst, width, height) -> int32_t
 * The C++ side wraps a CompRenderer* into this signature via a static
 * trampoline (one active renderer at a time; the factory replaces it on
 * device loss).
 */
typedef int32_t (*CompRenderFn)(const uint8_t *src, uint8_t *dst,
                                size_t width, size_t height);
void compositor_compat_set_render_fn(CompRenderFn fn);

#ifdef __cplusplus
}
#endif

#endif /* SKIABRIDGE_H */