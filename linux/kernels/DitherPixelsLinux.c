// Tip DitherPixels.c under Linux. Clang blocks + libdispatch aren't available in the
// SwiftPM C target the same way as on macOS; force `dispatch_apply` to run serially so
// the tip kernels (including Scanlines glow) behave deterministically.
#include <stddef.h>

static inline void compositor_serial_dispatch_apply(size_t n, void *queue, void (^block)(size_t)) {
    (void)queue;
    for (size_t i = 0; i < n; ++i) block(i);
}
#define dispatch_apply compositor_serial_dispatch_apply

#include "../../Compositor/Rendering/DitherPixels.c"
