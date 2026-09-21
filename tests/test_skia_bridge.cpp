// test_skia_bridge.cpp — Stage 0/5 DoD smoke for the Skia render-device
// bridge (plan §8.10, §9). Verifies, with no Qt and no Swift:
//
//   1. compositor_skia_raster_surface: a Skia Raster surface ingests a
//      canonical RGBA8 buffer and emits the same bytes (identity round-trip
//      proves the bridge handles the canonical contract).
//   2. compositor_renderer_create: factory returns a Raster device when
//      force_raster is set; kind is COMP_RENDERER_RASTER.
//   3. compositor_vulkan_enumerate_devices: returns 0 (loader reachable)
//      or -1 (no Vulkan); either is acceptable, a crash is not.
//   4. compositor_render_rgba: source-over composite of a red src over a
//      transparent dst yields red dst (premultiplied RGBA8).
//
// This is the plan's Stage 0 dependency smoke test, restricted to the Skia
// leg (Qt/Swift legs are verified by the existing CTest + Swift suite).
#include "SkiaBridge.h"

#include <cassert>
#include <cstdio>
#include <cstring>

static int test_raster_surface_identity() {
    const size_t w = 4, h = 4;
    uint8_t src[w * h * 4], dst[w * h * 4];
    for (size_t i = 0; i < w * h * 4; ++i) src[i] = static_cast<uint8_t>(i % 256);
    std::memset(dst, 0, sizeof(dst));
    int rc = compositor_skia_raster_surface(src, dst, w, h);
    if (rc != 0) { std::fprintf(stderr, "raster_surface rc=%d\n", rc); return 1; }
    // Premultiplied source-over over transparent dst == src (identity).
    if (std::memcmp(src, dst, sizeof(src)) != 0) {
        std::fprintf(stderr, "raster_surface bytes differ\n");
        return 1;
    }
    return 0;
}

static int test_renderer_factory_raster() {
    CompRendererKind kind = COMP_RENDERER_VULKAN;
    CompRenderer *r = compositor_renderer_create(1, &kind);
    if (!r) { std::fprintf(stderr, "renderer_create NULL\n"); return 1; }
    if (kind != COMP_RENDERER_RASTER) {
        std::fprintf(stderr, "expected RASTER, got %d\n", kind);
        compositor_renderer_close(r);
        return 1;
    }
    if (compositor_renderer_kind(r) != COMP_RENDERER_RASTER) {
        compositor_renderer_close(r);
        return 1;
    }
    compositor_renderer_close(r);
    return 0;
}

static int test_vulkan_enumerate_no_crash() {
    int n = compositor_vulkan_enumerate_devices();
    // 0 = loader reachable (enumeration deferred to Stage 8).
    // -1 = no Vulkan. Both are acceptable; a crash is not.
    std::printf("vulkan_enumerate_devices=%d\n", n);
    return 0;
}

static int test_render_rgba_source_over() {
    const size_t w = 2, h = 2;
    // src: opaque red, premultiplied.
    uint8_t src[w * h * 4] = {255, 0, 0, 255, 255, 0, 0, 255,
                              255, 0, 0, 255, 255, 0, 0, 255};
    // dst: transparent.
    uint8_t dst[w * h * 4] = {0};
    CompRenderer *r = compositor_renderer_create(1, nullptr);
    if (!r) return 1;
    int rc = compositor_render_rgba(r, src, dst, w, h);
    compositor_renderer_close(r);
    if (rc != 0) { std::fprintf(stderr, "render_rgba rc=%d\n", rc); return 1; }
    for (size_t p = 0; p < w * h; ++p) {
        const uint8_t *d = dst + p * 4;
        if (d[0] != 255 || d[1] != 0 || d[2] != 0 || d[3] != 255) {
            std::fprintf(stderr, "pixel %zu = %d,%d,%d,%d\n",
                p, d[0], d[1], d[2], d[3]);
            return 1;
        }
    }
    return 0;
}

