#include "RenderParitySupport.h"
#include "../../host/CompositorUIFont.h"
#include <QGuiApplication>

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
    return compositor_qt_imageio_install() && compositor_raw_install();
}
