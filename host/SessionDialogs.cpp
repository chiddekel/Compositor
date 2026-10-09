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


#include <algorithm>
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
    setWindowTitle(tr("Search Commands"));
    setObjectName("commandPaletteDialog");
    setMinimumSize(460, 290);
    resize(460, 290);
    setWindowFlags((windowFlags() | Qt::FramelessWindowHint) & ~Qt::WindowContextHelpButtonHint);

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
    // Tip CommandPaletteSearch: fuzzy letter match + tier ranking (word start > substring > scattered).
    const QString phrase = query.toLower().trimmed();
    QString wanted;
    for (QChar c : phrase) if (!c.isSpace()) wanted += c;

    auto scoreOf = [&](const QString &text) -> int {
        const QString title = text.toLower();
        if (phrase.isEmpty()) return 0;
        if (wanted.isEmpty()) return 0;
        int from = 0, previous = -2, total = 0;
        for (QChar character : wanted) {
            const int found = title.indexOf(character, from);
            if (found < 0) return -1;
            const bool wordStart = found == 0 || !title.at(found - 1).isLetterOrNumber();
            total += 1 + (wordStart ? 8 : 0) + (found == previous + 1 ? 5 : 0);
            previous = found;
            from = found + 1;
        }
        const QStringList words = phrase.split(QLatin1Char(' '), Qt::SkipEmptyParts);
        auto wordsStartWords = [&](const QStringList &ws) {
            int searchFrom = 0;
            for (const QString &word : ws) {
                bool ok = false;
                int at = searchFrom;
                while ((at = title.indexOf(word, at)) >= 0) {
                    if (at == 0 || !title.at(at - 1).isLetter()) { searchFrom = at + word.size(); ok = true; break; }
                    ++at;
                }
                if (!ok) return false;
            }
            return true;
        };
        int tier = 1;
        if (wordsStartWords({phrase})) tier = 5;
        else if (words.size() > 1 && wordsStartWords(words)) tier = 4;
        else if (title.contains(phrase)) tier = 3;
        else if (QString(title).remove(QLatin1Char(' ')).contains(wanted)) tier = 2;
        return tier * 1'000'000 + (tier == 1 ? total * 100 : 0) - title.size() / 4;
    };

    struct Ranked { int score; int index; };
    std::vector<Ranked> ranked;
    for (size_t i = 0; i < m_entries.size(); ++i) {
        const auto &cmd = m_entries[i];
        const QString full = cmd.category.isEmpty() ? cmd.title : cmd.category + QStringLiteral(" › ") + cmd.title;
        const int score = scoreOf(full);
        if (!phrase.isEmpty() && score < 0) continue;
        ranked.push_back({score, static_cast<int>(i)});
    }
    std::sort(ranked.begin(), ranked.end(), [](const Ranked &a, const Ranked &b) {
        if (a.score != b.score) return a.score > b.score;
        return a.index < b.index;
    });
    for (const Ranked &r : ranked) {
        const auto &cmd = m_entries[static_cast<size_t>(r.index)];
        QString label = cmd.category.isEmpty() ? cmd.title : QStringLiteral("%1 › %2").arg(cmd.category, cmd.title);
        if (cmd.action && cmd.action->isChecked()) label = QStringLiteral("✓ ") + label;
        if (!cmd.shortcut.isEmpty()) label += QStringLiteral("  ") + cmd.shortcut;
        auto *item = new QListWidgetItem(label, m_list);
        item->setData(Qt::UserRole, r.index);
        if (cmd.action && !cmd.action->isEnabled()) item->setForeground(Qt::gray);
    }
    if (m_list->count() > 0) m_list->setCurrentRow(0);
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

