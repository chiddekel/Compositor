#pragma once

#include <QDir>
#include <QString>
#include <QUrl>

namespace qtplatform {

inline QString localFilePath(QString input) {
    if (!input.startsWith(QStringLiteral("file:"), Qt::CaseInsensitive)) return input;
    QUrl url(input, QUrl::StrictMode);
    if (!url.isValid() || !url.isLocalFile() || url.hasQuery() || url.hasFragment()) return {};
    if (!url.host().isEmpty()) {
        if (url.host().compare(QStringLiteral("localhost"), Qt::CaseInsensitive) != 0) return {};
        url.setHost(QString());
    }
    const QString path = url.toLocalFile();
    return !path.isEmpty() && QDir::isAbsolutePath(path) ? path : QString();
}

} // namespace qtplatform
