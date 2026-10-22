#pragma once

#include <QDir>
#include <QDialogButtonBox>
#include <QAbstractButton>
#include <QLineEdit>
#include <QAbstractItemView>
#include <QFileDialog>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMessageBox>
#include <QPointer>
#include <cstring>
#include <cstdint>

namespace nativefilepanels {

class Panel : public QFileDialog {
public:
    Panel(QWidget *owner, bool packageSave, bool multipleDirectories)
        : QFileDialog(owner), m_packageSave(packageSave), m_multipleDirectories(multipleDirectories) {
        // A project is a directory package. Qt's ordinary Save dialog navigates into an existing one.
        if (packageSave || multipleDirectories) {
            setOption(QFileDialog::DontUseNativeDialog);
        }
    }
protected:
    void showEvent(QShowEvent *event) override {
        QFileDialog::showEvent(event);
        if (m_multipleDirectories)
            for (const auto &name : {"listView", "treeView"})
                if (auto *view = findChild<QAbstractItemView *>(name)) view->setSelectionMode(QAbstractItemView::ExtendedSelection);
        if (m_packageSave && !m_labelConnected) {
            m_labelConnected = true;
            if (auto *field = findChild<QLineEdit *>("fileNameEdit"))
                QObject::connect(field, &QLineEdit::textChanged, this, [this] { updatePackageLabel(); });
            QObject::connect(this, &QFileDialog::currentChanged, this, [this] { updatePackageLabel(); });
            updatePackageLabel();
        }
    }
    void accept() override {
        const auto paths = selectedFiles();
        if (m_packageSave && paths.size() == 1 && paths.first().endsWith(QStringLiteral(".comp"), Qt::CaseInsensitive)
            && QFileInfo(paths.first()).isDir()) {
            if (QMessageBox::question(this, tr("Replace Project?"),
                    tr("%1 already exists. Replace it?").arg(QFileInfo(paths.first()).fileName()),
                    QMessageBox::Yes | QMessageBox::Cancel, QMessageBox::Cancel) == QMessageBox::Yes) QDialog::accept();
            return;
        }
        QFileDialog::accept();
    }
private:
    void updatePackageLabel() {
        // Qt calls a directory destination Open; a project package is a Save destination.
        const auto paths = selectedFiles();
        if (paths.size() == 1 && paths.first().endsWith(QStringLiteral(".comp"), Qt::CaseInsensitive) && QFileInfo(paths.first()).isDir())
            if (auto *buttons = findChild<QDialogButtonBox *>()) for (auto *button : buttons->buttons())
                if (buttons->buttonRole(button) == QDialogButtonBox::AcceptRole) button->setText(tr("&Save"));
    }
    bool m_packageSave;
    bool m_multipleDirectories;
    bool m_labelConnected = false;
};

// A short output buffer must not make the user repeat a selection. The Swift caller retries synchronously.
struct Pending {
    uint64_t handle = 0;
    QByteArray descriptor, paths;
    QPointer<QWidget> owner;
    bool project = false;
};

inline int64_t present(QWidget *owner, uint64_t handle, const char *descriptor, uint8_t *output, size_t capacity) {
    static Pending pending;
    QPointer<QWidget> ownerGuard(owner);
    const QByteArray request(descriptor ? descriptor : "");
    if (handle && !owner) { pending = {}; return 0; }
    if (pending.paths.isEmpty() || pending.handle != handle || pending.descriptor != request
        || (pending.project && (pending.owner.isNull() || pending.owner != owner))) {
        pending = {};
        QJsonParseError error;
        const auto document = QJsonDocument::fromJson(request, &error);
        if (error.error != QJsonParseError::NoError || !document.isObject()) return 0;
        const auto options = document.object();
        const bool save = options.value("save").toBool();
        QStringList extensions, patterns;
        for (const auto &entry : options.value("extensions").toArray()) {
            const auto extension = entry.toString();
            if (!extension.isEmpty()) { extensions << extension; patterns << QStringLiteral("*.") + extension; }
        }
        const bool package = extensions.contains(QStringLiteral("comp")) && !options.value("packagesAsDirectories").toBool();
        const bool multipleDirectories = !save && options.value("multiple").toBool()
            && (package || options.value("directories").toBool());
        Panel dialog(owner, save && package, multipleDirectories);
        dialog.setObjectName(save ? QStringLiteral("nativeSavePanel") : QStringLiteral("nativeOpenPanel"));
        const auto message = options.value("message").toString();
        auto caption = message.isEmpty() ? options.value("title").toString() : message;
        if (caption.isEmpty()) caption = save ? QObject::tr("Save") : QObject::tr("Open");
        dialog.setWindowTitle(caption);
        dialog.setDirectory(QDir::homePath());
        dialog.setOption(QFileDialog::ReadOnly, !options.value("createDirectories").toBool());
        if (!patterns.isEmpty()) dialog.setNameFilter(QObject::tr("Files (%1)").arg(patterns.join(QLatin1Char(' '))));
        if (save) {
            dialog.setAcceptMode(QFileDialog::AcceptSave);
            dialog.setFileMode(QFileDialog::AnyFile);
            if (extensions.size() == 1) dialog.setDefaultSuffix(extensions.first());
            dialog.selectFile(options.value("name").toString());
            if (package) dialog.setLabelText(QFileDialog::Accept, QObject::tr("Save"));
        } else {
            dialog.setAcceptMode(QFileDialog::AcceptOpen);
            if (package || options.value("directories").toBool()) {
                dialog.setFileMode(QFileDialog::Directory);
                dialog.setOption(QFileDialog::ShowDirsOnly);
            } else {
                if (!options.value("files").toBool(true)) return 0;
                dialog.setFileMode(options.value("multiple").toBool() ? QFileDialog::ExistingFiles : QFileDialog::ExistingFile);
            }
        }
        if (dialog.exec() != QDialog::Accepted || (handle && ownerGuard.isNull())) return 0;
        QJsonArray paths;
        for (const auto &path : dialog.selectedFiles()) paths.append(path);
        if (paths.isEmpty()) return 0;
        pending = {handle, request, QJsonDocument(paths).toJson(QJsonDocument::Compact), owner, handle != 0};
    }
    const auto size = pending.paths.size();
    if (!output || capacity < size_t(size)) return -int64_t(size);
    std::memcpy(output, pending.paths.constData(), size_t(size));
    pending = {};
    return size;
}

} // namespace nativefilepanels
