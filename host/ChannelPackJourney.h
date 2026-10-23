#pragma once
#include "SessionWindow.h"
#include "Upstream154Journey.h"
#include <QFile>
#include <QImage>
#include <QMenu>
#include <QLabel>
#include <QScopedValueRollback>
#include <QPushButton>
#include <QTimer>

namespace channelpackjourney {
inline int run(QApplication &) {
    try {
        using upstream154journey::require;
        using upstream154journey::settle;
        QTemporaryDir temporary;
        require(temporary.isValid(), "Channel Pack temporary directory unavailable");
        SessionWindow window;
        window.resize(1200, 900); window.show(); QApplication::setActiveWindow(&window);
        QApplication::processEvents();
        // Hidden, named grayscale layers exercise the original snapshot/default-source logic.
        for (const auto &entry : QList<QPair<QString, int>>{{"Red", 51}, {"Green", 153}, {"Blue", 255}, {"Alpha", 0}}) {
            QImage image(4, 2, QImage::Format_RGBA8888); image.fill(QColor(entry.second, entry.second, entry.second));
            const QString path = temporary.filePath(entry.first + ".png");
            require(image.save(path) && window.sendCommand({{"action", "importFiles"}, {"paths", QJsonArray{path}}}), "Channel Pack layer import failed");
            require(window.sendCommand({{"action", "renameLayer"}, {"name", entry.first}}), "Channel Pack layer name failed");
            require(window.sendCommand({{"action", "setVisible"}, {"enabled", false}}), "Channel Pack hidden fixture failed");
        }
        const auto before = window.sessionState();
        // Commit a default pack, then change all four bindings and check per-document remembered choices.
        for (int round = 0; round < 3; ++round) {
            QString failure; bool inspected = false, inspecting = false;
            QElapsedTimer previewClock;
            QTimer inspector; inspector.setInterval(20);
            QObject::connect(&inspector, &QTimer::timeout, &window, [&] {
                auto *sheet = window.findChild<QDialog *>("swiftUISheet.ExportAsSheet");
                if (!sheet || !sheet->isVisible()) return;
                if (inspecting) return;
                QScopedValueRollback<bool> guard(inspecting, true);
                try {
                    if (!inspected) {
                    inspected = true; previewClock.start();
                    if (round == 0) {
                        QAction *pack = nullptr;
                        for (auto *button : sheet->findChildren<QPushButton *>())
                            if (button->isVisible() && button->text() == QLatin1String("More") && button->menu())
                                for (auto *action : button->menu()->actions())
                                    if (action->text().remove('&') == QLatin1String("Channel Pack")) pack = action;
                        require(pack && pack->isEnabled(), "Channel Pack format menu action missing");
                        pack->trigger(); QApplication::processEvents();
                    }
                    const auto picker = [&](const QString &name) -> QComboBox * {
                        for (auto *candidate : sheet->findChildren<QComboBox *>())
                            if (candidate->isVisible() && candidate->accessibleName() == name) return candidate;
                        return nullptr;
                    };
                    const QStringList names{"Red", "Green", "Blue", "Alpha"};
                    for (int index = 0; index < names.size(); ++index) {
                        auto *control = picker(names[index]);
                        require(control, "Channel Pack channel picker missing");
                        const QString expected = round == 2 ? (index == 3 ? "White" : "Black") : names[index];
                        require(control->currentText() == expected, "Channel Pack default or remembered source mismatch");
                        if (round == 1) {
                            const int choice = control->findText(index == 3 ? "White" : "Black");
                            require(choice >= 0, "Channel Pack solid source missing");
                            control->setCurrentIndex(choice); QApplication::processEvents();
                        }
                    }
                    return; // Let the sheet's event loop run its asynchronous preview before inspecting readiness.
                    }
                    const auto exportButton = [&]() -> QPushButton * {
                        for (auto *button : sheet->findChildren<QPushButton *>())
                            if (button->isVisible() && button->text() == QStringLiteral("Export…")) return button;
                        return nullptr;
                    };
                    if (auto *button = exportButton(); button && button->isEnabled()) {
                        inspector.stop(); button->click();
                    } else if (previewClock.elapsed() > 8000) {
                        for (auto *label : sheet->findChildren<QLabel *>())
                            if (label->isVisible()) qWarning() << "Channel Pack preview:" << label->text();
                        for (auto *button : sheet->findChildren<QPushButton *>())
                            qWarning() << "Channel Pack button:" << button->text() << "visible=" << button->isVisible() << "enabled=" << button->isEnabled();
                        throw std::runtime_error("Channel Pack preview did not become ready");
                    }
                } catch (const std::exception &error) {
                    failure = QString::fromUtf8(error.what()); inspector.stop(); sheet->reject();
                }
            });
            inspector.start();
            const bool answered = window.sendCommand({{"action", "exportAsSheet"}, {"kind", round == 0 ? "png" : "channelPack"}});
            inspector.stop();
            require(inspected && failure.isEmpty(), failure.isEmpty() ? "Channel Pack sheet did not open" : qPrintable(failure));
            require(answered && window.sessionState().value("exportFormat").toString() == QLatin1String("Channel Pack"), "Channel Pack export choice failed");
            const QString path = temporary.filePath(QString("packed-%1.png").arg(round));
            require(window.sendCommand({{"action", "writeExport"}, {"paths", QJsonArray{path}}}), "Channel Pack write failed");
            // Qt's straight RGBA decoder independently checks the Swift export, including RGB under alpha zero.
            const QImage decoded = QImage(path).convertToFormat(QImage::Format_RGBA8888);
            require(decoded.size() == QSize(4, 2), "Channel Pack export dimensions changed");
            for (int y = 0; y < decoded.height(); ++y) for (int x = 0; x < decoded.width(); ++x)
                require(decoded.pixelColor(x, y) == (round == 0 ? QColor(51, 153, 255, 0) : QColor(0, 0, 0, 255)), "Channel Pack file lost channel samples");
            for (const char *field : {"layers", "activeLayerID", "modified", "undoName"})
                require(window.sessionState().value(field) == before.value(field), "Channel Pack changed source records or history");
            require(!window.sessionState().value("busy").toBool(), "Channel Pack left the editor busy");
        }
        qInfo("Qt Channel Pack OK (hidden named layers, four source bindings, transparent RGB file samples, remembered choices and source/history isolation)");
        return 0;
    } catch (const std::exception &error) {
        qCritical("Qt Channel Pack failed: %s", error.what()); return 1;
    }
}
}
