// Normal-entry bridge probe; the contract runner supplies the built Swift host.
#include <QCoreApplication>
#include <QColor>
#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QList>
#include <QMap>
#include <QProcess>
#include <QProcessEnvironment>
#include <QTemporaryDir>
#include <QStringList>
#include <QUuid>
#include <QDebug>
#include <stdexcept>

static void require(bool ok, const char *message) {
    if (!ok) throw std::runtime_error(message);
}

static QByteArray digest(const QString &path) {
    QFile file(path); require(file.open(QIODevice::ReadOnly), "fixture read failed");
    return QCryptographicHash::hash(file.readAll(), QCryptographicHash::Sha256);
}

int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    QTemporaryDir temporary;
    try {
        require(argc == 2 && temporary.isValid(), "usage: group_rotation_probe COMPOSITOR_BINARY");
        const QString package = temporary.filePath("source.comp");
        require(QDir().mkpath(package + "/images"), "fixture directory failed");
        const auto uuid = [] { return QUuid::createUuid().toString(QUuid::WithoutBraces).toUpper(); };
        const QString redID = uuid(), blueID = uuid(), greenID = uuid();
        const QStringList ids{redID, blueID, greenID};
        const QList<QPoint> origins{{8, 12}, {34, 20}, {48, 48}};
        const QList<QSize> sizes{{8, 12}, {6, 10}, {8, 8}};
        QList<QImage> assets;
        QJsonArray records;
        for (int i = 0; i < 3; ++i) {
            QImage image(sizes[i], QImage::Format_RGBA8888);
            for (int y = 0; y < image.height(); ++y) for (int x = 0; x < image.width(); ++x)
                image.setPixelColor(x, y, QColor(i == 0 ? 180 + x * 5 : 20 + x * 3,
                    i == 2 ? 180 + y * 5 : 20 + y * 3, i == 1 ? 180 + y * 5 : 30 + x + y));
            require(image.save(package + "/images/" + ids[i] + ".png"), "fixture PNG failed");
            assets.append(image);
            records.append(QJsonObject{{"id", ids[i]}, {"name", QString("Source %1").arg(i)},
                {"imageFile", ids[i] + ".png"}, {"isVisible", true}, {"isGroup", false},
                {"opacity", 1}, {"blendMode", "Normal"}, {"transform", QJsonObject{
                    {"origin", QJsonArray{origins[i].x(), origins[i].y()}},
                    {"size", QJsonArray{sizes[i].width(), sizes[i].height()}}, {"rotation", 0},
                    {"flipX", false}, {"flipY", false}, {"sampling", "Nearest"}}}});
        }
        const QJsonObject manifest{{"format", "com.compositor.project"}, {"version", 11}, {"colorSpace", "sRGB"},
            {"documentID", uuid()}, {"width", 64}, {"height", 64}, {"resolution", 72},
            {"activeLayerID", blueID}, {"layers", records}};
        QFile file(package + "/manifest.json"); require(file.open(QIODevice::WriteOnly), "manifest open failed");
        require(file.write(QJsonDocument(manifest).toJson()) > 0, "manifest write failed"); file.close();
        QMap<QString, QByteArray> sourceDigests;
        sourceDigests.insert("manifest.json", digest(package + "/manifest.json"));
        for (const auto &id : ids) sourceDigests.insert("images/" + id + ".png", digest(package + "/images/" + id + ".png"));
        const auto oracle = [&](int angle) {
            QImage image(64, 64, QImage::Format_RGBA8888); image.fill(Qt::transparent);
            for (int i = 0; i < assets.size(); ++i) for (int y = 0; y < assets[i].height(); ++y)
                for (int x = 0; x < assets[i].width(); ++x) {
                    const int sx = origins[i].x() + x, sy = origins[i].y() + y;
                    int dx = sx, dy = sy;
                    // Selected bounds [8,12]-[40,30], shared center (24,21).
                    if (i < 2 && angle == 90) { dx = 44 - sy; dy = sx - 3; }
                    if (i < 2 && angle == -90) { dx = sy + 3; dy = 44 - sx; }
                    if (i < 2 && angle == 180) { dx = 47 - sx; dy = 41 - sy; }
                    require(image.rect().contains(dx, dy), "oracle outside canvas");
                    image.setPixelColor(dx, dy, assets[i].pixelColor(x, y));
                }
            return image;
        };
        const QImage original = oracle(0);
        for (bool folder : {false, true}) for (int angle : {90, -90, 180}) {
            const QString root = temporary.filePath(QString("%1-%2").arg(folder).arg(angle));
            require(QDir().mkpath(root), "case directory failed");
            QStringList commands;
            const auto command = [&](QJsonObject value) {
                commands.append(QString::fromUtf8(QJsonDocument(value).toJson(QJsonDocument::Compact)));
            };
            const auto exportPNG = [&](const QString &name) {
                command({{"action", "exportPNG"}, {"paths", QJsonArray{root + "/" + name + ".png"}}});
            };
            command({{"action", "selectLayer"}, {"layerID", redID}});
            command({{"action", "selectLayer"}, {"layerID", blueID}, {"enabled", true}});
            if (folder) command({{"action", "groupSelectedLayers"}});
            exportPNG("before");
            command({{"action", "transformBegin"}});
            command({{"action", "transformPreview"}, {"parameters", QJsonObject{{"rotation", angle}}}});
            command({{"action", "transformCancel"}}); exportPNG("cancel");
            command({{"action", "transformBegin"}});
            command({{"action", "transformPreview"}, {"parameters", QJsonObject{{"rotation", angle}}}});
            command({{"action", "transformCommit"}}); exportPNG("commit");
            command({{"action", "undo"}}); exportPNG("undo");
            command({{"action", "redo"}}); exportPNG("redo");
            for (const auto &id : ids) command({{"action", "selectLayer"}, {"layerID", id}});
            auto environment = QProcessEnvironment::systemEnvironment();
            for (const auto &key : environment.keys()) if (key.startsWith("COMPOSITOR_GRAB_")) environment.remove(key);
            environment.insert("XDG_CONFIG_HOME", root + "/config");
            environment.insert("XDG_DATA_HOME", root + "/data");
            environment.insert("COMPOSITOR_GRAB_PATH", root + "/window.png");
            environment.insert("COMPOSITOR_GRAB_STATE_PATH", root + "/startup.json");
            environment.insert("COMPOSITOR_GRAB_TOOL", "move");
            environment.insert("COMPOSITOR_GRAB_COMMAND", commands.join(';'));
            QProcess process; process.setProcessEnvironment(environment); process.setProcessChannelMode(QProcess::MergedChannels);
            process.start(QString::fromLocal8Bit(argv[1]), {package});
            require(process.waitForStarted(5000), "normal application did not start");
            const bool finished = process.waitForFinished(30000);
            if (!finished) { process.kill(); process.waitForFinished(5000); }
            const auto output = process.readAll();
            QFile log(root + "/process.log"); if (log.open(QIODevice::WriteOnly)) log.write(output);
            require(finished && process.exitStatus() == QProcess::NormalExit && process.exitCode() == 0,
                "normal application rotation run failed");
            require(!output.contains("Compositor command refused"), "rotation command was refused");
            QFile startup(root + "/startup.json"); require(startup.open(QIODevice::ReadOnly), "startup state missing");
            const auto state = QJsonDocument::fromJson(startup.readAll()).object();
            require(state.value("width").toInt() == 64 && state.value("layers").toArray().size() == 3,
                "rotation fixture did not load");
            for (const auto &name : {QString("before"), QString("cancel"), QString("commit"), QString("undo"), QString("redo")}) {
                const QImage actual(root + "/" + name + ".png");
                const QImage expected = name == "commit" || name == "redo" ? oracle(angle) : original;
                require(actual.size() == expected.size(), "rotation readback missing or wrong dimensions");
                for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) if (actual.pixelColor(x, y) != expected.pixelColor(x, y)) {
                    qWarning() << "rotation pixel mismatch" << folder << angle << name << x << y
                        << actual.pixelColor(x, y) << expected.pixelColor(x, y);
                    throw std::runtime_error("rotation pixels differ from independent shared-center oracle");
                }
            }
            for (auto it = sourceDigests.cbegin(); it != sourceDigests.cend(); ++it)
                require(digest(package + "/" + it.key()) == it.value(), "rotation modified a source package file");
            qInfo("Qt group rotation bridge OK (folder=%d angle=%d; unequal sizes/origins, independent all-pixel shared-center oracle, unselected isolation, Cancel and single Undo/Redo, original layer IDs and source-file hashes)", int(folder), angle);
        }
        return 0;
    } catch (const std::exception &error) {
        temporary.setAutoRemove(false);
        qCritical("Qt group rotation bridge failed: %s; artifacts: %s", error.what(), qPrintable(temporary.path()));
        return 1;
    }
}
