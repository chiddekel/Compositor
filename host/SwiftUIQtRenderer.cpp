#include <QKeyEvent>
#include "QtKeyboardLayout.h"
#include <QHash>
#include <QFile>
#include <QDir>
#include <QStandardPaths>
#include <QMouseEvent>
#include <QDragEnterEvent>
#include <QDragMoveEvent>
#include <QDragLeaveEvent>
#include <QDropEvent>
#include <QMimeData>
#include <QDrag>
#include <QPixmap>
#include <QBuffer>
#include <QElapsedTimer>
extern "C" int64_t compositor_current_layer_drag(uint8_t *output, size_t capacity);
extern "C" void compositor_end_layer_drag(int32_t copied);
// SwiftUIQtRenderer — see SwiftUIQtRenderer.h. Fetches the resolved tree via compositor_session_render_tree
// (same size-query convention as compositor_session_state, see SessionWindow::sessionState) and walks it once,
// mapping each `RenderNode` kind to the matching Qt widget. Interactive widgets (Button, Toggle) wire their Qt
// signal straight to compositor_session_dispatch_swiftui_action, by the node's id — the same generic path for
// every panel, no per-panel Qt glue. This is intentionally the *only* place that knows the kind→widget mapping.

#include "SwiftUIQtRenderer.h"
#include "LucideIcons.h"
#include "QtTextFont.h"
#include <QPointer>
#include <QStyleOption>
#include <QAbstractItemView>
#include <QAbstractButton>
#include <QActionGroup>
#include <QSvgRenderer>
#include "PerfTrace.h"
#include <QTimer>
#include <QTextEdit>
#include <QAbstractSpinBox>
#include <QApplication>
#include <QAccessible>
#include <QAccessibleWidget>

#include <QAction>
#include <QBoxLayout>
#include <QCheckBox>
#include <QGridLayout>
#include <QRadioButton>
#include <QFont>
#include <QFrame>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMenu>
#include <QMessageBox>
#include <QLabel>
#include <QComboBox>
#include <QScreen>
#include <QLineEdit>
#include <QPainter>
#include <QPaintEvent>
#include <QGraphicsEffect>
#include <QGraphicsOpacityEffect>
#include <QPushButton>
#include <QScrollArea>
#include <QScrollBar>
#include <QResizeEvent>
#include <QShowEvent>
#include <QIcon>
#include <QPainterPath>
#include <QProgressBar>
#include <QSlider>
#include <QStackedLayout>
#include <QVariant>
#include <QRegion>
#include <limits>
#include <memory>
#include <cmath>

extern "C" {
int64_t compositor_session_render_tree(uint64_t handle, const char *panel, uint8_t *output, size_t capacity);
int64_t compositor_session_accessibility_tree(uint64_t handle, const char *panel, const char *node_id, uint8_t *output, size_t capacity);
int32_t compositor_session_dispatch_swiftui_action(uint64_t handle, const char *panel, const char *node_id, const char *handler_key,
                                                   const uint8_t *payload, size_t payload_count);
int32_t compositor_session_dispatch_swiftui_drop_event(uint64_t handle, const char *panel, const char *node_id, const char *handler_key,
                                                        const uint8_t *payload, size_t payload_count);
int64_t compositor_session_render_swiftui_canvas(uint64_t handle, const char *panel, const char *node_id, size_t width, size_t height,
                                                 uint8_t *output, size_t capacity);
}

namespace {

// Defined below (with the cursor codes); the AppKit view widget applies it after each pointer event.
static void applyCompositorCursor(QWidget *widget);
static void synchronizeTrackingScroll(QWidget *widget);
QByteArray fetchTreeBytes(uint64_t handle, const QString &panel);
struct ScrollTraceEntry {
    const char *event;
    const void *owner;
    int y, maximum, desired, model, viewportHeight, documentHeight, flags;
};
// Keep failure diagnostics allocation-free while tracking. Only the failing native journey formats them.
static ScrollTraceEntry g_scrollTrace[512];
static unsigned g_scrollTraceCount = 0;
static void recordScrollTrace(const char *event, const void *owner, int y = 0, int maximum = 0,
                              int desired = 0, int model = -1, int viewportHeight = 0,
                              int documentHeight = 0, int flags = 0) {
    static const bool enabled = qEnvironmentVariableIsSet("COMPOSITOR_TRACE_SCROLL_BUFFER")
        || qEnvironmentVariableIsSet("XCTestConfigurationFilePath");
    if (!enabled) return;
    g_scrollTrace[g_scrollTraceCount++ % 512] = {event, owner, y, maximum, desired, model, viewportHeight, documentHeight, flags};
}

struct PointerTraceEntry {
    const char *event;
    const void *owner;
    uint64_t handle;
    double x, y;
    int modifiers, clicks;
};
static PointerTraceEntry g_pointerTrace[128];
static unsigned g_pointerTraceCount = 0;
static void recordPointerTrace(const char *event, const void *owner, uint64_t handle, QPointF point, int modifiers, int clicks) {
    static const bool enabled = qEnvironmentVariableIsSet("COMPOSITOR_TRACE_POINTER_BUFFER")
        || qEnvironmentVariableIsSet("XCTestConfigurationFilePath");
    if (enabled) g_pointerTrace[g_pointerTraceCount++ % 128] = {event, owner, handle, point.x(), point.y(), modifiers, clicks};
}

QAccessible::Role nativeAccessibilityRole(const QJsonObject &data) {
    static const QHash<QString, QAccessible::Role> roles{{"list", QAccessible::List}, {"listItem", QAccessible::ListItem},
        {"button", QAccessible::Button}, {"checkBox", QAccessible::CheckBox}, {"text", QAccessible::StaticText},
        {"textField", QAccessible::EditableText}, {"image", QAccessible::Graphic}, {"group", QAccessible::Grouping}};
    return roles.value(data.value("role").toString(), QAccessible::Grouping);
}

// Qt modal blocking does not disable the widget or its backing AppKit controls.
bool nativeAccessibilityBlockedByModal(QWidget *widget) {
    const auto *window = widget->window();
    for (auto *modal : QApplication::topLevelWidgets()) {
        if (!modal->isVisible() || !modal->isModal() || modal == window || modal->isAncestorOf(widget)) continue;
        if (modal->windowModality() == Qt::ApplicationModal) return true;
        for (auto *parent = modal->parentWidget(); parent; parent = parent->parentWidget()) {
            if (parent->window() == window || parent->window()->isAncestorOf(widget)) return true;
        }
    }
    return false;
}

// Transparent descendants give Qt ownership of accessible-object lifetimes while AppKit keeps drawing and input.
class NativeAccessibilityProxy : public QWidget {
public:
    NativeAccessibilityProxy(QJsonObject value, QWidget *parent, std::function<void(QString)> action)
        : QWidget(parent), data(std::move(value)), perform(std::move(action)) {
        setAttribute(Qt::WA_TransparentForMouseEvents);
        setAttribute(Qt::WA_NoSystemBackground);
        setAttribute(Qt::WA_TranslucentBackground);
        setFocusPolicy(Qt::NoFocus);
        setAccessibleName(data.value("label").toString());
        setAccessibleDescription(data.value("help").toString());
        setObjectName(data.value("identifier").toString());
        setEnabled(data.value("enabled").toBool(true));
    }
    QJsonObject data;
    std::function<void(QString)> perform;
protected:
    void paintEvent(QPaintEvent *) override {}
};

class NativeAccessibilityProxyInterface : public QAccessibleWidget {
public:
    explicit NativeAccessibilityProxyInterface(NativeAccessibilityProxy *proxy)
        : QAccessibleWidget(proxy, nativeAccessibilityRole(proxy->data)) {}
    QAccessible::State state() const override {
        auto current = QAccessibleWidget::state();
        auto *proxy = static_cast<NativeAccessibilityProxy *>(widget());
        current.disabled = current.disabled || nativeAccessibilityBlockedByModal(proxy);
        current.selected = proxy->data.value("selected").toBool();
        current.selectable = role() == QAccessible::ListItem;
        current.focusable = proxy->data.value("press").toBool();
        current.focused = proxy->data.value("focused").toBool();
        current.offscreen = proxy->data.value("offscreen").toBool();
        current.checkable = proxy->data.contains("checked");
        current.checked = proxy->data.value("checked").toBool();
        return current;
    }
    QStringList actionNames() const override {
        auto *proxy = static_cast<NativeAccessibilityProxy *>(widget());
        if (!proxy->isVisible() || !proxy->isEnabled() || nativeAccessibilityBlockedByModal(proxy)
                || !proxy->data.value("press").toBool()) return {};
        QStringList actions{role() == QAccessible::CheckBox ? toggleAction() : pressAction()};
        if (role() == QAccessible::ListItem) actions << setFocusAction();
        return actions;
    }
    void doAction(const QString &name) override {
        if (!actionNames().contains(name)) return;
        auto *proxy = static_cast<NativeAccessibilityProxy *>(widget());
        const auto action = proxy->perform;
        const QString id = proxy->data.value("id").toString();
        action(id);
    }
};

class NativeAppKitAccessibility : public QAccessibleWidget {
public:
    explicit NativeAppKitAccessibility(QWidget *owner) : QAccessibleWidget(owner, QAccessible::Grouping) {}
    int childCount() const override { refresh(); return QAccessibleWidget::childCount(); }
    QAccessibleInterface *child(int index) const override { refresh(); return QAccessibleWidget::child(index); }
    QAccessible::Role role() const override { refresh(); return nativeAccessibilityRole(m_data); }
    QAccessible::State state() const override {
        refresh();
        auto current = QAccessibleWidget::state();
        current.disabled = current.disabled || !m_data.value("enabled").toBool() || nativeAccessibilityBlockedByModal(widget());
        current.invisible = current.invisible || m_data.isEmpty() || m_data.value("hidden").toBool();
        current.offscreen = current.offscreen || m_data.value("offscreen").toBool();
        return current;
    }
    QString text(QAccessible::Text type) const override {
        refresh();
        if (type == QAccessible::Name && !m_data.value("label").toString().isEmpty()) return m_data.value("label").toString();
        return QAccessibleWidget::text(type);
    }
private:
    void refresh() const {
        if (m_refreshing || !widget()) return;
        m_refreshing = true;
        const uint64_t handle = widget()->property("appKitSession").toULongLong();
        const QString location = widget()->property("appKitNode").toString();
        const int split = location.indexOf('|');
        const QString panel = location.left(split), node = location.mid(split + 1);
        fetchTreeBytes(handle, panel); // synchronize the coordinator before reading names/states or dispatching actions
        const QByteArray panelBytes = panel.toUtf8(), nodeBytes = node.toUtf8();
        const int64_t size = compositor_session_accessibility_tree(handle, panelBytes.constData(), nodeBytes.constData(), nullptr, 0);
        QByteArray bytes;
        if (size > 0 && size <= 4 * 1024 * 1024) {
            bytes.resize(qsizetype(size));
            if (compositor_session_accessibility_tree(handle, panelBytes.constData(), nodeBytes.constData(),
                reinterpret_cast<uint8_t *>(bytes.data()), bytes.size()) != size) bytes.clear();
        }
        if (bytes != m_bytes) {
            for (auto *proxy : m_proxies) delete proxy;
            m_proxies.clear();
            m_bytes = bytes;
            m_data = QJsonDocument::fromJson(bytes).object();
            widget()->setObjectName(m_data.value("identifier").toString());
            QPointer<QWidget> owner(widget());
            const auto action = [handle, panel, node, owner](QString id) {
                if (!owner || !owner->isVisible() || !owner->isEnabled() || nativeAccessibilityBlockedByModal(owner)) return;
                fetchTreeBytes(handle, panel);
                const QByteArray p = panel.toUtf8(), n = node.toUtf8();
                const QByteArray payload = QJsonDocument(QJsonObject{{"id", id}, {"action", "press"}}).toJson(QJsonDocument::Compact);
                const int32_t result = compositor_session_dispatch_swiftui_drop_event(handle, p.constData(), n.constData(),
                    "accessibilityAction", reinterpret_cast<const uint8_t *>(payload.constData()), payload.size());
                if (result > 0 && owner) owner->setFocus(Qt::OtherFocusReason);
                QTimer::singleShot(0, [handle, panel] { notifyAccessibilityAction(handle, panel); });
            };
            std::function<void(QJsonObject, QWidget *, QPointF)> add = [&](QJsonObject value, QWidget *parent, QPointF offset) {
                auto *proxy = new NativeAccessibilityProxy(value, parent, action);
                const QPointF origin(value.value("x").toDouble(), value.value("y").toDouble());
                proxy->setGeometry(qRound(origin.x() - offset.x()), qRound(origin.y() - offset.y()),
                    qMax(1, qRound(value.value("width").toDouble())), qMax(1, qRound(value.value("height").toDouble())));
                for (const auto &child : value.value("children").toArray()) add(child.toObject(), proxy, origin);
                proxy->show();
                if (parent == widget()) m_proxies.append(proxy);
            };
            for (const auto &child : m_data.value("children").toArray()) add(child.toObject(), widget(), {});
        }
        m_refreshing = false;
    }
    static void notifyAccessibilityAction(uint64_t handle, const QString &panel);
    mutable bool m_refreshing = false;
    mutable QByteArray m_bytes;
    mutable QJsonObject m_data;
    mutable QList<NativeAccessibilityProxy *> m_proxies;
};

class SwiftUIAccessibleWidget : public QAccessibleWidget {
public:
    explicit SwiftUIAccessibleWidget(QWidget *widget)
        : QAccessibleWidget(widget, roleFor(widget), widget->accessibleName()) {}

    QAccessible::State state() const override {
        QAccessible::State current = QAccessibleWidget::state();
        if (widget()->property("swiftuiAccessibilityHidden").toBool()) current.invisible = true;
        return current;
    }

    QString text(QAccessible::Text type) const override {
        if (type == QAccessible::Value && widget()->property("swiftuiAccessibilityValue").isValid())
            return widget()->property("swiftuiAccessibilityValue").toString();
        return QAccessibleWidget::text(type);
    }

private:
    static QAccessible::Role roleFor(QWidget *widget) {
        const QString children = widget->property("swiftuiAccessibilityChildren").toString();
        return children == QLatin1String("contain") || children == QLatin1String("combine")
            ? QAccessible::Grouping : QAccessible::Client;
    }
};

bool hasNativeAccessibilityInterface(QWidget *widget) {
    return qobject_cast<QAbstractButton *>(widget) || qobject_cast<QAbstractSlider *>(widget)
        || qobject_cast<QLineEdit *>(widget) || qobject_cast<QComboBox *>(widget) || qobject_cast<QLabel *>(widget);
}

QAccessibleInterface *swiftUIAccessibilityFactory(const QString &, QObject *object) {
    auto *widget = qobject_cast<QWidget *>(object);
    if (auto *proxy = dynamic_cast<NativeAccessibilityProxy *>(widget)) return new NativeAccessibilityProxyInterface(proxy);
    if (widget && widget->property("appKitView").toBool()) return new NativeAppKitAccessibility(widget);
    if (!widget || !widget->property("swiftuiAccessibilityAdapter").toBool() || hasNativeAccessibilityInterface(widget)) return nullptr;
    const QString children = widget->property("swiftuiAccessibilityChildren").toString();
    const bool customMetadata = widget->property("swiftuiAccessibilityValue").isValid()
        || children == QLatin1String("contain") || children == QLatin1String("combine");
    if (!widget->property("swiftuiAccessibilityHidden").toBool() && !customMetadata) return nullptr;
    return new SwiftUIAccessibleWidget(widget);
}

void ensureSwiftUIAccessibilityFactory() {
    static const bool installed = [] {
        QAccessible::installFactory(swiftUIAccessibilityFactory);
        return true;
    }();
    Q_UNUSED(installed);
}

/// A `Canvas` node's widget: its `paintEvent` asks Swift to draw into a same-sized `CGContext` (the existing
/// Skia-backed bridge) and blits the result — upstream's `Canvas { context, size in ... }` closure runs unmodified,
/// this is the only Linux-specific code involved, and it is generic across every `Canvas` in every panel.
class SwiftUICanvasWidget : public QWidget {
public:
    SwiftUICanvasWidget(uint64_t handle, QString panel, QString nodeID, QWidget *parent = nullptr)
        : QWidget(parent), m_handle(handle), m_panel(std::move(panel)), m_nodeID(std::move(nodeID)) {
        setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);   // a Canvas takes the space it is offered
    }

protected:
    void paintEvent(QPaintEvent *) override {
        const int w = qMax(1, width()), h = qMax(1, height());
        const size_t capacity = static_cast<size_t>(w) * static_cast<size_t>(h) * 4;
        QByteArray bytes(static_cast<qsizetype>(capacity), Qt::Uninitialized);
        const QByteArray panelUtf8 = m_panel.toUtf8(), nodeUtf8 = m_nodeID.toUtf8();
        const int64_t written = compositor_session_render_swiftui_canvas(
            m_handle, panelUtf8.constData(), nodeUtf8.constData(), static_cast<size_t>(w), static_cast<size_t>(h),
            reinterpret_cast<uint8_t *>(bytes.data()), capacity);
        if (written != static_cast<int64_t>(capacity)) {
            QPainter painter(this);
            QStyleOption option;
            option.initFrom(this);
            style()->drawPrimitive(QStyle::PE_Widget, &option, &painter, this);
            return;
        }
        const QImage image(reinterpret_cast<const uchar *>(bytes.constData()), w, h, w * 4, QImage::Format_RGBA8888_Premultiplied);
        QPainter painter(this);
        QStyleOption option;   // its .background first, as a style sheet paints it
        option.initFrom(this);
        style()->drawPrimitive(QStyle::PE_Widget, &option, &painter, this);
        painter.drawImage(0, 0, image);
    }

private:
    uint64_t m_handle;
    QString m_panel, m_nodeID;
};

/// The `_AppKit` view (panel|node) that has the keys, so a rebuilt panel's widget for it takes them back.
QString g_appKitFocusedNode;
uint64_t g_appKitFocusedSession = 0;
/// The `_AppKit` widget a press is being tracked in (an AppKit tracking loop running the event pump), if any.
QPointer<QWidget> g_appKitTracking;
int g_appKitPumpDepth = 0;

/// Qt's modifiers as the shell's chord bits (1 Ctrl, 2 Alt, 4 Meta, 8 Shift).
int appKitModifierBits(Qt::KeyboardModifiers m) {
    return (m & Qt::ControlModifier ? 1 : 0) | (m & Qt::AltModifier ? 2 : 0) | (m & Qt::MetaModifier ? 4 : 0) | (m & Qt::ShiftModifier ? 8 : 0);
}

