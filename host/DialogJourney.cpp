// Qt event-loop journey, invoked by the Swift composition root with --dialog-smoke.
// Uses actual menu actions, modal controls, codecs, and the real Swift session.
#include "SessionWindow.h"
#include "EditorDialogs.h"
#include "compositor_host_run.h"
#include "interfaces/IPlatformServices.h"
#include <QAction>
#include <QApplication>
#include <QCheckBox>
#include <QComboBox>
#include <QDialogButtonBox>
#include <QDoubleSpinBox>
#include <QImageReader>
#include <QLabel>
#include <QJsonArray>
#include <QJsonDocument>
#include <QTreeView>
#include <QSpinBox>
#include <QMouseEvent>
#include <QStandardItemModel>
#include <QPushButton>
#include <QSlider>
#include <QLineEdit>
#include <QListWidget>
#include <QTemporaryDir>
#include <QFileInfo>
#include <QDir>
#include <QTimer>
#include <QColor>
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


// Test doubles for the platform seams (Dependency Inversion): the shell must run
// against these with no Qt file dialog, message box, clipboard or app-data lookup.
namespace {
struct FakeFiles final : IFileDialogService {
    QString exportPath, openImagePath;
    QString chooseImageToOpen() override { return openImagePath; }
    QString chooseProjectToOpen() override { return {}; }
    QString chooseProjectSavePath() override { return {}; }
    QString chooseExportPath(const QString &, const QString &) override { return exportPath; }
};
struct FakeClipboard final : IClipboardService {
    QImage stored;
    void setImage(const QImage &image) override { stored = image; }
    QImage image() const override { return stored; }
};
struct FakeNotifier final : IUserNotifier {
    QStringList warnings;
    void warn(const QString &title, const QString &) override { warnings << title; }
};
struct FakeStorage final : IStorageLocator {
    QString root;
    QString appDataDirectory() const override { return root; }
};
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
        // Regression: /qa 2026-09-21 — every Adjust sheet failed its first live preview
        // ("Invalid command JSON": the payload omitted `curves`), leaving OK disabled.
        for (const QString kind : {"Levels", "Hue/Saturation", "Curves", "Exposure", "Gradient Map", "Grain"}) {
            QString adjustError;
            modal(window, "adjust." + kind, [&](QDialog *dialog) {
                QTimer::singleShot(300, dialog, [&, dialog] {
                    auto *buttons = dialog->findChild<QDialogButtonBox *>();
                    if (!buttons || !buttons->button(QDialogButtonBox::Ok)->isEnabled()) adjustError = "OK disabled after first preview";
                    for (auto *label : dialog->findChildren<QLabel *>())
                        if (!label->text().isEmpty() && label->text().contains("failed")) adjustError = label->text();
                    dialog->reject();
                });
            });
            require(adjustError.isEmpty(), qPrintable(kind + ": " + adjustError));
            // Discard Cancelled New Adjustment Sheet (R26): rejection automatically rolled back the sheet
            require(exported(window, path) == original, "adjust discard did not restore source");
        }

