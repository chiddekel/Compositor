// `--ui-audit-probe`: every upstream view the shell draws, opened in one process and checked for what behavior tests
// cannot see — text cut short, buttons with nothing on them, symbols with no picture — plus the specific shapes of the
// 2026-10-18 audit's gaps (New Canvas presets, Camera Raw scope, Color Range eyedroppers). Findings print one per line
// and are written as JSON to $COMPOSITOR_UI_AUDIT_REPORT when it is set. Known, reasoned exceptions live in
// linux/ui-audit-allow.json (read from the working directory, or $COMPOSITOR_UI_AUDIT_ALLOW); anything else fails the gate.
#pragma once

#include "SessionWindow.h"
#include "SwiftUIQtRenderer.h"
#include "UIAudit.h"
#include <QAction>
#include <QApplication>
#include <QDialog>
#include <QFileDialog>
#include <QMessageBox>
#include <QElapsedTimer>
#include <QFile>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QKeyEvent>
#include <QLineEdit>
#include <QMenu>
#include <QMenuBar>
#include <QPainter>
#include <QPointer>
#include <QPushButton>
#include <QSet>
#include <QTemporaryDir>
#include <QThread>
#include <QTimer>
#include <QDebug>
#include <functional>
#include <stdexcept>

namespace uiauditjourney {

inline void require(bool ok, const char *message) {
    if (!ok) throw std::runtime_error(message);
}

inline void settle(int milliseconds = 120) {
    QElapsedTimer clock; clock.start();
    while (clock.elapsed() < milliseconds) { QApplication::processEvents(QEventLoop::AllEvents, 10); QThread::msleep(2); }
}

inline bool waitFor(const std::function<bool()> &ready, int milliseconds = 5000) {
    QElapsedTimer clock; clock.start();
    while (!ready() && clock.elapsed() < milliseconds) { QApplication::processEvents(QEventLoop::AllEvents, 10); QThread::msleep(1); }
    return ready();
}

/// A finding is reported once, at the first place it was seen.
struct Findings {
    QJsonArray list;
    QSet<QString> seen;
    QJsonArray allow;
    void merge(const QJsonArray &found) {
        for (const auto &value : found) {
            const QJsonObject finding = value.toObject();
            const QString key = finding.value("kind").toString() + '\x1f' + finding.value("path").toString() + '\x1f'
                + finding.value("text").toString();
            if (seen.contains(key) || allowed(finding)) continue;
            seen.insert(key);
            list.append(finding);
        }
    }
    void gap(const QString &where, const QString &text) {
        merge(QJsonArray{QJsonObject{{"where", where}, {"kind", "gap"}, {"path", ""}, {"text", text}, {"needed", 0}, {"available", 0}}});
    }
    bool allowed(const QJsonObject &finding) const {
        for (const auto &value : allow) {
            const QJsonObject rule = value.toObject();
            if (rule.value("kind").toString() != finding.value("kind").toString()) continue;
            if (!finding.value("path").toString().contains(rule.value("path").toString())) continue;
            if (rule.contains("text") && rule.value("text").toString() != finding.value("text").toString()) continue;
            return true;
        }
        return false;
    }
};

/// Triggers a menu-bar item by its titles, as the grab hook does: a title with a slash in it spans two parts.
inline bool trigger(SessionWindow &window, const QStringList &parts) {
    for (QAction *top : window.menuBar()->actions()) {
        if (!top->isVisible() || !top->menu() || top->text().remove('&').trimmed() != parts.value(0)) continue;
        emit top->menu()->aboutToShow();
        QMenu *menu = top->menu();
        for (int level = 1; menu && level < parts.size(); ++level) {
            const auto titled = [&](const QString &title) -> QAction * {
                for (QAction *item : menu->actions())
                    if (QString(item->text()).replace(QStringLiteral("&&"), QStringLiteral("&")) == title) return item;
                return nullptr;
            };
            QString title = parts[level];
            while (!titled(title) && level + 1 < parts.size()) title += QLatin1Char('/') + parts[++level];
            QAction *item = titled(title);
            if (!item || !item->isEnabled()) return false;
            if (item->menu()) { emit item->menu()->aboutToShow(); menu = item->menu(); continue; }
            item->trigger();
            return true;
        }
    }
    return false;
}

inline QList<QDialog *> floatingPanels(SessionWindow &window) {
    QList<QDialog *> panels;
    for (QDialog *panel : window.findChildren<QDialog *>())
        if (panel->isVisible() && panel->objectName().startsWith(QLatin1String("floatingPanel."))) panels.append(panel);
    return panels;
}

inline QPushButton *button(QWidget *root, const QString &title) {
    if (root) for (QPushButton *candidate : root->findChildren<QPushButton *>())
        if (candidate->isVisible() && candidate->isEnabled() && candidate->text() == title) return candidate;
    return nullptr;
}

/// The New Canvas sheet's ⋯ preset menu: visible, with something drawn on it, listing upstream's presets, and a choice
/// writing the preset's pixels into Width and Height.
inline void checkPresets(SessionWindow &window, Findings &findings) {
    QAbstractButton *presets = nullptr;
    for (QAbstractButton *candidate : window.findChildren<QAbstractButton *>())
        if (candidate->isVisible() && (candidate->toolTip().startsWith(QLatin1String("Preset sizes"))
                                       || candidate->accessibleName() == QLatin1String("Preset sizes")))
            presets = candidate;
    if (!presets) { findings.gap("welcome", "New Canvas preset (⋯) button missing"); return; }
    if (presets->width() < 14 || presets->height() < 14) findings.gap("welcome", "New Canvas preset button too small to click");
    const QImage drawn = presets->grab().toImage();
    bool painted = false;
    for (int y = 0; y < drawn.height() && !painted; ++y)
        for (int x = 0; x < drawn.width() && !painted; ++x) painted = qGray(drawn.pixel(x, y)) > 140;
    if (!painted) findings.gap("welcome", "New Canvas preset button draws nothing (its ⋯ label is missing)");
    auto *menu = qobject_cast<QPushButton *>(presets) ? qobject_cast<QPushButton *>(presets)->menu() : nullptr;
    if (!menu) {
        for (QMenu *candidate : presets->findChildren<QMenu *>()) menu = candidate;
    }
    if (!menu) { findings.gap("welcome", "New Canvas preset button has no menu"); return; }
    emit menu->aboutToShow();
    QAction *square = nullptr;
    QStringList titles;
    for (QAction *action : menu->actions()) {
        if (action->isSeparator()) continue;
        titles << action->text();
        if (action->text() == QLatin1String("Instagram Square")) square = action;
    }
    if (!titles.contains(QLatin1String("Custom")) || !titles.contains(QLatin1String("4K")) || !square) {
        findings.gap("welcome", "New Canvas presets incomplete: " + titles.join(", "));
        return;
    }
    square->trigger();
    settle(300);
    QStringList values;
    for (QLineEdit *edit : window.findChildren<QLineEdit *>()) if (edit->isVisible()) values << edit->text();
    if (values.count(QStringLiteral("1080")) < 2) findings.gap("welcome", "choosing Instagram Square did not set 1080 × 1080: " + values.join(", "));
}

/// The Camera Raw column's histogram: upstream draws it the column's width and 110 points tall.
inline void checkCameraRawScope(QDialog *panel, Findings &findings) {
    QWidget *scope = nullptr;
    for (QWidget *candidate : panel->findChildren<QWidget *>())
        if (candidate->isVisible() && candidate->toolTip().startsWith(QLatin1String("Tones from black"))) scope = candidate;
    if (!scope) { findings.gap("Camera Raw", "histogram not found"); return; }
    // The column: the panel's widest ancestor of the histogram short of the panel itself.
    int column = 0;
    for (QWidget *w = scope->parentWidget(); w && w != panel; w = w->parentWidget()) column = qMax(column, w->width());
    if (column == 0) column = panel->width();
    if (scope->height() < 100 || scope->width() < column * 3 / 4)
        findings.gap("Camera Raw", QStringLiteral("histogram %1×%2, column %3 wide (upstream: column width × 110)")
                                       .arg(scope->width()).arg(scope->height()).arg(column));
    const QPoint top = scope->mapTo(panel, QPoint(0, 0));
    if (top.y() > 60) findings.gap("Camera Raw", QStringLiteral("empty band of %1 px above the histogram").arg(top.y()));
}

/// Color Range's three eyedroppers (Replace, Add, Remove) draw three different pictures.
inline void checkColorRangeEyedroppers(QDialog *panel, Findings &findings) {
    QList<QImage> pictures;
    for (QAbstractButton *candidate : panel->findChildren<QAbstractButton *>())
        if (candidate->isVisible() && !candidate->icon().isNull() && candidate->toolTip().contains(QLatin1String("yedropper"), Qt::CaseInsensitive))
            pictures << candidate->icon().pixmap(24, 24).toImage();
    if (pictures.size() < 3) {
        pictures.clear();
        for (QAbstractButton *candidate : panel->findChildren<QAbstractButton *>())
            if (candidate->isVisible() && !candidate->icon().isNull() && candidate->text().isEmpty()) pictures << candidate->icon().pixmap(24, 24).toImage();
    }
    if (pictures.size() < 3) { findings.gap("Color Range", QStringLiteral("%1 eyedropper buttons, expected 3").arg(pictures.size())); return; }
    if (pictures[0] == pictures[1] || pictures[1] == pictures[2] || pictures[0] == pictures[2])
        findings.gap("Color Range", "Add/Remove eyedroppers draw the same picture");
}

inline int run(QApplication &app) {
    Findings findings;
    try {
        QFile allowFile(qEnvironmentVariable("COMPOSITOR_UI_AUDIT_ALLOW", QStringLiteral("linux/ui-audit-allow.json")));
        if (allowFile.open(QIODevice::ReadOnly)) findings.allow = QJsonDocument::fromJson(allowFile.readAll()).array();
        QTemporaryDir temporary; require(temporary.isValid(), "UI audit directory unavailable");
        QImage source(320, 240, QImage::Format_RGBA8888);
        {
            QPainter painter(&source);
            QLinearGradient gradient(0, 0, 320, 240);
            gradient.setColorAt(0, QColor(20, 40, 200)); gradient.setColorAt(0.5, QColor(230, 200, 40)); gradient.setColorAt(1, QColor(200, 30, 60));
            painter.fillRect(source.rect(), gradient);
        }
        const QString path = temporary.filePath("audit.png");
        require(source.save(path), "UI audit fixture write failed");

        SessionWindow window; window.resize(1600, 1000); window.show(); QApplication::setActiveWindow(&window);
        swiftUIClearUnresolvedSymbols();
        settle(400);

        qInfo("UI audit step: welcome");
        // Documentless: the welcome New Canvas sheet.
        findings.merge([&] { QJsonArray found; uiaudit::auditTree(&window, "welcome", found); return found; }());
        checkPresets(window, findings);

        require(window.importImage(path), "UI audit fixture import failed");
        require(waitFor([&] { return window.sessionState().value("width").toInt() == 320 && !window.sessionState().value("busy").toBool(); }),
                "UI audit fixture did not open");
        auto *canvas = window.findChild<QWidget *>(QStringLiteral("editorCanvas"));
        require(canvas, "editor canvas missing");
        const auto audit = [&](QWidget *root, const QString &where) {
            qInfo().noquote() << "UI audit step:" << where;
            QJsonArray found; uiaudit::auditTree(root, where, found); findings.merge(found);
        };
        audit(&window, "document");

        // Every tool and tool mode: its options bar (and the rest of the window as it changes).
        const auto press = [&](int code, Qt::KeyboardModifiers modifiers, const QString &text) {
            QApplication::setActiveWindow(&window); canvas->setFocus();
            QKeyEvent down(QEvent::KeyPress, code, modifiers, text), up(QEvent::KeyRelease, code, modifiers, text);
            QApplication::sendEvent(canvas, &down); QApplication::sendEvent(canvas, &up);
            settle();
        };
        struct Key { int code; Qt::KeyboardModifiers modifiers; const char *text; const char *where; };
        const QList<Key> keys{
            {Qt::Key_V, {}, "v", "Move"}, {Qt::Key_M, {}, "m", "Marquee"}, {Qt::Key_M, {}, "m", "Marquee ellipse"},
            {Qt::Key_L, {}, "l", "Lasso"}, {Qt::Key_L, {}, "l", "Lasso polygonal"}, {Qt::Key_W, {}, "w", "Magic"},
            {Qt::Key_Tab, {}, "\t", "Magic object"}, {Qt::Key_C, {}, "c", "Crop"}, {Qt::Key_B, {}, "b", "Brush"},
            {Qt::Key_E, {}, "e", "Eraser"}, {Qt::Key_J, {}, "j", "Spot Healing"}, {Qt::Key_S, {}, "s", "Clone Stamp"},
            {Qt::Key_R, {}, "r", "Smear"}, {Qt::Key_G, {}, "g", "Gradient"}, {Qt::Key_U, {}, "u", "Shape"},
            {Qt::Key_U, Qt::ShiftModifier, "U", "Shape ellipse"}, {Qt::Key_U, Qt::ShiftModifier, "U", "Shape line"},
            {Qt::Key_T, {}, "t", "Type"}, {Qt::Key_I, {}, "i", "Eyedropper"}, {Qt::Key_H, {}, "h", "Hand"},
            {Qt::Key_Z, {}, "z", "Zoom"}, {Qt::Key_A, {}, "a", "No tool"}, {Qt::Key_V, {}, "v", "Move again"}};
        for (const Key &k : keys) { press(k.code, k.modifiers, QString::fromUtf8(k.text)); audit(&window, QString::fromUtf8(k.where)); }

        // Floating panels opened from the menus, checked, then cancelled.
        const auto panel = [&](const QStringList &item, const std::function<void(QDialog *)> &extra = {}) {
            const QString where = item.join(QStringLiteral(" › "));
            qInfo().noquote() << "UI audit open:" << where;
            if (!trigger(window, item)) { findings.gap(where, "menu item unavailable"); return; }
            QDialog *open = nullptr;
            if (!waitFor([&] { const auto panels = floatingPanels(window); open = panels.isEmpty() ? nullptr : panels.last(); return open != nullptr; })) {
                findings.gap(where, "no floating panel opened");
                return;
            }
            settle(600);
            audit(open, where);
            if (extra) extra(open);
            QPointer<QDialog> guard(open);
            if (QPushButton *cancel = button(open, QStringLiteral("Cancel"))) cancel->click(); else open->close();
            waitFor([&] { return !guard || !guard->isVisible(); });
            settle(200);
        };
        const QString ellipsis = QString::fromUtf8("…");
        for (const QString &item : {"Curves", "Levels", "Hue/Saturation", "Black & White", "Color Balance", "Exposure", "Gradient Map", "Grain"})
            panel({"Image", item + ellipsis});
        for (const QString &item : {"Gaussian Blur", "Motion Blur", "Progressive Blur", "Add Noise", "Vignette", "Bloom / Glow", "Dither",
                                    "Scanlines", "Tonal Contrast", "Lens Correction", "Remove Background"})
            panel({"Filter", item + ellipsis});
        panel({"Filter", "Camera Raw Filter" + ellipsis}, [&](QDialog *open) { checkCameraRawScope(open, findings); });
        panel({"Select", "Color Range" + ellipsis}, [&](QDialog *open) { checkColorRangeEyedroppers(open, findings); });
        panel({"Edit", "Keyboard Shortcuts" + ellipsis});

        // Modal sheets: checked from inside their own event loop, then cancelled.
        const auto sheet = [&](const QStringList &item) {
            const QString where = item.join(QStringLiteral(" › "));
            qInfo().noquote() << "UI audit sheet:" << where;
            bool seen = false;
            QTimer poll;
            poll.setInterval(100);
            QElapsedTimer clock; clock.start();
            qint64 seenAt = -1;
            QObject::connect(&poll, &QTimer::timeout, [&] {
                for (QWidget *top : QApplication::topLevelWidgets()) {
                    auto *dialog = qobject_cast<QDialog *>(top);
                    if (!dialog || !dialog->isVisible()) continue;
                    // Cancelling must not lead to an alert or a save panel: record one and close it.
                    if (auto *box = qobject_cast<QMessageBox *>(dialog)) {
                        findings.gap(where, "alert after Cancel: " + box->text());
                        box->reject();
                        return;
                    }
                    if (qobject_cast<QFileDialog *>(dialog)) {
                        findings.gap(where, "file panel after Cancel");
                        dialog->reject();
                        return;
                    }
                    if (seen || !dialog->objectName().startsWith(QLatin1String("swiftUISheet."))) continue;
                    if (clock.elapsed() < 800) return;   // let it lay out
                    seen = true;
                    seenAt = clock.elapsed();
                    QJsonArray found; uiaudit::auditTree(dialog, where, found); findings.merge(found);
                    if (QPushButton *cancel = button(dialog, QStringLiteral("Cancel"))) cancel->click(); else dialog->reject();
                    return;
                }
                // Keep watching a moment after Cancel for anything it opens.
                if ((seen && clock.elapsed() - seenAt > 1500) || clock.elapsed() > 8000) poll.stop();
            });
            poll.start();
            if (!trigger(window, item)) { poll.stop(); findings.gap(where, "menu item unavailable"); return; }
            waitFor([&] { return !poll.isActive(); }, 10000);
            poll.stop();
            if (!seen) findings.gap(where, "no sheet opened");
            settle(300);
        };
        sheet({"Image", "Canvas Size" + ellipsis});
        sheet({"Image", "Image Size" + ellipsis});
        sheet({"Image", "Trim" + ellipsis});
        sheet({"View", "Grid Settings" + ellipsis});
        // File › Export As is driven by the --save-smoke journey: its sheet runs a nested export wait this poller can't end.

        // Adjustment layers: each kind's row in the Layers list (its symbol thumbnail) and its editor.
        for (const QString &kind : {"Hue/Saturation", "Levels", "Curves", "Exposure", "Gradient Map", "Grain", "Add Noise",
                                    "Gaussian Blur", "Motion Blur", "Black & White", "Color Balance"})
            panel({"Layer", "New Adjustment Layer", kind + ellipsis});
        require(trigger(window, {"Layer", "New Adjustment Layer", "Invert"}), "Invert adjustment layer unavailable");
        settle(400);
        window.grab();   // draws every visible row, so the list asks for every adjustment symbol
        settle(200);
        audit(&window, "Layers with adjustment layers");

        // View › CMYK: each mode upstream shows as a pill at the canvas's foot, naming the profile, with a ×.
        if (trigger(window, {"View", "CMYK", "Proof Colors"}) && trigger(window, {"View", "CMYK", "Gamut Warning"})) {
            settle(400);
            const auto pill = [&](const char *name) { return window.findChild<QWidget *>(QString::fromLatin1(name)); };
            QWidget *proof = pill("proofBadge"), *gamut = pill("gamutBadge");
            const QString profile = window.sessionState().value("proofProfileName").toString();
            if (!proof || !proof->isVisible() || !gamut || !gamut->isVisible()) {
                findings.gap("View › CMYK", "Proof / Gamut Warning pills not shown on the canvas");
            } else {
                audit(proof, "CMYK Proof pill");
                audit(gamut, "CMYK Gamut Warning pill");
                const auto text = [&](QWidget *root, const char *part) {
                    auto *label = root->findChild<QLabel *>(root->objectName() + QLatin1String(part));
                    return label ? label->text() : QString();
                };
                if (text(proof, ".title") != QLatin1String("CMYK Proof") || text(gamut, ".title") != QLatin1String("CMYK Gamut Warning")
                    || text(proof, ".detail") != profile || profile.isEmpty())
                    findings.gap("View › CMYK", "pill titles/profile differ from upstream: " + text(proof, ".title") + " / " + text(proof, ".detail"));
                if (!(proof->geometry().bottom() < gamut->geometry().top()))
                    findings.gap("View › CMYK", "Proof pill is not stacked above the Gamut Warning pill");
                if (auto *close = proof->findChild<QAbstractButton *>(QStringLiteral("proofBadge.close"))) close->click();
                settle(300);
                if (window.sessionState().value("proofsColors").toBool() || proof->isVisible() || !gamut->isVisible())
                    findings.gap("View › CMYK", "the Proof pill's × did not stop proofing (leaving the gamut warning)");
                if (auto *close = gamut->findChild<QAbstractButton *>(QStringLiteral("gamutBadge.close"))) close->click();
                settle(300);
                if (window.sessionState().value("showsGamutWarning").toBool() || gamut->isVisible())
                    findings.gap("View › CMYK", "the Gamut Warning pill's × did not hide the warning");
            }
        } else {
            qInfo("UI audit: View › CMYK unavailable (no CMYK profile installed); pills not checked");
        }

        QJsonArray symbols; uiaudit::auditSymbols("symbols", symbols); findings.merge(symbols);
    } catch (const std::exception &error) {
        qCritical("Qt UI audit FAILED: %s", error.what());
        return 1;
    }
    for (const auto &value : findings.list) {
        const QJsonObject f = value.toObject();
        qWarning().noquote() << "UI audit:" << f.value("kind").toString() << "|" << f.value("where").toString() << "|"
                             << f.value("path").toString() << "|" << f.value("text").toString() << "|"
                             << f.value("needed").toInt() << ">" << f.value("available").toInt();
    }
    if (const QString report = qEnvironmentVariable("COMPOSITOR_UI_AUDIT_REPORT"); !report.isEmpty()) {
        QFile file(report);
        if (file.open(QIODevice::WriteOnly)) file.write(QJsonDocument(findings.list).toJson());
    }
    if (!findings.list.isEmpty()) {
        qCritical("Qt UI audit FAILED: %d finding(s)", int(findings.list.size()));
        return 1;
    }
    qInfo("Qt UI audit OK (welcome, 23 tool states, 22 floating panels, 4 sheets, 12 adjustment layers, CMYK pills: no elided "
          "text, empty buttons or missing symbols; presets, Camera Raw scope, Color Range eyedroppers and pills as upstream draws them)");
    return 0;
}

} // namespace uiauditjourney
