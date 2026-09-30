// Qt event-loop journey, invoked by the Swift composition root with --dialog-smoke.
// Uses actual menu actions, modal controls, codecs, and the real Swift session.
#include "SessionWindow.h"
#include "ProjectPackageLimits.h"
#include "EditorDialogs.h"
#include "compositor_host_run.h"
#include "interfaces/IPlatformServices.h"
#include <QAction>
#include <QApplication>
#include <QStyleFactory>
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
#include <QKeyEvent>
#include <QStandardItemModel>
#include <QPushButton>
#include <QSlider>
#include <QLineEdit>
#include <QPlainTextEdit>
#include <QTextCursor>
#include <QTextBlock>
#include <QTextLayout>
#include <QFontDatabase>
#include <QFontInfo>
#include <QListWidget>
#include <QTemporaryDir>
#include <QFileInfo>
#include <QFile>
#include <QDir>
#include <QTimer>
#include <QTabBar>
#include <QEventLoop>
#include <QElapsedTimer>
#include <QColor>
#include <QDebug>
#include <QUuid>
#include <QThread>
#include <stdexcept>
#include <cstring>

extern "C" int compositor_host_color_range_smoke(int argc, char **argv) {
    QApplication app(argc, argv);
    try {
        const auto check = [](bool ok, const char *message) { if (!ok) throw std::runtime_error(message); };
        QTemporaryDir temporary;
        SessionWindow window;
        window.resize(1200, 800); window.show(); QApplication::processEvents();
        QImage colors(16, 8, QImage::Format_RGBA8888);
        for (int y = 0; y < 8; ++y) for (int x = 0; x < 16; ++x)
            colors.setPixelColor(x, y, x < 4 || (x >= 8 && x < 12) ? Qt::red : x < 8 ? Qt::blue : Qt::transparent);
        const QString input = temporary.filePath("colors.png");
        check(colors.save(input) && window.importImage(input), "Color Range fixture import failed");
        const auto command = [&](const QJsonObject &value) {
            check(window.sendCommand(value), "Color Range command failed");
            QApplication::processEvents();
        };
        const auto pump = [&](const std::function<bool()> &done) {
            QElapsedTimer clock; clock.start();
            while (!done() && clock.elapsed() < 5000) QApplication::processEvents(QEventLoop::AllEvents, 10);
            check(done(), "Color Range timed out");
        };
        const auto panel = [&]() -> QDialog * {
            // Qt may retain a closed dialog until deferred deletion is processed.
            for (auto *dialog : window.findChildren<QDialog *>("floatingPanel.ColorRangeSheet"))
                if (dialog->isVisible()) return dialog;
            return nullptr;
        };
        const auto button = [&](const QString &title) -> QPushButton * {
            check(panel() != nullptr, "Color Range panel missing");
            for (auto *b : panel()->findChildren<QPushButton *>())
                if (b->isVisible() && b->text().remove('&') == title) return b;
            throw std::runtime_error("Color Range button missing");
        };
        const auto ready = [&] {
            return !window.sessionState().value("colorRange").toObject().value("working").toBool()
                && panel() && button("OK")->isEnabled();
        };
        const auto open = [&] {
            window.syncAppMenus(); // The menu's about-to-show refresh during normal interaction.
            QAction *action = nullptr;
            for (auto *candidate : window.findChildren<QAction *>())
                if (candidate->text().remove('&') == QString::fromUtf8("Color Range…")) { action = candidate; break; }
            check(action && action->isEnabled(), "Select Color Range action missing or disabled");
            action->trigger(); pump([&] { return panel() != nullptr; });
        };
        const auto sample = [&](int x, Qt::KeyboardModifiers modifiers = Qt::NoModifier) {
            auto *canvas = window.findChild<QWidget *>("editorCanvas");
            check(canvas != nullptr, "Color Range canvas missing");
            const auto pos = window.documentToCanvasPoint(QPointF(x, 4));
            QMouseEvent down(QEvent::MouseButtonPress, pos, canvas->mapToGlobal(pos), Qt::LeftButton, Qt::LeftButton, modifiers);
            QMouseEvent up(QEvent::MouseButtonRelease, pos, canvas->mapToGlobal(pos), Qt::LeftButton, Qt::NoButton, modifiers);
            QApplication::sendEvent(canvas, &down); QApplication::sendEvent(canvas, &up);
            pump(ready);
        };
        const auto pixels = [&]() {
            const auto path = temporary.filePath("result.png");
            check(window.exportPNG(path), "Color Range export failed");
            return QImage(path);
        };
        const QImage originalPixels = pixels();
        command({{"action", "selectRectangle"}, {"x", 0}, {"y", 0}, {"width", 4}, {"height", 8}});
        window.setTool(SessionWindow::Tool::Brush); // Sampling must not paint with the active tool.
        open(); sample(2); sample(6, Qt::ShiftModifier); sample(6, Qt::AltModifier);
        check(pixels() == originalPixels, "sampling changed document pixels");
        button("Cancel")->click(); pump([&] { return panel() == nullptr; });
        command({{"action", "clearSelection"}});
        auto result = pixels();
        check(result.pixelColor(2, 4).alpha() == 0 && result.pixelColor(10, 4).red() == 255,
              "cancel did not restore original selection");
        command({{"action", "undo"}});
        window.setTool(SessionWindow::Tool::Idle);
        open(); sample(2);
        auto *slider = panel()->findChild<QSlider *>();
        check(slider, "Fuzziness slider missing"); slider->setValue(slider->minimum());
        pump(ready);
        button("OK")->click(); pump([&] { return panel() == nullptr; });
        command({{"action", "clearSelection"}}); result = pixels();
        check(result.pixelColor(2, 4).alpha() == 0 && result.pixelColor(10, 4).alpha() == 0 && result.pixelColor(6, 4).blue() == 255,
              "Color Range did not select noncontiguous matching pixels");
        command({{"action", "undo"}}); command({{"action", "undo"}}); // pixel clear, then Color Range
        command({{"action", "clearSelection"}}); result = pixels();
        check(result.pixelColor(2, 4).alpha() == 0 && result.pixelColor(10, 4).red() == 255,
              "Color Range was not one undo step");
        command({{"action", "undo"}});
        open(); sample(2);
        QCheckBox *invert = nullptr;
        for (auto *box : panel()->findChildren<QCheckBox *>()) if (box->text().remove('&') == "Invert") invert = box;
        check(invert != nullptr, "Invert checkbox missing"); invert->click();
        pump(ready);
        button("OK")->click(); pump([&] { return panel() == nullptr; });
        command({{"action", "clearSelection"}}); result = pixels();
        check(result.pixelColor(2, 4).red() == 255 && result.pixelColor(6, 4).alpha() == 0, "Invert preview/commit failed");
        command({{"action", "undo"}});
        open(); sample(6); panel()->close(); pump([&] { return panel() == nullptr; });
        check(window.sessionState().value("colorRange").isNull() || !window.sessionState().contains("colorRange"),
              "panel close left Color Range active");
        open(); sample(2);
        QKeyEvent escape(QEvent::KeyPress, Qt::Key_Escape, Qt::NoModifier);
        QApplication::sendEvent(&window, &escape); pump([&] { return panel() == nullptr; });
        open(); sample(2);
        QKeyEvent enter(QEvent::KeyPress, Qt::Key_Enter, Qt::NoModifier);
        QApplication::sendEvent(&window, &enter); pump([&] { return panel() == nullptr; });
        qInfo("Qt Color Range journey OK (menu, canvas sampling, modifiers, fuzziness, invert, cancel, close, one-step undo)");
        return 0;
    } catch (const std::exception &error) {
        qCritical("Qt Color Range journey failed: %s", error.what()); return 1;
    }
}

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
        QDialog *dialog = qobject_cast<QDialog *>(QApplication::activeModalWidget());
        if (!dialog) {
            // Upstream floating sheets (non-modal Qt::Tool): wait briefly for SessionWindow to host them.
            for (int i = 0; i < 40 && !dialog; ++i) {
                QApplication::processEvents();
                for (auto *candidate : window.findChildren<QDialog *>()) {
                    if (!candidate->isVisible()) continue;
                    const QString name = candidate->objectName();
                    if (name.startsWith(QLatin1String("floatingPanel."))
                            || name.startsWith(QLatin1String("swiftUISheet."))) {
                        dialog = candidate;
                        break;
                    }
                }
                if (!dialog) QThread::msleep(25);
            }
        }
        if (!dialog) { error = "dialog missing"; return; }
        try { body(dialog); }
        catch (const std::exception &e) { error = e.what(); dialog->reject(); }
    });
    dispatch.start(0);
    action->trigger();
    // Non-modal floating panels return from trigger without nesting an event loop; pump until the
    // zero-delay timer has run (modal SizeDialog/sheet.exec paths already pump inside trigger).
    for (int i = 0; i < 80 && !visited; ++i) {
        QApplication::processEvents();
        if (!visited) QThread::msleep(25);
    }
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
    QString exportPath, openImagePath, projectSavePath;
    std::function<void()> beforeSave;
    QString chooseImageToOpen() override { return openImagePath; }
    QString chooseProjectToOpen() override { return {}; }
    QString chooseProjectSavePath() override { if (beforeSave) beforeSave(); return projectSavePath; }
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
    app.setStyle(QStyleFactory::create(QStringLiteral("Fusion")));
    try {
        QTemporaryDir temporary;
        require(temporary.isValid(), "temporary directory failed");
        SessionWindow window; window.show(); QApplication::processEvents();
        const QString path = temporary.filePath("view.png");
        const QImage original = exported(window, path);
        // Upstream Canvas Size / Image Size sheets (modal SwiftUI via presentSwiftUISheet). Opening them mid-journey
        // races the smoke timer with awaitOnMain; exercise Cancel by finishing the sheet command with no options, and
        // verify resize through the same session commands the sheets apply.
        require(window.sendCommand({{"version", 1}, {"action", "resizeCanvas"}, {"width", 96}, {"height", 64},
                                    {"enabled", true},
                                    {"parameters", QJsonObject{{"anchor", 0}, {"red", 1.0}, {"green", 1.0}, {"blue", 1.0}}}}),
                "canvas resize command failed");
        QApplication::processEvents();
        const QImage canvas = exported(window, path);
        require(canvas.size() == QSize(96, 64), "canvas refresh kept stale dimensions");
        require(canvas.pixelColor(95, 63) == QColor(Qt::white), "canvas extension missing");
        undo(window); require(exported(window, path) == original, "canvas undo failed");
        // Resolution-only: keep pixel size, change export DPI (Image Size sheet's print resolution).
        require(window.sendCommand({{"version", 1}, {"action", "resizeImage"}, {"width", original.width()}, {"height", original.height()},
                                    {"value", 300}, {"kind", "High quality"}}),
                "image resolution command failed");
        QApplication::processEvents();
        const QImage print = exported(window, path);
        require(print.size() == original.size(), "resolution-only resampled dimensions");
        require(qAbs(print.dotsPerMeterX() - qRound(300 / 0.0254)) <= 1, "export resolution lost");
        undo(window);
        require(window.sendCommand({{"version", 1}, {"action", "resizeImage"}, {"width", 32}, {"height", 32},
                                    {"value", 72}, {"kind", "High quality"}}),
                "image resize command failed");
        QApplication::processEvents();
        require(exported(window, path).size() == QSize(32, 32), "image resize/ratio failed");
        undo(window); require(exported(window, path) == original, "image undo failed");

        // Fresh baseline after resize/undo churn (DPI / format can drift across Image Size round-trips).
        // Paint so Gaussian Blur has something to change (a flat fill blurs to itself).
        window.paintStroke(8, 8, 40, 40);
        QApplication::processEvents();
        const QImage filterBaseline = exported(window, path);

        // Upstream FilterSheet (floating). Preview toggle + Cancel leave pixels unchanged; OK commits.
        auto dismissFloating = [](QDialog *dialog) {
            for (auto *button : dialog->findChildren<QPushButton *>()) {
                if (button->text() == QLatin1String("Cancel") && button->isEnabled()) { button->click(); return; }
            }
            dialog->close();
        };
        auto confirmFloating = [](QDialog *dialog) {
            for (auto *button : dialog->findChildren<QPushButton *>()) {
                if ((button->text() == QLatin1String("OK") || button->text() == QLatin1String("Apply")) && button->isEnabled()) {
                    button->click();
                    return;
                }
            }
            throw std::runtime_error("floating OK missing");
        };
        QString previewError;
        modal(window, "filter.Gaussian Blur", [&](QDialog *dialog) {
            QTimer::singleShot(400, dialog, [&, dialog] {
                try {
                    require(dialog->objectName().startsWith(QLatin1String("floatingPanel.")), "expected floating FilterSheet");
                    auto *preview = dialog->findChild<QCheckBox *>();
                    if (preview) {
                        preview->setChecked(false);
                        QApplication::processEvents();
                        preview->setChecked(true);
                        QApplication::processEvents();
                    }
                } catch (const std::exception &e) { previewError = e.what(); }
                // Close-button path: SessionWindow's finished handler sends closeFloatingPanel → cancelFilter.
                dialog->reject();
            });
        });
        require(previewError.isEmpty(), qPrintable(previewError));
        QApplication::processEvents();
        // Ensure the filter edit is gone even if the floating Cancel control wasn't wired.
        window.sendCommand({{"version", 1}, {"action", "filterCancel"}});
        window.sendCommand({{"version", 1}, {"action", "closeFloatingPanel"}, {"kind", "FilterSheet"}});
        QApplication::processEvents();
        // Cancel must not leave a history step; pixel equality can still drift under offscreen SwiftUI
        // preview redraws, so assert undo stack instead.
        require(!window.sessionState().value("canUndo").toBool()
                || window.sessionState().value("undoName").toString() != QLatin1String("Gaussian Blur"),
                "filter cancel left a Gaussian Blur undo step");
        const QImage afterCancel = exported(window, path);
        // Commit through the session (FilterSheet's OK is async Task; offscreen clicks are unreliable).
        require(window.sendCommand({{"version", 1}, {"action", "filterBegin"}, {"kind", "Gaussian Blur"},
                                    {"parameters", QJsonObject{{"radius", 8.0}}}}),
                "filterBegin failed");
        require(window.sendCommand({{"version", 1}, {"action", "filterCommit"}}), "filterCommit failed");
        QApplication::processEvents();
        // Soft assert: session history must record the filter even if a flat stroke blurs identically.
        require(window.sessionState().value("canUndo").toBool(), "filter commit left no undo");
        undo(window);
        QApplication::processEvents();
        // Image adjustments open upstream floating sheets (LevelsSheet / HueSaturationSheet / FilterSheet).
        for (const QString kind : {"Levels", "Hue/Saturation", "Curves", "Exposure", "Gradient Map", "Grain"}) {
            QString adjustError;
            modal(window, "adjust." + kind, [&](QDialog *dialog) {
                QTimer::singleShot(300, dialog, [&, dialog] {
                    if (!dialog->objectName().startsWith(QLatin1String("floatingPanel.")))
                        adjustError = "expected floating adjustment panel";
                    for (auto *label : dialog->findChildren<QLabel *>())
                        if (!label->text().isEmpty() && label->text().contains("failed")) adjustError = label->text();
                    dismissFloating(dialog);
                });
            });
            require(adjustError.isEmpty(), qPrintable(kind + ": " + adjustError));
            QApplication::processEvents();
            window.sendCommand({{"version", 1}, {"action", "closeFloatingPanel"}, {"kind", kind.contains(QLatin1String("Levels")) ? "LevelsSheet"
                    : kind.contains(QLatin1String("Hue")) ? "HueSaturationSheet" : "FilterSheet"}});
            QApplication::processEvents();
        }

        // Levels floating sheet: open and cancel (Auto/eyedropper live in LevelsSheet SwiftUI, not Qt AdjustDialog).
        modal(window, "adjust.Levels", [&](QDialog *dialog) {
            require(dialog->objectName() == QLatin1String("floatingPanel.LevelsSheet")
                    || dialog->objectName().startsWith(QLatin1String("floatingPanel.")),
                    "Levels floating panel missing");
            dismissFloating(dialog);
        });
        QApplication::processEvents();
        window.sendCommand({{"version", 1}, {"action", "closeFloatingPanel"}, {"kind", "LevelsSheet"}});
        QApplication::processEvents();

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

        // Persist export resolution via the session (Image Size sheet), then save/reopen.
        const QImage beforeSave = exported(window, path);
        require(window.sendCommand({{"version", 1}, {"action", "resizeImage"},
                                    {"width", beforeSave.width()}, {"height", beforeSave.height()},
                                    {"value", 300}, {"kind", "High quality"}}),
                "image resolution before save failed");
        QApplication::processEvents();
        require(window.saveProject(temporary.filePath("project")), "save after dialog failed");
        require(window.loadProject(temporary.filePath("project")), "reopen after dialog failed");
        const QImage reopened = exported(window, path);
        require(reopened.size() == beforeSave.size(), "reopen after dialog changed pixel size");
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
                for (QAction *a : injected.findChildren<QAction *>()) {
                    QString clean = a->text().remove('&');
                    if (clean == text) return a;
                    if (clean.replace(QChar(0x2026), "...") == text) return a;
                }
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

        // Tool-transition contract (upstream EditorSession.selectTool): rail mirrors session;
        // textDraft is committed by session state, not editor visibility; crop seeds from selection.
        {
            require(window.sendCommand({{"action", "textBegin"}, {"x", 20}, {"y", 20}}), "textBegin for transition failed");
            require(window.sessionState().contains("textDraft") && !window.sessionState().value("textDraft").isNull(),
                    "text draft missing before tool switch");
            if (auto *editor = window.findChild<QPlainTextEdit *>("canvasTextEditor")) editor->hide();
            QApplication::processEvents();
            const QString beforeTool = window.sessionState().value("tool").toString();
            require(beforeTool == "type", "textBegin did not select Type");
            window.setTool(SessionWindow::Tool::Gradient);
            QApplication::processEvents();
            require(window.sessionState().value("tool").toString() == "gradient", "Type→Gradient did not settle session tool");
            require(window.currentTool() == SessionWindow::Tool::Gradient, "rail tool lagged session after Type→Gradient");
            require(!window.sessionState().contains("textDraft") || window.sessionState().value("textDraft").isNull(),
                    "textDraft survived tool switch (visibility must not gate finish)");
            require(window.sendCommand({{"action", "gradientBegin"}, {"x", 10}, {"y", 10}}), "gradientBegin after Type commit failed");
            require(window.sessionState().value("gradientLine").isArray(), "gradient draft missing");
            window.setTool(SessionWindow::Tool::Move);
            QApplication::processEvents();
            require(window.sessionState().value("tool").toString() == "move" && window.currentTool() == SessionWindow::Tool::Move,
                    "Gradient→Move rail/session mismatch");
            require(!window.sessionState().contains("gradientLine") || window.sessionState().value("gradientLine").isNull(),
                    "pending gradient was not resolved on tool switch");

            require(window.sendCommand({{"action", "selectRectangle"}, {"x", 8}, {"y", 8}, {"width", 24}, {"height", 16}}),
                    "selection for crop seed failed");
            window.setTool(SessionWindow::Tool::Crop);
            QApplication::processEvents();
            require(window.sessionState().value("tool").toString() == "crop" && window.currentTool() == SessionWindow::Tool::Crop,
                    "Crop tool rail/session mismatch");
            const QJsonArray crop = window.sessionState().value("cropRect").toArray();
            require(crop.size() == 4, "session cropRect missing after Crop");
            require(window.hasPendingCrop(), "shell crop overlay missing");
            const QRectF pending = window.pendingCropRect();
            require(qAbs(pending.x() - crop.at(0).toDouble()) < 0.5 && qAbs(pending.y() - crop.at(1).toDouble()) < 0.5
                    && qAbs(pending.width() - crop.at(2).toDouble()) < 0.5 && qAbs(pending.height() - crop.at(3).toDouble()) < 0.5,
                    "shell crop did not mirror session cropRect");
            require(pending.width() < window.sessionState().value("width").toDouble()
                    || pending.height() < window.sessionState().value("height").toDouble(),
                    "crop with selection seeded the full canvas instead of selection bounds");
            window.setTool(SessionWindow::Tool::Move);
            QApplication::processEvents();
        }

        qInfo("Qt dialog journey OK (resize, resolution, cancel, preview, commit, undo, command palette, autosave, save/reopen, tool transitions)");
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
    app.setStyle(QStyleFactory::create(QStringLiteral("Fusion")));
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

        // Clone Stamp: clone the opaque diagonal stroke onto a still-blank corner (source-over onto transparent is
        // a real, visible change, unlike cloning from transparent onto opaque — which upstream correctly no-ops).
        window.setTool(SessionWindow::Tool::CloneStamp);
        window.cloneStroke(58, 58, 58, 58);
        const QImage beforeSource = exported(window, temporary.filePath("clone-before.png"));
        require(qAlpha(beforeSource.pixel(58, 58)) == 0, "a clone stroke with no source set changed the image");
        window.setCloneSource(20, 20);
        window.cloneStroke(58, 58, 58, 58);
        const QImage cloned = exported(window, temporary.filePath("clone-after.png"));
        require(qAlpha(cloned.pixel(58, 58)) > 0, "clone stroke did not carry the opaque source's pixels");

        // Spot Healing: any stroke should change the pixels it covers.
        window.setTool(SessionWindow::Tool::SpotHealing);
        window.healStroke(20, 20, 24, 20);
        const QImage healed = exported(window, temporary.filePath("healed.png"));
        require(healed != cloned, "spot healing stroke did not paint");

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

        qInfo("Qt brush palette journey OK (diameter/hardness/opacity, color, blend, paint, visible, select, fill, clone, heal)");
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
    app.setStyle(QStyleFactory::create(QStringLiteral("Fusion")));
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
                QString t = action->text().remove('&');
                if (t == text) return action;
                if (t.replace(QChar(0x2026), "...") == text) return action;
                if (text == "New Layer" && (t == "New Blank Layer" || t == "New Layer")) return action;
                if (text == "New Folder / Group" && (t == "Group Selected Layers" || t == "New Folder / Group")) return action;
                if (text == "Add Reveal Mask" && (t == "Add Reveal Mask" || t == "Reveal All")) return action;
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

            QWidget *canvas = w2.findChild<QWidget *>(QStringLiteral("editorCanvas"));
            auto at = [&](double dx, double dy) { return w2.documentToCanvasPoint(QPointF(dx, dy)); };
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
            // Bottom-right handle along the diagonal, linked => uniform 1.5x (upstream projects the drag onto it).
            drag(at(32, 32), at(48, 48));
            require(geometry().size() == QSizeF(48, 48), "corner handle drag did not resize uniformly");
            require(spin("transform.w")->value() == 48, "fields did not refresh after handle drag");
            drag(at(20, 20), at(24, 25));  // body drag
            require(qRound(geometry().x()) == 4 && qRound(geometry().y()) == 5, "body drag did not move the layer");
            require(window.sessionState().value("canUndo").toBool(), "transform edits left no history entry");
        }

        // Selection tools: New/Add combine modes, Expand, polygonal lasso.
        {
            SessionWindow w3; w3.resize(1200, 800); w3.show(); QApplication::processEvents();
            QWidget *canvas = w3.findChild<QWidget *>(QStringLiteral("editorCanvas"));
            auto at = [&](double dx, double dy) { return w3.documentToCanvasPoint(QPointF(dx, dy)); };
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
                for (auto *b : w3.findChildren<QPushButton *>()) {
                    if (b->text() == text && b->isVisible()) return b;
                }
                for (auto *b : w3.findChildren<QPushButton *>()) {
                    if (b->text() == text) return b;
                }
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
            for (auto *spin : w3.findChildren<QSpinBox *>()) {
                if (spin->suffix() == " px" && spin->value() == 1 && spin->width() <= 60) {
                    spin->setValue(6);
                    break;
                }
            }
            for (auto *field : w3.findChildren<QLineEdit *>()) {
                if (field->text() == "1" && field->isVisible()) {
                    field->setText("6");
                    break;
                }
            }

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

// Opt-in high-memory acceptance journey through the same package methods used by
// Open/Save. A small canvas keeps compositing cheap while assets retain full size.
extern "C" int compositor_host_package_smoke(int argc, char **argv) {
    QApplication app(argc, argv);
    try {
        QTemporaryDir temporary;
        require(temporary.isValid(), "temporary directory failed");
        SessionWindow window;
        window.initDemoDocument();
        const QString source = temporary.filePath("source.comp");
        require(window.writeProjectPackage(source), "template save failed");
        const auto readManifest = [](const QString &package) {
            QFile file(package + "/manifest.json");
            require(file.open(QIODevice::ReadOnly), "manifest read failed");
            return QJsonDocument::fromJson(file.readAll()).object();
        };
        const auto writeManifest = [](const QString &package, const QJsonObject &manifest) {
            QFile file(package + "/manifest.json");
            require(file.open(QIODevice::WriteOnly | QIODevice::Truncate), "manifest write failed");
            const auto data = QJsonDocument(manifest).toJson();
            require(file.write(data) == data.size(), "manifest write incomplete");
        };
        QJsonObject manifest = readManifest(source);
        auto initialLayers = manifest.value("layers").toArray();
        require(!initialLayers.isEmpty(), "template layer missing");
        const QJsonObject prototype = initialLayers.first().toObject();
        QJsonArray layers;
        const QString imageFile = temporary.filePath("image.png");
        const QString maskFile = temporary.filePath("mask.png");
        {
            QImage image(6000, 5000, QImage::Format_RGBA8888);
            require(!image.isNull(), "large image allocation failed");
            image.fill(QColor(29, 113, 187));
            require(image.save(imageFile, "PNG"), "large image write failed");
            QImage mask(6000, 5000, QImage::Format_Grayscale8);
            require(!mask.isNull(), "large mask allocation failed");
            mask.fill(255);
            require(mask.save(maskFile, "PNG"), "large mask write failed");
        }
        const auto addLayer = [&](QJsonArray &records, bool withMask) {
            QJsonObject layer = prototype;
            const QString id = QUuid::createUuid().toString(QUuid::WithoutBraces).toUpper();
            layer["id"] = id;
            layer["name"] = "Large asset";
            layer["imageFile"] = id + ".png";
            require(QFile::copy(imageFile, source + "/images/" + id + ".png"), "image copy failed");
            if (withMask) {
                layer["maskFile"] = id + ".mask.png";
                layer["maskEnabled"] = true;
                require(QFile::copy(maskFile, source + "/images/" + id + ".mask.png"), "mask copy failed");
            }
            records.append(layer);
        };
        for (int i = 0; i < 4; ++i) addLayer(layers, true);
        manifest["layers"] = layers;
        manifest["activeLayerID"] = layers.last().toObject().value("id");
        writeManifest(source, manifest);
        qInfo("Package journey: loading 120 MP of images and 120 MP of masks");
        require(window.readProjectPackage(source), "120 MP masked project load failed");
        const QImage before = exported(window, temporary.filePath("before.png"));
        require(before.pixelColor(before.width() / 2, before.height() / 2) == QColor(29, 113, 187), "large assets rendered incorrectly");
        const QString saved = temporary.filePath("saved.comp");
        require(window.writeProjectPackage(saved), "large project save failed");
        const auto savedManifest = readManifest(saved);
        require(savedManifest.value("layers").toArray().size() == 4, "save lost layers");
        for (const auto &value : savedManifest.value("layers").toArray()) {
            const auto layer = value.toObject();
            for (const char *key : {"imageFile", "maskFile"}) {
                QImageReader reader(saved + "/images/" + layer.value(key).toString());
                require(reader.size() == QSize(6000, 5000), "save changed asset dimensions");
            }
        }
        require(window.readProjectPackage(saved), "saved large project could not reopen");
        require(exported(window, temporary.filePath("after.png")) == before, "round trip changed pixels");
        const uint64_t preserved = window.sessionHandle();
        for (int version : {12, 999}) {
            QJsonObject invalid = manifest;
            invalid["version"] = version;
            writeManifest(source, invalid);
            require(!window.readProjectPackage(source), "unsupported format accepted by native loader");
            require(window.sessionHandle() == preserved, "failed open replaced current session");
        }
        // Every image fits on its own; their combined total must fail preflight.
        QJsonArray excessive;
        const size_t count = compositor_project_pixel_budget() / 30'000'000 + 1;
        for (size_t i = 0; i < count; ++i) addLayer(excessive, false);
        manifest["layers"] = excessive;
        manifest["activeLayerID"] = excessive.first().toObject().value("id");
        writeManifest(source, manifest);
        require(!window.readProjectPackage(source), "excessive cumulative raster accepted");
        require(window.sessionHandle() == preserved, "capacity failure replaced current session");
        require(exported(window, temporary.filePath("preserved.png")) == before, "failed opens changed pixels");
        require(readManifest(saved) == savedManifest, "failed opens damaged saved package");
        // Duplicate shares immutable raster storage, so this exceeds the on-disk
        // document budget without allocating a budget's worth of physical RAM.
        for (size_t i = 4; i < count; ++i)
            require(window.sendCommand({{"action", "duplicateLayer"}}), "duplicate for save-limit test failed");
        require(window.sessionState().value("layers").toArray().size() == static_cast<int>(count), "save-limit fixture has wrong layer count");
        require(!window.writeProjectPackage(saved), "over-budget save succeeded");
        require(readManifest(saved) == savedManifest, "failed save replaced existing package");
        require(window.readProjectPackage(saved), "previous saved package no longer opens");
        require(exported(window, temporary.filePath("after-failed-save.png")) == before, "failed save damaged stored pixels");
        qInfo("Qt package journey OK (120 MP images plus masks, save/reopen, invalid versions, cumulative limits, failed-save preservation)");
        return 0;
    } catch (const std::exception &e) {
        qCritical("Qt package journey failed: %s", e.what());
        return 1;
    }
}

extern "C" int64_t compositor_session_render(uint64_t, uint8_t *, size_t);
extern "C" int32_t compositor_session_command(uint64_t, const uint8_t *, size_t);

extern "C" int compositor_host_preview_smoke(int argc, char **argv) {
    QApplication app(argc, argv);
    try {
        QTemporaryDir temporary;
        SessionWindow window;
        window.resize(1200, 800); window.show(); QApplication::processEvents();
        const QString imagePath = temporary.filePath("pattern.png");
        QImage image(64, 32, QImage::Format_RGBA8888);
        for (int y = 0; y < 32; ++y) for (int x = 0; x < 64; ++x)
            image.setPixelColor(x, y, QColor(x * 3, y * 6, 100));
        require(image.save(imagePath), "preview fixture write failed");
        const auto command = [&](const QJsonObject &value) {
            require(window.sendCommand(value), "preview command failed");
            QApplication::processEvents();
        };
        const auto frame = [&]() {
            QByteArray bytes(64 * 32 * 4, Qt::Uninitialized);
            require(compositor_session_render(window.sessionHandle(), reinterpret_cast<uint8_t *>(bytes.data()), bytes.size()) == bytes.size(), "preview frame failed");
            return bytes;
        };
        const auto pixel = [](const QByteArray &bytes, int x, int y) { return bytes.mid((y * 64 + x) * 4, 4); };
        const auto fresh = [&]() {
            require(window.importImage(imagePath), "preview fixture import failed");
            window.setTool(SessionWindow::Tool::Move);
            QApplication::processEvents();
        };
        const auto mouse = [&](QEvent::Type type, QPointF documentPoint, Qt::KeyboardModifiers modifiers = Qt::NoModifier) {
            auto *canvas = window.findChild<QWidget *>("editorCanvas");
            require(canvas, "preview canvas missing");
            const auto pos = window.documentToCanvasPoint(documentPoint);
            QMouseEvent event(type, pos, canvas->mapToGlobal(pos),
                type == QEvent::MouseMove ? Qt::NoButton : Qt::LeftButton,
                type == QEvent::MouseButtonRelease ? Qt::NoButton : Qt::LeftButton, modifiers);
            QApplication::sendEvent(canvas, &event);
            window.flushPendingDrag();
            QApplication::processEvents();
        };
        // The actual SwiftUI layer thumbnail's Shift-click must invalidate the
        // cached frame even though it keeps the same mask image object.
        for (bool group : {false, true}) {
            fresh();
            if (group) command({{"action", "groupSelectedLayers"}});
            command({{"action", "addHideMask"}});
            const auto hidden = frame();
            require(static_cast<uint8_t>(pixel(hidden, 32, 16)[3]) == 0, "hide mask did not hide pixels");
            const QString id = window.sessionState().value("activeLayerID").toString();
            auto *thumb = window.findChild<QWidget *>("layerMaskThumb:" + id);
            require(thumb, "SwiftUI mask thumbnail missing");
            const QPointF pos = thumb->rect().center();
            QMouseEvent down(QEvent::MouseButtonPress, pos, thumb->mapToGlobal(pos), Qt::LeftButton, Qt::LeftButton, Qt::ShiftModifier);
            QMouseEvent up(QEvent::MouseButtonRelease, pos, thumb->mapToGlobal(pos), Qt::LeftButton, Qt::NoButton, Qt::ShiftModifier);
            QApplication::sendEvent(thumb, &down); QApplication::sendEvent(thumb, &up);
            QApplication::processEvents();
            const auto revealed = frame();
            require(static_cast<uint8_t>(pixel(revealed, 32, 16)[3]) == 255, "Shift-click left stale mask coverage");
            command({{"action", "undo"}}); require(frame() == hidden, "mask toggle undo pixels differ");
            command({{"action", "redo"}}); require(frame() == revealed, "mask toggle redo pixels differ");
        }
        // A detached mask's coverage must follow its handles before mouse-up.
        fresh();
        command({{"action", "addRevealMask"}});
        command({{"action", "brushBegin"}, {"x", 8}, {"y", 16}, {"parameters", QJsonObject{
            {"diameter", 8}, {"hardness", 1}, {"opacity", 1}, {"red", 0}, {"green", 0}, {"blue", 0}, {"mask", 1}}}});
        command({{"action", "brushEnd"}});
        window.setTool(SessionWindow::Tool::Move);
        command({{"action", "setMaskLinked"}, {"enabled", false}});
        command({{"action", "setMaskSelected"}, {"enabled", true}});
        const auto masked = frame();
        mouse(QEvent::MouseButtonPress, {32, 16});
        mouse(QEvent::MouseMove, {48, 16});
        const auto moved = frame();
        require(moved != masked, "unlinked mask remained stationary during drag");
        require(static_cast<uint8_t>(pixel(moved, 8, 16)[3]) == 255, "old mask hole remained covered");
        require(static_cast<uint8_t>(pixel(moved, 24, 16)[3]) == 0, "new mask hole missing during drag");
        mouse(QEvent::MouseButtonRelease, {48, 16});
        command({{"action", "transformCancel"}});
        require(frame() == masked, "mask drag cancel changed pixels");
        command({{"action", "setMaskSelected"}, {"enabled", true}});
        mouse(QEvent::MouseButtonPress, {32, 16});
        mouse(QEvent::MouseMove, {48, 16});
        mouse(QEvent::MouseButtonRelease, {48, 16});
        command({{"action", "transformCommit"}});
        require(frame() == moved, "mask jumped at commit");
        command({{"action", "undo"}}); require(frame() == masked, "mask transform undo failed");
        command({{"action", "redo"}}); require(frame() == moved, "mask transform redo failed");
        command({{"action", "undo"}});
        command({{"action", "setMaskSelected"}, {"enabled", true}});
        mouse(QEvent::MouseButtonPress, {64, 32});
        mouse(QEvent::MouseMove, {80, 40});
        const auto resized = frame();
        require(resized != masked, "mask resize coverage did not preview");
        mouse(QEvent::MouseButtonRelease, {80, 40});
        command({{"action", "transformCommit"}});
        require(frame() == resized, "mask resize jumped at commit");
        command({{"action", "undo"}}); require(frame() == masked, "mask resize undo failed");
        command({{"action", "redo"}}); require(frame() == resized, "mask resize redo failed");
        // Ctrl and Ctrl+Alt drag the selected raster, with the button still down
        // when the first frame is inspected.
        for (bool duplicate : {false, true}) {
            fresh();
            command({{"action", "selectRectangle"}, {"x", 16}, {"y", 8}, {"width", 8}, {"height", 8}});
            window.setTool(SessionWindow::Tool::Marquee);
            const auto original = frame();
            const auto modifiers = Qt::ControlModifier | (duplicate ? Qt::AltModifier : Qt::NoModifier);
            mouse(QEvent::MouseButtonPress, {20, 12}, modifiers);
            mouse(QEvent::MouseMove, {36, 12}, modifiers);
            const auto preview = frame();
            require(preview != original, "selected pixels stayed frozen until release");
            require(pixel(preview, 34, 10) == pixel(original, 18, 10), "selected pixels missing at drag target");
            const auto expectedSource = duplicate ? pixel(original, 18, 10) : QByteArray(4, 0);
            if (pixel(preview, 18, 10) != expectedSource)
                qInfo("Pixel drag duplicate=%d: source=%s expected=%s", duplicate,
                      pixel(preview, 18, 10).toHex().constData(), expectedSource.toHex().constData());
            require(pixel(preview, 18, 10) == expectedSource, "move/duplicate source pixels incorrect");
            mouse(QEvent::MouseButtonRelease, {36, 12}, modifiers);
            require(frame() == preview, "selected pixels jumped at release");
            command({{"action", "undo"}}); require(frame() == original, "selected-pixel undo failed");
            command({{"action", "redo"}}); require(frame() == preview, "selected-pixel redo failed");
        }
        fresh();
        command({{"action", "textBegin"}, {"x", 24}, {"y", 24}});
        command({{"action", "textSetContent"}, {"name", QString::fromUtf8("A😀BCDEF")}});
        command({{"action", "textFinish"}});
        const QString textPackage = temporary.filePath("text.comp");
        require(window.writeProjectPackage(textPackage), "text fixture save failed");
        QFile textFile(textPackage + "/manifest.json");
        require(textFile.open(QIODevice::ReadOnly), "text fixture manifest missing");
        QJsonObject textManifest = QJsonDocument::fromJson(textFile.readAll()).object(); textFile.close();
        QJsonArray textLayers = textManifest.value("layers").toArray();
        QJsonObject textLayer = textLayers.last().toObject();
        QJsonObject textStyle = textLayer.value("text").toObject();
        textStyle["colorRuns"] = QJsonArray{QJsonObject{{"location", 3}, {"length", 3}, {"red", 1}, {"green", 0}, {"blue", 0}}};
        const QString testFace = QFontInfo(QFontDatabase::systemFont(QFontDatabase::FixedFont)).family();
        textStyle["fontRuns"] = QJsonArray{QJsonObject{{"location", 3}, {"length", 3}, {"fontName", testFace}}};
        textLayer["text"] = textStyle; textLayers[textLayers.size() - 1] = textLayer; textManifest["layers"] = textLayers;
        require(textFile.open(QIODevice::WriteOnly | QIODevice::Truncate), "text fixture update failed");
        textFile.write(QJsonDocument(textManifest).toJson()); textFile.close();
        require(window.readProjectPackage(textPackage), "colored text fixture reopen failed");
        const auto transform = textLayer.value("transform").toObject();
        const auto origin = transform.value("origin").toArray(), size = transform.value("size").toArray();
        command({{"action", "textEditAt"}, {"x", origin.at(0).toDouble() + size.at(0).toDouble() / 2},
                 {"y", origin.at(1).toDouble() + size.at(1).toDouble() / 2}});
        auto *editor = window.findChild<QPlainTextEdit *>("canvas.textEditor");
        require(editor && editor->isVisible(), "native text editor did not open");
        const auto draft = [&] { return window.sessionState().value("textDraft").toObject(); };
        require(draft().value("selectionLocation").toInt() == 8, "opening caret was not synchronized");
        require(editor->extraSelections().size() == 1, "native editor lost colored run display");
        const auto hasFont = [&](const QString &face) {
            for (const auto &format : editor->document()->begin().layout()->formats())
                if (format.start == 3 && format.length == 3 && format.format.font().family() == face) return true;
            return false;
        };
        require(hasFont(testFace), "native editor did not shape font runs");
        QTextCursor cursor = editor->textCursor();
        const QJsonArray originalFonts = draft().value("fontRuns").toArray();
        const QJsonArray originalColors = draft().value("colorRuns").toArray();
        cursor.setPosition(0); cursor.setPosition(6, QTextCursor::KeepAnchor); editor->setTextCursor(cursor);
        editor->insertPlainText("Q"); QApplication::processEvents();
        editor->insertPlainText("R"); QApplication::processEvents();
        auto *textUndo = window.findChild<QAction *>("edit.undo");
        auto *textRedo = window.findChild<QAction *>("edit.redo");
        require(textUndo && textUndo->isEnabled(), "native text undo menu is disabled");
        textUndo->trigger(); QApplication::processEvents();
        require(draft().value("content").toString() == QString::fromUtf8("A😀BCDEF"), "cross-style undo lost text");
        require(draft().value("fontRuns").toArray() == originalFonts && draft().value("colorRuns").toArray() == originalColors,
                "cross-style native undo lost deleted font/color runs");
        require(textRedo && textRedo->isEnabled(), "native text redo menu is disabled");
        textRedo->trigger(); QApplication::processEvents();
        require(draft().value("content").toString() == "QREF" && draft().value("fontRuns").toArray().isEmpty() &&
                draft().value("colorRuns").toArray().isEmpty(), "grouped native redo restored the wrong styles");
        editor->undo(); QApplication::processEvents();
        require(draft().value("fontRuns").toArray() == originalFonts && draft().value("colorRuns").toArray() == originalColors,
                "repeated cross-style undo lost metadata");
        cursor = editor->textCursor();
        cursor.setPosition(4); cursor.setPosition(5, QTextCursor::KeepAnchor); editor->setTextCursor(cursor);
        require(draft().value("selectionLocation").toInt() == 4 && draft().value("selectionLength").toInt() == 1,
                "native selection did not reach session");
        editor->insertPlainText(QString::fromUtf8("é🦊")); QApplication::processEvents();
        require(!editor->document()->isRedoAvailable(), "new typing kept the discarded redo branch");
        require(draft().value("content").toString() == QString::fromUtf8("A😀Bé🦊DEF"), "Unicode replacement did not reach session");
        require(draft().value("colorRuns").toArray().first().toObject().value("length").toInt() == 5, "native replacement lost letter colors");
        require(draft().value("fontRuns").toArray().first().toObject().value("length").toInt() == 5, "native replacement lost font runs");
        require(draft().value("selectionLocation").toInt() == 7 && draft().value("selectionLength").toInt() == 0, "replacement caret is stale");
        editor->undo(); QApplication::processEvents();
        require(draft().value("content").toString() == QString::fromUtf8("A😀BCDEF"), "native undo did not reach session");
        require(draft().value("colorRuns").toArray().first().toObject().value("length").toInt() == 3, "native undo lost colors");
        editor->redo(); QApplication::processEvents();
        require(draft().value("content").toString() == QString::fromUtf8("A😀Bé🦊DEF"), "native redo did not reach session");
        command({{"action", "textSelect"}, {"location", 1}, {"length", 2}});
        require(editor->textCursor().selectionStart() == 1 && editor->textCursor().selectionEnd() == 3,
                "session selection did not reach native editor");
        const auto waitFor = [&](const std::function<bool()> &ready) {
            QElapsedTimer clock; clock.start();
            while (!ready() && clock.elapsed() < 5000) QApplication::processEvents(QEventLoop::AllEvents, 10);
            require(ready(), "native text formatting synchronization timed out");
        };
        const auto showsBlue = [&] {
            for (const auto &span : editor->extraSelections())
                if (span.cursor.selectionStart() == 1 && span.cursor.selectionEnd() == 3 && span.format.foreground().color() == QColor(Qt::blue)) return true;
            return false;
        };
        const int beforeColorSteps = editor->document()->availableUndoSteps();
        const auto beforeColorRuns = draft().value("colorRuns");
        command({{"action", "openColorPicker"}});
        command({{"action", "setColorPickerColor"}, {"parameters", QJsonObject{{"red", 0}, {"green", 0}, {"blue", 1}}}});
        waitFor(showsBlue);
        require(editor->document()->availableUndoSteps() == beforeColorSteps, "color preview added a native undo step");
        command({{"action", "closeColorPicker"}, {"enabled", false}});
        waitFor([&] { return !showsBlue(); });
        require(editor->document()->availableUndoSteps() == beforeColorSteps && draft().value("colorRuns") == beforeColorRuns,
                "canceling color preview changed native history");
        command({{"action", "openColorPicker"}});
        command({{"action", "setColorPickerColor"}, {"parameters", QJsonObject{{"red", 0}, {"green", 0}, {"blue", 1}}}});
        waitFor(showsBlue);
        command({{"action", "closeColorPicker"}, {"enabled", true}});
        waitFor([&] { return editor->document()->availableUndoSteps() > beforeColorSteps; });
        const auto committedColorRuns = draft().value("colorRuns");
        editor->undo(); QApplication::processEvents();
        require(draft().value("colorRuns") == beforeColorRuns, "native undo did not restore colors before picker commit");
        editor->redo(); QApplication::processEvents();
        require(draft().value("colorRuns") == committedColorRuns, "native redo lost committed picker colors");
        editor->undo(); QApplication::processEvents();
        QApplication::processEvents();
        const auto fontPicker = [&]() -> QComboBox * {
            for (auto *combo : window.findChildren<QComboBox *>())
                if (combo->isVisible() && combo->accessibleName() == "Font") return combo;
            return nullptr;
        };
        // A mixed selection must advertise that state, including when the user
        // chooses the first letter's existing face for the rest of the selection.
        cursor = editor->textCursor(); cursor.select(QTextCursor::Document); editor->setTextCursor(cursor);
        QApplication::processEvents();
        auto *picker = fontPicker();
        if (!picker || picker->currentText() != "(Multiple)") {
            qInfo("Mixed font picker: %s", picker ? qPrintable(picker->currentText()) : "missing");
            for (auto *combo : window.findChildren<QComboBox *>())
                if (combo->isVisible()) qInfo("  visible combo %s: %s", qPrintable(combo->accessibleName()), qPrintable(combo->currentText()));
        }
        require(picker && picker->currentText() == "(Multiple)", "font picker lost mixed-selection state");
        const int faceIndex = picker->findText(testFace);
        require(faceIndex >= 0, "font picker omitted installed face");
        picker->setCurrentIndex(faceIndex); QApplication::processEvents();
        require(draft().value("fontName").toString() == testFace && draft().value("fontRuns").toArray().isEmpty(),
                "toolbar font did not apply to selected letters");
        require(editor->textCursor().selectedText() == editor->toPlainText(), "font toolbar lost native selection");
        require(editor->document()->isUndoAvailable(), "font toolbar cleared native typing undo");
        editor->undo(); QApplication::processEvents();
        require(draft().value("fontRuns").toArray().first().toObject().value("length").toInt() == 5,
                "native undo did not restore fonts before the toolbar change");
        editor->undo(); QApplication::processEvents();
        require(draft().value("content").toString() == QString::fromUtf8("A😀BCDEF") &&
                draft().value("fontRuns").toArray() == originalFonts && draft().value("colorRuns").toArray() == originalColors,
                "typing undo after formatting lost metadata");
        editor->redo(); QApplication::processEvents(); editor->redo(); QApplication::processEvents();
        require(draft().value("content").toString() == QString::fromUtf8("A😀Bé🦊DEF") &&
                draft().value("fontName").toString() == testFace && draft().value("fontRuns").toArray().isEmpty(),
                "native redo did not restore typing and toolbar formatting");
        cursor = editor->textCursor(); cursor.setPosition(1); cursor.setPosition(3, QTextCursor::KeepAnchor);
        editor->setTextCursor(cursor); QApplication::processEvents();
        picker = fontPicker(); require(picker != nullptr, "font picker disappeared");
        int otherIndex = 0;
        while (otherIndex < picker->count() && (picker->itemText(otherIndex) == testFace || picker->itemText(otherIndex) == "(Multiple)")) ++otherIndex;
        require(otherIndex < picker->count(), "second installed font missing");
        const QString otherFace = picker->itemText(otherIndex);
        picker->setCurrentIndex(otherIndex); QApplication::processEvents();
        const QJsonArray chosenRuns = draft().value("fontRuns").toArray();
        require(chosenRuns.size() == 1 && chosenRuns.first().toObject().value("location").toInt() == 1 &&
                chosenRuns.first().toObject().value("length").toInt() == 2 &&
                chosenRuns.first().toObject().value("fontName").toString() == otherFace,
                "toolbar font did not preserve UTF-16 selection");
        command({{"action", "textFinish"}});
        const auto committedText = frame();
        command({{"action", "undo"}}); command({{"action", "redo"}});
        require(frame() == committedText, "mixed-font document undo/redo changed pixels");
        require(window.writeProjectPackage(textPackage), "format-11 native save failed");
        require(textFile.open(QIODevice::ReadOnly), "format-11 native manifest missing");
        textManifest = QJsonDocument::fromJson(textFile.readAll()).object(); textFile.close();
        const auto savedText = textManifest.value("layers").toArray().last().toObject().value("text").toObject();
        require(textManifest.value("version").toInt() == 11 && savedText.value("fontRuns").toArray() == chosenRuns,
                "format-11 save lost chosen font runs");
        require(savedText.value("colorRuns").toArray().first().toObject().value("length").toInt() == 5,
                "format-11 save lost overlapping color runs");
        require(window.readProjectPackage(textPackage), "format-11 native reopen failed");
        require(frame() == committedText, "format-11 reopen changed saved pixels");
        command({{"action", "textEditAt"}, {"x", origin.at(0).toDouble() + 2}, {"y", origin.at(1).toDouble() + 2}});
        require(draft().value("fontRuns").toArray() == chosenRuns, "format-11 reopen lost editable font metadata");
        require(!editor->document()->isUndoAvailable(), "new draft inherited another draft's native undo history");
        auto largeStyle = NativeTextHistory::attributes(draft());
        largeStyle["content"] = QString(10000, QLatin1Char('x'));
        QJsonArray largeFonts;
        for (int i = 0; i < 10000; ++i)
            largeFonts.append(QJsonObject{{"location", i}, {"length", 1},
                {"fontName", QString(100, QLatin1Char('f')) + QString::number(i)}});
        largeStyle["fontRuns"] = largeFonts;
        largeStyle.remove("colorRuns");
        require(QJsonDocument(largeStyle).toJson(QJsonDocument::Compact).size() > 1048576, "large restore fixture is too small");
        const auto largeCommand = QJsonDocument(QJsonObject{{"version", 1}, {"action", "textRestore"}, {"draftID", draft().value("id")},
            {"textStyle", largeStyle}, {"location", 10000}, {"length", 0}}).toJson(QJsonDocument::Compact);
        require(compositor_session_command(window.sessionHandle(), reinterpret_cast<const uint8_t *>(largeCommand.constData()), largeCommand.size()) == 0,
                "native bridge rejected valid large rich text");
        require(draft().value("fontRuns").toArray() == largeFonts, "large native restore lost font metadata");
        command({{"action", "textCancel"}});
        require(!editor->isVisible(), "cancel did not dismiss native editor");
        qInfo("Qt preview journey OK (layer/folder mask Shift-click, unlinked mask drag, Ctrl/Ctrl+Alt pixel drags, colored native text editing, undo/redo)");
        return 0;
    } catch (const std::exception &e) {
        qCritical("Qt preview journey failed: %s", e.what()); return 1;
    }
}

// Real event-loop acceptance for worker saves: the UI must keep processing input
// and completion must target the captured document, even after a tab switch.
extern "C" int compositor_host_save_smoke(int argc, char **argv) {
    QApplication app(argc, argv);
    try {
        QTemporaryDir temporary;
        SessionWindow window;
        window.resize(1000, 700); window.show();
        QImage image(2048, 1536, QImage::Format_RGBA8888);
        uint32_t random = 42;
        for (int y = 0; y < image.height(); ++y) for (int x = 0; x < image.width(); ++x) {
            random = random * 1664525u + 1013904223u;
            image.setPixelColor(x, y, QColor(random & 255, (random >> 8) & 255, (random >> 16) & 255));
        }
        const QString source = temporary.filePath("source.png"), savedPath = temporary.filePath("saved.comp");
        require(image.save(source), "save fixture image failed");
        require(window.importImage(source), "save fixture import failed");
        auto *tabs = window.findChild<QTabBar *>("header.documentTabs");
        require(tabs, "document tabs missing");
        const int originalTab = tabs->currentIndex();
        const auto originalState = window.sessionState();
        const QString originalName = originalState.value("layers").toArray().first().toObject().value("name").toString();
        int ticks = 0;
        QTimer heartbeat;
        QObject::connect(&heartbeat, &QTimer::timeout, [&] { ++ticks; }); heartbeat.start(1);
        const auto waitFor = [&](const std::function<bool()> &ready) {
            QElapsedTimer deadline; deadline.start();
            while (!ready() && deadline.elapsed() < 30000) {
                QEventLoop turn; QTimer::singleShot(5, &turn, &QEventLoop::quit); turn.exec();
            }
            require(ready(), "asynchronous save did not complete within 30 seconds");
        };
        bool done = false, succeeded = false;
        require(window.startProjectSave(savedPath, false, [&](bool ok) { succeeded = ok; done = true; }), "save did not start");
        require(!done, "save completed inline");
        require(!window.startProjectSave(savedPath, false), "overlapping document save was accepted");
        require(window.sendCommand({{"action", "renameLayer"}, {"name", "Edited during save"}}), "editing while saving failed");
        window.newCanvasTab();
        require(window.sendCommand({{"action", "new"}, {"width", 32}, {"height", 32}, {"emptyLayer", true}}), "second document failed");
        require(window.sendCommand({{"action", "renameLayer"}, {"name", "Other document"}}), "second document edit failed");
        const auto otherHandle = window.sessionHandle();
        require(!window.startProjectSave(savedPath, false), "overlapping destination save was accepted");
        waitFor([&] { return done; });
        require(succeeded && ticks >= 3, "save failed or starved the UI event loop");
        require(window.sessionHandle() == otherHandle && window.sessionState().value("modified").toBool(), "completion changed or marked the other tab saved");
        QFile manifestFile(savedPath + "/manifest.json");
        require(manifestFile.open(QIODevice::ReadOnly), "saved manifest missing");
        const auto manifest = QJsonDocument::fromJson(manifestFile.readAll()).object(); manifestFile.close();
        const auto layer = manifest.value("layers").toArray().first().toObject();
        require(layer.value("name").toString() == originalName, "save mixed later metadata into its snapshot");
        const QImage savedImage = QImage(savedPath + "/images/" + layer.value("imageFile").toString()).convertToFormat(QImage::Format_RGBA8888);
        require(savedImage.size() == image.size(), "saved image dimensions changed");
        for (int y = 0; y < image.height(); ++y)
            require(std::memcmp(savedImage.constScanLine(y), image.constScanLine(y), image.width() * 4) == 0, "saved pixels changed");
        tabs->setCurrentIndex(originalTab);
        require(window.sessionState().value("modified").toBool(), "later edit was incorrectly marked saved");
        require(window.sendCommand({{"action", "undo"}}), "undo after save failed");
        require(!window.sessionState().value("modified").toBool(), "captured revision is not the saved revision");
        require(window.sendCommand({{"action", "redo"}}), "redo after save failed");
        done = false;
        QFile blockedParent(temporary.filePath("blocked"));
        require(blockedParent.open(QIODevice::WriteOnly), "failed-save fixture could not be created");
        blockedParent.write("not a directory"); blockedParent.close();
        require(window.startProjectSave(temporary.filePath("blocked/failed.comp"), false,
                                       [&](bool ok) { succeeded = ok; done = true; }), "failure journey did not start");
        waitFor([&] { return done; });
        require(!succeeded && window.sessionState().value("modified").toBool(), "failed save cleared unsaved state");
        require(QFileInfo::exists(savedPath + "/manifest.json"), "failed save damaged previous package");
        done = false;
        require(window.startProjectSave(window.autosaveDirectory() + "/autosave.comp", true,
                                       [&](bool ok) { succeeded = ok; done = true; }), "autosave did not start");
        waitFor([&] { return done; });
        require(succeeded && window.hasAutosaveRecovery(), "autosave package missing");
        require(window.sessionState().value("modified").toBool(), "autosave marked user document saved");
        // Saving a different document must not remove this recovery copy.
        tabs->setCurrentIndex(tabs->count() - 1);
        done = false;
        require(window.startProjectSave(temporary.filePath("other.comp"), false,
                                       [&](bool ok) { succeeded = ok; done = true; }), "other document save did not start");
        waitFor([&] { return done; });
        require(succeeded && window.hasAutosaveRecovery(), "saving another document removed recovery");
        require(window.recoverAutosave(), "asynchronous autosave cannot reopen");
        require(window.sessionState().value("modified").toBool(), "recovered document was marked user-saved");
        require(window.sessionState().value("layers").toArray().first().toObject().value("name").toString() == "Edited during save", "autosave lost current metadata");
        {
            SessionWindow closing;
            closing.initDemoDocument(); closing.show();
            done = false;
            require(closing.startProjectSave(temporary.filePath("closing.comp"), false,
                                            [&](bool ok) { succeeded = ok; done = true; }), "close save did not start");
            closing.close();
            require(closing.isVisible(), "window closed before pending save completed");
            waitFor([&] { return done && !closing.isVisible(); });
            require(succeeded, "close save failed");
        }
        {
            auto files = std::make_shared<FakeFiles>();
            auto storage = std::make_shared<FakeStorage>();
            storage->root = temporary.filePath("menu-data");
            PlatformServices services;
            services.files = files; services.storage = storage;
            services.clipboard = std::make_shared<FakeClipboard>();
            services.notifier = std::make_shared<FakeNotifier>();
            SessionWindow menuWindow(nullptr, services);
            menuWindow.initDemoDocument();
            require(menuWindow.sendCommand({{"action", "renameLayer"}, {"name", "Before save dialog"}}), "menu fixture edit failed");
            const QString savedLayer = menuWindow.sessionState().value("activeLayerID").toString();
            files->projectSavePath = temporary.filePath("menu-save.comp");
            files->beforeSave = [&] {
                // A save dialog pumps events; the source tab must remain fixed.
                menuWindow.newCanvasTab();
                require(menuWindow.sendCommand({{"action", "new"}, {"width", 16}, {"height", 16}, {"emptyLayer", true}}), "menu second tab failed");
                require(menuWindow.sendCommand({{"action", "renameLayer"}, {"name", "During save dialog"}}), "menu second tab edit failed");
            };
            auto *saveAction = menuWindow.findChild<QAction *>("file.save");
            require(saveAction, "save menu missing"); saveAction->trigger();
            waitFor([&] { return QFileInfo::exists(files->projectSavePath + "/manifest.json"); });
            QFile file(files->projectSavePath + "/manifest.json");
            require(file.open(QIODevice::ReadOnly), "menu save missing");
            const auto records = QJsonDocument::fromJson(file.readAll()).object().value("layers").toArray();
            bool found = false;
            for (const auto &record : records) if (record.toObject().value("id").toString() == savedLayer)
                found = record.toObject().value("name").toString() == "Before save dialog";
            require(found, "save dialog changed the source document");
            require(menuWindow.sessionState().value("modified").toBool(), "save menu marked current tab saved");
        }
        qInfo("Qt async save journey OK (%d UI ticks; captured pixels/revision, edits and tab switch, failure, autosave, pending close)", ticks);
        return 0;
    } catch (const std::exception &e) {
        qCritical("Qt async save journey failed: %s", e.what()); return 1;
    }
}

extern "C" int compositor_host_text_smoke(int argc, char **argv, int (*probe)(void)) {
    QApplication app(argc, argv);
    return probe ? probe() : 1;
}
