#include "../host/QtTextFont.h"
#include "../host/CompositorUIFont.h"
#include <QGuiApplication>
#include <QFontInfo>
#include <QFile>
#include <QFileInfo>
#include <QDir>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QPainter>
#include <QGlyphRun>
#include <QLibrary>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <stdexcept>

extern "C" int compositor_qt_font_metrics(const char *, double, double *, double *, double *);
extern "C" int32_t compositor_qt_text_layout_attributes(const char *, const char *, double, double, double, double,
                                                        const char *, double *, double *, double *);
extern "C" int32_t compositor_qt_text_render_attributes(const char *, const char *, double, double, double, double,
                                                        int32_t, double, double, double, double, double, const char *,
                                                        uint8_t **, int32_t *, int32_t *);
extern "C" int64_t compositor_qt_text_geometry_attributes(const char *, const char *, double, double, double, double,
                                                          int32_t, const char *, char *, size_t);

using TextRenderFn = decltype(&compositor_qt_text_render_attributes);

void checkNativeParagraphs(TextRenderFn renderer) {
    QFile file(QDir(QFileInfo(QString::fromUtf8(__FILE__)).absolutePath())
        .filePath("../Tests/Fixtures/text-paragraph-geometry-reference.json"));
    if (!file.open(QIODevice::ReadOnly)) throw std::runtime_error("missing native paragraph fixture");
    const auto cases = QJsonDocument::fromJson(file.readAll()).object().value("cases").toArray();
    if (cases.size() != 45) throw std::runtime_error("native paragraph recipe count");
    int paired = 0, fallback = 0, painted = 0;
    for (const auto &value : cases) {
        const auto sample = value.toObject();
        const auto require = [&](bool valid, const char *message) {
            if (!valid) throw std::runtime_error(sample.value("name").toString().toStdString() + ": " + message);
        };
        const QByteArray text = sample.value("text").toString().toUtf8(), face = sample.value("face").toString().toUtf8();
        const double size = sample.value("size").toDouble(), tracking = sample.value("tracking").toDouble();
        const double leading = sample.value("lineHeight").toDouble();
        const double width = sample.value("width").toDouble() >= 1e5 ? 0 : sample.value("width").toDouble();
        const int alignment = sample.value("alignment").toInt();
        const QJsonObject font{{"location", 0}, {"length", sample.value("utf16Length")}, {"font", sample.value("face")},
                               {"size", size}, {"kerning", false}};
        const QByteArray attributes = QJsonDocument(QJsonArray{font}).toJson(QJsonDocument::Compact);
        const auto count = compositor_qt_text_geometry_attributes(text.constData(), face.constData(), size, tracking,
            leading, width, alignment, attributes.constData(), nullptr, 0);
        require(count > 0 && count <= 1024 * 1024, "geometry size");
        QByteArray bytes(qsizetype(count), '\0');
        require(compositor_qt_text_geometry_attributes(text.constData(), face.constData(), size, tracking, leading, width,
            alignment, attributes.constData(), bytes.data(), size_t(bytes.size())) == count, "geometry read");
        const auto geometry = QJsonDocument::fromJson(bytes).object();
        const auto glyphs = geometry.value("glyphs").toArray(), lines = geometry.value("lines").toArray();
        const auto expected = sample.value("glyphs").toArray(), fallbackFonts = sample.value("nativeFallbacks").toArray();
        require(glyphs.size() == expected.size(), "glyph count");
        for (qsizetype i = 0; i < glyphs.size(); ++i) {
            const auto actual = glyphs[i].toObject(), native = expected[i].toObject();
            const int character = actual.value("character").toInt(), id = native.value("glyph").toInt();
            bool platformGlyph = false;
            for (const auto &entry : fallbackFonts) {
                const auto range = entry.toObject().value("range").toArray();
                platformGlyph |= character >= range[0].toInt() && character < range[0].toInt() + range[1].toInt();
            }
            require(character == native.value("characterIndex").toInt(), "UTF-16 character mapping");
            require(platformGlyph && id != 0 && id != 0x00FFFFFF ? actual.value("id").toInt() != 0
                    : actual.value("id").toInt() == id, "glyph identity or native null/control glyph");
            const int lineIndex = actual.value("line").toInt();
            require(lineIndex >= 0 && lineIndex < lines.size(), "line index");
            const auto line = lines[lineIndex].toObject();
            const auto range = native.value("effectiveRange").toArray();
            require(line.value("start").toInt() == range[0].toInt() && line.value("count").toInt() == range[1].toInt(),
                    "line glyph range");
            require(std::isfinite(actual.value("x").toDouble()) && std::isfinite(actual.value("y").toDouble()), "finite location");
            if (fallbackFonts.isEmpty()) {
                const auto position = native.value("location").toArray(), fragment = native.value("lineFragment").toArray();
                require(std::abs(actual.value("x").toDouble() - position[0].toDouble()) <= 4.0 / 64
                        && actual.value("y").toDouble() == position[1].toDouble(), "native glyph position");
                require(line.value("y").toDouble() == fragment[1].toDouble()
                        && line.value("height").toDouble() == fragment[3].toDouble(), "native line fragment");
            }
        }
        if (!fallbackFonts.isEmpty()) { ++fallback; continue; }
        ++paired;
        if (tracking == 0) continue;
        // Geometry above is checked against independent native positions. Painting
        // the same glyph IDs at those reported locations must agree with the ABI.
        const int variants = sample.value("name").toString() == QLatin1String("bidi-tracking") ? 2 : 1;
        for (int variant = 0; variant < variants; ++variant) {
            QJsonArray formats{font};
            if (variant == 1) {
                formats = {};
                for (const auto &part : {std::pair<int, int>{0, 2}, {2, 1}, {3, 1}, {4, 3}}) {
                    QJsonObject format = font;
                    format["location"] = part.first; format["length"] = part.second;
                    format["color"] = part.first == 2 ? QJsonArray{0, 1, 0, 1}
                        : part.first == 3 ? QJsonArray{0, 0, 1, 1} : QJsonArray{1, 0, 0, 1};
                    formats.append(format);
                }
            }
            const auto json = QJsonDocument(formats).toJson(QJsonDocument::Compact);
            uint8_t *pixels = nullptr; int32_t w = 0, h = 0;
            const int status = renderer(text.constData(), face.constData(), size, tracking, leading, width, alignment,
                width, 1, 1, 1, 1, json.constData(), &pixels, &w, &h);
            const std::unique_ptr<uint8_t, decltype(&std::free)> image(pixels, std::free);
            require(status == 0 && pixels && w > 0 && h > 0, "tracked raster render");
            QImage reference(w, h, QImage::Format_RGBA8888_Premultiplied);
            reference.fill(Qt::transparent);
            const double scale = size == std::round(size) ? 1 : 64;
            const QRawFont raw = QRawFont::fromFont(fontFor(face.constData(), size * scale));
            {
                QPainter painter(&reference);
                painter.setRenderHint(QPainter::TextAntialiasing);
                painter.scale(1 / scale, 1 / scale);
                for (const auto &entry : glyphs) {
                    const auto glyph = entry.toObject();
                    const int id = glyph.value("id").toInt(), character = glyph.value("character").toInt();
                    if (id == 0 || id == 0x00FFFFFF) continue;
                    painter.setPen(variant == 0 ? Qt::white : character == 2 ? Qt::green : character == 3 ? Qt::blue : Qt::red);
                    QGlyphRun run;
                    run.setRawFont(raw); run.setGlyphIndexes({quint32(id)});
                    const double y = lines[glyph.value("line").toInt()].toObject().value("y").toDouble() + glyph.value("y").toDouble();
                    run.setPositions({QPointF(glyph.value("x").toDouble() * scale, y * scale)});
                    painter.drawGlyphRun(QPointF(), run);
                }
            }
            int maximum = 0;
            for (int y = 0; y < h; ++y) for (int x = 0; x < w * 4; ++x)
                maximum = std::max(maximum, std::abs(int(reference.constScanLine(y)[x]) - int(pixels[y * w * 4 + x])));
            if (maximum > 1) std::fprintf(stderr, "%s paint variant %d maximum %d\n", sample.value("name").toString().toUtf8().constData(), variant, maximum);
            require(maximum <= 1, "tracked painting differs from reported glyph positions");
            ++painted;
        }
    }
    if (paired != 44 || fallback != 1) throw std::runtime_error("native paired/fallback paragraph coverage");
    const QByteArray partialColor = R"([{"location":6,"length":1,"font":"Inter-Regular","size":12.5,"kerning":false,"color":[1,0,0,1]}])";
    uint8_t *pixels = nullptr; int32_t w = 0, h = 0;
    const int status = renderer("A\u202EBC\u202C Ω\nAg Ω", "Inter-Regular", 12.5, 1.25, 0, 0, 0, 0,
        1, 1, 1, 1, partialColor.constData(), &pixels, &w, &h);
    const std::unique_ptr<uint8_t, decltype(&std::free)> image(pixels, std::free);
    if (status != 0 || !pixels || w <= 0 || h != 30) throw std::runtime_error("partial-color paragraph render");
    size_t coverage = 0;
    for (int y = 15; y < h; ++y) for (int x = 0; x < w; ++x) {
        const auto *pixel = pixels + (y * w + x) * 4;
        coverage += pixel[3];
        if (pixel[0] != pixel[3] || pixel[1] != pixel[3] || pixel[2] != pixel[3])
            throw std::runtime_error("plain paragraph inherited tracked paragraph's partial color");
    }
    if (!coverage) throw std::runtime_error("plain paragraph after tracked text is empty");
    ++painted;
    std::printf("Qt native paragraphs OK (%d paired-font layouts, %d platform-fallback mapping, %d tracked raster comparisons)\n", paired, fallback, painted);
}

