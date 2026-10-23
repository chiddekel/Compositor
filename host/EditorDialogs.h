#pragma once

#include <QDialog>
#include <QJsonObject>
#include <QPointer>
#include "interfaces/IPlatformServices.h"
#include <functional>
#include <vector>

// Dialogs describe edits. The caller owns dispatch, document state, and errors.
// They depend on callbacks, not the Swift ABI or SessionWindow.
class SizeDialog final : public QDialog {
public:
    // `colors` is the injected colour-choice service (defaults to the Qt picker).
    SizeDialog(const QJsonObject &state, bool imageSize, QWidget *parent = nullptr,
               std::shared_ptr<IColorPickerService> colors = nullptr);
    QJsonObject command() const;
private:
    std::function<QJsonObject()> m_command;
};

class FilterDialog final : public QDialog {
public:
    using Submit = std::function<bool(const QJsonObject &)>;
    FilterDialog(const QString &kind, Submit submit, QWidget *parent = nullptr);
};

class SessionWindow;
class QLineEdit;
class QListWidget;
class QLabel;
class QAction;

class CommandPaletteDialog final : public QDialog {
public:
    explicit CommandPaletteDialog(SessionWindow *window, QWidget *parent = nullptr);
protected:
    bool eventFilter(QObject *watched, QEvent *event) override;
private:
    SessionWindow *m_window = nullptr;
    QPointer<QWidget> m_returnFocus;
    QLineEdit *m_filter = nullptr;
    QListWidget *m_list = nullptr;
    QLabel *m_empty = nullptr;   // "No commands match"
    void populateList(const QString &query);
    void triggerSelected();
};

