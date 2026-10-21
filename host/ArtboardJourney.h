#pragma once
#include "SessionWindow.h"
#include "Upstream154Journey.h"
#include <QTabBar>
#include <QFileInfo>
#include <QFile>
#include <QLabel>
#include <QPushButton>
#include <QTimer>
#include <cstdlib>

namespace artboardjourney {
inline int runConversions(QApplication &) {
    try {
        using upstream154journey::require;
        using upstream154journey::settle;
        QTemporaryDir temporary;
        QFile source("tests/fixtures/artboards.psd");
        require(source.open(QIODevice::ReadOnly), "Artboard conversion fixture unavailable");
        auto bytes=source.readAll();
        const int blend=bytes.lastIndexOf("8BIMnorm",bytes.indexOf("Blue"));
        require(blend>=0, "Artboard conversion fixture has no Blue blend record");
        bytes.replace(blend+4,4,"diss"); // A real unsupported Photoshop blend on the second artboard.
        const QString path=temporary.filePath("artboard-conversions.psd");
        QFile fixture(path); require(fixture.open(QIODevice::WriteOnly) && fixture.write(bytes)==bytes.size(), "Artboard conversion fixture write failed");
        fixture.close();
        for (bool replace: {false,true}) for (bool accept: {false,true}) {
            SessionWindow window; window.resize(1200,900); window.show(); QApplication::setActiveWindow(&window);
            QApplication::processEvents(); window.createNewDocument(6,6);
            require(window.sendCommand({{"action","setOpacity"},{"value",0.5}}), "Artboard recovery fixture edit failed");
            auto *tabs=window.findChild<QTabBar *>("header.documentTabs"); require(tabs,"Artboard conversion tabs missing");
            const int originalIndex=tabs->currentIndex(), originalCount=tabs->count();
            const auto before=window.sessionState(); const auto beforePixels=upstream154journey::pixels(window);
            bool inspected=false; QString failure;
            QTimer inspector; inspector.setInterval(20);
            QObject::connect(&inspector,&QTimer::timeout,&window,[&] {
                auto *sheet=window.findChild<QDialog *>("swiftUISheet.PSDConversionSheet");
                if (!sheet || !sheet->isVisible() || inspected) return;
                QPushButton *import=nullptr,*cancel=nullptr;
                for (auto *button: sheet->findChildren<QPushButton *>()) if (button->isVisible()) {
                    if (button->text()=="Import") import=button;
                    if (button->text()=="Cancel") cancel=button;
                }
                if (!import || !import->isEnabled()) return;
                inspected=true; inspector.stop();
                QString text;
                for (auto *label: sheet->findChildren<QLabel *>()) text+=label->text()+"\n";
                if (!text.contains("Tablet") || !text.contains("Blue")) failure="Conversion sheet is bound to the wrong artboard";
                if (!cancel) { failure="Artboard conversion Cancel missing"; sheet->reject(); return; }
                (accept && failure.isEmpty()?import:cancel)->click();
            });
            QTimer watchdog; watchdog.setSingleShot(true);
            QObject::connect(&watchdog,&QTimer::timeout,&window,[] {
                qCritical("Qt PSD artboard conversion failed: the second artboard's prompt never completed");
                std::exit(1); // Fail this isolated test process rather than leave a hidden continuation hanging CI.
            });
            inspector.start(); watchdog.start(15000);
            const bool imported=window.sendCommand({{"action","importFiles"},{"paths",QJsonArray{path}},{"enabled",replace}});
            inspector.stop(); watchdog.stop();
            require(inspected && failure.isEmpty(),failure.isEmpty()?"Second artboard conversion sheet did not open":qPrintable(failure));
            require(imported==(!replace || accept),"Artboard conversion import result is wrong");
            const int expected=originalCount+(replace?(accept?1:0):2);
            settle([&] { return tabs->count()==expected; },"Artboard conversion left wrong native tabs");
            tabs->setCurrentIndex(originalIndex); QApplication::processEvents();
            if (!replace || !accept) {
                const auto after=window.sessionState();
                for (const char *field: {"width","height","layers","activeLayerID","modified","undoName","redoName"})
                    require(after.value(field)==before.value(field),"Artboard conversion changed the original document/history");
                require(upstream154journey::pixels(window)==beforePixels,"Artboard conversion changed original pixels");
            } else require(window.sessionState().value("width").toInt()==10,"Accepted replacement did not install Phone");
            if (!replace || accept) {
                const int tabletIndex=originalCount+(replace?0:1);
                tabs->setCurrentIndex(tabletIndex); QApplication::processEvents();
                require(window.sessionState().value("width").toInt()==(accept?12:0),"Artboard conversion answer reached the wrong tab");
            }
            qInfo("Qt PSD artboard conversion OK (replace=%d accept=%d, second-board prompt, original pixels/history and tab isolation)",replace,accept);
        }
        return 0;
    } catch (const std::exception &error) {
        qCritical("Qt PSD artboard conversion failed: %s",error.what()); return 1;
    }
}

inline int run(QApplication &) {
    try {
        using upstream154journey::require;
        using upstream154journey::settle;
        SessionWindow window; window.resize(1200,900); window.show(); QApplication::setActiveWindow(&window);
        QApplication::processEvents();
        auto *tabs=window.findChild<QTabBar *>("header.documentTabs");
        require(tabs, "Artboard native tab bar missing");
        const auto import=[&](bool replace) {
            const QString path=QFileInfo("tests/fixtures/artboards.psd").absoluteFilePath();
            require(window.sendCommand({{"action","importFiles"},{"paths",QJsonArray{path}},{"enabled",replace}}),
                    "Artboard native PSD import failed");
        };
        const auto verify=[&](int phone, int tablet) {
            settle([&] { return tabs->count()>tablet; }, "Artboard tabs did not reach the native shell");
            require(tabs->tabText(phone).startsWith("Phone") && tabs->tabText(tablet).startsWith("Tablet"),
                    "Artboard native tab names are wrong");
            for (const auto &entry: QList<QPair<int,QSize>>{{phone,{10,12}},{tablet,{12,14}}}) {
                tabs->setCurrentIndex(entry.first); QApplication::processEvents();
                const auto state=window.sessionState();
                require(state.value("width").toInt()==entry.second.width() && state.value("height").toInt()==entry.second.height(),
                        "Artboard native canvas dimensions are wrong");
                const auto layers=state.value("layers").toArray();
                require(layers.size()==1 && !layers[0].toObject().value("isGroup").toBool(), "Artboard kept its container or another board's layer");
                const bool first=entry.first==phone;
                require(layers[0].toObject().value("name").toString()==(first?"Red":"Blue"), "Artboard layer name is wrong");
                const auto bytes=upstream154journey::pixels(window);
                const int x=first?1:2, y=first?2:3;
                const int at=(y*entry.second.width()+x)*4;
                require(uint8_t(bytes[at+(first?0:2)])==255 && uint8_t(bytes[at+3])==255,
                        "Artboard pixels did not keep their artboard-relative placement");
            }
        };
        import(false); verify(0,1);
        // Replacement stages both artboards before touching the existing tab, then adopts its additional tab.
        tabs->setCurrentIndex(0); QApplication::processEvents();
        import(true); verify(0,2);
        require(tabs->count()==3, "Artboard replacement created an extra blank tab");
        qInfo("Qt PSD artboards OK (Open and atomic replacement, tab adoption/names, independent canvases and layer pixels)");
        return 0;
    } catch (const std::exception &error) {
        qCritical("Qt PSD artboards failed: %s",error.what()); return 1;
    }
}
}
