#include "TabletHandler.h"

extern "C" int32_t compositor_canvas_tablet(uint64_t handle, int32_t kind, double x, double y,
                                            int32_t modifiers, double pressure);

int32_t UpstreamTabletHandler::dispatch(const QTabletEvent &event, uint64_t handle, int32_t modifiers) {
    if (!handle) return -1;
    const int kind = event.type() == QEvent::TabletPress ? 0 : event.type() == QEvent::TabletRelease ? 2
        : event.buttons().testFlag(Qt::LeftButton) ? 1 : 3;
    return compositor_canvas_tablet(handle, kind, event.position().x(), event.position().y(), modifiers, event.pressure());
}
