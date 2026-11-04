// Input devices through Qt's public test hooks (T-16, without the devices): touch, wheel and key events go through the
// window-system entry points the xcb and Wayland plugins use, so they take the real delivery path (Qt's touch-to-mouse
// synthesis included); the pen and the pinch arrive at the window as the events Qt makes of them, routed to the canvas.
// `CompositorHostBootstrap --combo-smoke --input-probe`. What it checks happens in the document: pixels painted,
// the viewport panned or zoomed, the brush resized. What it cannot check is the hardware and its driver.
#pragma once

#include "SessionWindow.h"

#include <QApplication>
#include <QJsonObject>
#include <QNativeGestureEvent>
#include <QPointingDevice>
#include <QTabletEvent>
#include <QWidget>
#include <QWindow>
#include <QtGui/qtestsupport_gui.h>
#include <QtTest/qtestkeyboard.h>
#include <QtTest/qtesttouch.h>
#include <QtTest/qtestwheel.h>
#include <stdexcept>

extern "C" int64_t compositor_session_render(uint64_t, uint8_t *, size_t);
extern "C" int32_t compositor_session_viewport(uint64_t, double *);

namespace inputprobe {

inline void require(bool ok, const char *message) { if (!ok) throw std::runtime_error(message); }

inline QByteArray pixels(SessionWindow &window) {
    const int64_t size = compositor_session_render(window.sessionHandle(), nullptr, 0);
    QByteArray bytes(qsizetype(std::max<int64_t>(size, 0)), Qt::Uninitialized);
    if (size > 0) compositor_session_render(window.sessionHandle(), reinterpret_cast<uint8_t *>(bytes.data()), bytes.size());
    return bytes;
}

inline void settle(int rounds = 10) {
    for (int i = 0; i < rounds; ++i) {
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
        window.activateWindow();
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

        // Pen: a tablet stroke with the Brush. The window routes each tablet event to the canvas under it, which
        // paints with the pen's pressure (TabletHandler); the press grabs the stroke until the release.
        static QPointingDevice pen(QStringLiteral("probe pen"), 7001, QInputDevice::DeviceType::Stylus,
                                   QPointingDevice::PointerType::Pen,
                                   QInputDevice::Capability::Position | QInputDevice::Capability::Pressure, 1, 2);
        window.setTool(SessionWindow::Tool::Brush);
        settle();
        QByteArray before = pixels(window);
        for (int step = 0; step <= 12; ++step) {
            const auto [local, global] = at(0.2 + 0.4 * step / 12, 0.3 + 0.1 * step / 12);
            const QEvent::Type type = step == 0 ? QEvent::TabletPress : step == 12 ? QEvent::TabletRelease : QEvent::TabletMove;
            QTabletEvent event(type, &pen, local, global, step < 12 ? 0.6 : 0, 0, 0, 0, 0, 0, Qt::NoModifier, Qt::LeftButton,
                               step < 12 ? Qt::LeftButton : Qt::NoButton);
            QApplication::sendEvent(handle, &event);
            settle(2);
        }
        settle();
        require(pixels(window) != before, "a pen stroke painted nothing");
        qInfo("input probe: pen stroke painted (tablet events routed to the canvas)");

        // Touchscreen: one finger drawing with the Brush (touch becomes the mouse, as Qt does for widgets).
        QPointingDevice *touch = QTest::createTouchDevice();
        before = pixels(window);
        for (int step = 0; step <= 10; ++step) {
            const QPoint local = at(0.25 + 0.3 * step / 10, 0.7).first.toPoint();
            auto sequence = QTest::touchEvent(handle, touch, false);
            if (step == 0) sequence.press(1, local, handle);
            else if (step == 10) sequence.release(1, local, handle);
            else sequence.move(1, local, handle);
            sequence.commit();
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
            qt_handleWheelEvent(handle, local, global, QPoint(0, 0), QPoint(0, 0), Qt::NoModifier, Qt::ScrollBegin);
            for (int i = 0; i < 6; ++i)
                qt_handleWheelEvent(handle, local, global, QPoint(-6, -9), QPoint(-12, -18), Qt::NoModifier, Qt::ScrollUpdate);
            qt_handleWheelEvent(handle, local, global, QPoint(0, 0), QPoint(0, 0), Qt::NoModifier, Qt::ScrollEnd);
        }
        settle();
        Viewport now = viewport(window);
        require(now.zoom == start.zoom && (now.x != start.x || now.y != start.y), "two-finger scroll did not pan (or zoomed)");
        qInfo("input probe: trackpad scroll panned (%.0f, %.0f) -> (%.0f, %.0f) at the same zoom", start.x, start.y, now.x, now.y);

        // Trackpad: pinch zooms about the fingers.
        start = now;
        {
            const auto [local, global] = at(0.5, 0.5);
            const auto gesture = [&, local = local, global = global](Qt::NativeGestureType type, double value) {
                QNativeGestureEvent event(type, touch, 2, local, local, global, value, {});
                QApplication::sendEvent(handle, &event);
            };
            gesture(Qt::BeginNativeGesture, 0);
            for (int i = 0; i < 5; ++i) gesture(Qt::ZoomNativeGesture, 0.08);
            gesture(Qt::EndNativeGesture, 0);
        }
        settle();
        now = viewport(window);
        require(now.zoom > start.zoom * 1.2, "a pinch did not zoom in");
        qInfo("input probe: pinch zoomed %.3f -> %.3f", start.zoom, now.zoom);

        // Mouse wheel with Ctrl zooms; without, it scrolls.
        start = now;
        {
            const auto [local, global] = at(0.5, 0.5);
            qt_handleWheelEvent(handle, local, global, QPoint(), QPoint(0, -120), Qt::ControlModifier, Qt::NoScrollPhase);
        }
        settle();
        now = viewport(window);
        require(now.zoom < start.zoom, "Ctrl + wheel down did not zoom out");
        qInfo("input probe: Ctrl+wheel zoomed %.3f -> %.3f", start.zoom, now.zoom);

        // Keyboard: ] and [ resize the brush, as on the Mac.
        window.setTool(SessionWindow::Tool::Brush);
        settle();
        const double size = window.sessionState().value("brushDiameter").toDouble();
        QTest::sendKeyEvent(QTest::Click, handle, Qt::Key_BracketRight, QStringLiteral("]"), Qt::NoModifier);
        settle();
        const double larger = window.sessionState().value("brushDiameter").toDouble();
        QTest::sendKeyEvent(QTest::Click, handle, Qt::Key_BracketLeft, QStringLiteral("["), Qt::NoModifier);
        settle();
        const double back = window.sessionState().value("brushDiameter").toDouble();
        require(larger > size && back < larger, "[ and ] did not resize the brush");
        qInfo("input probe: ] and [ resized the brush %.0f -> %.0f -> %.0f", size, larger, back);

        qInfo("Qt input probe OK (pen, touch, trackpad scroll and pinch, Ctrl+wheel, brush keys through Qt's public input hooks)");
        return 0;
    } catch (const std::exception &e) {
        qCritical("Qt input probe failed: %s", e.what());
        return 1;
    }
}

}  // namespace inputprobe