int main(int argc, char **argv) {
    QGuiApplication app(argc, argv);
    installCompositorUIFont(app);
    try {
        std::unique_ptr<QLibrary> alternate;
        TextRenderFn paragraphRenderer = compositor_qt_text_render_attributes;
        if (argc == 3 && QByteArray(argv[1]) == "--renderer") {
            alternate = std::make_unique<QLibrary>(QString::fromUtf8(argv[2]));
            paragraphRenderer = reinterpret_cast<TextRenderFn>(alternate->resolve("compositor_qt_text_render_attributes"));
            if (!paragraphRenderer) throw std::runtime_error("alternate text renderer missing");
        }
        const std::pair<const char *, QFont::Weight> cases[] = {
            {"System-ultraLight", QFont::Thin}, {"System-thin", QFont::ExtraLight},
            {"System-light", QFont::Light}, {"System", QFont::Normal},
            {"System-medium", QFont::Medium}, {"System-semibold", QFont::DemiBold},
            {"System-bold", QFont::Bold}, {"System-heavy", QFont::ExtraBold}, {"System-black", QFont::Black},
            {"Helvetica-SemiboldOblique", QFont::DemiBold}
        };
        for (const auto &entry : cases)
            if (fontFor(entry.first, 13).weight() != entry.second) throw std::runtime_error(entry.first);
        const QFont digits = fontFor("System-semibold+monospacedDigit", 13);
        if (digits.weight() != QFont::DemiBold || digits.featureValue(QFont::Tag("tnum")) != 1)
            throw std::runtime_error("weighted tabular digits");
        const QFont mono = fontFor("Monospace-medium", 13);
        if (mono.weight() != QFont::Medium || mono.styleHint() != QFont::Monospace)
            throw std::runtime_error("weighted fixed-pitch font");
        if (!fontFor("Helvetica-SemiboldOblique", 13).italic()) throw std::runtime_error("face italic trait");
        for (const char *name : {"DejaVuSansMono-BoldOblique", "DejaVu Sans Mono Bold Oblique", "DejaVu Sans Mono-Bold Oblique"}) {
            const QFont selected = fontFor(name, 17);
            if (QFontInfo(selected).family() != QStringLiteral("DejaVu Sans Mono")
                || selected.weight() != QFont::Bold || !selected.italic() || selected.pixelSize() != 17)
                throw std::runtime_error(name);
        }
        for (const char *name : {"Inter-SemiBold", "Inter SemiBold"}) {
            const QFont selected = fontFor(name, 17);
            if (QFontInfo(selected).family() != QStringLiteral("Inter") || selected.weight() != QFont::DemiBold)
                throw std::runtime_error(name);
        }
        if (QFontInfo(fontFor("System", 17)).family() != QFontInfo(QGuiApplication::font()).family())
            throw std::runtime_error("system text did not use the selected application font");
        const auto named = nativeFontForToken(QStringLiteral("native:17:DejaVuSansMono-BoldOblique"), QFont());
        if (!named || QFontInfo(*named).family() != QStringLiteral("DejaVu Sans Mono") || !named->italic()
            || named->weight() != QFont::Bold) throw std::runtime_error("native named font token");
        const QFont inherited(QStringLiteral("Sans Serif"), 12);
        if (nativeFontForToken(QStringLiteral("native:nan:DejaVu Sans"), inherited) != inherited)
            throw std::runtime_error("invalid named size did not preserve inherited font");
        // Native NSFont/NSString metrics from capture run 40111031733, using the bundled Inter files.
        struct NativeCase { const char *face; double size, width, height; };
        for (const NativeCase &entry : {
                NativeCase{"Inter-Regular", 12, 28.25390625, 15}, {"Inter-Regular", 24, 56.5078125, 29},
                {"Inter-Regular", 36, 84.76171875, 44}, {"Inter-Regular", 12.5, 29.43115234375, 15},
                {"Inter-Regular", 24.5, 57.68505859375, 30}, {"Inter-Regular", 36.5, 85.93896484375, 44},
                {"Inter-Bold", 12, 28.48828125, 15}, {"Inter-Bold", 24, 56.9765625, 29},
                {"Inter-Bold", 36, 85.46484375, 44}, {"Inter-Bold", 12.5, 29.67529296875, 15},
                {"Inter-Bold", 24.5, 58.16357421875, 30}, {"Inter-Bold", 36.5, 86.65185546875, 44},
                {"Inter-Light", 12, 27.796875, 15}, {"Inter-Light", 24, 55.59375, 29},
                {"Inter-Light", 36, 83.390625, 44}, {"Inter-Light", 12.5, 28.955078125, 15},
                {"Inter-Light", 24.5, 56.751953125, 30}, {"Inter-Light", 36.5, 84.548828125, 44}}) {
            double ascent = 0, descent = 0, leading = 0, width = 0, height = 0, baseline = 0;
            const QByteArray attributes = QStringLiteral("[{\"location\":0,\"length\":4,\"font\":\"%1\",\"size\":%2}]")
                .arg(QString::fromUtf8(entry.face)).arg(entry.size).toUtf8();
            if (compositor_qt_font_metrics(entry.face, entry.size, &ascent, &descent, &leading) != 1
                || compositor_qt_text_layout_attributes("Ag Ω", entry.face, entry.size, 0, 0, 0, attributes.constData(),
                                                        &width, &height, &baseline) != 0)
                throw std::runtime_error("fractional native text ABI failed");
            // Qt's layout coordinates have 1/64-pixel precision; allow one unit per glyph in the advance.
            if (std::abs(ascent - entry.size * 1984 / 2048) > 1.0 / 64
                || std::abs(descent + entry.size * 494 / 2048) > 1.0 / 64
                || std::abs(width - entry.width) > 4.0 / 64 || height != entry.height || leading != 0) {
                std::fprintf(stderr, "%s at %.2f: ascent %.6f, descent %.6f, advance %.6f (native %.6f), height %.6f\n",
                             entry.face, entry.size, ascent, descent, width, entry.width, height);
                throw std::runtime_error("fractional font metrics differ from the native reference");
            }
            uint8_t *pixels = nullptr;
            int32_t renderedWidth = 0, renderedHeight = 0;
            const int status = compositor_qt_text_render_attributes("Ag Ω", entry.face, entry.size, 0, 0, 0, 0, 0,
                1, 1, 1, 1, attributes.constData(), &pixels, &renderedWidth, &renderedHeight);
            const std::unique_ptr<uint8_t, decltype(&std::free)> image(pixels, std::free);
            if (status != 0 || !pixels || renderedWidth != std::ceil(width) || renderedHeight != entry.height)
                throw std::runtime_error("rendered text dimensions differ from measured native metrics");
            size_t coverage = 0;
            for (int i = 0; i < renderedWidth * renderedHeight; ++i) {
                coverage += pixels[i * 4 + 3];
                if (pixels[i * 4] != pixels[i * 4 + 3] || pixels[i * 4 + 1] != pixels[i * 4 + 3]
                    || pixels[i * 4 + 2] != pixels[i * 4 + 3])
                    throw std::runtime_error("fractional white text is not premultiplied RGBA");
            }
            if (!coverage) throw std::runtime_error("native text render is empty");
        }
        double width = 0, height = 0, baseline = 0;
        if (compositor_qt_text_layout_attributes("Ag Ω\nAg Ω", "Inter-Regular", 12.5, 0, 19.25, 0, "[]",
                                                &width, &height, &baseline) != 0 || height != 38.5)
            throw std::runtime_error("fractional layout lost explicit line height");
        if (compositor_qt_text_layout_attributes("Ag Ω", "Inter-Regular", 12.5, 0, 0, 18, "[]",
                                                &width, &height, &baseline) != 0 || height != 30 || width > 18)
            throw std::runtime_error("fractional layout lost its wrapping width");
        QFile reference(QDir(QFileInfo(QString::fromUtf8(__FILE__)).absolutePath())
            .filePath("../Tests/Fixtures/text-glyph-geometry-reference.json"));
        if (!reference.open(QIODevice::ReadOnly)) throw std::runtime_error("missing native glyph geometry fixture");
        const auto geometryCases = QJsonDocument::fromJson(reference.readAll()).object().value("cases").toArray();
        if (geometryCases.size() != 18) throw std::runtime_error("native glyph geometry recipe count");
        for (const auto &value : geometryCases) {
            const auto sample = value.toObject();
            const QByteArray face = sample.value("face").toString().toUtf8();
            const double size = sample.value("size").toDouble();
            const int64_t count = compositor_qt_text_geometry_attributes("Ag Ω", face.constData(), size, 0, 0, 0,
                                                                        0, "[]", nullptr, 0);
            if (count <= 0 || count > 1024 * 1024) throw std::runtime_error("native glyph geometry ABI size");
            QByteArray buffer(qsizetype(count), '\0');
            if (compositor_qt_text_geometry_attributes("Ag Ω", face.constData(), size, 0, 0, 0, 0, "[]",
                                                      buffer.data(), size_t(buffer.size())) != count)
                throw std::runtime_error("native glyph geometry ABI read");
            const auto geometry = QJsonDocument::fromJson(buffer).object();
            const auto actual = geometry.value("glyphs").toArray(), expected = sample.value("glyphs").toArray();
            const auto lines = geometry.value("lines").toArray();
            if (actual.size() != 4 || expected.size() != 4 || lines.size() != 1
                || lines[0].toObject().value("height").toDouble() != sample.value("lineHeight").toDouble())
                throw std::runtime_error("native glyph geometry dimensions");
            for (qsizetype i = 0; i < actual.size(); ++i) {
                const auto a = actual[i].toObject(), e = expected[i].toObject();
                const auto position = e.value("location").toArray();
                if (a.value("id").toInt() != e.value("glyph").toInt()
                    || a.value("character").toInt() != e.value("characterIndex").toInt()
                    || std::abs(a.value("x").toDouble() - position[0].toDouble()) > 4.0 / 64
                    || a.value("y").toDouble() != position[1].toDouble())
                    throw std::runtime_error("shaped glyph location differs from native geometry");
            }
            if (compositor_qt_text_geometry_attributes("Ag Ω", face.constData(), size, 0, 0, 0, 0, "[]",
                                                      buffer.data(), size_t(buffer.size() - 1)) != -1)
                throw std::runtime_error("glyph geometry accepted a short output buffer");
        }
        const auto geometryFor = [](const char *text, double wrapWidth = 0) {
            const auto count = compositor_qt_text_geometry_attributes(text, "Inter-Regular", 12.5, 0, 0, wrapWidth,
                                                                     0, "[]", nullptr, 0);
            if (count <= 0 || count > 1024 * 1024) throw std::runtime_error("control text geometry size");
            QByteArray buffer(qsizetype(count), '\0');
            if (compositor_qt_text_geometry_attributes(text, "Inter-Regular", 12.5, 0, 0, wrapWidth, 0, "[]",
                                                      buffer.data(), size_t(buffer.size())) != count)
                throw std::runtime_error("control text geometry read");
            return QJsonDocument::fromJson(buffer).object();
        };
        const auto multiline = geometryFor("Ag Ω\nAg Ω");
        const auto multilineGlyphs = multiline.value("glyphs").toArray(), multilineLines = multiline.value("lines").toArray();
        if (multilineGlyphs.size() != 9 || multilineLines.size() != 2
            || multilineGlyphs[4].toObject().value("id").toInt() != 0x00FFFFFF
            || multilineGlyphs[4].toObject().value("character").toInt() != 4
            || multilineLines[0].toObject().value("count").toInt() != 5
            || multilineLines[1].toObject().value("start").toInt() != 5
            || multilineLines[1].toObject().value("y").toDouble() != 15)
            throw std::runtime_error("newline glyph or line fragment range was lost");
        const auto unicodeGlyphs = geometryFor("A😀\nΩ").value("glyphs").toArray();
        const int characters[] = {0, 1, 2, 3, 4};
        if (unicodeGlyphs.size() != 5 || unicodeGlyphs[2].toObject().value("id").toInt() != 0)
            throw std::runtime_error("surrogate pair lost its native null glyph");
        for (qsizetype i = 0; i < unicodeGlyphs.size(); ++i)
            if (unicodeGlyphs[i].toObject().value("character").toInt() != characters[i])
                throw std::runtime_error("glyph character mapping is not UTF-16");
        const auto wrapped = geometryFor("Ag Ω", 18);
        if (wrapped.value("lines").toArray().size() != 2 || wrapped.value("glyphs").toArray().size() != 4) {
            std::fprintf(stderr, "Wrapped geometry: %s\n", QJsonDocument(wrapped).toJson(QJsonDocument::Compact).constData());
            throw std::runtime_error("glyph geometry ignored the wrapping width");
        }
        if (compositor_qt_text_geometry_attributes("Ag Ω", "Inter-Regular", 12, 0, 0, 0, 0, "invalid", nullptr, 0) != -1
            || compositor_qt_text_geometry_attributes("Ag Ω", "Inter-Regular", std::nan(""), 0, 0, 0, 0, "[]", nullptr, 0) != -1)
            throw std::runtime_error("glyph geometry accepted invalid attributes or font size");
        checkNativeParagraphs(paragraphRenderer);
        std::puts("Qt named-font traits OK (PostScript, full name, Qt face alias, opaque native token)");
        std::puts("Qt font traits OK (all weights, semibold before bold, fixed pitch, tabular digits, italic)");
        std::puts("Qt Inter metrics and rendering OK (18 native macOS reference cases, fractional spacing and wrapping)");
        std::puts("Qt shaped glyph geometry OK (18 native layouts and 72 glyphs, integer and fractional sizes)");
        return 0;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "Qt font traits failed: %s\n", error.what());
        return 1;
    }
}
