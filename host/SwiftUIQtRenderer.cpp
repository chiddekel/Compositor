#include <QKeyEvent>
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
// SwiftUIQtRenderer — see SwiftUIQtRenderer.h. Fetches the resolved tree via compositor_session_render_tree
// (same size-query convention as compositor_session_state, see SessionWindow::sessionState) and walks it once,
// mapping each `RenderNode` kind to the matching Qt widget. Interactive widgets (Button, Toggle) wire their Qt
// signal straight to compositor_session_dispatch_swiftui_action, by the node's id — the same generic path for
// every panel, no per-panel Qt glue. This is intentionally the *only* place that knows the kind→widget mapping.

#include "SwiftUIQtRenderer.h"
#include "LucideIcons.h"
#include <QPointer>
#include <QStyleOption>
#include <QAbstractItemView>
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
#include <QLineEdit>
#include <QPainter>
#include <QPaintEvent>
#include <QGraphicsEffect>
#include <QPushButton>
#include <QScrollArea>
#include <QIcon>
#include <QPainterPath>
#include <QProgressBar>
#include <QSlider>
#include <QStackedLayout>
#include <QVariant>
#include <QRegion>

extern "C" {
int64_t compositor_session_render_tree(uint64_t handle, const char *panel, uint8_t *output, size_t capacity);
int32_t compositor_session_dispatch_swiftui_action(uint64_t handle, const char *panel, const char *node_id, const char *handler_key,
                                                   const uint8_t *payload, size_t payload_count);
int32_t compositor_session_dispatch_swiftui_drop_event(uint64_t handle, const char *panel, const char *node_id, const char *handler_key,
                                                        const uint8_t *payload, size_t payload_count);
int64_t compositor_session_render_swiftui_canvas(uint64_t handle, const char *panel, const char *node_id, size_t width, size_t height,
                                                 uint8_t *output, size_t capacity);
}

namespace {

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
                       double inset, QWidget *parent = nullptr)
        : QWidget(parent), m_shapeKind(shapeKind), m_cornerRadius(cornerRadius), m_inset(inset),
          m_fillColor(fillColor), m_strokeColor(strokeColor), m_strokeWidth(strokeWidth) {
        setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);   // a Shape fills what it is offered
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

