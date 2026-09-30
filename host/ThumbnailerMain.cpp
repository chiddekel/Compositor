// compositor-thumbnailer — Freedesktop thumbnailer for .comp packages.
// Reads QuickLook/Preview.jpg written on save (macOS Quick Look twin) and
// scales it to the requested size as PNG for Nautilus/Dolphin/etc.

#include <QCoreApplication>
#include <QFileInfo>
#include <QImage>
#include <QImageReader>
#include <QUrl>

#include <cstdio>

static QString localPath(const QString &input) {
    if (input.startsWith(QLatin1String("file:")))
        return QUrl(input).toLocalFile();
    return input;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        std::fprintf(stderr, "usage: compositor-thumbnailer INPUT OUTPUT [SIZE]\n");
        return 1;
    }
    QCoreApplication app(argc, argv);
    const QString input = localPath(QString::fromLocal8Bit(argv[1]));
    const QString output = QString::fromLocal8Bit(argv[2]);
    const int size = argc > 3 ? qMax(16, QString::fromLocal8Bit(argv[3]).toInt()) : 128;

    QString preview = input + QStringLiteral("/QuickLook/Preview.jpg");
    if (!QFileInfo::exists(preview))
        preview = input + QStringLiteral("/QuickLook/Preview.png");
    if (!QFileInfo::exists(preview))
        return 1;

    QImageReader reader(preview);
    reader.setAutoTransform(true);
    QImage image = reader.read();
    if (image.isNull())
        return 1;
    image = image.scaled(size, size, Qt::KeepAspectRatio, Qt::SmoothTransformation);
    return image.save(output, "PNG") ? 0 : 1;
}
