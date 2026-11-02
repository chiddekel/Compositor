#pragma once

#include "SessionWindow.h"
#include <QApplication>
#include <QColor>
#include <QDebug>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QProcess>
#include <QProcessEnvironment>
#include <QTemporaryDir>
#include <stdexcept>

namespace autosavejourney {
inline void require(bool ok, const char *message) {
    if (!ok) throw std::runtime_error(message);
}

inline QJsonObject readState(const QString &path) {
    QFile file(path); require(file.open(QIODevice::ReadOnly), "autosave process state missing");
    const auto json = QJsonDocument::fromJson(file.readAll());
    require(json.isObject(), "autosave process state is invalid"); return json.object();
}

inline void samePixels(const QImage &actual, const QImage &expected) {
    require(!actual.isNull() && actual.size() == expected.size(), "crash recovery changed raster dimensions");
    for (int y = 0; y < expected.height(); ++y) for (int x = 0; x < expected.width(); ++x)
        require(actual.pixelColor(x, y) == expected.pixelColor(x, y), "crash recovery changed a source pixel");
}

inline int writer(QApplication &app) {
    try {
        const int option = app.arguments().indexOf("--autosave-crash-writer");
        const QString root = app.arguments().value(option + 1), mode = app.arguments().value(option + 2);
        require(!root.isEmpty() && (mode == "committed" || mode == "gradient"), "autosave writer arguments missing");
        require(QDir().mkpath(root), "autosave writer directory unavailable");
        // Match the normal application entry point's QStandardPaths namespace.
        app.setApplicationName("Compositor"); app.setOrganizationName("Compositor");
        QImage image(64, 64, QImage::Format_RGBA8888); image.fill(Qt::transparent);
        for (int y = 10; y < 46; ++y) for (int x = 8; x < 41; ++x)
            image.setPixelColor(x, y, QColor(50 + x * 3, 20 + y * 4, 40));
        const QString input = root + "/input.png";
        require(image.save(input), "autosave writer fixture failed");
        SessionWindow window; window.show();
        require(window.importImage(input), "autosave writer import failed");
        require(window.sendCommand({{"action", "setPaletteColor"}, {"kind", "foreground"},
            {"parameters", QJsonObject{{"red", 0}, {"green", 0}, {"blue", 1}}}}), "autosave writer palette failed");
        require(window.sendCommand({{"action", "setBrushSettings"}, {"parameters", QJsonObject{
            {"diameter", 6}, {"hardness", 1}, {"opacity", 1}, {"smoothing", 0}}}}), "autosave writer brush settings failed");
        window.paintStroke(12, 30, 40, 30);
        require(window.sendCommand({{"action", "renameLayer"}, {"name", "Recovered source"}}), "autosave writer rename failed");
        require(window.exportPNG(root + "/expected.png"), "autosave writer source readback failed");
        if (mode == "gradient") {
            require(window.sendCommand({{"action", "gradientBegin"}, {"x", 4}, {"y", 4}})
                && window.sendCommand({{"action", "gradientMove"}, {"x", 48}, {"y", 50}})
                && window.sendCommand({{"action", "gradientEndDrag"}}), "autosave writer gradient setup failed");
            require(window.sessionState().value("gradientLine").toArray().size() == 4, "autosave writer gradient missing");
        }
        const auto before = window.sessionState();
        require(before.value("modified").toBool() && window.performAutosave(), "autosave writer did not finish its snapshot");
        const auto after = window.sessionState();
        for (const char *key : {"layers", "activeLayerID", "undoName", "redoName", "modified", "gradientLine"})
            require(after.value(key) == before.value(key), "autosave writer changed its live document or draft");
        QJsonObject state = after; state.insert("recoveryDirectory", window.autosaveDirectory());
        QFile file(root + "/expected.json"); require(file.open(QIODevice::WriteOnly), "autosave writer state failed");
        require(file.write(QJsonDocument(state).toJson()) > 0, "autosave writer state write failed"); file.close();
        qInfo("Qt autosave crash writer READY");
        // The parent kills this process after READY; no window/session destructor may clear its recovery.
        return app.exec();
    } catch (const std::exception &error) {
        qCritical("Qt autosave crash writer failed: %s", error.what()); return 1;
    }
}

inline int run(QApplication &) {
    try {
        QTemporaryDir temporary; require(temporary.isValid(), "crash recovery temporary directory unavailable");
        for (const QString &mode : {QString("committed"), QString("gradient")}) {
            const QString root = temporary.filePath(mode);
            auto environment = QProcessEnvironment::systemEnvironment();
            for (const auto &key : environment.keys()) if (key.startsWith("COMPOSITOR_GRAB_")) environment.remove(key);
            environment.insert("XDG_CONFIG_HOME", root + "/config");
            environment.insert("XDG_DATA_HOME", root + "/data");
            QProcess process; process.setProcessEnvironment(environment); process.setProcessChannelMode(QProcess::MergedChannels);
            process.start(QCoreApplication::applicationFilePath(), {"--combo-smoke", "--autosave-crash-writer", root, mode});
            require(process.waitForStarted(5000), "autosave crash writer did not start");
            QByteArray output; QElapsedTimer deadline; deadline.start();
            while (!output.contains("Qt autosave crash writer READY") && deadline.elapsed() < 15000
                   && process.state() != QProcess::NotRunning) {
                process.waitForReadyRead(250); output += process.readAll();
            }
            const bool ready = output.contains("Qt autosave crash writer READY");
            if (process.state() != QProcess::NotRunning) process.kill();
            const bool stopped = process.state() == QProcess::NotRunning || process.waitForFinished(5000);
            if (!ready) qWarning().noquote() << QString::fromUtf8(output + process.readAll());
            require(stopped, "autosave crash writer did not terminate");
            require(ready && process.exitStatus() == QProcess::CrashExit, "autosave writer did not cross a real process-crash boundary");
            qInfo("Qt autosave crash boundary OK (%s, QProcess kill/CrashExit after completed snapshot)", qPrintable(mode));
            const auto expected = readState(root + "/expected.json");
            const QImage pixels(root + "/expected.png"); require(!pixels.isNull(), "autosave expected pixels missing");
            const QString recovery = expected.value("recoveryDirectory").toString();
            require(recovery.startsWith(root + "/data/"), "autosave crash writer used another profile's recovery");
            const QString manifest = recovery + "/autosave.comp/manifest.json";
            require(QFile::exists(manifest), "process crash removed its completed recovery snapshot");
            const auto launch = [&](const QString &name, const QStringList &files, const QString &save, bool raster) {
                auto settings = environment;
                settings.insert("COMPOSITOR_GRAB_PATH", root + "/" + name + "-window.png");
                settings.insert("COMPOSITOR_GRAB_STATE_PATH", root + "/" + name + "-state.json");
                if (!save.isEmpty()) settings.insert("COMPOSITOR_GRAB_SAVE_PROJECT", save);
                if (raster) settings.insert("COMPOSITOR_GRAB_COMMAND", QString::fromUtf8(QJsonDocument(QJsonObject{
                    {"action", "exportPNG"}, {"paths", QJsonArray{root + "/" + name + ".png"}}}).toJson(QJsonDocument::Compact)));
                QProcess reader; reader.setProcessEnvironment(settings); reader.setProcessChannelMode(QProcess::MergedChannels);
                // No smoke flag: exercise the normal application's actual startup entry point.
                reader.start(QCoreApplication::applicationFilePath(), files);
                require(reader.waitForStarted(5000), "normal recovery launch did not start");
                const bool finished = reader.waitForFinished(30000);
                if (!finished) { reader.kill(); reader.waitForFinished(5000); }
                const auto text = reader.readAll();
                if (!finished || reader.exitStatus() != QProcess::NormalExit || reader.exitCode() != 0)
                    qWarning().noquote() << QString::fromUtf8(text.right(4096));
                require(finished && reader.exitStatus() == QProcess::NormalExit && reader.exitCode() == 0,
                    "normal recovery launch failed");
                return readState(root + "/" + name + "-state.json");
            };
            const auto recovered = launch("recovered", {}, {}, true);
            if (recovered.value("width") != expected.value("width"))
                qWarning() << "normal recovery startup dimensions" << recovered.value("width") << recovered.value("height");
            require(recovered.value("width") == expected.value("width") && recovered.value("height") == expected.value("height")
                && recovered.value("layers") == expected.value("layers"), "normal startup did not recover the autosaved document");
            require(recovered.value("modified").toBool() && recovered.value("windowTitle").toString().startsWith("Recovered")
                && recovered.value("gradientLine").toArray().isEmpty(), "recovery did not open unsaved committed content");
            samePixels(QImage(root + "/recovered.png"), pixels);
            require(QFile::exists(manifest), "recovery was removed before a user save");
            QImage extra(7, 5, QImage::Format_RGBA8888); extra.fill(QColor(20, 160, 70));
            const QString extraPath = root + "/extra.png"; require(extra.save(extraPath), "recovery startup input fixture failed");
            const auto alongside = launch("alongside", {extraPath}, {}, true);
            require(alongside.value("width").toInt() == 7 && alongside.value("height").toInt() == 5
                && alongside.value("tabs").toArray().contains(QJsonValue("Recovered")), "startup input replaced or hid the recovered project");
            samePixels(QImage(root + "/alongside.png"), extra);
            require(QFile::exists(manifest), "opening a different startup input removed recovery");
            const QString saved = root + "/saved.comp";
            const auto saving = launch("saved", {}, saved, true);
            require(saving.value("modified").toBool(), "recovery was marked saved before the actual user save");
            const auto savedManifest = readState(saved + "/manifest.json");
            const auto layers = savedManifest.value("layers").toArray();
            require(layers.size() == 1 && layers.first().toObject().value("id")
                == expected.value("layers").toArray().first().toObject().value("id"), "recovery save changed layer identity");
            samePixels(QImage(saved + "/images/" + layers.first().toObject().value("imageFile").toString()), pixels);
            require(!QFile::exists(manifest), "a successful user save left stale recovery");
            const auto clean = launch("clean", {}, {}, false);
            require(clean.value("width").toInt() == 0 && !clean.value("tabs").toArray().contains(QJsonValue("Recovered")),
                "a later startup reopened stale recovery after saving");
            qInfo("Qt autosave process recovery OK (%s, SIGKILL, normal startup, exact pixels/IDs, unsaved/no draft, startup file isolation, save cleanup and clean relaunch)", qPrintable(mode));
        }
        return 0;
    } catch (const std::exception &error) {
        qCritical("Qt autosave process recovery failed: %s", error.what()); return 1;
    }
}
} // namespace autosavejourney
