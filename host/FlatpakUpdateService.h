#pragma once

#include "interfaces/IUpdateService.h"
#include <QDBusConnection>
#include <QDBusObjectPath>
#include <QObject>
#include <QPointer>

class QDialog;
class QLabel;
class QProgressBar;
class QPushButton;

namespace qtplatform {

// Updates only this installed Flatpak through its host portal. SDK/developer
// launches never request an SDK update or execute host shell commands.
class FlatpakUpdateService : public QObject, public IUpdateService {
    Q_OBJECT
public:
    explicit FlatpakUpdateService(QObject *parent = nullptr);
    FlatpakUpdateService(const QString &infoPath, const QString &executable,
                         const QDBusConnection &bus, QObject *parent = nullptr);
    ~FlatpakUpdateService() override;

    void checkForUpdates(bool interactive = true) override;
    void installUpdate() override;
    UpdateStatus status() const override { return m_status; }
    UpdateInfo updateInfo() const override { return m_info; }
    bool isSupported() const override { return m_supported; }
    QString errorMessage() const { return m_error; }
    static bool isInstalledApplication(const QString &infoPath, const QString &executable);

public slots:
    void onUpdateAvailable(const QVariantMap &info);
    void onProgress(const QVariantMap &info);

private:
    void ensureMonitor();
    void closeMonitor();
    void beginUpdate();
    void fail(const QString &message);
    void refreshDialog();
    void subscribe(const QString &path, bool connect);

    QDBusConnection m_bus;
    bool m_supported = false;
    bool m_creating = false;
    bool m_installPending = false;
    UpdateStatus m_status = UpdateStatus::Idle;
    UpdateInfo m_info;
    QString m_monitorPath, m_error;
    int m_progress = 0;
    QPointer<QDialog> m_dialog;
    QPointer<QLabel> m_label;
    QPointer<QProgressBar> m_progressBar;
    QPointer<QPushButton> m_updateButton;
};

} // namespace qtplatform
