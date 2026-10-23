// Input devices through Qt's platform layer (T-16, without the devices): events are handed to QWindowSystemInterface
// exactly as the xcb and Wayland plugins hand over a pen, a touchscreen, a trackpad or a wheel, so they take the real
// delivery path (Qt's tablet-to-mouse and touch-to-mouse synthesis included) before reaching the canvas.
// `CompositorHostBootstrap --combo-smoke --input-probe`. What it checks happens in the document: pixels painted,
// the viewport panned or zoomed, the brush resized. What it cannot check is the hardware and its driver.
#pragma once

#include "SessionWindow.h"

#include <QApplication>
#include <QJsonObject>
#include <QPointingDevice>
#include <QWidget>
#include <QWindow>
#include <stdexcept>

#if __has_include(<qpa/qwindowsysteminterface.h>)
#include <qpa/qwindowsysteminterface.h>
#include <qpa/qwindowsysteminterface_p.h>
#define COMPOSITOR_HAS_QPA_INPUT 1
#endif

extern "C" int64_t compositor_session_render(uint64_t, uint8_t *, size_t);
extern "C" int32_t compositor_session_viewport(uint64_t, double *);

namespace inputprobe {

inline void require(bool ok, const char *message) { if (!ok) throw std::runtime_error(message); }

#if defined(COMPOSITOR_HAS_QPA_INPUT)
inline QByteArray pixels(SessionWindow &window) {
    const int64_t size = compositor_session_render(window.sessionHandle(), nullptr, 0);
    QByteArray bytes(qsizetype(std::max<int64_t>(size, 0)), Qt::Uninitialized);
    if (size > 0) compositor_session_render(window.sessionHandle(), reinterpret_cast<uint8_t *>(bytes.data()), bytes.size());
    return bytes;
}

inline void settle(int rounds = 10) {
    for (int i = 0; i < rounds; ++i) {
        QWindowSystemInterface::flushWindowSystemEvents();
        QApplication::processEvents(QEventLoop::AllEvents, 10);
    }
}

struct Viewport { double zoom = 0, x = 0, y = 0; };
inline Viewport viewport(SessionWindow &window) {
    double v[6] = {};
    compositor_session_viewport(window.sessionHandle(), v);
    return {v[0], v[1], v[2]};
}

inline int run(QApplication &app) {
    Q_UNUSED(app);
    try {
        SessionWindow window;
        window.resize(1200, 860);
        window.show();
        QApplication::setActiveWindow(&window);
        settle(20);
        window.createNewDocument(800, 600);
        settle(20);
        QWidget *canvas = window.findChild<QWidget *>(QStringLiteral("editorCanvas"));
        require(canvas && window.windowHandle(), "no canvas");
        QWindow *handle = window.windowHandle();
        const auto at = [&](double fx, double fy) {   // a point over the document, in window and global coordinates
            const QPointF local = canvas->mapTo(&window, window.documentToCanvasPoint(QPointF(800 * fx, 600 * fy)).toPoint());
            return std::pair{local, QPointF(window.mapToGlobal(local.toPoint()))};
        };
        ulong time = 1000;

        // Pen: a tablet stroke with the Brush. The canvas leaves tablet events to Qt, which turns them into the mouse
        // events the canvas paints with (upstream has no pressure: a pen draws as the mouse does on the Mac).
        // As the xcb and Wayland plugins declare (the offscreen one used for tests does not): the platform sends no
        // mouse events of its own for a pen, so Qt makes them from the tablet events the canvas leaves unhandled.
        QWindowSystemInterfacePrivate::TabletEvent::setPlatformSynthesizesMouse(false);
        static QPointingDevice pen(QStringLiteral("probe pen"), 7001, QInputDevice::DeviceType::Stylus,
                                   QPointingDevice::PointerType::Pen,
                                   QInputDevice::Capability::Position | QInputDevice::Capability::Pressure, 1, 2);
        QWindowSystemInterface::registerInputDevice(&pen);
        window.setTool(SessionWindow::Tool::Brush);
        settle();
        QByteArray before = pixels(window);
        for (int step = 0; step <= 12; ++step) {
            const auto [local, global] = at(0.2 + 0.4 * step / 12, 0.3 + 0.1 * step / 12);
            QWindowSystemInterface::handleTabletEvent(handle, time += 8, &pen, local, global,
                                                      step < 12 ? Qt::LeftButton : Qt::NoButton, step < 12 ? 0.6 : 0, 0, 0, 0, 0, 0);
            settle(2);
        }
        settle();
        require(pixels(window) != before, "a pen stroke painted nothing");
        qInfo("input probe: pen stroke painted (tablet events through Qt's mouse synthesis)");

        // Touchscreen: one finger drawing with the Brush (touch becomes the mouse, as Qt does for widgets).
        static QPointingDevice touch(QStringLiteral("probe touchscreen"), 7002, QInputDevice::DeviceType::TouchScreen,
                                     QPointingDevice::PointerType::Finger, QInputDevice::Capability::Position | QInputDevice::Capability::Area, 10, 0);
        QWindowSystemInterface::registerInputDevice(&touch);
        before = pixels(window);
        for (int step = 0; step <= 10; ++step) {
            const auto [local, global] = at(0.25 + 0.3 * step / 10, 0.7);
            QWindowSystemInterface::TouchPoint point;
            point.id = 1;
            point.state = step == 0 ? QEventPoint::State::Pressed : step == 10 ? QEventPoint::State::Released : QEventPoint::State::Updated;
            point.area = QRectF(global - QPointF(4, 4), QSizeF(8, 8));
            point.normalPosition = QPointF(global.x() / 1920, global.y() / 1080);
            point.pressure = 1;
            QWindowSystemInterface::handleTouchEvent(handle, time += 8, &touch, {point});
            settle(2);
        }
        settle();
        require(pixels(window) != before, "a finger stroke painted nothing");
        qInfo("input probe: touch stroke painted (touch through Qt's mouse synthesis)");

        // Trackpad: two-finger scroll pans (pixel deltas, with scroll phases).
        window.setTool(SessionWindow::Tool::Move);
        settle();
        Viewport start = viewport(window);
        {
            const auto [local, global] = at(0.5, 0.5);
            QWindowSystemInterface::handleWheelEvent(handle, time += 8, local, global, QPoint(0, 0), QPoint(0, 0), Qt::NoModifier, Qt::ScrollBegin,
                                                     Qt::MouseEventSynthesizedBySystem);
            for (int i = 0; i < 6; ++i)
                QWindowSystemInterface::handleWheelEvent(handle, time += 8, local, global, QPoint(-6, -9), QPoint(-12, -18), Qt::NoModifier,
                                                         Qt::ScrollUpdate, Qt::MouseEventSynthesizedBySystem);
            QWindowSystemInterface::handleWheelEvent(handle, time += 8, local, global, QPoint(0, 0), QPoint(0, 0), Qt::NoModifier, Qt::ScrollEnd,
                                                     Qt::MouseEventSynthesizedBySystem);
        }
        settle();
        Viewport now = viewport(window);
        require(now.zoom == start.zoom && (now.x != start.x || now.y != start.y), "two-finger scroll did not pan (or zoomed)");
        qInfo("input probe: trackpad scroll panned (%.0f, %.0f) -> (%.0f, %.0f) at the same zoom", start.x, start.y, now.x, now.y);

        // Trackpad: pinch zooms about the fingers.
        start = now;
        {
            const auto [local, global] = at(0.5, 0.5);
            QWindowSystemInterface::handleGestureEvent(handle, time += 8, &touch, Qt::BeginNativeGesture, local, global, 2);
            for (int i = 0; i < 5; ++i)
                QWindowSystemInterface::handleGestureEventWithRealValue(handle, time += 8, &touch, Qt::ZoomNativeGesture, 0.08, local, global, 2);
            QWindowSystemInterface::handleGestureEvent(handle, time += 8, &touch, Qt::EndNativeGesture, local, global, 2);
        }
        settle();
        now = viewport(window);
        require(now.zoom > start.zoom * 1.2, "a pinch did not zoom in");
        qInfo("input probe: pinch zoomed %.3f -> %.3f", start.zoom, now.zoom);

        // Mouse wheel with Ctrl zooms; without, it scrolls.
        start = now;
        {
            const auto [local, global] = at(0.5, 0.5);
            QWindowSystemInterface::handleWheelEvent(handle, time += 8, local, global, QPoint(), QPoint(0, -120), Qt::ControlModifier);
        }
        settle();
        now = viewport(window);
        require(now.zoom < start.zoom, "Ctrl + wheel down did not zoom out");
        qInfo("input probe: Ctrl+wheel zoomed %.3f -> %.3f", start.zoom, now.zoom);

        // Keyboard: ] and [ resize the brush, as on the Mac.
        window.setTool(SessionWindow::Tool::Brush);
        settle();
        const double size = window.sessionState().value("brushDiameter").toDouble();
        QWindowSystemInterface::handleKeyEvent(handle, QEvent::KeyPress, Qt::Key_BracketRight, Qt::NoModifier, QStringLiteral("]"));
        QWindowSystemInterface::handleKeyEvent(handle, QEvent::KeyRelease, Qt::Key_BracketRight, Qt::NoModifier, QStringLiteral("]"));
        settle();
        const double larger = window.sessionState().value("brushDiameter").toDouble();
        QWindowSystemInterface::handleKeyEvent(handle, QEvent::KeyPress, Qt::Key_BracketLeft, Qt::NoModifier, QStringLiteral("["));
        QWindowSystemInterface::handleKeyEvent(handle, QEvent::KeyRelease, Qt::Key_BracketLeft, Qt::NoModifier, QStringLiteral("["));
        settle();
        const double back = window.sessionState().value("brushDiameter").toDouble();
        require(larger > size && back < larger, "[ and ] did not resize the brush");
        qInfo("input probe: ] and [ resized the brush %.0f -> %.0f -> %.0f", size, larger, back);

        qInfo("Qt input probe OK (pen, touch, trackpad scroll and pinch, Ctrl+wheel, brush keys through QWindowSystemInterface)");
        return 0;
    } catch (const std::exception &e) {
        qCritical("Qt input probe failed: %s", e.what());
        return 1;
    }
}
#else
inline int run(QApplication &) {
    qCritical("Qt input probe needs Qt's private qpa headers (QWindowSystemInterface)");
    return 1;
}
#endif

}  // namespace inputprobe
