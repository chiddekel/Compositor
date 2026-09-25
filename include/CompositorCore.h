#ifndef CompositorCore_h
#define CompositorCore_h

/*
 * Compositor C ABI — versioned seam between the retained Swift core and the
 * Qt/C++ host (see docs/linux-port-plan.md, ENG-1).
 *
 * Canonical buffer contract:
 *   - 8-bit premultiplied RGBA, sRGB, in byte order R,G,B,A.
 *   - Explicit `stride` (bytes per row); rows are `stride` bytes apart, not
 *     necessarily `width*4`. Every C-kernel entry asserts stride >= width*4
 *     and that buffers are premultiplied (ENG-17).
 *   - Separate 8-bit grayscale coverage, one byte per pixel, row stride = width.
 *   - Committed tiles are immutable; callers must not mutate a tile in flight.
 *
 * ABI versioning: `@_cdecl` is an unofficial, Swift-version-sensitive attribute.
 * The Swift toolchain version is pinned in the versioned-ABI contract
 * (Package.swift swiftLanguageMode + the Freedesktop Swift runtime extension).
 * Bumping the toolchain is an ABI-affecting change.
 *
 * Status codes:
 *   0  success
 *  -1  invalid argument (bad geometry, NULL required buffer, out-of-range size)
 */

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Stateful editor ABI v1. One handle owns one document, transient edits, and
 * history. Calls are serialized per handle. Close invalidates the ID; IDs are
 * never reused. No Swift/Qt callbacks occur while a session lock is held.
 *
 * Commands are bounded UTF-8 JSON: {"version":1,"action":"new","width":64,
 * "height":64}. See docs/abi.md for commands and ownership. Input is copied.
 * Status: 0 success, -1 invalid input, -2 no document, -3 busy,
 * -4 unsupported version, -5 operation failed, -6 invalid/closed handle.
 *
 * state/render return required byte count or a negative status. A NULL or short
 * output buffer is not written. Query size, allocate, then call again with the
 * capacity. JSON is NOT NUL-terminated. Render returns tightly packed RGBA8
 * premultiplied sRGB, with dimensions from state. The caller owns all buffers.
 */
uint64_t compositor_session_create(void);
void compositor_session_close(uint64_t handle);
int32_t compositor_session_command(uint64_t handle, const uint8_t *json, size_t count);
int32_t compositor_session_import_rgba(uint64_t handle, const uint8_t *pixels, size_t count,
                                      size_t width, size_t height, const uint8_t *name, size_t name_count,
                                      int32_t replacing);
int64_t compositor_session_state(uint64_t handle, uint8_t *output, size_t capacity);
int64_t compositor_session_render(uint64_t handle, uint8_t *output, size_t capacity);
/* Moves whenever the next compositor_session_render would differ from the last (cheap: no pixels touched). */
int64_t compositor_session_render_revision(uint64_t handle);
/* Upstream CanvasViewport: out[6] = zoom, pan x, pan y, backing scale, view width, view height. -2 without a document. */
int32_t compositor_session_viewport(uint64_t handle, double *out);
/* op 0 resize(a=w, b=h, c=scale), 1 fit, 2 zoom to a at (b, c) or center when NaN, 3 keyboard zoom step a, 4 pan (a, b). */
int32_t compositor_session_viewport_update(uint64_t handle, int32_t op, double a, double b, double c);
/* Photoshop import: called with a JSON array of {"layer","message"} conversions to confirm; return non-zero to import. */
typedef int32_t (*compositor_conversion_prompt)(const uint8_t *json, size_t length);
void compositor_set_conversion_prompt(compositor_conversion_prompt prompt);
/* Called about every frame while a long command (RAW develop, large Photoshop import) waits on background work, so the
   shell can repaint and show progress. User input must not be processed from it. */
void compositor_set_wait_pump(void (*pump)(void *context), void *context);
/* Writes upstream's preferences (UserDefaults) to disk; Linux Foundation keeps them in memory until asked. */
void compositor_flush_preferences(void);
/* Mid-stroke partial render: the document area the brush changed since the last call, as premultiplied RGBA8 of
 * that area's size; rect receives x, y, width, height (document pixels). Returns the byte count (0: nothing changed)
 * or -3 when no region is tracked (not in a brush stroke) — then render the whole document instead. */
/* rect: 6 ints — the changed document area (x, y, width, height) and the pixel size (width, height) of the bytes,
 * which are at the current display scale (see compositor_session_render_scaled). */
int64_t compositor_session_render_dirty(uint64_t handle, int32_t *rect, uint8_t *output, size_t capacity);
/* The whole document at `scale` (display resolution); the pixel size comes back in width/height. */
int64_t compositor_session_render_scaled(uint64_t handle, double scale, uint8_t *output, size_t capacity, int32_t *width, int32_t *height);

/*
 * Composite a source tile over a destination tile in place using premultiplied
 * source-over, modulated by an optional coverage mask and opacity.
 *
 *   dst_rgba   in/out, premultiplied RGBA, `stride` bytes per row, width*height pixels.
 *   src_rgba   read-only, premultiplied RGBA, same stride and dimensions.
 *   coverage   read-only, one uint8 per pixel (0-255), row stride = width.
 *              May be NULL, treated as full coverage (255 everywhere).
 *   width,height  tile dimensions in pixels. Both must be > 0.
 *   stride     bytes per row; must be >= width*4.
 *   opacity    source opacity, clamped to [0.0, 1.0].
 *
 * Returns 0 on success, -1 on invalid argument.
 */
int compositor_composite_over(uint8_t *dst_rgba,
                               const uint8_t *src_rgba,
                               const uint8_t *coverage,
                               size_t width,
                               size_t height,
                               size_t stride,
                               float opacity);

/*
 * Project manifest (JSON) serialization for save/load operations.
 * The manifest is the Codable ProjectManifest (version 1-7 schema).
 * Returns required byte count or negative status.
 */
int64_t compositor_session_export_manifest(uint64_t handle, uint8_t *output, size_t capacity);
int32_t compositor_session_import_manifest(uint64_t handle, const uint8_t *json, size_t count);

/*
 * Export or install one canonical layer asset. UUID is its textual
 * representation. RGBA assets use premultiplied RGBA bytes; mask assets use
 * one grayscale byte per pixel.
 */
int64_t compositor_session_export_layer(uint64_t handle,
                                        const uint8_t *layer_id, size_t layer_id_count,
                                        int32_t mask, uint8_t *output, size_t capacity,
                                        size_t *width, size_t *height);
int32_t compositor_session_import_layer(uint64_t handle,
                                        const uint8_t *layer_id, size_t layer_id_count,
                                        int32_t mask, const uint8_t *pixels, size_t count,
                                        size_t width, size_t height);

#ifdef __cplusplus
}
#endif

#endif /* CompositorCore_h */
