#include <stdlib.h>
#include <stdint.h>
#include <string.h>
static int remaining;
static void *fault_malloc(size_t size) {
    if (remaining == 0) { remaining = -1; return NULL; }
    if (remaining > 0) --remaining;
    return malloc(size);
}
static void *fault_calloc(size_t count, size_t size) {
    if (remaining == 0) { remaining = -1; return NULL; }
    if (remaining > 0) --remaining;
    return calloc(count, size);
}
#define malloc fault_malloc
#define calloc fault_calloc
#define patch_fill patch_fill_fault
#include "../Compositor/Rendering/PatchPixels.c"
#undef malloc
#undef calloc
#undef patch_fill

int compositor_test_patch_alloc_failure(int allocation) {
    uint8_t pixels[48 * 48 * 4], original[sizeof pixels], mask[48 * 48];
    memset(mask, 0, sizeof mask);
    for (int y = 0; y < 48; ++y) for (int x = 0; x < 48; ++x) {
        int p = (y * 48 + x) * 4;
        pixels[p] = (uint8_t)(x * 3); pixels[p + 1] = (uint8_t)(y * 3);
        pixels[p + 2] = 80; pixels[p + 3] = 255;
        if (x >= 16 && x < 32 && y >= 16 && y < 32) mask[y * 48 + x] = 255;
    }
    memcpy(original, pixels, sizeof pixels);
    remaining = allocation;
    int result = patch_fill_fault(pixels, 48 * 4, mask, 48, 48, 48, 17);
    return result == -1 && memcmp(original, pixels, sizeof pixels) == 0;
}
