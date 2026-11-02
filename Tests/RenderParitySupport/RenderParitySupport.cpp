#include "RenderParitySupport.h"
#include "../../host/CompositorUIFont.h"
#include <QGuiApplication>
#include <cstdio>
#include <cstdlib>
#include <dlfcn.h>

extern "C" int compositor_qt_imageio_install(void);
extern "C" int compositor_raw_install(void);

int compositor_parity_install(void) {
    static int argc = 1;
    static char name[] = "CompositorRenderParity";
    static char *argv[] = {name, nullptr};
    // Qt's font/image engine needs the same GUI initialization as the real application.
    // Keep it alive for the test process; Swift Testing owns process teardown.
    if (!QGuiApplication::instance()) new QGuiApplication(argc, argv);
    installCompositorUIFont(*qGuiApp);
    using Install = int (*)(void);
    Install installImageIO = compositor_qt_imageio_install;
    if (const char *path = std::getenv("COMPOSITOR_IMAGEIO_BACKEND"); path && *path) {
        // Keep the selected library loaded: Swift retains its callbacks for this process.
        void *library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
        if (!library) {
            std::fprintf(stderr, "Parity ImageIO backend could not load: %s\n", dlerror());
            return 0;
        }
        installImageIO = reinterpret_cast<Install>(dlsym(library, "compositor_qt_imageio_install"));
        if (!installImageIO) {
            std::fprintf(stderr, "Parity ImageIO backend has no install entry point\n");
            dlclose(library);
            return 0;
        }
    }
    return installImageIO() && compositor_raw_install();
}
