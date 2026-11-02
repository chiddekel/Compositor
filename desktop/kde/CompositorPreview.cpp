#include <KIO/ThumbnailCreator>
#include <KPluginFactory>
#include <KPluginMetaData>
#include <QFileInfo>
#include <QImageReader>
#include <QPointer>

class CompositorPreview : public KIO::ThumbnailCreator {
    Q_OBJECT
public:
    CompositorPreview(QObject *parent, const QVariantList &args) : KIO::ThumbnailCreator(parent, args) {}
    KIO::ThumbnailResult create(const KIO::ThumbnailRequest &request) override {
        const QString path = request.url().toLocalFile();
        const QFileInfo package(path);
        if (!request.url().isLocalFile()) return KIO::ThumbnailResult::fail();
        if (package.isDir() && !package.isSymLink() && package.suffix().compare("comp", Qt::CaseInsensitive) == 0) {
            if (QFileInfo(path + QStringLiteral("/QuickLook")).isSymLink()) return KIO::ThumbnailResult::fail();
            for (const QString &name : {QStringLiteral("Preview.jpg"), QStringLiteral("Preview.png")}) {
                const QString file = path + QStringLiteral("/QuickLook/") + name;
                const QFileInfo info(file);
                if (!info.isFile() || info.isSymLink() || info.size() > 16 * 1024 * 1024) continue;
                QImageReader reader(file);
                reader.setAutoTransform(true);
                const QSize size = reader.size();
                if (!size.isValid() || qint64(size.width()) * size.height() > 200000000) continue;
                reader.setScaledSize(size.scaled(request.targetSize().boundedTo(QSize(1024, 1024)), Qt::KeepAspectRatio));
                QImage image = reader.read();
                if (!image.isNull()) return KIO::ThumbnailResult::pass(image);
            }
            return KIO::ThumbnailResult::fail();
        }
        // KIO selects one creator per MIME type. Delegate normal directories rather than hiding their previews.
        if (!directory) {
            const auto metadata = KPluginMetaData::findPluginById(QStringLiteral("kf6/thumbcreator"), QStringLiteral("directorythumbnail"));
            directory = KPluginFactory::instantiatePlugin<KIO::ThumbnailCreator>(metadata, this).plugin;
        }
        return directory ? directory->create(request) : KIO::ThumbnailResult::fail();
    }
private:
    QPointer<KIO::ThumbnailCreator> directory;
};

K_PLUGIN_CLASS_WITH_JSON(CompositorPreview, "compositorpreview.json")
#include "CompositorPreview.moc"
