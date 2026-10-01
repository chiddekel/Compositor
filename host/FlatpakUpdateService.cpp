#include "FlatpakUpdateService.h"

#include <QApplication>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDialog>
#include <QDialogButtonBox>
#include <QLabel>
#include <QProcess>
#include <QProgressBar>
#include <QPushButton>
#include <QSettings>
#include <QTimer>
#include <QUuid>
#include <QVBoxLayout>
#include <utility>

namespace qtplatform {
namespace {
const QString service = QStringLiteral("org.freedesktop.portal.Flatpak");
const QString portalPath = QStringLiteral("/org/freedesktop/portal/Flatpak");
const QString monitorInterface = QStringLiteral("org.freedesktop.portal.Flatpak.UpdateMonitor");
}

FlatpakUpdateService::FlatpakUpdateService(QObject *parent)
    : FlatpakUpdateService(QStringLiteral("/.flatpak-info"), QApplication::applicationFilePath(),
                           QDBusConnection::sessionBus(), parent) {}

FlatpakUpdateService::FlatpakUpdateService(const QString &infoPath, const QString &executable,
                                         const QDBusConnection &bus, QObject *parent)
    : QObject(parent), m_bus(bus), m_supported(isInstalledApplication(infoPath, executable)) {
    if (m_supported) QTimer::singleShot(0, this, [this] { ensureMonitor(); });
    else m_status = UpdateStatus::Unsupported;
}

FlatpakUpdateService::~FlatpakUpdateService() {
    closeMonitor();
    delete m_dialog;
}

bool FlatpakUpdateService::isInstalledApplication(const QString &infoPath, const QString &executable) {
    QSettings info(infoPath, QSettings::IniFormat);
    return executable == QLatin1String("/app/bin/compositor")
        && info.value(QStringLiteral("Application/name")).toString() == QLatin1String("com.compositor.Client")
        && !info.value(QStringLiteral("Instance/app-commit")).toString().isEmpty();
}

void FlatpakUpdateService::subscribe(const QString &path, bool connect) {
    for (const auto &pair : {std::pair{"UpdateAvailable", SLOT(onUpdateAvailable(QVariantMap))},
                            std::pair{"Progress", SLOT(onProgress(QVariantMap))}}) {
        if (connect) m_bus.connect(service, path, monitorInterface, QLatin1String(pair.first), this, pair.second);
        else m_bus.disconnect(service, path, monitorInterface, QLatin1String(pair.first), this, pair.second);
    }
}

void FlatpakUpdateService::ensureMonitor() {
    if (!m_supported || m_creating || !m_monitorPath.isEmpty()) return;
    if (!m_bus.isConnected()) { fail(tr("The Flatpak update service is unavailable.")); return; }
    m_creating = true;
    const QString token = QStringLiteral("compositor_") + QUuid::createUuid().toString(QUuid::Id128);
    QString sender = m_bus.baseService().mid(1);
    sender.replace('.', '_');
    const QString path = portalPath + QStringLiteral("/update_monitor/") + sender + '/' + token;
    // Subscribe before requesting the monitor, so an immediate update signal is not lost.
    m_monitorPath = path;
    subscribe(path, true);
    QDBusMessage message = QDBusMessage::createMethodCall(service, portalPath, service, QStringLiteral("CreateUpdateMonitor"));
    message << QVariantMap{{QStringLiteral("handle_token"), token}};
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(message, 10000), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, watcher, path] {
        QDBusPendingReply<QDBusObjectPath> reply = *watcher;
        watcher->deleteLater();
        m_creating = false;
        if (reply.isError()) { closeMonitor(); fail(reply.error().message()); return; }
        if (reply.value().path() != path) {
            closeMonitor();
            fail(tr("The Flatpak update service returned an unexpected monitor."));
            return;
        }
        if (m_installPending) beginUpdate();
        refreshDialog();
    });
}

void FlatpakUpdateService::closeMonitor() {
    if (m_monitorPath.isEmpty()) return;
    subscribe(m_monitorPath, false);
    m_bus.call(QDBusMessage::createMethodCall(service, m_monitorPath, monitorInterface, QStringLiteral("Close")), QDBus::NoBlock);
    m_monitorPath.clear();
}

