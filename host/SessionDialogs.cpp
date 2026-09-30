#include "SessionWindow.h"
#include <memory>
#include <QtMath>
#include <vector>
#include <QImage>
#include "EditorDialogs.h"
#include <QMessageBox>

void SessionWindow::showSizeDialog(bool imageSize) {
    // Prefer upstream Canvas Size / Image Size sheets (same as AppMenus → shell requests).
    if (sendCommand({{"action", imageSize ? "imageSizeSheet" : "canvasSizeSheet"}})) {
        refreshImage();
        refreshLayers();
        updateLayersPanel();
        updateStatusTelemetry();
        return;
    }
    const QJsonObject state = sessionState();
    if (state.value("busy").toBool() || state.value("width").toInt() <= 0) return;
    SizeDialog dialog(state, imageSize, this, m_platform.colors);
    while (dialog.exec() == QDialog::Accepted) {
        if (sendCommand(dialog.command())) { refreshImage(); return; }
        m_platform.notifier->warn(tr("Resize failed"), sessionState().value("error").toString());
    }
}

void SessionWindow::showFilterDialog(const QString &kind) {
    // Upstream FilterSheet (floating), matching CompositorApp's Filter / Image menus.
    if (sendCommand({{"action", "openFilter"}, {"kind", kind}})) {
        refreshImage();
        updateFloatingPanels();
        return;
    }
    if (!sendCommand({{"action", "filterBegin"}, {"kind", kind}})) return;
    FilterDialog dialog(kind, [this](const QJsonObject &command) {
        const bool ok = sendCommand(command);
        refreshImage();
        return ok;
    }, this);
    dialog.exec();
}

void SessionWindow::openImageAdjustment(const QString &kind) {
    // CompositorApp Image menu: Levels / Hue/Saturation have dedicated sheets; the rest are filters.
    if (kind == QLatin1String("Levels")) {
        if (sendCommand({{"action", "beginLevels"}})) { refreshImage(); updateFloatingPanels(); }
        return;
    }
    if (kind == QLatin1String("Hue/Saturation")) {
        if (sendCommand({{"action", "beginHueSaturation"}})) { refreshImage(); updateFloatingPanels(); }
        return;
    }
    showFilterDialog(kind);
}

void SessionWindow::openNewAdjustmentLayer(const QString &kind) {
    // Layer > New Adjustment Layer…: create the layer, then open upstream's editor.
    if (!sendCommand({{"action", "addAdjustment"}, {"kind", kind}})) return;
    refreshImage();
    refreshLayers();
    updateLayersPanel();
    updateFloatingPanels();
}

void SessionWindow::showAdjustDialog(const QString &kind) {
    // Legacy entry: Image-menu adjustments (objectName adjust.*). New adjustment layers use openNewAdjustmentLayer.
    openImageAdjustment(kind);
}


#include <QLineEdit>
#include <QListWidget>
#include <QListWidgetItem>
#include <QVBoxLayout>
#include <QKeyEvent>
#include <QAction>
#include <QMenuBar>
#include <QMenu>

CommandPaletteDialog::CommandPaletteDialog(SessionWindow *window, QWidget *parent)
    : QDialog(parent), m_window(window) {
    setWindowTitle(tr("Command Palette"));
    setObjectName("commandPaletteDialog");
    setMinimumSize(480, 320);
    resize(560, 380);

    auto *layout = new QVBoxLayout(this);
    layout->setContentsMargins(8, 8, 8, 8);
    layout->setSpacing(6);

    m_filter = new QLineEdit(this);
    m_filter->setObjectName("commandPalette.filter");
    m_filter->setPlaceholderText(tr("Type a command to run..."));
    m_filter->setClearButtonEnabled(true);
    m_filter->installEventFilter(this);
    layout->addWidget(m_filter);

    m_list = new QListWidget(this);
    m_list->setObjectName("commandPalette.list");
    m_list->setUniformItemSizes(true);
    layout->addWidget(m_list);

    collectCommands();
    populateList(QString());

    connect(m_filter, &QLineEdit::textChanged, this, [this](const QString &text) {
        populateList(text);
    });
    connect(m_filter, &QLineEdit::returnPressed, this, [this] {
        triggerSelected();
    });
    connect(m_list, &QListWidget::itemDoubleClicked, this, [this](QListWidgetItem *) {
        triggerSelected();
    });
}

