// Persistent fixtures for manual macOS <-> GNU/Linux package interchange.
#include "SessionWindow.h"
#include "compositor_host_run.h"
#include <QApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QImageReader>
#include <QJsonArray>
#include <QJsonDocument>
#include <QTemporaryDir>
#include <algorithm>
#include <stdexcept>

namespace {
void require(bool ok, const QString &message) {
    if (!ok) throw std::runtime_error(message.toStdString());
}

QJsonObject manifest(const QString &package) {
    QFile file(package + "/manifest.json");
    require(file.open(QIODevice::ReadOnly) && file.size() <= 4 * 1024 * 1024, "Cannot read bounded manifest: " + package);
    QJsonParseError error;
    const auto document = QJsonDocument::fromJson(file.readAll(), &error);
    require(error.error == QJsonParseError::NoError && document.isObject(), "Invalid manifest: " + package);
    return document.object();
}

void compareJSON(const QJsonValue &expected, const QJsonValue &actual, const QString &path) {
    require(expected.type() == actual.type(), "Metadata type changed at " + path);
    if (expected.isObject()) {
        const auto a = expected.toObject(), b = actual.toObject();
        require(a.keys() == b.keys(), "Metadata fields changed at " + path);
        for (auto it = a.begin(); it != a.end(); ++it) compareJSON(it.value(), b.value(it.key()), path + "/" + it.key());
    } else if (expected.isArray()) {
        const auto a = expected.toArray(), b = actual.toArray();
        require(a.size() == b.size(), "Metadata array length changed at " + path);
        for (int i = 0; i < a.size(); ++i) compareJSON(a.at(i), b.at(i), path + "/" + QString::number(i));
    } else require(expected == actual, "Metadata value changed at " + path);
}

QImage boundedImage(const QString &path) {
    QFileInfo file(path);
    require(file.isFile() && file.size() <= 512LL * 1024 * 1024, "Missing or oversized asset: " + path);
    QImageReader reader(path);
    const QSize size = reader.size();
    require(size.width() > 0 && size.height() > 0 && size.width() <= 30000 && size.height() <= 30000 &&
        qint64(size.width()) * size.height() <= 200000000, "Invalid or oversized image: " + path);
    QImageReader::setAllocationLimit(1024);
    auto image = reader.read();
    require(!image.isNull(), "Cannot decode image: " + path);
    return image;
}

void comparePixels(const QString &expected, const QString &actual, bool mask) {
    const auto format = mask ? QImage::Format_Grayscale8 : QImage::Format_RGBA8888_Premultiplied;
    const auto a = boundedImage(expected).convertToFormat(format);
    const auto b = boundedImage(actual).convertToFormat(format);
    require(a.size() == b.size(), "Asset dimensions changed: " + actual);
    int maxError = 0;
    const int bytes = a.width() * (mask ? 1 : 4);
    for (int y = 0; y < a.height(); ++y) for (int x = 0; x < bytes; ++x)
        maxError = std::max(maxError, std::abs(int(a.constScanLine(y)[x]) - int(b.constScanLine(y)[x])));
    // Mask coverage is exact; color assets allow one byte for premultiplication rounding.
    require(maxError <= (mask ? 0 : 1), "Decoded pixels changed (maximum channel error " + QString::number(maxError) + "): " + actual);
    qInfo("Pixels OK: %s (%dx%d, maximum error %d)", qPrintable(QFileInfo(actual).fileName()), a.width(), a.height(), maxError);
}

QString assetPath(const QString &package, const QString &name) {
    require(!name.isEmpty() && QFileInfo(name).fileName() == name && name != "." && name != ".." && !name.contains('\\'),
        "Unsafe asset filename: " + name);
    const QFileInfo images(package + "/images");
    require(!images.isSymLink(), "Images directory must not be a symlink");
    const QString directory = images.canonicalFilePath();
    const QString path = QFileInfo(package + "/images/" + name).canonicalFilePath();
    require(!directory.isEmpty() && !path.isEmpty() && QFileInfo(path).absolutePath() == directory, "Asset escapes images directory: " + name);
    return path;
}

void verify(const QString &original, const QString &roundtrip) {
    const auto a = manifest(original), b = manifest(roundtrip);
    compareJSON(a, b, "manifest");
    int assets = 0;
    for (const auto &value : a.value("layers").toArray()) {
        const auto layer = value.toObject();
        for (const auto *field : {"imageFile", "maskFile"}) {
            const auto name = layer.value(field).toString();
            if (name.isEmpty()) continue;
            comparePixels(assetPath(original, name), assetPath(roundtrip, name), QString(field) == "maskFile");
            ++assets;
        }
    }
    require(assets > 0, "Fixture contains no assets");
    qInfo("Interchange comparison OK: %d layers, %d assets; all manifest fields retained", a.value("layers").toArray().size(), assets);
}

void fixture(const QString &output) {
    require(!QFileInfo::exists(output), "Output already exists: " + output);
    require(QDir().mkpath(output), "Cannot create output directory");
    QTemporaryDir temporary;
    require(temporary.isValid(), "Cannot create temporary fixture directory");
    QImage background(1024, 640, QImage::Format_RGBA8888);
    for (int y = 0; y < background.height(); ++y) for (int x = 0; x < background.width(); ++x)
        background.setPixelColor(x, y, QColor(235 - y / 32, 239 - x / 64, 244 - y / 64));
    const QString backgroundPath = temporary.filePath("Background.png");
    require(background.save(backgroundPath), "Cannot create background");
    SessionWindow window;
    require(window.importImage(backgroundPath), "Cannot import background");
    const auto command = [&](const QJsonObject &value) {
        require(window.sendCommand(value), "Fixture command failed: " + value.value("action").toString());
        QApplication::processEvents();
    };
    QImage raster(260, 150, QImage::Format_RGBA8888);
    for (int y = 0; y < raster.height(); ++y) for (int x = 0; x < raster.width(); ++x)
        raster.setPixelColor(x, y, QColor(35 + x / 3, 110 + y / 2, 190, 80 + x / 2));
    const QString rasterPath = temporary.filePath("Translucent raster.png");
    require(raster.save(rasterPath), "Cannot create raster");
    command({{"action", "importFiles"}, {"paths", QJsonArray{rasterPath}}});
    command({{"action", "moveLayer"}, {"x", 310}, {"y", 170}});
    command({{"action", "setOpacity"}, {"value", 0.75}});
    command({{"action", "addRevealMask"}});
    command({{"action", "setMaskLinked"}, {"enabled", false}});
    command({{"action", "textBeginBox"}, {"x", 48}, {"y", 72}, {"width", 920}, {"height", 320}});
    const QString content = QString::fromUtf8("Compositor interchange\nMixed fonts + colors\nEmoji 😀 • combining é • Ω");
    const auto draft = window.sessionState().value("textDraft").toObject();
    auto style = NativeTextHistory::attributes(draft);
    style["content"] = content; style["fontName"] = "Helvetica"; style["fontSize"] = 42;
    style["tracking"] = 0.5; style["leading"] = 58;
    style["red"] = 0.08; style["green"] = 0.12; style["blue"] = 0.19;
    style["fontRuns"] = QJsonArray{QJsonObject{{"location", 0}, {"length", 10}, {"fontName", "Helvetica-Bold"}},
        QJsonObject{{"location", content.indexOf("Mixed")}, {"length", 5}, {"fontName", "Courier"}}};
    style["colorRuns"] = QJsonArray{QJsonObject{{"location", 4}, {"length", 12}, {"red", 0.75}, {"green", 0.12}, {"blue", 0.15}},
        QJsonObject{{"location", content.indexOf("fonts")}, {"length", 13}, {"red", 0.06}, {"green", 0.32}, {"blue", 0.75}}};
    command({{"action", "textRestore"}, {"draftID", draft.value("id")}, {"textStyle", style}, {"location", content.size()}, {"length", 0}});
    command({{"action", "textFinish"}});
    command({{"action", "renameLayer"}, {"name", "Editable mixed fonts and colors"}});
    command({{"action", "groupSelectedLayers"}});
    command({{"action", "renameLayer"}, {"name", "Masked text folder"}});
    command({{"action", "setOpacity"}, {"value", 0.9}});
    command({{"action", "addRevealMask"}});
    const QString project = output + "/original.comp";
    require(window.writeProjectPackage(project), "Cannot save fixture");
    // Nonuniform group coverage tests persisted mask pixels independently of text rasterization.
    const auto saved = manifest(project);
    bool wroteMask = false;
    for (const auto &value : saved.value("layers").toArray()) {
        const auto layer = value.toObject();
        if (!layer.value("isGroup").toBool()) continue;
        QImage mask(1024, 640, QImage::Format_Grayscale8);
        for (int y = 0; y < mask.height(); ++y) for (int x = 0; x < mask.width(); ++x)
            mask.scanLine(y)[x] = x < 800 ? 255 : 255 - (x - 800) / 2;
        require(mask.save(assetPath(project, layer.value("maskFile").toString())), "Cannot save folder mask");
        wroteMask = true;
    }
    require(wroteMask, "Fixture lacks masked folder");
    require(window.readProjectPackage(project), "Cannot reopen fixture");
    require(window.exportPNG(output + "/linux-reference.png"), "Cannot export fixture reference");
    require(window.writeProjectPackage(output + "/linux-resaved.comp"), "Cannot save Linux round trip");
    verify(project, output + "/linux-resaved.comp");
    qInfo("Interchange fixture ready: %s", qPrintable(output));
}
} // namespace

