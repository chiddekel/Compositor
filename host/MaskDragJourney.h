#pragma once
#include "SessionWindow.h"
#include "Upstream154Journey.h"
#include <QLineEdit>

namespace maskdragjourney {
inline int run(QApplication &, const std::function<void(SessionWindow &)> &disableSnap) {
    try {
        using upstream154journey::require;
        bool passed = true;
        for (const auto modifiers : {Qt::KeyboardModifiers(Qt::NoModifier), Qt::KeyboardModifiers(Qt::MetaModifier)}) {
            QTemporaryDir temporary;
            QImage image(64, 32, QImage::Format_RGBA8888); image.fill(QColor(120, 80, 100));
            const QString path = temporary.filePath("mask.png");
            require(image.save(path), "mask drag fixture write failed");
            SessionWindow window;
            window.resize(1200, 900); window.show(); QApplication::setActiveWindow(&window);
            QApplication::processEvents();
            require(window.importImage(path), "mask drag fixture import failed");
            const auto command = [&](const QJsonObject &value) {
                require(window.sendCommand(value), "mask drag fixture command failed"); QApplication::processEvents();
            };
            command({{"action", "addRevealMask"}});
            command({{"action", "brushBegin"}, {"x", 8}, {"y", 16}, {"parameters", QJsonObject{
                {"diameter", 8}, {"hardness", 1}, {"opacity", 1}, {"red", 0}, {"green", 0}, {"blue", 0}, {"mask", 1}}}});
            command({{"action", "brushEnd"}});
            window.setTool(SessionWindow::Tool::Move);
            command({{"action", "setMaskLinked"}, {"enabled", false}});
            command({{"action", "setMaskSelected"}, {"enabled", true}});
            disableSnap(window);
            const auto before = upstream154journey::pixels(window);
            require(static_cast<uint8_t>(before[(16 * 64 + 8) * 4 + 3]) == 0, "mask drag fixture has no hole");
            auto *canvas = window.findChild<QWidget *>("editorCanvas");
            require(canvas, "mask drag canvas missing");
            const auto mouse = [&](QEvent::Type type, QPointF point) {
                const auto position = window.documentToCanvasPoint(point);
                QMouseEvent event(type, position, canvas->mapToGlobal(position),
                    type == QEvent::MouseMove ? Qt::NoButton : Qt::LeftButton,
                    type == QEvent::MouseButtonRelease ? Qt::NoButton : Qt::LeftButton, modifiers);
                QApplication::sendEvent(canvas, &event); window.flushPendingDrag(); QApplication::processEvents();
            };
            mouse(QEvent::MouseButtonPress, {32, 16}); mouse(QEvent::MouseMove, {48, 16});
            const auto after = upstream154journey::pixels(window);
            qInfo() << "mask drag focused: modifiers=" << modifiers << "changed=" << (after != before)
                    << "selected=" << window.sessionState().value("isMaskSelected");
            for (auto *field : window.findChildren<QLineEdit *>())
                if (field->isVisible()) qInfo() << "mask drag field:" << field->accessibleName() << field->text();
            passed &= after != before && static_cast<uint8_t>(after[(16 * 64 + 8) * 4 + 3]) == 255
                && static_cast<uint8_t>(after[(16 * 64 + 24) * 4 + 3]) == 0;
            mouse(QEvent::MouseButtonRelease, {48, 16});
        }
        require(passed, "mask drag did not move coverage exactly sixteen document pixels");
        qInfo("Qt mask drag OK (100%% zoom, Snap disabled and temporary bypass, exact live coverage)");
        return 0;
    } catch (const std::exception &error) {
        qCritical("Qt mask drag failed: %s", error.what()); return 1;
    }
}
}