/// An `_AppKit` node (compat SwiftUI's NativeLowering): an AppKit view hierarchy Swift draws — tip's layers table, say
/// — shown as its pixels, with the pointer and (while focused) the keys going back to it as AppKit events, so its own
/// hit testing, tracking loops, drags and menus run. Its children are views over it (a field being edited), placed
/// where the node says.
class SwiftUIAppKitWidget : public SwiftUICanvasWidget {
public:
    SwiftUIAppKitWidget(uint64_t handle, QString panel, QString nodeID, QWidget *parent = nullptr)
        : SwiftUICanvasWidget(handle, panel, nodeID, parent), m_handle(handle), m_panel(panel), m_nodeID(nodeID) {
        setMouseTracking(true);
        setFocusPolicy(Qt::ClickFocus);
        setProperty("appKitView", true);   // headless journeys find it by this
        setProperty("appKitNode", key());
        setProperty("appKitSession", QVariant::fromValue<qulonglong>(m_handle));
        m_trackingDragTimer = new QTimer(this);
        m_trackingDragTimer->setInterval(50);
        QObject::connect(m_trackingDragTimer, &QTimer::timeout, this, [this] {
            if (!m_hasDragged || !(QGuiApplication::mouseButtons() & Qt::LeftButton)) return;
            const bool tracking = g_appKitTracking == this && g_appKitPumpDepth > 0;
            if (!tracking && !m_rowDragActive) return;
            for (QWidget *parent = parentWidget(); parent; parent = parent->parentWidget()) {
                auto *scroll = qobject_cast<QScrollArea *>(parent);
                if (!scroll || !scroll->property("appKitScroll").toBool()) continue;
                const QPointF point = scroll->viewport()->mapFromGlobal(m_lastDragGlobalPosition);
                if (!scroll->viewport()->rect().contains(point.toPoint())) {
                    if (!tracking && compositor_current_layer_drag(nullptr, 0) <= 0) {
                        m_rowDragActive = false; m_trackingDragTimer->stop(); return;
                    }
                    // A held pointer beyond the viewport keeps reaching new rows as the document scrolls.
                    const QPointer<SwiftUIAppKitWidget> self(this);
                    send("drag", mapFromGlobal(m_lastDragGlobalPosition), m_lastDragModifiers);
                    if (self) synchronizeTrackingScroll(self);
                }
                break;
            }
        });
        // The view had the keys before its panel was rebuilt: it keeps them.
        if (g_appKitFocusedNode == key() && g_appKitFocusedSession == m_handle)
            QTimer::singleShot(0, this, [this] { restoreFocus(); });
        setAttribute(Qt::WA_OpaquePaintEvent, false);
    }

protected:
    void showEvent(QShowEvent *event) override {
        SwiftUICanvasWidget::showEvent(event);
        // A modifier and its key can straddle a panel refresh. Restore logical focus before
        // the next key arrives, rather than leaving it on the dock until a queued callback.
        restoreFocus();
    }
    void mousePressEvent(QMouseEvent *event) override { press(event); }
    void mouseDoubleClickEvent(QMouseEvent *event) override { press(event); }
    void mouseMoveEvent(QMouseEvent *event) override {
        if (event->buttons() & Qt::MiddleButton) {
            const QPointer<SwiftUIAppKitWidget> self(this);
            send("middleDrag", event->position(), event->modifiers());
            if (self) synchronizeTrackingScroll(self);
            return;
        }
        if (event->buttons() & Qt::LeftButton) {
            m_hasDragged = true;
            m_lastDragGlobalPosition = event->globalPosition();
            m_lastDragModifiers = event->modifiers();
        }
        const QPointer<SwiftUIAppKitWidget> self(this);
        send((event->buttons() & Qt::LeftButton) ? "drag" : "move", event->position(), event->modifiers());
        if (self && event->buttons() & Qt::LeftButton) {
            synchronizeTrackingScroll(self);
            if (self) updateLayerTabTarget(event->globalPosition(), event->modifiers());
        }
    }
    void mouseReleaseEvent(QMouseEvent *event) override {
        if (event->button() == Qt::MiddleButton) {
            releaseMouse(); send("middleUp", event->position(), event->modifiers()); return;
        }
        if (event->button() != Qt::LeftButton) return;
        m_trackingDragTimer->stop();
        m_rowDragActive = false;
        m_hasDragged = false;
        releaseMouse();
        const QPointer<SwiftUIAppKitWidget> self(this);
        updateLayerTabTarget(event->globalPosition(), event->modifiers());
        bool copied = false;
        if (m_layerTabTarget && !m_layerDrag.isEmpty()) {
            QMimeData mime; mime.setData("com.compositor.layer-row", m_layerDrag);
            const QPointF point = m_layerTabTarget->mapFromGlobal(event->globalPosition().toPoint());
            QDropEvent drop(point, Qt::CopyAction, &mime, Qt::LeftButton, event->modifiers());
            QApplication::sendEvent(m_layerTabTarget, &drop);
            copied = drop.isAccepted() && drop.dropAction() == Qt::CopyAction;
        }
        if (!self) { compositor_end_layer_drag(copied ? 1 : 0); return; }
        m_layerTabTarget = nullptr; m_layerDrag.clear();
        send("up", event->position(), event->modifiers(), copied);
    }
    void leaveEvent(QEvent *) override { send("exit", QPointF(-1, -1), QGuiApplication::keyboardModifiers()); }
    bool event(QEvent *event) override {
        // Tab is the table's key (tip's keyDown cycles the tool mode), not focus navigation.
        if (event->type() == QEvent::KeyPress) { key(static_cast<QKeyEvent *>(event)); return true; }
        if (event->type() == QEvent::FocusIn) {
            g_appKitFocusedNode = key();
            g_appKitFocusedSession = m_handle;
            dispatchQuietly("focus", QByteArrayLiteral("true"));
        }
        if (event->type() == QEvent::FocusOut) {
            // A rebuilt panel replaces this widget with one for the same view, which takes the focus back (buildNode):
            // the view only loses the keys when the focus really went elsewhere.
            const QString node = key();
            const uint64_t handle = m_handle; const QString panel = m_panel, nodeID = m_nodeID;
            QTimer::singleShot(0, qApp, [node, handle, panel, nodeID] {
                QWidget *focus = QApplication::focusWidget();
                // An inline editor is a real Qt child over the drawn view and still belongs to its responder tree.
                for (QWidget *owner = focus; owner; owner = owner->parentWidget()) {
                    if (owner->property("appKitNode").toString() == node
                        && owner->property("appKitSession").toULongLong() == handle) return;
                }
                if (g_appKitFocusedNode == node && g_appKitFocusedSession == handle) {
                    g_appKitFocusedNode.clear();
                    g_appKitFocusedSession = 0;
                }
                const QByteArray panelUtf8 = panel.toUtf8(), nodeUtf8 = nodeID.toUtf8();
                compositor_session_dispatch_swiftui_action(handle, panelUtf8.constData(), nodeUtf8.constData(), "focus",
                                                           reinterpret_cast<const uint8_t *>("false"), 5);
            });
        }
        return SwiftUICanvasWidget::event(event);
    }

private:
    void restoreFocus() {
        if (g_appKitFocusedNode != key() || g_appKitFocusedSession != m_handle) return;
        for (QWidget *owner = QApplication::focusWidget(); owner; owner = owner->parentWidget())
            if (owner == this) return;
        recordScrollTrace("focus", this);
        setFocus(Qt::OtherFocusReason);
    }
    void press(QMouseEvent *event) {
        if ((event->button() == Qt::LeftButton || event->button() == Qt::RightButton) && !swiftUIAppKitTracking()) {
            // Commands can change rows before the next paint. As with keys/accessibility, synchronize the
            // native coordinator before hit testing; keep an existing tracking loop's views intact.
            const QPointer<SwiftUIAppKitWidget> self(this);
            fetchTreeBytes(m_handle, m_panel);
            if (!self) return;
        }
        if (event->button() == Qt::MiddleButton) {
            grabMouse(); send("middleDown", event->position(), event->modifiers()); return;
        }
        if (event->button() == Qt::RightButton) { send("rightDown", event->position(), event->modifiers()); return; }
        if (event->button() != Qt::LeftButton) { event->ignore(); return; }
        setFocus(Qt::MouseFocusReason);
        const QPoint at = event->position().toPoint();
        const bool repeat = m_clickTimer.isValid() && m_clickTimer.elapsed() < QApplication::doubleClickInterval()
            && (at - m_lastPress).manhattanLength() < 5;
        // Qt has already judged a double-click (its own timing and distance): that is the second click at least.
        m_clicks = event->type() == QEvent::MouseButtonDblClick ? qMax(2, m_clicks + 1) : repeat ? m_clicks + 1 : 1;
        m_clickTimer.restart();
        m_lastPress = at;
        grabMouse();
        QPointer<QWidget> self(this);
        g_appKitTracking = this;
        m_hasDragged = false;
        m_trackingDragTimer->start();
        send("down", event->position(), event->modifiers());
        if (self) {
            m_rowDragActive = compositor_current_layer_drag(nullptr, 0) > 0;
            if (!m_rowDragActive) m_trackingDragTimer->stop();
            // The final queued drag can change the clip origin immediately before release ends the native loop.
            synchronizeTrackingScroll(self);
        }
        if (g_appKitTracking == self) g_appKitTracking = nullptr;
        if (self && m_hasDragged) updateLayerTabTarget(m_lastDragGlobalPosition, m_lastDragModifiers);
    }
    /// The upstream native drag already owns the pointer grab. Offer its row payload to Qt's tab destination
    /// when the pointer leaves the Layers view; internal layer/mask/effect drags keep their existing routing.
    void updateLayerTabTarget(QPointF global, Qt::KeyboardModifiers modifiers) {
        if (qEnvironmentVariableIsSet("COMPOSITOR_PROBE_WITHOUT_LAYER_TAB_DRAG")) {
            m_layerTabTarget = nullptr; m_layerDrag.clear(); return;
        }
        QWidget *target = QApplication::widgetAt(global.toPoint());
        while (target && target->objectName() != QLatin1String("header.documentTabs")
               && target->objectName() != QLatin1String("header.dragArea")) target = target->parentWidget();
        if (!target) { m_layerTabTarget = nullptr; return; }
        const int64_t size = compositor_current_layer_drag(nullptr, 0);
        if (size <= 0 || size > 1048576) { m_layerTabTarget = nullptr; return; }
        m_layerDrag.resize(size);
        if (compositor_current_layer_drag(reinterpret_cast<uint8_t *>(m_layerDrag.data()), m_layerDrag.size()) != size) {
            m_layerTabTarget = nullptr; m_layerDrag.clear(); return;
        }
        QMimeData mime; mime.setData("com.compositor.layer-row", m_layerDrag);
        const QPoint point = target->mapFromGlobal(global.toPoint());
        if (m_layerTabTarget != target) {
            QDragEnterEvent enter(point, Qt::CopyAction, &mime, Qt::LeftButton, modifiers);
            QApplication::sendEvent(target, &enter);
            m_layerTabTarget = target;
        }
        QDragMoveEvent move(point, Qt::CopyAction, &mime, Qt::LeftButton, modifiers);
        QApplication::sendEvent(target, &move);
        setCursor(move.dropAction() == Qt::CopyAction ? Qt::DragCopyCursor : Qt::ForbiddenCursor);
    }
    void send(const char *type, const QPointF &at, Qt::KeyboardModifiers modifiers, bool externalLayerCopy = false) {
        recordPointerTrace(type, this, m_handle, at, appKitModifierBits(modifiers), m_clicks);
        const QJsonObject payload{{"type", QLatin1String(type)}, {"x", at.x()}, {"y", at.y()}, {"clicks", m_clicks},
                                  {"modifiers", appKitModifierBits(modifiers)}, {"externalLayerCopy", externalLayerCopy}};
        QPointer<QWidget> self(this);
        dispatchQuietly("pointer", QJsonDocument(payload).toJson(QJsonDocument::Compact));
        if (!self) return;   // what it did rebuilt the panel
        update();
        applyCompositorCursor(this);
    }
    void key(QKeyEvent *event) {
        static const QHash<int, int> codes{{Qt::Key_Return, 36}, {Qt::Key_Enter, 76}, {Qt::Key_Escape, 53}, {Qt::Key_Backspace, 51},
            {Qt::Key_Delete, 117}, {Qt::Key_Tab, 48}, {Qt::Key_Backtab, 48}, {Qt::Key_Space, 49}, {Qt::Key_Left, 123},
            {Qt::Key_Right, 124}, {Qt::Key_Down, 125}, {Qt::Key_Up, 126}, {Qt::Key_Home, 115}, {Qt::Key_End, 119},
            {Qt::Key_PageUp, 116}, {Qt::Key_PageDown, 121}};
        static const QHash<int, QString> typed{{Qt::Key_Return, "\r"}, {Qt::Key_Enter, "\u0003"}, {Qt::Key_Escape, "\u001b"},
            {Qt::Key_Backspace, "\u007f"}, {Qt::Key_Delete, QString(QChar(0xf728))}, {Qt::Key_Tab, "\t"}, {Qt::Key_Backtab, "\u0019"},
            {Qt::Key_Left, QString(QChar(0xf702))}, {Qt::Key_Right, QString(QChar(0xf703))}, {Qt::Key_Down, QString(QChar(0xf701))},
            {Qt::Key_Up, QString(QChar(0xf700))}};
        const int k = event->key();
        if (k == Qt::Key_Control || k == Qt::Key_Shift || k == Qt::Key_Alt || k == Qt::Key_Meta || k == Qt::Key_AltGr) return;
        QString characters = typed.value(k);
        if (characters.isEmpty()) characters = (k >= 0x20 && k < 0x7f) ? QString(QChar(k)).toLower() : event->text();
        if (event->modifiers() & Qt::ShiftModifier && k >= 0x20 && k < 0x7f && !event->text().isEmpty()) characters = event->text();
        const int keyCode = codes.contains(k) ? codes.value(k) : appKitPrintableKeyCode(event);
        const QJsonObject payload{{"characters", characters}, {"keyCode", keyCode},
                                  {"modifiers", appKitModifierBits(event->modifiers())}, {"repeat", event->isAutoRepeat()}};
        recordPointerTrace("key", this, m_handle, QPointF(codes.value(k, 0xffff), 0), appKitModifierBits(event->modifiers()), 0);
        QPointer<QWidget> self(this);
        // Model commands can precede the next paint. Update the native coordinator/cells before delivering keys,
        // without replacing the widget that owns focus (type selection must see current names and selection).
        fetchTreeBytes(m_handle, m_panel);
        if (!self) return;
        dispatchQuietly("key", QJsonDocument(payload).toJson(QJsonDocument::Compact));
        // A following pointer event uses the visible viewport before the periodic panel refresh runs.
        if (self) synchronizeTrackingScroll(self);
        if (self) update();
    }
    /// Straight to Swift: what the event changed marks the panels it touched dirty (Observation), and the shell's
    /// refresh picks that up, rather than every pointer move rebuilding panels here.
    void dispatchQuietly(const char *handlerKey, const QByteArray &payload) {
        const QByteArray panelUtf8 = m_panel.toUtf8(), nodeUtf8 = m_nodeID.toUtf8();
        const auto handle = m_handle;
        const void *owner = this;
        const char *phase = qstrcmp(handlerKey, "key") == 0 ? "dispatch-key" : qstrcmp(handlerKey, "pointer") == 0 ? "dispatch-pointer" : "dispatch-other";
        const int32_t result = compositor_session_dispatch_swiftui_action(m_handle, panelUtf8.constData(), nodeUtf8.constData(), handlerKey,
                                                   reinterpret_cast<const uint8_t *>(payload.constData()), static_cast<size_t>(payload.size()));
        recordPointerTrace(phase, owner, handle, QPointF(result, 0), 0, 0);
    }

    QString key() const { return m_panel + QLatin1Char('|') + m_nodeID; }

    uint64_t m_handle;
    QString m_panel, m_nodeID;
    int m_clicks = 1;
    QElapsedTimer m_clickTimer;
    QPoint m_lastPress;
    QTimer *m_trackingDragTimer = nullptr;
    bool m_hasDragged = false;
    bool m_rowDragActive = false;
    QPointF m_lastDragGlobalPosition;
    Qt::KeyboardModifiers m_lastDragModifiers = Qt::NoModifier;
    QPointer<QWidget> m_layerTabTarget;
    QByteArray m_layerDrag;
};

} // namespace

/// The event pump AppKit tracking loops run while they wait for the press's next event (NSApp.eventPump, registered
/// at startup): one turn of Qt's event loop. The shell's periodic refresh stands aside meanwhile (swiftUIAppKitTracking),
/// so no panel is rebuilt under the press. Returns whether the left button is still down.
extern "C" int32_t compositor_host_pump_events(void) {
    ++g_appKitPumpDepth;
    if (g_appKitTracking) synchronizeTrackingScroll(g_appKitTracking);
    QCoreApplication::processEvents(QEventLoop::WaitForMoreEvents);
    if (g_appKitTracking) g_appKitTracking->update();
    --g_appKitPumpDepth;
    return (QGuiApplication::mouseButtons() & Qt::LeftButton) ? 1 : 0;
}

bool swiftUIAppKitTracking() { return g_appKitPumpDepth > 0; }
QString swiftUIScrollTrace() {
    QStringList lines;
    for (unsigned index = g_scrollTraceCount > 512 ? g_scrollTraceCount - 512 : 0; index < g_scrollTraceCount; ++index) {
        const auto &entry = g_scrollTrace[index % 512];
        lines.append(QString("%1 %2 %3 y%4 max%5 desired%6 model%7 vh%8 dh%9 flags%10")
            .arg(index).arg(entry.event).arg(qulonglong(reinterpret_cast<quintptr>(entry.owner)), 0, 16)
            .arg(entry.y).arg(entry.maximum).arg(entry.desired).arg(entry.model)
            .arg(entry.viewportHeight).arg(entry.documentHeight).arg(entry.flags));
    }
    return lines.join('\n');
}

QString swiftUIPointerTrace() {
    QStringList lines;
    for (unsigned index = g_pointerTraceCount > 128 ? g_pointerTraceCount - 128 : 0; index < g_pointerTraceCount; ++index) {
        const auto &entry = g_pointerTrace[index % 128];
        lines.append(QString("%1 pointer-%2 widget %3 session %4 at %5,%6 modifiers %7 clicks %8")
            .arg(index).arg(entry.event).arg(qulonglong(reinterpret_cast<quintptr>(entry.owner)), 0, 16)
            .arg(qulonglong(entry.handle)).arg(entry.x).arg(entry.y).arg(entry.modifiers).arg(entry.clicks));
    }
    return lines.join('\n');
}

void swiftUITraceWindowKey(const void *owner, uint64_t handle, int code, int modifiers) {
    recordPointerTrace("window-key", owner, handle, QPointF(code, 0), modifiers, 0);
}

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
                       double inset, QWidget *parent = nullptr)
        : QWidget(parent), m_shapeKind(shapeKind), m_cornerRadius(cornerRadius), m_inset(inset),
          m_fillColor(fillColor), m_strokeColor(strokeColor), m_strokeWidth(strokeWidth) {
        setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);   // a Shape fills what it is offered
        setAttribute(Qt::WA_TransparentForMouseEvents, true);
    }

    QSize sizeHint() const override {
        return QSize(width() > 0 ? width() : 32, height() > 0 ? height() : 32);
    }
    /// A shape with neither fill nor stroke of its own fills with the foreground style around it, as SwiftUI's do
    /// (New Canvas's ⋯ is three bare Circles under `.foregroundStyle(.primary)`).
    void inheritForeground(const QColor &color) {
        if (m_fillColor.isValid() || (m_strokeWidth > 0 && m_strokeColor.isValid()) || !color.isValid()) return;
        m_fillColor = color;
        update();
    }

