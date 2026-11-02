#pragma once

#include <QLineEdit>
#include <QSignalBlocker>

namespace swiftuifields {
inline void refreshText(QLineEdit &field, const QString &text) {
    if ((field.hasFocus() && field.property("swiftuiTyped").toBool()) || field.text() == text) return;
    const bool focused = field.hasFocus();
    const int cursor = field.cursorPosition(), start = field.selectionStart(), length = field.selectedText().size();
    const bool selectedAll = start == 0 && length == field.text().size();
    const bool atEnd = cursor == field.text().size();
    const QSignalBlocker block(&field);
    field.setText(text);
    if (!focused) return;
    // A queued model update can land between Select All and the first replacement character.
    // Keep the selection's direction and let a full selection follow the new value's length.
    if (start >= 0) {
        const int nextStart = selectedAll ? 0 : qMin(start, int(text.size()));
        const int nextLength = selectedAll ? int(text.size()) : qMin(length, int(text.size()) - nextStart);
        if (cursor == start) field.setSelection(nextStart + nextLength, -nextLength);
        else field.setSelection(nextStart, nextLength);
    } else field.setCursorPosition(atEnd ? int(text.size()) : qMin(cursor, int(text.size())));
}
}
