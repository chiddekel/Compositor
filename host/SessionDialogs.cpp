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
#include <QApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QTimer>

extern "C" int64_t compositor_command_palette_search(uint64_t, const char *, uint8_t *, size_t);

CommandPaletteDialog::CommandPaletteDialog(SessionWindow *window, QWidget *parent)
    : QDialog(parent), m_window(window), m_returnFocus(QApplication::focusWidget()) {
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
        auto *key = static_cast<QKeyEvent *>(event);
        if (key->key() == Qt::Key_Down || key->key() == Qt::Key_Up) {
            const int count = m_list->count();
            if (count > 0) {
                const int step = key->key() == Qt::Key_Down ? 1 : -1;
                m_list->setCurrentRow((m_list->currentRow() + step + count) % count);
            }
            return true;
        }
    }
    return QDialog::eventFilter(watched, event);
}

void CommandPaletteDialog::populateList(const QString &query) {
    m_list->clear();
    if (!m_window) return;
    const QByteArray utf8 = query.toUtf8();
    const uint64_t handle = m_window->sessionHandle();
    const int64_t size = compositor_command_palette_search(handle, utf8.constData(), nullptr, 0);
    if (size <= 0 || size > 8 * 1024 * 1024) return;
    QByteArray data(static_cast<qsizetype>(size), Qt::Uninitialized);
    if (compositor_command_palette_search(handle, utf8.constData(), reinterpret_cast<uint8_t *>(data.data()), data.size()) != size) return;
    for (const auto &value : QJsonDocument::fromJson(data).array()) {
        const auto entry = value.toObject();
        QString label = entry.value("title").toString();
        if (entry.value("checked").toBool()) label.prepend(QStringLiteral("✓ "));
        if (entry.contains("shortcut")) label += QStringLiteral("  ") + entry.value("shortcut").toString();
        auto *item = new QListWidgetItem(label, m_list);
        item->setData(Qt::UserRole, entry.value("id").toString());
        item->setData(Qt::UserRole + 1, entry.value("enabled").toBool());
        if (!entry.value("enabled").toBool()) item->setForeground(Qt::gray);
    }
    if (m_list->count() > 0) m_list->setCurrentRow(0);
}

void CommandPaletteDialog::triggerSelected() {
    auto *current = m_list->currentItem();
    if (!current || !current->data(Qt::UserRole + 1).toBool() || !m_window) return;
    const QString id = current->data(Qt::UserRole).toString();
    const QPointer<SessionWindow> window(m_window);
    const QPointer<QWidget> focus(m_returnFocus);
    accept();
    // As upstream: give the editor its focus, then run on the next main-loop turn.
    QTimer::singleShot(0, m_window, [window, focus, id] {
        if (!window) return;
        QApplication::setActiveWindow(window);
        if (focus && focus->isVisible() && focus->isEnabled()) focus->setFocus(Qt::OtherFocusReason);
        window->performPaletteCommand(id);
    });
}

void SessionWindow::showCommandPalette() {
    CommandPaletteDialog dialog(this, this);
    dialog.exec();
}

