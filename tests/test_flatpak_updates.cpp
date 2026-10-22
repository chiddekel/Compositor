#include "FlatpakUpdateService.h"
#include <QApplication>
#include <QCloseEvent>
#include <QDBusMessage>
#include <QDialog>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QFile>
#include <QSettings>
#include <QPushButton>
#include <QTemporaryDir>
#include <QThread>
#include <QTimer>
#include <cstdio>

static QDBusConnection serverBus() {
    return QDBusConnection::connectToBus(qEnvironmentVariable("COMPOSITOR_TEST_DBUS_ADDRESS"), "update-test-server");
}
static int failures = 0;
#define CHECK(value) do { if (!(value)) { std::fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #value); ++failures; } } while (0)
static bool until(const std::function<bool()> &predicate) {
    QElapsedTimer timer; timer.start();
    while (!predicate() && timer.elapsed() < 3000) { QApplication::processEvents(); QThread::msleep(1); }
    return predicate();
}

class RefuseCloseWindow : public QWidget {
public:
    int attempts = 0;
protected:
    void closeEvent(QCloseEvent *event) override { ++attempts; event->ignore(); }
};

static QDialog *updateDialog() {
    for (auto *widget : QApplication::topLevelWidgets())
        if (widget->objectName() == "flatpakUpdates") return qobject_cast<QDialog *>(widget);
    return nullptr;
}

static QPushButton *updateButton(QDialog *dialog, const QString &text) {
    if (dialog) for (auto *button : dialog->findChildren<QPushButton *>())
        if (button->text() == text) return button;
    return nullptr;
}

class Monitor : public QObject {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.freedesktop.portal.Flatpak.UpdateMonitor")
public:
    int updates = 0, closes = 0;
    bool reject = false;
public slots:
    void Update(const QString &, const QVariantMap &, const QDBusMessage &message) {
        ++updates;
        if (reject) {
            message.setDelayedReply(true);
            serverBus().send(message.createErrorReply(QStringLiteral("org.freedesktop.DBus.Error.NotSupported"),
                QStringLiteral("New permissions require the software center.")));
        }
    }
    void Close() { ++closes; }
signals:
    void UpdateAvailable(const QVariantMap &info);
    void Progress(const QVariantMap &info);
};

class Portal : public QObject {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.freedesktop.portal.Flatpak")
public:
    Monitor monitor;
    int creates = 0;
public slots:
    QDBusObjectPath CreateUpdateMonitor(const QVariantMap &options, const QDBusMessage &message) {
        ++creates;
        QString sender = message.service().mid(1); sender.replace('.', '_');
        QString path = "/org/freedesktop/portal/Flatpak/update_monitor/" + sender + '/' + options.value("handle_token").toString();
        CHECK(serverBus().registerObject(path, &monitor, QDBusConnection::ExportAllSlots | QDBusConnection::ExportAllSignals));
        return QDBusObjectPath(path);
    }
};