// Regression (2026-09-21 review, R46): the bridge used to memcpy src over dst,
// so every test with an opaque source over a transparent destination passed
// while real compositing was never exercised. A partially transparent source
// over a NON-EMPTY destination is the smallest input a copy cannot satisfy.
// Premultiplied source-over: out = src + dst * (255 - src.a) / 255.
static int test_render_rgba_partial_alpha_over_nonempty_dst() {
    const size_t w = 2, h = 1;
    const uint8_t src[w * h * 4] = {128, 0, 0, 128,   0, 100, 0, 100};   // premultiplied
    const uint8_t dst0[w * h * 4] = {0, 0, 255, 255,  200, 200, 200, 255}; // opaque backdrop
    uint8_t expected[w * h * 4];
    for (size_t p = 0; p < w * h; ++p) {
        const int inv = 255 - src[p * 4 + 3];
        for (int c = 0; c < 4; ++c) {
            expected[p * 4 + c] = static_cast<uint8_t>(
                src[p * 4 + c] + (dst0[p * 4 + c] * inv + 127) / 255);
        }
    }
    uint8_t dst[w * h * 4];
    std::memcpy(dst, dst0, sizeof(dst));
    CompRenderer *r = compositor_renderer_create(1, nullptr);
    if (!r) return 1;
    int rc = compositor_render_rgba(r, src, dst, w, h);
    compositor_renderer_close(r);
    if (rc != 0) { std::fprintf(stderr, "partial_alpha rc=%d\n", rc); return 1; }
    for (size_t i = 0; i < sizeof(dst); ++i) {
        const int diff = static_cast<int>(dst[i]) - static_cast<int>(expected[i]);
        if (diff < -1 || diff > 1) {  // Skia may round differently by 1
            std::fprintf(stderr,
                "partial_alpha byte %zu = %d, expected %d (source-over, not a copy)\n",
                i, dst[i], expected[i]);
            return 1;
        }
    }
    return 0;
}

static int test_vulkan_device_creation_and_device_lost_fallback() {
    CompRendererKind kind = COMP_RENDERER_RASTER;
    CompRenderer *r = compositor_renderer_create(0, &kind);
    if (!r) {
        std::fprintf(stderr, "compositor_renderer_create(0) failed\n");
        return 1;
    }
    std::printf("Created renderer with kind=%d\n", static_cast<int>(kind));

    const size_t w = 2, h = 2;
    uint8_t src[w * h * 4] = {10, 20, 30, 255, 40, 50, 60, 255,
                              70, 80, 90, 255, 100, 110, 120, 255};
    uint8_t dst[w * h * 4] = {0};
    int rc = compositor_render_rgba(r, src, dst, w, h);
    if (rc != 0) {
        std::fprintf(stderr, "compositor_render_rgba failed rc=%d\n", rc);
        compositor_renderer_close(r);
        return 1;
    }
    if (std::memcmp(src, dst, sizeof(src)) != 0) {
        std::fprintf(stderr, "compositor_render_rgba output mismatch\n");
        compositor_renderer_close(r);
        return 1;
    }

    // If backend was Vulkan, simulate loss and verify seamless dynamic fallback to Raster CPU.
    if (kind == COMP_RENDERER_VULKAN) {
        compositor_renderer_simulate_device_lost(r);
        std::memset(dst, 0, sizeof(dst));
        rc = compositor_render_rgba(r, src, dst, w, h);
        if (rc != 0) {
            std::fprintf(stderr, "compositor_render_rgba after device_lost failed rc=%d\n", rc);
            compositor_renderer_close(r);
            return 1;
        }
        if (std::memcmp(src, dst, sizeof(src)) != 0) {
            std::fprintf(stderr, "compositor_render_rgba fallback output mismatch\n");
            compositor_renderer_close(r);
            return 1;
        }
        if (compositor_renderer_kind(r) != COMP_RENDERER_RASTER) {
            std::fprintf(stderr, "expected RASTER after device lost fallback\n");
            compositor_renderer_close(r);
            return 1;
        }
        std::printf("Device loss fallback to Raster CPU verified successfully\n");
    }

    compositor_renderer_close(r);
    return 0;
}

int main() {
    int failures = 0;
    failures += test_raster_surface_identity();
    failures += test_renderer_factory_raster();
    failures += test_vulkan_enumerate_no_crash();
    failures += test_render_rgba_source_over();
    failures += test_render_rgba_partial_alpha_over_nonempty_dst();
    failures += test_vulkan_device_creation_and_device_lost_fallback();
    if (failures) {
        std::fprintf(stderr, "SkiaBridge smoke: %d FAILURE(S)\n", failures);
        return 1;
    }
    std::printf("SkiaBridge smoke OK\n");
    return 0;
}