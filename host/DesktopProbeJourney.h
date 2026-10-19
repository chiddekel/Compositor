// Desktop integration through a real X server (T-15, scripts/test-desktop-dnd.sh): the app as one X client, a drag
// source and the clipboard tools as others, so drops arrive over XDND and the clipboard over X selections, not as
// synthesized Qt events. `CompositorHostBootstrap --combo-smoke --desktop-probe <work-dir>`.
//
// The driver script and this probe talk through files in <work-dir>: the probe writes targets.json (where the canvas
// and the header's empty area are on screen) and ready, then state.json whenever the documents change; the driver
// asks for clipboard steps with copy-request / paste-request (answered by copy-done / paste-done) and ends the run
// with finish.
#pragma once

#include "SessionWindow.h"
#include "SystemClipboard.h"

#include <QApplication>
#include <QClipboard>
#include <QElapsedTimer>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMimeData>
#include <QTabBar>
#include <QUrl>
#include <QWidget>

namespace desktopprobe {

inline void write(const QString &path, const QJsonObject &object) {
    QFile file(path + ".tmp");
    if (!file.open(QIODevice::WriteOnly)) return;
    file.write(QJsonDocument(object).toJson(QJsonDocument::Compact));
    file.close();
    QFile::remove(path);
    QFile::rename(path + ".tmp", path);
}

inline QJsonObject point(QWidget *widget) {
    if (!widget) return {};
    const QPoint centre = widget->mapToGlobal(widget->rect().center());
    return {{"x", centre.x()}, {"y", centre.y()}, {"width", widget->width()}, {"height", widget->height()}};
}

inline int run(QApplication &app) {
    const QStringList arguments = app.arguments();
    const int index = int(arguments.indexOf(QStringLiteral("--desktop-probe")));
    if (index < 0 || index + 1 >= arguments.size()) { qCritical("--desktop-probe needs a work directory"); return 2; }
    const QString work = arguments.at(index + 1);
    systemclipboard::install();   // as host_run does: NSPasteboard.general is the desktop clipboard
    SessionWindow window;
    window.setGeometry(0, 0, 1100, 760);
    window.show();
    QApplication::setActiveWindow(&window);
    for (int i = 0; i < 20; ++i) QApplication::processEvents(QEventLoop::AllEvents, 20);
    // A document on screen, as File › New makes it, with a background: files dropped on it come in as layers.
    window.createNewDocument(400, 300);
    if (window.sessionState().value("width").toInt() != 400) {
        qCritical("desktop probe: no document");
        return 1;
    }
    for (int i = 0; i < 20; ++i) QApplication::processEvents(QEventLoop::AllEvents, 20);
    auto *tabs = window.findChild<QTabBar *>(QStringLiteral("header.documentTabs"));
    const QJsonObject initial = window.sessionState();
    write(work + "/targets.json", {{"canvas", point(window.findChild<QWidget *>(QStringLiteral("editorCanvas")))},
                                   {"header", point(window.findChild<QWidget *>(QStringLiteral("header.dragArea")))},
                                   {"platform", QApplication::platformName()},
                                   {"initialLayers", initial.value("layers").toArray().size()},
                                   {"widgetAtCanvas", [&] {
                                        QWidget *canvas = window.findChild<QWidget *>(QStringLiteral("editorCanvas"));
                                        QWidget *hit = canvas ? QApplication::widgetAt(canvas->mapToGlobal(canvas->rect().center())) : nullptr;
                                        QStringList chain;
                                        for (QWidget *w = hit; w; w = w->parentWidget())
                                            chain << QString::fromLatin1(w->metaObject()->className()) + QLatin1Char(':') + w->objectName()
                                                         + (w->acceptDrops() ? QStringLiteral("[drops]") : QString());
                                        return chain.join(QStringLiteral(" < "));
                                    }()},
                                   {"initialWidth", initial.value("width")}, {"stateKeys", QJsonArray::fromStringList(initial.keys())}});
    QFile(work + "/ready").open(QIODevice::WriteOnly);

    QByteArray lastState;
    QElapsedTimer clock;
    clock.start();
    const auto exists = [&](const char *name) { return QFile::exists(work + "/" + name); };
    while (!exists("finish") && clock.elapsed() < 180000) {
        QApplication::processEvents(QEventLoop::AllEvents, 20);
        const QJsonObject current = window.sessionState();
        QJsonObject state{{"tabs", tabs ? tabs->count() : -1}, {"currentTab", tabs ? tabs->currentIndex() : -1},
                          {"handle", QString::number(window.sessionHandle())}, {"canSwitch", current.value("canSwitch")},
                          {"sheets", current.value("sheets")}, {"busy", current.value("busy")},
                          {"layers", current.value("layers").toArray().size()},
                          {"width", current.value("width")}, {"height", current.value("height")}};
        const QByteArray bytes = QJsonDocument(state).toJson(QJsonDocument::Compact);
        if (bytes != lastState) { write(work + "/state.json", state); lastState = bytes; }
        if (exists("import-request")) {
            // The same file the drags carry, imported directly: separates the drop's delivery from the import.
            QFile request(work + "/import-request");
            request.open(QIODevice::ReadOnly);
            const QString path = QString::fromUtf8(request.readAll()).trimmed();
            request.close();
            QFile::remove(work + "/import-request");
            const int before = window.sessionState().value("layers").toArray().size();
            const bool accepted = window.importImage(path);
            for (int i = 0; i < 100; ++i) QApplication::processEvents(QEventLoop::AllEvents, 20);
            const QJsonObject after = window.sessionState();
            write(work + "/import-done", {{"accepted", accepted}, {"layersBefore", before}, {"layersAfter", after.value("layers").toArray().size()},
                                          {"error", after.value("error")}, {"exists", QFile::exists(path)}});
        }
        if (exists("copy-request")) {
            QFile::remove(work + "/copy-request");
            // Edit › Select All, then Edit › Copy Merged, as a user does: the merged image goes to the clipboard.
            window.sendCommand({{"action", "selectAll"}});
            const bool copied = window.sendCommand({{"action", "copyMerged"}});
            for (int i = 0; i < 20; ++i) QApplication::processEvents(QEventLoop::AllEvents, 20);
            const QMimeData *mime = QApplication::clipboard()->mimeData();
            write(work + "/copy-done", {{"copied", copied}, {"formats", QJsonArray::fromStringList(mime ? mime->formats() : QStringList())},
                                        {"image", mime && mime->hasImage()}});
        }
        if (exists("paste-request")) {
            QFile::remove(work + "/paste-request");
            const int before = window.sessionState().value("layers").toArray().size();
            const bool pasted = window.sendCommand({{"action", "paste"}});
            for (int i = 0; i < 40; ++i) QApplication::processEvents(QEventLoop::AllEvents, 20);
            const int after = window.sessionState().value("layers").toArray().size();
            write(work + "/paste-done", {{"pasted", pasted}, {"layersBefore", before}, {"layersAfter", after},
                                         {"error", window.sessionState().value("error")}});
        }
    }
    return exists("finish") ? 0 : 1;
}

}  // namespace desktopprobe
