#pragma once

#include "SessionWindow.h"
#include "NativeTextHistory.h"
#include "Upstream154Journey.h"
#include <QApplication>
#include <QComboBox>
#include <QDialog>
#include <QElapsedTimer>
#include <QJsonArray>
#include <QLineEdit>
#include <QPlainTextEdit>
#include <stdexcept>

namespace fonthistoryjourney {
inline int run(QApplication &) {
    try {
        const auto require = [](bool value, const char *message) {
            if (!value) throw std::runtime_error(message);
        };
        SessionWindow window;
        window.resize(1200, 800); window.show(); QApplication::setActiveWindow(&window);
        QApplication::processEvents();
        const auto command = [&](const QJsonObject &value) {
            require(window.sendCommand(value), "font history fixture command failed");
            QApplication::processEvents();
        };
        command({{"action", "new"}, {"width", 128}, {"height", 64}, {"emptyLayer", true}});
        command({{"action", "textBegin"}, {"x", 8}, {"y", 8}});
        command({{"action", "textSetContent"}, {"name", QString::fromUtf8("A😀BCDEF")}});
        const auto draft = [&] { return window.sessionState().value("textDraft").toObject(); };
        auto style = NativeTextHistory::attributes(draft());
        style.insert("content", draft().value("content"));
        style.insert("fontName", "Helvetica");
        style.insert("fontRuns", QJsonArray{QJsonObject{{"location", 3}, {"length", 3}, {"fontName", "Helvetica-Bold"}}});
        command({{"action", "textRestore"}, {"draftID", draft().value("id")}, {"textStyle", style}, {"location", 0}, {"length", 8}});
        auto *editor = window.findChild<QPlainTextEdit *>("canvas.textEditor");
        require(editor && editor->isVisible(), "font history native text editor missing");
        const auto original = NativeTextHistory::attributes(draft());
        const int originalSteps = editor->document()->availableUndoSteps();
        const auto panel = [&]() -> QDialog * {
            for (auto *dialog : window.findChildren<QDialog *>())
                if (dialog->isVisible() && dialog->objectName().startsWith(QLatin1String("floatingPanel.NativeWindow:"))) return dialog;
            return nullptr;
        };
        const auto search = [&]() -> QLineEdit * {
            if (auto *dialog = panel()) for (auto *field : dialog->findChildren<QLineEdit *>())
                if (field->isVisible() && field->placeholderText() == QLatin1String("Search Fonts")) return field;
            return nullptr;
        };
        const auto settle = [&] {
            QElapsedTimer elapsed; elapsed.start();
            upstream154journey::settle([&] { return elapsed.elapsed() >= 300; }, "font history synchronization timed out");
        };
        const auto open = [&] {
            settle();
            QComboBox *picker = nullptr;
            for (auto *combo : window.findChildren<QComboBox *>())
                if (combo->isVisible() && combo->accessibleName() == QLatin1String("Font")) picker = combo;
            require(picker, "font history picker missing");
            picker->showPopup();
            upstream154journey::settle([&] { return search() != nullptr; }, "font history search did not open");
            for (QChar character : QStringLiteral("Helvetica")) {
                search()->setFocus(); upstream154journey::key(search(), 0, QString(character));
            }
        };
        const auto preview = [&] {
            for (int key : {Qt::Key_Down, Qt::Key_Up}) {
                upstream154journey::key(search(), key, {}); settle();
                qInfo("Font highlight Undo positions: before=%d after=%d", originalSteps, editor->document()->availableUndoSteps());
                require(editor->document()->availableUndoSteps() == originalSteps,
                        "font highlight added a native undo step before the choice was committed");
            }
        };
        open(); preview();
        // First Escape clears the search; the second cancels the font panel.
        upstream154journey::key(search(), Qt::Key_Escape, {});
        upstream154journey::key(search(), Qt::Key_Escape, {});
        upstream154journey::settle([&] { return panel() == nullptr; }, "font history cancellation did not close");
        settle();
        require(editor->document()->availableUndoSteps() == originalSteps && NativeTextHistory::attributes(draft()) == original,
                "canceling font highlights changed text styles or native history");
        open(); preview();
        upstream154journey::key(search(), Qt::Key_Return, QStringLiteral("\r"));
        upstream154journey::settle([&] { return panel() == nullptr; }, "font history commit did not close");
        settle();
        const auto committed = NativeTextHistory::attributes(draft());
        require(committed != original && draft().value("fontRuns").toArray().isEmpty(), "font history choice did not replace mixed fonts");
        require(editor->document()->availableUndoSteps() > originalSteps, "committed font choice has no native Undo step");
        editor->undo(); QApplication::processEvents();
        require(NativeTextHistory::attributes(draft()) == original && editor->document()->availableUndoSteps() == originalSteps,
                "one native Undo did not restore the original mixed font runs");
        editor->redo(); QApplication::processEvents();
        require(NativeTextHistory::attributes(draft()) == committed, "native Redo did not restore the committed font choice");
        qInfo("Qt font history OK (multiple live highlights, Cancel, one-step commit Undo, exact mixed-font restoration and Redo)");
        return 0;
    } catch (const std::exception &error) {
        qCritical("Qt font history failed: %s", error.what());
        return 1;
    }
}
}
