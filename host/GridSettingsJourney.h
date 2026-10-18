#pragma once

#include "SessionWindow.h"
#include "SwiftUIQtRenderer.h"
#include <QAbstractItemView>
#include <QAction>
#include <QApplication>
#include <QComboBox>
#include <QColor>
#include <QDialog>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QImage>
#include <QJsonArray>
#include <QKeyEvent>
#include <QLabel>
#include <QLineEdit>
#include <QMenuBar>
#include <QMenu>
#include <QMouseEvent>
#include <QPointer>
#include <QPushButton>
#include <QTemporaryDir>
#include <QStringList>
#include <QThread>
#include <QTimer>
#include <QDebug>
#include <functional>
#include <stdexcept>

extern "C" void compositor_flush_preferences();

namespace gridsettingsjourney {
inline void require(bool ok, const char *message) {
    if (!ok) throw std::runtime_error(message);
}

inline void pump(const std::function<bool()> &ready, const char *message) {
    QElapsedTimer clock; clock.start();
    while (!ready() && clock.elapsed() < 5000) {
        QApplication::processEvents(QEventLoop::AllEvents, 10); QThread::msleep(1);
    }
    require(ready(), message);
}

inline void key(QWidget *widget, int code, Qt::KeyboardModifiers modifiers = Qt::NoModifier, const QString &text = {}) {
    QPointer<QWidget> target(widget);
    require(target, "grid key target missing");
    const QByteArray kind(widget->metaObject()->className());
    QKeyEvent press(QEvent::KeyPress, code, modifiers, text), release(QEvent::KeyRelease, code, modifiers, text);
    QApplication::sendEvent(target, &press);
    if (target) QApplication::sendEvent(target, &release);
    else qInfo("Qt grid key target retired during press (class=%s key=%d)", kind.constData(), code);
    QApplication::processEvents();
}

inline void click(QWidget *widget) {
    if (widget && (!widget->isVisible() || !widget->isEnabled())) {
        qWarning() << "unavailable grid control" << widget->metaObject()->className() << widget->accessibleName()
            << widget->property("text") << widget->isVisible() << widget->isEnabled();
        if (auto *sheet = widget->window()) {
            for (auto *edit : sheet->findChildren<QLineEdit *>()) if (edit->isVisible())
                qWarning() << "grid field" << edit->placeholderText() << edit->text();
            for (auto *label : sheet->findChildren<QLabel *>()) if (label->isVisible()
                && (label->text().startsWith("A subdivision every") || label->text().startsWith("Use gridlines every")))
                qWarning() << "grid hint" << label->text();
        }
    }
    require(widget && widget->isVisible() && widget->isEnabled(), "grid control is unavailable");
    const QPointF point = widget->rect().center(), global = widget->mapToGlobal(point.toPoint());
    QMouseEvent press(QEvent::MouseButtonPress, point, global, Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
    QMouseEvent release(QEvent::MouseButtonRelease, point, global, Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
    QApplication::sendEvent(widget, &press); QApplication::sendEvent(widget, &release);
    QApplication::processEvents();
}

inline QLineEdit *field(QDialog *sheet, const QString &name) {
    for (auto *edit : sheet->findChildren<QLineEdit *>())
        if (edit->isVisible() && (edit->accessibleName() == name || edit->placeholderText() == name)) return edit;
    qWarning() << "missing grid field" << name;
    for (auto *edit : sheet->findChildren<QLineEdit *>()) qWarning() << edit->accessibleName() << edit->placeholderText();
    throw std::runtime_error("grid field missing");
}

inline QPushButton *button(QDialog *sheet, const QString &name) {
    for (auto *item : sheet->findChildren<QPushButton *>()) if (item->isVisible() && item->text() == name) return item;
    throw std::runtime_error("grid button missing");
}

inline QComboBox *picker(QDialog *sheet, const QString &member) {
    for (auto *item : sheet->findChildren<QComboBox *>()) if (item->isVisible() && item->findText(member) >= 0) return item;
    throw std::runtime_error("grid picker missing");
}

inline void type(QDialog *sheet, const QString &name, const QString &text) {
    QPointer<QLineEdit> edit = field(sheet, name); edit->setFocus();
    key(edit, Qt::Key_A, Qt::ControlModifier);
    for (const auto &character : text) {
        require(edit, "grid typing replaced its field");
        key(edit, 0, Qt::NoModifier, QString(character));
    }
    require(edit && QApplication::focusWidget() == edit && edit->text() == text && edit->cursorPosition() == text.size(),
        "grid typing lost text, focus or cursor");
}

inline void choose(QDialog *sheet, const QString &member, const QString &value) {
    QPointer<QComboBox> combo = picker(sheet, member); const int index = combo->findText(value);
    require(index >= 0, "grid picker value missing");
    combo->setFocus(); require(combo && combo->isVisible(), "grid picker retired during focus change");
    combo->showPopup(); require(combo, "grid picker retired while opening");
    QPointer<QAbstractItemView> list = combo->view(); require(list && list->isVisible(), "grid picker popup missing");
    // Keyboard popup navigation must survive a panel tick without a platform mouse grab.
    if (auto *grabber = QWidget::mouseGrabber()) grabber->releaseMouse();
    require(list && list->isVisible(), "grid keyboard popup fixture closed without its mouse grab");
    QWidget *root = nullptr;
    for (auto *widget : sheet->findChildren<QWidget *>())
        if (widget->property("swiftUITree").isValid()) { root = widget; break; }
    require(root, "grid popup rendered owner missing");
    QWidget *next = swiftUIRenderPanelIfChanged(root->property("swiftUIHandle").toULongLong(), "GridSettingsSheet", root);
    if (next != root) {
        delete next;
        throw std::runtime_error("grid popup refresh replaced its owning controls");
    }
    QApplication::processEvents();
    require(combo && list && list->isVisible(), "grid popup retired during its event tick");
    key(list, Qt::Key_Home);
    for (int i = 0; i < index; ++i) { require(list && list->isVisible(), "grid picker popup disappeared during navigation"); key(list, Qt::Key_Down); }
    require(list && list->isVisible(), "grid picker popup disappeared before activation");
    key(list, Qt::Key_Return);
    pump([&] { return picker(sheet, member)->currentText() == value; }, "grid picker did not update");
}

inline int run(QApplication &app) {
    try {
        QTemporaryDir temporary; require(temporary.isValid(), "grid fixture directory unavailable");
        QImage source(64, 64, QImage::Format_RGBA8888); source.fill(QColor(32, 64, 96));
        const QString path = temporary.filePath("source.png"); require(source.save(path), "grid fixture write failed");
        SessionWindow window; window.resize(1100, 800); window.show();
        require(window.importImage(path), "grid fixture import failed");
        window.setTool(SessionWindow::Tool::Move);
        const auto before = window.sessionState();
        const auto pixels = [&] {
            const QString output = temporary.filePath("pixels.png");
            require(window.exportPNG(output), "grid source readback failed");
            QImage image(output); require(image.size() == source.size(), "grid source dimensions changed");
            return image.convertToFormat(QImage::Format_RGBA8888);
        };
        const QImage original = pixels();
        for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x)
            require(original.pixelColor(x, y) == source.pixelColor(x, y), "grid fixture pixels changed");
        const auto isolated = [&] {
            const auto state = window.sessionState();
            for (const char *name : {"layers", "activeLayerID", "modified", "undoName", "redoName", "canUndo", "canRedo",
                                     "foregroundColor", "backgroundColor", "hasSelection", "tool"})
                require(state.value(name) == before.value(name), "grid settings changed document, target, history or palette");
            require(pixels() == original, "grid settings changed stored pixels");
        };
        const auto menuItem = [&](const QStringList &path) {
            QList<QAction *> actions = window.menuBar()->actions(); QAction *chosen = nullptr;
            for (int i = 0; i < path.size(); ++i) {
                chosen = nullptr;
                for (auto *action : actions) if (action->text().remove('&') == path[i]) chosen = action;
                require(chosen && chosen->isVisible() && chosen->isEnabled(), "grid menu action missing or disabled");
                if (i + 1 < path.size()) {
                    require(chosen->menu(), "grid menu path is incomplete");
                    emit chosen->menu()->aboutToShow(); actions = chosen->menu()->actions();
                }
            }
            return chosen;
        };
        int opening = 0;
        const auto open = [&](const std::function<void(QDialog *)> &inspect) {
            qInfo("Qt grid settings opening %d", ++opening);
            bool inspected = false; QString failure; QTimer timer; timer.setInterval(10);
            QObject::connect(&timer, &QTimer::timeout, &window, [&] {
                auto *sheet = window.findChild<QDialog *>("swiftUISheet.GridSettingsSheet");
                if (!sheet || !sheet->isVisible()) return;
                timer.stop(); inspected = true;
                try {
                    QApplication::setActiveWindow(sheet);
                    require(window.sessionState().value("showsGrid").toBool(), "grid sheet did not show its preview"); inspect(sheet);
                }
                catch (const std::exception &error) {
                    failure = QString::fromUtf8(error.what()); qWarning() << "Grid inspection failed:" << failure; sheet->reject();
                }
            });
            timer.start(); menuItem({"View", "Grid Settings…"})->trigger();
            pump([&] { return inspected; }, "grid sheet did not open"); timer.stop();
            pump([&] {
                auto *sheet = window.findChild<QDialog *>("swiftUISheet.GridSettingsSheet");
                return !sheet || !sheet->isVisible();
            }, "grid sheet did not close");
            require(failure.isEmpty(), qPrintable(failure));
            require(window.sessionState().value("showsGrid") == before.value("showsGrid"), "grid finish lost previous visibility");
            isolated();
        };
        const auto custom = [&](QDialog *sheet) {
            type(sheet, "Gridline every", "24"); type(sheet, "Subdivisions", "3");
            choose(sheet, "Black", "Black"); choose(sheet, "Lines", "Dashed Lines"); type(sheet, "Opacity", "75");
            pump([&] {
                if (!button(sheet, "OK")->isEnabled()) return false;
                for (auto *label : sheet->findChildren<QLabel *>())
                    if (label->isVisible() && label->text().startsWith("A subdivision every 8 pixels")) return true;
                return false;
            }, "grid custom settings did not refresh validation");
        };
        const auto settings = [&](QDialog *sheet, bool defaults) {
            if (field(sheet, "Gridline every")->text() != (defaults ? "64" : "24"))
                qWarning() << "grid reopen spacing" << "opening" << opening << "actual" << field(sheet, "Gridline every")->text()
                    << "expected" << (defaults ? "64" : "24");
            require(field(sheet, "Gridline every")->text() == (defaults ? "64" : "24"), "grid spacing did not restore or persist");
            require(field(sheet, "Subdivisions")->text() == (defaults ? "8" : "3"), "grid subdivisions did not restore or persist");
            require(field(sheet, "Opacity")->text() == (defaults ? "45" : "75"), "grid opacity did not restore or persist");
            require(picker(sheet, "Black")->currentText() == (defaults ? "Light Gray" : "Black"), "grid preset did not restore or persist");
            require(picker(sheet, "Lines")->currentText() == (defaults ? "Lines" : "Dashed Lines"), "grid style did not restore or persist");
        };
        if (app.arguments().contains("--grid-settings-restart")) {
            open([&](QDialog *sheet) { settings(sheet, false); click(button(sheet, "Cancel")); });
            qInfo("Qt grid settings restart OK (spacing/subdivisions, color/style/opacity, actual separate-process persistence)");
            return 0;
        }
        open([&](QDialog *sheet) { custom(sheet); click(button(sheet, "OK")); });
        open([&](QDialog *sheet) {
            settings(sheet, false);
            const auto hint = [&]() -> QLabel * {
                for (auto *label : sheet->findChildren<QLabel *>())
                    if (label->isVisible() && (label->text().startsWith("A subdivision every") || label->text().startsWith("Use gridlines every"))) return label;
                throw std::runtime_error("grid validation hint missing");
            };
            const QString validStyle = hint()->styleSheet();
            for (const QString &invalid : {QString("1"), QString("4097")}) {
                type(sheet, "Gridline every", invalid);
                pump([&] { return !button(sheet, "OK")->isEnabled(); }, "invalid grid spacing did not disable OK");
                pump([&] { return hint()->text().startsWith("Use gridlines every"); }, "invalid grid spacing did not update its hint");
                require(hint()->styleSheet() != validStyle && hint()->wordWrap(), "grid invalid hint lost its warning style or wrapping");
            }
            type(sheet, "Gridline every", "24");
            for (const QString &invalid : {QString("0"), QString("65"), QString("25")}) {
                type(sheet, "Subdivisions", invalid);
                pump([&] { return !button(sheet, "OK")->isEnabled(); }, "invalid grid subdivision did not disable OK");
                require(hint()->text().startsWith("Use gridlines every"), "invalid grid subdivisions did not update their hint");
            }
            type(sheet, "Subdivisions", "3");
            pump([&] { return button(sheet, "OK")->isEnabled(); }, "valid grid settings did not restore OK");
            pump([&] { return hint()->text().contains("every 8 pixels"); }, "valid grid settings did not restore their hint");
            type(sheet, "Gridline every", "32"); type(sheet, "Subdivisions", "4"); click(button(sheet, "Cancel"));
        });
        open([&](QDialog *sheet) {
            settings(sheet, false); click(button(sheet, "Restore Defaults"));
            pump([&] { return field(sheet, "Gridline every")->text() == "64"; }, "grid defaults did not update");
            settings(sheet, true); click(button(sheet, "Cancel"));
        });
        open([&](QDialog *sheet) { settings(sheet, false); click(button(sheet, "Restore Defaults")); click(button(sheet, "OK")); });
        open([&](QDialog *sheet) { settings(sheet, true); custom(sheet); click(button(sheet, "OK")); });
        compositor_flush_preferences();
        qInfo("Qt grid settings controls OK (visible menu, typed spacing/subdivisions and validity recovery, color/style keys, opacity, Cancel/OK, Restore Defaults Cancel/OK, reopen and exact document/history/palette isolation)");
        return 0;
    } catch (const std::exception &error) {
        qCritical("Qt grid settings controls failed: %s", error.what()); return 1;
    }
}
} // namespace gridsettingsjourney
