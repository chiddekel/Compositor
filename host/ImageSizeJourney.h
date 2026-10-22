#pragma once

#include "CanvasSizeJourney.h"
#include "DeepSizeJourney.h"

extern "C" int64_t compositor_take_session_shell_requests(uint64_t, uint8_t *, size_t);

namespace imagesizejourney {
inline int run(QApplication &) {
    using namespace canvassizejourney;
    try {
        QTemporaryDir temporary; require(temporary.isValid(), "image size temporary directory missing");
        QImage fixture(64, 48, QImage::Format_RGBA8888);
        for (int y = 0; y < 48; ++y) for (int x = 0; x < 64; ++x)
            fixture.setPixelColor(x, y, QColor(17 + x * 3, 29 + y * 4, 41 + x + y, 255));
        const QString input = temporary.filePath("source.png"); require(fixture.save(input), "image size source save failed");
        SessionWindow window; window.resize(1200, 900); window.show(); QApplication::setActiveWindow(&window);
        require(window.importImage(input), "image size import failed"); window.setTool(SessionWindow::Tool::Move);
        const auto command = [&](QJsonObject value) { require(window.sendCommand(value), "image size setup/history command failed"); QApplication::processEvents(); };
        command({{"action", "setShowsTransformControls"}, {"enabled", false}});
        command({{"action", "resizeImage"}, {"width", 64}, {"height", 48}, {"value", 100}, {"kind", "Nearest"}});
        const auto pixels = [&]() {
            const QString path = temporary.filePath("pixels.png"); require(window.exportPNG(path), "image size export failed");
            QImage image(path); require(!image.isNull(), "image size readback missing"); return image.convertToFormat(QImage::Format_RGBA8888);
        };
        const auto originalState = window.sessionState(); const auto original = pixels();
        const auto open = [&](const std::function<void(QDialog *)> &inspect) {
            QApplication::setActiveWindow(&window); window.activateWindow(); QApplication::processEvents();
            bool inspected = false; QString failure; QTimer timer; timer.setInterval(10);
            QObject::connect(&timer, &QTimer::timeout, &window, [&] {
                auto *sheet = window.findChild<QDialog *>("swiftUISheet.ImageSizeSheet");
                if (!sheet || !sheet->isVisible()) return;
                timer.stop(); inspected = true;
                try { QApplication::setActiveWindow(sheet); inspect(sheet); }
                catch (const std::exception &error) { failure = QString::fromUtf8(error.what()); qWarning() << "Image size inspection failed:" << failure; click(button(sheet, "Cancel")); }
            });
            QAction *action = nullptr;
            for (auto *top : window.menuBar()->actions()) if (top->isVisible() && top->menu() && top->menu()->objectName() == "appMenu.Image") {
                emit top->menu()->aboutToShow();
                for (auto *item : top->menu()->actions()) if (item->isVisible() && item->text().remove('&') == "Image Size…") action = item;
            }
            require(action && action->isEnabled(), "visible Image Size action unavailable"); timer.start(); action->trigger();
            try { pump([&] { return inspected; }, "image size sheet did not open"); }
            catch (...) {
                const auto state = window.sessionState(); qWarning() << "Image size owner state" << window.sessionHandle() << state.value("busy") << state.value("canSwitch") << state.value("sheets");
                for (uint64_t handle = 1; handle < 32; ++handle) {
                    const auto pending = compositor_take_session_shell_requests(handle, nullptr, 0);
                    if (pending > 2) qWarning() << "Image size queued owner" << handle << pending;
                }
                throw;
            }
            timer.stop();
            pump([&] { const auto state = window.sessionState(); return !state.value("busy").toBool() && state.value("sheets").toArray().isEmpty(); }, "image size sheet did not finish");
            require(failure.isEmpty(), qPrintable(failure));
        };
        const auto picker = [](QDialog *sheet, const QString &item) {
            for (auto *combo : sheet->findChildren<QComboBox *>()) if (combo->isVisible() && combo->findText(item) >= 0) return combo;
            throw std::runtime_error("image size picker missing");
        };
        const auto choose = [&](QDialog *sheet, const QString &item) {
            QPointer<QComboBox> combo = picker(sheet, item); const int index = combo->findText(item);
            combo->setFocus(); combo->showPopup(); QPointer<QAbstractItemView> view = combo->view();
            require(view && view->isVisible(), "image size picker popup missing"); key(view, Qt::Key_Home);
            for (int i = 0; i < index; ++i) { require(view, "image size picker retired"); key(view, Qt::Key_Down); }
            require(view, "image size picker retired before Return"); key(view, Qt::Key_Return);
        };
        const auto sourceState = [&]() {
            const auto state = window.sessionState();
            for (const char *name : {"width", "height", "resolution", "layers", "activeLayerID", "foregroundColor", "backgroundColor", "tool"})
                require(state.value(name) == originalState.value(name), "image size source state differs");
            require(pixels() == original, "image size source pixels differ");
        };
        const auto history = [&](const QJsonObject &committed, const QImage &expected) {
            command({{"action", "undo"}}); sourceState(); command({{"action", "redo"}});
            const auto state = window.sessionState();
            for (const char *name : {"width", "height", "resolution", "layers", "activeLayerID"})
                require(state.value(name) == committed.value(name), "image size Redo state differs");
            require(pixels() == expected, "image size Redo pixels differ"); command({{"action", "undo"}}); sourceState();
        };
        for (const QString &unit : {QString("Inches"), QString("Centimeters")}) for (int edit = 0; edit < 3; ++edit) {
            const double multiplier = unit == "Centimeters" ? 2.54 : 1;
            open([&](QDialog *sheet) {
                require(toggle(sheet, "Resample")->isChecked(), "image size reopened stale Resample draft");
                click(toggle(sheet, "Resample"));
                pump([&] { return picker(sheet, "Inches")->count() == 2; }, "image size no-resample units did not refresh");
                choose(sheet, unit);
                auto *combo = picker(sheet, unit);
                require(combo->count() == 2 && combo->findText("Pixels") < 0 && combo->findText("Percent") < 0,
                    "image size no-resample units not restricted to print dimensions");
                require(!toggle(sheet, "Lock aspect ratio")->isEnabled(), "image size no-resample aspect lock enabled");
                for (auto *sampling : sheet->findChildren<QComboBox *>())
                    require(!sampling->isVisible() || sampling->findText("Nearest") < 0, "image size no-resample sampling remained visible");
                if (edit == 2) type(sheet, "Resolution", "200");
                else type(sheet, edit == 0 ? "Width" : "Height", QString::number((edit == 0 ? 64 : 48) / 200.0 * multiplier, 'f', 8));
                pump([&] { return std::abs(field(sheet, "Resolution")->text().toDouble() - 200) < 0.001; }, "image size print dimension did not refresh resolution while focused");
                require(hint(sheet, "64 × 48 pixels") && button(sheet, "Resize")->isEnabled(), "image size print result differs");
                require(pixels() == original, "image size print draft changed pixels"); click(button(sheet, "Resize"));
            });
            pump([&] { return std::abs(window.sessionState().value("resolution").toDouble() - 200) < 0.001; }, "image size print resolution commit failed");
            const auto committed = window.sessionState();
            require(committed.value("layers") == originalState.value("layers") && committed.value("width").toInt() == 64 && committed.value("height").toInt() == 48,
                "image size print-only commit changed source records or dimensions");
            require(pixels() == original, "image size print-only commit changed pixels"); history(committed, original);
            qInfo("Qt Image Size print controls OK (unit=%s edit=%d, focused resolution refresh, unchanged pixels/records, single Undo/Redo)", qPrintable(unit), edit);
        }
        for (const QString &unit : {QString("Pixels"), QString("Percent"), QString("Inches"), QString("Centimeters")}) for (bool locked : {true, false}) {
            open([&](QDialog *sheet) {
                choose(sheet, unit); choose(sheet, "Nearest");
                if (!locked) click(toggle(sheet, "Lock aspect ratio"));
                double width = 128;
                if (unit == "Percent") width = 200;
                if (unit == "Inches") width = 1.28;
                if (unit == "Centimeters") width = 1.28 * 2.54;
                type(sheet, "Width", QString::number(width, 'f', 8));
                pump([&] { return hint(sheet, locked ? "128 × 96 pixels" : "128 × 48 pixels"); }, "image size dimensions did not refresh while focused");
                require(pixels() == original, "image size resample draft changed pixels"); click(button(sheet, "Resize"));
            });
            pump([&] { return window.sessionState().value("width").toInt() == 128; }, "image size resample commit failed");
            QImage expected(128, locked ? 96 : 48, QImage::Format_RGBA8888);
            for (int y = 0; y < expected.height(); ++y) for (int x = 0; x < 128; ++x) expected.setPixelColor(x, y, original.pixelColor(x / 2, locked ? y / 2 : y));
            require(pixels() == expected, "image size nearest pixels differ from independent oracle");
            const auto committed = window.sessionState(); require(committed.value("activeLayerID") == originalState.value("activeLayerID"), "image size resample lost layer identity"); history(committed, expected);
            qInfo("Qt Image Size resample controls OK (unit=%s locked=%d, exact nearest uniform/nonuniform pixels, retained identity and single Undo/Redo)", qPrintable(unit), locked);
        }
        for (const QString &unit : {QString("Inches"), QString("Centimeters")}) {
            open([&](QDialog *sheet) {
                choose(sheet, unit); choose(sheet, "Nearest"); type(sheet, "Resolution", "200");
                pump([&] { return hint(sheet, "128 × 96 pixels"); }, "image size print-unit DPI edit did not rescale pixels while focused");
                const double multiplier = unit == "Centimeters" ? 2.54 : 1;
                require(std::abs(field(sheet, "Width")->text().toDouble() - 0.64 * multiplier) < 0.001
                    && std::abs(field(sheet, "Height")->text().toDouble() - 0.48 * multiplier) < 0.001,
                    "image size resample DPI edit changed print dimensions");
                click(button(sheet, "Resize"));
            });
            pump([&] { return window.sessionState().value("width").toInt() == 128; }, "image size DPI resample commit failed");
            require(window.sessionState().value("resolution").toDouble() == 200, "image size resample DPI differs");
            QImage expected(128, 96, QImage::Format_RGBA8888);
            for (int y = 0; y < 96; ++y) for (int x = 0; x < 128; ++x) expected.setPixelColor(x, y, original.pixelColor(x / 2, y / 2));
            require(pixels() == expected, "image size DPI resample differs from independent oracle"); history(window.sessionState(), expected);
            qInfo("Qt Image Size DPI resample OK (unit=%s, retained print dimensions, exact nearest pixels and Undo/Redo)", qPrintable(unit));
        }
        open([&](QDialog *sheet) { click(toggle(sheet, "Resample")); type(sheet, "Resolution", "300"); click(button(sheet, "Cancel")); });
        sourceState();
        open([&](QDialog *sheet) {
            require(toggle(sheet, "Resample")->isChecked() && picker(sheet, "Pixels")->currentText() == "Pixels"
                && field(sheet, "Resolution")->text().toDouble() == 100, "image size Cancel leaked print settings into new sheet");
            type(sheet, "Resolution", "9601");
            pump([&] { return !button(sheet, "Resize")->isEnabled(); }, "image size invalid DPI did not disable Resize while focused");
            click(button(sheet, "Cancel"));
        }); sourceState();
        qInfo("Qt Image Size Cancel/validation OK (print draft isolation, fresh defaults, focused invalid DPI rejection)");
        deepsizejourney::run([&] { open([&](QDialog *sheet) { click(button(sheet, "Cancel")); }); sourceState(); });
        open([&](QDialog *sheet) { click(button(sheet, "Cancel")); }); sourceState();
        qInfo("Qt Image Size window ownership OK (both older/newer owners while alive, older owner after newer window destruction, source isolation)");
        return 0;
    } catch (const std::exception &error) { qCritical("Qt Image Size failed: %s", error.what()); return 1; }
}
} // namespace imagesizejourney
