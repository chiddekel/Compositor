#pragma once
#include "CanvasSizeJourney.h"
#include <QAbstractButton>
#include <QDir>
#include <QImageReader>
#include <QPushButton>
#include <QToolBar>

namespace gifjourney {
inline int run(QApplication &) {
    using namespace canvassizejourney;
    try {
        QTemporaryDir temporary;
        require(temporary.isValid(), "GIF temporary directory unavailable");
        SessionWindow window;
        window.resize(1200, 900); window.show(); QApplication::setActiveWindow(&window);
        const QString fixture = QDir::current().filePath("tests/fixtures/gif-disposal.gif");
        require(window.importWithUpstream({fixture}, true), "GIF native import failed");
        const auto timeline = [&]() { return window.findChild<QWidget *>("gifTimelineContainer"); };
        const auto frame = [&](int number) -> QWidget * {
            for (auto *widget : window.findChildren<QWidget *>())
                if (widget->isVisible() && widget->accessibleName() == QString("Frame %1").arg(number)) return widget;
            return nullptr;
        };
        const auto play = [&]() -> QAbstractButton * {
            for (auto *button : window.findChildren<QAbstractButton *>())
                if (button->isVisible() && button->toolTip() == "Play") return button;
            return nullptr;
        };
        pump([&] { return timeline() && timeline()->isVisible() && frame(3) && play(); }, "GIF timeline controls missing");
        const auto original = window.sessionState();
        pump([&] { return frame(2) && frame(2)->isEnabled(); }, "GIF frame selection remained disabled");
        click(frame(2));
        const QString preview = temporary.filePath("frame.png");
        pump([&] {
            if (!window.exportPNG(preview)) return false;
            const QImage image(preview);
            return !image.isNull() && image.pixelColor(0, 0) == QColor(0, 0, 255);
        }, "GIF frame selection did not update exported pixels");
        for (const char *field : {"modified", "undoName", "redoName"})
            require(window.sessionState().value(field) == original.value(field), "GIF frame selection changed history");
        pump([&] { return play() && play()->isEnabled(); }, "GIF play button remained disabled after frame export");
        click(play());
        pump([&] {
            for (auto *button : window.findChildren<QAbstractButton *>())
                if (button->isVisible() && button->toolTip() == "Pause") return true;
            return false;
        }, "GIF playback did not start");
        for (auto *button : window.findChildren<QAbstractButton *>())
            if (button->isVisible() && button->toolTip() == "Pause") { click(button); break; }
        pump([&] { return play() != nullptr; }, "GIF playback did not stop");
        const QString package = temporary.filePath("animation.comp");
        require(window.saveProject(package), "GIF native package save failed");
        require(window.loadProject(package), "GIF native package reopen failed");
        pump([&] { return frame(3) != nullptr; }, "GIF timeline missing after reopen");
        QString exportFailure;
        QElapsedTimer exportClock; exportClock.start();
        QTimer exporter; exporter.setInterval(20);
        QObject::connect(&exporter, &QTimer::timeout, &window, [&] {
            auto *sheet = window.findChild<QDialog *>("swiftUISheet.ExportAsSheet");
            if (!sheet || !sheet->isVisible()) return;
            for (auto *button : sheet->findChildren<QPushButton *>()) {
                if (button->isVisible() && button->text() == "Export…" && button->isEnabled()) {
                    exporter.stop(); button->click(); return;
                }
            }
            if (exportClock.elapsed() > 10000) {
                exporter.stop(); exportFailure = "GIF export preview did not become ready"; sheet->reject();
            }
        });
        exporter.start();
        const bool answered = window.sendCommand({{"action", "exportAsSheet"}, {"kind", "gif"}});
        exporter.stop();
        require(exportFailure.isEmpty(), qPrintable(exportFailure));
        require(answered && window.sessionState().value("exportFormat").toString() == "GIF", "GIF Export As did not retain its format");
        const QString exported = temporary.filePath("animation.gif");
        require(window.sendCommand({{"action", "writeExport"}, {"paths", QJsonArray{exported}}}), "GIF export file write failed");
        QImageReader reader(exported, "gif");
        require(reader.imageCount() == 3, "GIF export lost frames");
        for (int delay : {40, 160, 80}) {
            require(!reader.read().isNull() && reader.nextImageDelay() == delay, "GIF export lost frame pixels or timing");
        }
        auto *rail = window.findChild<QToolBar *>("toolbar.tools");
        require(rail, "tool rail missing");
        window.resize(1200, 1100);
        pump([&] { return rail->width() < 92; }, "tall window did not use one tool column");
        window.resize(1200, 600);
        pump([&] { return rail->width() >= 92; }, "short window did not use two tool columns");
        require(window.height() == 600, "tool rail resized the window instead of adapting");
        window.resize(1200, 1100);
        pump([&] { return rail->width() < 92; }, "tool rail did not return to one column");
        qInfo("Qt GIF OK (import, timeline controls, frame pixels/history, play/pause, save/reopen, GIF export timing and short-window tool columns)");
        return 0;
    } catch (const std::exception &error) {
        qCritical("Qt GIF failed: %s", error.what()); return 1;
    }
}
}
