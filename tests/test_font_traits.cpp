#include "../host/QtTextFont.h"
#include "../host/CompositorUIFont.h"
#include <QGuiApplication>
#include <QFontInfo>
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

int main(int argc, char **argv) {
    QGuiApplication app(argc, argv);
    installCompositorUIFont(app);
    try {
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
        std::puts("Qt named-font traits OK (PostScript, full name, Qt face alias, opaque native token)");
        std::puts("Qt font traits OK (all weights, semibold before bold, fixed pitch, tabular digits, italic)");
        std::puts("Qt Inter metrics and rendering OK (18 native macOS reference cases, fractional spacing and wrapping)");
        return 0;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "Qt font traits failed: %s\n", error.what());
        return 1;
    }
}