class SwiftUIMaskEffect : public QGraphicsEffect {
public:
    SwiftUIMaskEffect(QWidget *source, QWidget *mask) : QGraphicsEffect(source), m_mask(mask) {
        m_mask->setParent(source);
        m_mask->setAttribute(Qt::WA_TransparentForMouseEvents, true);
        m_mask->hide();
    }

protected:
    void draw(QPainter *painter) override {
        QPoint offset;
        const QPixmap source = sourcePixmap(Qt::LogicalCoordinates, &offset, QGraphicsEffect::NoPad);
        if (source.isNull() || !m_mask) {
            drawSource(painter);
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
        painter->drawImage(offset, masked);
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

void dispatch(uint64_t handle, const QString &panel, const QString &nodeID, const QString &handlerKey, const QByteArray &payload = {}) {
    const QByteArray panelUtf8 = panel.toUtf8(), nodeUtf8 = nodeID.toUtf8(), keyUtf8 = handlerKey.toUtf8();
    compositor_session_dispatch_swiftui_action(handle, panelUtf8.constData(), nodeUtf8.constData(), keyUtf8.constData(),
                                               payload.isEmpty() ? nullptr : reinterpret_cast<const uint8_t *>(payload.constData()),
                                               static_cast<size_t>(payload.size()));
    for (const auto &cb : g_actionListeners) {
        cb(handle, panel);
    }
}

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

/// Drag-and-drop for a List whose view asked for it (`compatListDrop`): press a row and drag to move it; the drop
/// lands above the nearer row edge, or into a folder row's middle (highlighted), Alt copies. The List's own handler
/// ("listDrop": [source row, row under the drop, fraction within it, copying]) decides what the drop does.
class ListDragController : public QObject {
public:
    ListDragController(QWidget *content, QList<QWidget *> rows, QString folders, QString layerIdentifiers,
                       QString maskDragIdentifiers, QString maskDropIdentifiers,
                       uint64_t handle, QString panel, QString nodeID)
        : QObject(content), m_content(content), m_rows(std::move(rows)), m_folders(std::move(folders)),
          m_layerIdentifiers(std::move(layerIdentifiers)), m_maskDragIdentifiers(std::move(maskDragIdentifiers)),
          m_maskDropIdentifiers(std::move(maskDropIdentifiers)), m_handle(handle),
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
                const int row = obj->property("listRow").toInt();
                if (m_pressRow != row) {
                    m_pressRow = row;
                    m_pressPos = e->globalPosition().toPoint();
                    m_pressMaskSource = e->modifiers().testFlag(Qt::AltModifier) && !e->modifiers().testFlag(Qt::ControlModifier)
                        ? obj->property("listMaskDragSource").toString() : QString();
                }
            }
            break;
        }
        case QEvent::MouseMove: {
            auto *e = static_cast<QMouseEvent *>(event);
            if (m_pressRow < 0 || !(e->buttons() & Qt::LeftButton)) break;
            if ((e->globalPosition().toPoint() - m_pressPos).manhattanLength() < QApplication::startDragDistance()) break;
            if (!m_pressMaskSource.isEmpty()) {
                const QString source = m_pressMaskSource;
                m_pressRow = -1;
                m_pressMaskSource.clear();
                auto *drag = new QDrag(m_content);
                auto *mime = new QMimeData;
                mime->setData("com.compositor.layer-mask", source.toUtf8());
                drag->setMimeData(mime);
                drag->exec(Qt::CopyAction, Qt::CopyAction);
                m_indicator->hide();
                return true;
            }
            const int source = m_pressRow;
            m_pressRow = -1;
            auto *drag = new QDrag(m_content);
            auto *mime = new QMimeData;
            mime->setData("application/x-compositor-list-row", QByteArray::number(source));
            const QStringList layerIdentifiers = m_layerIdentifiers.split(QLatin1Char(','), Qt::KeepEmptyParts);
            if (source < layerIdentifiers.size() && !layerIdentifiers[source].isEmpty())
                mime->setData("com.compositor.layer-row", layerIdentifiers[source].toUtf8());
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
            m_pressMaskSource.clear();
            break;
        case QEvent::DragEnter:
        case QEvent::DragMove: {
            if (obj != m_content) break;
            auto *e = static_cast<QDropEvent *>(event);
            if (e->mimeData()->hasFormat("com.compositor.layer-mask")) {
                if (!canCopyMaskAt(e->mimeData()->data("com.compositor.layer-mask"), e->position().toPoint())) break;
                e->setDropAction(Qt::CopyAction);
                e->accept();
                showMaskIndicator(e->position().toPoint());
                return true;
            }
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
            if (e->mimeData()->hasFormat("com.compositor.layer-mask")) {
                const QByteArray source = e->mimeData()->data("com.compositor.layer-mask");
                const QPoint position = e->position().toPoint();
                const int row = locate(position).first;
                if (!canCopyMaskAt(source, position) || row >= m_rows.size()) break;
                const QStringList targets = m_maskDropIdentifiers.split(QLatin1Char(','), Qt::KeepEmptyParts);
                if (row >= targets.size() || targets[row].isEmpty()) break;
                const QJsonArray data{QString::fromUtf8(source), targets[row]};
                const QByteArray payload = QJsonDocument(data).toJson(QJsonDocument::Compact);
                e->setDropAction(Qt::CopyAction);
                e->accept();
                m_indicator->hide();
                const uint64_t handle = m_handle; const QString panel = m_panel, node = m_nodeID;
                QTimer::singleShot(0, [handle, panel, node, payload] { dispatch(handle, panel, node, QStringLiteral("listMaskDrop"), payload); });
                return true;
            }
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
    bool canCopyMaskAt(const QByteArray &source, const QPoint &position) const {
        const QString sourceID = QString::fromUtf8(source);
        const QStringList sources = m_maskDragIdentifiers.split(QLatin1Char(','), Qt::KeepEmptyParts);
        const QStringList targets = m_maskDropIdentifiers.split(QLatin1Char(','), Qt::KeepEmptyParts);
        if (!sources.contains(sourceID)) return false;
        const int row = locate(position).first;
        return row < m_rows.size() && row < targets.size() && !targets[row].isEmpty() && targets[row] != sourceID;
    }
    void watch(QWidget *widget, int row, QString maskSource = {}) {
        widget->setProperty("listRow", row);
        if (widget->objectName().startsWith(QStringLiteral("layerMaskThumb:")))
            maskSource = widget->objectName().mid(QStringLiteral("layerMaskThumb:").size());
        if (!maskSource.isEmpty()) widget->setProperty("listMaskDragSource", maskSource);
        widget->installEventFilter(this);
        for (QWidget *child : widget->findChildren<QWidget *>(QString(), Qt::FindDirectChildrenOnly)) watch(child, row, maskSource);
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
    void showMaskIndicator(const QPoint &pos) {
        const auto [row, fraction] = locate(pos);
        Q_UNUSED(fraction);
        if (row >= m_rows.size()) { m_indicator->hide(); return; }
        m_indicator->setStyleSheet("background: rgba(0, 122, 255, 0.18); border: 2px solid #007aff; border-radius: 5px;");
        m_indicator->setGeometry(m_rows[row]->geometry());
        m_indicator->raise();
        m_indicator->show();
    }
    QWidget *m_content;
    QList<QWidget *> m_rows;
    QString m_folders, m_layerIdentifiers, m_maskDragIdentifiers, m_maskDropIdentifiers, m_pressMaskSource;
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
            if (!text.isEmpty()) {
                if (kind == "help") widget->setToolTip(text);
                else widget->setAccessibleName(text);
            }
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
    }
    QSize sizeHint() const override {
        QSize hint(0, 0);
        for (QWidget *w : m_children) if (!w->property("positioned").toBool()) hint = hint.expandedTo(ownSize(w));
        return hint.isEmpty() ? QSize(20, 20) : hint;
    }
protected:
    static QSize ownSize(QWidget *w) { return w->minimumSize() == w->maximumSize() && !w->minimumSize().isEmpty() ? w->minimumSize() : w->sizeHint(); }
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
    void start(uint64_t handle, QString panel, QString id, QPoint originGlobal, QPointF pressGlobal, double minimumDistance) {
        m_handle = handle; m_panel = std::move(panel); m_id = std::move(id);
        m_origin = originGlobal; m_pressGlobal = pressGlobal; m_start = pressGlobal - QPointF(originGlobal);
        m_minimumDistance = qMax(0.0, minimumDistance);
        m_started = m_minimumDistance == 0.0;
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
        if (name == QLatin1String("global")) {
            DragTracker::shared().start(m_handle, m_panel, m_id, QPoint(0, 0),
                                        static_cast<QMouseEvent *>(event)->globalPosition(),
                                        m_gestureWidget->property("swiftuiGestureMinimumDistance").toDouble());
            return true;
        }
        if (name != QLatin1String("local")) {
            for (QWidget *w = m_gestureWidget; w; w = w->parentWidget()) {
                if (w->property("swiftuiCoordinateSpaces").toStringList().contains(name)) { space = w; break; }
            }
        }
        DragTracker::shared().start(m_handle, m_panel, m_id, space->mapToGlobal(QPoint(0, 0)),
                                    static_cast<QMouseEvent *>(event)->globalPosition(),
                                    m_gestureWidget->property("swiftuiGestureMinimumDistance").toDouble());
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

/// compatSwipe: a press on one of a group's views, then a drag over the others (Photoshop's eye swipe).
class SwipeFilter : public QObject {
public:
    SwipeFilter(QWidget *widget, uint64_t handle, QString panel, QString id, QString group)
        : QObject(widget), m_widget(widget), m_handle(handle), m_panel(std::move(panel)), m_id(std::move(id)), m_group(std::move(group)) {
        widget->setProperty("swipeGroup", m_group);
        widget->setProperty("swipeNodeID", m_id);
        widget->installEventFilter(this);
        members().removeAll(nullptr);
        members() << widget;
    }
    static QList<QPointer<QWidget>> &members() { static QList<QPointer<QWidget>> all; return all; }
    bool eventFilter(QObject *, QEvent *event) override {
        auto *me = static_cast<QMouseEvent *>(event);
        switch (event->type()) {
        case QEvent::MouseButtonPress:
            if (me->button() != Qt::LeftButton) return false;
            m_last = m_id;
            m_widget->grabMouse();
            send(m_id, "swipeBegan");
            return true;
        case QEvent::MouseMove: {
            if (m_last.isEmpty()) return false;
            // The group's view under the pointer, by row: a swipe runs down a column, so only the height has to match.
            const QPoint at = me->globalPosition().toPoint();
            for (const QPointer<QWidget> &w : members()) {
                if (!w || !w->isVisible() || w->property("swipeGroup").toString() != m_group) continue;
                const QRect r(w->mapToGlobal(QPoint(0, 0)), w->size());
                if (at.y() < r.top() || at.y() > r.bottom()) continue;
                const QString id = w->property("swipeNodeID").toString();
                if (id != m_last) { m_last = id; send(id, "swipeEntered"); }
                break;
            }
            return true;
        }
        case QEvent::MouseButtonRelease:
            if (m_last.isEmpty()) return false;
            m_widget->releaseMouse();
            m_last.clear();
            send(m_id, "swipeEnded");
            notifyListeners(m_handle, m_panel);
            return true;
        default: return false;
        }
    }
private:
    void send(const QString &id, const char *key) {
        const QByteArray panelUtf8 = m_panel.toUtf8(), nodeUtf8 = id.toUtf8();
        compositor_session_dispatch_swiftui_action(m_handle, panelUtf8.constData(), nodeUtf8.constData(), key, nullptr, 0);
        // The rows repaint as they change (the panel itself rebuilds when the swipe ends).
        for (QWidget *top : QApplication::topLevelWidgets()) top->update();
    }
    QWidget *m_widget;
    uint64_t m_handle;
    QString m_panel, m_id, m_group, m_last;
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
        }
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
            if (QWidget *child = buildNode(handle, panel, row)) layout->addWidget(child, r++, 0, 1, columns, vertical | horizontal);
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
            layout->addWidget(child, r, c++, 1, 1, flexible ? rowVertical : (rowVertical | horizontal));
        }
        ++r;
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
            base->setGraphicsEffect(new SwiftUIMaskEffect(base, mask));
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
            const int minimumFractionLength = qBound(0, doubles.value("minimumFractionLength").toInt(), 15);
            const int maximumFractionLength = qBound(minimumFractionLength, doubles.value("maximumFractionLength").toInt(), 15);
            const bool hasPrecision = doubles.contains("maximumFractionLength");
            auto formatNumber = [minimumFractionLength, maximumFractionLength, hasPrecision](double value) {
                if (!hasPrecision) return QString::number(value);
                QString text = QString::number(value, 'f', maximumFractionLength);
                while (text.contains('.') && text.endsWith('0') &&
                       text.length() - text.indexOf('.') - 1 > minimumFractionLength) {
                    text.chop(1);
                }
                if (text.endsWith('.')) text.chop(1);
                return text;
            };
            field->setText(formatNumber(doubles.value("value").toDouble()));
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
                    new ListDragController(content, rows, strings.value("listFolders").toString(),
                                           strings.value("listLayerIdentifiers").toString(),
                                           strings.value("listMaskDragIdentifiers").toString(),
                                           strings.value("listMaskDropIdentifiers").toString(), handle, panel, id);
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
        if (hKeys.contains(QStringLiteral("dragChanged")) || hKeys.contains(QStringLiteral("dragEnded"))) {
            new DragPressFilter(widget, widget, handle, panel, id);
            for (QWidget *inner : widget->findChildren<QWidget *>()) new DragPressFilter(inner, widget, handle, panel, id);
        }
        if (hKeys.contains(QStringLiteral("swipeBegan"))) new SwipeFilter(widget, handle, panel, id, strings.value("swipeGroup").toString());
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
        if (hKeys.contains(QStringLiteral("keyCapture"))) new KeyCaptureFilter(widget, handle, panel, id);
        if (hKeys.contains(QStringLiteral("geometryChange"))) new GeometryChangeFilter(widget, handle, panel, id);
        if (hKeys.contains(QStringLiteral("dropEvent"))) {
            const QStringList dropTypes = strings.value("dropTypes").toString().split(QLatin1Char(','), Qt::SkipEmptyParts);
            if (!dropTypes.isEmpty()) new DropTargetFilter(widget, handle, panel, id, dropTypes);
        }
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

/// An unchanged tree's widgets already show it, except its Canvas nodes, which draw what their handler draws now.
static void repaintCanvases(QWidget *panel) {
    // (No Q_OBJECT on the canvas widget: findChildren<T> would match every QWidget.)
    for (QWidget *child : panel->findChildren<QWidget *>())
        if (dynamic_cast<SwiftUICanvasWidget *>(child)) child->update();
}

QWidget *swiftUIRenderPanelIfChanged(uint64_t sessionHandle, const QString &panel, QWidget *current) {
    PERF_SCOPE(QStringLiteral("swiftUIRenderPanel:") + panel);
    // Mid-drag / mid-typing the panel stays as it is (see below), so don't even resolve its tree.
    if (current && current->property("swiftUIHandle").toULongLong() == sessionHandle && isBeingManipulated(current)) {
        repaintCanvases(current);
        return current;
    }
    QByteArray bytes;
    { PERF_SCOPE(QStringLiteral("fetchTree:") + panel); bytes = fetchTreeBytes(sessionHandle, panel); }
    if (bytes.isEmpty()) return nullptr;
    // Same session, same tree: the widgets already show it. Node ids are positional, so its buttons still reach the
    // handlers the fetch just re-registered; canvases fetch their pixels at paint time, so a repaint refreshes them.
    if (current && current->property("swiftUIHandle").toULongLong() == sessionHandle
        && current->property("swiftUITree").toByteArray() == bytes) {
        repaintCanvases(current);
        return current;
    }
    // Being dragged or typed in: rebuilding now would replace the slider under the mouse (ending the drag) or the
    // field being typed in (losing focus mid-word). Keep it; the release / end of editing refreshes the panel.
    if (current && current->property("swiftUIHandle").toULongLong() == sessionHandle && isBeingManipulated(current)) {
        repaintCanvases(current);
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
