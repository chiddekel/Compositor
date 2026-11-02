#include "NativeFilePanels.h"
#include <QApplication>
#include <QDialogButtonBox>
#include <QAbstractButton>
#include <QFile>
#include <QTemporaryDir>
#include <QTimer>
#include <QDebug>
#include <QLineEdit>
#include <QClipboard>
#include <QKeyEvent>
#include <QInputMethodEvent>
#include <QAbstractItemView>
#include <QItemSelectionModel>

int main(int argc, char **argv) {
    QTemporaryDir temp;
    if (!temp.isValid()) return 2;
    qputenv("XDG_CONFIG_HOME", temp.filePath("config").toUtf8());
    qputenv("XDG_DATA_HOME", temp.filePath("data").toUtf8());
    qputenv("XDG_CACHE_HOME", temp.filePath("cache").toUtf8());
    QApplication::setAttribute(Qt::AA_DontUseNativeDialogs);
    QApplication app(argc, argv);
    QWidget owner; owner.show();
    const QString image = temp.filePath(QString::fromUtf8("雪 image.png"));
    QFile file(image); if (!file.open(QIODevice::WriteOnly)) return 2; file.write("fixture"); file.close();
    const QString package = temp.filePath("existing.comp"); QDir().mkpath(package);
    QFile manifest(package + "/manifest.json"); if (!manifest.open(QIODevice::WriteOnly)) return 2; manifest.write("fixture"); manifest.close();
    const auto run = [&](bool save, bool project, bool cancel, bool shortBuffer, const QString &path) {
        QJsonObject options{{"save", save}, {"files", true}, {"directories", false}, {"multiple", false},
            {"extensions", QJsonArray{project ? "comp" : "png"}}, {"name", project ? "new.comp" : "Export.png"},
            {"title", "Owned file panel"}, {"message", ""}, {"createDirectories", true}, {"packagesAsDirectories", false}};
        const auto descriptor = QJsonDocument(options).toJson(QJsonDocument::Compact);
        bool valid = true, acted = false, submitted = false, replaced = false, expired = false; int dialogs = 0;
        QPointer<QFileDialog> seen;
        QTimer inspect; inspect.setInterval(10);
        QObject::connect(&inspect, &QTimer::timeout, [&] {
            for (auto *widget : QApplication::topLevelWidgets()) if (auto *question = qobject_cast<QMessageBox *>(widget)) {
                if (!question->isVisible()) continue;
                replaced = true; question->button(QMessageBox::Yes)->click(); return;
            }
            for (auto *widget : QApplication::topLevelWidgets()) if (auto *dialog = qobject_cast<QFileDialog *>(widget)) {
                if (!dialog->isVisible()) continue;
                if (seen != dialog) { ++dialogs; seen = dialog; }
                if (submitted) { if (dialogs > 1) { valid = false; static_cast<QDialog *>(dialog)->reject(); } return; }
                if (!acted && !cancel) {
                    // Initial directory loading can clear fileNameEdit after it becomes visible. Type only after
                    // the real fixture row is present, so a queued Open click cannot race that initialization.
                    if (dialog->viewMode() != QFileDialog::Detail) dialog->setViewMode(QFileDialog::Detail);
                    if (dialog->directory().absolutePath() != temp.path()) {
                        dialog->setDirectory(temp.path());
                        return;
                    }
                    auto *view = dialog->findChild<QAbstractItemView *>("treeView");
                    if (!view) return;
                    const QString fixture = project ? QStringLiteral("existing.comp") : QFileInfo(image).fileName();
                    bool listed = false;
                    for (int row = 0; row < view->model()->rowCount(view->rootIndex()); ++row)
                        listed |= view->model()->index(row, 0, view->rootIndex()).data().toString() == fixture;
                    if (!listed) return;
                }
                if (!acted) {
                acted = true;
                valid = valid && dialog->parentWidget() == &owner
                    && dialog->acceptMode() == (save ? QFileDialog::AcceptSave : QFileDialog::AcceptOpen)
                    && dialog->fileMode() == (save ? QFileDialog::AnyFile : project ? QFileDialog::Directory : QFileDialog::ExistingFile)
                    && dialog->windowTitle() == "Owned file panel";
                if (cancel) { static_cast<QDialog *>(dialog)->reject(); return; }
                auto *name = dialog->findChild<QLineEdit *>("fileNameEdit");
                if (!name) { valid = false; static_cast<QDialog *>(dialog)->reject(); return; }
                name->setFocus(); name->selectAll();
                const auto shortcut = [&](int key, Qt::KeyboardModifiers modifiers = Qt::ControlModifier) {
                    QKeyEvent press(QEvent::KeyPress, key, modifiers);
                    QApplication::sendEvent(name, &press);
                    QKeyEvent release(QEvent::KeyRelease, key, modifiers);
                    QApplication::sendEvent(name, &release);
                };
                QInputMethodEvent edit; edit.setCommitString("panel-edit"); QApplication::sendEvent(name, &edit);
                shortcut(Qt::Key_A); shortcut(Qt::Key_C);
                valid = valid && QApplication::clipboard()->text() == "panel-edit";
                shortcut(Qt::Key_X); valid = valid && name->text().isEmpty();
                shortcut(Qt::Key_V); valid = valid && name->text() == "panel-edit";
                shortcut(Qt::Key_Z); valid = valid && name->text().isEmpty();
                shortcut(Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                valid = valid && name->text() == "panel-edit";
                name->selectAll();
                QInputMethodEvent input; input.setCommitString(path); QApplication::sendEvent(name, &input);
                }
                auto *buttons = dialog->findChild<QDialogButtonBox *>();
                if (!buttons) { valid = false; static_cast<QDialog *>(dialog)->reject(); return; }
                for (auto *button : buttons->buttons()) if (buttons->buttonRole(button) == QDialogButtonBox::AcceptRole) {
                    if (!button->isEnabled()) return;
                    if (save && project && button->text().remove('&') != "Save") valid = false;
                    submitted = true;
                    QTimer::singleShot(0, button, [button] { button->click(); }); return;
                }
            }
        });
        QTimer deadline; deadline.setSingleShot(true); deadline.setInterval(3000);
        QObject::connect(&deadline, &QTimer::timeout, [&] {
            expired = true;
            for (auto *widget : QApplication::topLevelWidgets()) if (auto *dialog = qobject_cast<QDialog *>(widget)) {
                if (auto *panel = qobject_cast<QFileDialog *>(dialog)) {
                    auto *name = panel->findChild<QLineEdit *>("fileNameEdit");
                    qWarning() << "file panel deadline" << "acted" << acted << "submitted" << submitted
                               << "valid" << valid << "directory" << panel->directory().absolutePath()
                               << "selected" << panel->selectedFiles() << "field" << (name ? name->text() : QString())
                               << "focus" << (QApplication::focusWidget() ? QApplication::focusWidget()->objectName() : QString());
                    if (auto *buttons = panel->findChild<QDialogButtonBox *>()) for (auto *button : buttons->buttons())
                        qWarning() << "file panel button" << button->text() << button->isEnabled();
                }
                dialog->reject();
            }
        });
        inspect.start(); deadline.start();
        QByteArray output(shortBuffer ? 1 : 4096, '\0');
        auto size = nativefilepanels::present(&owner, 123, descriptor.constData(), reinterpret_cast<uint8_t *>(output.data()), output.size());
        if (shortBuffer && size < 0) {
            output.resize(-size);
            size = nativefilepanels::present(&owner, 123, descriptor.constData(), reinterpret_cast<uint8_t *>(output.data()), output.size());
        }
        inspect.stop(); deadline.stop();
        if (cancel) valid = valid && size == 0;
        else {
            const auto expected = save && QFileInfo(path).suffix().isEmpty() ? path + (project ? ".comp" : ".png") : path;
            valid = valid && size > 0 && QJsonDocument::fromJson(output.left(size)).array() == QJsonArray{expected};
        }
        if (!valid) qWarning() << "file panel diagnostic" << "size" << size << "output" << output.left(qMax<int64_t>(0, size)) << "expected" << path;
        valid = valid && dialogs == 1 && !expired;
        if (save && project && path == package && !cancel) valid = valid && replaced;
        qInfo() << "file panel component" << "save" << save << "project" << project << "cancel" << cancel << "short" << shortBuffer
                << "valid" << valid << "replaced" << replaced << "dialogs" << dialogs << "expired" << expired;
        return valid;
    };
    if (!run(false, false, true, false, image) || !run(false, false, false, true, image)
        || !run(true, false, false, false, temp.filePath("export.png"))
        || !run(false, true, false, false, package) || !run(true, true, false, false, package)
        || !run(true, true, false, false, temp.filePath("new project"))) return 1;
    const QString secondPackage = temp.filePath("second.comp"); QDir().mkpath(secondPackage);
    const auto multiDescriptor = QJsonDocument(QJsonObject{{"save", false}, {"files", true}, {"multiple", true},
        {"extensions", QJsonArray{"comp"}}, {"packagesAsDirectories", false}}).toJson(QJsonDocument::Compact);
    bool directorySet = false, submitted = false, expired = false;
    QTimer multi; multi.setInterval(10);
    QObject::connect(&multi, &QTimer::timeout, [&] {
        for (auto *widget : QApplication::topLevelWidgets()) if (auto *dialog = qobject_cast<QFileDialog *>(widget)) {
            if (!dialog->isVisible() || submitted) continue;
            if (!directorySet) { dialog->setViewMode(QFileDialog::Detail); dialog->setDirectory(temp.path()); directorySet = true; }
            auto *view = dialog->findChild<QAbstractItemView *>("treeView"); if (!view) return;
            QModelIndexList indices;
            for (int row = 0; row < view->model()->rowCount(view->rootIndex()); ++row) {
                auto index = view->model()->index(row, 0, view->rootIndex());
                if (index.data().toString() == "existing.comp" || index.data().toString() == "second.comp") indices << index;
            }
            if (indices.size() != 2 || view->selectionMode() != QAbstractItemView::ExtendedSelection) return;
            view->selectionModel()->clearSelection();
            for (const auto &index : indices) view->selectionModel()->select(index, QItemSelectionModel::Select | QItemSelectionModel::Rows);
            if (auto *buttons = dialog->findChild<QDialogButtonBox *>()) for (auto *button : buttons->buttons())
                if (buttons->buttonRole(button) == QDialogButtonBox::AcceptRole && button->isEnabled()) {
                    submitted = true; QTimer::singleShot(0, button, [button] { button->click(); }); return;
                }
        }
    });
    QTimer deadline; deadline.setSingleShot(true);
    QObject::connect(&deadline, &QTimer::timeout, [&] {
        expired = true;
        for (auto *widget : QApplication::topLevelWidgets()) if (auto *dialog = qobject_cast<QDialog *>(widget)) dialog->reject();
    });
    multi.start(); deadline.start(3000);
    QByteArray paths(4096, '\0');
    const auto size = nativefilepanels::present(&owner, 123, multiDescriptor.constData(), reinterpret_cast<uint8_t *>(paths.data()), paths.size());
    multi.stop(); deadline.stop();
    QStringList actual; for (const auto &path : QJsonDocument::fromJson(paths.left(qMax<int64_t>(0, size))).array()) actual << path.toString();
    actual.sort(); QStringList wanted{package, secondPackage}; wanted.sort();
    if (expired || size <= 0 || actual != wanted) return 1;
    qInfo("Qt project-package multiselection OK (actual directory rows, ExtendedSelection, both paths retained)");
    if (nativefilepanels::present(nullptr, 123, "{}", nullptr, 0) != 0) return 1;
    qInfo("Qt file panel component OK (Open/Save/Cancel, owner/options, short-buffer single presentation, Unicode and existing project packages)");
    return 0;
}
