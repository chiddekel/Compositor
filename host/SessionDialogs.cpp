#include "SessionWindow.h"
#include "EditorDialogs.h"
#include <QMessageBox>

void SessionWindow::showSizeDialog(bool imageSize) {
    const QJsonObject state = sessionState();
    if (state.value("busy").toBool() || state.value("width").toInt() <= 0) return;
    SizeDialog dialog(state, imageSize, this);
    // Failed allocation/validation leaves the dialog open and the document intact.
    while (dialog.exec() == QDialog::Accepted) {
        if (sendCommand(dialog.command())) { refreshImage(); return; }
        QMessageBox::warning(&dialog, tr("Resize failed"), sessionState().value("error").toString());
    }
}

void SessionWindow::showFilterDialog(const QString &kind) {
    if (!sendCommand({{"action", "filterBegin"}, {"kind", kind}})) return;
    FilterDialog dialog(kind, [this](const QJsonObject &command) {
        const bool ok = sendCommand(command);
        refreshImage();
        return ok;
    }, this);
    dialog.exec();
}