int main(int argc, char **argv) {
    if (qEnvironmentVariableIsEmpty("COMPOSITOR_TEST_DBUS_ADDRESS")) return 2;
    QApplication app(argc, argv);
    auto server = serverBus();
    // Run only with the private bus created by scripts/test-flatpak-updates.sh; never replace a real portal on the desktop.
    if (!server.registerService("org.freedesktop.portal.Flatpak")) return 2;
    Portal portal;
    CHECK(server.registerObject("/org/freedesktop/portal/Flatpak", &portal, QDBusConnection::ExportAllSlots));
    auto bus = QDBusConnection::connectToBus(qEnvironmentVariable("COMPOSITOR_TEST_DBUS_ADDRESS"), "update-test-client");
    QTemporaryDir directory;
    const QString file = directory.filePath("flatpak-info");
    auto writeInfo = [&](const QString &name, bool commit) {
        QSettings info(file, QSettings::IniFormat); info.clear();
        info.setValue("Application/name", name);
        if (commit) info.setValue("Instance/app-commit", "running");
        info.sync();
    };
    using qtplatform::FlatpakUpdateService;
    writeInfo("org.kde.Sdk", true);
    CHECK(!FlatpakUpdateService::isInstalledApplication(file, "/app/bin/compositor"));
    writeInfo("com.compositor.Client", false);
    CHECK(!FlatpakUpdateService::isInstalledApplication(file, "/app/bin/compositor"));
    writeInfo("com.compositor.Client", true);
    CHECK(!FlatpakUpdateService::isInstalledApplication(file, "/workspace/.build/release/CompositorHostBootstrap"));
    CHECK(!FlatpakUpdateService::isInstalledApplication(directory.filePath("missing"), "/app/bin/compositor"));
    for (const char *key : {"XCTestConfigurationFilePath", "XCTestBundlePath"}) {
        const bool wasSet = qEnvironmentVariableIsSet(key);
        const QByteArray previous = qgetenv(key);
        qputenv(key, "/dev/null");
        {
            FlatpakUpdateService testHost(file, "/app/bin/compositor", bus);
            QEventLoop loop;
            QTimer::singleShot(100, &loop, &QEventLoop::quit);
            loop.exec();
            CHECK(testHost.isSupported());
            CHECK(testHost.status() == UpdateStatus::Idle && portal.creates == 0);
        }
        if (wasSet) qputenv(key, previous); else qunsetenv(key);
    }
    {
        FlatpakUpdateService unsupported(file, "/workspace/compositor", bus);
        unsupported.installUpdate(); unsupported.checkForUpdates(false);
        QApplication::processEvents();
        CHECK(unsupported.status() == UpdateStatus::Unsupported && portal.creates == 0);
        unsupported.checkForUpdates(true);
        auto *dialog = updateDialog();
        CHECK(dialog && dialog->isVisible());
        auto *install = updateButton(dialog, "Check and Update");
        auto *restart = updateButton(dialog, "Restart Now");
        CHECK(install && !install->isVisible() && restart && !restart->isVisible());
        CHECK(portal.creates == 0);
    }
    {
        FlatpakUpdateService updater(file, "/app/bin/compositor", bus);
        updater.checkForUpdates(false);
        CHECK(updater.status() != UpdateStatus::NoUpdate); // No fabricated "latest version" result.
        CHECK(until([&] { return portal.creates == 1; }));
        updater.installUpdate(); updater.installUpdate();
        CHECK(until([&] { return portal.monitor.updates == 1; }));
        emit portal.monitor.Progress({{"status", 0u}, {"progress", 100u}, {"op", 0u}, {"n_ops", 2u}});
        QApplication::processEvents();
        CHECK(updater.status() == UpdateStatus::Downloading);
        emit portal.monitor.Progress({{"status", 1u}});
        CHECK(until([&] { return updater.status() == UpdateStatus::NoUpdate; }));
        emit portal.monitor.UpdateAvailable({{"running-commit", "a"}, {"local-commit", "a"}, {"remote-commit", "b"}});
        CHECK(until([&] { return updater.status() == UpdateStatus::UpdateAvailable; }));
        // Equal commits clear the previous available-update state.
        emit portal.monitor.UpdateAvailable({{"running-commit", "a"}, {"local-commit", "a"}, {"remote-commit", "a"}});
        CHECK(until([&] { return updater.status() == UpdateStatus::NoUpdate; }));
        updater.installUpdate();
        CHECK(until([&] { return portal.monitor.updates == 2; }));
        emit portal.monitor.Progress({{"status", 3u}, {"error", "PermissionDenied"}, {"error_message", "Permission was denied."}});
        CHECK(until([&] { return updater.status() == UpdateStatus::Error; }));
        CHECK(updater.errorMessage() == "Permission was denied.");
        portal.monitor.reject = true;
        updater.installUpdate();
        CHECK(until([&] { return updater.status() == UpdateStatus::Error; }));
        CHECK(updater.errorMessage().contains("New permissions"));
        portal.monitor.reject = false;
        updater.installUpdate();
        CHECK(until([&] { return portal.monitor.updates == 4; }));
        emit portal.monitor.Progress({{"status", 2u}});
        CHECK(until([&] { return updater.status() == UpdateStatus::ReadyToRestart; }));
        updater.installUpdate();
        QApplication::processEvents();
        CHECK(portal.monitor.updates == 4); // No second transaction and no forced app exit.
        // A refused document close must keep the installed update available without relaunching.
        RefuseCloseWindow document;
        document.show();
        updater.checkForUpdates(true);
        auto *dialog = updateDialog();
        auto *restart = updateButton(dialog, "Restart Now");
        CHECK(dialog && dialog->isVisible() && restart && restart->isVisible() && restart->isEnabled());
        if (restart) restart->click();
        CHECK(document.attempts == 1 && document.isVisible());
        CHECK(dialog && dialog->isVisible() && updater.status() == UpdateStatus::ReadyToRestart);
        CHECK(portal.monitor.updates == 4);
    }
    CHECK(until([&] { return portal.monitor.closes >= 1; }));
    server.unregisterService("org.freedesktop.portal.Flatpak");
    {
        FlatpakUpdateService unavailable(file, "/app/bin/compositor", bus);
        unavailable.installUpdate();
        CHECK(until([&] { return unavailable.status() == UpdateStatus::Error; }));
    }
    std::printf("Flatpak updater: %d failures\n", failures);
    return failures ? 1 : 0;
}
#include "test_flatpak_updates.moc"