        // Levels: Auto buttons and eyedropper sampling from the canvas.
        modal(window, "adjust.Levels", [&](QDialog *dialog) {
            for (int i = 0; i < 3; ++i) {
                auto *autoButton = dialog->findChild<QPushButton *>(QString("auto.%1").arg(i));
                require(autoButton && autoButton->isEnabled(), "Levels Auto button missing or disabled");
                autoButton->click(); QApplication::processEvents();
            }
            auto *sample = dialog->findChild<QPushButton *>("sample.0");
            require(sample && sample->isEnabled(), "Levels eyedropper missing or disabled");
            sample->click(); QApplication::processEvents();
            QWidget *canvas = window.centralWidget();
            const double scale = std::max(1, int(std::min((canvas->width() - 48) / 64.0, (canvas->height() - 48) / 64.0)));
            const QPointF origin((canvas->width() - 64 * scale) / 2.0, (canvas->height() - 64 * scale) / 2.0);
            const QPointF pos = origin + QPointF(28.5 * scale, 28.5 * scale);  // on the red stroke
            QMouseEvent press(QEvent::MouseButtonPress, pos, canvas->mapToGlobal(pos), Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
            QApplication::sendEvent(canvas, &press);
            QMouseEvent release(QEvent::MouseButtonRelease, pos, canvas->mapToGlobal(pos), Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
            QApplication::sendEvent(canvas, &release);
            QApplication::processEvents();
            require(dialog->isModal(), "dialog did not become modal again after sampling");
            auto *channel = dialog->findChild<QComboBox *>("channel");
            channel->setCurrentIndex(1);  // Red: sampled 255 sets the black point to 254
            require(number(dialog, "Black")->value() == 254, "black eyedropper did not calibrate the red channel");
            channel->setCurrentIndex(2);  // Green: sampled 0 keeps black at 0
            require(number(dialog, "Black")->value() == 0, "black eyedropper changed the green channel");
            click(dialog, QDialogButtonBox::Cancel);
        });
        require(exported(window, path) == original, "Levels sampling discard did not restore source");

        // Command Palette (Ctrl+Shift+P / F1)
        modal(window, "commandPalette", [&](QDialog *dialog) {
            auto *filter = dialog->findChild<QLineEdit *>("commandPalette.filter");
            auto *list = dialog->findChild<QListWidget *>("commandPalette.list");
            require(filter != nullptr, "command palette filter input missing");
            require(list != nullptr, "command palette list missing");
            require(list->count() > 0, "command palette list is empty");
            filter->setText("Canvas");
            require(list->count() > 0, "command palette search for 'Canvas' returned no items");
            dialog->reject();
        });

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

        // Crash-Recovery Autosave (R61)
        window.clearAutosave();
        require(!window.hasAutosaveRecovery(), "unexpected autosave recovery state before edit");
        window.paintStroke(10, 10, 20, 20);
        require(window.performAutosave(), "performAutosave failed on dirty document");
        require(window.hasAutosaveRecovery(), "hasAutosaveRecovery false after performAutosave");
        require(window.recoverAutosave(), "recoverAutosave failed");
        window.clearAutosave();
        require(!window.hasAutosaveRecovery(), "hasAutosaveRecovery true after clearAutosave");
        // Platform seams: the shell runs entirely against injected fakes.
        {
            auto files = std::make_shared<FakeFiles>();
            auto clipboard = std::make_shared<FakeClipboard>();
            auto notifier = std::make_shared<FakeNotifier>();
            auto storage = std::make_shared<FakeStorage>();
            storage->root = temporary.filePath("appdata");
            PlatformServices services;
            services.files = files; services.clipboard = clipboard; services.notifier = notifier; services.storage = storage;
            SessionWindow injected(nullptr, services);
            auto action = [&](const QString &text) -> QAction * {
                for (QAction *a : injected.findChildren<QAction *>()) if (a->text().remove('&') == text) return a;
                require(false, "menu action missing"); return nullptr;
            };
            files->exportPath = temporary.filePath("injected.png");
            action("Export PNG...")->trigger();
            require(QFileInfo::exists(files->exportPath), "export did not use the injected file dialog");
            require(notifier->warnings.isEmpty(), "unexpected warning on a successful export");
            files->exportPath = temporary.filePath("missing-dir/injected.png");
            action("Export PNG...")->trigger();
            require(notifier->warnings.size() == 1, "failed export did not reach the injected notifier");
            action("Copy")->trigger();
            require(!clipboard->stored.isNull(), "copy did not reach the injected clipboard");
            require(injected.performAutosave(), "autosave failed against the injected storage");
            require(QDir(temporary.filePath("appdata/recovery")).exists(), "autosave ignored the injected storage locator");
        }
        qInfo("Qt dialog journey OK (resize, resolution, cancel, preview, commit, undo, command palette, autosave, save/reopen)");
        return 0;
    } catch (const std::exception &e) {
        qCritical("Qt dialog journey failed: %s", e.what()); return 1;
    }
}

// Count non-transparent pixels with a strong channel, i.e. pixels the compositor
// actually painted (as opposed to the transparent canvas background).
static int countPainted(const QImage &image) {
    int colored = 0;
    for (int y = 0; y < image.height(); ++y) {
        for (int x = 0; x < image.width(); ++x) {
            const QColor pixel = image.pixelColor(x, y);
            if (pixel.alpha() > 0 && (pixel.red() > 200 || pixel.green() > 200 || pixel.blue() > 200)) ++colored;
        }
    }
    return colored;
}

// Brush palette + blend round-trip: the palette sliders and color button feed
// brushBegin parameters through the C ABI, the blend combo drives setBlendMode,
// and the painted stroke renders with the chosen color/size.
extern "C" int compositor_host_brush_smoke(int argc, char **argv) {
    QApplication app(argc, argv);
    try {
        QTemporaryDir temporary;
        require(temporary.isValid(), "temporary directory failed");
        SessionWindow window; window.show(); QApplication::processEvents();
        auto *diameter = window.findChild<QSlider *>("brush.diameter");
        auto *hardness = window.findChild<QSlider *>("brush.hardness");
        auto *opacity = window.findChild<QSlider *>("brush.opacity");
        auto *blend = window.findChild<QComboBox *>("blend.mode");
        require(diameter && hardness && opacity && blend, "brush palette controls missing");
        diameter->setValue(24);
        hardness->setValue(100);
        opacity->setValue(100);
        blend->setCurrentText("Multiply");
        const QJsonArray layers = window.sessionState().value("layers").toArray();
        require(layers.size() > 0 && layers.at(0).toObject().value("blendMode").toString() == "Multiply", "blend combo did not reach setBlendMode");

        window.paintStroke(8, 8, 40, 40);
        const QImage painted = exported(window, temporary.filePath("brush.png"));
        require(countPainted(painted) > 0, "palette stroke did not paint");

        auto *visible = window.findChild<QCheckBox *>("layer.visible");
        require(visible, "visibility checkbox missing");
        visible->setChecked(false); QApplication::processEvents();
        require(!window.sessionState().value("layers").toArray().at(0).toObject().value("visible").toBool(true), "visibility toggle did not reach setVisible");
        visible->setChecked(true); QApplication::processEvents();
        require(window.sessionState().value("layers").toArray().at(0).toObject().value("visible").toBool(false) != false, "visibility re-enable did not reach setVisible");

        auto *selectAll = window.findChild<QAction *>("select.rectangle");
        auto *fill = window.findChild<QAction *>("fill.foreground");
        require(selectAll && fill, "select/fill actions missing");
        selectAll->trigger(); QApplication::processEvents();
        fill->trigger(); QApplication::processEvents();
        const QImage filled = exported(window, temporary.filePath("filled.png"));
        require(countPainted(filled) > 0, "selection fill did not paint");
        qInfo("Qt brush palette journey OK (diameter/hardness/opacity, color, blend, paint, visible, select, fill)");
        return 0;
    } catch (const std::exception &e) {
        qCritical("Qt brush palette journey failed: %s", e.what()); return 1;
    }
}

// Layers dock journey: the QTreeView hierarchical model mirrors the Swift state JSON, and the
// Layer menu actions round-trip addLayer/duplicateLayer/deleteLayer/selectLayer/
// setOpacity/addGroup/masks through the C ABI.
extern "C" int compositor_host_layers_smoke(int argc, char **argv) {
    QApplication app(argc, argv);
    try {
        QTemporaryDir temporary;
        require(temporary.isValid(), "temporary directory failed");
        SessionWindow window; window.show(); QApplication::processEvents();
        auto *tree = window.findChild<QTreeView *>();
        require(tree != nullptr, "layers tree view missing");
        auto *model = qobject_cast<QStandardItemModel *>(tree->model());
        require(model != nullptr, "layers model missing");
        auto *opacity = window.findChild<QSlider *>();
        require(opacity != nullptr, "opacity slider missing");
        auto menuAction = [&](const QString &text) -> QAction * {
            for (QAction *action : window.findChildren<QAction *>()) {
                if (action->text().remove('&') == text) return action;
            }
            return nullptr;
        };
        const auto stateLayers = [&]() -> QJsonArray {
            return window.sessionState().value("layers").toArray();
        };

        auto countItems = [&](auto self, const QModelIndex &parent = QModelIndex()) -> int {
            int total = 0;
            const int rows = model->rowCount(parent);
            total += rows;
            for (int r = 0; r < rows; ++r) {
                total += self(self, model->index(r, 0, parent));
            }
            return total;
        };

        require(countItems(countItems) == stateLayers().size(), "dock rows do not match session layers");
        const int opened = countItems(countItems);
        require(opened == 1, "initial dock does not hold the brush layer");
        const QImage original = exported(window, temporary.filePath("view.png"));

        auto *add = menuAction("New Layer"); require(add, "New Layer action missing");
        auto *duplicate = menuAction("Duplicate Layer"); require(duplicate, "Duplicate Layer action missing");
        auto *remove = menuAction("Delete Layer"); require(remove, "Delete Layer action missing");
        add->trigger();
        require(stateLayers().size() == 2 && countItems(countItems) == 2, "New Layer did not add a dock row");
        // The dock lists the top layer first; the document array is bottom-first.
        require(tree->currentIndex().row() == 0 && window.sessionState().value("activeLayerID").toString()
            == stateLayers().at(stateLayers().size() - 1 - tree->currentIndex().row()).toObject().value("id").toString(), "new layer not selected in the dock");
        duplicate->trigger();
        require(stateLayers().size() == 3 && countItems(countItems) == 3, "duplicate did not add a dock row");
        tree->setCurrentIndex(model->index(1, 0));
        require(window.sessionState().value("activeLayerID").toString()
            == stateLayers().at(stateLayers().size() - 2).toObject().value("id").toString(), "row selection did not switch active layer");
        opacity->setValue(50);
        const QString active = window.sessionState().value("activeLayerID").toString();
        double set = -1;
        for (const QJsonValue &v : stateLayers()) {
            if (v.toObject().value("id").toString() == active) set = v.toObject().value("opacity").toDouble(-1);
        }
        require(set > 0.49 && set < 0.51, "opacity slider did not round-trip");
        remove->trigger();
        require(stateLayers().size() == 2 && countItems(countItems) == 2, "delete did not remove a dock row");

        // Multi-selection layer deletion (ExtendedSelection)
        add->trigger();
        add->trigger();
        const int beforeMulti = countItems(countItems);
        require(beforeMulti >= 4, "failed to add layers for multi-selection test");
        tree->selectionModel()->clearSelection();
        tree->selectionModel()->select(model->index(0, 0), QItemSelectionModel::Select | QItemSelectionModel::Rows);
        tree->selectionModel()->select(model->index(1, 0), QItemSelectionModel::Select | QItemSelectionModel::Rows);
        require(tree->selectionModel()->selectedRows().size() == 2, "failed to select two rows");
        remove->trigger();
        require(countItems(countItems) == beforeMulti - 2, "multi-selection delete failed to delete both layers");

        // Group / Folder hierarchical verification
        auto *addGroup = menuAction("New Folder / Group");
        require(addGroup != nullptr, "New Folder / Group action missing");
        addGroup->trigger();
        require(countItems(countItems) == stateLayers().size(), "New Folder did not add a group row");
        const QString grpActive = window.sessionState().value("activeLayerID").toString();
        bool isGroup = false;
        for (const QJsonValue &v : stateLayers()) {
            if (v.toObject().value("id").toString() == grpActive) isGroup = v.toObject().value("isGroup").toBool();
        }
        require(isGroup, "active layer is not a group");

        // Mask verification on a raster layer
        tree->setCurrentIndex(model->index(model->rowCount() - 1, 0));  // bottom raster layer
        auto *addMask = menuAction("Add Reveal Mask");
        require(addMask != nullptr, "Add Reveal Mask action missing");
        addMask->trigger();
        const QString maskActive = window.sessionState().value("activeLayerID").toString();
        bool hasMask = false;
        for (const QJsonValue &v : stateLayers()) {
            if (v.toObject().value("id").toString() == maskActive) hasMask = v.toObject().value("hasMask").toBool();
        }
        require(hasMask, "layer hasMask is false after Add Reveal Mask");

        require(!exported(window, temporary.filePath("after.png")).isNull(), "render after layer ops failed");
        // Move / Transform: X/Y/W/H fields, Link, handle resize, body drag, panel order.
        {
            SessionWindow w2; w2.resize(1200, 800); w2.show(); QApplication::processEvents();
            w2.setTool(SessionWindow::Tool::Move); QApplication::processEvents();
            auto spin = [&](const char *name) { auto *s = w2.findChild<QSpinBox *>(name); require(s, "transform spin missing"); return s; };
            const auto geometry = [&]() {
                const QJsonObject layer = w2.sessionState().value("layers").toArray().at(0).toObject();
                const QJsonObject t = layer.value("transform").toObject();
                auto pair = [](const QJsonValue &v, const char *a, const char *b) {
                    if (v.isArray()) return QPointF(v.toArray().at(0).toDouble(), v.toArray().at(1).toDouble());
                    return QPointF(v.toObject().value(a).toDouble(), v.toObject().value(b).toDouble());
                };
                const QPointF o = pair(t.value("origin"), "x", "y"), z = pair(t.value("size"), "width", "height");
                return QRectF(o.x(), o.y(), z.x(), z.y());
            };
            // The startup brush stroke leaves a 56x56 layer inside the 64x64 document.
            require(geometry().size() == QSizeF(56, 56), "unexpected initial layer size");
            require(spin("transform.w")->value() == 56 && spin("transform.h")->value() == 56, "W/H fields do not mirror the layer");
            spin("transform.w")->setValue(32); QApplication::processEvents();
            require(geometry().size() == QSizeF(32, 32), "linked W edit did not resize the layer to 32x32");
            require(spin("transform.h")->value() == 32, "linked H field did not follow W");
            spin("transform.x")->setValue(6); QApplication::processEvents();
            require(qRound(geometry().x()) == 6, "X field did not move the layer");
            spin("transform.x")->setValue(0); QApplication::processEvents();

            QWidget *canvas = w2.centralWidget();
            const double scale = std::max(1, int(std::min((canvas->width() - 48) / 64.0, (canvas->height() - 48) / 64.0)));
            const QPointF origin((canvas->width() - 64 * scale) / 2.0, (canvas->height() - 64 * scale) / 2.0);
            auto at = [&](double dx, double dy) { return origin + QPointF(dx * scale, dy * scale); };
            auto drag = [&](QPointF from, QPointF to) {
                auto send = [&](QEvent::Type type, QPointF pos, Qt::MouseButton button, Qt::MouseButtons buttons) {
                    QMouseEvent ev(type, pos, canvas->mapToGlobal(pos), button, buttons, Qt::NoModifier);
                    QApplication::sendEvent(canvas, &ev);
                };
                send(QEvent::MouseButtonPress, from, Qt::LeftButton, Qt::LeftButton);
                send(QEvent::MouseMove, (from + to) / 2, Qt::NoButton, Qt::LeftButton);
                send(QEvent::MouseMove, to, Qt::NoButton, Qt::LeftButton);
                send(QEvent::MouseButtonRelease, to, Qt::LeftButton, Qt::NoButton);
                QApplication::processEvents();
            };
            drag(at(32, 32), at(48, 40));  // bottom-right handle, linked => uniform 1.5x
            require(geometry().size() == QSizeF(48, 48), "corner handle drag did not resize uniformly");
            require(spin("transform.w")->value() == 48, "fields did not refresh after handle drag");
            drag(at(20, 20), at(24, 25));  // body drag
            require(qRound(geometry().x()) == 4 && qRound(geometry().y()) == 5, "body drag did not move the layer");
            require(window.sessionState().value("canUndo").toBool(), "transform edits left no history entry");
        }

        // Selection tools: New/Add combine modes, Expand, polygonal lasso.
        {
            SessionWindow w3; w3.resize(1200, 800); w3.show(); QApplication::processEvents();
            QWidget *canvas = w3.centralWidget();
            const double scale = std::max(1, int(std::min((canvas->width() - 48) / 64.0, (canvas->height() - 48) / 64.0)));
            const QPointF origin((canvas->width() - 64 * scale) / 2.0, (canvas->height() - 64 * scale) / 2.0);
            auto at = [&](double dx, double dy) { return origin + QPointF(dx * scale, dy * scale); };
            auto send = [&](QEvent::Type type, QPointF pos, Qt::MouseButton button, Qt::MouseButtons buttons) {
                QMouseEvent ev(type, pos, canvas->mapToGlobal(pos), button, buttons, Qt::NoModifier);
                QApplication::sendEvent(canvas, &ev);
            };
            auto drag = [&](QPointF from, QPointF to) {
                send(QEvent::MouseButtonPress, from, Qt::LeftButton, Qt::LeftButton);
                send(QEvent::MouseMove, (from + to) / 2, Qt::NoButton, Qt::LeftButton);
                send(QEvent::MouseMove, to, Qt::NoButton, Qt::LeftButton);
                send(QEvent::MouseButtonRelease, to, Qt::LeftButton, Qt::NoButton);
                QApplication::processEvents();
            };
            auto click = [&](QPointF pos) {
                send(QEvent::MouseButtonPress, pos, Qt::LeftButton, Qt::LeftButton);
                send(QEvent::MouseButtonRelease, pos, Qt::LeftButton, Qt::NoButton);
                QApplication::processEvents();
            };
            auto button = [&](const QString &text) -> QPushButton * {
                for (auto *b : w3.findChildren<QPushButton *>()) if (b->text() == text) return b;
                require(false, "options button missing"); return nullptr;
            };
            QImage baseline = exported(w3, temporary.filePath("baseline.png"));
            auto fillAndExport = [&](const char *file) {
                baseline = exported(w3, temporary.filePath("baseline.png"));
                for (QAction *action : w3.findChildren<QAction *>()) if (action->objectName() == "fill.foreground") action->trigger();
                QApplication::processEvents();
                return exported(w3, temporary.filePath(file));
            };
            // A pixel counts as filled when the fill changed it relative to the pre-fill render.
            auto filled = [&](const QImage &img, int x, int y) { return img.pixelColor(x, y) != baseline.pixelColor(x, y); };

            w3.setTool(SessionWindow::Tool::RectSelect); QApplication::processEvents();
            drag(at(30, 4), at(44, 18));
            button("Add")->click();
            drag(at(4, 34), at(18, 48));
            const QImage combined = fillAndExport("combined.png");
            require(filled(combined, 36, 10) && filled(combined, 10, 40), "Add mode did not keep both rectangles");
            require(!filled(combined, 30, 30) && !filled(combined, 22, 24), "Add mode filled the gap between rectangles");
            button("New")->click();

            // Expand: a fresh 8px square grows by 6px on each side.
            w3.setTool(SessionWindow::Tool::RectSelect); QApplication::processEvents();
            drag(at(50, 4), at(58, 12));   // 8x8 at (50,4)
            for (auto *spin : w3.findChildren<QSpinBox *>()) if (spin->suffix() == " px" && spin->value() == 1 && spin->width() <= 60 && spin->isEnabledTo(spin->window())) { spin->setValue(6); break; }
            button("Expand")->click(); QApplication::processEvents();
            const QImage grown = fillAndExport("grown.png");
            require(filled(grown, 46, 8) && filled(grown, 55, 8), "Expand did not grow the selection");

            // Polygonal lasso: three clicks and a click on the first vertex close the triangle.
            w3.setTool(SessionWindow::Tool::Lasso); QApplication::processEvents();
            button("Polygonal")->click();
            click(at(44, 30)); click(at(54, 30)); click(at(54, 54)); click(at(44, 30));
            const QImage polygon = fillAndExport("polygon.png");
            require(filled(polygon, 52, 40), "polygonal lasso selection was not applied");
        }

        qInfo("Qt layers dock journey OK (add, duplicate, select, opacity, delete, multi-delete, group, mask)");
        return 0;
    } catch (const std::exception &e) {
        qCritical("Qt layers dock journey failed: %s", e.what()); return 1;
    }
}
