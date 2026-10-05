#pragma once

// Qt Widgets / XDG-portal implementations of the platform seams. Header-only and
// Q_OBJECT-free (SwiftPM cannot run moc). A macOS shell would provide AppKit-backed
// implementations of the same interfaces; nothing above this file would change.

#include "interfaces/IPlatformServices.h"
#include "ColorPickerDialog.h"

#include <QApplication>
#include <QClipboard>
#include <QDir>
#include <QFileDialog>
#include <QGuiApplication>
#include <QMessageBox>
#include <QMimeData>
#include <QStandardPaths>
#include <QUrl>
#include <QByteArray>

namespace qtplatform {

namespace {
bool isDocumentPortalPath(const QString &path) {
    // XDG document portal fuse: /run/user/<uid>/doc/<id>/name — file grants only, not directory packages.
    return path.startsWith(QStringLiteral("/run/user/")) && path.contains(QStringLiteral("/doc/"));
}

QString runProjectSaveDialog(const QString &suggestedPath, bool native) {
    QFileDialog dialog(QApplication::activeWindow(), QObject::tr("Save Project As"));
    dialog.setAcceptMode(QFileDialog::AcceptSave);
    dialog.setFileMode(QFileDialog::AnyFile);
    dialog.setNameFilters({QObject::tr("Compositor project (*.comp)"), QObject::tr("All files (*)")});
    dialog.setOption(QFileDialog::DontUseNativeDialog, !native);
    const QFileInfo suggestedInfo(suggestedPath.isEmpty() ? QDir::home().filePath(QStringLiteral("Untitled.comp"))
                                                          : suggestedPath);
    // Always start in the parent folder. An existing .comp package is a directory; browsing
    // into it made Save As write Untitled.comp/Untitled.comp.
    QString fileName = suggestedInfo.fileName();
    if (fileName.isEmpty()) fileName = QStringLiteral("Untitled.comp");
    if (!fileName.endsWith(QStringLiteral(".comp"), Qt::CaseInsensitive))
        fileName += QStringLiteral(".comp");
    // Portal / fuse parents are not useful starting points for a directory package.
    QString startDir = suggestedInfo.absolutePath();
    if (isDocumentPortalPath(startDir) || isDocumentPortalPath(suggestedInfo.absoluteFilePath()))
        startDir = QDir::homePath();
    dialog.setDirectory(startDir);
    dialog.selectFile(fileName);
    // selectFile already ends with .comp — defaultSuffix would produce *.comp.comp on some dialogs.
    dialog.setDefaultSuffix(QString());
    if (dialog.exec() != QDialog::Accepted) return {};
    const QStringList selected = dialog.selectedFiles();
    if (selected.isEmpty()) return {};
    QString path = selected.first();
    if (path.startsWith(QStringLiteral("file:"), Qt::CaseInsensitive))
        path = QUrl(path).toLocalFile();
    return QDir::cleanPath(path);
}
}  // namespace

class FileDialogs final : public IFileDialogService {
public:
    static QString imageFilter() {
        return QObject::tr("Images (*.png *.jpg *.jpeg *.bmp *.tif *.tiff *.webp *.heic *.heif *.psd *.psb *.dng *.cr2 *.cr3 *.crw *.nef *.nrw *.arw *.orf *.raf *.rw2 *.pef *.srw *.x3f *.3fr *.iiq *.erf *.kdc *.mos *.mrw);;Photoshop (*.psd *.psb);;Camera RAW (*.dng *.cr2 *.cr3 *.crw *.nef *.nrw *.arw *.orf *.raf *.rw2 *.pef *.srw *.x3f *.3fr *.iiq *.erf *.kdc *.mos *.mrw);;All files (*)");
    }
    QString chooseImageToOpen() override {
        return QFileDialog::getOpenFileName(QApplication::activeWindow(), QObject::tr("Open Image"), QString(), imageFilter());
    }
    QStringList chooseImagesToImport() override {
        return QFileDialog::getOpenFileNames(QApplication::activeWindow(), QObject::tr("Import Images"), QString(), imageFilter());
    }
    QString chooseProjectToOpen() override {
        return QFileDialog::getExistingDirectory(QApplication::activeWindow(), QObject::tr("Open Project"));
    }
    QString chooseProjectSavePath(const QString &suggestedPath) override {
        // .comp is a directory package. The XDG document portal returns a fuse *file* grant under
        // /run/user/.../doc/... which cannot be replaced with a directory. Prefer the real native
        // chooser (GTK/KDE) with portals disabled so --filesystem=host yields a real path and the
        // familiar system UI (not Qt's non-native dialog).
        const QByteArray previousPortal = qgetenv("QT_NO_XDG_DESKTOP_PORTAL");
        const QByteArray previousGtkPortal = qgetenv("GTK_USE_PORTAL");
        qputenv("QT_NO_XDG_DESKTOP_PORTAL", "1");
        qputenv("GTK_USE_PORTAL", "0");
        QString path = runProjectSaveDialog(suggestedPath, true);
        if (previousPortal.isNull()) qunsetenv("QT_NO_XDG_DESKTOP_PORTAL");
        else qputenv("QT_NO_XDG_DESKTOP_PORTAL", previousPortal);
        if (previousGtkPortal.isNull()) qunsetenv("GTK_USE_PORTAL");
        else qputenv("GTK_USE_PORTAL", previousGtkPortal);

        if (path.isEmpty()) return {};
        if (!isDocumentPortalPath(path)) return path;

        // Portal still won (some desktops ignore QT_NO_XDG_DESKTOP_PORTAL). A fuse *file* grant
        // cannot hold a .comp directory package — keep the chosen name and save automatically
        // under Documents (or Home) instead of showing a second dialog.
        QString fileName = QFileInfo(path).fileName();
        if (fileName.isEmpty()) fileName = QStringLiteral("Untitled.comp");
        if (!fileName.endsWith(QStringLiteral(".comp"), Qt::CaseInsensitive))
            fileName += QStringLiteral(".comp");
        QString dir = QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation);
        if (dir.isEmpty() || isDocumentPortalPath(dir)) dir = QDir::homePath();
        const QString redirected = QDir(dir).filePath(fileName);
        qWarning("project save: portal path %s → automatic save at %s",
                 qPrintable(path), qPrintable(redirected));
        // Best-effort: drop the empty portal placeholder file so it does not linger.
        if (QFileInfo(path).isFile()) QFile::remove(path);
        return redirected;
    }
    QString chooseExportPath(const QString &formatName, const QString &filter) override {
        return QFileDialog::getSaveFileName(QApplication::activeWindow(), QObject::tr("Export %1").arg(formatName), QString(), filter);
    }
};