protected:
    void paintEvent(QPaintEvent *) override {
        QPainter p(this);
        p.setRenderHint(QPainter::Antialiasing, true);

        QRectF rect(0, 0, width(), height());
        rect.adjust(m_inset, m_inset, -m_inset, -m_inset);
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

        if (!m_path.isEmpty()) {
            // The shape's own outline: scaled from its 100×100 box to the view, or as drawn (a bare Path).
            QPainterPath path;
            const QStringList t = m_path.split(QLatin1Char(' '), Qt::SkipEmptyParts);
            const double sx = m_pathAbsolute ? 1 : width() / 100.0, sy = m_pathAbsolute ? 1 : height() / 100.0;
            auto pt = [&](int i) { return QPointF(t.value(i).toDouble() * sx, t.value(i + 1).toDouble() * sy); };
            for (int i = 0; i < t.size();) {
                const QString op = t[i];
                if (op == QLatin1String("M")) { path.moveTo(pt(i + 1)); i += 3; }
                else if (op == QLatin1String("L")) { path.lineTo(pt(i + 1)); i += 3; }
                else if (op == QLatin1String("Q")) { path.quadTo(pt(i + 1), pt(i + 3)); i += 5; }
                else if (op == QLatin1String("C")) { path.cubicTo(pt(i + 1), pt(i + 3), pt(i + 5)); i += 7; }
                else { path.closeSubpath(); i += 1; }
            }
            if (m_mirrorX || m_mirrorY) {
                p.translate(m_mirrorX ? width() : 0, m_mirrorY ? height() : 0);
                p.scale(m_mirrorX ? -1 : 1, m_mirrorY ? -1 : 1);
            }
            p.drawPath(path);
        } else if (m_shapeKind == "circle") {
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

public:
    QString m_path;
    bool m_pathAbsolute = false, m_mirrorX = false, m_mirrorY = false;
    void prepareAsMask() {
        if (!m_fillColor.isValid() && !(m_strokeWidth > 0 && m_strokeColor.isValid())) {
            m_fillColor = Qt::black;
            update();
        }
    }
private:
    QString m_shapeKind;
    double m_cornerRadius, m_inset;
    QColor m_fillColor;
    QColor m_strokeColor;
    double m_strokeWidth;
};

class SwiftUIMaskEffect : public QGraphicsOpacityEffect {
public:
    SwiftUIMaskEffect(QWidget *source, QWidget *mask, qreal opacity = 1.0) : QGraphicsOpacityEffect(source), m_mask(mask) {
        setOpacity(opacity);
        m_mask->setParent(source);
        m_mask->setAttribute(Qt::WA_TransparentForMouseEvents, true);
        m_mask->hide();
    }

protected:
    void draw(QPainter *painter) override {
        if (opacity() <= 0.0) return;
        QPoint offset;
        const QPixmap source = sourcePixmap(Qt::LogicalCoordinates, &offset, QGraphicsEffect::NoPad);
        if (source.isNull() || !m_mask) {
            QGraphicsOpacityEffect::draw(painter);
            return;
        }

        QImage masked = source.toImage().convertToFormat(QImage::Format_ARGB32_Premultiplied);
        QImage alpha(masked.size(), QImage::Format_ARGB32_Premultiplied);
        alpha.fill(Qt::transparent);
        m_mask->resize(masked.size());
        if (QLayout *layout = m_mask->layout()) layout->activate();
        {
            QPainter maskPainter(&alpha);
            m_mask->render(&maskPainter, QPoint(), QRegion(), QWidget::DrawWindowBackground | QWidget::DrawChildren);
        }
        {
            QPainter sourcePainter(&masked);
            sourcePainter.setCompositionMode(QPainter::CompositionMode_DestinationIn);
            sourcePainter.drawImage(0, 0, alpha);
        }
        painter->save();
        painter->setOpacity(painter->opacity() * opacity());
        painter->drawImage(offset, masked);
        painter->restore();
    }

private:
    QPointer<QWidget> m_mask;
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

void NativeAppKitAccessibility::notifyAccessibilityAction(uint64_t handle, const QString &panel) { notifyListeners(handle, panel); }

namespace {
/// dragChanged can arrive every mouse move; coalesce shell refreshes so the picker doesn't rebuild at 500 Hz.
struct DragActionRefreshCoalescer {
    QTimer timer;
    uint64_t handle = 0;
    QString panel;
    DragActionRefreshCoalescer() {
        timer.setSingleShot(true);
        timer.setInterval(16);
        QObject::connect(&timer, &QTimer::timeout, [this] {
            if (handle) notifyListeners(handle, panel);
        });
    }
    void schedule(uint64_t h, const QString &p) {
        handle = h;
        panel = p;
        if (!timer.isActive()) timer.start();
    }
    void flush(uint64_t h, const QString &p) {
        timer.stop();
        handle = h;
        panel = p;
        notifyListeners(handle, panel);
        handle = 0;
    }
} g_dragActionRefresh;
} // namespace

void dispatch(uint64_t handle, const QString &panel, const QString &nodeID, const QString &handlerKey,
              const QByteArray &payload = {}, bool deferRefresh = false) {
    const QByteArray panelUtf8 = panel.toUtf8(), nodeUtf8 = nodeID.toUtf8(), keyUtf8 = handlerKey.toUtf8();
    compositor_session_dispatch_swiftui_action(handle, panelUtf8.constData(), nodeUtf8.constData(), keyUtf8.constData(),
                                               payload.isEmpty() ? nullptr : reinterpret_cast<const uint8_t *>(payload.constData()),
                                               static_cast<size_t>(payload.size()));
    if (deferRefresh) QTimer::singleShot(0, [handle, panel] { notifyListeners(handle, panel); });
    else if (handlerKey == QLatin1String("dragChanged")) g_dragActionRefresh.schedule(handle, panel);
    else if (handlerKey == QLatin1String("dragEnded")) g_dragActionRefresh.flush(handle, panel);
    else notifyListeners(handle, panel);
}

class SwiftUIButton : public QPushButton {
public:
    using QPushButton::QPushButton;
    int takeActivationModifiers() { const int value = m_modifiers; m_modifiers = 0; return value; }
protected:
    bool event(QEvent *event) override {
        if (event->type() == QEvent::MouseButtonPress || event->type() == QEvent::MouseButtonRelease)
            m_modifiers = appKitModifierBits(static_cast<QMouseEvent *>(event)->modifiers());
        else if (event->type() == QEvent::KeyPress || event->type() == QEvent::KeyRelease)
            m_modifiers = appKitModifierBits(static_cast<QKeyEvent *>(event)->modifiers());
        return QPushButton::event(event);
    }
private:
    int m_modifiers = 0;
};

class SwiftUITextField : public QLineEdit {
public:
    explicit SwiftUITextField(bool handlesSubmit) : m_handlesSubmit(handlesSubmit) {}
    std::function<void()> onExitCommand;

protected:
    void keyPressEvent(QKeyEvent *event) override {
        if (event->key() == Qt::Key_Escape && onExitCommand) {
            event->accept();
            const auto exit = onExitCommand;
            exit();
            return;
        }
        QLineEdit::keyPressEvent(event);
        // onSubmit owns Return while editing; do not also activate a surrounding dialog's default button.
        if (m_handlesSubmit && (event->key() == Qt::Key_Return || event->key() == Qt::Key_Enter)) event->accept();
    }

private:
    bool m_handlesSubmit;
};

class TextFieldFocusFilter : public QObject {
public:
    TextFieldFocusFilter(QLineEdit *field, uint64_t handle, QString panel, QString nodeID)
        : QObject(field), m_handle(handle), m_panel(std::move(panel)), m_nodeID(std::move(nodeID)) {
        field->installEventFilter(this);
    }

protected:
    bool eventFilter(QObject *watched, QEvent *event) override {
        // Commit the draft before the next button action, but let the mouse press reach that button before a
        // visual refresh can replace its widgets. The pressed button keeps its panel alive until release.
        if (event->type() == QEvent::FocusOut && watched->property("swiftuiPreservingFocus").toBool()) return false;
        if (event->type() == QEvent::FocusIn || event->type() == QEvent::FocusOut)
            dispatch(m_handle, m_panel, m_nodeID, QStringLiteral("focused"), event->type() == QEvent::FocusIn ? "true" : "false", true);
        return QObject::eventFilter(watched, event);
    }

private:
    uint64_t m_handle;
    QString m_panel, m_nodeID;
};

int32_t dispatchDropEvent(uint64_t handle, const QString &panel, const QString &nodeID, const QByteArray &payload) {
    const QByteArray panelUtf8 = panel.toUtf8(), nodeUtf8 = nodeID.toUtf8(), keyUtf8 = QByteArrayLiteral("dropEvent");
    const int32_t result = compositor_session_dispatch_swiftui_drop_event(
        handle, panelUtf8.constData(), nodeUtf8.constData(), keyUtf8.constData(),
        reinterpret_cast<const uint8_t *>(payload.constData()), static_cast<size_t>(payload.size()));
    if (result >= 0) QTimer::singleShot(0, [handle, panel] { notifyListeners(handle, panel); });
    return result;
}

QByteArray jsonFragment(const QJsonValue &value) {
    QByteArray array = QJsonDocument(QJsonArray{value}).toJson(QJsonDocument::Compact);
    return array.mid(1, array.size() - 2); // strip the wrapping '[' ']'
}

class DropTargetFilter : public QObject {
public:
    DropTargetFilter(QWidget *widget, uint64_t handle, QString panel, QString nodeID, QStringList types)
        : QObject(widget), m_handle(handle), m_panel(std::move(panel)), m_nodeID(std::move(nodeID)), m_types(std::move(types)) {
        widget->setAcceptDrops(true);
        widget->installEventFilter(this);
    }

    bool eventFilter(QObject *, QEvent *event) override {
        switch (event->type()) {
        case QEvent::DragEnter: {
            auto *drop = static_cast<QDragEnterEvent *>(event);
            if (!matches(drop->mimeData())) return false;
            m_lastAccepted = dispatchDrop(QStringLiteral("entered"), payload(drop->mimeData(), drop->position(), false));
            if (m_lastAccepted <= 0) return false;
            drop->setDropAction(Qt::CopyAction);
            drop->accept();
            return true;
        }
        case QEvent::DragMove: {
            auto *drop = static_cast<QDragMoveEvent *>(event);
            if (!matches(drop->mimeData())) return false;
            drop->setDropAction(Qt::CopyAction);
            if (!m_updated.isValid() || m_updated.elapsed() >= 16) {
                m_updated.restart();
                m_lastAccepted = dispatchDrop(QStringLiteral("updated"), payload(drop->mimeData(), drop->position(), false));
            }
            if (m_lastAccepted <= 0) return false;
            drop->accept();
            return true;
        }
        case QEvent::DragLeave:
            dispatchDrop(QStringLiteral("exited"), payload(nullptr, {}, false));
            m_lastAccepted = 0;
            return true;
        case QEvent::Drop: {
            auto *drop = static_cast<QDropEvent *>(event);
            if (!matches(drop->mimeData())) return false;
            if (dispatchDrop(QStringLiteral("perform"), payload(drop->mimeData(), drop->position(), true)) <= 0) return false;
            drop->setDropAction(Qt::CopyAction);
            drop->accept();
            return true;
        }
        default:
            return false;
        }
    }

private:
    bool matches(const QMimeData *mime) const {
        if (!mime) return false;
        for (const QString &type : m_types) {
            if (type == QLatin1String("public.file-url") && mime->hasUrls()) return true;
            if (type == QLatin1String("public.image")) {
                if (mime->hasImage()) return true;
                for (const QString &format : mime->formats()) if (format.startsWith(QLatin1String("image/"))) return true;
            }
            if (mime->hasFormat(type)) return true;
        }
        return false;
    }

    QJsonObject payload(const QMimeData *mime, const QPointF &position, bool includeData) const {
        QJsonArray items;
        if (mime) {
            if (mime->hasUrls()) {
                for (const QUrl &url : mime->urls()) {
                    const QByteArray encoded = includeData ? url.toString(QUrl::FullyEncoded).toUtf8().toBase64() : QByteArray();
                    items.append(QJsonObject{{QStringLiteral("representations"), QJsonArray{
                        QJsonObject{{QStringLiteral("type"), QStringLiteral("public.file-url")},
                                    {QStringLiteral("data"), QString::fromLatin1(encoded)}}}}});
                }
            }
            QString imageFormat;
            if (!mime->hasImage()) {
                for (const QString &format : mime->formats()) {
                    if (format.startsWith(QLatin1String("image/"))) { imageFormat = format; break; }
                }
            }
            if (mime->hasImage() || !imageFormat.isEmpty()) {
                QByteArray bytes;
                if (includeData) {
                    if (!imageFormat.isEmpty()) {
                        bytes = mime->data(imageFormat);
                    } else {
                        const QImage image = qvariant_cast<QImage>(mime->imageData());
                        QBuffer buffer(&bytes);
                        if (!image.isNull() && buffer.open(QIODevice::WriteOnly)) image.save(&buffer, "PNG");
                    }
                }
                items.append(QJsonObject{{QStringLiteral("representations"), QJsonArray{
                    QJsonObject{{QStringLiteral("type"), QStringLiteral("public.image")},
                                {QStringLiteral("data"), QString::fromLatin1(bytes.toBase64())}}}}});
            }
            for (const QString &type : m_types) {
                if (!mime->hasFormat(type) || type == QLatin1String("public.file-url") || type == QLatin1String("public.image")) continue;
                items.append(QJsonObject{{QStringLiteral("representations"), QJsonArray{
                    QJsonObject{{QStringLiteral("type"), type},
                                {QStringLiteral("data"), QString::fromLatin1(includeData ? mime->data(type).toBase64() : QByteArray())}}}}});
            }
        }
        return QJsonObject{{QStringLiteral("location"), QJsonObject{
                    {QStringLiteral("x"), position.x()}, {QStringLiteral("y"), position.y()}}},
                {QStringLiteral("items"), items}};
    }

    int32_t dispatchDrop(const QString &phase, QJsonObject data) const {
        data.insert(QStringLiteral("phase"), phase);
        const QByteArray encoded = QJsonDocument(data).toJson(QJsonDocument::Compact);
        return dispatchDropEvent(m_handle, m_panel, m_nodeID, encoded);
    }

    uint64_t m_handle;
    QString m_panel, m_nodeID;
    QStringList m_types;
    QElapsedTimer m_updated;
    int32_t m_lastAccepted = 0;
};

class GeometryChangeFilter : public QObject {
public:
    GeometryChangeFilter(QWidget *widget, uint64_t handle, QString panel, QString nodeID)
        : QObject(widget), m_widget(widget), m_handle(handle), m_panel(std::move(panel)), m_nodeID(std::move(nodeID)) {
        widget->installEventFilter(this);
        QPointer<GeometryChangeFilter> self(this);
        QTimer::singleShot(0, widget, [self] { if (self) self->report(); });
    }

protected:
    bool eventFilter(QObject *, QEvent *event) override {
        if (event->type() == QEvent::Resize || event->type() == QEvent::Move || event->type() == QEvent::Show) {
            QPointer<GeometryChangeFilter> self(this);
            QTimer::singleShot(0, m_widget, [self] { if (self) self->report(); });
        }
        return false;
    }

private:
    void report() {
        if (!m_widget) return;
        const QSize now = m_widget->size();
        if (now.isEmpty()) return;
        QJsonObject frames;
        for (QWidget *ancestor = m_widget; ancestor; ancestor = ancestor->parentWidget()) {
            const QStringList names = ancestor->property("swiftuiCoordinateSpaces").toStringList();
            if (names.isEmpty()) continue;
            const QPoint origin = m_widget->mapTo(ancestor, QPoint(0, 0));
            for (const QString &name : names) {
                frames.insert(name, QJsonArray{origin.x(), origin.y(), now.width(), now.height()});
            }
        }
        const QPoint globalOrigin = m_widget->mapToGlobal(QPoint(0, 0));
        frames.insert(QStringLiteral("global"), QJsonArray{globalOrigin.x(), globalOrigin.y(), now.width(), now.height()});
        const QJsonObject payload{{QStringLiteral("size"), QJsonArray{now.width(), now.height()}},
                                  {QStringLiteral("frames"), frames}};
        const QByteArray json = QJsonDocument(payload).toJson(QJsonDocument::Compact);
        if (json == m_lastPayload) return;
        m_lastPayload = json;
        dispatch(m_handle, m_panel, m_nodeID, QStringLiteral("geometryChange"), json);
    }

    QPointer<QWidget> m_widget;
    uint64_t m_handle;
    QString m_panel, m_nodeID;
    QByteArray m_lastPayload;
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
        // Esc is a key like any other here, as upstream's recorder takes it (ShortcutChord: keyCode 53 -> "\u{1b}").
        case Qt::Key_Escape: key = QStringLiteral("\x1b"); break;
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

extern "C" int32_t compositor_current_cursor(void);
extern "C" int64_t compositor_canvas_cursor_image(int32_t *width, int32_t *height, double *hotX, double *hotY, uint8_t *output, size_t capacity);

/// Apply whatever NSCursor.set() last chose: stock shapes 0–9, or the custom picture for code 10
/// (NumericScrub arrows, eyedropper, zoom magnifier — same path as the canvas and layer list).
static void applyCompositorCursor(QWidget *widget) {
    if (!widget) return;
    static const Qt::CursorShape shapes[] = {
        Qt::ArrowCursor, Qt::IBeamCursor, Qt::CrossCursor, Qt::OpenHandCursor, Qt::ClosedHandCursor,
        Qt::PointingHandCursor, Qt::SizeHorCursor, Qt::SizeVerCursor, Qt::SizeFDiagCursor, Qt::SizeBDiagCursor,
        Qt::ArrowCursor
    };
    const int code = compositor_current_cursor();
    if (code < 0 || code > 10) return;
    if (code == 10) {
        int32_t w = 0, h = 0;
        double hx = 0, hy = 0;
        const int64_t size = compositor_canvas_cursor_image(&w, &h, &hx, &hy, nullptr, 0);
        if (size > 0 && size == int64_t(w) * h * 4) {
            QByteArray bytes(qsizetype(size), Qt::Uninitialized);
            compositor_canvas_cursor_image(&w, &h, &hx, &hy, reinterpret_cast<uint8_t *>(bytes.data()), size_t(bytes.size()));
            const QImage image(reinterpret_cast<const uchar *>(bytes.constData()), w, h, w * 4, QImage::Format_RGBA8888_Premultiplied);
            widget->setCursor(QCursor(QPixmap::fromImage(image.copy()), qRound(hx), qRound(hy)));
            return;
        }
    }
    widget->setCursor(shapes[code]);
}

/// SwiftUI's `onContinuousHover`: the pointer's position in the view as it moves over it, "ended" when it leaves; the
/// cursor is whatever the handler set (NSCursor.set()).
///
/// A handler usually changes state (NumericScrub's isHovering), so the panel is rebuilt — and the rebuilt view, under
/// the pointer, gets a fresh hover-enter. So a report goes out only when it differs from the last one for that view (a
/// rebuilt widget keeps its view's id), and after the event that caused it, never from inside a rebuild.
class HoverFilter : public QObject {
public:
    HoverFilter(QWidget *widget, uint64_t handle, QString panel, QString id)
        : QObject(widget), m_widget(widget), m_handle(handle), m_panel(std::move(panel)), m_id(std::move(id)) {
        widget->setAttribute(Qt::WA_Hover, true);
        widget->installEventFilter(this);
    }
protected:
    bool eventFilter(QObject *, QEvent *event) override {
        QByteArray payload;
        if (event->type() == QEvent::HoverEnter || event->type() == QEvent::HoverMove) {
            const QPointF p = static_cast<QHoverEvent *>(event)->position();
            payload = "[" + QByteArray::number(qRound(p.x())) + "," + QByteArray::number(qRound(p.y())) + "]";
        } else if (event->type() == QEvent::HoverLeave) {
            payload = "\"ended\"";
        } else {
            return false;
        }
        const QString key = m_panel + QLatin1Char('/') + m_id;
        auto &last = lastReports();
        // Only a change of phase (entering, leaving) matters to a handler that doesn't read the position; a move within
        // the view is reported, but a rebuilt view's hover-enter at the same point is not.
        const QByteArray previous = last.value(key);
        if (previous == payload) return false;
        const bool phaseChanged = previous.isEmpty() || previous.startsWith('"') != payload.startsWith('"');
        last.insert(key, payload);
        if (!phaseChanged && pending().contains(key)) { pending()[key] = payload; return false; }
        pending()[key] = payload;
        QPointer<QWidget> widget = m_widget;
        const uint64_t handle = m_handle;
        const QString panel = m_panel, id = m_id;
        QTimer::singleShot(0, [key, handle, panel, id, widget] {
            const QByteArray latest = pending().take(key);
            if (latest.isEmpty()) return;
            dispatch(handle, panel, id, QStringLiteral("onContinuousHover"), latest);
            if (!widget) return;
            applyCompositorCursor(widget);
        });
        return false;
    }
private:
    static QHash<QString, QByteArray> &lastReports() { static QHash<QString, QByteArray> reports; return reports; }
    static QHash<QString, QByteArray> &pending() { static QHash<QString, QByteArray> queued; return queued; }
    QWidget *m_widget;
    uint64_t m_handle;
    QString m_panel, m_id;
};

class TapGestureFilter : public QObject {
public:
    /// `onTap` gets the click's modifier keys as ShortcutChord bits (Ctrl 1, Alt 2, Meta 4, Shift 8).
    TapGestureFilter(QObject *parent, int tapCount, int spatialTapCount,
                     std::function<void(int)> onTap, std::function<void(QPointF)> onSpatialTap)
        : QObject(parent), m_tapCount(tapCount), m_spatialTapCount(spatialTapCount),
          m_onTap(std::move(onTap)), m_onSpatialTap(std::move(onSpatialTap)) {}
protected:
    bool eventFilter(QObject *obj, QEvent *event) override {
        if (event->type() == QEvent::MouseButtonRelease && m_suppressRelease) {
            m_suppressRelease = false;
            return true;
        }
        if (event->type() == QEvent::MouseButtonRelease || event->type() == QEvent::MouseButtonDblClick) {
            auto *me = static_cast<QMouseEvent *>(event);
            if (me->button() != Qt::LeftButton) return QObject::eventFilter(obj, event);
            const int tapCount = m_tapCount;
            const int spatialTapCount = m_spatialTapCount;
            const auto onTap = m_onTap;
            const auto onSpatialTap = m_onSpatialTap;
            const bool single = event->type() == QEvent::MouseButtonRelease;
            bool handled = false;
            if (!single && tapCount != 1 && spatialTapCount != 1
                && ((tapCount == 2 && onTap) || (spatialTapCount == 2 && onSpatialTap))) m_suppressRelease = true;
            if (single && tapCount == 1 && onTap) {
                const Qt::KeyboardModifiers m = me->modifiers();
                const int bits = (m & Qt::ControlModifier ? 1 : 0) | (m & Qt::AltModifier ? 2 : 0) | (m & Qt::MetaModifier ? 4 : 0)
                               | (m & Qt::ShiftModifier ? 8 : 0);
                onTap(bits);
                handled = true;
            }
            if (single && spatialTapCount == 1 && onSpatialTap) {
                onSpatialTap(me->position());
                handled = true;
            }
            if (!single && tapCount == 2 && onTap) {
                const Qt::KeyboardModifiers m = me->modifiers();
                const int bits = (m & Qt::ControlModifier ? 1 : 0) | (m & Qt::AltModifier ? 2 : 0) | (m & Qt::MetaModifier ? 4 : 0)
                               | (m & Qt::ShiftModifier ? 8 : 0);
                onTap(bits);
                handled = true;
            }
            if (!single && spatialTapCount == 2 && onSpatialTap) {
                handled = true;
            }
            if (!single && spatialTapCount == 2 && onSpatialTap) onSpatialTap(me->position());
            if (handled) return true;
        }
        return QObject::eventFilter(obj, event);
    }
private:
    int m_tapCount;
    int m_spatialTapCount;
    bool m_suppressRelease = false;
    std::function<void(int)> m_onTap;
    std::function<void(QPointF)> m_onSpatialTap;
};

class PopoverDismissFilter : public QObject {
public:
    PopoverDismissFilter(QWidget *popover, uint64_t handle, QString panel, QString id)
        : QObject(popover), m_handle(handle), m_panel(std::move(panel)), m_id(std::move(id)) {
        popover->installEventFilter(this);
    }

    bool eventFilter(QObject *, QEvent *event) override {
        if (event->type() == QEvent::Show) m_visible = true;
        if (event->type() == QEvent::Hide && m_visible) {
            m_visible = false;
            const uint64_t handle = m_handle;
            const QString panel = m_panel, id = m_id;
            QTimer::singleShot(0, qApp, [handle, panel, id] {
                dispatch(handle, panel, id, QStringLiteral("dismiss"));
            });
        }
        return false;
    }

private:
    uint64_t m_handle;
    QString m_panel, m_id;
    bool m_visible = false;
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

/// `icon` turned by `degrees` about its centre, at 2x.
static QIcon rotatedIcon(const QIcon &icon, const QSize &size, double degrees) {
    if (degrees == 0 || icon.isNull()) return icon;
    const qreal dpr = 2;
    const QPixmap source = icon.pixmap(size * dpr);
    QPixmap turned(size * dpr);
    turned.fill(Qt::transparent);
    QPainter painter(&turned);
    painter.setRenderHint(QPainter::SmoothPixmapTransform);
    painter.translate(turned.width() / 2.0, turned.height() / 2.0);
    painter.rotate(degrees);
    painter.drawPixmap(QPointF(-source.width() / 2.0, -source.height() / 2.0), source);
    painter.end();
    turned.setDevicePixelRatio(dpr);
    return QIcon(turned);
}

static QStringList &unresolvedSymbolList() {
    static QStringList symbols;
    return symbols;
}
void swiftUINoteUnresolvedSymbol(const QString &symbol) {
    if (!symbol.isEmpty() && !unresolvedSymbolList().contains(symbol)) unresolvedSymbolList().append(symbol);
}
QStringList swiftUIUnresolvedSymbols() { return unresolvedSymbolList(); }
void swiftUIClearUnresolvedSymbols() { unresolvedSymbolList().clear(); }

QIcon renderToolVectorIcon(const QString &symbol, int size, const QColor &color) {
    // `base|badge=name`: a label's ZStack of a symbol and a small badge symbol (upstream's eyedropper with a plus or
    // minus, `.font(.system(size: 8))` at `.bottomTrailing`, offset 3, 1): the base at full size, the badge at about
    // half size in the bottom-trailing corner, over a cut-out so it reads on top of the base's strokes.
    if (const int bar = symbol.indexOf(QLatin1String("|badge=")); bar >= 0) {
        const QString base = symbol.left(bar), badge = symbol.mid(bar + 7);
        const qreal dpr = qApp ? std::max<qreal>(qApp->devicePixelRatio(), 2.0) : 2.0;
        QPixmap pixmap(QSize(size, size) * dpr);
        pixmap.setDevicePixelRatio(dpr);
        pixmap.fill(Qt::transparent);
        QPainter painter(&pixmap);
        painter.setRenderHint(QPainter::Antialiasing);
        painter.drawPixmap(QRectF(0, 0, size, size), renderToolVectorIcon(base, size, color).pixmap(QSize(size, size) * dpr),
                           QRectF(0, 0, size * dpr, size * dpr));
        const qreal badgeSize = std::max<qreal>(7, size * 0.55);
        const QRectF corner(size - badgeSize, size - badgeSize, badgeSize, badgeSize);
        painter.setCompositionMode(QPainter::CompositionMode_Clear);
        painter.setPen(Qt::NoPen);
        painter.setBrush(Qt::black);
        painter.drawEllipse(corner.adjusted(-1, -1, 1, 1));
        painter.setCompositionMode(QPainter::CompositionMode_SourceOver);
        const int badgePixels = qRound(badgeSize * dpr);
        painter.drawPixmap(corner, renderToolVectorIcon(badge, qRound(badgeSize), color).pixmap(badgePixels, badgePixels),
                           QRectF(0, 0, badgePixels, badgePixels));
        painter.end();
        return QIcon(pixmap);
    }
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
        // No picture for this name: a placeholder square, recorded so `--ui-audit-probe` reports it.
        swiftUINoteUnresolvedSymbol(symbol);
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

class SwiftUILineLimitFilter : public QObject {
public:
    SwiftUILineLimitFilter(QLabel *label, int lines)
        : QObject(label), m_label(label), m_text(label->text()), m_lines(qMax(1, lines)) {
        label->installEventFilter(this);
        label->setWordWrap(m_lines > 1);
        updateText();
    }

protected:
    bool eventFilter(QObject *, QEvent *event) override {
        if (event->type() == QEvent::Resize || event->type() == QEvent::FontChange) updateText();
        return false;
    }

private:
    void updateText() {
        if (!m_label || m_label->width() <= 0) return;
        const QMargins margins = m_label->contentsMargins();
        const int lineHeight = m_label->fontMetrics().lineSpacing();
        m_label->setMaximumHeight(lineHeight * m_lines + margins.top() + margins.bottom());
        const QString shown = m_lines == 1
            ? m_label->fontMetrics().elidedText(m_text, Qt::ElideRight,
                qMax(0, m_label->width() - margins.left() - margins.right()))
            : m_text;
        if (m_label->text() != shown) m_label->setText(shown);
    }

    QPointer<QLabel> m_label;
    QString m_text;
    int m_lines;
};

/// Applies the modifiers this first pass understands (the highest-frequency ones, per the plan); an unrecognised
/// modifier kind is silently skipped rather than failing the whole render — additive coverage, not all-or-nothing.
void applyModifiers(QWidget *widget, const QJsonArray &modifiers) {
    ensureSwiftUIAccessibilityFactory();
    for (const auto &entry : modifiers) {
        const QJsonObject modifier = entry.toObject();
        const QString kind = modifier.value("kind").toString();
        const QJsonObject doubles = modifier.value("doubleParams").toObject();
        const QJsonObject strings = modifier.value("stringParams").toObject();
        const QJsonObject bools = modifier.value("boolParams").toObject();
        if (kind == "coordinateSpace") {
            QStringList names = widget->property("swiftuiCoordinateSpaces").toStringList();
            const QString name = strings.value("name").toString();
            if (!name.isEmpty() && !names.contains(name)) names.append(name);
            widget->setProperty("swiftuiCoordinateSpaces", names);
        } else if (kind == "dragGesture") {
            widget->setProperty("swiftuiGestureCoordinateSpace", strings.value("coordinateSpace").toString());
            widget->setProperty("swiftuiGestureMinimumDistance", doubles.value("minimumDistance").toDouble(10.0));
        } else if (kind == "opacity") {
            // Opacity composites this view and its children together, keeping its place in the layout. Repeated
            // modifiers multiply; a parent's effect also composites any opacity already set on its children.
            const qreal opacity = qBound(0.0, doubles.value("value").toDouble(1.0), 1.0);
            if (auto *effect = qobject_cast<QGraphicsOpacityEffect *>(widget->graphicsEffect())) {
                effect->setOpacity(effect->opacity() * opacity);
            } else if (opacity < 1.0) {
                auto *effect = new QGraphicsOpacityEffect(widget);
                effect->setOpacity(opacity);
                widget->setGraphicsEffect(effect);
            }
        } else if (kind == "scrollIndicators") {
            // .scrollIndicators(.hidden / .never): the view still scrolls (wheel, trackpad), with no scroll bars drawn.
            // Qt has no system "always show scrollers" setting to override, so both hide them alike.
            const QString visibility = strings.value("name").toString();
            if (auto *scrollArea = qobject_cast<QScrollArea *>(widget); scrollArea && (visibility == "hidden" || visibility == "never")) {
                scrollArea->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
                scrollArea->setVerticalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
            }
        } else if (kind == "allowsHitTesting") {
            widget->setAttribute(Qt::WA_TransparentForMouseEvents, !bools.value("enabled").toBool());
        } else if (kind == "tapGesture") {
            widget->setProperty("swiftuiTapGestureCount", qMax(1, qRound(doubles.value("count").toDouble(1.0))));
        } else if (kind == "spatialTapGesture") {
            widget->setProperty("swiftuiSpatialTapGestureCount", qMax(1, qRound(doubles.value("count").toDouble(1.0))));
        } else if (kind == "clipped") {
            widget->setMask(QRegion(widget->rect()));
        } else if (kind == "frame") {
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
            if (auto named = nativeFontForToken(strings.value("name").toString(), widget->font())) {
                widget->setFont(*named);
                continue;
            }
            const QStringList parts = strings.value("name").toString().split(QLatin1Char('+'));
            QFont font = widget->font();
            static const QHash<QString, std::pair<int, QFont::Weight>> styles{
                {"largeTitle", {26, QFont::Normal}}, {"title", {22, QFont::Normal}}, {"title2", {17, QFont::Normal}},
                {"title3", {15, QFont::Normal}}, {"headline", {13, QFont::Bold}}, {"subheadline", {11, QFont::Normal}},
                {"body", {13, QFont::Normal}}, {"callout", {12, QFont::Normal}}, {"footnote", {10, QFont::Normal}},
                {"caption", {10, QFont::Normal}}, {"caption2", {10, QFont::Normal}}};
            const QString base = parts.value(0);
            if (base.startsWith(QLatin1String("system:"))) {
                font.setPixelSize(qMax(1, qRound(base.mid(7).toDouble())));
                font.setWeight(QFont::Normal);
            } else if (auto it = styles.constFind(base); it != styles.constEnd()) {
                font.setPixelSize(it->first);
                font.setWeight(it->second);
            }
            for (const QString &part : parts.mid(1)) {
                if (part.startsWith(QLatin1String("weight:"))) font.setWeight(fontWeightForName(part.mid(7)));
                else if (part == QLatin1String("bold")) font.setWeight(QFont::Bold);
                else if (part == QLatin1String("monospacedDigit")) font.setFeature(QFont::Tag("tnum"), 1);
                else if (part == QLatin1String("design:monospaced")) font.setFamilies(QFontDatabase::systemFont(QFontDatabase::FixedFont).families());
                else if (part.startsWith(QLatin1String("family:"))) font = fontFor(part.mid(7).toUtf8().constData(), font.pixelSize() > 0 ? font.pixelSize() : font.pointSizeF());   // Font.custom(_:size:)
            }
            widget->setFont(font);
        } else if (kind == "rotationEffect") {
            // A symbol image turned (SwiftUI rotates about its centre).
            if (auto *label = qobject_cast<QLabel *>(widget); label && !label->pixmap().isNull()) {
                const QPixmap source = label->pixmap();
                QPixmap turned(source.size());
                turned.fill(Qt::transparent);
                QPainter painter(&turned);
                painter.setRenderHint(QPainter::SmoothPixmapTransform);
                painter.translate(turned.width() / 2.0, turned.height() / 2.0);
                painter.rotate(doubles.value("radians").toDouble() * 180.0 / M_PI);
                painter.drawPixmap(QPointF(-source.width() / 2.0, -source.height() / 2.0), source);
                painter.end();
                turned.setDevicePixelRatio(source.devicePixelRatio());
                label->setPixmap(turned);
            }
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
        } else if (kind == "lineLimit") {
            const int lines = qMax(1, qRound(doubles.value("lines").toDouble()));
            QList<QLabel *> labels = widget->findChildren<QLabel *>();
            if (auto *self = qobject_cast<QLabel *>(widget)) labels.prepend(self);
            for (QLabel *label : labels) new SwiftUILineLimitFilter(label, lines);
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
                    button->setProperty("buttonStyleName", name);
                    if (button->property("buttonStyled").toBool() || button->text().isEmpty() || button->isCheckable()) continue;
                    button->setProperty("buttonStyled", true);
                    button->setStyleSheet(qss);
                }
            }
        } else if (kind == "buttonBorderShape") {
            const QString shape = strings.value("name").toString();
            // Qt's style sheets don't clamp a radius to half the height as CSS does (a huge one draws square
            // corners): a capsule's is half the button's own height.
            const bool capsule = shape == QLatin1String("capsule") || shape == QLatin1String("circle");
            const QString radius = capsule ? QStringLiteral("capsule")
                : shape == QLatin1String("roundedRectangle") ? QStringLiteral("6px") : QString();
            if (!radius.isEmpty()) {
                QList<QPushButton *> buttons = widget->findChildren<QPushButton *>();
                if (auto *self = qobject_cast<QPushButton *>(widget)) buttons.prepend(self);
                for (QPushButton *button : buttons) {
                    const QString style = button->property("buttonStyleName").toString();
                    if (style == QLatin1String("plain") || style == QLatin1String("borderless") ||
                        button->styleSheet().contains(QLatin1String("background: transparent")) ||
                        button->property("buttonBorderShape").toString() == shape) continue;
                    const QString r = capsule ? QStringLiteral("%1px").arg(std::max(1, button->sizeHint().height() / 2)) : radius;
                    button->setStyleSheet(button->styleSheet() + QStringLiteral(" QPushButton { border-radius: %1; }").arg(r));
                    button->setProperty("buttonBorderShape", shape);
                }
            }
        } else if (kind == "pointerStyle") {
            const QString pointerStyle = strings.value("name").toString();
            if (pointerStyle == QLatin1String("columnResize") || pointerStyle == QLatin1String("horizontalResize"))
                widget->setCursor(Qt::SizeHorCursor);
            else if (pointerStyle == QLatin1String("verticalResize"))
                widget->setCursor(Qt::SizeVerCursor);
        } else if (kind == "controlSize") {
            // AppKit control sizes carry their own text size: small 11, mini 9 (regular keeps the environment's).
            const QString size = strings.value("name").toString();
            // Large: AppKit's large push buttons stand 28 points high.
            if (size == QLatin1String("large")) {
                QList<QPushButton *> buttons = widget->findChildren<QPushButton *>();
                if (auto *self = qobject_cast<QPushButton *>(widget)) buttons.prepend(self);
                for (QPushButton *button : buttons) button->setMinimumHeight(28);
            }
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
            // Only the axes asked for: `.fixedSize(horizontal: false, vertical: true)` lets a text wrap to its width,
            // and FilterSheet's `.fixedSize(horizontal: false, vertical: !isCameraRaw)` fixes nothing for Camera Raw,
            // whose column then takes the panel's height instead of floating in its middle.
            QSizePolicy policy = widget->sizePolicy();
            if (!bools.contains("horizontal") || bools.value("horizontal").toBool()) policy.setHorizontalPolicy(QSizePolicy::Fixed);
            if (!bools.contains("vertical") || bools.value("vertical").toBool()) policy.setVerticalPolicy(QSizePolicy::Fixed);
            widget->setSizePolicy(policy);
        } else if (kind == "help" || kind == "accessibilityLabel") {
            const QString text = strings.value("text").toString();
            if (!text.isEmpty()) {
                if (kind == "help") {
                    widget->setToolTip(text);
                    // An icon-only button or menu is named by its help, as its tooltip is all a person sees of it
                    // (an explicit accessibilityLabel still replaces this).
                    if (auto *button = qobject_cast<QAbstractButton *>(widget); button && button->text().trimmed().isEmpty()
                        && button->accessibleName().isEmpty()) button->setAccessibleName(text);
                } else widget->setAccessibleName(text);
            }
        } else if (kind == "identifier") {
            widget->setProperty("swiftuiIdentifier", strings.value("text").toString());   // .id(_:), for scrollTo
        } else if (kind == "accessibilityIdentifier") {
            const QString id = strings.value("text").toString();
            if (!id.isEmpty()) widget->setObjectName(id);
        } else if (kind == "accessibilityHidden") {
            widget->setProperty("swiftuiAccessibilityHidden", bools.value("value").toBool());
            widget->setProperty("swiftuiAccessibilityAdapter", true);
        } else if (kind == "accessibilityValue") {
            const QString value = strings.value("value").toString();
            widget->setProperty("swiftuiAccessibilityValue", value);
            if (hasNativeAccessibilityInterface(widget)) widget->setAccessibleDescription(value);
            else widget->setProperty("swiftuiAccessibilityAdapter", true);
        } else if (kind == "accessibilityElement") {
            const QString children = strings.value("children").toString();
            widget->setProperty("swiftuiAccessibilityChildren", children);
            if (!hasNativeAccessibilityInterface(widget)) widget->setProperty("swiftuiAccessibilityAdapter", true);
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
                for (QWidget *w : symbols) if (auto *shape = dynamic_cast<SwiftUIShapeWidget *>(w)) shape->inheritForeground(color);
                for (QWidget *w : symbols) {
                    const QString symbol = w->property("systemIcon").toString();
                    if (symbol.isEmpty() || w->property("tinted").toBool()) continue;
                    const int size = w->property("iconSize").toInt() > 0 ? w->property("iconSize").toInt() : 16;
                    if (auto *button = qobject_cast<QAbstractButton *>(w))
                        button->setIcon(rotatedIcon(renderToolVectorIcon(symbol, size, color), button->iconSize(), w->property("iconRotation").toDouble()));
                    else if (auto *label = qobject_cast<QLabel *>(w)) label->setPixmap(renderToolVectorIcon(symbol, size, color).pixmap(size, size));
                    w->setProperty("tinted", true);
                }
            }
        }
    }
}

/// A `.resizable()` bitmap: scales within its layout slot using SwiftUI's aspect mode.
class SwiftUIFitImageWidget : public QWidget {
public:
    explicit SwiftUIFitImageWidget(QImage image, QString contentMode, qreal aspectRatio)
        : m_image(std::move(image)), m_contentMode(std::move(contentMode)), m_aspectRatio(aspectRatio) {
        QSizePolicy policy(QSizePolicy::Expanding, QSizePolicy::Expanding);
        policy.setHeightForWidth(m_aspectRatio > 0.0);
        setSizePolicy(policy);
    }
    QSize sizeHint() const override { return m_image.size().scaled(560, 560, Qt::KeepAspectRatio); }
    bool hasHeightForWidth() const override { return m_aspectRatio > 0.0; }
    int heightForWidth(int width) const override {
        return m_aspectRatio > 0.0 ? qRound(width / m_aspectRatio) : QWidget::heightForWidth(width);
    }
protected:
    void paintEvent(QPaintEvent *) override {
        QPainter painter(this);
        painter.setRenderHint(QPainter::SmoothPixmapTransform, true);
        const bool fill = m_contentMode == QLatin1String("fill");
        const QSize scaled = m_image.size().scaled(size(), fill ? Qt::KeepAspectRatioByExpanding : Qt::KeepAspectRatio);
        const QRect target(QPoint((width() - scaled.width()) / 2, (height() - scaled.height()) / 2), scaled);
        painter.setClipRect(rect());
        painter.drawImage(target, m_image);
    }
private:
    QImage m_image;
    QString m_contentMode;
    qreal m_aspectRatio;
};

QWidget *buildNode(uint64_t handle, const QString &panel, const QJsonObject &node);

/// A ZStack: children layered in order, filling it, or placed by `.position` / at the alignment when fixed-size.
class SwiftUIZStackWidget : public QWidget {
public:
    explicit SwiftUIZStackWidget(QString alignment) : m_alignment(std::move(alignment)) {}
    void add(QWidget *child, const QJsonObject &node) {
        child->setParent(this);
        for (const auto &m : node.value("modifiers").toArray()) {
            const QJsonObject mo = m.toObject();
            if (mo.value("kind").toString() != QLatin1String("position")) continue;
            child->setProperty("positionX", mo.value("doubleParams").toObject().value("x").toDouble());
            child->setProperty("positionY", mo.value("doubleParams").toObject().value("y").toDouble());
            child->setProperty("positioned", true);
        }
        child->show();
        m_children << child;
        // A stack is as flexible as its most flexible layer, as SwiftUI sizes a ZStack: a Canvas or a row with a Spacer
        // makes it take the width it is offered (Camera Raw's histogram spans its column).
        if (!child->property("positioned").toBool()) {
            QSizePolicy policy = sizePolicy();
            if (child->sizePolicy().horizontalPolicy() & QSizePolicy::ExpandFlag) policy.setHorizontalPolicy(QSizePolicy::Expanding);
            if (child->sizePolicy().verticalPolicy() & QSizePolicy::ExpandFlag) policy.setVerticalPolicy(QSizePolicy::Expanding);
            setSizePolicy(policy);
        }
    }
    QSize sizeHint() const override {
        QSize hint(0, 0);
        for (QWidget *w : m_children) if (!w->property("positioned").toBool()) hint = hint.expandedTo(ownSize(w));
        return hint.isEmpty() ? QSize(20, 20) : hint;
    }
    /// At least as large as each layer's own minimum (a `.frame(height: 110)` graph keeps the stack 110 tall).
    QSize minimumSizeHint() const override {
        QSize least(0, 0);
        for (QWidget *w : m_children) if (!w->property("positioned").toBool()) least = least.expandedTo(w->minimumSize()).expandedTo(w->minimumSizeHint());
        return least;
    }
protected:
    /// A layer's own size: its fixed size, else its size hint grown to its minimum, with a fixed dimension kept.
    static QSize ownSize(QWidget *w) {
        if (w->minimumSize() == w->maximumSize() && !w->minimumSize().isEmpty()) return w->minimumSize();
        QSize own = w->sizeHint().expandedTo(w->minimumSize());
        if (w->minimumHeight() > 0 && w->minimumHeight() == w->maximumHeight()) own.setHeight(w->minimumHeight());
        if (w->minimumWidth() > 0 && w->minimumWidth() == w->maximumWidth()) own.setWidth(w->minimumWidth());
        return own;
    }
    void resizeEvent(QResizeEvent *event) override {
        QWidget::resizeEvent(event);
        for (QWidget *w : std::as_const(m_children)) {
            const QSize own = ownSize(w);
            if (w->property("positioned").toBool()) {
                const QPointF c(w->property("positionX").toDouble(), w->property("positionY").toDouble());
                w->setGeometry(QRect(qRound(c.x() - own.width() / 2.0), qRound(c.y() - own.height() / 2.0), own.width(), own.height()));
            } else if (w->minimumSize() == w->maximumSize() && !w->minimumSize().isEmpty()) {
                int x = (width() - own.width()) / 2, y = (height() - own.height()) / 2;
                if (m_alignment.contains(QLatin1String("eading"))) x = 0;
                if (m_alignment.contains(QLatin1String("railing"))) x = width() - own.width();
                if (m_alignment.startsWith(QLatin1String("top"))) y = 0;
                if (m_alignment.startsWith(QLatin1String("bottom"))) y = height() - own.height();
                w->setGeometry(x + w->property("offsetX").toInt(), y + w->property("offsetY").toInt(), own.width(), own.height());
            } else {
                w->setGeometry(rect());
            }
        }
    }
private:
    QString m_alignment;
    QList<QWidget *> m_children;
};

/// A DragGesture: from the press on its view until the release, wherever the pointer goes, the view is told where it is
/// in its own space (a GeometryReader's, for views inside one) — by node id, so the panel can rebuild meanwhile.
class DragTracker : public QObject {
public:
    static DragTracker &shared() { static DragTracker *tracker = new DragTracker; return *tracker; }
    bool isActive() const { return m_tracking; }
    uint64_t handle() const { return m_handle; }
    void start(uint64_t handle, QString panel, QString id, QPoint originGlobal, QPointF pressGlobal, double minimumDistance) {
        m_handle = handle; m_panel = std::move(panel); m_id = std::move(id);
        m_origin = originGlobal; m_pressGlobal = pressGlobal; m_start = pressGlobal - QPointF(originGlobal);
        m_minimumDistance = qMax(0.0, minimumDistance);
        m_started = m_minimumDistance == 0.0;
        m_tracking = true;
        qApp->installEventFilter(this);
        if (m_started) send(QStringLiteral("dragChanged"), pressGlobal);
    }
protected:
    bool eventFilter(QObject *, QEvent *event) override {
        if (event->type() == QEvent::MouseMove) {
            const QPointF global = static_cast<QMouseEvent *>(event)->globalPosition();
            if (!m_started) {
                const QPointF delta = global - m_pressGlobal;
                if (delta.x() * delta.x() + delta.y() * delta.y() < m_minimumDistance * m_minimumDistance) return false;
                m_started = true;
            }
            send(QStringLiteral("dragChanged"), global);
            return true;
        }
        if (event->type() == QEvent::MouseButtonRelease) {
            qApp->removeEventFilter(this);
            m_tracking = false;
            if (!m_started) return false;
            send(QStringLiteral("dragEnded"), static_cast<QMouseEvent *>(event)->globalPosition());
            return true;
        }
        return false;
    }
private:
    void send(const QString &key, const QPointF &global) {
        const QPointF at = global - QPointF(m_origin);
        dispatch(m_handle, m_panel, m_id, key, "[" + QByteArray::number(at.x()) + "," + QByteArray::number(at.y()) + ","
                 + QByteArray::number(at.x() - m_start.x()) + "," + QByteArray::number(at.y() - m_start.y()) + "]");
    }
    uint64_t m_handle = 0;
    QString m_panel, m_id;
    QPoint m_origin;
    QPointF m_start, m_pressGlobal;
    double m_minimumDistance = 10.0;
    bool m_started = false;
    bool m_tracking = false;
};

class DragPressFilter : public QObject {
public:
    DragPressFilter(QWidget *widget, QWidget *gestureWidget, uint64_t handle, QString panel, QString id)
        : QObject(widget), m_gestureWidget(gestureWidget), m_handle(handle), m_panel(std::move(panel)), m_id(std::move(id)) {
        widget->installEventFilter(this);
    }
    bool eventFilter(QObject *, QEvent *event) override {
        if (event->type() != QEvent::MouseButtonPress || static_cast<QMouseEvent *>(event)->button() != Qt::LeftButton) return false;
        if (!m_gestureWidget) return false;
        const QString name = m_gestureWidget->property("swiftuiGestureCoordinateSpace").toString();
        QWidget *space = m_gestureWidget;
        if (name != QLatin1String("local") && name != QLatin1String("global")) {
            for (QWidget *w = m_gestureWidget; w; w = w->parentWidget()) {
                if (w->property("swiftuiCoordinateSpaces").toStringList().contains(name)) { space = w; break; }
            }
        }
        // Leaving a field permits the panel to refresh. Capture the gesture's
        // coordinates and identity first, since that refresh can replace its widgets.
        const QPoint origin = name == QLatin1String("global") ? QPoint(0, 0) : space->mapToGlobal(QPoint(0, 0));
        const QPointF press = static_cast<QMouseEvent *>(event)->globalPosition();
        const double minimum = m_gestureWidget->property("swiftuiGestureMinimumDistance").toDouble();
        const uint64_t handle = m_handle;
        const QString panel = m_panel, id = m_id;
        auto *field = qobject_cast<QLineEdit *>(QApplication::focusWidget());
        if (field && field->window() == m_gestureWidget->window() && field != m_gestureWidget
            && !m_gestureWidget->isAncestorOf(field)) field->clearFocus();
        DragTracker::shared().start(handle, panel, id, origin, press, minimum);
        return true;
    }
private:
    QPointer<QWidget> m_gestureWidget;
    uint64_t m_handle;
    QString m_panel, m_id;
};

/// SwiftUI's GeometryReader: fills what it is given, tells the view its size (which re-resolves the content for it), and
/// places children with `.position(x:y:)` by their centre (the rest fill it). A press on a child with a DragGesture is
/// tracked here, in this view's space, and the content re-resolved as it moves.
class SwiftUIGeometryWidget : public QWidget {
public:
    SwiftUIGeometryWidget(uint64_t handle, QString panel, QString id, QString key, QSizeF resolvedSize, const QJsonArray &children)
        : m_handle(handle), m_panel(std::move(panel)), m_id(std::move(id)), m_key(std::move(key)), m_resolved(resolvedSize) {
        setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
        setProperty("geometryReader", true);
        build(children);
    }
    QSize sizeHint() const override { return QSize(100, 40); }
    QSize minimumSizeHint() const override { return QSize(10, 10); }
protected:
    void resizeEvent(QResizeEvent *event) override {
        QWidget::resizeEvent(event);
        place();
        const QSizeF now = size();
        if (std::abs(now.width() - m_resolved.width()) < 0.5 && std::abs(now.height() - m_resolved.height()) < 0.5) return;
        m_resolved = now;
        const QPointer<SwiftUIGeometryWidget> self(this);
        QTimer::singleShot(0, this, [self, now] {
            if (!self) return;
            dispatch(self->m_handle, self->m_panel, self->m_id, QStringLiteral("size"),
                     QByteArray("[") + QByteArray::number(now.width()) + "," + QByteArray::number(now.height()) + "]");
            self->refresh();
        });
    }
    /// The content as the view now resolves it (after a size report or a drag step), rebuilt in place.
    void refresh() {
        const QJsonObject root = QJsonDocument::fromJson(fetchTreeBytes(m_handle, m_panel)).object();
        std::function<QJsonObject(const QJsonObject &)> find = [&](const QJsonObject &n) -> QJsonObject {
            if (n.value("stringParams").toObject().value("geometryKey").toString() == m_key) return n;
            for (const auto &c : n.value("children").toArray()) { const QJsonObject f = find(c.toObject()); if (!f.isEmpty()) return f; }
            return {};
        };
        const QJsonObject node = find(root);
        if (node.isEmpty()) return;
        m_id = node.value("id").toString();
        build(node.value("children").toArray());
        update();
    }
    void build(const QJsonArray &children) {
        for (QWidget *child : std::as_const(m_children)) { child->hide(); child->deleteLater(); }
        m_children.clear();
        for (const auto &value : children) {
            const QJsonObject child = value.toObject();
            QWidget *w = buildNode(m_handle, m_panel, child);
            if (!w) continue;
            w->setParent(this);
            for (const auto &m : child.value("modifiers").toArray()) {
                const QJsonObject mo = m.toObject();
                if (mo.value("kind").toString() != QLatin1String("position")) continue;
                w->setProperty("positionX", mo.value("doubleParams").toObject().value("x").toDouble());
                w->setProperty("positionY", mo.value("doubleParams").toObject().value("y").toDouble());
                w->setProperty("positioned", true);
            }
            w->show();
            m_children << w;
        }
        place();
    }
    void place() {
        for (QWidget *w : std::as_const(m_children)) {
            if (!w->property("positioned").toBool()) { w->setGeometry(rect()); continue; }
            const QSize s = (w->minimumSize() == w->maximumSize()) ? w->minimumSize() : w->sizeHint();
            const QPointF c(w->property("positionX").toDouble(), w->property("positionY").toDouble());
            w->setGeometry(QRect(qRound(c.x() - s.width() / 2.0), qRound(c.y() - s.height() / 2.0), s.width(), s.height()));
            w->raise();
        }
    }
    uint64_t m_handle;
    QString m_panel, m_id, m_key;
    QSizeF m_resolved;
    QList<QWidget *> m_children;
};

/// Keeps an overlay laid over its base view at the overlay's alignment (SwiftUI's `.overlay`).
class OverlayPlacer : public QObject {
public:
    OverlayPlacer(QWidget *base, QWidget *overlay, QString alignment) : QObject(base), m_base(base), m_overlay(overlay), m_alignment(std::move(alignment)) {
        base->installEventFilter(this);
        place();
    }
    bool eventFilter(QObject *, QEvent *event) override {
        if (event->type() == QEvent::Resize || event->type() == QEvent::Show || event->type() == QEvent::LayoutRequest) place();
        return false;
    }
    void place() {
        const QSize fixed = m_overlay->minimumSize() == m_overlay->maximumSize() ? m_overlay->minimumSize() : QSize();
        const bool fills = !fixed.isValid() && (m_overlay->sizePolicy().horizontalPolicy() & QSizePolicy::ExpandFlag);
        if (fills || m_alignment == QLatin1String("center") && !fixed.isValid() && !qobject_cast<QLabel *>(m_overlay)) {
            m_overlay->setGeometry(m_base->rect());
        } else {
            const QSize s = fixed.isValid() ? fixed : m_overlay->sizeHint().boundedTo(m_base->size());
            int x = (m_base->width() - s.width()) / 2, y = (m_base->height() - s.height()) / 2;
            if (m_alignment.contains(QLatin1String("eading"))) x = 0;
            if (m_alignment.contains(QLatin1String("railing"))) x = m_base->width() - s.width();
            if (m_alignment.startsWith(QLatin1String("top"))) y = 0;
            if (m_alignment.startsWith(QLatin1String("bottom"))) y = m_base->height() - s.height();
            m_overlay->setGeometry(x, y, s.width(), s.height());
        }
        m_overlay->raise();
    }
private:
    QWidget *m_base, *m_overlay;
    QString m_alignment;
};

class BackgroundPlacer : public QObject {
public:
    BackgroundPlacer(QWidget *container, QWidget *content, QWidget *background, QString alignment)
        : QObject(container), m_container(container), m_content(content), m_background(background), m_alignment(std::move(alignment)) {
        container->installEventFilter(this);
        place();
    }
    bool eventFilter(QObject *, QEvent *event) override {
        if (event->type() == QEvent::Resize || event->type() == QEvent::Show || event->type() == QEvent::LayoutRequest) place();
        return false;
    }
    void place() {
        m_content->setGeometry(m_container->rect());
        // `Text(…).fixedSize().background(GeometryReader { … }).frame(width:)` (FilterSheet's slider titles): SwiftUI sizes
        // a fixed-size view at its ideal size whatever frame it sits in, so the reader measures the whole title, not the
        // frame around it. Give the reader the content's own size so the preference it publishes is the natural width.
        if (m_background->property("geometryReader").toBool()
            && m_content->sizePolicy().horizontalPolicy() == QSizePolicy::Fixed) {
            const QSize natural = m_content->sizeHint();
            m_background->setGeometry(0, 0, natural.width(), qMax(natural.height(), m_container->height()));
            m_background->lower();
            m_content->raise();
            return;
        }
        const QSize fixed = m_background->minimumSize() == m_background->maximumSize() ? m_background->minimumSize() : QSize();
        const bool fills = !fixed.isValid() && (m_background->sizePolicy().horizontalPolicy() & QSizePolicy::ExpandFlag);
        if (fills || m_alignment == QLatin1String("center") && !fixed.isValid() && !qobject_cast<QLabel *>(m_background)) {
            m_background->setGeometry(m_container->rect());
        } else {
            const QSize size = fixed.isValid() ? fixed : m_background->sizeHint().boundedTo(m_container->size());
            int x = (m_container->width() - size.width()) / 2, y = (m_container->height() - size.height()) / 2;
            if (m_alignment.contains(QLatin1String("eading"))) x = 0;
            if (m_alignment.contains(QLatin1String("railing"))) x = m_container->width() - size.width();
            if (m_alignment.startsWith(QLatin1String("top"))) y = 0;
            if (m_alignment.startsWith(QLatin1String("bottom"))) y = m_container->height() - size.height();
            m_background->setGeometry(x, y, size.width(), size.height());
        }
        m_background->lower();
        m_content->raise();
    }
private:
    QWidget *m_container, *m_content, *m_background;
    QString m_alignment;
};

class SwiftUIBackgroundWidget : public QWidget {
public:
    SwiftUIBackgroundWidget(QWidget *content, QWidget *background, QString alignment)
        : m_content(content), m_background(background) {
        m_content->setParent(this);
        m_background->setParent(this);
        setSizePolicy(m_content->sizePolicy());
        setMinimumSize(m_content->minimumSize());
        setMaximumSize(m_content->maximumSize());
        new BackgroundPlacer(this, m_content, m_background, std::move(alignment));
    }
    QSize sizeHint() const override { return m_content->sizeHint(); }
    QSize minimumSizeHint() const override { return m_content->minimumSizeHint(); }
private:
    QWidget *m_content;
    QWidget *m_background;
};

/// LinearGradient: the colors spread evenly from `startPoint` to `endPoint` (unit points).
class SwiftUIGradientWidget : public QWidget {
public:
    SwiftUIGradientWidget(QList<QColor> colors, QString start, QString end)
        : m_colors(std::move(colors)), m_start(std::move(start)), m_end(std::move(end)) {
        setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
    }
protected:
    static QPointF unit(const QString &name) {
        const double x = name.contains(QLatin1String("eading")) ? 0 : name.contains(QLatin1String("railing")) ? 1 : 0.5;
        const double y = name.startsWith(QLatin1String("top")) ? 0 : name.startsWith(QLatin1String("bottom")) ? 1 : 0.5;
        return {x, y};
    }
    void paintEvent(QPaintEvent *) override {
        if (m_colors.isEmpty()) return;
        QPainter p(this);
        const QPointF a = unit(m_start), b = unit(m_end);
        QLinearGradient gradient(QPointF(a.x() * width(), a.y() * height()), QPointF(b.x() * width(), b.y() * height()));
        for (int i = 0; i < m_colors.size(); ++i) gradient.setColorAt(m_colors.size() == 1 ? 0 : double(i) / (m_colors.size() - 1), m_colors[i]);
        p.fillRect(rect(), gradient);
    }
private:
    QList<QColor> m_colors;
    QString m_start, m_end;
};

/// A horizontal-only ScrollView asks for its content's width, as SwiftUI sizes it to its content's ideal width, so a
/// Spacer beside it in a tool header only gets what is left over; it still shrinks and scrolls when space runs out.
/// (QScrollArea's own hint is capped at a few dozen characters, so the Spacer took half the row.)
class SwiftUIScrollArea : public QScrollArea {
public:
    SwiftUIScrollArea() {
        for (QScrollBar *bar : {horizontalScrollBar(), verticalScrollBar()}) {
            QObject::connect(bar, &QScrollBar::rangeChanged, this, [this] { trace("range"); scheduleGeometry(); });
            QObject::connect(bar, &QScrollBar::valueChanged, this, [this] {
                trace("value");
                if (m_applyingOffset) return;
                m_pendingOffset = false;
                reportGeometry();
            });
        }
    }
    void bindAppKit(uint64_t handle, const QString &panel, const QJsonObject &node) {
        m_handle = handle; m_panel = panel; m_nodeID = node.value("id").toString();
        const QJsonObject doubles = node.value("doubleParams").toObject();
        m_pendingOffset = doubles.contains("scrollX") && doubles.contains("scrollY");
        m_desiredOffset = QPoint(qRound(doubles.value("scrollX").toDouble()), qRound(doubles.value("scrollY").toDouble()));
        m_hasBasis = m_pendingOffset;
        m_basis = m_desiredOffset;
        trace("bind");
        setProperty("appKitScroll", true);
        setProperty("appKitScrollNode", panel + QLatin1Char('|') + m_nodeID);
        // A rebuilt panel replaces the scroll area that was showing the native offset. When the content is already
        // tall enough, show that offset from the first paint instead of the top until the deferred pass runs; the
        // deferred pass still reports the settled geometry.
        if (m_pendingOffset && widget() && horizontalScrollBar()->maximum() >= m_desiredOffset.x()
            && verticalScrollBar()->maximum() >= m_desiredOffset.y()) {
            m_applyingOffset = true;
            horizontalScrollBar()->setValue(m_desiredOffset.x());
            verticalScrollBar()->setValue(m_desiredOffset.y());
            m_applyingOffset = false;
            trace("bind-apply");
        }
        scheduleGeometry();
    }
    QSize sizeHint() const override {
        QSize hint = QScrollArea::sizeHint();
        if (horizontalOnly && widget())
            hint.setWidth(widget()->sizeHint().width() + 2 * frameWidth());
        return hint;
    }
    bool horizontalOnly = false;
    void synchronizeTrackingOffset() {
        if (!m_handle || !widget()) return;
        trace("track-before");
        const QJsonObject root = QJsonDocument::fromJson(fetchTreeBytes(m_handle, m_panel)).object();
        std::function<void(const QJsonObject &)> visit = [&](const QJsonObject &node) {
            if (node.value("id").toString() == m_nodeID) {
                const QJsonObject offsets = node.value("doubleParams").toObject();
                if (!offsets.contains("scrollX") || !offsets.contains("scrollY")) return;
                trace("track-model", qRound(offsets.value("scrollY").toDouble()));
                // Keep the native viewport in step without rebuilding the widgets in an AppKit tracking loop.
                m_applyingOffset = true;
                horizontalScrollBar()->setValue(qRound(offsets.value("scrollX").toDouble()));
                verticalScrollBar()->setValue(qRound(offsets.value("scrollY").toDouble()));
                m_applyingOffset = false;
                m_pendingOffset = false;
                m_hasBasis = true;
                m_basis = QPoint(qRound(offsets.value("scrollX").toDouble()), qRound(offsets.value("scrollY").toDouble()));
                reportGeometry();
                return;
            }
            for (const QJsonValue &child : node.value("children").toArray()) visit(child.toObject());
        };
        visit(root);
    }
protected:
    void resizeEvent(QResizeEvent *event) override { QScrollArea::resizeEvent(event); scheduleGeometry(); }
    void showEvent(QShowEvent *event) override { QScrollArea::showEvent(event); scheduleGeometry(); }
private:
    void trace(const char *event, int model = -1) {
        recordScrollTrace(event, this, verticalScrollBar()->value(), verticalScrollBar()->maximum(),
                          m_desiredOffset.y(), model, viewport()->height(), widget() ? widget()->height() : -1,
                          int(m_pendingOffset) | (int(m_applyingOffset) << 1) | (int(isVisible()) << 2) | (int(m_geometryQueued) << 3));
    }
    void scheduleGeometry() {
        if (!m_handle || m_geometryQueued) return;
        m_geometryQueued = true;
        QTimer::singleShot(0, this, [this] {
            m_geometryQueued = false;
            if (!isVisible() || !widget()) { trace("apply-skip"); return; }
            if (m_pendingOffset) {
                trace("apply-before");
                m_applyingOffset = true;
                horizontalScrollBar()->setValue(m_desiredOffset.x());
                verticalScrollBar()->setValue(m_desiredOffset.y());
                m_applyingOffset = false;
                m_pendingOffset = false;
                trace("apply-after");
            }
            reportGeometry();
        });
    }
    void reportGeometry() {
        if (!m_handle || !isVisible() || !widget() || viewport()->width() <= 0 || viewport()->height() <= 0) return;
        QJsonObject geometry{{"width", viewport()->width()}, {"height", viewport()->height()},
            {"documentWidth", widget()->width()}, {"documentHeight", widget()->height()},
            {"x", horizontalScrollBar()->value()}, {"y", verticalScrollBar()->value()}};
        // The native offset this view was given: an unchanged offset reported after the native one moved is stale.
        if (m_hasBasis) { geometry.insert("basisX", m_basis.x()); geometry.insert("basisY", m_basis.y()); }
        const QByteArray payload = QJsonDocument(geometry).toJson(QJsonDocument::Compact);
        if (payload == m_lastGeometry) return;
        trace("report-before");
        const QByteArray panel = m_panel.toUtf8(), node = m_nodeID.toUtf8();
        // Viewport synchronization paints the current widgets; it does not dispatch a document action or rebuild
        // the panel under a scrollbar drag. A pending AppKit reveal can independently invalidate its tree.
        if (compositor_session_dispatch_swiftui_action(m_handle, panel.constData(), node.constData(), "scrollGeometry",
            reinterpret_cast<const uint8_t *>(payload.constData()), payload.size()) != 0) return;
        m_lastGeometry = payload;
        m_hasBasis = true;
        m_basis = QPoint(horizontalScrollBar()->value(), verticalScrollBar()->value());
        trace("report-after");
        widget()->update();
        for (QWidget *child : widget()->findChildren<QWidget *>()) child->update();
    }
    uint64_t m_handle = 0;
    QString m_panel, m_nodeID;
    QPoint m_desiredOffset, m_basis;
    bool m_hasBasis = false;
    QByteArray m_lastGeometry;
    bool m_pendingOffset = false, m_applyingOffset = false, m_geometryQueued = false;
};

static void synchronizeTrackingScroll(QWidget *widget) {
    for (QWidget *parent = widget->parentWidget(); parent; parent = parent->parentWidget()) {
        if (auto *scroll = dynamic_cast<SwiftUIScrollArea *>(parent)) {
            scroll->synchronizeTrackingOffset();
            return;
        }
    }
}

/// `VStack`/`HStack` share everything but the layout's orientation.
QWidget *buildStack(uint64_t handle, const QString &panel, const QJsonObject &node, QBoxLayout::Direction direction) {
    auto *container = new QWidget;
    auto *layout = new QBoxLayout(direction, container);
    layout->setContentsMargins(0, 0, 0, 0);
    const QJsonObject doubles = node.value("doubleParams").toObject();
    // No spacing given: SwiftUI's default between two views, 8 points.
    layout->setSpacing(doubles.contains("spacing") ? static_cast<int>(doubles.value("spacing").toDouble()) : 8);
    QString precedingText;
    QList<std::pair<double, QWidget *>> zOrdered;
    for (const auto &childValue : node.value("children").toArray()) {
        const QJsonObject childObj = childValue.toObject();
        if (QWidget *child = buildNode(handle, panel, childObj)) {
            const QString childKind = childObj.value("kind").toString();
            // An unlabeled slider takes the text just before it in its row as its accessible name (a tool bar's
            // "Opacity" then its slider), as a label sits beside the control it names.
            if (childKind == QLatin1String("Text")) precedingText = childObj.value("stringParams").toObject().value("text").toString();
            else {
                if (auto *slider = qobject_cast<QAbstractSlider *>(child); slider && slider->accessibleName().isEmpty()
                    && !precedingText.isEmpty()) slider->setAccessibleName(precedingText);
                if (childKind != QLatin1String("Spacer")) precedingText.clear();
            }
            int stretch = 0;
            if (childKind == "ScrollView" || childKind == "Spacer" || childKind == "Canvas") {
                stretch = 1;
            }
            // A horizontal ScrollView takes its content's width before a Spacer beside it takes the rest (stretch
            // would split the free space evenly); its Expanding policy still lets it fill a row on its own.
            if (auto *scroll = dynamic_cast<SwiftUIScrollArea *>(child); scroll && scroll->horizontalOnly) stretch = 0;
            const bool horizontal = direction == QBoxLayout::LeftToRight;
            // SwiftUI's Spacer grows along its stack only; growing across it too would make the whole row (a header
            // with a Spacer in it) take a share of its column's height.
            if (childKind == "Spacer")
                child->setSizePolicy(horizontal ? QSizePolicy::Expanding : QSizePolicy::Preferred,
                                     horizontal ? QSizePolicy::Preferred : QSizePolicy::Expanding);
            // A Divider in an HStack is a vertical line.
            if (childKind == "Divider" && horizontal) {
                child->setMinimumHeight(0);
                child->setMaximumHeight(QWIDGETSIZE_MAX);
                child->setFixedWidth(1);
                child->setSizePolicy(QSizePolicy::Fixed, QSizePolicy::Expanding);
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
            const QJsonObject childDoubles = childObj.value("doubleParams").toObject();
            if (childDoubles.contains("zIndex"))
                zOrdered.append({childDoubles.value("zIndex").toDouble(), child});
        }
    }
    std::stable_sort(zOrdered.begin(), zOrdered.end(),
                     [](const auto &a, const auto &b) { return a.first < b.first; });
    for (const auto &entry : zOrdered) {
        if (entry.second) entry.second->raise();
    }
    return container;
}

/// A ForEach's or a conditional's views stand in its place: the grid's rows, a row's cells.
static void flattenViewLists(const QJsonArray &nodes, QList<QJsonObject> &out) {
    for (const QJsonValue &value : nodes) {
        const QJsonObject object = value.toObject();
        if (object.value("kind").toString() == QLatin1String("_ViewList") && object.value("modifiers").toArray().isEmpty())
            flattenViewLists(object.value("children").toArray(), out);
        else
            out << object;
    }
}

/// `Grid`: each GridRow's views in columns as wide as their widest cell, placed at the grid's alignment; a view that is
/// not in a GridRow spans the whole row. No spacing given: SwiftUI's default, 8 points.
QWidget *buildGrid(uint64_t handle, const QString &panel, const QJsonObject &node) {
    auto *container = new QWidget;
    auto *layout = new QGridLayout(container);
    layout->setContentsMargins(0, 0, 0, 0);
    const QJsonObject doubles = node.value("doubleParams").toObject();
    layout->setHorizontalSpacing(doubles.contains("horizontalSpacing") ? int(doubles.value("horizontalSpacing").toDouble()) : 8);
    layout->setVerticalSpacing(doubles.contains("verticalSpacing") ? int(doubles.value("verticalSpacing").toDouble()) : 8);
    const QString alignment = node.value("stringParams").toObject().value("alignment").toString();
    const Qt::Alignment horizontal = alignment.contains(QLatin1String("eading")) ? Qt::AlignLeft
                                   : alignment.contains(QLatin1String("railing")) ? Qt::AlignRight : Qt::AlignHCenter;
    const Qt::Alignment vertical = alignment.startsWith(QLatin1String("top")) ? Qt::AlignTop
                                 : alignment.startsWith(QLatin1String("bottom")) ? Qt::AlignBottom : Qt::AlignVCenter;
    // SwiftUI sizes a grid's columns to their cells; spare width lies beside them (at the grid's alignment), not in
    // them — empty stretch columns take it.
    const int first = horizontal == Qt::AlignLeft ? 0 : 1;
    QList<QJsonObject> rows;
    flattenViewLists(node.value("children").toArray(), rows);
    int columns = 1;
    for (const QJsonObject &row : rows) {
        if (row.value("kind").toString() != QLatin1String("GridRow")) continue;
        QList<QJsonObject> cells;
        flattenViewLists(row.value("children").toArray(), cells);
        columns = std::max(columns, int(cells.size()));
    }
    int r = 0;
    for (const QJsonObject &row : rows) {
        if (row.value("kind").toString() != QLatin1String("GridRow")) {
            if (QWidget *child = buildNode(handle, panel, row)) layout->addWidget(child, r++, first, 1, columns, vertical | horizontal);
            continue;
        }
        const QString rowAlignment = row.value("stringParams").toObject().value("alignment").toString();
        const Qt::Alignment rowVertical = rowAlignment == QLatin1String("top") ? Qt::AlignTop
                                        : rowAlignment == QLatin1String("bottom") ? Qt::AlignBottom : vertical;
        QList<QJsonObject> cells;
        flattenViewLists(row.value("children").toArray(), cells);
        int c = 0;
        for (const QJsonObject &cell : cells) {
            QWidget *child = buildNode(handle, panel, cell);
            if (!child) { ++c; continue; }
            const bool flexible = child->sizePolicy().horizontalPolicy() & QSizePolicy::ExpandFlag;
            layout->addWidget(child, r, first + c++, 1, 1, flexible ? rowVertical : (rowVertical | horizontal));
        }
        ++r;
    }
    if (first == 1) layout->setColumnStretch(0, 1);
    if (horizontal != Qt::AlignRight) layout->setColumnStretch(first + columns, 1);
    return container;
}

static QString formatTextFieldNumber(const QJsonObject &parameters, double value) {
    if (!parameters.contains("maximumFractionLength")) return QString::number(value);
    const int minimum = qBound(0, parameters.value("minimumFractionLength").toInt(), 15);
    const int maximum = qBound(minimum, parameters.value("maximumFractionLength").toInt(), 15);
    QString text = QString::number(value, 'f', maximum);
    while (text.contains('.') && text.endsWith('0') && text.length() - text.indexOf('.') - 1 > minimum) text.chop(1);
    if (text.endsWith('.')) text.chop(1);
    return text;
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
    } else if (kind == "Grid") {
        widget = buildGrid(handle, panel, node);
    } else if (kind == "Popover") {
        QWidget *base = children.size() > 0 ? buildNode(handle, panel, children[0].toObject()) : nullptr;
        if (!base) base = new QWidget;
        if (bools.value("isPresented").toBool() && children.size() > 1) {
            QWidget *content = buildNode(handle, panel, children[1].toObject());
            if (content) {
                auto *popover = new QFrame(base, Qt::Popup | Qt::FramelessWindowHint);
                popover->setObjectName(QStringLiteral("swiftuiPopover"));
                popover->setAttribute(Qt::WA_StyledBackground, true);
                popover->setStyleSheet(QStringLiteral(
                    "QFrame#swiftuiPopover { background: #29292d; color: #f5f5f7; border: 1px solid #45454b; border-radius: 7px; }"));
                auto *layout = new QVBoxLayout(popover);
                layout->setContentsMargins(0, 0, 0, 0);
                layout->addWidget(content);
                new PopoverDismissFilter(popover, handle, panel, id);
                QPointer<QWidget> anchor = base;
                QPointer<QFrame> popup = popover;
                QTimer::singleShot(0, popover, [anchor, popup] {
                    if (!anchor || !popup) return;
                    popup->adjustSize();
                    popup->move(anchor->mapToGlobal(QPoint(anchor->width() / 2, anchor->height())));
                    popup->show();
                });
            }
        }
        widget = base;
    } else if (kind == "Sheet") {
        QWidget *base = children.size() > 0 ? buildNode(handle, panel, children[0].toObject()) : nullptr;
        if (!base) base = new QWidget;
        if (bools.value("isPresented").toBool() && children.size() > 1) {
            QWidget *content = buildNode(handle, panel, children[1].toObject());
            if (content) {
                auto *sheet = new QDialog(base);
                sheet->setAttribute(Qt::WA_DeleteOnClose, true);
                sheet->setWindowModality(Qt::WindowModal);
                auto *layout = new QVBoxLayout(sheet);
                layout->setContentsMargins(16, 16, 16, 16);
                layout->addWidget(content);
                QObject::connect(sheet, &QDialog::finished, sheet, [handle, panel, id](int) {
                    dispatch(handle, panel, id, QStringLiteral("dismiss"));
                });
                QTimer::singleShot(0, sheet, [sheet] {
                    sheet->adjustSize();
                    sheet->open();
                });
            }
        }
        widget = base;
    } else if (kind == "Alert") {
        QWidget *base = children.size() > 0 ? buildNode(handle, panel, children[0].toObject()) : nullptr;
        if (!base) base = new QWidget;
        if (bools.value("isPresented").toBool()) {
            auto *alert = new QMessageBox(base);
            alert->setAttribute(Qt::WA_DeleteOnClose, true);
            alert->setIcon(QMessageBox::Warning);
            alert->setText(strings.value("title").toString());
            alert->setInformativeText(strings.value("message").toString());
            const QJsonArray actions = QJsonDocument::fromJson(strings.value("actions").toString().toUtf8()).array();
            for (const QJsonValue &value : actions) {
                const QJsonObject action = value.toObject();
                const int index = action.value("index").toInt(-1);
                const QString role = action.value("role").toString();
                const QMessageBox::ButtonRole buttonRole = role == QLatin1String("cancel") ? QMessageBox::RejectRole
                    : role == QLatin1String("destructive") ? QMessageBox::DestructiveRole : QMessageBox::AcceptRole;
                auto *button = alert->addButton(action.value("title").toString(), buttonRole);
                if (role == QLatin1String("cancel")) alert->setEscapeButton(button);
                const QString handler = QStringLiteral("alertAction%1").arg(index);
                QObject::connect(button, &QAbstractButton::clicked, alert, [handle, panel, id, handler] {
                    dispatch(handle, panel, id, handler);
                });
            }
            if (actions.isEmpty()) alert->addButton(QStringLiteral("OK"), QMessageBox::AcceptRole);
            alert->setWindowModality(Qt::WindowModal);
            QObject::connect(alert, &QDialog::finished, alert, [handle, panel, id](int) {
                dispatch(handle, panel, id, QStringLiteral("dismiss"));
            });
            QTimer::singleShot(0, alert, [alert] { alert->open(); });
        }
        widget = base;
    } else if (kind == "Overlay") {
        QWidget *base = children.size() > 0 ? buildNode(handle, panel, children[0].toObject()) : nullptr;
        QWidget *over = children.size() > 1 ? buildNode(handle, panel, children[1].toObject()) : nullptr;
        if (!base) base = new QWidget;
        if (over) {
            over->setParent(base);
            bool interactive = false;
            std::function<void(const QJsonObject &)> scan = [&](const QJsonObject &n) {
                if (!n.value("handlerKeys").toArray().isEmpty()) interactive = true;
                for (const auto &c : n.value("children").toArray()) scan(c.toObject());
            };
            scan(children[1].toObject());
            if (!interactive) over->setAttribute(Qt::WA_TransparentForMouseEvents, true);
            new OverlayPlacer(base, over, strings.value("alignment").toString());
            over->show();
        }
        widget = base;
    } else if (kind == "Background") {
        QWidget *base = children.size() > 0 ? buildNode(handle, panel, children[0].toObject()) : nullptr;
        QWidget *background = children.size() > 1 ? buildNode(handle, panel, children[1].toObject()) : nullptr;
        if (!base) base = new QWidget;
        if (background) {
            bool interactive = false;
            std::function<void(const QJsonObject &)> scan = [&](const QJsonObject &current) {
                if (!current.value("handlerKeys").toArray().isEmpty()) interactive = true;
                for (const auto &child : current.value("children").toArray()) scan(child.toObject());
            };
            if (children.size() > 1) scan(children[1].toObject());
            if (!interactive) background->setAttribute(Qt::WA_TransparentForMouseEvents, true);
        }
        widget = background ? static_cast<QWidget *>(new SwiftUIBackgroundWidget(base, background, strings.value("alignment").toString())) : base;
    } else if (kind == "Mask") {
        QWidget *base = children.size() > 0 ? buildNode(handle, panel, children[0].toObject()) : nullptr;
        QWidget *mask = children.size() > 1 ? buildNode(handle, panel, children[1].toObject()) : nullptr;
        if (!base) base = new QWidget;
        if (mask) {
            std::function<void(QWidget *)> prepareShapes = [&](QWidget *current) {
                if (auto *shape = dynamic_cast<SwiftUIShapeWidget *>(current)) shape->prepareAsMask();
                for (QWidget *child : current->findChildren<QWidget *>(QString(), Qt::FindDirectChildrenOnly)) prepareShapes(child);
            };
            prepareShapes(mask);
            // Qt permits one effect per widget, so a mask carries any opacity applied before it.
            const auto *opacity = qobject_cast<QGraphicsOpacityEffect *>(base->graphicsEffect());
            base->setGraphicsEffect(new SwiftUIMaskEffect(base, mask, opacity ? opacity->opacity() : 1.0));
        }
        widget = base;
    } else if (kind == "LinearGradient") {
        QList<QColor> colors;
        for (const QString &name : strings.value("colors").toString().split(QLatin1Char('|'), Qt::SkipEmptyParts)) colors << parseColorToken(name);
        widget = new SwiftUIGradientWidget(colors, strings.value("startPoint").toString(), strings.value("endPoint").toString());
    } else if (kind == "GeometryReader") {
        const QJsonObject d = node.value("doubleParams").toObject();
        widget = new SwiftUIGeometryWidget(handle, panel, id, strings.value("geometryKey").toString(),
                                           QSizeF(d.value("width").toDouble(), d.value("height").toDouble()), children);
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
            delete container;
            // Later children lie over earlier ones; each fills the stack unless it has a size of its own (then it
            // sits at the stack's alignment) or a `.position` (its centre there).
            auto *stack = new SwiftUIZStackWidget(strings.value("alignment").toString());
            for (int i = 0; i < builtChildren.size(); ++i) stack->add(builtChildren[i], children[i].toObject());
            container = stack;
        }
        widget = container;
    } else if (kind == "Text") {
        // No color of its own: it takes its container's foregroundStyle (SwiftUI's environment), else the primary label color.
        auto *label = new QLabel(strings.value("text").toString());
        widget = label;
    } else if (kind == "Button") {
        auto *button = new SwiftUIButton;
        button->setProperty("swiftUINode", id);
        QString systemIcon;
        bool isToolButton = false;
        QString textLabel;
        // A swatch button's label is a filled shape (upstream ColorPaletteControls / BrushControls): its fill is the
        // color the swatch shows.
        QString labelFill;
        // The label's own fixed frame (`.frame(width:height:)` on the icon), which sizes a small icon button
        // (the palette's 12x12 swap/reset arrows) instead of the rail's standard 36x36.
        QSize labelFrame;

        // A label framed `maxWidth: .infinity` makes the button as wide as it is offered (the color picker's OK).
        bool labelFillsWidth = false;
        std::function<void(const QJsonObject &)> extractLabel = [&](const QJsonObject &n) {
            const QString childKind = n.value("kind").toString();
            for (const auto &m : n.value("modifiers").toArray())
                if (m.toObject().value("kind").toString() == QLatin1String("frame")
                    && m.toObject().value("boolParams").toObject().value("maxWidthInfinity").toBool())
                    labelFillsWidth = true;
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
                    // A second symbol in the label is a badge over the first (a ZStack: eyedropper + plus.circle.fill).
                    systemIcon = systemIcon.isEmpty() ? source.mid(7) : systemIcon + QLatin1String("|badge=") + source.mid(7);
                    button->setProperty("systemIcon", systemIcon);
                    isToolButton = true;
                }
                for (const auto &m : n.value("modifiers").toArray())
                    if (m.toObject().value("kind").toString() == QLatin1String("rotationEffect"))
                        button->setProperty("iconRotation", m.toObject().value("doubleParams").toObject().value("radians").toDouble() * 180.0 / M_PI);
            } else if (childKind == "Canvas") {
                isToolButton = true;
            } else {
                for (const auto &c : n.value("children").toArray()) extractLabel(c.toObject());
            }
        };
        for (const auto &child : children) extractLabel(child.toObject());
        // `Label(title, systemImage:)` in a default-styled button: AppKit's bordered push button with the symbol
        // before the title (Levels' Sample eyedroppers). Other icon + title stacks are plain headers (Camera Raw's).
        const bool isLabel = !children.isEmpty() && children.first().toObject().value("kind").toString() == QLatin1String("Label");
        // `.tint(...)`: the color a bordered button's title and symbol take (compat carries it as foregroundStyle).
        QColor tint = parseColorToken(QStringLiteral("primary"));
        for (const auto &m : node.value("modifiers").toArray()) {
            const QJsonObject mo = m.toObject();
            if (mo.value("kind").toString() == QLatin1String("foregroundStyle")) {
                const QString name = mo.value("stringParams").toObject().value("name").toString();
                tint = name == QLatin1String("accentColor") ? QColor(0x0a, 0x84, 0xff) : parseColorToken(name);
            }
        }

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
        } else if (isLabel && !systemIcon.isEmpty() && !textLabel.isEmpty() && panel != QLatin1String("ToolRail")) {
            button->setIcon(renderToolVectorIcon(systemIcon, 13, tint));
            button->setIconSize(QSize(13, 13));
            button->setText(textLabel);
            button->setStyleSheet(QStringLiteral(
                "QPushButton { background-color: #2a2a2d; color: %1; border: 1px solid #38383c; border-radius: 4px; padding: 4px 10px; } "
                "QPushButton:hover { background-color: #35353a; border-color: #55555c; } "
                "QPushButton:pressed { background-color: #1f1f22; }").arg(tint.name(QColor::HexArgb)));
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

        // A label symbol turned by .rotationEffect (the palette's swap arrow).
        if (const double degrees = button->property("iconRotation").toDouble(); degrees != 0)
            button->setIcon(rotatedIcon(button->icon(), button->iconSize(), degrees));
        // The Return-key button is the window's default button, which AppKit draws in the accent color.
        for (const auto &m : node.value("modifiers").toArray()) {
            const QJsonObject mo = m.toObject();
            if (mo.value("kind").toString() != QLatin1String("keyboardShortcut")) continue;
            if (mo.value("stringParams").toObject().value("key").toString() == QLatin1String("\r")
                && mo.value("doubleParams").toObject().value("modifiers").toDouble() == 0 && !textLabel.isEmpty()) {
                button->setDefault(true);
                button->setStyleSheet(QStringLiteral(
                    "QPushButton { background-color: #0a84ff; color: #ffffff; border: none; border-radius: 5px; padding: 3px 12px; } "
                    "QPushButton:hover { background-color: #2a93ff; } QPushButton:pressed { background-color: #0a6fd6; } "
                    "QPushButton:disabled { background-color: rgba(255, 255, 255, 0.08); color: rgba(255, 255, 255, 0.25); }"));
                button->setProperty("buttonStyled", true);
            }
        }
        if (labelFillsWidth) button->setSizePolicy(QSizePolicy::Expanding, button->sizePolicy().verticalPolicy());
        QObject::connect(button, &QPushButton::clicked, button, [handle, panel, id, button] {
            const QByteArray payload = QJsonDocument(QJsonObject{{"modifiers", button->takeActivationModifiers()}})
                                           .toJson(QJsonDocument::Compact);
            dispatch(handle, panel, id, QStringLiteral("action"), payload);
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
        const QStringList handlerKeys = [&] {
            QStringList keys;
            for (const auto &k : node.value("handlerKeys").toArray()) keys << k.toString();
            return keys;
        }();
        auto *field = new SwiftUITextField(handlerKeys.contains(QStringLiteral("onSubmit")));
        if (handlerKeys.contains(QStringLiteral("fieldCommand"))) {
            class FieldCommandFilter : public QObject {
            public:
                std::function<bool(QKeyEvent *)> command;
                explicit FieldCommandFilter(QObject *owner) : QObject(owner) { owner->installEventFilter(this); }
                bool eventFilter(QObject *, QEvent *event) override {
                    return event->type() == QEvent::KeyPress && command && command(static_cast<QKeyEvent *>(event));
                }
            };
            auto *filter = new FieldCommandFilter(field);
            filter->command = [handle, panel, id](QKeyEvent *event) {
                const QString command = event->key() == Qt::Key_Down ? QStringLiteral("moveDown:")
                    : event->key() == Qt::Key_Up ? QStringLiteral("moveUp:")
                    : event->key() == Qt::Key_Escape ? QStringLiteral("cancelOperation:") : QString();
                if (command.isEmpty()) return false;
                const auto p = panel.toUtf8(), n = id.toUtf8(), payload = jsonFragment(command);
                const int result = compositor_session_dispatch_swiftui_drop_event(handle, p.constData(), n.constData(),
                    "fieldCommand", reinterpret_cast<const uint8_t *>(payload.constData()), size_t(payload.size()));
                if (result > 0) QTimer::singleShot(0, [handle, panel] { notifyListeners(handle, panel); });
                return result > 0;
            };
        }
        field->setPlaceholderText(strings.value("placeholder").toString());
        // TextField's title is its label for assistive technology, shown or not.
        field->setAccessibleName(strings.value("placeholder").toString());
        QObject::connect(field, &QLineEdit::editingFinished, field, [handle, panel] {
            QTimer::singleShot(0, [handle, panel] { notifyListeners(handle, panel); });
        });
        // Typed since the field took focus: a refresh then leaves its text alone. Untyped, a focused field still takes
        // a new value set from elsewhere (New Canvas's preset menu writes the focused Width field), as SwiftUI's does.
        QObject::connect(field, &QLineEdit::textEdited, field, [field] { field->setProperty("swiftuiTyped", true); });
        QObject::connect(field, &QLineEdit::editingFinished, field, [field] { field->setProperty("swiftuiTyped", false); });
        field->setStyleSheet("QLineEdit { background-color: #28282b; color: #ffffff; border: 1px solid #444448; border-radius: 4px; padding: 2px 4px; } QLineEdit:focus { border-color: #007aff; }");
        if (handlerKeys.contains(QStringLiteral("focused"))) new TextFieldFocusFilter(field, handle, panel, id);
        // SwiftUI can focus a newly presented field (inline rename), not only observe Qt's focus changes.
        if (bools.value("focused").toBool()) {
            QTimer::singleShot(0, field, [field] {
                if (!field->isVisible() || !field->isEnabled() || field->hasFocus()) return;
                field->setFocus(Qt::OtherFocusReason);
                field->selectAll();
            });
        }
        auto finishEditing = [field, handle, panel, id](const QString &key) {
            dispatch(handle, panel, id, key, {}, true);
            // Return can keep editing (Hex), release focus (Zoom), or remove the field (Rename). Respect the
            // resolved view before notifying the shell; otherwise its typing guard retains a finished editor.
            QJsonObject nextField;
            std::function<void(const QJsonObject &)> findField = [&](const QJsonObject &node) {
                if (node.value("id").toString() == id) { nextField = node; return; }
                for (const auto &child : node.value("children").toArray()) findField(child.toObject());
            };
            findField(fetchTree(handle, panel));
            if (panel == "ColorPickerSheet" && nextField.value("kind").toString() == QLatin1String("TextField")
                && nextField.value("stringParams").toObject().contains("text")) {
                const QSignalBlocker block(field);
                field->setText(nextField.value("stringParams").toObject().value("text").toString());
            }
            const QJsonObject focus = nextField.value("boolParams").toObject();
            if (nextField.value("kind").toString() != QLatin1String("TextField") ||
                (focus.contains("focused") && !focus.value("focused").toBool())) field->clearFocus();
        };
        if (handlerKeys.contains(QStringLiteral("onSubmit"))) {
            QObject::connect(field, &QLineEdit::returnPressed, field, [finishEditing] {
                finishEditing(QStringLiteral("onSubmit"));
            });
        }
        if (handlerKeys.contains(QStringLiteral("onExitCommand")))
            field->onExitCommand = [finishEditing] { finishEditing(QStringLiteral("onExitCommand")); };
        if (handlerKeys.contains(QStringLiteral("value"))) {
            const QJsonObject doubles = node.value("doubleParams").toObject();
            auto formatNumber = [doubles](double value) { return formatTextFieldNumber(doubles, value); };
            field->setProperty("swiftuiNumericField", true);
            field->setText(formatNumber(doubles.value("value").toDouble()));
            QObject::connect(field, &QLineEdit::editingFinished, field, [field, handle, panel, id, formatNumber] {
                if (panel != "ColorPickerSheet" || field->property("swiftuiPreservingFocus").toBool()) return;
                std::function<void(const QJsonObject &)> normalize = [&](const QJsonObject &node) {
                    if (node.value("id").toString() == id && node.value("kind").toString() == "TextField") {
                        const QSignalBlocker block(field);
                        field->setText(formatNumber(node.value("doubleParams").toObject().value("value").toDouble()));
                    }
                    for (const auto &child : node.value("children").toArray()) normalize(child.toObject());
                };
                normalize(fetchTree(handle, panel));
            });
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
        slider->setProperty("swiftUINode", id);
        // A colored track (upstream's GradientSliderCell): the gradient across the whole 4 pt bar, no filled part.
        QString groove = QStringLiteral("background: #38383c;");
        if (const QStringList stops = strings.value("trackGradient").toString().split(QLatin1Char(';'), Qt::SkipEmptyParts); stops.size() >= 2) {
            QStringList parts;
            for (int i = 0; i < stops.size(); ++i) {
                const QStringList c = stops[i].split(QLatin1Char(','));
                if (c.size() != 4) continue;
                parts << QStringLiteral("stop:%1 rgba(%2, %3, %4, %5)").arg(double(i) / (stops.size() - 1))
                             .arg(qRound(c[0].toDouble() * 255)).arg(qRound(c[1].toDouble() * 255)).arg(qRound(c[2].toDouble() * 255))
                             .arg(qRound(c[3].toDouble() * 255));
            }
            groove = QStringLiteral("background: qlineargradient(x1:0, y1:0, x2:1, y2:0, %1);").arg(parts.join(QStringLiteral(", ")));
        }
        slider->setStyleSheet(QStringLiteral("QSlider::groove:horizontal { height: 4px; %1 border-radius: 2px; } "
            "QSlider::handle:horizontal { background: #ffffff; border: 1px solid #b0b0b5; width: 12px; height: 12px; margin: -4px 0; border-radius: 6px; }").arg(groove)
            + (strings.contains("trackGradient") ? QStringLiteral(" QSlider::sub-page:horizontal { background: transparent; }") : QString()));
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
        bool isSegmented = false, isRadioGroup = false;
        for (const auto &m : node.value("modifiers").toArray()) {
            const QJsonObject mo = m.toObject();
            if (mo.value("kind").toString() != "pickerStyle") continue;
            const QString style = mo.value("stringParams").toObject().value("name").toString();
            isSegmented = style == "segmented";
            isRadioGroup = style == "radioGroup";
        }
        const QString selection = strings.value("selection").toString();

        struct ItemData {
            QString text;
            QString tag;
            QString family;   // An item shown in its own face (a font menu's Font.custom), else empty.
        };
        QVector<ItemData> items;
        for (int i = 1; i < children.size(); ++i) {
            const QJsonObject item = children[i].toObject();
            // A Divider between items is the menu's separator line.
            if (item.value("kind").toString() == QLatin1String("Divider")) { items.push_back({QString(), QStringLiteral("\u0001separator")}); continue; }
            QString itemText = item.value("stringParams").toObject().value("text").toString();
            QString itemTag = itemText, itemFamily;
            for (const auto &mv : item.value("modifiers").toArray()) {
                const QJsonObject mo = mv.toObject();
                if (mo.value("kind").toString() == "tag") {
                    itemTag = mo.value("stringParams").toObject().value("text").toString();
                } else if (mo.value("kind").toString() == "font") {
                    for (const QString &part : mo.value("stringParams").toObject().value("name").toString().split(QLatin1Char('+')))
                        if (part.startsWith(QLatin1String("family:"))) itemFamily = part.mid(7);
                }
            }
            items.push_back({itemText, itemTag, itemFamily});
        }

        if (isRadioGroup) {
            // NSMatrix of radio buttons: one per option, stacked, 6 apart; the chosen one a blue disc with a white dot.
            auto *group = new QWidget;
            auto *layout = new QVBoxLayout(group);
            layout->setContentsMargins(0, 0, 0, 0);
            layout->setSpacing(6);
            const QString dot = styleSheetImage(QStringLiteral("radio-dot"),
                "<svg xmlns='http://www.w3.org/2000/svg' width='14' height='14' viewBox='0 0 14 14'><circle cx='7' cy='7' r='2.6' fill='white'/></svg>");
            for (const auto &it : items) {
                if (it.tag == QStringLiteral("\u0001separator")) continue;
                auto *radio = new QRadioButton(it.text, group);
                radio->setChecked(it.tag.compare(selection, Qt::CaseInsensitive) == 0 || it.text.compare(selection, Qt::CaseInsensitive) == 0);
                radio->setStyleSheet(
                    "QRadioButton { color: #f5f5f7; spacing: 6px; } "
                    "QRadioButton::indicator { width: 14px; height: 14px; border: 1px solid #4a4a50; border-radius: 7px; background-color: #28282b; } "
                    "QRadioButton::indicator:checked { background-color: #007aff; border-color: #007aff; image: url(" + dot + "); } "
                    "QRadioButton:disabled { color: rgba(255, 255, 255, 0.25); }");
                const QString tagToSend = it.tag;
                QObject::connect(radio, &QRadioButton::clicked, radio, [handle, panel, id, tagToSend] {
                    dispatch(handle, panel, id, QStringLiteral("selection"), jsonFragment(tagToSend));
                });
                layout->addWidget(radio);
            }
            widget = group;
        } else if (isSegmented) {
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
            class HostedPopUpButton : public QComboBox {
            public:
                std::function<void()> present;
                void showPopup() override { if (present) present(); else QComboBox::showPopup(); }
            };
            auto *combo = new HostedPopUpButton;
            if (bools.value("customPopup").toBool()) {
                combo->present = [handle, panel, id, combo] {
                    const QRect anchor(combo->mapToGlobal(QPoint(0, 0)), combo->size());
                    const QRect screen = combo->screen()->availableGeometry();
                    const QJsonObject geometry{{"anchor", QJsonArray{anchor.x(), -anchor.y() - anchor.height(), anchor.width(), anchor.height()}},
                        {"screen", QJsonArray{screen.x(), -screen.y() - screen.height(), screen.width(), screen.height()}}};
                    dispatch(handle, panel, id, QStringLiteral("popupOpen"), QJsonDocument(geometry).toJson(QJsonDocument::Compact));
                };
            }
            // macOS pop-up button: the up/down chevron at the right edge says it opens a menu.
            combo->setStyleSheet("QComboBox { background-color: #28282b; color: #ffffff; border: 1px solid #444448; border-radius: 4px; padding: 3px 4px 3px 8px; min-height: 18px; } "
                                 "QComboBox::drop-down { border: none; width: 18px; subcontrol-origin: padding; subcontrol-position: center right; } "
                                 "QComboBox::down-arrow { width: 8px; height: 11px; image: url(" + styleSheetImage(QStringLiteral("popup-chevrons"),
                                     "<svg xmlns='http://www.w3.org/2000/svg' width='8' height='11' viewBox='0 0 8 11'><path fill='none' stroke='#d8d8dc' stroke-width='1.5' stroke-linecap='round' stroke-linejoin='round' d='M1.5 4 L4 1.5 L6.5 4 M1.5 7 L4 9.5 L6.5 7'/></svg>") + "); } "
                                 "QComboBox QAbstractItemView { background-color: #242427; color: #ffffff; selection-background-color: #007aff; }");
            QStringList tags;
            int selIdx = -1;
            for (int i = 0; i < items.size(); ++i) {
                if (items[i].tag == QStringLiteral("\u0001separator")) { combo->insertSeparator(combo->count()); tags << QString(); continue; }
                combo->addItem(items[i].text);
                if (!items[i].family.isEmpty()) {
                    QFont face = combo->font();
                    face = fontFor(items[i].family.toUtf8().constData(), face.pixelSize() > 0 ? face.pixelSize() : face.pointSizeF());
                    combo->setItemData(combo->count() - 1, face, Qt::FontRole);
                }
                tags << items[i].tag;
                if (items[i].tag.compare(selection, Qt::CaseInsensitive) == 0 ||
                    items[i].text.compare(selection, Qt::CaseInsensitive) == 0) {
                    selIdx = i;
                }
            }
            if (selIdx >= 0) combo->setCurrentIndex(selIdx);
            // compatPickerHighlight: the highlighted item previews while the menu is open; closing ends it (after the
            // choice, if any, has been applied).
            bool highlights = false;
            for (const auto &k : node.value("handlerKeys").toArray()) highlights = highlights || k.toString() == QLatin1String("pickerHighlight");
            if (highlights) {
                QObject::connect(combo, QOverload<int>::of(&QComboBox::highlighted), combo, [handle, panel, id, tags](int idx) {
                    if (idx >= 0 && idx < tags.size() && !tags[idx].isEmpty())
                        dispatch(handle, panel, id, QStringLiteral("pickerHighlight"), jsonFragment(tags[idx]));
                });
                class PopupClose : public QObject {
                public:
                    PopupClose(QComboBox *combo, std::function<void()> closed) : QObject(combo), m_closed(std::move(closed)) {
                        combo->view()->window()->installEventFilter(this);
                    }
                    bool eventFilter(QObject *, QEvent *event) override {
                        if (event->type() == QEvent::Hide) QTimer::singleShot(0, this, m_closed);
                        return false;
                    }
                private:
                    std::function<void()> m_closed;
                };
                new PopupClose(combo, [handle, panel, id] {
 dispatch(handle, panel, id, QStringLiteral("pickerHighlight"), "null"); });
            }
            QObject::connect(combo, QOverload<int>::of(&QComboBox::currentIndexChanged), combo, [handle, panel, id, tags](int idx) {
                if (idx >= 0 && idx < tags.size() && !tags[idx].isEmpty()) {
                    dispatch(handle, panel, id, QStringLiteral("selection"), jsonFragment(tags[idx]));
                }
            });
            widget = combo;
        }
        if (!children.isEmpty()) {
            const QJsonObject labelNode = children.first().toObject();
            if (bools.value("labelsHidden").toBool()) {
                const QString labelText = labelNode.value("stringParams").toObject().value("text").toString();
                if (!labelText.isEmpty()) widget->setAccessibleName(labelText);
            } else {
                QWidget *label = buildNode(handle, panel, labelNode);
                if (label) {
                    auto *container = new QWidget;
                    auto *layout = new QHBoxLayout(container);
                    layout->setContentsMargins(0, 0, 0, 0);
                    layout->setSpacing(8);
                    layout->addWidget(label);
                    layout->addWidget(widget);
                    widget = container;
                }
            }
        }
    } else if (kind == "Menu") {
        auto *btn = new QPushButton;
        QString textLabel;
        QString systemIcon;
        QWidget *drawnLabel = nullptr;
        if (!children.isEmpty()) {
            const QJsonObject labelObj = children.first().toObject();
            const QString lkind = labelObj.value("kind").toString();
            if (lkind == "Text") {
                textLabel = labelObj.value("stringParams").toObject().value("text").toString();
            } else if (lkind == "Image" && labelObj.value("stringParams").toObject().value("source").toString().startsWith(QLatin1String("system:"))) {
                systemIcon = labelObj.value("stringParams").toObject().value("source").toString().mid(7);
            } else if (!lkind.isEmpty() && lkind != QLatin1String("_Empty")) {
                // Any other label (New Canvas's three drawn dots, a Label, a stack) is drawn as the view it is, inside
                // the button; the button takes its size and opens the menu.
                drawnLabel = buildNode(handle, panel, labelObj);
            }
        }
        if (!systemIcon.isEmpty()) {
            QIcon icon = renderToolVectorIcon(systemIcon, 16, QColor(0x8e, 0x8e, 0x93));
            btn->setIcon(icon);
            btn->setIconSize(QSize(16, 16));
        } else if (drawnLabel) {
            auto *labelLayout = new QHBoxLayout(btn);
            labelLayout->setContentsMargins(0, 0, 0, 0);
            labelLayout->addWidget(drawnLabel);
            drawnLabel->setAttribute(Qt::WA_TransparentForMouseEvents, true);
            for (QWidget *inner : drawnLabel->findChildren<QWidget *>()) inner->setAttribute(Qt::WA_TransparentForMouseEvents, true);
            const QSize size = drawnLabel->sizeHint().expandedTo(drawnLabel->minimumSize()).expandedTo(QSize(16, 16));
            btn->setMinimumSize(size);
            btn->setProperty("drawnLabel", true);
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
                    act->setData(itemId);
                    QObject::connect(act, &QAction::triggered, btn, [handle, panel, itemId] {
                        dispatch(handle, panel, itemId, QStringLiteral("action"));
                    });
                    // Font menus (and similar) use onHover/onContinuousHover for live preview while the pointer
                    // walks the list — QAction has no hover widget, so QMenu::hovered drives it.
                    const QJsonArray handlerKeys = item.value("handlerKeys").toArray();
                    bool wantsHover = false;
                    for (const auto &k : handlerKeys) {
                        if (k.toString() == QLatin1String("onContinuousHover")) { wantsHover = true; break; }
                    }
                    if (wantsHover) {
                        // Remember the last hovered item so aboutToHide can end its preview.
                        if (!menu->property("compatHoverWired").toBool()) {
                            menu->setProperty("compatHoverWired", true);
                            QObject::connect(menu, &QMenu::aboutToHide, btn, [handle, panel, menu] {
                                const QString id = menu->property("compatHoverID").toString();
                                if (id.isEmpty()) return;
                                menu->setProperty("compatHoverID", QString());
                                dispatch(handle, panel, id, QStringLiteral("onContinuousHover"), QByteArrayLiteral("\"ended\""));
                            });
                        }
                        QObject::connect(menu, &QMenu::hovered, btn, [handle, panel, act, menu](QAction *hovered) {
                            if (hovered != act) return;
                            const QString id = act->data().toString();
                            if (id.isEmpty()) return;
                            const QString previous = menu->property("compatHoverID").toString();
                            if (previous == id) return;
                            if (!previous.isEmpty())
                                dispatch(handle, panel, previous, QStringLiteral("onContinuousHover"), QByteArrayLiteral("\"ended\""));
                            menu->setProperty("compatHoverID", id);
                            // Same payload shape as HoverFilter: [x,y] → .active, else .ended.
                            dispatch(handle, panel, id, QStringLiteral("onContinuousHover"), QByteArrayLiteral("[0,0]"));
                        });
                    }
                } else if (ikind == "Picker") {
                    auto *group = new QActionGroup(menu);
                    group->setExclusive(true);
                    const QString itemId = item.value("id").toString();
                    const QString selected = item.value("stringParams").toObject().value("selection").toString();
                    const QJsonArray choices = item.value("children").toArray();
                    for (int index = 1; index < choices.size(); ++index) {
                        const QJsonObject choice = choices.at(index).toObject();
                        if (choice.value("kind").toString() == "Divider") { menu->addSeparator(); continue; }
                        const QString title = choice.value("stringParams").toObject().value("text").toString();
                        QString tag = title;
                        for (const auto &value : choice.value("modifiers").toArray()) {
                            const QJsonObject modifier = value.toObject();
                            if (modifier.value("kind").toString() == "tag") tag = modifier.value("stringParams").toObject().value("text").toString();
                        }
                        auto *action = menu->addAction(title);
                        action->setCheckable(true); group->addAction(action);
                        action->setChecked(tag.compare(selected, Qt::CaseInsensitive) == 0 || title.compare(selected, Qt::CaseInsensitive) == 0);
                        action->setData(tag);
                        QObject::connect(action, &QAction::triggered, btn, [handle, panel, itemId, tag] {
                            dispatch(handle, panel, itemId, QStringLiteral("selection"), jsonFragment(tag));
                        });
                    }
                } else if (ikind == "Toggle") {
                    QString title = item.value("stringParams").toObject().value("text").toString();
                    for (const auto &child : item.value("children").toArray())
                        if (child.toObject().value("kind").toString() == "Text") title = child.toObject().value("stringParams").toObject().value("text").toString();
                    const QString itemId = item.value("id").toString();
                    auto *action = menu->addAction(title);
                    action->setCheckable(true);
                    action->setChecked(item.value("boolParams").toObject().value("isOn").toBool());
                    QObject::connect(action, &QAction::triggered, btn, [handle, panel, itemId](bool checked) {
                        dispatch(handle, panel, itemId, QStringLiteral("isOn"), checked ? "true" : "false");
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
        const double inset = node.value("doubleParams").toObject().value("inset").toDouble();
        auto *shape = new SwiftUIShapeWidget(shapeKind, cornerRadius, fillColor, strokeColor, strokeWidth, inset);
        shape->m_path = strings.value("path").toString();
        shape->m_pathAbsolute = bools.value("pathAbsolute").toBool();
        shape->m_mirrorX = bools.value("mirrorX").toBool();
        shape->m_mirrorY = bools.value("mirrorY").toBool();
        widget = shape;
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
                    const QString contentMode = strings.value("contentMode").toString();
                    const qreal aspectRatio = node.value("doubleParams").toObject().value("aspectRatio").toDouble();
                    fitted = new SwiftUIFitImageWidget(image, contentMode, aspectRatio);
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
        auto *scrollArea = new SwiftUIScrollArea;
        scrollArea->setWidgetResizable(true);
        scrollArea->setFrameShape(QFrame::NoFrame);
        scrollArea->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
        scrollArea->setStyleSheet("QScrollArea { background: transparent; border: none; } QScrollArea > QWidget > QWidget { background: transparent; }");
        // Tip tool headers use ScrollView(.horizontal); respect encoded axes (default vertical-only matches SwiftUI).
        const bool scrollH = bools.value("horizontal").toBool();
        const bool scrollV = bools.contains("vertical") ? bools.value("vertical").toBool() : !scrollH;
        scrollArea->horizontalOnly = scrollH && !scrollV;
        scrollArea->setHorizontalScrollBarPolicy(scrollH ? Qt::ScrollBarAsNeeded : Qt::ScrollBarAlwaysOff);
        scrollArea->setVerticalScrollBarPolicy(scrollV ? Qt::ScrollBarAsNeeded : Qt::ScrollBarAlwaysOff);
        if (!children.isEmpty()) {
            if (QWidget *content = buildNode(handle, panel, children.first().toObject())) {
                content->setSizePolicy(scrollH && !scrollV ? QSizePolicy::Preferred : QSizePolicy::Expanding,
                                       scrollV ? QSizePolicy::Preferred : QSizePolicy::Fixed);
                scrollArea->setWidget(content);
            }
        }
        if (bools.value("appKitScroll").toBool()) scrollArea->bindAppKit(handle, panel, node);
        widget = scrollArea;
    } else if (kind == "Spacer") {
        auto *spacer = new QWidget;
        spacer->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);   // narrowed to its stack's axis there
        spacer->setMinimumSize(0, 0);
        widget = spacer;
    } else if (kind == "Color") {
        // Color as a view leaf (Color.clear.contentShape + DragGesture, background fills, …).
        // Must produce a real widget so gesture handlers attach; skipping it leaves an interactive
        // GeometryReader overlay that eats clicks without delivering drag events (Image › Curves).
        auto *swatch = new QWidget;
        swatch->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
        swatch->setAttribute(Qt::WA_StyledBackground, true);
        const QColor fill = parseColorToken(strings.value("name").toString());
        swatch->setStyleSheet(QStringLiteral("background-color: rgba(%1,%2,%3,%4); border: none;")
                                  .arg(fill.red()).arg(fill.green()).arg(fill.blue()).arg(fill.alphaF(), 0, 'f', 4));
        widget = swatch;
    } else if (kind == "Divider") {
        // NSColor.separatorColor in dark aqua (white at 10%), one point thick across its stack (an HStack turns it).
        auto *line = new QFrame;
        line->setFrameShape(QFrame::NoFrame);
        line->setAttribute(Qt::WA_StyledBackground, true);
        line->setStyleSheet("background-color: rgba(255, 255, 255, 0.10); border: none;");
        line->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Fixed);
        line->setFixedHeight(1);
        widget = line;
    } else if (kind == "Canvas") {
        widget = new SwiftUICanvasWidget(handle, panel, id);
    } else if (kind == "_AppKit") {
        auto *appKit = new SwiftUIAppKitWidget(handle, panel, id);
        const QJsonObject doubles = node.value("doubleParams").toObject();
        if (doubles.contains("height")) {
            const int height = qMax(1, qRound(doubles.value("height").toDouble()));
            if (bools.value("tableDocument").toBool()) {
                appKit->setMinimumHeight(height);
                appKit->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Preferred);
            } else {
                appKit->setFixedHeight(height);
                appKit->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Fixed);
            }
        }
        if (doubles.contains("width")) appKit->setMinimumWidth(qRound(doubles.value("width").toDouble()));
        // Views over it (a field being edited), where the node puts them; a field takes the keys with its text selected.
        for (const QJsonValue &childValue : children) {
            const QJsonObject child = childValue.toObject();
            QWidget *over = buildNode(handle, panel, child);
            if (!over) continue;
            const QJsonObject frame = child.value("doubleParams").toObject();
            over->setParent(appKit);
            over->setGeometry(qRound(frame.value("frameX").toDouble()), qRound(frame.value("frameY").toDouble()),
                              qMax(20, qRound(frame.value("frameW").toDouble())), qMax(16, qRound(frame.value("frameH").toDouble())));
            over->show();
            if (child.value("boolParams").toObject().value("focused").toBool()) {
                QLineEdit *edit = qobject_cast<QLineEdit *>(over);
                if (!edit) edit = over->findChild<QLineEdit *>();
                QTimer::singleShot(0, over, [edit] { if (edit) { edit->setFocus(Qt::OtherFocusReason); edit->selectAll(); } });
            }
        }
        widget = appKit;
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
    } else if (kind == "ScrollViewReader") {
        // Its content as it is; a `scrollTo` it asked for shows the view with that `.id` in the scroll view around it.
        widget = children.isEmpty() ? new QWidget : buildNode(handle, panel, children.first().toObject());
        if (!widget) widget = new QWidget;
        const QString target = strings.value("scrollTarget").toString();
        if (!target.isEmpty()) {
            QTimer::singleShot(0, widget, [root = QPointer<QWidget>(widget), target] {
                if (!root) return;
                for (QWidget *child : root->findChildren<QWidget *>()) {
                    if (child->property("swiftuiIdentifier").toString() != target) continue;
                    for (QWidget *up = child->parentWidget(); up; up = up->parentWidget())
                        if (auto *area = qobject_cast<QScrollArea *>(up)) { area->ensureWidgetVisible(child, 0, 0); break; }
                    break;
                }
            });
        }
    } else {
        // Not yet mapped (e.g. _Native/LinearGradient land in later phases) — skip, don't crash.
        return nullptr;
    }

    if (widget && node.value("doubleParams").toObject().contains("nativeMinWidth")) {
        const double minimum = node.value("doubleParams").toObject().value("nativeMinWidth").toDouble();
        if (std::isfinite(minimum) && minimum >= 0) {
            widget->setMinimumWidth(qRound(qBound(1.0, minimum, double(QWIDGETSIZE_MAX))));
            widget->setSizePolicy(QSizePolicy::Expanding, widget->sizePolicy().verticalPolicy());
        }
    }
    applyModifiers(widget, node.value("modifiers").toArray());

    if (widget) {
        const QStringList hKeys = [&] {
            QStringList keys;
            for (const auto &k : node.value("handlerKeys").toArray()) keys << k.toString();
            return keys;
        }();
        for (const auto &entry : node.value("modifiers").toArray()) {
            const QJsonObject modifier = entry.toObject();
            if (modifier.value("kind").toString() != QLatin1String("timer")) continue;
            const double interval = modifier.value("doubleParams").toObject().value("interval").toDouble();
            auto *timer = new QTimer(widget);
            timer->setInterval(qMax(1, qRound(interval * 1000.0)));
            QObject::connect(timer, &QTimer::timeout, widget, [widget, handle, panel, id] {
                QTimer::singleShot(0, widget, [handle, panel, id] {
                    dispatch(handle, panel, id, QStringLiteral("onReceive"));
                });
            });
            timer->start();
        }
        // A view with gestures of its own takes the mouse, even one drawn passive (an Image: the layer and effect eyes),
        // unless SwiftUI turned its hit-testing off.
        static const QStringList interactive{QStringLiteral("dragChanged"), QStringLiteral("dragEnded"), QStringLiteral("onContinuousHover"),
            QStringLiteral("onTapGesture"), QStringLiteral("spatialTapGesture"), QStringLiteral("contextMenu")};
        if (std::any_of(interactive.begin(), interactive.end(), [&](const QString &key) { return hKeys.contains(key); })) {
            bool hitTestingOff = false;
            for (const auto &entry : node.value("modifiers").toArray()) {
                const QJsonObject modifier = entry.toObject();
                if (modifier.value("kind").toString() == QLatin1String("allowsHitTesting")
                    && !modifier.value("boolParams").toObject().value("enabled").toBool()) hitTestingOff = true;
            }
            if (!hitTestingOff) widget->setAttribute(Qt::WA_TransparentForMouseEvents, false);
        }
        if (hKeys.contains(QStringLiteral("dragChanged")) || hKeys.contains(QStringLiteral("dragEnded"))) {
            new DragPressFilter(widget, widget, handle, panel, id);
            for (QWidget *inner : widget->findChildren<QWidget *>()) new DragPressFilter(inner, widget, handle, panel, id);
        }
        if (hKeys.contains(QStringLiteral("onContinuousHover"))) new HoverFilter(widget, handle, panel, id);
        if (hKeys.contains(QStringLiteral("onTapGesture")) || hKeys.contains(QStringLiteral("spatialTapGesture"))) {
            widget->setCursor(Qt::PointingHandCursor);
            auto onTap = [handle, panel, id](int modifiers) {
                dispatch(handle, panel, id, QStringLiteral("onTapGesture"), QByteArray::number(modifiers));
            };
            auto onSpatialTap = [handle, panel, id](QPointF position) {
                const QByteArray payload = "[" + QByteArray::number(position.x()) + "," + QByteArray::number(position.y()) + "]";
                dispatch(handle, panel, id, QStringLiteral("spatialTapGesture"), payload);
            };
            widget->installEventFilter(new TapGestureFilter(widget,
                widget->property("swiftuiTapGestureCount").toInt(),
                widget->property("swiftuiSpatialTapGestureCount").toInt(),
                hKeys.contains(QStringLiteral("onTapGesture")) ? onTap : std::function<void(int)>(),
                hKeys.contains(QStringLiteral("spatialTapGesture")) ? onSpatialTap : std::function<void(QPointF)>()));
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
        // Drawn AppKit views forward all keys themselves, including the native key code and repeat state.
        // The one-shot shortcut recorder would otherwise intercept their next key application-wide.
        if (kind != QLatin1String("_AppKit") && hKeys.contains(QStringLiteral("keyCapture")))
            new KeyCaptureFilter(widget, handle, panel, id);
        if (hKeys.contains(QStringLiteral("geometryChange"))) new GeometryChangeFilter(widget, handle, panel, id);
        if (hKeys.contains(QStringLiteral("dropEvent"))) {
            const QStringList dropTypes = strings.value("dropTypes").toString().split(QLatin1Char(','), Qt::SkipEmptyParts);
            if (!dropTypes.isEmpty()) new DropTargetFilter(widget, handle, panel, id, dropTypes);
        }
    }

    if (widget) widget->setProperty("swiftUINode", id);
    return widget;
}

} // namespace

extern "C" int32_t compositor_host_measure_swiftui(const uint8_t *json, size_t count, double width, double height,
                                                   double *measuredWidth, double *measuredHeight) {
    Q_UNUSED(height);
    if (!qobject_cast<QApplication *>(QCoreApplication::instance()) || !json || !measuredWidth || !measuredHeight
        || count > static_cast<size_t>(std::numeric_limits<int>::max())) return 0;
    QJsonObject node = QJsonDocument::fromJson(QByteArray(reinterpret_cast<const char *>(json), static_cast<int>(count))).object();
    static const QStringList leaves{"Text", "Button", "Toggle", "TextField", "Slider", "Picker", "Label", "Image"};
    if (!leaves.contains(node.value("kind").toString())) return 0;
    // Measure with the actual widget builder, without event/lifecycle modifiers or opaque native content.
    // Unknown descendants keep the whole response unknown rather than silently shrinking a control's label.
    std::function<bool(QJsonObject &, bool)> sanitize = [&](QJsonObject &value, bool root) {
        const QString kind = value.value("kind").toString();
        if (!leaves.contains(kind) && kind != "HStack" && kind != "VStack" && kind != "Group" && kind != "_ViewList") return false;
        if (kind == "Image" && !value.value("stringParams").toObject().value("source").toString().startsWith("system:")) return false;
        value["handlerKeys"] = QJsonArray{};
        QJsonObject bools = value.value("boolParams").toObject();
        bools.remove("focused"); value["boolParams"] = bools;
        QJsonArray modifiers;
        static const QStringList styles{"font", "controlSize", "buttonStyle", "buttonBorderShape", "toggleStyle",
            "pickerStyle", "textFieldStyle", "multilineTextAlignment", "lineLimit", "foregroundStyle", "keyboardShortcut"};
        for (const auto &entry : value.value("modifiers").toArray()) {
            const QString name = entry.toObject().value("kind").toString();
            if (styles.contains(name) || (!root && (name == "frame" || name == "padding"))) modifiers.append(entry);
        }
        value["modifiers"] = modifiers;
        QJsonArray children;
        for (const auto &entry : value.value("children").toArray()) {
            QJsonObject child = entry.toObject();
            if (!sanitize(child, false)) return false;
            children.append(child);
        }
        value["children"] = children;
        return true;
    };
    if (!sanitize(node, true)) return 0;
    std::unique_ptr<QWidget> widget(buildNode(0, {}, node));
    if (!widget) return 0;
    widget->ensurePolished();
    QSize hint = widget->sizeHint().expandedTo(widget->minimumSize()).boundedTo(widget->maximumSize());
    if (auto *label = qobject_cast<QLabel *>(widget.get()); label && label->pixmap().isNull()) {
        const bool wraps = label->wordWrap();
        label->setWordWrap(false);
        label->setText(node.value("stringParams").toObject().value("text").toString());
        hint = label->sizeHint();
        label->setWordWrap(wraps);
        if (std::isfinite(width) && width >= 0 && width < hint.width()) {
            const int offered = qMax(1, static_cast<int>(std::ceil(width)));
            hint.setWidth(static_cast<int>(std::ceil(width)));
            if (wraps) hint.setHeight(label->heightForWidth(offered));
        }
        hint = hint.boundedTo(label->maximumSize());
    }
    if (!hint.isValid()) return 0;
    *measuredWidth = hint.width(); *measuredHeight = hint.height();
    return 1;
}

bool swiftUIDragGestureActive(uint64_t sessionHandle) {
    return DragTracker::shared().isActive() && DragTracker::shared().handle() == sessionHandle;
}

static bool isBeingManipulated(QWidget *panel) {
    for (QSlider *slider : panel->findChildren<QSlider *>()) if (slider->isSliderDown()) return true;
    for (QAbstractButton *button : panel->findChildren<QAbstractButton *>()) if (button->isDown()) return true;
    // Keyboard popups can be open without a platform mouse grab.
    for (QComboBox *picker : panel->findChildren<QComboBox *>())
        if (picker->view()->isVisible()) return true;
    if (QWidget *grabber = QWidget::mouseGrabber(); grabber && panel->isAncestorOf(grabber)) return true;
    QWidget *focus = QApplication::focusWidget();
    return focus && panel->isAncestorOf(focus)
        && (qobject_cast<QLineEdit *>(focus) || qobject_cast<QAbstractSpinBox *>(focus) || qobject_cast<QTextEdit *>(focus));
}

QWidget *swiftUIRenderPanel(uint64_t sessionHandle, const QString &panel) {
    return swiftUIRenderPanelIfChanged(sessionHandle, panel, nullptr);
}

/// An unchanged tree's widgets already show it, except its Canvas nodes, which draw what their handler draws now.
static void repaintCanvases(QWidget *panel) {
    // (No Q_OBJECT on the canvas widget: findChildren<T> would match every QWidget.)
    for (QWidget *child : panel->findChildren<QWidget *>())
        if (dynamic_cast<SwiftUICanvasWidget *>(child)) child->update();
}

// Update dependent controls while typing without replacing the focused field.
static void refreshEditingControlState(QWidget *current, const QJsonObject &root, bool refreshText) {
    QHash<QString, bool> enabled;
    QHash<QString, double> opacity;
    QHash<QString, int> sliderValues;
    QHash<QString, QJsonObject> labels;
    QHash<QString, QString> fields;
    std::function<void(const QJsonObject &, bool)> collect = [&](const QJsonObject &node, bool parentEnabled) {
        bool active = parentEnabled;
        const QString id = node.value("id").toString();
        for (const auto &value : node.value("modifiers").toArray()) {
            const auto modifier = value.toObject();
            if (modifier.value("kind").toString() == "disabled")
                active &= !modifier.value("boolParams").toObject().value("value").toBool();
            else if (modifier.value("kind").toString() == "opacity")
                opacity[id] = modifier.value("doubleParams").toObject().value("value").toDouble(1);
        }
        if (node.value("kind").toString() == "Button" || node.value("kind").toString() == "Toggle") enabled[id] = active;
        if (refreshText && node.value("kind").toString() == "Text") labels[id] = node;
        if (refreshText && node.value("kind").toString() == "TextField") {
            const auto strings = node.value("stringParams").toObject(), doubles = node.value("doubleParams").toObject();
            if (strings.contains("text")) fields[id] = strings.value("text").toString();
            else if (doubles.contains("value")) fields[id] = formatTextFieldNumber(doubles, doubles.value("value").toDouble());
        }
        if (node.value("kind").toString() == "Slider") {
            const auto values = node.value("doubleParams").toObject();
            const double lower = values.value("lowerBound").toDouble(), upper = values.value("upperBound").toDouble(1);
            const double span = upper > lower ? upper - lower : 1;
            sliderValues[id] = qBound(0, static_cast<int>((values.value("value").toDouble() - lower) / span * 1000), 1000);
        }
        for (const auto &child : node.value("children").toArray()) collect(child.toObject(), active);
    };
    collect(root, true);
    auto widgets = current->findChildren<QWidget *>(); widgets.prepend(current);
    for (auto *widget : widgets) {
        const QString id = widget->property("swiftUINode").toString();
        if (enabled.contains(id)) widget->setEnabled(enabled.value(id));
        if (sliderValues.contains(id))
            if (auto *slider = qobject_cast<QSlider *>(widget); slider && !slider->isSliderDown()) {
                const QSignalBlocker block(slider);
                slider->setValue(sliderValues.value(id));
            }
        if (opacity.contains(id))
            if (auto *effect = qobject_cast<QGraphicsOpacityEffect *>(widget->graphicsEffect())) effect->setOpacity(opacity.value(id));
        if (fields.contains(id)) if (auto *field = qobject_cast<QLineEdit *>(widget);
            field && (!field->hasFocus() || !field->property("swiftuiTyped").toBool()) && field->text() != fields.value(id)) {
            const QSignalBlocker block(field);
            field->setText(fields.value(id));
        }
        if (labels.contains(id)) if (auto *label = qobject_cast<QLabel *>(widget)) {
            const auto node = labels.value(id);
            const auto wire = QJsonDocument(node).toJson(QJsonDocument::Compact);
            if (label->property("swiftuiEditingLabelWire").toByteArray() == wire) continue;
            if (!label->property("swiftuiEditingLabelBaseStyle").isValid())
                label->setProperty("swiftuiEditingLabelBaseStyle", label->styleSheet());
            label->setStyleSheet(label->property("swiftuiEditingLabelBaseStyle").toString());
            label->setText(node.value("stringParams").toObject().value("text").toString());
            QJsonArray foreground;
            for (const auto &value : node.value("modifiers").toArray())
                if (value.toObject().value("kind").toString() == "foregroundStyle") foreground.append(value);
            applyModifiers(label, foreground);
            if (label->text().size() > 40 && label->text().contains(QLatin1Char(' '))) {
                label->setWordWrap(true);
                label->setSizePolicy(QSizePolicy::Expanding, label->sizePolicy().verticalPolicy());
                if (auto *parent = label->parentWidget(); parent && parent->layout()) parent->layout()->setAlignment(label, Qt::Alignment());
            }
            label->setProperty("swiftuiEditingLabelWire", wire);
        }
    }
}

QWidget *swiftUIRenderPanelIfChanged(uint64_t sessionHandle, const QString &panel, QWidget *current) {
    PERF_SCOPE(QStringLiteral("swiftUIRenderPanel:") + panel);
    QPointer<QLineEdit> search;
    QPointer<QLineEdit> amount;
    QPointer<QLineEdit> colorField;
    QPointer<QLineEdit> toolField;
    QPointer<QLineEdit> gridField;
    QPointer<QLineEdit> numericField;
    if (current && panel != "ColorPickerSheet" && !swiftUIDragGestureActive(sessionHandle)) {
        auto *field = qobject_cast<QLineEdit *>(QApplication::focusWidget());
        if (field && current->isAncestorOf(field) && field->property("swiftuiNumericField").toBool()) numericField = field;
    }
    if (panel == "ToolHeaders" && current && !swiftUIDragGestureActive(sessionHandle)) {
        auto *field = qobject_cast<QLineEdit *>(QApplication::focusWidget());
        if (field && current->isAncestorOf(field)) toolField = field;
    }
    if (panel == "ColorPickerSheet" && current && !swiftUIDragGestureActive(sessionHandle)) {
        auto *field = qobject_cast<QLineEdit *>(QApplication::focusWidget());
        if (field && current->isAncestorOf(field)) colorField = field;
    }
    if ((panel == "KeyboardShortcutsSheet" || panel.startsWith(QLatin1String("NativeWindow:"))) && current) {
        auto *field = qobject_cast<QLineEdit *>(QApplication::focusWidget());
        if (field && current->isAncestorOf(field)
            && (panel.startsWith(QLatin1String("NativeWindow:")) || field->placeholderText() == "Search shortcuts")) search = field;
    }
    if (panel == "SelectionAmountSheet" && current) {
        auto *field = qobject_cast<QLineEdit *>(QApplication::focusWidget());
        if (field && current->isAncestorOf(field) && field->placeholderText() == "Amount") amount = field;
    }
    if (panel == "GridSettingsSheet" && current) {
        auto *field = qobject_cast<QLineEdit *>(QApplication::focusWidget());
        if (field && current->isAncestorOf(field)) gridField = field;
    }
    // Focused but not typed in (New Canvas opens with Width focused): its text still follows the model, so a value set
    // from elsewhere (a preset) shows, as in SwiftUI; the field keeps its focus (updated in place, not rebuilt).
    QPointer<QLineEdit> untypedField;
    if (current && !search && !amount && !colorField && !toolField && !gridField && !numericField) {
        auto *field = qobject_cast<QLineEdit *>(QApplication::focusWidget());
        if (field && current->isAncestorOf(field) && !field->property("swiftuiTyped").toBool()) untypedField = field;
    }
    // Mid-drag / mid-typing the panel stays as it is (see below), so don't even resolve its tree.
    if (current && current->property("swiftUIHandle").toULongLong() == sessionHandle && !search && !amount && !colorField && !toolField && !gridField && !numericField && !untypedField && isBeingManipulated(current)) {
        repaintCanvases(current);
        return current;
    }
    QByteArray bytes;
    { PERF_SCOPE(QStringLiteral("fetchTree:") + panel); bytes = fetchTreeBytes(sessionHandle, panel); }
    if (bytes.isEmpty()) return nullptr;
    if ((amount || toolField || gridField || numericField || untypedField) && current && current->property("swiftUIHandle").toULongLong() == sessionHandle)
        refreshEditingControlState(current, QJsonDocument::fromJson(bytes).object(), gridField || numericField || untypedField);
    // Same session, same tree: the widgets already show it. Node ids are positional, so its buttons still reach the
    // handlers the fetch just re-registered; canvases fetch their pixels at paint time, so a repaint refreshes them.
    if (current && current->property("swiftUIHandle").toULongLong() == sessionHandle
        && current->property("swiftUITree").toByteArray() == bytes) {
        repaintCanvases(current);
        return current;
    }
    // Being dragged or typed in: rebuilding now would replace the slider under the mouse (ending the drag) or the
    // field being typed in (losing focus mid-word). Keep it; the release / end of editing refreshes the panel.
    if (current && current->property("swiftUIHandle").toULongLong() == sessionHandle && !search && !colorField && isBeingManipulated(current)) {
        repaintCanvases(current);
        return current;
    }
    const QJsonObject root = QJsonDocument::fromJson(bytes).object();
    if (root.isEmpty()) return nullptr;
    if (colorField) colorField->setProperty("swiftuiPreservingFocus", true);
    PERF_SCOPE(QStringLiteral("buildNode:") + panel);
    QWidget *built = buildNode(sessionHandle, panel, root);
    if (built) {
        built->setProperty("swiftUIHandle", QVariant::fromValue<qulonglong>(sessionHandle));
        built->setProperty("swiftUITree", bytes);
        if (search) {
            const QString placeholder = search->placeholderText();
            const int cursor = search->cursorPosition(), selection = search->selectionStart(), length = search->selectedText().size();
            for (auto *field : built->findChildren<QLineEdit *>()) if (field->placeholderText() == placeholder) {
                QTimer::singleShot(0, field, [field, cursor, selection, length] {
                    if (!field->isVisible()) return;
                    field->setFocus(Qt::OtherFocusReason);
                    if (selection >= 0) field->setSelection(selection, length);
                    else field->setCursorPosition(cursor);
                });
                break;
            }
        }
        if (colorField) {
            const QString name = colorField->placeholderText(), text = colorField->text();
            const int cursor = colorField->cursorPosition(), selection = colorField->selectionStart(), length = colorField->selectedText().size();
            for (auto *field : built->findChildren<QLineEdit *>()) if (field->placeholderText() == name) {
                const QSignalBlocker block(field);
                field->setText(text);
                QTimer::singleShot(0, field, [field, cursor, selection, length] {
                    if (!field->isVisible()) return;
                    field->setFocus(Qt::OtherFocusReason);
                    if (selection >= 0) field->setSelection(selection, length);
                    else field->setCursorPosition(cursor);
                });
                break;
            }
        }
    }
    return built;
}

void registerSwiftUIActionListener(std::function<void(uint64_t, const QString &)> listener) {
    g_actionListeners.push_back(std::move(listener));
}
