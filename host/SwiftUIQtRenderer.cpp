#include <QKeyEvent>
#include <QHash>
#include <QFile>
#include <QDir>
#include <QStandardPaths>
#include <QMouseEvent>
#include <QDropEvent>
#include <QMimeData>
#include <QDrag>
#include <QPixmap>
// SwiftUIQtRenderer — see SwiftUIQtRenderer.h. Fetches the resolved tree via compositor_session_render_tree
// (same size-query convention as compositor_session_state, see SessionWindow::sessionState) and walks it once,
// mapping each `RenderNode` kind to the matching Qt widget. Interactive widgets (Button, Toggle) wire their Qt
// signal straight to compositor_session_dispatch_swiftui_action, by the node's id — the same generic path for
// every panel, no per-panel Qt glue. This is intentionally the *only* place that knows the kind→widget mapping.

#include "SwiftUIQtRenderer.h"
#include "LucideIcons.h"
#include <QSvgRenderer>
#include "PerfTrace.h"
#include <QTimer>
#include <QTextEdit>
#include <QAbstractSpinBox>
#include <QApplication>

#include <QAction>
#include <QBoxLayout>
#include <QCheckBox>
#include <QFont>
#include <QFrame>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMenu>
#include <QLabel>
#include <QComboBox>
#include <QLineEdit>
#include <QPainter>
#include <QPaintEvent>
#include <QPushButton>
#include <QScrollArea>
#include <QIcon>
#include <QPainterPath>
#include <QProgressBar>
#include <QSlider>
#include <QStackedLayout>
#include <QVariant>

extern "C" {
int64_t compositor_session_render_tree(uint64_t handle, const char *panel, uint8_t *output, size_t capacity);
int32_t compositor_session_dispatch_swiftui_action(uint64_t handle, const char *panel, const char *node_id, const char *handler_key,
                                                   const uint8_t *payload, size_t payload_count);
int64_t compositor_session_render_swiftui_canvas(uint64_t handle, const char *panel, const char *node_id, size_t width, size_t height,
                                                 uint8_t *output, size_t capacity);
}

namespace {

/// A `Canvas` node's widget: its `paintEvent` asks Swift to draw into a same-sized `CGContext` (the existing
/// Skia-backed bridge) and blits the result — upstream's `Canvas { context, size in ... }` closure runs unmodified,
/// this is the only Linux-specific code involved, and it is generic across every `Canvas` in every panel.
class SwiftUICanvasWidget : public QWidget {
public:
    SwiftUICanvasWidget(uint64_t handle, QString panel, QString nodeID, QWidget *parent = nullptr)
        : QWidget(parent), m_handle(handle), m_panel(std::move(panel)), m_nodeID(std::move(nodeID)) {}

protected:
    void paintEvent(QPaintEvent *) override {
        const int w = qMax(1, width()), h = qMax(1, height());
        const size_t capacity = static_cast<size_t>(w) * static_cast<size_t>(h) * 4;
        QByteArray bytes(static_cast<qsizetype>(capacity), Qt::Uninitialized);
        const QByteArray panelUtf8 = m_panel.toUtf8(), nodeUtf8 = m_nodeID.toUtf8();
        const int64_t written = compositor_session_render_swiftui_canvas(
            m_handle, panelUtf8.constData(), nodeUtf8.constData(), static_cast<size_t>(w), static_cast<size_t>(h),
            reinterpret_cast<uint8_t *>(bytes.data()), capacity);
        if (written != static_cast<int64_t>(capacity)) return;
        const QImage image(reinterpret_cast<const uchar *>(bytes.constData()), w, h, w * 4, QImage::Format_RGBA8888_Premultiplied);
        QPainter painter(this);
        painter.drawImage(0, 0, image);
    }

private:
    uint64_t m_handle;
    QString m_panel, m_nodeID;
};

} // namespace

/// A small SVG for a style sheet's `image: url(...)`: Qt style sheets take files, not data: URLs, so each image is
/// written once to a per-user runtime directory and referenced by path.
QString styleSheetImage(const QString &name, const QByteArray &svg) {
    static QHash<QString, QString> written;
    if (auto it = written.constFind(name); it != written.constEnd()) return *it;
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation).isEmpty()
        ? QDir::tempPath() + QStringLiteral("/compositor-ui") : QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation) + QStringLiteral("/compositor-ui");
    QDir().mkpath(dir);
    const QString path = dir + QLatin1Char('/') + name + QStringLiteral(".svg");
    QFile file(path);
    if (file.open(QIODevice::WriteOnly | QIODevice::Truncate)) file.write(svg);
    written.insert(name, path);
    return path;
}

QColor parseColorToken(const QString &name) {
    // `Color.x.opacity(a)` arrives as "x+opacity:a" (compat StyleToken): the base color with its alpha scaled.
    if (const int plus = name.lastIndexOf(QLatin1String("+opacity:")); plus > 0) {
        QColor base = parseColorToken(name.left(plus));
        if (base.isValid()) base.setAlphaF(qBound(0.0, base.alphaF() * name.mid(plus + 9).toDouble(), 1.0));
        return base;
    }
    if (name.isEmpty() || name == "clear") return Qt::transparent;
    if (name == "black") return QColor(0, 0, 0);
    if (name == "white") return QColor(255, 255, 255);
    // AppKit's dark-aqua label colors (labelColor, secondaryLabelColor, ...): white at falling opacities.
    if (name == "primary") return QColor(255, 255, 255, 217);
    if (name == "secondary") return QColor(255, 255, 255, 140);
    if (name == "tertiary") return QColor(255, 255, 255, 64);
    if (name == "quaternary") return QColor(255, 255, 255, 26);
    if (name == "accentColor" || name == "accent" || name == "blue") return QColor(0, 122, 255);
    if (name == "red") return QColor(255, 59, 48);
    if (name == "green") return QColor(52, 199, 89);
    if (name == "yellow") return QColor(255, 204, 0);
    if (name.startsWith("rgb:") || name.startsWith("cgColor:")) {
        const QString sub = name.section(':', 1);
        const QStringList parts = sub.split(',');
        if (parts.size() >= 3) {
            const double r = parts[0].toDouble();
            const double g = parts[1].toDouble();
            const double b = parts[2].toDouble();
            const double a = (parts.size() >= 4) ? parts[3].toDouble() : 1.0;
            return QColor::fromRgbF(qBound(0.0, r, 1.0),
                                    qBound(0.0, g, 1.0),
                                    qBound(0.0, b, 1.0),
                                    qBound(0.0, a, 1.0));
        }
    }
    if (name.startsWith("white:")) {   // Color(white:opacity:)
        const QStringList parts = name.section(':', 1).split(',');
        const double w = qBound(0.0, parts.value(0).toDouble(), 1.0);
        return QColor::fromRgbF(w, w, w, qBound(0.0, parts.size() > 1 ? parts[1].toDouble() : 1.0, 1.0));
    }
    if (name.startsWith("hsb:")) {     // Color(hue:saturation:brightness:opacity:), components 0...1
        const QStringList parts = name.section(':', 1).split(',');
        if (parts.size() >= 3) {
            return QColor::fromHsvF(qBound(0.0, parts[0].toDouble(), 1.0), qBound(0.0, parts[1].toDouble(), 1.0),
                                    qBound(0.0, parts[2].toDouble(), 1.0),
                                    qBound(0.0, parts.size() > 3 ? parts[3].toDouble() : 1.0, 1.0));
        }
    }
    if (name.startsWith('#')) {
        return QColor(name);
    }
    return QColor(name);
}

namespace {

class SwiftUIShapeWidget : public QWidget {
public:
    SwiftUIShapeWidget(const QString &shapeKind, double cornerRadius,
                       const QColor &fillColor, const QColor &strokeColor, double strokeWidth,
                       QWidget *parent = nullptr)
        : QWidget(parent), m_shapeKind(shapeKind), m_cornerRadius(cornerRadius),
          m_fillColor(fillColor), m_strokeColor(strokeColor), m_strokeWidth(strokeWidth) {
        setAttribute(Qt::WA_TransparentForMouseEvents, true);
    }

