#ifndef CompositorKernels_h
#define CompositorKernels_h
#include <stdint.h>
#include <stddef.h>

// ENG-17 — canonical-buffer contract assert at every C-kernel entry.
//
// The port feeds kernels only canonical tiles: 8-bit premultiplied RGBA with
// stride == width*4, and 8-bit grayscale coverage with stride == width. A padded
// Skia buffer (stride > width*4) handed to a kernel that assumed tight packing
// would silently corrupt output, so the portable build asserts the contract at
// each entry and aborts on violation. macOS/Xcode builds do not define
// COMPOSITOR_PORTABLE, so these macros expand to nothing and existing callers
// that pass padded strides are unaffected. The macro is always defined (the
// no-op form keeps call sites compiling on both platforms); only the portable
// build references compositor_kernel_assert_fail, so no new link dependency is
// introduced on macOS.

#ifdef __cplusplus
extern "C" {
#endif

void compositor_kernel_assert_fail(const char *file, int line, const char *expr);

#ifdef __cplusplus
}
#endif

#ifdef COMPOSITOR_PORTABLE
#define COMPOSITOR_REQUIRE_CANONICAL_RGBA(stride_, width_) do { \
    if ((size_t)(stride_) != (size_t)(width_) * 4u) \
        compositor_kernel_assert_fail(__FILE__, __LINE__, "stride != width*4 (canonical RGBA)"); \
} while (0)
#define COMPOSITOR_REQUIRE_CANONICAL_GRAY(stride_, width_) do { \
    if ((size_t)(stride_) != (size_t)(width_)) \
        compositor_kernel_assert_fail(__FILE__, __LINE__, "stride != width (canonical gray)"); \
} while (0)
#else
#define COMPOSITOR_REQUIRE_CANONICAL_RGBA(stride_, width_) ((void)0)
#define COMPOSITOR_REQUIRE_CANONICAL_GRAY(stride_, width_) ((void)0)
#endif

#endif