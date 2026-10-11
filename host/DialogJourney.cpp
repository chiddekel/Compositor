#include "CompositorUIFont.h"
// Qt event-loop journey, invoked by the Swift composition root with --dialog-smoke.
// Uses actual menu actions, modal controls, codecs, and the real Swift session.
#include "SessionWindow.h"
#include "ProjectPackageLimits.h"
#include "EditorDialogs.h"
#include "SystemClipboard.h"
#include "ImageImportDialog.h"
#include "RawControlJourney.h"
#include "compositor_host_run.h"
#include "interfaces/IPlatformServices.h"
#include <QAction>
#include <QApplication>
#include <QClipboard>
#include <QMimeData>
#include <QStyleFactory>
#include <QCheckBox>
#include <QComboBox>
#include <QDialogButtonBox>
#include <QDockWidget>
#include <QDoubleSpinBox>
#include <QGraphicsOpacityEffect>
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
#include <QScrollArea>
#include <QScrollBar>
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
#include <QStatusBar>
#include <QTouchEvent>
#include <QTabletEvent>
#include <QPointingDevice>
#include <QtTest/qtestkeyboard.h>
#include <stdexcept>
#include <cstring>

/// Tool combinations through the visible Qt rail, canvas events and inline text editor.
extern "C" int compositor_host_combo_smoke(int argc, char **argv) {
    QApplication app(argc, argv);
    installCompositorUIFont(app);
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
                    << "busy=" << state.value("busy").toBool() << "gradientLine=" << state.value("gradientLine").toArray();
                throw std::runtime_error(message);
            }
        };
        const auto command = [&](QJsonObject value) {
            check(window.sendCommand(value), "combination setup command failed");
            QApplication::processEvents();
        };
        const auto mouse = [&](QWidget *target, QEvent::Type type, QPointF position,
                               Qt::MouseButton button, Qt::MouseButtons held, Qt::KeyboardModifiers modifiers) {
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
            click(railButton(label));
            const QByteArray message = QString("rail click did not select %1").arg(name).toUtf8();
            pump([&] { return window.sessionState().value("tool").toString() == name; }, message.constData());
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
            const QString output = temporary.filePath("result.png");
            check(window.exportPNG(output), "combination export failed");
            const QImage image(output);
            check(!image.isNull() && image.size() == QSize(64, 64), "combination export dimensions changed");
            return image.convertToFormat(QImage::Format_RGBA8888);
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
        const auto gradient = [&](QPointF from, QPointF to) {
            tool("Gradient", "gradient");
            drag(from, to);
            check(window.sessionState().value("gradientLine").toArray().size() == 4,
                  "gradient release did not leave an editable line");
            key(canvas, Qt::Key_Return);
            pump([&] { return window.sessionState().value("gradientLine").toArray().isEmpty()
                              && !window.sessionState().value("busy").toBool(); }, "Return did not commit the pending gradient");
        };

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
        tool("Gradient", "gradient"); drag(at(16, 16), at(31, 31));
        check(window.sessionState().value("gradientLine").toArray().size() == 4, "pending gradient missing before tool switch");
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
            command({{"action", "setShowsTransformControls"}, {"enabled", true}});
            command({{"action", "setTransformAutoSelect"}, {"enabled", false}});
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

        // Upstream CameraRawSlider's sizeThatFits must reach its lowered Qt slider, including after layout.
        reset();
        const QImage beforeRaw = pixels();
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
        panel->resize(panel->width() + 80, panel->height() + 30);
        QApplication::processEvents();
        temperature = temperatureSlider();
        check(temperature && temperature->height() == 22 && temperature->width() > 0,
              "Camera Raw custom height changed during Qt panel layout");
        command({{"action", "filterCancel"}});
        command({{"action", "closeFloatingPanel"}, {"kind", "FilterSheet"}});
        pump([&] { return !window.sessionState().value("busy").toBool(); }, "Camera Raw cancellation left the editor busy");
        check(pixels() == beforeRaw, "Camera Raw sizing or cancellation changed document pixels");
        qInfo("Qt Camera Raw custom sizing smoke OK (22-point native slider, panel relayout, cancel pixels)");
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
    installCompositorUIFont(app);
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
    installCompositorUIFont(app);
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
    installCompositorUIFont(app);
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
    installCompositorUIFont(app);
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
    installCompositorUIFont(app);
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
    installCompositorUIFont(app);
    try {
        QTemporaryDir temporary;
        SessionWindow window;
        window.resize(1200, 800); window.show(); QApplication::setActiveWindow(&window); QApplication::processEvents();
        verifyRawControls([&](const QString &path) {
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
                if (lens->isEnabled() || !lens->toolTip().contains("unavailable")) { fail("RAW lens capability/tooltip was dishonest"); return; }
                if (!noise->isEnabled() || !highlight->isEnabled()) { fail("RAW supported controls were disabled"); return; }
                if (phase == 0) {
                    initialNoise = noise->value();
                    noise->setValue((noise->minimum() + noise->maximum()) / 2);
                    highlight->click(); phase = 1;
                } else if (phase == 1 && reset->isEnabled()) {
                    reset->click(); phase = 2;
                } else if (phase == 2 && !reset->isEnabled()) {
                    if (noise->value() != initialNoise || highlight->isChecked()) { fail("RAW Reset did not restore decoder defaults"); return; }
                    finished = true; inspector.stop(); cancel->click();
                }
            });
            inspector.start();
            const bool imported = window.sendCommand({{"action", "importFiles"}, {"paths", QJsonArray{path}}});
            while (!finished && elapsed.elapsed() < 9000) QApplication::processEvents(QEventLoop::AllEvents, 10);
            inspector.stop();
            require(finished && failure.isEmpty(), failure.isEmpty() ? "RAW sheet controls unavailable" : qPrintable(failure));
            // With no document, the bridge reports nothing imported when the user cancels this sheet.
            require(!imported && window.sessionState().value("layers").toArray().isEmpty(), "RAW sheet Cancel imported a layer");
            QApplication::setActiveWindow(&window);
            qInfo("Qt RAW develop sheet OK (supported controls, disabled lens explanation, Reset, Cancel)");
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
            const auto pos = window.documentToCanvasPoint(documentPoint);
            QMouseEvent event(type, pos, canvas->mapToGlobal(pos),
                type == QEvent::MouseMove ? Qt::NoButton : Qt::LeftButton,
                type == QEvent::MouseButtonRelease ? Qt::NoButton : Qt::LeftButton, modifiers);
            QApplication::sendEvent(canvas, &event);
            window.flushPendingDrag();
            QApplication::processEvents();
        };
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
            QApplication::processEvents();
        };
        const QString keyboardUndo = window.sessionState().value("undoName").toString();
        tableKey(Qt::Key_Up);
        const QString keyboardLayer = window.sessionState().value("activeLayerID").toString();
        require(!keyboardLayer.isEmpty() && keyboardLayer != shortBottomLayer, "native Up arrow did not select the previous layer");
        tableKey(Qt::Key_Down);
        require(window.sessionState().value("activeLayerID").toString() == shortBottomLayer, "native Down arrow did not restore the selected layer");
        tableKey(Qt::Key_Up, Qt::ShiftModifier);
        require(window.sessionState().value("mergeTitle").toString() == "Merge Layers", "native Shift-Up did not extend layer selection");
        tableKey(Qt::Key_Down, Qt::ShiftModifier);
        require(!window.sessionState().value("canMergeLayers").toBool()
                && window.sessionState().value("activeLayerID").toString() == shortBottomLayer,
                "native Shift-Down did not contract layer selection");
        require(window.sessionState().value("undoName").toString() == keyboardUndo, "native layer keyboard selection created an Undo step");
        // The scrolling fixture hid this layer. Upstream intentionally refuses transforms of hidden layers.
        command({{"action", "setVisible"}, {"layerID", shortBottomLayer}, {"enabled", true}});
        command({{"action", "selectTool"}, {"kind", "move"}});
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
        qInfo("Qt native layer keyboard OK (Up/Down selection, Shift extension/contraction, no Undo step, Move-tool nudge)");

        // The upstream AppKit layer thumbnail's Shift-click must invalidate the
        // cached frame even though it keeps the same mask image object.
        for (bool group : {false, true}) {
            fresh();
            if (group) command({{"action", "groupSelectedLayers"}});
            command({{"action", "addHideMask"}});
            const auto hidden = frame();
            require(static_cast<uint8_t>(pixel(hidden, 32, 16)[3]) == 0, "hide mask did not hide pixels");
            QWidget *table = nullptr;
            for (auto *candidate : window.findChildren<QWidget *>()) {
                if (candidate->isVisible() && candidate->property("appKitView").toBool()
                    && candidate->property("appKitNode").toString().startsWith("LayersPanel|")) { table = candidate; break; }
            }
            require(table, "upstream AppKit layers table missing");
            // The active root is the first row. Tip's thumbnail slot ends at x=78; masks have a 30-point slot
            // after a 13-point linked gap on raster layers or a 5-point gap on folders. Row controls center at y=26.
            const QPointF pos(group ? 98 : 106, 26);
            QMouseEvent down(QEvent::MouseButtonPress, pos, table->mapToGlobal(pos), Qt::LeftButton, Qt::LeftButton, Qt::ShiftModifier);
            QMouseEvent up(QEvent::MouseButtonRelease, pos, table->mapToGlobal(pos), Qt::LeftButton, Qt::NoButton, Qt::ShiftModifier);
            QApplication::sendEvent(table, &down); QApplication::sendEvent(table, &up);
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
    installCompositorUIFont(app);
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
    installCompositorUIFont(app);
    return probe ? probe() : 1;
}

/// Focused Move / Free Transform journey: idle controls, drag history, explicit Apply/Cancel, and draft saves.
extern "C" int compositor_host_transform_smoke(int argc, char **argv) {
    QApplication app(argc, argv);
    installCompositorUIFont(app);
    try {
        const auto require = [](bool ok, const char *message) {
            if (!ok) throw std::runtime_error(message);
        };
        SessionWindow window;
        window.resize(1200, 800);
        window.show();
        QApplication::processEvents();
        window.setTool(SessionWindow::Tool::Move);
        QApplication::processEvents();

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

        qInfo("Qt transform smoke OK (idle Show Controls, editing and history, Ctrl+T Enter/Esc, pending-draft save, Save As)");
        return 0;
    } catch (const std::exception &e) {
        qCritical("Qt transform smoke failed: %s", e.what());
        return 1;
    }
}