void FlatpakUpdateService::fail(const QString &message) {
    m_installPending = false;
    m_error = message;
    m_status = UpdateStatus::Error;
    refreshDialog();
}

void FlatpakUpdateService::checkForUpdates(bool interactive) {
    if (m_supported) ensureMonitor();
    if (!interactive) return;
    if (!m_dialog) {
        m_dialog = new QDialog(QApplication::activeWindow());
        m_dialog->setAttribute(Qt::WA_DeleteOnClose);
        m_dialog->setWindowTitle(tr("Flatpak Updates"));
        m_dialog->setObjectName(QStringLiteral("flatpakUpdates"));
        auto *layout = new QVBoxLayout(m_dialog);
        m_label = new QLabel(m_dialog);
        m_label->setTextFormat(Qt::PlainText);
        m_label->setWordWrap(true);
        m_label->setMinimumWidth(380);
        layout->addWidget(m_label);
        m_progressBar = new QProgressBar(m_dialog);
        layout->addWidget(m_progressBar);
        auto *buttons = new QDialogButtonBox(QDialogButtonBox::Close, m_dialog);
        m_updateButton = buttons->addButton(tr("Check and Update"), QDialogButtonBox::ActionRole);
        m_restartButton = buttons->addButton(tr("Restart Now"), QDialogButtonBox::AcceptRole);
        connect(m_updateButton, &QPushButton::clicked, this, [this] { installUpdate(); });
        connect(m_restartButton, &QPushButton::clicked, this, [this] { restartNow(); });
        connect(buttons, &QDialogButtonBox::rejected, m_dialog, &QDialog::close);
        layout->addWidget(buttons);
    }
    refreshDialog();
    m_dialog->show();
    m_dialog->raise();
    m_dialog->activateWindow();
}

void FlatpakUpdateService::armRelaunch() {
    if (m_relaunchConnection) return;
    // Host launches the new Flatpak commit after this process has fully exited.
    m_relaunchConnection = connect(qApp, &QCoreApplication::aboutToQuit, this, [] {
        QProcess::startDetached(QStringLiteral("flatpak-spawn"), {
            QStringLiteral("--host"),
            QStringLiteral("sh"),
            QStringLiteral("-c"),
            QStringLiteral("sleep 1; exec flatpak run com.compositor.Client"),
        });
    });
}

void FlatpakUpdateService::disarmRelaunch() {
    if (!m_relaunchConnection) return;
    disconnect(m_relaunchConnection);
    m_relaunchConnection = {};
}

void FlatpakUpdateService::restartNow() {
    if (!m_supported || m_status != UpdateStatus::ReadyToRestart) return;
    if (m_dialog) m_dialog->hide();
    armRelaunch();
    for (QWidget *widget : QApplication::topLevelWidgets()) {
        if (!widget->isWindow() || !widget->isVisible() || widget == m_dialog.data()) continue;
        if (!widget->close()) {
            // Save/quit cancelled — stay on the installed update and show the dialog again.
            disarmRelaunch();
            if (m_dialog) {
                m_dialog->show();
                refreshDialog();
            }
            return;
        }
    }
}

void FlatpakUpdateService::installUpdate() {
    if (!m_supported || m_installPending || m_status == UpdateStatus::Downloading
        || m_status == UpdateStatus::ReadyToRestart) return;
    m_installPending = true;
    m_error.clear();
    m_status = UpdateStatus::Checking;
    ensureMonitor();
    if (!m_creating && !m_monitorPath.isEmpty()) beginUpdate();
    refreshDialog();
}

void FlatpakUpdateService::beginUpdate() {
    m_installPending = false;
    m_progress = 0;
    m_status = UpdateStatus::Downloading;
    QDBusMessage message = QDBusMessage::createMethodCall(service, m_monitorPath, monitorInterface, QStringLiteral("Update"));
    QString parentWindow;
    if (m_dialog && QApplication::platformName() == QLatin1String("xcb"))
        parentWindow = QStringLiteral("x11:%1").arg(qulonglong(m_dialog->winId()), 0, 16);
    message << parentWindow << QVariantMap();
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(message), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, watcher] {
        QDBusPendingReply<> reply = *watcher;
        watcher->deleteLater();
        if (reply.isError() && m_status == UpdateStatus::Downloading) {
            closeMonitor();
            fail(reply.error().message());
        }
    });
    refreshDialog();
}

