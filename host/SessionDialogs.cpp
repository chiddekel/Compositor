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
#include <QFrame>
#include <QLabel>
#include <QPainter>
#include <QStyledItemDelegate>
#include "SwiftUIQtRenderer.h"

extern "C" int64_t compositor_command_palette_search(uint64_t, const char *, uint8_t *, size_t);

namespace {
// Row data beside the title (Qt::DisplayRole) and the entry id / enabled flag (UserRole, UserRole + 1).
constexpr int PaletteShortcutRole = Qt::UserRole + 2;
constexpr int PaletteCheckedRole = Qt::UserRole + 3;

/// Upstream's CommandPaletteView row: a checkmark only where the menu shows one, the title, and the shortcut in a
/// secondary monospaced column at the right; 10 × 6 padding, the chosen row on accent at 35% in a 6 pt rounded rect,
/// disabled rows in the tertiary color.
class PaletteRowDelegate final : public QStyledItemDelegate {
public:
    using QStyledItemDelegate::QStyledItemDelegate;
    QSize sizeHint(const QStyleOptionViewItem &option, const QModelIndex &) const override {
        return QSize(option.rect.width(), option.fontMetrics.height() + 12);
    }
    void paint(QPainter *painter, const QStyleOptionViewItem &option, const QModelIndex &index) const override {
        painter->save();
        painter->setRenderHint(QPainter::Antialiasing);
        const QPalette &palette = option.palette;
        if (option.state & QStyle::State_Selected) {
            QColor chosen = palette.color(QPalette::Highlight);
            chosen.setAlphaF(0.35);
            painter->setPen(Qt::NoPen);
            painter->setBrush(chosen);
            painter->drawRoundedRect(QRectF(option.rect), 6, 6);
        }
        const bool enabled = index.data(Qt::UserRole + 1).toBool();
        QColor primary = palette.color(QPalette::Text);
        QColor secondary = primary;
        secondary.setAlphaF(0.5);
        if (!enabled) { primary.setAlphaF(0.25); secondary.setAlphaF(0.25); }
        QRect content = option.rect.adjusted(10, 0, -10, 0);
        if (index.data(PaletteCheckedRole).toBool()) {
            const int side = 12;
            renderToolVectorIcon(QStringLiteral("checkmark"), side, primary)
                .paint(painter, QRect(content.left(), content.center().y() - side / 2, side, side));
            content.setLeft(content.left() + side + 6);
        }
        const QString shortcut = index.data(PaletteShortcutRole).toString();
        if (!shortcut.isEmpty()) {
            QFont mono = option.font;
            mono.setFamily(QStringLiteral("monospace"));
            mono.setStyleHint(QFont::Monospace);
            const int width = QFontMetrics(mono).horizontalAdvance(shortcut);
            painter->setFont(mono);
            painter->setPen(secondary);
            painter->drawText(QRect(content.right() - width, content.top(), width, content.height()),
                              Qt::AlignRight | Qt::AlignVCenter, shortcut);
            content.setRight(content.right() - width - 6);
        }
        painter->setFont(option.font);
        painter->setPen(primary);
        painter->drawText(content, Qt::AlignLeft | Qt::AlignVCenter,
                          option.fontMetrics.elidedText(index.data(Qt::DisplayRole).toString(), Qt::ElideRight, content.width()));
        painter->restore();
    }
};
}

