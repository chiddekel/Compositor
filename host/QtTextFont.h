#pragma once

#include <QFont>
#include <QFontDatabase>
#include <QString>
#include <algorithm>
#include <cmath>

// "Helvetica-BoldOblique" -> family Helvetica, bold, italic: how PostScript names carry the face.
inline QFont fontFor(const char *name, double pixelSize) {
    QString family = QString::fromUtf8(name ? name : "");
    QString face;
    const qsizetype dash = family.lastIndexOf('-');
    if (dash > 0) { face = family.mid(dash + 1).toLower(); family = family.left(dash); }
    if (family.isEmpty() || family == QLatin1String("System") || family.startsWith('.')) family = QStringLiteral("Sans Serif");
    QFont font(family);
    // NSFont.monospacedSystemFont: the desktop's fixed-pitch face.
    if (family == QLatin1String("Monospace")) {
        font = QFontDatabase::systemFont(QFontDatabase::FixedFont);
        font.setStyleHint(QFont::Monospace);
    }
    font.setPixelSize(std::max(1, int(std::lround(pixelSize))));
    if (face.contains(QLatin1String("black")) || face.contains(QLatin1String("heavy"))) font.setWeight(QFont::Black);
    else if (face.contains(QLatin1String("bold"))) font.setWeight(QFont::Bold);
    else if (face.contains(QLatin1String("semibold")) || face.contains(QLatin1String("demi"))) font.setWeight(QFont::DemiBold);
    else if (face.contains(QLatin1String("medium"))) font.setWeight(QFont::Medium);
    else if (face.contains(QLatin1String("light"))) font.setWeight(QFont::Light);
    if (face.contains(QLatin1String("italic")) || face.contains(QLatin1String("oblique"))) font.setItalic(true);
    return font;
}

