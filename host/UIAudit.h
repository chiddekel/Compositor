// UIAudit — generic checks of what the Qt shell actually draws for upstream's views: text cut short, buttons with
// nothing to show, symbols with no picture. Behavior tests drive controls by name and read session state, so they pass
// while a label is clipped or a button is invisible; these checks look at the widgets themselves.
// Used by the `--ui-audit-probe` native gate (DialogJourney.cpp). Header-only and Q_OBJECT-free (SwiftPM runs no moc).
#pragma once

#include "SwiftUIQtRenderer.h"

#include <QAbstractButton>
#include <QCheckBox>
#include <QComboBox>
#include <QFontMetrics>
#include <QJsonArray>
#include <QJsonObject>
#include <QLabel>
#include <QPushButton>
#include <QRadioButton>
#include <QStyle>
#include <QStyleOptionButton>
#include <QTextDocument>
#include <QWidget>

namespace uiaudit {

/// Where a widget sits, for a finding: its nearest named ancestors (`floatingPanel.FilterSheet/…`).
inline QString path(const QWidget *widget) {
    QStringList parts;
    for (const QWidget *w = widget; w; w = w->parentWidget())
        if (!w->objectName().isEmpty()) parts.prepend(w->objectName());
    return parts.join(QLatin1Char('/'));
}

inline bool shown(const QWidget *widget, const QWidget *root) {
    return widget->isVisibleTo(root) && widget->width() > 0 && widget->height() > 0;
}

inline void add(QJsonArray &findings, const QString &where, const QString &kind, const QWidget *widget, const QString &text,
                int needed, int available) {
    findings.append(QJsonObject{{"where", where}, {"kind", kind}, {"path", path(widget)}, {"text", text},
                                {"needed", needed}, {"available", available}});
}

/// Text a widget shows that its width cannot hold (a label one line long, a button's or check box's title, a pop-up's
/// current choice), and visible buttons with neither a title nor a picture.
inline void auditTree(QWidget *root, const QString &where, QJsonArray &findings) {
    if (!root) return;
    QList<QWidget *> widgets = root->findChildren<QWidget *>();
    widgets.prepend(root);
    for (QWidget *widget : widgets) {
        if (!shown(widget, root) || widget->property("uiAuditIgnore").toBool()) continue;
        if (auto *label = qobject_cast<QLabel *>(widget)) {
            const QString text = label->text();
            if (text.isEmpty() || label->wordWrap() || !label->pixmap().isNull() || Qt::mightBeRichText(text)) continue;
            if (text.contains(QLatin1Char('\n'))) continue;
            const int needed = label->fontMetrics().horizontalAdvance(text);
            const int available = label->contentsRect().width() - 2 * label->margin() - label->indent();
            if (needed > available + 1) add(findings, where, "elidedLabel", label, text, needed, available);
        } else if (auto *combo = qobject_cast<QComboBox *>(widget)) {
            const QString text = combo->currentText();
            if (text.isEmpty()) continue;
            QStyleOptionComboBox option;
            option.initFrom(combo);
            option.editable = combo->isEditable();
            const QRect field = combo->style()->subControlRect(QStyle::CC_ComboBox, &option, QStyle::SC_ComboBoxEditField, combo);
            const int needed = combo->fontMetrics().horizontalAdvance(text);
            if (needed > field.width() + 1) add(findings, where, "elidedPopup", combo, text, needed, field.width());
        } else if (auto *button = qobject_cast<QAbstractButton *>(widget)) {
            const QString text = button->text();
            const bool box = qobject_cast<QCheckBox *>(button) || qobject_cast<QRadioButton *>(button);
            if (text.isEmpty()) {
                // A swatch draws its color with a style sheet; an indicator-only check box draws its box.
                if (box || button->styleSheet().contains(QLatin1String("background-color: #"))) continue;
                if (button->icon().isNull() && button->width() >= 6 && button->height() >= 6 && button->findChildren<QWidget *>().isEmpty())
                    add(findings, where, "emptyButton", button, button->toolTip(), 0, button->width());
                continue;
            }
            const int needed = button->sizeHint().width();
            if (needed > button->width() + 1) add(findings, where, box ? "clippedToggle" : "clippedButton", button, text, needed, button->width());
        }
    }
}

/// Symbols the renderer and the AppKit symbol callback were asked for and had no picture for.
inline void auditSymbols(const QString &where, QJsonArray &findings) {
    for (const QString &symbol : swiftUIUnresolvedSymbols())
        findings.append(QJsonObject{{"where", where}, {"kind", "unresolvedSymbol"}, {"path", ""}, {"text", symbol},
                                    {"needed", 0}, {"available", 0}});
}

} // namespace uiaudit
