#include "../host/QtTextFont.h"
#include "../host/CompositorUIFont.h"
#include <QGuiApplication>
#include <QFontInfo>
#include <cstdio>
#include <stdexcept>

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
        std::puts("Qt named-font traits OK (PostScript, full name, Qt face alias, opaque native token)");
        std::puts("Qt font traits OK (all weights, semibold before bold, fixed pitch, tabular digits, italic)");
        return 0;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "Qt font traits failed: %s\n", error.what());
        return 1;
    }
}
