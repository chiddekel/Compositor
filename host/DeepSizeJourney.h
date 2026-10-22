#pragma once

#include "CanvasSizeJourney.h"
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <cstdlib>
#include <vector>

using DeepSizeDecode = int32_t (*)(const uint8_t *, size_t, uint8_t **, int32_t *, int32_t *, int32_t *, double *, int32_t *, char *, size_t);
using DeepSizeEncode = int32_t (*)(const uint8_t *, int32_t, int32_t, int32_t, const char *, double, double, int32_t, uint8_t **, size_t *);
extern "C" int compositor_qt_imageio_functions(DeepSizeDecode *, DeepSizeEncode *);
extern "C" int compositor_qt_imageio_deep_decode(DeepSizeDecode *);

namespace deepsizejourney {
inline void run(const std::function<void()> &otherWindowProbe) {
    using namespace canvassizejourney;
    QTemporaryDir temporary; require(temporary.isValid(), "deep sizing temporary directory missing");
    DeepSizeDecode decode = nullptr; DeepSizeEncode encode = nullptr;
    require(compositor_qt_imageio_functions(&decode, &encode) && compositor_qt_imageio_deep_decode(&decode), "deep sizing codec unavailable");
    for (bool hdr : {false, true}) {
        std::vector<uint16_t> fine(64 * 8 * 4); std::vector<float> wide(64 * 8 * 4);
        for (int y = 0; y < 8; ++y) for (int x = 0; x < 64; ++x) {
            const int i = (y * 64 + x) * 4;
            const uint16_t a = x % 4 == 0 ? 0 : x % 4 == 1 ? 16384 : x % 4 == 2 ? 32768 : 65535;
            for (int c = 0; c < 3; ++c) fine[i + c] = ((25000 + x * 3 + y * 7 + c * 1000) * uint32_t(a) + 32767) / 65535;
            fine[i + 3] = a;
            wide[i] = (2 + x / 64.0f + y / 128.0f) * (a / 65535.0f);
            wide[i + 1] = 0.25f * (a / 65535.0f); wide[i + 2] = 0.125f * (a / 65535.0f); wide[i + 3] = a / 65535.0f;
        }
        uint8_t *encoded = nullptr; size_t encodedSize = 0;
        require(encode(hdr ? reinterpret_cast<const uint8_t *>(wide.data()) : reinterpret_cast<const uint8_t *>(fine.data()),
            64, 8, hdr ? 16 : 8, hdr ? "com.ilm.openexr-image" : "public.png", 1, 100, 1, &encoded, &encodedSize) == 0 && encodedSize > 0,
            "deep sizing fixture encode failed");
        const QString input = temporary.filePath(hdr ? "source.exr" : "source.png");
        QFile file(input); require(file.open(QIODevice::WriteOnly) && file.write(reinterpret_cast<const char *>(encoded), encodedSize) == qint64(encodedSize), "deep sizing fixture write failed");
        file.close(); std::free(encoded);
        SessionWindow window; window.resize(1200, 900); window.show(); QApplication::setActiveWindow(&window);
        require(window.importImage(input), "deep sizing photo import failed"); window.setTool(SessionWindow::Tool::Move);
        const auto command = [&](QJsonObject value) { require(window.sendCommand(value), "deep sizing history/setup failed"); QApplication::processEvents(); };
        command({{"action", "setShowsTransformControls"}, {"enabled", false}});
        const auto original = window.sessionState();
        const auto open = [&](bool canvas, const std::function<void(QDialog *)> &inspect) {
            QApplication::setActiveWindow(&window); window.activateWindow(); QApplication::processEvents();
            bool inspected = false; QString failure; QTimer timer; timer.setInterval(10);
            QObject::connect(&timer, &QTimer::timeout, &window, [&] {
                auto *sheet = window.findChild<QDialog *>(canvas ? "swiftUISheet.CanvasSizeSheet" : "swiftUISheet.ImageSizeSheet");
                if (!sheet || !sheet->isVisible()) return;
                timer.stop(); inspected = true;
                try { QApplication::setActiveWindow(sheet); inspect(sheet); }
                catch (const std::exception &error) { failure = QString::fromUtf8(error.what()); qWarning() << "Deep sizing inspection failed:" << failure; click(button(sheet, "Cancel")); }
            });
            QAction *action = nullptr;
            for (auto *top : window.menuBar()->actions()) if (top->isVisible() && top->menu() && top->menu()->objectName() == "appMenu.Image") {
                emit top->menu()->aboutToShow();
                for (auto *item : top->menu()->actions()) if (item->isVisible() && item->text().remove('&') == (canvas ? "Canvas Size…" : "Image Size…")) action = item;
            }
            require(action && action->isEnabled(), "deep sizing visible menu action unavailable"); timer.start(); action->trigger();
            pump([&] { return inspected; }, "deep sizing sheet did not open"); timer.stop();
            pump([&] { const auto state = window.sessionState(); return !state.value("busy").toBool() && state.value("sheets").toArray().isEmpty(); }, "deep sizing operation did not finish");
            require(failure.isEmpty(), qPrintable(failure));
        };
        int saves = 0;
        const auto saveAndCheck = [&](int assetScale, int width, int height, double resolution) {
            const QString path = temporary.filePath(QString("%1-%2.comp").arg(hdr ? "hdr" : "16bit").arg(++saves));
            require(window.writeProjectPackage(path), "deep sizing project save failed");
            QFile manifest(path + "/manifest.json"); require(manifest.open(QIODevice::ReadOnly), "deep sizing saved manifest missing");
            const auto object = QJsonDocument::fromJson(manifest.readAll()).object(); const auto layers = object.value("layers").toArray();
            require(object.value("width").toInt() == width && object.value("height").toInt() == height
                && std::abs(object.value("resolution").toDouble() - resolution) < 0.001 && layers.size() == 1,
                "deep sizing saved dimensions/DPI/layer count differ");
            const QString asset = layers.first().toObject().value("imageFile").toString();
            require(asset.endsWith(hdr ? ".exr" : ".png"), "deep sizing saved asset format changed");
            QFile image(path + "/images/" + asset); require(image.open(QIODevice::ReadOnly), "deep sizing saved asset missing"); const auto bytes = image.readAll();
            uint8_t *decoded = nullptr; int32_t w = 0, h = 0, layout = 0, orientation = 0; double dpi = 0; char type[80]{};
            require(decode(reinterpret_cast<const uint8_t *>(bytes.constData()), bytes.size(), &decoded, &w, &h, &layout, &dpi, &orientation, type, sizeof(type)) == 0,
                "deep sizing saved asset decode failed");
            require(w == 64 * assetScale && h == 8 * assetScale && layout == (hdr ? 16 : 8), "deep sizing discarded source precision or asset dimensions");
            double worst = 0;
            for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) for (int c = 0; c < 4; ++c) {
                const int source = ((y / assetScale) * 64 + x / assetScale) * 4 + c, dest = (y * w + x) * 4 + c;
                worst = std::max(worst, hdr ? double(std::abs(reinterpret_cast<const float *>(decoded)[dest] - wide[source]))
                    : double(std::abs(int(reinterpret_cast<const uint16_t *>(decoded)[dest]) - int(fine[source]))));
            }
            std::free(decoded);
            if (worst > (hdr ? 0.008 : 2)) qWarning() << "deep sizing all-channel error" << hdr << assetScale << worst;
            require(worst <= (hdr ? 0.008 : 2), "deep sizing source/nearest values or alpha changed");
            require(window.sessionState().value("activeLayerID") == original.value("activeLayerID"), "deep sizing target identity changed");
            return path;
        };
        const double sourceDPI = original.value("resolution").toDouble();
        saveAndCheck(1, 64, 8, sourceDPI);
        otherWindowProbe();
        open(false, [&](QDialog *sheet) { click(toggle(sheet, "Resample")); type(sheet, "Resolution", "200"); click(button(sheet, "Resize")); });
        saveAndCheck(1, 64, 8, 200); command({{"action", "undo"}}); saveAndCheck(1, 64, 8, sourceDPI);
        command({{"action", "redo"}}); saveAndCheck(1, 64, 8, 200); command({{"action", "undo"}});
        qInfo("Qt deep sizing print-only OK (HDR=%d, all source channels/alpha, saved deep asset and DPI, single Undo/Redo)", hdr);
        open(false, [&](QDialog *sheet) {
            QPointer<QComboBox> combo;
            for (auto *candidate : sheet->findChildren<QComboBox *>()) if (candidate->isVisible() && candidate->findText("Nearest") >= 0) combo = candidate;
            require(combo, "deep sizing sampling picker missing"); combo->setFocus(); combo->showPopup(); QPointer<QAbstractItemView> view = combo->view();
            require(view && view->isVisible(), "deep sizing sampling popup missing"); const int index = combo->findText("Nearest"); key(view, Qt::Key_Home);
            for (int i = 0; i < index; ++i) { require(view, "deep sizing sampling popup retired"); key(view, Qt::Key_Down); }
            require(view, "deep sizing sampling popup retired before Return"); key(view, Qt::Key_Return);
            type(sheet, "Width", "128"); click(button(sheet, "Resize"));
        });
        const auto resized = window.sessionState().value("layers"); const auto resizedPath = saveAndCheck(2, 128, 16, sourceDPI);
        command({{"action", "undo"}}); saveAndCheck(1, 64, 8, sourceDPI); command({{"action", "redo"}}); saveAndCheck(2, 128, 16, sourceDPI);
        require(window.sessionState().value("layers") == resized, "deep sizing resample Redo changed records");
        require(window.readProjectPackage(resizedPath), "deep sizing resized package reopen failed"); saveAndCheck(2, 128, 16, sourceDPI);
        qInfo("Qt deep sizing nearest OK (HDR=%d, transparent/partial/opaque alpha, independent every-channel 2x oracle, Undo/Redo and package reopen)", hdr);
        const auto canvas = [&](int w, int h) { open(true, [&](QDialog *sheet) { type(sheet, "Width", QString::number(w)); type(sheet, "Height", QString::number(h)); click(button(sheet, "Center")); click(button(sheet, "OK")); }); };
        const auto beforeCrop = window.sessionState().value("layers");
        canvas(124, 12); saveAndCheck(2, 124, 12, sourceDPI);
        canvas(132, 20); saveAndCheck(2, 132, 20, sourceDPI);
        const auto transform = window.sessionState().value("layers").toArray().first().toObject().value("transform").toObject();
        const auto origin = transform.value("origin").toArray();
        require(origin.size() == 2 && origin[0].toDouble() == 2 && origin[1].toDouble() == 2, "deep sizing crop/re-expand center translation differs");
        command({{"action", "undo"}}); saveAndCheck(2, 124, 12, sourceDPI); command({{"action", "undo"}}); saveAndCheck(2, 128, 16, sourceDPI);
        require(window.sessionState().value("layers") == beforeCrop, "deep sizing canvas Undo lost original records");
        qInfo("Qt deep sizing canvas retention OK (HDR=%d, crop/re-expand with unchanged deep source, center translation, saved dimensions and separate Undo)", hdr);
        otherWindowProbe();
    }
}
} // namespace deepsizejourney
