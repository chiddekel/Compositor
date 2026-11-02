// The in-app updater against the real portal (T-17, scripts/test-flatpak-update-e2e.sh): run inside an installed
// Compositor sandbox, it builds FlatpakUpdateService exactly as the app does (/.flatpak-info, the session bus), presses
// "Check and Update" (installUpdate) and waits for ReadyToRestart. Prints the final status; exit 0 only when the
// portal installed an update. Relaunching is the app's own code, covered by test_flatpak_updates.
#include "FlatpakUpdateService.h"

#include <QApplication>
#include <QElapsedTimer>
#include <QTimer>
#include <cstdio>

int main(int argc, char **argv) {
    qputenv("QT_QPA_PLATFORM", "offscreen");
    QApplication app(argc, argv);
    // The app's own check, with the installed executable's path (this probe runs from elsewhere in the sandbox).
    qtplatform::FlatpakUpdateService updates(QStringLiteral("/.flatpak-info"), QStringLiteral("/app/bin/compositor"),
                                             QDBusConnection::sessionBus());
    if (!updates.isSupported()) { std::fprintf(stderr, "not inside the installed Compositor Flatpak\n"); return 2; }
    QTimer::singleShot(200, &app, [&updates] { updates.installUpdate(); });
    QElapsedTimer clock; clock.start();
    using Status = UpdateStatus;
    while (clock.elapsed() < 600000) {
        app.processEvents(QEventLoop::AllEvents, 100);
        const Status status = updates.status();
        if (status == Status::ReadyToRestart || status == Status::Error || status == Status::NoUpdate) break;
    }
    const auto info = updates.updateInfo();
    const char *names[] = {"Idle", "Checking", "UpdateAvailable", "NoUpdate", "Downloading", "ReadyToRestart", "Error", "Unsupported"};
    std::printf("status %s running %s local %s remote %s %s\n", names[int(updates.status())], qPrintable(info.runningCommit),
                qPrintable(info.localCommit), qPrintable(info.remoteCommit), qPrintable(updates.errorMessage()));
    return updates.status() == Status::ReadyToRestart ? 0 : 1;
}
