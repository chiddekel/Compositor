#include "CompositorKernels.h"
#include <stdio.h>
#include <stdlib.h>

// Only the portable build defines COMPOSITOR_PORTABLE, so only it references
// (and therefore needs) the handler. On a macOS/Xcode build this translation
// unit compiles to no exported symbol and nothing links against it.
#ifdef COMPOSITOR_PORTABLE
void compositor_kernel_assert_fail(const char *file, int line, const char *expr) {
    fprintf(stderr,
            "Compositor kernel: canonical-buffer contract violated (%s) at %s:%d\n",
            expr, file, line);
    fflush(stderr);
    abort();
}
#endif