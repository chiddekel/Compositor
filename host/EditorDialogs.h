#pragma once

#include <QDialog>
#include <QJsonObject>
#include <functional>

// Dialogs describe edits. The caller owns dispatch, document state, and errors.
// They depend on callbacks, not the Swift ABI or SessionWindow.
class SizeDialog final : public QDialog {
public:
    SizeDialog(const QJsonObject &state, bool imageSize, QWidget *parent = nullptr);
    QJsonObject command() const;
private:
    std::function<QJsonObject()> m_command;
};

class FilterDialog final : public QDialog {
public:
    using Submit = std::function<bool(const QJsonObject &)>;
    FilterDialog(const QString &kind, Submit submit, QWidget *parent = nullptr);
};

class AdjustDialog final : public QDialog {
public:
    using Submit = std::function<bool(const QJsonObject &)>;
    AdjustDialog(const QString &kind, Submit submit, QWidget *parent = nullptr);
};

class SessionWindow;
class QLineEdit;
class QListWidget;
class QAction;

class CommandPaletteDialog final : public QDialog {
public:
    explicit CommandPaletteDialog(SessionWindow *window, QWidget *parent = nullptr);
protected:
    bool eventFilter(QObject *watched, QEvent *event) override;
private:
    struct CommandEntry {
        QString title;
        QString category;
        QString shortcut;
        QAction *action = nullptr;
    };
    SessionWindow *m_window = nullptr;
    QLineEdit *m_filter = nullptr;
    QListWidget *m_list = nullptr;
    std::vector<CommandEntry> m_entries;
    void collectCommands();
    void populateList(const QString &query);
    void triggerSelected();
};

