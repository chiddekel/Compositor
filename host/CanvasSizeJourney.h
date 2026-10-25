#pragma once

#include "SessionWindow.h"
#include <QAction>
#include <QApplication>
#include <QAbstractItemView>
#include <QCheckBox>
#include <QComboBox>
#include <QDialog>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QJsonArray>
#include <QKeyEvent>
#include <QLabel>
#include <QLineEdit>
#include <QMenu>
#include <QMenuBar>
#include <QMouseEvent>
#include <QPointer>
#include <QPushButton>
#include <QTemporaryDir>
#include <QThread>
#include <QTimer>
#include <QDebug>
#include <cmath>
#include <functional>
#include <stdexcept>

namespace canvassizejourney {
inline void require(bool ok, const char *message) { if (!ok) throw std::runtime_error(message); }
inline void pump(const std::function<bool()> &ready, const char *message) {
    QElapsedTimer timer; timer.start();
    while (!ready() && timer.elapsed() < 5000) { QApplication::processEvents(QEventLoop::AllEvents, 10); QThread::msleep(1); }
    require(ready(), message);
}
inline void key(QWidget *widget, int code, Qt::KeyboardModifiers modifiers = Qt::NoModifier, const QString &text = {}) {
    QPointer<QWidget> target(widget); require(target, "canvas size key target missing");
    QKeyEvent press(QEvent::KeyPress, code, modifiers, text), release(QEvent::KeyRelease, code, modifiers, text);
    QApplication::sendEvent(target, &press); if (target) QApplication::sendEvent(target, &release);
    QApplication::processEvents();
}
inline void click(QWidget *widget) {
    require(widget && widget->isVisible() && widget->isEnabled(), "canvas size control unavailable");
    QPointer<QWidget> target(widget); const QPointF point = widget->rect().center(), global = widget->mapToGlobal(point.toPoint());
    QMouseEvent press(QEvent::MouseButtonPress, point, global, Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
    QMouseEvent release(QEvent::MouseButtonRelease, point, global, Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
    QApplication::sendEvent(target, &press); if (target) QApplication::sendEvent(target, &release);
    QApplication::processEvents();
}
inline QLineEdit *field(QDialog *sheet, const QString &title) {
    for (auto *widget : sheet->findChildren<QLineEdit *>())
        if (widget->isVisible() && (widget->accessibleName() == title || widget->placeholderText() == title)) return widget;
    throw std::runtime_error("canvas size field missing");
}
inline QPushButton *button(QDialog *sheet, const QString &title) {
    for (auto *widget : sheet->findChildren<QPushButton *>())
        if (widget->isVisible() && (widget->text() == title || widget->accessibleName() == title)) return widget;
    throw std::runtime_error("canvas size button missing");
}
inline QCheckBox *toggle(QDialog *sheet, const QString &title) {
    for (auto *widget : sheet->findChildren<QCheckBox *>()) if (widget->isVisible() && widget->text() == title) return widget;
    throw std::runtime_error("canvas size toggle missing");
}
inline void type(QDialog *sheet, const QString &title, const QString &value) {
    QPointer<QLineEdit> edit = field(sheet, title);
    QStringList trace;
    QString stage = "before focus";
    const auto record = [&](const QString &event) {
        if (trace.size() >= 48) return;
        trace.append(QString("%1 / %2: text=%3 selection=%4,%5 cursor=%6 focus=%7 typed=%8")
            .arg(stage, event, edit ? edit->text() : QString())
            .arg(edit ? edit->selectionStart() : -1).arg(edit ? edit->selectedText().size() : 0)
            .arg(edit ? edit->cursorPosition() : -1).arg(edit && edit->hasFocus())
            .arg(edit && edit->property("swiftuiTyped").toBool()));
    };
    struct TraceObserver : QObject {
        std::function<void(QEvent *)> observe;
        bool eventFilter(QObject *, QEvent *event) override { observe(event); return false; }
    } observer;
    observer.observe = [&](QEvent *event) {
        if (event->type() == QEvent::FocusIn) record("focus in");
        else if (event->type() == QEvent::FocusOut) record("focus out");
        else if (event->type() == QEvent::InputMethod) record("input method");
    };
    edit->installEventFilter(&observer);
    QObject::connect(edit, &QLineEdit::selectionChanged, &observer, [&] { record("selection changed"); });
    QObject::connect(edit, &QLineEdit::textChanged, &observer, [&] { record("text changed"); });
    record("snapshot"); edit->setFocus(); record("focused");
    stage = "select all"; key(edit, Qt::Key_A, Qt::ControlModifier); record("after key");
    int index = 0;
    for (const auto character : value) {
        require(edit, "canvas size typing retired its field");
        stage = QString("character %1").arg(index++);
        key(edit, 0, Qt::NoModifier, QString(character)); record("after key");
    }
    const bool valid = edit && edit->text() == value && edit->hasFocus() && edit->cursorPosition() == value.size();
    if (!valid || qEnvironmentVariableIsSet("COMPOSITOR_TRACE_SIZE_FIELDS"))
        qWarning().noquote() << "Canvas size typing trace" << title << trace.join("\n");
    if (!valid)
        qWarning() << "Canvas size typing state" << title << "expected" << value
            << "actual" << (edit ? edit->text() : QString())
            << "focused" << (edit && edit->hasFocus()) << "cursor" << (edit ? edit->cursorPosition() : -1);
    require(edit && edit->text() == value && edit->hasFocus() && edit->cursorPosition() == value.size(),
        "canvas size typing lost text, focus or cursor");
}
inline bool hint(QDialog *sheet, const QString &text) {
    for (auto *label : sheet->findChildren<QLabel *>()) if (label->isVisible() && label->text().contains(text)) return true;
    return false;
}
inline void units(QDialog *sheet, int index) {
    QPointer<QComboBox> combo;
    for (auto *widget : sheet->findChildren<QComboBox *>()) if (widget->isVisible() && widget->findText("Pixels") >= 0) combo = widget;
    require(combo, "canvas units picker missing"); combo->setFocus(); combo->showPopup();
    QPointer<QAbstractItemView> view = combo->view(); require(view && view->isVisible(), "canvas units popup missing");
    key(view, Qt::Key_Home);
    for (int i = 0; i < index; ++i) { require(view, "canvas units popup retired"); key(view, Qt::Key_Down); }
    require(view, "canvas units popup retired before Return"); key(view, Qt::Key_Return);
}
inline int run(QApplication &) {
    try {
        QTemporaryDir temporary; require(temporary.isValid(), "canvas size fixture directory missing");
        QImage fixture(64, 48, QImage::Format_RGBA8888);
        for (int y = 0; y < 48; ++y) for (int x = 0; x < 64; ++x)
            fixture.setPixelColor(x, y, QColor((17 + x * 3) % 256, (29 + y * 5) % 256, (41 + x + y) % 256, y < 24 ? 128 : 255));
        const QString input = temporary.filePath("source.png"); require(fixture.save(input), "canvas size fixture save failed");
        SessionWindow window; window.resize(1200, 900); window.show(); QApplication::setActiveWindow(&window);
        require(window.importImage(input), "canvas size fixture import failed"); window.setTool(SessionWindow::Tool::Move);
        const auto command = [&](QJsonObject value) { require(window.sendCommand(value), "canvas size bridge setup/history failed"); QApplication::processEvents(); };
        command({{"action", "setShowsTransformControls"}, {"enabled", false}});
        command({{"action", "resizeImage"}, {"width", 64}, {"height", 48}, {"value", 100}, {"kind", "Nearest"}});
        auto *zoomIn = window.findChild<QAction *>("view.zoomIn");
        require(zoomIn && zoomIn->isEnabled(), "canvas size zoom fixture action missing");
        zoomIn->trigger(); QApplication::processEvents();
        require(window.sessionState().value("zoom").toDouble() != 1, "canvas size zoom fixture stayed at 100 percent");
        const auto pixels = [&]() {
            const QString path = temporary.filePath("pixels.png"); require(window.exportPNG(path), "canvas size pixel readback failed");
            QImage image(path); require(!image.isNull(), "canvas size readback missing"); return image.convertToFormat(QImage::Format_RGBA8888);
        };
        const auto originalState = window.sessionState(); const QImage original = pixels();
        require(original.size() == QSize(64, 48) && originalState.value("resolution").toDouble() == 100,
            "canvas size source dimensions/DPI differ");
        const QStringList anchors{"Top left", "Top center", "Top right", "Middle left", "Center", "Middle right", "Bottom left", "Bottom center", "Bottom right"};
        const QStringList unitNames{"Pixels", "Percent", "Inches", "Centimeters"};
        const auto open = [&](const std::function<void(QDialog *)> &inspect) {
            bool inspected = false; QString failure; QTimer timer; timer.setInterval(10);
            QObject::connect(&timer, &QTimer::timeout, &window, [&] {
                auto *sheet = window.findChild<QDialog *>("swiftUISheet.CanvasSizeSheet");
                if (!sheet || !sheet->isVisible()) return;
                timer.stop(); inspected = true;
                try { QApplication::setActiveWindow(sheet); inspect(sheet); }
                catch (const std::exception &error) { failure = QString::fromUtf8(error.what()); qWarning() << "Canvas size inspection failed:" << failure; click(button(sheet, "Cancel")); }
            });
            QAction *action = nullptr;
            for (auto *top : window.menuBar()->actions()) if (top->isVisible() && top->menu() && top->menu()->objectName() == "appMenu.Image") {
                emit top->menu()->aboutToShow();
                for (auto *item : top->menu()->actions()) if (item->isVisible() && item->text().remove('&') == "Canvas Size…") action = item;
            }
            require(action && action->isEnabled(), "visible Canvas Size action missing or disabled"); timer.start(); action->trigger();
            pump([&] { return inspected; }, "canvas size sheet did not open"); timer.stop();
            pump([&] { const auto state = window.sessionState(); return !state.value("busy").toBool() && state.value("sheets").toArray().isEmpty(); }, "canvas size sheet did not finish");
            require(failure.isEmpty(), qPrintable(failure));
        };
        const auto stateUnchanged = [&](const QJsonObject &before, bool ready = true) {
            const auto state = window.sessionState();
            for (const char *name : {"layers", "activeLayerID", "foregroundColor", "backgroundColor", "tool", "modified", "undoName", "redoName", "width", "height", "resolution"}) {
                if (state.value(name) != before.value(name)) qWarning() << "canvas size state changed" << name << before.value(name) << state.value(name);
                require(state.value(name) == before.value(name), "canvas size preview/Cancel changed document or history");
            }
            if (ready) for (const char *name : {"canUndo", "canRedo"})
                require(state.value(name) == before.value(name), "canvas size Cancel lost history readiness");
        };
        open([&](QDialog *sheet) {
            require(field(sheet, "Width")->text().toDouble() == 64 && field(sheet, "Height")->text().toDouble() == 48,
                "canvas size initial fields differ");
            for (const QString &invalid : {QString("0"), QString("30001")}) {
                type(sheet, "Width", invalid);
                pump([&] { return !button(sheet, "OK")->isEnabled(); }, "canvas size invalid width did not disable OK while focused");
                require(hint(sheet, "Final dimensions must"), "canvas size invalid width did not update its warning");
            }
            type(sheet, "Width", "95");
            pump([&] { return button(sheet, "OK")->isEnabled() && hint(sheet, "95 × 48 pixels"); }, "canvas size valid width did not update its hint while focused");
            click(toggle(sheet, "Lock original aspect ratio"));
            type(sheet, "Width", "96");
            pump([&] { return field(sheet, "Height")->text().toDouble() == 72 && hint(sheet, "96 × 72 pixels"); }, "canvas size locked height did not update while width retained focus");
            click(toggle(sheet, "Lock original aspect ratio")); click(toggle(sheet, "Relative to current dimensions"));
            type(sheet, "Width", "31"); type(sheet, "Height", "17");
            pump([&] { return hint(sheet, "95 × 65 pixels"); }, "canvas size relative hint did not update while focused");
            stateUnchanged(originalState, false); require(pixels() == original, "canvas size draft changed pixels"); click(button(sheet, "Cancel"));
        });
        stateUnchanged(originalState); require(pixels() == original, "canvas size Cancel changed source pixels");
        qInfo("Qt Canvas Size live controls OK (focused validation/hints, ratio sibling, relative dimensions, exact Cancel isolation)");
        const auto oracle = [&](QSize size, QPoint offset) {
            QImage image(size, QImage::Format_RGBA8888); image.fill(Qt::transparent);
            for (int y = 0; y < 48; ++y) for (int x = 0; x < 64; ++x)
                if (image.rect().contains(QPoint(x, y) + offset)) image.setPixelColor(QPoint(x, y) + offset, original.pixelColor(x, y));
            return image;
        };
        const auto apply = [&](QSize size, int anchor, int unit) {
            const auto before = window.sessionState();
            open([&](QDialog *sheet) {
                require(!toggle(sheet, "Relative to current dimensions")->isChecked() && !toggle(sheet, "Lock original aspect ratio")->isChecked(),
                    "canvas size reopened stale draft flags");
                units(sheet, unit);
                const auto value = [&](int count, int old) {
                    double number = count;
                    if (unit == 1) number = double(count) / old * 100;
                    if (unit == 2) number = count / 100.0;
                    if (unit == 3) number = count / 100.0 * 2.54;
                    return QString::number(number, 'f', 8);
                };
                type(sheet, "Width", value(size.width(), before.value("width").toInt()));
                type(sheet, "Height", value(size.height(), before.value("height").toInt()));
                click(button(sheet, anchors[anchor])); click(button(sheet, "OK"));
            });
            pump([&] { return window.sessionState().value("width").toInt() == size.width() && window.sessionState().value("height").toInt() == size.height(); }, "canvas size commit dimensions differ");
            require(window.sessionState().value("zoom") == before.value("zoom"), "Canvas Size changed the zoom");
            require(window.sessionState().value("activeLayerID") == originalState.value("activeLayerID")
                && window.sessionState().value("layers").toArray().size() == 1, "canvas size changed layer identity/count");
        };
        const auto checkImage = [&](const QImage &expected, const char *message) {
            const QImage actual = pixels(); require(actual.size() == expected.size(), message);
            for (int y = 0; y < actual.height(); ++y) for (int x = 0; x < actual.width(); ++x)
                require(actual.pixelColor(x, y) == expected.pixelColor(x, y), message);
        };
        for (int unit = 0; unit < 4; ++unit) for (int anchor = 0; anchor < 9; ++anchor) {
            const QPoint offset(int(std::floor(31.0 * (anchor % 3) / 2)), int(std::floor(17.0 * (anchor / 3) / 2)));
            apply(QSize(95, 65), anchor, unit); const auto committed = window.sessionState().value("layers");
            const QImage expected = oracle(QSize(95, 65), offset); checkImage(expected, "canvas unit/anchor pixels differ from independent translation");
            command({{"action", "undo"}}); require(window.sessionState().value("layers") == originalState.value("layers"), "canvas size Undo changed source records");
            checkImage(original, "canvas size single Undo failed"); command({{"action", "redo"}});
            require(window.sessionState().value("layers") == committed, "canvas size Redo changed committed records"); checkImage(expected, "canvas size single Redo failed");
            command({{"action", "undo"}});
            qInfo("Qt Canvas Size units/anchor OK (unit=%s anchor=%s, odd-delta floor translation, every pixel, retained identity and single Undo/Redo)", qPrintable(unitNames[unit]), qPrintable(anchors[anchor]));
        }
        for (int anchor = 0; anchor < 9; ++anchor) {
            const QPoint crop(int(std::floor(-11.0 * (anchor % 3) / 2)), int(std::floor(-11.0 * (anchor / 3) / 2)));
            apply(QSize(53, 37), anchor, 0); checkImage(oracle(QSize(53, 37), crop), "canvas crop anchor pixels differ");
            const QPoint expand(int(std::floor(13.0 * (anchor % 3) / 2)), int(std::floor(13.0 * (anchor / 3) / 2)));
            apply(QSize(66, 50), anchor, 0); checkImage(oracle(QSize(66, 50), crop + expand), "canvas re-expansion lost cropped source pixels");
            command({{"action", "undo"}}); checkImage(oracle(QSize(53, 37), crop), "canvas re-expansion Undo failed");
            command({{"action", "undo"}}); checkImage(original, "canvas crop Undo failed");
            require(window.sessionState().value("layers") == originalState.value("layers"), "canvas crop/re-expand changed source records");
            qInfo("Qt Canvas Size crop/re-expand OK (anchor=%s, retained outside-canvas artwork, all-pixel oracle and separate Undo steps)", qPrintable(anchors[anchor]));
        }
        return 0;
    } catch (const std::exception &error) { qCritical("Qt Canvas Size failed: %s", error.what()); return 1; }
}
} // namespace canvassizejourney
