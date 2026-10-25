#include "SwiftUITextFieldState.h"
#include <QApplication>
#include <QDebug>
#include <QKeyEvent>
#include <QTimer>
#include <QVBoxLayout>
#include <stdexcept>

namespace {
void require(bool value, const char *message) { if (!value) throw std::runtime_error(message); }
void key(QLineEdit &field, int code, Qt::KeyboardModifiers modifiers = Qt::NoModifier, const QString &text = {}) {
    QKeyEvent press(QEvent::KeyPress, code, modifiers, text), release(QEvent::KeyRelease, code, modifiers, text);
    QApplication::sendEvent(&field, &press);
    QApplication::sendEvent(&field, &release);
    QApplication::processEvents();
}
}

int main(int argc, char **argv) {
    QApplication app(argc, argv);
    try {
        QWidget window;
        QVBoxLayout layout(&window);
        QLineEdit field, other;
        layout.addWidget(&field); layout.addWidget(&other);
        window.show(); QApplication::setActiveWindow(&window);
        field.setFocus(); QApplication::processEvents();
        require(field.hasFocus(), "text field fixture did not acquire focus");
        int changed = 0;
        QObject::connect(&field, &QLineEdit::textChanged, &field, [&] { ++changed; });

        // A queued unit conversion resolves after Ctrl+A and before the first replacement character.
        field.setText("0.48");
        key(field, Qt::Key_A, Qt::ControlModifier);
        require(field.selectedText() == "0.48", "Ctrl+A did not select the old print dimension");
        changed = 0;
        QTimer::singleShot(0, &field, [&] { swiftuifields::refreshText(field, "1.219"); });
        QApplication::processEvents();
        require(changed == 0, "model refresh dispatched a text change back to the model");
        for (QChar character : QString("0.60960000")) key(field, 0, Qt::NoModifier, QString(character));
        if (field.text() != "0.60960000") qWarning() << "Replacement text" << field.text();
        require(field.text() == "0.60960000" && field.hasFocus() && field.cursorPosition() == 10,
            "queued model refresh cleared the replacement selection");

        const auto reset = [&](const QString &text) {
            field.setFocus(); field.setText(text); field.setProperty("swiftuiTyped", false); changed = 0;
        };
        reset("12345"); field.setSelection(0, 5);
        swiftuifields::refreshText(field, "12");
        require(field.selectedText() == "12" && field.cursorPosition() == 2, "full selection did not follow shorter model text");
        reset("12345"); field.setSelection(5, -5);
        swiftuifields::refreshText(field, "1234567");
        require(field.selectedText() == "1234567" && field.cursorPosition() == 0, "reverse full selection lost its anchor");
        reset("12345"); field.setSelection(1, 3);
        swiftuifields::refreshText(field, "ab");
        require(field.selectedText() == "b" && field.cursorPosition() == 2, "partial selection did not clamp to shorter text");
        reset("12345"); field.setSelection(4, -3);
        swiftuifields::refreshText(field, "ab");
        require(field.selectedText() == "b" && field.cursorPosition() == 1, "reverse partial selection lost its direction");
        reset("12345"); field.setCursorPosition(2);
        swiftuifields::refreshText(field, "abcdef");
        require(field.cursorPosition() == 2 && !field.hasSelectedText(), "interior caret moved during model refresh");
        reset("12345"); field.setCursorPosition(5);
        swiftuifields::refreshText(field, "abcdef");
        require(field.cursorPosition() == 6, "end caret did not follow the new text end");
        reset("12345"); field.selectAll();
        swiftuifields::refreshText(field, "");
        require(field.text().isEmpty() && field.cursorPosition() == 0, "empty model text left an invalid selection");
        reset("12345"); field.setCursorPosition(2); field.setProperty("swiftuiTyped", true);
        swiftuifields::refreshText(field, "model");
        require(field.text() == "12345" && field.cursorPosition() == 2, "focused typed text was overwritten");
        other.setFocus(); QApplication::processEvents(); changed = 0;
        swiftuifields::refreshText(field, "model");
        require(field.text() == "model" && changed == 0, "unfocused field did not follow the model silently");
        reset("unchanged"); field.setSelection(1, 3);
        swiftuifields::refreshText(field, "unchanged");
        require(field.selectionStart() == 1 && field.selectedText() == "nch" && changed == 0,
            "identical model text disturbed editing state");
        qInfo("Text field model refresh OK (queued replacement, full/partial/reverse selections, caret, typing and signals)");
        return 0;
    } catch (const std::exception &error) { qCritical() << "Text field model refresh failed:" << error.what(); return 1; }
}