CommandPaletteDialog::CommandPaletteDialog(SessionWindow *window, QWidget *parent)
    : QDialog(parent), m_window(window), m_returnFocus(QApplication::focusWidget()) {
    setWindowTitle(tr("Search Commands"));
    setObjectName("commandPaletteDialog");
    setMinimumSize(460, 290);
    resize(460, 290);
    setWindowFlags((windowFlags() | Qt::FramelessWindowHint) & ~Qt::WindowContextHelpButtonHint);

    // Upstream CommandPaletteView: a plain 17 pt search field (16 × 13 padding), a divider, then the rows 6 pt in.
    auto *layout = new QVBoxLayout(this);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(0);

    m_filter = new QLineEdit(this);
    m_filter->setObjectName("commandPalette.filter");
    m_filter->setPlaceholderText(tr("Search commands and tools"));
    m_filter->setFrame(false);
    m_filter->setTextMargins(16, 13, 16, 13);
    QFont searchFont = m_filter->font();
    searchFont.setPixelSize(17);
    m_filter->setFont(searchFont);
    m_filter->setStyleSheet(QStringLiteral("QLineEdit { background: transparent; }"));
    m_filter->installEventFilter(this);
    layout->addWidget(m_filter);

    auto *divider = new QFrame(this);
    divider->setFrameShape(QFrame::HLine);
    divider->setFrameShadow(QFrame::Plain);
    divider->setObjectName("commandPalette.divider");
    layout->addWidget(divider);

    m_list = new QListWidget(this);
    m_list->setObjectName("commandPalette.list");
    m_list->setUniformItemSizes(true);
    m_list->setFrameShape(QFrame::NoFrame);
    m_list->setStyleSheet(QStringLiteral("QListWidget { background: transparent; padding: 6px 6px 0 6px; }"));
    m_list->setItemDelegate(new PaletteRowDelegate(m_list));
    layout->addWidget(m_list, 1);

    // Upstream overlays this when nothing matches.
    m_empty = new QLabel(tr("No commands match"), m_list->viewport());
    m_empty->setObjectName("commandPalette.empty");
    m_empty->setAlignment(Qt::AlignCenter);
    QPalette emptyPalette = m_empty->palette();
    QColor emptyColor = emptyPalette.color(QPalette::WindowText);
    emptyColor.setAlphaF(0.5);
    emptyPalette.setColor(QPalette::WindowText, emptyColor);
    m_empty->setPalette(emptyPalette);
    m_empty->hide();
    m_list->viewport()->installEventFilter(this);

    populateList(QString());

    connect(m_filter, &QLineEdit::textChanged, this, [this](const QString &text) {
        populateList(text);
    });
    connect(m_filter, &QLineEdit::returnPressed, this, [this] {
        triggerSelected();
    });
    // Upstream runs a row on a tap (onTapGesture).
    connect(m_list, &QListWidget::itemClicked, this, [this](QListWidgetItem *item) {
        m_list->setCurrentItem(item);
        triggerSelected();
    });
}

bool CommandPaletteDialog::eventFilter(QObject *watched, QEvent *event) {
    if (m_list && watched == m_list->viewport() && event->type() == QEvent::Resize && m_empty)
        m_empty->setGeometry(m_list->viewport()->rect());
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
    struct ShowEmpty {
        CommandPaletteDialog *dialog;
        ~ShowEmpty() {
            if (!dialog->m_empty) return;
            dialog->m_empty->setGeometry(dialog->m_list->viewport()->rect());
            dialog->m_empty->setVisible(dialog->m_list->count() == 0);
        }
    } showEmpty{this};
    if (!m_window) return;
    const QByteArray utf8 = query.toUtf8();
    const uint64_t handle = m_window->sessionHandle();
    const int64_t size = compositor_command_palette_search(handle, utf8.constData(), nullptr, 0);
    if (size <= 0 || size > 8 * 1024 * 1024) return;
    QByteArray data(static_cast<qsizetype>(size), Qt::Uninitialized);
    if (compositor_command_palette_search(handle, utf8.constData(), reinterpret_cast<uint8_t *>(data.data()), data.size()) != size) return;
    for (const auto &value : QJsonDocument::fromJson(data).array()) {
        const auto entry = value.toObject();
        auto *item = new QListWidgetItem(entry.value("title").toString(), m_list);
        item->setData(Qt::UserRole, entry.value("id").toString());
        item->setData(Qt::UserRole + 1, entry.value("enabled").toBool());
        item->setData(PaletteShortcutRole, entry.value("shortcut").toString());
        item->setData(PaletteCheckedRole, entry.value("checked").toBool());
        // Screen readers hear the row as the menu says it.
        item->setData(Qt::AccessibleTextRole, entry.contains("shortcut")
            ? entry.value("title").toString() + QStringLiteral(", ") + entry.value("shortcut").toString() : entry.value("title").toString());
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