void FlatpakUpdateService::onUpdateAvailable(const QVariantMap &info) {
    if (!m_supported) return;
    m_info.runningCommit = info.value(QStringLiteral("running-commit")).toString();
    m_info.localCommit = info.value(QStringLiteral("local-commit")).toString();
    m_info.remoteCommit = info.value(QStringLiteral("remote-commit")).toString();
    if (m_status == UpdateStatus::Downloading || m_installPending) return;
    if (!m_info.runningCommit.isEmpty() && !m_info.localCommit.isEmpty() && m_info.localCommit != m_info.runningCommit)
        m_status = UpdateStatus::ReadyToRestart;
    else if (!m_info.runningCommit.isEmpty() && !m_info.remoteCommit.isEmpty() && m_info.remoteCommit != m_info.runningCommit)
        m_status = UpdateStatus::UpdateAvailable;
    else if (!m_info.runningCommit.isEmpty() && m_info.remoteCommit == m_info.runningCommit)
        m_status = UpdateStatus::NoUpdate;
    else m_status = UpdateStatus::Idle;
    refreshDialog();
}

void FlatpakUpdateService::onProgress(const QVariantMap &info) {
    if (!m_supported || m_status != UpdateStatus::Downloading) return;
    const uint status = info.value(QStringLiteral("status")).toUInt();
    // Flatpak's terminal states are Empty=1, Done=2, Failed=3. A completed
    // individual operation (progress=100, status=0) is not a completed update.
    if (status == 0) {
        const uint operations = qMax(1u, info.value(QStringLiteral("n_ops"), 1u).toUInt());
        const uint operation = qMin(operations - 1, info.value(QStringLiteral("op")).toUInt());
        m_progress = int((100.0 * operation + qMin(100u, info.value(QStringLiteral("progress")).toUInt())) / operations);
    } else if (status == 1) {
        m_status = !m_info.localCommit.isEmpty() && m_info.localCommit != m_info.runningCommit
            ? UpdateStatus::ReadyToRestart : UpdateStatus::NoUpdate;
    } else if (status == 2) m_status = UpdateStatus::ReadyToRestart;
    else if (status == 3) {
        fail(info.value(QStringLiteral("error_message"), info.value(QStringLiteral("error"), tr("The update could not be installed."))).toString());
        return;
    }
    refreshDialog();
}

void FlatpakUpdateService::refreshDialog() {
    if (!m_dialog) return;
    QString text;
    switch (m_status) {
    case UpdateStatus::Unsupported:
        text = tr("This copy was not installed as the Compositor Flatpak. Install the Flatpak release to receive updates here."); break;
    case UpdateStatus::Idle:
        text = tr("Check for Flatpak updates and install any available update. Your open documents will stay open."); break;
    case UpdateStatus::Checking: text = tr("Connecting to the Flatpak update service…"); break;
    case UpdateStatus::UpdateAvailable: text = tr("A Compositor update is available. You can install it while keeping your documents open."); break;
    case UpdateStatus::NoUpdate: text = tr("No update was available at the last check."); break;
    case UpdateStatus::Downloading: text = tr("Checking for and installing updates…"); break;
    case UpdateStatus::ReadyToRestart:
        text = tr("The update is installed. Save your work, then restart Compositor to use it."); break;
    case UpdateStatus::Error:
        text = tr("The update could not be completed. %1\n\nYou can also update Compositor in your software center or run:\nflatpak update com.compositor.Client").arg(m_error); break;
    }
    m_label->setText(text);
    const bool busy = m_status == UpdateStatus::Checking || m_status == UpdateStatus::Downloading;
    m_progressBar->setVisible(busy);
    m_progressBar->setRange(0, m_progress > 0 ? 100 : 0);
    m_progressBar->setValue(m_progress);
    m_updateButton->setText(m_status == UpdateStatus::UpdateAvailable ? tr("Install Update") : tr("Check and Update"));
    m_updateButton->setVisible(m_supported && m_status != UpdateStatus::ReadyToRestart);
    m_updateButton->setEnabled(!busy);
    if (m_restartButton) {
        m_restartButton->setVisible(m_supported && m_status == UpdateStatus::ReadyToRestart);
        m_restartButton->setEnabled(m_status == UpdateStatus::ReadyToRestart);
    }
}

} // namespace qtplatform
