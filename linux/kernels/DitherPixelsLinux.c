// Tip DitherPixels.c under Linux. Clang blocks + libdispatch aren't available in the
// SwiftPM C target the same way as on macOS; force `dispatch_apply` to run serially so
// the tip kernels (including Scanlines glow) behave deterministically.
#include <stddef.h>
#include <stdlib.h>

// Scanlines reads beam colors even where coverage is zero. Unwritten scratch
// floats can contain NaNs, whose product with zero still changes the screen.
// Initialize this kernel's scratch storage without modifying protected source.
static inline void *compositor_dither_scratch(size_t size) {
    return calloc(1, size);
}
#define malloc compositor_dither_scratch

static inline void compositor_serial_dispatch_apply(size_t n, void *queue, void (^block)(size_t)) {
    (void)queue;
    for (size_t i = 0; i < n; ++i) block(i);
}
#define dispatch_apply compositor_serial_dispatch_apply

#include "../../Compositor/Rendering/DitherPixels.c"

#undef malloc
