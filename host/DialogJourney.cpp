// Qt event-loop journey, invoked by the Swift composition root with --dialog-smoke.
// Uses actual menu actions, modal controls, codecs, and the real Swift session.
#include "SessionWindow.h"
#include "EditorDialogs.h"
#include "compositor_host_run.h"
#include <QAction>
#include <QApplication>
#include <QCheckBox>
#include <QComboBox>
#include <QDialogButtonBox>
#include <QDoubleSpinBox>
#include <QImageReader>
#include <QPushButton>
#include <QTemporaryDir>
#include <QTimer>
#include <QDebug>
#include <stdexcept>

namespace {
void require(bool ok, const char *message) { if (!ok) throw std::runtime_error(message); }
QImage exported(SessionWindow &window, const QString &path) {
    require(window.exportPNG(path), "PNG export failed");
    QImage image(path);
    require(!image.isNull(), "PNG read failed");
    return image;
}
void modal(SessionWindow &window, const QString &actionName, const std::function<void(QDialog *)> &body) {
    auto *action = window.findChild<QAction *>(actionName);
    require(action != nullptr, "menu action missing");
    QString error;
    bool visited = false;
    QTimer dispatch;
    dispatch.setSingleShot(true);
    QObject::connect(&dispatch, &QTimer::timeout, &window, [&] {
        visited = true;
        auto *dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget());
        if (!dialog) { error = "dialog missing"; return; }
        try { body(dialog); }
        catch (const std::exception &e) { error = e.what(); dialog->reject(); }
    });
    dispatch.start(0);
    action->trigger();
    require(visited, "action did not open a dialog");
    require(error.isEmpty(), qPrintable(error));
}
void click(QDialog *dialog, QDialogButtonBox::StandardButton which) {
    auto *buttons = dialog->findChild<QDialogButtonBox *>();
    require(buttons && buttons->button(which)->isEnabled(), "dialog action disabled");
    buttons->button(which)->click();
}
QDoubleSpinBox *number(QDialog *dialog, const char *name) {
    auto *field = dialog->findChild<QDoubleSpinBox *>(name);
    require(field != nullptr, "numeric control missing"); return field;
}
void undo(SessionWindow &window) {
    for (auto *action : window.findChildren<QAction *>()) {
        if (action->shortcut() == QKeySequence(QKeySequence::Undo)) { action->trigger(); return; }
    }
    throw std::runtime_error("undo action missing");
}
}

extern "C" int compositor_host_dialog_smoke(int argc, char **argv) {
    QApplication app(argc, argv);
    try {
        QTemporaryDir temporary;
        require(temporary.isValid(), "temporary directory failed");
        SessionWindow window; window.show(); QApplication::processEvents();
        const QString path = temporary.filePath("view.png");
        const QImage original = exported(window, path);
        modal(window, "canvasSize", [&](QDialog *dialog) {
            number(dialog, "width")->setValue(96);
            click(dialog, QDialogButtonBox::Cancel);
        });
        require(exported(window, path) == original, "cancel resized canvas");
        modal(window, "canvasSize", [&](QDialog *dialog) {
            number(dialog, "width")->setValue(96);
            dialog->findChild<QComboBox *>("anchor")->setCurrentIndex(0);
            dialog->findChild<QComboBox *>("extension")->setCurrentIndex(2);
            click(dialog, QDialogButtonBox::Ok);
        });
        const QImage canvas = exported(window, path);
        require(canvas.size() == QSize(96, 64), "canvas refresh kept stale dimensions");
        require(canvas.pixelColor(95, 63) == QColor(Qt::white), "canvas extension missing");
        undo(window); require(exported(window, path) == original, "canvas undo failed");
        modal(window, "imageSize", [&](QDialog *dialog) {
            dialog->findChild<QCheckBox *>("resample")->setChecked(false);
            number(dialog, "resolution")->setValue(300);
            click(dialog, QDialogButtonBox::Ok);
        });
        const QImage print = exported(window, path);
        require(print.size() == original.size(), "resolution-only resampled dimensions");
        require(qAbs(print.dotsPerMeterX() - qRound(300 / 0.0254)) <= 1, "export resolution lost");
        undo(window);
        modal(window, "imageSize", [&](QDialog *dialog) {
            dialog->findChild<QComboBox *>("units")->setCurrentIndex(1);
            number(dialog, "width")->setValue(50);
            click(dialog, QDialogButtonBox::Ok);
        });
        require(exported(window, path).size() == QSize(32, 32), "image resize/ratio failed");
        undo(window); require(exported(window, path) == original, "image undo failed");

        // Let the queued preview run, then exercise visibility and Escape rollback.
        QString previewError;
        modal(window, "filter.Gaussian Blur", [&](QDialog *dialog) {
            QTimer::singleShot(200, dialog, [&, dialog] {
                try {
                    require(exported(window, path) != original, "filter preview did not render");
                    auto *preview = dialog->findChild<QCheckBox *>("preview");
                    require(preview != nullptr, "preview checkbox missing");
                    preview->setChecked(false);
                    require(exported(window, path) == original, "preview toggle did not restore source");
                    preview->setChecked(true);
                    require(exported(window, path) != original, "preview toggle did not restore preview");
                } catch (const std::exception &e) { previewError = e.what(); }
                dialog->reject();
            });
        });
        require(previewError.isEmpty(), qPrintable(previewError));
        require(exported(window, path) == original, "filter cancel altered source");
        modal(window, "filter.Gaussian Blur", [&](QDialog *dialog) {
            number(dialog, "radius")->setValue(3);
            click(dialog, QDialogButtonBox::Ok);
        });
        require(exported(window, path) != original, "filter commit missing");
        undo(window); require(exported(window, path) == original, "filter undo did not restore source in one step");
        modal(window, "imageSize", [&](QDialog *dialog) {
            dialog->findChild<QCheckBox *>("resample")->setChecked(false);
            number(dialog, "resolution")->setValue(300);
            click(dialog, QDialogButtonBox::Ok);
        });
        require(window.saveProject(temporary.filePath("project")), "save after dialog failed");
        require(window.loadProject(temporary.filePath("project")), "reopen after dialog failed");
        const QImage reopened = exported(window, path);
        require(reopened == original, "reopen after dialog changed pixels");
        require(qAbs(reopened.dotsPerMeterX() - qRound(300 / 0.0254)) <= 1, "reopened project lost export resolution");
        qInfo("Qt dialog journey OK (resize, resolution, cancel, preview, commit, undo, save/reopen)");
        return 0;
    } catch (const std::exception &e) {
        qCritical("Qt dialog journey failed: %s", e.what()); return 1;
    }
}
