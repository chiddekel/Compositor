#pragma once

// Opt-in observation bridge for the desktop E2E driver. Input always comes through X11/XTest;
// this bridge exposes widget geometry, session state and image artifacts, never editor commands.
#include "SessionWindow.h"
#include <QAbstractButton>
#include <QAction>
#include <QApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QLabel>
#include <QKeyEvent>
#include <QShortcutEvent>
#include <QLineEdit>
#include <QSaveFile>
#include <QScreen>
#include <QThread>
#include <QTabBar>
#include <QTimer>

class UIE2EInputObserver : public QObject {
public:
    explicit UIE2EInputObserver(QObject *parent) : QObject(parent) {}
    quint64 presses = 0, releases = 0;
    QJsonArray keys;
    bool eventFilter(QObject *target, QEvent *event) override {
        if (event->type() == QEvent::MouseButtonPress) ++presses;
        if (event->type() == QEvent::MouseButtonRelease) ++releases;
        if (event->type() == QEvent::KeyPress || event->type() == QEvent::Shortcut) {
            QJsonObject key{{"target", target->metaObject()->className()}, {"type", int(event->type())}};
            if (event->type() == QEvent::KeyPress) {
                auto *e = static_cast<QKeyEvent *>(event);
                key["key"] = e->key(); key["modifiers"] = int(e->modifiers());
            } else key["shortcut"] = static_cast<QShortcutEvent *>(event)->key().toString();
            keys.append(key);
            if (keys.size() > 30) keys.removeFirst();
        }
        return false;
    }
};

