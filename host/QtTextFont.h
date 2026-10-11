#pragma once

#include <QFont>
#include <QFontDatabase>
#include <QGuiApplication>
#include <QHash>
#include <QRawFont>
#include <optional>
#include <limits>
#include <QString>
#include <algorithm>
#include <cmath>

// Native text and lowered SwiftUI controls use the same weight ordering and PostScript face aliases.
inline QFont::Weight fontWeightForName(QString face) {
    face = face.toLower();
    if (face.contains(QLatin1String("black"))) return QFont::Black;
    if (face.contains(QLatin1String("heavy"))) return QFont::ExtraBold;
    if (face.contains(QLatin1String("semibold")) || face.contains(QLatin1String("demi"))) return QFont::DemiBold;
    if (face.contains(QLatin1String("bold"))) return QFont::Bold;
    if (face.contains(QLatin1String("medium"))) return QFont::Medium;
    if (face.contains(QLatin1String("ultralight"))) return QFont::Thin;
    if (face.contains(QLatin1String("thin"))) return QFont::ExtraLight;
    if (face.contains(QLatin1String("light"))) return QFont::Light;
    return QFont::Normal;
}

inline QString fontNameKey(QString name) {
    return name.remove(QLatin1Char(' ')).toCaseFolded();
}

// Resolve the names NSFont accepts from the installed faces' own name tables. Family/style strings alone
// cannot resolve PostScript names, full names, or families that contain hyphens.
inline const QHash<QString, QFont> &installedFontAliases() {
    static const QHash<QString, QFont> aliases = [] {
        QHash<QString, QFont> result;
        const auto add = [&](const QString &name, const QFont &font) {
            const QString key = fontNameKey(name);
            if (!key.isEmpty() && !result.contains(key)) result.insert(key, font);
        };
        for (const QString &family : QFontDatabase::families()) {
            add(family, QFontDatabase::font(family, QString(), 12));
            for (const QString &style : QFontDatabase::styles(family)) {
                const QFont font = QFontDatabase::font(family, style, 12);
                add(family + QLatin1Char('-') + style, font);
                const QByteArray table = QRawFont::fromFont(font).fontTable("name");
                const auto word = [&](qsizetype offset) -> unsigned {
                    return (unsigned(static_cast<unsigned char>(table[offset])) << 8)
                        | unsigned(static_cast<unsigned char>(table[offset + 1]));
                };
                if (table.size() < 6) continue;
                const unsigned count = word(2), strings = word(4);
                if (6 + qsizetype(count) * 12 > table.size()) continue;
                for (unsigned i = 0; i < count; ++i) {
                    const qsizetype record = 6 + qsizetype(i) * 12;
                    const unsigned platform = word(record), nameID = word(record + 6);
                    if (nameID != 4 && nameID != 6) continue;
                    const qsizetype length = word(record + 8), start = strings + word(record + 10);
                    if (start + length > table.size()) continue;
                    QString name;
                    if (platform == 0 || platform == 3) {
                        if (length % 2) continue;
                        for (qsizetype offset = start; offset < start + length; offset += 2)
                            name.append(QChar(ushort(word(offset))));
                    } else if (platform == 1) {
                        name = QString::fromLatin1(table.constData() + start, length);
                    }
                    add(name, font);
                }
            }
        }
        return result;
    }();
    return aliases;
}

// "Helvetica-BoldOblique" -> family Helvetica, bold, italic: how PostScript names carry the face.
inline QFont fontFor(const char *name, double pixelSize) {
    QString family = QString::fromUtf8(name ? name : "");
    const bool digits = family.endsWith(QLatin1String("+monospacedDigit"));
    if (digits) family.chop(int(QStringLiteral("+monospacedDigit").size()));
    QString face;
    const qsizetype dash = family.lastIndexOf('-');
    if (dash > 0) { face = family.mid(dash + 1).toLower(); family = family.left(dash); }
    const bool system = family.isEmpty() || family == QLatin1String("System") || family.startsWith('.');
    if (system) family = QStringLiteral("Sans Serif");
    std::optional<QFont> installed;
    if (qGuiApp && family != QLatin1String("Sans Serif") && family != QLatin1String("Monospace")) {
        const auto &aliases = installedFontAliases();
        const QString original = QString::fromUtf8(name ? name : "");
        auto match = aliases.constFind(fontNameKey(digits ? original.chopped(int(QStringLiteral("+monospacedDigit").size())) : original));
        if (match != aliases.constEnd()) installed = match.value();
    }
    QFont font = system && qGuiApp ? QGuiApplication::font() : installed.value_or(QFont(family));
    // NSFont.monospacedSystemFont: the desktop's fixed-pitch face.
    if (family == QLatin1String("Monospace")) {
        font = QFontDatabase::systemFont(QFontDatabase::FixedFont);
        font.setStyleHint(QFont::Monospace);
    }
    font.setPixelSize(std::max(1, int(std::lround(pixelSize))));
    if (!installed) font.setWeight(fontWeightForName(face));
    if (digits) font.setFeature(QFont::Tag("tnum"), 1);
    if (!installed && (face.contains(QLatin1String("italic")) || face.contains(QLatin1String("oblique")))) font.setItalic(true);
    return font;
}


// Named AppKit fonts travel as an opaque name after the size, preserving punctuation in the name.
inline std::optional<QFont> nativeFontForToken(const QString &token, const QFont &inherited) {
    if (!token.startsWith(QLatin1String("native:"))) return std::nullopt;
    const qsizetype separator = token.indexOf(QLatin1Char(':'), 7);
    bool valid = false;
    const double size = token.mid(7, separator - 7).toDouble(&valid);
    if (separator < 0 || !valid || !std::isfinite(size) || std::abs(size) >= std::numeric_limits<int>::max() - 1)
        return inherited;
    return fontFor(token.mid(separator + 1).toUtf8().constData(), size);
}
