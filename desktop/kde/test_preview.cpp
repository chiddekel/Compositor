#include <KIO/ThumbnailCreator>
#include <KIO/PreviewJob>
#include <KFileItem>
#include <KPluginFactory>
#include <KPluginMetaData>
#include <QGuiApplication>
#include <QDir>
#include <QFile>
#include <QImage>
#include <QPixmap>
#include <QTemporaryDir>
#include <QEventLoop>
#include <QTimer>
#include <cstdlib>

static void require(bool value) { if (!value) std::abort(); }
int main(int argc, char **argv) {
    QGuiApplication app(argc, argv);
    auto result = KPluginFactory::instantiatePlugin<KIO::ThumbnailCreator>(KPluginMetaData(QString::fromLocal8Bit(argv[1])));
    require(bool(result));
    QTemporaryDir root;
    const QString package = root.path() + QString::fromUtf8("/Zażółć # %.comp");
    require(QDir().mkpath(package + "/QuickLook"));
    QImage image(320, 200, QImage::Format_RGB32);
    image.fill(Qt::red);
    require(image.save(package + "/QuickLook/Preview.png"));
    auto render = [&] { return result.plugin->create(KIO::ThumbnailRequest(QUrl::fromLocalFile(package), QSize(128, 128), "inode/directory", 1, 0)); };
    auto preview = render();
    require(preview.isValid() && preview.image().size() == QSize(128, 80));
    require(preview.image().pixelColor(20, 20) == QColor(Qt::red));
    if (argc > 2) {
        // Exercise the same MIME dispatch and out-of-process KIO worker that Dolphin uses.
        const QString pluginsRoot = QFileInfo(QString::fromLocal8Bit(argv[1])).absolutePath() + "/../..";
        QCoreApplication::addLibraryPath(pluginsRoot);
        qputenv("QT_PLUGIN_PATH", pluginsRoot.toUtf8());
        const QStringList enabled{QStringLiteral("acompositorpreview")};
        auto *job = KIO::filePreview(KFileItemList{KFileItem(QUrl::fromLocalFile(package))}, QSize(128,128), &enabled);
        job->setIgnoreMaximumSize(true);
        QEventLoop loop;
        QImage dispatched;
        QObject::connect(job, &KIO::PreviewJob::gotPreview, &loop, [&](const KFileItem &, const QPixmap &pixmap) { dispatched = pixmap.toImage(); });
        QObject::connect(job, &KJob::result, &loop, &QEventLoop::quit);
        QTimer::singleShot(15000, &loop, &QEventLoop::quit);
        loop.exec();
        require(!dispatched.isNull() && dispatched.pixelColor(20,20) == QColor(Qt::red));
    }
    image.fill(Qt::blue);
    require(image.save(package + "/QuickLook/Preview.png"));
    require(render().image().pixelColor(20, 20) == QColor(Qt::blue));
    require(QFile::remove(package + "/QuickLook/Preview.png"));
    require(!render().isValid());
    require(!result.plugin->create(KIO::ThumbnailRequest(QUrl("https://example.invalid/file.comp"), QSize(128,128), "inode/directory", 1, 0)).isValid());
    // Ordinary folders must take the actual KDE provider path, not the project decoder.
    require(QDir().mkpath(root.path() + "/ordinary"));
    auto normal = KPluginFactory::instantiatePlugin<KIO::ThumbnailCreator>(KPluginMetaData::findPluginById("kf6/thumbcreator", "directorythumbnail"));
    require(bool(normal));
    const KIO::ThumbnailRequest request(QUrl::fromLocalFile(root.path() + "/ordinary"), QSize(128,128), "inode/directory", 1, 0);
    require(result.plugin->create(request).isValid() == normal.plugin->create(request).isValid());
    delete normal.plugin;
    delete result.plugin;
}
