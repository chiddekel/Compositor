#pragma once
#include "SessionWindow.h"
#include "Upstream154Journey.h"
#include <QDoubleSpinBox>
#include <QPushButton>

namespace dispersionjourney {
inline int run(QApplication &) {
    try {
        using upstream154journey::require;
        using upstream154journey::settle;
        QTemporaryDir temporary;
        QImage fixture(61, 61, QImage::Format_RGBA8888); fixture.fill(Qt::transparent);
        for (int y=28;y<33;++y) for (int x=28;x<33;++x) fixture.setPixelColor(x,y,Qt::white);
        const QString path=temporary.filePath("spectrum.png");
        require(fixture.save(path), "RGB Split fixture could not be saved");
        SessionWindow window; window.resize(1200,900); window.show(); QApplication::setActiveWindow(&window);
        QApplication::processEvents(); require(window.importImage(path), "RGB Split fixture import failed");
        const auto original=window.sessionState();
        const auto pixels=upstream154journey::pixels(window);
        const auto panel=[&]() -> QDialog * {
            for (auto *candidate: window.findChildren<QDialog *>())
                if (candidate->isVisible() && candidate->objectName().contains("FilterSheet")) return candidate;
            return nullptr;
        };
        const auto button=[&](const QString &text) -> QPushButton * {
            if (auto *sheet=panel()) for (auto *candidate: sheet->findChildren<QPushButton *>())
                if (candidate->isVisible() && candidate->text()==text) return candidate;
            return nullptr;
        };
        const auto open=[&] {
            require(window.sendCommand({{"action","openFilter"},{"kind","RGB Split"}}), "RGB Split could not start");
            settle([&] { return panel()!=nullptr && !window.sessionState().value("filterPreviewRendering").toBool(); },
                   "RGB Split preview did not finish");
            require(button("Split to Layers"), "RGB Split utility button missing");
        };
        open();
        const auto preview=upstream154journey::pixels(window);
        require(preview!=pixels, "RGB Split preview did not disperse the source");
        int redAhead=0,blueAhead=0,redBehind=0,blueBehind=0;
        for (int x=34;x<=41;++x) {
            redAhead+=uint8_t(preview[(30*61+x)*4]); blueAhead+=uint8_t(preview[(30*61+x)*4+2]);
        }
        for (int x=19;x<=26;++x) {
            redBehind+=uint8_t(preview[(30*61+x)*4]); blueBehind+=uint8_t(preview[(30*61+x)*4+2]);
        }
        require(redAhead>blueAhead*2 && blueBehind>redBehind*2, "RGB Split preview spectral direction is wrong");
        require(button("Cancel"), "RGB Split Cancel missing"); button("Cancel")->click();
        settle([&] { return !panel(); }, "RGB Split Cancel left its panel open");
        require(upstream154journey::pixels(window)==pixels, "RGB Split Cancel changed source pixels");
        open(); require(button("OK"), "RGB Split OK missing"); button("OK")->click();
        settle([&] { return !panel(); }, "RGB Split commit left its panel open");
        require(upstream154journey::pixels(window)==preview, "RGB Split preview and committed pixels differ");
        require(window.sendCommand({{"action","undo"}}), "RGB Split Undo command failed"); require(upstream154journey::pixels(window)==pixels, "RGB Split Undo did not restore original");
        require(window.sendCommand({{"action","redo"}}), "RGB Split Redo command failed"); require(upstream154journey::pixels(window)==preview, "RGB Split Redo did not restore effect");
        require(window.sendCommand({{"action","undo"}}), "RGB Split Undo command failed");
        open(); button("Split to Layers")->click();
        settle([&] { return !panel(); }, "Split to Layers left the filter open");
        const auto layers=window.sessionState().value("layers").toArray();
        require(layers.size()==5 && layers[0].toObject().value("isGroup").toBool(), "Split to Layers hierarchy is wrong");
        const QStringList names{"Alpha","Blue","Green","Red"};
        for (int i=0;i<4;++i) {
            const auto layer=layers[i+1].toObject();
            require(layer.value("name").toString()==names[i], "Split to Layers channel order is wrong");
            require(layer.value("parentID")==layers[0].toObject().value("id"), "Split to Layers channel parent is wrong");
        }
        require(window.sendCommand({{"action","undo"}}), "RGB Split Undo command failed");
        require(window.sessionState().value("layers")==original.value("layers") && upstream154journey::pixels(window)==pixels,
                "Split to Layers Undo did not restore original layer and pixels");
        require(window.sendCommand({{"action","redo"}}), "RGB Split Redo command failed"); require(window.sessionState().value("layers").toArray().size()==5, "Split to Layers Redo failed");
        qInfo("Qt RGB Split OK (spectral preview, Cancel, exact commit Undo/Redo, Split to Layers hierarchy and history)");
        return 0;
    } catch (const std::exception &error) {
        qCritical("Qt RGB Split failed: %s",error.what()); return 1;
    }
}
}