extern "C" int compositor_host_interchange(int argc, char **argv) {
    QApplication app(argc, argv);
    try {
        const auto args = app.arguments();
        const int flag = args.indexOf("--interchange");
        const auto parameters = args.mid(flag + 1);
        require(flag >= 0 && !parameters.isEmpty(), "Missing interchange operation");
        if (parameters[0] == "fixture" && parameters.size() == 2) fixture(QFileInfo(parameters[1]).absoluteFilePath());
        else if (parameters[0] == "verify" && (parameters.size() == 3 || parameters.size() == 5)) {
            verify(parameters[1], parameters[2]);
            if (parameters.size() == 5) comparePixels(parameters[3], parameters[4], false);
        } else if (parameters[0] == "roundtrip" && parameters.size() == 3) {
            require(!QFileInfo::exists(parameters[2]), "Output already exists: " + parameters[2]);
            SessionWindow window;
            require(window.readProjectPackage(parameters[1]), "Cannot open input package");
            require(window.writeProjectPackage(parameters[2]), "Cannot save output package");
            require(window.exportPNG(parameters[2] + ".png"), "Cannot export output reference");
            verify(parameters[1], parameters[2]);
        } else throw std::runtime_error("Usage: --interchange fixture NEW_DIRECTORY | roundtrip INPUT.comp NEW_OUTPUT.comp | verify ORIGINAL.comp RETURNED.comp [ORIGINAL.png RETURNED.png]");
        return 0;
    } catch (const std::exception &error) {
        qCritical("Interchange failed: %s", error.what());
        return 1;
    }
}
