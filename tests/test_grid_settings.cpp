#include <QCoreApplication>
#include <QDebug>
#include <QFile>
#include <QProcess>
#include <QProcessEnvironment>
#include <QStringList>
#include <QTemporaryDir>

int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    QTemporaryDir profile;
    if (argc != 2 || !profile.isValid()) {
        qCritical("usage: test_grid_settings COMPOSITOR_BINARY"); return 1;
    }
    auto environment = QProcessEnvironment::systemEnvironment();
    for (const auto &key : environment.keys()) if (key.startsWith("COMPOSITOR_GRAB_")) environment.remove(key);
    environment.remove("XCTestConfigurationFilePath");
    environment.insert("XDG_CONFIG_HOME", profile.filePath("config"));
    environment.insert("XDG_DATA_HOME", profile.filePath("data"));
    for (bool restart : {false, true}) {
        QStringList arguments{"--combo-smoke", "--grid-settings-probe"};
        if (restart) arguments.append("--grid-settings-restart");
        QProcess process; process.setProcessEnvironment(environment); process.setProcessChannelMode(QProcess::MergedChannels);
        process.start(QString::fromLocal8Bit(argv[1]), arguments);
        const bool started = process.waitForStarted(5000);
        const bool finished = started && process.waitForFinished(30000);
        if (!finished && process.state() != QProcess::NotRunning) { process.kill(); process.waitForFinished(5000); }
        const auto output = process.readAll();
        QFile log(profile.filePath(restart ? "restart.log" : "controls.log"));
        if (log.open(QIODevice::WriteOnly)) log.write(output);
        const QByteArray marker = restart ? "Qt grid settings restart OK" : "Qt grid settings controls OK";
        if (!finished || process.exitStatus() != QProcess::NormalExit || process.exitCode() != 0 || !output.contains(marker)) {
            profile.setAutoRemove(false);
            qCritical().noquote() << QString::fromUtf8(output.right(4096));
            qCritical("Grid settings subprocess failed (restart=%d); artifacts: %s", int(restart), qPrintable(profile.path()));
            return 1;
        }
        qInfo().noquote() << QString::fromUtf8(output).split('\n').filter(QString::fromLatin1(marker)).join('\n');
    }
    return 0;
}
