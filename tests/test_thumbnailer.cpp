#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QImage>
#include <QImageReader>
#include <QProcess>
#include <QTemporaryDir>
#include <QUrl>

#include <cstdio>
#include <stdexcept>

static void require(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
}

int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    try {
        require(argc == 2, "expected thumbnailer executable argument");
        const QString executable = QString::fromLocal8Bit(argv[1]);
        QTemporaryDir directory;
        require(directory.isValid(), "temporary directory unavailable");
        const QString package = directory.filePath(QString::fromUtf8("Zażółć # % zdjęcie.comp"));
        require(QDir().mkpath(package + "/QuickLook"), "preview directory creation failed");
        const QString jpeg = package + "/QuickLook/Preview.jpg";
        const QString png = package + "/QuickLook/Preview.png";
        QImage source(320, 160, QImage::Format_RGB32);
        source.fill(Qt::red);
        for (int y = 0; y < source.height(); ++y)
            for (int x = 160; x < source.width(); ++x) source.setPixelColor(x, y, Qt::blue);
        require(source.save(jpeg, "JPEG", 95), "JPEG fixture encoding failed");
        QFile preview(jpeg);
        require(preview.open(QIODevice::ReadOnly), "JPEG fixture unreadable");
        const auto original = preview.readAll();
        preview.close();
        int invocation = 0;
        const auto run = [&](const QString &input, const QString &size, bool success, int expectedWidth, int expectedHeight) {
            const QString output = directory.filePath(QString("thumbnail-%1.png").arg(++invocation));
            QStringList arguments{input, output};
            if (!size.isEmpty()) arguments.append(size);
            QProcess process;
            process.start(executable, arguments);
            require(process.waitForStarted(5000) && process.waitForFinished(10000), "thumbnailer process did not finish");
            require(process.exitStatus() == QProcess::NormalExit, "thumbnailer crashed");
            require((process.exitCode() == 0) == success, "thumbnailer returned unexpected success/failure");
            if (!success) {
                require(!QFile::exists(output), "failed thumbnailer wrote an output image");
                return;
            }
            QImageReader reader(output);
            require(reader.format() == "png", "thumbnail was not PNG");
            const auto image = reader.read();
            require(!image.isNull() && image.width() == expectedWidth && image.height() == expectedHeight,
                    "thumbnail dimensions/aspect ratio incorrect");
            const auto left = image.pixelColor(image.width() / 4, image.height() / 2);
            const auto right = image.pixelColor(image.width() * 3 / 4, image.height() / 2);
            require(left.red() > 240 && left.blue() < 15 && right.blue() > 240 && right.red() < 15,
                    "thumbnail did not preserve preview content");
        };
        run(package, "96", true, 96, 48);
        run(QUrl::fromLocalFile(package).toString(QUrl::FullyEncoded), "", true, 128, 64);
        auto localhost = QUrl::fromLocalFile(package);
        localhost.setHost("localhost");
        run(localhost.toString(QUrl::FullyEncoded), "64", true, 64, 32);
        for (const QString &invalid : {QString("file:"), QString("file:relative.comp"),
                                      QString("file://remote.example/project.comp"),
                                      QUrl::fromLocalFile(package).toString(QUrl::FullyEncoded) + "?query",
                                      QUrl::fromLocalFile(package).toString(QUrl::FullyEncoded) + "#fragment",
                                      QUrl::fromLocalFile(package).toString(QUrl::FullyEncoded) + "/%GG"})
            run(invalid, "64", false, 0, 0);
        require(preview.open(QIODevice::ReadOnly) && preview.readAll() == original, "thumbnailer modified the source preview");
        preview.close();
        require(QFile::rename(jpeg, jpeg + ".held"), "could not hold JPEG fixture");
        require(source.save(png, "PNG"), "PNG fixture encoding failed");
        run(package, "64", true, 64, 32);
        require(QFile::rename(png, png + ".held"), "could not hold PNG fixture");
        run(package, "64", false, 0, 0);
        QFile corrupt(jpeg);
        require(corrupt.open(QIODevice::WriteOnly) && corrupt.write("invalid JPEG") == 12, "corrupt fixture write failed");
        corrupt.close();
        run(package, "64", false, 0, 0);
        run(directory.filePath("missing.comp"), "64", false, 0, 0);
        std::puts("Qt thumbnailer OK (JPEG/PNG, size/aspect/content, Unicode path/file URI, unchanged source, missing/corrupt preview refusal)");
        return 0;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "Qt thumbnailer failed: %s\n", error.what());
        return 1;
    }
}