    QSize sizeHint() const override {
        return QSize(width() > 0 ? width() : 32, height() > 0 ? height() : 32);
    }

protected:
    void paintEvent(QPaintEvent *) override {
        QPainter p(this);
        p.setRenderHint(QPainter::Antialiasing, true);

        QRectF rect(0, 0, width(), height());
        if (m_strokeWidth > 0 && m_strokeColor.isValid() && m_strokeColor.alpha() > 0) {
            const qreal half = m_strokeWidth / 2.0;
            rect.adjust(half, half, -half, -half);
        }

        QBrush brush(m_fillColor.isValid() ? m_fillColor : Qt::transparent);
        QPen pen(Qt::NoPen);
        if (m_strokeWidth > 0 && m_strokeColor.isValid() && m_strokeColor.alpha() > 0) {
            pen = QPen(m_strokeColor, m_strokeWidth);
        }

        p.setBrush(brush);
        p.setPen(pen);

        if (m_shapeKind == "circle") {
            p.drawEllipse(rect);
        } else if (m_shapeKind == "roundedRectangle") {
            p.drawRoundedRect(rect, m_cornerRadius, m_cornerRadius);
        } else if (m_shapeKind == "capsule") {
            const qreal r = qMin(rect.width(), rect.height()) / 2.0;
            p.drawRoundedRect(rect, r, r);
        } else {
            p.drawRect(rect);
        }
    }

private:
    QString m_shapeKind;
    double m_cornerRadius;
    QColor m_fillColor;
    QColor m_strokeColor;
    double m_strokeWidth;
};

extern "C" int64_t compositor_swiftui_image(const char *token, int32_t *width, int32_t *height, uint8_t *output, size_t capacity);

/// The panel's resolved tree as the Swift side serialises it (also re-registers its action handlers there).
QByteArray fetchTreeBytes(uint64_t handle, const QString &panel) {
    const QByteArray panelUtf8 = panel.toUtf8();
    const int64_t size = compositor_session_render_tree(handle, panelUtf8.constData(), nullptr, 0);
    if (size <= 0 || size > 4 * 1024 * 1024) return {};
    QByteArray bytes(static_cast<qsizetype>(size), Qt::Uninitialized);
    if (compositor_session_render_tree(handle, panelUtf8.constData(), reinterpret_cast<uint8_t *>(bytes.data()), bytes.size()) != size)
        return {};
    return bytes;
}

QJsonObject fetchTree(uint64_t handle, const QString &panel) {
    const QByteArray bytes = fetchTreeBytes(handle, panel);
    return bytes.isEmpty() ? QJsonObject() : QJsonDocument::fromJson(bytes).object();
}

std::vector<std::function<void(uint64_t, const QString &)>> g_actionListeners;

/// Tells the shell a panel may need refreshing, without dispatching an action (an interaction just ended).
void notifyListeners(uint64_t handle, const QString &panel) {
    for (const auto &cb : g_actionListeners) cb(handle, panel);
}

void dispatch(uint64_t handle, const QString &panel, const QString &nodeID, const QString &handlerKey, const QByteArray &payload = {}) {
    const QByteArray panelUtf8 = panel.toUtf8(), nodeUtf8 = nodeID.toUtf8(), keyUtf8 = handlerKey.toUtf8();
    compositor_session_dispatch_swiftui_action(handle, panelUtf8.constData(), nodeUtf8.constData(), keyUtf8.constData(),
                                               payload.isEmpty() ? nullptr : reinterpret_cast<const uint8_t *>(payload.constData()),
                                               static_cast<size_t>(payload.size()));
    for (const auto &cb : g_actionListeners) {
        cb(handle, panel);
    }
}

QByteArray jsonFragment(const QJsonValue &value) {
    QByteArray array = QJsonDocument(QJsonArray{value}).toJson(QJsonDocument::Compact);
    return array.mid(1, array.size() - 2); // strip the wrapping '[' ']'
}

/// Drag-and-drop for a List whose view asked for it (`compatListDrop`): press a row and drag to move it; the drop
/// lands above the nearer row edge, or into a folder row's middle (highlighted), Alt copies. The List's own handler
/// ("listDrop": [source row, row under the drop, fraction within it, copying]) decides what the drop does.
class ListDragController : public QObject {
public:
    ListDragController(QWidget *content, QList<QWidget *> rows, QString folders, uint64_t handle, QString panel, QString nodeID)
        : QObject(content), m_content(content), m_rows(std::move(rows)), m_folders(std::move(folders)), m_handle(handle),
          m_panel(std::move(panel)), m_nodeID(std::move(nodeID)) {
        content->setAcceptDrops(true);
        content->installEventFilter(this);
        for (int i = 0; i < m_rows.size(); ++i) watch(m_rows[i], i);
        m_indicator = new QFrame(content);
        m_indicator->setAttribute(Qt::WA_TransparentForMouseEvents);
        m_indicator->hide();
    }
protected:
    bool eventFilter(QObject *obj, QEvent *event) override {
        switch (event->type()) {
        case QEvent::MouseButtonPress: {
            auto *e = static_cast<QMouseEvent *>(event);
            if (e->button() == Qt::LeftButton && obj->property("listRow").isValid()) {
                m_pressRow = obj->property("listRow").toInt();
                m_pressPos = e->globalPosition().toPoint();
            }
            break;
        }
        case QEvent::MouseMove: {
            auto *e = static_cast<QMouseEvent *>(event);
            if (m_pressRow < 0 || !(e->buttons() & Qt::LeftButton)) break;
            if ((e->globalPosition().toPoint() - m_pressPos).manhattanLength() < QApplication::startDragDistance()) break;
            const int source = m_pressRow;
            m_pressRow = -1;
            auto *drag = new QDrag(m_content);
            auto *mime = new QMimeData;
            mime->setData("application/x-compositor-list-row", QByteArray::number(source));
            drag->setMimeData(mime);
            if (source < m_rows.size()) {
                const QPixmap snapshot = m_rows[source]->grab();
                drag->setPixmap(snapshot);
                drag->setHotSpot(m_rows[source]->mapFromGlobal(e->globalPosition().toPoint()));
            }
            drag->exec(Qt::MoveAction | Qt::CopyAction, Qt::MoveAction);
            m_indicator->hide();
            return true;
        }
        case QEvent::MouseButtonRelease:
            m_pressRow = -1;
            break;
        case QEvent::DragEnter:
        case QEvent::DragMove: {
            if (obj != m_content) break;
            auto *e = static_cast<QDropEvent *>(event);
            if (!e->mimeData()->hasFormat("application/x-compositor-list-row")) break;
            e->setDropAction((e->modifiers() & Qt::AltModifier) ? Qt::CopyAction : Qt::MoveAction);
            e->accept();
            showIndicator(e->position().toPoint());
            return true;
        }
        case QEvent::DragLeave:
            if (obj == m_content) m_indicator->hide();
            break;
        case QEvent::Drop: {
            if (obj != m_content) break;
            auto *e = static_cast<QDropEvent *>(event);
            if (!e->mimeData()->hasFormat("application/x-compositor-list-row")) break;
            const int source = e->mimeData()->data("application/x-compositor-list-row").toInt();
            const auto [row, fraction] = locate(e->position().toPoint());
            const bool copying = e->modifiers() & Qt::AltModifier;
            e->setDropAction(copying ? Qt::CopyAction : Qt::MoveAction);
            e->accept();
            m_indicator->hide();
            const QByteArray payload = QJsonDocument(QJsonArray{source, row, fraction, copying}).toJson(QJsonDocument::Compact);
            // After this event returns: the handler rebuilds the panel, which deletes these rows.
            const uint64_t handle = m_handle; const QString panel = m_panel, node = m_nodeID;
            QTimer::singleShot(0, [handle, panel, node, payload] { dispatch(handle, panel, node, QStringLiteral("listDrop"), payload); });
            return true;
        }
        default: break;
        }
        return QObject::eventFilter(obj, event);
    }
private:
    void watch(QWidget *widget, int row) {
        widget->setProperty("listRow", row);
        widget->installEventFilter(this);
        for (QWidget *child : widget->findChildren<QWidget *>()) { child->setProperty("listRow", row); child->installEventFilter(this); }
    }
    /// The row under `pos` (content coordinates) and where in it (0 top ... 1 bottom); past the last row: rows.size().
    std::pair<int, double> locate(const QPoint &pos) const {
        for (int i = 0; i < m_rows.size(); ++i) {
            const QRect r = m_rows[i]->geometry();
            if (pos.y() < r.bottom() + 1) return {i, r.height() > 0 ? std::clamp(double(pos.y() - r.top()) / r.height(), 0.0, 1.0) : 0.5};
        }
        return {int(m_rows.size()), 0.0};
    }
    void showIndicator(const QPoint &pos) {
        const auto [row, fraction] = locate(pos);
        const bool folder = row < m_rows.size() && row < m_folders.size() && m_folders[row] == QLatin1Char('1');
        if (folder && fraction >= 0.25 && fraction <= 0.75) {   // into the folder: its row outlined
            m_indicator->setStyleSheet("background: rgba(0, 122, 255, 0.18); border: 2px solid #007aff; border-radius: 5px;");
            m_indicator->setGeometry(m_rows[row]->geometry());
        } else {                                                // between rows: a line at the nearer edge
            const int y = row >= m_rows.size() ? (m_rows.isEmpty() ? 0 : m_rows.last()->geometry().bottom() + 1)
                        : (fraction < 0.5 ? m_rows[row]->geometry().top() : m_rows[row]->geometry().bottom() + 1);
            m_indicator->setStyleSheet("background: #007aff; border: none; border-radius: 1px;");
            m_indicator->setGeometry(4, y - 1, m_content->width() - 8, 2);
        }
        m_indicator->raise();
        m_indicator->show();
    }
    QWidget *m_content;
    QList<QWidget *> m_rows;
    QString m_folders;
    uint64_t m_handle;
    QString m_panel, m_nodeID;
    QFrame *m_indicator = nullptr;
    int m_pressRow = -1;
    QPoint m_pressPos;
};

/// A view that records a key (compatKeyCapture, e.g. a shortcut being rebound): while it exists, the next key pressed
/// anywhere in the app goes to it — as ShortcutChord takes keys ("a", "\r", "\u{f702}"…; "" for Esc = cancel) and
/// modifiers (Ctrl 1, Alt 2, Meta 4, Shift 8: Linux's Command / Option / Control / Shift) — instead of its usual target.
class KeyCaptureFilter : public QObject {
public:
    KeyCaptureFilter(QWidget *owner, uint64_t handle, QString panel, QString nodeID)
        : QObject(owner), m_handle(handle), m_panel(std::move(panel)), m_nodeID(std::move(nodeID)) { qApp->installEventFilter(this); }
protected:
    bool eventFilter(QObject *, QEvent *event) override {
        if (m_done || event->type() != QEvent::KeyPress) return false;
        auto *e = static_cast<QKeyEvent *>(event);
        const int k = e->key();
        if (k == Qt::Key_Control || k == Qt::Key_Shift || k == Qt::Key_Alt || k == Qt::Key_Meta || k == Qt::Key_AltGr || e->isAutoRepeat()) return true;
        QString key;
        switch (k) {
        case Qt::Key_Escape: key = QString(); break;
        case Qt::Key_Backspace: case Qt::Key_Delete: key = QStringLiteral("\x7f"); break;
        case Qt::Key_Return: case Qt::Key_Enter: key = QStringLiteral("\r"); break;
        case Qt::Key_Tab: case Qt::Key_Backtab: key = QStringLiteral("\t"); break;
        case Qt::Key_Space: key = QStringLiteral(" "); break;
        case Qt::Key_Left: key = QString(QChar(0xf702)); break;
        case Qt::Key_Right: key = QString(QChar(0xf703)); break;
        case Qt::Key_Down: key = QString(QChar(0xf701)); break;
        case Qt::Key_Up: key = QString(QChar(0xf700)); break;
        default: {
            // The unshifted character, as ShortcutChord stores it ("{" -> "[", "+" -> "=", "_" -> "-").
            QString typed = (k >= 0x20 && k < 0x7f) ? QString(QChar(k)).toLower() : e->text().toLower();
            static const QHash<QString, QString> unshift{{"{", "["}, {"}", "]"}, {"+", "="}, {"_", "-"}};
            key = unshift.value(typed, typed);
            if (key.isEmpty()) return true;   // a key with no character (F-keys, …): keep waiting
        }
        }
        const Qt::KeyboardModifiers m = e->modifiers();
        const int modifiers = (m & Qt::ControlModifier ? 1 : 0) | (m & Qt::AltModifier ? 2 : 0) | (m & Qt::MetaModifier ? 4 : 0)
                            | (m & Qt::ShiftModifier ? 8 : 0);
        m_done = true;
        const QByteArray payload = QJsonDocument(QJsonArray{key, modifiers}).toJson(QJsonDocument::Compact);
        const uint64_t handle = m_handle; const QString panel = m_panel, node = m_nodeID;
        QTimer::singleShot(0, [handle, panel, node, payload] { dispatch(handle, panel, node, QStringLiteral("keyCapture"), payload); });
        return true;
    }
private:
    uint64_t m_handle;
    QString m_panel, m_nodeID;
    bool m_done = false;
};

class TapGestureFilter : public QObject {
public:
    /// `onTap` gets the click's modifier keys as ShortcutChord bits (Ctrl 1, Alt 2, Meta 4, Shift 8).
    TapGestureFilter(QObject *parent, std::function<void(int)> onTap)
        : QObject(parent), m_onTap(std::move(onTap)) {}
protected:
    bool eventFilter(QObject *obj, QEvent *event) override {
        if (event->type() == QEvent::MouseButtonRelease) {
            auto *me = static_cast<QMouseEvent *>(event);
            if (me->button() == Qt::LeftButton) {
                const Qt::KeyboardModifiers m = me->modifiers();
                const int bits = (m & Qt::ControlModifier ? 1 : 0) | (m & Qt::AltModifier ? 2 : 0) | (m & Qt::MetaModifier ? 4 : 0)
                               | (m & Qt::ShiftModifier ? 8 : 0);
                if (m_onTap) m_onTap(bits);
                return true;
            }
        }
        return QObject::eventFilter(obj, event);
    }
private:
    std::function<void(int)> m_onTap;
};

/// SwiftUI's `.contextMenu`: the view's items (compat resolves them into "contextMenu" JSON) as a QMenu on right-click;
/// the chosen item's index goes back to the view, which runs that item's action.
static void buildContextMenu(QMenu *menu, const QJsonArray &items, const std::function<void(int)> &choose) {
    for (const QJsonValue &value : items) {
        const QJsonObject item = value.toObject();
        if (item.value("separator").toBool()) { menu->addSeparator(); continue; }
        if (item.contains("items")) {
            QMenu *sub = menu->addMenu(item.value("title").toString());
            sub->setEnabled(item.value("enabled").toBool(true));
            buildContextMenu(sub, item.value("items").toArray(), choose);
            continue;
        }
        QAction *action = menu->addAction(item.value("title").toString());
        action->setEnabled(item.value("enabled").toBool(true));
        const int index = item.value("index").toInt(-1);
        QObject::connect(action, &QAction::triggered, menu, [choose, index] { choose(index); });
    }
}

} // namespace