class Clipboard final : public IClipboardService {
public:
    void setImage(const QImage &image) override {
        if (auto *clipboard = QGuiApplication::clipboard()) clipboard->setImage(image);
    }
    QImage image() const override {
        const QClipboard *clipboard = QGuiApplication::clipboard();
        const QMimeData *mime = clipboard ? clipboard->mimeData() : nullptr;
        return (mime && mime->hasImage()) ? qvariant_cast<QImage>(mime->imageData()) : QImage();
    }
};

class ColorPicker final : public IColorPickerService {
public:
    QColor pick(const QColor &initial, const QString &title) override {
        return ColorPickerDialog::getColor(initial, QApplication::activeWindow(), title);
    }
    QColor pick(const QColor &initial, const QString &title, const std::function<void(const QColor &)> &preview) override {
        return ColorPickerDialog::getColor(initial, QApplication::activeWindow(), title, preview);
    }
};

class Notifier final : public IUserNotifier {
public:
    void warn(const QString &title, const QString &text) override {
        QMessageBox::warning(QApplication::activeWindow(), title, text);
    }
};

class Storage final : public IStorageLocator {
public:
    QString appDataDirectory() const override {
        QString dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
        return dir.isEmpty() ? QDir::tempPath() + "/Compositor" : dir;
    }
};

}  // namespace qtplatform

#include "FlatpakUpdateService.h"

inline PlatformServices PlatformServices::qtDefaults() {
    PlatformServices services;
    services.files = std::make_shared<qtplatform::FileDialogs>();
    services.clipboard = std::make_shared<qtplatform::Clipboard>();
    services.colors = std::make_shared<qtplatform::ColorPicker>();
    services.notifier = std::make_shared<qtplatform::Notifier>();
    services.storage = std::make_shared<qtplatform::Storage>();
    services.updates = std::make_shared<qtplatform::FlatpakUpdateService>();
    return services;
}

inline PlatformServices PlatformServices::withDefaults() const {
    const PlatformServices fallback = qtDefaults();
    PlatformServices merged = *this;
    if (!merged.files) merged.files = fallback.files;
    if (!merged.clipboard) merged.clipboard = fallback.clipboard;
    if (!merged.colors) merged.colors = fallback.colors;
    if (!merged.notifier) merged.notifier = fallback.notifier;
    if (!merged.storage) merged.storage = fallback.storage;
    if (!merged.updates) merged.updates = fallback.updates;
    return merged;
}
