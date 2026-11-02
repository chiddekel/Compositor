#include "QtKeyboardLayout.h"
#include <QGuiApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QTimer>
#include <QWindow>
#include <iostream>

static QString recorded;
extern "C" void compositor_keyboard_set_latin_character(int32_t, int32_t, const char *characters) {
    recorded = QString::fromUtf8(characters);
}

class KeyboardWindow final : public QWindow {
    bool event(QEvent *event) override {
        if (event->type() != QEvent::KeyPress) return QWindow::event(event);
        auto *key = static_cast<QKeyEvent *>(event);
        if (key->text().isEmpty()) return QWindow::event(event);
        recorded.clear();
        const int code = appKitPrintableKeyCode(key);
        QJsonArray candidates;
        for (const auto &candidate : QKeyMapper::possibleKeys(key))
            candidates.append(QJsonObject{{"key", int(candidate.key())}, {"modifiers", int(candidate.keyboardModifiers())}});
        const QJsonObject result{{"typed", key->text()}, {"latin", recorded}, {"code", code},
                                 {"scanCode", int(key->nativeScanCode())}, {"candidates", candidates}};
        std::cout << QJsonDocument(result).toJson(QJsonDocument::Compact).constData() << std::endl;
        QCoreApplication::quit();
        return true;
    }
};

int main(int argc, char **argv) {
    QGuiApplication application(argc, argv);
    if (argc == 3 && QByteArray(argv[1]) == "--lookup") {
        const auto code = QByteArray(argv[2]).toUInt();
        auto *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
        auto *map = nativekeyboard::currentKeymap(context);
        QJsonArray layouts;
        if (map) for (xkb_layout_index_t i = 0; i < xkb_keymap_num_layouts(map); ++i)
            layouts.append(QString::fromUtf8(xkb_keymap_layout_get_name(map, i)));
        xkb_keymap_unref(map);
        xkb_context_unref(context);
        const QJsonObject result{{"normal", nativekeyboard::latinCharacter(code, false)},
                                 {"shifted", nativekeyboard::latinCharacter(code, true)}, {"layouts", layouts},
                                 {"display", QString::fromUtf8(qgetenv("WAYLAND_DISPLAY"))},
                                 {"platform", QGuiApplication::platformName()}};
        std::cout << QJsonDocument(result).toJson(QJsonDocument::Compact).constData() << std::endl;
        return 0;
    }
    KeyboardWindow window;
    window.resize(320, 200);
    window.show();
    QGuiApplication::sync();
    std::cout << "WINDOW " << window.winId() << std::endl;
    QTimer::singleShot(15000, [] { QCoreApplication::exit(2); });
    return application.exec();
}