bool CommandPaletteDialog::eventFilter(QObject *watched, QEvent *event) {
    if (watched == m_filter && event->type() == QEvent::KeyPress) {
        auto *keyEvent = static_cast<QKeyEvent *>(event);
        if (keyEvent->key() == Qt::Key_Down) {
            int row = m_list->currentRow();
            if (row < m_list->count() - 1) m_list->setCurrentRow(row + 1);
            return true;
        } else if (keyEvent->key() == Qt::Key_Up) {
            int row = m_list->currentRow();
            if (row > 0) m_list->setCurrentRow(row - 1);
            return true;
        }
    }
    return QDialog::eventFilter(watched, event);
}

void CommandPaletteDialog::collectCommands() {
    m_entries.clear();
    if (!m_window) return;

    auto traverseMenu = [this](auto self, QMenu *menu, const QString &prefix) -> void {
        if (!menu) return;
        const QString cat = prefix.isEmpty() ? menu->title().remove('&') : prefix + " > " + menu->title().remove('&');
        for (QAction *act : menu->actions()) {
            if (act->isSeparator()) continue;
            if (act->menu()) {
                self(self, act->menu(), cat);
            } else if (!act->text().isEmpty()) {
                QString cleanText = act->text().remove('&');
                QString shortcut = act->shortcut().toString(QKeySequence::NativeText);
                m_entries.push_back({cleanText, cat, shortcut, act});
            }
        }
    };

    if (m_window->menuBar()) {
        for (QAction *menuAct : m_window->menuBar()->actions()) {
            if (menuAct->menu()) {
                traverseMenu(traverseMenu, menuAct->menu(), QString());
            }
        }
    }

    for (QAction *act : m_window->findChildren<QAction *>()) {
        if (act->isSeparator() || act->text().isEmpty()) continue;
        bool already = false;
        for (const auto &e : m_entries) {
            if (e.action == act) { already = true; break; }
        }
        if (!already) {
            QString cleanText = act->text().remove('&');
            QString shortcut = act->shortcut().toString(QKeySequence::NativeText);
            m_entries.push_back({cleanText, tr("Action"), shortcut, act});
        }
    }
}

void CommandPaletteDialog::populateList(const QString &query) {
    m_list->clear();
    const QString lower = query.toLower().trimmed();
    for (size_t i = 0; i < m_entries.size(); ++i) {
        const auto &cmd = m_entries[i];
        const QString full = (cmd.category + " " + cmd.title).toLower();
        if (!lower.isEmpty() && !full.contains(lower)) continue;

        QString label = cmd.category.isEmpty() ? cmd.title : QString("[%1] %2").arg(cmd.category, cmd.title);
        if (!cmd.shortcut.isEmpty()) {
            label += QString(" (%1)").arg(cmd.shortcut);
        }

        auto *item = new QListWidgetItem(label, m_list);
        item->setData(Qt::UserRole, static_cast<int>(i));
        if (!cmd.action->isEnabled()) {
            item->setForeground(Qt::gray);
        }
    }
    if (m_list->count() > 0) {
        m_list->setCurrentRow(0);
    }
}

void CommandPaletteDialog::triggerSelected() {
    QListWidgetItem *cur = m_list->currentItem();
    if (!cur) return;
    int idx = cur->data(Qt::UserRole).toInt();
    if (idx >= 0 && idx < static_cast<int>(m_entries.size())) {
        QAction *act = m_entries[idx].action;
        accept();
        if (act && act->isEnabled()) {
            act->trigger();
        }
    }
}

void SessionWindow::showCommandPalette() {
    CommandPaletteDialog dialog(this, this);
    dialog.exec();
}

