#pragma once

#include <QCoreApplication>
#include <QDir>
#include <QFont>
#include <QFontDatabase>

// Shared by the app and its native journeys, so measurement exercises the UI font the user sees.
template <typename Application>
void installCompositorUIFont(Application &app) {
    QString family;
    for (const QString &path : {QCoreApplication::applicationDirPath() + QStringLiteral("/../share/compositor/fonts"),
                               QDir::currentPath() + QStringLiteral("/third_party/fonts/inter")}) {
        const QDir dir(path);
        for (const QString &file : dir.entryList({QStringLiteral("Inter-*.ttf")}, QDir::Files)) {
            const int id = QFontDatabase::addApplicationFont(dir.filePath(file));
            if (id >= 0 && family.isEmpty() && !QFontDatabase::applicationFontFamilies(id).isEmpty())
                family = QFontDatabase::applicationFontFamilies(id).first();
        }
        if (!family.isEmpty()) break;
    }
    if (family.isEmpty()) {
        family = QFontDatabase::families().contains(QStringLiteral("Noto Sans")) ? QStringLiteral("Noto Sans")
            : QFontDatabase::systemFont(QFontDatabase::GeneralFont).family();
    }
    QFont ui(family);
    ui.setPixelSize(13);
    ui.setHintingPreference(QFont::PreferNoHinting);
    app.setFont(ui);
}
