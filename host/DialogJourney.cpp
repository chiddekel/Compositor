#include "CompositorUIFont.h"
#include "QtTextFont.h"
// Qt event-loop journey, invoked by the Swift composition root with --dialog-smoke.
// Uses actual menu actions, modal controls, codecs, and the real Swift session.
#include "SessionWindow.h"
#include "SwiftUIQtRenderer.h"
#include "ProjectPackageLimits.h"
#include "EditorDialogs.h"
#include "SystemClipboard.h"
#include "ImageImportDialog.h"
#include "RawControlJourney.h"
#include "AutosaveJourney.h"
#include "GridSettingsJourney.h"
#include "CanvasSizeJourney.h"
#include "ImageSizeJourney.h"
#include "UIAuditJourney.h"
#include "DesktopProbeJourney.h"
#include "InputProbeJourney.h"
#include "Upstream154Journey.h"
#include "FontHistoryJourney.h"
#include "ChannelPackJourney.h"
#include "DispersionJourney.h"
#include "ArtboardJourney.h"
#include "MaskDragJourney.h"
#include "OtherApplications.h"
#include "compositor_host_run.h"
#include "interfaces/IPlatformServices.h"
#include <QAction>
#include <QScopeGuard>
#include <csignal>
#include <sys/wait.h>
#include <QApplication>
#include <QAccessible>
#include <QClipboard>
#include <QMimeData>
#include <QMessageBox>
#include <QMenu>
#include <QMenuBar>
#include <QDropEvent>
#include <QUrl>
#include <QProcess>
#include <QProcessEnvironment>
#include <QStyleFactory>
#include <QCheckBox>
#include <QComboBox>
#include <QColorSpace>
#include <QDialogButtonBox>
#include <QDockWidget>
#include <QDoubleSpinBox>
#include <QGraphicsOpacityEffect>
#include <QImageReader>
#include <QLabel>
#include <QRegularExpression>
#include <QTransform>
#include <QJsonArray>
#include <QJsonDocument>
#include <QTreeView>
#include <QSpinBox>
#include <QMouseEvent>
#include <QWheelEvent>
#include <QNativeGestureEvent>
#include <QPointingDevice>
#include <QKeyEvent>
#include <QStandardItemModel>
#include <QPushButton>
#include <QToolButton>
#include <QSlider>
#include <QScrollArea>
#include <QScrollBar>
#include <QLineEdit>
#include <QPlainTextEdit>
#include <QInputMethodEvent>
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
#include <QWindow>
#include <QTabBar>
#include <QEventLoop>
#include <QElapsedTimer>
#include <QColor>
#include <QDebug>
#include <QDataStream>
#include <QUuid>
#include <QThread>
#include <memory>
#include <utility>
#include <QStatusBar>
#include <QTouchEvent>
#include <QTabletEvent>
#include <QPointingDevice>
#include <QtTest/qtestkeyboard.h>
#include <stdexcept>
#include <cmath>
#include <cstring>
#include <cstdlib>

using PackageImageDecode = int32_t (*)(const uint8_t *, size_t, uint8_t **, int32_t *, int32_t *, int32_t *, double *, int32_t *, char *, size_t);
using PackageImageEncode = int32_t (*)(const uint8_t *, int32_t, int32_t, int32_t, const char *, double, double, int32_t, uint8_t **, size_t *);
extern "C" int compositor_qt_imageio_functions(PackageImageDecode *, PackageImageEncode *);
extern "C" int compositor_qt_imageio_deep_decode(PackageImageDecode *);

static void installJourneyUI(QApplication &app) {
    installCompositorUIFont(app);
    compositor_host_install_menu_tracking_bridge();
}

extern "C" int32_t compositor_workspace_select_tab(uint64_t handle);
extern "C" int64_t compositor_current_layer_drag(uint8_t *output, size_t capacity);
extern "C" int32_t compositor_workspace_layer_drop_allowed(uint64_t destination, const uint8_t *bytes, size_t count, int32_t modifiers);
extern "C" void compositor_set_native_text_action_handler(int32_t (*handler)(const char *));
extern "C" int64_t compositor_session_render(uint64_t, uint8_t *, size_t);
extern "C" int64_t compositor_session_render_tree(uint64_t, const char *, uint8_t *, size_t);
extern "C" int64_t compositor_session_accessibility_tree(uint64_t, const char *, const char *, uint8_t *, size_t);
extern "C" int32_t compositor_session_viewport(uint64_t, double *);
extern "C" int32_t compositor_install_subject_model(void);

/// Tool combinations through the visible Qt rail, canvas events and inline text editor.
// Exact pixel oracles exclude alignment snapping. At 100% its screen-space tolerance covers more document pixels
// than the enlarged fit these fixtures used before upstream capped opening zoom. Dedicated snap cases opt in.
static void setPixelOracleSnapping(SessionWindow &window, bool enabled) {
    QPointer<QMenu> view = window.findChild<QMenu *>("appMenu.View");
    if (!view) throw std::runtime_error("pixel oracle View menu missing");
    QMetaObject::invokeMethod(view, "aboutToShow", Qt::DirectConnection);
    QPointer<QAction> snap;
    for (auto *action : view->actions()) if (action->text().remove('&') == QLatin1String("Snap")) snap = action;
    if (!snap || !snap->isEnabled() || !snap->isCheckable()) throw std::runtime_error("pixel oracle Snap toggle missing");
    if (snap->isChecked() != enabled) {
        snap->trigger();
        QApplication::processEvents();
    }
}

static void disablePixelOracleSnapping(SessionWindow &window) { setPixelOracleSnapping(window, false); }

extern "C" int compositor_host_combo_smoke(int argc, char **argv) {
    QApplication app(argc, argv);
    installJourneyUI(app);
    if (app.arguments().contains("--autosave-crash-writer")) return autosavejourney::writer(app);
    if (app.arguments().contains("--autosave-crash-probe")) return autosavejourney::run(app);
    if (app.arguments().contains("--grid-settings-probe")) return gridsettingsjourney::run(app);
    if (app.arguments().contains("--canvas-size-controls-probe")) return canvassizejourney::run(app);
    if (app.arguments().contains("--image-size-controls-probe")) return imagesizejourney::run(app);
    if (app.arguments().contains("--ui-audit-probe")) return uiauditjourney::run(app);
    if (app.arguments().contains("--desktop-probe")) return desktopprobe::run(app);
    if (app.arguments().contains("--input-probe")) return inputprobe::run(app);
    if (app.arguments().contains("--upstream-154-probe")) return upstream154journey::run(app);
    if (app.arguments().contains("--font-history-probe")) return fonthistoryjourney::run(app);
    if (app.arguments().contains("--dispersion-probe")) return dispersionjourney::run(app);
    if (app.arguments().contains("--psd-artboard-probe")) return artboardjourney::run(app);
    if (app.arguments().contains("--psd-artboard-conversion-probe")) return artboardjourney::runConversions(app);
    if (app.arguments().contains("--channel-pack-probe")) return channelpackjourney::run(app);
    if (app.arguments().contains("--mask-drag-probe")) return maskdragjourney::run(app, disablePixelOracleSnapping);
    try {
        const auto check = [](bool ok, const char *message) { if (!ok) throw std::runtime_error(message); };
        QTemporaryDir temporary;
        check(temporary.isValid(), "combination temporary directory unavailable");
        SessionWindow window;
        window.resize(1200, 900); window.show(); QApplication::setActiveWindow(&window); QApplication::processEvents();
        auto *canvas = window.findChild<QWidget *>("editorCanvas");
        check(canvas, "combination canvas missing");
        const auto pump = [&](const std::function<bool()> &done, const char *message = "combination did not settle within five seconds") {
            QElapsedTimer clock; clock.start();
            while (!done() && clock.elapsed() < 5000) {
                QApplication::processEvents(QEventLoop::AllEvents, 10);
                QThread::msleep(1);
            }
            if (!done()) {
                const auto state = window.sessionState();
                qWarning().noquote() << "combination timeout:" << message << "tool=" << state.value("tool").toString()
                    << "busy=" << state.value("busy").toBool() << "canSwitch=" << state.value("canSwitch").toBool()
                    << "gradientLine=" << state.value("gradientLine").toArray();
                throw std::runtime_error(message);
            }
        };
        const auto writeProjectPackage = [&](const QString &path) {
            // The real autosave timer uses the same per-document save guard.
            pump([&] { return !window.isProjectSaveInProgress(); }, "autosave did not finish before package verification");
            return window.writeProjectPackage(path);
        };
        const auto command = [&](QJsonObject value) {
            check(window.sendCommand(value), "combination setup command failed");
            QApplication::processEvents();
        };
        const auto mouse = [&](QWidget *target, QEvent::Type type, QPointF position,
                               Qt::MouseButton button, Qt::MouseButtons held, Qt::KeyboardModifiers modifiers) {
            if (target == canvas && type == QEvent::MouseButtonPress && !app.arguments().contains("--transform-snap-probe"))
                setPixelOracleSnapping(window, window.sessionState().value("tool").toString() == QLatin1String("crop"));
            QMouseEvent event(type, position, target->mapToGlobal(position.toPoint()), button, held, modifiers);
            QApplication::sendEvent(target, &event);
            QApplication::processEvents();
        };
        const auto click = [&](QWidget *target) {
            check(target && target->isVisible() && target->isEnabled(), "combination control is unavailable");
            const QPointF center = target->rect().center();
            mouse(target, QEvent::MouseButtonPress, center, Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
            mouse(target, QEvent::MouseButtonRelease, center, Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
        };
        const auto railButton = [&](const QString &label) -> QPushButton * {
            auto *rail = window.findChild<QWidget *>("swiftUIToolRailContainer");
            check(rail, "upstream tool rail missing");
            for (auto *button : rail->findChildren<QPushButton *>())
                if (button->isVisible() && button->accessibleName().startsWith(label)) return button;
            throw std::runtime_error("upstream tool rail button missing");
        };
        const auto checkTool = [&](const QString &label, const QString &name) {
            check(window.sessionState().value("tool").toString() == name, "rail/session tool mismatch");
            // Inspect the displayed selection, not the shell's hidden legacy actions.
            check(!railButton(label)->styleSheet().contains("border: 1px solid transparent;"),
                  "rail does not display the session's selected tool");
        };
        const auto tool = [&](const QString &label, const QString &name) {
            const auto before = window.sessionState();
            auto *button = railButton(label);
            bool clicked = false;
            const auto connection = QObject::connect(button, &QPushButton::clicked, &window, [&] { clicked = true; });
            click(button);
            QObject::disconnect(connection);
            if (!clicked) {
                const QByteArray message = QString("rail pointer click did not emit clicked for %1").arg(name).toUtf8();
                throw std::runtime_error(message.constData());
            }
            const QByteArray message = QString("rail click did not select %1").arg(name).toUtf8();
            try { pump([&] { return window.sessionState().value("tool").toString() == name; }, message.constData()); }
            catch (...) {
                qWarning() << "rail before click" << name << "busy=" << before.value("busy")
                           << "canSwitch=" << before.value("canSwitch");
                throw;
            }
            checkTool(label, name);
        };
        const auto key = [&](QWidget *target, int code, Qt::KeyboardModifiers modifiers = Qt::NoModifier,
                             const QString &text = QString()) {
            target->setFocus();
            check(QApplication::focusWidget() == target, "combination key target did not acquire focus");
            // The window overload delivers through Qt's platform-key path, including shortcut dispatch. Sending
            // a QKeyEvent straight to a widget skips that stage. This helper links only QtGui's event support.
            QTest::sendKeyEvent(QTest::Click, window.windowHandle(), static_cast<Qt::Key>(code), text, modifiers);
        };
        const auto at = [&](double x, double y) { return window.documentToCanvasPoint(QPointF(x, y)); };
        const auto drag = [&](QPointF from, QPointF to, Qt::KeyboardModifiers modifiers = Qt::NoModifier) {
            canvas->setFocus();
            mouse(canvas, QEvent::MouseButtonPress, from, Qt::LeftButton, Qt::LeftButton, modifiers);
            mouse(canvas, QEvent::MouseMove, (from + to) / 2, Qt::NoButton, Qt::LeftButton, modifiers);
            mouse(canvas, QEvent::MouseMove, to, Qt::NoButton, Qt::LeftButton, modifiers);
            mouse(canvas, QEvent::MouseButtonRelease, to, Qt::LeftButton, Qt::NoButton, modifiers);
            pump([&] { return !window.sessionState().value("busy").toBool(); }, "canvas drag did not finish its busy operation");
        };
        const auto pixels = [&] {
            const auto state = window.sessionState();
            check(state.value("width").toInt() == 64 && state.value("height").toInt() == 64,
                  "combination raster dimensions changed");
            // Read the live raster without encoding files; export behavior is checked separately.
            QByteArray bytes(64 * 64 * 4, Qt::Uninitialized);
            check(compositor_session_render(window.sessionHandle(), reinterpret_cast<uint8_t *>(bytes.data()), bytes.size()) == bytes.size(),
                  "combination raster unavailable");
            return QImage(reinterpret_cast<const uchar *>(bytes.constData()), 64, 64, 64 * 4,
                          QImage::Format_RGBA8888_Premultiplied).copy().convertToFormat(QImage::Format_RGBA8888);
        };
        const auto unchangedOutside = [&](const QImage &before, const QImage &after, const QRect &inside) {
            for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x)
                if (!inside.contains(x, y)) check(before.pixelColor(x, y) == after.pixelColor(x, y),
                                                  "combination changed pixels outside its selection");
        };
        QImage fixture(64, 64, QImage::Format_RGBA8888);
        fixture.fill(Qt::transparent);
        for (int y = 16; y < 32; ++y) for (int x = 16; x < 32; ++x) fixture.setPixelColor(x, y, Qt::red);
        const QString input = temporary.filePath("input.png");
        check(fixture.save(input), "combination fixture save failed");
        const auto reset = [&] {
            check(window.importImage(input), "combination fixture import failed");
            command({{"action", "setShowsTransformControls"}, {"enabled", false}});
            command({{"action", "deselect"}});
        };
        const auto inputTargets = [&] {
            // Exercise the application input filter through the handle it actually widens, rather than reading a flag.
            QPointingDevice finger("smoke touchscreen", 101, QInputDevice::DeviceType::TouchScreen,
                                   QPointingDevice::PointerType::Finger, QInputDevice::Capability::Position, 10, 0);
            QPointingDevice pen("smoke pen", 102, QInputDevice::DeviceType::Stylus,
                                QPointingDevice::PointerType::Pen,
                                QInputDevice::Capability::Position | QInputDevice::Capability::Pressure, 1, 1);
            const auto touch = [&](QWidget *receiver) {
                const QPointF position(20, 20);
                QTouchEvent event(QEvent::TouchBegin, &finger, Qt::NoModifier,
                                  {QEventPoint(1, QEventPoint::State::Pressed, position, receiver->mapToGlobal(position.toPoint()))});
                QApplication::sendEvent(receiver->window()->windowHandle(), &event);
                QTouchEvent end(QEvent::TouchEnd, &finger, Qt::NoModifier,
                                {QEventPoint(1, QEventPoint::State::Released, position, receiver->mapToGlobal(position.toPoint()))});
                QApplication::sendEvent(receiver->window()->windowHandle(), &end);
            };
            const auto tablet = [&](QWidget *receiver) {
                const QPointF position(20, 20);
                QTabletEvent event(QEvent::TabletPress, &pen, position, receiver->mapToGlobal(position.toPoint()),
                                   0.5, 0, 0, 0, 0, 0, Qt::NoModifier, Qt::LeftButton, Qt::LeftButton);
                QApplication::sendEvent(receiver, &event);
                QTabletEvent end(QEvent::TabletRelease, &pen, position, receiver->mapToGlobal(position.toPoint()),
                                 0, 0, 0, 0, 0, 0, Qt::NoModifier, Qt::LeftButton, Qt::NoButton);
                QApplication::sendEvent(receiver, &end);
            };
            const auto prepareHandles = [&] {
                reset(); tool("Move", "move");
                // This checks the wider touch target on a large object. Small objects deliberately cap handle reach
                // to retain a draggable interior; their geometry is covered separately by TouchTargetsTests.
                command({{"action", "resizeImage"}, {"width", 200}, {"height", 200}});
                command({{"action", "setShowsTransformControls"}, {"enabled", true}});
                command({{"action", "setTransformAutoSelect"}, {"enabled", false}});
                // The native canvas refresh runs on its event timer. Wait for its cached document rectangle before
                // calculating a pointer position; the session already has 200 pixels while the host may still show 64.
                pump([&] {
                    const double scale = window.sessionState().value("zoom").toDouble() / canvas->devicePixelRatioF();
                    return std::abs(window.canvasTargetRect().width() - 200 * scale) < 0.01;
                }, "input-device fixture did not reach the native canvas");
            };
            const auto grabNearCorner = [&](Qt::MouseEventSource source, bool shouldGrab,
                                            const QPointingDevice *device = QPointingDevice::primaryPointingDevice()) {
                const auto before = window.sessionState().value("layers").toArray().first().toObject().value("transform");
                const QPointF start = at(0, 0) + QPointF(-22, 0);
                const auto send = [&](QEvent::Type type, QPointF position, Qt::MouseButton button, Qt::MouseButtons held) {
                    QMouseEvent event(type, position, position, canvas->mapToGlobal(position.toPoint()), button, held,
                                      Qt::NoModifier, source, device);
                    QApplication::sendEvent(canvas, &event); QApplication::processEvents();
                };
                send(QEvent::MouseButtonPress, start, Qt::LeftButton, Qt::LeftButton);
                check(window.sessionState().value("transforming").toBool(), "input-device press did not start a transform");
                // Move past the document-edge snap distance as well as the drag threshold.
                send(QEvent::MouseMove, start + QPointF(24, 24), Qt::NoButton, Qt::LeftButton);
                send(QEvent::MouseButtonRelease, start + QPointF(24, 24), Qt::LeftButton, Qt::NoButton);
                check(!window.sessionState().value("transforming").toBool(), "input-device handle release left an edit open");
                const auto after = window.sessionState().value("layers").toArray().first().toObject().value("transform");
                check(after != before, "input-device drag did not change geometry");
                // Move can drag the active layer from outside its bounds. A handle grab resizes it; a body drag only moves.
                if ((after.toObject().value("size") != before.toObject().value("size")) != shouldGrab)
                    qWarning() << "input target mismatch: source=" << int(source) << "pointer=" << int(device->pointerType())
                               << "expected resize=" << shouldGrab << "start=" << start
                               << "before=" << before << "after=" << after
                               << "zoom=" << window.sessionState().value("zoom");
                check((after.toObject().value("size") != before.toObject().value("size")) == shouldGrab,
                      "touch/mouse/pen input chose the wrong transform hit region");
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(window.sessionState().value("layers").toArray().first().toObject().value("transform") == before,
                      "input-device drag Undo did not restore its geometry");
            };
            for (auto source : {Qt::MouseEventSynthesizedByQt, Qt::MouseEventSynthesizedBySystem, Qt::MouseEventSynthesizedByApplication}) {
                prepareHandles(); touch(&window); grabNearCorner(source, true);
                qInfo("touch: finger -> synthesized mouse source %d keeps large targets OK", int(source));
                prepareHandles(); touch(&window); tablet(&window); grabNearCorner(source, false);
                prepareHandles(); touch(&window); grabNearCorner(source, false, &pen);
                qInfo("touch: pen -> synthesized mouse source %d restores normal targets OK", int(source));
            }
            prepareHandles(); touch(&window); grabNearCorner(Qt::MouseEventNotSynthesized, false);
            qInfo("touch: real mouse restores normal targets OK");
            prepareHandles();
            {
                SessionWindow second;
                second.resize(1200, 900); second.show(); QApplication::processEvents();
                touch(&second);
            }
            QApplication::setActiveWindow(&window); QApplication::processEvents();
            grabNearCorner(Qt::MouseEventSynthesizedByQt, true);
            qInfo("touch: second-window touch survives window destruction OK");
            // Finish with ordinary hit regions for the next test process or a later QApplication.
            grabNearCorner(Qt::MouseEventNotSynthesized, false);
            qInfo("Qt touch input smoke OK (synthetic device events; physical-device verification remains separate)");
        };
        if (app.arguments().contains("--touch-targets-probe")) { inputTargets(); return 0; }

        const auto gradient = [&](QPointF from, QPointF to) {
            tool("Gradient", "gradient");
            drag(from, to);
            check(window.sessionState().value("gradientLine").toArray().size() == 4,
                  "gradient release did not leave an editable line");
            key(canvas, Qt::Key_Return);
            pump([&] { return window.sessionState().value("gradientLine").toArray().isEmpty()
                              && !window.sessionState().value("busy").toBool(); }, "Return did not commit the pending gradient");
        };

        if (app.arguments().contains("--app-visibility-probe")) {
            reset();
            command({{"action", "renameLayer"}, {"name", "First unsaved image"}});
            SessionWindow other; other.resize(1000, 800); other.show();
            QImage blue(64, 64, QImage::Format_RGBA8888); blue.fill(QColor(20, 80, 200));
            const QString path = temporary.filePath("visibility-other.png");
            check(blue.save(path) && other.importImage(path), "visibility second document import failed");
            check(other.sendCommand({{"action", "renameLayer"}, {"name", "Second unsaved image"}}), "visibility second edit failed");
            const auto firstBefore = window.sessionState(), secondBefore = other.sessionState();
            const auto read = [&](SessionWindow &owner, const QString &name) {
                const QString output = temporary.filePath(name + ".png");
                check(owner.exportPNG(output), "visibility raster export failed");
                QImage image(output); check(image.size() == QSize(64, 64), "visibility raster dimensions changed");
                return image.convertToFormat(QImage::Format_RGBA8888);
            };
            const QImage firstPixels = read(window, "first-before"), secondPixels = read(other, "second-before");
            const auto isolated = [&](SessionWindow &owner, const QJsonObject &before, const QImage &original, const QString &name) {
                const auto state = owner.sessionState();
                for (const char *field : {"width", "height", "layers", "activeLayerID", "modified", "canUndo", "canRedo",
                                          "undoName", "redoName", "foregroundColor", "backgroundColor", "tool", "hasSelection"})
                    check(state.value(field) == before.value(field), "application visibility changed document or editing state");
                check(read(owner, name) == original, "application visibility changed pixels");
            };
            const auto hideApplication = [&](SessionWindow &owner) {
                QAction *hide = nullptr;
                for (auto *top : owner.menuBar()->actions()) if (top->isVisible() && top->menu()
                    && top->menu()->objectName() == "appMenu.Compositor") {
                    emit top->menu()->aboutToShow();
                    for (auto *action : top->menu()->actions())
                        if (action->isVisible() && action->text().remove('&') == "Hide Compositor") hide = action;
                }
                check(hide && hide->isEnabled(), "visible Hide Compositor action missing or disabled"); hide->trigger();
            };
            const auto appMenuAction = [&](SessionWindow &owner, const QString &title) {
                QAction *found = nullptr;
                for (auto *top : owner.menuBar()->actions()) if (top->isVisible() && top->menu()
                    && top->menu()->objectName() == "appMenu.Compositor") {
                    emit top->menu()->aboutToShow();
                    for (auto *action : top->menu()->actions())
                        if (action->isVisible() && action->text().remove('&') == title) found = action;
                }
                check(found, "visible application-menu action missing");
                return found;
            };
            window.showNormal(); other.showNormal();
            QApplication::setActiveWindow(&window); window.activateWindow(); QApplication::processEvents();
            {
                // Window menu as AppKit completes it: Minimize, Zoom, Bring All to Front, then the window, checked.
                QMenu *windowMenu = nullptr;
                for (auto *top : window.menuBar()->actions())
                    if (top->isVisible() && top->menu() && top->menu()->objectName() == "appMenu.Window") windowMenu = top->menu();
                check(windowMenu, "visible Window menu missing");
                emit windowMenu->aboutToShow();
                QStringList titles;
                QAction *bring = nullptr, *entry = nullptr;
                for (auto *action : windowMenu->actions()) {
                    if (!action->isVisible()) continue;
                    titles << (action->isSeparator() ? QStringLiteral("-") : action->text().remove('&'));
                    if (action->text().remove('&') == "Bring All to Front") bring = action;
                    if (action->text().remove('&') == "Compositor") entry = action;
                }
                const std::string shown = "Window menu differs from AppKit's: " + titles.join(", ").toStdString();
                check(titles == QStringList({"Minimize", "Zoom", "-", "Bring All to Front", "-", "Compositor"}), shown.c_str());
                check(entry->isCheckable() && entry->isChecked(), "the window's own entry is not checked");
                window.showMinimized(); QApplication::processEvents();
                bring->trigger();
                QElapsedTimer settle; settle.start();
                while (settle.elapsed() < 300 && window.isMinimized()) QApplication::processEvents(QEventLoop::AllEvents, 10);
                check(!window.isMinimized() && window.isVisible(), "Bring All to Front left the project window minimized");
                qInfo("Qt Window menu OK (Minimize, Zoom, Bring All to Front, checked window entry; Bring All to Front restores)");
            }
            if (!OtherApplications::canHideOthers()) {
                // No window manager lets this client hide other applications (Wayland, offscreen): Hide Others is
                // disabled rather than silently doing nothing, and Show All leaves every project window as it was.
                check(!appMenuAction(window, "Hide Others")->isEnabled(), "Hide Others enabled without a window manager that supports it");
                QAction *showAll = appMenuAction(window, "Show All");
                check(showAll->isEnabled(), "Show All disabled"); showAll->trigger();
                QElapsedTimer settle; settle.start();
                while (settle.elapsed() < 200) QApplication::processEvents(QEventLoop::AllEvents, 10);
                check(window.isVisible() && other.isVisible() && !window.isMinimized() && !other.isMinimized(),
                    "Show All changed project windows");
                isolated(window, firstBefore, firstPixels, "first-show-all");
                isolated(other, secondBefore, secondPixels, "second-show-all");
                qInfo("Qt Hide Others/Show All OK (no client window management: Hide Others disabled, Show All leaves both windows and documents unchanged)");
            }
#if defined(COMPOSITOR_HAS_XCB_APPLICATIONS)
            else {
                // A separate X11 client process with one shown window and one its user minimized.
                xcb_connection_t *c = OtherApplications::connection();
                int ready[2]; check(::pipe(ready) == 0, "foreign client pipe failed");
                const pid_t child = ::fork();
                check(child >= 0, "foreign client fork failed");
                if (child == 0) {
                    ::close(ready[0]);
                    xcb_connection_t *foreign = xcb_connect(nullptr, nullptr);
                    if (xcb_connection_has_error(foreign)) _exit(2);
                    const xcb_screen_t *screen = xcb_setup_roots_iterator(xcb_get_setup(foreign)).data;
                    const auto intern = [&](const char *name) { return OtherApplications::atom(foreign, name); };
                    const uint32_t pid = uint32_t(getpid());
                    xcb_window_t windows[2];
                    for (int i = 0; i < 2; i++) {
                        windows[i] = xcb_generate_id(foreign);
                        const uint32_t background = i ? 0x2050c0 : 0xc05020;
                        xcb_create_window(foreign, XCB_COPY_FROM_PARENT, windows[i], screen->root, 40 + 260 * i, 40, 220, 160, 0,
                            XCB_WINDOW_CLASS_INPUT_OUTPUT, screen->root_visual, XCB_CW_BACK_PIXEL, &background);
                        const char *title = i ? "Foreign minimized" : "Foreign shown";
                        xcb_change_property(foreign, XCB_PROP_MODE_REPLACE, windows[i], XCB_ATOM_WM_NAME, XCB_ATOM_STRING, 8, strlen(title), title);
                        xcb_change_property(foreign, XCB_PROP_MODE_REPLACE, windows[i], intern("_NET_WM_PID"), XCB_ATOM_CARDINAL, 32, 1, &pid);
                        xcb_map_window(foreign, windows[i]);
                    }
                    xcb_flush(foreign);
                    for (int attempt = 0; attempt < 400; attempt++) {
                        if (OtherApplications::property32(foreign, screen->root, "_NET_CLIENT_LIST").contains(windows[1])) break;
                        usleep(10000);
                    }
                    xcb_client_message_event_t iconify{};
                    iconify.response_type = XCB_CLIENT_MESSAGE; iconify.format = 32; iconify.window = windows[1];
                    iconify.type = intern("WM_CHANGE_STATE"); iconify.data.data32[0] = 3;
                    xcb_send_event(foreign, 0, screen->root, XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT | XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY,
                        reinterpret_cast<const char *>(&iconify));
                    xcb_flush(foreign);
                    const uint32_t ids[2] = {windows[0], windows[1]};
                    if (::write(ready[1], ids, sizeof ids) != sizeof ids) _exit(3);
                    for (;;) { xcb_generic_event_t *event = xcb_wait_for_event(foreign); if (!event) _exit(0); free(event); }
                }
                ::close(ready[1]);
                const auto stopChild = qScopeGuard([&] { ::kill(child, SIGTERM); ::waitpid(child, nullptr, 0); });
                uint32_t ids[2] = {0, 0};
                check(::read(ready[0], ids, sizeof ids) == sizeof ids, "foreign client did not create its windows");
                ::close(ready[0]);
                const auto iconic = [&](uint32_t id) { return OtherApplications::isIconic(c, id); };
                const auto managed = [&](uint32_t id) { return OtherApplications::otherClientWindows(c).contains(id); };
                pump([&] { return managed(ids[0]) && managed(ids[1]) && !iconic(ids[0]) && iconic(ids[1]); },
                    "foreign client windows were not managed as shown and user-minimized");
                for (QWidget *top : QApplication::topLevelWidgets())
                    if (top->windowHandle()) check(!managed(uint32_t(top->winId())), "Hide Others counts a Compositor window as another application");
                QAction *hideOthers = appMenuAction(window, "Hide Others");
                check(hideOthers->isEnabled(), "Hide Others disabled under an X11 window manager");
                hideOthers->trigger();
                pump([&] { return iconic(ids[0]); }, "Hide Others did not hide the other application's window");
                check(iconic(ids[1]), "Hide Others changed the user-minimized window");
                check(window.isVisible() && other.isVisible() && !window.isMinimized() && !other.isMinimized(),
                    "Hide Others hid a Compositor project window");
                isolated(window, firstBefore, firstPixels, "first-hide-others");
                isolated(other, secondBefore, secondPixels, "second-hide-others");
                appMenuAction(window, "Show All")->trigger();
                pump([&] { return !iconic(ids[0]); }, "Show All did not show the hidden application's window");
                QElapsedTimer settle; settle.start();
                while (settle.elapsed() < 300) QApplication::processEvents(QEventLoop::AllEvents, 10);
                check(iconic(ids[1]), "Show All restored a window the user minimized");
                check(window.isVisible() && other.isVisible() && !window.isMinimized() && !other.isMinimized(),
                    "Show All changed project windows");
                isolated(window, firstBefore, firstPixels, "first-show-all");
                isolated(other, secondBefore, secondPixels, "second-show-all");
                qInfo("Qt Hide Others/Show All OK (X11 window manager: separate client hidden and shown again, its user-minimized window and both project windows/documents unchanged)");
            }
#endif
            if (app.arguments().contains("--hide-others-probe")) {
                // A window manager restores (and reports) asynchronously: Hide Compositor through the visible menu,
                // restore as the task switcher would, and wait for the manager before checking windows/documents.
                for (SessionWindow *owner : {&window, &other}) {
                    QApplication::setActiveWindow(owner); owner->activateWindow(); QApplication::processEvents();
                    hideApplication(*owner);
                    pump([&] { return window.isMinimized() && other.isMinimized(); }, "Hide Compositor did not minimize every project window");
                    window.showNormal(); other.showNormal();
                    pump([&] { return window.isVisible() && other.isVisible() && !window.isMinimized() && !other.isMinimized(); },
                        "window manager did not restore project windows after Hide");
                    isolated(window, firstBefore, firstPixels, "first-x11-restored");
                    isolated(other, secondBefore, secondPixels, "second-x11-restored");
                    qInfo("Qt application Hide under window manager OK (origin=%s, both windows minimized and restored, exact document isolation)",
                        owner == &window ? "first" : "second");
                }
                return 0;
            }
            for (SessionWindow *owner : {&window, &other}) {
                window.showNormal(); other.showNormal();
                QApplication::setActiveWindow(owner); owner->activateWindow(); QApplication::processEvents();
                hideApplication(*owner);
                pump([&] { return window.isMinimized() && other.isMinimized(); }, "Hide Compositor did not minimize every project window");
                isolated(window, firstBefore, firstPixels, "first-minimized");
                isolated(other, secondBefore, secondPixels, "second-minimized");
                window.showNormal(); other.showNormal(); QApplication::processEvents();
                check(window.isVisible() && other.isVisible() && !window.isMinimized() && !other.isMinimized(),
                    "project windows did not restore after Hide");
                isolated(window, firstBefore, firstPixels, "first-restored");
                isolated(other, secondBefore, secondPixels, "second-restored");
                qInfo("Qt application Hide OK (origin=%s, two windows minimize/restore, exact pixels/layers/target/palette/tool/selection/history isolation)",
                    owner == &window ? "first" : "second");
            }
            for (bool maximized : {false, true}) {
                if (maximized) window.showMaximized(); else window.showNormal();
                QApplication::setActiveWindow(&window); window.activateWindow(); QApplication::processEvents();
                command({{"action", "openFilter"}, {"kind", "Gaussian Blur"}});
                QPointer<QDialog> panel;
                pump([&] {
                    panel = window.findChild<QDialog *>("floatingPanel.FilterSheet");
                    return panel && panel->isVisible() && panel->windowHandle() && panel->windowHandle()->isExposed();
                }, "Hide fixture did not expose its real filter panel");
                const auto radius = [&]() -> QLineEdit * {
                    if (panel) for (auto *field : panel->findChildren<QLineEdit *>())
                        if (field->isVisible() && (field->accessibleName() == "Radius" || field->placeholderText() == "Radius")) return field;
                    throw std::runtime_error("Hide filter radius field missing");
                };
                radius()->setFocus(); radius()->selectAll(); radius()->insert("3"); radius()->clearFocus();
                pump([&] { return !window.sessionState().value("filterPreviewRendering").toBool(); }, "Hide filter preview did not settle");
                const auto draft = window.sessionState(); const QImage preview = pixels();
                check(radius()->text().toDouble() == 3, "Hide filter fixture lost its edited radius");
                hideApplication(window);
                pump([&] { return window.isMinimized() && other.isMinimized(); }, "Hide with a filter did not minimize project windows");
                pump([&] { return panel && panel->windowHandle() && !panel->windowHandle()->isExposed(); },
                    "Hide left the floating filter panel exposed");
                QElapsedTimer hidden; hidden.start();
                while (hidden.elapsed() < 350) {
                    QApplication::processEvents(QEventLoop::AllEvents, 10); QThread::msleep(1);
                    if (!panel || panel->windowHandle()->isExposed())
                        qWarning() << "Hide panel resurfaced at" << hidden.elapsed() << "ms; project state" << window.windowState()
                            << "project visible" << window.isVisible() << "panel visible" << (panel && panel->isVisible())
                            << "surface visible" << (panel && panel->windowHandle()->isVisible());
                    check(panel && !panel->windowHandle()->isExposed(), "floating filter resurfaced while its project was minimized");
                }
                isolated(window, draft, preview, "draft-hidden");
                window.setWindowState(window.windowState() & ~Qt::WindowMinimized);
                other.setWindowState(other.windowState() & ~Qt::WindowMinimized);
                window.show(); other.show();
                QApplication::setActiveWindow(nullptr);
                window.activateWindow(); QApplication::setActiveWindow(&window);
                pump([&] { return !window.isMinimized() && !other.isMinimized() && panel && panel->isVisible()
                    && panel->windowHandle() && panel->windowHandle()->isExposed(); }, "restored project did not expose its filter panel");
                check(window.isMaximized() == maximized, "Hide/restore lost the maximized window state");
                check(window.findChild<QDialog *>("floatingPanel.FilterSheet") == panel && radius()->text().toDouble() == 3,
                    "Hide/restore recreated the filter panel or lost its draft value");
                isolated(window, draft, preview, "draft-restored");
                QPushButton *cancel = nullptr;
                for (auto *button : panel->findChildren<QPushButton *>()) if (button->isVisible() && button->text() == "Cancel") cancel = button;
                click(cancel);
                pump([&] { return window.sessionState().value("floatingPanels").toArray().isEmpty(); }, "restored filter Cancel did not close its panel");
                isolated(window, firstBefore, firstPixels, "first-after-filter");
                isolated(other, secondBefore, secondPixels, "second-after-filter");
                qInfo("Qt application Hide panel OK (maximized=%d platform=%s, hidden across refresh ticks, same edited panel/preview restored, Cancel and exact document/history isolation)",
                    int(maximized), qPrintable(QGuiApplication::platformName()));
            }
            return 0;
        }

        if (app.arguments().contains("--selection-clear-probe")) {
            const auto clearAction = [&]() -> QAction * {
                for (auto *top : window.menuBar()->actions()) if (top->isVisible() && top->text().remove('&') == "Edit" && top->menu()) {
                    emit top->menu()->aboutToShow();
                    for (auto *action : top->menu()->actions())
                        if (action->isVisible() && action->text().remove('&') == "Clear Selection Pixels") return action;
                }
                throw std::runtime_error("visible Clear Selection Pixels action missing");
            };
            for (bool mask : {false, true}) for (bool ellipse : {false, true}) for (int alpha : {255, 128}) {
                QImage fixture(64, 64, QImage::Format_RGBA8888);
                fixture.fill(QColor(192, 64, 32, alpha));
                const QString input = temporary.filePath("clear-source.png");
                check(fixture.save(input) && window.importImage(input), "clear fixture import failed");
                command({{"action", "setShowsTransformControls"}, {"enabled", false}});
                if (mask) {
                    command({{"action", "addRevealMask"}});
                    command({{"action", "setMaskSelected"}, {"enabled", true}});
                    command({{"action", "setPaletteColor"}, {"kind", "background"},
                        {"parameters", QJsonObject{{"red", 0}, {"green", 0}, {"blue", 0}}}});
                }
                check(!clearAction()->isEnabled(), "Clear without a selection was enabled");
                command({{"action", ellipse ? "selectEllipse" : "selectRectangle"},
                    {"x", 16}, {"y", 20}, {"width", 24}, {"height", 16}});
                const auto before = window.sessionState(); const QImage original = pixels();
                if (!before.value("hasSelection").toBool() || !clearAction()->isEnabled()) {
                    QJsonObject diagnostic;
                    for (const char *name : {"activeLayerHasMask", "activeLayerID", "busy", "canSwitch", "hasSelection",
                                             "isMaskSelected", "layers", "transforming", "undoName"}) diagnostic[name] = before.value(name);
                    qWarning().noquote() << "Clear setup state:" << QJsonDocument(diagnostic).toJson(QJsonDocument::Compact);
                }
                check(before.value("hasSelection").toBool() && clearAction()->isEnabled(), "selected Clear action was disabled");
                clearAction()->trigger();
                pump([&] { return !window.sessionState().value("busy").toBool()
                    && window.sessionState().value("undoName") != before.value("undoName"); }, "visible Clear did not finish");
                const auto after = window.sessionState(); const QImage cleared = pixels();
                int interior = 0, exterior = 0;
                for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                    const double dx = (x + .5 - 28) / 12, dy = (y + .5 - 28) / 8;
                    const double radius = dx * dx + dy * dy;
                    const bool inside = ellipse ? radius < .75 : QRect(16, 20, 24, 16).contains(x, y);
                    const bool outside = ellipse ? radius > 1.3 : !QRect(16, 20, 24, 16).contains(x, y);
                    if (inside) { ++interior; check(cleared.pixelColor(x, y).alpha() == 0, "Clear left selected interior pixels"); }
                    if (outside) { ++exterior; check(cleared.pixelColor(x, y) == original.pixelColor(x, y), "Clear changed pixels outside selection"); }
                    check(cleared.pixelColor(x, y).alpha() <= original.pixelColor(x, y).alpha(), "Clear increased alpha");
                }
                check(interior > 100 && exterior > 3000, "Clear oracle did not cover interior and exterior");
                for (const char *name : {"activeLayerID", "hasSelection", "isMaskSelected", "foregroundColor", "backgroundColor"})
                    check(after.value(name) == before.value(name), "Clear changed selection, target or palette");
                check(after.value("layers").toArray().size() == before.value("layers").toArray().size(), "Clear deleted a layer");
                command({{"action", "undo"}});
                check(pixels() == original && window.sessionState().value("layers") == before.value("layers"),
                    "single Clear Undo did not restore exact pixels and records");
                command({{"action", "redo"}});
                check(pixels() == cleared && window.sessionState().value("layers") == after.value("layers"),
                    "single Clear Redo did not restore exact pixels and records");
                if (mask) {
                    command({{"action", "setMaskSelected"}, {"enabled", false}});
                    command({{"action", "setMaskEnabled"}, {"enabled", false}});
                    check(pixels() == original, "mask Clear altered source image pixels");
                }
                qInfo("Qt visible selection Clear OK (mask=%d ellipse=%d alpha=%d; disabled without selection, independent interior/exterior coverage, target/palette isolation and exact single Undo/Redo)",
                    int(mask), int(ellipse), alpha);
            }
            return 0;
        }

        if (app.arguments().contains("--modern-adjustment-probe")) {
            struct Entry { QString kind, field, savedField; double value; int occurrence = 0; };
            const QList<Entry> entries{{"Gaussian Blur", "Radius", "blurRadius", 1.5},
                {"Motion Blur", "Angle", "motionAngle", 90}, {"Add Noise", "Amount", "noiseAmount", 55},
                {"Black & White", "Reds", "blackWhiteSettings", 80},
                {"Color Balance", "Yellow / Blue", "colorBalanceSettings", 60, 1}, {"Invert", "", "", 0}};
            QImage image(64, 64, QImage::Format_RGBA8888); image.fill(Qt::transparent);
            for (int y = 12; y < 48; ++y) for (int x = 12; x < 48; ++x)
                image.setPixelColor(x, y, QColor(40 + (x * 7) % 180, 30 + (y * 5) % 180, 20 + ((x + y) * 3) % 180));
            const QString path = temporary.filePath("modern-adjustment.png");
            check(image.save(path), "modern adjustment fixture save failed");
            const auto panel = [&]() -> QDialog * {
                for (auto *top : QApplication::topLevelWidgets())
                    if (auto *dialog = qobject_cast<QDialog *>(top); dialog && dialog->isVisible()
                        && dialog->objectName() == "floatingPanel.FilterSheet") return dialog;
                return nullptr;
            };
            const auto finish = [&](const QString &title) {
                QPushButton *button = nullptr;
                if (panel()) for (auto *candidate : panel()->findChildren<QPushButton *>())
                    if (candidate->isVisible() && candidate->text() == title) button = candidate;
                click(button); pump([&] { return !panel(); }, "modern adjustment sheet did not close");
                QApplication::setActiveWindow(&window); QApplication::processEvents();
            };
            const auto menuTitle = [](QAction *action) {
                const auto text = action->text(); QString label;
                for (qsizetype i = 0; i < text.size(); ++i) {
                    if (text[i] != '&') label += text[i];
                    else if (i + 1 < text.size() && text[i + 1] == '&') { label += '&'; ++i; }
                }
                return label;
            };
            const auto menuAction = [&](const QString &title, bool create, bool enabled = true) {
                QMenu *root = nullptr;
                for (auto *action : window.menuBar()->actions()) if (menuTitle(action) == "Layer") root = action->menu();
                check(root, "modern adjustment Layer menu missing");
                root->popup(window.mapToGlobal(QPoint(200, 50))); QApplication::processEvents();
                QMenu *menu = root;
                if (create) {
                    menu = nullptr;
                    for (auto *action : root->actions()) if (menuTitle(action) == "New Adjustment Layer") menu = action->menu();
                    check(menu, "modern adjustment creation submenu missing");
                    menu->popup(window.mapToGlobal(QPoint(400, 50))); QApplication::processEvents();
                }
                QAction *chosen = nullptr;
                for (auto *action : menu->actions()) if (menuTitle(action) == title) chosen = action;
                if (!chosen) {
                    QStringList titles; for (auto *action : menu->actions()) titles.append(action->text());
                    qWarning() << "modern adjustment menu missing" << title << titles;
                }
                check(menu->isVisible() && chosen && chosen->isEnabled() == enabled, "modern adjustment menu action unavailable");
                if (enabled) chosen->trigger();
                menu->hide(); root->hide(); QApplication::processEvents();
            };
            for (const auto &entry : entries) {
                const bool editable = entry.kind != "Invert";
                check(window.importImage(path), "modern adjustment fixture import failed");
                command({{"action", "setShowsTransformControls"}, {"enabled", false}});
                const auto sourceState = window.sessionState(); const QImage source = pixels();
                menuAction(entry.kind + (editable ? QString::fromUtf8("…") : QString()), true);
                if (editable) pump([&] { return panel(); }, "modern adjustment creation did not open its sheet");
                else check(!panel(), "Invert unexpectedly opened an editor");
                const auto created = window.sessionState(); const QImage createdPixels = pixels();
                if (editable) finish("OK");
                const auto baseline = window.sessionState(); const QImage original = pixels();
                const auto adjustmentID = baseline.value("activeLayerID");
                check(baseline.value("layers").toArray().size() == 2
                    && baseline.value("layers").toArray().first() == sourceState.value("layers").toArray().first(),
                    "modern adjustment creation changed source identity or layer count");
                const QString creationHistory = "New " + entry.kind + " Adjustment", editHistory = "Edit " + entry.kind + " Adjustment";
                const bool acceptedDefaults = baseline.value("undoName").toString() == editHistory;
                check(created.value("undoName").toString() == creationHistory
                    && (baseline.value("undoName").toString() == creationHistory || (editable && acceptedDefaults)),
                    "modern adjustment creation recorded an unexpected history step");
                // Accepting the editor can materialize optional default settings in its own Edit step.
                if (acceptedDefaults) {
                    command({{"action", "undo"}});
                    check(pixels() == createdPixels && window.sessionState().value("layers") == created.value("layers")
                        && window.sessionState().value("undoName").toString() == creationHistory,
                        "modern adjustment default-settings Undo lost its creation checkpoint");
                }
                command({{"action", "undo"}});
                if (pixels() != source || window.sessionState().value("layers") != sourceState.value("layers"))
                    qWarning() << "modern adjustment creation Undo" << entry.kind << "source/baseline/current undo"
                        << sourceState.value("undoName") << baseline.value("undoName") << window.sessionState().value("undoName")
                        << "source/current layer counts" << sourceState.value("layers").toArray().size()
                        << window.sessionState().value("layers").toArray().size() << "same pixels" << (pixels() == source);
                check(pixels() == source && window.sessionState().value("layers") == sourceState.value("layers"),
                    "modern adjustment creation Undo lost source pixels or records");
                command({{"action", "redo"}});
                check(pixels() == createdPixels && window.sessionState().value("layers") == created.value("layers"),
                    "modern adjustment creation Redo lost its original checkpoint");
                if (acceptedDefaults) command({{"action", "redo"}});
                check(pixels() == original && window.sessionState().value("layers") == baseline.value("layers"),
                    "modern adjustment creation Redo lost exact composite or identity");
                QImage accepted = original;
                if (editable) {
                    QWidget *table = nullptr;
                    for (auto *candidate : window.findChildren<QWidget *>())
                        if (candidate->isVisible() && candidate->property("appKitView").toBool()
                            && candidate->property("appKitSession").toULongLong() == window.sessionHandle()
                            && candidate->property("appKitNode").toString().startsWith("LayersPanel|")) table = candidate;
                    check(table, "modern adjustment thumbnail missing");
                    const QPoint point = table->mapTo(&window, QPoint(60, 26));
                    for (auto type : {QEvent::MouseButtonPress, QEvent::MouseButtonDblClick}) {
                        // Native table presses track synchronously; deliver each release from the event queue.
                        QTimer::singleShot(0, &window, [&, point] {
                            QMouseEvent release(QEvent::MouseButtonRelease, QPointF(point), QPointF(window.mapToGlobal(point)),
                                Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
                            QApplication::sendEvent(window.windowHandle(), &release);
                        });
                        QMouseEvent event(type, QPointF(point), QPointF(window.mapToGlobal(point)), Qt::LeftButton,
                            Qt::LeftButton, Qt::NoModifier);
                        QApplication::sendEvent(window.windowHandle(), &event);
                    }
                    pump([&] { return panel(); }, "modern adjustment thumbnail did not reopen its sheet");
                    const auto edit = [&] {
                        QList<QLineEdit *> fields;
                        for (auto *candidate : panel()->findChildren<QLineEdit *>())
                            if (candidate->isVisible() && candidate->placeholderText() == entry.field) fields.append(candidate);
                        check(fields.size() > entry.occurrence && fields[entry.occurrence]->isEnabled(),
                            "modern adjustment numeric field missing");
                        auto *field = fields[entry.occurrence]; field->setFocus(); field->selectAll(); field->insert(QString::number(entry.value));
                        QApplication::processEvents();
                        pump([&] { return !window.sessionState().value("filterPreviewRendering").toBool() && pixels() != original; },
                            "modern adjustment numeric edit did not update its composite");
                        check(window.sessionState().value("layers").toArray().first() == sourceState.value("layers").toArray().first()
                            && window.sessionState().value("activeLayerID") == adjustmentID,
                            "modern adjustment preview changed its source or edit target");
                    };
                    edit(); finish("Cancel");
                    check(pixels() == original && window.sessionState().value("layers") == baseline.value("layers")
                        && window.sessionState().value("undoName") == baseline.value("undoName"),
                        "modern adjustment Cancel changed source, identity or history");
                    menuAction(QString::fromUtf8("Edit Adjustment…"), false);
                    pump([&] { return panel(); }, "modern adjustment Edit menu did not reopen its sheet");
                    edit(); accepted = pixels(); finish("OK");
                    check(pixels() == accepted && window.sessionState().value("activeLayerID") == adjustmentID,
                        "modern adjustment OK lost the completed preview or target");
                    command({{"action", "undo"}});
                    check(pixels() == original && window.sessionState().value("layers") == baseline.value("layers"),
                        "modern adjustment edit Undo lost its original composite or identity");
                    command({{"action", "redo"}});
                    check(pixels() == accepted && window.sessionState().value("activeLayerID") == adjustmentID,
                        "modern adjustment edit Redo lost exact pixels or target");
                } else for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                    const auto before = source.pixelColor(x, y), after = accepted.pixelColor(x, y);
                    check(after.alpha() == before.alpha(), "Invert adjustment changed source alpha");
                    if (before.alpha()) check(std::abs(before.red() + after.red() - 255) <= 1
                        && std::abs(before.green() + after.green() - 255) <= 1 && std::abs(before.blue() + after.blue() - 255) <= 1,
                        "Invert adjustment disagrees with independent channel complements");
                }
                if (!editable) {
                    const auto idle = window.sessionState();
                    check(idle.value("canSwitch").toBool(), "Invert left the project blocked without an editor");
                    menuAction(QString::fromUtf8("Edit Adjustment…"), false, false);
                    check(!window.sendCommand({{"action", "beginAdjustmentEditing"}, {"layerID", adjustmentID}}),
                        "Invert bridge request was accepted despite having no editable settings");
                    const auto afterRefusal = window.sessionState();
                    for (const char *key : {"layers", "activeLayerID", "undoName", "redoName", "canUndo", "canRedo", "modified", "canSwitch"})
                        check(afterRefusal.value(key) == idle.value(key), "Invert editor refusal changed the document or blocked editing");
                    check(pixels() == accepted, "Invert editor refusal changed the composite");
                }
                const QString project = temporary.filePath(entry.kind + ".comp");
                check(writeProjectPackage(project), "modern adjustment package write failed");
                QFile manifest(project + "/manifest.json"); check(manifest.open(QIODevice::ReadOnly), "modern adjustment manifest missing");
                const auto records = QJsonDocument::fromJson(manifest.readAll()).object().value("layers").toArray();
                check(records.size() == 2, "modern adjustment package lost its source or adjustment");
                const auto saved = records.last().toObject().value("adjustment").toObject();
                check(saved.value("kind").toString() == entry.kind, "modern adjustment package saved the wrong kind");
                if (editable) {
                    auto value = saved.value(entry.savedField);
                    if (entry.kind == "Black & White") value = value.toObject().value("reds");
                    if (entry.kind == "Color Balance") value = value.toObject().value("midYellowBlue");
                    check(value.isDouble() && std::abs(value.toDouble() - entry.value) < 0.00001,
                        "modern adjustment package did not retain the visible numeric edit");
                }
                const QImage savedSource(project + "/images/" + records.first().toObject().value("imageFile").toString());
                check(savedSource.size() == image.size(), "modern adjustment source PNG missing");
                for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x)
                    check(savedSource.pixelColor(x, y) == image.pixelColor(x, y), "modern adjustment changed saved source PNG channels");
                check(window.loadProject(project) && pixels() == accepted,
                    "modern adjustment package reopen lost its exact composite");
                qInfo("Qt modern adjustment OK (%s, visible creation, %s, exact creation/edit Undo/Redo, saved parameters/source PNG and reopened composite)",
                    qPrintable(entry.kind), editable ? "thumbnail/Edit menu, numeric preview and Cancel/OK"
                        : "no editor, disabled Edit menu, refused bridge request and independent channel complements");
            }
            return 0;
        }

        if (app.arguments().contains("--thumbnail-selection-probe")) {
            const QRect ink(12, 16, 24, 24), reveal(20, 12, 24, 24), initial(8, 28, 32, 20);
            QImage image(64, 64, QImage::Format_RGBA8888); image.fill(Qt::transparent);
            for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x)
                if (ink.contains(x, y)) image.setPixelColor(x, y, QColor(180, 40, 60));
            const QString path = temporary.filePath("thumbnail-selection.png");
            check(image.save(path), "thumbnail selection fixture save failed");
            const auto table = [&]() -> QWidget * {
                for (auto *candidate : window.findChildren<QWidget *>())
                    if (candidate->isVisible() && candidate->property("appKitView").toBool()
                        && candidate->property("appKitSession").toULongLong() == window.sessionHandle()
                        && candidate->property("appKitNode").toString().startsWith("LayersPanel|")) return candidate;
                throw std::runtime_error("thumbnail selection table missing");
            };
            for (int target = 0; target < 3; ++target) for (int mode = 0; mode < 4; ++mode) {
                const bool mask = target != 0, folder = target == 2;
                check(window.importImage(path), "thumbnail selection fixture import failed");
                command({{"action", "setShowsTransformControls"}, {"enabled", false}});
                if (folder) command({{"action", "groupSelectedLayers"}});
                command({{"action", "selectRectangle"}, {"x", reveal.x()}, {"y", reveal.y()},
                         {"width", reveal.width()}, {"height", reveal.height()}});
                command({{"action", "addRevealMask"}});
                check(window.sessionState().value("activeLayerHasMask").toBool(), "thumbnail selection mask setup failed");
                const auto original = pixels();
                command({{"action", "selectRectangle"}, {"x", initial.x()}, {"y", initial.y()},
                         {"width", initial.width()}, {"height", initial.height()}});
                const auto before = window.sessionState();
                const QString history = mask ? "Load Mask Selection" : "Load Layer Selection";
                Qt::KeyboardModifiers modifiers = Qt::ControlModifier;
                if (mode == 1 || mode == 3) modifiers |= Qt::ShiftModifier;
                if (mode >= 2) modifiers |= Qt::AltModifier;
                const auto load = [&] {
                    const auto gestureBefore = window.sessionState();
                    const QPoint point = table()->mapTo(&window, QPoint(mask ? 108 : 60, 26));
                    for (auto type : {QEvent::MouseButtonPress, QEvent::MouseButtonRelease}) {
                        QMouseEvent event(type, QPointF(point), QPointF(window.mapToGlobal(point)), Qt::LeftButton,
                            type == QEvent::MouseButtonPress ? Qt::LeftButton : Qt::NoButton, modifiers);
                        QApplication::sendEvent(window.windowHandle(), &event);
                    }
                    QApplication::processEvents();
                    const auto after = window.sessionState();
                    check(after.value("hasSelection").toBool() && after.value("undoName").toString() == history,
                          "thumbnail modifier gesture did not load a selection");
                    const bool samePixels = pixels() == original;
                    if (after.value("layers") != gestureBefore.value("layers") || !samePixels
                        || after.value("activeLayerID") != gestureBefore.value("activeLayerID")
                        || after.value("isMaskSelected") != gestureBefore.value("isMaskSelected"))
                        qWarning() << "thumbnail selection isolation" << target << mode
                            << "pixels" << samePixels << "records" << (after.value("layers") == gestureBefore.value("layers"))
                            << "active before/after" << gestureBefore.value("activeLayerID") << after.value("activeLayerID")
                            << "mask target before/after" << gestureBefore.value("isMaskSelected") << after.value("isMaskSelected");
                    check(after.value("layers") == gestureBefore.value("layers") && samePixels
                        && after.value("activeLayerID") == gestureBefore.value("activeLayerID")
                        && after.value("isMaskSelected") == gestureBefore.value("isMaskSelected"),
                        "thumbnail selection changed source pixels, records or edit target");
                };
                const auto prove = [&](bool loaded) {
                    const auto prior = window.sessionState();
                    command({{"action", "addLayer"}});
                    bool nested = false;
                    const auto destination = window.sessionState().value("activeLayerID");
                    for (const auto &value : window.sessionState().value("layers").toArray()) {
                        const auto record = value.toObject();
                        if (record.value("id") == destination) nested = !record.value("parentID").toString().isEmpty();
                    }
                    if (nested) command({{"action", "moveActiveLayerOutOfGroup"}});
                    command({{"action", "setPaletteColor"}, {"kind", "foreground"},
                        {"parameters", QJsonObject{{"red", 0}, {"green", 0}, {"blue", 1}}}});
                    const auto unpainted = window.sessionState();
                    command({{"action", "fillForeground"}});
                    const auto filled = pixels(); const auto painted = window.sessionState();
                    for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                        const bool old = initial.contains(x, y), incoming = mask ? !reveal.contains(x, y) : ink.contains(x, y);
                        const bool selected = !loaded ? old : mode == 0 ? incoming : mode == 1 ? old || incoming : old && !incoming;
                        if (filled.pixelColor(x, y) != (selected ? QColor(Qt::blue) : original.pixelColor(x, y))) {
                            qWarning() << "thumbnail selection pixel mismatch" << target << mode << loaded << x << y
                                << filled.pixelColor(x, y) << "selected" << selected;
                            check(false, "thumbnail selection disagrees with independent union/difference coverage");
                        }
                    }
                    command({{"action", "undo"}});
                    check(pixels() == original && window.sessionState().value("layers") == unpainted.value("layers"),
                          "thumbnail selection fill Undo changed original pixels or records");
                    command({{"action", "redo"}});
                    check(pixels() == filled && window.sessionState().value("layers") == painted.value("layers"),
                          "thumbnail selection fill Redo lost exact coverage or records");
                    command({{"action", "undo"}});
                    if (nested) command({{"action", "undo"}});
                    command({{"action", "undo"}});
                    check(pixels() == original && window.sessionState().value("layers") == prior.value("layers")
                        && window.sessionState().value("undoName") == prior.value("undoName"),
                        "thumbnail selection coverage proof did not restore the source and history");
                };
                load(); command({{"action", "undo"}});
                check(window.sessionState().value("undoName") == before.value("undoName"),
                      "thumbnail selection Undo did not restore the prior history step");
                prove(false);
                // Painting the Undo proof consumes Redo. Repeat the same gesture to check its Undo/Redo pair.
                load(); command({{"action", "undo"}}); command({{"action", "redo"}});
                prove(true);
                qInfo("Qt thumbnail selection OK (target=%d mode=%d, actual Ctrl/Shift/Alt pointer, subtract precedence, independent all-pixel coverage, source/target isolation and Undo/Redo)", target, mode);
            }
            return 0;
        }

        if (app.arguments().contains("--layer-nesting-probe")) {
            struct DragCase { bool copy = false, multiple = false, folder = false, descendant = false, refused = false, moveOut = false, lateAlt = false;
                bool collapsedSource = false, collapsedTarget = false, crossFolders = false, scrolling = false, scrollDown = false; };
            QList<DragCase> cases{{}, {false, true}, {true}, {true, true}, {false, false, true},
                {true, false, true}, {true, false, true, true}, {false, false, true, false, true},
                {true, false, true, false, true}, {false, false, false, false, false, true},
                {true, false, false, false, false, false, true}};
            for (bool copy : {false, true}) {
                for (bool multiple : {false, true}) { DragCase entry; entry.copy = copy; entry.multiple = multiple; entry.collapsedTarget = true; cases.append(entry); }
                DragCase folded; folded.copy = copy; folded.folder = true; folded.collapsedSource = true; cases.append(folded);
                for (bool target : {false, true}) { DragCase entry; entry.copy = copy; entry.multiple = true; entry.crossFolders = true; entry.collapsedTarget = target; cases.append(entry); }
                DragCase scrolling; scrolling.copy = copy; scrolling.scrolling = true; cases.append(scrolling);
            }
            DragCase bothFolded; bothFolded.copy = bothFolded.folder = bothFolded.collapsedSource = bothFolded.collapsedTarget = true; cases.append(bothFolded);
            for (bool copy : {false, true}) { DragCase entry; entry.copy = copy; entry.scrolling = entry.scrollDown = true; cases.append(entry); }
            QSet<QString> collapsed;
            const auto layers = [&] { return window.sessionState().value("layers").toArray(); };
            const auto byID = [&](const QJsonArray &records) {
                QMap<QString, QJsonObject> result;
                for (const auto &value : records) result.insert(value.toObject().value("id").toString(), value.toObject());
                return result;
            };
            const auto panelIDs = [&](const QJsonArray &records) {
                QStringList result;
                std::function<void(QString)> visit = [&](QString parent) {
                    for (qsizetype i = records.size(); i-- > 0;) {
                        const auto record = records[i].toObject();
                        if (record.value("parentID").toString() != parent) continue;
                        const auto id = record.value("id").toString(); result.append(id);
                        if (record.value("isGroup").toBool() && !collapsed.contains(id)) visit(id);
                    }
                };
                visit(QString()); return result;
            };
            const auto table = [&]() -> QWidget * {
                for (auto *candidate : window.findChildren<QWidget *>())
                    if (candidate->isVisible() && candidate->property("appKitView").toBool()
                        && candidate->property("appKitSession").toULongLong() == window.sessionHandle()
                        && candidate->property("appKitNode").toString().startsWith("LayersPanel|")) return candidate;
                throw std::runtime_error("current native nesting table missing");
            };
            const auto selectedIDs = [&] {
                const auto ids = panelIDs(layers());
                auto *accessible = QAccessible::queryAccessibleInterface(table());
                check(accessible, "nesting table accessibility missing");
                QSet<QString> selected; int row = 0;
                for (int i = 0; i < accessible->childCount(); ++i) {
                    auto *child = accessible->child(i);
                    if (!child || child->role() != QAccessible::ListItem) continue;
                    check(row < ids.size(), "nesting accessibility has extra rows");
                    if (child->state().selected) selected.insert(ids[row]);
                    ++row;
                }
                check(row == ids.size(), "nesting accessibility lost an expanded row"); return selected;
            };
            const auto collapse = [&](const QString &id) {
                const int row = panelIDs(layers()).indexOf(id); check(row >= 0, "folder disclosure row missing");
                auto *accessible = QAccessible::queryAccessibleInterface(table()); check(accessible, "folder disclosure accessibility missing");
                QAccessibleInterface *item = nullptr; int index = 0;
                for (int i = 0; i < accessible->childCount(); ++i) {
                    auto *child = accessible->child(i);
                    if (child && child->role() == QAccessible::ListItem && index++ == row) { item = child; break; }
                }
                QAccessibleInterface *disclosure = nullptr;
                std::function<void(QAccessibleInterface *)> find = [&](QAccessibleInterface *node) {
                    if (!node) return;
                    if (node->text(QAccessible::Name) == "Expand or collapse folder") disclosure = node;
                    for (int i = 0; i < node->childCount(); ++i) find(node->child(i));
                };
                find(item); check(disclosure && !disclosure->state().disabled, "visible folder disclosure missing");
                const QPoint point = window.mapFromGlobal(disclosure->rect().center());
                const auto send = [&](QEvent::Type type, Qt::MouseButtons held) {
                    QMouseEvent event(type, QPointF(point), QPointF(window.mapToGlobal(point)), Qt::LeftButton, held, Qt::NoModifier);
                    QApplication::sendEvent(window.windowHandle(), &event);
                };
                QTimer::singleShot(0, &window, [&] { send(QEvent::MouseButtonRelease, Qt::NoButton); });
                send(QEvent::MouseButtonPress, Qt::LeftButton); QApplication::processEvents();
                collapsed.insert(id);
            };
            QString lastPointerRoute;
            const auto pointerDrag = [&](const QString &source, const QString &target, bool above, Qt::KeyboardModifiers initial, Qt::KeyboardModifiers final, bool autoscroll = false, bool down = false) {
                const auto ids = panelIDs(layers()); const int from = ids.indexOf(source), to = ids.indexOf(target);
                check(from >= 0 && to >= 0, "nesting drag row identity missing");
                const auto viewport = [&]() -> QScrollArea * {
                    for (auto *parent = table()->parentWidget(); parent; parent = parent->parentWidget())
                        if (auto *scroll = qobject_cast<QScrollArea *>(parent)) return scroll;
                    return nullptr;
                };
                QPointer<QScrollArea> area = viewport();
                check(area, "nesting viewport missing");
                if (autoscroll) {
                    try {
                        pump([&] { area = viewport(); return area && area->verticalScrollBar()->maximum() > 500; }, "nesting offscreen fixture is not scrollable");
                    } catch (...) {
                        qWarning() << "nesting viewport current model rows/table geometry" << ids.size() << table()->geometry();
                        for (auto *scroll : window.findChildren<QScrollArea *>())
                            if (scroll->isVisible()) qWarning() << "nesting viewport candidate" << scroll << scroll->property("appKitScrollNode")
                                << scroll->geometry() << scroll->widget()->size() << scroll->verticalScrollBar()->maximum();
                        qWarning().noquote() << "nesting viewport trace" << swiftUIScrollTrace();
                        throw;
                    }
                    area->verticalScrollBar()->setValue(down ? 0 : area->verticalScrollBar()->maximum()); QApplication::processEvents();
                    pump([&] {
                        area = viewport();
                        if (!area) return false;
                        area->verticalScrollBar()->setValue(down ? 0 : area->verticalScrollBar()->maximum());
                        return area->viewport()->rect().contains(area->viewport()->mapFromGlobal(table()->mapToGlobal(QPoint(140, from * 54 + 26))));
                    }, "scrolling drag source did not become reachable in the live viewport");
                }
                const QPoint start = table()->mapTo(&window, QPoint(140, from * 54 + 26));
                QPoint end = table()->mapTo(&window, QPoint(140, to * 54 + (above ? 2 : 26)));
                lastPointerRoute = QString("session=%1 rows=%2/%3 start=%4,%5 end=%6,%7 table=%8 startHit=%9 endHit=%10")
                    .arg(window.sessionHandle()).arg(from).arg(to).arg(start.x()).arg(start.y()).arg(end.x()).arg(end.y())
                    .arg(quintptr(table()), 0, 16).arg(quintptr(window.childAt(start)), 0, 16).arg(quintptr(window.childAt(end)), 0, 16);
                const auto send = [&](QEvent::Type type, QPoint point, Qt::MouseButton button, Qt::MouseButtons held, Qt::KeyboardModifiers flags) {
                    QMouseEvent event(type, QPointF(point), QPointF(window.mapToGlobal(point)), button, held, flags);
                    QApplication::sendEvent(window.windowHandle(), &event);
                };
                QTimer::singleShot(0, &window, [&] { send(QEvent::MouseMove, start + QPoint(4, 0), Qt::NoButton, Qt::LeftButton, initial); });
                send(QEvent::MouseButtonPress, start, Qt::LeftButton, Qt::LeftButton, initial);
                if (autoscroll) {
                    area = viewport(); check(area, "scrolling drag viewport disappeared after press");
                    const auto before = window.sessionState(); const QImage original = pixels();
                    const int beforeScroll = area->verticalScrollBar()->value();
                    const QPoint outside = area->viewport()->mapTo(&window, QPoint(140, down ? area->viewport()->height() + 40 : -40));
                    send(QEvent::MouseMove, outside, Qt::NoButton, Qt::LeftButton, final);
                    try {
                        // Keep the pointer stationary: the native drag timer must reveal the offscreen target.
                        pump([&] { area = viewport(); return area && area->verticalScrollBar()->value() == (down ? area->verticalScrollBar()->maximum() : 0); }, "held layer drag did not autoscroll to its offscreen folder");
                    } catch (...) {
                        qWarning() << "layer autoscroll before/after/max" << beforeScroll << (area ? area->verticalScrollBar()->value() : -1)
                            << (area ? area->verticalScrollBar()->maximum() : -1);
                        qWarning().noquote() << "layer autoscroll pointer trace" << swiftUIPointerTrace();
                        send(QEvent::MouseButtonRelease, outside, Qt::LeftButton, Qt::NoButton, final);
                        throw;
                    }
                    check(layers() == before.value("layers").toArray() && pixels() == original
                        && window.sessionState().value("undoName") == before.value("undoName"), "layer autoscroll edited the document before drop");
                    end = table()->mapTo(&window, QPoint(140, to * 54 + (above ? 2 : 26)));
                }
                send(QEvent::MouseMove, end, Qt::NoButton, Qt::LeftButton, final);
                send(QEvent::MouseButtonRelease, end, Qt::LeftButton, Qt::NoButton, final);
                QApplication::processEvents();
            };
            const auto pixelOracle = [&](const QJsonArray &records) {
                const auto map = byID(records); const QImage actual = pixels();
                for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                    double alpha = 0; int red = 0, blue = 0;
                    for (const auto &record : map) {
                        if (record.value("isGroup").toBool()) continue;
                        if (!record.value("name").toString().startsWith("Drag red") && !record.value("name").toString().startsWith("Drag blue")) continue;
                        const bool isRed = record.value("name").toString().startsWith("Drag red");
                        const QRect rect(isRed ? 16 : 32, 16, 16, 16);
                        if (!rect.contains(x, y)) continue;
                        double opacity = record.value("opacity").toDouble(1);
                        auto parent = record.value("parentID").toString(); int depth = 0;
                        while (!parent.isEmpty()) {
                            check(map.contains(parent) && ++depth < 64, "drag produced a missing/cyclic parent");
                            opacity *= map[parent].value("opacity").toDouble(1);
                            parent = map[parent].value("parentID").toString();
                        }
                        alpha = opacity + alpha * (1 - opacity);
                        if (isRed) red = 255; else blue = 255;
                    }
                    const auto color = actual.pixelColor(x, y);
                    check(std::abs(color.alpha() - qRound(alpha * 255)) <= 2, "layer drag composite disagrees with independent source-over alpha");
                    if (color.alpha()) check(color.red() == red && color.green() == 0 && color.blue() == blue,
                        "layer drag changed source colors or geometry");
                }
            };
            for (int caseIndex = 0; caseIndex < cases.size(); ++caseIndex) {
                const auto entry = cases[caseIndex]; collapsed.clear(); reset();
                command({{"action", "renameLayer"}, {"name", "Drag red"}});
                command({{"action", "setOpacity"}, {"value", 0.5}});
                const QString red = window.sessionState().value("activeLayerID").toString();
                QImage blueImage(64, 64, QImage::Format_RGBA8888); blueImage.fill(Qt::transparent);
                for (int y = 16; y < 32; ++y) for (int x = 32; x < 48; ++x) blueImage.setPixelColor(x, y, Qt::blue);
                const QString path = temporary.filePath("drag-blue.png"); check(blueImage.save(path), "nesting blue fixture save failed");
                command({{"action", "importFiles"}, {"paths", QJsonArray{path}}});
                command({{"action", "renameLayer"}, {"name", "Drag blue"}});
                command({{"action", "setOpacity"}, {"value", 0.5}});
                const QString blue = window.sessionState().value("activeLayerID").toString();
                command({{"action", "addGroup"}});
                command({{"action", "renameLayer"}, {"name", "Destination"}});
                const QString destination = window.sessionState().value("activeLayerID").toString();
                if (entry.collapsedTarget) {
                    command({{"action", "addLayer"}}); command({{"action", "renameLayer"}, {"name", "Destination placeholder"}});
                    collapse(destination);
                }
                QString source = red, inner;
                if (entry.crossFolders) for (const auto &id : {red, blue}) {
                    command({{"action", "selectLayer"}, {"layerID", id}}); command({{"action", "groupSelectedLayers"}});
                    command({{"action", "renameLayer"}, {"name", id == red ? "Red source folder" : "Blue source folder"}});
                    command({{"action", "setOpacity"}, {"value", id == red ? 0.5 : 0.75}});
                }
                if (entry.folder) {
                    command({{"action", "selectLayer"}, {"layerID", red}});
                    command({{"action", "selectLayer"}, {"layerID", blue}, {"enabled", true}});
                    command({{"action", "groupSelectedLayers"}});
                    command({{"action", "renameLayer"}, {"name", "Inner source"}});
                    inner = window.sessionState().value("activeLayerID").toString();
                    command({{"action", "groupSelectedLayers"}});
                    command({{"action", "renameLayer"}, {"name", "Outer source"}});
                    command({{"action", "setOpacity"}, {"value", 0.5}});
                    source = window.sessionState().value("activeLayerID").toString();
                    if (entry.collapsedSource) collapse(source);
                }
                if (entry.scrolling) {
                    if (entry.scrollDown) {
                        command({{"action", "selectLayer"}, {"layerID", destination}});
                        command({{"action", "moveActiveLayer"}, {"value", -1}});
                        command({{"action", "moveActiveLayer"}, {"value", -1}});
                    }
                    command({{"action", "selectLayer"}, {"layerID", red}});
                    for (int i = 0; i < 24; ++i) {
                        command({{"action", "addLayer"}}); command({{"action", "renameLayer"}, {"name", QString("Spacer %1").arg(i)}});
                    }
                    if (entry.scrollDown) source = blue;
                }
                command({{"action", "selectLayer"}, {"layerID", source}});
                if (entry.multiple || entry.descendant)
                    command({{"action", "selectLayer"}, {"layerID", entry.multiple ? blue : red}, {"enabled", true}});
                QSet<QString> roots{source}; if (entry.multiple) roots.insert(blue);
                if (entry.moveOut) {
                    const auto setupBefore = layers();
                    // Read the existing native tree directly: Qt accessibility would first resolve the panel,
                    // hiding a stale coordinator. This snapshot may lay out cells but does not update its rows.
                    const QString location = table()->property("appKitNode").toString(); const int split = location.indexOf('|');
                    const QByteArray nativePanel = location.left(split).toUtf8(), nativeNode = location.mid(split + 1).toUtf8();
                    const auto length = compositor_session_accessibility_tree(window.sessionHandle(), nativePanel.constData(), nativeNode.constData(), nullptr, 0);
                    QByteArray nativeBytes(qMax<int64_t>(0, length), Qt::Uninitialized);
                    if (length > 0) compositor_session_accessibility_tree(window.sessionHandle(), nativePanel.constData(), nativeNode.constData(),
                        reinterpret_cast<uint8_t *>(nativeBytes.data()), nativeBytes.size());
                    const auto nativeRows = QJsonDocument::fromJson(nativeBytes).object().value("children").toArray();
                    QStringList nativeNames; for (const auto &row : nativeRows) nativeNames.append(row.toObject().value("label").toString());
                    qInfo() << "move-out setup native cached row names/model rows" << nativeNames << panelIDs(setupBefore);
                    pointerDrag(source, destination, false, Qt::NoModifier, Qt::NoModifier);
                    if (byID(layers())[source].value("parentID").toString() != destination) {
                        qWarning().noquote() << "move-out setup pointer route" << lastPointerRoute;
                        qWarning() << "move-out setup source/target/before/after" << source << destination << setupBefore << layers();
                        qWarning().noquote() << "move-out setup pointer trace" << swiftUIPointerTrace();
                        qWarning().noquote() << "move-out setup scroll trace" << swiftUIScrollTrace();
                    }
                    check(byID(layers())[source].value("parentID").toString() == destination, "move-out setup did not nest its source");
                }
                const auto beforeState = window.sessionState(); const auto before = layers();
                const auto originals = byID(before); const QImage beforePixels = pixels(); pixelOracle(before);
                const auto beforeSelection = selectedIDs();
                check(beforeSelection.contains(source), "source row not selected before nesting drag");
                QStringList expectedOrder;
                for (const auto &id : panelIDs(before)) if (roots.contains(id)) expectedOrder.append(id);
                const Qt::KeyboardModifiers initial = entry.copy && !entry.lateAlt ? Qt::AltModifier : Qt::NoModifier;
                pointerDrag(source, entry.refused ? inner : destination, entry.moveOut, initial, entry.copy ? Qt::AltModifier : Qt::NoModifier, entry.scrolling, entry.scrollDown);
                if (!entry.refused) collapsed.remove(destination);
                const auto after = layers(); const auto result = byID(after); const QImage afterPixels = pixels();
                check(result.size() == after.size(), "layer drag produced duplicate record IDs");
                if (entry.refused) {
                    check(after == before && afterPixels == beforePixels, "folder drop into its descendant changed the document");
                    for (const char *name : {"undoName", "redoName", "canUndo", "canRedo", "modified"})
                        check(window.sessionState().value(name) == beforeState.value(name), "refused descendant drag changed history");
                    check(selectedIDs() == beforeSelection, "refused descendant drag changed selection");
                } else {
                    QMap<QString, QString> copies;
                    for (auto i = result.cbegin(); i != result.cend(); ++i) if (!originals.contains(i.key())) {
                        const auto name = i.value().value("name").toString(); QString match;
                        for (auto j = originals.cbegin(); j != originals.cend(); ++j)
                            if (name == j.value().value("name").toString() + (roots.contains(j.key()) ? " copy" : "")) match = j.key();
                        check(!match.isEmpty() && !copies.contains(match), "drag copy duplicated an unknown or already copied source");
                        copies.insert(match, i.key());
                    }
                    check(copies.size() == (entry.copy ? (entry.folder ? 4 : roots.size()) : 0), "Alt drag did not copy the selected roots/subtree exactly once");
                    check(result.size() == originals.size() + copies.size(), "layer drag lost a source or duplicated a record identity");
                    for (auto i = originals.cbegin(); i != originals.cend(); ++i) {
                        auto expected = i.value();
                        if (!entry.copy && roots.contains(i.key())) {
                            if (entry.moveOut) expected.remove("parentID"); else expected.insert("parentID", destination);
                        }
                        check(result.value(i.key()) == expected, "layer drag changed an unselected/source record or wrong parent");
                    }
                    for (auto i = copies.cbegin(); i != copies.cend(); ++i) {
                        if (collapsed.contains(i.key())) collapsed.insert(i.value());
                        auto expected = originals.value(i.key()); expected.insert("id", i.value());
                        if (roots.contains(i.key())) { expected.insert("name", expected.value("name").toString() + " copy"); expected.insert("parentID", destination); }
                        else expected.insert("parentID", copies.value(expected.value("parentID").toString()));
                        check(result.value(i.value()) == expected, "folder drag copy lost appearance/geometry or descendant parent remapping");
                    }
                    QStringList placed;
                    for (const auto &id : panelIDs(after)) if ((entry.copy && copies.values().contains(id) && roots.contains(copies.key(id)))
                        || (!entry.copy && roots.contains(id))) placed.append(entry.copy ? copies.key(id) : id);
                    check(placed == expectedOrder, "multi-row drag changed the selected roots' displayed order");
                    if (!entry.copy) check(selectedIDs() == roots, "move drag lost its selected roots");
                    else {
                        const auto active = window.sessionState().value("activeLayerID").toString();
                        check(copies.values().contains(active), "Alt drag did not select a copied layer");
                        check(selectedIDs().contains(active), "Alt drag's copied selection or collapsed subtree differs from the visible list");
                    }
                    pixelOracle(after);
                    const QString history = (entry.copy ? "Duplicate Layer" : "Move Layer") + QString(roots.size() > 1 ? "s" : "");
                    check(window.sessionState().value("undoName").toString() == history, "layer drag did not create the upstream grouped history step");
                    command({{"action", "undo"}});
                    check(layers() == before && pixels() == beforePixels, "layer drag did not undo its exact hierarchy/IDs/pixels in one step");
                    command({{"action", "redo"}});
                    check(layers() == after && pixels() == afterPixels, "layer drag did not redo its exact hierarchy/IDs/pixels in one step");
                }
                qInfo("Qt layer nesting OK (case=%d copy=%d multiple=%d folder=%d selected-descendant=%d refused=%d move-out=%d late-Alt=%d collapsed-source=%d collapsed-target=%d cross-folders=%d scrolling=%d scroll-down=%d; actual pointer, exact records/parents, pixel oracle, source isolation and Undo/Redo)",
                    caseIndex, int(entry.copy), int(entry.multiple), int(entry.folder), int(entry.descendant), int(entry.refused), int(entry.moveOut), int(entry.lateAlt),
                    int(entry.collapsedSource), int(entry.collapsedTarget), int(entry.crossFolders), int(entry.scrolling), int(entry.scrollDown));
            }
            return 0;
        }

        if (app.arguments().contains("--effects-controls-probe")) {
            struct EffectCase { QString title, name; int size = 0, angle = 0, distance = 0, blur = 0, opacity = 50; bool inside = false; };
            QList<EffectCase> cases;
            for (bool inside : {false, true}) for (int size : {2, 6}) for (int opacity : {50, 100})
                cases.append({"Stroke", "stroke", size, 0, 0, 0, opacity, inside});
            for (bool inside : {false, true}) cases.append({"Stroke", "stroke", 50, 0, 0, 0, 50, inside});
            for (const auto &kind : QList<QPair<QString, QString>>{{"Drop Shadow", "shadow"}, {"Inner Shadow", "innerShadow"}}) {
                for (int angle : {-90, 0, 90, 180}) cases.append({kind.first, kind.second, 0, angle, 8});
                cases.append({kind.first, kind.second, 0, 90, 8, 4});
            }
            for (int opacity : {0, 25, 100}) cases.append({"Color Overlay", "colorOverlay", 0, 0, 0, 0, opacity});
            for (const auto &kind : QList<QPair<QString, QString>>{{"Outer Glow", "outerGlow"}, {"Inner Glow", "innerGlow"}})
                for (int size : {2, 8}) cases.append({kind.first, kind.second, size});
            const QRect shape(16, 16, 16, 16);
            const auto panel = [&]() -> QDialog * {
                auto *dialog = window.findChild<QDialog *>("floatingPanel.EffectsSheet");
                return dialog && dialog->isVisible() ? dialog : nullptr;
            };
            const auto finish = [&](const QString &title) {
                QPushButton *button = nullptr;
                if (panel()) for (auto *candidate : panel()->findChildren<QPushButton *>())
                    if (candidate->isVisible() && candidate->text() == title) button = candidate;
                check(button, "visible effects finish button missing"); click(button);
                pump([&] { return !panel(); }, "effects sheet did not close");
            };
            const auto number = [&](const QString &title, double value) {
                QPointer<QLineEdit> field;
                if (panel()) for (auto *candidate : panel()->findChildren<QLineEdit *>())
                    if (candidate->isVisible() && candidate->placeholderText() == title) field = candidate;
                check(field, "visible effect numeric field missing");
                QApplication::setActiveWindow(panel()); field->setFocus(); field->selectAll(); field->insert(QString::number(value));
                QApplication::processEvents();
                check(field && field->hasFocus() && field->text().toDouble() == value, "effect numeric edit lost text/focus");
                field->clearFocus(); QApplication::processEvents();
            };
            const auto open = [&](const EffectCase &entry) {
                QPushButton *button = nullptr;
                for (auto *candidate : window.findChildren<QPushButton *>())
                    if (candidate->isVisible() && candidate->accessibleName() == "Layer effects") button = candidate;
                check(button && button->isEnabled() && button->menu(), "visible effects menu unavailable");
                QApplication::setActiveWindow(&window);
                auto *menu = button->menu(); menu->popup(button->mapToGlobal(QPoint(0, button->height())));
                QApplication::processEvents(); QAction *action = nullptr;
                for (auto *candidate : menu->actions()) if (candidate->text() == entry.title + QString::fromUtf8("…")) action = candidate;
                check(menu->isVisible() && action && action->isEnabled(), "visible effect creation action missing");
                action->trigger(); menu->hide(); QApplication::processEvents();
                pump([&] { return panel(); }, "effects menu did not open its sheet");
            };
            const auto configure = [&](const EffectCase &entry) {
                if (entry.name == "stroke" || entry.name.endsWith("Glow")) number("Size", entry.size);
                if (entry.name == "stroke") {
                    QPushButton *choice = nullptr;
                    for (auto *candidate : panel()->findChildren<QPushButton *>())
                        if (candidate->isVisible() && candidate->text() == (entry.inside ? "Inside" : "Outside")) choice = candidate;
                    check(choice, "visible stroke position missing"); click(choice);
                }
                if (entry.name == "shadow" || entry.name == "innerShadow") {
                    number("Angle", entry.angle); number("Distance", entry.distance); number("Blur", entry.blur);
                }
                number("Opacity", entry.opacity == 100 ? 50 : 100);
            };
            // A separable, normalized discrete Gaussian on the known rectangle, independent of all app renderers.
            const auto sourceAlpha = [&](int x, int y, bool soft) {
                return shape.contains(x, y) ? (soft && y >= 24 ? 128.0 / 255 : 1.0) : 0.0;
            };
            const auto coverage = [&](int x, int y, int dx, int dy, double sigma, bool soft) {
                if (sigma <= 0) return sourceAlpha(x - dx, y - dy, soft);
                const int radius = int(std::ceil(3 * sigma));
                const auto axis = [&](int coordinate, int minimum, int maximum) {
                    double sum = 0, weight = 0;
                    for (int offset = -radius; offset <= radius; ++offset) {
                        const double w = std::exp(-double(offset * offset) / (2 * sigma * sigma)); weight += w;
                        if (coordinate + offset >= minimum && coordinate + offset <= maximum) sum += w;
                    }
                    return sum / weight;
                };
                const double vertical = soft ? axis(y - dy, 16, 23) + (128.0 / 255) * axis(y - dy, 24, 31)
                    : axis(y - dy, shape.top(), shape.bottom());
                return axis(x - dx, shape.left(), shape.right()) * vertical;
            };
            const auto oracle = [&](const EffectCase &entry, const QImage &actual, bool soft) {
                const double opacity = entry.opacity / 100.0;
                const int dx = qRound(-std::cos(entry.angle * M_PI / 180) * entry.distance);
                const int dy = qRound(std::sin(entry.angle * M_PI / 180) * entry.distance);
                double largest = 0;
                for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                    const double source = sourceAlpha(x, y, soft);
                    double alpha = source, red = source, green = 0, blue = 0;
                    if (entry.name == "stroke") {
                        double extreme = 0;
                        if (entry.inside) {
                            const QRect eroded = shape.adjusted(entry.size, entry.size, -entry.size, -entry.size);
                            // QRect::contains normalizes negative extents; an over-eroded shape is empty.
                            if (eroded.isValid() && eroded.contains(x, y))
                                extreme = soft && y + entry.size >= 24 ? 128.0 / 255 : 1;
                        } else {
                            if (shape.adjusted(-entry.size, -entry.size, entry.size, entry.size).contains(x, y)) extreme = soft ? 128.0 / 255 : 1;
                            if (soft && QRect(16, 16, 16, 8).adjusted(-entry.size, -entry.size, entry.size, entry.size).contains(x, y)) extreme = 1;
                        }
                        const double ring = opacity * (entry.inside ? source - extreme : extreme - source);
                        alpha = source + ring * (1 - source);
                        if (entry.inside) red = source * (1 - ring);
                    } else if (entry.name == "shadow") {
                        alpha = source + opacity * coverage(x, y, dx, dy, entry.blur / 2.0, soft) * (1 - source);
                    } else if (entry.name == "innerShadow") {
                        red = source * (1 - opacity * (1 - coverage(x, y, dx, dy, entry.blur / 2.0, soft)));
                    } else if (entry.name == "colorOverlay") {
                        red = source * (1 - opacity);
                    } else if (entry.name == "outerGlow") {
                        green = blue = opacity * coverage(x, y, 0, 0, entry.size / 2.0, soft) * (1 - source) * (1 - source);
                        red = alpha = source + green;
                    } else if (entry.name == "innerGlow") {
                        green = blue = source * opacity * (1 - coverage(x, y, 0, 0, entry.size / 2.0, soft));
                    }
                    const auto color = actual.pixelColor(x, y);
                    const double a = color.alphaF();
                    const double difference = std::max({std::abs(a - alpha), std::abs(color.redF() * a - red),
                        std::abs(color.greenF() * a - green), std::abs(color.blueF() * a - blue)});
                    largest = std::max(largest, difference);
                    if (entry.name == "innerShadow" || entry.name == "innerGlow" || entry.name == "colorOverlay")
                        check(color.alpha() == qRound(source * 255), "inside effect changed source alpha");
                }
                if (largest > 4.0 / 255) qWarning() << "effect oracle mismatch" << entry.title << entry.size << entry.angle << entry.blur << largest;
                check(largest <= 4.0 / 255, "effect numeric controls disagree with independent pixel equations");
            };
            int index = 0;
            for (bool soft : {false, true}) for (const auto &entry : cases) {
                QImage sourceFixture = fixture;
                if (soft) for (int y = 24; y < 32; ++y) for (int x = 16; x < 32; ++x)
                    sourceFixture.setPixelColor(x, y, QColor(255, 0, 0, 128));
                const QString path = temporary.filePath("effect-source.png");
                check(sourceFixture.save(path) && window.importImage(path), "effect source fixture import failed");
                command({{"action", "setShowsTransformControls"}, {"enabled", false}});
                command({{"action", "setPaletteColor"}, {"kind", "background"},
                    {"parameters", QJsonObject{{"red", 0}, {"green", 0}, {"blue", 0}}}});
                const auto sourceState = window.sessionState(); const QImage source = pixels();
                const auto isolated = [&] {
                    const auto state = window.sessionState();
                    for (const char *name : {"layers", "activeLayerID", "foregroundColor", "backgroundColor"})
                        check(state.value(name) == sourceState.value(name), "effect edited source records/target/palette");
                };
                open(entry); configure(entry); number("Opacity", entry.opacity);
                oracle(entry, pixels(), soft); isolated(); finish("Cancel");
                check(pixels() == source, "effect Cancel did not restore exact source pixels"); isolated();
                check(window.sessionState().value("undoName").toString() == "Cancel " + entry.title,
                    "effect Cancel did not follow upstream's compensating history policy");
                open(entry); configure(entry);
                const auto checkpoint = window.sessionState(); const QImage beforeLast = pixels();
                number("Opacity", entry.opacity);
                const auto edited = window.sessionState(); const QImage preview = pixels(); oracle(entry, preview, soft); isolated();
                finish("OK"); check(pixels() == preview, "effect OK lost its live preview");
                const auto history = [&](Qt::KeyboardModifiers modifiers) {
                    QApplication::setActiveWindow(&window); canvas->setFocus(); QApplication::processEvents();
                    key(canvas, Qt::Key_Z, modifiers); QApplication::processEvents();
                };
                history(Qt::ControlModifier);
                check(pixels() == beforeLast && window.sessionState().value("layers") == checkpoint.value("layers")
                    && window.sessionState().value("undoName") == checkpoint.value("undoName"), "effect numeric Undo lost its exact checkpoint");
                history(Qt::ControlModifier | Qt::ShiftModifier);
                check(pixels() == preview && window.sessionState().value("layers") == edited.value("layers"), "effect numeric Redo lost exact pixels/records");
                isolated();
                const QString project = temporary.filePath(QString("effects-controls-%1.comp").arg(index++));
                std::shared_ptr<std::pair<bool, bool>> overlappingAutosave;
                if (index == 1 && app.arguments().contains("--effects-autosave-overlap")) {
                    overlappingAutosave = std::make_shared<std::pair<bool, bool>>(false, false);
                    check(window.startProjectSave(window.autosaveDirectory() + "/autosave.comp", true,
                        [overlappingAutosave](bool ok) { overlappingAutosave->first = true; overlappingAutosave->second = ok; }),
                        "effect autosave overlap did not start");
                    check(window.isProjectSaveInProgress() && !window.writeProjectPackage(project),
                        "effect overlapping explicit save did not refuse while autosave was pending");
                    check(!QFileInfo::exists(project), "refused effect save wrote a destination");
                    qInfo("Qt effects autosave overlap reproduced (pending autosave refuses immediate explicit package save)");
                }
                const bool packageSaved = writeProjectPackage(project);
                if (overlappingAutosave)
                    check(overlappingAutosave->first && overlappingAutosave->second, "overlapping effect autosave failed");
                if (!packageSaved) qWarning("effect controls package save failed (case=%d, kind=%s, soft=%d)",
                    index - 1, qPrintable(entry.title), int(soft));
                check(packageSaved, "effect controls project save failed");
                QFile file(project + "/manifest.json"); check(file.open(QIODevice::ReadOnly), "effect controls saved manifest missing");
                const auto records = QJsonDocument::fromJson(file.readAll()).object().value("layers").toArray();
                check(records.size() == 1, "effect controls changed saved layer count");
                const QImage savedSource(project + "/images/" + records.first().toObject().value("imageFile").toString());
                int differences = 0, largest = 0;
                if (savedSource.size() == source.size()) for (int y = 0; y < source.height(); ++y) for (int x = 0; x < source.width(); ++x) {
                    const auto a = savedSource.pixelColor(x, y), b = source.pixelColor(x, y);
                    if (a != b) ++differences;
                    largest = std::max({largest, std::abs(a.red() - b.red()), std::abs(a.green() - b.green()),
                        std::abs(a.blue() - b.blue()), std::abs(a.alpha() - b.alpha())});
                }
                if (savedSource.isNull() || savedSource.size() != source.size() || differences) {
                    qWarning() << "effect saved source mismatch" << savedSource.size() << source.size()
                        << savedSource.format() << source.format() << "different pixels/largest channel" << differences << largest
                        << "saved color space" << savedSource.colorSpace() << "source color space" << source.colorSpace();
                }
                // The encoded source has an ICC tag; raw compositor readback is untagged. Compare channels,
                // then verify the saved working space separately rather than comparing QImage metadata.
                check(!savedSource.isNull() && savedSource.size() == source.size() && differences == 0,
                    "non-destructive effect changed the saved source image pixels");
                check(savedSource.colorSpace() == QColorSpace(QColorSpace::SRgb), "effect source PNG lost its sRGB tag");
                const auto saved = records.first().toObject().value("effects").toObject().value(entry.name).toObject();
                check(std::abs(saved.value("opacity").toDouble(-1) - entry.opacity / 100.0) < 1e-9, "effect controls saved wrong opacity");
                if (entry.name == "stroke" || entry.name.endsWith("Glow"))
                    check(saved.value("size").toInt(-1) == entry.size, "effect controls saved wrong size");
                if (entry.name == "stroke") check(saved.value("inside").toBool() == entry.inside, "effect controls saved wrong position");
                if (entry.name == "shadow" || entry.name == "innerShadow")
                    check(saved.value("angle").toInt(-999) == entry.angle && saved.value("distance").toInt(-1) == entry.distance
                        && saved.value("blur").toInt(-1) == entry.blur, "effect controls saved wrong shadow geometry");
                qInfo("Qt effects controls OK (%s, size=%d inside=%d angle=%d distance=%d blur=%d opacity=%d soft=%d; independent pixels, Cancel/OK, source/palette isolation, numeric Undo/Redo and saved parameters/source PNG)",
                    qPrintable(entry.title), entry.size, int(entry.inside), entry.angle, entry.distance, entry.blur, entry.opacity, int(soft));
            }
            return 0;
        }

        if (app.arguments().contains("--filter-controls-probe") || app.arguments().contains("--image-adjustment-controls-probe")) {
            const bool adjustments = app.arguments().contains("--image-adjustment-controls-probe");
            const QRect selectedArea(32, 16, 24, 32);
            const auto historyKey = [&](Qt::KeyboardModifiers modifiers) {
                // A sheet's deferred destruction can restore focus after it is already hidden. Deliver history
                // keys only after the visible main canvas owns focus, as an actual click/key sequence would.
                QApplication::setActiveWindow(&window); canvas->setFocus(); QApplication::processEvents();
                pump([&] {
                    QApplication::setActiveWindow(&window); canvas->setFocus();
                    return QApplication::activeWindow() == &window && QApplication::focusWidget() == canvas;
                }, "filter history canvas did not acquire focus after closing its sheet");
                key(canvas, Qt::Key_Z, modifiers);
            };
            const auto panel = [&]() -> QDialog * {
                auto *value = window.findChild<QDialog *>("floatingPanel.FilterSheet");
                return value && value->isVisible() ? value : nullptr;
            };
            const auto button = [&](const QString &title) -> QPushButton * {
                if (auto *dialog = panel()) for (auto *value : dialog->findChildren<QPushButton *>())
                    if (value->isVisible() && value->text() == title) return value;
                throw std::runtime_error("visible filter button missing");
            };
            const auto toggle = [&](const QString &title) -> QCheckBox * {
                if (auto *dialog = panel()) for (auto *value : dialog->findChildren<QCheckBox *>())
                    if (value->isVisible() && value->text() == title) return value;
                throw std::runtime_error("visible filter toggle missing");
            };
            const auto settled = [&] {
                pump([&] { return panel() && !window.sessionState().value("filterPreviewRendering").toBool(); },
                     "filter controls preview did not settle");
            };
            const auto number = [&](const QString &title, double value) {
                QPointer<QLineEdit> field;
                for (auto *candidate : panel()->findChildren<QLineEdit *>())
                    if (candidate->isVisible() && candidate->placeholderText() == title) field = candidate;
                check(field, "visible filter numeric field missing");
                QApplication::setActiveWindow(panel()); field->setFocus(); field->selectAll(); field->insert(QString::number(value));
                QApplication::processEvents();
                check(field && field->hasFocus() && field->text().toDouble() == value, "filter edit lost its field/value/focus");
                field->clearFocus(); QApplication::processEvents(); settled();
            };
            const auto sliderRange = [&](const QString &title, double minimum, double maximum, double restore) {
                const auto field = [&]() -> QLineEdit * {
                    if (panel()) for (auto *candidate : panel()->findChildren<QLineEdit *>())
                        if (candidate->isVisible() && candidate->placeholderText() == title) return candidate;
                    throw std::runtime_error("adjustment slider's numeric field missing");
                };
                for (bool last : {false, true}) {
                    QSlider *slider = nullptr;
                    for (auto *row = field()->parentWidget(); row && row != panel(); row = row->parentWidget()) {
                        const auto sliders = row->findChildren<QSlider *>();
                        if (sliders.size() == 1) { slider = sliders.first(); break; }
                    }
                    check(slider && slider->isVisible(), "visible adjustment slider missing");
                    QApplication::setActiveWindow(panel()); slider->setFocus(); QApplication::processEvents();
                    QTest::sendKeyEvent(QTest::Click, panel()->windowHandle(), last ? Qt::Key_End : Qt::Key_Home, QString(), Qt::NoModifier);
                    QApplication::processEvents();
                    if (auto *focus = QApplication::focusWidget(); focus && panel()->isAncestorOf(focus)) focus->clearFocus();
                    QApplication::processEvents(); settled();
                    pump([&] { return std::abs(field()->text().toDouble() - (last ? maximum : minimum)) < 0.00001; },
                         "adjustment slider endpoint did not update its model/numeric field");
                }
                number(title, restore);
            };
            const auto open = [&](const QString &kind) {
                QMenu *menu = nullptr;
                for (auto *action : window.menuBar()->actions()) if (action->text().remove('&') == (adjustments ? "Image" : "Filter")) menu = action->menu();
                check(menu, "visible filter/adjustment menu missing");
                QApplication::setActiveWindow(&window); menu->popup(window.mapToGlobal(QPoint(250, 50))); QApplication::processEvents();
                QAction *chosen = nullptr;
                for (auto *action : menu->actions()) if (action->text().remove('&') == kind + QString::fromUtf8("…")) chosen = action;
                check(menu->isVisible() && chosen && chosen->isEnabled(), "visible filter menu action unavailable");
                chosen->trigger(); menu->hide(); QApplication::processEvents();
                pump([&] { return panel(); }, "filter controls sheet did not open"); settled();
            };
            struct Case {
                QString kind; double amount, angle = 0; bool gaussian = false, monochromatic = false;
                double offset = 0, gamma = 1; bool reversed = false, customColors = false;
            };
            QList<Case> cases;
            if (adjustments) {
                for (const auto &values : QList<QList<double>>{{0, 0, 1}, {1, 0, 1}, {-1, 0, 1}, {0, 0.05, 1},
                         {0, -0.05, 1}, {0, 0, 2}, {0, 0, 0.5}, {0.5, 0.02, 1.4}}) {
                    Case entry{"Exposure", values[0]}; entry.offset = values[1]; entry.gamma = values[2]; cases.append(entry);
                }
                for (bool custom : {false, true}) for (bool reversed : {false, true}) {
                    Case entry{"Gradient Map", 0}; entry.customColors = custom; entry.reversed = reversed; cases.append(entry);
                }
                for (int amount : {0, 20, 40}) cases.append({"Grain", double(amount)});
            } else {
                for (int angle : {-45, 0, 45, 90}) for (int distance : {12, 24}) cases.append({"Motion Blur", double(distance), double(angle)});
                for (bool gaussian : {false, true}) for (bool mono : {false, true}) for (int amount : {10, 40})
                    cases.append({"Add Noise", double(amount), 0, gaussian, mono});
                for (int distortion : {-60, -20, 0, 20, 60}) cases.append({"Lens Correction", double(distortion)});
            }
            if (app.arguments().contains("--gradient-map-colors-only"))
                for (qsizetype i = cases.size(); i-- > 0;)
                    if (cases[i].kind != "Gradient Map" || !cases[i].customColors) cases.removeAt(i);
            QMap<int, double> shortMotionVariance;
            QMap<int, QImage> fullMotion;
            for (bool limited : {false, true}) for (const auto &entry : cases) {
                QImage fixture(64, 64, QImage::Format_RGBA8888); fixture.fill(Qt::transparent);
                if (entry.kind == "Motion Blur") fixture.setPixelColor(32, 31, Qt::white);
                else for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                    if (entry.kind == "Add Noise" || entry.kind == "Grain") {
                        if (x >= 8 && x < 56 && y >= 8 && y < 56) fixture.setPixelColor(x, y, QColor(128, 128, 128, y < 32 ? 255 : 128));
                    } else if (!(x >= 28 && x < 36 && y >= 28 && y < 36)) {
                        fixture.setPixelColor(x, y, QColor(32 + x * 3, 32 + y * 3, (x / 8 + y / 8) % 2 ? 192 : 64, y < 32 ? 255 : 128));
                    }
                }
                const QString path = temporary.filePath("filter-controls.png");
                check(fixture.save(path) && window.importImage(path), "filter controls fixture import failed");
                command({{"action", "setShowsTransformControls"}, {"enabled", false}});
                command({{"action", "deselect"}});
                if (limited) {
                    tool("Marquee", "marquee");
                    for (const QString &title : {QString("Rectangle"), QString("New")}) {
                        QPushButton *choice = nullptr;
                        for (auto *picker : window.findChildren<QWidget *>("segmentedPicker"))
                            for (auto *candidate : picker->findChildren<QPushButton *>())
                                if (candidate->isVisible() && candidate->text() == title) choice = candidate;
                        click(choice);
                    }
                    drag(at(32, 16), at(56, 48));
                    check(window.sessionState().value("hasSelection").toBool(), "filter pointer selection missing");
                    // The state ABI exposes selection presence, not its bounds. Prove the actual coverage by filling
                    // and undoing, so a missing or differently shaped selection cannot pass as the expected rectangle.
                    const QImage source = pixels(); const auto state = window.sessionState();
                    command({{"action", "setPaletteColor"}, {"kind", "foreground"},
                             {"parameters", QJsonObject{{"red", 0}, {"green", 0}, {"blue", 1}}}});
                    command({{"action", "fillForeground"}}); const QImage filled = pixels();
                    for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x)
                        check(filled.pixelColor(x, y) == (selectedArea.contains(x, y) ? QColor(Qt::blue) : source.pixelColor(x, y)),
                              "filter pointer selection coverage differs from its rectangle oracle");
                    historyKey(Qt::ControlModifier);
                    check(pixels() == source && window.sessionState().value("layers") == state.value("layers")
                              && window.sessionState().value("undoName") == state.value("undoName"), "selection coverage proof did not restore source/history");
                }
                if (entry.kind == "Gradient Map") {
                    command({{"action", "setPaletteColor"}, {"kind", "foreground"},
                             {"parameters", QJsonObject{{"red", 1}, {"green", 0}, {"blue", 0}}}});
                    command({{"action", "setPaletteColor"}, {"kind", "background"},
                             {"parameters", QJsonObject{{"red", 0}, {"green", 0}, {"blue", 1}}}});
                }
                const QImage original = pixels(); const auto before = window.sessionState();
                const auto grainEnergy = [&](const QImage &image) {
                    double sum = 0, squares = 0, differences = 0; int count = 0, pairs = 0;
                    for (int y = 8; y < 32; ++y) for (int x = 8; x < 56; ++x) {
                        if (limited && !selectedArea.contains(x, y)) continue;
                        const double value = image.pixelColor(x, y).red() - original.pixelColor(x, y).red();
                        sum += value; squares += value * value; ++count;
                        if (x + 1 < 56 && (!limited || selectedArea.contains(x + 1, y))) {
                            const double next = image.pixelColor(x + 1, y).red() - original.pixelColor(x + 1, y).red();
                            differences += (value - next) * (value - next); ++pairs;
                        }
                    }
                    const double variance = squares / count - std::pow(sum / count, 2);
                    check(variance > 0.1 && pairs > 0, "grain energy fixture has no variation");
                    return differences / pairs / variance;
                };
                const auto configure = [&] {
                    open(entry.kind);
                    if (entry.kind == "Exposure") {
                        number("Exposure", entry.amount); number("Offset", entry.offset); number("Gamma", entry.gamma);
                        if (entry.amount == 0 && entry.offset == 0 && entry.gamma == 1) {
                            sliderRange("Exposure", -20, 20, 0); sliderRange("Offset", -0.5, 0.5, 0); sliderRange("Gamma", 0.01, 9.99, 1);
                        }
                    } else if (entry.kind == "Gradient Map") {
                        if (entry.customColors) for (const auto &end : QList<QPair<QString, QString>>{{"Shadows color", "204060"}, {"Highlights color", "E0C0A0"}}) {
                            const auto picker = [&]() -> QDialog * {
                                auto *value = window.findChild<QDialog *>("floatingPanel.ColorPickerSheet");
                                return value && value->isVisible() ? value : nullptr;
                            };
                            const QImage prior = pixels();
                            for (bool commit : {false, true}) {
                                QPushButton *swatch = nullptr;
                                for (auto *value : panel()->findChildren<QPushButton *>())
                                    if (value->isVisible() && value->accessibleName() == end.first) swatch = value;
                                QApplication::setActiveWindow(panel()); click(swatch); pump([&] { return picker(); }, "Gradient Map color picker missing");
                                const auto colorField = [&](const QString &title) -> QLineEdit * {
                                    if (picker()) for (auto *value : picker()->findChildren<QLineEdit *>())
                                        if (value->isVisible() && value->placeholderText() == title) return value;
                                    throw std::runtime_error("Gradient Map color field missing");
                                };
                                auto *hex = colorField("Hex");
                                QApplication::setActiveWindow(picker()); hex->setFocus(); hex->selectAll(); hex->insert(end.second);
                                QApplication::processEvents();
                                pump([&] { return picker() && colorField("Hex")->hasFocus() && colorField("Hex")->text() == end.second; },
                                     "Gradient Map Hex draft lost its text or focus");
                                check(colorField("Hex")->cursorPosition() == end.second.size(), "Gradient Map Hex refresh moved the cursor");
                                // Hex is a draft until focus leaves (or Return submits); keep the picker open for live preview.
                                colorField("Hex")->clearFocus(); QApplication::processEvents(); settled();
                                const QColor expected("#" + end.second);
                                pump([&] { return std::abs(colorField("R")->text().toInt() - expected.red()) <= 1
                                    && std::abs(colorField("G")->text().toInt() - expected.green()) <= 1
                                    && std::abs(colorField("B")->text().toInt() - expected.blue()) <= 1; }, "Gradient Map Hex did not update RGB");
                                pump([&] { return pixels() != prior; }, "Gradient Map endpoint did not preview its color");
                                QPushButton *finish = nullptr;
                                for (auto *value : picker()->findChildren<QPushButton *>())
                                    if (value->isVisible() && value->text() == (commit ? "OK" : "Cancel")) finish = value;
                                click(finish); pump([&] { return !picker(); }, "Gradient Map color picker did not close"); settled();
                                if (!commit) pump([&] { return pixels() == prior; }, "Gradient Map color Cancel lost its previous preview");
                            }
                        }
                        if (toggle("Reverse")->isChecked() != entry.reversed) click(toggle("Reverse")); settled();
                    } else if (entry.kind == "Grain") {
                        number("Amount", entry.amount); number("Size", 1.5); number("Roughness", 50);
                        if (entry.amount == 0) {
                            sliderRange("Amount", 0, 100, 0); sliderRange("Size", 0.5, 20, 1.5); sliderRange("Roughness", 0, 100, 50);
                        }
                        if (entry.amount > 0) {
                            number("Size", 1); number("Roughness", 0); const double fineEnergy = grainEnergy(pixels());
                            number("Size", 4); const QImage smooth = pixels(); const double smoothEnergy = grainEnergy(smooth);
                            check(smoothEnergy < fineEnergy * 0.6, "Grain Size did not enlarge its particles");
                            number("Roughness", 100); const QImage rough = pixels();
                            check(grainEnergy(rough) > smoothEnergy * 1.5, "Grain Roughness did not add smaller detail");
                            number("Roughness", 50); const QImage middle = pixels();
                            for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x)
                                check(std::abs(middle.pixelColor(x, y).red() - (smooth.pixelColor(x, y).red() + rough.pixelColor(x, y).red()) / 2.0) <= 3,
                                      "Grain Roughness midpoint did not interpolate the same two patterns");
                            number("Size", 1.5); const QImage reference = pixels();
                            number("Amount", entry.amount * 2); const QImage doubled = pixels();
                            for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                                const int base = original.pixelColor(x, y).red();
                                check(std::abs(doubled.pixelColor(x, y).red() - base - 2 * (reference.pixelColor(x, y).red() - base)) <= 4,
                                      "Grain Amount did not scale the same pattern");
                            }
                            number("Amount", 0); check(pixels() == original, "zero Grain preview changed pixels");
                            number("Amount", entry.amount); check(pixels() == reference, "Grain parameter changes reshuffled its seed");
                        }
                    } else if (entry.kind == "Motion Blur") { number("Angle", entry.angle); number("Distance", entry.amount); }
                    else if (entry.kind == "Add Noise") {
                        number("Amount", entry.amount); click(button(entry.gaussian ? "Gaussian" : "Uniform"));
                        if (toggle("Monochromatic")->isChecked() != entry.monochromatic) click(toggle("Monochromatic"));
                        settled();
                    } else number("Remove Distortion", entry.amount);
                    check(toggle("Preview")->isChecked(), "filter did not start with Preview enabled");
                };
                const auto isolated = [&] {
                    const auto state = window.sessionState();
                    for (const char *field : {"layers", "activeLayerID", "hasSelection", "undoName", "redoName", "canUndo", "canRedo", "modified", "foregroundColor", "backgroundColor"})
                        if (state.value(field) != before.value(field)) {
                            qWarning() << "filter isolation mismatch" << entry.kind << field << state.value(field) << before.value(field);
                            check(false, "filter preview changed source, selection, target or history");
                        }
                };
                const auto verify = [&](const QImage &image) {
                    if (limited) unchangedOutside(original, image, selectedArea);
                    if (entry.kind == "Exposure" || entry.kind == "Gradient Map" || entry.kind == "Grain") {
                        int varied = 0;
                        for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                            const auto src = original.pixelColor(x, y), dst = image.pixelColor(x, y);
                            check(src.alpha() == dst.alpha(), "image adjustment changed alpha");
                            if (!src.alpha() || (limited && !selectedArea.contains(x, y))) { check(dst == src, "image adjustment changed outside coverage"); continue; }
                            if (entry.kind == "Grain") {
                                check(dst.red() == dst.green() && dst.green() == dst.blue(), "Grain colored the neutral fixture");
                                if (dst.red() != src.red()) ++varied;
                                check(std::abs(dst.red() - src.red()) <= entry.amount * 0.35 * 255 * 1.6 + 2, "Grain exceeded its strength bound");
                                continue;
                            }
                            const int input[] = {src.red(), src.green(), src.blue()}, actual[] = {dst.red(), dst.green(), dst.blue()};
                            const double brightness = std::round((2126 * input[0] + 7152 * input[1] + 722 * input[2]) / 10000.0) / 255;
                            for (int c = 0; c < 3; ++c) {
                                double expected;
                                if (entry.kind == "Exposure") {
                                    const double encoded = input[c] / 255.0;
                                    const double linear = encoded <= 0.04045 ? encoded / 12.92 : std::pow((encoded + 0.055) / 1.055, 2.4);
                                    const double raised = std::pow(std::max(0.0, linear * std::pow(2.0, entry.amount) + entry.offset), 1 / entry.gamma);
                                    expected = 255 * std::clamp(raised <= 0.0031308 ? raised * 12.92 : 1.055 * std::pow(raised, 1 / 2.4) - 0.055, 0.0, 1.0);
                                } else {
                                    const int dark[] = {entry.customColors ? 32 : 255, entry.customColors ? 64 : 0, entry.customColors ? 96 : 0};
                                    const int light[] = {entry.customColors ? 224 : 0, entry.customColors ? 192 : 0, entry.customColors ? 160 : 255};
                                    const double t = entry.reversed ? 1 - brightness : brightness;
                                    expected = dark[c] + (light[c] - dark[c]) * t;
                                }
                                if (std::abs(actual[c] - expected) > 3) {
                                    qWarning("adjustment oracle mismatch %s selected=%d at=%d,%d component=%d actual=%d expected=%.3f", qPrintable(entry.kind), limited, x, y, c, actual[c], expected);
                                    check(false, "image adjustment differs from its independent pixel equation");
                                }
                            }
                        }
                        if (entry.kind == "Grain" && entry.amount > 0) check(varied > 100, "Grain did not vary its image");
                    } else if (entry.kind == "Motion Blur") {
                        const int motionKey = int(entry.angle) + int(entry.amount) * 1000;
                        if (limited) {
                            check(fullMotion.contains(motionKey), "selected motion case lacks its whole-image result");
                            for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x)
                                check(image.pixelColor(x, y) == (selectedArea.contains(x, y) ? fullMotion[motionKey].pixelColor(x, y) : original.pixelColor(x, y)),
                                      "Motion Blur did not clip the streak to the pointer selection");
                            return;
                        }
                        double mass = 0, major = 0, minor = 0, dx = 0, dy = 0;
                        const double angle = entry.angle * std::acos(-1.0) / 180;
                        for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                            const auto color = image.pixelColor(x, y); const double a = color.alpha();
                            if (a) check(color.red() == 255 && color.green() == 255 && color.blue() == 255, "motion impulse lost white premultiplied color");
                            const double u = (x - 32) * std::cos(angle) - (y - 31) * std::sin(angle);
                            const double v = (x - 32) * std::sin(angle) + (y - 31) * std::cos(angle);
                            mass += a; dx += a * (x - 32); dy += a * (y - 31); major += a * u * u; minor += a * v * v;
                        }
                        check(mass > 225 && mass < 285 && std::abs(dx / mass) < 0.25 && std::abs(dy / mass) < 0.25,
                              "motion blur changed impulse mass or center");
                        major /= mass; minor /= mass;
                        check(major > 0.5 && minor < 0.5 && major > minor * 4, "motion blur direction differs from the selected angle");
                        const double expectedVariance = entry.amount * entry.amount / 12;
                        check(std::abs(major - expectedVariance) < expectedVariance * 0.15 + 0.5,
                              "Motion Blur spread differs from upstream's absolute Distance calibration");
                        const int index = int(entry.angle) + (limited ? 1000 : 0);
                        if (entry.amount == 12) shortMotionVariance[index] = major;
                        else check(major > shortMotionVariance.value(index) * 2.5 && major < shortMotionVariance.value(index) * 5.5,
                                   "doubling Motion Blur distance did not scale its spread");
                        fullMotion[motionKey] = image;
                    } else if (entry.kind == "Add Noise") {
                        const double spread = entry.amount * 1.275;
                        double sum = 0, squares = 0; int count = 0, colored = 0, tails = 0;
                        for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                            const auto src = original.pixelColor(x, y), dst = image.pixelColor(x, y);
                            check(dst.alpha() == src.alpha(), "Add Noise changed alpha");
                            if (!src.alpha()) check(dst == src, "Add Noise changed a transparent pixel");
                            if (!src.alpha() || (limited && !selectedArea.contains(x, y))) continue;
                            const int r = dst.red() - src.red(), g = dst.green() - src.green(), b = dst.blue() - src.blue();
                            if (r != g || r != b) ++colored;
                            if (entry.monochromatic) check(r == g && r == b, "monochromatic noise changed channel balance");
                            if (std::abs(r) > spread + 2) ++tails;
                            if (!entry.gaussian) check(std::abs(r) <= spread + 2 && std::abs(g) <= spread + 2 && std::abs(b) <= spread + 2,
                                                       "uniform noise exceeded its amplitude");
                            sum += r; squares += r * r; ++count;
                        }
                        const double mean = sum / count, variance = squares / count - mean * mean;
                        const double expected = spread * spread * (entry.gaussian ? 4.0 / 9 : 1.0 / 3);
                        // The selected fixture has 768 samples and an intentionally random seed. A 30% variance
                        // envelope is about six Gaussian sampling standard errors; wrong amplitudes/modes still fail.
                        check(std::abs(mean) < spread * 0.12 + 1 && variance > expected * 0.7 && variance < expected * 1.3,
                              "noise mean/variance differs from the selected amount/distribution");
                        if (!entry.monochromatic) check(colored > count * 0.8, "color noise did not vary channels independently");
                        if (entry.gaussian) check(tails > count * 0.04 && tails < count * 0.25, "Gaussian noise did not produce its expected tails");
                    } else {
                        const QImage source = original.convertToFormat(QImage::Format_ARGB32_Premultiplied);
                        const QImage actual = image.convertToFormat(QImage::Format_ARGB32_Premultiplied);
                        for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                            if (limited && !selectedArea.contains(x, y)) continue;
                            // Independent inverse radial map in pixel-center coordinates, with bilinear premultiplied samples.
                            const double dx = x + 0.5 - 32, dy = y + 0.5 - 32;
                            const double scale = 1 - entry.amount / 100 * 0.35 * (dx * dx + dy * dy) / 2048;
                            const double sx = 31.5 + dx * scale, sy = 31.5 + dy * scale;
                            const int left = int(std::floor(sx)), top = int(std::floor(sy));
                            double expected[4]{};
                            for (int j = 0; j < 2; ++j) for (int i = 0; i < 2; ++i) {
                                if (!source.rect().contains(left + i, top + j)) continue;
                                const auto sample = source.pixel(left + i, top + j);
                                const double weight = (i ? sx - left : 1 - sx + left) * (j ? sy - top : 1 - sy + top);
                                const int components[] = {qRed(sample), qGreen(sample), qBlue(sample), qAlpha(sample)};
                                for (int c = 0; c < 4; ++c) expected[c] += components[c] * weight;
                            }
                            const auto result = actual.pixel(x, y);
                            const int components[] = {qRed(result), qGreen(result), qBlue(result), qAlpha(result)};
                            for (int c = 0; c < 4; ++c) if (std::abs(components[c] - std::round(expected[c])) > 2) {
                                qWarning("lens oracle mismatch distortion=%.0f selected=%d at=%d,%d component=%d actual=%d expected=%.1f", entry.amount, limited, x, y, c, components[c], expected[c]);
                                check(false, "Lens Correction pixels differ from radial-map oracle");
                            }
                        }
                    }
                };
                configure(); const QImage first = pixels(); verify(first); isolated();
                click(toggle("Preview")); settled(); check(pixels() == original, "filter Preview Off did not restore exact pixels"); isolated();
                click(toggle("Preview")); settled(); check(pixels() == first, "filter Preview On changed the prepared result or noise seed");
                click(button("Cancel")); pump([&] { return !panel(); }, "filter Cancel did not close");
                check(pixels() == original, "filter Cancel did not restore pixels"); isolated();
                configure(); const QImage preview = pixels(); verify(preview); isolated();
                click(button("OK")); pump([&] { return !panel() && !window.sessionState().value("busy").toBool(); }, "filter commit did not finish");
                const auto committed = window.sessionState();
                if ((entry.kind == "Lens Correction" && entry.amount == 0) || (entry.kind == "Grain" && entry.amount == 0)
                    || (entry.kind == "Exposure" && entry.amount == 0 && entry.offset == 0 && entry.gamma == 1)) {
                    // Upstream treats zero distortion/grain and default Exposure as Cancel, without an undo step.
                    check(preview == original && pixels() == original, "identity filter/adjustment changed pixels"); isolated();
                    qInfo("Qt filter controls OK (%s, identity selected=%d; identity preview, Preview Off/On, Cancel and history-free OK)", qPrintable(entry.kind), limited);
                    continue;
                }
                check(pixels() == preview && committed.value("activeLayerID") == before.value("activeLayerID")
                          && committed.value("hasSelection") == before.value("hasSelection") && committed.value("undoName").toString() == entry.kind,
                      "filter commit differs from preview or lost its target/selection/history");
                historyKey(Qt::ControlModifier);
                check(pixels() == original && window.sessionState().value("layers") == before.value("layers"), "filter Undo lost exact source/records");
                historyKey(Qt::ControlModifier | Qt::ShiftModifier);
                check(pixels() == preview && window.sessionState().value("layers") == committed.value("layers"), "filter Redo lost exact result/records");
                qInfo("Qt filter controls OK (%s, amount=%.0f angle=%.0f gaussian=%d monochromatic=%d selected=%d; pixel oracle, Preview Off/On, Cancel/OK, source/history isolation and exact Undo/Redo)",
                      qPrintable(entry.kind), entry.amount, entry.angle, entry.gaussian, entry.monochromatic, limited);
                if (adjustments) qInfo("Qt image adjustment parameters (%s exposure/amount=%.2f offset=%.4f gamma=%.2f reversed=%d custom-colors=%d selected=%d)",
                    qPrintable(entry.kind), entry.amount, entry.offset, entry.gamma, entry.reversed, entry.customColors, limited);
            }
            return 0;
        }

        if (app.arguments().contains("--layer-disjoint-probe")) {
            window.resize(1200, 800); QApplication::processEvents();
            reset(); const auto bottom = window.sessionState().value("activeLayerID");
            for (int i = 0; i < 24; ++i) command({{"action", "addLayer"}});
            tool("Brush", "brush");
            command({{"action", "selectLayer"}, {"layerID", bottom}});
            const auto table = [&]() -> QWidget * {
                for (auto *candidate : window.findChildren<QWidget *>())
                    if (candidate->isVisible() && candidate->property("appKitView").toBool()
                        && candidate->property("appKitNode").toString().startsWith("LayersPanel|")) return candidate;
                throw std::runtime_error("disjoint probe table missing");
            };
            const auto selected = [&] {
                auto *list = QAccessible::queryAccessibleInterface(table());
                check(list, "disjoint probe accessible list missing");
                QList<int> result;
                int row = 0;
                for (int i = 0; i < list->childCount(); ++i) {
                    auto *child = list->child(i);
                    if (!child || child->role() != QAccessible::ListItem) continue;
                    if (child->state().selected) result.append(row);
                    ++row;
                }
                check(row == 25, "disjoint probe lost native rows");
                return result;
            };
            const auto tableKey = [&](int code, Qt::KeyboardModifiers modifiers = Qt::NoModifier) {
                table()->setFocus(Qt::OtherFocusReason); QApplication::processEvents();
                QTest::sendKeyEvent(QTest::Click, window.windowHandle(), static_cast<Qt::Key>(code), QString(), modifiers);
                QApplication::processEvents();
            };
            struct Click { const void *owner; uint64_t session; QPoint position, global; QRect geometry; int scroll; };
            std::array<Click, 2> clicks{};
            int clickIndex = 0;
            const auto rowClick = [&](int row, Qt::KeyboardModifiers modifiers) {
                auto *target = table();
                const QPoint position = target->mapTo(&window, QPoint(140, row * 54 + 26));
                QScrollArea *area = nullptr;
                for (auto *parent = target->parentWidget(); parent; parent = parent->parentWidget())
                    if ((area = qobject_cast<QScrollArea *>(parent))) break;
                if (clickIndex < 2) clicks[clickIndex++] = {target, target->property("appKitSession").toULongLong(), position,
                    window.mapToGlobal(position), target->geometry(), area ? area->verticalScrollBar()->value() : -1};
                const auto send = [&](QEvent::Type type, Qt::MouseButtons held) {
                    QMouseEvent event(type, QPointF(position), QPointF(window.mapToGlobal(position)), Qt::LeftButton, held, modifiers);
                    QApplication::sendEvent(window.windowHandle(), &event);
                };
                QTimer::singleShot(0, &window, [&] { send(QEvent::MouseButtonRelease, Qt::NoButton); });
                send(QEvent::MouseButtonPress, Qt::LeftButton);
                QApplication::processEvents();
            };
            const auto undo = window.sessionState().value("undoName"); const QImage source = pixels();
            const auto initial = window.sessionState();
            const auto checkSessionUI = [&] {
                const auto state = window.sessionState();
                for (const char *field : {"tool", "foregroundColor", "backgroundColor"})
                    check(state.value(field) == initial.value(field), "constructing another window reset the current tool or palette");
            };
            const auto checkRows = [&](const QList<int> &expected, const char *phase, int round) {
                const auto actual = selected();
                if (actual != expected) {
                    const auto state = window.sessionState();
                    int primary = -1;
                    const auto layers = state.value("layers").toArray();
                    for (int i = 0; i < layers.size(); ++i)
                        if (layers[i].toObject().value("id") == state.value("activeLayerID")) primary = layers.size() - 1 - i;
                    auto *focus = QApplication::focusWidget();
                    qWarning() << "disjoint phase mismatch" << phase << "round" << round << "actual/expected" << actual << expected
                               << "primary" << primary << "focus" << focus
                               << "focus session" << (focus ? focus->property("appKitSession").toULongLong() : 0)
                               << "current session" << window.sessionHandle();
                    qWarning().noquote() << swiftUIPointerTrace();
                    qWarning().noquote() << swiftUIScrollTrace();
                }
                check(actual == expected, phase);
            };
            for (int round = 0; round < 16; ++round) {
                if (round % 2) {
                    {
                        SessionWindow second;
                        checkSessionUI();
                        second.createNewDocument(64, 64); second.resize(1200, 800); second.show(); QApplication::processEvents();
                        for (auto *candidate : second.findChildren<QWidget *>())
                            if (candidate->isVisible() && candidate->property("appKitView").toBool()) {
                                candidate->setFocus(Qt::OtherFocusReason); break;
                            }
                        QApplication::processEvents(); second.hide(); QApplication::processEvents();
                    }
                    check(compositor_workspace_select_tab(window.sessionHandle()) == 0, "disjoint probe could not restore workspace");
                    QApplication::setActiveWindow(&window); QApplication::processEvents();
                    checkSessionUI();
                    check(window.currentTool() == SessionWindow::Tool::Brush, "restored window does not mirror its Brush tool");
                }
                tableKey(Qt::Key_Home); clickIndex = 0;
                rowClick(2, Qt::NoModifier); rowClick(8, Qt::ControlModifier);
                const auto rows = selected();
                if (rows != QList<int>({2, 8})) {
                    qWarning() << "disjoint probe mismatch" << round << "selected" << rows << "current session" << window.sessionHandle();
                    for (const auto &entry : clicks) qWarning() << "row click widget/session" << entry.owner << entry.session
                        << "position/global" << entry.position << entry.global << "geometry/scroll" << entry.geometry << entry.scroll;
                    qWarning().noquote() << swiftUIPointerTrace();
                    qWarning().noquote() << swiftUIScrollTrace();
                }
                check(rows == QList<int>({2, 8}), "disjoint probe Command-click selected the wrong rows");
                rowClick(6, Qt::ShiftModifier);
                checkRows({2, 6, 7, 8}, "disjoint probe Shift-click lost the base", round);
                tableKey(Qt::Key_Up, Qt::ShiftModifier);
                checkRows({2, 5, 6, 7, 8}, "disjoint probe Shift-Up lost the clicked range", round);
                tableKey(Qt::Key_Down, Qt::ShiftModifier);
                checkRows({2, 6, 7, 8}, "disjoint probe Shift-Down did not contract", round);
                check(window.sessionState().value("undoName") == undo && pixels() == source, "disjoint probe edited the document");
                qInfo("Qt disjoint probe OK (round=%d, second-window=%d, Command/Shift clicks and arrows, exact selection, no document edit)", round, round % 2);
            }
            return 0;
        }

        if (app.arguments().contains("--keyboard-cursor-probe")) {
            reset(); tool("Zoom", "zoom"); canvas->setFocus();
            const QPointF position = canvas->rect().center();
            const auto hover = [&] {
                mouse(canvas, QEvent::MouseMove, position, Qt::NoButton, Qt::NoButton, Qt::NoModifier);
            };
            const auto sameCursor = [](const QCursor &a, const QCursor &b) {
                return a.shape() == b.shape() && a.hotSpot() == b.hotSpot()
                    && a.pixmap().toImage() == b.pixmap().toImage();
            };
            hover();
            check(canvas->cursor().shape() == Qt::BitmapCursor, "Zoom hover did not display its pictured cursor");
            const auto before = window.sessionState(); const QImage source = pixels();
            struct Choice { int code; const char *text; const char *label; const char *name; Qt::CursorShape shape; };
            for (const auto &choice : {Choice{Qt::Key_H, "h", "Hand", "hand", Qt::OpenHandCursor},
                                       Choice{Qt::Key_Z, "z", "Zoom", "zoom", Qt::BitmapCursor}}) {
                key(canvas, choice.code, Qt::NoModifier, choice.text);
                QApplication::processEvents();
                checkTool(choice.label, choice.name);
                const QCursor afterKey = canvas->cursor();
                hover();
                const QCursor afterHover = canvas->cursor();
                check(afterHover.shape() == choice.shape, "stationary hover retained a cursor from another tool");
                if (!sameCursor(afterKey, afterHover))
                    qWarning() << "keyboard cursor mismatch" << choice.name
                               << "before/after hover shapes" << afterKey.shape() << afterHover.shape();
                check(sameCursor(afterKey, afterHover), "keyboard tool change left its cursor stale until the next hover");
                qInfo("Qt keyboard cursor OK (%s, native shape/picture/hotspot already correct before a stationary hover)", choice.name);
            }
            const auto after = window.sessionState();
            for (const char *field : {"layers", "activeLayerID", "undoName", "redoName", "canUndo", "canRedo", "modified"})
                check(before.value(field) == after.value(field), "keyboard cursor refresh changed source, target or history");
            check(pixels() == source, "keyboard cursor refresh changed document pixels");
            return 0;
        }

        if (app.arguments().contains("--zoom-cursor-probe")) {
            const auto viewport = [&] {
                std::array<double, 6> result{};
                check(compositor_session_viewport(window.sessionHandle(), result.data()) == 0, "cursor viewport unavailable");
                return result;
            };
            const auto picture = [&] {
                check(canvas->cursor().shape() == Qt::BitmapCursor, "canvas did not install upstream's pictured zoom cursor");
                const auto image = canvas->cursor().pixmap().toImage();
                check(!image.isNull(), "zoom cursor has no native picture");
                return image;
            };
            const auto isolated = [&](const QJsonObject &before, const QImage &source) {
                const auto after = window.sessionState();
                for (const char *field : {"layers", "activeLayerID", "undoName", "redoName", "canUndo", "canRedo", "modified"})
                    check(before.value(field) == after.value(field), "canvas navigation changed source, target or history");
                check(pixels() == source, "canvas navigation changed document pixels");
            };
            for (bool optionOnRelease : {false, true}) {
                reset(); tool("Zoom", "zoom"); canvas->setFocus();
                const auto before = window.sessionState(); const QImage source = pixels();
                const QPointF start = canvas->rect().center();
                const double initial = viewport()[0];
                mouse(canvas, QEvent::MouseButtonPress, start, Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
                const QImage plus = picture();
                const auto move = [&](int dx) {
                    mouse(canvas, QEvent::MouseMove, start + QPointF(dx, 0), Qt::NoButton, Qt::LeftButton, Qt::NoModifier);
                };
                move(100);
                check(std::abs(viewport()[0] / initial - 2) < 1e-6 && picture() == plus,
                      "Zoom drag did not double or retain the plus cursor");
                move(80); const QImage minus = picture();
                check(minus != plus && viewport()[0] > initial, "Zoom reversal waited to cross the starting point");
                move(80); check(picture() == minus, "stationary Zoom sample changed direction");
                move(90); check(picture() == plus, "Zoom forward reversal did not restore plus");
                move(70); check(picture() == minus, "Zoom backward reversal did not restore minus");
                const auto modifiers = optionOnRelease ? Qt::AltModifier : Qt::NoModifier;
                mouse(canvas, QEvent::MouseButtonRelease, start + QPointF(70, 0), Qt::LeftButton, Qt::NoButton, modifiers);
                check(picture() == (optionOnRelease ? minus : plus), "Zoom release did not restore its modifier cursor");
                const double prior = viewport()[0];
                mouse(canvas, QEvent::MouseButtonPress, start, Qt::LeftButton, Qt::LeftButton, modifiers);
                mouse(canvas, QEvent::MouseButtonRelease, start, Qt::LeftButton, Qt::NoButton, modifiers);
                check(std::abs(viewport()[0] / prior - (optionOnRelease ? 0.5 : 2)) < 1e-6,
                      "Zoom click no longer follows Alt");
                isolated(before, source);
                qInfo("Qt Zoom cursor OK (Alt release=%d, immediate reversals above start, stationary sample, native pictures, click ratio, source/history isolation)", optionOnRelease);
            }
            for (const auto modifier : {Qt::ControlModifier, Qt::MetaModifier}) {
                reset(); tool("Move", "move"); canvas->setFocus();
                const auto before = window.sessionState(); const QImage source = pixels();
                const QPointF start = canvas->rect().center();
                mouse(canvas, QEvent::MouseButtonPress, start, Qt::MiddleButton, Qt::MiddleButton, modifier);
                const QImage plus = picture();
                const double initial = viewport()[0];
                const auto move = [&](int rise) {
                    mouse(canvas, QEvent::MouseMove, start - QPointF(0, rise), Qt::NoButton, Qt::MiddleButton, modifier);
                };
                move(100); const double peak = viewport()[0];
                check(peak > initial && picture() == plus, "middle zoom did not increase with its plus cursor");
                move(80); const QImage minus = picture();
                check(viewport()[0] < peak && viewport()[0] > initial, "middle zoom reversal moved to the wrong zoom level");
                check(minus != plus, "middle zoom reversal did not update its cursor above the starting point");
                move(80); check(picture() == minus, "stationary middle zoom changed cursor direction");
                move(-100); check(picture() == minus && viewport()[0] < initial, "middle zoom lost its downward cursor");
                move(-80); check(picture() == plus, "middle zoom reversal below the starting point did not restore plus");
                mouse(canvas, QEvent::MouseButtonRelease, start + QPointF(0, 80), Qt::MiddleButton, Qt::NoButton, modifier);
                check(canvas->cursor().shape() != Qt::ClosedHandCursor, "middle zoom release retained a grabbing cursor");
                isolated(before, source);
                qInfo("Qt middle Zoom cursor OK (modifier=%d, native pictures, immediate reversals above/below start, stationary sample, source/history isolation)", int(modifier));
            }
            for (const auto &name : {QString("Move"), QString("Brush")}) {
                reset(); tool(name, name.toLower()); canvas->setFocus();
                const auto before = window.sessionState(); const QImage source = pixels();
                const QPointF start = canvas->rect().center(); const auto initial = viewport();
                mouse(canvas, QEvent::MouseButtonPress, start, Qt::MiddleButton, Qt::MiddleButton, Qt::NoModifier);
                check(canvas->cursor().shape() == Qt::ClosedHandCursor, "middle pan press did not install the grabbing cursor");
                mouse(canvas, QEvent::MouseMove, start + QPointF(25, 17), Qt::NoButton, Qt::MiddleButton, Qt::NoModifier);
                const auto moved = viewport();
                check(std::abs(moved[1] - initial[1] - 25) < 1e-6 && std::abs(moved[2] - initial[2] - 17) < 1e-6
                          && moved[0] == initial[0] && canvas->cursor().shape() == Qt::ClosedHandCursor,
                      "middle pan changed zoom, lost pointer distance or lost the grabbing cursor");
                mouse(canvas, QEvent::MouseButtonRelease, start + QPointF(25, 17), Qt::MiddleButton, Qt::NoButton, Qt::NoModifier);
                check(canvas->cursor().shape() != Qt::ClosedHandCursor, "middle pan release retained the grabbing cursor");
                isolated(before, source);
                qInfo("Qt middle pan cursor OK (%s, exact pointer distance, no zoom/paint, grabbing/release, source/history isolation)", qPrintable(name));
            }
            return 0;
        }

        if (app.arguments().contains("--upstream-153-probe")) {
            reset();
            for (int i = 0; i < 25; ++i) command({{"action", "addLayer"}});
            const auto layerTable = [&]() -> QWidget * {
                for (auto *widget : window.findChildren<QWidget *>())
                    if (widget->isVisible() && widget->property("appKitView").toBool()
                        && widget->property("appKitNode").toString().startsWith("LayersPanel|")) return widget;
                throw std::runtime_error("1.5.3 native layer table missing");
            };
            const auto scroll = [&]() -> QScrollArea * {
                for (auto *area : window.findChildren<QScrollArea *>())
                    if (area->isVisible() && area->property("appKitScroll").toBool()
                        && area->property("appKitScrollNode").toString().startsWith("LayersPanel|")) return area;
                return nullptr;
            };
            const auto offset = [&] {
                auto *area = scroll(); check(area, "1.5.3 current Layers viewport missing");
                return area->verticalScrollBar()->value();
            };
            pump([&] { return scroll() && scroll()->verticalScrollBar()->maximum() > 200; },
                 "1.5.3 Layers viewport is not scrollable");
            scroll()->verticalScrollBar()->setValue(0); QApplication::processEvents();
            const auto before = window.sessionState(); const QImage original = pixels();
            const QPointF start = layerTable()->mapToGlobal(QPoint(60, 78));
            const auto middle = [&](QEvent::Type type, QPointF global, bool release = false) {
                auto *table = layerTable();
                mouse(table, type, table->mapFromGlobal(global.toPoint()),
                      type == QEvent::MouseMove ? Qt::NoButton : Qt::MiddleButton,
                      release ? Qt::NoButton : Qt::MiddleButton, Qt::NoModifier);
            };
            middle(QEvent::MouseButtonPress, start);
            middle(QEvent::MouseMove, start - QPointF(0, 40));
            check(std::abs(offset() - 40) <= 1, "middle layer drag did not synchronize its live viewport");
            middle(QEvent::MouseMove, start - QPointF(0, 80));
            check(std::abs(offset() - 80) <= 1, "middle layer drag lost window coordinates after scrolling");
            middle(QEvent::MouseButtonRelease, start - QPointF(0, 80), true);
            for (int i = 0; i < 10; ++i) { QApplication::processEvents(); QThread::msleep(1); }
            check(std::abs(offset() - 80) <= 1, "middle layer release reset the viewport");
            const QPointF again = layerTable()->mapToGlobal(QPoint(60, 120));
            middle(QEvent::MouseButtonPress, again);
            middle(QEvent::MouseMove, again + QPointF(0, 200));
            middle(QEvent::MouseButtonRelease, again + QPointF(0, 200), true);
            check(offset() == 0, "middle layer drag did not clamp to the document start");
            const auto after = window.sessionState();
            for (const char *field : {"layers", "activeLayerID", "undoName", "redoName", "canUndo", "canRedo", "modified"})
                check(after.value(field) == before.value(field), "middle Layers scrolling changed selection, source or history");
            check(pixels() == original, "middle Layers scrolling changed document pixels");
            qInfo("Qt 1.5.3 middle Layers OK (thumbnail press, live 40/80 px, scroll-coordinate continuity, release retention, boundary clamp, source/selection/history isolation)");

            const auto radius = [&](const QString &text) {
                QLineEdit *field = nullptr;
                for (auto *candidate : window.findChildren<QLineEdit *>())
                    if (candidate->isVisible() && candidate->placeholderText() == "Radius") field = candidate;
                check(field, "1.5.3 Shape Radius field missing");
                field->setFocus(); field->selectAll(); field->insert(text);
                const QPointer<QLineEdit> retained(field);
                const int cursor = field->cursorPosition();
                pump([&] {
                    for (auto *box : window.findChildren<QCheckBox *>())
                        if (box->isVisible() && box->text() == "Smooth Corners")
                            return box->isEnabled() == (text.toDouble() > 0);
                    return false;
                }, "Shape Radius did not refresh Smooth Corners while typing");
                check(retained && QApplication::focusWidget() == retained && retained->cursorPosition() == cursor
                          && retained->text() == text,
                      "Shape dependent-control refresh replaced its focused field or moved its cursor");
                key(retained, Qt::Key_Return); QApplication::processEvents();
            };
            const auto smoothing = [&]() -> QCheckBox * {
                for (auto *box : window.findChildren<QCheckBox *>())
                    if (box->isVisible() && box->text() == "Smooth Corners") return box;
                throw std::runtime_error("1.5.3 visible Smooth Corners control missing");
            };
            for (bool smooth : {false, true}) {
                command({{"action", "new"}, {"width", 64}, {"height", 64}, {"emptyLayer", true}});
                command({{"action", "setPaletteColor"}, {"kind", "foreground"},
                         {"parameters", QJsonObject{{"red", 0}, {"green", 0}, {"blue", 1}}}});
                tool("Shape", "shape");
                QPushButton *rectangle = nullptr;
                for (auto *picker : window.findChildren<QWidget *>("segmentedPicker"))
                    for (auto *button : picker->findChildren<QPushButton *>())
                        if (button->isVisible() && button->text() == "Rectangle") rectangle = button;
                click(rectangle); radius("0");
                check(!smoothing()->isEnabled(), "Smooth Corners must be disabled at zero radius");
                radius("12");
                try { pump([&] { return smoothing()->isEnabled(); }, "positive Radius did not enable Smooth Corners"); }
                catch (...) {
                    const auto size = compositor_session_render_tree(window.sessionHandle(), "ToolHeaders", nullptr, 0);
                    if (size > 0 && size < 1024 * 1024) {
                        QByteArray bytes(qsizetype(size), Qt::Uninitialized);
                        compositor_session_render_tree(window.sessionHandle(), "ToolHeaders", reinterpret_cast<uint8_t *>(bytes.data()), bytes.size());
                        std::function<void(const QJsonObject &)> inspect = [&](const QJsonObject &node) {
                            if (node.value("kind").toString() == "TextField" || node.value("kind").toString() == "Toggle")
                                qWarning().noquote() << "Shape model control" << QJsonDocument(node).toJson(QJsonDocument::Compact);
                            for (const auto &child : node.value("children").toArray()) inspect(child.toObject());
                        };
                        inspect(QJsonDocument::fromJson(bytes).object());
                    }
                    qWarning() << "Shape Qt control" << smoothing()->isEnabled() << "focus" << QApplication::focusWidget();
                    throw;
                }
                if (smoothing()->isChecked() != smooth) click(smoothing());
                const auto beforeShape = window.sessionState(); const QImage blank = pixels();
                mouse(canvas, QEvent::MouseButtonPress, at(8, 8), Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
                mouse(canvas, QEvent::MouseMove, at(56, 56), Qt::NoButton, Qt::LeftButton, Qt::NoModifier);
                const QImage preview = pixels();
                check(window.sessionState().value("undoName") == beforeShape.value("undoName") && preview != blank,
                      "Shape draft failed to preview without a history step");
                mouse(canvas, QEvent::MouseButtonRelease, at(56, 56), Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
                const QImage committed = pixels(); const auto created = window.sessionState();
                for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                    const QColor a = preview.pixelColor(x, y), b = committed.pixelColor(x, y);
                    check(std::abs(a.alpha() - b.alpha()) <= 1 && a.rgb() == b.rgb(), "Shape preview and commit use different corner geometry");
                }
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(pixels() == blank && window.sessionState().value("layers") == beforeShape.value("layers"), "smoothed Shape Undo lost source");
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                check(pixels() == committed && window.sessionState().value("layers") == created.value("layers"), "smoothed Shape Redo lost exact pixels/records");
                qInfo("Qt 1.5.3 Shape controls OK (smooth=%d, zero-radius refusal, visible Radius/checkbox, live preview equals commit, exact Undo/Redo)", smooth);
            }
            return 0;
        }

        if (app.arguments().contains("--transform-snap-probe")) {
            const auto toggle = [&](const QString &submenu, const QString &title, bool enabled) {
                const auto locate = [&](QMenu *view) -> QAction * {
                    if (!view) return nullptr;
                    QMenu *menu = view;
                    if (!submenu.isEmpty()) {
                        menu = nullptr;
                        for (auto *action : view->actions())
                            if (action->text().remove('&') == submenu) menu = action->menu();
                    }
                    if (menu) for (auto *action : menu->actions())
                        if (action->text().remove('&') == title) return action;
                    return nullptr;
                };
                QPointer<QMenu> view = window.findChild<QMenu *>("appMenu.View");
                check(view && view->menuAction()->isVisible(), "snap View menu missing");
                view->popup(window.mapToGlobal(QPoint(180, 60))); QApplication::processEvents();
                QPointer<QAction> action = locate(view);
                check(action && action->isCheckable() && action->isEnabled(), "snap menu toggle unavailable");
                QPointer<QMenu> child;
                if (!submenu.isEmpty()) {
                    for (auto *entry : view->actions()) if (entry->text().remove('&') == submenu) child = entry->menu();
                    check(child, "snap submenu missing");
                    child->popup(view->mapToGlobal(QPoint(view->width(), 20))); QApplication::processEvents();
                }
                if (action->isChecked() != enabled) action->trigger();
                if (child) child->hide();
                if (view) view->hide();
                QApplication::processEvents(); QApplication::processEvents();
                auto *fresh = locate(window.findChild<QMenu *>("appMenu.View"));
                check(fresh && fresh->isChecked() == enabled, "snap menu toggle did not retain its checked state");
            };
            const auto zoom = [&](int screenPercent) {
                tool("Zoom", "zoom");
                QLineEdit *field = nullptr;
                for (auto *candidate : window.findChildren<QLineEdit *>())
                    if (candidate->isVisible() && candidate->placeholderText() == "Zoom") field = candidate;
                check(field, "snap Zoom field missing");
                const int percent = qRound(screenPercent * canvas->devicePixelRatioF());
                field->setFocus(); field->selectAll(); field->insert(QString::number(percent));
                key(field, Qt::Key_Return);
                pump([&] { return std::abs(window.sessionState().value("zoom").toDouble() - percent / 100.0) < 0.0001; },
                     "snap Zoom field did not apply");
                tool("Move", "move");
                check(std::abs(at(1, 0).x() - at(0, 0).x() - screenPercent / 100.0) < 0.0001,
                      "snap fixture does not have the requested screen-point scale");
            };
            QImage red(8, 8, QImage::Format_RGBA8888), blue(24, 16, QImage::Format_RGBA8888), blueVertical(16, 24, QImage::Format_RGBA8888);
            red.fill(Qt::red); blue.fill(Qt::blue); blueVertical.fill(Qt::blue);
            const QString redPath = temporary.filePath("snap-moving.png"), bluePath = temporary.filePath("snap-target.png");
            const QString blueVerticalPath = temporary.filePath("snap-target-vertical.png");
            check(red.save(redPath) && blue.save(bluePath) && blueVertical.save(blueVerticalPath), "snap fixtures could not be saved");
            struct Case {
                QString source, label;
                int percent, rawX, expectedX, line;
                bool snap = true, sourceOn = true, visible = true;
                Qt::KeyboardModifiers modifiers = Qt::NoModifier;
                int resize = 0, expectedWidth = 8, expectedHeight = 8;
                bool linked = false;
            };
            QList<Case> cases{
                {"bounds", "left edge", 100, 3, 0, 0},
                {"bounds", "center", 100, 27, 28, 32},
                {"bounds", "right edge", 100, 55, 56, 64},
                {"bounds", "outside tolerance", 100, 45, 45, -1},
                {"bounds", "three pixels / three points", 100, 53, 56, 64},
                {"bounds", "three pixels / six points", 200, 53, 56, 64},
                {"bounds", "three pixels / twelve points", 400, 53, 53, -1},
                {"bounds", "two pixels / eight points", 400, 54, 56, 64},
                {"bounds", "Control suppresses", 100, 53, 53, -1, true, true, true, Qt::MetaModifier},
                {"bounds", "Snap off", 100, 53, 53, -1, false},
                {"bounds", "target off", 100, 53, 53, -1, true, false},
                {"layers", "left edge", 100, 27, 28, 36},
                {"layers", "center", 100, 43, 44, 48},
                {"layers", "right edge", 100, 51, 52, 60},
                {"layers", "center zoomed", 400, 43, 44, 48},
                {"layers", "target off", 100, 43, 43, -1, true, false},
                {"guides", "edge", 100, 24, 25, 25},
                {"guides", "center", 100, 20, 21, 25},
                {"guides", "center zoomed", 400, 20, 21, 25},
                {"guides", "outside tolerance", 100, 42, 42, -1},
                {"guides", "hidden", 100, 20, 20, -1, true, true, false},
                {"guides", "target off", 100, 20, 20, -1, true, false},
                {"guides", "Snap off", 100, 20, 20, -1, false},
                {"guides", "Control suppresses", 100, 20, 20, -1, true, true, true, Qt::MetaModifier},
            };
            const auto resizeCase = [](const QString &source, const QString &label, int edge, int width, int line) {
                Case entry{source, label, 400, edge, 12, line};
                entry.resize = 1; entry.expectedWidth = width; entry.expectedHeight = 16;
                return entry;
            };
            cases.append(resizeCase("layers", "side edge", 35, 24, 36));
            cases.append(resizeCase("layers", "side outside tolerance", 33, 21, -1));
            auto resizeOff = resizeCase("layers", "side Snap off", 35, 23, -1);
            resizeOff.snap = false; cases.append(resizeOff);
            auto resizeFree = resizeCase("layers", "side Control suppresses", 35, 23, -1);
            resizeFree.modifiers = Qt::MetaModifier; cases.append(resizeFree);
            auto corner = resizeCase("layers", "proportional corner", 35, 24, 36);
            corner.resize = 2; corner.linked = true; corner.expectedHeight = 24; cases.append(corner);
            cases.append(resizeCase("bounds", "side edge", 63, 52, 64));
            cases.append(resizeCase("bounds", "side outside tolerance", 61, 49, -1));
            cases.append(resizeCase("guides", "side edge", 24, 13, 25));
            auto hidden = resizeCase("guides", "side hidden", 24, 12, -1);
            hidden.visible = false; cases.append(hidden);
            for (bool vertical : {false, true}) for (const auto &entry : cases) {
                const int originY = entry.resize ? 24 : 28;
                const auto point = [&](double x, double y) { return vertical ? at(y, x) : at(x, y); };
                command({{"action", "new"}, {"width", 64}, {"height", 64}, {"emptyLayer", false}});
                command({{"action", "importFiles"}, {"paths", QJsonArray{vertical ? blueVerticalPath : bluePath}}});
                command({{"action", "transform"}, {"parameters", QJsonObject{{"x", vertical ? 24 : 36}, {"y", vertical ? 36 : 24}}}});
                command({{"action", "importFiles"}, {"paths", QJsonArray{redPath}}});
                command({{"action", "transform"}, {"parameters", QJsonObject{{"x", vertical ? originY : 12}, {"y", vertical ? 12 : originY},
                    {"width", entry.resize ? 16 : 8}, {"height", entry.resize ? 16 : 8}}}});
                command({{"action", "setShowsTransformControls"}, {"enabled", entry.resize != 0}});
                command({{"action", "setTransformAutoSelect"}, {"enabled", false}});
                toggle("", "Snap", entry.snap);
                for (const auto &target : {QString("Guides"), QString("Grid"), QString("Layers"), QString("Document Bounds")}) {
                    const bool chosen = target == (entry.source == "bounds" ? "Document Bounds" : entry.source == "layers" ? "Layers" : "Guides");
                    toggle("Snap To", target, chosen && entry.sourceOn);
                }
                toggle("Show", "Grid", false);
                toggle("Show", "Guides", entry.source == "guides");
                if (entry.source == "guides") {
                    command({{"action", "guideCreate"}, {"kind", vertical ? "horizontal" : "vertical"}, {"value", 25}});
                    command({{"action", "guideFinish"}});
                    toggle("Show", "Guides", entry.visible);
                    const auto guides = window.sessionState().value("guides").toArray();
                    check(guides.size() == 1 && guides.first().toObject().value("position").toDouble() == 25,
                          "snap guide fixture has the wrong position");
                }
                zoom(entry.percent);
                if (entry.resize) {
                    QAbstractButton *ratio = nullptr;
                    for (auto *widget : window.findChildren<QWidget *>())
                        if (widget->isVisible() && widget->toolTip().startsWith("Lock aspect ratio.")) {
                            ratio = qobject_cast<QAbstractButton *>(widget);
                            if (!ratio) ratio = widget->findChild<QAbstractButton *>();
                            if (ratio) break;
                        }
                    check(ratio && ratio->isCheckable(), "snap ratio lock missing");
                    if (ratio->isChecked() != entry.linked) {
                        for (auto *parent = ratio->parentWidget(); parent; parent = parent->parentWidget())
                            if (auto *area = qobject_cast<QScrollArea *>(parent)) area->ensureWidgetVisible(ratio);
                        QApplication::processEvents(); click(ratio);
                    }
                    QComboBox *sampling = nullptr;
                    for (auto *combo : window.findChildren<QComboBox *>())
                        if (combo->isVisible() && combo->findText("Nearest") >= 0 && combo->findText("High quality") >= 0) sampling = combo;
                    check(sampling, "snap sampling control missing");
                    key(sampling, Qt::Key_Home); QApplication::processEvents();
                }
                command({{"action", "markSaved"}});
                const auto before = window.sessionState(); const QImage original = pixels();
                const auto id = before.value("activeLayerID");
                const auto verify = [&](const QJsonObject &state, const QImage &image) {
                    check(state.value("layers").toArray().size() == 2 && state.value("activeLayerID") == id,
                          "snapping changed layer count or target");
                    auto expectedLayers = before.value("layers").toArray();
                    for (int i = 0; i < expectedLayers.size(); ++i) {
                        auto layer = expectedLayers[i].toObject();
                        if (layer.value("id") == id) {
                            auto placement = layer.value("transform").toObject();
                            placement["origin"] = vertical ? QJsonArray{originY, entry.expectedX} : QJsonArray{entry.expectedX, originY};
                            placement["size"] = vertical ? QJsonArray{entry.expectedHeight, entry.expectedWidth} : QJsonArray{entry.expectedWidth, entry.expectedHeight};
                            layer["transform"] = placement; expectedLayers[i] = layer;
                        }
                    }
                    if (state.value("layers") != expectedLayers)
                        qWarning() << "snap geometry mismatch" << entry.source << entry.label << "actual" << state.value("layers") << "expected" << expectedLayers;
                    check(state.value("layers") == expectedLayers, "snapping geometry or untouched layer metadata differs");
                    QImage expected(64, 64, QImage::Format_RGBA8888); expected.fill(Qt::transparent);
                    for (int y = 24; y < 40; ++y) for (int x = 36; x < 60; ++x) expected.setPixelColor(vertical ? y : x, vertical ? x : y, Qt::blue);
                    for (int y = originY; y < originY + entry.expectedHeight; ++y)
                        for (int x = entry.expectedX; x < entry.expectedX + entry.expectedWidth; ++x) expected.setPixelColor(vertical ? y : x, vertical ? x : y, Qt::red);
                    check(image == expected, "snapping pixels differ from independent opaque-rectangle oracle");
                };
                canvas->setFocus();
                const QPointF start = entry.resize ? point(28, entry.resize == 2 ? 40 : 32) : point(16, 32);
                const QPointF end = entry.resize ? point(entry.rawX, entry.resize == 2 ? entry.rawX + 10 : 32) : point(entry.rawX + 4, 32);
                mouse(canvas, QEvent::MouseButtonPress, start, Qt::LeftButton, Qt::LeftButton, entry.modifiers);
                mouse(canvas, QEvent::MouseMove, end, Qt::NoButton, Qt::LeftButton, entry.modifiers);
                window.flushPendingDrag(); QApplication::processEvents();
                const auto draft = window.sessionState(); const QImage preview = pixels();
                verify(draft, preview);
                check(draft.value("transforming").toBool() && draft.value("undoName") == before.value("undoName")
                          && !draft.value("modified").toBool(), "snapping preview added a history step");
                const auto lines = draft.value("snapLines").toArray();
                check(lines.size() == 2 && lines[vertical ? 1 : 0].toArray() == (entry.line < 0 ? QJsonArray{} : QJsonArray{entry.line}),
                      "snapping preview has the wrong alignment target");
                const QImage liveScreen = canvas->grab().toImage();
                mouse(canvas, QEvent::MouseButtonRelease, end, Qt::LeftButton, Qt::NoButton, entry.modifiers);
                const auto after = window.sessionState(); const QImage committed = pixels();
                verify(after, committed);
                check(!after.value("transforming").toBool() && after.value("undoName").toString() == "Transform Layer"
                          && after.value("modified").toBool() && committed == preview,
                      "snapping release did not commit exactly its preview");
                const auto cleared = after.value("snapLines").toArray();
                check(cleared.size() == 2 && cleared[0].toArray().isEmpty() && cleared[1].toArray().isEmpty(),
                      "snapping release retained alignment lines");
                if (entry.line > 0 && entry.line < 64 && entry.source != "guides") {
                    const QImage releasedScreen = canvas->grab().toImage();
                    const double dpr = canvas->devicePixelRatioF();
                    const QPoint mark = (point(entry.line, 4) * dpr).toPoint();
                    const int length = qMax(1, qRound(entry.percent / 100.0 * 8 * dpr));
                    const QRect strip = vertical ? QRect(mark.x(), mark.y() - 2, length, 5) : QRect(mark.x() - 2, mark.y(), 5, length);
                    check(liveScreen.copy(strip) != releasedScreen.copy(strip), "native snap line was not visible or did not disappear on release");
                }
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(pixels() == original && window.sessionState().value("layers") == before.value("layers")
                          && !window.sessionState().value("modified").toBool(), "snapping Undo did not restore the exact saved state in one step");
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                check(pixels() == committed && window.sessionState().value("layers") == after.value("layers"),
                      "snapping Redo did not restore exact pixels/records");
                qInfo("Qt transform snap OK (%s, %s, %s, %d%% screen scale, visible menus/Zoom, live geometry/pixels, release and exact Undo/Redo)",
                      vertical ? "vertical" : "horizontal", qPrintable(entry.source), qPrintable(entry.label), entry.percent);
            }
            return 0;
        }

        if (app.arguments().contains("--transform-gestures-probe")) {
            const auto headerButton = [&](const QString &title) -> QPushButton * {
                auto *header = window.findChild<QWidget *>("swiftUIOptionsContainer");
                check(header && header->isVisible(), "transform gesture header missing");
                for (auto *button : header->findChildren<QPushButton *>())
                    if (button->isVisible() && button->isEnabled() && button->text() == title) return button;
                throw std::runtime_error("transform gesture header button missing");
            };
            const auto history = [&](const QJsonObject &before, const QImage &original, const QJsonObject &after, const QImage &changed) {
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(pixels() == original && window.sessionState().value("layers") == before.value("layers")
                          && window.sessionState().value("undoName") == before.value("undoName"),
                      "transform gesture Undo lost exact pixels/records or used more than one history step");
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                check(pixels() == changed && window.sessionState().value("layers") == after.value("layers"),
                      "transform gesture Redo lost exact pixels/records");
            };
            QImage quadrants(64, 64, QImage::Format_RGBA8888);
            for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x)
                quadrants.setPixelColor(x, y, x < 32 ? (y < 32 ? QColor(Qt::red) : QColor(Qt::blue))
                                                                    : (y < 32 ? QColor(Qt::green) : QColor(Qt::yellow)));
            const QString quadrantsPath = temporary.filePath("distort-quadrants.png");
            check(quadrants.save(quadrantsPath), "distortion fixture save failed");
            const QPolygonF square{QPointF(0, 0), QPointF(64, 0), QPointF(64, 64), QPointF(0, 64)};
            for (int variant = 0; variant < 3; ++variant) for (bool apply : {false, true}) {
                check(window.importImage(quadrantsPath), "distortion fixture import failed"); tool("Move", "move");
                command({{"action", "setShowsTransformControls"}, {"enabled", true}});
                command({{"action", "setTransformAutoSelect"}, {"enabled", false}});
                const auto before = window.sessionState(); const QImage original = pixels();
                auto corners = square;
                const QPointF from = variant == 1 ? QPointF(32, 0) : QPointF(0, 0);
                const QPointF offset = variant == 0 ? QPointF(8, 10) : variant == 1 ? QPointF(0, 8) : QPointF(12, 4);
                if (variant == 1) { corners[0] += offset; corners[1] += offset; }
                else corners[0] += variant == 2 ? QPointF(12, 0) : offset;
                const QPointF start = at(from.x(), from.y()), end = at(from.x() + offset.x(), from.y() + offset.y());
                const auto modifiers = Qt::ControlModifier | (variant == 2 ? Qt::ShiftModifier : Qt::NoModifier);
                canvas->setFocus();
                mouse(canvas, QEvent::MouseButtonPress, start, Qt::LeftButton, Qt::LeftButton, modifiers);
                mouse(canvas, QEvent::MouseMove, (start + end) / 2, Qt::NoButton, Qt::LeftButton, modifiers);
                mouse(canvas, QEvent::MouseMove, end, Qt::NoButton, Qt::LeftButton, modifiers);
                mouse(canvas, QEvent::MouseButtonRelease, end, Qt::LeftButton, Qt::NoButton, modifiers);
                const auto draft = window.sessionState(); const auto actualCorners = draft.value("distortCorners").toArray();
                check(draft.value("transformPending").toBool() && actualCorners.size() == 4
                          && draft.value("undoName") == before.value("undoName"),
                      "Ctrl handle drag did not leave an isolated persistent distortion");
                for (int i = 0; i < 4; ++i) {
                    const auto point = actualCorners.at(i).toArray();
                    check(point.size() == 2 && std::abs(point.at(0).toDouble() - corners.at(i).x()) < 0.01
                              && std::abs(point.at(1).toDouble() - corners.at(i).y()) < 0.01,
                          "distortion pointer moved the wrong corner/edge or ignored Shift");
                }
                QTransform inverse;
                check(QTransform::quadToQuad(corners, square, inverse), "independent distortion inverse unavailable");
                const auto verify = [&](const QImage &image) {
                    int interior = 0, exterior = 0;
                    for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                        const auto source = inverse.map(QPointF(x + 0.5, y + 0.5));
                        if (source.x() < -2 || source.x() > 66 || source.y() < -2 || source.y() > 66) {
                            if (image.pixelColor(x, y).alpha() != 0) {
                                image.save("/tmp/compositor-distortion-actual.png");
                                qWarning() << "distortion mismatch variant/apply" << variant << apply << "at" << x << y
                                           << "inverse source" << source << "actual" << image.pixelColor(x, y)
                                           << "corners" << actualCorners;
                            }
                            check(image.pixelColor(x, y).alpha() == 0, "distortion painted outside its independent perspective"); ++exterior;
                        } else if (source.x() > 2 && source.x() < 62 && source.y() > 2 && source.y() < 62
                                   && std::abs(source.x() - 32) > 2 && std::abs(source.y() - 32) > 2) {
                            check(image.pixelColor(x, y) == quadrants.pixelColor(int(source.x()), int(source.y())),
                                  "distortion interior differs from independent Qt perspective"); ++interior;
                        }
                    }
                    check(interior > 2000 && exterior > 20, "distortion oracle did not exercise enough interior/exterior pixels");
                };
                const QImage preview = pixels(); verify(preview);
                click(headerButton(apply ? "Apply" : "Cancel"));
                pump([&] { return !window.sessionState().value("transforming").toBool(); });
                if (apply) {
                    const auto after = window.sessionState(); const QImage committed = pixels(); verify(committed);
                    check(after.value("undoName").toString() == "Distort" && committed == preview
                              && after.value("activeLayerID") == before.value("activeLayerID"),
                          "distortion Apply changed preview/target or omitted its history step");
                    history(before, original, after, committed);
                } else check(pixels() == original && window.sessionState().value("layers") == before.value("layers")
                                 && window.sessionState().value("undoName") == before.value("undoName"),
                             "distortion Cancel changed source records/pixels/history");
                qInfo("Qt distortion gesture OK (variant=%d apply=%d, corner/edge/Shift, independent perspective, Cancel/Apply and exact Undo/Redo)", variant, apply);
            }

            QImage blue(64, 64, QImage::Format_RGBA8888), green(64, 64, QImage::Format_RGBA8888);
            blue.fill(Qt::transparent); green.fill(Qt::transparent);
            for (int y = 16; y < 32; ++y) for (int x = 32; x < 48; ++x) blue.setPixelColor(x, y, Qt::blue);
            for (int y = 48; y < 56; ++y) for (int x = 48; x < 56; ++x) green.setPixelColor(x, y, Qt::green);
            const QString bluePath = temporary.filePath("transform-blue.png"), greenPath = temporary.filePath("transform-untouched.png");
            check(blue.save(bluePath) && green.save(greenPath), "group transform fixtures failed");
            for (bool folder : {false, true}) for (bool resize : {false, true}) {
                reset(); const auto redID = window.sessionState().value("activeLayerID");
                command({{"action", "importFiles"}, {"paths", QJsonArray{greenPath}}});
                const auto greenID = window.sessionState().value("activeLayerID");
                command({{"action", "importFiles"}, {"paths", QJsonArray{bluePath}}});
                const auto blueID = window.sessionState().value("activeLayerID");
                command({{"action", "selectLayer"}, {"layerID", redID}});
                command({{"action", "selectLayer"}, {"layerID", blueID}, {"enabled", true}});
                if (folder) {
                    QPushButton *group = nullptr;
                    for (auto *button : window.findChildren<QPushButton *>())
                        if (button->isVisible() && button->accessibleName() == "New folder") group = button;
                    click(group); check(window.sessionState().value("activeLayerIsGroup").toBool(), "group transform fixture did not select folder");
                }
                tool("Move", "move");
                command({{"action", "setShowsTransformControls"}, {"enabled", true}});
                command({{"action", "setTransformAutoSelect"}, {"enabled", false}});
                QComboBox *sampling = nullptr;
                for (auto *combo : window.findChildren<QComboBox *>())
                    if (combo->isVisible() && combo->findText("Nearest") >= 0 && combo->findText("High quality") >= 0) sampling = combo;
                check(sampling, "group transform sampling control missing");
                key(sampling, Qt::Key_Home); QApplication::processEvents();
                const auto before = window.sessionState(); const QImage original = pixels();
                if (resize) drag(at(64, 64), at(32, 32));
                else drag(at(24, 24), at(31, 29));
                const auto after = window.sessionState(); const QImage changed = pixels();
                check(!after.value("transforming").toBool() && after.value("undoName").toString() == "Transform Layers"
                          && after.value("activeLayerID") == before.value("activeLayerID"),
                      "multi-layer/folder pointer transform did not commit once on release or changed target");
                for (const auto &value : before.value("layers").toArray()) {
                    const auto prior = value.toObject(); QJsonObject current;
                    for (const auto &candidate : after.value("layers").toArray())
                        if (candidate.toObject().value("id") == prior.value("id")) current = candidate.toObject();
                    check(!current.isEmpty(), "group transform lost a layer record");
                    if (prior.value("id") == redID || prior.value("id") == blueID) {
                        auto expected = prior; auto placement = expected.value("transform").toObject();
                        placement["origin"] = QJsonArray{resize ? 0 : 7, resize ? 0 : 5};
                        placement["size"] = QJsonArray{resize ? 32 : 64, resize ? 32 : 64};
                        expected["transform"] = placement;
                        check(current == expected, "group transform did not carry exact child geometry/appearance");
                    } else check(current == prior, "group transform changed unselected layer or folder metadata");
                }
                QImage expected(64, 64, QImage::Format_RGBA8888); expected.fill(Qt::transparent);
                for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                    const int sx = resize ? x * 2 : x - 7, sy = resize ? y * 2 : y - 5;
                    if (fixture.rect().contains(sx, sy)) {
                        const QColor color = blue.pixelColor(sx, sy).alpha() ? blue.pixelColor(sx, sy) : fixture.pixelColor(sx, sy);
                        expected.setPixelColor(x, y, color);
                    }
                    if (green.pixelColor(x, y).alpha()) expected.setPixelColor(x, y, green.pixelColor(x, y));
                }
                check(changed == expected, "group transform pixels differ from independent translation/half-size oracle");
                history(before, original, after, changed);
                check(after.value("layers").toArray().size() == before.value("layers").toArray().size() && !greenID.isNull(),
                      "group transform changed layer count");
                qInfo("Qt group transform gesture OK (folder=%d resize=%d, exact child geometry/pixels, unselected isolation, one-step Undo/Redo)", folder, resize);
            }
            return 0;
        }

        if (app.arguments().contains("--selection-outline-probe")) {
            const auto segment = [&](const QString &title) {
                QPushButton *button = nullptr;
                for (auto *picker : window.findChildren<QWidget *>("segmentedPicker"))
                    for (auto *candidate : picker->findChildren<QPushButton *>())
                        if (candidate->isVisible() && candidate->text() == title) button = candidate;
                click(button);
            };
            const QRect initial(20, 20, 20, 20);
            const auto coverage = [&](const QRect &expected) {
                const auto before = window.sessionState(); const QImage source = pixels();
                command({{"action", "fillForeground"}});
                const QImage filled = pixels();
                for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x)
                    check(filled.pixelColor(x, y) == (expected.contains(x, y) ? QColor(Qt::blue) : source.pixelColor(x, y)),
                          "selection outline all-pixel coverage differs from translated rectangle");
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(pixels() == source && window.sessionState().value("layers") == before.value("layers")
                          && window.sessionState().value("undoName") == before.value("undoName"),
                      "selection outline fill proof did not restore source/history");
            };
            struct Entry { int key; Qt::KeyboardModifiers modifiers; QPoint offset; };
            const QList<Entry> entries{{Qt::Key_Left, Qt::NoModifier, {-1, 0}}, {Qt::Key_Right, Qt::NoModifier, {1, 0}},
                {Qt::Key_Up, Qt::NoModifier, {0, -1}}, {Qt::Key_Down, Qt::NoModifier, {0, 1}},
                {Qt::Key_Left, Qt::ShiftModifier, {-10, 0}}, {Qt::Key_Right, Qt::ShiftModifier, {10, 0}},
                {Qt::Key_Up, Qt::ShiftModifier, {0, -10}}, {Qt::Key_Down, Qt::ShiftModifier, {0, 10}},
                {0, Qt::NoModifier, {7, -5}}, {0, Qt::NoModifier, {-25, 0}}};
            for (const auto &entry : entries) {
                reset(); tool("Marquee", "marquee"); segment("Rectangle"); segment("New");
                command({{"action", "setPaletteColor"}, {"kind", "foreground"},
                         {"parameters", QJsonObject{{"red", 0}, {"green", 0}, {"blue", 1}}}});
                drag(at(20, 20), at(40, 40)); coverage(initial);
                const auto before = window.sessionState(); const QImage source = pixels();
                if (entry.key) key(canvas, entry.key, entry.modifiers);
                else drag(at(30, 30), at(30 + entry.offset.x(), 30 + entry.offset.y()));
                const auto moved = window.sessionState();
                check(moved.value("undoName").toString() == "Move Selection" && pixels() == source
                          && moved.value("layers") == before.value("layers")
                          && moved.value("activeLayerID") == before.value("activeLayerID"),
                      "selection outline movement changed pixels/layers/target or omitted its history step");
                coverage(initial.translated(entry.offset));
                // Undo immediately followed by Redo proves the move is one operation. Fill proofs
                // branch history, so inspect original coverage only after that Redo has completed.
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(window.sessionState().value("undoName") == before.value("undoName") && pixels() == source,
                      "selection outline Undo did not restore the previous history position");
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                coverage(initial.translated(entry.offset));
                key(canvas, Qt::Key_Z, Qt::ControlModifier); coverage(initial);
                qInfo("Qt selection outline OK (key=%d shift=%d, offset=%d,%d, unchanged source/target, exact coverage Undo/Redo)",
                      entry.key, entry.modifiers.testFlag(Qt::ShiftModifier), entry.offset.x(), entry.offset.y());
            }
            return 0;
        }

        // A fresh process reads the persisted shortcut table and exercises real canvas key routing.
        const int bindingProbe = app.arguments().indexOf("--shortcut-binding-probe");
        if (bindingProbe >= 0) {
            check(bindingProbe + 1 < app.arguments().size(), "shortcut probe binding missing");
            const QString requested = app.arguments().at(bindingProbe + 1);
            check(requested == "k" || requested == "b" || requested == "none", "shortcut probe binding invalid");
            const QString expected = requested == "none" ? QString() : requested;
            reset();
            QString loaded;
            for (const auto &entry : window.sessionState().value("shortcuts").toArray())
                if (entry.toObject().value("title").toString() == "Brush tool") loaded = entry.toObject().value("key").toString();
            check(loaded == expected, "fresh process loaded the wrong Brush binding");
            for (const auto code : {Qt::Key_K, Qt::Key_B}) {
                tool("Move", "move");
                const QString text = code == Qt::Key_K ? "k" : "b";
                key(canvas, code, Qt::NoModifier, text);
                pump([&] { return window.sessionState().value("tool").toString() == (expected == text ? "brush" : "move"); },
                     "fresh process did not route the persisted Brush binding");
            }
            check(pixels() == fixture, "fresh-process shortcut routing changed document pixels");
            qInfo("Qt persisted shortcut probe OK (%s, fresh process, loaded settings and native K/B routing)", qPrintable(requested));
            return 0;
        }

        // Initial New Canvas participates in upstream history, including the empty-editor UI and immediate Redo.
        command({{"action", "new"}, {"width", 64}, {"height", 64}, {"emptyLayer", true}});
        const QImage newCanvas = pixels();
        const auto initialLayer = window.sessionState().value("activeLayerID");
        check(window.sessionState().value("canUndo").toBool()
                  && window.sessionState().value("undoName").toString() == "New Canvas"
                  && window.sessionState().value("modified").toBool(), "new canvas history missing");
        key(canvas, Qt::Key_Z, Qt::ControlModifier);
        check(window.sessionState().value("width").toInt() == 0
                  && !window.sessionState().value("canUndo").toBool()
                  && window.sessionState().value("canRedo").toBool()
                  && !window.sessionState().value("modified").toBool(), "new canvas Undo did not restore empty editor");
        pump([&] { auto *welcome = window.findChild<QWidget *>("welcome"); return welcome && welcome->isVisible(); },
             "new canvas Undo did not display upstream welcome");
        key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
        check(window.sessionState().value("width").toInt() == 64
                  && window.sessionState().value("activeLayerID") == initialLayer
                  && !window.sessionState().value("canRedo").toBool()
                  && window.sessionState().value("modified").toBool()
                  && pixels() == newCanvas, "new canvas Redo did not restore layer, pixels and unsaved revision");
        qInfo("combo: new canvas -> Undo to welcome -> Redo OK");

        // Import SVG (README): drawn once into pixels by the platform's SVG renderer; opened alone, at its declared size.
        if (app.arguments().contains("--svg-import-probe")) {
            const QString path = temporary.filePath("two-halves.svg");
            QFile file(path);
            check(file.open(QIODevice::WriteOnly), "SVG fixture open failed");
            file.write(R"(<svg xmlns="http://www.w3.org/2000/svg" width="20" height="10" viewBox="0 0 20 10">)"
                       R"(<rect x="0" y="0" width="10" height="10" fill="#ff0000"/><rect x="10" y="0" width="10" height="10" fill="#0000ff"/></svg>)");
            file.close();
            check(window.importImage(path), "SVG import failed");
            // Opened as its own document, as upstream opens an SVG with no canvas to fit: at its declared 20x10.
            pump([&] { const auto state = window.sessionState();
                       return state.value("width").toInt() == 20 && state.value("height").toInt() == 10 && !state.value("busy").toBool(); },
                 "SVG did not open at its declared size");
            QByteArray bytes(20 * 10 * 4, Qt::Uninitialized);
            check(compositor_session_render(window.sessionHandle(), reinterpret_cast<uint8_t *>(bytes.data()), bytes.size()) == bytes.size(),
                  "SVG document raster unavailable");
            const QImage shown = QImage(reinterpret_cast<const uchar *>(bytes.constData()), 20, 10, 20 * 4,
                                        QImage::Format_RGBA8888_Premultiplied).copy().convertToFormat(QImage::Format_RGBA8888);
            for (int y = 0; y < 10; ++y) for (int x = 0; x < 20; ++x)
                check(shown.pixelColor(x, y) == (x < 10 ? QColor(255, 0, 0) : QColor(0, 0, 255)), "SVG pixels differ from its two exact halves");
            check(window.sessionState().value("layers").toArray().size() == 1, "SVG did not open as one layer");
            qInfo("Qt SVG import OK (Qt SVG renderer, new 20x10 document at the declared size, every pixel of both halves exact, one layer)");
            return 0;
        }

        // Upstream's label scrubbing (NumericScrub): dragging a field's label changes its value live; release applies it.
        if (app.arguments().contains("--scrub-probe")) {
            QImage source(64, 64, QImage::Format_RGBA8888); source.fill(Qt::transparent);
            for (int y = 8; y < 40; ++y) for (int x = 8; x < 40; ++x) source.setPixelColor(x, y, Qt::red);
            const QString path = temporary.filePath("scrub.png");
            check(source.save(path), "scrub fixture save failed");
            check(window.importImage(path), "scrub fixture import failed");
            tool("Move", "move");
            const auto label = [&]() -> QWidget * {
                for (auto *widget : window.findChildren<QWidget *>()) {
                    if (!widget->isVisible() || !widget->property("swiftuiGestureMinimumDistance").isValid()) continue;
                    auto *text = qobject_cast<QLabel *>(widget);
                    if (!text) text = widget->findChild<QLabel *>();
                    if (text && text->text() == "X") return widget;
                }
                throw std::runtime_error("scrubbable X label missing");
            };
            const auto origin = [&] {
                const auto target = window.sessionState().value("activeLayerID");
                for (const auto &value : window.sessionState().value("layers").toArray())
                    if (value.toObject().value("id") == target)
                        return value.toObject().value("transform").toObject().value("origin").toArray().at(0).toDouble();
                throw std::runtime_error("scrub target disappeared");
            };
            const auto before = window.sessionState();
            const QImage original = pixels();
            check(origin() == 0, "scrub fixture is not at the origin");
            click(label());
            check(origin() == 0 && window.sessionState().value("undoName") == before.value("undoName")
                      && !window.sessionState().value("transforming").toBool(), "a plain click on a scrub label changed the layer");
            auto *target = label();
            const QPointF start = target->rect().center();
            mouse(target, QEvent::MouseButtonPress, start, Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
            // As a real drag: after the press the window's tracker follows the pointer (see the Levels handles).
            const auto towards = [&](double dx) { return QPointF(window.mapFromGlobal(target->mapToGlobal((start + QPointF(dx, 0)).toPoint()))); };
            mouse(&window, QEvent::MouseMove, towards(12), Qt::NoButton, Qt::LeftButton, Qt::NoModifier);
            mouse(&window, QEvent::MouseMove, towards(30), Qt::NoButton, Qt::LeftButton, Qt::NoModifier);
            pump([&] { return origin() == 30 && window.sessionState().value("transforming").toBool(); },
                 "dragging the X label did not move the layer live by its translation");
            check(window.sessionState().value("undoName") == before.value("undoName"), "scrubbing committed before release");
            mouse(&window, QEvent::MouseButtonRelease, towards(30), Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
            pump([&] { return !window.sessionState().value("transforming").toBool(); }, "releasing the scrub did not apply it");
            const QImage moved = pixels();
            check(origin() == 30 && window.sessionState().value("undoName").toString() == "Transform Layer" && moved != original
                      && moved.pixelColor(38, 20) == QColor(Qt::red) && moved.pixelColor(8, 20).alpha() == 0,
                  "scrub release did not apply one exact Transform Layer step");
            key(canvas, Qt::Key_Z, Qt::ControlModifier);
            check(origin() == 0 && pixels() == original, "scrub Undo lost the exact source position");
            key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
            check(origin() == 30 && pixels() == moved, "scrub Redo lost the exact result");
            qInfo("Qt label scrub OK (Transform X label: click inert, live draft by drag translation, release applies one Transform Layer step, exact Undo/Redo)");
            return 0;
        }

        // View › CMYK proofs what the canvas shows through upstream's lookups, on white paper; the document, the export
        // composite and history keep the document's own colors.
        if (app.arguments().contains("--cmyk-proof-probe")) {
            QImage source(64, 64, QImage::Format_RGBA8888);
            for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x)
                source.setPixelColor(x, y, x < 32 ? QColor(0, 0, 255) : QColor(128, 128, 128));
            const QString path = temporary.filePath("cmyk-proof.png");
            check(source.save(path), "CMYK proof fixture save failed");
            check(window.importImage(path), "CMYK proof fixture import failed");
            tool("Move", "move");
            const auto toggle = [&](const QString &title, const char *stateKey, bool enabled) {
                QMenu *view = nullptr;
                for (auto *action : window.menuBar()->actions()) if (action->text().remove('&') == "View") view = action->menu();
                check(view, "CMYK View menu missing");
                view->popup(window.mapToGlobal(QPoint(200, 50))); QApplication::processEvents();
                QMenu *cmyk = nullptr;
                for (auto *action : view->actions()) if (action->text().remove('&') == "CMYK") cmyk = action->menu();
                check(cmyk, "View > CMYK submenu missing");
                cmyk->popup(window.mapToGlobal(QPoint(420, 80))); QApplication::processEvents();
                QAction *chosen = nullptr;
                for (auto *action : cmyk->actions()) if (action->text().remove('&') == title) chosen = action;
                check(chosen && chosen->isCheckable() && chosen->isEnabled(), "CMYK proof toggle missing or disabled");
                check(chosen->isChecked() == window.sessionState().value(stateKey).toBool(), "CMYK menu checkmark disagrees with model");
                if (chosen->isChecked() != enabled) chosen->trigger();
                cmyk->hide(); view->hide(); QApplication::processEvents();
                pump([&] { return window.sessionState().value(stateKey).toBool() == enabled; }, "CMYK toggle did not reach model");
            };
            const auto frame = [&] { return canvas->grab().toImage().convertToFormat(QImage::Format_RGBA8888); };
            const auto sample = [&](const QImage &shown, double x, double y) {
                // Pixel centers: from 800% the pixel grid draws hairlines on the pixel boundaries.
                return shown.pixelColor((at(x + 0.5, y + 0.5) * canvas->devicePixelRatioF()).toPoint());
            };
            const auto near = [](const QColor &a, const QColor &b, int tolerance) {
                return qAbs(a.red() - b.red()) <= tolerance && qAbs(a.green() - b.green()) <= tolerance && qAbs(a.blue() - b.blue()) <= tolerance;
            };
            const QColor blue(0, 0, 255), gray(128, 128, 128);
            const auto before = window.sessionState();
            const QImage document = pixels(), off = frame();
            check(sample(off, 16, 32) == blue && sample(off, 48, 32) == gray, "CMYK fixture is not shown as imported");
            toggle("Proof Colors", "proofsColors", true);
            pump([&] { return sample(frame(), 16, 32) != blue; }, "Proof Colors did not change the canvas");
            const QImage proof = frame();
            const QColor proofBlue = sample(proof, 16, 32), proofGray = sample(proof, 48, 32);
            check(proofBlue.blue() < 243 || proofBlue.red() > 12, "Proof Colors did not dull saturated blue");
            check(near(proofGray, gray, 10), "Proof Colors changed mid gray beyond the profile's own tolerance");
            toggle("Gamut Warning", "showsGamutWarning", true);
            pump([&] { return near(sample(frame(), 16, 32), gray, 2); }, "Gamut Warning did not mark unprintable blue gray");
            check(near(sample(frame(), 48, 32), proofGray, 1), "Gamut Warning changed printable gray over the proof");
            toggle("Proof Colors", "proofsColors", false);
            pump([&] { return sample(frame(), 48, 32) == gray; }, "Gamut Warning alone did not show the document's own gray");
            check(near(sample(frame(), 16, 32), gray, 2), "Gamut Warning alone stopped marking blue");
            const auto after = window.sessionState();
            check(pixels() == document && after.value("undoName") == before.value("undoName")
                      && after.value("canUndo") == before.value("canUndo") && after.value("modified") == before.value("modified")
                      && after.value("layers") == before.value("layers"),
                  "CMYK proofing changed the document, export composite or history");
            toggle("Gamut Warning", "showsGamutWarning", false);
            pump([&] { return frame() == off; }, "turning CMYK proofing off did not restore the exact canvas");
            qInfo("Qt CMYK proof OK (visible View > CMYK toggles, proof dulls blue %s and keeps gray %s, gamut warning marks blue, "
                  "document/export/history untouched, exact frame restored)",
                  qPrintable(proofBlue.name()), qPrintable(proofGray.name()));
            return 0;
        }

        if (app.arguments().contains("--transform-fields-probe")) {
            QImage source(64, 64, QImage::Format_RGBA8888); source.fill(Qt::transparent);
            for (int y = 8; y < 40; ++y) for (int x = 8; x < 40; ++x)
                source.setPixelColor(x, y, x < 24 ? QColor(Qt::red) : y < 24 ? QColor(Qt::blue) : QColor(Qt::green));
            const QString path = temporary.filePath("transform-fields.png");
            check(source.save(path), "transform fields fixture save failed");
            const auto expose = [&](QWidget *widget) {
                for (auto *parent = widget->parentWidget(); parent; parent = parent->parentWidget())
                    if (auto *area = qobject_cast<QScrollArea *>(parent)) area->ensureWidgetVisible(widget);
                QApplication::processEvents();
            };
            const auto field = [&](const QString &name) -> QLineEdit * {
                for (auto *candidate : window.findChildren<QLineEdit *>())
                    if (candidate->isVisible() && candidate->placeholderText() == name) return candidate;
                throw std::runtime_error("visible transform numeric field missing");
            };
            const auto ratio = [&]() -> QAbstractButton * {
                for (auto *widget : window.findChildren<QWidget *>())
                    if (widget->isVisible() && widget->toolTip().startsWith("Lock aspect ratio.")) {
                        if (auto *button = qobject_cast<QAbstractButton *>(widget)) return button;
                        if (auto *button = widget->findChild<QAbstractButton *>()) return button;
                    }
                throw std::runtime_error("visible transform ratio lock missing");
            };
            struct Entry { QString name; QString text; bool linked; int x, y, width, height, angle; };
            const QList<Entry> entries{{"X", "8", false, 8, 0, 64, 64, 0}, {"Y", "10", false, 0, 10, 64, 64, 0},
                {"W", "32", false, 0, 0, 32, 64, 0}, {"H", "32", false, 0, 0, 64, 32, 0},
                {"W", "32", true, 0, 0, 32, 32, 0}, {"H", "32", true, 0, 0, 32, 32, 0},
                {"Scale", "50", false, 16, 16, 32, 32, 0}, {"°", "90", false, 0, 0, 64, 64, 90}};
            for (const auto &entry : entries) {
                check(window.importImage(path), "transform fields fixture import failed"); tool("Move", "move");
                const auto sampler = [&]() -> QComboBox * {
                    for (auto *candidate : window.findChildren<QComboBox *>())
                        if (candidate->isVisible() && candidate->findText("Nearest") >= 0 && candidate->findText("High quality") >= 0) return candidate;
                    throw std::runtime_error("visible transform sampling picker missing");
                };
                expose(sampler()); sampler()->setFocus();
                QTest::sendKeyEvent(QTest::Click, window.windowHandle(), Qt::Key_Home, QString(), Qt::NoModifier); QApplication::processEvents();
                pump([&] { return sampler()->currentText() == "Nearest" && !window.sessionState().value("transforming").toBool(); },
                     "transform field nearest-sampling fixture did not settle");
                expose(ratio()); if (ratio()->isChecked() != entry.linked) click(ratio());
                const auto before = window.sessionState(); const QImage original = pixels();
                const auto target = before.value("activeLayerID");
                const auto layer = [&]() -> QJsonObject {
                    for (const auto &value : window.sessionState().value("layers").toArray())
                        if (value.toObject().value("id") == target) return value.toObject();
                    throw std::runtime_error("transform fields target disappeared");
                };
                const auto matchesGeometry = [&]() {
                    const auto transform = layer().value("transform").toObject();
                    const auto origin = transform.value("origin").toArray(), size = transform.value("size").toArray();
                    return origin.size() == 2 && size.size() == 2 && origin.at(0).toDouble() == entry.x && origin.at(1).toDouble() == entry.y
                        && size.at(0).toDouble() == entry.width && size.at(1).toDouble() == entry.height
                        && transform.value("rotation").toDouble() == entry.angle && transform.value("sampling").toString() == "Nearest";
                };
                QImage transformed = original.scaled(entry.width, entry.height, Qt::IgnoreAspectRatio, Qt::FastTransformation);
                if (entry.angle) transformed = transformed.transformed(QTransform().rotate(entry.angle), Qt::FastTransformation);
                QImage expected(64, 64, QImage::Format_RGBA8888); expected.fill(Qt::transparent);
                for (int y = 0; y < transformed.height(); ++y) for (int x = 0; x < transformed.width(); ++x)
                    if (expected.rect().contains(x + entry.x, y + entry.y)) expected.setPixelColor(x + entry.x, y + entry.y, transformed.pixelColor(x, y));
                expose(field(entry.name)); field(entry.name)->setFocus(); QApplication::processEvents();
                field(entry.name)->selectAll(); field(entry.name)->insert(entry.text); QApplication::processEvents();
                try { pump([&] { return matchesGeometry() && pixels() == expected; }, "transform typed value did not match exact Qt geometry/pixels"); }
                catch (...) {
                    const QImage actual = pixels(); int differing = 0; QPoint first(-1, -1);
                    for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x)
                        if (actual.pixelColor(x, y) != expected.pixelColor(x, y) && differing++ == 0) first = QPoint(x, y);
                    qWarning().noquote() << "transform field" << entry.name << entry.text << "linked=" << entry.linked
                        << "layer=" << QJsonDocument(layer()).toJson(QJsonDocument::Compact) << "field=" << field(entry.name)->text()
                        << "enabled=" << field(entry.name)->isEnabled() << "focused=" << (QApplication::focusWidget() == field(entry.name))
                        << "focusWidget=" << (QApplication::focusWidget() ? QApplication::focusWidget()->metaObject()->className() : "none")
                        << "transforming=" << window.sessionState().value("transforming").toBool()
                        << "differing pixels=" << differing << "first=" << first
                        << (first.x() >= 0 ? actual.pixelColor(first).name(QColor::HexArgb) + " vs " + expected.pixelColor(first).name(QColor::HexArgb) : QString());
                    throw;
                }
                check(window.sessionState().value("transforming").toBool() && !window.sessionState().value("transformPending").toBool(),
                      "transform field did not create an automatic draft");
                check(window.sessionState().value("undoName") == before.value("undoName") && window.sessionState().value("modified") == before.value("modified"),
                      "transform field typing committed history too early");
                key(field(entry.name), Qt::Key_Tab);
                pump([&] { return !window.sessionState().value("transforming").toBool() && matchesGeometry(); }, "transform field Tab did not commit its draft");
                const auto committed = window.sessionState();
                check(pixels() == expected && committed.value("undoName").toString() == "Transform Layer"
                          && committed.value("activeLayerID") == target && committed.value("layers").toArray().size() == 1,
                      "transform field commit changed result/target/history");
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(pixels() == original && window.sessionState().value("layers") == before.value("layers"), "transform field Undo lost exact source/records");
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                check(pixels() == expected && window.sessionState().value("layers") == committed.value("layers"), "transform field Redo lost exact result/records");
                qInfo("Qt transform fields OK (%s=%s, linked=%d, visible sampling/ratio/numeric controls, live draft, Tab commit, Qt nearest pixel oracle, exact one-step Undo/Redo)",
                      qPrintable(entry.name), qPrintable(entry.text), entry.linked);
            }
            return 0;
        }

        if (app.arguments().contains("--image-clipboard-probe")) {
            check(qEnvironmentVariableIsEmpty("XCTestConfigurationFilePath"), "image clipboard probe requires the normal system pasteboard");
            systemclipboard::install(); // This test entry bypasses host_run's desktop pasteboard setup.
            QImage base(64, 64, QImage::Format_RGBA8888); base.fill(Qt::transparent);
            QImage top(64, 64, QImage::Format_RGBA8888); top.fill(Qt::transparent);
            for (int y = 8; y < 24; ++y) for (int x = 8; x < 24; ++x) base.setPixelColor(x, y, Qt::red);
            for (int y = 16; y < 40; ++y) for (int x = 16; x < 40; ++x) top.setPixelColor(x, y, Qt::blue);
            const QString basePath = temporary.filePath("clipboard-base.png"), topPath = temporary.filePath("clipboard-top.png");
            check(base.save(basePath) && top.save(topPath), "image clipboard fixtures could not be saved");
            const QRect selection(12, 12, 20, 20);
            const auto action = [&](const QString &title) {
                QMenu *menu = nullptr;
                for (auto *candidate : window.menuBar()->actions())
                    if (candidate->text().remove('&') == "Edit") menu = candidate->menu();
                check(menu, "visible Edit menu missing"); menu->popup(window.mapToGlobal(QPoint(120, 50))); QApplication::processEvents();
                QAction *selected = nullptr;
                for (auto *candidate : menu->actions()) if (candidate->text().remove('&') == title) selected = candidate;
                if (!selected || !selected->isEnabled() || !menu->isVisible())
                    qWarning() << "image clipboard menu diagnostic" << title << "found" << bool(selected)
                               << "enabled" << (selected && selected->isEnabled()) << "visible" << menu->isVisible()
                               << "active window" << QApplication::activeWindow();
                check(selected && selected->isEnabled() && menu->isVisible(), "image clipboard menu action unavailable");
                selected->trigger(); menu->hide(); QApplication::processEvents();
            };
            const auto clipboardImage = [&]() -> QImage {
                const auto *mime = QApplication::clipboard()->mimeData();
                if (!mime || !mime->hasFormat("image/png")) return {};
                return QImage::fromData(mime->data("image/png"), "PNG").convertToFormat(QImage::Format_RGBA8888);
            };
            const auto samePixels = [](const QImage &actual, const QImage &expected) {
                if (actual.size() != expected.size()) return false;
                for (int y = 0; y < actual.height(); ++y) for (int x = 0; x < actual.width(); ++x)
                    if (actual.pixelColor(x, y) != expected.pixelColor(x, y)) return false;
                return true;
            };
            for (const QString &choice : QStringList{"Copy", "Copy Merged", "Cut"}) {
                check(window.importImage(basePath), "image clipboard base import failed");
                command({{"action", "importFiles"}, {"paths", QJsonArray{topPath}}});
                command({{"action", "setShowsTransformControls"}, {"enabled", false}});
                tool("Marquee", "marquee"); drag(at(12, 12), at(32, 32));
                check(window.sessionState().value("hasSelection").toBool(), "image clipboard pointer selection missing");
                const QImage original = pixels(); const auto before = window.sessionState();
                const QImage expectedClip = choice == "Copy Merged" ? original.copy(selection) : top.copy(selection);
                QApplication::clipboard()->clear(); action(choice);
                try { pump([&] { return samePixels(clipboardImage(), expectedClip); }, "image clipboard PNG differs from exact selected/merged pixels"); }
                catch (...) {
                    const auto *data = QApplication::clipboard()->mimeData(); const QImage actual = clipboardImage();
                    qWarning() << "image clipboard diagnostic" << choice << "formats" << (data ? data->formats() : QStringList())
                               << "actual size" << actual.size() << "expected size" << expectedClip.size()
                               << "selection" << window.sessionState().value("selectionRect");
                    if (!actual.isNull()) qWarning() << "image clipboard sample" << actual.pixelColor(0, 0) << actual.pixelColor(actual.width() / 2, actual.height() / 2)
                                                    << "expected" << expectedClip.pixelColor(0, 0) << expectedClip.pixelColor(10, 10);
                    if (actual.size() == expectedClip.size()) {
                        for (int y = 0; y < actual.height(); ++y) for (int x = 0; x < actual.width(); ++x)
                            if (actual.pixelColor(x, y) != expectedClip.pixelColor(x, y))
                                qWarning() << "image clipboard pixel mismatch" << x << y << actual.pixelColor(x, y) << expectedClip.pixelColor(x, y);
                    }
                    throw;
                }
                const QImage copied = clipboardImage();
                qInfo("image clipboard comparison: %s pixels=exact objectEqual=%d actualDPM=%d expectedDPM=%d", qPrintable(choice), copied == expectedClip,
                      copied.dotsPerMeterX(), expectedClip.dotsPerMeterX());
                const auto *mime = QApplication::clipboard()->mimeData();
                check(mime && mime->hasImage(), "image clipboard PNG did not expose image MIME data");
                QImage cut = original;
                if (choice == "Cut") {
                    QImage remaining = top.copy();
                    for (int y = selection.top(); y <= selection.bottom(); ++y)
                        for (int x = selection.left(); x <= selection.right(); ++x) remaining.setPixelColor(x, y, Qt::transparent);
                    for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x)
                        cut.setPixelColor(x, y, remaining.pixelColor(x, y).alpha() ? remaining.pixelColor(x, y) : base.pixelColor(x, y));
                    pump([&] { return !window.sessionState().value("busy").toBool() && pixels() == cut; }, "image Cut changed wrong pixels or did not settle");
                    // Upstream Cut copies, then clearSelectedPixels records its "Clear" action.
                    check(window.sessionState().value("undoName").toString() == "Clear", "image Cut did not retain upstream's Clear history action");
                } else {
                    check(pixels() == original, "image Copy changed document pixels");
                    for (const char *field : {"layers", "activeLayerID", "modified", "undoName", "redoName"})
                        check(window.sessionState().value(field) == before.value(field), "image Copy changed source/history");
                }
                const auto beforePaste = window.sessionState(); action("Paste");
                pump([&] { return window.sessionState().value("layers").toArray().size() == 3 && !window.sessionState().value("busy").toBool(); },
                     "image Paste did not create a layer");
                const auto pasted = window.sessionState(); QJsonObject layer;
                for (const auto &entry : pasted.value("layers").toArray())
                    if (entry.toObject().value("id") == pasted.value("activeLayerID")) layer = entry.toObject();
                const auto transform = layer.value("transform").toObject();
                const auto origin = transform.value("origin").toArray(), size = transform.value("size").toArray();
                check(origin.size() == 2 && size.size() == 2 && origin.at(0).toDouble() == 12 && origin.at(1).toDouble() == 12
                          && size.at(0).toDouble() == 20 && size.at(1).toDouble() == 20,
                      "image Paste lost selection origin or cropped dimensions");
                check(pasted.value("undoName").toString() == "Paste" && pixels() == original, "image Paste did not restore/preserve exact composite");
                QApplication::setActiveWindow(&window); key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(pixels() == cut && window.sessionState().value("layers") == beforePaste.value("layers"), "image Paste Undo lost exact source records/pixels");
                if (choice == "Cut") {
                    key(canvas, Qt::Key_Z, Qt::ControlModifier);
                    check(pixels() == original && window.sessionState().value("layers") == before.value("layers"), "image Cut Undo lost exact source");
                    key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                    check(pixels() == cut && window.sessionState().value("layers") == beforePaste.value("layers"), "image Cut Redo lost exact result");
                }
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                check(pixels() == original && window.sessionState().value("layers") == pasted.value("layers"), "image Paste Redo lost exact result/records");
                qInfo("Qt image clipboard OK (%s > Paste, actual Edit menu/pointer selection, PNG MIME/all-pixel colors, cropped origin/dimensions and exact Undo/Redo)", qPrintable(choice));
            }
            // A Qt editor or another clipboard writer must invalidate the retained selection origin.
            const auto beforeReplacement = window.sessionState(); const QImage beforeReplacementPixels = pixels();
            QImage replacement(6, 8, QImage::Format_RGBA8888); replacement.fill(Qt::green);
            QApplication::clipboard()->setImage(replacement); QApplication::processEvents(); action("Paste");
            pump([&] { return window.sessionState().value("layers").toArray().size() == 4 && !window.sessionState().value("busy").toBool(); },
                 "replacement clipboard Paste did not create a layer");
            const auto replacementState = window.sessionState(); QJsonObject replacementLayer;
            for (const auto &entry : replacementState.value("layers").toArray())
                if (entry.toObject().value("id") == replacementState.value("activeLayerID")) replacementLayer = entry.toObject();
            const auto replacementTransform = replacementLayer.value("transform").toObject();
            check(replacementTransform.value("origin").toArray() == QJsonArray{29, 28}
                      && replacementTransform.value("size").toArray() == QJsonArray{6, 8},
                  "replacement clipboard reused the app's cached image or selection origin");
            QImage expectedReplacement = beforeReplacementPixels;
            for (int y = 28; y < 36; ++y) for (int x = 29; x < 35; ++x) expectedReplacement.setPixelColor(x, y, Qt::green);
            check(pixels() == expectedReplacement, "replacement clipboard Paste changed unexpected pixels");
            QApplication::setActiveWindow(&window); key(canvas, Qt::Key_Z, Qt::ControlModifier);
            check(pixels() == beforeReplacementPixels && window.sessionState().value("layers") == beforeReplacement.value("layers"),
                  "replacement clipboard Undo did not restore exact records/pixels");
            key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
            check(pixels() == expectedReplacement && window.sessionState().value("layers") == replacementState.value("layers"),
                  "replacement clipboard Redo did not restore exact records/pixels");
            qInfo("Qt image clipboard replacement OK (Qt writer invalidates cached selection, centered new image, exact pixels and Undo/Redo)");
            return 0;
        }


        if (app.arguments().contains("--hue-range-handles-probe")) {
            QImage source(64, 64, QImage::Format_RGBA8888); source.fill(Qt::transparent);
            for (int y = 8; y < 56; ++y) for (int x = 8; x < 56; ++x) {
                QColor color = QColor::fromHslF((x - 8) / 48.0, 1, 0.5);
                color.setAlpha(y < 32 ? 128 : 255); source.setPixelColor(x, y, color);
            }
            const QString path = temporary.filePath("hue-range-handles.png");
            check(source.save(path), "Hue range fixture save failed");
            const QStringList ranges{"Reds", "Yellows", "Greens", "Cyans", "Blues", "Magentas"};
            const std::array<std::array<double, 4>, 6> defaults{{{315, 345, 15, 45}, {15, 45, 75, 105}, {75, 105, 135, 165},
                                                              {135, 165, 195, 225}, {195, 225, 255, 285}, {255, 285, 315, 345}}};
            const auto panel = [&]() -> QDialog * {
                auto *dialog = window.findChild<QDialog *>("floatingPanel.HueSaturationSheet");
                return dialog && dialog->isVisible() ? dialog : nullptr;
            };
            const auto button = [&](const QString &title) -> QPushButton * {
                if (auto *dialog = panel()) for (auto *candidate : dialog->findChildren<QPushButton *>())
                    if (candidate->isVisible() && candidate->text() == title) return candidate;
                throw std::runtime_error("visible Hue range button missing");
            };
            const auto toggle = [&](const QString &title) -> QCheckBox * {
                if (auto *dialog = panel()) for (auto *candidate : dialog->findChildren<QCheckBox *>())
                    if (candidate->isVisible() && candidate->text() == title) return candidate;
                throw std::runtime_error("visible Hue range toggle missing");
            };
            const auto bar = [&]() -> QWidget * {
                if (auto *dialog = panel()) for (auto *candidate : dialog->findChildren<QWidget *>())
                    if (candidate->isVisible() && candidate->property("swiftuiGestureMinimumDistance").isValid()
                        && candidate->height() == 12 && candidate->width() > 150) return candidate;
                throw std::runtime_error("visible Hue spectrum handle bar missing");
            };
            const auto forward = [](double from, double to) { double value = std::fmod(to - from, 360); return value < 0 ? value + 360 : value; };
            for (int range = 0; range < 6; ++range) for (int handle = 0; handle < 4; ++handle) {
                check(window.importImage(path), "Hue range fixture import failed");
                command({{"action", "setShowsTransformControls"}, {"enabled", false}});
                const QImage original = pixels(); const auto before = window.sessionState();
                const QImage originalPremultiplied = original.convertToFormat(QImage::Format_RGBA8888_Premultiplied);
                auto band = defaults[range];
                const auto matches = [&](const QImage &image, bool inverted, bool report = false) {
                    const auto weight = [&](double hue) {
                        const double span = forward(band[0], band[3]), position = forward(band[0], hue);
                        const double leading = forward(band[0], band[1]), plateau = forward(band[0], band[2]);
                        double result = position > span ? 0 : position < leading ? position / leading
                            : position <= plateau ? 1 : (span - position) / (span - plateau);
                        return inverted ? 1 - result : result;
                    };
                    for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                        const QColor input = original.pixelColor(x, y), actual = image.pixelColor(x, y);
                        if (input.alpha() != actual.alpha()) return false;
                        if (!input.alpha()) continue;
                        // Preserve fractional straight RGB when undoing premultiplication;
                        // rounding it to RGBA8 first can select a different hue-response degree.
                        const uchar *raw = originalPremultiplied.constScanLine(y) + x * 4;
                        int low[3]; double fraction[3];
                        for (int c = 0; c < 3; ++c) {
                            const double position = raw[c] * 32.0 / raw[3];
                            low[c] = std::min(31, int(position)); fraction[c] = position - low[c];
                        }
                        double expected[3] = {0, 0, 0};
                        // Interpolate the eight neighboring entries of the 33-point
                        // cube; Qt supplies independent RGB/HSL conversion for each entry.
                        for (int corner = 0; corner < 8; ++corner) {
                            double rgb[3], contribution = 1;
                            for (int c = 0; c < 3; ++c) {
                                const bool high = corner & (1 << c);
                                rgb[c] = (low[c] + int(high)) / 32.0;
                                contribution *= high ? fraction[c] : 1 - fraction[c];
                            }
                            if (contribution == 0) continue;
                            const QColor entry = QColor::fromRgbF(rgb[0], rgb[1], rgb[2]);
                            QColor adjusted = entry;
                            if (entry.hslSaturationF() > 0) {
                                const double hue = entry.hslHueF() * 360;
                                adjusted = QColor::fromHslF(std::fmod(hue + 60 * weight(std::round(hue)), 360) / 360,
                                                           entry.hslSaturationF(), entry.lightnessF());
                            }
                            expected[0] += contribution * adjusted.redF() * 255;
                            expected[1] += contribution * adjusted.greenF() * 255;
                            expected[2] += contribution * adjusted.blueF() * 255;
                        }
                        if (std::abs(actual.red() - expected[0]) > 3 || std::abs(actual.green() - expected[1]) > 3
                            || std::abs(actual.blue() - expected[2]) > 3) {
                            if (report)
                                qWarning("Hue cube diagnostic range=%s handle=%d pixel=%d/%d alpha=%d actual=%d/%d/%d expected=%.6f/%.6f/%.6f raw=%d/%d/%d",
                                         qPrintable(ranges[range]), handle, x, y, actual.alpha(), actual.red(), actual.green(), actual.blue(),
                                         expected[0], expected[1], expected[2], raw[0], raw[1], raw[2]);
                            return false;
                        }
                    }
                    return true;
                };
                const auto begin = [&] {
                    command({{"action", "beginHueSaturation"}}); pump([&] { return panel(); }, "Hue range panel missing");
                    const auto picker = [&]() -> QComboBox * {
                        for (auto *candidate : panel()->findChildren<QComboBox *>())
                            if (candidate->isVisible() && candidate->findText("Master") >= 0 && candidate->findText("Reds") >= 0) return candidate;
                        throw std::runtime_error("visible Hue range picker missing");
                    };
                    for (int step = 0; step <= range + 1; ++step) {
                        QApplication::setActiveWindow(panel()); picker()->setFocus();
                        QTest::sendKeyEvent(QTest::Click, panel()->windowHandle(), step == 0 ? Qt::Key_Home : Qt::Key_Down, QString(), Qt::NoModifier);
                        QApplication::processEvents(); pump([&] { return picker()->currentIndex() == step; }, "Hue range keyboard selection failed");
                    }
                    QLineEdit *hue = nullptr;
                    for (auto *candidate : panel()->findChildren<QLineEdit *>())
                        if (candidate->isVisible() && candidate->placeholderText() == "Hue") hue = candidate;
                    check(hue, "Hue numeric control missing"); hue->setFocus(); hue->selectAll(); hue->insert("60"); QApplication::processEvents();
                    QWidget *surface = bar();
                    const int from = qRound(surface->width() * defaults[range][handle] / 360);
                    const double requested = defaults[range][handle] + (handle < 2 ? 10 : -10);
                    const int to = qRound(surface->width() * requested / 360);
                    band = defaults[range]; band[handle] = to * 360.0 / surface->width();
                    const QPoint destination = surface->mapToGlobal(QPoint(to, 6));
                    mouse(surface, QEvent::MouseButtonPress, QPoint(from, 6), Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
                    check(!qobject_cast<QLineEdit *>(QApplication::focusWidget()), "Hue spectrum gesture retained numeric-field editing");
                    mouse(panel(), QEvent::MouseMove, panel()->mapFromGlobal(destination), Qt::NoButton, Qt::LeftButton, Qt::NoModifier);
                    mouse(panel(), QEvent::MouseButtonRelease, panel()->mapFromGlobal(destination), Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
                    try { pump([&] {
                        for (auto *label : panel()->findChildren<QLabel *>()) if (label->isVisible()) {
                            auto values = QRegularExpression("([0-9]+)°").globalMatch(label->text()); int count = 0; bool equal = true;
                            while (values.hasNext()) {
                                const int value = values.next().captured(1).toInt();
                                if (count >= 4 || value != qRound(band[count])) equal = false;
                                ++count;
                            }
                            if (count == 4 && equal) return true;
                        }
                        return false;
                    }, "Hue handle degree labels differ from named gesture coordinates"); }
                    catch (...) {
                        QStringList labels;
                        for (auto *label : panel()->findChildren<QLabel *>())
                            if (label->isVisible() && label->text().contains(QChar(0x00b0))) labels << label->text();
                        qWarning("Hue handle diagnostic range=%s handle=%d width=%d from=%d to=%d expected=%.3f/%.3f/%.3f/%.3f", qPrintable(ranges[range]),
                                 handle, bar()->width(), from, to, band[0], band[1], band[2], band[3]);
                        qWarning() << "Hue visible degree labels" << labels;
                        throw;
                    }
                    try { pump([&] { return matches(pixels(), false); }, "Hue range pixels did not reach the independent HSL/band oracle"); }
                    catch (...) { matches(pixels(), false, true); throw; }
                };
                begin(); const QImage preview = pixels();
                for (const char *name : {"layers", "activeLayerID", "modified", "undoName", "redoName"})
                    check(window.sessionState().value(name) == before.value(name), "Hue handle preview changed source/history");
                click(toggle("Apply outside this range instead"));
                pump([&] { return matches(pixels(), true); }, "Hue inverted range differs from independent oracle");
                click(toggle("Apply outside this range instead")); pump([&] { return pixels() == preview; }, "Hue range inversion did not restore preview");
                click(toggle("Preview")); pump([&] { return pixels() == original; }, "Hue range Preview Off lost source");
                click(toggle("Preview")); pump([&] { return pixels() == preview; }, "Hue range Preview On lost result");
                click(button("Cancel")); pump([&] { return !panel() && pixels() == original; }, "Hue range Cancel lost source");
                begin(); pump([&] { return pixels() == preview; }, "Hue handle repeated preview differs");
                click(button("OK")); pump([&] { return !panel() && !window.sessionState().value("busy").toBool(); }, "Hue range commit did not settle");
                check(pixels() == preview && window.sessionState().value("undoName").toString() == "Hue/Saturation", "Hue range commit differs from preview");
                QApplication::setActiveWindow(&window); key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(pixels() == original && window.sessionState().value("layers") == before.value("layers"), "Hue range Undo lost source/records");
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                check(pixels() == preview && window.sessionState().value("activeLayerID") == before.value("activeLayerID"), "Hue range Redo lost result/target");
                qInfo("Qt Hue range handles OK (%s, handle=%d, visible spectrum drag/degree labels, independent Qt HSL/band oracle, invert/Preview, exact alpha, Cancel/OK and Undo/Redo)", qPrintable(ranges[range]), handle);
            }
            return 0;
        }

        if (app.arguments().contains("--curves-points-probe")) {
            QImage source(64, 64, QImage::Format_RGBA8888); source.fill(Qt::transparent);
            for (int y = 8; y < 56; ++y) for (int x = 8; x < 56; ++x)
                source.setPixelColor(x, y, QColor(128, 128, 128, y < 32 ? 128 : 255));
            const QString path = temporary.filePath("curves-points.png");
            check(source.save(path), "Curves points fixture save failed");
            const auto panel = [&]() -> QDialog * {
                auto *dialog = window.findChild<QDialog *>("floatingPanel.FilterSheet");
                return dialog && dialog->isVisible() ? dialog : nullptr;
            };
            const auto button = [&](const QString &title) -> QPushButton * {
                if (auto *dialog = panel()) for (auto *candidate : dialog->findChildren<QPushButton *>())
                    if (candidate->isVisible() && candidate->text() == title) return candidate;
                throw std::runtime_error("visible Curves button missing");
            };
            const auto graph = [&]() -> QWidget * {
                if (auto *dialog = panel()) for (auto *candidate : dialog->findChildren<QWidget *>())
                    if (candidate->isVisible() && candidate->property("swiftuiGestureMinimumDistance").isValid()
                        && candidate->width() > 150 && candidate->height() == 260) return candidate;
                throw std::runtime_error("visible Curves graph gesture missing");
            };
            const auto selectChannel = [&](int selected) {
                const auto picker = [&]() -> QComboBox * {
                    if (auto *dialog = panel()) for (auto *candidate : dialog->findChildren<QComboBox *>())
                        if (candidate->isVisible() && candidate->findText("RGB") >= 0 && candidate->findText("Red") >= 0) return candidate;
                    throw std::runtime_error("visible Curves channel missing");
                };
                for (int step = 0; step <= selected; ++step) {
                    QApplication::setActiveWindow(panel()); picker()->setFocus();
                    QTest::sendKeyEvent(QTest::Click, panel()->windowHandle(), step == 0 ? Qt::Key_Home : Qt::Key_Down, QString(), Qt::NoModifier);
                    QApplication::processEvents();
                    pump([&] { return picker()->currentIndex() == step; }, "Curves channel did not update");
                }
            };
            const auto stroke = [&](QPoint from, QPoint to) {
                const QPoint destination = graph()->mapToGlobal(to);
                QApplication::setActiveWindow(panel());
                mouse(graph(), QEvent::MouseButtonPress, from, Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
                mouse(panel(), QEvent::MouseMove, panel()->mapFromGlobal(destination), Qt::NoButton, Qt::LeftButton, Qt::NoModifier);
                mouse(panel(), QEvent::MouseButtonRelease, panel()->mapFromGlobal(destination), Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
                pump([&] { return !window.sessionState().value("filterPreviewRendering").toBool(); }, "Curves point preview did not settle");
            };
            for (int selected = 0; selected < 4; ++selected) {
                check(window.importImage(path), "Curves points fixture import failed");
                command({{"action", "setShowsTransformControls"}, {"enabled", false}});
                const auto before = window.sessionState(); const QImage original = pixels();
                const auto begin = [&] {
                    command({{"action", "openFilter"}, {"kind", "Curves"}});
                    pump([&] { return panel() && !window.sessionState().value("filterPreviewRendering").toBool(); }, "Curves points panel did not settle");
                    selectChannel(selected);
                    check(!button("Remove point")->isEnabled(), "Curves initially enabled Remove without a selected interior point");
                };
                const auto add = [&] {
                    const QPoint center(graph()->width() / 2, graph()->height() / 2);
                    stroke(center, center);
                    pump([&] { return button("Remove point")->isEnabled(); }, "Curves click did not create/select an interior point");
                    check(pixels() == original, "Curves identity point changed source colors");
                };
                double raised = 0;
                const auto move = [&] {
                    const QPoint from(graph()->width() / 2, graph()->height() / 2);
                    const QPoint to(graph()->width() / 2, graph()->height() / 4);
                    raised = 255 * (1 - double(to.y()) / graph()->height());
                    stroke(from, to);
                    check(button("Remove point")->isEnabled(), "Curves point move lost its interior selection");
                };
                const auto verify = [&](const QImage &image) {
                    for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                        const auto actual = image.pixelColor(x, y), source = original.pixelColor(x, y);
                        check(actual.alpha() == source.alpha(), "Curves point changed alpha");
                        if (!source.alpha()) continue;
                        for (int c = 1; c < 4; ++c) {
                            const int value = c == 1 ? source.red() : c == 2 ? source.green() : source.blue();
                            const int component = c == 1 ? actual.red() : c == 2 ? actual.green() : actual.blue();
                            const double expected = selected == 0 || selected == c ? raised : value;
                            // All source components lie at the moved middle knot; allow integer/alpha rounding.
                            check(std::abs(component - expected) <= 2, "Curves point/channel pixels differ from the middle-knot oracle");
                        }
                    }
                };
                begin(); add(); move(); const QImage preview = pixels(); verify(preview);
                for (const char *name : {"layers", "activeLayerID", "undoName", "redoName", "modified"})
                    check(window.sessionState().value(name) == before.value(name), "Curves point preview edited source/history");
                click(button("Remove point"));
                pump([&] { return !button("Remove point")->isEnabled() && pixels() == original; }, "Curves Remove did not restore identity");
                add(); move(); click(button("Reset curve"));
                pump([&] { return !button("Remove point")->isEnabled() && pixels() == original; }, "Curves Reset did not restore identity");
                const QPoint endpoint(1, graph()->height() - 1); stroke(endpoint, endpoint);
                check(!button("Remove point")->isEnabled(), "Curves allowed removal of an endpoint");
                click(button("Reset curve"));
                add(); move(); pump([&] { return pixels() == preview; }, "Curves rebuilt point preview differs");
                click(button("Cancel")); pump([&] { return !panel() && pixels() == original; }, "Curves points Cancel lost source");
                begin(); add(); move(); pump([&] { return pixels() == preview; }, "Curves repeated point preview differs");
                click(button("OK")); pump([&] { return !panel() && !window.sessionState().value("busy").toBool(); }, "Curves points commit did not settle");
                check(pixels() == preview && window.sessionState().value("undoName").toString() == "Curves", "Curves points commit differs from preview");
                QApplication::setActiveWindow(&window); key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(pixels() == original && window.sessionState().value("layers") == before.value("layers"), "Curves points Undo lost source/records");
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                check(pixels() == preview && window.sessionState().value("activeLayerID") == before.value("activeLayerID"), "Curves points Redo lost result/target");
                qInfo("Qt Curves points OK (channel=%d, graph add/move, Remove/Reset, endpoint refusal, knot RGB/exact partial alpha, source/history isolation, Cancel/OK and exact Undo/Redo)", selected);
            }
            return 0;
        }

        if (app.arguments().contains("--levels-controls-probe") || app.arguments().contains("--levels-handles-probe")) {
            QImage source(64, 64, QImage::Format_RGBA8888); source.fill(Qt::transparent);
            for (int y = 8; y < 56; ++y) for (int x = 8; x < 56; ++x)
                source.setPixelColor(x, y, y < 32 ? QColor(32 + (x - 8) * 3, 64 + (x - 8) * 2, 96 + x - 8) : QColor(80, 100, 110));
            const QString path = temporary.filePath("levels-controls.png");
            check(source.save(path), "Levels controls fixture save failed");
            const auto panel = [&]() -> QDialog * {
                auto *dialog = window.findChild<QDialog *>("floatingPanel.LevelsSheet");
                return dialog && dialog->isVisible() ? dialog : nullptr;
            };
            const auto button = [&](const QString &title) -> QPushButton * {
                if (auto *dialog = panel()) for (auto *candidate : dialog->findChildren<QPushButton *>())
                    if (candidate->isVisible() && candidate->text() == title) return candidate;
                throw std::runtime_error("visible Levels button missing");
            };
            const auto field = [&](const QString &name) -> double {
                if (auto *dialog = panel()) for (auto *candidate : dialog->findChildren<QLineEdit *>())
                    if (candidate->isVisible() && candidate->placeholderText() == name) {
                        bool valid = false; const double result = candidate->text().toDouble(&valid);
                        check(valid, "Levels field is not numeric"); return result;
                    }
                throw std::runtime_error("visible Levels numeric field missing");
            };
            const auto channel = [&](int selected) {
                const auto picker = [&]() -> QComboBox * {
                    if (auto *dialog = panel()) for (auto *candidate : dialog->findChildren<QComboBox *>())
                        if (candidate->isVisible() && candidate->findText("RGB") >= 0 && candidate->findText("Red") >= 0) return candidate;
                    throw std::runtime_error("visible Levels channel missing");
                };
                for (int step = 0; step <= selected; ++step) {
                    QApplication::setActiveWindow(panel()); picker()->setFocus();
                    QTest::sendKeyEvent(QTest::Click, panel()->windowHandle(), step == 0 ? Qt::Key_Home : Qt::Key_Down, QString(), Qt::NoModifier);
                    QApplication::processEvents();
                    pump([&] { return picker()->currentIndex() == step; }, "Levels channel keyboard selection did not update");
                }
            };
            if (!app.arguments().contains("--levels-handles-probe"))
            for (const QString &choice : QStringList{"Contrast", "Color", "Color + neutral midtones", "Black", "Gray", "White"}) {
                check(window.importImage(path), "Levels controls fixture import failed");
                command({{"action", "setShowsTransformControls"}, {"enabled", false}});
                const QImage original = pixels(); const auto before = window.sessionState();
                double low[4] = {0, 0, 0, 0}, high[4] = {255, 255, 255, 255}, gamma[4] = {1, 1, 1, 1};
                const bool automatic = choice != "Black" && choice != "Gray" && choice != "White";
                if (automatic) {
                    for (int c = 1; c < 4; ++c) {
                        low[c] = 255; high[c] = 0;
                        for (int y = 8; y < 56; ++y) for (int x = 8; x < 56; ++x) {
                            const auto color = original.pixelColor(x, y); const int value = c == 1 ? color.red() : c == 2 ? color.green() : color.blue();
                            low[c] = std::min(low[c], double(value)); high[c] = std::max(high[c], double(value));
                        }
                        if (choice == "Color + neutral midtones") {
                            double mean = 0;
                            for (int y = 8; y < 56; ++y) for (int x = 8; x < 56; ++x) {
                                const auto color = original.pixelColor(x, y); const int value = c == 1 ? color.red() : c == 2 ? color.green() : color.blue();
                                mean += (value - low[c]) / (high[c] - low[c]);
                            }
                            gamma[c] = std::log(mean / (48 * 48)) / std::log(0.5);
                        }
                    }
                    if (choice == "Contrast") {
                        low[0] = std::min({low[1], low[2], low[3]}); high[0] = std::max({high[1], high[2], high[3]});
                        for (int c = 1; c < 4; ++c) { low[c] = 0; high[c] = 255; }
                    }
                } else {
                    const QColor sample = original.pixelColor(24, 24);
                    for (int c = 1; c < 4; ++c) {
                        const int value = c == 1 ? sample.red() : c == 2 ? sample.green() : sample.blue();
                        if (choice == "Black") low[c] = value;
                        else if (choice == "White") high[c] = value;
                        else gamma[c] = std::log(value / 255.0) / std::log(0.5);
                    }
                }
                const auto begin = [&] {
                    command({{"action", "beginLevels"}});
                    pump([&] { return panel() && button(choice)->isEnabled(); }, "Levels histogram/control did not become ready");
                    click(button(choice));
                    if (!automatic) {
                        QApplication::setActiveWindow(&window);
                        mouse(canvas, QEvent::MouseButtonPress, at(1.5, 1.5), Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
                        mouse(canvas, QEvent::MouseButtonRelease, at(1.5, 1.5), Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
                        for (int c = 0; c < 4; ++c) {
                            channel(c);
                            check(field("Input black") == 0 && field("Input white") == 255 && field("Gamma") == 1,
                                  "Levels accepted a transparent sample");
                        }
                        QApplication::setActiveWindow(&window);
                        mouse(canvas, QEvent::MouseButtonPress, at(24.5, 24.5), Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
                        mouse(canvas, QEvent::MouseButtonRelease, at(24.5, 24.5), Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
                    }
                    for (int c = 0; c < 4; ++c) {
                        channel(c);
                        try {
                            pump([&] { return std::abs(field("Input black") - low[c]) <= 1 && std::abs(field("Input white") - high[c]) <= 1
                                                  && std::abs(field("Gamma") - gamma[c]) <= 0.02; }, "Levels channel values differ from histogram/sample oracle");
                        } catch (...) {
                            QString selected;
                            for (auto *combo : panel()->findChildren<QComboBox *>()) if (combo->isVisible()) selected = combo->currentText();
                            qWarning("Levels diagnostic %s channel=%d selected=%s actual=%.3f/%.3f/%.3f expected=%.3f/%.3f/%.3f", qPrintable(choice), c,
                                     qPrintable(selected), field("Input black"), field("Input white"), field("Gamma"), low[c], high[c], gamma[c]);
                            throw;
                        }
                        check(field("Output black") == 0 && field("Output white") == 255, "Levels automatic/sample output range changed");
                    }
                    pump([&] { return pixels() != original; }, "Levels controls did not change preview pixels");
                };
                begin(); const QImage preview = pixels();
                for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                    const auto actual = preview.pixelColor(x, y), color = original.pixelColor(x, y);
                    check(actual.alpha() == color.alpha(), "Levels controls changed source alpha");
                    if (!color.alpha()) continue;
                    for (int c = 1; c < 4; ++c) {
                        const int value = c == 1 ? color.red() : c == 2 ? color.green() : color.blue();
                        double adjusted = std::pow(std::clamp((value - low[c]) / (high[c] - low[c]), 0.0, 1.0), 1 / gamma[c]) * 255;
                        adjusted = std::pow(std::clamp((adjusted - low[0]) / (high[0] - low[0]), 0.0, 1.0), 1 / gamma[0]) * 255;
                        const int component = c == 1 ? actual.red() : c == 2 ? actual.green() : actual.blue();
                        check(std::abs(component - adjusted) <= 2, "Levels preview differs from independent channel equation");
                    }
                }
                check(window.sessionState().value("layers") == before.value("layers") && window.sessionState().value("undoName") == before.value("undoName"),
                      "Levels controls preview edited source/history");
                click(button("Cancel")); pump([&] { return !panel() && pixels() == original; }, "Levels controls Cancel lost source");
                begin(); pump([&] { return pixels() == preview; }, "Levels controls repeated preview differs");
                click(button("OK")); pump([&] { return !panel() && !window.sessionState().value("busy").toBool(); }, "Levels controls commit did not settle");
                check(pixels() == preview && window.sessionState().value("undoName").toString() == "Levels", "Levels controls commit differs from preview");
                QApplication::setActiveWindow(&window); key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(pixels() == original && window.sessionState().value("layers") == before.value("layers"), "Levels controls Undo lost source/records");
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                check(pixels() == preview && window.sessionState().value("activeLayerID") == before.value("activeLayerID"), "Levels controls Redo lost result/target");
                qInfo("Qt Levels controls OK (%s, visible controls/all channels, independent histogram/sample and pixel equations, transparent sample refusal, Cancel/OK, exact Undo/Redo)", qPrintable(choice));
            }
            if (app.arguments().contains("--levels-handles-probe"))
            for (int selected = 0; selected < 4; ++selected)
                for (const QString &name : QStringList{"Input black", "Gamma", "Input white", "Output black", "Output white"}) {
                    check(window.importImage(path), "Levels handle fixture import failed");
                    command({{"action", "setShowsTransformControls"}, {"enabled", false}});
                    const QImage original = pixels(); const auto before = window.sessionState();
                    const bool output = name.startsWith("Output");
                    const QString spaceName = output ? "levelsOutput" : "levelsInput";
                    double setting = 0;
                    const auto begin = [&] {
                        command({{"action", "beginLevels"}});
                        pump([&] { return panel(); }, "Levels handle panel missing"); channel(selected);
                        QWidget *handle = nullptr, *space = nullptr;
                        for (auto *candidate : panel()->findChildren<QWidget *>())
                            if (candidate->isVisible() && candidate->accessibleName() == name
                                && candidate->property("swiftuiGestureCoordinateSpace").toString() == spaceName) handle = candidate;
                        check(handle, "visible Levels triangle handle missing");
                        for (auto *candidate = handle; candidate; candidate = candidate->parentWidget())
                            if (candidate->property("swiftuiCoordinateSpaces").toStringList().contains(spaceName)) { space = candidate; break; }
                        check(space && space->width() > 100, "Levels handle named coordinate space missing");
                        const double requested = name == "Input black" ? 60 : name == "Input white" ? 200
                            : name == "Output black" ? 40 : name == "Output white" ? 180 : 255 * 0.3;
                        const int x = qRound(space->width() * requested / 255);
                        const double value = x * 255.0 / space->width();
                        setting = name == "Gamma" ? std::log(value / 255) / std::log(0.5) : std::round(value);
                        const QPoint destination = space->mapToGlobal(QPoint(x, 9));
                        QApplication::setActiveWindow(panel());
                        mouse(handle, QEvent::MouseButtonPress, handle->rect().center(), Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
                        mouse(panel(), QEvent::MouseMove, panel()->mapFromGlobal(destination), Qt::NoButton, Qt::LeftButton, Qt::NoModifier);
                        mouse(panel(), QEvent::MouseButtonRelease, panel()->mapFromGlobal(destination), Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
                        pump([&] { return std::abs(field(name) - setting) <= (name == "Gamma" ? 0.02 : 0.5); }, "Levels triangle did not update its numeric value");
                        pump([&] { return pixels() != original; }, "Levels handle did not update preview");
                    };
                    const auto matchesExpected = [&](const QImage &rendered) {
                        for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                            const auto actual = rendered.pixelColor(x, y), source = original.pixelColor(x, y);
                            if (actual.alpha() != source.alpha()) return false;
                            if (!source.alpha()) continue;
                            for (int c = 1; c < 4; ++c) {
                                const int value = c == 1 ? source.red() : c == 2 ? source.green() : source.blue();
                                double expected = value;
                                if (selected == 0 || selected == c) {
                                    const double black = name == "Input black" ? setting : 0, white = name == "Input white" ? setting : 255;
                                    const double gamma = name == "Gamma" ? setting : 1;
                                    const double outBlack = name == "Output black" ? setting : 0, outWhite = name == "Output white" ? setting : 255;
                                    expected = outBlack + std::pow(std::clamp((value - black) / (white - black), 0.0, 1.0), 1 / gamma) * (outWhite - outBlack);
                                }
                                const int component = c == 1 ? actual.red() : c == 2 ? actual.green() : actual.blue();
                                if (std::abs(component - expected) > 2) return false;
                            }
                        }
                        return true;
                    };
                    begin();
                    pump([&] { return matchesExpected(pixels()); }, "Levels handle pixels did not reach the independent range equation");
                    const QImage preview = pixels();
                    check(matchesExpected(preview), "Levels handle captured preview differs from independent range equation");
                    for (const char *key : {"layers", "activeLayerID", "undoName", "redoName", "modified"})
                        check(window.sessionState().value(key) == before.value(key), "Levels handle preview changed source/history");
                    const auto toggle = [&]() -> QCheckBox * {
                        for (auto *candidate : panel()->findChildren<QCheckBox *>())
                            if (candidate->isVisible() && candidate->text() == "Preview") return candidate;
                        throw std::runtime_error("Levels handle Preview toggle missing");
                    };
                    click(toggle()); pump([&] { return pixels() == original; }, "Levels handle Preview Off lost source");
                    click(toggle()); pump([&] { return pixels() == preview; }, "Levels handle Preview On lost result");
                    click(button("Cancel")); pump([&] { return !panel() && pixels() == original; }, "Levels handle Cancel lost source");
                    begin(); pump([&] { return pixels() == preview; }, "Levels handle repeated preview differs");
                    click(button("OK")); pump([&] { return !panel() && !window.sessionState().value("busy").toBool(); }, "Levels handle commit did not settle");
                    check(pixels() == preview && window.sessionState().value("undoName").toString() == "Levels", "Levels handle commit differs from preview");
                    QApplication::setActiveWindow(&window); key(canvas, Qt::Key_Z, Qt::ControlModifier);
                    check(pixels() == original && window.sessionState().value("layers") == before.value("layers"), "Levels handle Undo lost source/records");
                    key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                    check(pixels() == preview && window.sessionState().value("activeLayerID") == before.value("activeLayerID"), "Levels handle Redo lost result/target");
                    qInfo("Qt Levels handles OK (channel=%d, %s, actual triangle drag/named space, independent all-pixel equation, Preview Off/On, Cancel/OK and exact Undo/Redo)", selected, qPrintable(name));
                }
            return 0;
        }

        // Exercise the upstream AppKit picker through its visible Qt menu.
        {
            QImage base(64, 64, QImage::Format_RGBA8888);
            QImage top(64, 64, QImage::Format_RGBA8888); top.fill(Qt::transparent);
            for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                base.setPixelColor(x, y, QColor(32 + x * 3, 48 + y * 2, 176 - x * 2));
                if (x >= 8 && x < 56 && y >= 8 && y < 56)
                    top.setPixelColor(x, y, QColor(196 - y * 2, 24 + x * 3, 32 + y * 3, y < 32 ? 128 : 255));
            }
            const QString basePath = temporary.filePath("blend-base.png"), topPath = temporary.filePath("blend-top.png");
            check(base.save(basePath) && top.save(topPath) && window.importImage(basePath), "blend picker fixture import failed");
            command({{"action", "importFiles"}, {"paths", QJsonArray{topPath}}});
            command({{"action", "setShowsTransformControls"}, {"enabled", false}});
            const auto picker = [&]() -> QComboBox * {
                for (auto *candidate : window.findChildren<QComboBox *>())
                    if (candidate->isVisible() && candidate->accessibleName() == "Blend mode") return candidate;
                throw std::runtime_error("visible upstream blend picker missing");
            };
            QStringList modes;
            for (int index = 0; index < picker()->count(); ++index)
                if (!picker()->itemText(index).isEmpty()) modes << picker()->itemText(index);
            check(modes.size() == 24, "blend picker does not contain all 24 upstream modes");
            const auto target = window.sessionState().value("activeLayerID");
            const auto selectedMode = [&]() -> QString {
                for (const auto &entry : window.sessionState().value("layers").toArray())
                    if (entry.toObject().value("id") == target) return entry.toObject().value("blendMode").toString();
                throw std::runtime_error("blend picker target disappeared");
            };
            const QImage normal = pixels();
            const auto highlight = [&](const QString &mode) {
                QComboBox *combo = picker();
                combo->setFocus();
                QTest::sendKeyEvent(QTest::Click, window.windowHandle(), Qt::Key_Down, QString(), Qt::AltModifier);
                pump([&] { return picker()->view()->isVisible(); }, "blend popup did not open");
                combo = picker();
                const auto index = combo->model()->index(combo->findText(mode), combo->modelColumn(), combo->rootModelIndex());
                combo->view()->scrollTo(index);
                const QPointF position = combo->view()->visualRect(index).center();
                mouse(combo->view()->viewport(), QEvent::MouseMove, position, Qt::NoButton, Qt::NoButton, Qt::NoModifier);
            };
            const auto popupKey = [&](int code) {
                auto *popup = picker()->view()->window();
                check(popup->isVisible(), "blend popup closed before its key");
                QTest::sendKeyEvent(QTest::Click, popup->windowHandle(), static_cast<Qt::Key>(code), QString(), Qt::NoModifier);
                QApplication::processEvents();
            };
            for (const QString &mode : modes) {
                QImage reference = normal;
                if (mode != "Normal") {
                    command({{"action", "setBlendMode"}, {"kind", mode}});
                    reference = pixels();
                    key(canvas, Qt::Key_Z, Qt::ControlModifier);
                    check(selectedMode() == "Normal" && pixels() == normal, "blend reference Undo changed its source");
                }
                const auto before = window.sessionState();
                highlight(mode);
                pump([&] { return pixels() == reference; }, "blend menu highlight differs from the session reference");
                for (const char *field : {"layers", "activeLayerID", "modified", "undoName", "redoName", "canUndo", "canRedo"})
                    check(window.sessionState().value(field) == before.value(field), "blend highlight edited document records/history");
                popupKey(Qt::Key_Escape);
                pump([&] { return !picker()->view()->isVisible() && pixels() == normal; }, "blend menu Cancel did not restore exact source");
                check(window.sessionState().value("layers") == before.value("layers"), "blend menu Cancel changed records");
                highlight(mode); popupKey(Qt::Key_Return);
                pump([&] { return !picker()->view()->isVisible() && selectedMode() == mode && pixels() == reference; },
                     "blend menu choice did not commit its preview");
                if (mode != "Normal") {
                    const auto committed = window.sessionState();
                    check(committed.value("undoName").toString() == "Layer Blend Mode", "blend choice has the wrong history action");
                    key(canvas, Qt::Key_Z, Qt::ControlModifier);
                    check(pixels() == normal && window.sessionState().value("layers") == before.value("layers"), "blend choice Undo lost exact pixels/records");
                    key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                    check(pixels() == reference && window.sessionState().value("layers") == committed.value("layers"), "blend choice Redo lost exact pixels/records");
                    key(canvas, Qt::Key_Z, Qt::ControlModifier);
                }
                qInfo("Qt all blend modes OK (%s, visible menu highlight/Cancel/Return, exact session-reference pixels, source/history isolation and Undo/Redo)", qPrintable(mode));
            }
        }
        if (app.arguments().contains("--blend-mode-probe")) return 0;


        {
            QImage source(64, 64, QImage::Format_RGBA8888); source.fill(Qt::transparent);
            for (int y = 8; y < 24; ++y) for (int x = 8; x < 24; ++x)
                source.setPixelColor(x, y, QColor(64, 128, 192));
            const QString path = temporary.filePath("picker-sample.png");
            check(source.save(path) && window.importImage(path), "Color Picker fixture import failed");
            command({{"action", "setShowsTransformControls"}, {"enabled", false}});
            tool("Brush", "brush");
            const auto panel = [&]() -> QDialog * {
                auto *dialog = window.findChild<QDialog *>("floatingPanel.ColorPickerSheet");
                return dialog && dialog->isVisible() ? dialog : nullptr;
            };
            const auto field = [&](const QString &name) -> QLineEdit * {
                if (auto *dialog = panel()) for (auto *candidate : dialog->findChildren<QLineEdit *>())
                    if (candidate->isVisible() && candidate->placeholderText() == name) return candidate;
                qWarning() << "Color Picker missing field" << name << "panel visible=" << bool(panel());
                check(false, "visible Color Picker field missing"); return nullptr;
            };
            const auto enter = [&](const QString &name, const QString &value) {
                auto *target = field(name); QApplication::setActiveWindow(panel()); target->setFocus(); target->selectAll(); target->insert(value);
                pump([&] { return panel() && field(name)->hasFocus() && field(name)->text() == value; },
                     "Color Picker refresh lost the edited text or focus");
                check(field(name)->cursorPosition() == value.size(), "Color Picker refresh moved the editing cursor");
                if (name != "Hex") {
                    const QColor current(qBound(0, field("R")->text().toInt(), 255), qBound(0, field("G")->text().toInt(), 255),
                                         qBound(0, field("B")->text().toInt(), 255));
                    const QString hex = current.name(QColor::HexRgb).mid(1).toUpper();
                    pump([&] { return field("Hex")->text() == hex; }, "Color Picker Hex did not follow live RGB editing");
                    check(field(name)->hasFocus() && field(name)->text() == value && field(name)->cursorPosition() == value.size(),
                          "live Color Picker update replaced the active text or cursor");
                }
                bool submitted = false;
                const auto submittedConnection = QObject::connect(field(name), &QLineEdit::returnPressed, &window, [&] { submitted = true; });
                QTest::sendKeyEvent(QTest::Click, panel()->windowHandle(), name == "Hex" ? Qt::Key_Return : Qt::Key_Tab, QString(), Qt::NoModifier);
                QObject::disconnect(submittedConnection);
                if (name == "Hex" && !submitted) {
                    qWarning() << "Color Picker Return not delivered" << "modal=" << QApplication::activeModalWidget()
                               << "parent=" << panel()->parentWidget() << "focus=" << QApplication::focusWidget();
                    check(false, "Color Picker Hex Return was blocked");
                }
                QApplication::processEvents();
            };
            const auto rgb = [&](int red, int green, int blue) {
                try {
                    pump([&] { return panel() && std::abs(field("R")->text().toInt() - red) <= 1
                        && std::abs(field("G")->text().toInt() - green) <= 1
                        && std::abs(field("B")->text().toInt() - blue) <= 1; }, "Color Picker draft RGB did not update");
                } catch (...) {
                    if (panel()) qWarning() << "Color Picker actual RGB/Hex" << field("R")->text() << field("G")->text()
                        << field("B")->text() << field("Hex")->text() << "expected" << red << green << blue;
                    throw;
                }
            };
            const auto finish = [&](const QString &name) {
                QPushButton *button = nullptr;
                if (auto *dialog = panel()) for (auto *candidate : dialog->findChildren<QPushButton *>())
                    if (candidate->isVisible() && candidate->text() == name) button = candidate;
                check(button, "visible Color Picker action missing"); click(button);
                pump([&] { return !panel(); }, "Color Picker did not close");
                QApplication::setActiveWindow(&window); QApplication::processEvents();
            };
            const auto open = [&](bool background) {
                QPushButton *button = nullptr;
                auto *rail = window.findChild<QWidget *>("swiftUIToolRailContainer");
                check(rail, "Color Picker tool rail missing");
                for (auto *candidate : rail->findChildren<QPushButton *>())
                    if (candidate->isVisible() && candidate->accessibleName() == (background ? "Background color" : "Foreground color")) button = candidate;
                check(button, "visible palette swatch missing"); click(button);
                pump([&] { return panel(); }, "palette swatch did not open Color Picker");
            };
            const auto gesture = [&](const QString &name, QPointF point) {
                const auto surface = [&]() -> QWidget * {
                    if (auto *dialog = panel()) for (auto *candidate : dialog->findChildren<QWidget *>())
                        if (candidate->isVisible() && candidate->accessibleName() == name) return candidate;
                    return nullptr;
                };
                QWidget *target = surface();
                check(target && target->height() == 256, "Color Picker gesture surface missing or wrong size");
                const QPointF global = target->mapToGlobal(point.toPoint());
                mouse(target, QEvent::MouseButtonPress, point, Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
                target = surface(); check(target, "Color Picker gesture surface lost after refresh");
                mouse(target, QEvent::MouseButtonRelease, target->mapFromGlobal(global.toPoint()), Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
            };
            if (!app.arguments().contains("--rgb-tiff-probe")) {
            for (bool background : {false, true}) {
                command({{"action", "setPaletteColor"}, {"kind", "foreground"},
                    {"parameters", QJsonObject{{"red", 0.05}, {"green", 0.1}, {"blue", 0.15}}}});
                command({{"action", "setPaletteColor"}, {"kind", "background"},
                    {"parameters", QJsonObject{{"red", 0.7}, {"green", 0.8}, {"blue", 0.9}}}});
                const auto before = window.sessionState(); const QImage original = pixels();
                open(background);
                enter("R", "300"); enter("G", "-20"); enter("B", "128"); rgb(255, 0, 128);
                enter("Hex", "123456"); rgb(18, 52, 86);
                enter("Hex", "#0f0"); rgb(0, 255, 0);
                enter("Hex", "GGGGGG"); rgb(0, 255, 0);
                check(field("Hex")->text() == "00FF00", "invalid Color Picker hex was not normalized to the current color");
                gesture("Hue", QPointF(17, 128));
                gesture("Saturation and brightness", QPointF(64, 192)); rgb(48, 64, 64);
                QWidget *preview = nullptr;
                for (auto *candidate : panel()->findChildren<QWidget *>())
                    if (candidate->isVisible() && candidate->accessibleName() == "New color") preview = candidate;
                check(preview, "Color Picker preview missing");
                const auto shown = preview->grab().toImage().pixelColor(preview->width() / 2, preview->height() / 2);
                check(std::abs(shown.red() - 48) <= 2 && std::abs(shown.green() - 64) <= 2 && std::abs(shown.blue() - 64) <= 2,
                      "Color Picker visible preview did not follow its draft RGB");
                check(panel()->grab().save(background ? "/tmp/compositor-color-picker-background.png" : "/tmp/compositor-color-picker-foreground.png"),
                      "Color Picker screenshot save failed");
                check(window.sessionState().value("foregroundColor") == before.value("foregroundColor")
                          && window.sessionState().value("backgroundColor") == before.value("backgroundColor"),
                      "Color Picker draft edited the live palette before OK");
                finish("Cancel");
                check(window.sessionState().value("foregroundColor") == before.value("foregroundColor")
                          && window.sessionState().value("backgroundColor") == before.value("backgroundColor"),
                      "Color Picker Cancel changed the palette");
                open(background);
                canvas->setFocus();
                mouse(canvas, QEvent::MouseButtonPress, at(16.5, 16.5), Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
                mouse(canvas, QEvent::MouseButtonRelease, at(16.5, 16.5), Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
                rgb(64, 128, 192);
                mouse(canvas, QEvent::MouseButtonPress, at(32.5, 32.5), Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
                mouse(canvas, QEvent::MouseButtonRelease, at(32.5, 32.5), Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
                rgb(64, 128, 192); finish("OK");
                const auto after = window.sessionState();
                const auto chosen = after.value(background ? "backgroundColor" : "foregroundColor").toArray();
                check(chosen.size() == 3 && std::abs(chosen[0].toDouble() - 64.0 / 255) <= 1.0 / 255
                    && std::abs(chosen[1].toDouble() - 128.0 / 255) <= 1.0 / 255
                    && std::abs(chosen[2].toDouble() - 192.0 / 255) <= 1.0 / 255,
                    "Color Picker OK did not commit to the selected palette target");
                check(after.value(background ? "foregroundColor" : "backgroundColor") == before.value(background ? "foregroundColor" : "backgroundColor"),
                      "Color Picker changed the other palette target");
                check(pixels() == original, "Color Picker edited document pixels");
                for (const char *name : {"layers", "activeLayerID", "modified", "canUndo", "canRedo", "undoName", "redoName"})
                    check(after.value(name) == before.value(name), "Color Picker changed document records or history");
                open(background);
                const QPoint position = panel()->pos() + QPoint(24, 18); panel()->move(position);
                enter("Hex", "ABCDEF"); rgb(171, 205, 239);
                panel()->close(); pump([&] { return !panel(); }, "Color Picker title-bar close did not cancel");
                check(window.sessionState().value("foregroundColor") == after.value("foregroundColor")
                          && window.sessionState().value("backgroundColor") == after.value("backgroundColor"),
                      "Color Picker title-bar close committed the draft");
                open(background); check(panel()->pos() == position, "Color Picker reopened at a different position"); finish("Cancel");
                check(pixels() == original, "Color Picker title-close/reopen changed document pixels");
                for (const char *name : {"layers", "activeLayerID", "modified", "canUndo", "canRedo", "undoName", "redoName"})
                    check(window.sessionState().value(name) == before.value(name), "Color Picker title-close/reopen changed document records or history");
                qInfo("Qt Color Picker OK (%s, visible swatch/RGB clamp/live Hex/focus/cursor/Hue/SB/Cancel/OK, canvas sampling, transparent refusal, title-close/reopen position, palette isolation, unchanged document/history)",
                    background ? "background" : "foreground");
            }
            for (bool palette : {false, true}) {
                command({{"action", "new"}, {"width", 64}, {"height", 64}, {"emptyLayer", true}});
                command({{"action", "setPaletteColor"}, {"kind", "foreground"},
                    {"parameters", QJsonObject{{"red", 1}, {"green", 0}, {"blue", 0}}}});
                tool("Type", "type"); drag(at(8, 8), at(8, 8));
                auto *editor = window.findChild<QPlainTextEdit *>("canvas.textEditor");
                check(editor && editor->isVisible(), "text Color Picker fixture did not open the inline editor");
                QApplication::setActiveWindow(&window); editor->setFocus(); editor->insertPlainText("ABCD"); QApplication::processEvents();
                QTextCursor selection = editor->textCursor(); selection.setPosition(1); selection.setPosition(3, QTextCursor::KeepAnchor);
                editor->setTextCursor(selection); QApplication::processEvents();
                const auto draft = [&] { return window.sessionState().value("textDraft").toObject(); };
                pump([&] { return draft().value("content").toString() == "ABCD" && draft().value("selectionLocation").toInt() == 1
                    && draft().value("selectionLength").toInt() == 2; }, "text Color Picker fixture did not retain its selected letters");
                const auto colorAt = [&](int location) {
                    const auto state = draft(); const auto base = state.value("color").toArray();
                    check(base.size() == 3, "text Color Picker fixture lacks a base RGB color");
                    QColor result = QColor::fromRgbF(base[0].toDouble(), base[1].toDouble(), base[2].toDouble());
                    for (const auto &value : state.value("colorRuns").toArray()) {
                        const auto run = value.toObject();
                        if (location >= run.value("location").toInt() && location < run.value("location").toInt() + run.value("length").toInt())
                            result = QColor::fromRgbF(run.value("red").toDouble(), run.value("green").toDouble(), run.value("blue").toDouble());
                    }
                    return result;
                };
                const auto before = window.sessionState(); const auto beforeDraft = draft();
                const auto firstColor = colorAt(0), lastColor = colorAt(3);
                const int history = editor->document()->availableUndoSteps();
                const auto openText = [&] {
                    if (palette) open(false);
                    else {
                        QPushButton *button = nullptr;
                        for (auto *candidate : window.findChildren<QPushButton *>())
                            if (candidate->isVisible() && candidate->accessibleName() == "Text color") button = candidate;
                        check(button, "visible Type color swatch missing"); click(button);
                        pump([&] { return panel(); }, "Type swatch did not open Color Picker");
                    }
                };
                const auto greenPreview = [&] {
                    for (const auto &span : editor->extraSelections())
                        if (span.cursor.selectionStart() == 1 && span.cursor.selectionEnd() == 3
                            && span.format.foreground().color() == QColor(Qt::green)) return true;
                    return false;
                };
                const auto preview = [&] {
                    openText(); enter("Hex", "00FF00"); rgb(0, 255, 0);
                    pump(greenPreview, "visible Color Picker did not preview the selected text in Qt");
                    check(colorAt(1) == QColor(Qt::green) && colorAt(2) == QColor(Qt::green)
                              && colorAt(0) == firstColor && colorAt(3) == lastColor,
                          "text Color Picker changed unselected letters or failed to preview the selection");
                    check(editor->document()->availableUndoSteps() == history, "text Color Picker preview added a local Undo step");
                    check(window.sessionState().value("foregroundColor") == before.value("foregroundColor")
                              && window.sessionState().value("backgroundColor") == before.value("backgroundColor"),
                          "text Color Picker preview changed the live palette");
                };
                preview(); finish("Cancel");
                pump([&] { return !greenPreview(); }, "text Color Picker Cancel retained the preview");
                check(draft().value("colorRuns") == beforeDraft.value("colorRuns")
                          && draft().value("color") == beforeDraft.value("color")
                          && editor->document()->availableUndoSteps() == history,
                      "text Color Picker Cancel did not restore exact styles and local history");
                preview(); finish("OK");
                pump([&] { return editor->document()->availableUndoSteps() > history; }, "text Color Picker OK did not record local Undo");
                const auto committed = draft().value("colorRuns");
                check(colorAt(1) == QColor(Qt::green) && colorAt(2) == QColor(Qt::green)
                          && colorAt(0) == firstColor && colorAt(3) == lastColor, "text Color Picker OK lost selection isolation");
                const auto foreground = window.sessionState().value("foregroundColor").toArray();
                check(foreground == QJsonArray{0, 1, 0}
                          && window.sessionState().value("backgroundColor") == before.value("backgroundColor"),
                      "text Color Picker OK did not update only the foreground palette");
                editor->undo(); QApplication::processEvents();
                check(draft().value("colorRuns") == beforeDraft.value("colorRuns") && draft().value("color") == beforeDraft.value("color"),
                      "text Color Picker local Undo did not restore exact colors");
                editor->redo(); QApplication::processEvents();
                check(draft().value("colorRuns") == committed && draft().value("content").toString() == "ABCD",
                      "text Color Picker local Redo did not restore exact committed runs/content");
                for (const char *name : {"layers", "activeLayerID", "modified", "canUndo", "canRedo", "undoName", "redoName"})
                    check(window.sessionState().value(name) == before.value(name), "text Color Picker changed document records or global history");
                command({{"action", "textCancel"}});
                qInfo("Qt text Color Picker OK (%s, visible swatch/Hex, selected-letter live preview, unselected isolation, Cancel/OK, local Undo/Redo, foreground policy, unchanged document history)",
                    palette ? "foreground palette" : "Type color swatch");
            }
            for (const auto &effect : QList<QPair<QString, QString>>{
                    {"Stroke", "stroke"}, {"Drop Shadow", "shadow"}, {"Color Overlay", "colorOverlay"},
                    {"Inner Shadow", "innerShadow"}, {"Outer Glow", "outerGlow"}, {"Inner Glow", "innerGlow"}}) {
                check(window.importImage(path), "effect Color Picker fixture import failed");
                command({{"action", "setShowsTransformControls"}, {"enabled", false}});
                command({{"action", "setPaletteColor"}, {"kind", "foreground"},
                    {"parameters", QJsonObject{{"red", 0.8}, {"green", 0.1}, {"blue", 0.2}}}});
                command({{"action", "setPaletteColor"}, {"kind", "background"},
                    {"parameters", QJsonObject{{"red", 0.3}, {"green", 0.4}, {"blue", 0.6}}}});
                QPushButton *effectsMenu = nullptr;
                for (auto *button : window.findChildren<QPushButton *>())
                    if (button->isVisible() && (button->objectName() == "layerEffects" || button->accessibleName() == "Layer effects")) effectsMenu = button;
                if (!effectsMenu || !effectsMenu->isEnabled() || !effectsMenu->menu())
                    qWarning() << "effect menu diagnostic" << effect.first << "found=" << bool(effectsMenu)
                               << "enabled=" << (effectsMenu && effectsMenu->isEnabled()) << "layers=" << window.sessionState().value("layers");
                check(effectsMenu && effectsMenu->isVisible() && effectsMenu->isEnabled() && effectsMenu->menu(),
                      "visible layer effects menu missing");
                QMenu *menu = effectsMenu->menu(); menu->popup(effectsMenu->mapToGlobal(QPoint(0, effectsMenu->height())));
                QApplication::processEvents(); QAction *chosen = nullptr;
                for (auto *action : menu->actions()) if (action->text() == effect.first + QString::fromUtf8("…")) chosen = action;
                check(menu->isVisible() && chosen && chosen->isEnabled(), "visible effect creation action missing");
                chosen->trigger(); menu->hide(); QApplication::processEvents();
                const auto effectsPanel = [&]() -> QDialog * {
                    auto *dialog = window.findChild<QDialog *>("floatingPanel.EffectsSheet");
                    return dialog && dialog->isVisible() ? dialog : nullptr;
                };
                pump([&] { return effectsPanel(); }, "effect menu did not open its editor");
                const auto before = window.sessionState(); const QImage original = pixels();
                const auto openEffect = [&] {
                    QPushButton *button = nullptr;
                    if (auto *dialog = effectsPanel()) for (auto *candidate : dialog->findChildren<QPushButton *>())
                        if (candidate->isVisible() && candidate->accessibleName() == effect.first + " color") button = candidate;
                    check(button, "visible effect color swatch missing"); QApplication::setActiveWindow(effectsPanel()); click(button);
                    pump([&] { return panel(); }, "effect swatch did not open Color Picker");
                };
                openEffect(); enter("Hex", "00FF00"); rgb(0, 255, 0);
                pump([&] { return pixels() != original; }, "effect Color Picker did not preview on the canvas");
                const QImage preview = pixels();
                for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x)
                    check(preview.pixelColor(x, y).alpha() == original.pixelColor(x, y).alpha(), "effect color preview changed alpha");
                if (effect.second == "colorOverlay") check(preview.pixelColor(16, 16) == QColor(Qt::green),
                    "Color Overlay picker did not apply the chosen RGB to the source interior");
                finish("Cancel");
                pump([&] { return pixels() == original; }, "effect Color Picker Cancel did not restore exact pixels");
                openEffect(); enter("Hex", "00FF00"); rgb(0, 255, 0);
                pump([&] { return pixels() == preview; }, "effect Color Picker repeated preview differs"); finish("OK");
                check(pixels() == preview && window.sessionState().value("foregroundColor") == before.value("foregroundColor")
                          && window.sessionState().value("backgroundColor") == before.value("backgroundColor"),
                      "effect Color Picker OK changed the palette or lost its preview");
                QPushButton *ok = nullptr;
                for (auto *button : effectsPanel()->findChildren<QPushButton *>())
                    if (button->isVisible() && button->text() == "OK") ok = button;
                check(ok, "effect editor OK missing"); click(ok); pump([&] { return !effectsPanel(); }, "effect editor did not close");
                QApplication::setActiveWindow(&window); QApplication::processEvents();
                check(window.sessionState().value("undoName").toString() == "Edit " + effect.first,
                      "effect Color Picker did not retain upstream's effect history policy");
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(pixels() == original && window.sessionState().value("layers") == before.value("layers")
                          && window.sessionState().value("activeLayerID") == before.value("activeLayerID"),
                      "effect Color Picker Undo did not restore exact pixels/records/target");
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                check(pixels() == preview && window.sessionState().value("layers") == before.value("layers")
                          && window.sessionState().value("activeLayerID") == before.value("activeLayerID"),
                      "effect Color Picker Redo did not restore exact pixels/records/target");
                const QString project = temporary.filePath("picker-effect-" + effect.second + ".comp");
                check(writeProjectPackage(project), "effect Color Picker project save failed");
                QFile manifest(QDir(project).filePath("manifest.json")); check(manifest.open(QIODevice::ReadOnly), "effect Color Picker manifest missing");
                const auto layers = QJsonDocument::fromJson(manifest.readAll()).object().value("layers").toArray();
                check(layers.size() == 1, "effect Color Picker save changed the layer count");
                const auto saved = layers.first().toObject().value("effects").toObject().value(effect.second).toObject();
                check(saved.value("red").toDouble(-1) == 0 && saved.value("green").toDouble(-1) == 1
                          && saved.value("blue").toDouble(-1) == 0, "effect Color Picker saved the wrong effect color");
                qInfo("Qt effect Color Picker OK (%s, visible fx menu/swatch/Hex, live RGB with exact alpha, Cancel/OK, palette isolation, exact Undo/Redo, saved effect RGB)",
                    qPrintable(effect.first));
            }
            QImage ramp(64, 64, QImage::Format_RGBA8888); ramp.fill(Qt::transparent);
            for (int y = 8; y < 56; ++y) for (int x = 8; x < 56; ++x) {
                const int gray = qRound((x - 8) * 255.0 / 47); ramp.setPixelColor(x, y, QColor(gray, gray, gray));
            }
            const QString rampPath = temporary.filePath("picker-filter-ramp.png");
            check(ramp.save(rampPath), "filter Color Picker fixture save failed");
            for (const auto &target : QList<QPair<QString, QString>>{
                    {"Gradient Map", "Shadows color"}, {"Gradient Map", "Highlights color"},
                    {"Vignette", "Choose the vignette color"}, {"Dither", "Choose the dark color"},
                    {"Dither", "Choose the light color"}, {"Scanlines", "Choose the screen's color"},
                    {"Scanlines", "Choose the lines' color"}}) {
                check(window.importImage(rampPath), "filter Color Picker fixture import failed");
                command({{"action", "setShowsTransformControls"}, {"enabled", false}});
                const auto sourceState = window.sessionState(); const QImage sourcePixels = pixels();
                command({{"action", "openFilter"}, {"kind", target.first}});
                const auto filterPanel = [&]() -> QDialog * {
                    auto *dialog = window.findChild<QDialog *>("floatingPanel.FilterSheet");
                    return dialog && dialog->isVisible() ? dialog : nullptr;
                };
                pump([&] { return filterPanel() && !window.sessionState().value("filterPreviewRendering").toBool(); },
                     "filter Color Picker owner did not finish its initial preview");
                if (target.first == "Dither" || target.first == "Scanlines") {
                    const auto colors = [&]() -> QComboBox * {
                        if (auto *dialog = filterPanel()) for (auto *combo : dialog->findChildren<QComboBox *>())
                            if (combo->isVisible() && combo->findText("Two Colors") >= 0) return combo;
                        check(false, "filter two-color mode control missing"); return nullptr;
                    };
                    QApplication::setActiveWindow(filterPanel()); colors()->setFocus();
                    QTest::sendKeyEvent(QTest::Click, filterPanel()->windowHandle(), Qt::Key_Home, QString(), Qt::NoModifier);
                    QApplication::processEvents(); colors()->setFocus();
                    QTest::sendKeyEvent(QTest::Click, filterPanel()->windowHandle(), Qt::Key_Down, QString(), Qt::NoModifier);
                    QApplication::processEvents();
                    pump([&] { return colors()->currentText() == "Two Colors" && !window.sessionState().value("filterPreviewRendering").toBool(); },
                         "filter two-color mode did not update");
                }
                const QImage baseline = pixels();
                const auto openFilterColor = [&] {
                    QPushButton *button = nullptr;
                    if (auto *dialog = filterPanel()) for (auto *candidate : dialog->findChildren<QPushButton *>())
                        if (candidate->isVisible() && (candidate->accessibleName() == target.second || candidate->toolTip() == target.second)) button = candidate;
                    check(button, "visible filter color swatch missing"); QApplication::setActiveWindow(filterPanel()); click(button);
                    pump([&] { return panel(); }, "filter swatch did not open Color Picker");
                };
                const auto chosenPreview = [&] {
                    openFilterColor(); enter("Hex", "00FF00"); rgb(0, 255, 0);
                    pump([&] { return !window.sessionState().value("filterPreviewRendering").toBool() && pixels() != baseline; },
                         "filter Color Picker did not update its canvas preview");
                    check(window.sessionState().value("layers") == sourceState.value("layers")
                              && window.sessionState().value("activeLayerID") == sourceState.value("activeLayerID")
                              && window.sessionState().value("undoName") == sourceState.value("undoName"),
                          "filter color preview edited source records, target or document history");
                    return pixels();
                };
                const QImage preview = chosenPreview();
                for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x)
                    check(preview.pixelColor(x, y).alpha() == baseline.pixelColor(x, y).alpha(), "filter color change altered alpha");
                finish("Cancel");
                pump([&] { return !window.sessionState().value("filterPreviewRendering").toBool() && pixels() == baseline; },
                     "filter Color Picker Cancel did not restore exact preview pixels");
                check(chosenPreview() == preview, "filter Color Picker repeated preview differs"); finish("OK");
                pump([&] { return !window.sessionState().value("filterPreviewRendering").toBool() && pixels() == preview; },
                     "filter Color Picker OK lost its preview");
                check(window.sessionState().value("foregroundColor") == sourceState.value("foregroundColor")
                          && window.sessionState().value("backgroundColor") == sourceState.value("backgroundColor"),
                      "filter Color Picker changed the palette");
                QPushButton *ok = nullptr;
                for (auto *button : filterPanel()->findChildren<QPushButton *>()) if (button->isVisible() && button->text() == "OK") ok = button;
                check(ok, "filter Color Picker owner OK missing"); click(ok);
                pump([&] { return !filterPanel() && !window.sessionState().value("busy").toBool(); }, "filter color did not commit");
                QApplication::setActiveWindow(&window); QApplication::processEvents();
                const bool committedMatches = pixels() == preview && window.sessionState().value("layers") == sourceState.value("layers");
                if (!committedMatches) {
                    qWarning("filter commit mismatch %s / %s: preview=%d source=%d baseline=%d geometry=%d", qPrintable(target.first), qPrintable(target.second),
                             pixels() == preview, pixels() == sourcePixels, pixels() == baseline,
                             window.sessionState().value("layers") == sourceState.value("layers"));
                    for (int sample = 0; sample < 3; ++sample) {
                        QThread::msleep(5); QApplication::processEvents();
                        qWarning("filter commit diagnostic sample %d: preview=%d geometry=%d busy=%d", sample,
                                 pixels() == preview, window.sessionState().value("layers") == sourceState.value("layers"), window.sessionState().value("busy").toBool());
                    }
                }
                check(committedMatches,
                      "filter color commit differs from preview or changed target geometry");
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(pixels() == sourcePixels && window.sessionState().value("layers") == sourceState.value("layers")
                          && window.sessionState().value("activeLayerID") == sourceState.value("activeLayerID"),
                      "filter color Undo did not restore exact source pixels/records/target");
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                check(pixels() == preview && window.sessionState().value("layers") == sourceState.value("layers"),
                      "filter color Redo did not restore exact committed pixels/records");
                qInfo("Qt filter Color Picker OK (%s / %s, visible swatch/Hex, live RGB/exact alpha, Cancel/OK, palette/source/history isolation, exact filter preview/commit and Undo/Redo)",
                    qPrintable(target.first), qPrintable(target.second));
            }
            // The generic dialog target must remain usable while its owning sheet is modal.
            check(window.importImage(rampPath), "Grid Color fixture import failed");
            command({{"action", "setShowsTransformControls"}, {"enabled", false}});
            const auto gridBefore = window.sessionState();
            const QImage gridPixels = pixels();
            QString gridFailure;
            bool gridInspected = false;
            QTimer gridInspector; gridInspector.setInterval(20);
            QObject::connect(&gridInspector, &QTimer::timeout, &window, [&] {
                auto *sheet = window.findChild<QDialog *>("swiftUISheet.GridSettingsSheet");
                if (!sheet || !sheet->isVisible()) return;
                gridInspector.stop(); gridInspected = true;
                try {
                    const auto preset = [&]() -> QComboBox * {
                        for (auto *candidate : sheet->findChildren<QComboBox *>())
                            if (candidate->isVisible() && candidate->findText("Custom") >= 0) return candidate;
                        check(false, "Grid Color preset control missing"); return nullptr;
                    };
                    const QString originalPreset = preset()->currentText();
                    const auto openGridColor = [&] {
                        QPushButton *swatch = nullptr;
                        for (auto *candidate : sheet->findChildren<QPushButton *>())
                            if (candidate->isVisible() && candidate->accessibleName() == "Grid Color") swatch = candidate;
                        QApplication::setActiveWindow(sheet); click(swatch);
                        pump([&] { return panel(); }, "Grid Color swatch did not open picker");
                        for (auto *label : panel()->findChildren<QLabel *>())
                            check(!label->isVisible() || label->text() != "Click the canvas to sample",
                                  "dialog Color Picker offered unavailable canvas sampling");
                    };
                    openGridColor(); enter("Hex", "00FF00"); rgb(0, 255, 0);
                    pump([&] { return preset()->currentText() == "Custom"; }, "Grid Color did not update its preset live");
                    finish("Cancel"); QApplication::setActiveWindow(sheet);
                    pump([&] { return preset()->currentText() == originalPreset; }, "Grid Color Cancel did not restore original preset");
                    openGridColor(); enter("Hex", "00FF00"); rgb(0, 255, 0);
                    finish("OK"); QApplication::setActiveWindow(sheet);
                    check(preset()->currentText() == "Custom", "Grid Color OK lost its custom preset");
                    QPushButton *cancel = nullptr;
                    for (auto *candidate : sheet->findChildren<QPushButton *>())
                        if (candidate->isVisible() && candidate->text() == "Cancel") cancel = candidate;
                    click(cancel);
                } catch (const std::exception &error) {
                    gridFailure = QString::fromUtf8(error.what());
                    if (auto *picker = panel()) picker->close();
                    sheet->reject();
                }
            });
            gridInspector.start(); command({{"action", "gridSettingsSheet"}}); gridInspector.stop();
            check(gridInspected && gridFailure.isEmpty(), gridFailure.isEmpty() ? "Grid Settings modal was not inspected" : qPrintable(gridFailure));
            QApplication::setActiveWindow(&window); QApplication::processEvents();
            for (const char *name : {"layers", "activeLayerID", "modified", "undoName", "redoName", "foreground", "background"})
                check(window.sessionState().value(name) == gridBefore.value(name), "Grid Color changed document history or palette");
            check(pixels() == gridPixels, "Grid Color changed document pixels");
            qInfo("Qt dialog Color Picker OK (modal Grid Color, Hex/focus, live custom preset, Cancel/OK, outer Cancel, document/history/palette isolation)");
            for (const QString &target : {QString("Extension Color"), QString("Export Background"), QString("PDF Export Background"), QString("CMYK TIFF Export Background")}) for (int qualityPercent : {0, 100, 85, 10}) {
                const bool resizing = target == "Extension Color";
                const bool pdf = target == "PDF Export Background", cmykTIFF = target == "CMYK TIFF Export Background";
                const QString swatchTitle = resizing ? target : "Export Background";
                if ((resizing || pdf || cmykTIFF) && qualityPercent != 0 && qualityPercent != 100) continue;
                const bool commit = qualityPercent != 0;
                check(window.importImage(rampPath), "dialog color fixture import failed");
                command({{"action", "setShowsTransformControls"}, {"enabled", false}});
                const auto before = window.sessionState(); const QImage sourcePixels = pixels();
                QString failure; bool inspected = false;
                QTimer inspector; inspector.setInterval(20);
                QObject::connect(&inspector, &QTimer::timeout, &window, [&] {
                    auto *sheet = window.findChild<QDialog *>(resizing ? "swiftUISheet.CanvasSizeSheet" : "swiftUISheet.ExportAsSheet");
                    if (!sheet || !sheet->isVisible()) return;
                    inspector.stop(); inspected = true;
                    try {
                        if (resizing) {
                            QComboBox *extension = nullptr;
                            for (auto *candidate : sheet->findChildren<QComboBox *>())
                                if (candidate->isVisible() && candidate->findText("Transparent") >= 0 && candidate->findText("Custom") >= 0) extension = candidate;
                            check(extension, "canvas extension mode control missing");
                            QApplication::setActiveWindow(sheet); extension->setFocus();
                            QTest::sendKeyEvent(QTest::Click, sheet->windowHandle(), Qt::Key_End, QString(), Qt::NoModifier);
                            QApplication::processEvents();
                            for (const QString &name : {QString("Width"), QString("Height")}) {
                                QLineEdit *dimension = nullptr;
                                for (auto *candidate : sheet->findChildren<QLineEdit *>())
                                    if (candidate->isVisible() && candidate->placeholderText() == name) dimension = candidate;
                                check(dimension, "canvas dimension control missing");
                                dimension->setFocus(); dimension->selectAll(); dimension->insert("72");
                                QTest::sendKeyEvent(QTest::Click, sheet->windowHandle(), Qt::Key_Tab, QString(), Qt::NoModifier);
                                QApplication::processEvents();
                            }
                        } else if (cmykTIFF) {
                            QPushButton *colorMenu = nullptr;
                            for (auto *candidate : sheet->findChildren<QPushButton *>())
                                if (candidate->isVisible() && candidate->text() == "RGB" && candidate->menu()) colorMenu = candidate;
                            check(colorMenu, "TIFF color mode menu missing");
                            auto *menu = colorMenu->menu(); QAction *cmyk = nullptr;
                            for (auto *candidate : menu->actions())
                                if (candidate->text().remove('&') == "CMYK") cmyk = candidate;
                            check(cmyk && cmyk->isEnabled(), "TIFF CMYK action missing or disabled");
                            menu->popup(colorMenu->mapToGlobal(colorMenu->rect().bottomLeft()));
                            cmyk->trigger(); menu->hide(); QApplication::processEvents();
                        } else if (!pdf) {
                            QSlider *quality = nullptr;
                            for (auto *candidate : sheet->findChildren<QSlider *>())
                                if (candidate->isVisible()) quality = candidate;
                            check(quality, "JPEG quality control missing");
                            const int requested = quality->minimum() + qRound((quality->maximum() - quality->minimum()) * (commit ? qualityPercent : 100) / 100.0);
                            quality->setValue(requested);
                            check(quality->value() == requested, "JPEG quality control refused requested value");
                            QApplication::processEvents();
                        }
                        const auto swatch = [&]() -> QPushButton * {
                            for (auto *candidate : sheet->findChildren<QPushButton *>())
                                if (candidate->isVisible() && candidate->accessibleName() == swatchTitle) return candidate;
                            return nullptr;
                        };
                        pump([&] { return swatch(); }, "dialog color swatch missing");
                        const auto shownColor = [&] {
                            auto *button = swatch(); check(button, "dialog color swatch disappeared");
                            const QImage icon = button->icon().pixmap(button->iconSize()).toImage();
                            check(!icon.isNull(), "dialog color swatch icon missing");
                            return icon.pixelColor(icon.width() / 2, icon.height() / 2);
                        };
                        const QColor original = shownColor();
                        const auto choose = [&] {
                            QApplication::setActiveWindow(sheet); click(swatch());
                            pump([&] { return panel(); }, "dialog swatch did not open picker");
                            check(panel()->parentWidget() == sheet, "dialog Color Picker has wrong modal owner");
                            enter("Hex", "00FF00"); rgb(0, 255, 0);
                            pump([&] { return shownColor() == QColor(Qt::green); }, "dialog Color Picker did not update visible swatch");
                        };
                        choose(); finish("Cancel"); QApplication::setActiveWindow(sheet);
                        pump([&] { return shownColor() == original; }, "dialog Color Picker Cancel did not restore swatch");
                        choose(); finish("OK"); QApplication::setActiveWindow(sheet);
                        check(shownColor() == QColor(Qt::green), "dialog Color Picker OK lost chosen swatch");
                        const QString answer = commit ? (resizing ? "OK" : "Export…") : "Cancel";
                        const auto answerButton = [&]() -> QPushButton * {
                            for (auto *candidate : sheet->findChildren<QPushButton *>())
                                if (candidate->isVisible() && candidate->text() == answer) return candidate;
                            return nullptr;
                        };
                        pump([&] { return answerButton() && answerButton()->isEnabled(); }, "dialog color outer action not ready");
                        click(answerButton());
                    } catch (const std::exception &error) {
                        failure = QString::fromUtf8(error.what());
                        if (auto *picker = panel()) picker->close();
                        sheet->reject();
                    }
                });
                inspector.start();
                const bool answered = window.sendCommand({{"action", resizing ? "canvasSizeSheet" : "exportAsSheet"}, {"kind", pdf ? "pdf" : cmykTIFF ? "tiff" : "jpeg"}});
                inspector.stop();
                check(inspected && failure.isEmpty(), failure.isEmpty() ? "dialog color sheet not inspected" : qPrintable(failure));
                check(answered == (resizing || commit), "dialog color outer action returned unexpected result");
                QApplication::setActiveWindow(&window); QApplication::processEvents();
                if (commit && resizing) {
                    check(window.sessionState().value("width").toInt() == 72 && window.sessionState().value("height").toInt() == 72,
                          "custom extension did not resize canvas");
                    const auto resizedPixels = [&] {
                        QByteArray bytes(72 * 72 * 4, Qt::Uninitialized);
                        check(compositor_session_render(window.sessionHandle(), reinterpret_cast<uint8_t *>(bytes.data()), bytes.size()) == bytes.size(), "custom extension pixels unavailable");
                        return QImage(reinterpret_cast<const uchar *>(bytes.constData()), 72, 72, 72 * 4, QImage::Format_RGBA8888_Premultiplied).copy().convertToFormat(QImage::Format_RGBA8888);
                    };
                    const QImage resized = resizedPixels();
                    for (int y = 0; y < 72; ++y) for (int x = 0; x < 72; ++x)
                        check(resized.pixelColor(x, y) == (QRect(4, 4, 64, 64).contains(x, y) ? sourcePixels.pixelColor(x - 4, y - 4) : QColor(Qt::green)),
                              "custom extension pixels differ from chosen color or centered source");
                    key(canvas, Qt::Key_Z, Qt::ControlModifier); check(pixels() == sourcePixels, "custom extension Undo did not restore exact source");
                    key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier); check(resizedPixels() == resized, "custom extension Redo changed pixels");
                    key(canvas, Qt::Key_Z, Qt::ControlModifier);
                } else if (commit && (pdf || cmykTIFF)) {
                    const QString artifactRoot = qEnvironmentVariable("COMPOSITOR_EXPORT_MATTE_ARTIFACTS", temporary.path());
                    check(QDir().mkpath(artifactRoot), "export matte artifact directory unavailable");
                    const QString output = QDir(artifactRoot).filePath(pdf ? "matte.pdf" : "matte-cmyk.tiff");
                    command({{"action", "writeExport"}, {"paths", QJsonArray{output}}});
                    check(QFileInfo(output).size() > 0, "PDF/TIFF matte export missing");
                    QImage expected(64, 64, QImage::Format_RGB32); expected.fill(Qt::green);
                    for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                        const QColor source = sourcePixels.pixelColor(x, y);
                        check(source.alpha() == 0 || source.alpha() == 255, "PDF/TIFF matte fixture has unexpected partial alpha");
                        if (source.alpha() == 255) expected.setPixelColor(x, y, source);
                    }
                    check(expected.save(QDir(artifactRoot).filePath("matte-expected.png")), "PDF/TIFF independent matte fixture save failed");
                    qInfo("Qt %s matte artifact ready for independent Poppler/LittleCMS check: %s", pdf ? "PDF" : "CMYK TIFF", qPrintable(output));
                } else if (commit) {
                    const QString output = temporary.filePath("picker-matte.jpg");
                    command({{"action", "writeExport"}, {"paths", QJsonArray{output}}});
                    const QImage exported(output); check(exported.size() == QSize(64, 64), "custom matte JPEG missing or wrong size");
                    const QColor matte = exported.pixelColor(0, 0);
                    // Use the installed JPEG codec as a lossy oracle around an independently assembled matte.
                    // This tests the dialog's chosen color, including compression artifacts at low quality.
                    QImage expected(64, 64, QImage::Format_RGB32); expected.fill(Qt::green);
                    for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                        const QColor source = sourcePixels.pixelColor(x, y);
                        check(source.alpha() == 0 || source.alpha() == 255, "JPEG matte fixture has unexpected partial alpha");
                        if (source.alpha() == 255) expected.setPixelColor(x, y, source);
                    }
                    const QString oraclePath = temporary.filePath("picker-matte-oracle.jpg");
                    check(expected.save(oraclePath, "JPEG", qualityPercent), "JPEG matte oracle encoding failed");
                    const QImage oracle(oraclePath); check(oracle.size() == exported.size(), "JPEG matte oracle decode failed");
                    qInfo("Qt Export Background JPEG quality=%d actual matte RGB=%d/%d/%d oracle=%d/%d/%d", qualityPercent,
                          matte.red(), matte.green(), matte.blue(), oracle.pixelColor(0, 0).red(), oracle.pixelColor(0, 0).green(), oracle.pixelColor(0, 0).blue());
                    for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                        const QColor actual = exported.pixelColor(x, y), reference = oracle.pixelColor(x, y);
                        check(std::abs(actual.red() - reference.red()) <= 2 && std::abs(actual.green() - reference.green()) <= 2
                                  && std::abs(actual.blue() - reference.blue()) <= 2 && actual.alpha() == 255,
                              "JPEG output differs from independently composed chosen background");
                    }
                }
                for (const char *name : {"width", "height", "layers", "activeLayerID", "modified", "undoName", "foreground", "background"})
                    check(window.sessionState().value(name) == before.value(name), "dialog color changed source records/history/palette");
                check(pixels() == sourcePixels && !window.sessionState().value("busy").toBool(), "dialog color did not restore source or release busy hold");
                qInfo("Qt dialog Color Picker OK (%s, outer %s, visible swatch RGB, Hex/Return, live preview, picker Cancel/OK, exact source/history/palette isolation)",
                      qPrintable(target), commit ? "commit and output" : "Cancel");
            }
            }
            for (int dpi : {72, 150, 300}) for (bool commit : {false, true}) {
                QImage source(64, 64, QImage::Format_RGBA8888); source.fill(Qt::transparent);
                source.setDotsPerMeterX(qRound(dpi / 0.0254)); source.setDotsPerMeterY(qRound(dpi / 0.0254));
                for (int y = 8; y < 56; ++y) for (int x = 8; x < 56; ++x) {
                    const int gray = qRound((x - 8) * 255.0 / 47);
                    source.setPixelColor(x, y, QColor(gray, gray, gray, y < 24 ? 128 : 255));
                }
                const QString input = temporary.filePath(QString("rgb-tiff-%1.png").arg(dpi));
                check(source.save(input) && window.importImage(input), "RGB TIFF fixture import failed");
                command({{"action", "setShowsTransformControls"}, {"enabled", false}});
                // Raster import starts at upstream's default DPI; export uses the document's resolution.
                command({{"action", "resizeImage"}, {"width", 64}, {"height", 64}, {"value", dpi}});
                check(window.sessionState().value("resolution").toDouble() == dpi, "RGB TIFF document DPI setup failed");
                const auto before = window.sessionState(); const QImage reference = pixels();
                QString failure; bool inspected = false;
                QTimer inspector; inspector.setInterval(20);
                QObject::connect(&inspector, &QTimer::timeout, &window, [&] {
                    auto *sheet = window.findChild<QDialog *>("swiftUISheet.ExportAsSheet");
                    if (!sheet || !sheet->isVisible()) return;
                    inspector.stop(); inspected = true;
                    try {
                        QPushButton *formats = nullptr;
                        for (auto *candidate : sheet->findChildren<QPushButton *>())
                            if (candidate->isVisible() && candidate->text() == "More" && candidate->menu()) formats = candidate;
                        check(formats, "visible export More menu missing");
                        auto *menu = formats->menu(); QAction *tiff = nullptr;
                        for (auto *candidate : menu->actions()) if (candidate->text().remove('&') == "TIFF") tiff = candidate;
                        check(tiff && tiff->isEnabled(), "visible TIFF format action missing");
                        menu->popup(formats->mapToGlobal(formats->rect().bottomLeft())); tiff->trigger(); menu->hide();
                        QApplication::processEvents();
                        pump([&] {
                            bool rgb = false, selected = false;
                            for (auto *candidate : sheet->findChildren<QPushButton *>()) if (candidate->isVisible()) {
                                rgb |= candidate->text() == "RGB";
                                selected |= candidate->text() == "TIFF";
                            }
                            return rgb && selected;
                        }, "TIFF format/RGB mode did not appear");
                        for (auto *candidate : sheet->findChildren<QPushButton *>())
                            check(!candidate->isVisible() || candidate->accessibleName() != "Export Background",
                                  "RGB TIFF offered a matte that would remove transparency");
                        const auto answer = [&]() -> QPushButton * {
                            for (auto *candidate : sheet->findChildren<QPushButton *>())
                                if (candidate->isVisible() && candidate->text() == (commit ? "Export…" : "Cancel")) return candidate;
                            return nullptr;
                        };
                        pump([&] { return answer() && answer()->isEnabled(); }, "RGB TIFF export preview did not become ready");
                        QApplication::setActiveWindow(sheet); click(answer());
                    } catch (const std::exception &error) {
                        failure = QString::fromUtf8(error.what()); sheet->reject();
                    }
                });
                inspector.start();
                const bool answered = window.sendCommand({{"action", "exportAsSheet"}, {"kind", "jpeg"}});
                inspector.stop();
                check(inspected && failure.isEmpty(), failure.isEmpty() ? "RGB TIFF modal was not inspected" : qPrintable(failure));
                check(answered == commit, "RGB TIFF Cancel/Export returned unexpected result");
                if (commit) {
                    const QString root = qEnvironmentVariable("COMPOSITOR_RGB_TIFF_ARTIFACTS", temporary.path());
                    check(QDir().mkpath(root), "RGB TIFF artifact directory unavailable");
                    const QString output = QDir(root).filePath(QString("rgb-tiff-%1.tiff").arg(dpi));
                    command({{"action", "writeExport"}, {"paths", QJsonArray{output}}});
                    const QImage exported(output);
                    check(reference.save(QDir(root).filePath(QString("rgb-tiff-%1-reference.png").arg(dpi))), "RGB TIFF reference save failed");
                    qInfo("RGB TIFF DPI diagnostic: input=%d document=%.6f sourceDPM=%d exportedDPM=%d/%d file=%s", dpi,
                          before.value("resolution").toDouble(), source.dotsPerMeterX(), exported.dotsPerMeterX(), exported.dotsPerMeterY(), qPrintable(output));
                    check(exported.size() == reference.size(), "RGB TIFF dimensions changed");
                    check(std::abs(exported.dotsPerMeterX() - source.dotsPerMeterX()) <= 1
                              && std::abs(exported.dotsPerMeterY() - source.dotsPerMeterY()) <= 1, "RGB TIFF DPI metadata changed");
                    for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                        const QColor actual = exported.pixelColor(x, y), expected = reference.pixelColor(x, y);
                        check(actual.alpha() == expected.alpha() && std::abs(actual.red() - expected.red()) <= 2
                                  && std::abs(actual.green() - expected.green()) <= 2 && std::abs(actual.blue() - expected.blue()) <= 2,
                              "RGB TIFF changed transparency or source colors");
                    }
                }
                QApplication::setActiveWindow(&window); QApplication::processEvents();
                for (const char *name : {"width", "height", "layers", "activeLayerID", "modified", "undoName", "redoName", "foregroundColor", "backgroundColor"})
                    check(window.sessionState().value(name) == before.value(name), "RGB TIFF export changed document/history/palette");
                check(pixels() == reference && !window.sessionState().value("busy").toBool(), "RGB TIFF did not preserve source or release busy hold");
                qInfo("Qt RGB TIFF visible export OK (More > TIFF, RGB/no matte, DPI=%d, %s, partial/clear/opaque alpha, all-pixel RGB, document/history/palette isolation)",
                      dpi, commit ? "Export" : "Cancel");
            }
            command({{"action", "setPaletteColor"}, {"kind", "foreground"},
                {"parameters", QJsonObject{{"red", 0}, {"green", 0}, {"blue", 0}}}});
            command({{"action", "setPaletteColor"}, {"kind", "background"},
                {"parameters", QJsonObject{{"red", 1}, {"green", 1}, {"blue", 1}}}});
        }
        if (app.arguments().contains("--color-picker-probe") || app.arguments().contains("--rgb-tiff-probe")) return 0;

        {
            const auto shape = [&](const QString &name) {
                QPushButton *choice = nullptr;
                for (auto *picker : window.findChildren<QWidget *>("segmentedPicker"))
                    for (auto *button : picker->findChildren<QPushButton *>())
                        if (button->isVisible() && button->text() == name) choice = button;
                check(choice, "visible Gradient shape missing"); click(choice);
            };
            const auto style = [&](bool transparent) {
                const auto choice = [&]() -> QComboBox * {
                    for (auto *candidate : window.findChildren<QComboBox *>())
                        if (candidate->isVisible() && candidate->findText("Foreground to Background") >= 0) return candidate;
                    check(false, "visible Gradient colors missing"); return nullptr;
                };
                key(choice(), Qt::Key_Home);
                if (transparent) key(choice(), Qt::Key_Down);
            };
            const auto reverse = [&](bool value) {
                QCheckBox *choice = nullptr;
                for (auto *candidate : window.findChildren<QCheckBox *>())
                    if (candidate->isVisible() && candidate->text() == "Reverse") choice = candidate;
                check(choice, "visible Gradient Reverse missing");
                if (choice->isChecked() != value) click(choice);
            };
            const auto opacity = [&](int value) {
                QLineEdit *field = nullptr;
                for (auto *candidate : window.findChildren<QLineEdit *>())
                    if (candidate->isVisible() && candidate->placeholderText() == "Opacity") field = candidate;
                check(field, "visible Gradient Opacity missing");
                field->setFocus(); field->selectAll(); field->insert(QString::number(value)); key(field, Qt::Key_Return);
            };
            const auto draftButton = [&](const QString &name) {
                QPushButton *button = nullptr;
                for (auto *candidate : window.findChildren<QPushButton *>())
                    if (candidate->isVisible() && candidate->text() == name) button = candidate;
                check(button, "visible Gradient draft action missing"); click(button);
            };
            for (bool radial : {false, true}) for (bool transparent : {false, true})
                for (bool reversed : {false, true}) for (int amount : {100, 50}) {
                    command({{"action", "new"}, {"width", 64}, {"height", 64}, {"emptyLayer", true}});
                    command({{"action", "setShowsTransformControls"}, {"enabled", false}});
                    command({{"action", "setPaletteColor"}, {"kind", "foreground"},
                             {"parameters", QJsonObject{{"red", 1}, {"green", 0}, {"blue", 0}}}});
                    command({{"action", "setPaletteColor"}, {"kind", "background"},
                             {"parameters", QJsonObject{{"red", 0}, {"green", 0}, {"blue", 1}}}});
                    tool("Gradient", "gradient");
                    shape(radial ? "Radial" : "Linear"); style(transparent); reverse(reversed); opacity(amount);
                    const auto before = window.sessionState(); const QImage blank = pixels();
                    drag(at(16.5, 32.5), at(48.5, 32.5));
                    check(window.sessionState().value("gradientLine").toArray().size() == 4,
                          "Gradient release lost the editable draft");
                    for (const char *field : {"layers", "activeLayerID", "undoName", "redoName", "canUndo", "canRedo"})
                        check(window.sessionState().value(field) == before.value(field), "Gradient draft changed records or history");
                    draftButton("Cancel");
                    check(window.sessionState().value("gradientLine").toArray().isEmpty() && pixels() == blank,
                          "Gradient Cancel did not discard the preview");
                    drag(at(16.5, 32.5), at(48.5, 32.5)); draftButton("Apply");
                    pump([&] { return window.sessionState().value("gradientLine").toArray().isEmpty()
                                      && !window.sessionState().value("busy").toBool(); }, "Gradient Apply did not settle");
                    const auto after = window.sessionState(); const QImage filled = pixels();
                    check(after.value("activeLayerID") == before.value("activeLayerID")
                              && after.value("layers").toArray().size() == before.value("layers").toArray().size()
                              && after.value("undoName").toString() == "Gradient", "Gradient Apply changed target or history name");
                    for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                        double t = radial ? std::hypot(x - 16.0, y - 32.0) / 32.0 : (x - 16.0) / 32.0;
                        t = std::clamp(t, 0.0, 1.0); if (reversed) t = 1 - t;
                        const double alpha = amount / 100.0 * (transparent ? 1 - t : 1);
                        const double red = transparent ? alpha : (1 - t) * alpha;
                        const double blue = transparent ? 0 : t * alpha;
                        const auto color = filled.pixelColor(x, y);
                        if (std::abs(color.alpha() - 255 * alpha) > 3
                            || std::abs(color.red() * color.alpha() / 255.0 - 255 * red) > 3
                            || color.green() * color.alpha() / 255.0 > 3
                            || std::abs(color.blue() * color.alpha() / 255.0 - 255 * blue) > 3) {
                            qWarning() << "Gradient oracle mismatch" << radial << transparent << reversed << amount << x << y << color
                                       << "expected premultiplied" << 255 * red << 255 * blue << 255 * alpha;
                            check(false, "Gradient pixels differ from the independent ramp oracle");
                        }
                    }
                    key(canvas, Qt::Key_Z, Qt::ControlModifier);
                    check(pixels() == blank && window.sessionState().value("layers") == before.value("layers")
                              && window.sessionState().value("activeLayerID") == before.value("activeLayerID"),
                          "Gradient Undo did not restore exact source records/pixels");
                    key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                    check(pixels() == filled && window.sessionState().value("layers") == after.value("layers")
                              && window.sessionState().value("activeLayerID") == after.value("activeLayerID"),
                          "Gradient Redo did not restore exact pixels/records");
                    qInfo("Qt Gradient settings OK (%s, %s, reverse=%d, opacity=%d, visible Cancel/Apply, independent all-pixel RGBA oracle, exact Undo/Redo)",
                          radial ? "Radial" : "Linear", transparent ? "Foreground to Transparent" : "Foreground to Background", reversed, amount);
                }
            shape("Linear"); style(true); reverse(false); opacity(100);
            command({{"action", "setPaletteColor"}, {"kind", "foreground"},
                     {"parameters", QJsonObject{{"red", 0}, {"green", 0}, {"blue", 0}}}});
            command({{"action", "setPaletteColor"}, {"kind", "background"},
                     {"parameters", QJsonObject{{"red", 1}, {"green", 1}, {"blue", 1}}}});
        }
        if (app.arguments().contains("--gradient-settings-probe")) return 0;

        {
            QImage source(64, 64, QImage::Format_RGBA8888); source.fill(Qt::red);
            const QString path = temporary.filePath("eraser-solid.png");
            check(source.save(path), "Eraser fixture save failed");
            const auto saved = window.sessionState();
            const auto segment = [&](const QString &name) {
                QPushButton *choice = nullptr;
                for (auto *picker : window.findChildren<QWidget *>("segmentedPicker"))
                    for (auto *button : picker->findChildren<QPushButton *>())
                        if (button->isVisible() && button->text() == name) choice = button;
                check(choice, "visible Eraser/selection segment missing"); click(choice);
            };
            const auto number = [&](const QString &name, int value) {
                QLineEdit *field = nullptr;
                for (auto *candidate : window.findChildren<QLineEdit *>())
                    if (candidate->isVisible() && candidate->placeholderText() == name) field = candidate;
                check(field, "visible Eraser numeric control missing");
                field->setFocus(); field->selectAll(); field->insert(QString::number(value)); key(field, Qt::Key_Return);
            };
            for (int variant = 0; variant < 10; ++variant) {
                const bool selected = variant >= 8;
                const int diameter = selected ? 24 : variant < 4 ? 8 : 16;
                const int hardness = selected || variant % 4 < 2 ? 100 : 0;
                const int amount = variant % 2 == 0 ? 100 : 50;
                check(window.importImage(path), "Eraser fixture import failed");
                command({{"action", "setShowsTransformControls"}, {"enabled", false}});
                if (selected) {
                    tool("Marquee", "marquee"); segment("Rectangle"); segment("New");
                    drag(at(24, 24), at(40, 40));
                }
                tool("Brush", "brush"); segment("Erase");
                number("Size", diameter); number("Hardness", hardness); number("Opacity", amount); number("Smoothing", 0);
                const auto before = window.sessionState(); const QImage original = pixels();
                check(before.value("brushDiameter").toDouble() == diameter
                          && before.value("brushHardness").toDouble() == hardness / 100.0
                          && before.value("brushOpacity").toDouble() == amount / 100.0
                          && before.value("brushSmoothing").toDouble() == 0,
                      "Eraser visible settings did not reach upstream");
                canvas->setFocus();
                mouse(canvas, QEvent::MouseButtonPress, at(32.5, 32.5), Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
                mouse(canvas, QEvent::MouseButtonRelease, at(32.5, 32.5), Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
                pump([&] { return !window.sessionState().value("busy").toBool(); }, "Eraser release did not finish");
                const auto after = window.sessionState(); const QImage erased = pixels();
                const int floor = amount == 100 ? 0 : 128;
                check(std::abs(erased.pixelColor(32, 32).alpha() - floor) <= 3,
                      "Eraser center did not apply the requested opacity");
                int partial = 0;
                for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                    const auto color = erased.pixelColor(x, y);
                    const double distance = std::hypot(x - 32.0, y - 32.0);
                    const bool outside = distance >= diameter / 2.0 + 1
                        || (selected && !QRect(24, 24, 16, 16).contains(x, y));
                    if (outside) check(color == original.pixelColor(x, y), "Eraser changed a pixel outside its tip/selection");
                    if (hardness == 100 && distance < diameter / 2.0 - 1 && !outside)
                        check(std::abs(color.alpha() - floor) <= 3, "hard Eraser did not clear its interior uniformly");
                    check(color.alpha() >= floor - 3, "Eraser opacity accumulated beyond the stroke cap");
                    if (color.alpha() > 0) check(color.red() >= 254 && color.green() <= 1 && color.blue() <= 1,
                                               "Eraser replaced the source color instead of reducing alpha");
                    if (color.alpha() > floor + 3 && color.alpha() < 252) ++partial;
                }
                if (hardness == 0) check(partial > 0, "soft Eraser lost its partial-alpha falloff");
                check(after.value("activeLayerID") == before.value("activeLayerID")
                          && after.value("layers").toArray().size() == before.value("layers").toArray().size(),
                      "Eraser changed target or layer count");
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(pixels() == original && window.sessionState().value("layers") == before.value("layers")
                          && window.sessionState().value("activeLayerID") == before.value("activeLayerID"),
                      "Eraser Undo did not restore exact pixels/records/target");
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                check(pixels() == erased && window.sessionState().value("layers") == after.value("layers")
                          && window.sessionState().value("activeLayerID") == after.value("activeLayerID"),
                      "Eraser Redo did not restore exact pixels/records/target");
                qInfo("Qt Eraser controls OK (size=%d, hardness=%d, opacity=%d, selection=%d, pointer stamp, alpha/color/outside checks, exact Undo/Redo)",
                      diameter, hardness, amount, selected);
            }
            segment("Paint");
            command({{"action", "setBrushSettings"}, {"parameters", QJsonObject{
                {"diameter", saved.value("brushDiameter")}, {"hardness", saved.value("brushHardness")},
                {"opacity", saved.value("brushOpacity")}, {"smoothing", saved.value("brushSmoothing")}}}});
            command({{"action", "deselect"}});
        }
        if (app.arguments().contains("--eraser-probe")) return 0;

        {
            QImage source(64, 64, QImage::Format_RGBA8888);
            for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                const int gray = x % 4 < 2 ? 100 : 112;
                source.setPixelColor(x, y, QRect(28, 28, 8, 8).contains(x, y)
                    ? QColor(230, 20, 20) : QColor(gray, gray, gray));
            }
            const QString path = temporary.filePath("healing-blemish.png");
            check(source.save(path), "Spot Healing fixture save failed");
            const auto saved = window.sessionState();
            const auto modeButton = [&](const QString &name) -> QPushButton * {
                for (auto *picker : window.findChildren<QWidget *>("spotHealingType"))
                    for (auto *button : picker->findChildren<QPushButton *>())
                        if (button->isVisible() && button->text() == name) return button;
                check(false, "visible Spot Healing mode missing"); return nullptr;
            };
            const auto number = [&](const QString &name, int value) {
                QLineEdit *field = nullptr;
                for (auto *candidate : window.findChildren<QLineEdit *>())
                    if (candidate->isVisible() && candidate->placeholderText() == name) field = candidate;
                check(field, "visible Spot Healing numeric control missing");
                field->setFocus(); field->selectAll(); field->insert(QString::number(value)); key(field, Qt::Key_Return);
            };
            for (const QString mode : {"Content-Aware", "Create Texture", "Proximity Match"})
                for (bool stroke : {false, true}) for (int amount : {100, 50}) {
                    check(window.importImage(path), "Spot Healing fixture import failed");
                    command({{"action", "setShowsTransformControls"}, {"enabled", false}});
                    tool("Spot Healing", "spotHealing"); click(modeButton(mode));
                    pump([&] { return modeButton(mode)->styleSheet().contains("0.24"); },
                         "Spot Healing mode did not remain selected after binding dispatch");
                    number("Size", stroke ? 16 : 20); number("Hardness", 100); number("Opacity", amount);
                    const auto before = window.sessionState(); const QImage original = pixels();
                    check(before.value("brushDiameter").toDouble() == (stroke ? 16 : 20)
                              && before.value("brushHardness").toDouble() == 1
                              && before.value("brushOpacity").toDouble() == amount / 100.0,
                          "Spot Healing visible settings did not reach upstream");
                    if (stroke) drag(at(28.5, 32.5), at(36.5, 32.5));
                    else {
                        canvas->setFocus();
                        mouse(canvas, QEvent::MouseButtonPress, at(32.5, 32.5), Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
                        mouse(canvas, QEvent::MouseButtonRelease, at(32.5, 32.5), Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
                        pump([&] { return !window.sessionState().value("busy").toBool(); }, "Spot Healing click did not finish");
                    }
                    const auto after = window.sessionState(); const QImage healed = pixels();
                    check(after.value("undoName").toString() == "Spot Healing"
                              && after.value("activeLayerID") == before.value("activeLayerID")
                              && after.value("layers").toArray().size() == before.value("layers").toArray().size(),
                          "Spot Healing did not commit to its original target");
                    for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                        const auto color = healed.pixelColor(x, y);
                        const double dx = stroke ? x - std::clamp(double(x), 28.0, 36.0) : x - 32.0;
                        const double distance = std::hypot(dx, y - 32.0);
                        if (distance >= (stroke ? 9 : 11))
                            check(color == original.pixelColor(x, y), "Spot Healing changed a pixel outside its footprint");
                        check(color.alpha() == 255, "Spot Healing changed the opaque source alpha");
                        if (QRect(28, 28, 8, 8).contains(x, y)) {
                            const bool repaired = amount == 100
                                ? color.red() - color.green() < 30 && color.green() >= 80 && color.green() <= 130
                                : color.red() - color.green() >= 75 && color.red() - color.green() <= 135
                                    && color.green() >= 50 && color.green() <= 80;
                            if (!repaired) qWarning() << "Spot Healing repair mismatch" << mode << stroke << amount << x << y << color;
                            check(repaired, "Spot Healing did not replace/blend the red blemish with the gray surface");
                        }
                    }
                    key(canvas, Qt::Key_Z, Qt::ControlModifier);
                    check(pixels() == original && window.sessionState().value("layers") == before.value("layers")
                              && window.sessionState().value("activeLayerID") == before.value("activeLayerID"),
                          "Spot Healing Undo did not restore exact source pixels/records/target");
                    key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                    check(pixels() == healed && window.sessionState().value("layers") == after.value("layers")
                              && window.sessionState().value("activeLayerID") == after.value("activeLayerID"),
                          "Spot Healing Redo did not restore exact committed pixels/records/target");
                    qInfo("Qt Spot Healing OK (%s, %s, opacity=%d, visible controls, blemish repair/blend, unchanged outside/alpha, exact Undo/Redo)",
                          qPrintable(mode), stroke ? "pointer stroke" : "pointer stamp", amount);
                }
            click(modeButton("Content-Aware"));
            command({{"action", "setBrushSettings"}, {"parameters", QJsonObject{
                {"diameter", saved.value("brushDiameter")}, {"hardness", saved.value("brushHardness")},
                {"opacity", saved.value("brushOpacity")}, {"smoothing", saved.value("brushSmoothing")}}}});
        }
        if (app.arguments().contains("--healing-probe")) return 0;

        // Use the upstream segmented picker and numeric fields, then draw each shape through Qt pointer events.
        {
            const auto chooseShape = [&](const QString &name) {
                QPushButton *choice = nullptr;
                for (auto *picker : window.findChildren<QWidget *>("segmentedPicker"))
                    for (auto *button : picker->findChildren<QPushButton *>())
                        if (button->isVisible() && button->text() == name) choice = button;
                check(choice, "visible Shape segment missing");
                click(choice);
                QApplication::processEvents();
            };
            const auto shapeNumber = [&](const QString &placeholder, const QString &value) {
                QLineEdit *field = nullptr;
                for (auto *candidate : window.findChildren<QLineEdit *>())
                    if (candidate->isVisible() && candidate->placeholderText() == placeholder) field = candidate;
                check(field, "visible Shape numeric field missing");
                field->setFocus(); field->selectAll();
                QTest::sendKeyEvent(QTest::Click, window.windowHandle(), Qt::Key_0, value, Qt::NoModifier);
                key(field, Qt::Key_Return);
                QApplication::processEvents();
            };
            for (int variant = 0; variant < 4; ++variant) {
                command({{"action", "new"}, {"width", 64}, {"height", 64}, {"emptyLayer", true}});
                command({{"action", "setPaletteColor"}, {"kind", "foreground"},
                         {"parameters", QJsonObject{{"red", 0}, {"green", 0}, {"blue", 1}}}});
                tool("Shape", "shape");
                chooseShape(variant < 2 ? "Rectangle" : variant == 2 ? "Ellipse" : "Line");
                if (variant < 2) shapeNumber("Radius", variant == 0 ? "0" : "6");
                if (variant == 3) shapeNumber("Width", "4");
                const auto beforeLayers = window.sessionState().value("layers");
                const auto beforeActive = window.sessionState().value("activeLayerID");
                const QImage before = pixels();
                drag(at(8, 10), at(40, 34));
                const auto afterState = window.sessionState();
                const auto afterLayers = afterState.value("layers");
                const QImage after = pixels();
                check(afterLayers.toArray().size() == beforeLayers.toArray().size() + 1
                          && afterState.value("activeLayerID") != beforeActive,
                      "Shape gesture did not create a separate layer");
                check(after.pixelColor(24, 22) == QColor(Qt::blue), "Shape interior does not use foreground color");
                check(after.pixelColor(variant == 3 ? 9 : 8, variant == 3 ? 11 : 10).alpha()
                          == (variant == 0 || variant == 3 ? 255 : 0),
                      "Shape corner does not distinguish its geometry");
                if (variant == 3) check(after.pixelColor(9, 32).alpha() == 0, "Line filled its bounding box");
                // A square cap's diagonal corner reaches halfWidth * (|dx| + |dy|) / length beyond an endpoint.
                // Upstream 1.5.4 defaults to square caps; the old two-pixel round-cap margin is too small here.
                const int reach = variant == 3 ? int(std::ceil(2.0 * (32.0 + 24.0) / std::hypot(32.0, 24.0))) : 2;
                unchangedOutside(before, after, QRect(8 - reach, 10 - reach, 32 + 2 * reach, 24 + 2 * reach));
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(pixels() == before && window.sessionState().value("layers") == beforeLayers
                          && window.sessionState().value("activeLayerID") == beforeActive,
                      "Shape Undo did not restore pixels and layers");
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                check(pixels() == after && window.sessionState().value("layers") == afterLayers,
                      "Shape Redo did not restore exact geometry and layer identity");
            }
            qInfo("Qt Shape OK (rectangle, radius-6 rounded rectangle, ellipse, width-4 line, visible controls, pointer drawing, exact Undo/Redo)");
        }
        if (app.arguments().contains("--shape-probe")) return 0;

        // Clone source selection is an Alt pointer gesture; Aligned changes subsequent source placement.
        {
            QImage image(64, 64, QImage::Format_RGBA8888);
            image.fill(Qt::blue);
            for (int y = 0; y < 64; ++y) for (int x = 0; x < 32; ++x) image.setPixelColor(x, y, Qt::red);
            for (int y = 16; y < 26; ++y) for (int x = 10; x < 20; ++x) image.setPixelColor(x, y, Qt::green);
            const QString path = temporary.filePath("clone-colors.png");
            check(image.save(path) && window.importImage(path), "Clone fixture import failed");
            command({{"action", "setShowsTransformControls"}, {"enabled", false}});
            tool("Clone Stamp", "cloneStamp");
            command({{"action", "setBrushSettings"}, {"parameters", QJsonObject{
                         {"diameter", 6}, {"hardness", 1}, {"opacity", 1}, {"smoothing", 0}}}});
            QCheckBox *aligned = nullptr;
            for (auto *candidate : window.findChildren<QCheckBox *>())
                if (candidate->isVisible() && candidate->text() == "Aligned") aligned = candidate;
            check(aligned, "visible Clone Aligned control missing");
            if (!aligned->isChecked()) click(aligned);
            QPushButton *sample = nullptr;
            for (auto *candidate : window.findChildren<QPushButton *>())
                if (candidate->isVisible() && candidate->text() == "This Layer") sample = candidate;
            check(sample, "visible Clone This Layer segment missing");
            click(sample);
            const auto before = window.sessionState();
            mouse(canvas, QEvent::MouseButtonPress, at(15, 21), Qt::LeftButton, Qt::LeftButton, Qt::AltModifier);
            mouse(canvas, QEvent::MouseButtonRelease, at(15, 21), Qt::LeftButton, Qt::NoButton, Qt::AltModifier);
            check(pixels() == image && window.sessionState().value("layers") == before.value("layers")
                      && window.sessionState().value("undoName") == before.value("undoName"),
                  "Clone Alt source gesture painted or changed document history");
            const auto stamp = [&](int x, int y, const QColor &expected) {
                const QImage prior = pixels();
                const auto priorState = window.sessionState();
                drag(at(x, y), at(x + 0.5, y));
                const QImage painted = pixels();
                const auto paintedState = window.sessionState();
                if (painted.pixelColor(x, y) != expected)
                    qWarning() << "Clone sample mismatch" << x << y << painted.pixelColor(x, y) << "expected" << expected;
                check(painted.pixelColor(x, y) == expected, "Clone stamp sampled the wrong source location");
                unchangedOutside(prior, painted, QRect(x - 4, y - 4, 9, 9));
                check(paintedState.value("activeLayerID") == priorState.value("activeLayerID")
                          && paintedState.value("layers").toArray().size() == priorState.value("layers").toArray().size(),
                      "Clone stamp changed layer target or count");
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(pixels() == prior && window.sessionState().value("layers") == priorState.value("layers"),
                      "Clone Undo did not restore pixels and layer geometry");
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                check(pixels() == painted && window.sessionState().value("layers") == paintedState.value("layers"),
                      "Clone Redo did not restore exact pixels and layer geometry");
            };
            stamp(48, 21, Qt::green);
            stamp(54, 21, Qt::red);
            aligned = nullptr;
            for (auto *candidate : window.findChildren<QCheckBox *>())
                if (candidate->isVisible() && candidate->text() == "Aligned") aligned = candidate;
            check(aligned && aligned->isChecked(), "Clone Aligned control lost its enabled value");
            click(aligned);
            stamp(48, 40, Qt::green);
            const auto sourceLayerID = window.sessionState().value("activeLayerID");
            QJsonObject sourceLayer;
            for (const auto &entry : window.sessionState().value("layers").toArray())
                if (entry.toObject().value("id") == sourceLayerID) sourceLayer = entry.toObject();
            check(!sourceLayer.isEmpty(), "Clone source layer record missing");
            command({{"action", "addLayer"}});
            check(window.sessionState().value("activeLayerID") != sourceLayerID,
                  "Clone All Layers fixture did not select the blank destination");
            sample = nullptr;
            for (auto *candidate : window.findChildren<QPushButton *>())
                if (candidate->isVisible() && candidate->text() == "All Layers") sample = candidate;
            check(sample, "visible Clone All Layers segment missing");
            click(sample);
            stamp(48, 55, Qt::green);
            bool sourceUnchanged = false;
            for (const auto &entry : window.sessionState().value("layers").toArray())
                if (entry.toObject().value("id") == sourceLayerID) sourceUnchanged = entry.toObject() == sourceLayer;
            check(sourceUnchanged, "Clone All Layers changed the underlying source layer");
            qInfo("Qt Clone Stamp OK (Alt source, visible This Layer/All Layers/Aligned controls, aligned sampling, unaligned restart, blank destination, source isolation, exact Undo/Redo)");
        }
        if (app.arguments().contains("--clone-probe")) return 0;

        // Mask paint colors come from the visible Boolean picker, independently of the foreground swatch.
        {
            QImage image(64, 64, QImage::Format_RGBA8888); image.fill(QColor(80, 140, 200));
            const QString path = temporary.filePath("mask-picker-source.png");
            check(image.save(path), "mask picker fixture save failed");
            for (bool folder : {false, true}) for (bool hideAll : {false, true}) {
                check(window.importImage(path), "mask picker fixture import failed");
                command({{"action", "setShowsTransformControls"}, {"enabled", false}});
                if (folder) {
                    QPushButton *group = nullptr;
                    for (auto *candidate : window.findChildren<QPushButton *>())
                        if (candidate->isVisible() && candidate->accessibleName() == "New folder") group = candidate;
                    click(group);
                }
                const auto target = window.sessionState().value("activeLayerID");
                QPushButton *add = nullptr;
                for (auto *candidate : window.findChildren<QPushButton *>())
                    if (candidate->isVisible() && candidate->accessibleName() == "Add layer mask") add = candidate;
                check(add && add->isEnabled(), "mask picker footer missing");
                const auto modifiers = hideAll ? Qt::AltModifier : Qt::NoModifier;
                mouse(add, QEvent::MouseButtonPress, add->rect().center(), Qt::LeftButton, Qt::LeftButton, modifiers);
                mouse(add, QEvent::MouseButtonRelease, add->rect().center(), Qt::LeftButton, Qt::NoButton, modifiers);
                pump([&] { return window.sessionState().value("isMaskSelected").toBool()
                                   && window.sessionState().value("activeLayerHasMask").toBool(); },
                     "mask picker footer did not select the mask");
                const QImage initial = pixels();
                if (hideAll) {
                    for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x)
                        check(initial.pixelColor(x, y).alpha() == 0, "Alt mask footer did not create Hide All");
                } else check(initial == image, "mask footer did not create Reveal All");
                tool("Brush", "brush");
                command({{"action", "setBrushSettings"}, {"parameters", QJsonObject{
                             {"diameter", 8}, {"hardness", 1}, {"opacity", 1}, {"smoothing", 0}}}});
                QImage firstPaint;
                for (bool reveal : {hideAll, !hideAll}) {
                    QComboBox *paint = nullptr;
                    for (auto *candidate : window.findChildren<QComboBox *>())
                        if (candidate->isVisible() && candidate->findText("Black · Hide") >= 0
                            && candidate->findText("White · Reveal") >= 0) paint = candidate;
                    check(paint, "visible mask Paint picker missing");
                    key(paint, reveal ? Qt::Key_End : Qt::Key_Home);
                    const QImage prior = pixels();
                    const auto priorState = window.sessionState();
                    drag(at(16, 32), at(48, 32));
                    const QImage painted = pixels();
                    if (reveal == hideAll) firstPaint = painted;
                    const auto paintedState = window.sessionState();
                    check(painted.pixelColor(32, 32) == (reveal ? image.pixelColor(32, 32) : QColor(Qt::transparent)),
                          "visible mask Paint choice did not hide/reveal the stroke");
                    unchangedOutside(prior, painted, QRect(11, 27, 43, 11));
                    check(paintedState.value("activeLayerID") == target && paintedState.value("isMaskSelected").toBool()
                              && paintedState.value("layers").toArray().size() == (folder ? 2 : 1),
                          "mask Paint changed target or hierarchy");
                    key(canvas, Qt::Key_Z, Qt::ControlModifier);
                    check(pixels() == prior && window.sessionState().value("layers") == priorState.value("layers"),
                          "mask Paint Undo lost exact coverage or geometry");
                    key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                    check(pixels() == painted && window.sessionState().value("layers") == paintedState.value("layers"),
                          "mask Paint Redo lost exact coverage or geometry");
                }
                const QImage restored = pixels();
                for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                    const int alpha = firstPaint.pixelColor(x, y).alpha();
                    // The second stroke blends its opposite color through the same antialiased coverage.
                    const double expected = hideAll ? alpha * (255 - alpha) / 255.0
                                                    : alpha * alpha / 255.0 + 255 - alpha;
                    check(std::abs(restored.pixelColor(x, y).alpha() - expected) <= 2,
                          "opposite mask Paint stroke does not follow source-over coverage");
                }
                command({{"action", "setMaskEnabled"}, {"enabled", false}});
                check(pixels() == image, "mask Paint changed source-image pixels");
                qInfo("Qt mask Paint picker OK (%s, %s footer, native Black/White keys, source isolation and exact Undo/Redo)",
                      folder ? "folder" : "layer", hideAll ? "Alt Hide All" : "Reveal All");
            }
        }
        if (app.arguments().contains("--mask-paint-probe")) return 0;

        // Native layer-table menus and Cmd-click mask thumbnails use the original AppKit handlers.
        {
            const auto layerTable = [&]() -> QWidget * {
                for (auto *candidate : window.findChildren<QWidget *>())
                    if (candidate->isVisible() && candidate->property("appKitView").toBool()
                        && candidate->property("appKitNode").toString().startsWith("LayersPanel|")) return candidate;
                throw std::runtime_error("mask context layer table missing");
            };
            const auto contextAction = [&](const QString &title, bool enabled = true, int row = 0) {
                bool chosen = false, unavailable = false;
                QElapsedTimer deadline; deadline.start();
                QTimer choose;
                QObject::connect(&choose, &QTimer::timeout, &window, [&] {
                    QMenu *menu = nullptr;
                    for (auto *candidate : window.findChildren<QMenu *>())
                        if (candidate->isVisible() && candidate->property("upstreamMenuOwnsTracking").toBool()) menu = candidate;
                    if (!menu) return;
                    QAction *action = nullptr;
                    const auto path = title.split('/');
                    for (int depth = 0; depth < path.size(); ++depth) {
                        action = nullptr;
                        for (auto *candidate : menu->actions()) if (candidate->text() == path.at(depth)) action = candidate;
                        if (!action || depth == path.size() - 1) break;
                        if (!action->isEnabled() || !action->menu()) { action = nullptr; break; }
                        if (!action->menu()->isVisible()) {
                            menu->setActiveAction(action);
                            QTest::sendKeyEvent(QTest::Click, menu->windowHandle(), Qt::Key_Right, QString(), Qt::NoModifier);
                            return;
                        }
                        menu = action->menu();
                    }
                    if (!action || action->isEnabled() != enabled || deadline.elapsed() > 5000) {
                        QStringList titles;
                        for (auto *candidate : menu->actions()) titles << candidate->text();
                        qWarning() << "mask context unavailable" << title << "elapsed" << deadline.elapsed()
                                   << "enabled" << (action && action->isEnabled()) << "items" << titles;
                        unavailable = true; choose.stop(); menu->close(); return;
                    }
                    chosen = true; choose.stop(); menu->setActiveAction(action);
                    if (!enabled) { menu->close(); return; }
                    QTest::sendKeyEvent(QTest::Click, menu->windowHandle(), Qt::Key_Return, QString(), Qt::NoModifier);
                });
                choose.start(10);
                const QPointF position(108, row * 54 + 26);
                mouse(layerTable(), QEvent::MouseButtonPress, position, Qt::RightButton, Qt::RightButton, Qt::NoModifier);
                pump([&] { return chosen || unavailable; }, "mask context popup did not open");
                choose.stop();
                mouse(layerTable(), QEvent::MouseButtonRelease, position, Qt::RightButton, Qt::NoButton, Qt::NoModifier);
                check(chosen && !unavailable, "visible mask context action unavailable");
                QApplication::setActiveWindow(&window); QApplication::processEvents();
            };
            const auto undoRedo = [&](const QJsonObject &before, const QImage &beforePixels) {
                const auto after = window.sessionState(); const QImage afterPixels = pixels();
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(pixels() == beforePixels && window.sessionState().value("layers") == before.value("layers"),
                      "mask menu Undo lost exact pixels or records");
                check(window.sessionState().value("activeLayerIsClipped") == before.value("activeLayerIsClipped"),
                      "mask menu Undo lost clipping state");
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                check(pixels() == afterPixels && window.sessionState().value("layers") == after.value("layers")
                          && window.sessionState().value("activeLayerID") == after.value("activeLayerID"),
                      "mask menu Redo lost exact pixels, records or target");
                check(window.sessionState().value("activeLayerIsClipped") == after.value("activeLayerIsClipped"),
                      "mask menu Redo lost clipping state");
            };
            QImage source(64, 64, QImage::Format_RGBA8888); source.fill(QColor(80, 140, 200));
            const QString path = temporary.filePath("mask-menu-source.png");
            check(source.save(path), "mask menu fixture save failed");
            for (bool folder : {false, true}) for (bool hidden : {false, true}) {
                check(window.importImage(path), "mask submenu fixture import failed");
                command({{"action", "setShowsTransformControls"}, {"enabled", false}});
                if (folder) {
                    QPushButton *group = nullptr;
                    for (auto *button : window.findChildren<QPushButton *>())
                        if (button->isVisible() && button->accessibleName() == "New folder") group = button;
                    click(group);
                }
                const auto before = window.sessionState();
                contextAction(hidden ? "Add Mask/Hide All (Black)" : "Add Mask/Reveal All (White)");
                check(window.sessionState().value("activeLayerHasMask").toBool(), "nested Add Mask did not create a mask");
                const QImage after = pixels();
                for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x)
                    check(hidden ? after.pixelColor(x, y).alpha() == 0 : after.pixelColor(x, y) == source.pixelColor(x, y),
                          "nested Add Mask created the wrong coverage");
                undoRedo(before, source);
                const auto maskedState = window.sessionState();
                contextAction("Add Mask", false);
                check(pixels() == after && window.sessionState().value("layers") == maskedState.value("layers")
                          && window.sessionState().value("undoName") == maskedState.value("undoName"),
                      "disabled Add Mask changed existing coverage or history");
                qInfo("Qt Add Mask submenu OK (%s, %s, visible nested menu, disabled parent, exact pixels/records Undo/Redo)",
                      folder ? "folder" : "layer", hidden ? "Hide All" : "Reveal All");
            }
            for (bool folder : {false, true}) {
                check(window.importImage(path), "mask menu fixture import failed");
                command({{"action", "setShowsTransformControls"}, {"enabled", false}});
                if (folder) {
                    QPushButton *group = nullptr;
                    for (auto *button : window.findChildren<QPushButton *>())
                        if (button->isVisible() && button->accessibleName() == "New folder") group = button;
                    click(group);
                }
                QPushButton *add = nullptr;
                for (auto *button : window.findChildren<QPushButton *>())
                    if (button->isVisible() && button->accessibleName() == "Add layer mask") add = button;
                click(add); tool("Brush", "brush");
                command({{"action", "setBrushSettings"}, {"parameters", QJsonObject{
                             {"diameter", 8}, {"hardness", 1}, {"opacity", 1}, {"smoothing", 0}}}});
                QComboBox *paint = nullptr;
                for (auto *candidate : window.findChildren<QComboBox *>())
                    if (candidate->isVisible() && candidate->findText("Black · Hide") >= 0) paint = candidate;
                check(paint, "mask context Paint picker missing"); key(paint, Qt::Key_Home);
                drag(at(16, 32), at(48, 32));
                const QImage masked = pixels();
                check(masked.pixelColor(32, 32).alpha() == 0 && masked.pixelColor(4, 4) == source.pixelColor(4, 4),
                      "mask context fixture stroke missing");
                const QStringList titles = folder ? QStringList{"Disable Mask", "Enable Mask"}
                                                  : QStringList{"Disable Mask", "Enable Mask", "Unlink Mask", "Link Mask"};
                for (const auto &title : titles) {
                    const auto before = window.sessionState(); const QImage beforePixels = pixels();
                    contextAction(title);
                    check(pixels() == (title == "Disable Mask" ? source : masked), "mask context changed unexpected pixels");
                    check(window.sessionState().value("layers") != before.value("layers"), "mask context action did not update mask state");
                    undoRedo(before, beforePixels);
                }
                if (folder) {
                    const auto before = window.sessionState(); contextAction("Unlink Mask", false);
                    check(pixels() == masked && window.sessionState().value("layers") == before.value("layers")
                              && window.sessionState().value("undoName") == before.value("undoName"),
                          "disabled folder Unlink changed pixels, hierarchy or history");
                }
                const auto beforeInvert = window.sessionState();
                QMenu *imageMenu = nullptr;
                for (auto *action : window.menuBar()->actions()) if (action->text().remove('&') == "Image") imageMenu = action->menu();
                check(imageMenu, "mask Image menu missing");
                imageMenu->popup(window.mapToGlobal(QPoint(200, 50))); QApplication::processEvents();
                QAction *invert = nullptr;
                for (auto *action : imageMenu->actions()) if (action->text().remove('&') == "Invert Mask") invert = action;
                check(imageMenu->isVisible() && invert && invert->isEnabled(), "visible Invert Mask action missing");
                invert->trigger(); imageMenu->hide(); QApplication::processEvents();
                pump([&] { return !window.sessionState().value("busy").toBool()
                                  && window.sessionState().value("undoName").toString() == "Invert Mask"; });
                const QImage inverted = pixels();
                for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x)
                    check(std::abs(inverted.pixelColor(x, y).alpha() + masked.pixelColor(x, y).alpha() - 255) <= 1,
                          "Invert Mask did not complement coverage");
                undoRedo(beforeInvert, masked); key(canvas, Qt::Key_Z, Qt::ControlModifier);
                if (!folder) {
                    const auto beforeLayerSelection = window.sessionState();
                    mouse(layerTable(), QEvent::MouseButtonPress, QPointF(60, 26), Qt::LeftButton, Qt::LeftButton, Qt::ControlModifier);
                    mouse(layerTable(), QEvent::MouseButtonRelease, QPointF(60, 26), Qt::LeftButton, Qt::NoButton, Qt::ControlModifier);
                    check(window.sessionState().value("hasSelection").toBool()
                              && window.sessionState().value("undoName").toString() == "Load Layer Selection"
                              && pixels() == masked, "Ctrl image thumbnail did not load source pixels");
                    command({{"action", "addLayer"}});
                    command({{"action", "setPaletteColor"}, {"kind", "foreground"},
                             {"parameters", QJsonObject{{"red", 0}, {"green", 0}, {"blue", 1}}}});
                    const auto beforeFill = window.sessionState();
                    command({{"action", "fillForeground"}});
                    const QImage filled = pixels();
                    for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x)
                        check(filled.pixelColor(x, y) == QColor(Qt::blue), "loaded layer selection unexpectedly applied its mask");
                    undoRedo(beforeFill, masked);
                    key(canvas, Qt::Key_Z, Qt::ControlModifier);
                    key(canvas, Qt::Key_Z, Qt::ControlModifier);
                    key(canvas, Qt::Key_Z, Qt::ControlModifier);
                    check(!window.sessionState().value("hasSelection").toBool() && pixels() == masked
                              && window.sessionState().value("layers") == beforeLayerSelection.value("layers"),
                          "layer selection cleanup changed mask or original pixels");
                }
                const auto beforeLoad = window.sessionState();
                mouse(layerTable(), QEvent::MouseButtonPress, QPointF(108, 26), Qt::LeftButton, Qt::LeftButton, Qt::ControlModifier);
                mouse(layerTable(), QEvent::MouseButtonRelease, QPointF(108, 26), Qt::LeftButton, Qt::NoButton, Qt::ControlModifier);
                check(window.sessionState().value("hasSelection").toBool()
                          && window.sessionState().value("undoName").toString() == "Load Mask Selection"
                          && pixels() == masked && window.sessionState().value("layers") == beforeLoad.value("layers"),
                      "Ctrl mask thumbnail did not load coverage without changing pixels");
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(!window.sessionState().value("hasSelection").toBool(), "loaded mask selection Undo failed");
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                check(window.sessionState().value("hasSelection").toBool(), "loaded mask selection Redo failed");
                command({{"action", "addLayer"}});
                if (folder) command({{"action", "moveActiveLayerOutOfGroup"}});
                check(pixels() == masked, "mask selection destination changed the source composite");
                command({{"action", "setPaletteColor"}, {"kind", "foreground"},
                         {"parameters", QJsonObject{{"red", 0}, {"green", 0}, {"blue", 1}}}});
                const auto beforeFill = window.sessionState();
                command({{"action", "fillForeground"}});
                const QImage filled = pixels();
                check(filled.pixelColor(32, 32) == QColor(Qt::blue)
                          && filled.pixelColor(4, 4) == masked.pixelColor(4, 4),
                      "loaded mask selection did not select dark/hidden pixels");
                unchangedOutside(masked, filled, QRect(11, 27, 43, 11));
                undoRedo(beforeFill, masked);
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                if (folder) key(canvas, Qt::Key_Z, Qt::ControlModifier);
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(pixels() == masked && window.sessionState().value("layers") == beforeLoad.value("layers"),
                      "mask selection fill cleanup changed original masks or images");
                command({{"action", "deselect"}});
                const auto beforeDelete = window.sessionState();
                contextAction("Delete Mask");
                check(!window.sessionState().value("activeLayerHasMask").toBool() && pixels() == source
                          && window.sessionState().value("layers").toArray().size() == (folder ? 2 : 1),
                      "Delete Mask removed the image or retained mask coverage");
                undoRedo(beforeDelete, masked);
                qInfo("Qt mask menus OK (%s, right-click Disable/Enable/Delete, layer Unlink/Link or folder refusal, Image Invert Mask, Ctrl-thumbnail selection, exact Undo/Redo)",
                      folder ? "folder" : "layer");
            }
            for (bool soft : {false, true}) {
                QImage base(64, 64, QImage::Format_RGBA8888); base.fill(Qt::transparent);
                for (int y = 16; y < 48; ++y) for (int x = 16; x < 48; ++x)
                    base.setPixelColor(x, y, QColor(255, 0, 0, soft ? (x < 24 ? 32 : x < 32 ? 64 : x < 40 ? 128 : 255) : 255));
                const QString basePath = temporary.filePath(soft ? "clip-soft.png" : "clip-hard.png");
                check(base.save(basePath) && window.importImage(basePath), "clipping fixture import failed");
                command({{"action", "setShowsTransformControls"}, {"enabled", false}});
                const auto sourceID = window.sessionState().value("activeLayerID");
                const auto sourceRecords = window.sessionState().value("layers").toArray();
                command({{"action", "addLayer"}});
                command({{"action", "setPaletteColor"}, {"kind", "foreground"},
                         {"parameters", QJsonObject{{"red", 0}, {"green", 0}, {"blue", 1}}}});
                command({{"action", "fillForeground"}});
                const auto before = window.sessionState(); const QImage full = pixels();
                const auto targetID = before.value("activeLayerID");
                check(!before.value("activeLayerIsClipped").toBool() && before.value("layers").toArray().size() == 2,
                      "clipping fixture did not create a separate top layer");
                contextAction("Create Clipping Mask");
                const QImage clipped = pixels();
                check(window.sessionState().value("activeLayerIsClipped").toBool()
                          && window.sessionState().value("activeLayerID") == targetID,
                      "visible clipping creation did not retain its target");
                for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                    const int alpha = base.pixelColor(x, y).alpha();
                    check(clipped.pixelColor(x, y) == (alpha ? QColor(0, 0, 255, alpha) : QColor(Qt::transparent)),
                          "clipping did not preserve base alpha or left a color fringe");
                }
                const auto layers = window.sessionState().value("layers").toArray();
                bool keptSource = false;
                for (const auto &entry : layers) if (entry.toObject().value("id") == sourceID)
                    keptSource = entry == sourceRecords.first();
                check(keptSource && layers.size() == 2, "clipping changed its source record or layer count");
                undoRedo(before, full);
                const QString project = temporary.filePath(soft ? "clip-soft.comp" : "clip-hard.comp");
                bool saved = false, succeeded = false;
                check(window.startProjectSave(project, false, [&](bool ok) { succeeded = ok; saved = true; }),
                      "clipping manifest proof could not save");
                pump([&] { return saved; }, "clipping manifest proof save did not finish");
                QFile manifest(project + "/manifest.json");
                check(succeeded && manifest.open(QIODevice::ReadOnly), "clipping manifest proof missing");
                const auto records = QJsonDocument::fromJson(manifest.readAll()).object().value("layers").toArray();
                bool linked = false;
                for (const auto &entry : records) if (QUuid(entry.toObject().value("id").toString()) == QUuid(targetID.toString()))
                    linked = QUuid(entry.toObject().value("maskSourceID").toString()) == QUuid(sourceID.toString());
                check(linked, "clipping manifest did not retain the exact base-layer identity");
                const auto beforeRelease = window.sessionState();
                contextAction("Release Clipping Mask");
                check(!window.sessionState().value("activeLayerIsClipped").toBool() && pixels() == full,
                      "visible clipping release did not restore the full top layer");
                undoRedo(beforeRelease, clipped);
                command({{"action", "selectLayer"}, {"layerID", sourceID}});
                const auto beforeRefusal = window.sessionState();
                contextAction("Create Clipping Mask", false, 1);
                check(pixels() == full && window.sessionState().value("layers") == beforeRefusal.value("layers")
                          && window.sessionState().value("undoName") == beforeRefusal.value("undoName"),
                      "disabled bottom-layer clipping changed document or history");
                qInfo("Qt clipping menu OK (%s base, Create/Release, exact alpha/no fringe, source/target identity, manifest link, bottom refusal and Undo/Redo)",
                      soft ? "32/64/128/255 alpha" : "opaque");
            }
        }
        if (app.arguments().contains("--mask-menu-probe")) return 0;

        // Selection amount dialogs and menu commands operate on the original selection, proven by reversible fills.
        {
            const auto selectAction = [&](const QString &title) {
                canvas->setFocus();
                QMenu *menu = nullptr;
                for (auto *action : window.menuBar()->actions()) if (action->text().remove('&') == "Select") menu = action->menu();
                check(menu, "selection menu missing");
                menu->popup(window.mapToGlobal(QPoint(180, 40))); QApplication::processEvents();
                QAction *chosen = nullptr;
                for (auto *action : menu->actions()) if (action->text().remove('&') == title) chosen = action;
                check(menu->isVisible() && chosen && chosen->isEnabled(), "visible selection action unavailable");
                chosen->trigger(); menu->hide(); QApplication::processEvents();
            };
            const auto amountPanel = [&]() -> QDialog * {
                for (auto *top : QApplication::topLevelWidgets())
                    if (auto *dialog = qobject_cast<QDialog *>(top); dialog && dialog->isVisible()
                        && dialog->objectName() == "floatingPanel.SelectionAmountSheet") return dialog;
                return nullptr;
            };
            const auto amountButton = [&](const QString &title) -> QPushButton * {
                if (auto *dialog = amountPanel()) for (auto *button : dialog->findChildren<QPushButton *>())
                    if (button->isVisible() && button->text() == title) return button;
                return nullptr;
            };
            const auto enterAmount = [&](const QString &value) {
                QLineEdit *field = nullptr;
                if (auto *dialog = amountPanel()) for (auto *candidate : dialog->findChildren<QLineEdit *>())
                    if (candidate->isVisible() && candidate->placeholderText() == "Amount") field = candidate;
                check(field && field->isEnabled(), "selection Amount field unavailable");
                const QPointer<QLineEdit> originalField = field;
                field->setFocus(); field->selectAll(); field->insert(value); QApplication::processEvents();
                check(originalField && QApplication::focusWidget() == originalField && originalField->text() == value
                          && originalField->cursorPosition() == value.size(), "Amount validation replaced the field or lost focus/cursor");
                QLabel *hint = nullptr;
                for (auto *label : amountPanel()->findChildren<QLabel *>())
                    if (label->text() == "Enter a whole number from 1 to 500 px.") hint = label;
                auto *effect = hint ? qobject_cast<QGraphicsOpacityEffect *>(hint->graphicsEffect()) : nullptr;
                const bool valid = value.toInt() >= 1 && value.toInt() <= 500;
                check(effect && std::abs(effect->opacity() - (valid ? 0 : 1)) < 0.01,
                      "Amount validation did not refresh its range hint");
                QSlider *slider = nullptr;
                for (auto *candidate : amountPanel()->findChildren<QSlider *>()) if (candidate->isVisible()) slider = candidate;
                check(slider && ((!valid || value == "1") ? slider->value() == slider->minimum()
                                                          : slider->value() > slider->minimum()),
                      "Amount typing did not synchronize the visible slider");
            };
            const auto coverage = [&] {
                const QImage before = pixels(); const auto state = window.sessionState();
                command({{"action", "fillForeground"}});
                const QImage result = pixels();
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(pixels() == before && window.sessionState().value("layers") == state.value("layers")
                          && window.sessionState().value("hasSelection") == state.value("hasSelection"),
                      "selection fill proof changed the document or selection after Undo");
                return result;
            };
            const auto rectangle = [&] {
                command({{"action", "new"}, {"width", 64}, {"height", 64}, {"emptyLayer", true}});
                command({{"action", "setShowsTransformControls"}, {"enabled", false}});
                command({{"action", "setPaletteColor"}, {"kind", "foreground"},
                         {"parameters", QJsonObject{{"red", 0}, {"green", 0}, {"blue", 1}}}});
                tool("Marquee", "marquee"); drag(at(20, 20), at(40, 40));
                check(window.sessionState().value("hasSelection").toBool(), "selection rectangle gesture missing");
            };
            for (const QString &operation : {QString("Expand"), QString("Contract")}) {
                rectangle();
                const QImage original = coverage(); const auto before = window.sessionState();
                selectAction(operation + "…");
                pump([&] { return amountPanel() != nullptr; }, "selection amount dialog missing");
                for (const QString &invalid : {QString("0"), QString("501")}) {
                    enterAmount(invalid);
                    check(amountButton("OK") && !amountButton("OK")->isEnabled(), "invalid selection amount did not disable OK");
                }
                enterAmount("1");
                check(amountButton("OK") && amountButton("OK")->isEnabled(), "restoring initial Amount did not enable OK");
                enterAmount("4");
                check(amountButton("OK") && amountButton("OK")->isEnabled(), "valid selection amount did not enable OK");
                click(amountButton("Cancel"));
                pump([&] { return !amountPanel(); }, "selection amount Cancel retained dialog");
                QApplication::setActiveWindow(&window); QApplication::processEvents();
                check(window.sessionState().value("layers") == before.value("layers")
                          && window.sessionState().value("undoName") == before.value("undoName")
                          && coverage() == original, "selection amount Cancel changed coverage, layers or history");
                selectAction(operation + "…"); pump([&] { return amountPanel() != nullptr; }); enterAmount("4");
                click(amountButton("OK"));
                pump([&] { return !amountPanel() && window.sessionState().value("undoName").toString() == operation + " Selection"; },
                     "selection amount OK did not record history");
                QApplication::setActiveWindow(&window); QApplication::processEvents();
                const QImage changed = coverage();
                check(changed.pixelColor(30, 30) == QColor(Qt::blue), "selection amount lost its interior");
                const bool expand = operation == "Expand";
                for (const QPoint &point : {QPoint(18, 30), QPoint(42, 30), QPoint(30, 18), QPoint(30, 42)})
                    check(changed.pixelColor(point).alpha() == (expand ? 255 : 0), "selection amount produced wrong outer coverage");
                check(changed.pixelColor(22, 30).alpha() == (expand ? 255 : 0)
                          && changed.pixelColor(26, 30) == QColor(Qt::blue), "selection amount produced wrong inner coverage");
                QImage empty(64, 64, QImage::Format_RGBA8888); empty.fill(Qt::transparent);
                unchangedOutside(empty, changed, expand ? QRect(16, 16, 28, 28) : QRect(24, 24, 12, 12));
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(coverage() == original, "selection amount Undo lost original coverage");
                // The fill proof consumes Redo; apply the same visible command again to verify its result deterministically.
                selectAction(operation + "…"); pump([&] { return amountPanel() != nullptr; }); enterAmount("4");
                click(amountButton("OK")); pump([&] { return !amountPanel(); });
                QApplication::setActiveWindow(&window); QApplication::processEvents();
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                check(coverage() == changed, "selection amount Redo lost changed coverage");
                qInfo("Qt selection amount OK (%s, invalid 0/501 gates, Amount 4, Cancel/OK, coverage and Undo/Redo)", qPrintable(operation));
            }
            rectangle(); const QImage selected = coverage();
            selectAction("Inverse"); const QImage inverse = coverage();
            for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x)
                check(selected.pixelColor(x, y).alpha() + inverse.pixelColor(x, y).alpha() == 255,
                      "visible Inverse did not complement the rectangular selection");
            key(canvas, Qt::Key_Z, Qt::ControlModifier);
            key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
            check(coverage() == inverse, "selection Inverse Undo/Redo lost its coverage");
            selectAction("All"); const QImage all = coverage();
            for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x)
                check(all.pixelColor(x, y) == QColor(Qt::blue), "visible Select All left pixels unselected");
            selectAction("Inverse");
            check(!window.sessionState().value("hasSelection").toBool(), "Inverse of All did not remove selection as upstream requires");
            key(canvas, Qt::Key_Z, Qt::ControlModifier);
            check(window.sessionState().value("hasSelection").toBool(), "Inverse of All Undo did not restore selection");
            key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
            check(!window.sessionState().value("hasSelection").toBool(), "Inverse of All Redo did not remove selection");
            qInfo("Qt selection All/Inverse OK (visible menus, exact rectangular complement, full coverage, All inverse policy and Undo/Redo)");
        }
        if (app.arguments().contains("--selection-menu-probe")) return 0;

        // Concave lasso outlines distinguish an actual path from its bounding rectangle.
        {
            const auto segment = [&](const QString &title) {
                QPushButton *button = nullptr;
                for (auto *picker : window.findChildren<QWidget *>("segmentedPicker"))
                    for (auto *candidate : picker->findChildren<QPushButton *>())
                        if (candidate->isVisible() && candidate->text() == title) button = candidate;
                click(button);
            };
            const QVector<QPointF> points{{12, 12}, {44, 12}, {44, 24}, {24, 24}, {24, 44}, {12, 44}};
            const auto pointerClick = [&](QPointF point, bool doubleClick = false, Qt::KeyboardModifiers modifiers = Qt::NoModifier) {
                mouse(canvas, doubleClick ? QEvent::MouseButtonDblClick : QEvent::MouseButtonPress,
                      at(point.x(), point.y()), Qt::LeftButton, Qt::LeftButton, modifiers);
                mouse(canvas, QEvent::MouseButtonRelease, at(point.x(), point.y()), Qt::LeftButton, Qt::NoButton, modifiers);
            };
            const auto setup = [&](bool polygonal) {
                command({{"action", "new"}, {"width", 64}, {"height", 64}, {"emptyLayer", true}});
                command({{"action", "setShowsTransformControls"}, {"enabled", false}});
                command({{"action", "setPaletteColor"}, {"kind", "foreground"},
                         {"parameters", QJsonObject{{"red", 0}, {"green", 0}, {"blue", 1}}}});
                tool("Lasso", "lasso"); segment(polygonal ? "Polygonal" : "Freehand"); segment("New");
            };
            for (int finish = 0; finish < 4; ++finish) {
                const bool polygonal = finish > 0;
                setup(polygonal);
                const auto before = window.sessionState(); const QImage empty = pixels();
                if (polygonal) {
                    for (const auto &point : points) pointerClick(point);
                    pointerClick(QPointF(55, 55));
                    key(canvas, Qt::Key_Backspace);
                    check(!window.sessionState().value("hasSelection").toBool() && pixels() == empty
                              && window.sessionState().value("undoName") == before.value("undoName"),
                          "polygonal draft or Backspace changed committed selection/pixels/history");
                    if (finish == 1) pointerClick(points.first());
                    else if (finish == 2) pointerClick(points.last(), true);
                    else key(canvas, Qt::Key_Return);
                } else {
                    canvas->setFocus();
                    mouse(canvas, QEvent::MouseButtonPress, at(12, 12), Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
                    for (int index = 1; index < points.size(); ++index)
                        mouse(canvas, QEvent::MouseMove, at(points[index].x(), points[index].y()), Qt::NoButton, Qt::LeftButton, Qt::NoModifier);
                    mouse(canvas, QEvent::MouseButtonRelease, at(12, 44), Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
                }
                check(window.sessionState().value("hasSelection").toBool() && pixels() == empty
                          && window.sessionState().value("layers") == before.value("layers")
                          && window.sessionState().value("undoName").toString() == (polygonal ? "Polygonal Lasso" : "Lasso"),
                      "native lasso did not commit only its outline as one history step");
                command({{"action", "fillForeground"}}); const QImage filled = pixels();
                for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                    const bool inside = x >= 12 && x < 44 && y >= 12 && y < 44 && (x < 24 || y < 24);
                    check(filled.pixelColor(x, y) == (inside ? QColor(Qt::blue) : QColor(Qt::transparent)),
                          "lasso filled the wrong concave path or its bounding box");
                }
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(pixels() == empty && window.sessionState().value("hasSelection").toBool(), "lasso fill Undo lost its outline");
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(!window.sessionState().value("hasSelection").toBool() && pixels() == empty
                          && window.sessionState().value("layers") == before.value("layers"), "lasso selection Undo changed the document");
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                check(pixels() == filled && window.sessionState().value("hasSelection").toBool(), "lasso selection/fill Redo lost exact coverage");
                qInfo("Qt lasso path OK (%s, visible mode, concave pixels, polygon Backspace, no draft edits, exact selection/fill Undo/Redo)",
                      finish == 0 ? "Freehand release" : finish == 1 ? "Polygonal close on first" : finish == 2 ? "Polygonal double-click" : "Polygonal Return");
            }
            for (bool polygonal : {false, true}) {
                setup(polygonal); const auto before = window.sessionState(); const QImage empty = pixels();
                if (polygonal) { pointerClick(points[0]); pointerClick(points[1]); pointerClick(points[2]); }
                else {
                    mouse(canvas, QEvent::MouseButtonPress, at(12, 12), Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
                    mouse(canvas, QEvent::MouseMove, at(44, 12), Qt::NoButton, Qt::LeftButton, Qt::NoModifier);
                }
                key(canvas, Qt::Key_Escape);
                if (!polygonal) mouse(canvas, QEvent::MouseButtonRelease, at(44, 12), Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
                check(!window.sessionState().value("hasSelection").toBool() && pixels() == empty
                          && window.sessionState().value("layers") == before.value("layers")
                          && window.sessionState().value("undoName") == before.value("undoName"),
                      "lasso Escape committed or changed the document/history");
                qInfo("Qt lasso Escape OK (%s, unchanged selection/pixels/layers/history)", polygonal ? "Polygonal" : "Freehand");
            }
            const auto drawOutline = [&](const QVector<QPointF> &outline, bool polygonal, Qt::KeyboardModifiers modifiers) {
                canvas->setFocus();
                if (polygonal) {
                    for (const auto &point : outline) pointerClick(point, false, modifiers);
                    pointerClick(outline.first(), false, modifiers);
                } else {
                    mouse(canvas, QEvent::MouseButtonPress, at(outline.first().x(), outline.first().y()),
                          Qt::LeftButton, Qt::LeftButton, modifiers);
                    for (int index = 1; index < outline.size(); ++index)
                        mouse(canvas, QEvent::MouseMove, at(outline[index].x(), outline[index].y()), Qt::NoButton, Qt::LeftButton, modifiers);
                    mouse(canvas, QEvent::MouseButtonRelease, at(outline.last().x(), outline.last().y()),
                          Qt::LeftButton, Qt::NoButton, modifiers);
                }
            };
            const auto fillProof = [&] {
                const auto before = window.sessionState(); const QImage empty = pixels();
                command({{"action", "fillForeground"}}); const QImage result = pixels();
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(pixels() == empty && window.sessionState().value("layers") == before.value("layers")
                          && window.sessionState().value("hasSelection").toBool(), "lasso mode fill proof changed source or selection");
                return result;
            };
            const QVector<QPointF> addition{{20, 20}, {52, 20}, {52, 52}, {20, 52}};
            const QVector<QPointF> subtraction{{16, 16}, {36, 16}, {36, 36}, {16, 36}};
            for (bool polygonal : {false, true}) for (bool modifiers : {false, true}) {
                setup(polygonal); drawOutline(points, polygonal, Qt::NoModifier);
                for (bool subtract : {false, true}) {
                    const QImage beforeCoverage = fillProof(); const auto before = window.sessionState();
                    if (!modifiers) segment(subtract ? "Subtract" : "Add");
                    const auto flags = modifiers ? (subtract ? Qt::AltModifier : Qt::ShiftModifier) : Qt::NoModifier;
                    const auto &outline = subtract ? subtraction : addition;
                    drawOutline(outline, polygonal, flags);
                    check(window.sessionState().value("layers") == before.value("layers")
                              && window.sessionState().value("activeLayerID") == before.value("activeLayerID"),
                          "lasso mode changed layer records or target");
                    const QImage changed = fillProof();
                    for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                        const bool first = x >= 12 && x < 44 && y >= 12 && y < 44 && (x < 24 || y < 24);
                        const bool added = x >= 20 && x < 52 && y >= 20 && y < 52;
                        const bool removed = x >= 16 && x < 36 && y >= 16 && y < 36;
                        const bool inside = (first || added) && (!subtract || !removed);
                        check(changed.pixelColor(x, y) == (inside ? QColor(Qt::blue) : QColor(Qt::transparent)),
                              "lasso Add/Subtract did not produce the expected union/difference");
                    }
                    key(canvas, Qt::Key_Z, Qt::ControlModifier);
                    check(fillProof() == beforeCoverage, "lasso mode Undo lost previous coverage");
                    // A reversible fill consumes Redo; repeat the same gesture before checking its Redo coverage.
                    drawOutline(outline, polygonal, flags);
                    key(canvas, Qt::Key_Z, Qt::ControlModifier);
                    key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                    check(fillProof() == changed, "lasso mode Redo lost exact changed coverage");
                }
                qInfo("Qt lasso Add/Subtract OK (%s, %s, all-pixel union/difference, source isolation and exact coverage Undo/Redo)",
                      polygonal ? "Polygonal" : "Freehand", modifiers ? "Shift/Alt pointers" : "visible mode buttons");
            }
        }
        if (app.arguments().contains("--lasso-probe")) return 0;

        {
            const auto segment = [&](const QString &title) {
                QPushButton *button = nullptr;
                for (auto *picker : window.findChildren<QWidget *>("segmentedPicker"))
                    for (auto *candidate : picker->findChildren<QPushButton *>())
                        if (candidate->isVisible() && candidate->text() == title) button = candidate;
                click(button);
            };
            const auto setup = [&](bool ellipse) {
                command({{"action", "new"}, {"width", 64}, {"height", 64}, {"emptyLayer", true}});
                command({{"action", "setShowsTransformControls"}, {"enabled", false}});
                command({{"action", "setPaletteColor"}, {"kind", "foreground"},
                         {"parameters", QJsonObject{{"red", 0}, {"green", 0}, {"blue", 1}}}});
                tool("Marquee", "marquee"); segment(ellipse ? "Ellipse" : "Rectangle"); segment("New");
                if (ellipse) {
                    QCheckBox *antialias = nullptr;
                    for (auto *box : window.findChildren<QCheckBox *>()) if (box->isVisible() && box->text() == "Anti-alias") antialias = box;
                    check(antialias, "visible Ellipse Anti-alias control missing");
                    if (antialias->isChecked()) click(antialias);
                }
            };
            const auto gesture = [&](QPointF from, QPointF to, Qt::KeyboardModifiers press, Qt::KeyboardModifiers move) {
                canvas->setFocus();
                mouse(canvas, QEvent::MouseButtonPress, at(from.x(), from.y()), Qt::LeftButton, Qt::LeftButton, press);
                mouse(canvas, QEvent::MouseMove, at(to.x(), to.y()), Qt::NoButton, Qt::LeftButton, move);
                mouse(canvas, QEvent::MouseMove, at(to.x(), to.y()), Qt::NoButton, Qt::LeftButton, move);
                mouse(canvas, QEvent::MouseButtonRelease, at(to.x(), to.y()), Qt::LeftButton, Qt::NoButton, move);
            };
            const auto coverage = [&] {
                const auto before = window.sessionState(); const QImage empty = pixels();
                command({{"action", "fillForeground"}}); const QImage result = pixels();
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(pixels() == empty && window.sessionState().value("layers") == before.value("layers")
                          && window.sessionState().value("activeLayerID") == before.value("activeLayerID"),
                      "marquee fill proof changed source records or target");
                return result;
            };
            // Hard scan conversion differs at the curve: compare interior/exterior outside a one-pixel boundary band.
            const auto contains = [&](bool ellipse, const QRect &box, int x, int y) {
                if (!ellipse) return box.contains(x, y) ? 1 : 0;
                const double dx = (x + 0.5 - box.x() - box.width() / 2.0) / (box.width() / 2.0);
                const double dy = (y + 0.5 - box.y() - box.height() / 2.0) / (box.height() / 2.0);
                const double value = dx * dx + dy * dy;
                const double distance = (std::sqrt(value) - 1) * std::min(box.width(), box.height()) / 2.0;
                return distance < -1 ? 1 : distance > 1 ? 0 : -1;
            };
            for (bool ellipse : {false, true}) for (int modifier = 0; modifier < 3; ++modifier) {
                setup(ellipse); const auto before = window.sessionState();
                gesture(QPointF(20, 20), QPointF(44, 36), Qt::NoModifier,
                        modifier == 1 ? Qt::ShiftModifier : modifier == 2 ? Qt::AltModifier : Qt::NoModifier);
                const QImage result = coverage();
                const QRect box(20, 20, 24, modifier == 1 ? 24 : 16);
                for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                    const int expected = contains(ellipse, box, x, y);
                    const int alpha = result.pixelColor(x, y).alpha();
                    check(alpha == 0 || alpha == 255, "non-antialiased marquee left partial coverage");
                    if (!box.contains(x, y)) check(alpha == 0, "marquee changed pixels outside its exact bounding rectangle");
                    if (expected >= 0) {
                        const QColor color = expected ? QColor(Qt::blue) : QColor(Qt::transparent);
                        if (result.pixelColor(x, y) != color)
                            qWarning() << "marquee mismatch" << ellipse << modifier << x << y << "expected" << color << "actual" << result.pixelColor(x, y);
                        check(result.pixelColor(x, y) == color, "marquee shape or captured modifier geometry is incorrect");
                    }
                }
                check(result.pixelColor(32, 28) == QColor(Qt::blue), "marquee interior missing");
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(!window.sessionState().value("hasSelection").toBool()
                          && window.sessionState().value("layers") == before.value("layers"), "marquee Undo changed layers or retained selection");
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                check(coverage() == result, "marquee Redo lost exact coverage");
                qInfo("Qt marquee gesture OK (%s, %s, visible shape/Anti-alias, curve interior/exterior, exact coverage Undo/Redo)",
                      ellipse ? "Ellipse" : "Rectangle", modifier == 0 ? "ordinary" : modifier == 1 ? "fresh Shift square/circle" : "late Alt keeps anchor/New");
            }
            const QRect base(12, 12, 32, 24), addition(20, 20, 32, 24), subtraction(16, 16, 20, 16);
            for (bool ellipse : {false, true}) for (bool modifiers : {false, true}) {
                setup(ellipse);
                gesture(base.topLeft(), QPointF(base.x() + base.width(), base.y() + base.height()), Qt::NoModifier, Qt::NoModifier);
                for (bool subtract : {false, true}) {
                    const QImage original = coverage();
                    if (!modifiers) segment(subtract ? "Subtract" : "Add");
                    const auto flags = modifiers ? (subtract ? Qt::AltModifier : Qt::ShiftModifier) : Qt::NoModifier;
                    const QRect &box = subtract ? subtraction : addition;
                    const auto draw = [&] { gesture(box.topLeft(), QPointF(box.x() + box.width(), box.y() + box.height()), flags, flags); };
                    draw(); const QImage changed = coverage();
                    for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                        const int a = contains(ellipse, base, x, y), b = contains(ellipse, addition, x, y), c = contains(ellipse, subtraction, x, y);
                        check(changed.pixelColor(x, y).alpha() == 0 || changed.pixelColor(x, y).alpha() == 255,
                              "marquee combination left partial coverage with Anti-alias off");
                        if (a < 0 || b < 0 || (subtract && c < 0)) continue;
                        const bool inside = (a || b) && (!subtract || !c);
                        const QColor expected = inside ? QColor(Qt::blue) : QColor(Qt::transparent);
                        if (changed.pixelColor(x, y) != expected)
                            qWarning() << "marquee mode mismatch" << ellipse << modifiers << subtract << x << y
                                       << "membership" << a << b << c << "expected" << expected << "actual" << changed.pixelColor(x, y)
                                       << "mode" << window.sessionState().value("selectionMode");
                        check(changed.pixelColor(x, y) == expected,
                              "marquee Add/Subtract produced the wrong union/difference or squared a held-Shift gesture");
                    }
                    key(canvas, Qt::Key_Z, Qt::ControlModifier);
                    check(coverage() == original, "marquee mode Undo lost original coverage");
                    draw(); key(canvas, Qt::Key_Z, Qt::ControlModifier);
                    key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                    check(coverage() == changed, "marquee mode Redo lost exact changed coverage");
                }
                qInfo("Qt marquee Add/Subtract OK (%s, %s, union/difference, unchanged source/target and exact coverage Undo/Redo)",
                      ellipse ? "Ellipse" : "Rectangle", modifiers ? "Shift/Alt press" : "visible mode buttons");
            }
            for (auto *box : window.findChildren<QCheckBox *>()) if (box->isVisible() && box->text() == "Anti-alias" && !box->isChecked()) { click(box); break; }
            segment("Rectangle"); segment("New");
        }
        if (app.arguments().contains("--marquee-probe")) return 0;

        for (int repetition = 0; repetition < (app.arguments().contains("--wand-repeat") ? 6 : 1); ++repetition) {
            qInfo("Qt Wand repetition %d", repetition + 1);
            QImage source(64, 64, QImage::Format_RGBA8888); source.fill(QColor(20, 40, 220));
            const QRect left(8, 16, 16, 24), right(40, 16, 16, 24), near(24, 16, 8, 24);
            for (int y = 16; y < 40; ++y) for (int x = 8; x < 56; ++x) {
                if (left.contains(x, y) || right.contains(x, y)) source.setPixelColor(x, y, QColor(180, 40, 40));
                else if (near.contains(x, y)) source.setPixelColor(x, y, QColor(200, 40, 40));
            }
            const QString path = temporary.filePath("wand-colors.png");
            check(source.save(path), "wand fixture save failed");
            const auto segment = [&](const QString &title) {
                QPushButton *button = nullptr;
                for (auto *picker : window.findChildren<QWidget *>("segmentedPicker"))
                    for (auto *candidate : picker->findChildren<QPushButton *>())
                        if (candidate->isVisible() && candidate->text() == title) button = candidate;
                click(button);
            };
            for (bool allLayers : {false, true}) for (bool contiguous : {false, true}) for (int tolerance : {0, 24}) {
                check(window.importImage(path), "wand fixture import failed");
                command({{"action", "setShowsTransformControls"}, {"enabled", false}});
                if (allLayers) command({{"action", "addLayer"}});
                tool("Magic", "wand"); segment("Wand"); segment("New");
                segment(allLayers ? "All Layers" : "This Layer");
                QCheckBox *connected = nullptr, *antialias = nullptr;
                QComboBox *sample = nullptr;
                QLineEdit *amount = nullptr;
                for (auto *box : window.findChildren<QCheckBox *>()) if (box->isVisible()) {
                    if (box->text() == "Contiguous") connected = box;
                    if (box->text() == "Anti-alias") antialias = box;
                }
                for (auto *combo : window.findChildren<QComboBox *>())
                    if (combo->isVisible() && combo->findText("Point Sample") >= 0) sample = combo;
                for (auto *field : window.findChildren<QLineEdit *>())
                    if (field->isVisible() && field->placeholderText() == "Tolerance") amount = field;
                check(connected && antialias && sample && amount, "visible Wand controls missing");
                if (connected->isChecked() != contiguous) click(connected);
                // Controls can be rebuilt after each setting; find numeric fields again rather than retaining stale widgets.
                antialias = nullptr; sample = nullptr; amount = nullptr;
                for (auto *box : window.findChildren<QCheckBox *>())
                    if (box->isVisible() && box->text() == "Anti-alias") antialias = box;
                check(antialias, "Wand Anti-alias control missing after Contiguous change");
                if (antialias->isChecked()) click(antialias);
                for (auto *combo : window.findChildren<QComboBox *>())
                    if (combo->isVisible() && combo->findText("Point Sample") >= 0) sample = combo;
                check(sample, "Wand sample-size control missing"); key(sample, Qt::Key_Home);
                for (auto *field : window.findChildren<QLineEdit *>())
                    if (field->isVisible() && field->placeholderText() == "Tolerance") amount = field;
                check(amount, "Wand Tolerance control missing");
                amount->setFocus(); amount->selectAll(); amount->insert(QString::number(tolerance)); key(amount, Qt::Key_Return);
                command({{"action", "setPaletteColor"}, {"kind", "foreground"},
                         {"parameters", QJsonObject{{"red", 0}, {"green", 1}, {"blue", 0}}}});
                const auto before = window.sessionState();
                check(pixels() == source && before.value("layers").toArray().size() == (allLayers ? 2 : 1),
                      "Wand settings changed source or blank destination");
                canvas->setFocus();
                mouse(canvas, QEvent::MouseButtonPress, at(16.5, 24.5), Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
                mouse(canvas, QEvent::MouseButtonRelease, at(16.5, 24.5), Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
                pump([&] { return !window.sessionState().value("busy").toBool()
                                  && window.sessionState().value("undoName").toString() == "Magic Wand"; }, "Wand click did not finish selection");
                check(pixels() == source && window.sessionState().value("layers") == before.value("layers")
                          && window.sessionState().value("hasSelection").toBool(), "Wand click edited pixels instead of only selecting");
                command({{"action", "fillForeground"}}); const QImage painted = pixels();
                for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                    const bool selected = left.contains(x, y) || (!contiguous && right.contains(x, y)) || (tolerance == 24 && near.contains(x, y));
                    check(painted.pixelColor(x, y) == (selected ? QColor(Qt::green) : source.pixelColor(x, y)),
                          "Wand tolerance/contiguous/sampling controls selected the wrong pixels");
                }
                check(window.sessionState().value("activeLayerID") == before.value("activeLayerID"), "Wand fill changed target layer");
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(pixels() == source && window.sessionState().value("hasSelection").toBool(), "Wand fill Undo lost source or selection");
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(!window.sessionState().value("hasSelection").toBool()
                          && window.sessionState().value("layers") == before.value("layers"), "Wand selection Undo changed source records");
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                check(pixels() == painted && window.sessionState().value("hasSelection").toBool(), "Wand Redo lost exact selection/fill pixels");
                qInfo("Qt Wand controls OK (%s, contiguous=%d, tolerance=%d, visible Point Sample/Anti-alias, exact selection/fill and Undo/Redo)",
                      allLayers ? "All Layers into blank target" : "This Layer", contiguous, tolerance);
            }
            for (bool modifiers : {false, true}) {
                check(window.importImage(path), "Wand mode fixture import failed");
                command({{"action", "setShowsTransformControls"}, {"enabled", false}});
                tool("Marquee", "marquee"); segment("Rectangle"); segment("New"); drag(at(8, 16), at(24, 40));
                tool("Magic", "wand"); segment("Wand"); segment("New"); segment("This Layer");
                for (const auto &title : {QString("Contiguous"), QString("Anti-alias")}) {
                    QCheckBox *box = nullptr;
                    for (auto *candidate : window.findChildren<QCheckBox *>())
                        if (candidate->isVisible() && candidate->text() == title) box = candidate;
                    check(box, "Wand mode checkbox missing");
                    if (box->isChecked() != (title == "Contiguous")) click(box);
                }
                QComboBox *sample = nullptr;
                for (auto *combo : window.findChildren<QComboBox *>())
                    if (combo->isVisible() && combo->findText("Point Sample") >= 0) sample = combo;
                check(sample, "Wand mode sample-size control missing"); key(sample, Qt::Key_Home);
                QLineEdit *amount = nullptr;
                for (auto *field : window.findChildren<QLineEdit *>())
                    if (field->isVisible() && field->placeholderText() == "Tolerance") amount = field;
                check(amount, "Wand mode Tolerance control missing");
                amount->setFocus(); amount->selectAll(); amount->insert("0"); key(amount, Qt::Key_Return);
                command({{"action", "setPaletteColor"}, {"kind", "foreground"},
                         {"parameters", QJsonObject{{"red", 0}, {"green", 1}, {"blue", 0}}}});
                for (bool subtract : {false, true}) {
                    if (!modifiers) segment(subtract ? "Subtract" : "Add");
                    // A fixture rename provides a distinct history marker so an asynchronous Wand cannot look finished early.
                    command({{"action", "renameLayer"}, {"name", subtract ? "Wand subtraction target" : "Wand addition target"}});
                    const auto before = window.sessionState();
                    const auto clickWand = [&] {
                        const auto flags = modifiers ? (subtract ? Qt::AltModifier : Qt::ShiftModifier) : Qt::NoModifier;
                        const QPointF point = subtract ? at(16.5, 24.5) : at(48.5, 24.5);
                        canvas->setFocus();
                        mouse(canvas, QEvent::MouseButtonPress, point, Qt::LeftButton, Qt::LeftButton, flags);
                        mouse(canvas, QEvent::MouseButtonRelease, point, Qt::LeftButton, Qt::NoButton, flags);
                        pump([&] { return !window.sessionState().value("busy").toBool()
                                          && window.sessionState().value("undoName").toString() == "Magic Wand"; },
                             "Wand mode click did not finish asynchronously");
                    };
                    const auto proof = [&] {
                        command({{"action", "fillForeground"}}); const QImage result = pixels();
                        key(canvas, Qt::Key_Z, Qt::ControlModifier);
                        check(pixels() == source && window.sessionState().value("layers") == before.value("layers"),
                              "Wand mode fill proof changed source records or pixels");
                        return result;
                    };
                    clickWand();
                    check(pixels() == source && window.sessionState().value("layers") == before.value("layers")
                              && window.sessionState().value("activeLayerID") == before.value("activeLayerID"),
                          "Wand mode click changed source or target");
                    const QImage changed = proof();
                    for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                        const bool selected = right.contains(x, y) || (!subtract && left.contains(x, y));
                        check(changed.pixelColor(x, y) == (selected ? QColor(Qt::green) : source.pixelColor(x, y)),
                              "Wand Add/Subtract produced the wrong disconnected union/difference");
                    }
                    key(canvas, Qt::Key_Z, Qt::ControlModifier);
                    const QImage previous = proof();
                    for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                        const bool selected = left.contains(x, y) || (subtract && right.contains(x, y));
                        check(previous.pixelColor(x, y) == (selected ? QColor(Qt::green) : source.pixelColor(x, y)),
                              "Wand mode Undo lost previous selection coverage");
                    }
                    clickWand(); key(canvas, Qt::Key_Z, Qt::ControlModifier);
                    key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                    check(proof() == changed, "Wand mode Redo lost exact coverage");
                }
                qInfo("Qt Wand Add/Subtract OK (%s, disconnected union/difference, asynchronous completion, source/target and coverage Undo/Redo)",
                      modifiers ? "Shift/Alt pointers" : "visible mode buttons");
            }
            QImage dot(64, 64, QImage::Format_RGBA8888); dot.fill(Qt::black); dot.setPixelColor(32, 32, Qt::white);
            const QString dotPath = temporary.filePath("wand-sample-dot.png");
            check(dot.save(dotPath), "Wand averaging fixture save failed");
            for (int size = 0; size < 3; ++size) {
                check(window.importImage(dotPath), "Wand averaging fixture import failed");
                command({{"action", "setShowsTransformControls"}, {"enabled", false}});
                tool("Marquee", "marquee"); segment("Rectangle"); segment("New"); drag(at(4, 4), at(8, 8));
                tool("Magic", "wand"); segment("Wand"); segment("New"); segment("This Layer");
                QCheckBox *connected = nullptr;
                for (auto *box : window.findChildren<QCheckBox *>())
                    if (box->isVisible() && box->text() == "Contiguous") connected = box;
                check(connected, "Wand averaging Contiguous control missing");
                if (connected->isChecked()) click(connected);
                QComboBox *sample = nullptr;
                for (auto *combo : window.findChildren<QComboBox *>())
                    if (combo->isVisible() && combo->findText("Point Sample") >= 0) sample = combo;
                check(sample, "Wand averaging sample-size control missing");
                key(sample, Qt::Key_Home);
                for (int step = 0; step < size; ++step) {
                    sample = nullptr;
                    for (auto *combo : window.findChildren<QComboBox *>())
                        if (combo->isVisible() && combo->findText("Point Sample") >= 0) sample = combo;
                    check(sample, "Wand sample-size control lost during keyboard choice"); key(sample, Qt::Key_Down);
                }
                QLineEdit *amount = nullptr;
                for (auto *field : window.findChildren<QLineEdit *>())
                    if (field->isVisible() && field->placeholderText() == "Tolerance") amount = field;
                check(amount, "Wand averaging Tolerance control missing");
                amount->setFocus(); amount->selectAll(); amount->insert("15"); key(amount, Qt::Key_Return);
                command({{"action", "setPaletteColor"}, {"kind", "foreground"},
                         {"parameters", QJsonObject{{"red", 0}, {"green", 1}, {"blue", 0}}}});
                const auto before = window.sessionState();
                canvas->setFocus();
                mouse(canvas, QEvent::MouseButtonPress, at(32.5, 32.5), Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
                mouse(canvas, QEvent::MouseButtonRelease, at(32.5, 32.5), Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
                pump([&] { return !window.sessionState().value("busy").toBool()
                                  && window.sessionState().value("undoName").toString() == (size == 1 ? "Deselect" : "Magic Wand"); },
                     "Wand averaging click did not finish");
                check(pixels() == dot && window.sessionState().value("layers") == before.value("layers"),
                      "Wand averaging selection changed source pixels or records");
                if (size == 1) {
                    check(!window.sessionState().value("hasSelection").toBool(), "3 by 3 mean unexpectedly matched at tolerance 15");
                    key(canvas, Qt::Key_Z, Qt::ControlModifier);
                    check(window.sessionState().value("hasSelection").toBool() && pixels() == dot, "Wand no-match Undo lost old selection/source");
                    key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                    check(!window.sessionState().value("hasSelection").toBool() && pixels() == dot, "Wand no-match Redo failed");
                } else {
                    command({{"action", "fillForeground"}}); const QImage filled = pixels();
                    for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                        const bool center = x == 32 && y == 32, selected = size == 0 ? center : !center;
                        check(filled.pixelColor(x, y) == (selected ? QColor(Qt::green) : dot.pixelColor(x, y)),
                              "Wand sample averaging did not select the expected pixels");
                    }
                    key(canvas, Qt::Key_Z, Qt::ControlModifier); key(canvas, Qt::Key_Z, Qt::ControlModifier);
                    check(pixels() == dot && window.sessionState().value("hasSelection").toBool(), "Wand averaging Undo lost source/old selection");
                    key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                    key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                    check(pixels() == filled, "Wand averaging Redo lost exact pixels");
                }
                qInfo("Qt Wand sample size OK (%s, visible keyboard choice, tolerance 15, distinct expected match/no-match and Undo/Redo)",
                      size == 0 ? "Point Sample" : size == 1 ? "3 by 3 Average" : "5 by 5 Average");
            }
            QComboBox *sample = nullptr;
            for (auto *combo : window.findChildren<QComboBox *>())
                if (combo->isVisible() && combo->findText("Point Sample") >= 0) sample = combo;
            check(sample, "Wand sample-size restoration control missing"); key(sample, Qt::Key_Home);
            QCheckBox *connected = nullptr;
            for (auto *box : window.findChildren<QCheckBox *>())
                if (box->isVisible() && box->text() == "Contiguous") connected = box;
            check(connected, "Wand Contiguous restoration control missing");
            if (!connected->isChecked()) click(connected);
            segment("This Layer");
            QCheckBox *antialias = nullptr;
            for (auto *box : window.findChildren<QCheckBox *>())
                if (box->isVisible() && box->text() == "Anti-alias") antialias = box;
            check(antialias, "Wand Anti-alias restoration control missing");
            if (!antialias->isChecked()) click(antialias);
            QLineEdit *amount = nullptr;
            for (auto *field : window.findChildren<QLineEdit *>())
                if (field->isVisible() && field->placeholderText() == "Tolerance") amount = field;
            check(amount, "Wand Tolerance restoration control missing");
            amount->setFocus(); amount->selectAll(); amount->insert("32"); key(amount, Qt::Key_Return);
        }
        if (app.arguments().contains("--wand-probe")) return 0;

        {
            QImage source(64, 64, QImage::Format_RGBA8888); source.fill(Qt::transparent);
            for (int y = 8; y < 24; ++y) for (int x = 8; x < 56; ++x) {
                if (x < 24) source.setPixelColor(x, y, QColor(64, 128, 192));
                if (x >= 40) source.setPixelColor(x, y, QColor(200, 80, 40, 128));
            }
            const QString path = temporary.filePath("eyedropper-colors.png");
            check(source.save(path), "eyedropper fixture save failed");
            const auto colorMatches = [&](const QColor &color) {
                const auto value = window.sessionState().value("foregroundColor").toArray();
                check(value.size() == 3 && std::abs(value[0].toDouble() - color.redF()) <= 2.0 / 255
                          && std::abs(value[1].toDouble() - color.greenF()) <= 2.0 / 255
                          && std::abs(value[2].toDouble() - color.blueF()) <= 2.0 / 255,
                      "eyedropper did not sample unpremultiplied composite RGB");
            };
            for (bool temporary : {false, true}) {
                check(window.importImage(path), "eyedropper fixture import failed");
                command({{"action", "setShowsTransformControls"}, {"enabled", false}});
                command({{"action", "setPaletteColor"}, {"kind", "foreground"},
                         {"parameters", QJsonObject{{"red", 0.05}, {"green", 0.1}, {"blue", 0.15}}}});
                tool(temporary ? "Brush" : "Eyedropper", temporary ? "brush" : "eyedropper");
                const auto before = window.sessionState(); const QImage original = pixels();
                const auto flags = temporary ? Qt::AltModifier : Qt::NoModifier;
                canvas->setFocus();
                mouse(canvas, QEvent::MouseButtonPress, at(16.5, 16.5), Qt::LeftButton, Qt::LeftButton, flags);
                colorMatches(original.pixelColor(16, 16));
                mouse(canvas, QEvent::MouseMove, at(48.5, 16.5), Qt::NoButton, Qt::LeftButton, flags);
                colorMatches(original.pixelColor(48, 16));
                mouse(canvas, QEvent::MouseButtonRelease, at(48.5, 16.5), Qt::LeftButton, Qt::NoButton, flags);
                const auto sampled = window.sessionState().value("foregroundColor");
                for (const auto &point : {QPointF(32.5, 32.5), QPointF(70, 16)}) {
                    mouse(canvas, QEvent::MouseButtonPress, at(point.x(), point.y()), Qt::LeftButton, Qt::LeftButton, flags);
                    mouse(canvas, QEvent::MouseButtonRelease, at(point.x(), point.y()), Qt::LeftButton, Qt::NoButton, flags);
                    check(window.sessionState().value("foregroundColor") == sampled,
                          "transparent/outside eyedropper sample changed the palette");
                }
                check(pixels() == original, "eyedropper or temporary Brush sampling painted pixels");
                const auto after = window.sessionState();
                for (const char *field : {"layers", "activeLayerID", "backgroundColor", "modified", "canUndo", "canRedo", "undoName", "redoName"})
                    check(after.value(field) == before.value(field), "eyedropper changed background palette, document or history");
                check(after.value("tool").toString() == (temporary ? "brush" : "eyedropper"),
                      "temporary eyedropper changed the selected tool");
                qInfo("Qt eyedropper OK (%s, opaque/half-alpha RGB, drag sampling, transparent/outside refusal, unchanged pixels/layers/background/history)",
                      temporary ? "Alt Brush" : "visible Eyedropper tool");
            }
        }
        if (app.arguments().contains("--eyedropper-probe")) return 0;

        // Visible menu transforms use layer/canvas centers; Invert preserves alpha and selection clipping.
        {
            QImage image(32, 24, QImage::Format_RGBA8888);
            for (int y = 0; y < 24; ++y) for (int x = 0; x < 32; ++x)
                image.setPixelColor(x, y, QColor(20 + x * 5, 30 + y * 7, 40 + (x + y) * 3, x % 2 ? 128 : 255));
            const QString path = temporary.filePath("flip-invert.png");
            check(image.save(path), "flip/invert fixture save failed");
            const auto fresh = [&] {
                check(window.importImage(path), "flip/invert fixture import failed");
                command({{"action", "resizeCanvas"}, {"width", 64}, {"height", 64},
                         {"parameters", QJsonObject{{"anchor", 0}}}});
                command({{"action", "setShowsTransformControls"}, {"enabled", false}});
                command({{"action", "deselect"}});
                tool("Move", "move");
            };
            const auto menuAction = [&](const QString &name, const QString &title) {
                QMenu *menu = nullptr;
                for (auto *action : window.menuBar()->actions()) if (action->text().remove('&') == name) menu = action->menu();
                check(menu, "flip/invert menu missing");
                menu->popup(window.mapToGlobal(QPoint(200, 50))); QApplication::processEvents();
                QAction *chosen = nullptr;
                for (auto *action : menu->actions()) if (action->text().remove('&') == title) chosen = action;
                check(menu->isVisible() && chosen && chosen->isEnabled(), "flip/invert menu action unavailable");
                chosen->trigger(); menu->hide(); QApplication::processEvents();
            };
            for (bool canvasFlip : {false, true}) for (bool horizontal : {true, false}) {
                fresh();
                const auto beforeState = window.sessionState();
                const QImage before = pixels();
                const auto layer = beforeState.value("layers").toArray().first().toObject();
                const auto size = layer.value("transform").toObject().value("size").toArray();
                const auto origin = layer.value("transform").toObject().value("origin").toArray();
                check(size == QJsonArray({32, 24}) && origin == QJsonArray({0, 0}), "flip fixture layer geometry mismatch");
                QImage expected = before;
                if (canvasFlip) expected = before.mirrored(horizontal, !horizontal);
                else for (int y = 0; y < 24; ++y) for (int x = 0; x < 32; ++x)
                    expected.setPixelColor(x, y, before.pixelColor(horizontal ? 31 - x : x, horizontal ? y : 23 - y));
                const QString title = QString("Flip %1 %2").arg(canvasFlip ? "Canvas" : "Layer", horizontal ? "Horizontal" : "Vertical");
                menuAction(canvasFlip ? "Image" : "Layer", title);
                pump([&] { return pixels() == expected; }, "visible flip did not produce the exact mirror");
                const auto after = window.sessionState();
                check(after.value("activeLayerID") == beforeState.value("activeLayerID")
                          && after.value("layers").toArray().size() == 1 && after.value("width").toInt() == 64
                          && after.value("height").toInt() == 64, "flip changed layer identity/count or canvas dimensions");
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(pixels() == before && window.sessionState().value("layers") == beforeState.value("layers"), "flip Undo lost exact pixels/geometry");
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                check(pixels() == expected && window.sessionState().value("layers") == after.value("layers"), "flip Redo lost exact pixels/geometry");
                qInfo("Qt visible flip OK (%s, distinct layer/canvas centers, exact pixels/geometry, identity and Undo/Redo)", qPrintable(title));
            }
            for (bool selected : {false, true}) {
                fresh();
                const QRect region(8, 6, 16, 12);
                if (selected) { tool("Marquee", "marquee"); drag(at(8, 6), at(24, 18)); }
                const auto state = window.sessionState();
                const QImage before = pixels();
                menuAction("Image", "Invert");
                pump([&] { return !window.sessionState().value("busy").toBool()
                                      && window.sessionState().value("undoName").toString() == "Invert"; }, "visible Invert did not complete");
                const QImage after = pixels();
                check(after != before, "visible Invert did not change pixels");
                for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                    const QColor a = before.pixelColor(x, y), b = after.pixelColor(x, y);
                    if ((selected && !region.contains(x, y)) || a.alpha() == 0) {
                        check(a == b, "Invert changed outside-selection or transparent pixels"); continue;
                    }
                    check(b.alpha() == a.alpha() && qAbs(b.red() - (255 - a.red())) <= 2
                              && qAbs(b.green() - (255 - a.green())) <= 2 && qAbs(b.blue() - (255 - a.blue())) <= 2,
                          "Invert lost alpha or expected channel complement");
                }
                check(window.sessionState().value("layers") == state.value("layers")
                          && window.sessionState().value("hasSelection") == state.value("hasSelection"), "Invert changed geometry, identity or selection");
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(pixels() == before, "Invert Undo lost exact source pixels");
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                check(pixels() == after && window.sessionState().value("hasSelection") == state.value("hasSelection"), "Invert Redo lost exact pixels/selection");
                qInfo("Qt visible Invert OK (%s, channel complements, exact outside pixels, alpha/identity/selection and Undo/Redo)", selected ? "selected" : "whole layer");
            }
        }

        // Pixel Grid is display chrome: its threshold and hairlines never change stored pixels/history.
        {
            reset(); tool("Move", "move");
            const auto baseline = window.sessionState();
            const QImage stored = pixels();
            const bool initialGrid = baseline.value("showsPixelGrid").toBool();
            const auto grid = [&](bool enabled) {
                QMenu *view = nullptr;
                for (auto *action : window.menuBar()->actions()) if (action->text().remove('&') == "View") view = action->menu();
                check(view, "pixel-grid View menu missing");
                view->popup(window.mapToGlobal(QPoint(200, 50))); QApplication::processEvents();
                QAction *chosen = nullptr;
                for (auto *action : view->actions())
                    if (action->text().remove('&') == "Pixel Grid (800% and above)") chosen = action;
                check(chosen && chosen->isCheckable() && chosen->isEnabled(), "pixel-grid toggle missing");
                check(chosen->isChecked() == window.sessionState().value("showsPixelGrid").toBool(), "pixel-grid menu checkmark disagrees with model");
                if (chosen->isChecked() != enabled) chosen->trigger();
                view->hide(); QApplication::processEvents();
                pump([&] { return window.sessionState().value("showsPixelGrid").toBool() == enabled; }, "pixel-grid toggle did not reach model");
            };
            const auto zoom = [&](int percent) {
                tool("Zoom", "zoom");
                QLineEdit *field = nullptr;
                for (auto *candidate : window.findChildren<QLineEdit *>())
                    if (candidate->isVisible() && candidate->placeholderText() == "Zoom") field = candidate;
                check(field && field->isEnabled(), "pixel-grid Zoom field missing");
                field->setFocus(); field->selectAll(); field->insert(QString::number(percent));
                key(field, Qt::Key_Return);
                pump([&] { return qAbs(window.sessionState().value("zoom").toDouble() - percent / 100.0) < 0.0001; },
                     "pixel-grid Zoom field did not apply percent");
                tool("Move", "move");
            };
            const auto frame = [&] { return canvas->grab().toImage().convertToFormat(QImage::Format_RGBA8888); };
            for (int percent : {799, 800, 1600}) {
                zoom(percent); grid(false); const QImage off = frame();
                grid(true); const QImage on = frame();
                check(on.size() == off.size(), "pixel-grid display dimensions changed");
                if (percent < 800) {
                    check(on == off, "pixel grid appeared below 800 percent");
                } else {
                    const double dpr = canvas->devicePixelRatioF();
                    const QPointF origin = at(0, 0) * dpr;
                    const double step = (at(21, 20).x() - at(20, 20).x()) * dpr;
                    const QRect inside((at(17, 17) * dpr).toPoint(), (at(30, 30) * dpr).toPoint());
                    check(step >= 8 && off.rect().contains(inside), "pixel-grid interior fixture outside viewport");
                    int changed = 0;
                    for (int y = inside.top(); y <= inside.bottom(); ++y) for (int x = inside.left(); x <= inside.right(); ++x) {
                        if (off.pixelColor(x, y) == on.pixelColor(x, y)) continue;
                        ++changed;
                        const double column = (x + 0.5 - origin.x()) / step, row = (y + 0.5 - origin.y()) / step;
                        check(qMin(qAbs(column - std::round(column)), qAbs(row - std::round(row))) * step <= 1.5,
                              "pixel-grid changed pixels away from a document pixel boundary");
                    }
                    check(changed > 100, "pixel-grid toggle did not draw visible hairlines");
                    const QPoint center = (at(20.5, 20.5) * dpr).toPoint();
                    check(on.pixelColor(center) == off.pixelColor(center), "pixel-grid changed a pixel-cell center");
                    const QRect document((at(0, 0) * dpr).toPoint(), (at(64, 64) * dpr).toPoint());
                    for (int y = 0; y < off.height(); ++y) for (int x = 0; x < off.width(); ++x)
                        if (!document.adjusted(-1, -1, 1, 1).contains(x, y))
                            check(on.pixelColor(x, y) == off.pixelColor(x, y), "pixel-grid changed the canvas surround");
                }
                grid(false); check(frame() == off, "pixel-grid Off did not restore the exact canvas frame");
                check(pixels() == stored && window.sessionState().value("layers") == baseline.value("layers")
                          && window.sessionState().value("undoName") == baseline.value("undoName"),
                      "pixel-grid display controls changed the document or history");
            }
            grid(initialGrid); click(window.findChild<QPushButton *>("actualPixels"));
            qInfo("Qt pixel grid OK (visible menu/Zoom field, 799/800/1600 percent, boundary hairlines, cell/surround isolation, exact Off and document/history)");
        }

        // Edit the actual upstream shortcut recorder, then exercise the saved binding on the canvas.
        {
            reset(); tool("Move", "move");
            const auto baseline = window.sessionState();
            const QImage original = pixels();
            const auto brushKey = [&] {
                for (const auto &entry : window.sessionState().value("shortcuts").toArray())
                    if (entry.toObject().value("title").toString() == "Brush tool") return entry.toObject().value("key").toString();
                return QString();
            };
            check(brushKey() == "b", "shortcut fixture requires default Brush binding");
            for (const auto &entry : baseline.value("shortcuts").toArray()) {
                const auto shortcut = entry.toObject();
                check(shortcut.value("key") == shortcut.value("originalKey")
                          && shortcut.value("modifiers") == shortcut.value("originalModifiers"),
                      "Restore Defaults fixture requires original bindings");
            }
            const auto panel = [&]() -> QDialog * {
                for (auto *top : QApplication::topLevelWidgets())
                    if (auto *dialog = qobject_cast<QDialog *>(top); dialog && dialog->isVisible()
                        && dialog->objectName() == "floatingPanel.KeyboardShortcutsSheet") return dialog;
                return nullptr;
            };
            const auto button = [&](const QString &title) -> QPushButton * {
                if (panel()) for (auto *candidate : panel()->findChildren<QPushButton *>())
                    if (candidate->isVisible() && candidate->text() == title) return candidate;
                return nullptr;
            };
            const auto open = [&] {
                QMenu *edit = nullptr;
                for (auto *action : window.menuBar()->actions())
                    if (action->text().remove('&') == "Edit") edit = action->menu();
                check(edit, "shortcut Edit menu missing");
                edit->popup(window.mapToGlobal(QPoint(200, 50))); QApplication::processEvents();
                QAction *chosen = nullptr;
                for (auto *action : edit->actions())
                    if (action->text().remove('&') == QString::fromUtf8("Keyboard Shortcuts…")) chosen = action;
                check(chosen && chosen->isEnabled(), "shortcut window menu entry missing");
                chosen->trigger(); edit->hide(); QApplication::processEvents();
                pump([&] { return panel() != nullptr; }, "shortcut window did not open");
                QLineEdit *search = nullptr;
                for (auto *candidate : panel()->findChildren<QLineEdit *>())
                    if (candidate->placeholderText() == "Search shortcuts") search = candidate;
                check(search && search->isVisible(), "shortcut search field missing");
                search->setFocus(); search->setText("Brush tool"); QApplication::processEvents();
                pump([&] {
                    int count = 0;
                    if (panel()) for (auto *candidate : panel()->findChildren<QPushButton *>()) if (candidate->isVisible()) ++count;
                    return count == 4;
                }, "shortcut search did not filter while focused");
                const auto focusedSearch = [&]() -> QLineEdit * {
                    auto *field = qobject_cast<QLineEdit *>(QApplication::focusWidget());
                    return field && panel()->isAncestorOf(field) && field->placeholderText() == "Search shortcuts" ? field : nullptr;
                };
                pump([&] { return focusedSearch() != nullptr; }, "shortcut search lost focus after filtering");
                focusedSearch()->setCursorPosition(3);
                QTest::sendKeyEvent(QTest::Click, panel()->windowHandle(), Qt::Key_Backspace, QString(), Qt::NoModifier);
                pump([&] { return focusedSearch() && focusedSearch()->text() == "Brsh tool"
                                      && focusedSearch()->cursorPosition() == 2; }, "shortcut search lost text or cursor after middle deletion");
                QTest::sendKeyEvent(QTest::Click, panel()->windowHandle(), Qt::Key_U, "u", Qt::NoModifier);
                pump([&] { return focusedSearch() && focusedSearch()->text() == "Brush tool"
                                      && focusedSearch()->cursorPosition() == 3 && button(brushKey().isEmpty() ? QStringLiteral("None") : brushKey().toUpper()); },
                     "shortcut search lost text, cursor or result after middle insertion");
            };
            const auto startRecording = [&] {
                QPushButton *recorder = nullptr;
                pump([&] { recorder = button(brushKey().isEmpty() ? QStringLiteral("None") : brushKey().toUpper()); return recorder != nullptr; },
                     "filtered shortcut recorder missing");
                bool clicked = false;
                const auto connection = QObject::connect(recorder, &QPushButton::clicked, &window, [&] { clicked = true; });
                const QPoint point = recorder->mapTo(panel(), recorder->rect().center());
                for (const auto type : {QEvent::MouseButtonPress, QEvent::MouseButtonRelease}) {
                    QMouseEvent event(type, QPointF(point), QPointF(panel()->mapToGlobal(point)), Qt::LeftButton,
                                      type == QEvent::MouseButtonPress ? Qt::LeftButton : Qt::NoButton, Qt::NoModifier);
                    QApplication::sendEvent(panel()->windowHandle(), &event);
                    QApplication::processEvents();
                }
                QObject::disconnect(connection);
                check(clicked, "shortcut recorder pointer did not emit clicked");
                try { pump([&] { return button("Save") && !button("Save")->isEnabled(); }, "shortcut click did not enter recording"); }
                catch (...) {
                    if (panel()) for (auto *candidate : panel()->findChildren<QPushButton *>())
                        qWarning() << "shortcut button" << candidate->text() << candidate->isVisible()
                                   << candidate->isEnabled() << candidate->accessibleName();
                    throw;
                }
            };
            const auto record = [&](int code, const QString &text, bool valid = true) {
                startRecording();
                QTest::sendKeyEvent(QTest::Click, panel()->windowHandle(), static_cast<Qt::Key>(code), text, Qt::NoModifier);
                pump([&] {
                    if (!button("Save") || button("Save")->isEnabled() != valid) return false;
                    if (valid) return true;
                    for (auto *label : panel()->findChildren<QLabel *>())
                        if (label->isVisible() && label->text().contains("assigned to both")) return true;
                    return false;
                }, "shortcut recording did not expose the expected validation state");
            };
            const auto finish = [&](const QString &title) {
                click(button(title)); pump([&] { return !panel(); }, "shortcut window did not close");
                QApplication::setActiveWindow(&window); QApplication::processEvents();
            };
            const auto verifyFreshProcess = [&](const QString &binding) {
                QProcess process;
                process.setProcessChannelMode(QProcess::MergedChannels);
                process.start(QCoreApplication::applicationFilePath(), {"--combo-smoke", "--shortcut-binding-probe", binding});
                check(process.waitForStarted(5000), "persisted-shortcut subprocess did not start");
                check(process.waitForFinished(30000), "persisted-shortcut subprocess did not finish");
                const QByteArray output = process.readAll();
                if (process.exitStatus() != QProcess::NormalExit || process.exitCode() != 0)
                    qWarning().noquote() << QString::fromUtf8(output.right(8192));
                check(process.exitStatus() == QProcess::NormalExit && process.exitCode() == 0,
                      "persisted-shortcut subprocess failed");
                check(output.contains("Qt persisted shortcut probe OK"), "persisted-shortcut subprocess omitted its proof marker");
                qInfo("Qt shortcut restart OK (%s)", qPrintable(binding));
            };
            open(); record(Qt::Key_M, "m", false);
            check(brushKey() == "b" && pixels() == original, "conflicting shortcut changed bindings or pixels");
            finish("Cancel");
            check(window.sessionState().value("shortcuts") == baseline.value("shortcuts"), "conflict Cancel changed bindings");
            open(); record(Qt::Key_K, "k");
            check(brushKey() == "b", "unsaved shortcut draft changed active bindings");
            finish("Cancel");
            check(window.sessionState().value("shortcuts") == baseline.value("shortcuts"), "shortcut Cancel changed bindings");
            open(); record(Qt::Key_K, "k"); finish("Save");
            pump([&] { return brushKey() == "k"; }, "shortcut Save did not install recorded binding");
            verifyFreshProcess("k");
            key(canvas, Qt::Key_K, Qt::NoModifier, "k");
            pump([&] { return window.sessionState().value("tool").toString() == "brush"; }, "saved shortcut did not select Brush");
            tool("Move", "move"); key(canvas, Qt::Key_B, Qt::NoModifier, "b");
            check(window.sessionState().value("tool").toString() == "move", "old Brush shortcut remained active");
            open(); record(Qt::Key_B, "b"); finish("Save");
            check(window.sessionState().value("shortcuts") == baseline.value("shortcuts"), "shortcut restore changed other bindings");
            key(canvas, Qt::Key_B, Qt::NoModifier, "b");
            pump([&] { return window.sessionState().value("tool").toString() == "brush"; }, "restored Brush shortcut did not work");
            open(); startRecording();
            QPushButton *remove = nullptr;
            pump([&] {
                if (panel()) for (auto *candidate : panel()->findChildren<QPushButton *>())
                    if (candidate->isVisible() && (candidate->accessibleName() == "Remove this shortcut"
                        || candidate->toolTip() == "Remove this shortcut")) remove = candidate;
                return remove != nullptr;
            }, "shortcut removal control missing");
            click(remove);
            pump([&] { return button("Save") && button("Save")->isEnabled(); }, "shortcut removal did not finish recording");
            finish("Save");
            check(brushKey().isEmpty(), "shortcut removal did not clear Brush binding");
            verifyFreshProcess("none");
            tool("Move", "move"); key(canvas, Qt::Key_M, Qt::NoModifier, "m");
            pump([&] { return window.sessionState().value("tool").toString() == "marquee"; }, "clearing shortcut broke another tool key");
            tool("Move", "move"); key(canvas, Qt::Key_B, Qt::NoModifier, "b");
            check(window.sessionState().value("tool").toString() == "move", "cleared Brush key still selected Brush");
            open(); click(button("Restore Defaults"));
            check(brushKey().isEmpty(), "Restore Defaults applied before Save");
            finish("Cancel");
            check(brushKey().isEmpty(), "Restore Defaults Cancel changed saved bindings");
            open(); click(button("Restore Defaults")); finish("Save");
            check(window.sessionState().value("shortcuts") == baseline.value("shortcuts"), "Restore Defaults Save changed original bindings");
            verifyFreshProcess("b");
            key(canvas, Qt::Key_B, Qt::NoModifier, "b");
            pump([&] { return window.sessionState().value("tool").toString() == "brush"; }, "default Brush key did not recover after clearing");
            check(pixels() == original && window.sessionState().value("layers") == baseline.value("layers")
                      && window.sessionState().value("undoName") == baseline.value("undoName"),
                  "shortcut editing changed document pixels, layers or history");
            qInfo("Qt shortcut window OK (visible menu/search, native recorder, conflict refusal, draft Cancel, Save, clear, Restore Defaults, new/old routing, original bindings restored)");
        }

        // Reopen existing adjustments through the original Layers thumbnail and Layer menu.
        for (const QString kind : {"Levels", "Hue/Saturation", "Curves", "Exposure", "Gradient Map", "Grain"}) {
            const bool levels = kind == "Levels";
            const bool hue = kind == "Hue/Saturation";
            reset();
            const QImage source = pixels();
            const auto sourceLayer = window.sessionState().value("layers").toArray().first();
            const QString panelName = levels ? "floatingPanel.LevelsSheet" : hue ? "floatingPanel.HueSaturationSheet" : "floatingPanel.FilterSheet";
            const auto panel = [&]() -> QDialog * {
                for (auto *top : QApplication::topLevelWidgets())
                    if (auto *dialog = qobject_cast<QDialog *>(top); dialog && dialog->isVisible()
                        && dialog->objectName() == panelName) return dialog;
                return nullptr;
            };
            const auto finish = [&](const QString &title) {
                QPushButton *button = nullptr;
                if (panel()) for (auto *candidate : panel()->findChildren<QPushButton *>())
                    if (candidate->isVisible() && candidate->text() == title) button = candidate;
                click(button);
                pump([&] { return !panel(); }, "adjustment editor did not close");
                QApplication::setActiveWindow(&window); QApplication::processEvents();
            };
            const auto layerMenuAction = [&](const QString &title, bool create) {
                QMenu *menu = nullptr;
                for (auto *action : window.menuBar()->actions())
                    if (action->text().remove('&') == "Layer") menu = action->menu();
                check(menu, "adjustment Layer menu missing");
                QMenu *rootMenu = menu;
                menu->popup(window.mapToGlobal(QPoint(200, 50))); QApplication::processEvents();
                if (create) {
                    QMenu *submenu = nullptr;
                    for (auto *action : menu->actions())
                        if (action->text().remove('&') == "New Adjustment Layer") submenu = action->menu();
                    check(submenu, "New Adjustment Layer submenu missing");
                    submenu->popup(window.mapToGlobal(QPoint(400, 50))); QApplication::processEvents();
                    menu = submenu;
                }
                QAction *chosen = nullptr;
                for (auto *action : menu->actions())
                    if (action->text().remove('&') == title) chosen = action;
                check(menu->isVisible() && chosen && chosen->isEnabled(), "adjustment menu action unavailable");
                chosen->trigger(); menu->hide(); rootMenu->hide(); QApplication::processEvents();
                pump([&] { return panel() != nullptr; }, "adjustment action did not open its editor");
            };
            layerMenuAction(kind + QString::fromUtf8("…"), true);
            finish("OK");
            const auto baseline = window.sessionState();
            const QImage original = pixels();
            check(baseline.value("layers").toArray().size() == 2
                      && baseline.value("layers").toArray().first() == sourceLayer,
                  "adjustment creation changed source record or layer count");
            if (levels || hue || kind == "Curves" || kind == "Exposure")
                check(original == source, "identity adjustment creation changed pixels");
            const auto adjustmentID = baseline.value("activeLayerID");
            QWidget *table = nullptr;
            for (auto *candidate : window.findChildren<QWidget *>())
                if (candidate->isVisible() && candidate->property("appKitView").toBool()
                    && candidate->property("appKitNode").toString().startsWith("LayersPanel|")) table = candidate;
            check(table && table->rect().contains(QPoint(60, 26)), "adjustment thumbnail unavailable");
            mouse(table, QEvent::MouseButtonDblClick, QPointF(60, 26), Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
            mouse(table, QEvent::MouseButtonRelease, QPointF(60, 26), Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
            pump([&] { return panel() != nullptr; }, "adjustment thumbnail double-click did not reopen editor");
            const auto edit = [&] {
                if (kind == "Gradient Map") {
                    QCheckBox *reverse = nullptr;
                    for (auto *candidate : panel()->findChildren<QCheckBox *>())
                        if (candidate->isVisible() && candidate->text() == "Reverse") reverse = candidate;
                    click(reverse);
                } else if (kind == "Curves") {
                    QWidget *graph = nullptr;
                    for (auto *candidate : panel()->findChildren<QWidget *>())
                        if (candidate->isVisible() && candidate->property("swiftuiGestureMinimumDistance").isValid()
                            && candidate->property("swiftuiGestureMinimumDistance").toDouble() == 0
                            && candidate->height() == 260 && candidate->width() > 200) graph = candidate;
                    check(graph, "reopened Curves graph gesture missing");
                    const QPointF from(graph->width() - 1, 1), to(graph->width() - 1, graph->height() / 2);
                    mouse(graph, QEvent::MouseButtonPress, from, Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
                    mouse(graph, QEvent::MouseMove, to, Qt::NoButton, Qt::LeftButton, Qt::NoModifier);
                    mouse(graph, QEvent::MouseButtonRelease, to, Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
                } else {
                    const QString title = levels ? "Output white" : hue ? "Hue" : kind == "Exposure" ? "Exposure" : "Amount";
                    QLineEdit *field = nullptr;
                    for (auto *candidate : panel()->findChildren<QLineEdit *>())
                        if (candidate->isVisible() && candidate->placeholderText() == title) field = candidate;
                    check(field && field->isEnabled(), "reopened adjustment field unavailable");
                    field->selectAll(); field->insert(levels ? "128" : hue ? "120" : kind == "Exposure" ? "-1" : "50");
                }
                pump([&] {
                    const QImage frame = pixels();
                    const auto color = frame.pixelColor(20, 20);
                    if (levels) return color.alpha() == 255 && qAbs(color.red() - 128) <= 2 && color.green() == 0;
                    // Exposure -1 halves linear light; converting 0.5 to sRGB gives 188.
                    if (kind == "Exposure") return color.alpha() == 255 && qAbs(color.red() - 188) <= 2 && color.green() == 0;
                    if (hue) return color.alpha() == 255 && color.green() > 250 && color.red() < 5;
                    return frame != original;
                }, "reopened adjustment edit did not update composite");
                unchangedOutside(original, pixels(), QRect(16, 16, 16, 16));
            };
            edit(); finish("Cancel");
            check(pixels() == original && window.sessionState().value("layers") == baseline.value("layers")
                      && window.sessionState().value("undoName") == baseline.value("undoName"),
                  "adjustment re-edit Cancel changed pixels, identity or history");
            layerMenuAction(QString::fromUtf8("Edit Adjustment…"), false);
            edit(); const QImage accepted = pixels(); finish("OK");
            check(pixels() == accepted && window.sessionState().value("activeLayerID") == adjustmentID
                      && window.sessionState().value("layers").toArray().first() == sourceLayer,
                  "adjustment re-edit OK changed source layer or lost preview/identity");
            key(canvas, Qt::Key_Z, Qt::ControlModifier);
            check(pixels() == original && window.sessionState().value("layers") == baseline.value("layers"),
                  "adjustment re-edit Undo changed hierarchy or lost original pixels");
            key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
            check(pixels() == accepted && window.sessionState().value("activeLayerID") == adjustmentID,
                  "adjustment re-edit Redo lost exact pixels or adjustment identity");
            qInfo("Qt adjustment re-edit OK (%s, visible creation, thumbnail double-click, Edit menu, Cancel/OK, exact Undo/Redo)", qPrintable(kind));
        }


        {
            const auto saved = window.sessionState();
            const auto livePixels = [&] {
                QByteArray bytes(64 * 64 * 4, Qt::Uninitialized);
                check(compositor_session_render(window.sessionHandle(), reinterpret_cast<uint8_t *>(bytes.data()), bytes.size()) == bytes.size(),
                      "live brush frame unavailable");
                return QImage(reinterpret_cast<const uchar *>(bytes.constData()), 64, 64, 64 * 4,
                              QImage::Format_RGBA8888_Premultiplied).copy().convertToFormat(QImage::Format_RGBA8888);
            };
            for (bool vertical : {false, true}) {
                reset();
                command({{"action", "setPaletteColor"}, {"kind", "foreground"},
                         {"parameters", QJsonObject{{"red", 0}, {"green", 0}, {"blue", 1}}}});
                command({{"action", "setBrushSettings"},
                         {"parameters", QJsonObject{{"diameter", 2}, {"hardness", 1}, {"opacity", 1}, {"smoothing", 0}}}});
                tool("Brush", "brush");
                const auto layer = window.sessionState().value("activeLayerID");
                const QImage before = pixels();
                const auto point = [&](double x, double y) { return vertical ? at(y, x) : at(x, y); };
                mouse(canvas, QEvent::MouseButtonPress, point(5, 8), Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
                mouse(canvas, QEvent::MouseMove, point(20, 13), Qt::NoButton, Qt::LeftButton, Qt::ShiftModifier);
                mouse(canvas, QEvent::MouseMove, point(38, 50), Qt::NoButton, Qt::LeftButton, Qt::ShiftModifier);
                const QImage held = livePixels();
                check(held != before, "held Shift brush did not paint");
                unchangedOutside(before, held, vertical ? QRect(6, 3, 5, 38) : QRect(3, 6, 38, 5));
                const QColor axisColor = held.pixelColor(vertical ? QPoint(8, 25) : QPoint(25, 8));
                check(axisColor.blue() > 200 && axisColor.alpha() > 0,
                      "Shift brush did not paint along its chosen axis");
                check(held.pixelColor(vertical ? QPoint(50, 38) : QPoint(38, 50))
                          == before.pixelColor(vertical ? QPoint(50, 38) : QPoint(38, 50)),
                      "held Shift followed the off-axis pointer");
                QKeyEvent release(QEvent::KeyRelease, Qt::Key_Shift, Qt::ShiftModifier);
                QApplication::sendEvent(&window, &release);
                mouse(canvas, QEvent::MouseMove, point(47, 29), Qt::NoButton, Qt::LeftButton, Qt::NoModifier);
                mouse(canvas, QEvent::MouseMove, point(54, 38), Qt::NoButton, Qt::LeftButton, Qt::NoModifier);
                mouse(canvas, QEvent::MouseButtonRelease, point(54, 38), Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
                pump([&] { return !window.sessionState().value("busy").toBool(); }, "Shift brush did not finish");
                const QImage committed = pixels();
                const QColor freeColor = committed.pixelColor(vertical ? QPoint(38, 54) : QPoint(54, 38));
                check(freeColor.blue() > 200 && freeColor.alpha() > 0,
                      "brush did not resume freehand after Shift release");
                check(window.sessionState().value("activeLayerID") == layer, "Shift brush changed its target layer");
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(pixels() == before, "Shift/freehand stroke was not one exact Undo");
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                check(pixels() == committed, "Shift/freehand stroke Redo changed pixels");
            }
            command({{"action", "setBrushSettings"}, {"parameters", QJsonObject{
                {"diameter", saved.value("brushDiameter")}, {"hardness", saved.value("brushHardness")},
                {"opacity", saved.value("brushOpacity")}, {"smoothing", saved.value("brushSmoothing")}}}});
            const auto color = saved.value("foregroundColor").toArray();
            command({{"action", "setPaletteColor"}, {"kind", "foreground"},
                     {"parameters", QJsonObject{{"red", color.at(0)}, {"green", color.at(1)}, {"blue", color.at(2)}}}});
            qInfo("Qt Shift brush axes OK (horizontal/vertical, off-axis refusal, release to freehand, one exact Undo/Redo)");
        }

        {
            const auto groupButton = [&]() -> QPushButton * {
                for (auto *button : window.findChildren<QPushButton *>())
                    if (button->isVisible() && button->accessibleName() == "New folder") return button;
                return nullptr;
            };
            const auto opacityField = [&]() -> QLineEdit * {
                for (auto *field : window.findChildren<QLineEdit *>())
                    if (field->isVisible() && field->placeholderText() == "Opacity percent") return field;
                return nullptr;
            };
            reset();
            const auto child = window.sessionState().value("activeLayerID");
            click(groupButton());
            const auto group = window.sessionState().value("activeLayerID");
            check(group != child && window.sessionState().value("activeLayerIsGroup").toBool(), "native folder control did not group the child");
            const auto grouped = window.sessionState().value("layers");
            const QImage opaque = pixels();
            auto *field = opacityField();
            check(field && field->isEnabled(), "native folder opacity field is disabled or missing");
            field->setFocus(); field->selectAll(); field->insert("50");
            key(field, Qt::Key_Return);
            pump([&] {
                for (const auto &value : window.sessionState().value("layers").toArray()) {
                    const auto layer = value.toObject();
                    if (layer.value("id") == group && layer.value("opacity").toDouble() == 0.5) return true;
                }
                return false;
            }, "native opacity field did not change the folder");
            const auto halfLayers = window.sessionState().value("layers");
            for (const auto &value : halfLayers.toArray()) {
                const auto layer = value.toObject();
                if (layer.value("id") == child)
                    check(layer.value("opacity").toDouble() == 1 && layer.value("parentID") == group,
                          "folder opacity changed child opacity or hierarchy");
            }
            const QImage half = pixels();
            const QColor sample = half.pixelColor(24, 24);
            check(qAbs(sample.alpha() - 128) <= 1 && sample.red() == 255 && sample.green() == 0 && sample.blue() == 0,
                  "native folder opacity did not dim its child's pixels");
            key(canvas, Qt::Key_Z, Qt::ControlModifier);
            check(window.sessionState().value("layers") == grouped && pixels() == opaque, "folder opacity Undo did not restore exact source and hierarchy");
            key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
            check(window.sessionState().value("layers") == halfLayers && pixels() == half, "folder opacity Redo did not restore exact pixels and hierarchy");
            qInfo("Qt folder opacity OK (visible percent field, child opacity/hierarchy retained, rendered alpha, exact Undo/Redo)");

            QImage blue(64, 64, QImage::Format_RGBA8888), green(64, 64, QImage::Format_RGBA8888);
            blue.fill(Qt::transparent); green.fill(Qt::transparent);
            for (int y = 20; y < 40; ++y) for (int x = 8; x < 40; ++x) blue.setPixelColor(x, y, Qt::blue);
            for (int y = 48; y < 56; ++y) for (int x = 48; x < 56; ++x) green.setPixelColor(x, y, Qt::green);
            const QString bluePath = temporary.filePath("merge-blue.png"), greenPath = temporary.filePath("merge-unselected.png");
            check(blue.save(bluePath) && green.save(greenPath), "native merge fixtures failed");
            for (const QString title : {QString("Merge Down"), QString("Merge Layers"), QString("Merge Group")}) {
                reset();
                const auto redID = window.sessionState().value("activeLayerID");
                QJsonValue unselected;
                if (title != "Merge Down") {
                    command({{"action", "importFiles"}, {"paths", QJsonArray{greenPath}}});
                    unselected = window.sessionState().value("activeLayerID");
                }
                command({{"action", "importFiles"}, {"paths", QJsonArray{bluePath}}});
                const auto blueID = window.sessionState().value("activeLayerID");
                if (title != "Merge Down") {
                    command({{"action", "selectLayer"}, {"layerID", redID}});
                    command({{"action", "selectLayer"}, {"layerID", blueID}, {"enabled", true}});
                }
                if (title == "Merge Group") {
                    click(groupButton());
                    command({{"action", "setOpacity"}, {"value", 0.5}});
                }
                const auto before = window.sessionState();
                const QImage beforePixels = pixels();
                QByteArray currentBytes(64 * 64 * 4, Qt::Uninitialized);
                check(compositor_session_render(window.sessionHandle(), reinterpret_cast<uint8_t *>(currentBytes.data()), currentBytes.size()) == currentBytes.size(),
                      "native pre-merge raster unavailable");
                const QImage currentPixels = QImage(reinterpret_cast<const uchar *>(currentBytes.constData()), 64, 64, 64 * 4,
                    QImage::Format_RGBA8888_Premultiplied).copy().convertToFormat(QImage::Format_RGBA8888);
                if (beforePixels != currentPixels)
                    qWarning() << "native export stale before merge" << title << beforePixels.pixelColor(8, 20) << currentPixels.pixelColor(8, 20);
                check(beforePixels == currentPixels, "native PNG export used an obsolete display frame");
                check(before.value("canMergeLayers").toBool() && before.value("mergeTitle").toString() == title,
                      "native merge plan does not match the selected scope");
                QMenu *layerMenu = nullptr;
                for (auto *action : window.menuBar()->actions())
                    if (action->text().remove('&') == "Layer") layerMenu = action->menu();
                check(layerMenu, "native Layer menu missing");
                layerMenu->popup(window.mapToGlobal(QPoint(30, 30))); QApplication::processEvents();
                QAction *merge = nullptr;
                for (auto *action : layerMenu->actions()) if (action->text().remove('&') == title) merge = action;
                check(layerMenu->isVisible() && merge && merge->isEnabled(), "visible native merge action missing or disabled");
                merge->trigger(); layerMenu->hide(); QApplication::processEvents();
                pump([&] { return window.sessionState().value("undoName").toString() == title; }, "native merge menu did not record upstream history");
                const auto merged = window.sessionState().value("layers");
                const QImage mergedPixels = pixels();
                if (mergedPixels != beforePixels) {
                    int different = 0;
                    for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x)
                        if (mergedPixels.pixelColor(x, y) != beforePixels.pixelColor(x, y)) {
                            if (different++ < 5) qWarning() << "merge pixel" << title << x << y
                                << beforePixels.pixelColor(x, y) << mergedPixels.pixelColor(x, y);
                        }
                    qWarning() << "merge changed pixels" << different << "before layers" << before.value("layers") << "after layers" << merged;
                }
                check(merged.toArray().size() == (title == "Merge Down" ? 1 : 2) && mergedPixels == beforePixels,
                      "native merge changed composite pixels or removed unselected layers");
                if (!unselected.isNull()) {
                    QJsonValue beforeLayer, afterLayer;
                    for (const auto &v : before.value("layers").toArray()) if (v.toObject().value("id") == unselected) beforeLayer = v;
                    for (const auto &v : merged.toArray()) if (v.toObject().value("id") == unselected) afterLayer = v;
                    check(!beforeLayer.isNull() && afterLayer == beforeLayer, "native merge changed the unselected layer");
                }
                QApplication::setActiveWindow(&window); QApplication::processEvents();
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(window.sessionState().value("layers") == before.value("layers") && pixels() == beforePixels,
                      "native merge Undo did not restore exact pixels, IDs and hierarchy");
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                check(window.sessionState().value("layers") == merged && pixels() == beforePixels,
                      "native merge Redo did not restore exact pixels and merged layer identity");
                qInfo("Qt layer merge OK (%s, visible menu, exact composite, unselected isolation, hierarchy/IDs Undo/Redo)", qPrintable(title));
            }
            command({{"action", "resizeCanvas"}, {"width", 80}, {"height", 72}});
            command({{"action", "resizeImage"}, {"width", 80}, {"height", 72}, {"value", 300}});
            const QString png = temporary.filePath("current-export.png"), jpeg = temporary.filePath("current-export.jpg");
            check(window.exportPNG(png) && window.exportJPEG(jpeg, 100), "native current-resolution export failed");
            for (const QString &path : {png, jpeg}) {
                const QImage exported(path);
                check(exported.size() == QSize(80, 72) && qAbs(exported.dotsPerMeterX() - qRound(300 / 0.0254)) <= 1
                          && qAbs(exported.dotsPerMeterY() - qRound(300 / 0.0254)) <= 1,
                      "native export used obsolete dimensions or resolution");
            }
            qInfo("Qt current-raster export OK (immediate layer import, PNG/JPEG, current dimensions and 300-DPI metadata)");
        }

        {
            reset();
            QImage extra(64, 64, QImage::Format_RGBA8888);
            extra.fill(Qt::transparent);
            for (int y = 12; y < 36; ++y) for (int x = 20; x < 36; ++x) extra.setPixelColor(x, y, Qt::blue);
            const QString path = temporary.filePath("duplicate-child.png");
            check(extra.save(path), "native duplicate child fixture failed");
            command({{"action", "importFiles"}, {"paths", QJsonArray{path}}});
            const auto blue = window.sessionState().value("activeLayerID");
            const auto initial = window.sessionState().value("layers").toArray();
            check(initial.size() == 2, "native duplicate fixture has unexpected layer count");
            command({{"action", "selectLayer"}, {"layerID", initial.first().toObject().value("id")}});
            command({{"action", "selectLayer"}, {"layerID", blue}, {"enabled", true}});
            const auto group = [&] {
                QPushButton *button = nullptr;
                for (auto *candidate : window.findChildren<QPushButton *>())
                    if (candidate->isVisible() && candidate->accessibleName() == "New folder") button = candidate;
                click(button);
                check(window.sessionState().value("activeLayerIsGroup").toBool(), "native nested grouping did not select its folder");
            };
            group(); group();
            const auto root = window.sessionState().value("activeLayerID");
            command({{"action", "setOpacity"}, {"value", 0.5}});
            const auto before = window.sessionState().value("layers").toArray();
            check(before.size() == 4, "native nested duplicate fixture lost descendants");
            const QImage beforePixels = pixels();
            QMenu *menu = nullptr;
            for (auto *action : window.menuBar()->actions())
                if (action->text().remove('&') == "Layer") menu = action->menu();
            check(menu, "native duplicate Layer menu missing");
            menu->popup(window.mapToGlobal(QPoint(30, 30))); QApplication::processEvents();
            QAction *duplicate = nullptr;
            for (auto *action : menu->actions()) if (action->text().remove('&') == "Duplicate Layer") duplicate = action;
            check(menu->isVisible() && duplicate && duplicate->isEnabled(), "visible native folder duplicate action missing or disabled");
            duplicate->trigger(); menu->hide(); QApplication::processEvents();
            pump([&] { return window.sessionState().value("layers").toArray().size() == 8; }, "native folder duplicate did not copy its complete subtree");
            const auto after = window.sessionState().value("layers").toArray();
            const auto copyRoot = window.sessionState().value("activeLayerID");
            check(copyRoot != root && window.sessionState().value("activeLayerIsGroup").toBool()
                      && window.sessionState().value("undoName").toString() == "Duplicate Layer",
                  "native folder duplicate did not select its new root or record history");
            QSet<QString> originalIDs, allIDs;
            for (const auto &value : before) originalIDs.insert(value.toObject().value("id").toString());
            QJsonArray copies;
            for (const auto &value : after) {
                const auto id = value.toObject().value("id").toString();
                check(!allIDs.contains(id), "native folder duplicate reused a layer ID"); allIDs.insert(id);
                if (!originalIDs.contains(id)) copies.append(value);
                else {
                    bool exact = false;
                    for (const auto &original : before) if (original == value) exact = true;
                    check(exact, "native folder duplicate mutated an original record");
                }
            }
            QMap<QString, QString> mapping;
            for (const auto &value : before) {
                const auto original = value.toObject();
                const QString name = original.value("name").toString() + (original.value("id") == root ? " copy" : "");
                for (const auto &copy : copies) if (copy.toObject().value("name").toString() == name)
                    mapping.insert(original.value("id").toString(), copy.toObject().value("id").toString());
            }
            check(mapping.size() == before.size() && mapping.value(root.toString()) == copyRoot.toString(),
                  "native folder duplicate lost descendant names or root mapping");
            for (const auto &value : before) {
                auto original = value.toObject();
                QJsonObject copy;
                for (const auto &candidate : copies) if (candidate.toObject().value("id").toString() == mapping.value(original.value("id").toString()))
                    copy = candidate.toObject();
                const auto parent = original.value("parentID");
                check(parent.isNull() ? copy.value("parentID").isNull()
                                     : copy.value("parentID").toString() == mapping.value(parent.toString()),
                      "native folder duplicate did not remap a nested parent");
                for (const QString key : {QString("id"), QString("name"), QString("parentID")}) { original.remove(key); copy.remove(key); }
                check(copy == original, "native folder duplicate changed descendant appearance or geometry");
            }
            const QImage doubled = pixels();
            command({{"action", "selectLayer"}, {"layerID", root}});
            command({{"action", "setVisible"}, {"enabled", false}});
            check(pixels() == beforePixels, "native duplicate depends on its original subtree's visibility or loses pixels");
            command({{"action", "undo"}});
            check(window.sessionState().value("layers").toArray() == after && pixels() == doubled, "native duplicate visibility Undo lost exact data");
            QApplication::setActiveWindow(&window); QApplication::processEvents();
            key(canvas, Qt::Key_Z, Qt::ControlModifier);
            check(window.sessionState().value("layers").toArray() == before && pixels() == beforePixels, "native folder duplicate Undo lost exact original hierarchy or pixels");
            key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
            check(window.sessionState().value("layers").toArray() == after && pixels() == doubled
                      && window.sessionState().value("activeLayerID") == copyRoot,
                  "native folder duplicate Redo lost copied IDs, hierarchy, pixels or selection");
            qInfo("Qt nested folder duplicate OK (visible menu, new IDs, remapped parents, names/appearance, source isolation, exact pixels/hierarchy Undo/Redo)");
        }

        {
            const auto saved = window.sessionState();
            QImage source(64, 64, QImage::Format_RGBA8888);
            for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x)
                source.setPixelColor(x, y, QColor(40 + x % 16 * 8, 80 + y % 16 * 8, 160));
            const QString path = temporary.filePath("mask-edit-source.png");
            check(source.save(path), "native mask fixture failed");
            for (bool folder : {false, true}) {
                check(window.importImage(path), "native mask fixture import failed");
                const auto child = window.sessionState().value("activeLayerID");
                if (folder) {
                    QPushButton *button = nullptr;
                    for (auto *candidate : window.findChildren<QPushButton *>())
                        if (candidate->isVisible() && candidate->accessibleName() == "New folder") button = candidate;
                    click(button);
                }
                const auto target = window.sessionState().value("activeLayerID");
                QPushButton *add = nullptr;
                for (auto *candidate : window.findChildren<QPushButton *>())
                    if (candidate->isVisible() && candidate->accessibleName() == "Add layer mask") add = candidate;
                click(add);
                pump([&] { return window.sessionState().value("isMaskSelected").toBool()
                                   && window.sessionState().value("activeLayerHasMask").toBool(); }, "native mask footer did not select a reveal mask");
                check(pixels() == source, "native reveal mask changed source pixels");
                command({{"action", "setPaletteColor"}, {"kind", "foreground"}, {"parameters", QJsonObject{{"red", 0}, {"green", 0}, {"blue", 0}}}});
                command({{"action", "setBrushSettings"}, {"parameters", QJsonObject{{"diameter", 8}, {"hardness", 1}, {"opacity", 1}, {"smoothing", 0}}}});
                command({{"action", "selectTool"}, {"kind", "brush"}, {"name", "Brush"}});
                tool("Brush", "brush"); drag(at(16, 32), at(48, 32));
                const QImage painted = pixels();
                check(painted.pixelColor(32, 32).alpha() == 0 && painted.pixelColor(4, 4) == source.pixelColor(4, 4),
                      "native black mask brush did not hide only the stroke");
                command({{"action", "setMaskEnabled"}, {"enabled", false}});
                check(pixels() == source, "native mask brush changed the underlying image");
                command({{"action", "undo"}});
                check(pixels() == painted, "native mask enable Undo lost painted coverage");
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(pixels() == source, "native mask brush Undo lost original pixels");
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                check(pixels() == painted && window.sessionState().value("activeLayerID") == target,
                      "native mask brush Redo lost pixels or target identity");
                command({{"action", "fillForeground"}});
                const QImage hidden = pixels();
                for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x)
                    check(hidden.pixelColor(x, y).alpha() == 0, "native black mask fill left visible pixels");
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(pixels() == painted, "native mask fill Undo lost the painted mask");
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                check(pixels() == hidden, "native mask fill Redo lost exact hidden pixels");
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                command({{"action", "setBrushSettings"}, {"parameters", QJsonObject{{"diameter", 16}, {"hardness", 1}, {"opacity", 1}, {"blurRadius", 3}}}});
                command({{"action", "selectTool"}, {"kind", "blur"}, {"name", "Blur"}});
                tool("Smear", "blur"); drag(at(24, 28), at(40, 28));
                const QImage softened = pixels();
                const int edge = softened.pixelColor(32, 30).alpha();
                check(edge > 0 && edge < 255 && softened.pixelColor(4, 4) == source.pixelColor(4, 4),
                      "native mask blur did not soften the painted edge");
                command({{"action", "setMaskEnabled"}, {"enabled", false}});
                check(pixels() == source, "native mask blur changed source image pixels");
                command({{"action", "undo"}});
                check(pixels() == softened, "native mask blur enable Undo lost coverage");
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(pixels() == painted, "native mask blur Undo lost sharp mask pixels");
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                check(pixels() == softened && window.sessionState().value("activeLayerID") == target,
                      "native mask blur Redo lost exact coverage or target identity");
                const auto layers = window.sessionState().value("layers").toArray();
                bool keptChild = false;
                for (const auto &value : layers) if (value.toObject().value("id") == child) keptChild = true;
                check(keptChild && layers.size() == (folder ? 2 : 1), "native mask operations changed source layer hierarchy");
                command({{"action", "setMaskSelected"}, {"enabled", false}});
                tool("Move", "move");
                qInfo("Qt mask paint/fill/blur OK (%s, visible mask footer and pointer tools, source-image isolation, soft edge, exact Undo/Redo)", folder ? "folder" : "layer");
            }
            command({{"action", "setBrushSettings"}, {"parameters", QJsonObject{
                {"diameter", saved.value("brushDiameter")}, {"hardness", saved.value("brushHardness")},
                {"opacity", saved.value("brushOpacity")}, {"smoothing", saved.value("brushSmoothing")}, {"blurRadius", saved.value("blurRadius")}}}});
        }

        {
            QImage source(64, 64, QImage::Format_RGBA8888); source.fill(QColor(80, 140, 200));
            const QString path = temporary.filePath("feather-mask-source.png");
            check(source.save(path), "native Feather mask fixture failed");
            for (bool folder : {false, true}) {
                check(window.importImage(path), "native Feather mask import failed");
                if (folder) {
                    QPushButton *group = nullptr;
                    for (auto *button : window.findChildren<QPushButton *>())
                        if (button->isVisible() && button->accessibleName() == "New folder") group = button;
                    click(group);
                }
                const auto target = window.sessionState().value("activeLayerID");
                tool("Marquee", "marquee"); drag(at(16, 16), at(48, 48));
                const auto before = window.sessionState();
                const auto panel = [&]() -> QDialog * {
                    for (auto *top : QApplication::topLevelWidgets())
                        if (auto *dialog = qobject_cast<QDialog *>(top); dialog && dialog->isVisible()
                            && dialog->objectName() == "floatingPanel.SelectionAmountSheet") return dialog;
                    return nullptr;
                };
                const auto actionButton = [&](const QString &title) -> QPushButton * {
                    if (auto *dialog = panel()) for (auto *button : dialog->findChildren<QPushButton *>())
                        if (button->isVisible() && button->text() == title) return button;
                    return nullptr;
                };
                const auto begin = [&] {
                    QMenu *menu = nullptr;
                    for (auto *action : window.menuBar()->actions()) if (action->text().remove('&') == "Select") menu = action->menu();
                    check(menu, "native Select menu missing");
                    menu->popup(window.mapToGlobal(QPoint(30, 30))); QApplication::processEvents();
                    QAction *feather = nullptr;
                    for (auto *action : menu->actions()) if (action->text().remove('&').startsWith("Feather")) feather = action;
                    check(menu->isVisible() && feather && feather->isEnabled(), "visible native Feather action missing or disabled");
                    feather->trigger(); menu->hide(); QApplication::processEvents();
                    pump([&] { return panel() != nullptr; }, "native Feather Amount panel missing");
                    QLineEdit *amount = nullptr;
                    for (auto *field : panel()->findChildren<QLineEdit *>())
                        if (field->isVisible() && field->placeholderText() == "Amount") amount = field;
                    check(amount && amount->isEnabled(), "native Feather Amount field missing");
                    amount->selectAll(); amount->insert("6"); QApplication::processEvents();
                };
                begin(); click(actionButton("Cancel"));
                pump([&] { return !panel(); }, "native Feather Cancel retained panel");
                check(pixels() == source && window.sessionState().value("layers") == before.value("layers")
                          && window.sessionState().value("undoName") == before.value("undoName")
                          && window.sessionState().value("hasSelection").toBool(), "native Feather Cancel changed source, selection or history");
                begin(); click(actionButton("OK"));
                pump([&] { return !panel() && window.sessionState().value("undoName").toString() == "Feather Selection"; },
                     "native Feather OK did not record selection history");
                check(pixels() == source && window.sessionState().value("layers") == before.value("layers"),
                      "native Feather changed image pixels before mask creation");
                QApplication::setActiveWindow(&window); QApplication::processEvents();
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(window.sessionState().value("undoName") == before.value("undoName") && window.sessionState().value("hasSelection").toBool(),
                      "native Feather Undo did not restore selection history");
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                check(window.sessionState().value("undoName").toString() == "Feather Selection", "native Feather Redo lost its history step");
                QPushButton *add = nullptr;
                for (auto *button : window.findChildren<QPushButton *>())
                    if (button->isVisible() && button->accessibleName() == "Add layer mask") add = button;
                click(add);
                pump([&] { return window.sessionState().value("activeLayerHasMask").toBool()
                                   && !window.sessionState().value("hasSelection").toBool(); }, "native Feather selection did not become a mask");
                const QImage masked = pixels();
                int soft = 0;
                for (int x = 0; x < 64; ++x) { const int alpha = masked.pixelColor(x, 32).alpha(); if (alpha > 8 && alpha < 247) ++soft; }
                check(soft >= 8 && masked.pixelColor(32, 32).alpha() > 230 && masked.pixelColor(4, 4).alpha() < 8,
                      "native Feather mask lost soft boundary coverage");
                command({{"action", "setMaskEnabled"}, {"enabled", false}});
                check(pixels() == source, "native Feather mask altered the source image");
                command({{"action", "undo"}});
                check(pixels() == masked, "native Feather mask enable Undo lost exact coverage");
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(!window.sessionState().value("activeLayerHasMask").toBool()
                          && window.sessionState().value("hasSelection").toBool() && pixels() == source,
                      "native Feather mask creation Undo lost the feathered selection or source");
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                check(pixels() == masked && window.sessionState().value("activeLayerID") == target,
                      "native Feather mask Redo lost exact coverage or target identity");
                command({{"action", "setMaskSelected"}, {"enabled", false}}); tool("Move", "move");
                qInfo("Qt Feather to mask OK (%s, visible menu/Amount/Cancel/OK, soft alpha, source isolation, selection and mask Undo/Redo)", folder ? "folder" : "layer");
            }
        }

        {
            const auto liveFilterPixels = [&] {
                QByteArray bytes(64 * 64 * 4, Qt::Uninitialized);
                check(compositor_session_render(window.sessionHandle(), reinterpret_cast<uint8_t *>(bytes.data()), bytes.size()) == bytes.size(),
                      "native selected-filter frame unavailable");
                return QImage(reinterpret_cast<const uchar *>(bytes.constData()), 64, 64, 64 * 4,
                              QImage::Format_RGBA8888_Premultiplied).copy().convertToFormat(QImage::Format_RGBA8888);
            };
            const auto filterPanel = [&]() -> QDialog * {
                for (auto *top : QApplication::topLevelWidgets())
                    if (auto *dialog = qobject_cast<QDialog *>(top); dialog && dialog->isVisible()
                        && dialog->objectName() == "floatingPanel.FilterSheet") return dialog;
                return nullptr;
            };
            const auto filterButton = [&](const QString &text) -> QPushButton * {
                if (auto *panel = filterPanel())
                    for (auto *button : panel->findChildren<QPushButton *>())
                        if (button->isVisible() && button->text() == text) return button;
                return nullptr;
            };
            for (const QString kind : {QString("Gaussian Blur"), QString("Black & White")}) {
                reset();
                tool("Marquee", "marquee");
                drag(at(8, 8), at(24, 40));
                check(window.sessionState().value("hasSelection").toBool(), "native selected-filter marquee missing");
                const QImage before = liveFilterPixels();
                const auto state = window.sessionState();
                const auto begin = [&] {
                    command({{"action", "openFilter"}, {"kind", kind}});
                    pump([&] { return filterPanel() != nullptr; }, "native selected-filter panel missing");
                    command({{"action", "filterPreview"}, {"parameters", QJsonObject{{"radius", 3}, {"preserveTransparency", 0}}}});
                    pump([&] { return !window.sessionState().value("filterPreviewRendering").toBool()
                                       && liveFilterPixels() != before; }, "native selected-filter preview never finished changing pixels");
                };
                begin();
                const QImage preview = liveFilterPixels();
                unchangedOutside(before, preview, QRect(8, 8, 16, 32));
                check(window.sessionState().value("layers") == state.value("layers")
                          && window.sessionState().value("undoName") == state.value("undoName"),
                      "native selected-filter preview changed source layers or history");
                command({{"action", "filterSetPreview"}, {"enabled", false}});
                check(liveFilterPixels() == before, "native selected-filter preview Off did not restore exact pixels");
                command({{"action", "filterSetPreview"}, {"enabled", true}});
                pump([&] { return liveFilterPixels() == preview; }, "native selected-filter preview On lost clipped pixels");
                click(filterButton("Cancel"));
                pump([&] { return !filterPanel() && !window.sessionState().value("busy").toBool(); },
                     "native selected-filter Cancel did not close the panel");
                check(liveFilterPixels() == before && window.sessionState().value("layers") == state.value("layers")
                          && window.sessionState().value("undoName") == state.value("undoName"),
                      "native selected-filter Cancel changed pixels, layers or history");
                begin();
                const QImage acceptedPreview = liveFilterPixels();
                click(filterButton("OK"));
                pump([&] { return !filterPanel() && !window.sessionState().value("busy").toBool()
                                   && window.sessionState().value("undoName").toString() == kind; },
                     "native selected-filter OK did not commit upstream history");
                const QImage committed = liveFilterPixels();
                check(committed == acceptedPreview, "native selected-filter committed pixels differ from the preview");
                unchangedOutside(before, committed, QRect(8, 8, 16, 32));
                QApplication::setActiveWindow(&window); QApplication::processEvents();
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(liveFilterPixels() == before && window.sessionState().value("hasSelection").toBool(),
                      "native selected-filter Undo did not restore pixels and selection");
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                check(liveFilterPixels() == committed && window.sessionState().value("activeLayerID") == state.value("activeLayerID"),
                      "native selected-filter Redo lost exact pixels or layer identity");
                tool("Move", "move");
                qInfo("Qt selected-filter preview OK (%s, exact outside pixels, Off/On, visible Cancel/OK, exact Apply Undo/Redo)", qPrintable(kind));
            }
        }

        {
            const auto liveAdjustmentPixels = [&] {
                QByteArray bytes(64 * 64 * 4, Qt::Uninitialized);
                check(compositor_session_render(window.sessionHandle(), reinterpret_cast<uint8_t *>(bytes.data()), bytes.size()) == bytes.size(),
                      "native selected-adjustment frame unavailable");
                return QImage(reinterpret_cast<const uchar *>(bytes.constData()), 64, 64, 64 * 4,
                              QImage::Format_RGBA8888_Premultiplied).copy().convertToFormat(QImage::Format_RGBA8888);
            };
            for (bool levels : {true, false}) {
                const QString kind = levels ? "Levels" : "Hue/Saturation";
                const QString panelName = levels ? "floatingPanel.LevelsSheet" : "floatingPanel.HueSaturationSheet";
                const auto panel = [&]() -> QDialog * {
                    for (auto *top : QApplication::topLevelWidgets())
                        if (auto *dialog = qobject_cast<QDialog *>(top); dialog && dialog->isVisible()
                            && dialog->objectName() == panelName) return dialog;
                    return nullptr;
                };
                const auto button = [&](const QString &title) -> QPushButton * {
                    if (auto *dialog = panel()) for (auto *candidate : dialog->findChildren<QPushButton *>())
                        if (candidate->isVisible() && candidate->text() == title) return candidate;
                    return nullptr;
                };
                const auto previewToggle = [&]() -> QCheckBox * {
                    if (auto *dialog = panel()) for (auto *candidate : dialog->findChildren<QCheckBox *>())
                        if (candidate->isVisible() && candidate->text() == "Preview") return candidate;
                    return nullptr;
                };
                reset();
                tool("Marquee", "marquee"); drag(at(8, 8), at(24, 40));
                check(window.sessionState().value("hasSelection").toBool(), "native selected-adjustment marquee missing");
                const QImage before = liveAdjustmentPixels();
                const auto state = window.sessionState();
                const QColor expected = levels ? QColor(128, 0, 0) : QColor(Qt::green);
                const auto ready = [&] {
                    const QColor actual = liveAdjustmentPixels().pixelColor(20, 20);
                    return qAbs(actual.red() - expected.red()) <= 2 && qAbs(actual.green() - expected.green()) <= 2
                        && qAbs(actual.blue() - expected.blue()) <= 2 && actual.alpha() == 255;
                };
                const auto begin = [&] {
                    command({{"action", levels ? "beginLevels" : "beginHueSaturation"}});
                    pump([&] { return panel() != nullptr; }, "native selected-adjustment panel missing");
                    QLineEdit *field = nullptr;
                    for (auto *candidate : panel()->findChildren<QLineEdit *>())
                        if (candidate->isVisible() && candidate->placeholderText() == (levels ? "Output white" : "Hue")) field = candidate;
                    check(field && field->isEnabled(), "native selected-adjustment numeric field missing");
                    field->selectAll(); field->insert(levels ? "128" : "120");
                    pump(ready, "native selected-adjustment numeric edit did not produce the expected preview color");
                };
                begin();
                const QImage preview = liveAdjustmentPixels();
                unchangedOutside(before, preview, QRect(8, 8, 16, 32));
                check(window.sessionState().value("layers") == state.value("layers")
                          && window.sessionState().value("undoName") == state.value("undoName"),
                      "native selected-adjustment preview changed source or history");
                click(previewToggle());
                pump([&] { return liveAdjustmentPixels() == before; }, "native selected-adjustment Preview Off changed original pixels");
                click(previewToggle());
                pump([&] { return liveAdjustmentPixels() == preview; }, "native selected-adjustment Preview On lost clipped pixels");
                click(button("Cancel"));
                pump([&] { return !panel(); }, "native selected-adjustment Cancel retained panel");
                check(liveAdjustmentPixels() == before && window.sessionState().value("layers") == state.value("layers")
                          && window.sessionState().value("undoName") == state.value("undoName"),
                      "native selected-adjustment Cancel changed pixels or history");
                begin();
                const QImage acceptedPreview = liveAdjustmentPixels();
                click(button("OK"));
                pump([&] { return !panel() && window.sessionState().value("undoName").toString() == kind; },
                     "native selected-adjustment OK did not commit history");
                const QImage committed = liveAdjustmentPixels();
                check(committed == acceptedPreview, "native selected-adjustment commit differs from preview");
                unchangedOutside(before, committed, QRect(8, 8, 16, 32));
                QApplication::setActiveWindow(&window); QApplication::processEvents();
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(liveAdjustmentPixels() == before && window.sessionState().value("hasSelection").toBool(),
                      "native selected-adjustment Undo lost original pixels or selection");
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                check(liveAdjustmentPixels() == committed && window.sessionState().value("activeLayerID") == state.value("activeLayerID"),
                      "native selected-adjustment Redo lost committed pixels or layer identity");
                tool("Move", "move");
                qInfo("Qt selected-adjustment preview OK (%s, numeric control, exact outside pixels, Preview toggle, visible Cancel/OK, exact Undo/Redo)", qPrintable(kind));
            }
        }

        {
            QImage texture(64, 64, QImage::Format_RGBA8888);
            for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x)
                texture.setPixelColor(x, y, QColor(40 + x % 16 * 8, 80 + y % 16 * 8, 120 + (x + y) % 16 * 4));
            const QString texturePath = temporary.filePath("content-extend.png");
            check(texture.save(texturePath), "native content extension fixture save failed");
            const auto frame = [&] {
                QByteArray bytes(80 * 80 * 4, Qt::Uninitialized);
                check(compositor_session_render(window.sessionHandle(), reinterpret_cast<uint8_t *>(bytes.data()), bytes.size()) == bytes.size(),
                      "native expanded-canvas frame unavailable");
                return QImage(reinterpret_cast<const uchar *>(bytes.constData()), 80, 80, 80 * 4,
                              QImage::Format_RGBA8888_Premultiplied).copy().convertToFormat(QImage::Format_RGBA8888);
            };
            const auto panel = [&]() -> QDialog * {
                for (auto *top : QApplication::topLevelWidgets())
                    if (auto *dialog = qobject_cast<QDialog *>(top); dialog && dialog->isVisible()
                        && dialog->objectName() == "floatingPanel.FilterSheet") return dialog;
                return nullptr;
            };
            const auto button = [&](const QString &title) -> QPushButton * {
                if (auto *dialog = panel()) for (auto *candidate : dialog->findChildren<QPushButton *>())
                    if (candidate->isVisible() && candidate->text() == title) return candidate;
                return nullptr;
            };
            const QRect strips[] = {{0, 0, 8, 80}, {72, 0, 8, 80}, {0, 0, 80, 8}, {0, 72, 80, 8}};
            for (int side = 0; side < 4; ++side) {
                check(window.importImage(texturePath), "native content extension import failed");
                command({{"action", "resizeCanvas"}, {"width", 80}, {"height", 80}, {"parameters", QJsonObject{{"anchor", 4}}}});
                check(window.sessionState().value("width").toInt() == 80 && window.sessionState().value("height").toInt() == 80,
                      "native content extension did not expand the canvas");
                const QImage before = frame();
                for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x)
                    check(before.pixelColor(x + 8, y + 8) == texture.pixelColor(x, y), "canvas expansion changed original texture pixels");
                const QRect strip = strips[side];
                tool("Marquee", "marquee");
                drag(at(strip.x(), strip.y()), at(strip.x() + strip.width(), strip.y() + strip.height()));
                check(window.sessionState().value("hasSelection").toBool(), "native content extension selection missing");
                tool("Crop", "crop");
                const QJsonArray bounds = window.sessionState().value("cropRect").toArray();
                check(bounds == QJsonArray{strip.x(), strip.y(), strip.width(), strip.height()},
                      "expanded-canvas pointer selection did not match the requested strip");
                key(canvas, Qt::Key_Escape); tool("Marquee", "marquee");
                const auto state = window.sessionState();
                const auto begin = [&] {
                    command({{"action", "openFilter"}, {"kind", "Content-Aware Fill"}});
                    pump([&] { return panel() && !window.sessionState().value("filterPreviewRendering").toBool(); },
                         "native content extension preview did not finish");
                };
                const auto checkFill = [&](const QImage &image) {
                    bool varied = false;
                    int colorSignal = 0;
                    const QColor first = image.pixelColor(strip.topLeft());
                    for (int y = 0; y < 80; ++y) for (int x = 0; x < 80; ++x) {
                        const QColor color = image.pixelColor(x, y);
                        if (!strip.contains(x, y)) {
                            check(color == before.pixelColor(x, y), "content extension changed pixels outside the added strip");
                        } else {
                            if (color.alpha() != 255)
                                qWarning() << "content extension pixel" << side << x << y << color
                                           << "layers" << window.sessionState().value("layers");
                            check(color.alpha() == 255, "content extension did not synthesize opaque pixels");
                            colorSignal += color.red() + color.green() + color.blue();
                            varied |= color != first;
                        }
                    }
                    check(varied, "content extension lost the source texture variation");
                    // PatchMatch adapts tone at the boundary; synthesized colors can exceed the source's range.
                    check(colorSignal > strip.width() * strip.height() * 60, "content extension lost the source color signal");
                };
                begin();
                checkFill(frame());
                check(window.sessionState().value("undoName") == state.value("undoName"), "content extension preview changed history");
                click(button("Cancel"));
                pump([&] { return !panel() && !window.sessionState().value("busy").toBool(); }, "content extension Cancel did not settle");
                check(frame() == before && window.sessionState().value("layers") == state.value("layers")
                          && window.sessionState().value("undoName") == state.value("undoName"),
                      "content extension Cancel changed pixels, layer geometry or history");
                begin();
                const QImage preview = frame();
                checkFill(preview);
                click(button("OK"));
                pump([&] { return !panel() && !window.sessionState().value("busy").toBool()
                                   && window.sessionState().value("undoName").toString() == "Content-Aware Fill"; },
                     "content extension OK did not commit history");
                const auto committedLayers = window.sessionState().value("layers");
                check(committedLayers.toArray().size() == state.value("layers").toArray().size(),
                      "content extension added a layer instead of extending its target");
                const QJsonObject transform = committedLayers.toArray().first().toObject().value("transform").toObject();
                const QJsonArray origin = transform.value("origin").toArray(), size = transform.value("size").toArray();
                const QRect expected = QRect(8, 8, 64, 64).united(strip);
                check(origin == QJsonArray{expected.x(), expected.y()} && size == QJsonArray{expected.width(), expected.height()},
                      "content extension committed incorrect layer bounds");
                check(frame() == preview && window.sessionState().value("activeLayerID") == state.value("activeLayerID"),
                      "content extension commit changed prepared pixels or layer identity");
                QApplication::setActiveWindow(&window); QApplication::processEvents();
                key(canvas, Qt::Key_Z, Qt::ControlModifier);
                check(frame() == before && window.sessionState().value("layers") == state.value("layers")
                          && window.sessionState().value("hasSelection").toBool(), "content extension Undo lost pixels, geometry or selection");
                key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                check(frame() == preview && window.sessionState().value("layers") == committedLayers,
                      "content extension Redo lost exact filled pixels or geometry");
                tool("Move", "move");
                qInfo("Qt expanded-canvas Content-Aware Fill OK (side %d, original pixels, opaque texture, Cancel, exact preview/commit Undo/Redo)", side);
            }
        }

        {
            check(compositor_install_subject_model() == 0, "native Object selection requires the shipped U2Net/OpenCV model");
            QImage subject(128, 96, QImage::Format_RGBA8888);
            subject.fill(QColor(244, 244, 244));
            for (int y = 0; y < subject.height(); ++y) for (int x = 0; x < subject.width(); ++x) {
                const double dx = (x - 64) / 32.0, dy = (y - 48) / 28.0;
                if (dx * dx + dy * dy < 1) subject.setPixelColor(x, y, QColor(200, 40, 30));
            }
            const QString subjectPath = temporary.filePath("object-subject.png");
            check(subject.save(subjectPath) && window.importImage(subjectPath), "native Object fixture import failed");
            const auto layer = window.sessionState().value("activeLayerID");
            const auto layers = window.sessionState().value("layers");
            tool("Magic", "wand");
            QPushButton *object = nullptr;
            for (auto *button : window.findChildren<QPushButton *>())
                if (button->isVisible() && button->text() == "Object") object = button;
            click(object);
            const auto objectClick = [&](double x, double y, bool selected) {
                canvas->setFocus();
                mouse(canvas, QEvent::MouseButtonPress, at(x, y), Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
                mouse(canvas, QEvent::MouseButtonRelease, at(x, y), Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
                pump([&] { return !window.sessionState().value("busy").toBool()
                                   && window.sessionState().value("hasSelection").toBool() == selected; },
                     "native Object pointer selection did not settle");
            };
            objectClick(64, 48, true);
            check(window.sessionState().value("undoName").toString() == "Object Selection"
                      && window.sessionState().value("layers") == layers
                      && window.sessionState().value("activeLayerID") == layer,
                  "native Object selection changed source layers or missed upstream history");
            key(canvas, Qt::Key_Z, Qt::ControlModifier);
            check(!window.sessionState().value("hasSelection").toBool(), "native Object Undo retained selection");
            key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
            check(window.sessionState().value("hasSelection").toBool(), "native Object Redo lost selection");
            const auto savedColor = window.sessionState().value("foregroundColor").toArray();
            command({{"action", "setPaletteColor"}, {"kind", "foreground"},
                     {"parameters", QJsonObject{{"red", 0}, {"green", 0}, {"blue", 1}}}});
            command({{"action", "fillForeground"}});
            const QString selectedPath = temporary.filePath("object-fill.png");
            check(window.exportPNG(selectedPath), "native Object selected fill export failed");
            const QImage selected(selectedPath);
            check(selected.size() == subject.size() && selected.pixelColor(64, 48) == QColor(Qt::blue)
                      && selected.pixelColor(1, 1) == subject.pixelColor(1, 1),
                  "native Object pointer selected background or lost foreground");
            key(canvas, Qt::Key_Z, Qt::ControlModifier);
            check(window.exportPNG(selectedPath) && QImage(selectedPath).convertToFormat(QImage::Format_RGBA8888) == subject,
                  "native Object fill Undo did not restore exact source pixels");
            objectClick(1, 1, false);
            check(window.sessionState().value("layers") == layers, "native Object background click changed source layers");
            key(canvas, Qt::Key_Z, Qt::ControlModifier);
            check(window.sessionState().value("hasSelection").toBool(), "native Object background Undo lost prior selection");
            key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
            check(!window.sessionState().value("hasSelection").toBool(), "native Object background Redo retained selection");
            command({{"action", "setPaletteColor"}, {"kind", "foreground"}, {"parameters", QJsonObject{
                {"red", savedColor[0]}, {"green", savedColor[1]}, {"blue", savedColor[2]}}}});
            tool("Move", "move");
            qInfo("Qt Object selection OK (shipped U2Net/OpenCV, visible mode, foreground/background clicks, selected fill, exact pixel Undo, selection Undo/Redo)");
        }

        // Crop gestures reach the unchanged upstream geometry through the visible rail and canvas.
        {
            const auto cropRect = [&] {
                const QJsonArray rect = window.sessionState().value("cropRect").toArray();
                check(rect.size() == 4, "native crop draft missing");
                return QRectF(rect[0].toDouble(), rect[1].toDouble(), rect[2].toDouble(), rect[3].toDouble());
            };
            const auto expectCrop = [&](QRectF expected) {
                const QRectF actual = cropRect();
                if (actual != expected) qWarning() << "crop geometry actual" << actual << "expected" << expected;
                check(qAbs(actual.x() - expected.x()) < 0.01 && qAbs(actual.y() - expected.y()) < 0.01
                          && qAbs(actual.width() - expected.width()) < 0.01 && qAbs(actual.height() - expected.height()) < 0.01,
                      "native crop gesture did not preserve upstream geometry");
            };
            for (bool symmetric : {false, true}) {
                reset();
                click(window.findChild<QPushButton *>("actualPixels"));
                const auto before = window.sessionState();
                const QImage beforePixels = pixels();
                tool("Crop", "crop");
                drag(at(32, 32), at(50, 45), symmetric ? Qt::AltModifier : Qt::NoModifier);
                expectCrop(symmetric ? QRectF(14, 19, 36, 26) : QRectF(32, 32, 18, 13));
                check(window.sessionState().value("layers") == before.value("layers")
                          && window.sessionState().value("undoName") == before.value("undoName"),
                      "native crop draft changed layers or history");
                key(canvas, Qt::Key_Escape);
                check(window.sessionState().value("cropRect").toArray().isEmpty(), "Escape retained native crop draft");
                tool("Move", "move");
                check(pixels() == beforePixels, "native crop cancellation changed pixels");
            }
            for (bool suppressSnap : {false, true}) {
                reset();
                click(window.findChild<QPushButton *>("actualPixels"));
                tool("Crop", "crop");
                // Linux Meta maps to upstream Control, which temporarily disables snapping.
                drag(at(20, 20), at(63, 60), suppressSnap ? Qt::MetaModifier : Qt::NoModifier);
                expectCrop(suppressSnap ? QRectF(20, 20, 43, 40) : QRectF(20, 20, 44, 44));
                if (!suppressSnap) {
                    // Alt-resize mirrors the opposite edge around the original frame's center.
                    drag(at(64, 42), at(60, 42), Qt::AltModifier | Qt::MetaModifier);
                    expectCrop(QRectF(24, 20, 36, 44));
                    key(canvas, Qt::Key_Escape);
                } else {
                    const auto layer = window.sessionState().value("activeLayerID");
                    key(canvas, Qt::Key_Return);
                    pump([&] { return window.sessionState().value("width").toInt() == 43
                                       && window.sessionState().value("height").toInt() == 40; },
                         "native crop Apply did not change canvas dimensions");
                    check(window.sessionState().value("activeLayerID") == layer, "native crop Apply changed layer identity");
                    key(canvas, Qt::Key_Z, Qt::ControlModifier);
                    check(window.sessionState().value("width").toInt() == 64
                              && window.sessionState().value("height").toInt() == 64 && pixels() == fixture,
                          "native crop Undo did not restore dimensions and pixels");
                    key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
                    check(window.sessionState().value("width").toInt() == 43
                              && window.sessionState().value("height").toInt() == 40,
                          "native crop Redo did not restore dimensions");
                    key(canvas, Qt::Key_Z, Qt::ControlModifier);
                }
                tool("Move", "move");
            }
            qInfo("Qt crop gestures OK (Alt create/resize symmetry, canvas-edge snap, Meta suppression, Cancel and Apply Undo/Redo)");
        }

        // Selection -> Gradient: draw the selection and gradient, then compare every outside pixel.
        reset();
        const QImage original = pixels();
        tool("Marquee", "marquee"); drag(at(16, 16), at(32, 32));
        check(window.sessionState().value("hasSelection").toBool(), "native marquee did not select");
        gradient(at(16, 16), at(31, 31));
        const QImage filled = pixels();
        check(filled != original, "native gradient did not paint");
        unchangedOutside(original, filled, QRect(16, 16, 16, 16));
        key(canvas, Qt::Key_Z, Qt::ControlModifier);
        check(pixels() == original, "native gradient Undo did not restore the exact pixels");
        key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
        check(pixels() == filled, "immediate native Redo did not restore the gradient");
        key(canvas, Qt::Key_Z, Qt::ControlModifier);
        check(pixels() == original, "native Undo after Redo did not restore the source pixels");
        qInfo("combo: selection -> gradient -> Undo OK");

        // Ctrl-drag inside a marquee moves its pixels, not just the selection outline.
        tool("Marquee", "marquee"); drag(at(24, 24), at(40, 24), Qt::ControlModifier);
        QImage moved = original;
        for (int y = 16; y < 32; ++y) for (int x = 16; x < 48; ++x)
            moved.setPixelColor(x, y, x < 32 ? QColor(Qt::transparent) : original.pixelColor(x - 16, y));
        check(pixels() == moved, "native selected-pixel drag did not cut and move the expected pixels");
        gradient(at(32, 16), at(47, 31));
        unchangedOutside(moved, pixels(), QRect(32, 16, 16, 16));
        key(canvas, Qt::Key_Z, Qt::ControlModifier); check(pixels() == moved, "gradient Undo lost moved pixels");
        key(canvas, Qt::Key_Z, Qt::ControlModifier); check(pixels() == original, "pixel move Undo lost source pixels");
        qInfo("combo: selected pixel move -> gradient -> two Undo steps OK");

        // Show Controls -> real corner press/drag/release -> Gradient. Release must finish an ordinary transform.
        reset(); tool("Move", "move");
        command({{"action", "setShowsTransformControls"}, {"enabled", true}});
        check(!window.sessionState().value("transforming").toBool(), "Show Controls armed an edit");
        drag(at(64, 64), at(48, 48));
        check(!window.sessionState().value("transforming").toBool(), "released handle drag left a transform open");
        check(pixels() != original, "native transform handle drag did not change pixels");
        gradient(at(4, 4), at(40, 40));
        key(canvas, Qt::Key_Z, Qt::ControlModifier); key(canvas, Qt::Key_Z, Qt::ControlModifier);
        check(pixels() == original, "transform/gradient Undo did not restore source pixels");
        qInfo("combo: transform handle release -> gradient -> Undo OK");

        // A pending gradient is committed by the next tool click before its stroke starts.
        reset(); tool("Marquee", "marquee"); drag(at(16, 16), at(32, 32));
        tool("Gradient", "gradient");
        drag(at(16, 16), at(31, 31));
        check(window.sessionState().value("gradientLine").toArray().size() == 4, "pending gradient missing before tool switch");
        const auto beforeRefusal = window.sessionState();
        const QImage beforeRefusalPixels = pixels();
        check(window.performAutosave(), "pending-gradient autosave failed");
        const auto afterAutosave = window.sessionState();
        for (const char *field : {"layers", "activeLayerID", "gradientLine", "modified", "undoName", "redoName"})
            check(afterAutosave.value(field) == beforeRefusal.value(field), "autosave changed a pending gradient or its history");
        check(pixels() == beforeRefusalPixels, "autosave changed pending-gradient pixels");
        const QDir recoveryImages(window.autosaveDirectory() + "/autosave.comp/images");
        const auto recoveryPNGs = recoveryImages.entryList({"*.png"}, QDir::Files);
        check(recoveryPNGs.size() == 1, "pending-gradient autosave source image missing");
        const QImage recoveredSource(recoveryImages.filePath(recoveryPNGs.first()));
        check(recoveredSource.size() == fixture.size(), "pending-gradient autosave source dimensions changed");
        for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x)
            check(recoveredSource.pixelColor(x, y) == fixture.pixelColor(x, y),
                  "pending-gradient autosave did not retain the committed source pixels");
        qInfo("Qt pending-gradient autosave OK (frozen committed snapshot, unchanged live draft/pixels/history)");
        const QJsonObject invalidRequests[] = {
            {{"action", "unknownAction"}},
            {{"action", "new"}, {"width", 0}, {"height", 64}},
            {{"action", "selectLayer"}},
            {{"action", "selectLayer"}, {"layerID", QUuid::createUuid().toString(QUuid::WithoutBraces)}},
            {{"action", "renameLayer"}},
            {{"action", "setOpacity"}},
            {{"action", "selectTool"}, {"kind", "invalid"}},
            {{"action", "openFilter"}, {"kind", "invalid"}},
            {{"action", "resizeCanvas"}, {"width", 64}, {"height", 64}, {"parameters", QJsonObject{{"anchor", 9}}}},
            {{"action", "importFiles"}, {"paths", QJsonArray{}}},
            {{"action", "featherSelection"}, {"parameters", QJsonObject{{"amount", 1e300}}}},
            {{"action", "expandSelection"}, {"parameters", QJsonObject{{"amount", 1e300}}}},
            {{"action", "contractSelection"}, {"parameters", QJsonObject{{"amount", 1e300}}}},
            {{"action", "setSelectionExpandAmount"}, {"parameters", QJsonObject{{"amount", 1e300}}}},
            {{"action", "moveActiveLayer"}, {"value", 1e300}},
            {{"action", "magicWand"}, {"x", 4}, {"y", 3}, {"parameters", QJsonObject{{"tolerance", 1e300}}}},
            {{"action", "distortDragBegin"}, {"x", 4}, {"y", 3}, {"value", 1e300}},
            {{"action", "brushBegin"}, {"x", 4}, {"y", 3}, {"parameters", QJsonObject{{"healing", 1}, {"healingMode", 1e300}}}}
        };
        for (const auto &request : invalidRequests) {
            check(!window.sendCommand(request), "invalid command was accepted while a gradient was pending");
            QApplication::processEvents();
            const auto afterRefusal = window.sessionState();
            for (const char *field : {"width", "height", "layers", "activeLayerID", "gradientLine", "tool",
                                     "modified", "canUndo", "canRedo", "undoName", "redoName"}) {
                if (afterRefusal.value(field) != beforeRefusal.value(field))
                    qWarning() << "invalid request changed" << field << "request=" << request
                               << "before=" << beforeRefusal.value(field) << "after=" << afterRefusal.value(field);
                check(afterRefusal.value(field) == beforeRefusal.value(field), "invalid command changed the pending document or history");
            }
            check(pixels() == beforeRefusalPixels, "invalid command changed pending-gradient pixels");
        }
        qInfo("combo: invalid command refusal preserves pending gradient, pixels and history OK (unsupported, size, layer, opacity, tool/filter, anchor, empty import and integer overflow)");
        tool("Brush", "brush");
        pump([&] { return window.sessionState().value("gradientLine").toArray().isEmpty()
                          && window.sessionState().value("canUndo").toBool(); });
        const QImage committedGradient = pixels();
        check(committedGradient != original, "tool switch discarded the pending gradient");
        drag(at(24, 24), at(26, 24));
        unchangedOutside(original, pixels(), QRect(16, 16, 16, 16));
        key(canvas, Qt::Key_Z, Qt::ControlModifier);
        check(pixels() == committedGradient, "brush Undo did not retain the previously committed gradient");
        key(canvas, Qt::Key_Z, Qt::ControlModifier);
        check(pixels() == original, "pending-gradient Undo did not restore the source pixels");
        qInfo("combo: pending gradient -> brush -> two Undo steps OK");

        // Type owns typing and local Undo while focused; a tool click finishes it. Gradient Undo restores live text.
        reset(); tool("Marquee", "marquee"); drag(at(0, 0), at(32, 64));
        tool("Type", "type"); drag(at(4, 4), at(4, 4));
        auto *editor = window.findChild<QPlainTextEdit *>("canvas.textEditor");
        check(editor && editor->isVisible(), "native text click did not show the inline editor");
        key(editor, Qt::Key_H, Qt::NoModifier, "H"); key(editor, Qt::Key_I, Qt::NoModifier, "i");
        check(editor->toPlainText() == "Hi" && window.sessionState().value("tool").toString() == "type",
              "typing triggered a canvas tool shortcut");
        key(editor, Qt::Key_Z, Qt::ControlModifier);
        check(editor->toPlainText() != "Hi", "focused text Undo did not edit the text");
        key(editor, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
        check(editor->toPlainText() == "Hi", "focused text Redo did not restore typing");
        tool("Gradient", "gradient");
        pump([&] { return !editor->isVisible() && window.sessionState().value("textDraft").toObject().isEmpty(); },
             "tool switch did not finish the native inline text editor");
        check(window.sessionState().value("layers").toArray().size() == 2, "tool switch did not commit text");
        const QImage liveText = pixels();
        gradient(at(4, 4), at(48, 48));
        unchangedOutside(liveText, pixels(), QRect(0, 0, 32, 64));
        key(canvas, Qt::Key_Z, Qt::ControlModifier);
        tool("Move", "move");
        mouse(canvas, QEvent::MouseButtonDblClick, at(8, 12), Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
        mouse(canvas, QEvent::MouseButtonRelease, at(8, 12), Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
        pump([&] { return editor->isVisible(); }, "gradient Undo did not reopen the live-text editor");
        check(editor->toPlainText() == "Hi" && window.sessionState().value("layers").toArray().size() == 2,
              "gradient Undo did not restore editable text");
        qInfo("combo: text focus/local Undo -> gradient -> live-text Undo OK");

        // G during an active brush drag is refused, silently; after release the same shortcut works.
        tool("Brush", "brush");
        mouse(canvas, QEvent::MouseButtonPress, at(24, 24), Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
        check(window.sessionState().value("busy").toBool(), "native brush press did not start a stroke");
        check(!window.sendCommand({{"action", "selectTool"}, {"kind", "gradient"}}),
              "bridge accepted a tool switch during a native stroke");
        checkTool("Brush", "brush");
        check(window.statusBar()->currentMessage().isEmpty(), "bridge refusal displayed a status-bar error");
        key(canvas, Qt::Key_G, Qt::NoModifier, "g"); checkTool("Brush", "brush");
        check(window.sessionState().value("gradientLine").toArray().isEmpty(), "refused switch started a gradient");
        check(window.statusBar()->currentMessage().isEmpty(), "refused shortcut displayed a status-bar error");
        mouse(canvas, QEvent::MouseButtonRelease, at(24, 24), Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
        pump([&] { return !window.sessionState().value("busy").toBool()
                          && window.sessionState().value("canUndo").toBool(); });
        key(canvas, Qt::Key_G, Qt::NoModifier, "g");
        pump([&] { return window.sessionState().value("tool").toString() == "gradient"; });
        checkTool("Gradient", "gradient");
        qInfo("combo: refused shortcut during stroke -> release -> recovery OK");

        inputTargets();

        // Upstream CameraRawSlider's sizeThatFits must reach its lowered Qt slider, including after layout.
        reset();
        const QImage beforeRaw = pixels();
        const QJsonObject beforeRawState = window.sessionState();
        command({{"action", "openFilter"}, {"kind", "Camera Raw Filter"}});
        const auto rawPanel = [&]() -> QDialog * {
            for (auto *top : QApplication::topLevelWidgets())
                if (auto *dialog = qobject_cast<QDialog *>(top); dialog &&
                    dialog->objectName() == QLatin1String("floatingPanel.FilterSheet") && dialog->isVisible()) return dialog;
            return nullptr;
        };
        const auto temperatureSlider = [&]() -> QWidget * {
            if (auto *panel = rawPanel())
                for (auto *widget : panel->findChildren<QSlider *>())
                    for (auto *owner = static_cast<QWidget *>(widget); owner && owner != panel; owner = owner->parentWidget())
                        if (owner->accessibleName() == QLatin1String("Shifts the picture from blue to yellow.") ||
                            owner->toolTip() == QLatin1String("Shifts the picture from blue to yellow.")) return widget;
            return nullptr;
        };
        pump([&] { return temperatureSlider() != nullptr; }, "Camera Raw temperature slider missing from Qt panel");
        auto *temperature = temperatureSlider();
        check(temperature->height() == 22 && temperature->width() > 0, "Camera Raw custom size did not reach Qt widget");
        auto *panel = rawPanel();
        const auto dockedRawFrame = [&]() {
            const auto *current = rawPanel();
            if (!current) return false;
            const QRect owner = window.frameGeometry(), dock = current->frameGeometry();
            return current->width() == 440 && dock.height() == owner.height()
                && dock.right() == owner.right() && dock.top() == owner.top();
        };
        qInfo("Qt Camera Raw frame before docking check: client %dx%d, frame %d,%d %dx%d; document frame %d,%d %dx%d",
              panel->width(), panel->height(), panel->frameGeometry().x(), panel->frameGeometry().y(),
              panel->frameGeometry().width(), panel->frameGeometry().height(), window.frameGeometry().x(),
              window.frameGeometry().y(), window.frameGeometry().width(), window.frameGeometry().height());
        check(dockedRawFrame(), "Camera Raw panel did not inherit upstream docking width, height and right-edge placement");
        const QSize beforeDockResize = window.size();
        const QPoint beforeDockMove = window.pos();
        window.resize(beforeDockResize + QSize(80, 30));
        window.move(beforeDockMove + QPoint(40, 25));
        QApplication::processEvents();
        pump(dockedRawFrame, "Camera Raw panel did not follow document resize/move");
        panel->resize(panel->width() + 80, panel->height() + 30);
        QApplication::processEvents();
        check(dockedRawFrame(), "manual resize broke Camera Raw docking bounds");
        temperature = temperatureSlider();
        check(temperature && temperature->height() == 22 && temperature->width() > 0,
              "Camera Raw custom height changed during Qt panel layout");
        bool rawFooterVisible = false;
        for (auto *button : rawPanel()->findChildren<QPushButton *>()) {
            if (button->text() != QLatin1String("OK") || !button->isVisible()) continue;
            const QRect rectangle(button->mapTo(rawPanel(), QPoint()), button->size());
            rawFooterVisible = rawPanel()->rect().contains(rectangle);
        }
        check(rawFooterVisible, "Camera Raw docking left its confirmation footer outside the panel");
        command({{"action", "filterCancel"}});
        command({{"action", "closeFloatingPanel"}, {"kind", "FilterSheet"}});
        pump([&] { return !window.sessionState().value("busy").toBool(); }, "Camera Raw cancellation left the editor busy");
        check(pixels() == beforeRaw, "Camera Raw sizing or cancellation changed document pixels");
        const QJsonObject afterRawState = window.sessionState();
        check(afterRawState.value("undoName") == beforeRawState.value("undoName")
              && afterRawState.value("canUndo") == beforeRawState.value("canUndo")
              && afterRawState.value("modified") == beforeRawState.value("modified"),
              "Camera Raw docking or cancellation changed document history or unsaved state");
        qInfo("Qt Camera Raw docking smoke OK (upstream width, outer height/right edge, document move/resize, bounded footer, 22-point slider, cancel pixels/history)");
        // Upstream's new transparency control must reach both the preview and committed layer through Qt.
        QImage colorFixture = fixture;
        for (int y = 16; y < 32; ++y) for (int x = 24; x < 32; ++x) colorFixture.setPixelColor(x, y, Qt::green);
        const QString colorPath = temporary.filePath("blur-colors.png");
        check(colorFixture.save(colorPath) && window.importImage(colorPath), "blur colors fixture import failed");
        const QImage beforeBlur = pixels();
        const auto beforeBlurTransform = window.sessionState().value("layers").toArray().first().toObject().value("transform");
        command({{"action", "openFilter"}, {"kind", "Gaussian Blur"}});
        const auto blurDialog = [&]() -> QDialog * {
            for (auto *top : QApplication::topLevelWidgets())
                if (auto *dialog = qobject_cast<QDialog *>(top); dialog && dialog->isVisible()
                    && dialog->objectName() == QLatin1String("floatingPanel.FilterSheet")) return dialog;
            return nullptr;
        };
        const auto transparency = [&]() -> QCheckBox * {
            if (auto *dialog = blurDialog()) for (auto *box : dialog->findChildren<QCheckBox *>())
                if (box->text() == QLatin1String("Preserve Transparency")) return box;
            return nullptr;
        };
        pump([&] { return transparency() != nullptr; }, "native blur transparency control missing");
        const QSize blurSize = blurDialog()->size();
        window.resize(window.width() + 30, window.height() + 20);
        QApplication::processEvents();
        check(blurDialog()->size() == blurSize, "ordinary filter panel inherited Camera Raw docking bounds");
        transparency()->click(); QApplication::processEvents();
        const auto blurOK = [&]() -> QPushButton * {
            if (auto *dialog = blurDialog()) for (auto *button : dialog->findChildren<QPushButton *>())
                if (button->text() == QLatin1String("OK")) return button;
            return nullptr;
        };
        pump([&] { return blurOK() && blurOK()->isEnabled(); }, "native blur OK remained disabled");
        blurOK()->click();
        pump([&] { return !window.sessionState().value("busy").toBool(); }, "native blur commit did not finish");
        const QImage afterBlur = pixels();
        check(afterBlur != beforeBlur, "transparency-preserving blur did not mix colors");
        for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x)
            check(afterBlur.pixelColor(x, y).alpha() == beforeBlur.pixelColor(x, y).alpha(), "native blur changed the original alpha");
        check(window.sessionState().value("layers").toArray().first().toObject().value("transform") == beforeBlurTransform,
              "native transparency-preserving blur grew or moved the layer");
        QApplication::setActiveWindow(&window); QApplication::processEvents();
        key(canvas, Qt::Key_Z, Qt::ControlModifier); check(pixels() == beforeBlur, "native blur Undo lost the source");
        key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier); check(pixels() == afterBlur, "native blur Redo lost the committed result");
        qInfo("Qt blur transparency OK (native toggle, alpha/geometry preservation, color mixing, Undo/Redo)");

        for (const QString mode : {QStringLiteral("Smudge"), QStringLiteral("Liquify")}) {
            check(window.importImage(colorPath), "native warp fixture import failed");
            tool("Smear", "blur");
            QAbstractButton *modeButton = nullptr;
            for (auto *button : window.findChildren<QAbstractButton *>())
                if (button->isVisible() && button->text() == mode) { modeButton = button; break; }
            check(modeButton, "native warp mode control missing");
            modeButton->click(); QApplication::processEvents();
            pump([&] { return window.sessionState().value("blurMode").toString() == mode; }, "native warp mode did not reach upstream");
            command({{"action", "setBrushSettings"}, {"parameters", QJsonObject{{"diameter", 31.5}, {"hardness", 0.5}, {"opacity", 0.7}}}});
            const QImage beforeWarp = pixels();
            mouse(canvas, QEvent::MouseButtonPress, at(18, 18), Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
            for (const QPointF point : {QPointF(40, 20), QPointF(25, 40), QPointF(12, 15)})
                mouse(canvas, QEvent::MouseMove, at(point.x(), point.y()), Qt::NoButton, Qt::LeftButton, Qt::NoModifier);
            mouse(canvas, QEvent::MouseButtonRelease, at(12, 15), Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
            pump([&] { return window.sessionState().value("undoName").toString() == mode; }, "native warp release did not commit queued dabs");
            const QImage afterWarp = pixels();
            check(afterWarp != beforeWarp, "native warp did not change pixels");
            key(canvas, Qt::Key_Z, Qt::ControlModifier); check(pixels() == beforeWarp, "native warp Undo did not restore pixels");
            key(canvas, Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier); check(pixels() == afterWarp, "native warp Redo did not restore pixels");
        }
        qInfo("Qt queued warp strokes OK (native Smudge/Liquify mode controls, pointer turns, release, Undo/Redo)");
        qInfo("Qt tool combination smoke OK (native pointer/key journeys)");
        return 0;
    } catch (const std::exception &e) {
        qCritical("Qt tool combination smoke failed: %s", e.what());
        return 1;
    }
}

extern "C" int compositor_host_color_range_smoke(int argc, char **argv) {
    QApplication app(argc, argv);
    installJourneyUI(app);
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
    QString chooseProjectSavePath(const QString &) override { if (beforeSave) beforeSave(); return projectSavePath; }
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
    installJourneyUI(app);
    systemclipboard::install();   // This entry bypasses host_run's desktop pasteboard setup.
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
            // Upstream CommandPaletteView: panel.setContentSize(NSSize(width: 460, height: 290)).
            require(dialog->size() == QSize(460, 290) && dialog->minimumWidth() == 460 && dialog->minimumHeight() == 290,
                    "command palette ignored its upstream content size");
            filter->setText("Canvas");
            require(list->count() > 0, "command palette search for 'Canvas' returned no items");
            // Upstream CommandPaletteView: its placeholder, the "No commands match" overlay, shortcuts in their own
            // column (not appended to the title).
            require(filter->placeholderText() == QLatin1String("Search commands and tools"), "command palette placeholder differs from upstream");
            auto *empty = dialog->findChild<QLabel *>("commandPalette.empty");
            require(empty && empty->isHidden(), "command palette shows its empty state over results");
            filter->setText("zzzzqq");
            require(list->count() == 0 && !empty->isHidden() && empty->text() == QLatin1String("No commands match"),
                    "command palette lacks upstream's 'No commands match'");
            filter->setText("Copy");
            bool shortcutColumn = false;
            for (int row = 0; row < list->count(); ++row) {
                const auto *item = list->item(row);
                const QString shortcut = item->data(Qt::UserRole + 2).toString();
                if (!shortcut.isEmpty() && !item->text().contains(shortcut)) shortcutColumn = true;
            }
            require(shortcutColumn, "command palette shortcuts are not in their own column");
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
            QApplication::clipboard()->clear();
            action("Copy")->trigger();
            // Selection Clipboard writes through SystemClipboard → QClipboard (not IClipboardService).
            require(QApplication::clipboard()->mimeData()
                        && QApplication::clipboard()->mimeData()->hasImage()
                        && !QApplication::clipboard()->image().isNull(),
                    "copy did not reach the system clipboard");
            require(injected.performAutosave(), "autosave failed against the injected storage");
            require(QDir(temporary.filePath("appdata/recovery")).exists(), "autosave ignored the injected storage locator");
        }

        // Copy Merged + Paste via Edit menu: selection pixels from every visible layer, placed in situ —
        // not the full canvas (the old shell overwrite) and not a centered import_rgba dump.
        {
            require(window.sendCommand({{"action", "selectRectangle"}, {"x", 4}, {"y", 4}, {"width", 40}, {"height", 40}}),
                    "selection for Copy Merged failed");
            QAction *copyMerged = nullptr;
            QAction *paste = nullptr;
            for (QAction *a : window.findChildren<QAction *>()) {
                const QString clean = a->text().remove('&');
                if (clean == QLatin1String("Copy Merged")) copyMerged = a;
                if (clean == QLatin1String("Paste")) paste = a;
            }
            require(copyMerged && paste, "Copy Merged / Paste menu actions missing");
            const int layersBefore = window.sessionState().value("layers").toArray().size();
            copyMerged->trigger();
            QApplication::processEvents();
            paste->trigger();
            QApplication::processEvents();
            require(window.sessionState().value("layers").toArray().size() == layersBefore + 1,
                    "Copy Merged → Paste did not add a layer");
            require(window.sessionState().value("undoName").toString() == QLatin1String("Paste"),
                    "Paste undo name missing after Copy Merged");
        }

        // Multi-layer panel selection: Cut clears the marquee on every selected pixel layer (one undo).
        {
            require(window.sendCommand({{"action", "addLayer"}}), "addLayer for multi-cut failed");
            const QJsonArray layers = window.sessionState().value("layers").toArray();
            require(layers.size() >= 2, "need two layers for multi-cut");
            const QString bottom = layers.at(0).toObject().value("id").toString();
            const QString top = layers.at(1).toObject().value("id").toString();
            // Paint opaque pixels on both layers inside the upcoming marquee.
            require(window.sendCommand({{"action", "selectLayer"}, {"layerID", bottom}}), "select bottom to paint failed");
            require(window.sendCommand({{"action", "selectRectangle"}, {"x", 4}, {"y", 4}, {"width", 40}, {"height", 40}}),
                    "marquee for bottom fill failed");
            require(window.sendCommand({{"action", "fillForeground"}}), "fill bottom for multi-cut failed");
            require(window.sendCommand({{"action", "selectLayer"}, {"layerID", top}}), "select top to paint failed");
            require(window.sendCommand({{"action", "selectRectangle"}, {"x", 4}, {"y", 4}, {"width", 40}, {"height", 40}}),
                    "marquee for top fill failed");
            require(window.sendCommand({{"action", "fillForeground"}}), "fill top for multi-cut failed");
            require(window.sendCommand({{"action", "selectLayer"}, {"layerID", bottom}}), "select bottom failed");
            require(window.sendCommand({{"action", "selectLayer"}, {"layerID", top}, {"enabled", true}}),
                    "additive select top failed");
            require(window.sendCommand({{"action", "selectLayer"}, {"layerID", bottom}, {"enabled", true}}),
                    "re-primary bottom while multi-selected failed");
            require(window.sendCommand({{"action", "selectRectangle"}, {"x", 4}, {"y", 4}, {"width", 40}, {"height", 40}}),
                    "selection for multi-cut failed");
            const QImage beforeCut = exported(window, temporary.filePath("before-multi-cut.png"));
            require(beforeCut.pixelColor(20, 20).alpha() > 200, "multi-cut fixture missing opaque pixels");
            QAction *cut = nullptr;
            for (QAction *a : window.findChildren<QAction *>()) {
                if (a->text().remove('&') == QLatin1String("Cut")) { cut = a; break; }
            }
            require(cut, "Cut menu action missing");
            cut->trigger();
            QApplication::processEvents();
            require(window.sessionState().value("undoName").toString() == QLatin1String("Clear"),
                    "Cut with multi-layer selection did not clear");
            const QImage afterCut = exported(window, temporary.filePath("after-multi-cut.png"));
            require(afterCut.pixelColor(20, 20).alpha() < 10,
                    "Cut with all layers selected did not cut through the stack");
            // Leave a clean single-layer selection so later Type→Gradient transitions are not blocked.
            require(window.sendCommand({{"action", "deselect"}}), "deselect after multi-cut failed");
            require(window.sendCommand({{"action", "selectLayer"}, {"layerID", top}}), "restore single layer failed");
            window.setTool(SessionWindow::Tool::Move);
            QApplication::processEvents();
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
    installJourneyUI(app);
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
    installJourneyUI(app);
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
            require(w2.sessionState().value("canUndo").toBool(), "transform edits left no history entry");
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
    installJourneyUI(app);
    try {
        QTemporaryDir temporary;
        require(temporary.isValid(), "temporary directory failed");
        SessionWindow window;
        window.initDemoDocument();
        const QString source = temporary.filePath("source.comp");
        require(window.writeProjectPackage(source), "template save failed");
        require(QFileInfo::exists(source + "/QuickLook/Preview.jpg"),
                "QuickLook/Preview.jpg missing after save (Finder Quick Look twin)");
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
        for (int version : {0, savedManifest.value("version").toInt() + 1, 999}) {
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
extern "C" int64_t compositor_session_state(uint64_t, uint8_t *, size_t);
extern "C" int32_t compositor_session_command(uint64_t, const uint8_t *, size_t);

extern "C" int compositor_host_preview_smoke(int argc, char **argv) {
    QApplication app(argc, argv);
    installJourneyUI(app);
    try {
        QTemporaryDir temporary;
        SessionWindow window;
        window.resize(1200, 800); window.show(); QApplication::setActiveWindow(&window); QApplication::processEvents();
        require(window.minimumWidth() == 800 && window.minimumHeight() == 520,
                "native main-window minimum differs from upstream ContentView");
        window.resize(400, 200); QApplication::processEvents();
        require(window.width() >= 800 && window.height() >= 520, "native window manager did not enforce content minimums");
        window.resize(1200, 800); QApplication::processEvents();
        require(window.width() == 1200 && window.height() == 800, "native window could not grow beyond its content minimums");
        verifyRawControls([&](const QString &path) {
            for (const QString &variant : {QStringLiteral("single"), QStringLiteral("mixed"), QStringLiteral("folder"), QStringLiteral("window")}) {
                const QString folder = temporary.filePath("raw-replacement-" + variant);
                require(QDir().mkpath(folder), "RAW replacement folder failed");
                const QString prefix = folder + "/1 Prefix.png";
                QImage prefixImage(32, 16, QImage::Format_RGBA8888); prefixImage.fill(QColor(170, 40, 90));
                require(prefixImage.save(prefix), "RAW replacement prefix failed");
                QJsonArray importPaths{path};
                if (variant == QLatin1String("mixed")) importPaths = QJsonArray{prefix, path};
                if (variant == QLatin1String("folder")) {
                    require(QFile::copy(path, folder + "/2 Sensor.dng"), "RAW replacement folder sensor failed");
                    importPaths = QJsonArray{folder};
                }
                require(window.sendCommand({{"action", "new"}, {"width", 32}, {"height", 16}, {"emptyLayer", true}}), "RAW replacement canvas failed");
                require(window.sendCommand({{"action", "gradientBegin"}, {"x", 0}, {"y", 0}})
                        && window.sendCommand({{"action", "gradientMove"}, {"x", 31}, {"y", 15}})
                        && window.sendCommand({{"action", "gradientEndDrag"}}), "RAW replacement gradient failed");
                const auto beforeRaw = window.sessionState();
                QByteArray beforeRawPixels(32 * 16 * 4, Qt::Uninitialized);
                require(compositor_session_render(window.sessionHandle(), reinterpret_cast<uint8_t *>(beforeRawPixels.data()), beforeRawPixels.size()) == beforeRawPixels.size(), "RAW replacement pixels failed");
                QTimer inspector;
                inspector.setInterval(20);
                QElapsedTimer elapsed; elapsed.start();
                QString failure;
                int phase = 0, initialNoise = -1;
                bool finished = false;
                QObject::connect(&inspector, &QTimer::timeout, &window, [&] {
                    QDialog *dialog = nullptr;
                    for (auto *top : QApplication::topLevelWidgets())
                        if (auto *candidate = qobject_cast<QDialog *>(top); candidate && candidate->isVisible()
                            && candidate->objectName() == QLatin1String("swiftUISheet.RawDevelopSheet")) dialog = candidate;
                    const auto fail = [&](const QString &message) {
                        failure = message; finished = true; inspector.stop();
                        if (dialog) dialog->reject();
                    };
                    if (elapsed.elapsed() > 8000) {
                        qWarning("RAW sheet timeout phase=%d visible=%d", phase, dialog != nullptr);
                        if (dialog) for (QWidget *control : dialog->findChildren<QWidget *>()) {
                            QString label;
                            if (auto *button = qobject_cast<QAbstractButton *>(control)) label = button->text();
                            if (auto *text = qobject_cast<QLabel *>(control)) label = text->text();
                            if (!label.isEmpty() || !control->toolTip().isEmpty() || qobject_cast<QSlider *>(control))
                                qWarning("RAW control %s text=%s enabled=%d tooltip=%s", control->metaObject()->className(), qPrintable(label), control->isEnabled(), qPrintable(control->toolTip()));
                        }
                        fail("RAW control sheet did not complete"); return;
                    }
                    if (!dialog) return;
                    QCheckBox *lens = nullptr, *highlight = nullptr;
                    QSlider *noise = nullptr;
                    QPushButton *reset = nullptr, *cancel = nullptr;
                    for (auto *control : dialog->findChildren<QCheckBox *>()) {
                        if (control->text() == QLatin1String("Lens Correction")) lens = control;
                        if (control->text() == QLatin1String("Highlight Recovery")) highlight = control;
                    }
                    for (auto *slider : dialog->findChildren<QSlider *>())
                        for (QWidget *owner = slider; owner && owner != dialog; owner = owner->parentWidget())
                            if (owner->toolTip().contains("Smooths grain")) { noise = slider; break; }
                    for (auto *button : dialog->findChildren<QPushButton *>()) {
                        if (button->text() == QLatin1String("Reset")) reset = button;
                        if (button->text() == QLatin1String("Cancel")) cancel = button;
                    }
                    if (!lens || !highlight || !noise || !reset || !cancel) return;
                    if (lens->isEnabled() || lens->toolTip() != QLatin1String("This file has no lens profile")) { fail("RAW lens capability/tooltip was dishonest"); return; }
                    if (!noise->isEnabled() || !highlight->isEnabled()) { fail("RAW supported controls were disabled"); return; }
                    if (phase == 0) {
                        if (window.sendCommand({{"action", "new"}, {"width", 64}, {"height", 64}})) { fail("RAW replacement allowed a nested document command"); return; }
                        initialNoise = noise->value();
                        noise->setValue((noise->minimum() + noise->maximum()) / 2);
                        highlight->click(); phase = 1;
                    } else if (phase == 1 && reset->isEnabled()) {
                        reset->click(); phase = 2;
                    } else if (phase == 2 && !reset->isEnabled()) {
                        if (noise->value() != initialNoise || highlight->isChecked()) { fail("RAW Reset did not restore decoder defaults"); return; }
                        finished = true; inspector.stop();
                        if (variant == QLatin1String("window")) dialog->reject(); else cancel->click();
                    }
                });
                inspector.start();
                const bool imported = window.sendCommand({{"action", "importFiles"}, {"paths", importPaths}, {"enabled", true}});
                while (!finished && elapsed.elapsed() < 9000) QApplication::processEvents(QEventLoop::AllEvents, 10);
                inspector.stop();
                require(finished && failure.isEmpty(), failure.isEmpty() ? "RAW sheet controls unavailable" : qPrintable(failure));
                require(!imported, "RAW replacement Cancel imported a layer");
                const auto afterRaw = window.sessionState();
                for (const char *field : {"width", "height", "layers", "activeLayerID", "modified", "canUndo", "canRedo", "undoName", "redoName", "gradientLine"})
                    require(afterRaw.value(field) == beforeRaw.value(field), "RAW replacement Cancel changed the original document or draft/history");
                QByteArray afterRawPixels(beforeRawPixels.size(), Qt::Uninitialized);
                require(compositor_session_render(window.sessionHandle(), reinterpret_cast<uint8_t *>(afterRawPixels.data()), afterRawPixels.size()) == afterRawPixels.size()
                        && afterRawPixels == beforeRawPixels, "RAW replacement Cancel changed pending pixels");
                require(window.sendCommand({{"action", "gradientCancel"}}) && window.sendCommand({{"action", "undo"}})
                        && window.sessionState().value("layers").toArray().isEmpty(), "RAW replacement Cancel lost draft cancellation or Undo");
                require(window.sendCommand({{"action", "importFiles"}, {"paths", QJsonArray{prefix}}, {"enabled", true}})
                        && window.sessionState().value("layers").toArray().size() == 1, "RAW replacement Cancel blocked a valid retry");
                require(window.sendCommand({{"action", "undo"}}) && window.sessionState().value("layers").toArray().isEmpty(),
                        "RAW replacement retry lost Undo to welcome");
                QApplication::setActiveWindow(&window);
                qInfo("Qt RAW replacement cancellation OK (%s: no partial import, draft/pixels/history retained, nested refusal and valid retry)", qPrintable(variant));
            }
            qInfo("Qt RAW develop sheet OK (supported controls, disabled lens explanation, Reset, single/mixed/folder replacement cancellation)");
            for (bool cameraRaw : {false, true}) for (bool mixed : {false, true}) {
                const QString suffix = temporary.filePath("After.png");
                QImage suffixImage(32, 16, QImage::Format_RGBA8888); suffixImage.fill(Qt::green);
                require(suffixImage.save(suffix), "RAW Camera Raw suffix failed");
                QJsonArray paths{path};
                if (mixed) paths.append(suffix);
                require(window.sendCommand({{"action", "new"}, {"width", 32}, {"height", 16}, {"emptyLayer", true}}),
                        "RAW Camera Raw fixture failed");
                QTimer chooser; chooser.setInterval(20);
                QElapsedTimer elapsed; elapsed.start();
                bool clicked = false;
                QString failure;
                QObject::connect(&chooser, &QTimer::timeout, &window, [&] {
                    for (auto *top : QApplication::topLevelWidgets()) {
                        auto *dialog = qobject_cast<QDialog *>(top);
                        if (!dialog || !dialog->isVisible() || dialog->objectName() != QLatin1String("swiftUISheet.RawDevelopSheet")) continue;
                        if (elapsed.elapsed() > 8000) { failure = "RAW Camera Raw button unavailable"; chooser.stop(); dialog->reject(); return; }
                        for (auto *button : dialog->findChildren<QPushButton *>())
                            if (button->isEnabled() && (cameraRaw ? button->text().startsWith("Camera Raw") : button->text() == "Import")) {
                                clicked = true; chooser.stop(); button->click(); return;
                            }
                    }
                });
                chooser.start();
                const bool imported = window.sendCommand({{"action", "importFiles"}, {"paths", paths}, {"enabled", true}});
                chooser.stop();
                require(imported && clicked && failure.isEmpty(), "RAW Camera Raw import did not finish");
                QApplication::processEvents();
                const auto state = window.sessionState();
                const auto layers = state.value("layers").toArray();
                require(layers.size() == (mixed ? 2 : 1) && !state.value("rawDevelopOpen").toBool(), "RAW Camera Raw import changed layer count or left its sheet open");
                bool opened = false;
                for (const auto &panel : state.value("floatingPanels").toArray())
                    opened |= panel.toObject().value("panel") == "FilterSheet" && panel.toObject().value("title") == "Camera Raw Filter";
                require(opened == cameraRaw, "RAW Import/Camera Raw choice opened the wrong filter state");
                if (cameraRaw) {
                    QJsonObject active;
                    for (const auto &layer : layers)
                        if (layer.toObject().value("id") == state.value("activeLayerID")) active = layer.toObject();
                    require(active.value("name").toString() == QFileInfo(path).completeBaseName(), "Camera Raw opened on the later PNG rather than the RAW layer");
                    QDialog *panel = nullptr;
                    for (auto *top : QApplication::topLevelWidgets())
                        if (auto *candidate = qobject_cast<QDialog *>(top); candidate && candidate->isVisible()
                            && candidate->objectName() == QLatin1String("floatingPanel.FilterSheet")) panel = candidate;
                    require(panel && panel->isVisible(), "Camera Raw filter panel did not appear after RAW import");
                    require(window.sendCommand({{"action", "filterCancel"}}), "imported Camera Raw filter did not cancel");
                    require(window.sessionState().value("layers") == layers && !window.sessionState().value("busy").toBool(),
                            "Camera Raw cancellation changed imported layers or remained busy");
                }
                require(window.sendCommand({{"action", "undo"}}) && window.sessionState().value("width").toInt() == 0,
                        "RAW import did not retain Undo to welcome");
                require(window.sendCommand({{"action", "redo"}}) && window.sessionState().value("layers") == layers,
                        "RAW import Redo did not retain layer identity and state");
                require(window.sendCommand({{"action", "undo"}}) && window.sessionState().value("width").toInt() == 0,
                        "RAW Camera Raw fixture did not return to welcome");
                qInfo("Qt RAW import to Camera Raw Filter OK (%s, %s, correct layer, panel/cancel, import Undo/Redo)",
                      cameraRaw ? "Camera Raw" : "Import", mixed ? "mixed" : "single");
            }
        });
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
            if (type == QEvent::MouseButtonPress) disablePixelOracleSnapping(window);
            const auto pos = window.documentToCanvasPoint(documentPoint);
            QMouseEvent event(type, pos, canvas->mapToGlobal(pos),
                type == QEvent::MouseMove ? Qt::NoButton : Qt::LeftButton,
                type == QEvent::MouseButtonRelease ? Qt::NoButton : Qt::LeftButton, modifiers);
            QApplication::sendEvent(canvas, &event);
            window.flushPendingDrag();
            QApplication::processEvents();
        };
        const auto checkMaskToggle = [&] {
            for (bool group : {false, true}) {
                fresh();
                if (group) command({{"action", "groupSelectedLayers"}});
                command({{"action", "addHideMask"}});
                const auto hidden = frame();
                require(static_cast<uint8_t>(pixel(hidden, 32, 16)[3]) == 0, "hide mask did not hide pixels");
                const QPointF pos(group ? 98 : 106, 26);
                const auto maskAtPoint = [&](QWidget *candidate, QByteArray *snapshot = nullptr) {
                    const QString location = candidate->property("appKitNode").toString();
                    const int split = location.indexOf('|');
                    const QByteArray panel = location.left(split).toUtf8(), node = location.mid(split + 1).toUtf8();
                    const auto handle = candidate->property("appKitSession").toULongLong();
                    const auto size = compositor_session_accessibility_tree(handle, panel.constData(), node.constData(), nullptr, 0);
                    if (size <= 0 || size >= 1024 * 1024) return false;
                    QByteArray bytes(qsizetype(size), Qt::Uninitialized);
                    if (compositor_session_accessibility_tree(handle, panel.constData(), node.constData(),
                        reinterpret_cast<uint8_t *>(bytes.data()), bytes.size()) != bytes.size()) return false;
                    bool found = false;
                    std::function<void(const QJsonObject &)> inspect = [&](const QJsonObject &entry) {
                        const QRectF rect(entry.value("x").toDouble(), entry.value("y").toDouble(),
                                          entry.value("width").toDouble(), entry.value("height").toDouble());
                        if (entry.value("label").toString().startsWith("Select mask:") && rect.contains(pos)) found = true;
                        for (const auto &child : entry.value("children").toArray()) inspect(child.toObject());
                    };
                    inspect(QJsonDocument::fromJson(bytes).object());
                    if (snapshot) *snapshot = bytes;
                    return found;
                };
                QWidget *table = nullptr;
                QElapsedTimer ready; ready.start();
                while (!table && ready.elapsed() < 5000) {
                    for (auto *candidate : window.findChildren<QWidget *>()) {
                        if (!candidate->isVisible() || !candidate->property("appKitView").toBool()
                            || candidate->property("appKitSession").toULongLong() != window.sessionHandle()
                            || !candidate->property("appKitNode").toString().startsWith("LayersPanel|")) continue;
                        QScrollArea *scroll = nullptr;
                        for (auto *parent = candidate->parentWidget(); parent; parent = parent->parentWidget())
                            if ((scroll = qobject_cast<QScrollArea *>(parent))) break;
                        const QPoint global = candidate->mapToGlobal(pos.toPoint());
                        auto *hit = window.childAt(window.mapFromGlobal(global));
                        if (scroll && scroll->viewport()->rect().contains(scroll->viewport()->mapFromGlobal(global))
                            && (hit == candidate || (hit && candidate->isAncestorOf(hit))) && maskAtPoint(candidate)) {
                            table = candidate; break;
                        }
                    }
                    if (!table) { QApplication::processEvents(QEventLoop::AllEvents, 10); QThread::msleep(1); }
                }
                if (!table) {
                    qWarning() << "mask readiness timeout group/current session/layers" << group << window.sessionHandle()
                               << window.sessionState().value("layers");
                    for (auto *candidate : window.findChildren<QWidget *>()) {
                        if (!candidate->isVisible() || !candidate->property("appKitView").toBool()
                            || !candidate->property("appKitNode").toString().startsWith("LayersPanel|")) continue;
                        QByteArray snapshot;
                        const bool nativeMask = maskAtPoint(candidate, &snapshot);
                        const QPoint global = candidate->mapToGlobal(pos.toPoint());
                        QScrollArea *scroll = nullptr;
                        for (auto *parent = candidate->parentWidget(); parent; parent = parent->parentWidget())
                            if ((scroll = qobject_cast<QScrollArea *>(parent))) break;
                        qWarning() << "mask readiness candidate/session/geometry/global/scroll/native mask" << candidate
                                   << candidate->property("appKitSession").toULongLong() << candidate->geometry() << global
                                   << (scroll ? scroll->verticalScrollBar()->value() : -1) << nativeMask;
                        qWarning().noquote() << "mask readiness native snapshot" << snapshot;
                    }
                }
                require(table, "active project's mask thumbnail did not become visible within five seconds");
                const QPointer<QWidget> clickedTable(table);
                // The root is row zero. Raster/folder masks follow the thumbnail's linked gap.
                QScrollArea *area = nullptr;
                for (auto *parent = table->parentWidget(); parent; parent = parent->parentWidget())
                    if ((area = qobject_cast<QScrollArea *>(parent))) break;
                const QPoint global = table->mapToGlobal(pos.toPoint());
                auto *hit = window.childAt(window.mapFromGlobal(global));
                const auto tableSession = table->property("appKitSession").toULongLong();
                const QRect tableBeforeClick = table->geometry();
                const int scrollBeforeClick = area ? area->verticalScrollBar()->value() : -1;
                const bool inViewport = area && area->viewport()->rect().contains(area->viewport()->mapFromGlobal(global));
                if (!inViewport || (hit != table && (!hit || !table->isAncestorOf(hit))))
                    qWarning() << "mask click target mismatch" << "group" << group << "table" << table->geometry()
                               << "scroll" << (area ? area->verticalScrollBar()->value() : -1)
                               << "global" << global << "hit" << hit << "in viewport" << inViewport;
                require(inViewport && (hit == table || (hit && table->isAncestorOf(hit))),
                        "mask synthetic click does not reach its visible table");
                require(tableSession == window.sessionHandle(), "mask synthetic click targets a different project");
                QByteArray accessibility;
                const bool hasMask = maskAtPoint(table, &accessibility);
                if (!hasMask) qWarning().noquote() << "mask row before click" << accessibility;
                require(hasMask, "mask thumbnail is not present at the native click point");
                QMouseEvent down(QEvent::MouseButtonPress, pos, table->mapToGlobal(pos), Qt::LeftButton, Qt::LeftButton, Qt::ShiftModifier);
                QMouseEvent up(QEvent::MouseButtonRelease, pos, table->mapToGlobal(pos), Qt::LeftButton, Qt::NoButton, Qt::ShiftModifier);
                QApplication::sendEvent(table, &down); QApplication::sendEvent(table, &up);
                QApplication::processEvents();
                const auto revealed = frame();
                const auto alpha = static_cast<uint8_t>(pixel(revealed, 32, 16)[3]);
                if (alpha != 255 || app.arguments().contains("--trace-layer-input")) {
                    const auto afterToggle = window.sessionState();
                    qWarning() << "mask toggle state group/alpha" << group << int(alpha)
                               << "after" << afterToggle.value("layers")
                               << "history" << afterToggle.value("undoName");
                    if (clickedTable) qWarning() << "mask table geometry" << clickedTable->geometry();
                    qWarning() << "mask table before click" << tableBeforeClick << "scroll" << scrollBeforeClick
                               << "table/current session" << tableSession << window.sessionHandle();
                    qWarning().noquote() << swiftUIPointerTrace();
                    qWarning().noquote() << swiftUIScrollTrace();
                    for (auto *area : window.findChildren<QScrollArea *>())
                        if (area->property("appKitScrollNode").toString().startsWith("LayersPanel|"))
                            qWarning() << "mask table scroll" << area->verticalScrollBar()->value() << area->viewport()->size();
                }
                require(alpha == 255, "Shift-click left stale mask coverage");
                command({{"action", "undo"}}); require(frame() == hidden, "mask toggle undo pixels differ");
                command({{"action", "redo"}}); require(frame() == revealed, "mask toggle redo pixels differ");
                qInfo("Qt mask Shift-click OK (folder=%d, exact alpha and Undo/Redo)", group);
            }
        };
        if (app.arguments().contains("--mask-scroll-replacement-probe")) {
            fresh();
            for (int i = 0; i < 25; ++i) command({{"action", "addLayer"}});
            QScrollArea *area = nullptr;
            for (auto *candidate : window.findChildren<QScrollArea *>())
                if (candidate->isVisible() && candidate->property("appKitScrollNode").toString().startsWith("LayersPanel|")) area = candidate;
            require(area && area->verticalScrollBar()->maximum() > 432, "mask replacement scroll fixture missing");
            area->verticalScrollBar()->setValue(432); QApplication::processEvents();
            checkMaskToggle();
            return 0;
        }
        if (app.arguments().contains("--mask-toggle-probe")) { checkMaskToggle(); return 0; }
        // A mixed native import uses the new upstream folder expansion, including natural name order and filtering.
        {
            const QString folderPath = temporary.filePath("Images");
            require(QDir().mkpath(folderPath + "/More") && QDir().mkpath(folderPath + "/Project.comp"), "folder import fixture failed");
            require(image.save(folderPath + "/10 Ten.png") && image.save(folderPath + "/2 Two.png")
                    && image.save(folderPath + "/.Hidden.png") && image.save(folderPath + "/More/Nested.png"), "folder images failed");
            QFile notes(folderPath + "/Notes.txt"); require(notes.open(QIODevice::WriteOnly), "folder notes failed"); notes.write("notes"); notes.close();
            ImageImportDialog importDialog("Images (*.png)", &window, [&] { return QStringList{imagePath}; }, [&] { return folderPath; });
            QTimer::singleShot(0, &importDialog, [&] {
                auto *confirm = importDialog.findChild<QPushButton *>("import.confirm");
                require(confirm && !confirm->isEnabled(), "empty import list was enabled");
                importDialog.findChild<QPushButton *>("import.addImages")->click();
                importDialog.findChild<QPushButton *>("import.addFolder")->click();
                importDialog.findChild<QPushButton *>("import.addFolder")->click();
                require(importDialog.selectedPaths() == QStringList{imagePath, folderPath}, "mixed import selection order or duplicate handling failed");
                auto *sources = importDialog.findChild<QListWidget *>("import.sources");
                sources->item(1)->setSelected(true);
                importDialog.findChild<QPushButton *>("import.remove")->click();
                require(importDialog.selectedPaths() == QStringList{imagePath}, "import selection removal failed");
                importDialog.findChild<QPushButton *>("import.addFolder")->click();
                confirm->click();
            });
            require(importDialog.exec() == QDialog::Accepted, "mixed import dialog did not confirm");
            QJsonArray importPaths; for (const QString &path : importDialog.selectedPaths()) importPaths.append(path);
            command({{"action", "importFiles"}, {"paths", importPaths}});
            const QJsonArray importedLayers = window.sessionState().value("layers").toArray();
            require(importedLayers.size() == 3 && importedLayers.at(0).toObject().value("name").toString() == "pattern"
                    && importedLayers.at(1).toObject().value("name").toString() == "2 Two"
                    && importedLayers.at(2).toObject().value("name").toString() == "10 Ten", "native folder import lost ordering or included unwanted files");
            qInfo("Qt folder import OK (mixed file/folder chooser, duplicate/removal handling, natural order, hidden/nested filtering)");
        }
        QApplication::setActiveWindow(&window);

        // Replacement decoding must leave the old document and its usable history intact on every failure.
        {
            fresh();
            command({{"action", "setOpacity"}, {"value", 0.5}});
            const auto before = window.sessionState();
            const QByteArray beforePixels = frame();
            const QString corruptPath = temporary.filePath("broken.png");
            QFile corrupt(corruptPath);
            require(corrupt.open(QIODevice::WriteOnly), "replacement failure fixture failed");
            corrupt.write("invalid PNG"); corrupt.close();
            for (const auto &paths : {QJsonArray{corruptPath + ".missing"}, QJsonArray{corruptPath}, QJsonArray{imagePath, corruptPath}}) {
                require(!window.sendCommand({{"action", "importFiles"}, {"paths", paths}, {"enabled", true}}),
                        "failed replacement import was accepted");
                const auto after = window.sessionState();
                for (const char *field : {"width", "height", "layers", "activeLayerID", "modified", "canUndo", "canRedo", "undoName", "redoName"})
                    require(after.value(field) == before.value(field), "failed replacement import changed the document or history");
                require(frame() == beforePixels, "failed replacement import changed pixels");
            }
            command({{"action", "undo"}});
            require(window.sessionState().value("canRedo").toBool(), "replacement failure lost usable Undo");
            command({{"action", "redo"}});
            require(frame() == beforePixels, "replacement failure lost usable Redo");
            command({{"action", "importFiles"}, {"paths", QJsonArray{imagePath}}, {"enabled", true}});
            command({{"action", "undo"}});
            require(window.sessionState().value("layers").toArray().isEmpty(), "replacement retry Undo did not return to welcome");
            command({{"action", "redo"}});
            require(window.sessionState().value("width").toInt() == 64, "replacement retry Redo failed");
            qInfo("Qt replacement import recovery OK (missing/corrupt/mixed failure, exact old pixels/history, Undo/Redo and valid retry)");
        }

        // A minimal layered PSD with unsupported Dissolve requires the original conversion sheet.
        {
            const auto u16 = [](QByteArray &bytes, quint16 value) {
                QDataStream out(&bytes, QIODevice::WriteOnly | QIODevice::Append); out << value;
            };
            const auto u32 = [](QByteArray &bytes, quint32 value) {
                QDataStream out(&bytes, QIODevice::WriteOnly | QIODevice::Append); out << value;
            };
            QByteArray extra;
            u32(extra, 0); u32(extra, 0);
            const QByteArray name("Dissolved"); extra.append(char(name.size())); extra.append(name);
            while ((extra.size() - 8) % 4) extra.append(char(0));
            QByteArray layerInfo;
            u16(layerInfo, 1);
            u32(layerInfo, 0); u32(layerInfo, 0); u32(layerInfo, 8); u32(layerInfo, 8);
            u16(layerInfo, 4);
            for (quint16 channel : {quint16(0xffff), quint16(0), quint16(1), quint16(2)}) {
                u16(layerInfo, channel); u32(layerInfo, 66);
            }
            layerInfo.append("8BIMdiss"); layerInfo.append(char(255)); layerInfo.append(QByteArray(3, char(0)));
            u32(layerInfo, extra.size()); layerInfo.append(extra);
            for (int channel : {255, 170, 40, 90}) { u16(layerInfo, 0); layerInfo.append(QByteArray(64, char(channel))); }
            if (layerInfo.size() % 2) layerInfo.append(char(0));
            QByteArray layerMask; u32(layerMask, layerInfo.size()); layerMask.append(layerInfo); u32(layerMask, 0);
            QByteArray psd("8BPS"); u16(psd, 1); psd.append(QByteArray(6, char(0)));
            u16(psd, 4); u32(psd, 8); u32(psd, 8); u16(psd, 8); u16(psd, 3);
            u32(psd, 0); u32(psd, 0); u32(psd, layerMask.size()); psd.append(layerMask);
            u16(psd, 0);
            for (int channel : {170, 40, 90, 255}) psd.append(QByteArray(64, char(channel)));
            const QString psdPath = temporary.filePath("conversion.psd");
            QFile file(psdPath); require(file.open(QIODevice::WriteOnly) && file.write(psd) == psd.size(), "conversion PSD fixture failed"); file.close();
            const QString folder = temporary.filePath("Photoshop Images");
            require(QDir().mkpath(folder) && QFile::copy(imagePath, folder + "/1 Prefix.png")
                    && QFile::copy(psdPath, folder + "/2 Converted.psd"), "conversion folder fixture failed");

            for (bool confirm : {false, true})
            for (const QString &variant : {QStringLiteral("single"), QStringLiteral("mixed"), QStringLiteral("folder")}) {
                fresh(); command({{"action", "setOpacity"}, {"value", 0.5}});
                const QByteArray beforeDraft = frame();
                command({{"action", "gradientBegin"}, {"x", 0}, {"y", 0}});
                command({{"action", "gradientMove"}, {"x", 63}, {"y", 31}});
                command({{"action", "gradientEndDrag"}});
                const auto before = window.sessionState(); const QByteArray beforePixels = frame();
                QJsonArray paths{psdPath};
                if (variant == QLatin1String("mixed")) paths = QJsonArray{imagePath, psdPath};
                if (variant == QLatin1String("folder")) paths = QJsonArray{folder};
                QTimer inspector; inspector.setInterval(20);
                QElapsedTimer elapsed; elapsed.start();
                bool finished = false; QString failure;
                QObject::connect(&inspector, &QTimer::timeout, &window, [&] {
                    QDialog *dialog = nullptr;
                    for (auto *top : QApplication::topLevelWidgets())
                        if (auto *candidate = qobject_cast<QDialog *>(top); candidate && candidate->isVisible()
                            && candidate->objectName() == QLatin1String("swiftUISheet.PSDConversionSheet")) dialog = candidate;
                    const auto fail = [&](const QString &message) {
                        failure = message; finished = true; inspector.stop(); if (dialog) dialog->reject();
                    };
                    if (elapsed.elapsed() > 8000) { fail("PSD conversion sheet timed out"); return; }
                    if (!dialog) return;
                    QPushButton *accept = nullptr, *cancel = nullptr;
                    for (auto *button : dialog->findChildren<QPushButton *>()) {
                        if (button->text() == QLatin1String("Import")) accept = button;
                        if (button->text() == QLatin1String("Cancel")) cancel = button;
                    }
                    if (!accept || !cancel || !accept->isEnabled()) return;
                    bool named = false, explained = false;
                    for (auto *label : dialog->findChildren<QLabel *>()) {
                        named |= label->text().contains("Dissolved"); explained |= label->text().contains("diss");
                    }
                    if (!named || !explained) { fail("PSD conversion report omitted the layer or unsupported blend explanation"); return; }
                    // Upstream PSDConversionSheet: .frame(minWidth: 520, minHeight: 360).
                    if (dialog->width() < 520 || dialog->height() < 360 || dialog->minimumSizeHint().width() < 520
                        || dialog->minimumSizeHint().height() < 360) {
                        fail(QString("PSD conversion sheet ignored its upstream minimum frame (%1x%2, minimum hint %3x%4)")
                             .arg(dialog->width()).arg(dialog->height()).arg(dialog->minimumSizeHint().width())
                             .arg(dialog->minimumSizeHint().height()));
                        return;
                    }
                    if (window.sendCommand({{"action", "new"}, {"width", 32}, {"height", 32}})) {
                        fail("PSD conversion allowed a nested document command"); return;
                    }
                    finished = true; inspector.stop(); (confirm ? accept : cancel)->click();
                });
                inspector.start();
                const bool imported = window.sendCommand({{"action", "importFiles"}, {"paths", paths}, {"enabled", true}});
                inspector.stop();
                require(finished && failure.isEmpty(), failure.isEmpty() ? "PSD conversion sheet was not presented" : qPrintable(failure));
                require(imported == confirm, "PSD conversion result disagreed with the modal choice");
                if (!confirm) {
                    const auto after = window.sessionState();
                    for (const char *field : {"width", "height", "layers", "activeLayerID", "modified", "canUndo", "canRedo", "undoName", "redoName", "gradientLine"})
                        require(after.value(field) == before.value(field), "PSD cancellation changed the original document or draft/history");
                    require(frame() == beforePixels, "PSD cancellation changed pending pixels");
                    command({{"action", "gradientCancel"}}); command({{"action", "undo"}}); command({{"action", "redo"}});
                    require(frame() == beforeDraft, "PSD cancellation lost usable Undo/Redo");
                } else {
                    const int width = variant == QLatin1String("single") ? 8 : 64;
                    const int height = variant == QLatin1String("single") ? 8 : 32;
                    const auto state = window.sessionState();
                    require(state.value("width").toInt() == width && state.value("height").toInt() == height
                            && state.value("gradientLine").toArray().isEmpty(), "PSD confirmation retained the old document or gradient");
                    bool converted = false;
                    for (const auto &value : state.value("layers").toArray()) {
                        const auto layer = value.toObject();
                        converted |= layer.value("name").toString() == QLatin1String("Dissolved")
                            && layer.value("blendMode").toString() == QLatin1String("Normal");
                    }
                    require(converted, "PSD confirmation did not convert Dissolve to Normal");
                    QByteArray pixels(width * height * 4, Qt::Uninitialized);
                    require(compositor_session_render(window.sessionHandle(), reinterpret_cast<uint8_t *>(pixels.data()), pixels.size()) == pixels.size(), "PSD confirmation pixels unavailable");
                    // Upstream preserves Photoshop coordinates unless a drop point explicitly requests centering.
                    const int sample = (4 * width + 4) * 4;
                    require(qAbs(int(uint8_t(pixels[sample])) - 170) <= 1 && qAbs(int(uint8_t(pixels[sample + 1])) - 40) <= 1
                            && qAbs(int(uint8_t(pixels[sample + 2])) - 90) <= 1 && uint8_t(pixels[sample + 3]) == 255,
                            "PSD confirmation changed imported pixels");
                    if (variant != QLatin1String("single")) {
                        const int outside = (16 * width + 32) * 4;
                        require(qAbs(int(uint8_t(pixels[outside])) - 96) <= 1 && qAbs(int(uint8_t(pixels[outside + 1])) - 96) <= 1
                                && qAbs(int(uint8_t(pixels[outside + 2])) - 100) <= 1 && uint8_t(pixels[outside + 3]) == 255,
                                "PSD confirmation shifted its coordinates or changed the earlier PNG outside its bounds");
                    }
                    command({{"action", "undo"}});
                    require(window.sessionState().value("layers").toArray().isEmpty(), "PSD replacement did not Undo in one step");
                    command({{"action", "redo"}});
                    require(window.sessionState().value("width").toInt() == width, "PSD replacement Redo failed");
                }
                qInfo("Qt PSD conversion recovery OK (%s %s: report, nested refusal, pixels and history)", confirm ? "confirm" : "cancel", qPrintable(variant));
            }
        }

        // The upstream coordinator reveals a newly selected layer. Manual scrolling is viewport state and
        // survives subsequent layer updates, including drawing the full document widget inside its viewport.
        const auto layersScroll = [&]() -> QScrollArea * {
            for (auto *area : window.findChildren<QScrollArea *>())
                if (area->isVisible() && area->property("appKitScroll").toBool()
                    && area->property("appKitScrollNode").toString().startsWith("LayersPanel|")) return area;
            return nullptr;
        };
        const auto waitForScroll = [&](const std::function<bool()> &ready, const char *message) {
            QElapsedTimer elapsed; elapsed.start();
            while (!ready() && elapsed.elapsed() < 5000) QApplication::processEvents(QEventLoop::AllEvents, 10);
            require(ready(), message);
        };
        fresh();
        auto *layersDock = window.findChild<QDockWidget *>("dock.layers");
        require(layersDock && layersDock->minimumWidth() == 222 && layersDock->maximumWidth() == 352,
                "native Layers panel is still fixed instead of respecting upstream resize bounds");
        const QByteArray resizePixels = frame();
        const QString resizeUndo = window.sessionState().value("undoName").toString();
        const int originalPanelWidth = layersDock->width();
        for (const int width : {222, 352, originalPanelWidth}) {
            window.resizeDocks({layersDock}, {width}, Qt::Horizontal);
            waitForScroll([&] {
                return layersDock->width() == width && compositor_session_layers_panel_width(window.sessionHandle(), 0) == width;
            }, "native Layers panel did not resize its upstream body");
            auto *container = window.findChild<QWidget *>("swiftUILayersContainer");
            require(container && container->isVisible(), "resized Layers panel missing");
            for (auto *control : container->findChildren<QWidget *>()) {
                if (!control->isVisible() || (!qobject_cast<QAbstractButton *>(control)
                    && !qobject_cast<QComboBox *>(control) && !qobject_cast<QLineEdit *>(control))) continue;
                const QRect bounds(control->mapTo(container, QPoint()), control->size());
                require(bounds.left() >= 0 && bounds.right() < container->width(), "resized Layers control overflowed its panel");
            }
            require(frame() == resizePixels && window.sessionState().value("undoName").toString() == resizeUndo,
                    "Layers panel resize edited pixels or history");
        }
        window.resizeDocks({layersDock}, {252}, Qt::Horizontal);
        waitForScroll([&] { return layersDock->width() == 252 && compositor_session_layers_panel_width(window.sessionHandle(), 0) == 252; },
                      "Layers splitter test could not establish its starting width");
        const int separatorWidth = window.style()->pixelMetric(QStyle::PM_DockWidgetSeparatorExtent);
        const QPoint splitter(layersDock->geometry().left() - qMax(1, separatorWidth / 2), layersDock->geometry().center().y());
        const auto splitterMouse = [&](QEvent::Type type, QPoint position, Qt::MouseButton button, Qt::MouseButtons buttons) {
            QMouseEvent event(type, QPointF(position), QPointF(window.mapToGlobal(position)), button, buttons, Qt::NoModifier);
            QApplication::sendEvent(window.windowHandle(), &event);
            QApplication::processEvents();
        };
        splitterMouse(QEvent::MouseMove, splitter, Qt::NoButton, Qt::NoButton);
        splitterMouse(QEvent::MouseButtonPress, splitter, Qt::LeftButton, Qt::LeftButton);
        splitterMouse(QEvent::MouseMove, splitter - QPoint(40, 0), Qt::NoButton, Qt::LeftButton);
        splitterMouse(QEvent::MouseButtonRelease, splitter - QPoint(40, 0), Qt::LeftButton, Qt::NoButton);
        waitForScroll([&] {
            return layersDock->width() > 252 && compositor_session_layers_panel_width(window.sessionHandle(), 0) == layersDock->width();
        }, "pointer drag did not resize the native Layers splitter");
        require(frame() == resizePixels && window.sessionState().value("undoName").toString() == resizeUndo,
                "Layers splitter drag edited pixels or history");
        window.resizeDocks({layersDock}, {originalPanelWidth}, Qt::Horizontal);
        waitForScroll([&] { return compositor_session_layers_panel_width(window.sessionHandle(), 0) == originalPanelWidth; },
                      "Layers splitter test did not restore its original width");
        qInfo("Qt Layers panel resizing OK (222/352-point bounds, pointer splitter drag, contained controls, upstream body, no document edit)");
        waitForScroll([&] {
            auto *area = layersScroll();
            return area && area->widget() && area->widget()->height() >= area->viewport()->height();
        }, "short native layer table did not fill its viewport");
        const QString shortBottomLayer = window.sessionState().value("layers").toArray().first().toObject().value("id").toString();
        for (int i = 0; i < 24; ++i) command({{"action", "addLayer"}});
        waitForScroll([&] { auto *area = layersScroll(); return area && area->verticalScrollBar()->maximum() > 100; },
                      "native layer list did not overflow its viewport");
        command({{"action", "selectLayer"}, {"layerID", shortBottomLayer}});
        waitForScroll([&] {
            auto *area = layersScroll();
            return area && area->verticalScrollBar()->value() >= area->verticalScrollBar()->maximum() - 2;
        }, "newly selected bottom layer was not revealed");
        auto *area = layersScroll();
        const QByteArray beforeScroll = frame();
        const QString beforeScrollUndo = window.sessionState().value("undoName").toString();
        area->verticalScrollBar()->setValue(area->verticalScrollBar()->maximum() / 3);
        const int manualScroll = area->verticalScrollBar()->value();
        QApplication::processEvents();
        require(frame() == beforeScroll && window.sessionState().value("undoName").toString() == beforeScrollUndo,
                "manual layer scrolling edited the document");
        command({{"action", "setVisible"}, {"layerID", shortBottomLayer}, {"enabled", false}});
        waitForScroll([&] { auto *current = layersScroll(); return current && current->verticalScrollBar()->value() == manualScroll; },
                      "layer update reset manual scrolling");
        qInfo("Qt native layer scrolling OK (selection reveal, viewport drawing, manual-scroll preservation, no document edit)");

        // A layer update rebuilds the panel with a new scroll area. It must show the native offset from the moment it
        // appears, not the top of the list until a deferred pass runs (seen after eye drags as a reset to 0).
        {
            struct ShownOffsets : QObject {
                QList<QPair<QObject *, int>> shown;
                bool eventFilter(QObject *watched, QEvent *event) override {
                    if (event->type() == QEvent::Show) {
                        if (auto *scroll = qobject_cast<QScrollArea *>(watched); scroll
                            && scroll->property("appKitScrollNode").toString().startsWith("LayersPanel|"))
                            shown.append({scroll, scroll->verticalScrollBar()->value()});
                    }
                    return false;
                }
            } recorder;
            area = layersScroll();
            const int heldOffset = area->verticalScrollBar()->value();
            require(heldOffset > 0, "rebuilt-scroll fixture needs a scrolled native viewport");
            qApp->installEventFilter(&recorder);
            const QList<QJsonObject> updates{{{"action", "setVisible"}, {"layerID", shortBottomLayer}, {"enabled", true}},
                {{"action", "setOpacity"}, {"value", 0.5}}, {{"action", "setVisible"}, {"layerID", shortBottomLayer}, {"enabled", false}},
                {{"action", "setOpacity"}, {"value", 1.0}}};
            for (const QJsonObject &update : updates) {
                command(update);
                QElapsedTimer settle; settle.start();
                while (settle.elapsed() < 250) QApplication::processEvents(QEventLoop::AllEvents, 10);
                waitForScroll([&] { auto *current = layersScroll(); return current && current->verticalScrollBar()->value() == heldOffset; },
                              "layer update moved the native layer viewport");
            }
            qApp->removeEventFilter(&recorder);
            require(!recorder.shown.isEmpty(), "rebuilt native layer scroll areas were not observed appearing");
            for (const auto &entry : recorder.shown)
                require(entry.second == heldOffset, qPrintable(QString("rebuilt native layer list appeared at offset %1 instead of %2")
                                                               .arg(entry.second).arg(heldOffset)));
            qInfo("Qt rebuilt layer scroll offset OK (%lld rebuilt areas appeared at offset %d)", qlonglong(recorder.shown.size()), heldOffset);
        }

        // Eye tracking must move the actual viewport while the press is still held, before the panel can rebuild.
        // CI exercises each edge once; stress reproductions can repeat without skipping the rest of the journey.
        for (int repeat = 0; repeat < qBound(1, qEnvironmentVariableIntValue("COMPOSITOR_AUTOSCROLL_REPEATS"), 32); ++repeat)
        for (bool upwards : {false, true}) {
            waitForScroll([&] { auto *scroll = layersScroll(); return scroll && scroll->verticalScrollBar()->maximum() > 100; },
                          "eye autoscroll fixture has no scrollable native range");
            area = layersScroll();
            area->verticalScrollBar()->setValue(upwards ? area->verticalScrollBar()->maximum() : 0);
            QApplication::processEvents();
            waitForScroll([&] {
                auto *scroll = layersScroll();
                return scroll && scroll->verticalScrollBar()->maximum() > 100
                    && scroll->verticalScrollBar()->value() == (upwards ? scroll->verticalScrollBar()->maximum() : 0);
            }, "eye autoscroll fixture did not reach its starting viewport edge");
            area = layersScroll();
            const int eyeStartOffset = area->verticalScrollBar()->value();
            QWidget *eyeTable = area->widget();
            if (!eyeTable->property("appKitView").toBool()) {
                for (QWidget *candidate : eyeTable->findChildren<QWidget *>())
                    if (candidate->property("appKitView").toBool()) { eyeTable = candidate; break; }
            }
            require(eyeTable->property("appKitView").toBool(), "eye autoscroll table missing");
            const QJsonArray beforeEyeSwipe = window.sessionState().value("layers").toArray();
            // Upstream raster rows are 52 points tall with 2 points of intercell spacing.
            const int firstVisibleEye = ((eyeStartOffset + 53) / 54) * 54 + 26;
            const QPoint pressPoint = eyeTable->mapTo(&window, QPoint(18, firstVisibleEye));
            const QPoint outsidePoint = area->viewport()->mapTo(&window, QPoint(18, upwards ? -12 : area->viewport()->height() + 12));
            const auto eyeMouse = [&](QEvent::Type type, QPoint position, Qt::MouseButton button, Qt::MouseButtons buttons) {
                QMouseEvent event(type, QPointF(position), QPointF(window.mapToGlobal(position)), button, buttons, Qt::NoModifier);
                QApplication::sendEvent(window.windowHandle(), &event);
            };
            bool scrolledWhileHeld = false, eyeReleased = false;
            QTimer::singleShot(0, &window, [&] {
                eyeMouse(QEvent::MouseMove, outsidePoint, Qt::NoButton, Qt::LeftButton);
                QTimer::singleShot(180, &window, [&] {
                    auto *scroll = layersScroll();
                    scrolledWhileHeld = scroll && (upwards ? scroll->verticalScrollBar()->value() <= eyeStartOffset - 24
                                                           : scroll->verticalScrollBar()->value() >= eyeStartOffset + 24);
                    eyeMouse(QEvent::MouseButtonRelease, outsidePoint, Qt::LeftButton, Qt::NoButton);
                    eyeReleased = true;
                });
            });
            eyeMouse(QEvent::MouseButtonPress, pressPoint, Qt::LeftButton, Qt::LeftButton);
            waitForScroll([&] { return eyeReleased; }, "eye visibility drag release was not delivered");
            const QByteArray eyeScrollFailure = QString("eye visibility drag did not repeatedly scroll %1 while tracking (start %2, end %3)")
                .arg(upwards ? "up" : "down").arg(eyeStartOffset)
                .arg(layersScroll() ? layersScroll()->verticalScrollBar()->value() : -1).toUtf8();
            require(scrolledWhileHeld, eyeScrollFailure.constData());
            const int releasedOffset = layersScroll()->verticalScrollBar()->value();
            QEventLoop afterRelease;
            QTimer::singleShot(120, &afterRelease, &QEventLoop::quit);
            afterRelease.exec();
            const QByteArray releaseFailure = QString("eye viewport changed after release (%1: released %2, later %3)")
                .arg(upwards ? "up" : "down").arg(releasedOffset)
                .arg(layersScroll() ? layersScroll()->verticalScrollBar()->value() : -1).toUtf8();
            if (!layersScroll() || layersScroll()->verticalScrollBar()->value() != releasedOffset)
                qWarning().noquote() << swiftUIScrollTrace();
            require(layersScroll() && layersScroll()->verticalScrollBar()->value() == releasedOffset,
                    releaseFailure.constData());
            const QJsonArray afterEyeSwipe = window.sessionState().value("layers").toArray();
            int changedEyes = 0;
            for (int row = 0; row < beforeEyeSwipe.size() && row < afterEyeSwipe.size(); ++row) {
                if (beforeEyeSwipe.at(row).toObject().value("visible") != afterEyeSwipe.at(row).toObject().value("visible")) ++changedEyes;
            }
            require(changedEyes >= 2, "eye drag did not change visibility on newly reached rows");
            command({{"action", "undo"}});
            require(window.sessionState().value("layers").toArray() == beforeEyeSwipe,
                    "eye visibility swipe did not undo as one operation");
        }
        qInfo("Qt eye drag autoscroll OK (both viewport edges move while held, visibility changes, single Undo)");

        // Upstream ProjectWorkspace.receive waits while the editor cannot switch (here, an open text draft), then
        // imports the dropped files: no refusal alert, no import into the draft, one later layer and one Undo step.
        {
            const QJsonArray beforeLayers = window.sessionState().value("layers").toArray();
            const QString beforeUndo = window.sessionState().value("undoName").toString();
            const QString beforeActive = window.sessionState().value("activeLayerID").toString();
            const QString beforeTool = window.sessionState().value("tool").toString();
            command({{"action", "textBegin"}, {"x", 24}, {"y", 24}});
            require(!window.sessionState().value("canSwitch").toBool(true), "text draft did not block file receiving");
            QStringList alerts;
            QTimer alertWatch; alertWatch.setInterval(10);
            QObject::connect(&alertWatch, &QTimer::timeout, &window, [&] {
                for (auto *top : QApplication::topLevelWidgets())
                    if (auto *box = qobject_cast<QMessageBox *>(top); box && box->isVisible()) {
                        alerts.append(box->text() + QLatin1Char(' ') + box->informativeText()); box->reject();
                    }
            });
            alertWatch.start();
            QMimeData dropped; dropped.setUrls({QUrl::fromLocalFile(imagePath)});
            auto *canvasWidget = window.findChild<QWidget *>("editorCanvas");
            const QPoint dropAt = canvasWidget->mapTo(&window, canvasWidget->rect().center());
            QDropEvent drop(QPointF(dropAt), Qt::CopyAction, &dropped, Qt::LeftButton, Qt::NoModifier);
            // Qt delivers a drop to the widget that accepted the drag's entry.
            QDragEnterEvent enter(dropAt, Qt::CopyAction, &dropped, Qt::LeftButton, Qt::NoModifier);
            QApplication::sendEvent(&window, &enter);
            require(enter.isAccepted(), "main window refused a dragged file");
            QApplication::sendEvent(&window, &drop);
            require(drop.isAccepted(), "busy editor rejected a file drop instead of waiting");
            QElapsedTimer held; held.start();
            while (held.elapsed() < 200) QApplication::processEvents(QEventLoop::AllEvents, 10);
            require(alerts.isEmpty(), qPrintable("busy file drop raised an alert: " + alerts.join("; ")));
            require(window.pendingDropCount() == 1 && window.sessionState().value("layers").toArray().size() == beforeLayers.size(),
                    "busy file drop was imported or lost while the text draft was open");
            command({{"action", "textCancel"}});
            waitForScroll([&] { return window.pendingDropCount() == 0; }, "waiting file drop was not imported after the draft ended");
            alertWatch.stop();
            require(alerts.isEmpty(), qPrintable("deferred file drop raised an alert: " + alerts.join("; ")));
            require(window.sessionState().value("layers").toArray().size() == beforeLayers.size() + 1,
                    "deferred file drop did not add exactly one layer");
            command({{"action", "undo"}});
            require(window.sessionState().value("layers").toArray() == beforeLayers
                    && window.sessionState().value("undoName").toString() == beforeUndo,
                    "deferred file drop was not one Undo step");
            command({{"action", "selectTool"}, {"kind", beforeTool}});
            command({{"action", "selectLayer"}, {"layerID", beforeActive}});
            require(window.sessionState().value("activeLayerID").toString() == beforeActive
                    && window.sessionState().value("tool").toString() == beforeTool, "busy file drop fixture did not restore its state");
            // Upstream ProjectController.begin(): while Image Size is open the project is busy. Menu items chosen
            // anyway (a global menu bypasses Qt's modality) change nothing, and work again after Cancel.
            {
                const QJsonArray sheetLayers = window.sessionState().value("layers").toArray();
                const QString sheetUndo = window.sessionState().value("undoName").toString();
                // Upstream's own menu items (CompositorApp's commands), as a global menu exports them.
                const auto menuAction = [&](const QString &prefix) -> QAction * {
                    std::function<QAction *(QMenu *)> find = [&](QMenu *menu) -> QAction * {
                        for (QAction *action : menu->actions()) {
                            if (action->menu()) { if (QAction *found = find(action->menu())) return found; }
                            else if (action->text().startsWith(prefix)) return action;
                        }
                        return nullptr;
                    };
                    for (QMenu *menu : window.findChildren<QMenu *>())
                        if (menu->objectName().startsWith("appMenu."))
                            if (QAction *found = find(menu)) return found;
                    return nullptr;
                };
                QString failure; bool inspected = false;
                QTimer inspector; inspector.setInterval(20);
                QElapsedTimer opened; opened.start();
                QObject::connect(&inspector, &QTimer::timeout, &window, [&] {
                    QDialog *sheet = nullptr;
                    for (auto *top : QApplication::topLevelWidgets())
                        if (auto *candidate = qobject_cast<QDialog *>(top); candidate && candidate->isVisible()
                            && candidate->objectName() == QLatin1String("swiftUISheet.ImageSizeSheet")) sheet = candidate;
                    if (!sheet) { if (opened.elapsed() > 8000) { failure = "Image Size sheet was not presented"; inspector.stop(); } return; }
                    inspector.stop();
                    window.syncAppMenus();
                    QAction *undo = menuAction("Undo"), *newLayer = menuAction("New Blank Layer"), *newCanvas = menuAction("New Canvas");
                    if (!undo || !newLayer || !newCanvas) failure = "upstream menu actions missing during Image Size";
                    else {
                        if (newLayer->isEnabled() || newCanvas->isEnabled())
                            failure = "layer and project menu items stayed enabled while Image Size held the project";
                        undo->trigger(); newLayer->trigger(); newCanvas->trigger();
                        QApplication::processEvents();
                        QTest::sendKeyEvent(QTest::Click, window.windowHandle(), Qt::Key_Z, QString(), Qt::ControlModifier);
                        QApplication::processEvents();
                        if (window.sessionState().value("layers").toArray() != sheetLayers
                            || window.sessionState().value("undoName").toString() != sheetUndo
                            || window.sessionState().value("canSwitch").toBool(true))
                            failure = QString("menu items or keys changed the document while Image Size held the project "
                                              "(layers %1 -> %2, undo '%3' -> '%4', canSwitch %5)")
                                .arg(sheetLayers.size()).arg(window.sessionState().value("layers").toArray().size())
                                .arg(sheetUndo, window.sessionState().value("undoName").toString())
                                .arg(window.sessionState().value("canSwitch").toBool(true));
                    }
                    inspected = true;
                    for (auto *button : sheet->findChildren<QPushButton *>())
                        if (button->text() == QLatin1String("Cancel")) { button->click(); return; }
                    sheet->reject();
                });
                inspector.start();
                window.sendCommand({{"action", "imageSizeSheet"}});   // returns once the sheet is answered
                inspector.stop();
                require(inspected && failure.isEmpty(), failure.isEmpty() ? "Image Size sheet was not inspected" : qPrintable(failure));
                require(window.sessionState().value("layers").toArray() == sheetLayers, "cancelled Image Size changed the layers");
                require(window.sessionState().value("canSwitch").toBool(), "cancelled Image Size kept the project busy");
                command({{"action", "addLayer"}});
                require(window.sessionState().value("layers").toArray().size() == sheetLayers.size() + 1, "layer edits did not recover after Image Size");
                command({{"action", "undo"}});
                require(window.sessionState().value("layers").toArray() == sheetLayers, "Undo did not recover after Image Size");
                qInfo("Qt modal project hold OK (Image Size: menu items disabled and refused, keys blocked, recovery after Cancel)");
            }
            qInfo("Qt busy file drop OK (waited during a text draft without alert, imported once afterwards, one Undo)");
        }

        command({{"action", "selectTool"}, {"kind", "brush"}});
        const auto layerTable = [&]() -> QWidget * {
            for (auto *candidate : window.findChildren<QWidget *>())
                if (candidate->isVisible() && candidate->property("appKitView").toBool()
                    && candidate->property("appKitNode").toString().startsWith("LayersPanel|")) return candidate;
            return nullptr;
        };
        const auto tableKey = [&](int code, Qt::KeyboardModifiers modifiers = Qt::NoModifier) {
            auto *table = layerTable(); require(table, "native layer keyboard table missing");
            const QString node = table->property("appKitNode").toString();
            table->setFocus(Qt::OtherFocusReason);
            QApplication::processEvents();
            // A pending panel replacement restores this node's focus on the next event-loop turn.
            waitForScroll([&] {
                return QApplication::focusWidget() && QApplication::focusWidget()->property("appKitNode").toString() == node;
            }, "native layer keyboard table did not acquire focus");
            QTest::sendKeyEvent(QTest::Click, window.windowHandle(), static_cast<Qt::Key>(code), QString(), modifiers);
            if (code == Qt::Key_Home && modifiers == Qt::NoModifier)
                require(layersScroll() && layersScroll()->verticalScrollBar()->value() == 0,
                        "native Home left the visible Layers viewport behind the model before the next event");
            QApplication::processEvents();
        };
        const auto stableKeyboardViewport = [&](const char *message) {
            require(layersScroll(), "keyboard viewport missing");
            const int offset = layersScroll()->verticalScrollBar()->value();
            QEventLoop settle;
            QTimer::singleShot(120, &settle, &QEventLoop::quit);
            settle.exec();
            require(layersScroll() && layersScroll()->verticalScrollBar()->value() == offset, message);
        };
        const QString keyboardUndo = window.sessionState().value("undoName").toString();
        QAccessible::Id closedRowID = 0;
        QPointer<QObject> closedRowObject;
        uint64_t closedAccessibilitySession = 0;
        {
            auto *originalTable = layerTable(); require(originalTable, "focus ownership table missing");
            originalTable->setFocus(Qt::OtherFocusReason);
            QApplication::processEvents();
            const QString originalNode = layerTable()->property("appKitNode").toString();
            SessionWindow second;
            second.createNewDocument(64, 64); second.resize(1200, 800); second.show();
            QApplication::processEvents();
            QWidget *secondTable = nullptr;
            for (auto *candidate : second.findChildren<QWidget *>())
                if (candidate->isVisible() && candidate->property("appKitNode").toString() == originalNode) {
                    secondTable = candidate; break;
                }
            require(secondTable, "second session did not expose the matching layer table node");
            require(secondTable->property("appKitSession").toULongLong() == second.sessionHandle()
                    && second.sessionHandle() != window.sessionHandle(), "native focus lacks distinct session ownership");
            require(QApplication::focusWidget() != secondTable, "new session inherited another session's table focus");
            auto *secondAccessible = QAccessible::queryAccessibleInterface(secondTable);
            require(secondAccessible && secondAccessible->childCount() > 0,
                    "second session did not expose an accessible layer row");
            auto *secondRow = secondAccessible->child(0);
            require(secondRow && secondRow->role() == QAccessible::ListItem && secondRow->actionInterface(),
                    "second session accessible row lacks its action interface");
            closedAccessibilitySession = second.sessionHandle();
            {
                QDialog documentModal(&window);
                documentModal.setWindowModality(Qt::WindowModal);
                documentModal.open();
                require(secondRow->actionInterface()->actionNames().contains(QAccessibleActionInterface::pressAction())
                        && !secondRow->state().disabled,
                        "another document's modal dialog blocked independent accessible rows");
                documentModal.reject();
                QDialog applicationModal(&window);
                applicationModal.setWindowModality(Qt::ApplicationModal);
                applicationModal.show();
                require(secondRow->actionInterface()->actionNames().isEmpty() && secondRow->state().disabled,
                        "application-modal dialog did not block another document's accessible row");
                applicationModal.reject();
                require(secondRow->actionInterface()->actionNames().contains(QAccessibleActionInterface::pressAction()),
                        "independent document accessibility did not recover after application-modal dismissal");
            }
            secondTable->setFocus(Qt::OtherFocusReason); QApplication::processEvents();
            second.hide(); QApplication::processEvents();
            // Capture the current row after queued focus/panel updates, immediately before destruction.
            QAccessibleInterface *closingRow = nullptr;
            for (auto *candidate : second.findChildren<QWidget *>()) {
                if (candidate->isHidden() || candidate->property("appKitNode").toString() != originalNode) continue;
                auto *list = QAccessible::queryAccessibleInterface(candidate);
                if (list && list->childCount() > 0) { closingRow = list->child(0); break; }
            }
            require(closingRow && closingRow->object(), "closing session lacks a live cached accessible row");
            closedRowID = QAccessible::uniqueId(closingRow);
            closedRowObject = closingRow->object();
        }
        require(!closedRowObject && !QAccessible::accessibleInterface(closedRowID),
                "closed session retained a cached accessible row or action interface");
        require(compositor_session_state(closedAccessibilitySession, nullptr, 0) <= 0,
                "closed accessibility fixture retained its Swift session");
        QApplication::processEvents();
        qInfo("Qt accessible session destruction OK (cached object and interface retired, Swift session closed)");
        require(compositor_workspace_select_tab(window.sessionHandle()) == 0, "original workspace tab could not be restored");
        QApplication::setActiveWindow(&window); QApplication::processEvents();
        require(window.sessionState().value("layers").toArray().size() == 25,
                "second-window focus fixture replaced the original document");
        command({{"action", "selectTool"}, {"kind", "brush"}});
        tableKey(Qt::Key_Up);
        const QString keyboardLayer = window.sessionState().value("activeLayerID").toString();
        require(!keyboardLayer.isEmpty() && keyboardLayer != shortBottomLayer, "native Up arrow did not select the previous layer");
        stableKeyboardViewport("Up selection reveal reset during a queued panel refresh");
        tableKey(Qt::Key_Down);
        require(window.sessionState().value("activeLayerID").toString() == shortBottomLayer, "native Down arrow did not restore the selected layer");
        tableKey(Qt::Key_Up, Qt::ShiftModifier);
        require(window.sessionState().value("mergeTitle").toString() == "Merge Layers", "native Shift-Up did not extend layer selection");
        tableKey(Qt::Key_Down, Qt::ShiftModifier);
        require(!window.sessionState().value("canMergeLayers").toBool()
                && window.sessionState().value("activeLayerID").toString() == shortBottomLayer,
                "native Shift-Down did not contract layer selection");
        require(window.sessionState().value("undoName").toString() == keyboardUndo, "native layer keyboard selection created an Undo step");
        {
            tableKey(Qt::Key_Home);
            struct RowClickTrace {
                const void *table, *hit;
                uint64_t session;
                int row, modifiers, scroll;
                QPoint windowPoint, global;
                QRect geometry, viewport;
                bool enabled, reachesTable;
            };
            std::array<RowClickTrace, 3> clicks{};
            size_t clickCount = 0;
            const auto clickLayerRow = [&](int row, Qt::KeyboardModifiers modifiers) {
                auto *table = layerTable(); require(table, "disjoint selection table missing");
                const QPoint position = table->mapTo(&window, QPoint(140, row * 54 + 26));
                // Read Qt geometry only: diagnostics must not refresh the native model or settle the event queue.
                QScrollArea *scroll = nullptr;
                for (auto *parent = table->parentWidget(); parent; parent = parent->parentWidget())
                    if ((scroll = qobject_cast<QScrollArea *>(parent))) break;
                auto *hit = window.childAt(position);
                if (clickCount < clicks.size()) clicks[clickCount++] = {
                    table, hit, table->property("appKitSession").toULongLong(), row, int(modifiers),
                    scroll ? scroll->verticalScrollBar()->value() : -1, position, window.mapToGlobal(position), table->geometry(),
                    scroll ? QRect(scroll->viewport()->mapToGlobal(QPoint()), scroll->viewport()->size()) : QRect(),
                    table->isEnabled(), hit == table || (hit && table->isAncestorOf(hit))};
                const auto sendMouse = [&](QEvent::Type type, Qt::MouseButtons buttons) {
                    QMouseEvent event(type, QPointF(position), QPointF(window.mapToGlobal(position)),
                                      Qt::LeftButton, buttons, modifiers);
                    QApplication::sendEvent(window.windowHandle(), &event);
                };
                QTimer::singleShot(0, &window, [&] { sendMouse(QEvent::MouseButtonRelease, Qt::NoButton); });
                sendMouse(QEvent::MouseButtonPress, Qt::LeftButton);
                QApplication::processEvents();
            };
            const auto selectedRows = [&]() {
                auto *table = layerTable(); require(table, "disjoint accessibility table missing");
                auto *accessible = QAccessible::queryAccessibleInterface(table);
                require(accessible, "disjoint table lacks accessible rows");
                QList<int> selected;
                int row = 0;
                for (int index = 0; index < accessible->childCount(); ++index) {
                    auto *child = accessible->child(index);
                    if (!child || child->role() != QAccessible::ListItem) continue;
                    if (child->state().selected) selected.append(row);
                    ++row;
                }
                require(row == 25, "disjoint selection lost native rows");
                return selected;
            };
            clickLayerRow(2, Qt::NoModifier);
            clickLayerRow(8, Qt::ControlModifier);
            const auto disjointRows = selectedRows();
            if (disjointRows != QList<int>({2, 8}) || app.arguments().contains("--trace-layer-input")) {
                qWarning() << "native disjoint selection/current session" << disjointRows << window.sessionHandle();
                for (size_t i = 0; i < clickCount; ++i) {
                    const auto &entry = clicks[i];
                    qWarning() << "disjoint click table/hit/session/row/modifiers" << entry.table << entry.hit << entry.session << entry.row << entry.modifiers
                               << "window/global" << entry.windowPoint << entry.global << "geometry/scroll" << entry.geometry << entry.scroll
                               << "viewport/inside" << entry.viewport << entry.viewport.contains(entry.global)
                               << "enabled/reaches table" << entry.enabled << entry.reachesTable;
                }
                qWarning().noquote() << swiftUIPointerTrace();
                qWarning().noquote() << swiftUIScrollTrace();
            }
            require(disjointRows == QList<int>({2, 8}), "native Command-click did not create disjoint selection");
            clickLayerRow(6, Qt::ShiftModifier);
            require(selectedRows() == QList<int>({2, 6, 7, 8}), "native Shift-click lost the disjoint base or last-click anchor");
            tableKey(Qt::Key_Up, Qt::ShiftModifier);
            const QList<int> extendedRows = selectedRows();
            QStringList extendedRowNames;
            for (int row : extendedRows) extendedRowNames.append(QString::number(row));
            const auto afterExtendedLayers = window.sessionState().value("layers").toArray();
            const QString afterExtendedPrimary = window.sessionState().value("activeLayerID").toString();
            int primaryRow = -1;
            for (int index = 0; index < afterExtendedLayers.size(); ++index)
                if (afterExtendedLayers.at(index).toObject().value("id").toString() == afterExtendedPrimary)
                    primaryRow = afterExtendedLayers.size() - 1 - index;
            require(extendedRows == QList<int>({2, 5, 6, 7, 8}),
                    qPrintable(QStringLiteral("native Shift-Up did not continue the clicked range (selected %1, model primary %2, focus %3)")
                        .arg(extendedRowNames.join(',')).arg(primaryRow)
                        .arg(QApplication::focusWidget() ? QApplication::focusWidget()->metaObject()->className() : "none")));
            tableKey(Qt::Key_Down, Qt::ShiftModifier);
            require(selectedRows() == QList<int>({2, 6, 7, 8}), "native Shift-Down did not contract the clicked range");
            require(window.sessionState().value("undoName").toString() == keyboardUndo,
                    "native disjoint selection created an Undo step");
            tableKey(Qt::Key_Home);
            const QJsonArray beforeRowDrag = window.sessionState().value("layers").toArray();
            auto *dragTable = layerTable(); require(dragTable, "multi-row drag table missing");
            const QPoint dragStart = dragTable->mapTo(&window, QPoint(140, 6 * 54 + 26));
            const QPoint dragTarget = dragTable->mapTo(&window, QPoint(140, 26));
            const auto dragMouse = [&](QEvent::Type type, QPoint position, Qt::MouseButton button, Qt::MouseButtons buttons) {
                QMouseEvent event(type, QPointF(position), QPointF(window.mapToGlobal(position)), button, buttons, Qt::NoModifier);
                QApplication::sendEvent(window.windowHandle(), &event);
            };
            QTimer::singleShot(0, &window, [&] {
                dragMouse(QEvent::MouseMove, dragStart + QPoint(4, 0), Qt::NoButton, Qt::LeftButton);
            });
            dragMouse(QEvent::MouseButtonPress, dragStart, Qt::LeftButton, Qt::LeftButton);
            dragMouse(QEvent::MouseMove, dragTarget, Qt::NoButton, Qt::LeftButton);
            dragMouse(QEvent::MouseButtonRelease, dragTarget, Qt::LeftButton, Qt::NoButton);
            QApplication::processEvents();
            QJsonArray expectedRowDrag;
            const QList<int> draggedRows{2, 6, 7, 8};
            // Session JSON stores bottom-to-top; the upstream native list displays top-to-bottom.
            for (int index = 0; index < beforeRowDrag.size(); ++index)
                if (!draggedRows.contains(beforeRowDrag.size() - 1 - index)) expectedRowDrag.append(beforeRowDrag.at(index));
            for (auto row = draggedRows.crbegin(); row != draggedRows.crend(); ++row)
                expectedRowDrag.append(beforeRowDrag.at(beforeRowDrag.size() - 1 - *row));
            require(window.sessionState().value("layers").toArray() == expectedRowDrag,
                    "native row drag did not move every selected layer in upstream order");
            require(selectedRows() == QList<int>({0, 1, 2, 3}), "native row drag lost the moved selection");
            require(window.sessionState().value("undoName").toString() == "Move Layers",
                    "native multi-layer drag was not one grouped edit");
            command({{"action", "undo"}});
            require(window.sessionState().value("layers").toArray() == beforeRowDrag,
                    "native multi-row drag did not undo in one step");
            qInfo("Qt native multi-row drag OK (selected set retained, all rows moved in order, single Undo)");
            command({{"action", "selectLayer"}, {"layerID", shortBottomLayer}});
            qInfo("Qt native disjoint layer selection OK (Command-click, Shift-click, Shift arrows, retained base, no Undo)");
        }
        tableKey(Qt::Key_Home);
        waitForScroll([&] { return layersScroll() && layersScroll()->verticalScrollBar()->value() == 0; },
                      "native Home did not scroll to the first layer");
        tableKey(Qt::Key_PageDown);
        waitForScroll([&] { return layersScroll() && layersScroll()->verticalScrollBar()->value() > 0; },
                      "native Page Down did not move the Layers viewport");
        stableKeyboardViewport("Page Down viewport reset during a queued panel refresh");
        tableKey(Qt::Key_End);
        waitForScroll([&] { auto *scroll = layersScroll(); return scroll && scroll->verticalScrollBar()->value() == scroll->verticalScrollBar()->maximum(); },
                      "native End did not scroll to the last layer");
        stableKeyboardViewport("End viewport reset during a queued panel refresh");
        tableKey(Qt::Key_PageUp);
        waitForScroll([&] { auto *scroll = layersScroll(); return scroll && scroll->verticalScrollBar()->value() < scroll->verticalScrollBar()->maximum(); },
                      "native Page Up did not move the Layers viewport");
        require(window.sessionState().value("activeLayerID").toString() == shortBottomLayer
                && window.sessionState().value("undoName").toString() == keyboardUndo,
                "native Layers paging changed selection or history");
        const QString typeSelectedLayer = window.sessionState().value("layers").toArray().last().toObject().value("id").toString();
        command({{"action", "selectLayer"}, {"layerID", typeSelectedLayer}});
        command({{"action", "renameLayer"}, {"name", "Quartz"}});
        command({{"action", "selectLayer"}, {"layerID", shortBottomLayer}});
        const QString typeSelectUndo = window.sessionState().value("undoName").toString();
        tableKey(Qt::Key_Q);
        require(window.sessionState().value("activeLayerID").toString() == typeSelectedLayer,
                "native layer type selection did not find its displayed name");
        require(window.sessionState().value("undoName").toString() == typeSelectUndo,
                "native layer type selection created an Undo step");
        tableKey(Qt::Key_Home);
        for (const auto type : {QEvent::MouseButtonDblClick, QEvent::MouseButtonRelease}) {
            auto *table = layerTable(); require(table, "rename table missing");
            const QPointF point(120, 26);
            QMouseEvent event(type, point, table->mapToGlobal(point.toPoint()), Qt::LeftButton,
                type == QEvent::MouseButtonRelease ? Qt::NoButton : Qt::LeftButton, Qt::NoModifier);
            QApplication::sendEvent(table, &event);
        }
        QApplication::processEvents();
        QPointer<QLineEdit> renameEditor;
        waitForScroll([&] {
            auto *table = layerTable();
            if (!table) return false;
            for (auto *field : table->findChildren<QLineEdit *>())
                if (field->isVisible() && field->text() == "Quartz") { renameEditor = field; return true; }
            return false;
        }, "native double-click did not open the layer rename editor");
        renameEditor->setFocus(Qt::OtherFocusReason); QApplication::processEvents();
        require(renameEditor && renameEditor->hasFocus(), "inline rename lost focus to its drawn table");
        QTest::sendKeyEvent(QTest::Click, window.windowHandle(), Qt::Key_A, QString(), Qt::ControlModifier);
        QTest::sendKeyEvent(QTest::Click, window.windowHandle(), Qt::Key_unknown, QStringLiteral("Quartz renamed"), Qt::NoModifier);
        QApplication::processEvents();
        require(renameEditor && renameEditor->hasFocus() && renameEditor->text() == "Quartz renamed",
                "layer rename ended while transferring focus or typing");
        {
            // The field editor is first responder: Edit-menu keys (Undo/Redo, Select All, Copy/Paste) act on its text,
            // not on the document behind it, as AppKit's responder chain sends them to the text first.
            const auto documentState = [&] {
                const QJsonObject state = window.sessionState();
                return QJsonArray{state.value("layers"), state.value("undoName"), state.value("redoName"), state.value("hasSelection")};
            };
            const QJsonArray beforeEditKeys = documentState();
            const auto editKey = [&](Qt::Key key, Qt::KeyboardModifiers modifiers) {
                QTest::sendKeyEvent(QTest::Click, window.windowHandle(), key, QString(), modifiers);
                QApplication::processEvents();
                require(renameEditor && renameEditor->hasFocus(), "an Edit key took focus from the rename editor");
            };
            editKey(Qt::Key_Z, Qt::ControlModifier);
            require(renameEditor->text() == "Quartz", "Undo in the rename editor did not undo its typing");
            editKey(Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
            require(renameEditor->text() == "Quartz renamed", "Redo in the rename editor did not redo its typing");
            editKey(Qt::Key_A, Qt::ControlModifier);
            editKey(Qt::Key_C, Qt::ControlModifier);
            require(QApplication::clipboard()->text() == "Quartz renamed", "Copy in the rename editor did not copy its text");
            editKey(Qt::Key_End, Qt::NoModifier);
            editKey(Qt::Key_V, Qt::ControlModifier);
            require(renameEditor->text() == "Quartz renamedQuartz renamed", "Paste in the rename editor did not paste text");
            editKey(Qt::Key_Z, Qt::ControlModifier);
            require(renameEditor->text() == "Quartz renamed", "Undo in the rename editor did not undo its paste");
            require(documentState() == beforeEditKeys, "Edit keys in the rename editor changed the document");
            qInfo("Qt rename responder chain OK (Undo/Redo/Select All/Copy/Paste act on the field, document unchanged)");
        }
        QTest::sendKeyEvent(QTest::Click, window.windowHandle(), Qt::Key_Return, QString(), Qt::NoModifier);
        QApplication::processEvents();
        const QString committedName = window.sessionState().value("layers").toArray().last().toObject().value("name").toString();
        require(committedName == "Quartz renamed",
                qPrintable(QStringLiteral("native layer rename did not commit its editor text (actual: %1)").arg(committedName)));
        command({{"action", "undo"}});
        require(window.sessionState().value("layers").toArray().last().toObject().value("name").toString() == "Quartz",
                "native layer rename did not undo in one step");
        qInfo("Qt native layer focus OK (distinct sessions, second-window destruction, inline rename and Undo)");
        {
            // Deliver a normal viewport key so the post-Undo coordinator is current before comparing pixels.
            tableKey(Qt::Key_Home);
            const QString beforeAccessibilityUndo = window.sessionState().value("undoName").toString();
            auto *viewport = layersScroll() ? layersScroll()->viewport() : nullptr;
            require(viewport, "accessible Layers viewport missing");
            const QImage beforeAccessibilityPixels = viewport->grab().toImage();
            auto *table = layerTable(); require(table, "accessibility table missing");
            auto *accessible = QAccessible::queryAccessibleInterface(table);
            require(accessible && accessible->role() == QAccessible::List, "drawn layer table lacks its native accessible list");
            require(table->objectName() == QLatin1String("layersList"), "upstream accessibility identifier was dropped");
            int rows = 0;
            QAccessibleInterface *bottom = nullptr, *top = nullptr;
            for (int index = 0; index < accessible->childCount(); ++index) {
                auto *child = accessible->child(index);
                if (!child || child->role() != QAccessible::ListItem) continue;
                ++rows;
                if (child->text(QAccessible::Name) == QLatin1String("pattern")) bottom = child;
                if (child->text(QAccessible::Name) == QLatin1String("Quartz")) top = child;
            }
            require(rows == 25 && bottom && top, "accessible layer names/count do not match the upstream rows");
            require(top->state().selected, "accessible row selection was not forwarded");
            require(bottom->state().offscreen && bottom->actionInterface(), "offscreen row lacks its accessibility action");
            const QImage afterAccessibilityPixels = viewport->grab().toImage();
            if (afterAccessibilityPixels != beforeAccessibilityPixels) {
                beforeAccessibilityPixels.save(".build/compositor-accessibility-viewport-before.png");
                afterAccessibilityPixels.save(".build/compositor-accessibility-viewport-after.png");
            }
            require(afterAccessibilityPixels == beforeAccessibilityPixels,
                    "accessibility descendants changed the drawn Layers viewport");
            // Qt can hide a panel without changing its backing AppKit view's hidden state.
            const QString selectedBeforeHide = window.sessionState().value("activeLayerID").toString();
            table->hide();
            bottom->actionInterface()->doAction(QAccessibleActionInterface::pressAction());
            require(window.sessionState().value("activeLayerID").toString() == selectedBeforeHide,
                    "hidden Qt panel accepted an accessible layer selection");
            require(bottom->actionInterface()->actionNames().isEmpty(),
                    "hidden Qt panel still advertises accessible actions");
            table->show();
            table->setEnabled(false);
            bottom->actionInterface()->doAction(QAccessibleActionInterface::pressAction());
            require(window.sessionState().value("activeLayerID").toString() == selectedBeforeHide
                    && bottom->actionInterface()->actionNames().isEmpty(),
                    "disabled Qt panel accepted or advertised accessible selection");
            table->setEnabled(true);
            {
                QDialog blockingDialog(&window);
                blockingDialog.setWindowModality(Qt::WindowModal);
                blockingDialog.open();
                require(QApplication::activeModalWidget() == &blockingDialog,
                        "accessibility refusal fixture did not block its document");
                bottom->actionInterface()->doAction(QAccessibleActionInterface::pressAction());
                require(window.sessionState().value("activeLayerID").toString() == selectedBeforeHide,
                        "modal-blocked document accepted accessible layer selection");
                require(bottom->actionInterface()->actionNames().isEmpty() && bottom->state().disabled,
                        "modal-blocked row advertises actions or an enabled state");
                blockingDialog.reject();
            }
            bottom->actionInterface()->doAction(QAccessibleActionInterface::pressAction());
            QApplication::processEvents();
            require(window.sessionState().value("activeLayerID").toString() == shortBottomLayer,
                    "accessibility row press did not select the original layer");
            require(window.sessionState().value("undoName").toString() == beforeAccessibilityUndo,
                    "accessibility row selection created an Undo step");
            table = layerTable(); require(table, "selected accessibility table missing");
            accessible = QAccessible::queryAccessibleInterface(table);
            QAccessibleInterface *eye = nullptr;
            std::function<void(QAccessibleInterface *)> findEye = [&](QAccessibleInterface *element) {
                if (!element) return;
                if (element->text(QAccessible::Name) == QLatin1String("Hide Quartz")) eye = element;
                for (int index = 0; index < element->childCount(); ++index) findEye(element->child(index));
            };
            findEye(accessible);
            require(eye && eye->role() == QAccessible::Button && eye->actionInterface(),
                    "upstream visibility control lacks its accessible name, role or action");
            const auto beforeVisibility = window.sessionState().value("layers").toArray();
            table->hide();
            eye->actionInterface()->doAction(QAccessibleActionInterface::pressAction());
            require(window.sessionState().value("layers").toArray() == beforeVisibility
                    && eye->actionInterface()->actionNames().isEmpty(),
                    "hidden Qt panel accepted or advertised accessible visibility changes");
            table->show();
            eye->actionInterface()->doAction(QAccessibleActionInterface::pressAction()); QApplication::processEvents();
            require(!window.sessionState().value("layers").toArray().last().toObject().value("visible").toBool(),
                    "accessible visibility press did not invoke the upstream action");
            command({{"action", "undo"}});
            require(window.sessionState().value("layers").toArray() == beforeVisibility,
                    "accessible visibility did not undo as one operation");
            qInfo("Qt native layer accessibility OK (all rows, names, identifier, selected/offscreen states, hidden/disabled/modal refusal and recovery, native select/visibility actions and Undo)");
        }
        // Every visible control in the main window is reachable by assistive technology with a name and an
        // interactive role, as AppKit/SwiftUI controls are (titles, .help or .accessibilityLabel).
        {
            QStringList unnamed;
            int audited = 0;
            for (QWidget *control : window.findChildren<QWidget *>()) {
                if (!control->isVisibleTo(&window) || control->property("appKitView").toBool()) continue;
                if (!qobject_cast<QAbstractButton *>(control) && !qobject_cast<QAbstractSlider *>(control)
                    && !qobject_cast<QComboBox *>(control) && !qobject_cast<QLineEdit *>(control)
                    && !qobject_cast<QAbstractSpinBox *>(control)) continue;
                // Line edits inside spin boxes and combo boxes are parts of the named control.
                if (qobject_cast<QLineEdit *>(control) && (qobject_cast<QAbstractSpinBox *>(control->parentWidget())
                    || qobject_cast<QComboBox *>(control->parentWidget()))) continue;
                QAccessibleInterface *accessible = QAccessible::queryAccessibleInterface(control);
                ++audited;
                const QString name = accessible ? accessible->text(QAccessible::Name).trimmed() : QString();
                const QAccessible::Role role = accessible ? accessible->role() : QAccessible::NoRole;
                // Scroll bars are identified by role and orientation, as AppKit scrollers are; everything else needs a name.
                const bool scrollBar = qobject_cast<QScrollBar *>(control) && role == QAccessible::ScrollBar;
                if ((name.isEmpty() && !scrollBar) || role == QAccessible::NoRole || role == QAccessible::Client)
                    unnamed.append(QString("%1 '%2' (%3, tip '%4')").arg(control->metaObject()->className(), control->objectName())
                                   .arg(int(role)).arg(control->toolTip()));
            }
            require(audited > 20, "accessible control audit found too few main-window controls");
            require(unnamed.isEmpty(), qPrintable(QString("%1 of %2 main-window controls lack an accessible name or role: %3")
                                                  .arg(unnamed.size()).arg(audited).arg(unnamed.join("; "))));
            qInfo("Qt accessible control names OK (%d visible main-window controls named with interactive roles)", audited);
        }
        command({{"action", "selectLayer"}, {"layerID", shortBottomLayer}});
        // The scrolling fixture hid this layer. Upstream intentionally refuses transforms of hidden layers.
        command({{"action", "setVisible"}, {"layerID", shortBottomLayer}, {"enabled", true}});
        const QString beforeToolKeysUndo = window.sessionState().value("undoName").toString();
        const QString beforeToolKeysLayer = window.sessionState().value("activeLayerID").toString();
        for (const auto &shortcut : QList<QPair<int, QString>>{
                 {Qt::Key_A, "idle"}, {Qt::Key_V, "move"}, {Qt::Key_H, "hand"}, {Qt::Key_Z, "zoom"},
                 {Qt::Key_B, "brush"}, {Qt::Key_E, "brush"}, {Qt::Key_G, "gradient"}, {Qt::Key_L, "lasso"},
                 {Qt::Key_M, "marquee"}, {Qt::Key_W, "wand"}, {Qt::Key_J, "spotHealing"},
                 {Qt::Key_S, "cloneStamp"}, {Qt::Key_U, "shape"}, {Qt::Key_R, "blur"},
                 {Qt::Key_I, "eyedropper"}, {Qt::Key_C, "crop"}, {Qt::Key_T, "type"}}) {
            tableKey(shortcut.first);
            require(window.sessionState().value("tool").toString() == shortcut.second,
                    qPrintable(QString("Layers shortcut %1 did not select %2").arg(QChar(shortcut.first)).arg(shortcut.second)));
        }
        tableKey(Qt::Key_M);
        const QString beforeTab = window.sessionState().value("marqueeKind").toString();
        tableKey(Qt::Key_Tab);
        require(window.sessionState().value("marqueeKind").toString() == (beforeTab == "Rectangle" ? "Ellipse" : "Rectangle"),
                "Layers Tab navigated focus instead of cycling the Marquee mode");
        tableKey(Qt::Key_B);
        tableKey(Qt::Key_5);
        require(window.sessionState().value("brushOpacity").toDouble() == 0.5,
                "Layers numeric key did not set brush opacity");
        command({{"action", "setBrushSettings"}, {"parameters", QJsonObject{{"opacity", 1.0}}}});
        command({{"action", "setPaletteColor"}, {"parameters", QJsonObject{{"red", 0.2}, {"green", 0.4}, {"blue", 0.6}}}});
        const QJsonValue beforeSwapForeground = window.sessionState().value("foregroundColor");
        const QJsonValue beforeSwapBackground = window.sessionState().value("backgroundColor");
        tableKey(Qt::Key_X);
        require(window.sessionState().value("foregroundColor") == beforeSwapBackground
                && window.sessionState().value("backgroundColor") == beforeSwapForeground,
                "Layers X did not swap the palette");
        tableKey(Qt::Key_D);
        require(window.sessionState().value("foregroundColor").toArray() == QJsonArray({0, 0, 0})
                && window.sessionState().value("backgroundColor").toArray() == QJsonArray({1, 1, 1}),
                "Layers D did not reset the palette");
        require(window.sessionState().value("activeLayerID").toString() == beforeToolKeysLayer
                && window.sessionState().value("undoName").toString() == beforeToolKeysUndo,
                "Layers tool, mode or palette shortcuts changed selection or document history");
        tableKey(Qt::Key_V);
        const QJsonObject beforeNudge = window.sessionState().value("layers").toArray().first().toObject();
        tableKey(Qt::Key_Right);
        const QJsonObject afterNudge = window.sessionState().value("layers").toArray().first().toObject();
        QJsonObject expectedTransform = beforeNudge.value("transform").toObject();
        const QJsonValue nudgeOrigin = expectedTransform.value("origin");
        if (nudgeOrigin.isArray()) {
            QJsonArray moved = nudgeOrigin.toArray(); moved[0] = moved[0].toDouble() + 1;
            expectedTransform.insert("origin", moved);
        } else {
            QJsonObject moved = nudgeOrigin.toObject(); moved.insert("x", moved.value("x").toDouble() + 1);
            expectedTransform.insert("origin", moved);
        }
        require(window.sessionState().value("activeLayerID").toString() == shortBottomLayer
                && afterNudge.value("transform").toObject() == expectedTransform,
                "native Move-tool arrow did not preserve upstream layer nudge behavior");
        command({{"action", "transformBegin"}});
        require(window.sessionState().value("transforming").toBool(), "Layers transform-key fixture did not start");
        tableKey(Qt::Key_Right, Qt::ShiftModifier);
        tableKey(Qt::Key_Escape);
        require(!window.sessionState().value("transforming").toBool()
                && window.sessionState().value("layers").toArray().first() == afterNudge,
                "Layers Escape did not cancel the Shift-arrow transform draft");
        command({{"action", "transformBegin"}});
        tableKey(Qt::Key_Right, Qt::ShiftModifier);
        tableKey(Qt::Key_Return);
        QJsonObject committedTransform = afterNudge.value("transform").toObject();
        const auto committedOrigin = committedTransform.value("origin");
        if (committedOrigin.isArray()) {
            auto origin = committedOrigin.toArray(); origin[0] = origin[0].toDouble() + 10;
            committedTransform.insert("origin", origin);
        } else {
            auto origin = committedOrigin.toObject(); origin.insert("x", origin.value("x").toDouble() + 10);
            committedTransform.insert("origin", origin);
        }
        require(!window.sessionState().value("transforming").toBool()
                && window.sessionState().value("layers").toArray().first().toObject().value("transform").toObject() == committedTransform,
                "Layers Return did not commit the ten-pixel Shift-arrow transform");
        command({{"action", "undo"}});
        require(window.sessionState().value("layers").toArray().first() == afterNudge,
                "Layers transform-key commit did not undo in one step");
        qInfo("Qt native layer keyboard OK (stable navigation viewport, disjoint ranges, paging/type selection, 17 tool keys, Tab/palette/opacity keys, Move and Shift nudges, Escape/Return transform and Undo)");

        // The upstream AppKit layer thumbnail's Shift-click must invalidate the
        // cached frame even though it keeps the same mask image object.
        checkMaskToggle();
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
        if (moved == masked) {
            double viewport[6] = {};
            compositor_session_viewport(window.sessionHandle(), viewport);
            qWarning() << "mask drag diagnostic: canvas=" << window.findChild<QWidget *>("editorCanvas")->size()
                       << "zoom/dpr=" << viewport[0] << viewport[3] << "view=" << viewport[4] << viewport[5]
                       << "transforming=" << window.sessionState().value("transforming")
                       << "mask selected=" << window.sessionState().value("isMaskSelected")
                       << "layers=" << window.sessionState().value("layers");
            for (auto *field : window.findChildren<QLineEdit *>())
                if (field->isVisible()) qWarning() << "mask drag field:" << field->accessibleName() << field->text();
        }
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
        {
            const QString corruptPackage = temporary.filePath("corrupt-load.comp");
            require(QDir().mkpath(corruptPackage + "/images"), "corrupt-load fixture directory failed");
            require(QFile::copy(textPackage + "/manifest.json", corruptPackage + "/manifest.json"),
                    "corrupt-load fixture manifest copy failed");
            for (const QString &name : QDir(textPackage + "/images").entryList(QDir::Files))
                require(QFile::copy(textPackage + "/images/" + name, corruptPackage + "/images/" + name),
                        "corrupt-load fixture asset copy failed");
            require(textLayers.size() >= 2, "corrupt-load fixture needs an earlier valid asset");
            QFile corruptAsset(corruptPackage + "/images/" + textLayer.value("imageFile").toString());
            require(corruptAsset.open(QIODevice::ReadOnly), "corrupt-load image missing");
            const QByteArray png = corruptAsset.readAll(); corruptAsset.close();
            int truncatedSize = 0;
            for (int offset = 8; offset + 12 <= png.size();) {
                quint32 length = 0;
                for (int byte = 0; byte < 4; ++byte) length = (length << 8) | static_cast<unsigned char>(png.at(offset + byte));
                require(length <= static_cast<quint32>(png.size() - offset - 12), "invalid fixture PNG chunk");
                if (png.mid(offset + 4, 4) == "IDAT") { truncatedSize = offset + 8 + qMin<quint32>(length, 1); break; }
                offset += static_cast<int>(length) + 12;
            }
            require(truncatedSize > 0, "corrupt-load fixture lacks PNG image data");
            require(corruptAsset.open(QIODevice::WriteOnly | QIODevice::Truncate), "corrupt-load image update failed");
            require(corruptAsset.write(png.left(truncatedSize)) == truncatedSize, "corrupt-load image truncation failed");
            corruptAsset.close();
            QImageReader corruptHeader(corruptAsset.fileName());
            require(corruptHeader.size().isValid() && corruptHeader.format().toLower() == "png",
                    "corrupt-load fixture must pass header validation before decode failure");
            const auto beforeRenameLayers = window.sessionState().value("layers");
            command({{"action", "renameLayer"}, {"name", "Unsaved before failed load"}});
            const auto beforeLoad = window.sessionState();
            const auto beforePixels = frame();
            const auto beforeHandle = window.sessionHandle();
            require(beforeLoad.value("modified").toBool() && beforeLoad.value("canUndo").toBool(),
                    "corrupt-load fixture needs unsaved history");
            require(!window.readProjectPackage(corruptPackage), "truncated asset was accepted by native package loader");
            const auto afterLoad = window.sessionState();
            require(window.sessionHandle() == beforeHandle && afterLoad.value("layers") == beforeLoad.value("layers")
                    && afterLoad.value("activeLayerID") == beforeLoad.value("activeLayerID")
                    && afterLoad.value("undoName") == beforeLoad.value("undoName")
                    && afterLoad.value("modified").toBool() && afterLoad.value("canUndo").toBool()
                    && frame() == beforePixels, "failed staged load changed the existing unsaved document or history");
            command({{"action", "undo"}});
            require(window.sessionState().value("layers") == beforeRenameLayers,
                    "failed staged load damaged the previous Undo snapshot");
            command({{"action", "redo"}});
            require(window.sessionState().value("layers") == beforeLoad.value("layers") && frame() == beforePixels,
                    "failed staged load damaged Redo or its document pixels");
            qInfo("Qt staged package failure recovery OK (later asset decode failure, old document/pixels/history preserved, Undo/Redo)");
        }
        require(window.readProjectPackage(textPackage), "colored text fixture reopen failed");
        const auto transform = textLayer.value("transform").toObject();
        const auto origin = transform.value("origin").toArray(), size = transform.value("size").toArray();
        command({{"action", "textEditAt"}, {"x", origin.at(0).toDouble() + size.at(0).toDouble() / 2},
                 {"y", origin.at(1).toDouble() + size.at(1).toDouble() / 2}});
        auto *editor = window.findChild<QPlainTextEdit *>("canvas.textEditor");
        require(editor && editor->isVisible(), "native text editor did not open");
        editor->setFocus(); QApplication::processEvents();
        require(editor->hasFocus(), "native text menu fixture lacks editor focus");
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
        const auto visibleTextAction = [&](const QString &title) -> QAction * {
            std::function<QAction *(QMenu *)> find = [&](QMenu *menu) -> QAction * {
                for (QAction *action : menu->actions()) {
                    if (action->menu()) { if (auto *found = find(action->menu())) return found; }
                    else if (action->isVisible() && action->text().remove('&') == title) return action;
                }
                return nullptr;
            };
            for (QAction *root : window.menuBar()->actions()) {
                if (!root->isVisible() || !root->menu()) continue;
                // AppKit/Qt validate when a menu opens, before a user can choose its action.
                QMetaObject::invokeMethod(root->menu(), "aboutToShow", Qt::DirectConnection);
                if (auto *found = find(root->menu())) return found;
            }
            return nullptr;
        };
        auto *textUndo = visibleTextAction("Undo");
        auto *textRedo = visibleTextAction("Redo");
        require(textUndo, "visible native text Undo action missing");
        require(textUndo->isEnabled(), "visible native text Undo action disabled");
        // Regression control: the former host never registered a native responder for these menu actions.
        if (qEnvironmentVariableIsSet("COMPOSITOR_PROBE_WITHOUT_TEXT_RESPONDER"))
            compositor_set_native_text_action_handler(nullptr);
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
        const auto preservedTextLayers = window.sessionState().value("layers");
        const auto textSelection = window.sessionState().value("hasSelection");
        require(textSelection.isBool(), "native text fixture lacks canvas selection state");
        editor->setFocus(); QApplication::processEvents();
        require(editor->hasFocus(), "native clipboard fixture lacks text focus");
        auto *textAll = visibleTextAction("All");
        require(textAll && textAll->isEnabled(), "visible text Select All missing");
        textAll->trigger(); QApplication::processEvents();
        require(editor->textCursor().selectedText() == QString::fromUtf8("A😀BCDEF"), "visible Select All did not select the text");
        cursor = editor->textCursor(); cursor.setPosition(1); cursor.setPosition(3, QTextCursor::KeepAnchor); editor->setTextCursor(cursor);
        auto *textCopy = visibleTextAction("Copy"), *textCut = visibleTextAction("Cut"), *textPaste = visibleTextAction("Paste");
        require(textCopy && textCut && textPaste && textCopy->isEnabled() && textCut->isEnabled() && textPaste->isEnabled(),
                "visible clipboard text actions missing or disabled");
        textCopy->trigger(); QApplication::processEvents();
        require(QApplication::clipboard()->text() == QString::fromUtf8("😀"), "visible Copy did not copy selected Unicode text");
        {
            CommandPaletteDialog palette(&window, &window);
            auto *filter = palette.findChild<QLineEdit *>("commandPalette.filter");
            auto *list = palette.findChild<QListWidget *>("commandPalette.list");
            require(filter && list && list->count() > 0, "native palette catalog missing");
            // Upstream CommandPaletteView: its placeholder, "No commands match" over an empty list, and shortcuts in a
            // column of their own rather than appended to the title.
            require(filter->placeholderText() == QLatin1String("Search commands and tools"), "native palette placeholder differs from upstream");
            auto *empty = palette.findChild<QLabel *>("commandPalette.empty");
            require(empty && empty->isHidden(), "native palette shows its empty state over results");
            filter->setText("zzzzqq");
            require(list->count() == 0 && !empty->isHidden() && empty->text() == QLatin1String("No commands match"),
                    "native palette lacks upstream's 'No commands match'");
            filter->clear();
            bool shortcutColumn = false;
            for (int row = 0; row < list->count(); ++row) {
                const QString shortcut = list->item(row)->data(Qt::UserRole + 2).toString();
                if (!shortcut.isEmpty() && !list->item(row)->text().contains(shortcut)) shortcutColumn = true;
            }
            require(shortcutColumn, "native palette shortcuts are not in their own column");
            int copies = 0, disabled = -1;
            for (int row = 0; row < list->count(); ++row) {
                const auto id = list->item(row)->data(Qt::UserRole).toString();
                require(!id.startsWith("Compositor ›") && !id.startsWith("Help ›") && !id.startsWith("Window ›"),
                        "native palette included a skipped system menu");
                if (id == QString::fromUtf8("Edit › Copy")) ++copies;
                if (!list->item(row)->data(Qt::UserRole + 1).toBool()) disabled = row;
            }
            require(copies == 1, "native palette duplicated a hidden legacy Copy action");
            require(disabled >= 0, "native palette lost disabled commands");
            list->setCurrentRow(disabled); palette.show(); QApplication::processEvents();
            QMetaObject::invokeMethod(filter, "returnPressed", Qt::DirectConnection);
            require(palette.isVisible(), "choosing a disabled palette entry closed the launcher");
            palette.reject(); QApplication::processEvents();
            filter->setText("pol la");
            require(list->count() > 0 && list->item(0)->data(Qt::UserRole).toString() == QString::fromUtf8("Tool › Polygonal Lasso"),
                    "native palette did not expose upstream tool modes and fuzzy ranking");
            filter->clear();
            require(list->count() > 1, "native wrapping fixture needs multiple results");
            list->setCurrentRow(0);
            QKeyEvent up(QEvent::KeyPress, Qt::Key_Up, Qt::NoModifier);
            QCoreApplication::sendEvent(filter, &up);
            require(list->currentRow() == list->count() - 1, "native palette Up did not wrap");
            QKeyEvent down(QEvent::KeyPress, Qt::Key_Down, Qt::NoModifier);
            QCoreApplication::sendEvent(filter, &down);
            require(list->currentRow() == 0, "native palette Down did not wrap");
            filter->setText("Copy");
            require(list->count() > 0 && list->item(0)->data(Qt::UserRole).toString() == QString::fromUtf8("Edit › Copy"),
                    "native palette Copy ranking selected the wrong command");
            QApplication::clipboard()->setText("palette sentinel");
            QTimer::singleShot(0, &palette, [filter] { QMetaObject::invokeMethod(filter, "returnPressed", Qt::DirectConnection); });
            QTimer::singleShot(5000, &palette, &QDialog::reject);
            require(palette.exec() == QDialog::Accepted, "native palette did not run enabled Copy");
            QApplication::processEvents();
            require(editor->hasFocus() && QApplication::clipboard()->text() == QString::fromUtf8("😀"),
                    "native palette Copy did not restore text focus before dispatch");
            qInfo("Qt upstream command palette OK (single catalog, skipped menus, tool modes, fuzzy ranking, disabled refusal, wrapping, focused text dispatch)");
        }
        const auto readonlyDraft = draft();
        editor->setReadOnly(true);
        textCut->trigger(); textPaste->trigger(); QApplication::processEvents();
        require(draft() == readonlyDraft && window.sessionState().value("layers") == preservedTextLayers,
                "read-only text Cut/Paste fell through to the document");
        editor->setReadOnly(false);
        textCut->trigger(); QApplication::processEvents();
        require(draft().value("content").toString() == "ABCDEF", "visible Cut edited document pixels instead of text");
        auto *plainPaste = new QMimeData;
        plainPaste->setText(QString::fromUtf8("😀")); plainPaste->setHtml("<b>wrong rich-text payload</b>");
        QApplication::clipboard()->setMimeData(plainPaste);
        textPaste->trigger(); QApplication::processEvents();
        require(draft().value("content").toString() == QString::fromUtf8("A😀BCDEF"), "visible Paste did not use plain Unicode text");
        textUndo->trigger(); QApplication::processEvents();
        require(draft().value("content").toString() == "ABCDEF", "visible Paste undo failed");
        textUndo->trigger(); QApplication::processEvents();
        require(draft().value("content").toString() == QString::fromUtf8("A😀BCDEF")
                && draft().value("fontRuns").toArray() == originalFonts && draft().value("colorRuns").toArray() == originalColors,
                "visible Cut undo did not restore text and attributes");
        cursor = editor->textCursor(); cursor.setPosition(8); editor->setTextCursor(cursor);
        const auto beforeComposition = draft();
        QInputMethodEvent preedit(QString::fromUtf8("你"), {});
        QCoreApplication::sendEvent(editor, &preedit); QApplication::processEvents();
        require(editor->toPlainText() == QString::fromUtf8("A😀BCDEF") && draft() == beforeComposition,
                "IME preedit committed draft text prematurely");
        QInputMethodEvent commit; commit.setCommitString(QString::fromUtf8("你"));
        QCoreApplication::sendEvent(editor, &commit); QApplication::processEvents();
        require(draft().value("content").toString() == QString::fromUtf8("A😀BCDEF你"), "IME commit did not reach the text draft");
        textUndo->trigger(); QApplication::processEvents();
        require(draft().value("content").toString() == QString::fromUtf8("A😀BCDEF"), "visible IME undo failed");
        require(window.sessionState().value("layers") == preservedTextLayers && window.sessionState().value("hasSelection") == textSelection,
                "native text actions changed persistent layers or canvas selection");
        qInfo("Qt visible text menu OK (Undo/Redo, Select All, Unicode Copy/Cut/plain Paste, font/color restoration, IME preedit/commit)");
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
        const auto chooseFont = [&](const QString &query) {
            const int beforePreviewSteps = editor->document()->availableUndoSteps();
            // The closed control only displays the current face in 1.5.4. Choose through the upstream search panel.
            QElapsedTimer delay; delay.start();
            upstream154journey::settle([&] { return delay.elapsed() >= 300; }, "font panel reopen delay did not finish");
            auto *control = fontPicker(); require(control, "font control disappeared before opening its panel");
            control->showPopup();
            const auto popup = [&]() -> QDialog * {
                for (auto *dialog : window.findChildren<QDialog *>())
                    if (dialog->isVisible() && dialog->objectName().startsWith(QLatin1String("floatingPanel.NativeWindow:"))) return dialog;
                return nullptr;
            };
            const auto search = [&]() -> QLineEdit * {
                if (auto *dialog = popup()) for (auto *field : dialog->findChildren<QLineEdit *>())
                    if (field->isVisible() && field->placeholderText() == QLatin1String("Search Fonts")) return field;
                return nullptr;
            };
            upstream154journey::settle([&] { return search() != nullptr; }, "font search panel did not open");
            for (QChar character : query) {
                auto *field = search(); require(field, "font search field disappeared while typing");
                field->setFocus(); upstream154journey::key(field, 0, QString(character));
            }
            // Exercise live highlights before committing, with time for the native editor to synchronize each one.
            for (int key : {Qt::Key_Down, Qt::Key_Up}) {
                upstream154journey::key(search(), key, {});
                QElapsedTimer preview; preview.start();
                upstream154journey::settle([&] { return preview.elapsed() >= 300; }, "font highlight did not settle");
                require(editor->document()->availableUndoSteps() == beforePreviewSteps,
                        "font highlight added a native undo step before the choice was committed");
            }
            upstream154journey::key(search(), Qt::Key_Return, QStringLiteral("\r"));
            upstream154journey::settle([&] { return popup() == nullptr; }, "font panel did not accept its selection");
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
        const auto beforeToolbarFonts = draft().value("fontRuns");
        const int beforeToolbarSteps = editor->document()->availableUndoSteps();
        chooseFont(testFace);
        const QString chosenFace = draft().value("fontName").toString();
        require(!chosenFace.isEmpty() && QFontInfo(fontFor(chosenFace.toUtf8().constData(), 13)).family() == testFace
                    && draft().value("fontRuns").toArray().isEmpty(),
                "toolbar font did not apply to selected letters");
        require(editor->textCursor().selectedText() == editor->toPlainText(), "font toolbar lost native selection");
        require(editor->document()->isUndoAvailable(), "font toolbar cleared native typing undo");
        // Undo immediately through the native responder, before the next periodic state sync. The committed
        // font must get its own history step ahead of the existing typing edit.
        QKeyEvent undoFont(QEvent::KeyPress, Qt::Key_Z, Qt::ControlModifier);
        QApplication::sendEvent(editor, &undoFont); QApplication::processEvents();
        if (draft().value("fontRuns").toArray().first().toObject().value("length").toInt() != 5)
            qWarning() << "Font toolbar Undo:" << "before steps" << beforeToolbarSteps
                       << "after steps" << editor->document()->availableUndoSteps()
                       << "before runs" << beforeToolbarFonts << "after draft" << draft();
        require(draft().value("fontRuns").toArray().first().toObject().value("length").toInt() == 5,
                "native undo did not restore fonts before the toolbar change");
        editor->undo(); QApplication::processEvents();
        require(draft().value("content").toString() == QString::fromUtf8("A😀BCDEF") &&
                draft().value("fontRuns").toArray() == originalFonts && draft().value("colorRuns").toArray() == originalColors,
                "typing undo after formatting lost metadata");
        editor->redo(); QApplication::processEvents(); editor->redo(); QApplication::processEvents();
        require(draft().value("content").toString() == QString::fromUtf8("A😀Bé🦊DEF") &&
                draft().value("fontName").toString() == chosenFace && draft().value("fontRuns").toArray().isEmpty(),
                "native redo did not restore typing and toolbar formatting");
        cursor = editor->textCursor(); cursor.setPosition(1); cursor.setPosition(3, QTextCursor::KeepAnchor);
        editor->setTextCursor(cursor); QApplication::processEvents();
        picker = fontPicker(); require(picker != nullptr, "font picker disappeared");
        const QString otherFace = QStringLiteral("Helvetica-Bold");
        chooseFont(QStringLiteral("Helvetica Bold"));
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
        // New saves use version 16 (filter adjustment layers); font runs arrived in version 11.
        require(textManifest.value("version").toInt() == 16, "native save did not write current format 16");
        require(savedText.value("fontRuns").toArray() == chosenRuns, "format-11 save lost chosen font runs");
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
        {
            const auto beforeMode = window.sessionState();
            const auto beforeModePixels = frame();
            CommandPaletteDialog palette(&window, &window);
            auto *filter = palette.findChild<QLineEdit *>("commandPalette.filter");
            auto *list = palette.findChild<QListWidget *>("commandPalette.list");
            require(filter && list, "tool palette controls missing");
            filter->setText("Polygonal Lasso");
            require(list->count() > 0 && list->item(0)->data(Qt::UserRole).toString() == QString::fromUtf8("Tool › Polygonal Lasso"),
                    "tool palette selected the wrong mode entry");
            QTimer::singleShot(0, &palette, [filter] { QMetaObject::invokeMethod(filter, "returnPressed", Qt::DirectConnection); });
            QTimer::singleShot(5000, &palette, &QDialog::reject);
            require(palette.exec() == QDialog::Accepted, "tool palette refused the enabled mode");
            QApplication::processEvents();
            const auto afterMode = window.sessionState();
            require(afterMode.value("tool").toString() == "lasso" && afterMode.value("lassoKind").toString() == "Polygonal",
                    "palette mode dispatch did not reach the upstream session");
            require(afterMode.value("layers") == beforeMode.value("layers") && afterMode.value("undoName") == beforeMode.value("undoName")
                    && frame() == beforeModePixels, "palette tool choice changed pixels or document history");
            qInfo("Qt palette tool mode OK (Polygonal Lasso selected, pixels and document history unchanged)");
        }
        qInfo("Qt preview journey OK (layer/folder mask Shift-click, unlinked mask drag, Ctrl/Ctrl+Alt pixel drags, colored native text editing, undo/redo)");
        return 0;
    } catch (const std::exception &e) {
        qCritical("Qt preview journey failed: %s", e.what());
        qWarning().noquote() << swiftUIPointerTrace();
        qWarning().noquote() << swiftUIScrollTrace();
        return 1;
    }
}

extern "C" int compositor_host_tab_smoke(int argc, char **argv) {
    QApplication app(argc, argv);
    installJourneyUI(app);
    try {
        SessionWindow window;
        window.resize(1200, 900); window.show(); QApplication::setActiveWindow(&window);
        QApplication::processEvents();
        require(window.sendCommand({{"action", "new"}, {"width", 64}, {"height", 64}}), "first tab document failed");
        const uint64_t first = window.sessionHandle();
        window.createNewDocument(32, 24);
        const uint64_t second = window.sessionHandle();
        auto *tabs = window.findChild<QTabBar *>("header.documentTabs");
        require(tabs && tabs->count() == 2 && first != second, "distinct native tabs missing");
        require(compositor_workspace_select_tab(0) == -6, "invalid workspace handle was accepted");
        const auto state = [&](uint64_t handle) {
            const int64_t size = compositor_session_state(handle, nullptr, 0);
            require(size > 0 && size < 4 * 1024 * 1024, "tab state unavailable");
            QByteArray data(size, Qt::Uninitialized);
            require(compositor_session_state(handle, reinterpret_cast<uint8_t *>(data.data()), data.size()) == size,
                    "tab state read failed");
            return QJsonDocument::fromJson(data).object();
        };
        const auto pixels = [&](uint64_t handle) {
            const int64_t size = compositor_session_render(handle, nullptr, 0);
            require(size > 0 && size < 4 * 1024 * 1024, "tab pixels unavailable");
            QByteArray data(size, Qt::Uninitialized);
            require(compositor_session_render(handle, reinterpret_cast<uint8_t *>(data.data()), data.size()) == size,
                    "tab pixels read failed");
            return data;
        };
        const auto mouse = [&](QWidget *target, QEvent::Type type, QPointF point, Qt::MouseButtons buttons) {
            QMouseEvent event(type, point, QPointF(target->mapToGlobal(point.toPoint())),
                              Qt::LeftButton, buttons, Qt::NoModifier);
            QApplication::sendEvent(target, &event);
            QApplication::processEvents();
        };
        const auto clickTab = [&](int index) {
            if (!tabs->isTabVisible(index)) {
                auto *overflow = window.findChild<QToolButton *>("header.tabOverflow");
                require(overflow && overflow->menu(), "hidden tab lacks its overflow menu");
                QAction *choose = nullptr;
                for (auto *action : overflow->menu()->actions())
                    if (action->text() == tabs->tabText(index)) { choose = action; break; }
                require(choose, "hidden tab missing from overflow menu");
                choose->trigger(); QApplication::processEvents();
                require(tabs->currentIndex() == index && tabs->isTabVisible(index), "overflow did not select and reveal its tab");
                return;
            }
            const QPointF point = tabs->tabRect(index).center();
            mouse(tabs, QEvent::MouseButtonPress, point, Qt::LeftButton);
            mouse(tabs, QEvent::MouseButtonRelease, point, Qt::NoButton);
        };
        const auto addViaVisibleMenu = [&](SessionWindow *target = nullptr, bool perform = true) {
            auto &owner = target ? *target : window;
            QAction *found = nullptr;
            std::function<void(QMenu *)> visit = [&](QMenu *menu) {
                for (QAction *action : menu->actions()) {
                    if (action->menu()) visit(action->menu());
                    else if (action->isVisible() && action->text().remove('&') == "New Blank Layer") found = action;
                }
            };
            for (QAction *root : owner.menuBar()->actions()) {
                if (!root->isVisible() || !root->menu()) continue;
                QMetaObject::invokeMethod(root->menu(), "aboutToShow", Qt::DirectConnection);
                visit(root->menu());
            }
            require(found && found->isEnabled(), "visible New Blank Layer unavailable");
            if (perform) { found->trigger(); QApplication::processEvents(); }
            return found;
        };
        const auto firstBefore = state(first), secondBefore = state(second);
        const auto secondPixels = pixels(second);
        const auto firstBeforeReorderPixels = pixels(first);
        tabs->moveTab(1, 0);
        QApplication::processEvents();
        require(window.sessionHandle() == second && tabs->currentIndex() == 0,
                "moving the selected tab changed document identity");
        clickTab(1);
        require(window.sessionHandle() == first, "reordered tab selected the wrong document");
        tabs->moveTab(0, 1);
        QApplication::processEvents();
        require(window.sessionHandle() == first && tabs->currentIndex() == 0,
                "moving an inactive tab changed document selection");
        clickTab(1);
        require(window.sessionHandle() == second, "restored tab order lost its document identity");
        require(state(first).value("layers") == firstBefore.value("layers")
                && state(first).value("undoName") == firstBefore.value("undoName") && pixels(first) == firstBeforeReorderPixels
                && state(second).value("layers") == secondBefore.value("layers")
                && state(second).value("undoName") == secondBefore.value("undoName") && pixels(second) == secondPixels,
                "tab reordering changed document pixels or history");
        const auto dragTab = [&](int from, int to) {
            const QPointF start = tabs->tabRect(from).center();
            const QPointF finish = tabs->tabRect(to).center() + QPointF(to < from ? -25 : 25, 0);
            mouse(tabs, QEvent::MouseButtonPress, start, Qt::LeftButton);
            const int steps = qMax(1, int(qAbs(finish.x() - start.x()) / 4));
            for (int step = 1; step <= steps; ++step)
                mouse(tabs, QEvent::MouseMove, start + (finish - start) * (double(step) / steps), Qt::LeftButton);
            mouse(tabs, QEvent::MouseButtonRelease, finish, Qt::NoButton);
        };
        dragTab(1, 0);
        require(window.sessionHandle() == second && tabs->currentIndex() == 0,
                "pointer tab reorder changed its selected document");
        clickTab(1);
        require(window.sessionHandle() == first, "pointer-reordered tab lost its document identity");
        addViaVisibleMenu();
        require(state(first).value("layers").toArray().size() == firstBefore.value("layers").toArray().size() + 1
                && state(second).value("layers") == secondBefore.value("layers")
                && state(second).value("undoName") == secondBefore.value("undoName") && pixels(second) == secondPixels,
                "pointer-reordered tab menu edited the wrong project");
        require(window.sendCommand({{"action", "undo"}}) && state(first).value("layers") == firstBefore.value("layers")
                && pixels(first) == firstBeforeReorderPixels, "pointer-reordered tab menu Undo changed pixels");
        dragTab(0, 1);
        require(window.sessionHandle() == second && tabs->currentIndex() == 1,
                "pointer reorder did not restore the original project order");
        clickTab(0);
        require(window.sessionHandle() == first && tabs->currentIndex() == 0, "first tab click did not select Qt document");
        addViaVisibleMenu();
        require(state(first).value("layers").toArray().size() == firstBefore.value("layers").toArray().size() + 1,
                "visible menu edited another workspace tab");
        require(state(second).value("layers") == secondBefore.value("layers")
                && state(second).value("undoName") == secondBefore.value("undoName"), "inactive tab changed through visible menu");
        require(window.sendCommand({{"action", "selectTool"}, {"kind", "brush"}}), "tab brush selection failed");
        auto *canvas = window.findChild<QWidget *>("editorCanvas");
        require(canvas, "tab canvas missing");
        const auto firstPixelsBeforeStroke = pixels(first);
        QTemporaryDir drops;
        require(drops.isValid(), "tab drop fixture directory unavailable");
        const QString droppedPath = drops.filePath("Tab destination.png");
        QImage droppedImage(8, 8, QImage::Format_RGBA8888);
        droppedImage.fill(QColor(40, 190, 70));
        require(droppedImage.save(droppedPath), "tab drop fixture image failed");
        QMimeData dropped;
        dropped.setUrls({QUrl::fromLocalFile(droppedPath)});
        const QPoint dropAt = tabs->tabRect(1).center();
        QDragEnterEvent enter(dropAt, Qt::CopyAction, &dropped, Qt::LeftButton, Qt::NoModifier);
        QApplication::sendEvent(tabs, &enter);
        require(enter.isAccepted() && enter.dropAction() == Qt::CopyAction, "ready tab strip refused a supported file drag");
        const QPointF center = canvas->rect().center();
        mouse(canvas, QEvent::MouseButtonPress, center, Qt::LeftButton);
        require(!state(first).value("canSwitch").toBool(true), "tab refusal fixture did not start a stroke");
        require(compositor_workspace_select_tab(first) == 0, "already-current busy tab was refused");
        require(compositor_workspace_select_tab(second) == -5, "workspace bridge did not report active-stroke refusal");
        int busyTabMoves = 0;
        const auto busyMoveConnection = QObject::connect(tabs, &QTabBar::tabMoved, &window,
                                                         [&](int, int) { ++busyTabMoves; });
        dragTab(1, 0);
        QObject::disconnect(busyMoveConnection);
        require(busyTabMoves == 0 && window.sessionHandle() == first && tabs->currentIndex() == 0,
                "tab pointer reorder escaped upstream active-stroke refusal");
        clickTab(1);
        require(window.sessionHandle() == first && tabs->currentIndex() == 0, "tab switch escaped active-stroke refusal");
        QDropEvent refusedDrop(QPointF(dropAt), Qt::CopyAction, &dropped, Qt::LeftButton, Qt::NoModifier);
        QApplication::sendEvent(tabs, &refusedDrop);
        require(refusedDrop.dropAction() == Qt::IgnoreAction && window.pendingDropCount() == 0,
                "busy tab strip accepted a drop for another document");
        QDragEnterEvent busyEnter(dropAt, Qt::CopyAction, &dropped, Qt::LeftButton, Qt::NoModifier);
        QApplication::sendEvent(tabs, &busyEnter);
        require(busyEnter.isAccepted() && busyEnter.dropAction() == Qt::IgnoreAction,
                "busy tab strip did not retain forbidden drag entry");
        QDragMoveEvent busyMove(dropAt, Qt::CopyAction, &dropped, Qt::LeftButton, Qt::NoModifier);
        QApplication::sendEvent(tabs, &busyMove);
        require(busyMove.isAccepted() && busyMove.dropAction() == Qt::IgnoreAction,
                "busy tab strip did not retain forbidden drag movement");
        auto *busyHeader = window.findChild<QWidget *>("header.dragArea");
        require(busyHeader && busyHeader->isVisible(), "busy header drop target missing");
        const QPoint busyHeaderPoint = busyHeader->rect().center();
        QDragEnterEvent headerEnter(busyHeaderPoint, Qt::CopyAction, &dropped, Qt::LeftButton, Qt::NoModifier);
        QApplication::sendEvent(busyHeader, &headerEnter);
        require(headerEnter.isAccepted() && headerEnter.dropAction() == Qt::IgnoreAction,
                "busy header drag entry fell through to the window");
        QDragMoveEvent headerMove(busyHeaderPoint, Qt::CopyAction, &dropped, Qt::LeftButton, Qt::NoModifier);
        QApplication::sendEvent(busyHeader, &headerMove);
        require(headerMove.isAccepted() && headerMove.dropAction() == Qt::IgnoreAction, "busy header movement was allowed");
        QDropEvent headerDrop(QPointF(busyHeaderPoint), Qt::CopyAction, &dropped, Qt::LeftButton, Qt::NoModifier);
        QApplication::sendEvent(busyHeader, &headerDrop);
        require(headerDrop.dropAction() == Qt::IgnoreAction && window.pendingDropCount() == 0 && tabs->count() == 2,
                "busy header drop queued an import or created a tab");
        mouse(canvas, QEvent::MouseButtonRelease, center, Qt::NoButton);
        require(state(first).value("canSwitch").toBool(), "stroke release did not restore tab switching");
        require(pixels(first) != firstPixelsBeforeStroke, "tab stroke fixture did not paint pixels");
        require(pixels(second) == secondPixels, "refused tab switch changed inactive pixels");
        dragTab(1, 0);
        require(window.sessionHandle() == second && tabs->currentIndex() == 0,
                "tab pointer reorder did not recover after stroke release");
        dragTab(0, 1);
        require(window.sessionHandle() == second && tabs->currentIndex() == 1,
                "recovered pointer reorder did not restore project order");
        clickTab(1);
        require(window.sessionHandle() == second && tabs->currentIndex() == 1, "tab switching did not recover after stroke");
        const auto firstAfter = state(first);
        const auto firstPixelsAfter = pixels(first);
        addViaVisibleMenu();
        require(state(second).value("layers").toArray().size() == secondBefore.value("layers").toArray().size() + 1,
                "recovered tab menu did not edit selected document");
        require(state(first).value("layers") == firstAfter.value("layers")
                && state(first).value("undoName") == firstAfter.value("undoName")
                && pixels(first) == firstPixelsAfter, "recovered menu changed inactive document");
        clickTab(0);
        const auto firstBeforeDrop = state(first);
        const auto firstBeforeDropPixels = pixels(first);
        const int secondLayerCount = state(second).value("layers").toArray().size();
        QDragEnterEvent readyEnter(dropAt, Qt::CopyAction, &dropped, Qt::LeftButton, Qt::NoModifier);
        QApplication::sendEvent(tabs, &readyEnter);
        require(readyEnter.isAccepted() && readyEnter.dropAction() == Qt::CopyAction, "tab strip did not recover after stroke");
        QDropEvent readyDrop(QPointF(dropAt), Qt::CopyAction, &dropped, Qt::LeftButton, Qt::NoModifier);
        QApplication::sendEvent(tabs, &readyDrop);
        QApplication::processEvents();
        require(readyDrop.isAccepted() && readyDrop.dropAction() == Qt::CopyAction
                && window.sessionHandle() == second && tabs->currentIndex() == 1
                && state(second).value("layers").toArray().size() == secondLayerCount + 1,
                "ready tab drop did not import into its destination");
        require(state(first).value("layers") == firstBeforeDrop.value("layers")
                && state(first).value("undoName") == firstBeforeDrop.value("undoName")
                && pixels(first) == firstBeforeDropPixels, "targeted tab drop changed the previous document");
        clickTab(0);
        const auto layerSource = state(first);
        const auto layerSourcePixels = pixels(first);
        const auto layerTarget = state(second);
        const auto layerTargetPixels = pixels(second);
        QWidget *sourceTable = nullptr;
        for (auto *candidate : window.findChildren<QWidget *>())
            if (candidate->isVisible() && candidate->property("appKitView").toBool()
                && candidate->property("appKitNode").toString().startsWith("LayersPanel|")) { sourceTable = candidate; break; }
        require(sourceTable, "native layer drag source missing");
        const QPoint row = sourceTable->mapTo(&window, QPoint(140, (layerSource.value("layers").toArray().size() - 1) * 54 + 26));
        const QPoint destinationPoint = tabs->mapTo(&window, tabs->tabRect(1).center());
        const auto nativePointer = [&](QEvent::Type type, QPoint point, Qt::MouseButtons buttons) {
            QMouseEvent event(type, QPointF(point), QPointF(window.mapToGlobal(point)), Qt::LeftButton, buttons, Qt::NoModifier);
            QApplication::sendEvent(window.windowHandle(), &event);
        };
        bool layerReleased = false, layerRestrictions = false;
        QTimer::singleShot(0, &window, [&] {
            nativePointer(QEvent::MouseMove, destinationPoint, Qt::LeftButton);
            QTimer::singleShot(20, &window, [&] {
                const int64_t count = compositor_current_layer_drag(nullptr, 0);
                if (count > 0 && count <= 1048576) {
                    QByteArray payload(count, Qt::Uninitialized);
                    if (compositor_current_layer_drag(reinterpret_cast<uint8_t *>(payload.data()), payload.size()) == count) {
                        const auto *bytes = reinterpret_cast<const uint8_t *>(payload.constData());
                        layerRestrictions = compositor_workspace_layer_drop_allowed(first, bytes, payload.size(), 0) == 0
                            && compositor_workspace_layer_drop_allowed(second, bytes, payload.size(), 2) == 0
                            && compositor_workspace_layer_drop_allowed(second, bytes, payload.size(), 0) == 1;
                    }
                }
                nativePointer(QEvent::MouseButtonRelease, destinationPoint, Qt::NoButton);
                layerReleased = true;
            });
        });
        nativePointer(QEvent::MouseButtonPress, row, Qt::LeftButton);
        QElapsedTimer layerDeadline; layerDeadline.start();
        while (!layerReleased && layerDeadline.elapsed() < 5000) QApplication::processEvents(QEventLoop::AllEvents, 10);
        require(layerReleased, "native layer drag did not release");
        require(layerRestrictions, "native layer drag did not apply same-project and Alt refusal");
        require(window.sessionHandle() == second && state(second).value("layers").toArray().size() == layerTarget.value("layers").toArray().size() + 1,
                "native layer-row drag did not reach the destination project tab");
        require(compositor_current_layer_drag(nullptr, 0) == 0, "completed native layer drag retained its session");
        const auto copiedLayer = state(second).value("layers").toArray().last().toObject();
        const auto originalLayer = layerSource.value("layers").toArray().first().toObject();
        require(copiedLayer.value("name") == originalLayer.value("name") && copiedLayer.value("id") != originalLayer.value("id"),
                "native project copy lost the layer name or reused its identity");
        require(state(first).value("layers") == layerSource.value("layers")
                && state(first).value("undoName") == layerSource.value("undoName")
                && pixels(first) == layerSourcePixels, "native project copy changed source pixels or history");
        const auto layerCopyPixels = pixels(second);
        require(window.sendCommand({{"action", "undo"}}), "native project-copy undo failed");
        require(state(second).value("layers") == layerTarget.value("layers") && pixels(second) == layerTargetPixels,
                "native project-copy undo did not restore its destination");
        require(window.sendCommand({{"action", "redo"}}) && pixels(second) == layerCopyPixels,
                "native project-copy redo changed copied pixels");
        clickTab(0);
        const auto beforeRepeat = state(second);
        const auto beforeRepeatPixels = pixels(second);
        layerReleased = false; layerRestrictions = false;
        QTimer::singleShot(0, &window, [&] {
            nativePointer(QEvent::MouseMove, destinationPoint, Qt::LeftButton);
            QTimer::singleShot(20, &window, [&] {
                nativePointer(QEvent::MouseButtonRelease, destinationPoint, Qt::NoButton);
                layerReleased = true;
            });
        });
        nativePointer(QEvent::MouseButtonPress, row, Qt::LeftButton);
        layerDeadline.restart();
        while (!layerReleased && layerDeadline.elapsed() < 5000) QApplication::processEvents(QEventLoop::AllEvents, 10);
        require(layerReleased && window.sessionHandle() == second
                && state(second).value("layers").toArray().size() == beforeRepeat.value("layers").toArray().size() + 1,
                "repeated native drag reused stale rows or lost its destination");
        require(compositor_current_layer_drag(nullptr, 0) == 0, "repeated native drag retained its session");
        require(window.sendCommand({{"action", "undo"}}) && state(second).value("layers") == beforeRepeat.value("layers")
                && pixels(second) == beforeRepeatPixels, "repeated native drag did not undo as one fresh copy");
        clickTab(0);
        auto *emptyHeader = window.findChild<QWidget *>("header.dragArea");
        require(emptyHeader && emptyHeader->isVisible() && emptyHeader->width() > 20, "empty header drop space missing");
        const QPoint newProjectPoint = emptyHeader->mapTo(&window, emptyHeader->rect().center());
        const int oldTabCount = tabs->count();
        const auto beforeNewProject = state(first);
        const auto beforeNewProjectPixels = pixels(first);
        layerReleased = false;
        QTimer::singleShot(0, &window, [&] {
            nativePointer(QEvent::MouseMove, newProjectPoint, Qt::LeftButton);
            QTimer::singleShot(20, &window, [&] {
                nativePointer(QEvent::MouseButtonRelease, newProjectPoint, Qt::NoButton);
                layerReleased = true;
            });
        });
        nativePointer(QEvent::MouseButtonPress, row, Qt::LeftButton);
        layerDeadline.restart();
        while (!layerReleased && layerDeadline.elapsed() < 5000) QApplication::processEvents(QEventLoop::AllEvents, 10);
        require(layerReleased && tabs->count() == oldTabCount + 1 && window.sessionHandle() != first
                && window.sessionHandle() != second, "native header layer drop did not create a project");
        const auto created = window.sessionState();
        require(created.value("layers").toArray().size() == 1
                && created.value("layers").toArray().first().toObject().value("name") == originalLayer.value("name"),
                "header layer drop did not create a project containing the dragged layer");
        const auto originalSize = originalLayer.value("transform").toObject().value("size");
        const double fittedWidth = originalSize.isArray() ? originalSize.toArray().at(0).toDouble() : originalSize.toObject().value("width").toDouble();
        const double fittedHeight = originalSize.isArray() ? originalSize.toArray().at(1).toDouble() : originalSize.toObject().value("height").toDouble();
        require(fittedWidth > 0 && fittedHeight > 0 && created.value("width").toDouble() == fittedWidth
                && created.value("height").toDouble() == fittedHeight, "header project did not fit its dragged pixels");
        require(state(first).value("layers") == beforeNewProject.value("layers")
                && state(first).value("undoName") == beforeNewProject.value("undoName")
                && pixels(first) == beforeNewProjectPixels, "header project creation changed its source");
        const auto createdPixels = pixels(window.sessionHandle());
        require(window.sendCommand({{"action", "undo"}}) && window.sessionState().value("width").toInt() == 0
                && window.sessionState().value("layers").toArray().isEmpty(),
                "header project-copy undo did not restore the welcome state");
        require(window.sendCommand({{"action", "redo"}}) && pixels(window.sessionHandle()) == createdPixels,
                "header project-copy redo changed its pixels");
        for (bool imagePayload : {false, true}) {
            QMimeData input;
            QImage image(7, 5, QImage::Format_RGBA8888); image.fill(QColor(80, 130, 220, 180));
            if (imagePayload) input.setImageData(image);
            else input.setUrls(dropped.urls());
            const int beforeCount = tabs->count();
            const uint64_t previousHandle = window.sessionHandle();
            const auto previousState = window.sessionState();
            const auto previousPixels = pixels(previousHandle);
            const QPoint at = emptyHeader->rect().center();
            QDragEnterEvent ready(at, Qt::CopyAction, &input, Qt::LeftButton, Qt::NoModifier);
            QApplication::sendEvent(emptyHeader, &ready);
            require(ready.isAccepted() && ready.dropAction() == Qt::CopyAction, "header refused a ready file/image drag");
            QDropEvent import(QPointF(at), Qt::CopyAction, &input, Qt::LeftButton, Qt::NoModifier);
            QApplication::sendEvent(emptyHeader, &import);
            QApplication::processEvents();
            require(import.isAccepted() && import.dropAction() == Qt::CopyAction && tabs->count() == beforeCount + 1
                    && window.sessionHandle() != previousHandle, "header file/image drop did not create a new project");
            require(window.sessionState().value("width").toInt() == (imagePayload ? 7 : 8)
                    && window.sessionState().value("height").toInt() == (imagePayload ? 5 : 8)
                    && window.sessionState().value("layers").toArray().size() == 1,
                    "header file/image project did not fit its image");
            require(state(previousHandle).value("layers") == previousState.value("layers")
                    && state(previousHandle).value("undoName") == previousState.value("undoName")
                    && pixels(previousHandle) == previousPixels, "header file/image import changed the previous project");
        }
        const auto dragRows = [&](int visualRow, QPoint globalDestination) {
            QWidget *table = nullptr;
            for (auto *candidate : window.findChildren<QWidget *>())
                if (candidate->isVisible() && candidate->property("appKitView").toBool()
                    && candidate->property("appKitNode").toString().startsWith("LayersPanel|")) { table = candidate; break; }
            require(table, "extended drag source table missing");
            const QPoint start = table->mapTo(&window, QPoint(140, visualRow * 54 + 26));
            const QPoint finish = window.mapFromGlobal(globalDestination);
            bool released = false;
            QTimer::singleShot(0, &window, [&] {
                nativePointer(QEvent::MouseMove, finish, Qt::LeftButton);
                QTimer::singleShot(20, &window, [&] {
                    nativePointer(QEvent::MouseButtonRelease, finish, Qt::NoButton);
                    released = true;
                });
            });
            nativePointer(QEvent::MouseButtonPress, start, Qt::LeftButton);
            QElapsedTimer deadline; deadline.start();
            while (!released && deadline.elapsed() < 5000) QApplication::processEvents(QEventLoop::AllEvents, 10);
            require(released && compositor_current_layer_drag(nullptr, 0) == 0, "extended drag did not release its session");
        };
        // Show both original projects after the preceding drops filled the strip.
        window.resize(2200, 900);
        QApplication::processEvents();
        const int multiTargetIndex = 1;
        clickTab(0);
        require(window.sessionHandle() == first, "extended drag did not select its source");
        require(tabs->isTabVisible(multiTargetIndex), "extended drag destination is hidden");
        addViaVisibleMenu();
        const auto multiSource = window.sessionState();
        const auto multiLayers = multiSource.value("layers").toArray();
        require(multiLayers.size() >= 2, "multi-row fixture lacks multiple layers");
        for (int i = 0; i < multiLayers.size(); ++i)
            require(window.sendCommand({{"action", "selectLayer"}, {"layerID", multiLayers.at(i).toObject().value("id")}, {"enabled", i > 0}}),
                    "multi-row selection failed");
        const auto multiBefore = state(second);
        const auto multiBeforePixels = pixels(second);
        const auto multiSourcePixels = pixels(first);
        dragRows(0, tabs->mapToGlobal(tabs->tabRect(multiTargetIndex).center()));
        require(window.sessionHandle() == second
                && state(second).value("layers").toArray().size() == multiBefore.value("layers").toArray().size() + multiLayers.size(),
                "multiple native rows did not reach the destination");
        require(state(first).value("layers") == multiSource.value("layers")
                && state(first).value("undoName") == multiSource.value("undoName") && pixels(first) == multiSourcePixels,
                "multiple-row copying changed its source");
        // Upstream receives one provider per row: each provider is its own copy/history operation.
        require(window.sendCommand({{"action", "undo"}})
                && state(second).value("layers").toArray().size() == multiBefore.value("layers").toArray().size() + multiLayers.size() - 1,
                "multiple-row copy did not retain upstream per-provider Undo");
        for (int i = 1; i < multiLayers.size(); ++i)
            require(window.sendCommand({{"action", "undo"}}), "multiple-row remaining Undo failed");
        require(state(second).value("layers") == multiBefore.value("layers")
                && pixels(second) == multiBeforePixels, "multiple-row Undo did not restore the destination");
        clickTab(0);
        for (int i = 0; i < multiLayers.size(); ++i)
            require(window.sendCommand({{"action", "selectLayer"}, {"layerID", multiLayers.at(i).toObject().value("id")}, {"enabled", i > 0}}),
                    "folder fixture selection failed");
        require(window.sendCommand({{"action", "groupSelectedLayers"}}), "folder drag fixture could not group its rows");
        const auto folderSource = window.sessionState();
        const auto folderLayers = folderSource.value("layers").toArray();
        require(folderLayers.size() == multiLayers.size() + 1 && folderLayers.first().toObject().value("isGroup").toBool(), "folder drag fixture missing group");
        const auto folderPixels = pixels(first);
        const auto folderTarget = state(second);
        const auto folderTargetPixels = pixels(second);
        dragRows(0, tabs->mapToGlobal(tabs->tabRect(multiTargetIndex).center()));
        const auto folderAfter = state(second).value("layers").toArray();
        const int base = folderTarget.value("layers").toArray().size();
        require(window.sessionHandle() == second && folderAfter.size() == base + folderLayers.size(), "native folder drag lost its descendants");
        const auto copiedGroup = folderAfter.at(base).toObject();
        require(copiedGroup.value("isGroup").toBool() && copiedGroup.value("id") != folderLayers.first().toObject().value("id"),
                "folder copy reused its group identity");
        for (int i = 0; i < multiLayers.size(); ++i) {
            const auto child = folderAfter.at(base + i + 1).toObject();
            require(child.value("parentID") == copiedGroup.value("id") && child.value("name") == folderLayers.at(i + 1).toObject().value("name")
                    && child.value("id") != folderLayers.at(i + 1).toObject().value("id"), "folder copy lost hierarchy, names or fresh IDs");
        }
        require(state(first).value("layers") == folderSource.value("layers")
                && state(first).value("undoName") == folderSource.value("undoName") && pixels(first) == folderPixels,
                "folder copying changed its source");
        const auto folderCopyPixels = pixels(second);
        require(window.sendCommand({{"action", "undo"}}) && state(second).value("layers") == folderTarget.value("layers")
                && pixels(second) == folderTargetPixels, "folder copy did not undo as one provider");
        require(window.sendCommand({{"action", "redo"}}) && pixels(second) == folderCopyPixels, "folder copy redo changed pixels");
        {
            SessionWindow other;
            other.resize(1200, 900); other.move(0, 450); other.show();
            other.createNewDocument(33, 27);
            QApplication::processEvents();
            const uint64_t otherHandle = other.sessionHandle();
            auto *otherTabs = other.findChild<QTabBar *>("header.documentTabs");
            require(otherTabs && otherHandle != first && otherHandle != second, "cross-window destination missing");
            const QPoint destination = otherTabs->mapToGlobal(otherTabs->tabRect(otherTabs->currentIndex()).center());
            auto *underDestination = QApplication::widgetAt(destination);
            require(underDestination && underDestination->window() == &other, "cross-window destination is occluded");
            clickTab(0);
            require(window.sessionHandle() == first, "cross-window source selection failed");
            const auto sourceBefore = state(first);
            const auto sourcePixels = pixels(first);
            const auto otherBefore = state(otherHandle);
            const auto otherPixels = pixels(otherHandle);
            dragRows(0, destination);
            const auto otherAfter = state(otherHandle).value("layers").toArray();
            const int otherBase = otherBefore.value("layers").toArray().size();
            require(other.sessionHandle() == otherHandle && otherAfter.size() == otherBase + folderLayers.size(),
                    "native folder drag did not reach the other window");
            const auto otherGroup = otherAfter.at(otherBase).toObject();
            require(otherGroup.value("isGroup").toBool() && otherGroup.value("id") != folderLayers.first().toObject().value("id"),
                    "cross-window folder identity was reused");
            for (int i = 1; i < folderLayers.size(); ++i) {
                const auto child = otherAfter.at(otherBase + i).toObject();
                require(child.value("parentID") == otherGroup.value("id")
                        && child.value("name") == folderLayers.at(i).toObject().value("name")
                        && child.value("id") != folderLayers.at(i).toObject().value("id"),
                        "cross-window folder hierarchy or identity changed");
            }
            require(state(first).value("layers") == sourceBefore.value("layers")
                    && state(first).value("undoName") == sourceBefore.value("undoName") && pixels(first) == sourcePixels,
                    "cross-window drag changed source pixels or history");
            const auto otherCopyPixels = pixels(otherHandle);
            require(other.sendCommand({{"action", "undo"}}) && state(otherHandle).value("layers") == otherBefore.value("layers")
                    && pixels(otherHandle) == otherPixels, "cross-window Undo did not restore its destination");
            require(other.sendCommand({{"action", "redo"}}) && pixels(otherHandle) == otherCopyPixels,
                    "cross-window Redo changed copied pixels");
            const auto sourceBeforeActivation = state(first);
            const auto otherBeforeActivation = state(otherHandle);
            QApplication::setActiveWindow(&other);
            QApplication::setActiveWindow(&window);
            QApplication::processEvents();
            addViaVisibleMenu();
            require(state(first).value("layers").toArray().size() == sourceBeforeActivation.value("layers").toArray().size() + 1,
                    "reactivated window menu edited another workspace project");
            require(state(otherHandle).value("layers") == otherBeforeActivation.value("layers")
                    && state(otherHandle).value("undoName") == otherBeforeActivation.value("undoName")
                    && pixels(otherHandle) == otherCopyPixels, "reactivated menu changed the inactive window");
            require(window.sendCommand({{"action", "undo"}}) && state(first).value("layers") == sourceBeforeActivation.value("layers")
                    && pixels(first) == sourcePixels, "reactivated source menu did not have independent Undo");
            QApplication::setActiveWindow(&other);
            QApplication::processEvents();
            addViaVisibleMenu(&other);
            require(state(otherHandle).value("layers").toArray().size() == otherBeforeActivation.value("layers").toArray().size() + 1
                    && state(first).value("layers") == sourceBeforeActivation.value("layers") && pixels(first) == sourcePixels,
                    "second window activation did not restore its menu context");
            require(other.sendCommand({{"action", "undo"}}) && state(otherHandle).value("layers") == otherBeforeActivation.value("layers")
                    && pixels(otherHandle) == otherCopyPixels, "reactivated destination menu did not have independent Undo");
            QAction *staleMenuAction = addViaVisibleMenu(&other, false);
            QApplication::setActiveWindow(&window);
            require(window.sendCommand({{"action", "selectLayer"}, {"layerID", multiLayers.first().toObject().value("id")}})
                    && window.sendCommand({{"action", "selectTool"}, {"kind", "brush"}}), "busy activation fixture failed");
            auto *sourceCanvas = window.findChild<QWidget *>("editorCanvas");
            require(sourceCanvas, "busy activation canvas missing");
            const QPointF strokePoint = sourceCanvas->rect().center();
            mouse(sourceCanvas, QEvent::MouseButtonPress, strokePoint, Qt::LeftButton);
            require(!state(first).value("canSwitch").toBool(), "busy activation fixture did not begin a stroke");
            const auto busySource = state(first), busyDestination = state(otherHandle);
            const auto busySourcePixels = pixels(first), busyDestinationPixels = pixels(otherHandle);
            QApplication::setActiveWindow(&other);
            require(QMetaObject::invokeMethod(staleMenuAction, "triggered", Qt::DirectConnection, Q_ARG(bool, false)),
                    "stale menu dispatch could not be exercised");
            require(state(first).value("layers") == busySource.value("layers")
                    && state(first).value("undoName") == busySource.value("undoName") && pixels(first) == busySourcePixels
                    && state(otherHandle).value("layers") == busyDestination.value("layers")
                    && state(otherHandle).value("undoName") == busyDestination.value("undoName")
                    && pixels(otherHandle) == busyDestinationPixels, "refused activation let a stale menu edit a project");
            mouse(sourceCanvas, QEvent::MouseButtonRelease, strokePoint, Qt::NoButton);
            require(state(first).value("canSwitch").toBool(), "busy activation did not recover after release");
            const auto sourceAfterStroke = state(first);
            const auto sourceAfterStrokePixels = pixels(first);
            addViaVisibleMenu(&other);
            require(state(otherHandle).value("layers").toArray().size() == busyDestination.value("layers").toArray().size() + 1
                    && state(first).value("layers") == sourceAfterStroke.value("layers")
                    && state(first).value("undoName") == sourceAfterStroke.value("undoName")
                    && pixels(first) == sourceAfterStrokePixels, "menu did not recover its window after stroke release");
            require(other.sendCommand({{"action", "undo"}}) && state(otherHandle).value("layers") == busyDestination.value("layers")
                    && pixels(otherHandle) == busyDestinationPixels, "recovered window menu Undo changed its destination");
        }
        window.resize(800, 900);
        QApplication::setActiveWindow(&window);
        clickTab(tabs->count() - 1);
        QApplication::processEvents();
        require(!tabs->isTabVisible(0), "overflow fixture did not hide the oldest project");
        const auto overflowSource = state(first);
        const auto overflowSourcePixels = pixels(first);
        clickTab(0);
        require(window.sessionHandle() == first && tabs->isTabVisible(0), "overflow selection lost its project identity");
        addViaVisibleMenu();
        require(state(first).value("layers").toArray().size() == overflowSource.value("layers").toArray().size() + 1,
                "overflow-selected menu edited another project");
        require(window.sendCommand({{"action", "undo"}}) && state(first).value("layers") == overflowSource.value("layers")
                && pixels(first) == overflowSourcePixels, "overflow-selected menu Undo changed pixels");
        QVector<uint64_t> overflowHandles;
        QVector<QJsonObject> overflowStates;
        QVector<QByteArray> overflowPixels;
        QStringList overflowTitles;
        for (int i = 0; i < tabs->count(); ++i) {
            clickTab(i);
            const uint64_t handle = window.sessionHandle();
            overflowHandles.append(handle); overflowStates.append(state(handle)); overflowPixels.append(pixels(handle));
            overflowTitles.append(tabs->tabText(i));
        }
        clickTab(0);
        tabs->moveTab(tabs->count() - 1, 0);
        QApplication::processEvents();
        require(window.sessionHandle() == first && tabs->currentIndex() == 1, "overflow reorder lost the selected project");
        auto reorderedHandles = overflowHandles;
        reorderedHandles.prepend(reorderedHandles.takeLast());
        overflowTitles.prepend(overflowTitles.takeLast());
        for (int i = 0; i < tabs->count(); ++i)
            require(tabs->tabText(i) == overflowTitles.at(i), "overflow reorder changed the other projects' relative order");
        int hiddenProject = -1;
        for (int i = 0; i < tabs->count(); ++i)
            if (!tabs->isTabVisible(i)) { hiddenProject = i; break; }
        require(hiddenProject >= 0, "overflow reorder fixture has no hidden project");
        clickTab(hiddenProject);
        require(tabs->isTabVisible(hiddenProject) && tabs->currentIndex() == hiddenProject,
                "reordered overflow menu did not select its displayed project");
        for (int i = 0; i < tabs->count(); ++i) {
            clickTab(i);
            const uint64_t handle = reorderedHandles.at(i);
            require(window.sessionHandle() == handle, "reordered overflow entry lost its project identity");
            const int original = overflowHandles.indexOf(handle);
            const auto after = state(handle), before = overflowStates.at(original);
            require(after.value("layers") == before.value("layers") && after.value("undoName") == before.value("undoName")
                    && after.value("redoName") == before.value("redoName") && after.value("canUndo") == before.value("canUndo")
                    && after.value("canRedo") == before.value("canRedo") && after.value("modified") == before.value("modified")
                    && pixels(handle) == overflowPixels.at(original), "overflow reorder changed a project's pixels or history");
        }
        require(state(first).value("layers") == overflowSource.value("layers") && pixels(first) == overflowSourcePixels,
                "overflow reorder changed source pixels");
        clickTab(1);
        require(window.sessionHandle() == first && tabs->isTabVisible(tabs->count() - 1), "overflow pointer fixture lacks its visible target");
        dragTab(1, tabs->count() - 1);
        reorderedHandles.append(reorderedHandles.takeAt(1));
        require(window.sessionHandle() == first && tabs->currentIndex() == tabs->count() - 1,
                "pointer reorder across hidden projects lost its selected document");
        for (int i = 0; i < tabs->count(); ++i) {
            clickTab(i);
            const auto handle = reorderedHandles.at(i);
            const int original = overflowHandles.indexOf(handle);
            const auto after = state(handle), before = overflowStates.at(original);
            require(window.sessionHandle() == handle && after.value("layers") == before.value("layers")
                    && after.value("undoName") == before.value("undoName") && after.value("redoName") == before.value("redoName")
                    && after.value("canUndo") == before.value("canUndo") && after.value("canRedo") == before.value("canRedo")
                    && after.value("modified") == before.value("modified") && pixels(handle) == overflowPixels.at(original),
                    "overflow pointer reorder changed project order, identity, pixels or history");
        }
        auto *overflowButton = window.findChild<QToolButton *>("header.tabOverflow");
        require(overflowButton && overflowButton->menu() && !overflowButton->menu()->actions().isEmpty(), "busy overflow menu missing");
        require(window.sendCommand({{"action", "selectLayer"}, {"layerID", multiLayers.first().toObject().value("id")}})
                && window.sendCommand({{"action", "selectTool"}, {"kind", "brush"}}), "busy overflow stroke setup failed");
        auto *overflowCanvas = window.findChild<QWidget *>("editorCanvas");
        require(overflowCanvas, "busy overflow canvas missing");
        const QPointF overflowStroke = overflowCanvas->rect().center();
        mouse(overflowCanvas, QEvent::MouseButtonPress, overflowStroke, Qt::LeftButton);
        require(!state(first).value("canSwitch").toBool(), "busy overflow fixture did not begin a stroke");
        const auto busyOverflow = state(first);
        const auto busyOverflowPixels = pixels(first);
        require(overflowButton->menu() && !overflowButton->menu()->actions().isEmpty(), "busy overflow entries disappeared");
        QAction *hiddenAction = overflowButton->menu()->actions().first();
        hiddenAction->trigger(); QApplication::processEvents();
        require(window.sessionHandle() == first && tabs->currentIndex() == tabs->count() - 1
                && state(first).value("layers") == busyOverflow.value("layers")
                && state(first).value("undoName") == busyOverflow.value("undoName") && pixels(first) == busyOverflowPixels,
                "overflow menu selection escaped active-stroke refusal");
        for (int i = 0; i < overflowHandles.size(); ++i) {
            const auto handle = overflowHandles.at(i);
            if (handle == first) continue;
            const auto after = state(handle), before = overflowStates.at(i);
            require(after.value("layers") == before.value("layers") && after.value("undoName") == before.value("undoName")
                    && after.value("redoName") == before.value("redoName") && after.value("canUndo") == before.value("canUndo")
                    && after.value("canRedo") == before.value("canRedo") && after.value("modified") == before.value("modified")
                    && pixels(handle) == overflowPixels.at(i), "busy overflow selection changed an inactive project");
        }
        mouse(overflowCanvas, QEvent::MouseButtonRelease, overflowStroke, Qt::NoButton);
        clickTab(0);
        require(window.sessionHandle() == reorderedHandles.first(), "overflow menu did not recover after stroke release");
        window.createNewDocument(32, 24);
        require(window.sendCommand({{"action", "renameLayer"}, {"name", "Close target work"}}), "close target edit failed");
        const auto closeTarget = window.sessionHandle();
        const int closeTargetIndex = tabs->currentIndex();
        const auto closeTargetState = state(closeTarget);
        const auto closeTargetPixels = pixels(closeTarget);
        window.createNewDocument(32, 24);
        require(window.sendCommand({{"action", "renameLayer"}, {"name", "Close stroke source"}}), "close source edit failed");
        const auto closeSource = window.sessionHandle();
        const int closeCount = tabs->count();
        int closePrompts = 0;
        QString closeAnswer = "Don’t Save";
        QTimer answerClose;
        answerClose.setInterval(10);
        QObject::connect(&answerClose, &QTimer::timeout, [&] {
            for (auto *widget : QApplication::topLevelWidgets()) {
                auto *box = qobject_cast<QMessageBox *>(widget);
                if (!box || !box->isVisible() || !box->text().startsWith("Save changes to")) continue;
                for (auto *button : box->buttons()) if (button->text() == closeAnswer) {
                    ++closePrompts; button->click(); return;
                }
            }
        });
        answerClose.start();
        require(window.sendCommand({{"action", "brushBegin"}, {"x", 5}, {"y", 5},
                    {"parameters", QJsonObject{{"diameter", 3}, {"hardness", 1}, {"opacity", 1},
                                               {"red", 1}, {"green", 0}, {"blue", 0}, {"mask", 0}}}}), "close busy stroke failed");
        require(QMetaObject::invokeMethod(tabs, "tabCloseRequested", Qt::DirectConnection, Q_ARG(int, closeTargetIndex)), "close tab signal failed");
        require(closePrompts == 0 && tabs->count() == closeCount && window.sessionHandle() == closeSource,
                "native close bypassed upstream busy refusal");
        require(state(closeTarget).value("layers") == closeTargetState.value("layers") && pixels(closeTarget) == closeTargetPixels,
                "busy close changed the inactive target");
        require(!window.close() && window.isVisible() && closePrompts == 0, "window closed or prompted during an active stroke");
        require(window.sendCommand({{"action", "brushEnd"}}), "close busy stroke release failed");
        closeAnswer = "Cancel";
        require(QMetaObject::invokeMethod(tabs, "tabCloseRequested", Qt::DirectConnection, Q_ARG(int, closeTargetIndex)), "cancel-close signal failed");
        require(closePrompts == 1 && tabs->count() == closeCount && state(closeTarget).value("layers") == closeTargetState.value("layers"),
                "Cancel did not preserve the close target");
        closeAnswer = "Don’t Save";
        require(QMetaObject::invokeMethod(tabs, "tabCloseRequested", Qt::DirectConnection, Q_ARG(int, closeTargetIndex)), "discard-close signal failed");
        require(closePrompts == 2 && tabs->count() == closeCount - 1 && compositor_session_state(closeTarget, nullptr, 0) <= 0,
                "discard close did not recover after stroke release");
        answerClose.stop();
        qInfo("Qt tab journey OK (existing/new projects, multiple rows, folders, two windows, overflow, source isolation and provider Undo/Redo)");
        return 0;
    } catch (const std::exception &error) {
        qCritical("Qt tab journey failed: %s", error.what()); return 1;
    }
}

// Real event-loop acceptance for worker saves: the UI must keep processing input
// and completion must target the captured document, even after a tab switch.
extern "C" int compositor_host_save_smoke(int argc, char **argv) {
    QApplication app(argc, argv);
    installJourneyUI(app);
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
        const QString source = temporary.filePath(QString::fromUtf8("Zażółć # % source.png"));
        const QString savedPath = temporary.filePath(QString::fromUtf8("Zażółć # % saved.comp"));
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
        for (const QString &input : {savedPath, source}) {
            const QString output = temporary.filePath(input == savedPath ? "cli-project.comp" : "cli-image.comp");
            auto environment = QProcessEnvironment::systemEnvironment();
            environment.insert("COMPOSITOR_GRAB_PATH", temporary.filePath("cli.png"));
            environment.insert("COMPOSITOR_GRAB_SAVE_PROJECT", output);
            QProcess process;
            process.setProcessEnvironment(environment);
            process.start(QCoreApplication::applicationFilePath(), {QUrl::fromLocalFile(input).toString(QUrl::FullyEncoded)});
            require(process.waitForStarted(5000) && process.waitForFinished(30000), "file URI launch did not finish");
            require(process.exitStatus() == QProcess::NormalExit && process.exitCode() == 0, "file URI launch failed");
            QFile copy(output + "/manifest.json");
            require(copy.open(QIODevice::ReadOnly), "file URI launch did not load/save its input");
            const auto copied = QJsonDocument::fromJson(copy.readAll()).object();
            require(copied.value("width") == manifest.value("width") && copied.value("height") == manifest.value("height"),
                    "file URI launch changed dimensions");
            if (input == savedPath) require(copied == manifest, "file URI project launch changed metadata");
            const auto copiedLayers = copied.value("layers").toArray();
            require(copiedLayers.size() == 1, "file URI launch did not preserve one-layer input");
            const auto copiedImage = QImage(output + "/images/" + copiedLayers.first().toObject().value("imageFile").toString())
                                         .convertToFormat(QImage::Format_RGBA8888);
            require(copiedImage.size() == image.size(), "file URI launch changed asset dimensions");
            for (int y = 0; y < image.height(); ++y)
                require(std::memcmp(copiedImage.constScanLine(y), image.constScanLine(y), image.width() * 4) == 0,
                        "file URI launch changed image pixels");
        }
        qInfo("Qt file URI launch OK (actual project/image subprocesses, Unicode/reserved characters, exact metadata/pixels)");
        const QString batchSource = temporary.filePath(QString::fromUtf8("Drugi # % obraz.png"));
        const QString batchProject = temporary.filePath("startup-project.comp");
        require(QDir().mkpath(batchProject + "/images")
                    && QFile::copy(savedPath + "/manifest.json", batchProject + "/manifest.json")
                    && QFile::copy(savedPath + "/images/" + layer.value("imageFile").toString(),
                                   batchProject + "/images/" + layer.value("imageFile").toString()),
                "startup project copy fixture failed");
        QImage batchImage(7, 5, QImage::Format_RGBA8888);
        batchImage.fill(QColor(40, 80, 120));
        require(batchImage.save(batchSource), "batch launch image fixture failed");
        {
            const QString output = temporary.filePath("cli-batch.comp");
            auto environment = QProcessEnvironment::systemEnvironment();
            environment.insert("COMPOSITOR_GRAB_PATH", temporary.filePath("cli-batch.png"));
            environment.insert("COMPOSITOR_GRAB_SAVE_PROJECT", output);
            QProcess process;
            process.setProcessEnvironment(environment);
            process.start(QCoreApplication::applicationFilePath(),
                          {QUrl::fromLocalFile(batchProject).toString(QUrl::FullyEncoded),
                           QUrl::fromLocalFile(source).toString(QUrl::FullyEncoded),
                           QUrl::fromLocalFile(batchSource).toString(QUrl::FullyEncoded)});
            require(process.waitForStarted(5000) && process.waitForFinished(30000), "multi-file launch did not finish");
            require(process.exitStatus() == QProcess::NormalExit && process.exitCode() == 0, "multi-file launch failed");
            QFile copy(output + "/manifest.json");
            require(copy.open(QIODevice::ReadOnly), "multi-file launch did not save its last input");
            const auto copied = QJsonDocument::fromJson(copy.readAll()).object();
            require(copied.value("width").toInt() == 7 && copied.value("height").toInt() == 5,
                    "multi-file launch discarded later project/image arguments");
            const auto records = copied.value("layers").toArray();
            require(records.size() == 1, "multi-file launch merged separate image projects");
            const auto copiedImage = QImage(output + "/images/" + records.first().toObject().value("imageFile").toString())
                                         .convertToFormat(QImage::Format_RGBA8888);
            require(copiedImage.size() == batchImage.size(), "multi-file launch changed the last image dimensions");
            for (int y = 0; y < batchImage.height(); ++y)
                require(std::memcmp(copiedImage.constScanLine(y), batchImage.constScanLine(y), batchImage.width() * 4) == 0,
                        "multi-file launch changed the last image pixels");
        }
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
            const auto closingHandle = closing.sessionHandle();
            done = false;
            require(closing.startProjectSave(temporary.filePath("closing.comp"), false,
                                            [&](bool ok) { succeeded = ok; done = true; }), "close save did not start");
            closing.close();
            require(closing.isVisible(), "window closed before pending save completed");
            waitFor([&] { return done && !closing.isVisible(); });
            require(succeeded, "close save failed");
            require(compositor_session_state(closingHandle, nullptr, 0) <= 0,
                    "closed window retained its session handle after save completion");
            auto *closedAutosave = closing.findChild<QTimer *>("autosaveTimer");
            require(closedAutosave && !closedAutosave->isActive(), "closed window retained its autosave timer");
        }
        {
            auto files = std::make_shared<FakeFiles>();
            auto storage = std::make_shared<FakeStorage>();
            storage->root = temporary.filePath("menu-data");
            auto notifier = std::make_shared<FakeNotifier>();
            PlatformServices services;
            services.files = files; services.storage = storage;
            services.clipboard = std::make_shared<FakeClipboard>();
            services.notifier = notifier;
            SessionWindow menuWindow(nullptr, services);
            menuWindow.initDemoDocument();
            require(menuWindow.sendCommand({{"action", "renameLayer"}, {"name", "Before save dialog"}}), "menu fixture edit failed");
            const QString savedLayer = menuWindow.sessionState().value("activeLayerID").toString();
            {
                QTemporaryDir rejected;
                require(rejected.isValid(), "invalid save-path fixture unavailable");
                const auto before = menuWindow.sessionState();
                auto *saveAs = menuWindow.findChild<QAction *>("file.saveAs");
                require(saveAs, "Save As menu missing");
                const auto uri = QUrl::fromLocalFile(rejected.filePath("invalid.comp")).toString(QUrl::FullyEncoded);
                for (const QString &invalid : {QString("file:"), QString("file:relative.comp"), uri + "/%GG", uri + "?query", uri + "#fragment",
                                              QString("file://remote.example/project.comp")}) {
                    files->projectSavePath = invalid;
                    const auto previousDirectory = QDir::currentPath();
                    require(QDir::setCurrent(rejected.path()), "could not enter isolated save-path fixture");
                    saveAs->trigger();
                    require(QDir::setCurrent(previousDirectory), "could not restore working directory");
                    require(!notifier->warnings.isEmpty() && QDir(rejected.path()).entryList(QDir::NoDotAndDotDot | QDir::AllEntries | QDir::Hidden).isEmpty(),
                            "invalid file URI was saved into the working directory");
                    notifier->warnings.clear();
                }
                const auto after = menuWindow.sessionState();
                for (const char *field : {"width", "height", "layers", "activeLayerID", "modified", "canUndo", "canRedo", "undoName", "redoName"})
                    require(after.value(field) == before.value(field), "invalid save URI changed document/history");
                notifier->warnings.clear();
            }
            const auto menuSavePath = temporary.filePath(QString::fromUtf8("Zażółć # % menu-save.comp"));
            files->projectSavePath = QUrl::fromLocalFile(menuSavePath).toString(QUrl::FullyEncoded);
            files->beforeSave = [&] {
                // A save dialog pumps events; the source tab must remain fixed.
                menuWindow.newCanvasTab();
                require(menuWindow.sendCommand({{"action", "new"}, {"width", 16}, {"height", 16}, {"emptyLayer", true}}), "menu second tab failed");
                require(menuWindow.sendCommand({{"action", "renameLayer"}, {"name", "During save dialog"}}), "menu second tab edit failed");
            };
            auto *saveAction = menuWindow.findChild<QAction *>("file.save");
            require(saveAction, "save menu missing"); saveAction->trigger();
            waitFor([&] { return QFileInfo::exists(menuSavePath + "/manifest.json"); });
            QFile file(menuSavePath + "/manifest.json");
            require(file.open(QIODevice::ReadOnly), "menu save missing");
            const auto records = QJsonDocument::fromJson(file.readAll()).object().value("layers").toArray();
            bool found = false;
            for (const auto &record : records) if (record.toObject().value("id").toString() == savedLayer)
                found = record.toObject().value("name").toString() == "Before save dialog";
            require(found, "save dialog changed the source document");
            require(menuWindow.sessionState().value("modified").toBool(), "save menu marked current tab saved");
        }
        {
            SessionWindow startup;
            startup.createNewDocument(32, 24);
            startup.show();
            QApplication::processEvents();
            auto *startupTabs = startup.findChild<QTabBar *>("header.documentTabs");
            require(startupTabs, "startup batch tabs missing");
            const int first = startupTabs->count();
            startup.openStartupFiles({"file:", temporary.filePath("missing.png"),
                                      QUrl::fromLocalFile(batchProject).toString(QUrl::FullyEncoded),
                                      QUrl::fromLocalFile(source).toString(QUrl::FullyEncoded),
                                      QUrl::fromLocalFile(batchSource).toString(QUrl::FullyEncoded)});
            require(startupTabs->count() == first + 3 && startupTabs->currentIndex() == first + 2,
                    "startup batch did not create one ordered project per input");
            const auto checkImage = [&](const QImage &expected) {
                const auto state = startup.sessionState();
                require(state.value("width").toInt() == expected.width() && state.value("height").toInt() == expected.height()
                            && state.value("layers").toArray().size() == 1, "startup batch changed image/project dimensions or layers");
                QByteArray pixels(expected.width() * expected.height() * 4, Qt::Uninitialized);
                require(compositor_session_render(startup.sessionHandle(), reinterpret_cast<uint8_t *>(pixels.data()), pixels.size()) == pixels.size(),
                        "startup batch pixels unavailable");
                for (int y = 0; y < expected.height(); ++y)
                    require(std::memcmp(pixels.constData() + y * expected.width() * 4, expected.constScanLine(y), expected.width() * 4) == 0,
                            "startup batch changed pixels");
            };
            checkImage(batchImage);
            const auto last = startup.sessionState();
            startupTabs->setCurrentIndex(first);
            checkImage(image);
            const auto project = startup.sessionState();
            require(!project.value("modified").toBool() && !project.value("canUndo").toBool()
                        && project.value("layers").toArray().first().toObject().value("name").toString() == originalName,
                    "startup batch changed the opened project/history");
            startupTabs->setCurrentIndex(first + 1);
            checkImage(image);
            const auto photo = startup.sessionState();
            require(startup.sendCommand({{"action", "renameLayer"}, {"name", "First input edited"}}), "startup photo edit failed");
            startupTabs->setCurrentIndex(first + 2);
            checkImage(batchImage);
            const auto unchanged = [&](const QJsonObject &expected) {
                const auto current = startup.sessionState();
                for (const char *field : {"layers", "activeLayerID", "modified", "canUndo", "canRedo", "undoName", "redoName"})
                    require(current.value(field) == expected.value(field), "startup input edit changed another project/history");
            };
            unchanged(last);
            startupTabs->setCurrentIndex(first);
            unchanged(project);
            startupTabs->setCurrentIndex(first + 1);
            require(startup.sendCommand({{"action", "undo"}}), "startup photo Undo failed");
            require(startup.sessionState().value("layers") == photo.value("layers"), "startup photo Undo changed another input");
            checkImage(image);
            startupTabs->setCurrentIndex(first);
            require(startup.sendCommand({{"action", "renameLayer"}, {"name", "Unsaved reopened project"}}), "reopen fixture edit failed");
            const auto openedHandle = startup.sessionHandle();
            const auto unsavedProject = startup.sessionState();
            startupTabs->setCurrentIndex(first + 2);
            const int openedCount = startupTabs->count();
            require(startup.loadProject(batchProject), "reopening existing project failed");
            require(startupTabs->count() == openedCount && startup.sessionHandle() == openedHandle
                        && startupTabs->currentIndex() == first, "reopening project created a duplicate tab");
            unchanged(unsavedProject);
            checkImage(image);
            const QString projectAlias = temporary.filePath(QString::fromUtf8("Alias # % projektu.comp"));
            require(QFile::link(batchProject, projectAlias), "reopen alias fixture failed");
            startupTabs->setCurrentIndex(first + 2);
            require(startup.loadProject(QUrl::fromLocalFile(projectAlias).toString(QUrl::FullyEncoded)), "reopening project alias failed");
            require(startupTabs->count() == openedCount && startup.sessionHandle() == openedHandle, "project alias created a duplicate tab");
            unchanged(unsavedProject);
            startupTabs->setCurrentIndex(first + 2);
            const auto strokeHandle = startup.sessionHandle();
            require(startup.sendCommand({{"action", "brushBegin"}, {"x", 2}, {"y", 2},
                        {"parameters", QJsonObject{{"diameter", 3}, {"hardness", 1}, {"opacity", 1},
                                                   {"red", 1}, {"green", 0}, {"blue", 0}, {"mask", 0}}}}), "reopen busy stroke failed");
            require(!startup.loadProject(batchProject) && startup.sessionHandle() == strokeHandle && startupTabs->count() == openedCount,
                    "reopening project bypassed the active-stroke switch gate");
            require(startup.sendCommand({{"action", "brushEnd"}}), "reopen busy stroke release failed");
            require(startup.loadProject(batchProject) && startup.sessionHandle() == openedHandle, "reopen did not recover after release");
            unchanged(unsavedProject);
            {
                SessionWindow requester;
                requester.createNewDocument(32, 24);
                requester.show(); requester.activateWindow();
                QApplication::processEvents();
                auto *requesterTabs = requester.findChild<QTabBar *>("header.documentTabs");
                require(requesterTabs, "cross-window reopen tabs missing");
                const auto requesterBefore = requester.sessionState();
                const auto requesterHandle = requester.sessionHandle();
                const int requesterCount = requesterTabs->count();
                require(requester.loadProject(batchProject), "cross-window existing project open failed");
                QApplication::processEvents();
                require(QApplication::activeWindow() == &startup && startup.sessionHandle() == openedHandle
                            && startupTabs->count() == openedCount && requesterTabs->count() == requesterCount
                            && requester.sessionHandle() == requesterHandle,
                        "cross-window reopen duplicated or failed to focus the existing project");
                unchanged(unsavedProject);
                checkImage(image);
                const auto checkRequester = [&] {
                    const auto current = requester.sessionState();
                    for (const char *field : {"width", "height", "layers", "activeLayerID", "modified", "canUndo", "canRedo", "undoName", "redoName"})
                        require(current.value(field) == requesterBefore.value(field), "cross-window reopen changed the requesting project/history");
                };
                checkRequester();
                require(startup.sendCommand({{"action", "brushBegin"}, {"x", 20}, {"y", 20},
                            {"parameters", QJsonObject{{"diameter", 3}, {"hardness", 1}, {"opacity", 1},
                                                       {"red", 1}, {"green", 0}, {"blue", 0}, {"mask", 0}}}}), "current-project reopen stroke failed");
                require(!startup.loadProject(batchProject) && !requester.loadProject(batchProject)
                            && startupTabs->count() == openedCount && requesterTabs->count() == requesterCount,
                        "same-project or cross-window reopen bypassed busy refusal");
                require(startup.sendCommand({{"action", "brushEnd"}}) && startup.sendCommand({{"action", "undo"}}),
                        "current-project reopen stroke recovery failed");
                const auto recovered = startup.sessionState();
                require(requester.loadProject(projectAlias), "cross-window reopen did not recover after release");
                unchanged(recovered);
                checkImage(image);
                checkRequester();
                require(startup.sendCommand({{"action", "undo"}}), "reopened unsaved project Undo failed");
                require(startup.sessionState().value("layers").toArray().first().toObject().value("name").toString() == originalName,
                        "reopening project lost its original Undo history");
                checkImage(image);
                checkRequester();
            }
            qInfo("Qt existing project reopen OK (same/other window, file URI/symlink alias, exact state/history, busy refusal/recovery and Undo)");
            qInfo("Qt multi-file startup OK (actual subprocess, project/image order, skipped invalid paths, isolated pixels/history and Undo)");
        }
        qInfo("Qt async save journey OK (%d UI ticks; captured pixels/revision, edits and tab switch, failure, autosave, pending close)", ticks);
        return 0;
    } catch (const std::exception &e) {
        qCritical("Qt async save journey failed: %s", e.what()); return 1;
    }
}

extern "C" int compositor_host_text_smoke(int argc, char **argv, int (*probe)(void)) {
    QApplication app(argc, argv);
    installJourneyUI(app);
    return probe ? probe() : 1;
}

/// Focused Move / Free Transform journey: idle controls, drag history, explicit Apply/Cancel, and draft saves.
extern "C" int compositor_host_transform_smoke(int argc, char **argv) {
    QApplication app(argc, argv);
    installJourneyUI(app);
    compositor_host_install_application_state_bridge();
    try {
        const auto require = [](bool ok, const char *message) {
            if (!ok) throw std::runtime_error(message);
        };
        SessionWindow window;
        window.resize(1200, 800);
        window.show();
        QApplication::processEvents();
        {
            auto *canvas = window.findChild<QWidget *>("editorCanvas");
            require(canvas, "navigation canvas missing");
            const auto viewport = [&] {
                std::array<double, 6> result{};
                require(compositor_session_viewport(window.sessionHandle(), result.data()) == 0, "navigation viewport unavailable");
                return result;
            };
            const QPointF anchor(canvas->width() * 0.35, canvas->height() * 0.4);
            const auto wheel = [&](QPoint pixels, QPoint angle, Qt::KeyboardModifiers modifiers) {
                QWheelEvent event(anchor, canvas->mapToGlobal(anchor.toPoint()), pixels, angle,
                                  Qt::NoButton, modifiers, Qt::ScrollUpdate, false);
                QApplication::sendEvent(canvas, &event);
                require(event.isAccepted(), "canvas did not accept wheel event");
            };
            const auto gesture = [&](Qt::NativeGestureType type, double value) {
                QNativeGestureEvent event(type, QPointingDevice::primaryPointingDevice(), 2,
                                          anchor, canvas->mapTo(&window, anchor.toPoint()),
                                          canvas->mapToGlobal(anchor.toPoint()), value, {});
                QApplication::sendEvent(canvas, &event);
            };
            window.setTool(SessionWindow::Tool::Brush);
            QApplication::processEvents();
            require(window.sendCommand({{"action", "brushBegin"}, {"x", 20}, {"y", 20},
                        {"parameters", QJsonObject{{"diameter", 3}, {"hardness", 1}, {"opacity", 1},
                                                   {"red", 1}, {"green", 0}, {"blue", 0}, {"mask", 0}}}}), "navigation brush stroke did not start");
            const auto busy = viewport();
            wheel(QPoint(11, 17), {}, Qt::NoModifier);
            require(viewport() == busy, "wheel pan interrupted an active upstream stroke");
            wheel(QPoint(0, 4), {}, Qt::ControlModifier);
            require(viewport() == busy, "wheel zoom interrupted an active upstream stroke");
            gesture(Qt::ZoomNativeGesture, 0.25);
            require(viewport() == busy, "pinch zoom interrupted an active upstream stroke");
            require(window.sendCommand({{"action", "brushEnd"}}), "navigation brush stroke did not finish");
            const auto ready = viewport();
            const auto history = window.sessionState();
            wheel(QPoint(11, 17), {}, Qt::NoModifier);
            const auto panned = viewport();
            require(std::abs(panned[1] - ready[1] - 11) < 1e-6 && std::abs(panned[2] - ready[2] - 17) < 1e-6,
                    "precise wheel pan did not recover after stroke release");
            wheel({}, QPoint(0, 120), Qt::NoModifier);
            const auto stepped = viewport();
            require(std::abs(stepped[2] - panned[2] - 36) < 1e-6, "wheel notch pan changed Linux line scaling");
            wheel(QPoint(0, 4), {}, Qt::ControlModifier);
            const auto zoomed = viewport();
            const double ratio = std::exp(0.06);
            require(std::abs(zoomed[0] / stepped[0] - ratio) < 1e-6, "precise wheel zoom changed Linux gain");
            require(std::abs(zoomed[1] - (anchor.x() - canvas->width() / 2.0 - (anchor.x() - canvas->width() / 2.0 - stepped[1]) * ratio)) < 1e-6
                        && std::abs(zoomed[2] - (anchor.y() - canvas->height() / 2.0 - (anchor.y() - canvas->height() / 2.0 - stepped[2]) * ratio)) < 1e-6,
                    "wheel zoom did not preserve the pointer anchor");
            const auto pixels = [&] {
                const auto size = compositor_session_render(window.sessionHandle(), nullptr, 0);
                require(size > 0, "navigation pixels unavailable");
                QByteArray result(qsizetype(size), Qt::Uninitialized);
                require(compositor_session_render(window.sessionHandle(), reinterpret_cast<uint8_t *>(result.data()), result.size()) == size,
                        "navigation pixel capture failed");
                return result;
            };
            const auto beforePinch = pixels();
            for (double magnification : {0.25, -0.2}) {
                const auto before = viewport();
                gesture(Qt::ZoomNativeGesture, magnification);
                const auto after = viewport();
                const double factor = 1 + magnification;
                require(std::abs(after[0] / before[0] - factor) < 1e-6,
                        "pinch zoom did not use upstream magnification");
                require(std::abs(after[1] - (anchor.x() - canvas->width() / 2.0 - (anchor.x() - canvas->width() / 2.0 - before[1]) * factor)) < 1e-6
                            && std::abs(after[2] - (anchor.y() - canvas->height() / 2.0 - (anchor.y() - canvas->height() / 2.0 - before[2]) * factor)) < 1e-6,
                        "pinch zoom did not preserve the pointer anchor");
            }
            require(pixels() == beforePinch, "pinch zoom changed document pixels");
            const auto beforeRotation = viewport();
            gesture(Qt::RotateNativeGesture, 30);
            require(viewport() == beforeRotation, "unsupported rotation changed the viewport");
            const auto afterNavigation = window.sessionState();
            for (const char *field : {"layers", "activeLayerID", "modified", "canUndo", "canRedo", "undoName", "redoName"})
                require(afterNavigation.value(field) == history.value(field), "wheel navigation changed document/history");
            require(window.sendCommand({{"action", "undo"}}), "navigation stroke Undo failed");
            qInfo("Qt canvas wheel OK (stroke refusal/release, precise and notch pan, pointer-anchored zoom, no navigation Undo)");
            qInfo("Qt canvas pinch OK (native zoom in/out, pointer anchor, stroke refusal/recovery, exact pixels/history, rotation ignored)");
        }
        window.setTool(SessionWindow::Tool::Move);
        QApplication::processEvents();

        {
            const auto option = [&](const QString &text, const QString &help) -> QAbstractButton * {
                for (QWidget *widget : window.findChildren<QWidget *>()) {
                    if (!widget->isVisible()) continue;
                    auto *button = qobject_cast<QAbstractButton *>(widget);
                    if (button && button->text() == text && !text.isEmpty()) return button;
                    if (!help.isEmpty() && widget->toolTip().startsWith(help)) {
                        if (button) return button;
                        if (auto *child = widget->findChild<QAbstractButton *>()) return child;
                    }
                }
                throw std::runtime_error("visible transform option missing");
            };
            const auto linked = [&] { return option({}, "Lock aspect ratio.")->isChecked(); };
            const auto automatic = [&] { return option("Auto Select", {})->isChecked(); };
            const auto modifiers = [&](QEvent::Type type, int key, Qt::KeyboardModifiers flags) {
                // Qt adjusts modifiers() for the modifier key itself. Supply the raw mask
                // that produces the post-accessor flags this regression needs to deliver.
                const auto raw = flags ^ (key == Qt::Key_Shift ? Qt::ShiftModifier : Qt::ControlModifier);
                QKeyEvent event(type, key, raw);
                require(event.modifiers() == flags, "modifier-event fixture has incorrect flags");
                QApplication::sendEvent(&window, &event);
                QApplication::processEvents();
            };
            const bool baseLink = linked(), baseAuto = automatic();
            const auto before = window.sessionState();
            modifiers(QEvent::KeyPress, Qt::Key_Shift, Qt::ShiftModifier);
            require(linked() != baseLink, "Shift did not temporarily flip the aspect lock");
            modifiers(QEvent::KeyRelease, Qt::Key_Shift, Qt::ShiftModifier);
            require(linked() == baseLink, "released Shift left the aspect lock flipped");
            modifiers(QEvent::KeyPress, Qt::Key_Control, Qt::ControlModifier | Qt::ShiftModifier);
            require(linked() != baseLink && automatic() != baseAuto, "combined modifiers did not flip transform options");
            modifiers(QEvent::KeyRelease, Qt::Key_Shift, Qt::ControlModifier | Qt::ShiftModifier);
            require(linked() == baseLink && automatic() != baseAuto, "Shift release did not preserve held Control");
            modifiers(QEvent::KeyRelease, Qt::Key_Control, Qt::ControlModifier);
            require(automatic() == baseAuto, "Control release left Auto Select flipped");
            modifiers(QEvent::KeyPress, Qt::Key_Control, Qt::ControlModifier | Qt::ShiftModifier);
            require(linked() != baseLink && automatic() != baseAuto, "activation fixture did not hold both modifiers");
            require(QMetaObject::invokeMethod(qApp, "applicationStateChanged", Qt::DirectConnection,
                        Q_ARG(Qt::ApplicationState, Qt::ApplicationInactive)), "application inactive signal unavailable");
            QApplication::processEvents();
            require(linked() == baseLink && automatic() == baseAuto, "app deactivation left transform modifiers held");
            require(QMetaObject::invokeMethod(qApp, "applicationStateChanged", Qt::DirectConnection,
                        Q_ARG(Qt::ApplicationState, Qt::ApplicationActive)), "application active signal unavailable");
            QApplication::processEvents();
            const auto polled = QGuiApplication::queryKeyboardModifiers();
            require(linked() == (baseLink != bool(polled & Qt::ShiftModifier))
                        && automatic() == (baseAuto != bool(polled & Qt::ControlModifier)),
                    "reactivation did not follow the platform modifier state");
            require(QMetaObject::invokeMethod(qApp, "applicationStateChanged", Qt::DirectConnection,
                        Q_ARG(Qt::ApplicationState, Qt::ApplicationInactive)), "second application inactive signal unavailable");
            // Offscreen Qt updates its cached modifier state on key-down. Model release
            // and plain input elsewhere without sending key-up through SessionWindow.
            QWidget outside;
            QKeyEvent shiftReleased(QEvent::KeyRelease, Qt::Key_Shift, Qt::ShiftModifier | Qt::ControlModifier);
            QKeyEvent controlReleased(QEvent::KeyRelease, Qt::Key_Control, Qt::ControlModifier);
            QApplication::sendEvent(&outside, &shiftReleased);
            QApplication::sendEvent(&outside, &controlReleased);
            QKeyEvent plainOutsideInput(QEvent::KeyPress, Qt::Key_A, Qt::NoModifier, "a");
            QApplication::sendEvent(&outside, &plainOutsideInput);
            require(QGuiApplication::queryKeyboardModifiers() == Qt::NoModifier, "outside-release fixture did not clear platform modifiers");
            require(QMetaObject::invokeMethod(qApp, "applicationStateChanged", Qt::DirectConnection,
                        Q_ARG(Qt::ApplicationState, Qt::ApplicationActive)), "second application active signal unavailable");
            QApplication::processEvents();
            require(linked() == baseLink && automatic() == baseAuto, "reactivation restored stale transform modifiers");
            qInfo("Qt app activation modifiers OK (production signal bridge, inactive reset, platform poll on return, visible options)");
            modifiers(QEvent::KeyPress, Qt::Key_Control, Qt::ControlModifier | Qt::ShiftModifier);
            auto *trackedMenu = window.findChild<QMenu *>("appMenu.View");
            require(trackedMenu && trackedMenu->menuAction()->isVisible(), "visible View menu unavailable");
            trackedMenu->popup(window.mapToGlobal(QPoint(150, 150)));
            QApplication::processEvents();
            require(trackedMenu->isVisible(), "View menu did not enter tracking");
            QMenu *nested = nullptr;
            for (QAction *action : trackedMenu->actions())
                if (action->menu()) { nested = action->menu(); break; }
            require(nested, "View submenu unavailable");
            nested->popup(trackedMenu->mapToGlobal(QPoint(trackedMenu->width(), 20)));
            QApplication::processEvents();
            require(nested->isVisible(), "View submenu did not enter tracking");
            // Menu navigation after release updates Qt's offscreen keyboard cache,
            // while neither key-up nor this arrow key is delivered to the editor.
            QKeyEvent menuInput(QEvent::KeyPress, Qt::Key_Down, Qt::NoModifier);
            QApplication::sendEvent(nested, &menuInput);
            require(QGuiApplication::queryKeyboardModifiers() == Qt::NoModifier, "menu-release fixture did not clear platform modifiers");
            nested->hide();
            QApplication::processEvents();
            require(trackedMenu->isVisible() && linked() != baseLink && automatic() != baseAuto,
                    "closing a submenu reset options while its parent still tracked");
            trackedMenu->hide();
            QApplication::processEvents();
            QApplication::processEvents();
            require(linked() == baseLink && automatic() == baseAuto, "menu tracking ended with stale held modifiers");
            qInfo("Qt menu tracking modifiers OK (real root/submenu popups, nested-close deferral, released keys, visible options)");
            const auto after = window.sessionState();
            for (const char *field : {"layers", "activeLayerID", "modified", "canUndo", "canRedo", "undoName", "redoName", "transformAutoSelect"})
                require(after.value(field) == before.value(field), "held transform modifiers changed document/history or stored option");
            qInfo("Qt transform held modifiers OK (visible options, retained release flags, Shift/Control independence, no document/history edit)");
        }

        {
            const auto menu = [&](const QString &text) {
                std::function<QAction *(QMenu *)> find = [&](QMenu *parent) -> QAction * {
                    for (QAction *action : parent->actions()) {
                        if (action->menu()) { if (auto *found = find(action->menu())) return found; }
                        if (action->text().remove('&') == text) return action;
                    }
                    return nullptr;
                };
                QAction *result = nullptr;
                for (QAction *root : window.menuBar()->actions())
                    if (root->isVisible() && root->menu() && (result = find(root->menu()))) break;
                require(result && result->isEnabled(), "guide menu action unavailable");
                result->trigger();
                QApplication::processEvents();
                QApplication::processEvents();
            };
            auto *canvas = window.findChild<QWidget *>("editorCanvas");
            auto *horizontal = window.findChild<QWidget *>("ruler.horizontal");
            auto *vertical = window.findChild<QWidget *>("ruler.vertical");
            require(canvas && horizontal && vertical, "named native rulers missing");
            if (!window.sessionState().value("showsRulers").toBool()) menu("Rulers");
            require(horizontal->isVisible() && vertical->isVisible(), "Rulers menu did not show both native rulers");
            const auto guides = [&] { return window.sessionState().value("guides").toArray(); };
            require(guides().isEmpty(), "guide fixture is not empty");
            const auto mouse = [&](QWidget *target, QEvent::Type type, QPointF position, Qt::MouseButton button, Qt::MouseButtons buttons) {
                QMouseEvent event(type, position, target->mapToGlobal(position), button, buttons, Qt::NoModifier);
                QApplication::sendEvent(target, &event);
                QApplication::processEvents();
            };
            const auto drag = [&](QWidget *ruler, QPointF destination) {
                const QPointF start = ruler->rect().center();
                mouse(ruler, QEvent::MouseButtonPress, start, Qt::LeftButton, Qt::LeftButton);
                mouse(ruler, QEvent::MouseMove, destination, Qt::NoButton, Qt::LeftButton);
                mouse(ruler, QEvent::MouseButtonRelease, destination, Qt::LeftButton, Qt::NoButton);
            };
            for (bool isVertical : {false, true}) {
                QWidget *ruler = isVertical ? vertical : horizontal;
                const QPointF documentPosition(123, 87);
                const QPointF destination = ruler->mapFromGlobal(canvas->mapToGlobal(window.documentToCanvasPoint(documentPosition)));
                drag(ruler, destination);
                require(guides().size() == 1 && guides().first().toObject().value("vertical").toBool() == isVertical,
                        "ruler drag created the wrong guide axis");
                require(std::abs(guides().first().toObject().value("position").toDouble()
                                 - (isVertical ? documentPosition.x() : documentPosition.y())) <= 1,
                        "zoomed ruler drag used incorrect document coordinates");
                require(window.sessionState().value("undoName").toString() == "New Guide"
                            && !window.sessionState().value("guideDragging").toBool(),
                        "ruler release did not finish one guide edit");
                const auto created = guides();
                const QPointF onGuide = window.documentToCanvasPoint(documentPosition);
                const QPointF onRuler = isVertical ? QPointF(-9, onGuide.y()) : QPointF(onGuide.x(), -9);
                mouse(canvas, QEvent::MouseButtonPress, onGuide, Qt::LeftButton, Qt::LeftButton);
                require(window.sessionState().value("guideDragging").toBool(), "Move did not grab the existing guide");
                mouse(canvas, QEvent::MouseMove, onRuler, Qt::NoButton, Qt::LeftButton);
                mouse(canvas, QEvent::MouseButtonRelease, onRuler, Qt::LeftButton, Qt::NoButton);
                require(guides().isEmpty() && window.sessionState().value("undoName").toString() == "Delete Guide",
                        "canvas guide released on a ruler was not deleted");
                require(window.sendCommand({{"action", "undo"}}) && guides() == created, "Delete Guide Undo did not restore guide");
                require(window.sendCommand({{"action", "undo"}}) && guides().isEmpty(), "guide Undo did not remove the new guide");
                const auto history = window.sessionState();
                drag(ruler, ruler->rect().center());
                const auto canceled = window.sessionState();
                require(guides().isEmpty() && !canceled.value("guideDragging").toBool(), "ruler-return did not discard new guide");
                for (const char *field : {"layers", "activeLayerID", "modified", "canUndo", "canRedo", "undoName", "redoName"})
                    require(canceled.value(field) == history.value(field), "discarded guide changed document/history");
            }
            menu("Lock Guides");
            require(!window.sessionState().value("canEditGuides").toBool(), "Lock Guides did not prevent guide edits");
            drag(horizontal, horizontal->mapFromGlobal(canvas->mapToGlobal(window.documentToCanvasPoint(QPointF(123, 87)))));
            require(guides().isEmpty() && !window.sessionState().value("guideDragging").toBool(), "locked ruler created a guide");
            menu("Lock Guides");
            require(window.sessionState().value("canEditGuides").toBool(), "guide editing did not recover after unlocking");
            menu("Rulers");
            require(!horizontal->isVisible() && !vertical->isVisible(), "Rulers menu did not hide native rulers");
            qInfo("Qt ruler guides OK (both axes, zoomed document coordinates, creation/deletion Undo, ruler-return discard, lock/refusal/recovery)");
        }

        // Show Controls displays handles while ordinary editing and history remain available.
        require(window.sendCommand({{"action", "setShowsTransformControls"}, {"enabled", true}}),
                "setShowsTransformControls failed");
        require(window.sessionState().value("showsTransformControls").toBool(),
                "Show Controls did not stick in session state");
        QApplication::processEvents();
        require(!window.sessionState().value("transforming").toBool(),
                "Show Controls entered Free Transform without an edit");
        require(window.sessionState().value("canUndo").toBool(), "Show Controls blocked startup history");
        const QString initialLayer = window.sessionState().value("activeLayerID").toString();
        require(window.sendCommand({{"action", "addLayer"}}), "add layer with Show Controls failed");
        require(window.sessionState().value("layers").toArray().size() == 2,
                "Show Controls blocked adding a layer");
        require(window.sendCommand({{"action", "undo"}}), "undo add layer with Show Controls failed");
        require(window.sessionState().value("layers").toArray().size() == 1
                    && window.sessionState().value("activeLayerID").toString() == initialLayer,
                "Show Controls blocked undoing a layer addition");
        auto *blend = window.findChild<QComboBox *>("blend.mode");
        require(blend, "blend mode combo missing");
        blend->setCurrentText("Multiply");
        require(window.sessionState().value("layers").toArray().at(0).toObject().value("blendMode").toString()
                    == QLatin1String("Multiply"), "Show Controls blocked blend mode editing");
        require(window.sendCommand({{"action", "undo"}}), "undo blend mode with Show Controls failed");
        require(window.sessionState().value("layers").toArray().at(0).toObject().value("blendMode").toString()
                    == QLatin1String("Normal"), "Show Controls blocked undoing blend mode");
        auto *apply = window.findChild<QPushButton *>("transform.apply");
        auto *cancel = window.findChild<QPushButton *>("transform.cancel");
        require(apply && cancel, "transform Apply/Cancel controls missing");
        const auto checkTransformControls = [&](bool pending) {
            require(window.sessionState().value("transformPending").toBool() == pending,
                    "pending transform state disagrees with the edit");
            // The fallback options page is hidden while the SwiftUI header is on screen; inspect each button's
            // own visibility, then check the displayed header too, including opacity inherited from its row.
            require(apply->isHidden() != pending && cancel->isHidden() != pending,
                    "fallback Apply/Cancel visibility disagrees with the edit");
            auto *header = window.findChild<QWidget *>("swiftUIOptionsContainer");
            require(header && header->isVisible(), "SwiftUI transform header is not displayed");
            QPushButton *headerApply = nullptr;
            QPushButton *headerCancel = nullptr;
            for (auto *button : header->findChildren<QPushButton *>()) {
                if (!button->isVisible()) continue; // a replaced header can await deferred deletion
                if (button->objectName() == QLatin1String("applyTransform")) headerApply = button;
                if (button->text() == QLatin1String("Cancel")) headerCancel = button;
            }
            require(headerApply && headerCancel, "SwiftUI Apply/Cancel controls missing");
            const auto isDrawn = [](QWidget *widget) {
                if (!widget->isVisible()) return false;
                for (auto *ancestor = widget; ancestor; ancestor = ancestor->parentWidget()) {
                    if (auto *effect = qobject_cast<QGraphicsOpacityEffect *>(ancestor->graphicsEffect());
                        effect && effect->opacity() == 0) return false;
                }
                return true;
            };
            require(isDrawn(headerApply) == pending && isDrawn(headerCancel) == pending,
                    "SwiftUI Apply/Cancel drawing disagrees with the edit");
        };
        checkTransformControls(false);

        const auto transformValue = [&]() {
            return window.sessionState().value("layers").toArray().at(0).toObject().value("transform").toObject();
        };
        const auto headerButton = [&](const QString &title) -> QPushButton * {
            auto *header = window.findChild<QWidget *>("swiftUIOptionsContainer");
            require(header && header->isVisible(), "transform header missing for toolbar action");
            for (auto *button : header->findChildren<QPushButton *>()) {
                if (button->isVisible() && button->text() == title) {
                    require(button->isEnabled(), "transform toolbar action is disabled");
                    return button;
                }
            }
            throw std::runtime_error("transform toolbar button missing");
        };
        const auto changeSampling = [&]() {
            auto *header = window.findChild<QWidget *>("swiftUIOptionsContainer");
            require(header && header->isVisible(), "transform header missing for Sampling");
            for (auto *combo : header->findChildren<QComboBox *>()) {
                if (!combo->isVisible() || combo->findText("Nearest") < 0
                    || combo->findText("Smooth") < 0 || combo->findText("High quality") < 0) continue;
                require(combo->isEnabled(), "transform Sampling is disabled");
                const QString next = combo->currentText() == QLatin1String("Nearest")
                    ? QStringLiteral("Smooth") : QStringLiteral("Nearest");
                combo->setCurrentText(next);
                QApplication::processEvents();
                return next;
            }
            throw std::runtime_error("transform Sampling picker missing");
        };

        // Buttons and pop-up choices are complete actions: starting from idle, they must finish their own edit.
        const QJsonObject beforeToolbarActions = transformValue();
        headerButton(QStringLiteral("Flip H"))->click();
        QApplication::processEvents();
        require(!window.sessionState().value("transforming").toBool(), "toolbar Flip H left an idle transform open");
        QJsonObject flipped = beforeToolbarActions;
        flipped.insert("flipX", !beforeToolbarActions.value("flipX").toBool());
        require(transformValue() == flipped, "toolbar Flip H changed the wrong transform values");
        require(window.sessionState().value("canUndo").toBool(), "toolbar Flip H left no undo");
        checkTransformControls(false);
        require(window.sendCommand({{"action", "undo"}}), "toolbar Flip H undo failed");
        require(transformValue() == beforeToolbarActions, "toolbar Flip H undo did not restore the exact transform");

        QJsonObject resampled = beforeToolbarActions;
        resampled.insert("sampling", changeSampling());
        require(!window.sessionState().value("transforming").toBool(), "toolbar Sampling left an idle transform open");
        require(transformValue() == resampled, "toolbar Sampling changed the wrong transform values");
        require(window.sessionState().value("canUndo").toBool(), "toolbar Sampling left no undo");
        checkTransformControls(false);
        require(window.sendCommand({{"action", "undo"}}), "toolbar Sampling undo failed");
        require(transformValue() == beforeToolbarActions, "toolbar Sampling undo did not restore the exact transform");

        // The same choices join an explicit Free Transform draft, which still waits for Apply or Cancel.
        for (const bool commit : {false, true}) {
            window.enterFreeTransform();
            QApplication::processEvents();
            checkTransformControls(true);
            headerButton(QStringLiteral("Flip H"))->click();
            QApplication::processEvents();
            require(window.sessionState().value("transforming").toBool(), "toolbar Flip H ended explicit Free Transform");
            QJsonObject pending = flipped;
            require(transformValue() == pending, "pending toolbar Flip H changed the wrong transform values");
            pending.insert("sampling", changeSampling());
            require(window.sessionState().value("transforming").toBool(), "toolbar Sampling ended explicit Free Transform");
            require(transformValue() == pending, "pending toolbar Sampling changed the wrong transform values");
            require(!window.sessionState().value("canUndo").toBool(), "pending toolbar choices exposed history");
            checkTransformControls(true);
            headerButton(commit ? QStringLiteral("Apply") : QStringLiteral("Cancel"))->click();
            QApplication::processEvents();
            require(!window.sessionState().value("transforming").toBool(), "toolbar completion left Free Transform open");
            require(transformValue() == (commit ? pending : beforeToolbarActions),
                    "toolbar completion did not apply or restore the exact transform");
            checkTransformControls(false);
            if (commit) {
                require(window.sessionState().value("canUndo").toBool(), "applying toolbar choices left no undo");
                require(window.sendCommand({{"action", "undo"}}), "applied toolbar choices undo failed");
                require(transformValue() == beforeToolbarActions, "applied toolbar choices undo lost the original transform");
            }
        }

        const auto geometry = [&]() {
            const QJsonObject layer = window.sessionState().value("layers").toArray().at(0).toObject();
            const QJsonObject t = layer.value("transform").toObject();
            auto pair = [](const QJsonValue &v, const char *a, const char *b) {
                if (v.isArray()) return QPointF(v.toArray().at(0).toDouble(), v.toArray().at(1).toDouble());
                return QPointF(v.toObject().value(a).toDouble(), v.toObject().value(b).toDouble());
            };
            const QPointF o = pair(t.value("origin"), "x", "y");
            const QPointF z = pair(t.value("size"), "width", "height");
            return QRectF(o.x(), o.y(), z.x(), z.y());
        };
        const auto rotation = [&]() {
            const QJsonObject layer = window.sessionState().value("layers").toArray().at(0).toObject();
            return layer.value("transform").toObject().value("rotation").toDouble();
        };

        // Demo canvas: red brush stroke leaves a ~56x56 layer in a 64x64 document.
        require(geometry().size() == QSizeF(56, 56), "unexpected initial layer size for transform smoke");

        QWidget *canvas = window.findChild<QWidget *>(QStringLiteral("editorCanvas"));
        require(canvas != nullptr, "editorCanvas missing");
        auto at = [&](double dx, double dy) { return window.documentToCanvasPoint(QPointF(dx, dy)); };
        auto drag = [&](QPointF from, QPointF to, Qt::KeyboardModifiers mods = Qt::NoModifier) {
            disablePixelOracleSnapping(window);
            const bool pending = window.sessionState().value("transformPending").toBool();
            auto send = [&](QEvent::Type type, QPointF pos, Qt::MouseButton button, Qt::MouseButtons buttons) {
                QMouseEvent ev(type, pos, canvas->mapToGlobal(pos.toPoint()), button, buttons, mods);
                QApplication::sendEvent(canvas, &ev);
            };
            send(QEvent::MouseButtonPress, from, Qt::LeftButton, Qt::LeftButton);
            QApplication::processEvents();
            require(window.sessionState().value("transforming").toBool(), "transform drag did not begin an edit");
            checkTransformControls(pending);
            send(QEvent::MouseMove, (from + to) / 2, Qt::NoButton, Qt::LeftButton);
            QApplication::processEvents();
            checkTransformControls(pending);
            send(QEvent::MouseMove, to, Qt::NoButton, Qt::LeftButton);
            send(QEvent::MouseButtonRelease, to, Qt::LeftButton, Qt::NoButton);
            QApplication::processEvents();
            checkTransformControls(pending);
        };

        // 1) A Show Controls handle drag applies on release as one undo step.
        drag(at(56, 56), at(48, 48));
        require(geometry().size() == QSizeF(48, 48),
                "corner handle drag with Show Controls did not resize (transformation missing)");
        require(!window.sessionState().value("transforming").toBool(),
                "ordinary handle drag left a pending Free Transform");
        require(window.sessionState().value("canUndo").toBool(), "handle resize left no undo");
        require(window.sendCommand({{"action", "undo"}}), "handle resize undo failed");
        require(geometry().size() == QSizeF(56, 56), "handle resize undo did not restore size");
        require(window.sendCommand({{"action", "redo"}}), "handle resize redo failed");
        require(geometry().size() == QSizeF(48, 48), "handle resize redo did not restore size");

        // 2) A body drag applies on release, with controls still visible.
        const QRectF beforeMove = geometry();
        drag(at(20, 20), at(24, 25));
        require(qRound(geometry().x()) == qRound(beforeMove.x()) + 4
                    && qRound(geometry().y()) == qRound(beforeMove.y()) + 5,
                "body drag did not move the layer");

        require(!window.sessionState().value("transforming").toBool(),
                "ordinary body drag left a pending Free Transform");
        require(window.sendCommand({{"action", "undo"}}), "body drag undo failed");
        require(geometry() == beforeMove, "body drag undo did not restore placement");
        require(window.sendCommand({{"action", "redo"}}), "body drag redo failed");
        require(!window.sessionState().value("transforming").toBool(), "redo re-armed Free Transform");

        // 3) Ctrl+T explicitly enters Free Transform, independently of Show Controls.
        require(window.sendCommand({{"action", "setShowsTransformControls"}, {"enabled", false}}),
                "could not turn Show Controls off");
        require(!window.sessionState().value("showsTransformControls").toBool(),
                "Show Controls stayed on");
        require(!window.sessionState().value("transforming").toBool(),
                "Show Controls off did not clear Free Transform");
        window.enterFreeTransform();
        QApplication::processEvents();
        require(window.sessionState().value("transforming").toBool(),
                "enterFreeTransform did not enter transforming state");
        checkTransformControls(true);
        require(window.sessionState().value("tool").toString() == QLatin1String("move"),
                "enterFreeTransform did not select Move tool");
        require(window.sendCommand({{"action", "setShowsTransformControls"}, {"enabled", true}}),
                "could not show controls during Free Transform");
        require(window.sessionState().value("transforming").toBool(), "showing controls ended Free Transform");
        require(window.sendCommand({{"action", "setShowsTransformControls"}, {"enabled", false}}),
                "could not hide controls during Free Transform");
        require(window.sessionState().value("transforming").toBool(), "hiding controls cancelled explicit Free Transform");

        const QRectF beforePersistent = geometry();
        // Simulate leftover Ctrl from the Ctrl+T chord on the press — enterFreeTransform must have cleared
        // HeldModifiers/⌘ so this still scales instead of distorting.
        drag(at(beforePersistent.right(), beforePersistent.bottom()),
             at(beforePersistent.right() + 16, beforePersistent.bottom() + 16), Qt::ControlModifier);
        require(geometry().width() > beforePersistent.width() + 0.5
                    && geometry().height() > beforePersistent.height() + 0.5,
                "persistent Free Transform handle drag did not resize (Ctrl leftover after Ctrl+T?)");
        require(window.sessionState().value("transforming").toBool(),
                "persistent transform ended on mouse-up (should wait for Enter/Esc)");
        require(window.sessionState().value("distortCorners").toArray().isEmpty(),
                "Ctrl leftover after Ctrl+T entered distort instead of scale");

        // Rotation handle sits 28 view-points above the top-edge midpoint (TransformOverlayGeometry).
        const QRectF beforeRotate = geometry();
        const double angleBefore = rotation();
        const QPointF topMidView = at(beforeRotate.center().x(), beforeRotate.top());
        const QPointF rotHandle = topMidView + QPointF(0, -28);
        drag(rotHandle, rotHandle + QPointF(40, 18));
        require(qAbs(rotation() - angleBefore) > 1.0,
                "persistent Free Transform rotation handle did not rotate");
        require(window.sessionState().value("transforming").toBool(),
                "rotation ended persistent transform early");

        // Enter applies via the shell key path with Show Controls on, without reopening an edit.
        require(window.sendCommand({{"action", "setShowsTransformControls"}, {"enabled", true}}),
                "could not show controls before applying Free Transform");
        {
            QKeyEvent enter(QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier);
            QApplication::sendEvent(&window, &enter);
            QApplication::processEvents();
        }
        require(!window.sessionState().value("transforming").toBool(),
                "Enter did not apply Free Transform (transforming still true)");
        require(window.sessionState().value("showsTransformControls").toBool(), "Enter hid transform controls");
        checkTransformControls(false);

        // 4) Esc resets a fresh persistent transform (shell key path).
        window.enterFreeTransform();
        QApplication::processEvents();
        const QRectF beforeCancel = geometry();
        drag(at(beforeCancel.right(), beforeCancel.bottom()),
             at(beforeCancel.right() + 10, beforeCancel.bottom() + 10));
        {
            QKeyEvent esc(QEvent::KeyPress, Qt::Key_Escape, Qt::NoModifier);
            QApplication::sendEvent(&window, &esc);
            QApplication::processEvents();
        }
        require(!window.sessionState().value("transforming").toBool(), "Esc did not reset Free Transform");
        checkTransformControls(false);
        require(qAbs(geometry().width() - beforeCancel.width()) < 0.5
                    && qAbs(geometry().height() - beforeCancel.height()) < 0.5,
                "Esc reset did not restore size");

        // 5) Save commits an explicit pending draft and leaves Show Controls idle.
        require(window.sendCommand({{"action", "setShowsTransformControls"}, {"enabled", true}}),
                "could not re-enable Show Controls before save");
        QApplication::processEvents();
        require(!window.sessionState().value("transforming").toBool(), "showing controls before save started an edit");
        window.enterFreeTransform();
        require(window.sendCommand({{"action", "transform"}, {"parameters", QJsonObject{{"x", geometry().x() + 3}}}}),
                "pending transform before save failed");
        require(window.sessionState().value("transforming").toBool(), "save fixture has no pending transform");
        const QRectF savedGeometry = geometry();
        const double savedRotation = rotation();
        QTemporaryDir packageDir;
        require(packageDir.isValid(), "temp dir for save smoke");
        const QString savedPath = packageDir.filePath(QStringLiteral("transform-save.comp"));
        require(window.saveProject(savedPath), "save while Free Transform active failed");
        require(QFileInfo::exists(savedPath + "/manifest.json"), "saved package missing manifest");
        const QImage packagePreview(savedPath + "/QuickLook/Preview.jpg");
        require(!packagePreview.isNull(), "saved package missing readable QuickLook JPEG");
        const auto savedState = window.sessionState();
        const int canvasWidth = savedState.value("width").toInt();
        const int canvasHeight = savedState.value("height").toInt();
        const double previewScale = std::min(1.0, 1024.0 / std::max(canvasWidth, canvasHeight));
        require(packagePreview.width() == std::max(1, qRound(canvasWidth * previewScale))
                    && packagePreview.height() == std::max(1, qRound(canvasHeight * previewScale)),
                "saved QuickLook preview has incorrect canvas dimensions");
        require(!window.sessionState().value("transforming").toBool(), "save re-armed Free Transform");
        // Overwrite save (atomic replace of existing .comp directory).
        require(window.saveProject(savedPath), "overwrite saved transform failed");
        require(window.loadProject(savedPath), "reopening saved transform failed");
        require(geometry() == savedGeometry && qAbs(rotation() - savedRotation) < 0.001,
                "saved project lost the pending transform draft");
        require(!window.sessionState().value("transforming").toBool(), "reopening saved project re-armed Free Transform");

        // 6) Save As: native dialogs often create an empty file at the chosen path — package install must replace it.
        const QString saveAsPath = packageDir.filePath(QStringLiteral("save-as.comp"));
        {
            QFile placeholder(saveAsPath);
            require(placeholder.open(QIODevice::WriteOnly), "could not create Save As placeholder file");
            placeholder.close();
            require(QFileInfo(saveAsPath).isFile(), "Save As placeholder should be a file");
        }
        require(window.writeProjectPackage(saveAsPath), "Save As over empty placeholder file failed");
        require(QFileInfo(saveAsPath).isDir(), "Save As did not install a directory package");
        require(QFileInfo::exists(saveAsPath + "/manifest.json"), "Save As package missing manifest");
        // Save As over an existing directory package (not just a placeholder file).
        require(window.writeProjectPackage(saveAsPath), "Save As overwrite of directory package failed");

        SessionWindow deepWindow;
        deepWindow.initDemoDocument();
        const QString templatePath = packageDir.filePath("deep-template.comp");
        require(deepWindow.writeProjectPackage(templatePath), "deep project template save failed");
        QFile templateFile(templatePath + "/manifest.json");
        require(templateFile.open(QIODevice::ReadOnly), "deep template manifest missing");
        const QJsonObject prototype = QJsonDocument::fromJson(templateFile.readAll()).object();
        PackageImageDecode decode = nullptr;
        PackageImageEncode encode = nullptr;
        require(compositor_qt_imageio_functions(&decode, &encode) && compositor_qt_imageio_deep_decode(&decode),
                "deep image codec unavailable");
        const auto writeBytes = [&](const QString &path, const QByteArray &bytes) {
            QFile file(path);
            require(file.open(QIODevice::WriteOnly) && file.write(bytes) == bytes.size(), "deep fixture write failed");
        };
        for (const bool hdr : {false, true}) {
            QJsonObject manifest = prototype;
            QJsonObject layer = manifest.value("layers").toArray().first().toObject();
            const QString id = QUuid::createUuid().toString(QUuid::WithoutBraces).toUpper();
            const QString filename = id + (hdr ? ".exr" : ".png");
            manifest["version"] = hdr ? 13 : 12;
            manifest["width"] = 256; manifest["height"] = 8;
            manifest["activeLayerID"] = id;
            layer["id"] = id; layer["imageFile"] = filename;
            QJsonObject transform = layer.value("transform").toObject();
            transform["origin"] = QJsonArray{0, 0};
            transform["size"] = QJsonArray{256, 8};
            layer["transform"] = transform;
            manifest["layers"] = QJsonArray{layer};
            std::vector<uint16_t> fine(256 * 8 * 4);
            std::vector<float> wide(256 * 8 * 4);
            for (int i = 0; i < 256 * 8; ++i) {
                const uint16_t alpha16 = i % 4 == 0 ? 0 : i % 4 == 1 ? 16384 : i % 4 == 2 ? 32768 : 65535;
                const float alpha = alpha16 / 65535.0f;
                fine[i * 4] = fine[i * 4 + 1] = fine[i * 4 + 2] = ((25000 + i % 256) * alpha16 + 32767) / 65535;
                fine[i * 4 + 3] = alpha16;
                wide[i * 4] = (2.0f + (i % 256) / 256.0f) * alpha;
                wide[i * 4 + 1] = 0.25f * alpha; wide[i * 4 + 2] = 0.125f * alpha; wide[i * 4 + 3] = alpha;
            }
            uint8_t *encoded = nullptr; size_t encodedSize = 0;
            require(encode(hdr ? reinterpret_cast<const uint8_t *>(wide.data()) : reinterpret_cast<const uint8_t *>(fine.data()),
                           256, 8, hdr ? 16 : 8, hdr ? "com.ilm.openexr-image" : "public.png", 1, 72, 1,
                           &encoded, &encodedSize) == 0 && encodedSize > 0, "deep fixture encode failed");
            const QString sourcePath = packageDir.filePath(hdr ? "hdr-source.comp" : "16-source.comp");
            require(QDir().mkpath(sourcePath + "/images"), "deep fixture directory failed");
            writeBytes(sourcePath + "/manifest.json", QJsonDocument(manifest).toJson());
            writeBytes(sourcePath + "/images/" + filename, QByteArray(reinterpret_cast<const char *>(encoded), encodedSize));
            std::free(encoded);
            require(deepWindow.readProjectPackage(sourcePath), "deep project open failed");
            const QString saved = packageDir.filePath(hdr ? "hdr-saved.comp" : "16-saved.comp");
            require(deepWindow.writeProjectPackage(saved), "deep project save failed");
            const auto checkDeepAsset = [&](const QString &assetPath) {
                QFile asset(assetPath);
                require(asset.open(QIODevice::ReadOnly), "saved deep asset missing");
                const QByteArray bytes = asset.readAll();
                uint8_t *decoded = nullptr; int32_t width = 0, height = 0, layout = 0, orientation = 0;
                double dpi = 0; char type[80]{};
                require(decode(reinterpret_cast<const uint8_t *>(bytes.constData()), bytes.size(), &decoded, &width, &height,
                               &layout, &dpi, &orientation, type, sizeof(type)) == 0, "saved deep asset decode failed");
                require(width == 256 && height == 8 && layout == (hdr ? 16 : 8), "saved layer lost 16-bit/HDR precision");
                for (int i = 0; i < 256 * 8 * 4; ++i) {
                    if (hdr) require(std::abs(reinterpret_cast<const float *>(decoded)[i] - wide[i]) < 0.008f, "HDR light changed on save");
                    else require(std::abs(int(reinterpret_cast<const uint16_t *>(decoded)[i]) - int(fine[i])) <= 1, "16-bit fine steps changed on save");
                }
                std::free(decoded);
            };
            checkDeepAsset(saved + "/images/" + filename);
            require(deepWindow.readProjectPackage(saved), "saved deep project reopen failed");
            require(deepWindow.importImage(sourcePath + "/images/" + filename), "deep photo import failed");
            const auto importedState = deepWindow.sessionState();
            require(importedState.value("width").toInt() == 256 && importedState.value("height").toInt() == 8,
                    "deep photo import changed the canvas dimensions");
            const QString importedPath = packageDir.filePath(hdr ? "hdr-imported.comp" : "16-imported.comp");
            require(deepWindow.writeProjectPackage(importedPath), "deep imported photo save failed");
            QFile importedManifest(importedPath + "/manifest.json");
            require(importedManifest.open(QIODevice::ReadOnly), "imported deep manifest missing");
            const auto importedLayers = QJsonDocument::fromJson(importedManifest.readAll()).object().value("layers").toArray();
            require(importedLayers.size() == 1, "deep photo import retained another document's layers");
            const QString importedFile = importedLayers.first().toObject().value("imageFile").toString();
            require(importedFile.endsWith(hdr ? ".exr" : ".png"), "imported deep photo used the wrong asset format");
            checkDeepAsset(importedPath + "/images/" + importedFile);
            require(deepWindow.readProjectPackage(importedPath), "imported deep photo package reopen failed");

            const auto watchedHandle = deepWindow.sessionHandle();
            importedManifest.seek(0);
            QJsonObject changed = QJsonDocument::fromJson(importedManifest.readAll()).object();
            auto changedLayers = changed.value("layers").toArray();
            auto changedLayer = changedLayers.first().toObject();
            changedLayer["name"] = "Changed outside Compositor";
            changedLayers[0] = changedLayer; changed["layers"] = changedLayers;
            writeBytes(importedPath + "/manifest.json", QJsonDocument(changed).toJson());
            QElapsedTimer watchDeadline; watchDeadline.start();
            while (watchDeadline.elapsed() < 4000 && deepWindow.sessionState().value("layers").toArray().first().toObject().value("name").toString() != "Changed outside Compositor") {
                QApplication::processEvents(QEventLoop::AllEvents, 10);
                QThread::msleep(10);
            }
            require(deepWindow.sessionState().value("layers").toArray().first().toObject().value("name").toString() == "Changed outside Compositor",
                    "native project did not reload after an external manifest change");
            require(deepWindow.sessionHandle() == watchedHandle, "external reload replaced the document tab");
            deepWindow.show(); deepWindow.activateWindow();
            QApplication::processEvents();
            int watchPrompts = 0;
            QString watchAnswer = "Keep Mine";
            QTimer answerWatchAlert;
            answerWatchAlert.setInterval(10);
            QObject::connect(&answerWatchAlert, &QTimer::timeout, [&] {
                for (auto *widget : QApplication::topLevelWidgets()) {
                    auto *alert = qobject_cast<QMessageBox *>(widget);
                    if (!alert || !alert->isVisible() || !alert->text().contains("was changed on disk")) continue;
                    for (auto *button : alert->buttons()) if (button->text() == watchAnswer) {
                        ++watchPrompts; button->click(); return;
                    }
                }
            });
            answerWatchAlert.start();
            const auto settleWatch = [&](int duration) {
                QElapsedTimer clock; clock.start();
                while (clock.elapsed() < duration) {
                    QApplication::processEvents(QEventLoop::AllEvents, 10);
                    QThread::msleep(10);
                }
            };
            const auto watchedPixels = [&] {
                const auto size = compositor_session_render(watchedHandle, nullptr, 0);
                require(size > 0 && size <= 256 * 8 * 4, "watched project pixels unavailable");
                QByteArray pixels(size, Qt::Uninitialized);
                require(compositor_session_render(watchedHandle, reinterpret_cast<uint8_t *>(pixels.data()), pixels.size()) == size,
                        "watched project pixel read failed");
                return pixels;
            };
            const QString watchedAssetPath = importedPath + "/images/" + importedFile;
            QFile watchedAsset(watchedAssetPath);
            require(watchedAsset.open(QIODevice::ReadOnly), "watched asset missing before corruption checks");
            const auto validAsset = watchedAsset.readAll();
            watchedAsset.close();
            for (const QString &fault : {QString("manifest"), QString("missing asset"), QString("truncated asset")}) {
                const auto beforeFault = deepWindow.sessionState();
                const auto pixelsBeforeFault = watchedPixels();
                if (fault == "manifest") writeBytes(importedPath + "/manifest.json", "{\"version\":");
                else if (fault == "missing asset")
                    require(QFile::rename(watchedAssetPath, watchedAssetPath + ".held"), "could not hold watched asset");
                else writeBytes(watchedAssetPath, validAsset.left(12));
                settleWatch(900);
                const auto afterFault = deepWindow.sessionState();
                require(watchPrompts == 0 && deepWindow.sessionHandle() == watchedHandle,
                        "invalid watched package prompted or replaced the tab");
                for (const char *field : {"width", "height", "layers", "activeLayerID", "modified", "canUndo", "canRedo", "undoName", "redoName"})
                    require(afterFault.value(field) == beforeFault.value(field), "invalid watched package changed document or history");
                require(watchedPixels() == pixelsBeforeFault, "invalid watched package changed canvas pixels");
                if (fault == "missing asset")
                    require(QFile::rename(watchedAssetPath + ".held", watchedAssetPath), "could not restore watched asset");
                else if (fault == "truncated asset") writeBytes(watchedAssetPath, validAsset);
                changedLayer["name"] = "Recovered after " + fault;
                changedLayers[0] = changedLayer; changed["layers"] = changedLayers;
                writeBytes(importedPath + "/manifest.json", QJsonDocument(changed).toJson());
                watchDeadline.restart();
                while (deepWindow.sessionState().value("layers").toArray().first().toObject().value("name") != changedLayer.value("name")
                       && watchDeadline.elapsed() < 4000) settleWatch(20);
                require(deepWindow.sessionState().value("layers").toArray().first().toObject().value("name") == changedLayer.value("name")
                            && deepWindow.sessionHandle() == watchedHandle && watchPrompts == 0,
                        "valid watched package did not recover after corruption");
                require(watchedPixels() == pixelsBeforeFault, "recovered watched package changed deep-image pixels");
            }
            qInfo("Qt external package corruption recovery OK (%s; truncated manifest, missing/truncated asset, same tab/pixels/history)",
                  hdr ? "HDR" : "PNG16");
            require(deepWindow.sendCommand({{"action", "renameLayer"}, {"name", "Local unsaved"}}), "local watch edit failed");
            writeBytes(importedPath + "/manifest.json", QJsonDocument(changed).toJson());
            settleWatch(900);
            require(watchPrompts == 0 && deepWindow.sessionState().value("canUndo").toBool(), "unchanged bytes disturbed local history");
            changedLayer["name"] = "External kept"; changedLayers[0] = changedLayer; changed["layers"] = changedLayers;
            writeBytes(importedPath + "/manifest.json", QJsonDocument(changed).toJson());
            watchDeadline.restart();
            while (watchPrompts < 1 && watchDeadline.elapsed() < 4000) settleWatch(20);
            require(watchPrompts == 1 && deepWindow.sessionState().value("modified").toBool()
                        && deepWindow.sessionState().value("layers").toArray().first().toObject().value("name").toString() == "Local unsaved",
                    "Keep Mine lost unsaved project work");
            watchAnswer = "Revert";
            changedLayer["name"] = "External reverted"; changedLayers[0] = changedLayer; changed["layers"] = changedLayers;
            writeBytes(importedPath + "/manifest.json", QJsonDocument(changed).toJson());
            watchDeadline.restart();
            while (deepWindow.sessionState().value("layers").toArray().first().toObject().value("name").toString() != "External reverted"
                   && watchDeadline.elapsed() < 4000) settleWatch(20);
            require(watchPrompts == 2 && !deepWindow.sessionState().value("modified").toBool()
                        && !deepWindow.sessionState().value("canUndo").toBool(), "Revert did not install the external saved revision");
            require(deepWindow.sendCommand({{"action", "brushBegin"}, {"x", 3}, {"y", 3},
                        {"parameters", QJsonObject{{"diameter", 3}, {"hardness", 1}, {"opacity", 1},
                                                   {"red", 1}, {"green", 0}, {"blue", 0}, {"mask", 0}}}}),
                    "watched busy stroke failed to start");
            watchAnswer = "Keep Mine";
            changedLayer["name"] = "Changed during stroke"; changedLayers[0] = changedLayer; changed["layers"] = changedLayers;
            writeBytes(importedPath + "/manifest.json", QJsonDocument(changed).toJson());
            settleWatch(900);
            require(watchPrompts == 2 && deepWindow.sessionState().value("layers").toArray().first().toObject().value("name").toString() == "External reverted",
                    "external reload interrupted an active stroke");
            require(deepWindow.sendCommand({{"action", "brushEnd"}}), "watched busy stroke failed to finish");
            watchDeadline.restart();
            while (watchPrompts < 3 && watchDeadline.elapsed() < 4000) settleWatch(20);
            require(watchPrompts == 3 && deepWindow.sessionState().value("modified").toBool(),
                    "deferred external change did not recover after stroke release");
            require(deepWindow.sendCommand({{"action", "renameLayer"}, {"name", "Own saved edit"}}), "own watch save edit failed");
            bool ownSaveFinished = false, ownSaveSucceeded = false;
            require(deepWindow.startProjectSave(importedPath, false, [&](bool ok) {
                ownSaveSucceeded = ok; ownSaveFinished = true;
            }), "own watched save failed to start");
            watchDeadline.restart();
            while (!ownSaveFinished && watchDeadline.elapsed() < 4000) settleWatch(20);
            require(ownSaveFinished && ownSaveSucceeded, "own watched save failed");
            settleWatch(900);
            require(watchPrompts == 3 && deepWindow.sessionState().value("canUndo").toBool()
                        && !deepWindow.sessionState().value("modified").toBool(), "own save triggered a reload or erased history");
            require(deepWindow.sessionHandle() == watchedHandle, "watch responses replaced the document tab");
            require(deepWindow.sendCommand({{"action", "renameLayer"}, {"name", "Inactive local work"}}), "inactive watch edit failed");
            auto *watchTabs = deepWindow.findChild<QTabBar *>("header.documentTabs");
            require(watchTabs, "watch document tabs missing");
            const int watchedIndex = watchTabs->currentIndex();
            deepWindow.createNewDocument(32, 24);
            require(deepWindow.sendCommand({{"action", "renameLayer"}, {"name", "Other document work"}}), "other watch document edit failed");
            const auto otherHandle = deepWindow.sessionHandle();
            const int otherIndex = watchTabs->currentIndex();
            const auto otherBefore = deepWindow.sessionState();
            changedLayer["name"] = "Inactive external change"; changedLayers[0] = changedLayer; changed["layers"] = changedLayers;
            writeBytes(importedPath + "/manifest.json", QJsonDocument(changed).toJson());
            settleWatch(900);
            require(watchPrompts == 3 && deepWindow.sessionHandle() == otherHandle,
                    "inactive dirty project prompted or stole the active document");
            const auto checkOtherWatchState = [&] {
                const auto current = deepWindow.sessionState();
                for (const char *field : {"width", "height", "layers", "activeLayerID", "modified", "canUndo", "canRedo", "undoName", "redoName"})
                    require(current.value(field) == otherBefore.value(field), "external watch changed the other document or history");
            };
            checkOtherWatchState();
            watchTabs->setCurrentIndex(watchedIndex);
            watchDeadline.restart();
            while (watchPrompts < 4 && watchDeadline.elapsed() < 4000) settleWatch(20);
            require(watchPrompts == 4 && deepWindow.sessionHandle() == watchedHandle
                        && deepWindow.sessionState().value("modified").toBool()
                        && deepWindow.sessionState().value("layers").toArray().first().toObject().value("name").toString() == "Inactive local work",
                    "selecting the dirty watched tab did not resume Keep Mine safely");
            watchTabs->setCurrentIndex(otherIndex);
            require(deepWindow.sessionHandle() == otherHandle, "return to other watched document failed");
            checkOtherWatchState();
            answerWatchAlert.stop();

        }
        qInfo("Qt transform smoke OK (idle Show Controls, editing and history, Ctrl+T Enter/Esc, pending-draft save, Save As, 16-bit/HDR package and photo-import pixels)");
        return 0;
    } catch (const std::exception &e) {
        qCritical("Qt transform smoke failed: %s", e.what());
        return 1;
    }
}
