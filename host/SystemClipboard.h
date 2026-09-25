#pragma once

// The desktop clipboard for upstream's NSPasteboard.general (Sources/LinuxBridge/SystemClipboard.swift): Apple type
// identifiers in, MIME types on QClipboard out, and a count of the changes other applications made (AppKit's
// changeCount moves for those too, which is how upstream tells its own copy from someone else's).

#include <QApplication>
#include <QBuffer>
#include <QClipboard>
#include <QImage>
#include <QMimeData>
#include <QUrl>
#include <cstdint>
#include <cstring>

extern "C" void compositor_set_system_clipboard(
    void (*write)(int32_t, const char *const *, const uint8_t *const *, const intptr_t *),
    int64_t (*types)(char *, intptr_t), int64_t (*read)(const char *, uint8_t *, intptr_t), int64_t (*changes)());

namespace systemclipboard {

inline int64_t &externalChanges() { static int64_t count = 0; return count; }
inline bool &writing() { static bool flag = false; return flag; }

inline QString mimeFor(const QString &type) {
    if (type == QLatin1String("public.png")) return QStringLiteral("image/png");
    if (type == QLatin1String("public.tiff")) return QStringLiteral("image/tiff");
    if (type == QLatin1String("public.jpeg")) return QStringLiteral("image/jpeg");
    if (type == QLatin1String("public.utf8-plain-text")) return QStringLiteral("text/plain");
    if (type == QLatin1String("public.file-url")) return QStringLiteral("text/uri-list");
    return QStringLiteral("application/x-uti-") + type;   // this app's own types (a copied layer's id)
}

inline QByteArray bytesFor(const QString &type) {
    const QMimeData *mime = QApplication::clipboard()->mimeData();
    if (!mime) return {};
    const QString wanted = mimeFor(type);
    if (mime->hasFormat(wanted)) {
        QByteArray data = mime->data(wanted);
        if (type == QLatin1String("public.file-url")) data = data.split('\n').value(0).trimmed();
        return data;
    }
    // An image another application copied in some other format (a browser's, a screenshot tool's): as PNG/TIFF.
    if ((type == QLatin1String("public.png") || type == QLatin1String("public.tiff")) && mime->hasImage()) {
        const QImage image = qvariant_cast<QImage>(mime->imageData());
        QByteArray encoded;
        QBuffer buffer(&encoded);
        buffer.open(QIODevice::WriteOnly);
        image.save(&buffer, type == QLatin1String("public.png") ? "PNG" : "TIFF");
        return encoded;
    }
    if (type == QLatin1String("public.utf8-plain-text") && mime->hasText()) return mime->text().toUtf8();
    return {};
}

inline void install() {
    QObject::connect(QApplication::clipboard(), &QClipboard::dataChanged, QApplication::clipboard(), [] {
        if (!writing()) ++externalChanges();
    });
    compositor_set_system_clipboard(
        [](int32_t count, const char *const *types, const uint8_t *const *data, const intptr_t *lengths) {
            auto *mime = new QMimeData;
            for (int32_t i = 0; i < count; ++i) {
                const QString type = QString::fromUtf8(types[i]);
                const QByteArray bytes(reinterpret_cast<const char *>(data[i]), qsizetype(lengths[i]));
                mime->setData(mimeFor(type), bytes);
                // Applications that only take Qt's image type (or text) still get it.
                if (type == QLatin1String("public.png")) mime->setImageData(QImage::fromData(bytes, "PNG"));
                if (type == QLatin1String("public.utf8-plain-text")) mime->setText(QString::fromUtf8(bytes));
            }
            writing() = true;
            QApplication::clipboard()->setMimeData(mime);
            writing() = false;
        },
        [](char *out, intptr_t capacity) -> int64_t {
            const QMimeData *mime = QApplication::clipboard()->mimeData();
            QStringList types;
            if (mime) {
                for (const QString &format : mime->formats()) {
                    if (format == QLatin1String("image/png")) types << QStringLiteral("public.png");
                    else if (format == QLatin1String("image/tiff")) types << QStringLiteral("public.tiff");
                    else if (format == QLatin1String("image/jpeg")) types << QStringLiteral("public.jpeg");
                    else if (format == QLatin1String("text/uri-list")) types << QStringLiteral("public.file-url");
                    else if (format.startsWith(QLatin1String("application/x-uti-"))) types << format.mid(18);
                }
                if (mime->hasImage() && !types.contains(QStringLiteral("public.png"))) types << QStringLiteral("public.png");
                if (mime->hasText()) types << QStringLiteral("public.utf8-plain-text");
            }
            types.removeDuplicates();
            const QByteArray joined = types.join(QLatin1Char('\n')).toUtf8();
            if (out && capacity >= joined.size()) memcpy(out, joined.constData(), size_t(joined.size()));
            return joined.size();
        },
        [](const char *type, uint8_t *out, intptr_t capacity) -> int64_t {
            const QByteArray bytes = bytesFor(QString::fromUtf8(type));
            if (out && capacity >= bytes.size()) memcpy(out, bytes.constData(), size_t(bytes.size()));
            return bytes.size();
        },
        []() -> int64_t { return externalChanges(); });
}

} // namespace systemclipboard
