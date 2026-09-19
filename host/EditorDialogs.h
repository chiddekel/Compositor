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