QIcon renderToolVectorIcon(const QString &symbol, int size, const QColor &color) {
    // SF Symbols by their upstream names, drawn from Lucide (the open stand-in; host/LucideIcons.h), at the device's
    // resolution; a 1.75-unit stroke on the 24-unit grid sits close to SF's regular weight.
    if (const QByteArray svg = lucideIconSVG(symbol); !svg.isEmpty()) {
        QByteArray tinted = svg;
        tinted.replace("currentColor", color.name(QColor::HexRgb).toLatin1());
        tinted.replace("stroke-width=\"2\"", QByteArrayLiteral("stroke-width=\"1.75\" stroke-opacity=\"") + QByteArray::number(color.alphaF()) + '"');
        const qreal dpr = qApp ? std::max<qreal>(qApp->devicePixelRatio(), 2.0) : 2.0;
        QPixmap pixmap(QSize(size, size) * dpr);
        pixmap.setDevicePixelRatio(dpr);
        pixmap.fill(Qt::transparent);
        QPainter painter(&pixmap);
        QSvgRenderer(tinted).render(&painter, QRectF(0, 0, size, size));
        painter.end();
        return QIcon(pixmap);
    }
    QPixmap pix(size, size);
    pix.fill(Qt::transparent);
    QPainter p(&pix);
    p.setRenderHint(QPainter::Antialiasing, true);

    const qreal s = size / 20.0;
    p.scale(s, s);

    if (symbol == "arrow.up.left.and.arrow.down.right" || symbol == "move") {
        p.setPen(QPen(color, 1.6, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p.drawLine(5, 5, 15, 15);
        p.drawLine(5, 5, 10, 5);
        p.drawLine(5, 5, 5, 10);
        p.drawLine(15, 15, 10, 15);
        p.drawLine(15, 15, 15, 10);
    } else if (symbol.contains("circle.dashed")) {
        QPen dashPen(color, 1.5, Qt::CustomDashLine, Qt::SquareCap);
        dashPen.setDashPattern({2, 2});
        p.setPen(dashPen);
        p.drawEllipse(QRectF(3, 3, 14, 14));
    } else if (symbol.contains("rectangle.dashed") || symbol == "marquee") {
        QPen dashPen(color, 1.5, Qt::CustomDashLine, Qt::SquareCap);
        dashPen.setDashPattern({2, 2});
        p.setPen(dashPen);
        p.drawRoundedRect(QRectF(3, 3, 14, 14), 1, 1);
    } else if (symbol.contains("lasso")) {
        p.setPen(QPen(color, 1.5, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        QPainterPath path;
        path.moveTo(5, 8);
        path.cubicTo(5, 3, 16, 3, 16, 9);
        path.cubicTo(16, 15, 11, 16, 8, 14);
        path.lineTo(4, 17);
        p.drawPath(path);
        p.drawLine(6, 13, 9, 16);
    } else if (symbol.contains("wand")) {
        p.setPen(QPen(color, 1.6, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p.drawLine(3, 17, 13, 7);
        p.drawLine(12, 6, 14, 8);
        p.setPen(QPen(color, 1.2, Qt::SolidLine, Qt::RoundCap));
        p.drawLine(16, 2, 16, 6); p.drawLine(14, 4, 18, 4);
        p.drawLine(8, 2, 8, 4); p.drawLine(7, 3, 9, 3);
        p.drawLine(17, 9, 17, 11); p.drawLine(16, 10, 18, 10);
    } else if (symbol == "crop") {
        p.setPen(QPen(color, 1.6, Qt::SolidLine, Qt::SquareCap, Qt::MiterJoin));
        p.drawLine(2, 6, 14, 6);
        p.drawLine(6, 2, 6, 14);
        p.drawLine(6, 14, 18, 14);
        p.drawLine(14, 6, 14, 18);
    } else if (symbol.contains("eraser")) {
        p.setPen(QPen(color, 1.5, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p.save();
        p.translate(10, 10);
        p.rotate(-30);
        p.drawRoundedRect(QRectF(-6, -4, 12, 8), 2, 2);
        p.drawLine(-1, -4, -1, 4);
        p.restore();
    } else if (symbol.contains("paintbrush") || symbol == "brush") {
        p.setPen(QPen(color, 1.5, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        QPainterPath b;
        b.moveTo(4, 16);
        b.cubicTo(3, 13, 6, 10, 9, 9);
        b.lineTo(11, 11);
        b.cubicTo(10, 14, 7, 17, 4, 16);
        p.setBrush(color);
        p.drawPath(b);
        p.setBrush(Qt::NoBrush);
        p.drawLine(9, 9, 15, 3);
        p.drawLine(11, 11, 17, 5);
        p.drawLine(15, 3, 17, 5);
    } else if (symbol.contains("bandage") || symbol == "spotHealing") {
        p.setPen(QPen(color, 1.5, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p.save();
        p.translate(10, 10);
        p.rotate(45);
        p.drawRoundedRect(QRectF(-4, -8, 8, 16), 3, 3);
        p.setPen(QPen(color, 1.5, Qt::SolidLine, Qt::RoundCap));
        p.drawPoint(-1, -1); p.drawPoint(1, 1);
        p.drawPoint(-1, 1); p.drawPoint(1, -1);
        p.restore();
    } else if (symbol.contains("seal") || symbol == "cloneStamp") {
        p.setPen(QPen(color, 1.5, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p.drawEllipse(8, 2, 4, 4);
        p.drawLine(10, 6, 10, 11);
        p.drawRoundedRect(QRectF(4, 11, 12, 4), 1.5, 1.5);
        p.fillRect(QRectF(3, 15, 14, 2), color);
    } else if (symbol == "drop" || symbol == "smear" || symbol == "blur") {
        p.setPen(QPen(color, 1.5, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        QPainterPath drop;
        drop.moveTo(10, 3);
        drop.cubicTo(10, 3, 4, 10, 4, 13);
        drop.arcTo(QRectF(4, 7, 12, 12), 180, 180);
        drop.cubicTo(16, 10, 10, 3, 10, 3);
        p.drawPath(drop);
    } else if (symbol.contains("square.bottomhalf.filled") || symbol == "gradient") {
        p.setPen(QPen(color, 1.5, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p.drawRoundedRect(QRectF(3, 3, 14, 14), 2, 2);
        p.fillRect(QRectF(3, 10, 14, 7), color);
    } else if (symbol.contains("square.on.circle") || symbol == "shape") {
        p.setPen(QPen(color, 1.5, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p.drawEllipse(QRectF(7, 7, 10, 10));
        p.drawRoundedRect(QRectF(3, 3, 9, 9), 1, 1);
    } else if (symbol.contains("textformat") || symbol == "type") {
        p.setPen(QPen(color, 1.8, Qt::SolidLine, Qt::SquareCap, Qt::MiterJoin));
        p.drawLine(4, 4, 16, 4);
        p.drawLine(10, 4, 10, 16);
        p.drawLine(7, 16, 13, 16);
    } else if (symbol.contains("eyedropper")) {
        p.setPen(QPen(color, 1.5, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p.drawLine(4, 16, 7, 13);
        p.drawLine(7, 13, 13, 7);
        p.drawLine(13, 7, 15, 9);
        p.drawLine(15, 9, 9, 15);
        p.drawLine(9, 15, 4, 16);
        p.drawLine(13, 7, 16, 4);
        p.drawEllipse(15, 3, 3, 3);
    } else if (symbol.contains("hand.draw") || symbol == "hand") {
        p.setPen(QPen(color, 1.5, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p.drawRoundedRect(QRectF(5, 8, 9, 10), 2, 2);
        p.drawLine(7, 4, 7, 8);
        p.drawLine(9, 3, 9, 8);
        p.drawLine(11, 4, 11, 8);
        p.drawLine(13, 6, 13, 8);
        p.drawLine(4, 10, 4, 13);
    } else if (symbol.contains("plus.magnifyingglass")) {
        p.setPen(QPen(color, 1.5, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p.drawEllipse(QRectF(3.5, 3.5, 9.5, 9.5));
        p.drawLine(QPointF(10.5, 10.5), QPointF(16, 16));
        p.drawLine(QPointF(8.25, 5.5), QPointF(8.25, 11));
        p.drawLine(QPointF(5.5, 8.25), QPointF(11, 8.25));
    } else if (symbol.contains("minus.magnifyingglass")) {
        p.setPen(QPen(color, 1.5, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p.drawEllipse(QRectF(3.5, 3.5, 9.5, 9.5));
        p.drawLine(QPointF(10.5, 10.5), QPointF(16, 16));
        p.drawLine(QPointF(5.5, 8.25), QPointF(11, 8.25));
    } else if (symbol.contains("magnifyingglass") || symbol == "zoom") {
        p.setPen(QPen(color, 1.6, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p.drawEllipse(QRectF(4, 4, 9, 9));
        p.drawLine(11, 11, 16, 16);
    } else if (symbol.contains("arrow.left.and.right")) {
        p.setPen(QPen(color, 1.3, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p.drawLine(3, 7, 13, 7);
        p.drawLine(11, 5, 13, 7); p.drawLine(11, 9, 13, 7);
        p.drawLine(13, 11, 3, 11);
        p.drawLine(5, 9, 3, 11); p.drawLine(5, 13, 3, 11);
    } else if (symbol.contains("arrow.counterclockwise")) {
        p.setPen(QPen(color, 1.3, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p.drawArc(QRectF(3, 3, 10, 10), 45 * 16, 270 * 16);
        p.drawLine(10, 2, 10, 5); p.drawLine(10, 2, 13, 2);
    } else if (symbol.contains("plus.square")) {
        p.setPen(QPen(color, 1.4, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p.drawRoundedRect(QRectF(3.5, 3.5, 13, 13), 2, 2);
        p.drawLine(QPointF(10, 6.5), QPointF(10, 13.5));
        p.drawLine(QPointF(6.5, 10), QPointF(13.5, 10));
    } else if (symbol.contains("folder.badge.plus")) {
        p.setPen(QPen(color, 1.3, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        QPainterPath f;
        f.moveTo(3, 6); f.lineTo(7, 6); f.lineTo(8.5, 7.5); f.lineTo(17, 7.5); f.lineTo(17, 14); f.lineTo(3, 14); f.closeSubpath();
        p.drawPath(f);
        p.setPen(QPen(color, 1.5, Qt::SolidLine, Qt::RoundCap));
        p.drawLine(14, 11, 14, 17);
        p.drawLine(11, 14, 17, 14);
    } else if (symbol == "folder" || symbol.contains("folder")) {
        p.setPen(QPen(color, 1.3, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        QPainterPath f;
        f.moveTo(3, 6); f.lineTo(7, 6); f.lineTo(8.5, 7.5); f.lineTo(17, 7.5); f.lineTo(17, 14.5); f.lineTo(3, 14.5); f.closeSubpath();
        p.drawPath(f);
    } else if (symbol.contains("circle.lefthalf.filled")) {
        p.setPen(QPen(color, 1.4, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p.drawEllipse(QRectF(3.5, 3.5, 13, 13));
        QPainterPath half;
        half.moveTo(10, 3.5);
        half.arcTo(QRectF(3.5, 3.5, 13, 13), 90, 180);
        half.closeSubpath();
        p.fillPath(half, color);
    } else if (symbol.contains("trash")) {
        p.setPen(QPen(color, 1.3, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p.drawLine(QPointF(4, 5.5), QPointF(16, 5.5));
        p.drawLine(QPointF(8, 3.5), QPointF(12, 3.5));
        p.drawRoundedRect(QRectF(5.5, 6, 9, 10.5), 1, 1);
        p.drawLine(QPointF(8.5, 8), QPointF(8.5, 14));
        p.drawLine(QPointF(11.5, 8), QPointF(11.5, 14));
    } else if (symbol.contains("sparkles")) {
        p.setPen(Qt::NoPen);
        p.setBrush(color);
        QPainterPath sp;
        sp.moveTo(10, 2);
        sp.quadTo(10, 9, 17, 9);
        sp.quadTo(10, 9, 10, 16);
        sp.quadTo(10, 9, 3, 9);
        sp.quadTo(10, 9, 10, 2);
        p.drawPath(sp);
        QPainterPath s2;
        s2.moveTo(15, 12);
        s2.quadTo(15, 15, 18, 15);
        s2.quadTo(15, 15, 15, 18);
        s2.quadTo(15, 15, 12, 15);
        s2.quadTo(15, 15, 15, 12);
        p.drawPath(s2);
    } else if (symbol.contains("link")) {
        p.setPen(QPen(color, 1.4, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p.drawRoundedRect(QRectF(4, 7, 7, 6), 3, 3);
        p.drawRoundedRect(QRectF(9, 7, 7, 6), 3, 3);
    } else if (symbol == "chevron.down" || symbol == "chevron.right" || symbol == "chevron.left" || symbol == "chevron.up") {
        p.setPen(QPen(color, 2.0, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        QPolygonF v;
        if (symbol == "chevron.down") v << QPointF(5, 7.5) << QPointF(10, 12.5) << QPointF(15, 7.5);
        else if (symbol == "chevron.up") v << QPointF(5, 12.5) << QPointF(10, 7.5) << QPointF(15, 12.5);
        else if (symbol == "chevron.right") v << QPointF(7.5, 5) << QPointF(12.5, 10) << QPointF(7.5, 15);
        else v << QPointF(12.5, 5) << QPointF(7.5, 10) << QPointF(12.5, 15);
        p.drawPolyline(v);
    } else if (symbol == "text.alignleft" || symbol == "text.aligncenter" || symbol == "text.alignright") {
        // Four lines of text, long and short alternating, flush to the alignment's edge.
        p.setPen(QPen(color, 1.6, Qt::SolidLine, Qt::RoundCap));
        const double widths[4] = {14, 9, 14, 9};
        for (int i = 0; i < 4; ++i) {
            const double w = widths[i], y = 5 + i * 3.4;
            const double x = symbol == "text.alignleft" ? 3 : symbol == "text.alignright" ? 17 - w : 10 - w / 2;
            p.drawLine(QPointF(x, y), QPointF(x + w, y));
        }
    } else if (symbol == "triangle.fill") {
        p.setPen(Qt::NoPen);
        p.setBrush(color);
        p.drawPolygon(QPolygonF({QPointF(10, 4), QPointF(17, 16), QPointF(3, 16)}));
    } else if (symbol == "eye") {
        p.setPen(QPen(color, 1.3, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        QPainterPath e;
        e.moveTo(3, 10);
        e.quadTo(10, 4.5, 17, 10);
        e.quadTo(10, 15.5, 3, 10);
        p.drawPath(e);
        p.setBrush(color);
        p.drawEllipse(QRectF(8.5, 8.5, 3, 3));
    } else if (symbol.contains("eye.slash")) {
        p.setPen(QPen(color, 1.3, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        QPainterPath e;
        e.moveTo(3, 10);
        e.quadTo(10, 4.5, 17, 10);
        e.quadTo(10, 15.5, 3, 10);
        p.drawPath(e);
        p.drawLine(4, 16, 16, 4);
    } else if (symbol.contains("slider.horizontal.3")) {
        p.setPen(QPen(color, 1.3, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p.drawLine(3, 6, 17, 6);
        p.drawLine(3, 10, 17, 10);
        p.drawLine(3, 14, 17, 14);
        p.setBrush(color);
        p.drawEllipse(QRectF(6, 4.5, 3, 3));
        p.drawEllipse(QRectF(11, 8.5, 3, 3));
        p.drawEllipse(QRectF(7, 12.5, 3, 3));
    } else if (symbol.contains("slider.horizontal.2.square")) {
        p.setPen(QPen(color, 1.3, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p.drawRoundedRect(QRectF(3, 3, 14, 14), 2, 2);
        p.drawLine(5, 7, 15, 7);
        p.drawLine(5, 13, 15, 13);
        p.setBrush(color);
        p.drawEllipse(QRectF(7, 5.5, 3, 3));
        p.drawEllipse(QRectF(11, 11.5, 3, 3));
    } else if (symbol.contains("rectangle.inset.filled")) {
        p.setPen(QPen(color, 1.3, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p.drawRoundedRect(QRectF(3, 3, 14, 14), 2, 2);
        p.fillRect(QRectF(6, 6, 8, 8), color);
    } else if (symbol.contains("square.3.layers.3d")) {
        p.setPen(QPen(color, 1.3, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        auto drawDiamond = [&](qreal y) {
            QPainterPath d;
            d.moveTo(10, y); d.lineTo(17, y + 3.5); d.lineTo(10, y + 7); d.lineTo(3, y + 3.5); d.closeSubpath();
            p.drawPath(d);
        };
        drawDiamond(3);
        drawDiamond(7);
        drawDiamond(11);
    } else if (symbol == "xmark" || symbol == "multiply") {
        p.setPen(QPen(color, 1.6, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p.drawLine(5, 5, 15, 15);
        p.drawLine(15, 5, 5, 15);
    } else {
        p.setPen(QPen(color, 1.5, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p.drawRect(4, 4, 12, 12);
    }
    p.end();
    return QIcon(pix);
}

namespace {

/// AppKit's disabled controls in dark aqua: tertiary text, faded chrome.
const QString &disabledStyleSheet() {
    static const QString qss = QStringLiteral(
        "QPushButton:disabled { color: rgba(255, 255, 255, 0.25); background-color: rgba(255, 255, 255, 0.05); border-color: rgba(255, 255, 255, 0.06); } "
        "QLineEdit:disabled, QComboBox:disabled, QSpinBox:disabled, QDoubleSpinBox:disabled { color: rgba(255, 255, 255, 0.25); "
        "background-color: rgba(255, 255, 255, 0.03); border-color: rgba(255, 255, 255, 0.08); } "
        "QCheckBox:disabled, QLabel:disabled { color: rgba(255, 255, 255, 0.25); } "
        "QCheckBox::indicator:disabled { background-color: rgba(255, 255, 255, 0.04); border-color: rgba(255, 255, 255, 0.10); } "
        "QCheckBox::indicator:checked:disabled { background-color: rgba(0, 122, 255, 0.35); border-color: rgba(0, 122, 255, 0.35); }");
    return qss;
}

/// Applies the modifiers this first pass understands (the highest-frequency ones, per the plan); an unrecognised
/// modifier kind is silently skipped rather than failing the whole render — additive coverage, not all-or-nothing.
void applyModifiers(QWidget *widget, const QJsonArray &modifiers) {
    for (const auto &entry : modifiers) {
        const QJsonObject modifier = entry.toObject();
        const QString kind = modifier.value("kind").toString();
        const QJsonObject doubles = modifier.value("doubleParams").toObject();
        const QJsonObject strings = modifier.value("stringParams").toObject();
        const QJsonObject bools = modifier.value("boolParams").toObject();
        if (kind == "frame") {
            if (doubles.contains("width")) widget->setFixedWidth(static_cast<int>(doubles.value("width").toDouble()));
            if (doubles.contains("height")) widget->setFixedHeight(static_cast<int>(doubles.value("height").toDouble()));
            // minWidth / minHeight hold as minimums; maxWidth / maxHeight .infinity (sent as flags: JSON has no
            // infinity) let the view grow to fill its row / column, as SwiftUI does.
            if (doubles.contains("minWidth")) widget->setMinimumWidth(static_cast<int>(doubles.value("minWidth").toDouble()));
            if (doubles.contains("minHeight")) widget->setMinimumHeight(static_cast<int>(doubles.value("minHeight").toDouble()));
            if (doubles.contains("maxWidth")) widget->setMaximumWidth(static_cast<int>(doubles.value("maxWidth").toDouble()));
            if (doubles.contains("maxHeight")) widget->setMaximumHeight(static_cast<int>(doubles.value("maxHeight").toDouble()));
            QSizePolicy policy = widget->sizePolicy();
            const bool growsH = bools.value("maxWidthInfinity").toBool(), growsV = bools.value("maxHeightInfinity").toBool();
            if (growsH) policy.setHorizontalPolicy(QSizePolicy::Expanding);
            if (growsV) policy.setVerticalPolicy(QSizePolicy::Expanding);
            widget->setSizePolicy(policy);
            // The content sits in the frame at the frame's alignment (center by default), not stretched to fill it.
            const QString alignment = strings.value("alignment").toString();
            Qt::Alignment h = Qt::AlignHCenter, v = Qt::AlignVCenter;
            if (alignment.contains(QLatin1String("eading"))) h = Qt::AlignLeft;
            else if (alignment.contains(QLatin1String("railing"))) h = Qt::AlignRight;
            if (alignment.startsWith(QLatin1String("top"))) v = Qt::AlignTop;
            else if (alignment.startsWith(QLatin1String("bottom"))) v = Qt::AlignBottom;
            if (auto *label = qobject_cast<QLabel *>(widget)) {
                label->setAlignment(h | v);
            } else if (QLayout *layout = widget->layout(); layout && (growsH || growsV)) {
                // Only along an axis nothing inside stretches in (a Spacer, a flexible field): then the stack keeps
                // its own size there and is placed.
                const Qt::Orientations expanding = layout->expandingDirections();
                Qt::Alignment placed;
                if (growsH && !(expanding & Qt::Horizontal)) placed |= h;
                if (growsV && !(expanding & Qt::Vertical)) placed |= v;
                if (placed) layout->setAlignment(placed);
            }
        } else if (kind == "padding") {
            // Paddings nest (.padding(.horizontal, 8).padding(.vertical, 4) pads both), so each adds to what is there.
            const QMargins add(static_cast<int>(doubles.value("leading").toDouble()), static_cast<int>(doubles.value("top").toDouble()),
                               static_cast<int>(doubles.value("trailing").toDouble()), static_cast<int>(doubles.value("bottom").toDouble()));
            if (auto *layout = widget->layout()) layout->setContentsMargins(layout->contentsMargins() + add);
            else widget->setContentsMargins(widget->contentsMargins() + add);
        } else if (kind == "font") {
            // Compat font tokens: "<base>[+weight:<w>][+bold][+monospacedDigit][+design:<d>]", base a text style or
            // "system:<size>". Set with setFont, so it reaches every child that has no font of its own (SwiftUI's
            // environment font).
            const QStringList parts = strings.value("name").toString().split(QLatin1Char('+'));
            QFont font = widget->font();
            static const QHash<QString, std::pair<int, QFont::Weight>> styles{
                {"largeTitle", {26, QFont::Normal}}, {"title", {22, QFont::Normal}}, {"title2", {17, QFont::Normal}},
                {"title3", {15, QFont::Normal}}, {"headline", {13, QFont::Bold}}, {"subheadline", {11, QFont::Normal}},
                {"body", {13, QFont::Normal}}, {"callout", {12, QFont::Normal}}, {"footnote", {10, QFont::Normal}},
                {"caption", {10, QFont::Normal}}, {"caption2", {10, QFont::Normal}}};
            static const QHash<QString, QFont::Weight> weights{
                {"ultraLight", QFont::ExtraLight}, {"thin", QFont::Thin}, {"light", QFont::Light}, {"regular", QFont::Normal},
                {"medium", QFont::Medium}, {"semibold", QFont::DemiBold}, {"bold", QFont::Bold}, {"heavy", QFont::ExtraBold},
                {"black", QFont::Black}};
            const QString base = parts.value(0);
            if (base.startsWith(QLatin1String("system:"))) {
                font.setPixelSize(qMax(1, qRound(base.mid(7).toDouble())));
                font.setWeight(QFont::Normal);
            } else if (auto it = styles.constFind(base); it != styles.constEnd()) {
                font.setPixelSize(it->first);
                font.setWeight(it->second);
            }
            for (const QString &part : parts.mid(1)) {
                if (part.startsWith(QLatin1String("weight:"))) font.setWeight(weights.value(part.mid(7), QFont::Normal));
                else if (part == QLatin1String("bold")) font.setWeight(QFont::Bold);
                else if (part == QLatin1String("monospacedDigit")) font.setFeature(QFont::Tag("tnum"), 1);
                else if (part == QLatin1String("design:monospaced")) font.setFamilies({QStringLiteral("DejaVu Sans Mono"), QStringLiteral("monospace")});
            }
            widget->setFont(font);
        } else if (kind == "multilineTextAlignment") {
            // Text wraps to the space it is given and lines up at this alignment.
            const QString name = strings.value("name").toString();
            const Qt::Alignment h = name == QLatin1String("center") ? Qt::AlignHCenter
                                  : name == QLatin1String("trailing") ? Qt::AlignRight : Qt::AlignLeft;
            QList<QLabel *> labels = widget->findChildren<QLabel *>();
            if (auto *self = qobject_cast<QLabel *>(widget)) labels.prepend(self);
            for (QLabel *label : labels) {
                if (label->pixmap().isNull()) {
                    label->setAlignment(h | Qt::AlignVCenter);
                    label->setWordWrap(true);
                    // It takes the width it is offered and wraps only past it, as SwiftUI's Text does.
                    label->setSizePolicy(QSizePolicy::Expanding, label->sizePolicy().verticalPolicy());
                }
            }
        } else if (kind == "textFieldStyle") {
            // .plain: the bare text, no bezel (upstream draws its own background around it); .roundedBorder: the bezel.
            if (strings.value("name").toString() == QLatin1String("plain")) {
                QList<QLineEdit *> fields = widget->findChildren<QLineEdit *>();
                if (auto *self = qobject_cast<QLineEdit *>(widget)) fields.prepend(self);
                for (QLineEdit *field : fields) {
                    if (field->property("fieldStyled").toBool()) continue;
                    field->setProperty("fieldStyled", true);
                    field->setFrame(false);
                    field->setStyleSheet(QStringLiteral("QLineEdit { background: transparent; border: none; padding: 0px; } "
                                                        "QLineEdit:disabled { color: rgba(255, 255, 255, 0.25); }"));
                }
            }
        } else if (kind == "buttonStyle") {
            // Text buttons below take the style (the innermost .buttonStyle wins); icon buttons keep their own look.
            const QString name = strings.value("name").toString();
            QString qss;
            if (name == QLatin1String("borderedProminent"))
                qss = QStringLiteral("QPushButton { background-color: #0a84ff; color: #ffffff; border: none; border-radius: 5px; padding: 3px 10px; } "
                                     "QPushButton:hover { background-color: #2a93ff; } QPushButton:pressed { background-color: #0a6fd6; } "
                                     "QPushButton:disabled { background-color: rgba(255, 255, 255, 0.08); color: rgba(255, 255, 255, 0.25); }");
            else if (name == QLatin1String("plain") || name == QLatin1String("borderless"))
                qss = QStringLiteral("QPushButton { background: transparent; border: none; padding: 0px; } "
                                     "QPushButton:disabled { color: rgba(255, 255, 255, 0.25); }");
            if (!qss.isEmpty()) {
                QList<QPushButton *> buttons = widget->findChildren<QPushButton *>();
                if (auto *self = qobject_cast<QPushButton *>(widget)) buttons.prepend(self);
                for (QPushButton *button : buttons) {
                    if (button->property("buttonStyled").toBool() || button->text().isEmpty() || button->isCheckable()) continue;
                    button->setProperty("buttonStyled", true);
                    button->setStyleSheet(qss);
                }
            }
        } else if (kind == "controlSize") {
            // AppKit control sizes carry their own text size: small 11, mini 9 (regular keeps the environment's).
            const QString size = strings.value("name").toString();
            if (size == QLatin1String("small") || size == QLatin1String("mini")) {
                QFont font = widget->font();
                font.setPixelSize(size == QLatin1String("small") ? 11 : 9);
                widget->setFont(font);
            }
        } else if (kind == "disabled") {
            const bool disabled = bools.value("value").toBool();
            widget->setDisabled(disabled);
            // A widget's own style sheet beats inherited rules, so the controls built with one (buttons, fields,
            // checkboxes) carry AppKit's disabled look themselves.
            if (disabled) {
                QList<QWidget *> styled = widget->findChildren<QWidget *>();
                styled.prepend(widget);
                for (QWidget *w : styled)
                    if (!w->styleSheet().isEmpty() && !w->property("disabledStyled").toBool()) {
                        // Plain (bezel-less) buttons only dim; they grow no chrome when disabled.
                        if (qobject_cast<QPushButton *>(w) && w->styleSheet().contains(QLatin1String("transparent"))) {
                            w->setStyleSheet(w->styleSheet() + QStringLiteral(" QPushButton:disabled { color: rgba(255, 255, 255, 0.25); }"));
                            w->setProperty("disabledStyled", true);
                            continue;
                        }
                        w->setStyleSheet(w->styleSheet() + QLatin1Char(' ') + disabledStyleSheet());
                        w->setProperty("disabledStyled", true);
                    }
            }
        } else if (kind == "offset") {
            const int ox = static_cast<int>(doubles.value("x").toDouble());
            const int oy = static_cast<int>(doubles.value("y").toDouble());
            widget->move(widget->x() + ox, widget->y() + oy);
            widget->setProperty("offsetX", ox);
            widget->setProperty("offsetY", oy);
        } else if (kind == "fixedSize") {
            widget->setSizePolicy(QSizePolicy::Fixed, QSizePolicy::Fixed);
        } else if (kind == "help" || kind == "accessibilityLabel") {
            const QString text = strings.value("text").toString();
            if (!text.isEmpty()) widget->setToolTip(text);
        } else if (kind == "accessibilityIdentifier") {
            const QString id = strings.value("text").toString();
            if (!id.isEmpty()) widget->setObjectName(id);
        } else if (kind == "background") {
            const QString colorName = strings.value("name").toString();
            const QColor color = parseColorToken(colorName);
            if (color.isValid() && color.alpha() > 0) {
                widget->setAttribute(Qt::WA_StyledBackground, true);
                const int r = widget->property("cornerRadius").toInt();
                // Scoped to this widget: an unscoped rule would paint every child (a row's labels, its spacer) too.
                const QString tag = QString::number(quintptr(widget), 16);
                widget->setProperty("swiftuiBackground", tag);
                QString bg = QString("QWidget[swiftuiBackground=\"%1\"] { background-color: %2;").arg(tag, color.name(QColor::HexArgb));
                if (r > 0) bg += QString(" border-radius: %1px;").arg(r);
                bg += QLatin1String(" }");
                widget->setStyleSheet(widget->styleSheet() + " " + bg);
            }
        } else if (kind == "border") {
            const QColor color = parseColorToken(strings.value("name").toString());
            if (color.isValid() && color.alpha() > 0) {
                const QString tag = QString::number(quintptr(widget), 16);
                widget->setAttribute(Qt::WA_StyledBackground, true);
                widget->setProperty("swiftuiBorder", tag);
                widget->setStyleSheet(widget->styleSheet() + QStringLiteral(" QWidget[swiftuiBorder=\"%1\"] { border: %2px solid %3; }")
                                      .arg(tag).arg(qRound(doubles.value("width").toDouble())).arg(color.name(QColor::HexArgb)));
            }
        } else if (kind == "cornerRadius") {
            // Rounds this view's own background (see "background"); a capsule's huge radius is its half height, which a
            // style sheet can't express, so it is capped at a control's.
            const int r = qMin(11, static_cast<int>(doubles.value("radius").toDouble()));
            widget->setProperty("cornerRadius", r);
        } else if (kind == "foregroundStyle") {
            const QString colorName = strings.value("name").toString();
            const QColor color = parseColorToken(colorName);
            if (color.isValid()) {
                const QString rgba = QStringLiteral("rgba(%1, %2, %3, %4)").arg(color.red()).arg(color.green()).arg(color.blue()).arg(color.alphaF());
                widget->setStyleSheet(widget->styleSheet() + QString(" * { color: %1; }").arg(rgba));   // a rule, so it mixes with other rules
                // Symbols take it too, unless one set its own (modifiers apply innermost first, so that one is done).
                QList<QWidget *> symbols = widget->findChildren<QWidget *>();
                symbols.prepend(widget);
                for (QWidget *w : symbols) {
                    const QString symbol = w->property("systemIcon").toString();
                    if (symbol.isEmpty() || w->property("tinted").toBool()) continue;
                    const int size = w->property("iconSize").toInt() > 0 ? w->property("iconSize").toInt() : 16;
                    if (auto *button = qobject_cast<QAbstractButton *>(w)) button->setIcon(renderToolVectorIcon(symbol, size, color));
                    else if (auto *label = qobject_cast<QLabel *>(w)) label->setPixmap(renderToolVectorIcon(symbol, size, color).pixmap(size, size));
                    w->setProperty("tinted", true);
                }
            }
        }
    }
}

/// A `.resizable()` bitmap: scaled to fit whatever size its layout gives it, centred, aspect kept.
class SwiftUIFitImageWidget : public QWidget {
public:
    explicit SwiftUIFitImageWidget(QImage image) : m_image(std::move(image)) {
        setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
    }
    QSize sizeHint() const override { return m_image.size().scaled(560, 560, Qt::KeepAspectRatio); }
protected:
    void paintEvent(QPaintEvent *) override {
        QPainter painter(this);
        painter.setRenderHint(QPainter::SmoothPixmapTransform, true);
        const QSize fitted = m_image.size().scaled(size(), Qt::KeepAspectRatio);
        const QRect target(QPoint((width() - fitted.width()) / 2, (height() - fitted.height()) / 2), fitted);
        painter.drawImage(target, m_image);
    }
private:
    QImage m_image;
};

QWidget *buildNode(uint64_t handle, const QString &panel, const QJsonObject &node);

/// `VStack`/`HStack` share everything but the layout's orientation.
QWidget *buildStack(uint64_t handle, const QString &panel, const QJsonObject &node, QBoxLayout::Direction direction) {
    auto *container = new QWidget;
    auto *layout = new QBoxLayout(direction, container);
    layout->setContentsMargins(0, 0, 0, 0);
    const QJsonObject doubles = node.value("doubleParams").toObject();
    // No spacing given: SwiftUI's default between two views, 8 points.
    layout->setSpacing(doubles.contains("spacing") ? static_cast<int>(doubles.value("spacing").toDouble()) : 8);
    for (const auto &childValue : node.value("children").toArray()) {
        const QJsonObject childObj = childValue.toObject();
        if (QWidget *child = buildNode(handle, panel, childObj)) {
            const QString childKind = childObj.value("kind").toString();
            int stretch = 0;
            if (childKind == "ScrollView" || childKind == "Spacer" || childKind == "Canvas") {
                stretch = 1;
            }
            const bool horizontal = direction == QBoxLayout::LeftToRight;
            // SwiftUI's Spacer grows along its stack only; growing across it too would make the whole row (a header
            // with a Spacer in it) take a share of its column's height.
            if (childKind == "Spacer")
                child->setSizePolicy(horizontal ? QSizePolicy::Expanding : QSizePolicy::Preferred,
                                     horizontal ? QSizePolicy::Preferred : QSizePolicy::Expanding);
            // A Divider in an HStack is a vertical line.
            if (childKind == "Divider" && horizontal) {
                if (auto *line = qobject_cast<QFrame *>(child)) {
                    line->setFrameShape(QFrame::VLine);
                    line->setStyleSheet("background-color: #141416; max-width: 1px; border: none;");
                    line->setFixedWidth(1);
                    line->setMaximumHeight(QWIDGETSIZE_MAX);
                }
            }
            // A VStack places each child at its own width, at the stack's alignment (center by default); only the
            // flexible ones (fields, sliders, rows with a Spacer, maxWidth: .infinity) span it.
            Qt::Alignment placed;
            if (!horizontal) {
                // Wrapping text takes the stack's width too (then wraps only when it has to).
                auto *label = qobject_cast<QLabel *>(child);
                const bool flexible = (child->sizePolicy().horizontalPolicy() & QSizePolicy::ExpandFlag)
                    || (child->layout() && (child->layout()->expandingDirections() & Qt::Horizontal))
                    || (label && label->wordWrap());
                const QString alignment = node.value("stringParams").toObject().value("alignment").toString();
                if (!flexible) placed = alignment == QLatin1String("leading") ? Qt::AlignLeft
                                      : alignment == QLatin1String("trailing") ? Qt::AlignRight : Qt::AlignHCenter;
            }
            layout->addWidget(child, stretch, placed);
        }
    }
    return container;
}

QWidget *buildNode(uint64_t handle, const QString &panel, const QJsonObject &node) {
    const QString kind = node.value("kind").toString();
    const QString id = node.value("id").toString();
    const QJsonObject strings = node.value("stringParams").toObject();
    const QJsonObject bools = node.value("boolParams").toObject();
    const QJsonArray children = node.value("children").toArray();

    QWidget *widget = nullptr;
    if (kind == "VStack") {
        widget = buildStack(handle, panel, node, QBoxLayout::TopToBottom);
    } else if (kind == "HStack") {
        widget = buildStack(handle, panel, node, QBoxLayout::LeftToRight);
    } else if (kind == "ZStack") {
        auto *container = new QWidget;
        bool hasOffset = false;
        QList<QWidget *> builtChildren;
        for (const auto &childValue : children) {
            if (QWidget *child = buildNode(handle, panel, childValue.toObject())) {
                builtChildren.append(child);
                if (child->property("offsetX").toInt() != 0 || child->property("offsetY").toInt() != 0) {
                    hasOffset = true;
                }
            }
        }
        if (hasOffset) {
            int maxW = 36, maxH = 36;
            for (auto *child : builtChildren) {
                child->setParent(container);
                const int ox = child->property("offsetX").toInt();
                const int oy = child->property("offsetY").toInt();
                // A widget that was never laid out still has Qt's 640x480 default size, not its own: use a fixed size
                // when it has one, else its size hint. (A 640x480 "Default colors" button on top of the palette
                // swallowed every click, so Swap reset the colours.)
                const bool fixed = child->minimumSize() == child->maximumSize();
                const QSize own = fixed ? child->minimumSize() : child->sizeHint();
                const int cw = own.width() > 0 ? own.width() : 12;
                const int ch = own.height() > 0 ? own.height() : 12;
                child->setGeometry(ox, oy, cw, ch);
                maxW = qMax(maxW, ox + cw);
                maxH = qMax(maxH, oy + ch);
                child->show();
            }
            container->setFixedSize(maxW, maxH);
        } else {
            auto *layout = new QStackedLayout(container);
            layout->setStackingMode(QStackedLayout::StackAll);
            layout->setContentsMargins(0, 0, 0, 0);
            for (auto *child : builtChildren) {
                layout->addWidget(child);
            }
        }
        widget = container;
    } else if (kind == "Text") {
        // No color of its own: it takes its container's foregroundStyle (SwiftUI's environment), else the primary label color.
        auto *label = new QLabel(strings.value("text").toString());
        widget = label;
    } else if (kind == "Button") {
        auto *button = new QPushButton;
        QString systemIcon;
        bool isToolButton = false;
        QString textLabel;
        // A swatch button's label is a filled shape (upstream ColorPaletteControls / BrushControls): its fill is the
        // color the swatch shows.
        QString labelFill;
        // The label's own fixed frame (`.frame(width:height:)` on the icon), which sizes a small icon button
        // (the palette's 12x12 swap/reset arrows) instead of the rail's standard 36x36.
        QSize labelFrame;

        std::function<void(const QJsonObject &)> extractLabel = [&](const QJsonObject &n) {
            const QString childKind = n.value("kind").toString();
            if (!labelFrame.isValid()) {
                for (const auto &m : n.value("modifiers").toArray()) {
                    const QJsonObject mo = m.toObject();
                    if (mo.value("kind").toString() != "frame") continue;
                    const QJsonObject d = mo.value("doubleParams").toObject();
                    if (d.contains("width") && d.contains("height") && !d.contains("maxWidth") && !d.contains("minWidth"))
                        labelFrame = QSize(qRound(d.value("width").toDouble()), qRound(d.value("height").toDouble()));
                }
            }
            const QString fill = n.value("stringParams").toObject().value("fillColor").toString();
            if (labelFill.isEmpty() && !fill.isEmpty()) labelFill = fill;
            if (childKind == "Text") {
                if (textLabel.isEmpty()) textLabel = n.value("stringParams").toObject().value("text").toString();
            } else if (childKind == "Image") {
                const QString source = n.value("stringParams").toObject().value("source").toString();
                if (source.startsWith(QLatin1String("system:"))) {
                    systemIcon = source.mid(7);
                    button->setProperty("systemIcon", systemIcon);
                    isToolButton = true;
                }
            } else if (childKind == "Canvas") {
                isToolButton = true;
            } else {
                for (const auto &c : n.value("children").toArray()) extractLabel(c.toObject());
            }
        };
        for (const auto &child : children) extractLabel(child.toObject());

        QString hint;
        for (const auto &m : node.value("modifiers").toArray()) {
            const QJsonObject mo = m.toObject();
            const QString mkind = mo.value("kind").toString();
            if (mkind == "help" || mkind == "accessibilityLabel") {
                hint = mo.value("stringParams").toObject().value("text").toString();
                if (!hint.isEmpty()) break;
            }
        }

        // Infer icon for Canvas tool buttons or named tools:
        if (systemIcon.isEmpty()) {
            if (hint.contains(QLatin1String("Gradient"), Qt::CaseInsensitive)) systemIcon = QStringLiteral("square.bottomhalf.filled");
            else if (hint.contains(QLatin1String("Clone"), Qt::CaseInsensitive)) systemIcon = QStringLiteral("seal");
            else if (hint.contains(QLatin1String("Lasso"), Qt::CaseInsensitive)) systemIcon = QStringLiteral("lasso");
            else if (hint.contains(QLatin1String("Wand"), Qt::CaseInsensitive) || hint.contains(QLatin1String("Object"), Qt::CaseInsensitive)) systemIcon = QStringLiteral("wand.and.stars");
            else if (hint.contains(QLatin1String("Move"), Qt::CaseInsensitive)) systemIcon = QStringLiteral("arrow.up.left.and.arrow.down.right");
            else if (hint.contains(QLatin1String("Marquee"), Qt::CaseInsensitive)) systemIcon = QStringLiteral("rectangle.dashed");
            else if (hint.contains(QLatin1String("Crop"), Qt::CaseInsensitive)) systemIcon = QStringLiteral("crop");
            else if (hint.contains(QLatin1String("Brush"), Qt::CaseInsensitive)) systemIcon = QStringLiteral("paintbrush.pointed");
            else if (hint.contains(QLatin1String("Eraser"), Qt::CaseInsensitive)) systemIcon = QStringLiteral("eraser");
            else if (hint.contains(QLatin1String("Healing"), Qt::CaseInsensitive)) systemIcon = QStringLiteral("bandage");
            else if (hint.contains(QLatin1String("Smear"), Qt::CaseInsensitive) || hint.contains(QLatin1String("Blur"), Qt::CaseInsensitive)) systemIcon = QStringLiteral("drop");
            else if (hint.contains(QLatin1String("Shape"), Qt::CaseInsensitive)) systemIcon = QStringLiteral("square.on.circle");
            else if (hint.contains(QLatin1String("Type"), Qt::CaseInsensitive)) systemIcon = QStringLiteral("textformat");
            else if (hint.contains(QLatin1String("Eye"), Qt::CaseInsensitive)) systemIcon = QStringLiteral("eyedropper");
            else if (hint.contains(QLatin1String("Hand"), Qt::CaseInsensitive)) systemIcon = QStringLiteral("hand.draw");
            else if (hint.contains(QLatin1String("Zoom"), Qt::CaseInsensitive)) systemIcon = QStringLiteral("magnifyingglass");
            else if (hint.contains(QLatin1String("Swap"), Qt::CaseInsensitive)) systemIcon = QStringLiteral("arrow.left.and.right");
            else if (hint.contains(QLatin1String("Default colors"), Qt::CaseInsensitive)) systemIcon = QStringLiteral("arrow.counterclockwise");
            if (!systemIcon.isEmpty()) isToolButton = true;
        }

        const bool isSelected = bools.value("isSelected").toBool();

        if (hint.contains(QLatin1String("Background color"), Qt::CaseInsensitive)) {
            button->setFixedSize(24, 24);
            button->setCursor(Qt::PointingHandCursor);
            button->setText(QString());
            const QColor swatch = labelFill.isEmpty() ? QColor(Qt::white) : parseColorToken(labelFill);
            button->setStyleSheet(QString("QPushButton { background-color: %1; border: 1.5px solid #ffffff; border-radius: 6px; } "
                                          "QPushButton:hover { border: 1.5px solid #007aff; }").arg(swatch.name()));
        } else if (hint.contains(QLatin1String("Foreground color"), Qt::CaseInsensitive)) {
            button->setFixedSize(24, 24);
            button->setCursor(Qt::PointingHandCursor);
            button->setText(QString());
            const QColor swatch = labelFill.isEmpty() ? QColor(Qt::black) : parseColorToken(labelFill);
            button->setStyleSheet(QString("QPushButton { background-color: %1; border: 1.5px solid #ffffff; border-radius: 6px; } "
                                          "QPushButton:hover { border: 1.5px solid #007aff; }").arg(swatch.name()));
        } else if (!labelFill.isEmpty() && textLabel.isEmpty() && systemIcon.isEmpty()) {
            // A color swatch button (a filled shape as the label, e.g. an effect's color): drawn as upstream draws it —
            // the fill in a rounded rect with a white inner and a black outer line — at the label's frame size.
            const QSize size = labelFrame.isValid() ? labelFrame : QSize(36, 18);
            const qreal dpr = qApp ? qApp->devicePixelRatio() : 1.0;
            QPixmap pixmap(size * dpr);
            pixmap.setDevicePixelRatio(dpr);
            pixmap.fill(Qt::transparent);
            {
                QPainter painter(&pixmap);
                painter.setRenderHint(QPainter::Antialiasing);
                const QRectF outer = QRectF(QPointF(0, 0), QSizeF(size)).adjusted(0.5, 0.5, -0.5, -0.5);
                painter.setPen(QPen(Qt::black, 1));
                painter.setBrush(parseColorToken(labelFill));
                painter.drawRoundedRect(outer, 3, 3);
                painter.setPen(QPen(Qt::white, 1));
                painter.setBrush(Qt::NoBrush);
                painter.drawRoundedRect(outer.adjusted(1, 1, -1, -1), 2, 2);
            }
            button->setIcon(QIcon(pixmap));
            button->setIconSize(size);
            button->setFixedSize(size);
            button->setText(QString());
            button->setFlat(true);
            button->setCursor(Qt::PointingHandCursor);
            button->setStyleSheet("QPushButton { border: none; padding: 0; background: transparent; }");
        } else if (isToolButton && !systemIcon.isEmpty() && labelFrame.isValid() && labelFrame.width() < 30 && labelFrame.height() < 30) {
            // A small icon button sized by its label (the palette's swap/reset arrows): exactly that size, plain.
            const int iconSize = qMax(8, qMin(labelFrame.width(), labelFrame.height()));
            button->setIcon(renderToolVectorIcon(systemIcon, iconSize, QColor(0x8e, 0x8e, 0x93)));   // .secondary
            button->setIconSize(QSize(iconSize, iconSize));
            button->setText(QString());
            button->setCursor(Qt::PointingHandCursor);
            button->setFixedSize(labelFrame);
            button->setStyleSheet("QPushButton { background: transparent; border: none; padding: 0px; margin: 0px; } "
                                  "QPushButton:hover { background-color: rgba(255, 255, 255, 0.10); border-radius: 3px; }");
        } else if (!systemIcon.isEmpty() && !textLabel.isEmpty() && panel != QLatin1String("ToolRail")) {
            // An icon and a title in one plain button (e.g. Camera Raw's disclosure headers: chevron + section name).
            button->setIcon(renderToolVectorIcon(systemIcon, 12, QColor(0xf5, 0xf5, 0xf7)));
            button->setIconSize(QSize(12, 12));
            button->setText(textLabel);
            button->setCursor(Qt::PointingHandCursor);
            button->setStyleSheet("QPushButton { background: transparent; border: none; color: #f5f5f7; font-size: 13px; "
                                  "font-weight: 600; padding: 0px; margin: 0px; text-align: left; }");
        } else if (isToolButton && !systemIcon.isEmpty()) {
            const bool isToolRail = (panel == QLatin1String("ToolRail"));
            const int iconSize = isToolRail ? 20 : 16;
            button->setProperty("iconSize", iconSize);
            QIcon icon = renderToolVectorIcon(systemIcon, iconSize, parseColorToken(QStringLiteral("primary")));
            button->setIcon(icon);
            button->setIconSize(QSize(iconSize, iconSize));
            button->setText(QString());
            button->setCursor(Qt::PointingHandCursor);
            if (isToolRail) {
                button->setFixedSize(36, 36);
                if (isSelected) {
                    button->setStyleSheet(
                        "QPushButton { background-color: rgba(255, 255, 255, 0.15); border: 1px solid rgba(255, 255, 255, 0.18); border-radius: 7px; padding: 0px; margin: 0px; } "
                        "QPushButton:hover { background-color: rgba(255, 255, 255, 0.22); }"
                    );
                } else {
                    button->setStyleSheet(
                        "QPushButton { background-color: transparent; border: 1px solid transparent; border-radius: 7px; padding: 0px; margin: 0px; } "
                        "QPushButton:hover { background-color: rgba(255, 255, 255, 0.08); border: 1px solid rgba(255, 255, 255, 0.10); }"
                    );
                }
            } else {
                button->setStyleSheet(
                    "QPushButton { background-color: transparent; border: none; border-radius: 4px; padding: 2px 4px; margin: 0px; } "
                    "QPushButton:hover { background-color: rgba(255, 255, 255, 0.10); }"
                );
            }
        } else {
            button->setText(textLabel);
            button->setStyleSheet(
                "QPushButton { background-color: #2a2a2d; color: #ffffff; border: 1px solid #38383c; border-radius: 4px; padding: 4px 10px; } "
                "QPushButton:hover { background-color: #35353a; color: #ffffff; border-color: #55555c; } "
                "QPushButton:pressed { background-color: #1f1f22; }"
            );
        }

        QObject::connect(button, &QPushButton::clicked, button, [handle, panel, id] {
            dispatch(handle, panel, id, QStringLiteral("action"));
        });
        widget = button;
    } else if (kind == "Toggle" && [&] {
                   for (const auto &m : node.value("modifiers").toArray())
                       if (m.toObject().value("kind").toString() == QLatin1String("toggleStyle")
                           && m.toObject().value("stringParams").toObject().value("name").toString() == QLatin1String("button")) return true;
                   return false;
               }()) {
        // .toggleStyle(.button): a push button that stays pressed while on (AppKit's pushOnPushOff bezel).
        auto *button = new QPushButton;
        button->setCheckable(true);
        button->setChecked(bools.value("isOn").toBool());
        QString symbol, title;
        std::function<void(const QJsonObject &)> find = [&](const QJsonObject &n) {
            const QString k = n.value("kind").toString();
            const QJsonObject st = n.value("stringParams").toObject();
            if (k == "Image" && st.value("source").toString().startsWith(QLatin1String("system:")) && symbol.isEmpty()) symbol = st.value("source").toString().mid(7);
            else if (k == "Text" && title.isEmpty()) title = st.value("text").toString();
            for (const auto &c : n.value("children").toArray()) find(c.toObject());
        };
        for (const auto &child : children) find(child.toObject());
        if (!symbol.isEmpty()) {
            button->setIcon(renderToolVectorIcon(symbol, 14, QColor(0xf5, 0xf5, 0xf7)));
            button->setIconSize(QSize(14, 14));
            button->setFixedSize(30, 22);
        } else {
            button->setText(title);
        }
        button->setStyleSheet(
            "QPushButton { background-color: #2a2a2d; color: #ffffff; border: 1px solid #38383c; border-radius: 5px; padding: 0px 6px; } "
            "QPushButton:hover { background-color: #35353a; } "
            "QPushButton:checked { background-color: #5a5a5f; border-color: #6a6a70; }");
        QObject::connect(button, &QPushButton::toggled, button, [handle, panel, id](bool checked) {
            dispatch(handle, panel, id, QStringLiteral("isOn"), checked ? "true" : "false");
        });
        widget = button;
    } else if (kind == "Toggle") {
        auto *checkBox = new QCheckBox;
        if (!children.isEmpty()) {
            const QJsonObject label = children.first().toObject();
            if (label.value("kind").toString() == "Text") checkBox->setText(label.value("stringParams").toObject().value("text").toString());
        }
        checkBox->setChecked(bools.value("isOn").toBool());
        checkBox->setStyleSheet(
            "QCheckBox { color: #f5f5f7; spacing: 6px; } "
            "QCheckBox::indicator { width: 14px; height: 14px; border: 1px solid #4a4a50; border-radius: 3px; background-color: #28282b; } "
            "QCheckBox::indicator:checked { background-color: #007aff; border-color: #007aff; image: url(" + styleSheetImage(QStringLiteral("checkbox-tick"), "<svg xmlns='http://www.w3.org/2000/svg' width='14' height='14' viewBox='0 0 14 14'><path fill='none' stroke='white' stroke-width='2' stroke-linecap='round' stroke-linejoin='round' d='M3.2 7.2 L5.6 9.8 L10.8 4.2'/></svg>") + "); }"
        );
        QObject::connect(checkBox, &QCheckBox::toggled, checkBox, [handle, panel, id](bool checked) {
            dispatch(handle, panel, id, QStringLiteral("isOn"), checked ? "true" : "false");
        });
        widget = checkBox;
    } else if (kind == "TextField") {
        auto *field = new QLineEdit;
        field->setPlaceholderText(strings.value("placeholder").toString());
        QObject::connect(field, &QLineEdit::editingFinished, field, [handle, panel] { notifyListeners(handle, panel); });
        field->setStyleSheet("QLineEdit { background-color: #28282b; color: #ffffff; border: 1px solid #444448; border-radius: 4px; padding: 2px 4px; } QLineEdit:focus { border-color: #007aff; }");
        const QStringList handlerKeys = [&] {
            QStringList keys;
            for (const auto &k : node.value("handlerKeys").toArray()) keys << k.toString();
            return keys;
        }();
        if (handlerKeys.contains(QStringLiteral("value"))) {
            const QJsonObject doubles = node.value("doubleParams").toObject();
            field->setText(QString::number(doubles.value("value").toDouble()));
            QObject::connect(field, &QLineEdit::textChanged, field, [handle, panel, id](const QString &text) {
                bool ok = false;
                const double number = text.toDouble(&ok);
                if (ok) dispatch(handle, panel, id, QStringLiteral("value"), jsonFragment(number));
            });
        } else {
            field->setText(strings.value("text").toString());
            if (handlerKeys.contains(QStringLiteral("text"))) {
                QObject::connect(field, &QLineEdit::textChanged, field, [handle, panel, id](const QString &text) {
                    dispatch(handle, panel, id, QStringLiteral("text"), jsonFragment(text));
                });
            }
        }
        widget = field;
    } else if (kind == "Slider") {
        const QJsonObject doubles = node.value("doubleParams").toObject();
        const double lower = doubles.value("lowerBound").toDouble(), upper = doubles.value("upperBound").toDouble(1);
        constexpr int steps = 1000;
        auto *slider = new QSlider(Qt::Horizontal);
        slider->setStyleSheet("QSlider::groove:horizontal { height: 4px; background: #38383c; border-radius: 2px; } QSlider::handle:horizontal { background: #ffffff; border: 1px solid #b0b0b5; width: 12px; height: 12px; margin: -4px 0; border-radius: 6px; }");
        slider->setRange(0, steps);
        const double span = (upper > lower) ? (upper - lower) : 1;
        slider->setValue(static_cast<int>((doubles.value("value").toDouble() - lower) / span * steps));
        // A drag moves through hundreds of steps a second, each one an action plus whatever it updates. Send at most one
        // per frame (the latest), and the exact final value on release — a drag then keeps up with the pointer.
        auto *frame = new QTimer(slider);
        frame->setSingleShot(true);
        frame->setInterval(16);
        auto send = [handle, panel, id, lower, span, slider] {
            dispatch(handle, panel, id, QStringLiteral("value"), jsonFragment(lower + span * slider->value() / 1000.0));
        };
        QObject::connect(frame, &QTimer::timeout, slider, send);
        QObject::connect(slider, &QSlider::valueChanged, slider, [slider, frame, send](int) {
            if (!slider->isSliderDown()) { send(); return; }   // keyboard, wheel, click on the track: immediate
            if (!frame->isActive()) frame->start();
        });
        // While dragging, the panel is not rebuilt (it would replace this slider under the mouse and end the drag);
        // on release it catches up with everything the drag changed.
        QObject::connect(slider, &QSlider::sliderReleased, slider, [handle, panel, frame, send] {
            frame->stop();
            send();
            notifyListeners(handle, panel);
        });
        widget = slider;
    } else if (kind == "Picker") {
        bool isSegmented = false;
        for (const auto &m : node.value("modifiers").toArray()) {
            const QJsonObject mo = m.toObject();
            if (mo.value("kind").toString() == "pickerStyle" &&
                mo.value("stringParams").toObject().value("name").toString() == "segmented") {
                isSegmented = true;
                break;
            }
        }
        const QString selection = strings.value("selection").toString();

        struct ItemData {
            QString text;
            QString tag;
        };
        QVector<ItemData> items;
        for (int i = 1; i < children.size(); ++i) {
            const QJsonObject item = children[i].toObject();
            // A Divider between items is the menu's separator line.
            if (item.value("kind").toString() == QLatin1String("Divider")) { items.push_back({QString(), QStringLiteral("\u0001separator")}); continue; }
            QString itemText = item.value("stringParams").toObject().value("text").toString();
            QString itemTag = itemText;
            for (const auto &mv : item.value("modifiers").toArray()) {
                const QJsonObject mo = mv.toObject();
                if (mo.value("kind").toString() == "tag") {
                    itemTag = mo.value("stringParams").toObject().value("text").toString();
                }
            }
            items.push_back({itemText, itemTag});
        }

        if (isSegmented) {
            auto *segContainer = new QWidget;
            segContainer->setObjectName("segmentedPicker");
            segContainer->setAttribute(Qt::WA_StyledBackground, true);
            segContainer->setStyleSheet("QWidget#segmentedPicker { background-color: rgba(255, 255, 255, 0.08); border-radius: 6px; }");
            auto *layout = new QHBoxLayout(segContainer);
            layout->setContentsMargins(2, 2, 2, 2);
            layout->setSpacing(0);

            for (int i = 0; i < items.size(); ++i) {
                const auto &it = items[i];
                auto *btn = new QPushButton(it.text, segContainer);
                btn->setFixedHeight(20);
                btn->setCursor(Qt::PointingHandCursor);
                const bool isSel = (it.tag.compare(selection, Qt::CaseInsensitive) == 0 ||
                                    it.text.compare(selection, Qt::CaseInsensitive) == 0);

                if (isSel) {
                    // NSSegmentedControl in dark aqua: the chosen segment is a lighter raised gray, not the accent.
                    btn->setStyleSheet(
                        "QPushButton { background-color: rgba(255, 255, 255, 0.24); color: #ffffff; border: none; padding: 2px 10px; border-radius: 5px; } "
                        "QPushButton:disabled { color: rgba(255, 255, 255, 0.25); background-color: rgba(255, 255, 255, 0.08); }"
                    );
                } else {
                    btn->setStyleSheet(
                        "QPushButton { background-color: transparent; color: rgba(255, 255, 255, 0.85); border: none; padding: 2px 10px; border-radius: 5px; } "
                        "QPushButton:disabled { color: rgba(255, 255, 255, 0.25); } "
                        "QPushButton:hover { background-color: rgba(255, 255, 255, 0.08); color: #ffffff; } "
                        "QPushButton:pressed { background-color: rgba(255, 255, 255, 0.16); }"
                    );
                }

                const QString tagToSend = it.tag;
                QObject::connect(btn, &QPushButton::clicked, btn, [handle, panel, id, tagToSend] {
                    dispatch(handle, panel, id, QStringLiteral("selection"), jsonFragment(tagToSend));
                });
                layout->addWidget(btn);
            }
            widget = segContainer;
        } else {
            auto *combo = new QComboBox;
            // macOS pop-up button: the up/down chevron at the right edge says it opens a menu.
            combo->setStyleSheet("QComboBox { background-color: #28282b; color: #ffffff; border: 1px solid #444448; border-radius: 4px; padding: 3px 22px 3px 8px; min-height: 18px; } "
                                 "QComboBox::drop-down { border: none; width: 18px; subcontrol-origin: padding; subcontrol-position: center right; } "
                                 "QComboBox::down-arrow { width: 8px; height: 11px; image: url(" + styleSheetImage(QStringLiteral("popup-chevrons"),
                                     "<svg xmlns='http://www.w3.org/2000/svg' width='8' height='11' viewBox='0 0 8 11'><path fill='none' stroke='#d8d8dc' stroke-width='1.5' stroke-linecap='round' stroke-linejoin='round' d='M1.5 4 L4 1.5 L6.5 4 M1.5 7 L4 9.5 L6.5 7'/></svg>") + "); } "
                                 "QComboBox QAbstractItemView { background-color: #242427; color: #ffffff; selection-background-color: #007aff; }");
            QStringList tags;
            int selIdx = -1;
            for (int i = 0; i < items.size(); ++i) {
                if (items[i].tag == QStringLiteral("\u0001separator")) { combo->insertSeparator(combo->count()); tags << QString(); continue; }
                combo->addItem(items[i].text);
                tags << items[i].tag;
                if (items[i].tag.compare(selection, Qt::CaseInsensitive) == 0 ||
                    items[i].text.compare(selection, Qt::CaseInsensitive) == 0) {
                    selIdx = i;
                }
            }
            if (selIdx >= 0) combo->setCurrentIndex(selIdx);
            QObject::connect(combo, QOverload<int>::of(&QComboBox::currentIndexChanged), combo, [handle, panel, id, tags](int idx) {
                if (idx >= 0 && idx < tags.size() && !tags[idx].isEmpty()) {
                    dispatch(handle, panel, id, QStringLiteral("selection"), jsonFragment(tags[idx]));
                }
            });
            widget = combo;
        }
    } else if (kind == "Menu") {
        auto *btn = new QPushButton;
        QString textLabel;
        QString systemIcon;
        if (!children.isEmpty()) {
            const QJsonObject labelObj = children.first().toObject();
            const QString lkind = labelObj.value("kind").toString();
            if (lkind == "Text") {
                textLabel = labelObj.value("stringParams").toObject().value("text").toString();
            } else if (lkind == "Image") {
                const QString source = labelObj.value("stringParams").toObject().value("source").toString();
                if (source.startsWith(QLatin1String("system:"))) {
                    systemIcon = source.mid(7);
                }
            }
        }
        if (!systemIcon.isEmpty()) {
            QIcon icon = renderToolVectorIcon(systemIcon, 16, QColor(0x8e, 0x8e, 0x93));
            btn->setIcon(icon);
            btn->setIconSize(QSize(16, 16));
        } else {
            btn->setText(textLabel);
        }

        auto *menu = new QMenu(btn);
        menu->setStyleSheet("QMenu { background-color: #242427; color: #ffffff; border: 1px solid #38383c; border-radius: 6px; padding: 4px; } "
                            "QMenu::item { padding: 4px 20px 4px 10px; border-radius: 4px; } "
                            "QMenu::item:selected { background-color: #007aff; }");

        std::function<void(const QJsonArray &)> populateActions = [&](const QJsonArray &items) {
            for (const auto &itemVal : items) {
                const QJsonObject item = itemVal.toObject();
                const QString ikind = item.value("kind").toString();
                if (ikind == "Button") {
                    QString itemText = item.value("stringParams").toObject().value("text").toString();
                    if (itemText.isEmpty()) {
                        for (const auto &c : item.value("children").toArray()) {
                            if (c.toObject().value("kind").toString() == "Text") {
                                itemText = c.toObject().value("stringParams").toObject().value("text").toString();
                                break;
                            }
                        }
                    }
                    const QString itemId = item.value("id").toString();
                    auto *act = menu->addAction(itemText);
                    QObject::connect(act, &QAction::triggered, btn, [handle, panel, itemId] {
                        dispatch(handle, panel, itemId, QStringLiteral("action"));
                    });
                } else {
                    populateActions(item.value("children").toArray());
                }
            }
        };
        if (children.size() > 1) {
            QJsonArray rest;
            for (int i = 1; i < children.size(); ++i) rest.append(children[i]);
            populateActions(rest);
        }
        btn->setMenu(menu);
        btn->setStyleSheet("QPushButton { background-color: transparent; border: none; border-radius: 4px; padding: 2px 4px; } "
                           "QPushButton:hover { background-color: rgba(255, 255, 255, 0.1); } "
                           "QPushButton::menu-indicator { image: none; width: 0px; }");
        widget = btn;
    } else if (kind == "Shape") {
        const QString shapeKind = strings.value("shapeKind").toString("rectangle");
        const double cornerRadius = node.value("doubleParams").toObject().value("cornerRadius").toDouble(0);
        QColor fillColor;
        QColor strokeColor;
        const double strokeWidth = node.value("doubleParams").toObject().value("strokeWidth").toDouble(0);

        if (strings.contains("fillColor")) {
            fillColor = parseColorToken(strings.value("fillColor").toString());
        }
        if (strings.contains("strokeColor")) {
            strokeColor = parseColorToken(strings.value("strokeColor").toString());
        }
        for (const auto &m : node.value("modifiers").toArray()) {
            const QJsonObject mo = m.toObject();
            const QString mkind = mo.value("kind").toString();
            if (mkind == "foregroundStyle" && !fillColor.isValid()) {
                fillColor = parseColorToken(mo.value("stringParams").toObject().value("name").toString());
            }
        }
        widget = new SwiftUIShapeWidget(shapeKind, cornerRadius, fillColor, strokeColor, strokeWidth);
    } else if (kind == "Image") {
        const QString source = strings.value("source").toString();
        QString systemIcon;
        if (source.startsWith(QLatin1String("system:"))) {
            systemIcon = source.mid(7);
        }
        QWidget *fitted = nullptr;
        auto *label = new QLabel;
        label->setAttribute(Qt::WA_TransparentForMouseEvents, true);
        if (source.startsWith(QLatin1String("pixels:"))) {
            // A bitmap (a layer thumbnail, ...): its pixels by token, drawn at the node's frame size.
            const QByteArray token = source.mid(7).toUtf8();
            int32_t w = 0, h = 0;
            const int64_t size = compositor_swiftui_image(token.constData(), &w, &h, nullptr, 0);
            if (size > 0 && w > 0 && h > 0 && size == int64_t(w) * h * 4) {
                QByteArray pixels(qsizetype(size), Qt::Uninitialized);
                compositor_swiftui_image(token.constData(), &w, &h, reinterpret_cast<uint8_t *>(pixels.data()), size_t(size));
                const QImage image = QImage(reinterpret_cast<const uchar *>(pixels.constData()), w, h, w * 4,
                                            QImage::Format_RGBA8888_Premultiplied).copy();
                QSize box(w, h);
                for (const auto &m : node.value("modifiers").toArray()) {
                    const QJsonObject d = m.toObject().value("doubleParams").toObject();
                    if (m.toObject().value("kind").toString() == "frame" && d.contains("width") && d.contains("height"))
                        box = QSize(qRound(d.value("width").toDouble()), qRound(d.value("height").toDouble()));
                }
                if (node.value("boolParams").toObject().value("resizable").toBool()) {
                    // .resizable(): fill the slot it's given, keeping the aspect (a preview in a fixed frame).
                    fitted = new SwiftUIFitImageWidget(image);
                    fitted->setAttribute(Qt::WA_TransparentForMouseEvents, true);
                }
                const qreal dpr = label->devicePixelRatioF();
                if (!fitted) {
                QPixmap pixmap = QPixmap::fromImage(image.scaled(box * dpr, Qt::KeepAspectRatio, Qt::SmoothTransformation));
                pixmap.setDevicePixelRatio(dpr);
                label->setPixmap(pixmap);
                label->setFixedSize(box);
                label->setAlignment(Qt::AlignCenter);
                }
            }
        } else if (!systemIcon.isEmpty()) {
            QColor iconColor = parseColorToken(QStringLiteral("primary"));
            int iconSize = 16;
            label->setProperty("systemIcon", systemIcon);
            for (const auto &m : node.value("modifiers").toArray()) {
                const QJsonObject mo = m.toObject();
                const QString mkind = mo.value("kind").toString();
                if (mkind == "font") {
                    // A symbol takes its size from the font (.font(.system(size: 25))).
                    const QString font = mo.value("stringParams").toObject().value("name").toString().section(QLatin1Char('+'), 0, 0);
                    if (font.startsWith(QLatin1String("system:"))) iconSize = qMax(8, qRound(font.mid(7).toDouble()));
                } else if (mkind == "foregroundStyle") {
                    iconColor = parseColorToken(mo.value("stringParams").toObject().value("name").toString());
                    label->setProperty("tinted", true);
                } else if (mkind == "frame") {
                    const QJsonObject doubles = mo.value("doubleParams").toObject();
                    if (doubles.contains("width")) iconSize = static_cast<int>(doubles.value("width").toDouble());
                    else if (doubles.contains("height")) iconSize = static_cast<int>(doubles.value("height").toDouble());
                }
            }
            label->setPixmap(renderToolVectorIcon(systemIcon, iconSize, iconColor).pixmap(iconSize, iconSize));
            label->setFixedSize(iconSize, iconSize);
            label->setProperty("iconSize", iconSize);
        }
        if (fitted) { delete label; widget = fitted; } else
        widget = label;
    } else if (kind == "ScrollView") {
        auto *scrollArea = new QScrollArea;
        scrollArea->setWidgetResizable(true);
        scrollArea->setFrameShape(QFrame::NoFrame);
        scrollArea->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
        scrollArea->setStyleSheet("QScrollArea { background: transparent; border: none; } QScrollArea > QWidget > QWidget { background: transparent; }");
        scrollArea->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
        scrollArea->setVerticalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
        if (!children.isEmpty()) {
            if (QWidget *content = buildNode(handle, panel, children.first().toObject())) {
                content->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Preferred);
                scrollArea->setWidget(content);
                // A List whose view handles drops (compatListDrop): its rows are the stack's items, minus the trailing
                // Spacer every List ends with.
                bool dropping = false;
                for (const auto &k : node.value("handlerKeys").toArray()) dropping = dropping || k.toString() == QLatin1String("listDrop");
                if (dropping && content->layout()) {
                    QList<QWidget *> rows;
                    for (int i = 0; i < content->layout()->count(); ++i)
                        if (QWidget *item = content->layout()->itemAt(i)->widget()) rows << item;
                    if (!rows.isEmpty()) rows.removeLast();
                    new ListDragController(content, rows, strings.value("listFolders").toString(), handle, panel, id);
                }
            }
        }
        widget = scrollArea;
    } else if (kind == "Spacer") {
        auto *spacer = new QWidget;
        spacer->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);   // narrowed to its stack's axis there
        spacer->setMinimumSize(0, 0);
        widget = spacer;
    } else if (kind == "Divider") {
        auto *line = new QFrame;
        line->setFrameShape(QFrame::HLine);
        line->setFrameShadow(QFrame::Plain);
        line->setStyleSheet("background-color: #141416; max-height: 1px; border: none;");
        widget = line;
    } else if (kind == "Canvas") {
        widget = new SwiftUICanvasWidget(handle, panel, id);
    } else if (kind == "ProgressView") {
        auto *progress = new QProgressBar;
        progress->setRange(0, 0);
        progress->setTextVisible(false);
        progress->setFixedHeight(14);
        progress->setFixedWidth(14);
        widget = progress;
    } else if (kind == "_ViewList") {
        if (children.isEmpty()) return nullptr;
        if (children.size() == 1) {
            widget = buildNode(handle, panel, children.first().toObject());
        } else {
            auto *container = new QWidget;
            auto *layout = new QVBoxLayout(container);
            layout->setContentsMargins(0, 0, 0, 0);
            layout->setSpacing(0);
            for (const auto &childValue : children) {
                if (QWidget *child = buildNode(handle, panel, childValue.toObject())) {
                    layout->addWidget(child);
                }
            }
            widget = container;
        }
    } else {
        // Not yet mapped (e.g. _Native/LinearGradient land in later phases) — skip, don't crash.
        return nullptr;
    }

    applyModifiers(widget, node.value("modifiers").toArray());

    if (widget) {
        const QStringList hKeys = [&] {
            QStringList keys;
            for (const auto &k : node.value("handlerKeys").toArray()) keys << k.toString();
            return keys;
        }();
        if (hKeys.contains(QStringLiteral("onTapGesture"))) {
            widget->setCursor(Qt::PointingHandCursor);
            widget->installEventFilter(new TapGestureFilter(widget, [handle, panel, id](int modifiers) {
                dispatch(handle, panel, id, QStringLiteral("onTapGesture"), QByteArray::number(modifiers));
            }));
        }
        if (hKeys.contains(QStringLiteral("contextMenu")) && strings.contains("contextMenu")) {
            const QJsonArray items = QJsonDocument::fromJson(strings.value("contextMenu").toString().toUtf8()).array();
            widget->setContextMenuPolicy(Qt::CustomContextMenu);
            QObject::connect(widget, &QWidget::customContextMenuRequested, widget, [widget, items, handle, panel, id](const QPoint &at) {
                QMenu menu;
                // Picked after the menu closes: the action rebuilds the panel, which deletes this widget.
                int chosen = -1;
                buildContextMenu(&menu, items, [&chosen](int index) { chosen = index; });
                menu.exec(widget->mapToGlobal(at));
                if (chosen >= 0) {
                    const uint64_t h = handle; const QString p = panel, n = id; const QByteArray payload = QByteArray::number(chosen);
                    QTimer::singleShot(0, [h, p, n, payload] { dispatch(h, p, n, QStringLiteral("contextMenu"), payload); });
                }
            });
        }
        if (hKeys.contains(QStringLiteral("keyCapture"))) new KeyCaptureFilter(widget, handle, panel, id);
    }

    return widget;
}

} // namespace

static bool isBeingManipulated(QWidget *panel) {
    for (QSlider *slider : panel->findChildren<QSlider *>()) if (slider->isSliderDown()) return true;
    if (QWidget *grabber = QWidget::mouseGrabber(); grabber && panel->isAncestorOf(grabber)) return true;
    QWidget *focus = QApplication::focusWidget();
    return focus && panel->isAncestorOf(focus)
        && (qobject_cast<QLineEdit *>(focus) || qobject_cast<QAbstractSpinBox *>(focus) || qobject_cast<QTextEdit *>(focus));
}

QWidget *swiftUIRenderPanel(uint64_t sessionHandle, const QString &panel) {
    return swiftUIRenderPanelIfChanged(sessionHandle, panel, nullptr);
}

QWidget *swiftUIRenderPanelIfChanged(uint64_t sessionHandle, const QString &panel, QWidget *current) {
    PERF_SCOPE(QStringLiteral("swiftUIRenderPanel:") + panel);
    // Mid-drag / mid-typing the panel stays as it is (see below), so don't even resolve its tree.
    if (current && current->property("swiftUIHandle").toULongLong() == sessionHandle && isBeingManipulated(current)) {
        current->update();
        return current;
    }
    QByteArray bytes;
    { PERF_SCOPE(QStringLiteral("fetchTree:") + panel); bytes = fetchTreeBytes(sessionHandle, panel); }
    if (bytes.isEmpty()) return nullptr;
    // Same session, same tree: the widgets already show it. Node ids are positional, so its buttons still reach the
    // handlers the fetch just re-registered; canvases fetch their pixels at paint time, so a repaint refreshes them.
    if (current && current->property("swiftUIHandle").toULongLong() == sessionHandle
        && current->property("swiftUITree").toByteArray() == bytes) {
        current->update();
        return current;
    }
    // Being dragged or typed in: rebuilding now would replace the slider under the mouse (ending the drag) or the
    // field being typed in (losing focus mid-word). Keep it; the release / end of editing refreshes the panel.
    if (current && current->property("swiftUIHandle").toULongLong() == sessionHandle && isBeingManipulated(current)) {
        current->update();
        return current;
    }
    const QJsonObject root = QJsonDocument::fromJson(bytes).object();
    if (root.isEmpty()) return nullptr;
    PERF_SCOPE(QStringLiteral("buildNode:") + panel);
    QWidget *built = buildNode(sessionHandle, panel, root);
    if (built) {
        built->setProperty("swiftUIHandle", QVariant::fromValue<qulonglong>(sessionHandle));
        built->setProperty("swiftUITree", bytes);
    }
    return built;
}

void registerSwiftUIActionListener(std::function<void(uint64_t, const QString &)> listener) {
    g_actionListeners.push_back(std::move(listener));
}