inline void installUIE2EBridge(SessionWindow &window) {
    const QString directory = qEnvironmentVariable("COMPOSITOR_UI_E2E_DIR");
    if (directory.isEmpty()) return;
    if (!QDir(directory).exists()) qFatal("UI E2E artifact directory does not exist");
    // The private test desktop has no portal service contract; exercise Qt's visible file dialogs consistently.
    QCoreApplication::setAttribute(Qt::AA_DontUseNativeDialogs, true);
    window.resize(1440, 900);
    // A negative-control run must fail the trajectory checks with input compression restored.
    if (qEnvironmentVariableIsSet("COMPOSITOR_UI_E2E_COMPRESS_INPUT"))
        QCoreApplication::setAttribute(Qt::AA_CompressHighFrequencyEvents, true);
    auto *input = new UIE2EInputObserver(&window);
    qApp->installEventFilter(input);
    auto *timer = new QTimer(&window);
    timer->setInterval(10);
    QObject::connect(timer, &QTimer::timeout, &window, [&window, directory, input] {
        QFile requestFile(directory + "/request.json");
        if (!requestFile.exists() || !requestFile.open(QIODevice::ReadOnly)) return;
        const QJsonObject request = QJsonDocument::fromJson(requestFile.readAll()).object();
        requestFile.close();
        requestFile.remove();
        QJsonObject reply{{"id", request.value("id")}, {"ok", true}};
        const QString action = request.value("action").toString();
        if (action == "inspect") {
            reply["state"] = window.sessionState();
            reply["platform"] = QGuiApplication::platformName();
            reply["windowID"] = qint64(window.winId());
            reply["pointerPresses"] = qint64(input->presses);
            reply["pointerReleases"] = qint64(input->releases);
            reply["recentKeys"] = input->keys;
            reply["compressInput"] = QCoreApplication::testAttribute(Qt::AA_CompressHighFrequencyEvents);
            reply["activeWindow"] = window.isActiveWindow();
            QJsonArray actions;
            for (QAction *action : window.findChildren<QAction *>()) {
                if (action->shortcut().isEmpty()) continue;
                actions.append(QJsonObject{{"text", action->text()}, {"shortcut", action->shortcut().toString()},
                    {"enabled", action->isEnabled()}});
            }
            reply["actions"] = actions;
            QJsonArray widgets;
            for (QWidget *widget : QApplication::allWidgets()) {
                if (!widget->isVisible() || widget->width() <= 0 || widget->height() <= 0) continue;
                const QPoint origin = widget->mapToGlobal(QPoint());
                QJsonObject item{{"class", widget->metaObject()->className()}, {"name", widget->objectName()},
                    {"label", widget->accessibleName()}, {"help", widget->toolTip()},
                    {"enabled", widget->isEnabled()}, {"focused", widget->hasFocus()},
                    {"windowID", qint64(widget->window()->winId())},
                    {"rect", QJsonArray{origin.x(), origin.y(), widget->width(), widget->height()}}};
                QStringList ancestors;
                for (QWidget *parent = widget->parentWidget(); parent; parent = parent->parentWidget())
                    if (!parent->objectName().isEmpty()) ancestors << parent->objectName();
                item["ancestors"] = QJsonArray::fromStringList(ancestors);
                if (auto *field = qobject_cast<QLineEdit *>(widget)) {
                    item["kind"] = "field"; item["text"] = field->text();
                    item["selected"] = field->selectedText();
                    item["placeholder"] = field->placeholderText();
                } else if (auto *button = qobject_cast<QAbstractButton *>(widget)) {
                    item["kind"] = "button"; item["text"] = button->text();
                    item["checked"] = button->isChecked();
                } else if (auto *label = qobject_cast<QLabel *>(widget)) {
                    item["kind"] = "label"; item["text"] = label->text();
                } else if (auto *tabs = qobject_cast<QTabBar *>(widget)) {
                    QJsonArray names;
                    for (int i = 0; i < tabs->count(); ++i) names.append(tabs->tabText(i));
                    item["tabs"] = names; item["currentTab"] = tabs->currentIndex();
                }
                widgets.append(item);
            }
            reply["widgets"] = widgets;
            if (QWidget *canvas = window.findChild<QWidget *>("editorCanvas")) {
                const QPoint origin = canvas->mapToGlobal(QPoint());
                const QPointF zero = window.documentToCanvasPoint(QPointF(0, 0)) + origin;
                const QPointF unit = window.documentToCanvasPoint(QPointF(1, 1)) + origin;
                reply["canvasMapping"] = QJsonArray{zero.x(), zero.y(), unit.x()-zero.x(), unit.y()-zero.y()};
            }
        } else if (action == "capture" || action == "export") {
            // Keep every output in the test's private artifact directory.
            const QString name = request.value("name").toString();
            if (name.isEmpty() || name != QFileInfo(name).fileName() || !name.endsWith(".png")) {
                reply["ok"] = false; reply["error"] = "Expected a PNG filename";
            } else {
                const QString path = directory + "/" + name;
                reply["ok"] = action == "export" ? window.exportPNG(path)
                    : QGuiApplication::primaryScreen()->grabWindow(0).save(path);
                reply["path"] = path;
            }
        } else if (action == "triggerAction") {
            // Activate a QAction by its menu title (same objects the menubar / AppMenus sync owns).
            const QString title = request.value("text").toString();
            bool found = false;
            for (QAction *act : window.findChildren<QAction *>()) {
                if (act->text() == title && act->isEnabled()) {
                    act->trigger();
                    found = true;
                    break;
                }
            }
            reply["ok"] = found;
            if (!found) reply["error"] = "No enabled action titled " + title;
        } else if (action == "stall") {
            // Simulate a busy UI while the independent driver queues real desktop pointer events.
            // Publish the acknowledgement first so the driver knows when the stall begins.
            QSaveFile response(directory + "/response.json");
            if (!response.open(QIODevice::WriteOnly)) qFatal("UI E2E response write failed");
            response.write(QJsonDocument(reply).toJson());
            if (!response.commit()) qFatal("UI E2E response commit failed");
            QThread::msleep(qBound(0, request.value("milliseconds").toInt(), 1000));
            return;
        } else {
            reply["ok"] = false; reply["error"] = "Unknown observation request";
        }
        QSaveFile response(directory + "/response.json");
        if (!response.open(QIODevice::WriteOnly)) qFatal("UI E2E response write failed");
        response.write(QJsonDocument(reply).toJson());
        if (!response.commit()) qFatal("UI E2E response commit failed");
    });
    timer->start();
}
