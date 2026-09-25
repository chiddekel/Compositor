// SessionWindow — see SessionWindow.h. Drives the Swift core via compositor_session_*
// and paints the composited RGBA via QImage. Implements file operations using Qt
// codecs (IO milestone: file-map "IO / codec mapping" tier).

#include "SessionWindow.h"
#include "PerfTrace.h"

static bool needsUpstreamImporter(const QString &path);
#include "ImageExporters.h"
#include "TabletHandler.h"
#include "LayerItemDelegate.h"
#include "QtPlatformServices.h"
#include "EditorDialogs.h"
#include "SwiftUIQtRenderer.h"
#include "LucideIcons.h"
#include "AppVersion.h"
#include <QSvgRenderer>

#include <QPainter>
#include <QDialog>
#include <QFontMetricsF>
#include <QTextDocument>
#include <QTextOption>
#include <QTextCursor>
#include <QPlainTextEdit>
#include <QLineF>
#include <cmath>
#include <QScrollArea>
#include <QScrollBar>
#include <QScreen>
#include <QSettings>
#include <QPainterPath>
#include <QPaintEvent>
#include <QMouseEvent>
#include <QWindow>
#include <QTabletEvent>
#include <QDragEnterEvent>
#include <QDropEvent>
#include <QMimeData>
#include <QClipboard>
#include <QGuiApplication>
#include <QUrl>
#include <QMenuBar>
#include <QMessageBox>
#include <QComboBox>
#include <QCheckBox>
#include <QColorDialog>
#include <QPushButton>
#include <QStatusBar>
#include <QDockWidget>
#include <QTreeView>
#include <QStandardItemModel>
#include <QHeaderView>
#include <QStyle>
#include <QHBoxLayout>
#include <QMap>
#include <QSlider>
#include <QVBoxLayout>
#include <QLabel>
#include <QFile>
#include <QImageWriter>
#include <QImageReader>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QFileInfo>
#include <QDir>
#include <QToolBar>
#include <QActionGroup>
#include <QTimer>
#include <QDateTime>
#include <QCloseEvent>
#include <QStackedWidget>
#include <QTabBar>
#include <QSignalBlocker>
#include <QSpinBox>
#include <QDoubleSpinBox>
#include <QLineEdit>
#include <QTextEdit>
#include <QButtonGroup>
#include <QFrame>
#include <QToolButton>
#include <QMenu>
#include <QPixmap>
#include <QWheelEvent>
#include <QKeyEvent>
#include <QInputDialog>

#include <cstdint>
#include <cstring>
#include <algorithm>
#include <vector>

// compositor_session_* C ABI (see include/CompositorCore.h). Declared locally so
// the Qt host need not add an include path to the Swift core's headers.
extern "C" {
uint64_t compositor_session_create(void);
void compositor_session_close(uint64_t handle);
int32_t compositor_session_command(uint64_t handle, const uint8_t *json, size_t count);
int64_t compositor_session_render(uint64_t handle, uint8_t *output, size_t capacity);
int64_t compositor_session_render_revision(uint64_t handle);
int32_t compositor_session_viewport(uint64_t handle, double *out);
int32_t compositor_canvas_resize(uint64_t handle, double width, double height, double scale);
typedef int32_t (*compositor_symbol_renderer)(const char *name, int32_t width, int32_t height, double r, double g, double b, double a, uint8_t *output);
void compositor_set_symbol_renderer(compositor_symbol_renderer render);
int64_t compositor_canvas_cursor_image(int32_t *width, int32_t *height, double *hotX, double *hotY, uint8_t *output, size_t capacity);
int32_t compositor_canvas_key(uint64_t handle, int32_t keyCode, const char *characters, int32_t modifiers, int32_t isRepeat);
int32_t compositor_canvas_mouse(uint64_t handle, int32_t kind, double x, double y, int32_t modifiers, int32_t clickCount);
int64_t compositor_canvas_overlay(uint64_t handle, int32_t width, int32_t height, uint8_t *output, size_t capacity);
int64_t compositor_canvas_overlay_region(uint64_t handle, int32_t x, int32_t y, int32_t width, int32_t height, uint8_t *output, size_t capacity);
int32_t compositor_canvas_overlay_invalid(uint64_t handle, double *rect);
int64_t compositor_app_menus(uint8_t *output, size_t capacity);
int32_t compositor_app_menu_perform(const char *path);
int64_t compositor_take_shell_requests(uint8_t *output, size_t capacity);
int32_t compositor_session_viewport_update(uint64_t handle, int32_t op, double a, double b, double c);
typedef int32_t (*compositor_conversion_prompt)(const uint8_t *json, size_t length);
void compositor_set_sheet_presenter(void (*presenter)(void *context, const char *panel), void *context);
void compositor_pump_main(void);
void compositor_session_raw_develop_cancel(uint64_t handle);
void compositor_set_conversion_prompt(compositor_conversion_prompt prompt);
void compositor_set_wait_pump(void (*pump)(void *context), void *context);
void compositor_flush_preferences(void);
int64_t compositor_session_render_dirty(uint64_t handle, int32_t *rect, uint8_t *output, size_t capacity);
int64_t compositor_session_render_scaled(uint64_t handle, double scale, uint8_t *output, size_t capacity, int32_t *width, int32_t *height);
int64_t compositor_session_state(uint64_t handle, uint8_t *output, size_t capacity);
int64_t compositor_session_export_manifest(uint64_t handle, uint8_t *output, size_t capacity);
int32_t compositor_session_import_manifest(uint64_t handle, const uint8_t *json, size_t count);
int64_t compositor_session_export_layer(uint64_t handle, const uint8_t *layer_id, size_t layer_id_count,
                                        int32_t mask, uint8_t *output, size_t capacity,
                                        size_t *width, size_t *height);
int32_t compositor_session_import_layer(uint64_t handle, const uint8_t *layer_id, size_t layer_id_count,
                                        int32_t mask, const uint8_t *pixels, size_t count,
                                        size_t width, size_t height);
int32_t compositor_session_import_rgba(uint64_t handle, const uint8_t *pixels, size_t count,
                                       size_t width, size_t height, const uint8_t *name, size_t name_count,
                                       int32_t replacing);
// Document tabs are backed by upstream's own ProjectWorkspace (the same open-documents model the macOS app uses),
// not a Linux-only list — see Sources/LinuxBridge/SessionABI.swift's compositor_workspace_* functions.
uint64_t compositor_workspace_bootstrap(void);
uint64_t compositor_workspace_add_tab(void);
int32_t compositor_workspace_select_tab(uint64_t handle);
uint64_t compositor_workspace_close_tab(uint64_t handle);
int64_t compositor_workspace_tab_title(uint64_t handle, uint8_t *output, size_t capacity);
}

static int32_t cmd(uint64_t h, const char *json) {
    return compositor_session_command(h, reinterpret_cast<const uint8_t *>(json),
                                      std::strlen(json));
}

// Fetches a document tab's title from upstream's own ProjectWorkspace (see compositor_workspace_tab_title):
// "Untitled"/"Untitled N" until a project has a path, then the project's filename. Empty if handle isn't a
// workspace tab (compositor_session_create handles never are).
/// Modifier keys as ShortcutChord bits: Ctrl 1 (⌘), Alt 2 (⌥), Meta 4 (⌃), Shift 8.
static int chordBits(Qt::KeyboardModifiers m) {
    return (m & Qt::ControlModifier ? 1 : 0) | (m & Qt::AltModifier ? 2 : 0) | (m & Qt::MetaModifier ? 4 : 0) | (m & Qt::ShiftModifier ? 8 : 0);
}

static QString workspaceTabTitle(uint64_t handle) {
    const int64_t size = compositor_workspace_tab_title(handle, nullptr, 0);
    if (size <= 0) return {};
    QByteArray bytes(static_cast<int>(size), Qt::Uninitialized);
    if (compositor_workspace_tab_title(handle, reinterpret_cast<uint8_t *>(bytes.data()), bytes.size()) != size) return {};
    return QString::fromUtf8(bytes);
}

static QImage straightRGBA(const std::vector<uint8_t> &premultiplied, int width, int height) {
    // Qt's (SIMD) unpremultiply; convertToFormat always returns an image that owns its pixels.
    return QImage(reinterpret_cast<const uchar *>(premultiplied.data()), width, height, width * 4,
                  QImage::Format_RGBA8888_Premultiplied).convertToFormat(QImage::Format_RGBA8888);
}

static QImage renderToQImage(uint64_t h, int width, int height) {
    PERF_SCOPE("renderToQImage");
    const int bytes = width * height * 4;
    std::vector<uint8_t> rgba(static_cast<size_t>(bytes));
    int64_t n = compositor_session_render(h, rgba.data(), rgba.size());
    if (n == bytes) {
        return straightRGBA(rgba, width, height);
    }
    return QImage();
}

class SessionCanvasWidget : public QWidget {
public:
    explicit SessionCanvasWidget(SessionWindow *window) : QWidget(window), m_window(window) {
        setFocusPolicy(Qt::StrongFocus);
        setMouseTracking(true);
        setAcceptDrops(true);
        setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
    }
protected:
    void paintEvent(QPaintEvent *event) override {
        m_window->canvasPaintEvent(event, this);
    }
    void resizeEvent(QResizeEvent *event) override {
        QWidget::resizeEvent(event);
        m_window->syncViewportGeometry();
        m_window->positionWelcome();
    }
    void mousePressEvent(QMouseEvent *event) override {
        m_window->canvasMousePressEvent(event, this);
    }
    void mouseMoveEvent(QMouseEvent *event) override {
        m_window->canvasMouseMoveEvent(event, this);
    }
    void mouseReleaseEvent(QMouseEvent *event) override {
        m_window->canvasMouseReleaseEvent(event, this);
    }
    void mouseDoubleClickEvent(QMouseEvent *event) override {
        if (!m_window->canvasMouseDoubleClickEvent(event, this)) QWidget::mouseDoubleClickEvent(event);
    }
    void tabletEvent(QTabletEvent *event) override {
        m_window->canvasTabletEvent(event, this);
    }
    void dragEnterEvent(QDragEnterEvent *event) override {
        m_window->canvasDragEnterEvent(event, this);
    }
    void dropEvent(QDropEvent *event) override {
        m_window->canvasDropEvent(event, this);
    }
    void wheelEvent(QWheelEvent *event) override {
        m_window->canvasWheelEvent(event);
    }
private:
    SessionWindow *m_window;
};

/// CanvasRuler.thickness.
static constexpr int kRulerThickness = 18;

/// CanvasRulerCorner: white 0.2 with a 28% diagonal hairline toward the bottom-trailing corner.
class RulerCornerWidget : public QWidget {
public:
    explicit RulerCornerWidget(QWidget *parent) : QWidget(parent) { setFixedSize(kRulerThickness, kRulerThickness); }
protected:
    void paintEvent(QPaintEvent *) override {
        QPainter p(this);
        p.fillRect(rect(), QColor::fromRgbF(0.2, 0.2, 0.2));
        p.setRenderHint(QPainter::Antialiasing, true);
        p.setPen(QPen(QColor(255, 255, 255, 71), 1));
        p.drawLine(QPointF(5, kRulerThickness - 4), QPointF(kRulerThickness - 4, 5));
    }
};

class CanvasRulerWidget : public QWidget {
public:
    CanvasRulerWidget(SessionWindow *window, bool vertical, QWidget *parent) : QWidget(parent), m_window(window), m_vertical(vertical) {
        if (vertical) setFixedWidth(kRulerThickness); else setFixedHeight(kRulerThickness);
        setCursor(vertical ? Qt::SizeHorCursor : Qt::SizeVerCursor);
        setAttribute(Qt::WA_OpaquePaintEvent, true);
    }
protected:
    void paintEvent(QPaintEvent *) override { m_window->paintRuler(this, m_vertical); }
    void mousePressEvent(QMouseEvent *event) override { m_window->rulerMousePress(event, this, m_vertical); }
    void mouseMoveEvent(QMouseEvent *event) override { m_window->rulerMouseMove(event, this); }
    void mouseReleaseEvent(QMouseEvent *event) override { m_window->rulerMouseRelease(event, this); }
private:
    SessionWindow *m_window;
    bool m_vertical;
};

static QIcon makeToolIcon(SessionWindow::Tool tool,
                          SessionWindow::MarqueeMode marqueeMode = SessionWindow::MarqueeMode::Rectangle,
                          SessionWindow::BrushToolMode brushMode = SessionWindow::BrushToolMode::Paint) {
    QPixmap pix(18, 18);
    pix.fill(Qt::transparent);
    QPainter p(&pix);
    p.setRenderHint(QPainter::Antialiasing, true);
    p.setPen(QPen(QColor(0xd0, 0xd0, 0xd5), 1.5, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));

    switch (tool) {
    case SessionWindow::Tool::Move:
        p.drawLine(9, 2, 9, 16);
        p.drawLine(2, 9, 16, 9);
        p.drawLine(9, 2, 6, 5);
        p.drawLine(9, 2, 12, 5);
        p.drawLine(9, 16, 6, 13);
        p.drawLine(9, 16, 12, 13);
        p.drawLine(2, 9, 5, 6);
        p.drawLine(2, 9, 5, 12);
        p.drawLine(16, 9, 13, 6);
        p.drawLine(16, 9, 13, 12);
        break;
    case SessionWindow::Tool::Marquee:
        p.setPen(QPen(QColor(0xd0, 0xd0, 0xd5), 1.5, Qt::DashLine));
        if (marqueeMode == SessionWindow::MarqueeMode::Rectangle) {
            p.drawRect(2, 2, 14, 14);
        } else {
            p.drawEllipse(2, 2, 14, 14);
        }
        break;
    case SessionWindow::Tool::Lasso: {
        QPainterPath path;
        path.moveTo(4, 7);
        path.cubicTo(4, 2, 15, 2, 15, 8);
        path.cubicTo(15, 14, 10, 15, 7, 13);
        path.lineTo(4, 16);
        p.drawPath(path);
        break;
    }
    case SessionWindow::Tool::Magic:
        p.drawLine(3, 15, 13, 5);
        p.drawLine(15, 2, 15, 5);
        p.drawLine(13, 3, 16, 3);
        p.drawLine(11, 2, 11, 3);
        p.drawLine(16, 7, 16, 8);
        break;
    case SessionWindow::Tool::Crop:
        p.drawLine(2, 5, 13, 5);
        p.drawLine(5, 2, 5, 13);
        p.drawLine(5, 13, 16, 13);
        p.drawLine(13, 5, 13, 16);
        break;
    case SessionWindow::Tool::Brush:
        if (brushMode == SessionWindow::BrushToolMode::Paint) {
            p.drawLine(13, 3, 16, 6);
            p.drawLine(13, 3, 9, 8);
            p.drawLine(16, 6, 11, 11);
            p.drawLine(9, 8, 6, 13);
            p.drawLine(11, 11, 6, 13);
            p.setBrush(QColor(0xd0, 0xd0, 0xd5));
            p.drawEllipse(3, 12, 4, 4);
        } else {
            p.drawRoundedRect(3, 5, 12, 8, 2, 2);
            p.drawLine(7, 5, 7, 13);
        }
        break;
    case SessionWindow::Tool::SpotHealing:
        p.save();
        p.translate(9, 9);
        p.rotate(45);
        p.drawRoundedRect(-3, -7, 6, 14, 2, 2);
        p.drawPoint(-1, 0); p.drawPoint(1, 0);
        p.restore();
        break;
    case SessionWindow::Tool::CloneStamp:
        p.drawEllipse(7, 2, 4, 4);
        p.drawLine(9, 6, 9, 10);
        p.drawRoundedRect(4, 10, 10, 4, 1, 1);
        p.fillRect(3, 14, 12, 2, QColor(0xd0, 0xd0, 0xd5));
        break;
    case SessionWindow::Tool::Smear: {
        QPainterPath path;
        path.moveTo(9, 3);
        path.cubicTo(9, 3, 4, 10, 4, 13);
        path.arcTo(4, 8, 10, 10, 180, 180);
        path.cubicTo(14, 10, 9, 3, 9, 3);
        p.drawPath(path);
        break;
    }
    case SessionWindow::Tool::Gradient:
        p.drawRect(2, 2, 14, 14);
        p.fillRect(2, 9, 14, 7, QColor(0xd0, 0xd0, 0xd5));
        break;
    case SessionWindow::Tool::Shape:
        p.drawRect(2, 2, 8, 8);
        p.drawEllipse(7, 7, 9, 9);
        break;
    case SessionWindow::Tool::Type:
        p.drawLine(3, 3, 15, 3);
        p.drawLine(9, 3, 9, 15);
        p.drawLine(6, 15, 12, 15);
        break;
    case SessionWindow::Tool::Eyedropper:
        p.drawLine(4, 14, 6, 12);
        p.drawLine(6, 12, 12, 6);
        p.drawLine(12, 6, 14, 8);
        p.drawLine(14, 8, 8, 14);
        p.drawLine(8, 14, 4, 14);
        p.drawLine(12, 6, 15, 3);
        break;
    case SessionWindow::Tool::Hand:
        p.drawRoundedRect(5, 7, 8, 9, 2, 2);
        p.drawLine(7, 3, 7, 7);
        p.drawLine(9, 2, 9, 7);
        p.drawLine(11, 3, 11, 7);
        break;
    case SessionWindow::Tool::Zoom:
        p.drawEllipse(3, 3, 9, 9);
        p.drawLine(10, 10, 15, 15);
        break;
    case SessionWindow::Tool::Idle:
        break;
    }
    return QIcon(pix);
}

void SessionWindow::initDemoDocument() {
    if (m_sessionHandle == 0) m_sessionHandle = compositor_session_create();
    // emptyLayer: a blank "Layer 1", as upstream's New Canvas sheet creates (createDocument(emptyLayer: true)).
    cmd(m_sessionHandle, R"({"version":1,"action":"new","width":64,"height":64,"emptyLayer":true})");
    cmd(m_sessionHandle, R"({"version":1,"action":"brushBegin","x":8,"y":8,"parameters":{"diameter":16,"hardness":1,"opacity":1,"red":1,"green":0,"blue":0,"erasing":0,"mask":0}})");
    cmd(m_sessionHandle, R"({"version":1,"action":"brushMove","x":48,"y":48})");
    cmd(m_sessionHandle, R"({"version":1,"action":"brushEnd"})");
    m_image = renderToQImage(m_sessionHandle, 64, 64);
    m_hasDocument = true;
    refreshLayers();
}

void SessionWindow::createNewDocument(int width, int height) {
    // emptyLayer: a blank "Layer 1", as upstream's New Canvas sheet creates (createDocument(emptyLayer: true)).
    const QString json = QString(R"({"version":1,"action":"new","width":%1,"height":%2,"emptyLayer":true})").arg(width).arg(height);
    const QByteArray bytes = json.toUtf8();

    if (m_documentTabBar) {
        // Post-construction: every "New" opens its own document tab (a real ProjectWorkspace tab, not just a bare
        // session handle) rather than overwriting the current one.
        const uint64_t handle = compositor_workspace_add_tab();
        compositor_session_command(handle, reinterpret_cast<const uint8_t *>(bytes.constData()), bytes.size());
        addDocumentTab(handle, workspaceTabTitle(handle));
        return;
    }

    // Initial construction: the very first document, created before any tab exists.
    if (m_sessionHandle == 0) m_sessionHandle = compositor_session_create();
    compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(bytes.constData()), bytes.size());
    m_image = renderToQImage(m_sessionHandle, width, height);
    m_hasDocument = true;
    refreshImage();
    refreshLayers();
}

void SessionWindow::addDocumentTab(uint64_t handle, const QString &title, const QString &filePath) {
    m_documents.push_back({handle, title, filePath, 0.0, QPointF(0, 0)});
    const int index = static_cast<int>(m_documents.size()) - 1;
    if (m_documentTabBar) {
        m_documentTabBar->addTab(title);
        // Emits currentChanged(index) -> switchToDocumentTab(index), which does the actual UI refresh.
        m_documentTabBar->setCurrentIndex(index);
    } else {
        // Constructor path: the header bar (and thus the tab bar) doesn't exist yet.
        switchToDocumentTab(index);
    }
}

void SessionWindow::switchToDocumentTab(int index) {
    PERF_SCOPE("switchToDocumentTab");
    if (index < 0 || index >= static_cast<int>(m_documents.size())) return;
    m_activeDocumentIndex = index;
    const DocumentTab &doc = m_documents[index];
    m_sessionHandle = doc.handle;
    m_hasDocument = true;
    syncViewportGeometry();
    refreshImage();
    refreshLayers();
    updateOptionsBar();
    syncPaletteFromSession();   // each document has its own palette; also re-renders the tool rail
    updateStatusTelemetry();
    setWindowTitle(doc.title.isEmpty() ? tr("Compositor") : tr("%1 — Compositor").arg(doc.title));
}

bool SessionWindow::isDocumentModified(uint64_t handle) const {
    if (handle == 0) return false;
    const int64_t size = compositor_session_state(handle, nullptr, 0);
    if (size <= 0 || size > 4 * 1024 * 1024) return false;
    QByteArray bytes(static_cast<qsizetype>(size), Qt::Uninitialized);
    if (compositor_session_state(handle, reinterpret_cast<uint8_t *>(bytes.data()), bytes.size()) != size) return false;
    return QJsonDocument::fromJson(bytes).object().value("modified").toBool(false);
}

bool SessionWindow::saveCurrentDocument(bool forceChoosePath) {
    if (m_activeDocumentIndex < 0 || m_activeDocumentIndex >= static_cast<int>(m_documents.size())) return false;
    const QString known = m_documents[m_activeDocumentIndex].filePath;
    const QString path = (!forceChoosePath && known.endsWith(".comp", Qt::CaseInsensitive))
        ? known : m_platform.files->chooseProjectSavePath();
    if (path.isEmpty()) return false;
    if (!saveProject(path)) {
        m_platform.notifier->warn(tr("Save failed"), tr("Could not save project."));
        return false;
    }
    sendCommand({{"action", "markSaved"}});
    DocumentTab &doc = m_documents[m_activeDocumentIndex];
    doc.filePath = path;
    doc.title = QFileInfo(path).completeBaseName();
    if (m_documentTabBar) m_documentTabBar->setTabText(m_activeDocumentIndex, doc.title);
    setWindowTitle(tr("%1 — Compositor").arg(doc.title));
    return true;
}

bool SessionWindow::confirmDocumentClose(int index) {
    if (index < 0 || index >= static_cast<int>(m_documents.size())) return true;
    if (!isDocumentModified(m_documents[index].handle)) return true;
    if (index != m_activeDocumentIndex) {
        if (m_documentTabBar) m_documentTabBar->setCurrentIndex(index); // currentChanged -> switchToDocumentTab
        if (index != m_activeDocumentIndex) switchToDocumentTab(index);
    }
    const QString name = m_documents[index].filePath.isEmpty()
        ? QStringLiteral("Untitled") : QFileInfo(m_documents[index].filePath).fileName();
    QMessageBox box(this);
    box.setText(tr("Save changes to %1?").arg(name));
    box.setInformativeText(tr("Your changes will be lost if you don’t save them."));
    QPushButton *save = box.addButton(tr("Save"), QMessageBox::AcceptRole);
    box.addButton(tr("Cancel"), QMessageBox::RejectRole);
    QPushButton *discard = box.addButton(tr("Don’t Save"), QMessageBox::DestructiveRole);
    box.setDefaultButton(save);
    box.exec();
    if (box.clickedButton() == save) return saveCurrentDocument(false);
    return box.clickedButton() == discard;
}

void SessionWindow::closeDocumentTab(int index) {
    if (index < 0 || index >= static_cast<int>(m_documents.size())) return;
    // Closing the last tab closes the window rather than letting upstream mint a blank replacement document below;
    // closeEvent() asks about unsaved changes and handles the session teardown.
    if (m_documents.size() == 1) {
        close();
        return;
    }
    if (!confirmDocumentClose(index)) return;
    const uint64_t closedHandle = m_documents[index].handle;
    const bool wasActive = (index == m_activeDocumentIndex);
    m_documents.erase(m_documents.begin() + index);
    if (m_activeDocumentIndex > index) --m_activeDocumentIndex;

    // ProjectWorkspace (upstream's own open-documents model) does the actual close and guarantees at least one
    // tab remains open, minting a fresh one if that was the last; it hands back whichever tab is current after.
    const uint64_t currentHandle = compositor_workspace_close_tab(closedHandle);

    auto existing = std::find_if(m_documents.begin(), m_documents.end(),
        [currentHandle](const DocumentTab &doc) { return doc.handle == currentHandle; });

    int target;
    if (existing != m_documents.end()) {
        target = static_cast<int>(existing - m_documents.begin());
        if (m_documentTabBar) {
            const QSignalBlocker blocker(m_documentTabBar);
            m_documentTabBar->removeTab(index);
        }
    } else {
        // Upstream minted a brand-new replacement tab (the closed one was the last document open).
        m_documents.push_back({currentHandle, workspaceTabTitle(currentHandle), QString(), 0.0, QPointF(0, 0)});
        target = static_cast<int>(m_documents.size()) - 1;
        if (m_documentTabBar) {
            const QSignalBlocker blocker(m_documentTabBar);
            m_documentTabBar->removeTab(index);
            m_documentTabBar->addTab(m_documents[target].title);
        }
    }

    if (m_documentTabBar) m_documentTabBar->setCurrentIndex(target);
    if (wasActive || existing == m_documents.end()) {
        m_activeDocumentIndex = -1; // the active document actually changed: force a real refresh
        switchToDocumentTab(target);
    } else {
        m_activeDocumentIndex = target; // a background tab closed; just re-sync the index, keep the active view
    }
}

SessionWindow::SessionWindow(QWidget *parent, PlatformServices services)
    : QMainWindow(parent), m_platform(services.withDefaults()) {
    setWindowTitle("Compositor");
    // The header bar (setupHeaderBar) already draws its own macOS-style traffic-light close/minimize/maximize
    // buttons, so the native system title bar is pure duplicate chrome — hide it. Window dragging then has to
    // come from somewhere else; the eventFilter installed on m_headerToolBar below provides it.
    setWindowFlag(Qt::FramelessWindowHint, true);
    resize(ParityMetrics::WindowDefaultWidth, ParityMetrics::WindowDefaultHeight);
    setMinimumSize(ParityMetrics::WindowMinWidth, ParityMetrics::WindowMinHeight);
    setAcceptDrops(true);
    m_tabletHandler = std::make_unique<PressureModulatedTabletHandler>();
    applyDarkTheme();

    // Central canvas widget:
    m_canvasWidget = new SessionCanvasWidget(this);
    m_canvasWidget->setObjectName("editorCanvas");
    // canvasPaintEvent fills every pixel (the surround first): nothing behind it needs painting.
    m_canvasWidget->setAttribute(Qt::WA_OpaquePaintEvent, true);
    // ContentView's canvas column: the ruler corner and the top ruler over the left ruler and the canvas (rulers only
    // while View > Show > Rulers is on and there is a document).
    {
        auto *column = new QWidget(this);
        column->setObjectName("canvasColumn");
        auto *grid = new QGridLayout(column);
        grid->setContentsMargins(0, 0, 0, 0);
        grid->setSpacing(0);
        m_rulerCorner = new RulerCornerWidget(column);
        m_rulerH = new CanvasRulerWidget(this, false, column);
        m_rulerV = new CanvasRulerWidget(this, true, column);
        grid->addWidget(m_rulerCorner, 0, 0);
        grid->addWidget(m_rulerH, 0, 1);
        grid->addWidget(m_rulerV, 1, 0);
        grid->addWidget(m_canvasWidget, 1, 1);
        for (QWidget *w : {m_rulerCorner, m_rulerH, m_rulerV}) w->hide();
        setCentralWidget(column);
    }

    m_toolsBar = addToolBar(tr("Tools"));
    m_toolsBar->setObjectName("toolbar.tools");
    m_toolsBar->setMovable(false);
    m_toolsBar->setOrientation(Qt::Vertical);
    m_toolsBar->setFixedWidth(ParityMetrics::ToolRailWidth);
    m_toolsBar->setToolButtonStyle(Qt::ToolButtonIconOnly);
    m_toolsBar->setIconSize(QSize(ParityMetrics::ToolIconNominal, ParityMetrics::ToolIconNominal));
    addToolBar(Qt::LeftToolBarArea, m_toolsBar);
    auto *toolGroup = new QActionGroup(this);
    toolGroup->setExclusive(true);

    auto addToolAct = [&](const QString &title, QKeySequence shortcut, Tool t, const char *objName) {
        auto *act = new QAction(makeToolIcon(t), title, this);
        act->setShortcut(shortcut);
        QString cleanTitle = title;
        cleanTitle.remove('&');
        act->setToolTip(QString("%1 (%2)").arg(cleanTitle).arg(shortcut.toString(QKeySequence::NativeText)));
        act->setObjectName(objName);
        act->setCheckable(true);
        connect(act, &QAction::triggered, this, [this, t] { setTool(t); });
        toolGroup->addAction(act);
        m_toolsBar->addAction(act);
        m_toolActions[t] = act;
        return act;
    };

    auto *actMove = addToolAct(tr("Move / Transform (V)"), QKeySequence(Qt::Key_V), Tool::Move, "tool.move");
    addToolAct(tr("Marquee (M)"), QKeySequence(Qt::Key_M), Tool::Marquee, "tool.marquee");
    addToolAct(tr("Lasso (L)"), QKeySequence(Qt::Key_L), Tool::Lasso, "tool.lasso");
    addToolAct(tr("Magic (W)"), QKeySequence(Qt::Key_W), Tool::Magic, "tool.magic");
    addToolAct(tr("Crop (C)"), QKeySequence(Qt::Key_C), Tool::Crop, "tool.crop");
    addToolAct(tr("Brush (B) · Eraser (E)"), QKeySequence(Qt::Key_B), Tool::Brush, "tool.brush");
    addToolAct(tr("Spot Healing Brush (J)"), QKeySequence(Qt::Key_J), Tool::SpotHealing, "tool.spotHealing");
    addToolAct(tr("Clone Stamp (S)"), QKeySequence(Qt::Key_S), Tool::CloneStamp, "tool.cloneStamp");
    addToolAct(tr("Smear (R)"), QKeySequence(Qt::Key_R), Tool::Smear, "tool.blur");
    addToolAct(tr("Gradient (G)"), QKeySequence(Qt::Key_G), Tool::Gradient, "tool.gradient");
    addToolAct(tr("Shape (U)"), QKeySequence(Qt::Key_U), Tool::Shape, "tool.shape");
    addToolAct(tr("Type (T)"), QKeySequence(Qt::Key_T), Tool::Type, "tool.type");
    addToolAct(tr("Eyedropper (I)"), QKeySequence(Qt::Key_I), Tool::Eyedropper, "tool.eyedropper");
    addToolAct(tr("Hand (H)"), QKeySequence(Qt::Key_H), Tool::Hand, "tool.hand");
    addToolAct(tr("Zoom (Z)"), QKeySequence(Qt::Key_Z), Tool::Zoom, "tool.zoom");

    // Hidden action aliases for compatibility with automated smoke tests looking for older names
    auto addHiddenAlias = [&](const char *name, std::function<void()> slot) {
        auto *act = new QAction(this);
        act->setObjectName(name);
        connect(act, &QAction::triggered, this, slot);
        addAction(act);
    };
    addHiddenAlias("tool.rectSelect", [this] { setMarqueeMode(MarqueeMode::Rectangle); setTool(Tool::Marquee); });
    addHiddenAlias("tool.ellipseSelect", [this] { setMarqueeMode(MarqueeMode::Ellipse); setTool(Tool::Marquee); });
    addHiddenAlias("tool.magicWand", [this] { setMagicMode(MagicMode::Wand); setTool(Tool::Magic); });
    addHiddenAlias("tool.eraser", [this] { setBrushToolMode(BrushToolMode::Erase); setTool(Tool::Brush); });

    auto *paletteWidget = new QWidget(m_toolsBar);
    paletteWidget->setObjectName("palette.controls");
    paletteWidget->setFixedSize(ParityMetrics::PaletteFrameWidth, ParityMetrics::PaletteFrameHeight);

    m_bgColorButton = new QPushButton(paletteWidget);
    m_bgColorButton->setObjectName("palette.background");
    m_bgColorButton->setGeometry(12, 12, ParityMetrics::SwatchSize, ParityMetrics::SwatchSize);
    m_bgColorButton->setStyleSheet(QString("background-color: %1; border: 1.5px solid #ffffff; border-radius: %2px;").arg(m_backgroundColor.name()).arg(ParityMetrics::SwatchCornerRadius));
    m_bgColorButton->setToolTip(tr("Background color (click to change)"));
    connect(m_bgColorButton, &QPushButton::clicked, this, &SessionWindow::pickBackgroundColor);

    m_fgPaletteButton = new QPushButton(paletteWidget);
    m_fgPaletteButton->setObjectName("palette.foreground");
    m_fgPaletteButton->setGeometry(0, 0, ParityMetrics::SwatchSize, ParityMetrics::SwatchSize);
    m_fgPaletteButton->setStyleSheet(QString("background-color: %1; border: 1.5px solid #ffffff; border-radius: %2px;").arg(m_brushColor.name()).arg(ParityMetrics::SwatchCornerRadius));
    m_fgPaletteButton->setToolTip(tr("Foreground color (click to change)"));
    connect(m_fgPaletteButton, &QPushButton::clicked, this, &SessionWindow::pickBrushColor);

    auto *btnSwap = new QToolButton(paletteWidget);
    btnSwap->setGeometry(27, -3, ParityMetrics::SwapIconSize, ParityMetrics::SwapIconSize);
    btnSwap->setAutoRaise(true);
    btnSwap->setText(QString::fromUtf8("⇄"));
    btnSwap->setStyleSheet("color: #f5f5f7; font-size: 10px; font-weight: bold; border: none; padding: 0px;");
    btnSwap->setToolTip(tr("Swap colors (X)"));
    connect(btnSwap, &QToolButton::clicked, this, &SessionWindow::swapPaletteColors);

    auto *btnReset = new QToolButton(paletteWidget);
    btnReset->setGeometry(-1, 27, ParityMetrics::ResetIconSize, ParityMetrics::ResetIconSize);
    btnReset->setAutoRaise(true);
    btnReset->setText(QString::fromUtf8("⟲"));
    btnReset->setStyleSheet("color: #f5f5f7; font-size: 9px; font-weight: bold; border: none; padding: 0px;");
    btnReset->setToolTip(tr("Default black/white (D)"));
    connect(btnReset, &QToolButton::clicked, this, &SessionWindow::resetPaletteColors);

    m_paletteAction = m_toolsBar->addWidget(paletteWidget);

    // Document #1 is upstream's own ProjectWorkspace's initial tab, not a bare session — see addDocumentTab() below.
    m_sessionHandle = compositor_workspace_bootstrap();
    const bool isSmokeTest = qApp && (
        qApp->arguments().contains("--dialog-smoke") ||
        qApp->arguments().contains("--brush-smoke") ||
        qApp->arguments().contains("--layers-smoke") ||
        qApp->arguments().contains("--io-smoke") ||
        qEnvironmentVariableIsSet("COMPOSITOR_DEMO_CANVAS")
    );
    if (isSmokeTest) {
        initDemoDocument();
        setBrushColor(QColor(255, 0, 0));
    } else {
        // Upstream starts with an empty tab: the New Canvas sheet in the canvas (ContentView's welcome), no document.
        setBrushColor(QColor(0, 0, 0));
    }

    actMove->setChecked(true);
    setTool(Tool::Move);

    m_layersDock = new QDockWidget(tr("Layers"), this);
    auto *dock = m_layersDock;
    dock->setObjectName("dock.layers");
    dock->setFeatures(QDockWidget::NoDockWidgetFeatures);
    auto *emptyTitle = new QWidget(dock);
    emptyTitle->setFixedHeight(0);
    emptyTitle->hide();
    dock->setTitleBarWidget(emptyTitle);
    dock->setFixedWidth(ParityMetrics::LayersPanelDefaultWidth);

    m_layersStack = new QStackedWidget(dock);
    m_layersStack->setObjectName("layersStack");

    auto *panel = new QWidget(m_layersStack);
    m_legacyLayersPanel = panel;
    auto *layout = new QVBoxLayout(panel);
    layout->setContentsMargins(8, 8, 8, 8);
    layout->setSpacing(6);

    // Header: "Layers" and layer count
    auto *headerLayout = new QHBoxLayout();
    auto *lblLayersTitle = new QLabel(tr("Layers"), panel);
    lblLayersTitle->setStyleSheet("font-size: 12px; font-weight: 600; color: #ffffff;");
    m_layerCountLabel = new QLabel(tr("1"), panel);
    m_layerCountLabel->setObjectName("layerCount");
    m_layerCountLabel->setStyleSheet("font-size: 11px; color: #707074; font-family: monospace;");
    headerLayout->addWidget(lblLayersTitle);
    headerLayout->addStretch();
    headerLayout->addWidget(m_layerCountLabel);
    layout->addLayout(headerLayout);

    // Appearance Controls: Blend & Opacity
    auto *blendLayout = new QHBoxLayout();
    auto *lblBlend = new QLabel(tr("Blend"), panel);
    lblBlend->setStyleSheet("font-size: 11px; color: #a0a0a5;");
    blendLayout->addWidget(lblBlend);
    m_blend = new QComboBox(panel);
    m_blend->setObjectName("blend.mode");
    for (const QString &mode : blendModes()) m_blend->addItem(mode);
    blendLayout->addWidget(m_blend, 1);
    layout->addLayout(blendLayout);

    auto *opacityLayout = new QHBoxLayout();
    auto *lblOpacity = new QLabel(tr("Opacity"), panel);
    lblOpacity->setStyleSheet("font-size: 11px; color: #a0a0a5;");
    opacityLayout->addWidget(lblOpacity);
    m_opacity = new QSlider(Qt::Horizontal, panel);
    m_opacity->setObjectName("layer.opacity");
    m_opacity->setRange(0, 100);
    m_opacity->setValue(100);
    opacityLayout->addWidget(m_opacity, 1);
    m_opacityLabel = new QLabel(tr("100 %"), panel);
    m_opacityLabel->setFixedWidth(40);
    m_opacityLabel->setAlignment(Qt::AlignRight | Qt::AlignVCenter);
    m_opacityLabel->setStyleSheet("font-size: 11px; color: #d0d0d5;");
    opacityLayout->addWidget(m_opacityLabel);
    layout->addLayout(opacityLayout);

    m_layersView = new QTreeView(panel);
    m_layersView->setObjectName("layers.treeView");
    m_layerModel = new QStandardItemModel(this);
    m_layerModel->setHorizontalHeaderLabels({tr("Layer"), tr("Visible"), tr("Mask")});
    m_layersView->setModel(m_layerModel);
    m_layersView->setSelectionMode(QAbstractItemView::ExtendedSelection);
    m_layersView->setSelectionBehavior(QAbstractItemView::SelectRows);
    m_layersView->setUniformRowHeights(true);
    m_layersView->setAnimated(false);
    m_layersView->setAllColumnsShowFocus(true);
    m_layersView->setRootIsDecorated(false);
    m_layersView->setIndentation(18);
    m_layersView->setHeaderHidden(true);
    m_layersView->setMouseTracking(true);
    m_layersView->setFrameShape(QFrame::NoFrame);
    m_layersView->setItemDelegateForColumn(0, new LayerItemDelegate(m_layersView));
    m_layersView->header()->setStretchLastSection(false);
    m_layersView->header()->setSectionResizeMode(0, QHeaderView::Stretch);
    // Visibility / mask state stays in the model (columns 1-2) but is drawn by
    // the row delegate (eye icon, mask badge) instead of as separate columns.
    m_layersView->setColumnHidden(1, true);
    m_layersView->setColumnHidden(2, true);
    layout->addWidget(m_layersView, 1);

    auto *checksLayout = new QHBoxLayout();
    m_visibleCheck = new QCheckBox(tr("Visible"), panel);
    m_visibleCheck->setObjectName("layer.visible");
    m_visibleCheck->setVisible(false);  // superseded by the eye icon in each row; kept for automation
    m_maskCheck = new QCheckBox(tr("Mask enabled"), panel);
    m_maskCheck->setObjectName("layer.mask");
    checksLayout->addWidget(m_visibleCheck);
    checksLayout->addWidget(m_maskCheck);
    checksLayout->addStretch();
    layout->addLayout(checksLayout);

    // Bottom icon bar: add layer, folder, mask, adjustment, delete.
    auto glyph = [](int kind) {
        QPixmap pm(40, 40);
        pm.fill(Qt::transparent);
        QPainter g(&pm);
        g.setRenderHint(QPainter::Antialiasing, true);
        g.setPen(QPen(QColor(0xb4, 0xb4, 0xba), 2.0, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        g.setBrush(Qt::NoBrush);
        switch (kind) {
        case 0:  // add layer
            g.drawRoundedRect(QRectF(8, 8, 24, 24), 4, 4);
            g.drawLine(20, 14, 20, 26); g.drawLine(14, 20, 26, 20);
            break;
        case 1:  // folder
            g.drawRoundedRect(QRectF(7, 13, 26, 18), 3, 3);
            g.drawLine(8, 13, 8, 10); g.drawLine(8, 10, 16, 10); g.drawLine(16, 10, 19, 13);
            break;
        case 2:  // mask
            g.drawRoundedRect(QRectF(8, 8, 24, 24), 4, 4);
            g.setBrush(QColor(0xb4, 0xb4, 0xba));
            g.drawEllipse(QPointF(20, 20), 6, 6);
            break;
        case 3:  // adjustment
            g.drawEllipse(QPointF(20, 20), 12, 12);
            g.setBrush(QColor(0xb4, 0xb4, 0xba));
            { QPainterPath half; half.moveTo(20, 8); half.arcTo(QRectF(8, 8, 24, 24), 90, -180); half.closeSubpath(); g.drawPath(half); }
            break;
        default:  // trash
            g.drawLine(11, 12, 29, 12); g.drawLine(16, 12, 16, 9); g.drawLine(16, 9, 24, 9); g.drawLine(24, 9, 24, 12);
            g.drawRoundedRect(QRectF(13, 12, 14, 19), 2, 2);
            g.drawLine(18, 17, 18, 26); g.drawLine(22, 17, 22, 26);
            break;
        }
        pm.setDevicePixelRatio(2.0);
        return QIcon(pm.scaled(40, 40));
    };
    auto makeIconButton = [&](int kind, const QString &name, const QString &tip) {
        auto *button = new QToolButton(panel);
        button->setObjectName(name);
        button->setToolTip(tip);
        button->setAccessibleName(tip);
        button->setIcon(glyph(kind));
        button->setIconSize(QSize(20, 20));
        button->setAutoRaise(true);
        button->setFixedSize(30, 28);
        button->setCursor(Qt::PointingHandCursor);
        return button;
    };
    auto *btnLayout = new QHBoxLayout();
    btnLayout->setContentsMargins(0, 4, 0, 0);
    btnLayout->setSpacing(6);
    auto *btnAddLayer = makeIconButton(0, "layer.add", tr("Add blank layer"));
    auto *btnAddGroup = makeIconButton(1, "layer.addGroup", tr("Add new group/folder"));
    auto *btnAddMask = makeIconButton(2, "layer.addMask", tr("Add reveal layer mask"));
    auto *btnAdjustment = makeIconButton(3, "layer.addAdjustment", tr("Add adjustment layer"));
    auto *btnDelete = makeIconButton(4, "layer.delete", tr("Delete active layer or group"));
    auto *adjustmentMenu = new QMenu(btnAdjustment);
    for (const QString &kind : {QString("Hue/Saturation"), QString("Levels"), QString("Curves"),
                                QString("Exposure"), QString("Grain"), QString("Gradient Map")}) {
        adjustmentMenu->addAction(kind, this, [this, kind] { showAdjustDialog(kind); });
    }
    btnAdjustment->setMenu(adjustmentMenu);
    btnAdjustment->setPopupMode(QToolButton::InstantPopup);
    btnLayout->addWidget(btnAddLayer);
    btnLayout->addWidget(btnAddGroup);
    btnLayout->addWidget(btnAddMask);
    btnLayout->addWidget(btnAdjustment);
    btnLayout->addStretch();
    btnLayout->addWidget(btnDelete);
    layout->addLayout(btnLayout);

    connect(btnAddLayer, &QToolButton::clicked, this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"addLayer"})") == 0) { refreshImage(); refreshLayers(); }
    });
    connect(btnAddGroup, &QToolButton::clicked, this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"addGroup"})") == 0) { refreshImage(); refreshLayers(); }
    });
    connect(btnAddMask, &QToolButton::clicked, this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"addRevealMask"})") == 0) { refreshImage(); refreshLayers(); }
    });
    connect(btnDelete, &QToolButton::clicked, this, [this] {
        deleteSelectedLayers();
    });

    m_layersStack->addWidget(panel);

    m_swiftUILayersContainer = new QWidget(m_layersStack);
    m_swiftUILayersContainer->setObjectName("swiftUILayersContainer");
    auto *layoutSwiftUI = new QVBoxLayout(m_swiftUILayersContainer);
    layoutSwiftUI->setContentsMargins(0, 0, 0, 0);
    layoutSwiftUI->setSpacing(0);
    m_layersStack->addWidget(m_swiftUILayersContainer);

    dock->setWidget(m_layersStack);
    addDockWidget(Qt::RightDockWidgetArea, dock);

    // Floating "Adjustments" palette: one row per adjustment, opens its sheet.
    {
        m_adjustmentsDock = new QDockWidget(tr("Adjustments"), this);
        auto *adjDock = m_adjustmentsDock;
        adjDock->setObjectName("dock.adjustments");
        adjDock->setFeatures(QDockWidget::DockWidgetClosable | QDockWidget::DockWidgetFloatable | QDockWidget::DockWidgetMovable);
        auto *body = new QWidget(adjDock);
        auto *rows = new QVBoxLayout(body);
        rows->setContentsMargins(6, 6, 6, 8);
        rows->setSpacing(2);
        auto adjustmentIcon = [](int kind) {
            QPixmap pm(48, 48);
            pm.fill(Qt::transparent);
            QPainter g(&pm);
            g.setRenderHint(QPainter::Antialiasing, true);
            const QColor ink(0xc8, 0xc8, 0xce);
            g.setPen(QPen(ink, 2.2, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
            g.setBrush(Qt::NoBrush);
            switch (kind) {
            case 0:  // Hue/Saturation: half-filled disc
                g.drawEllipse(QPointF(24, 24), 15, 15);
                g.setBrush(ink);
                { QPainterPath half; half.moveTo(24, 9); half.arcTo(QRectF(9, 9, 30, 30), 90, -180); half.closeSubpath(); g.drawPath(half); }
                break;
            case 1:  // Levels: two sliders
                g.drawLine(8, 17, 40, 17); g.drawLine(8, 31, 40, 31);
                g.setBrush(QColor(0x1e, 0x1e, 0x20)); g.drawEllipse(QPointF(29, 17), 4, 4); g.drawEllipse(QPointF(18, 31), 4, 4);
                break;
            case 2:  // Curves
                { QPainterPath c; c.moveTo(8, 40); c.cubicTo(20, 40, 24, 10, 40, 8); g.drawPath(c); g.setBrush(ink); g.drawEllipse(QPointF(8, 40), 3, 3); g.drawEllipse(QPointF(40, 8), 3, 3); }
                break;
            case 3:  // Exposure: plus/minus in a circle
                g.drawEllipse(QPointF(24, 24), 15, 15);
                g.drawLine(24, 15, 24, 25); g.drawLine(19, 20, 29, 20); g.drawLine(19, 31, 29, 31);
                break;
            case 4:  // Grain: dot lattice
                g.setPen(Qt::NoPen); g.setBrush(ink);
                for (int ix = 0; ix < 4; ++ix) for (int iy = 0; iy < 4; ++iy) g.drawEllipse(QPointF(10 + ix * 9.3, 10 + iy * 9.3), 1.8, 1.8);
                break;
            default:  // Gradient Map: palette blob
                g.drawEllipse(QPointF(24, 24), 15, 15);
                g.setPen(Qt::NoPen); g.setBrush(ink);
                g.drawEllipse(QPointF(18, 19), 2.4, 2.4); g.drawEllipse(QPointF(28, 18), 2.4, 2.4);
                g.drawEllipse(QPointF(16, 28), 2.4, 2.4); g.drawEllipse(QPointF(27, 30), 2.4, 2.4);
                break;
            }
            pm.setDevicePixelRatio(2.0);
            return QIcon(pm);
        };
        const QStringList kinds = {"Hue/Saturation", "Levels", "Curves", "Exposure", "Grain", "Gradient Map"};
        for (int i = 0; i < kinds.size(); ++i) {
            const QString kind = kinds.at(i);
            auto *row = new QToolButton(body);
            row->setObjectName("adjustments." + kind);
            row->setText(kind);
            row->setIcon(adjustmentIcon(i));
            row->setIconSize(QSize(24, 24));
            row->setToolButtonStyle(Qt::ToolButtonTextBesideIcon);
            row->setAutoRaise(true);
            row->setCursor(Qt::PointingHandCursor);
            row->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Fixed);
            row->setMinimumHeight(38);
            row->setStyleSheet("QToolButton { text-align: left; padding: 4px 8px; font-size: 13px; color: #e6e6ea; border: none; border-radius: 6px; }"
                               "QToolButton:hover { background: #2c2d31; }");
            connect(row, &QToolButton::clicked, this, [this, kind] { showAdjustDialog(kind); });
            rows->addWidget(row);
        }
        rows->addStretch();
        adjDock->setWidget(body);
        adjDock->setMinimumWidth(220);
        addDockWidget(Qt::RightDockWidgetArea, adjDock);
        adjDock->setFloating(true);
        adjDock->hide();
        QAction *toggle = adjDock->toggleViewAction();
        toggle->setText(tr("Adjustments Panel"));
        toggle->setObjectName("view.adjustmentsPanel");
    }

    connect(m_layersView->selectionModel(), &QItemSelectionModel::currentChanged,
            this, [this](const QModelIndex &current, const QModelIndex &) {
        if (m_syncingLayers || !current.isValid() || m_sessionHandle == 0) return;
        const QModelIndex nameIndex = current.siblingAtColumn(0);
        const QString id = nameIndex.data(Qt::UserRole).toString();
        if (id.isEmpty()) return;
        const QByteArray json = QString(R"({"version":1,"action":"selectLayer","layerID":"%1"})").arg(id).toUtf8();
        if (compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(json.constData()), json.size()) == 0) {
            refreshImage();
        }
    });

    connect(m_layerModel, &QStandardItemModel::itemChanged, this, [this](QStandardItem *item) {
        if (m_syncingLayers || !item || m_sessionHandle == 0) return;
        m_syncingLayers = true;
        if (item->column() == 0) {
            const QString id = item->data(Qt::UserRole).toString();
            const QString newName = item->text();
            if (!id.isEmpty() && !newName.isEmpty()) {
                QJsonObject selectCmd{{"action", "selectLayer"}, {"layerID", id}};
                sendCommand(selectCmd);
                QJsonObject renameCmd{{"action", "renameLayer"}, {"name", newName}};
                if (sendCommand(renameCmd)) refreshImage();
            }
        } else if (item->column() == 1) {
            const QModelIndex nameIndex = m_layerModel->index(item->row(), 0, item->parent() ? item->parent()->index() : QModelIndex());
            const QString id = nameIndex.data(Qt::UserRole).toString();
            const bool visible = (item->checkState() == Qt::Checked);
            if (!id.isEmpty()) {
                QJsonObject selectCmd{{"action", "selectLayer"}, {"layerID", id}};
                sendCommand(selectCmd);
                setLayerFlag("setVisible", visible);
                refreshImage();
            }
        } else if (item->column() == 2) {
            const QModelIndex nameIndex = m_layerModel->index(item->row(), 0, item->parent() ? item->parent()->index() : QModelIndex());
            const QString id = nameIndex.data(Qt::UserRole).toString();
            const bool enabled = (item->checkState() == Qt::Checked);
            if (!id.isEmpty()) {
                QJsonObject selectCmd{{"action", "selectLayer"}, {"layerID", id}};
                sendCommand(selectCmd);
                sendCommand({{"action", "setMaskEnabled"}, {"enabled", enabled}});
                refreshImage();
            }
        }
        m_syncingLayers = false;
    });

    connect(m_opacity, &QSlider::valueChanged, this, &SessionWindow::setOpacityFromSlider);
    connect(m_blend, &QComboBox::currentIndexChanged, this, &SessionWindow::setBlendModeFromCombo);
    connect(m_visibleCheck, &QCheckBox::toggled, this, [this](bool on) { if (setLayerFlag("setVisible", on)) refreshImage(); });
    connect(m_maskCheck, &QCheckBox::toggled, this, [this](bool on) {
        if (sendCommand({{"action", "setMaskEnabled"}, {"enabled", on}})) refreshImage();
    });
    setupHeaderBar();
    setupOptionsBar();
    createMenus();
    installAppMenus();
    refreshLayers();
    updateOptionsBar();
    updateToolRail();
    updateLayersPanel();
    updateStatusTelemetry();

    // Register the document created above (before the tab bar existed) as its own tab now that the whole
    // window is built; every later document goes through addDocumentTab/createNewDocument/loadProject instead.
    addDocumentTab(m_sessionHandle, workspaceTabTitle(m_sessionHandle));

    registerSwiftUIActionListener([this](uint64_t handle, const QString &panel) {
        if (handle != m_sessionHandle) return;
        if (panel == "ToolRail") {
            syncPaletteFromSession();   // swatches, swap/reset and "open the picker" live in the rail
            syncToolFromSession();
            syncOptionsFromSession();
            updateOptionsBar();
            updateLayersPanel();
        } else if (panel == "ToolHeaders") {
            syncTextEditor();           // Done / Cancel in the Type bar, or a style change of the text being typed
            syncPaletteFromSession();   // header swatches (type color, effects) open the picker too
            syncOptionsFromSession();
            updateOptionsBar();
            refreshImage();
        } else if (panel == "LayersPanel") {
            updateLayersPanel();
            refreshLayers();
            refreshImage();
            updateFloatingPanels();   // the fx menu opens the effect's panel
        } else if (panel == "Welcome") {
            handleSessionFileRequests();
            refreshImage();
            refreshLayers();
            updateLayersPanel();
            updateToolRail();
        } else if (m_floatingPanels.contains(panel)) {
            refreshImage();           // effect changes preview on the canvas
            refreshLayers();
            updateFloatingPanels();
        }
    });

    m_autosaveTimer = new QTimer(this);
    m_autosaveTimer->setObjectName("autosaveTimer");
    m_autosaveTimer->setInterval(60000);
    connect(m_autosaveTimer, &QTimer::timeout, this, [this] { performAutosave(); compositor_flush_preferences(); });
    connect(qApp, &QCoreApplication::aboutToQuit, this, [] { compositor_flush_preferences(); });
    m_autosaveTimer->start();

    // SF Symbols upstream draws (cursor pictures, icons in bitmaps) come from the shell's Lucide set.
    compositor_set_symbol_renderer([](const char *name, int32_t width, int32_t height, double r, double g, double b, double a,
                                      uint8_t *output) -> int32_t {
        const QByteArray svg = lucideIconSVG(QString::fromUtf8(name));
        if (svg.isEmpty() || !output || width <= 0 || height <= 0) return -1;
        QImage image(width, height, QImage::Format_RGBA8888_Premultiplied);
        image.fill(Qt::transparent);
        QByteArray tinted = svg;
        tinted.replace("currentColor", QColor::fromRgbF(r, g, b).name(QColor::HexRgb).toLatin1());
        QPainter painter(&image);
        painter.setOpacity(a);
        QSvgRenderer(tinted).render(&painter, QRectF(0, 0, width, height));
        painter.end();
        for (int y = 0; y < height; ++y) std::memcpy(output + size_t(y) * width * 4, image.constScanLine(y), size_t(width) * 4);
        return 0;
    });

    // Upstream sheets that open mid-command (RAW Develop during an import) are shown by the shell.
    compositor_set_sheet_presenter([](void *context, const char *panel) {
        static_cast<SessionWindow *>(context)->presentSwiftUISheet(QString::fromUtf8(panel));
    }, this);

    // Long commands (RAW develop, big Photoshop files) keep the window painting, with a busy cursor and a status line.
    compositor_set_wait_pump([](void *context) { static_cast<SessionWindow *>(context)->pumpWhileBusy(); }, this);

    // Swift's main queue has no other pump under Qt's event loop: upstream async work started from a panel
    // (previews, Task {} in button actions) runs here, and whatever it changed shows.
    m_mainPumpTimer = new QTimer(this);
    m_mainPumpTimer->setInterval(16);
    connect(m_mainPumpTimer, &QTimer::timeout, this, [this] {
        compositor_pump_main();
        if (m_sessionHandle == 0 || m_painting) return;
        updateInvalidOverlay();   // upstream's timers (the marching ants) redraw what they invalidated
        // Floating panels whose view changes without the session state changing (a histogram computed in a Task).
        if (!m_floatingPanels.isEmpty() && ++m_panelPollTick % 6 == 0) updateFloatingPanels();
        // Menu items whose upstream action is a Task (Canvas Size…, Save, ...) ask the shell once that task runs.
        if (!m_handlingShellRequests) {
            m_handlingShellRequests = true;
            handleShellRequests();
            m_handlingShellRequests = false;
        }
        const int64_t size = compositor_session_state(m_sessionHandle, nullptr, 0);
        if (size <= 0 || size > 4 * 1024 * 1024) return;
        QByteArray bytes(qsizetype(size), Qt::Uninitialized);
        if (compositor_session_state(m_sessionHandle, reinterpret_cast<uint8_t *>(bytes.data()), bytes.size()) != size) return;
        if (bytes == m_pumpedState) return;
        const bool first = m_pumpedState.isEmpty();
        m_pumpedState = bytes;
        if (!first) { refreshImage(); updateToolRail(); }
        updateFloatingPanels();
        showSessionAlert();
        applyShortcutSettings();
        const bool wasDistorting = !m_distortCorners.isEmpty();
        syncDistortFromSession();
        if (wasDistorting != !m_distortCorners.isEmpty() && m_canvasWidget) m_canvasWidget->update();
    });
    m_mainPumpTimer->start();
}

// ShortcutChord's form (see Sources/Overrides/KeyboardShortcuts.swift): one lowercase key ("\x7f" Delete, "\r", "\x1b",
// "\t", " ", U+F700-F703 arrows) and modifier bits Command 1 / Option 2 / Control 4 / Shift 8 — Ctrl / Alt / Meta / Shift.
SessionWindow::CanvasChord SessionWindow::chordFromKeyEvent(const QKeyEvent *event) {
    const int k = event->key();
    QString key;
    switch (k) {
    case Qt::Key_Backspace: case Qt::Key_Delete: key = QStringLiteral("\x7f"); break;
    case Qt::Key_Return: case Qt::Key_Enter: key = QStringLiteral("\r"); break;
    case Qt::Key_Escape: key = QStringLiteral("\x1b"); break;
    case Qt::Key_Tab: case Qt::Key_Backtab: key = QStringLiteral("\t"); break;
    case Qt::Key_Space: key = QStringLiteral(" "); break;
    case Qt::Key_Left: key = QString(QChar(0xf702)); break;
    case Qt::Key_Right: key = QString(QChar(0xf703)); break;
    case Qt::Key_Down: key = QString(QChar(0xf701)); break;
    case Qt::Key_Up: key = QString(QChar(0xf700)); break;
    default: {
        const QString typed = (k >= 0x20 && k < 0x7f) ? QString(QChar(k)).toLower() : event->text().toLower();
        static const QHash<QString, QString> unshift{{"{", "["}, {"}", "]"}, {"+", "="}, {"_", "-"}};
        key = unshift.value(typed, typed);
    }
    }
    const Qt::KeyboardModifiers m = event->modifiers();
    return {key, (m & Qt::ControlModifier ? 1 : 0) | (m & Qt::AltModifier ? 2 : 0) | (m & Qt::MetaModifier ? 4 : 0) | (m & Qt::ShiftModifier ? 8 : 0)};
}

int SessionWindow::qtKeyForChord(const QString &key) {
    static const QHash<QString, int> special{{"\x7f", Qt::Key_Backspace}, {"\r", Qt::Key_Return}, {"\x1b", Qt::Key_Escape},
        {"\t", Qt::Key_Tab}, {" ", Qt::Key_Space}, {QString(QChar(0xf702)), Qt::Key_Left}, {QString(QChar(0xf703)), Qt::Key_Right},
        {QString(QChar(0xf701)), Qt::Key_Down}, {QString(QChar(0xf700)), Qt::Key_Up}};
    if (auto it = special.constFind(key); it != special.constEnd()) return *it;
    return key.isEmpty() ? 0 : int(key.toUpper()[0].unicode());
}

Qt::KeyboardModifiers SessionWindow::modifiersForChord(int bits) {
    Qt::KeyboardModifiers m;
    if (bits & 1) m |= Qt::ControlModifier;
    if (bits & 2) m |= Qt::AltModifier;
    if (bits & 4) m |= Qt::MetaModifier;
    if (bits & 8) m |= Qt::ShiftModifier;
    return m;
}

void SessionWindow::applyShortcutSettings() {
    if (m_sessionHandle == 0) return;
    const QJsonArray shortcuts = sessionState().value("shortcuts").toArray();
    const QByteArray applied = QJsonDocument(shortcuts).toJson(QJsonDocument::Compact);
    if (applied == m_appliedShortcuts) return;
    m_appliedShortcuts = applied;
    // Upstream's menu titles for the shell's menu items.
    static const QHash<QString, QString> menuText{
        {"New Canvas", "New Canvas…"}, {"Open Project", "Open Project…"}, {"Save As", "Save As…"}, {"Export PNG", "Export PNG…"},
        {"Export JPEG", "Export JPEG…"}, {"Fill with Foreground", "Fill with Foreground Color"},
        {"Fill with Background", "Fill with Background Color"}, {"Content-Aware Fill", "Content-Aware Fill…"},
        {"Select All", "All"}, {"Inverse Selection", "Inverse"}, {"Select Subject", "Subject"}, {"Curves", "Curves…"},
        {"Levels", "Levels…"}, {"Hue/Saturation", "Hue/Saturation…"}, {"Invert Pixels / Mask", "Invert"},
        {"Canvas Size", "Canvas Size…"}, {"Image Size", "Image Size…"}, {"Transform Layer / Selection", "Transform Layer"},
        {"Duplicate / Layer via Copy", "Duplicate Layer"}, {"Toggle Clipping Mask", "Create Clipping Mask"},
        {"Group Layers", "Group Selected Layers"}, {"Merge Layers", "Merge Down"}, {"Show Grid", "Grid"},
        {"Show Guides", "Guides"}, {"Show Rulers", "Rulers"}};
    auto sequence = [](const QString &key, int bits) {
        static const QHash<QString, QString> names{{"\x7f", "Backspace"}, {"\r", "Return"}, {"\x1b", "Esc"}, {"\t", "Tab"},
            {" ", "Space"}, {QString(QChar(0xf702)), "Left"}, {QString(QChar(0xf703)), "Right"}, {QString(QChar(0xf701)), "Down"},
            {QString(QChar(0xf700)), "Up"}};
        QString text = (bits & 1 ? "Ctrl+" : "") + QString(bits & 2 ? "Alt+" : "") + QString(bits & 4 ? "Meta+" : "")
                     + QString(bits & 8 ? "Shift+" : "") + names.value(key, key.toUpper());
        return QKeySequence::fromString(text, QKeySequence::PortableText);
    };
    const QList<QAction *> actions = findChildren<QAction *>();
    m_canvasRemap.clear();
    m_canvasBlocked.clear();
    QList<CanvasChord> assignedCanvas;
    for (const QJsonValue &value : shortcuts) {
        const QJsonObject o = value.toObject();
        const CanvasChord now{o.value("key").toString(), o.value("modifiers").toInt()};
        const CanvasChord original{o.value("originalKey").toString(), o.value("originalModifiers").toInt()};
        const QString group = o.value("group").toString();
        if (group == QLatin1String("Menus") && !m_appMenuActions.isEmpty()) {
            continue;   // the menu bar is upstream's own (syncAppMenus): its items carry their configured chords
        } else if (group == QLatin1String("Menus")) {
            const QString text = menuText.value(o.value("title").toString(), o.value("title").toString());
            // The item that carries this shortcut (a title can appear in two menus: the one with a shortcut of its own).
            QAction *target = nullptr;
            for (QAction *action : actions) {
                if (action->text() != text) continue;
                if (!target || (!action->shortcuts().isEmpty() && target->shortcuts().isEmpty())) target = action;
            }
            if (!target) continue;
            if (!m_defaultShortcuts.contains(target)) m_defaultShortcuts.insert(target, target->shortcuts());
            if (now == original) target->setShortcuts(m_defaultShortcuts.value(target));   // back to its own default
            else target->setShortcut(sequence(now.key, now.modifiers));
        } else if (group == QLatin1String("Canvas & Layers")) {
            assignedCanvas << now;
            if (!(now == original)) m_canvasRemap.append({now, original});
        }
    }
    // An original chord reassigned to something else, and not now used by another shortcut, does nothing.
    for (const auto &[now, original] : m_canvasRemap)
        if (!assignedCanvas.contains(original)) m_canvasBlocked << original;
}

/// Upstream's alerts ("Couldn’t paint", "Couldn’t crop"): shown when the session raises one, OK clears it.
void SessionWindow::showSessionAlert() {
    if (m_showingAlert || m_sessionHandle == 0) return;
    const QJsonObject alert = sessionState().value("alert").toObject();
    if (alert.isEmpty()) return;
    m_showingAlert = true;
    statusBar()->clearMessage();
    QMessageBox box(this);
    box.setIcon(QMessageBox::Warning);
    box.setText(alert.value("title").toString());
    box.setInformativeText(alert.value("message").toString());
    box.addButton(tr("OK"), QMessageBox::AcceptRole);
    if (!qEnvironmentVariableIsSet("COMPOSITOR_AUTO_CONFIRM_IMPORT")) box.exec();
    sendCommandQuiet({{"action", "dismissAlert"}, {"kind", alert.value("kind").toString()}});
    m_showingAlert = false;
}

/// SwiftUI's Text in a sheet: wraps to the width its column gives it (not its one-line width).
static void wrapText(QLabel *label) {
    label->setWordWrap(true);
    label->setSizePolicy(QSizePolicy::Expanding, label->sizePolicy().verticalPolicy());
    if (QWidget *parent = label->parentWidget(); parent && parent->layout()) parent->layout()->setAlignment(label, Qt::Alignment());
}

/// ContentView's `welcome`: while the tab has no document, upstream's New Canvas sheet sits in the middle of the canvas
/// (a ZStack over EditorCanvas), at most 500 wide.
void SessionWindow::updateWelcome() {
    if (!m_canvasWidget || m_sessionHandle == 0) return;
    QWidget *next = swiftUIRenderPanelIfChanged(m_sessionHandle, QStringLiteral("Welcome"), m_welcomeContent);
    if (next != m_welcomeContent) {
        if (m_welcomeContent) retireRenderedPanel(m_welcomeContent);
        m_welcomeContent = next;
        if (next) {
            next->setParent(m_canvasWidget);
            next->setObjectName("welcome");
            for (QLabel *label : next->findChildren<QLabel *>())
                if (label->text().size() > 40 && label->text().contains(QLatin1Char(' '))) wrapText(label);
        }
    }
    if (!m_welcomeContent) return;
    positionWelcome();
    m_welcomeContent->show();
    m_welcomeContent->raise();
}

void SessionWindow::positionWelcome() {
    if (!m_welcomeContent || !m_canvasWidget) return;
    const int width = qMin(500, m_canvasWidget->width());
    const int height = qMin(m_welcomeContent->heightForWidth(width) > 0 ? m_welcomeContent->heightForWidth(width)
                                                                        : m_welcomeContent->sizeHint().height(),
                            m_canvasWidget->height());
    m_welcomeContent->setGeometry((m_canvasWidget->width() - width) / 2, (m_canvasWidget->height() - height) / 2, width, height);
}

/// Upstream's `.fileImporter(isPresented: $session.showsImporter)` (the welcome's Import image, File > Import) and the
/// welcome's Open project (`projects.open()`), answered with the shell's choosers.
void SessionWindow::handleSessionFileRequests() {
    if (m_sessionHandle == 0 || m_handlingFileRequests) return;
    const QJsonObject state = sessionState();
    const bool importer = state.value("showsImporter").toBool(), openProject = state.value("openProjectRequested").toBool();
    if (!importer && !openProject) return;
    m_handlingFileRequests = true;
    sendCommandQuiet({{"action", "dismissImporter"}});
    if (openProject) {
        for (QAction *action : findChildren<QAction *>())
            if (action->objectName() == QLatin1String("file.openProject")) { action->trigger(); break; }
    } else {
        const QStringList paths = m_platform.files->chooseImagesToImport();
        if (!paths.isEmpty()) importWithUpstream(paths, false);
    }
    m_handlingFileRequests = false;
    refreshImage();
    refreshLayers();
}

/// The floating panels the session wants (state "floatingPanels": panel + title), as upstream's ContentView shows them
/// in NSPanels: non-modal tool windows beside the canvas, re-rendered as the session changes. Closing one runs the
/// panel's cancel (closeFloatingPanel); one the session no longer lists closes.
void SessionWindow::updateFloatingPanels() {
    if (m_sessionHandle == 0) return;
    // Not re-entrant: closing or rebuilding a panel moves focus, and a field losing it notifies the listeners, which
    // land here again. A nested call only asks for another pass once this one is done.
    if (m_updatingFloatingPanels) { m_floatingPanelsDirty = true; return; }
    m_updatingFloatingPanels = true;
    do {
        m_floatingPanelsDirty = false;
        updateFloatingPanelsPass();
    } while (m_floatingPanelsDirty);
    m_updatingFloatingPanels = false;
}

void SessionWindow::updateFloatingPanelsPass() {
    QHash<QString, QString> wanted;
    for (const QJsonValue &v : sessionState().value("floatingPanels").toArray()) {
        const QJsonObject o = v.toObject();
        wanted.insert(o.value("panel").toString(), o.value("title").toString());
    }
    // Closed ones leave the table first; their windows go after, when nothing refers to the table's entries.
    QList<QPointer<QDialog>> closing;
    for (auto it = m_floatingPanels.begin(); it != m_floatingPanels.end();) {
        if (wanted.contains(it.key()) && it->window) { ++it; continue; }
        if (it->window) closing << it->window;
        it = m_floatingPanels.erase(it);
    }
    for (const QPointer<QDialog> &window : closing) {
        if (!window) continue;
        window->setProperty("closingFromSession", true);
        window->close();
        window->deleteLater();
    }
    for (auto it = wanted.cbegin(); it != wanted.cend(); ++it) {
        const QString panel = it.key();
        if (!m_floatingPanels.contains(panel)) m_floatingPanels.insert(panel, FloatingPanelWindow());
        FloatingPanelWindow entry = m_floatingPanels.value(panel);
        if (!entry.window) {
            auto *window = new QDialog(this, Qt::Tool);
            window->setObjectName("floatingPanel." + panel);
            window->setAttribute(Qt::WA_DeleteOnClose, false);
            window->setModal(false);
            auto *layout = new QVBoxLayout(window);
            layout->setContentsMargins(0, 0, 0, 0);
            layout->setSizeConstraint(QLayout::SetFixedSize);   // sized by the upstream view, as NSPanel fits its content
            // The window's close button is the panel's: upstream's onClose (e.g. cancel the effect edit).
            connect(window, &QDialog::finished, this, [this, panel, window] {
                if (window->property("closingFromSession").toBool()) return;
                sendCommandQuiet({{"action", "closeFloatingPanel"}, {"kind", panel}});
                refreshImage();
                refreshLayers();
                updateFloatingPanels();
            });
            entry.window = window;
            entry.content = nullptr;
            // Beside the canvas's top-right, left of the Layers panel (upstream's automatic placement).
            const QPoint anchor = mapToGlobal(QPoint(width() - 340 - 280, 120));
            window->move(anchor);
        }
        if (entry.title != it.value()) { entry.title = it.value(); entry.window->setWindowTitle(it.value()); }
        QWidget *next = swiftUIRenderPanelIfChanged(m_sessionHandle, panel, entry.content);
        if (next && next != entry.content) {
            if (entry.content) { entry.window->layout()->removeWidget(entry.content); retireRenderedPanel(entry.content); }
            // A panel's sentences wrap to its width, as SwiftUI's Text does (as in the modal sheets).
            for (QLabel *label : next->findChildren<QLabel *>())
                if (label->text().size() > 40 && label->text().contains(QLatin1Char(' '))) wrapText(label);
            entry.content = next;
            entry.window->layout()->addWidget(next);
            next->show();
        }
        if (!entry.window->isVisible()) entry.window->show();
        m_floatingPanels.insert(panel, entry);
    }
}

/// Shows an upstream SwiftUI sheet panel (RAW Develop) modally, the way the macOS app shows it as a sheet: rendered
/// and re-rendered from the session, its buttons calling upstream's own code, closed when upstream closes it.
void SessionWindow::presentSwiftUISheet(const QString &panel) {
    if (m_sessionHandle == 0) return;
    const uint64_t handle = m_sessionHandle;
    QDialog dialog(this);
    dialog.setWindowTitle(panel == QLatin1String("PSDConversionSheet") ? tr("Import Photoshop File")
                          : panel == QLatin1String("TrimSheet") ? tr("Trim")
                          : panel == QLatin1String("CanvasSizeSheet") ? tr("Canvas Size")
                          : panel == QLatin1String("ImageSizeSheet") ? tr("Image Size")
                          : panel == QLatin1String("JPEGExportSheet") ? tr("Export JPEG") : tr("Develop"));
    auto *layout = new QVBoxLayout(&dialog);
    layout->setContentsMargins(0, 0, 0, 0);
    QWidget *current = nullptr;
    auto render = [&] {
        QWidget *next = swiftUIRenderPanelIfChanged(handle, panel, current);
        if (next && next != current) {
            if (current) { layout->removeWidget(current); retireRenderedPanel(current); }
            // A sheet's sentences wrap to its width, as SwiftUI's Text does (the bars keep one line).
            for (QLabel *label : next->findChildren<QLabel *>())
                if (label->text().size() > 40 && label->text().contains(QLatin1Char(' '))) wrapText(label);
            current = next;
            layout->addWidget(current);
            current->show();
        }
    };
    auto isOpen = [&] { return sessionState().value("sheets").toArray().contains(panel); };
    render();
    if (!current) { compositor_session_raw_develop_cancel(handle); return; }
    QTimer tick;
    tick.setInterval(16);
    QObject::connect(&tick, &QTimer::timeout, &dialog, [&] {
        compositor_pump_main();   // the sheet's preview task runs on the main queue
        if (!isOpen()) { dialog.accept(); return; }
        render();
    });
    tick.start();
    // Headless runs: let the preview develop (or the file be read), keep a picture of the sheet, then press its own
    // Import button once it is enabled.
    QTimer confirm;
    // COMPOSITOR_AUTO_CONFIRM=<button title> presses another sheet's confirm button (e.g. Trim's).
    const QString confirmTitle = qEnvironmentVariableIsSet("COMPOSITOR_AUTO_CONFIRM") ? qEnvironmentVariable("COMPOSITOR_AUTO_CONFIRM")
                                                                                    : QStringLiteral("Import");
    if (qEnvironmentVariableIsSet("COMPOSITOR_AUTO_CONFIRM_IMPORT") || qEnvironmentVariableIsSet("COMPOSITOR_AUTO_CONFIRM")) {
        confirm.setInterval(250);
        QObject::connect(&confirm, &QTimer::timeout, &dialog, [&, started = QDateTime::currentMSecsSinceEpoch()] {
            if (QDateTime::currentMSecsSinceEpoch() - started < 2500) return;
            render();
            for (QPushButton *button : dialog.findChildren<QPushButton *>()) {
                if (button->text() != confirmTitle || !button->isEnabled()) continue;
                if (!qEnvironmentVariable("COMPOSITOR_GRAB_PATH").isEmpty())
                    dialog.grab().save(qEnvironmentVariable("COMPOSITOR_GRAB_PATH") + ".sheet.png");
                confirm.stop();
                button->click();
                break;
            }
        });
        confirm.start();
    }
    if (dialog.exec() != QDialog::Accepted && isOpen()) compositor_session_raw_develop_cancel(handle);
    tick.stop();
    if (current) retireRenderedPanel(current);
}

SessionWindow::~SessionWindow() {
    // Floating panels first, while this window's members still exist: a panel losing focus as it goes (its search
    // field) notifies the listeners, which look the panel up here.
    const auto panels = m_floatingPanels;
    m_floatingPanels.clear();
    for (const FloatingPanelWindow &entry : panels) {
        if (!entry.window) continue;
        entry.window->setProperty("closingFromSession", true);
        delete entry.window.data();
    }
    for (const DocumentTab &doc : m_documents) {
        if (doc.handle != 0) compositor_session_close(doc.handle);
    }
}

bool SessionWindow::eventFilter(QObject *watched, QEvent *event) {
    if (watched == m_textEditor && event->type() == QEvent::KeyPress) {
        auto *key = static_cast<QKeyEvent *>(event);
        const bool apply = (key->key() == Qt::Key_Return || key->key() == Qt::Key_Enter) && (key->modifiers() & Qt::ControlModifier);
        if (key->key() == Qt::Key_Escape || apply) {   // Esc cancels, Ctrl+Return applies (Cmd+Return on macOS)
            sendCommandQuiet({{"action", apply ? "textFinish" : "textCancel"}});
            syncTextEditor();
            refreshImage();
            refreshLayers();
            if (m_canvasWidget) m_canvasWidget->setFocus();
            return true;
        }
    }
    const bool isMenuBar = watched == menuBar();
    if (watched == m_headerToolBar || isMenuBar || watched->objectName() == QLatin1String("header.dragArea")) {
        auto *mouseEvent = event->type() == QEvent::MouseButtonPress || event->type() == QEvent::MouseButtonDblClick
            ? static_cast<QMouseEvent *>(event) : nullptr;
        // On the menu bar only the empty area drags; presses on a menu title must still open it.
        if (mouseEvent && isMenuBar && menuBar()->actionAt(mouseEvent->position().toPoint())) {
            return QMainWindow::eventFilter(watched, event);
        }
        if (event->type() == QEvent::MouseButtonPress) {
            if (mouseEvent->button() == Qt::LeftButton) {
                if (QWindow *handle = windowHandle()) {
                    handle->startSystemMove();
                    return true;
                }
            }
        } else if (event->type() == QEvent::MouseButtonDblClick) {
            if (mouseEvent->button() == Qt::LeftButton) {
                if (isMaximized()) showNormal(); else showMaximized();
                return true;
            }
        }
    }
    return QMainWindow::eventFilter(watched, event);
}

void SessionWindow::setMarqueeMode(MarqueeMode mode) {
    m_marqueeMode = mode;
    if (m_toolActions.contains(Tool::Marquee)) {
        m_toolActions[Tool::Marquee]->setIcon(makeToolIcon(Tool::Marquee, m_marqueeMode, m_brushToolMode));
        m_toolActions[Tool::Marquee]->setToolTip(mode == MarqueeMode::Rectangle
            ? tr("Rectangular Marquee (M)") : tr("Elliptical Marquee (M)"));
    }
    updateOptionsBar();
}

void SessionWindow::cycleMarqueeMode() {
    setMarqueeMode(m_marqueeMode == MarqueeMode::Rectangle ? MarqueeMode::Ellipse : MarqueeMode::Rectangle);
}

void SessionWindow::setLassoMode(LassoMode mode) {
    m_lassoMode = mode;
    m_polygonalLasso = (mode == LassoMode::Polygonal);
    if (m_toolActions.contains(Tool::Lasso)) {
        m_toolActions[Tool::Lasso]->setToolTip(mode == LassoMode::Freehand
            ? tr("Lasso (L)") : tr("Polygonal Lasso (L)"));
    }
    updateOptionsBar();
}

void SessionWindow::cycleLassoMode() {
    setLassoMode(m_lassoMode == LassoMode::Freehand ? LassoMode::Polygonal : LassoMode::Freehand);
}

void SessionWindow::setMagicMode(MagicMode mode) {
    m_magicMode = mode;
    if (m_toolActions.contains(Tool::Magic)) {
        m_toolActions[Tool::Magic]->setToolTip(mode == MagicMode::Wand
            ? tr("Magic Wand (W)") : tr("Magic Object (W)"));
    }
    updateOptionsBar();
}

void SessionWindow::toggleMagicMode() {
    setMagicMode(m_magicMode == MagicMode::Wand ? MagicMode::Object : MagicMode::Wand);
}

void SessionWindow::setBrushToolMode(BrushToolMode mode) {
    m_brushToolMode = mode;
    m_brushMode = (mode == BrushToolMode::Erase) ? "Erase" : "Paint";
    if (m_toolActions.contains(Tool::Brush)) {
        m_toolActions[Tool::Brush]->setIcon(makeToolIcon(Tool::Brush, m_marqueeMode, m_brushToolMode));
        m_toolActions[Tool::Brush]->setToolTip(mode == BrushToolMode::Erase
            ? tr("Eraser (E)") : tr("Brush (B) · Eraser (E)"));
    }
    updateOptionsBar();
}

void SessionWindow::setSmearMode(SmearMode mode) {
    m_smearMode = mode;
    updateOptionsBar();
}

void SessionWindow::setSpotHealingMode(SpotHealingMode mode) {
    m_spotHealingMode = mode;
    updateOptionsBar();
}

void SessionWindow::setShapeMode(ShapeMode mode) {
    m_shapeMode = mode;
    updateOptionsBar();
}

void SessionWindow::cycleShapeMode() {
    switch (m_shapeMode) {
    case ShapeMode::Rectangle: setShapeMode(ShapeMode::Ellipse); break;
    case ShapeMode::Ellipse: setShapeMode(ShapeMode::Line); break;
    case ShapeMode::Line: setShapeMode(ShapeMode::Rectangle); break;
    }
}

void SessionWindow::applyCrop() {
    if (!m_hasPendingCrop) return;
    const double x = std::max(0.0, m_pendingCropRect.x());
    const double y = std::max(0.0, m_pendingCropRect.y());
    const int w = qRound(m_pendingCropRect.width());
    const int h = qRound(m_pendingCropRect.height());
    if (w > 0 && h > 0) {
        const QString json = QString(R"({"version":1,"action":"cropCanvas","x":%1,"y":%2,"width":%3,"height":%4})")
            .arg(x, 0, 'f', 2).arg(y, 0, 'f', 2).arg(w).arg(h);
        const QByteArray bytes = json.toUtf8();
        if (compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(bytes.constData()), bytes.size()) == 0) {
            refreshImage();
        }
    }
    m_hasPendingCrop = false;
    m_pendingCropRect = QRectF();
    if (m_canvasWidget) m_canvasWidget->update();
}

void SessionWindow::cancelCrop() {
    m_hasPendingCrop = false;
    m_pendingCropRect = QRectF();
    if (m_canvasWidget) m_canvasWidget->update();
}

void SessionWindow::swapPaletteColors() {
    sendCommand({{"action", "swapPaletteColors"}});
    syncPaletteFromSession();
}

void SessionWindow::resetPaletteColors() {
    sendCommand({{"action", "resetPaletteColors"}});
    syncPaletteFromSession();
}

void SessionWindow::setBackgroundColor(const QColor &color) { sendPaletteColor(color, true); }

void SessionWindow::sendPaletteColor(const QColor &color, bool background) {
    (background ? m_backgroundColor : m_brushColor) = color;   // kept even without a session (startup)
    if (m_sessionHandle == 0) return;
    sendCommand({{"action", "setPaletteColor"}, {"kind", background ? "background" : "foreground"},
                 {"parameters", QJsonObject{{"red", color.redF()}, {"green", color.greenF()}, {"blue", color.blueF()}}}});
    syncPaletteFromSession();
}

void SessionWindow::syncPaletteFromSession() {
    PERF_SCOPE("syncPaletteFromSession");
    if (m_sessionHandle != 0) {
        const QJsonObject state = sessionState();
        auto colorOf = [](const QJsonValue &v, const QColor &fallback) {
            const QJsonArray a = v.toArray();
            return a.size() == 3 ? QColor::fromRgbF(a[0].toDouble(), a[1].toDouble(), a[2].toDouble()) : fallback;
        };
        m_brushColor = colorOf(state.value("foregroundColor"), m_brushColor);
        m_backgroundColor = colorOf(state.value("backgroundColor"), m_backgroundColor);
        // Upstream's ColorPickerSheet floats beside the canvas (FloatingPanels); the canvas samples into it.
        m_colorPickerOpen = !state.value("colorPickerTitle").toString().isEmpty();
        if (m_colorPickerOpen) QTimer::singleShot(0, this, [this] { updateFloatingPanels(); });
    }
    const QString swatch("background-color: %1; border: 1.5px solid #ffffff; border-radius: %2px;");
    if (m_fgPaletteButton) m_fgPaletteButton->setStyleSheet(swatch.arg(m_brushColor.name()).arg(ParityMetrics::SwatchCornerRadius));
    if (m_bgColorButton) m_bgColorButton->setStyleSheet(swatch.arg(m_backgroundColor.name()).arg(ParityMetrics::SwatchCornerRadius));
    if (m_brushColorButton) {
        m_brushColorButton->setText(QString());
        m_brushColorButton->setStyleSheet(QString("background-color: %1; border: 1px solid #101012; border-radius: 3px;").arg(m_brushColor.name()));
    }
    updateToolRail();   // the SwiftUI rail's swatches are drawn from the session: re-render them
}


void SessionWindow::pickBackgroundColor() {
    const QColor color = m_platform.colors ? m_platform.colors->pick(m_backgroundColor, tr("Background color")) : QColorDialog::getColor(m_backgroundColor, this, tr("Background color"));
    if (color.isValid()) setBackgroundColor(color);
}

void SessionWindow::keyPressEvent(QKeyEvent *event) {
    // Responder check: editable text controls handle their own keys
    QWidget *focus = QApplication::focusWidget();
    if (focus && (qobject_cast<QLineEdit *>(focus) || qobject_cast<QAbstractSpinBox *>(focus) || qobject_cast<QTextEdit *>(focus))) {
        QMainWindow::keyPressEvent(event);
        return;
    }
    // The canvas's keys are upstream's (EditorCanvas.keyDown): apply / cancel, delete, nudge, Tab, and the plain keys —
    // tool letters (M, L, W toggle their modes; B/E; Shift-U), X / D, 1–0 opacity, [ ] size. Space stays the shell's
    // temporary hand; chords with Ctrl or Meta are menu shortcuts.
    if (!m_spaceHandActive && event->key() != Qt::Key_Space && !(event->modifiers() & (Qt::ControlModifier | Qt::MetaModifier))
        && !event->text().isEmpty() && event->text().at(0).isPrint()) {
        const QByteArray characters = event->text().toUtf8();
        compositor_canvas_key(m_sessionHandle, 0xffff, characters.constData(), chordBits(event->modifiers()), event->isAutoRepeat());
        invalidateOverlay();
        compositor_pump_main();
        syncToolFromSession();
        syncPaletteFromSession();
        syncOptionsFromSession();
        updateOptionsBar();
        refreshImage();
        refreshLayers();
        updateLayersPanel();
        if (m_canvasWidget) m_canvasWidget->update();
        event->accept();
        return;
    }
    if (routesToUpstreamCanvas()) {
        static const QHash<int, int> codes{{Qt::Key_Return, 36}, {Qt::Key_Enter, 76}, {Qt::Key_Escape, 53}, {Qt::Key_Backspace, 51},
            {Qt::Key_Delete, 117}, {Qt::Key_Tab, 48}, {Qt::Key_Left, 123}, {Qt::Key_Right, 124}, {Qt::Key_Down, 125}, {Qt::Key_Up, 126}};
        static const QHash<int, QString> typed{{Qt::Key_Return, "\r"}, {Qt::Key_Enter, "\u0003"}, {Qt::Key_Escape, "\u001b"},
            {Qt::Key_Backspace, "\u007f"}, {Qt::Key_Delete, QString(QChar(0xf728))}, {Qt::Key_Tab, "\t"},
            {Qt::Key_Left, QString(QChar(0xf702))}, {Qt::Key_Right, QString(QChar(0xf703))}, {Qt::Key_Down, QString(QChar(0xf701))},
            {Qt::Key_Up, QString(QChar(0xf700))}};
        if (codes.contains(event->key())) {
            const QByteArray characters = typed.value(event->key()).toUtf8();
            compositor_canvas_key(m_sessionHandle, codes.value(event->key()), characters.constData(), chordBits(event->modifiers()), event->isAutoRepeat());
            invalidateOverlay();
            compositor_pump_main();
            refreshImage();
            refreshLayers();
            updateLayersPanel();
            updateOptionsBar();
            if (m_canvasWidget) m_canvasWidget->update();
            event->accept();
            return;
        }
    }
    // Canvas shortcuts the Keyboard Shortcuts editor reassigned: the new chord stands in for the original (handled
    // below as before), and an original now assigned elsewhere does nothing — ShortcutSettings.canvasEvent.
    if (!m_translatingKey && (!m_canvasRemap.isEmpty() || !m_canvasBlocked.isEmpty())) {
        const CanvasChord input = chordFromKeyEvent(event);
        for (const auto &[from, to] : m_canvasRemap) {
            if (!(from == input)) continue;
            QKeyEvent translated(QEvent::KeyPress, qtKeyForChord(to.key), modifiersForChord(to.modifiers),
                                 to.key.size() == 1 && to.key[0].isPrint() ? (to.modifiers & 8 ? to.key.toUpper() : to.key) : QString(),
                                 event->isAutoRepeat());
            m_translatingKey = true;
            keyPressEvent(&translated);
            m_translatingKey = false;
            event->setAccepted(translated.isAccepted());
            return;
        }
        if (m_canvasBlocked.contains(input)) { event->accept(); return; }
    }

    // A pending gradient: Enter applies it, Esc drops it (upstream EditorCanvas keyDown). Esc also drops a shape drag.
    if (m_gradientLine.size() == 4 && (event->key() == Qt::Key_Return || event->key() == Qt::Key_Enter || event->key() == Qt::Key_Escape)) {
        sendCommand({{"action", event->key() == Qt::Key_Escape ? "gradientCancel" : "gradientCommit"}});
        m_gradientHandle = 0;
        syncCanvasDrafts();
        refreshImage();
        event->accept();
        return;
    }
    if (!m_shapeRect.isNull() && event->key() == Qt::Key_Escape) {
        sendCommand({{"action", "shapeCancel"}});
        m_painting = false;
        syncCanvasDrafts();
        if (m_canvasWidget) m_canvasWidget->update();
        event->accept();
        return;
    }

    if (event->modifiers() == Qt::NoModifier) {
        switch (event->key()) {
        case Qt::Key_V:
            setTool(Tool::Move);
            event->accept();
            return;
        case Qt::Key_M:
            if (m_tool == Tool::Marquee) cycleMarqueeMode();
            else setTool(Tool::Marquee);
            event->accept();
            return;
        case Qt::Key_L:
            if (m_tool == Tool::Lasso) cycleLassoMode();
            else setTool(Tool::Lasso);
            event->accept();
            return;
        case Qt::Key_W:
            setTool(Tool::Magic);
            event->accept();
            return;
        case Qt::Key_Tab:
            if (m_tool == Tool::Magic) {
                toggleMagicMode();
                event->accept();
                return;
            }
            break;
        case Qt::Key_C:
            setTool(Tool::Crop);
            event->accept();
            return;
        case Qt::Key_B:
            setBrushToolMode(BrushToolMode::Paint);
            setTool(Tool::Brush);
            event->accept();
            return;
        case Qt::Key_E:
            setBrushToolMode(BrushToolMode::Erase);
            setTool(Tool::Brush);
            event->accept();
            return;
        case Qt::Key_J:
            setTool(Tool::SpotHealing);
            event->accept();
            return;
        case Qt::Key_S:
            setTool(Tool::CloneStamp);
            event->accept();
            return;
        case Qt::Key_R:
            setTool(Tool::Smear);
            event->accept();
            return;
        case Qt::Key_G:
            setTool(Tool::Gradient);
            event->accept();
            return;
        case Qt::Key_U:
            setTool(Tool::Shape);
            event->accept();
            return;
        case Qt::Key_T:
            setTool(Tool::Type);
            event->accept();
            return;
        case Qt::Key_I:
            setTool(Tool::Eyedropper);
            event->accept();
            return;
        case Qt::Key_H:
            setTool(Tool::Hand);
            event->accept();
            return;
        case Qt::Key_Z:
            setTool(Tool::Zoom);
            event->accept();
            return;
        case Qt::Key_X:
            swapPaletteColors();
            event->accept();
            return;
        case Qt::Key_D:
            resetPaletteColors();
            event->accept();
            return;
        case Qt::Key_BracketLeft:
            setBrushDiameter(std::max(1, m_brushDiameter - 5));
            event->accept();
            return;
        case Qt::Key_BracketRight:
            setBrushDiameter(std::min(500, m_brushDiameter + 5));
            event->accept();
            return;
        case Qt::Key_Space:
            if (!event->isAutoRepeat() && !m_spaceHandActive && m_tool != Tool::Hand) {
                m_preSpaceTool = m_tool;
                m_spaceHandActive = true;
                setTool(Tool::Hand);
                event->accept();
                return;
            }
            break;
        case Qt::Key_Escape:
            if (m_hasPendingCrop) {
                cancelCrop();
                event->accept();
                return;
            }
            if (!m_distortCorners.isEmpty()) {   // ... and Escape puts the layer back
                sendCommand({{"action", "transformCancel"}});
                syncDistortFromSession();
                refreshImage(); refreshLayers(); updateOptionsBar();
                event->accept();
                return;
            }
            break;
        case Qt::Key_Return:
        case Qt::Key_Enter:
            if (m_hasPendingCrop) {
                applyCrop();
                event->accept();
                return;
            }
            if (!m_distortCorners.isEmpty()) {   // a pending distortion: Enter applies it
                sendCommand({{"action", "transformCommit"}});
                syncDistortFromSession();
                refreshImage(); refreshLayers(); updateOptionsBar();
                event->accept();
                return;
            }
            break;
        default:
            break;
        }
    } else if (event->modifiers() == Qt::ShiftModifier) {
        if (event->key() == Qt::Key_U) {
            cycleShapeMode();
            event->accept();
            return;
        } else if (event->key() == Qt::Key_BracketLeft) {
            setBrushHardness(std::max(0, m_brushHardness - 10));
            event->accept();
            return;
        } else if (event->key() == Qt::Key_BracketRight) {
            setBrushHardness(std::min(100, m_brushHardness + 10));
            event->accept();
            return;
        }
    }
    QMainWindow::keyPressEvent(event);
}

void SessionWindow::keyReleaseEvent(QKeyEvent *event) {
    if (event->key() == Qt::Key_Space && m_spaceHandActive && !event->isAutoRepeat()) {
        m_spaceHandActive = false;
        setTool(m_preSpaceTool);
        event->accept();
        return;
    }
    QMainWindow::keyReleaseEvent(event);
}

void SessionWindow::refreshMenuTitles(const QJsonObject &state) {
    const bool canUndo = state.value("canUndo").toBool(false);
    const QString undoName = state.value("undoName").toString();
    const bool canRedo = state.value("canRedo").toBool(false);
    const QString redoName = state.value("redoName").toString();
    const bool hasSelection = state.value("hasSelection").toBool(false);
    const bool canTransformSelection = state.value("canTransformSelection").toBool(false);
    const bool isMaskSelected = state.value("isMaskSelected").toBool(false);
    const bool activeLayerIsVisible = state.value("activeLayerIsVisible").toBool(true);
    const bool activeLayerHasMask = state.value("activeLayerHasMask").toBool(false);
    const bool activeLayerHasParent = state.value("activeLayerHasParent").toBool(false);
    const bool activeLayerIsClipped = state.value("activeLayerIsClipped").toBool(false);
    const bool canToggleClippingMask = state.value("canToggleClippingMask").toBool(false);
    const bool canMergeLayers = state.value("canMergeLayers").toBool(false);
    const QString mergeTitle = state.value("mergeTitle").toString("Merge Down");
    const bool canMoveActiveLayerUp = state.value("canMoveActiveLayerUp").toBool(false);
    const bool canMoveActiveLayerDown = state.value("canMoveActiveLayerDown").toBool(false);
    const QString activeLayerID = state.value("activeLayerID").toString();

    // 1. Undo / Redo
    if (m_actUndo) {
        m_actUndo->setEnabled(canUndo);
        m_actUndo->setText(canUndo && !undoName.isEmpty() ? QString("Undo %1").arg(undoName) : tr("Undo"));
    }
    if (m_actRedo) {
        m_actRedo->setEnabled(canRedo);
        m_actRedo->setText(canRedo && !redoName.isEmpty() ? QString("Redo %1").arg(redoName) : tr("Redo"));
    }

    // 2. Invert: isMaskSelected ? "Invert Mask" : "Invert"
    if (m_actInvert) {
        m_actInvert->setText(isMaskSelected ? tr("Invert Mask") : tr("Invert"));
    }

    // 3. Transform: canTransformSelection ? "Transform Selection" : "Transform Layer"
    if (m_actTransform) {
        m_actTransform->setText(canTransformSelection ? tr("Transform Selection") : tr("Transform Layer"));
    }

    // 4. Duplicate: selection == nil ? "Duplicate Layer" : "Layer via Copy"
    if (m_actDuplicate) {
        m_actDuplicate->setText(hasSelection ? tr("Layer via Copy") : tr("Duplicate Layer"));
    }

    // 5. Clipping Mask: activeLayerIsClipped ? "Release Clipping Mask" : "Create Clipping Mask"
    if (m_actClippingMask) {
        m_actClippingMask->setText(activeLayerIsClipped ? tr("Release Clipping Mask") : tr("Create Clipping Mask"));
        m_actClippingMask->setEnabled(canToggleClippingMask);
    }

    // 6. Layer Visibility: activeLayerIsVisible == false ? "Show Layer" : "Hide Layer"
    if (m_actShowHideLayer) {
        m_actShowHideLayer->setText(activeLayerIsVisible ? tr("Hide Layer") : tr("Show Layer"));
        m_actShowHideLayer->setEnabled(!activeLayerID.isEmpty());
    }

    // 7. Move out of folder
    if (m_actMoveOutOfFolder) {
        m_actMoveOutOfFolder->setEnabled(activeLayerHasParent);
    }

    // 8. Move Up / Down
    if (m_actMoveLayerUp) m_actMoveLayerUp->setEnabled(canMoveActiveLayerUp);
    if (m_actMoveLayerDown) m_actMoveLayerDown->setEnabled(canMoveActiveLayerDown);

    // 9. Merge: session.mergeTitle
    if (m_actMerge) {
        m_actMerge->setText(mergeTitle.isEmpty() ? tr("Merge Down") : mergeTitle);
        m_actMerge->setEnabled(canMergeLayers);
    }

    // 10. Delete: isMaskSelected && activeLayerHasMask ? "Delete Layer Mask" : (selectedLayers > 1 ? "Delete Layers" : "Delete Layer")
    if (m_actDelete) {
        int selectedCount = 1;
        if (m_layersView && m_layersView->selectionModel()) {
            selectedCount = std::max(1, static_cast<int>(m_layersView->selectionModel()->selectedRows().size()));
        }
        if (isMaskSelected && activeLayerHasMask) {
            m_actDelete->setText(tr("Delete Layer Mask"));
        } else if (selectedCount > 1) {
            m_actDelete->setText(tr("Delete Layers"));
        } else {
            m_actDelete->setText(tr("Delete Layer"));
        }
        m_actDelete->setEnabled(!activeLayerID.isEmpty());
    }

    // 11. Selection commands enable/disable
    if (m_actDeselect) m_actDeselect->setEnabled(hasSelection);
    if (m_actInverse) m_actInverse->setEnabled(hasSelection);
    if (m_actClearSelection) m_actClearSelection->setEnabled(hasSelection);
}

/// The menu bar is upstream's (CompositorApp's `.commands`, compositor_app_menus): the shell's own menus stay built,
/// hidden and without shortcuts, so their actions remain reachable by name (tests, internal triggers).
void SessionWindow::installAppMenus() {
    std::function<void(QMenu *)> strip = [&](QMenu *menu) {
        for (QAction *action : menu->actions()) {
            action->setShortcuts({});
            if (action->menu()) strip(action->menu());
        }
    };
    for (QAction *top : menuBar()->actions()) {
        if (top->menu()) { strip(top->menu()); m_legacyMenus << top->menu(); }
        top->setVisible(false);
    }
    // Single keys (tool letters, X, D, digits, brackets) belong to the canvas (EditorCanvas.keyDown), not to actions.
    for (QAction *action : findChildren<QAction *>()) {
        const QKeySequence key = action->shortcut();
        if (key.isEmpty()) continue;
        const int combined = key[0].toCombined();
        if (!(combined & (Qt::ControlModifier | Qt::MetaModifier | Qt::AltModifier))) action->setShortcuts({});
    }
    syncAppMenus();
}

static QKeySequence appMenuSequence(const QString &key, int modifiers) {
    // SwiftUI EventModifiers: shift 2, control 4, option 8, command 16 — ⌘ is Ctrl here, ⌃ Meta, ⌥ Alt.
    int code = 0;
    if (key == QLatin1String("\b") || key == QLatin1String("\x7f")) code = Qt::Key_Backspace;
    else if (key == QLatin1String("\r")) code = Qt::Key_Return;
    else if (key == QLatin1String("\x1b")) code = Qt::Key_Escape;
    else if (key == QLatin1String("\t")) code = Qt::Key_Tab;
    else if (key == QLatin1String(" ")) code = Qt::Key_Space;
    else if (key == QString(QChar(0xf700))) code = Qt::Key_Up;
    else if (key == QString(QChar(0xf701))) code = Qt::Key_Down;
    else if (key == QString(QChar(0xf702))) code = Qt::Key_Left;
    else if (key == QString(QChar(0xf703))) code = Qt::Key_Right;
    else if (!key.isEmpty()) code = key.toUpper().at(0).unicode();
    if (!code) return {};
    int mods = 0;
    if (modifiers & 16) mods |= Qt::CTRL;
    if (modifiers & 8) mods |= Qt::ALT;
    if (modifiers & 4) mods |= Qt::META;
    if (modifiers & 2) mods |= Qt::SHIFT;
    return QKeySequence(mods | code);
}

/// Brings the menu bar up to date with upstream's menus: the same items re-titled / re-enabled / re-checked in place, or
/// rebuilt when the items themselves changed.
void SessionWindow::syncAppMenus() {
    const int64_t size = compositor_app_menus(nullptr, 0);
    if (size <= 0) return;
    QByteArray bytes(static_cast<qsizetype>(size), Qt::Uninitialized);
    if (compositor_app_menus(reinterpret_cast<uint8_t *>(bytes.data()), bytes.size()) != size) return;
    if (bytes == m_appMenusJson) return;
    m_appMenusJson = bytes;
    const QJsonArray menus = QJsonDocument::fromJson(bytes).array();
    // The shape: every item's path and kind. Same shape, update in place (an open menu stays open).
    QStringList shape;
    std::function<void(const QJsonArray &)> collect = [&](const QJsonArray &items) {
        for (const QJsonValue &v : items) {
            const QJsonObject o = v.toObject();
            shape << (o.value("separator").toBool() ? QStringLiteral("-") : o.value("path").toString() + (o.contains("items") ? ">" : "")
                      + (o.contains("checked") ? "?" : ""));
            if (o.contains("items")) collect(o.value("items").toArray());
        }
    };
    collect(menus);
    auto apply = [](QAction *action, const QJsonObject &o) {
        action->setText(QString(o.value("title").toString()).replace(QLatin1Char('&'), QStringLiteral("&&")));   // no mnemonics
        action->setEnabled(o.value("enabled").toBool(true));
        if (o.contains("checked")) action->setChecked(o.value("checked").toBool());
        // Only when it differs: setting a shortcut re-registers it with the window's shortcut map.
        const QKeySequence shortcut = o.contains("key") ? appMenuSequence(o.value("key").toString(), o.value("modifiers").toInt()) : QKeySequence();
        if (action->shortcut() != shortcut) action->setShortcut(shortcut);
    };
    if (shape == m_appMenuShape) {
        std::function<void(const QJsonArray &)> update = [&](const QJsonArray &items) {
            for (const QJsonValue &v : items) {
                const QJsonObject o = v.toObject();
                if (QAction *action = m_appMenuActions.value(o.value("path").toString())) apply(action, o);
                if (o.contains("items")) update(o.value("items").toArray());
            }
        };
        update(menus);
        return;
    }
    m_appMenuShape = shape;
    for (QMenu *menu : m_appMenus) { menuBar()->removeAction(menu->menuAction()); menu->deleteLater(); }
    m_appMenus.clear();
    m_appMenuActions.clear();
    std::function<void(QMenu *, const QJsonArray &)> fill = [&](QMenu *menu, const QJsonArray &items) {
        for (const QJsonValue &v : items) {
            const QJsonObject o = v.toObject();
            if (o.value("separator").toBool()) { menu->addSeparator(); continue; }
            const QString path = o.value("path").toString();
            if (o.contains("items")) {
                QMenu *sub = menu->addMenu(QString());
                m_appMenuActions.insert(path, sub->menuAction());
                apply(sub->menuAction(), o);
                fill(sub, o.value("items").toArray());
                continue;
            }
            QAction *action = menu->addAction(QString());
            action->setCheckable(o.contains("checked"));
            action->setShortcutContext(Qt::WindowShortcut);
            apply(action, o);
            m_appMenuActions.insert(path, action);
            connect(action, &QAction::triggered, this, [this, path] { performAppMenu(path); });
        }
    };
    for (const QJsonValue &v : menus) {
        const QJsonObject o = v.toObject();
        auto *menu = new QMenu(o.value("title").toString() == QLatin1String("Compositor") ? QStringLiteral("  Compositor")
                                                                                           : o.value("title").toString(), menuBar());
        menu->setObjectName("appMenu." + o.value("title").toString());
        fill(menu, o.value("items").toArray());
        // As AppKit validates a menu when it opens: titles, enabled and checked states as of now.
        connect(menu, &QMenu::aboutToShow, this, [this] { syncAppMenus(); });
        menuBar()->addMenu(menu);
        m_appMenus << menu;
    }
}

/// Chooses an upstream menu item, then does what it asked of the shell (save, export, a size dialog, ...) and shows
/// what changed.
void SessionWindow::performAppMenu(const QString &path) {
    syncAppMenus();
    const QByteArray utf8 = path.toUtf8();
    compositor_app_menu_perform(utf8.constData());
    handleShellRequests();
    compositor_pump_main();   // Task { await ... } actions start on the main queue
    handleSessionFileRequests();
    syncToolFromSession();
    syncPaletteFromSession();
    syncOptionsFromSession();
    updateOptionsBar();
    refreshImage();
    refreshLayers();
    updateLayersPanel();
    updateFloatingPanels();
    applyShortcutSettings();
    syncAppMenus();
}

/// ProjectController.exportPNG / exportJPEG: upstream's exporter (and JPEG sheet), the save panel being the shell's,
/// suggesting "<project or Untitled>.png|.jpg".
void SessionWindow::exportWithUpstream(bool jpeg) {
    if (jpeg && !sendCommand({{"action", "jpegExportSheet"}})) return;   // cancelled, or it couldn't render
    const QString base = m_activeDocumentIndex >= 0 && m_activeDocumentIndex < int(m_documents.size())
        ? m_documents[m_activeDocumentIndex].title : QStringLiteral("Untitled");
    const QString path = QFileDialog::getSaveFileName(this, jpeg ? tr("Export JPEG") : tr("Export PNG"),
        QDir::home().filePath(base + (jpeg ? QStringLiteral(".jpg") : QStringLiteral(".png"))),
        jpeg ? tr("JPEG image (*.jpg *.jpeg)") : tr("PNG image (*.png)"));
    if (path.isEmpty()) { if (jpeg) sendCommandQuiet({{"action", "writeJPEG"}}); return; }
    if (!sendCommand({{"action", jpeg ? "writeJPEG" : "exportPNG"}, {"paths", QJsonArray{path}}}))
        m_platform.notifier->warn(jpeg ? tr("Couldn’t export JPEG") : tr("Couldn’t export PNG"), sessionState().value("error").toString());
}

/// Upstream ProjectController calls and system items the menus made (ShellProjects on the Swift side).
void SessionWindow::handleShellRequests() {
    const int64_t size = compositor_take_shell_requests(nullptr, 0);
    if (size <= 2) return;
    QByteArray bytes(static_cast<qsizetype>(size), Qt::Uninitialized);
    if (compositor_take_shell_requests(reinterpret_cast<uint8_t *>(bytes.data()), bytes.size()) != size) return;
    auto trigger = [this](const char *name) {
        for (QAction *action : findChildren<QAction *>())
            if (action->objectName() == QLatin1String(name)) { action->trigger(); return; }
    };
    for (const QJsonValue &v : QJsonDocument::fromJson(bytes).array()) {
        const QString request = v.toString();
        if (request == QLatin1String("newCanvas")) newCanvasTab();
        else if (request == QLatin1String("open")) trigger("file.openProject");
        else if (request == QLatin1String("save")) trigger("file.save");
        else if (request == QLatin1String("saveAs")) trigger("file.saveAs");
        else if (request == QLatin1String("exportPNG")) exportWithUpstream(false);
        else if (request == QLatin1String("exportJPEG")) exportWithUpstream(true);
        else if (request == QLatin1String("close")) trigger("file.closeProject");
        else if (request == QLatin1String("canvasSize") || request == QLatin1String("imageSize")) {
            // Upstream's own sheet (CanvasSizeSheet / ImageSizeSheet) and resizer.
            if (sendCommand({{"action", request == QLatin1String("canvasSize") ? "canvasSizeSheet" : "imageSizeSheet"}})) {
                refreshImage(); refreshLayers(); updateLayersPanel(); updateStatusTelemetry();
            }
        }
        else if (request == QLatin1String("trim")) trigger("image.trim");
        else if (request == QLatin1String("about")) trigger("help.about");
        else if (request == QLatin1String("checkForUpdates")) trigger("help.updates");
        else if (request == QLatin1String("quit")) close();
        else if (request == QLatin1String("minimize")) showMinimized();
        else if (request == QLatin1String("zoom")) { if (isMaximized()) showNormal(); else showMaximized(); }
        else if (request == QLatin1String("fullScreen")) { if (isFullScreen()) showNormal(); else showFullScreen(); }
    }
}

/// AppKit's standard About panel: the app icon, its name in bold, "Version x (build)", centred in a small window.
void SessionWindow::showAboutPanel() {
    auto *panel = new QDialog(this, Qt::Dialog);
    panel->setAttribute(Qt::WA_DeleteOnClose);
    panel->setObjectName("aboutPanel");
    panel->setWindowTitle(QString());
    auto *layout = new QVBoxLayout(panel);
    layout->setContentsMargins(40, 24, 40, 24);
    layout->setSpacing(6);
    auto *icon = new QLabel(panel);
    icon->setPixmap(windowIcon().pixmap(64, 64));
    icon->setAlignment(Qt::AlignCenter);
    layout->addWidget(icon);
    layout->addSpacing(8);
    auto *name = new QLabel(QStringLiteral("Compositor"), panel);
    QFont bold = name->font();
    bold.setPixelSize(14);
    bold.setWeight(QFont::Bold);
    name->setFont(bold);
    name->setAlignment(Qt::AlignCenter);
    layout->addWidget(name);
    auto *version = new QLabel(tr("Version %1 (%2)").arg(QStringLiteral(COMPOSITOR_VERSION), QStringLiteral(COMPOSITOR_BUILD)), panel);
    QFont small = version->font();
    small.setPixelSize(11);
    version->setFont(small);
    version->setAlignment(Qt::AlignCenter);
    version->setStyleSheet(QStringLiteral("color: rgba(255, 255, 255, 0.55);"));
    layout->addWidget(version);
    panel->setFixedSize(panel->sizeHint().expandedTo(QSize(280, 0)));
    panel->show();
}

void SessionWindow::createMenus() {
    // Where the desktop offers a global menu (Plasma's, or an appmenu extension elsewhere), the menus leave the window
    // for the top of the screen, as on the Mac; otherwise Qt keeps them in the window. COMPOSITOR_IN_WINDOW_MENUS=1
    // keeps them in the window regardless.
    menuBar()->setNativeMenuBar(!qEnvironmentVariableIsSet("COMPOSITOR_IN_WINDOW_MENUS"));
    // The menu bar is the window's topmost strip, where a frameless window is naturally grabbed — its empty area
    // (right of the last menu) moves the window too. See eventFilter().
    menuBar()->installEventFilter(this);
    auto *appMenu = menuBar()->addMenu(QString::fromUtf8("  Compositor"));
    appMenu->addAction(tr("About Compositor…"), this, [this] {
        QMessageBox::about(this, tr("About Compositor"),
            tr("<h3>Compositor</h3>"
               "<p>Professional Non-Destructive Image Editor.</p>"
               "<p>Native GNU/Linux port powered by Qt 6, Skia, and unmodified upstream Swift engine.</p>"));
    });
    appMenu->addSeparator();
    appMenu->addAction(tr("Quit Compositor"), QKeySequence::Quit, this, &QWidget::close);

    // --- File ---
    auto *file = menuBar()->addMenu(tr("File"));
    // Upstream's New Canvas… (projects.newCanvas → workspace.newCanvas): a new empty tab showing the New Canvas sheet.
    file->addAction(tr("New Canvas…"), QKeySequence::New, this, [this] { newCanvasTab();     })->setObjectName("file.new");

    file->addAction(tr("Open Project…"), QKeySequence::Open, this, [this] {
        const QString path = m_platform.files->chooseProjectToOpen();
        if (!path.isEmpty() && !loadProject(path)) {
            m_platform.notifier->warn(tr("Open failed"), tr("Could not load project."));
        }
    })->setObjectName("file.openProject");

    // Upstream's Import Images… sets session.showsImporter; its .fileImporter imports the picked files as layers (or,
    // into an empty tab, as a document the size of the first).
    file->addAction(tr("Import Images…"), this, [this] {
        const QStringList paths = m_platform.files->chooseImagesToImport();
        if (!paths.isEmpty()) importWithUpstream(paths, false);
    })->setObjectName("file.importImages");

    file->addSeparator();

    file->addAction(tr("Save"), QKeySequence::Save, this, [this] { saveCurrentDocument(false); })
        ->setObjectName("file.save");

    file->addAction(tr("Save As…"), QKeySequence(Qt::CTRL | Qt::SHIFT | Qt::Key_S), this,
                    [this] { saveCurrentDocument(true); })->setObjectName("file.saveAs");

    file->addSeparator();

    file->addAction(tr("Export PNG…"), QKeySequence(Qt::CTRL | Qt::SHIFT | Qt::Key_E), this, [this] {
        const QString path = m_platform.files->chooseExportPath(QStringLiteral("PNG"), tr("PNG (*.png)"));
        if (!path.isEmpty() && !exportPNG(path)) {
            m_platform.notifier->warn(tr("Export failed"), tr("Could not export PNG."));
        }
    })->setObjectName("file.exportPNG");

    file->addAction(tr("Export JPEG…"), QKeySequence(Qt::CTRL | Qt::ALT | Qt::SHIFT | Qt::Key_S), this, [this] {
        const QString path = m_platform.files->chooseExportPath(QStringLiteral("JPEG"), tr("JPEG (*.jpg *.jpeg)"));
        if (!path.isEmpty() && !exportJPEG(path)) {
            m_platform.notifier->warn(tr("Export failed"), tr("Could not export JPEG."));
        }
    })->setObjectName("file.exportJPEG");

    file->addAction(tr("Export TIFF…"), this, [this] {
        const QString path = m_platform.files->chooseExportPath(QStringLiteral("TIFF"), tr("TIFF (*.tiff *.tif)"));
        if (!path.isEmpty() && !exportTIFF(path)) {
            m_platform.notifier->warn(tr("Export failed"), tr("Could not export TIFF."));
        }
    })->setObjectName("file.exportTIFF");

    file->addAction(tr("Export WebP…"), this, [this] {
        const QString path = m_platform.files->chooseExportPath(QStringLiteral("WebP"), tr("WebP (*.webp)"));
        if (!path.isEmpty() && !exportWebP(path)) {
            m_platform.notifier->warn(tr("Export failed"), tr("Could not export WebP."));
        }
    })->setObjectName("file.exportWebP");

    file->addSeparator();

    // Upstream: Close closes the current tab (ProjectController.close -> ProjectWorkspace.close), asking first.
    file->addAction(tr("Close Project"), QKeySequence::Close, this, [this] {
        closeDocumentTab(m_activeDocumentIndex);
    })->setObjectName("file.closeProject");

    file->addSeparator();

    file->addAction(tr("Quit"), QKeySequence::Quit, this, &QWidget::close)->setObjectName("file.quit");

    // --- Edit ---
    auto *edit = menuBar()->addMenu(tr("Edit"));
    m_actUndo = edit->addAction(tr("Undo"), QKeySequence::Undo, this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"undo"})") == 0) {
            refreshImage();
            refreshLayers();
        }
    });
    m_actUndo->setObjectName("edit.undo");

    m_actRedo = edit->addAction(tr("Redo"), QKeySequence::Redo, this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"redo"})") == 0) {
            refreshImage();
            refreshLayers();
        }
    });
    m_actRedo->setObjectName("edit.redo");

    edit->addSeparator();

    m_actCut = edit->addAction(tr("Cut"), QKeySequence::Cut, this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"cut"})") == 0) refreshImage();
    });
    m_actCut->setObjectName("edit.cut");

    m_actCopy = edit->addAction(tr("Copy"), QKeySequence::Copy, this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"copy"})") == 0) {
            if (!m_image.isNull()) m_platform.clipboard->setImage(fullResolutionImage());
            statusBar()->showMessage(tr("Copied to clipboard."), 1500);
        }
    });
    m_actCopy->setObjectName("edit.copy");

    m_actCopyMerged = edit->addAction(tr("Copy Merged"), QKeySequence(Qt::CTRL | Qt::SHIFT | Qt::Key_C), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"copyMerged"})") == 0) {
            if (!m_image.isNull()) m_platform.clipboard->setImage(fullResolutionImage());
            statusBar()->showMessage(tr("Copied merged to clipboard."), 1500);
        }
    });
    m_actCopyMerged->setObjectName("edit.copyMerged");

    m_actPaste = edit->addAction(tr("Paste"), QKeySequence::Paste, this, [this] {
        const QImage img = m_platform.clipboard->image();
        if (!img.isNull()) {
            QImage rgba = img.convertToFormat(QImage::Format_RGBA8888);
            std::vector<uint8_t> premul(rgba.width() * rgba.height() * 4);
            for (int y = 0; y < rgba.height(); ++y) {
                const uint8_t *src = rgba.constScanLine(y);
                uint8_t *dst = premul.data() + y * rgba.width() * 4;
                for (int x = 0; x < rgba.width(); ++x) {
                    const uint8_t a = src[x * 4 + 3];
                    dst[x * 4] = static_cast<uint8_t>((src[x * 4] * a + 127) / 255);
                    dst[x * 4 + 1] = static_cast<uint8_t>((src[x * 4 + 1] * a + 127) / 255);
                    dst[x * 4 + 2] = static_cast<uint8_t>((src[x * 4 + 2] * a + 127) / 255);
                    dst[x * 4 + 3] = a;
                }
            }
            std::string name = "Pasted Layer";
            if (compositor_session_import_rgba(m_sessionHandle, premul.data(), premul.size(),
                                               rgba.width(), rgba.height(),
                                               reinterpret_cast<const uint8_t *>(name.data()), name.size(), 0) == 0) {
                refreshImage();
                refreshLayers();
            }
        }
    });
    m_actPaste->setObjectName("edit.paste");

    edit->addSeparator();

    // Upstream's shortcut editor (ShortcutSettings.show): search, click a shortcut and press its new keys, Save.
    edit->addAction(tr("Keyboard Shortcuts…"), this, [this] {
        if (sendCommand({{"action", "showKeyboardShortcuts"}})) updateFloatingPanels();
    })->setObjectName("edit.shortcuts");

    edit->addSeparator();

    m_actFillFG = edit->addAction(tr("Fill with Foreground Color"), QKeySequence(Qt::ALT | Qt::Key_Delete), this, [this] {
        if (sendCommand({{"action", "fillForeground"}, {"parameters", QJsonObject{{"red", m_brushColor.redF()}, {"green", m_brushColor.greenF()}, {"blue", m_brushColor.blueF()}}}})) {
            refreshImage();
        }
    });
    m_actFillFG->setObjectName("fill.foreground");

    m_actFillBG = edit->addAction(tr("Fill with Background Color"), QKeySequence(Qt::CTRL | Qt::Key_Delete), this, [this] {
        if (sendCommand({{"action", "fillBackground"}, {"parameters", QJsonObject{{"red", m_backgroundColor.redF()}, {"green", m_backgroundColor.greenF()}, {"blue", m_backgroundColor.blueF()}}}})) {
            refreshImage();
        }
    });
    m_actFillBG->setObjectName("fill.background");

    m_actClearSelection = edit->addAction(tr("Clear Selection Pixels"), QKeySequence::Delete, this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"clearSelection"})") == 0) refreshImage();
    });
    m_actClearSelection->setObjectName("fill.clear");

    m_actContentAwareFill = edit->addAction(tr("Content-Aware Fill…"), QKeySequence(Qt::SHIFT | Qt::Key_Delete), this, [this] {
        showFilterDialog("Content-Aware Fill");
    });
    m_actContentAwareFill->setObjectName("edit.contentFill");

    edit->addSeparator();

    edit->addAction(tr("Command Palette…"), QKeySequence(Qt::CTRL | Qt::SHIFT | Qt::Key_P), this, [this] {
        showCommandPalette();
    })->setObjectName("commandPalette");

    // --- View ---
    auto *view = menuBar()->addMenu(tr("View"));
    view->addAction(tr("Fit Canvas"), QKeySequence(Qt::CTRL | Qt::Key_0), this, &SessionWindow::fitCanvas)->setObjectName("view.fitCanvas");
    view->addAction(tr("Actual Pixels"), QKeySequence(Qt::CTRL | Qt::Key_1), this, &SessionWindow::actualPixels)->setObjectName("view.actualPixels");
    view->addAction(tr("Zoom In"), QKeySequence::ZoomIn, this, [this] { zoomStep(1); })->setObjectName("view.zoomIn");
    view->addAction(tr("Zoom Out"), QKeySequence::ZoomOut, this, [this] { zoomStep(-1); })->setObjectName("view.zoomOut");

    view->addSeparator();

    auto *actPixelGrid = view->addAction(tr("Pixel Grid (800% and above)"));
    actPixelGrid->setCheckable(true);
    actPixelGrid->setChecked(true);
    actPixelGrid->setObjectName("view.pixelGrid");

    auto *actSnap = view->addAction(tr("Snap"));
    actSnap->setCheckable(true);
    actSnap->setChecked(true);
    actSnap->setObjectName("view.snap");

    auto *actTransformControls = view->addAction(tr("Show Transform Controls"), QKeySequence(Qt::CTRL | Qt::Key_H), this, [this](bool) {
        if (m_canvasWidget) m_canvasWidget->update();
    });
    actTransformControls->setCheckable(true);
    actTransformControls->setChecked(true);
    actTransformControls->setObjectName("view.transformControls");

    view->addSeparator();

    auto *showMenu = view->addMenu(tr("Show"));
    auto *actShowGrid = showMenu->addAction(tr("Grid"), QKeySequence(Qt::CTRL | Qt::Key_Apostrophe));
    actShowGrid->setCheckable(true);
    actShowGrid->setObjectName("view.showGrid");
    auto *actShowGuides = showMenu->addAction(tr("Guides"), QKeySequence(Qt::CTRL | Qt::Key_Semicolon));
    actShowGuides->setCheckable(true);
    actShowGuides->setChecked(true);
    actShowGuides->setObjectName("view.showGuides");

    auto *actRulers = view->addAction(tr("Rulers"), QKeySequence(Qt::CTRL | Qt::Key_R));
    actRulers->setCheckable(true);
    actRulers->setObjectName("view.rulers");

    view->addSeparator();

    auto *snapMenu = view->addMenu(tr("Snap To"));
    auto *snapGuides = snapMenu->addAction(tr("Guides")); snapGuides->setCheckable(true); snapGuides->setChecked(true);
    auto *snapGrid = snapMenu->addAction(tr("Grid")); snapGrid->setCheckable(true);
    auto *snapLayers = snapMenu->addAction(tr("Layers")); snapLayers->setCheckable(true); snapLayers->setChecked(true);
    auto *snapDocBounds = snapMenu->addAction(tr("Document Bounds")); snapDocBounds->setCheckable(true); snapDocBounds->setChecked(true);

    view->addSeparator();

    auto *actLockGuides = view->addAction(tr("Lock Guides"), QKeySequence(Qt::CTRL | Qt::ALT | Qt::Key_Semicolon));
    actLockGuides->setCheckable(true);
    actLockGuides->setObjectName("view.lockGuides");

    view->addAction(tr("Clear Guides"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"clearGuides"})") == 0) {
            if (m_canvasWidget) m_canvasWidget->update();
        }
    })->setObjectName("view.clearGuides");

    // --- Select ---
    auto *select = menuBar()->addMenu(tr("Select"));
    m_actSelectAll = select->addAction(tr("All"), QKeySequence::SelectAll, this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"selectAll"})") == 0) {
            refreshImage();
            refreshLayers();
        }
    });
    m_actSelectAll->setObjectName("select.all");

    m_actDeselect = select->addAction(tr("Deselect"), QKeySequence(Qt::CTRL | Qt::Key_D), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"deselect"})") == 0) {
            refreshImage();
            refreshLayers();
        }
    });
    m_actDeselect->setObjectName("select.deselect");

    m_actInverse = select->addAction(tr("Inverse"), QKeySequence(Qt::CTRL | Qt::SHIFT | Qt::Key_I), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"invertSelection"})") == 0) {
            refreshImage();
            refreshLayers();
        }
    });
    m_actInverse->setObjectName("select.inverse");

    m_actLayerPixels = select->addAction(tr("Layer's Pixels"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"loadLayerSelection"})") == 0) {
            refreshImage();
            refreshLayers();
        }
    });
    m_actLayerPixels->setObjectName("select.layerPixels");

    m_actSelectSubject = select->addAction(tr("Subject"), QKeySequence(Qt::CTRL | Qt::ALT | Qt::Key_A), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"selectSubject"})") == 0) {
            refreshImage();
            refreshLayers();
        }
    });
    m_actSelectSubject->setObjectName("select.subject");

    m_actMaskBlackAreas = select->addAction(tr("Mask's Black Areas"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"loadMaskSelection"})") == 0) {
            refreshImage();
            refreshLayers();
        }
    });
    m_actMaskBlackAreas->setObjectName("select.maskBlackAreas");

    select->addSeparator();

    m_actExpandSelection = select->addAction(tr("Expand…"), this, [this] {
        bool ok = false;
        const int px = QInputDialog::getInt(this, tr("Expand Selection"), tr("Expand by (pixels):"), 1, 1, 500, 1, &ok);
        if (ok && px > 0) {
            if (sendCommand({{"action", "expandSelection"}, {"parameters", QJsonObject{{"amount", px}}}})) {
                refreshImage();
                refreshLayers();
            }
        }
    });
    m_actExpandSelection->setObjectName("select.expand");

    m_actContractSelection = select->addAction(tr("Contract…"), this, [this] {
        bool ok = false;
        const int px = QInputDialog::getInt(this, tr("Contract Selection"), tr("Contract by (pixels):"), 1, 1, 500, 1, &ok);
        if (ok && px > 0) {
            if (sendCommand({{"action", "contractSelection"}, {"parameters", QJsonObject{{"amount", px}}}})) {
                refreshImage();
                refreshLayers();
            }
        }
    });
    m_actContractSelection->setObjectName("select.contract");

    m_actFeatherSelection = select->addAction(tr("Feather…"), this, [this] {
        bool ok = false;
        const int px = QInputDialog::getInt(this, tr("Feather Selection"), tr("Feather radius (pixels):"), 1, 1, 500, 1, &ok);
        if (ok && px > 0) {
            if (sendCommand({{"action", "featherSelection"}, {"parameters", QJsonObject{{"amount", px}}}})) {
                refreshImage();
                refreshLayers();
            }
        }
    });
    m_actFeatherSelection->setObjectName("select.feather");

    select->addSeparator();

    // Preserved for automation compatibility:
    select->addAction(tr("Rectangle Selection"), this, [this] { selectRegion(true); })->setObjectName("select.rectangle");
    select->addAction(tr("Ellipse Selection"), this, [this] { selectRegion(false); })->setObjectName("select.ellipse");

    // --- Image ---
    auto *image = menuBar()->addMenu(tr("Image"));
    image->addAction(tr("Curves…"), QKeySequence(Qt::CTRL | Qt::Key_M), this, [this] { showAdjustDialog("Curves"); })->setObjectName("adjust.Curves");
    image->addAction(tr("Levels…"), QKeySequence(Qt::CTRL | Qt::Key_L), this, [this] { showAdjustDialog("Levels"); })->setObjectName("adjust.Levels");
    image->addAction(tr("Hue/Saturation…"), QKeySequence(Qt::CTRL | Qt::Key_U), this, [this] { showAdjustDialog("Hue/Saturation"); })->setObjectName("adjust.Hue/Saturation");
    for (const QString &kind : {QString("Black & White"), QString("Color Balance"), QString("Exposure"), QString("Gradient Map"), QString("Grain")}) {
        auto *act = image->addAction(kind + "…", this, [this, kind] { showAdjustDialog(kind); });
        act->setObjectName("adjust." + kind);
    }

    image->addSeparator();

    m_actInvert = image->addAction(tr("Invert"), QKeySequence(Qt::CTRL | Qt::Key_I), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"invert"})") == 0) {
            refreshImage();
            refreshLayers();
        }
    });
    m_actInvert->setObjectName("image.invert");

    image->addSeparator();

    image->addAction(tr("Canvas Size…"), QKeySequence(Qt::CTRL | Qt::ALT | Qt::Key_C), this, [this] { showSizeDialog(false); })->setObjectName("canvasSize");
    image->addAction(tr("Image Size…"), QKeySequence(Qt::CTRL | Qt::ALT | Qt::Key_I), this, [this] { showSizeDialog(true); })->setObjectName("imageSize");
    // Upstream's Trim… (its TrimSheet, then its trim: one undo step).
    image->addAction(tr("Trim…"), this, [this] {
        if (sendCommand({{"action", "trim"}})) { refreshImage(); refreshLayers(); updateLayersPanel(); updateStatusTelemetry(); }
    })->setObjectName("image.trim");

    image->addSeparator();

    image->addAction(tr("Flip Canvas Horizontal"), this, [this] {
        if (sendCommand({{"action", "flipCanvas"}, {"horizontally", true}})) refreshImage();
    })->setObjectName("image.flipH");
    image->addAction(tr("Flip Canvas Vertical"), this, [this] {
        if (sendCommand({{"action", "flipCanvas"}, {"horizontally", false}})) refreshImage();
    })->setObjectName("image.flipV");

    // --- Filter ---
    auto *filter = menuBar()->addMenu(tr("Filter"));
    // Upstream's Filter menu, in its order (FilterKind.allCases minus the Image menu's adjustments). The first four
    // keep the shell's dialogs; the rest open upstream's FilterSheet as a floating panel, as on the Mac.
    for (const QString &kind : {QString("Gaussian Blur"), QString("Motion Blur"), QString("Add Noise"), QString("Vignette"),
                                QString("Bloom / Glow"), QString("Tonal Contrast"), QString("Lens Correction"),
                                QString("Camera Raw Filter")}) {
        const bool shellDialog = kind == "Gaussian Blur" || kind == "Motion Blur" || kind == "Add Noise" || kind == "Lens Correction";
        auto *action = filter->addAction(kind + "…", this, [this, kind, shellDialog] {
            if (shellDialog) { showFilterDialog(kind); return; }
            if (sendCommand({{"action", "openFilter"}, {"kind", kind}})) { refreshImage(); updateFloatingPanels(); }
        });
        action->setObjectName("filter." + kind);
    }
    filter->addAction(tr("Remove Background…"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"removeBackground"})") == 0) {
            refreshImage();
            refreshLayers();
        }
    })->setObjectName("filter.Remove Background");

    // --- Layer ---
    auto *layer = menuBar()->addMenu(tr("Layer"));
    auto *adjMenu = layer->addMenu(tr("New Adjustment Layer"));
    for (const QString &kind : {QString("Hue/Saturation"), QString("Levels"), QString("Curves"), QString("Exposure"),
                                QString("Gradient Map"), QString("Grain"), QString("Invert"), QString("Black & White"), QString("Color Balance")}) {
        adjMenu->addAction(kind == "Invert" ? kind : kind + "…", this, [this, kind] {
            showAdjustDialog(kind);
        })->setObjectName("layer.adjust." + kind);
    }

    layer->addAction(tr("Edit Adjustment…"), this, [this] {
        const QJsonObject state = sessionState();
        const QString active = state.value("activeLayerID").toString();
        for (const QJsonValue &v : state.value("layers").toArray()) {
            const QJsonObject l = v.toObject();
            if (l.value("id").toString() == active && l.contains("adjustment")) {
                const QString kind = l.value("adjustment").toObject().value("kind").toString();
                if (!kind.isEmpty()) showAdjustDialog(kind);
                break;
            }
        }
    })->setObjectName("layer.editAdjustment");

    layer->addSeparator();

    m_actTransform = layer->addAction(tr("Transform Layer"), QKeySequence(Qt::CTRL | Qt::Key_T), this, [this] {
        setTool(Tool::Move);
    });
    m_actTransform->setObjectName("layer.transform");

    m_actDuplicate = layer->addAction(tr("Duplicate Layer"), QKeySequence(Qt::CTRL | Qt::Key_J), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"duplicateLayer"})") == 0) {
            refreshImage();
            refreshLayers();
        }
    });
    m_actDuplicate->setObjectName("layer.duplicate");

    layer->addSeparator();

    m_actClippingMask = layer->addAction(tr("Create Clipping Mask"), QKeySequence(Qt::CTRL | Qt::ALT | Qt::Key_G), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"toggleClippingMask"})") == 0) {
            refreshImage();
            refreshLayers();
        }
    });
    m_actClippingMask->setObjectName("layer.clippingMask");

    layer->addSeparator();

    m_actGroupLayers = layer->addAction(tr("Group Selected Layers"), QKeySequence(Qt::CTRL | Qt::Key_G), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"addGroup"})") == 0) {
            refreshImage();
            refreshLayers();
        }
    });
    m_actGroupLayers->setObjectName("layer.addGroup");

    m_actMoveOutOfFolder = layer->addAction(tr("Move Out of Folder"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"moveActiveLayerOutOfGroup"})") == 0) {
            refreshImage();
            refreshLayers();
        }
    });
    m_actMoveOutOfFolder->setObjectName("layer.moveOutOfFolder");

    m_actNewBlankLayer = layer->addAction(tr("New Blank Layer"), QKeySequence(Qt::CTRL | Qt::SHIFT | Qt::Key_N), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"addLayer"})") == 0) {
            refreshImage();
            refreshLayers();
        }
    });
    m_actNewBlankLayer->setObjectName("layer.new");

    m_actRenameLayer = layer->addAction(tr("Rename Layer…"), this, [this] {
        if (m_layersView) m_layersView->edit(m_layersView->currentIndex());
    });
    m_actRenameLayer->setObjectName("layer.rename");

    m_actShowHideLayer = layer->addAction(tr("Show Layer"), this, [this] {
        const QJsonObject state = sessionState();
        const bool vis = state.value("activeLayerIsVisible").toBool(true);
        if (setLayerFlag("setVisible", !vis)) refreshImage();
    });
    m_actShowHideLayer->setObjectName("layer.showHide");

    layer->addSeparator();

    m_actMoveLayerUp = layer->addAction(tr("Move Layer Up"), QKeySequence(Qt::CTRL | Qt::Key_BracketRight), this, [this] {
        if (sendCommand({{"action", "moveActiveLayer"}, {"value", 1}})) {
            refreshImage();
            refreshLayers();
        }
    });
    m_actMoveLayerUp->setObjectName("layer.moveUp");

    m_actMoveLayerDown = layer->addAction(tr("Move Layer Down"), QKeySequence(Qt::CTRL | Qt::Key_BracketLeft), this, [this] {
        if (sendCommand({{"action", "moveActiveLayer"}, {"value", -1}})) {
            refreshImage();
            refreshLayers();
        }
    });
    m_actMoveLayerDown->setObjectName("layer.moveDown");

    layer->addSeparator();

    m_actMerge = layer->addAction(tr("Merge Down"), QKeySequence(Qt::CTRL | Qt::Key_E), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"mergeLayers"})") == 0) {
            refreshImage();
            refreshLayers();
        }
    });
    m_actMerge->setObjectName("layer.merge");

    layer->addSeparator();

    m_actFlipLayerH = layer->addAction(tr("Flip Layer Horizontal"), this, [this] {
        if (sendCommand({{"action", "flipLayer"}, {"horizontally", true}})) refreshImage();
    });
    m_actFlipLayerH->setObjectName("layer.flipH");

    m_actFlipLayerV = layer->addAction(tr("Flip Layer Vertical"), this, [this] {
        if (sendCommand({{"action", "flipLayer"}, {"horizontally", false}})) refreshImage();
    });
    m_actFlipLayerV->setObjectName("layer.flipV");

    layer->addSeparator();

    auto *maskMenu = layer->addMenu(tr("Layer Mask"));
    maskMenu->addAction(tr("Add Reveal Mask"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"addRevealMask"})") == 0) {
            refreshImage();
            refreshLayers();
        }
    })->setObjectName("layer.addRevealMask");

    maskMenu->addAction(tr("Add Hide Mask"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"addHideMask"})") == 0) {
            refreshImage();
            refreshLayers();
        }
    })->setObjectName("layer.addHideMask");

    maskMenu->addAction(tr("Invert Mask"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"invertMask"})") == 0) {
            refreshImage();
            refreshLayers();
        }
    })->setObjectName("layer.invertMask");

    maskMenu->addAction(tr("Delete Mask"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"deleteMask"})") == 0) {
            refreshImage();
            refreshLayers();
        }
    })->setObjectName("layer.deleteMask");

    layer->addSeparator();

    m_actDelete = layer->addAction(tr("Delete Layer"), QKeySequence::Delete, this, [this] {
        deleteSelectedLayers();
    });
    m_actDelete->setObjectName("layer.delete");

    // --- Window ---
    auto *window = menuBar()->addMenu(tr("Window"));
    window->addAction(tr("Reset Workspace Layout"), this, [this] {
        if (m_toolsBar) m_toolsBar->show();
        if (m_optionsToolBar) m_optionsToolBar->show();
        if (m_layersDock) m_layersDock->show();
    })->setObjectName("window.resetLayout");

    window->addSeparator();

    if (m_toolsBar) {
        auto *actTools = window->addAction(tr("Tools"));
        actTools->setCheckable(true);
        actTools->setChecked(m_toolsBar->isVisible());
        connect(actTools, &QAction::toggled, m_toolsBar, &QWidget::setVisible);
        connect(m_toolsBar, &QToolBar::visibilityChanged, actTools, &QAction::setChecked);
    }
    if (m_optionsToolBar) {
        auto *actOptions = window->addAction(tr("Options Bar"));
        actOptions->setCheckable(true);
        actOptions->setChecked(m_optionsToolBar->isVisible());
        connect(actOptions, &QAction::toggled, m_optionsToolBar, &QWidget::setVisible);
        connect(m_optionsToolBar, &QToolBar::visibilityChanged, actOptions, &QAction::setChecked);
    }
    if (m_layersDock) {
        auto *actLayers = window->addAction(tr("Layers"));
        actLayers->setCheckable(true);
        actLayers->setChecked(m_layersDock->isVisible());
        connect(actLayers, &QAction::toggled, m_layersDock, &QWidget::setVisible);
        connect(m_layersDock, &QDockWidget::visibilityChanged, actLayers, &QAction::setChecked);
    }
    if (m_adjustmentsDock) {
        window->addAction(m_adjustmentsDock->toggleViewAction());
    }

    // --- Help ---
    auto *help = menuBar()->addMenu(tr("Help"));
    help->addAction(tr("About Compositor"), this, [this] { showAboutPanel(); })->setObjectName("help.about");

    help->addAction(tr("Check for Updates…"), this, [this] {
        if (m_platform.updates) {
            m_platform.updates->checkForUpdates(true);
        } else {
            QMessageBox::information(this, tr("Check for Updates"),
                tr("You are running the latest version of Compositor for GNU/Linux."));
        }
    })->setObjectName("help.updates");
}

namespace {
constexpr double kPi = 3.14159265358979323846;
const QPointF kHandleUnits[8] = {{0, 0}, {0.5, 0}, {1, 0}, {1, 0.5}, {1, 1}, {0.5, 1}, {0, 1}, {0, 0.5}};

QPointF geometryPoint(const SessionWindow::LayerGeometry &g, const QPointF &unit) {
    const double r = g.rotation * kPi / 180.0;
    const double lx = (unit.x() - 0.5) * g.w, ly = (unit.y() - 0.5) * g.h;
    return QPointF(g.x + g.w / 2 + lx * std::cos(r) - ly * std::sin(r),
                   g.y + g.h / 2 + lx * std::sin(r) + ly * std::cos(r));
}

}  // namespace

/// CanvasRulerNSView.draw: white 0.2, ticks (0.62) every tenth of a 1-2-5 major step about 70 points apart, 8 long at
/// majors, 5 at halves, 3 otherwise, numbered majors (0.78, 8-pt digits) — the left ruler's turned to read downward —
/// and a 0.08 hairline along the canvas edge.
void SessionWindow::paintRuler(QWidget *ruler, bool vertical) {
    QPainter p(ruler);
    p.fillRect(ruler->rect(), QColor::fromRgbF(0.2, 0.2, 0.2));
    if (m_image.isNull() || !m_canvasWidget) return;
    const QRectF doc = canvasTargetRect();
    if (doc.width() <= 0 || docWidth() <= 0) return;
    const double scale = doc.width() / docWidth();   // points per document pixel
    static const double nice[] = {1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000, 2000, 2500, 5000, 10000, 20000, 25000};
    double step = 50000;
    for (double n : nice) if (n >= 70 / std::max(scale, 0.0001)) { step = n; break; }
    const double minor = step / 10;
    const double dpr = ruler->devicePixelRatioF(), hairline = 1.0 / std::max(dpr, 1.0);
    // The canvas's origin in ruler coordinates (the ruler runs along the canvas's edge).
    const QPoint offset = m_canvasWidget->mapTo(ruler->window(), QPoint(0, 0)) - ruler->mapTo(ruler->window(), QPoint(0, 0));
    const double origin = vertical ? doc.top() + offset.y() : doc.left() + offset.x();
    const double length = vertical ? ruler->height() : ruler->width();
    const double start = (0 - origin) / scale, end = (length - origin) / scale;
    const double first = std::floor(std::min(start, end) / minor) * minor, last = std::ceil(std::max(start, end) / minor) * minor;
    QFont font = ruler->font();
    font.setPixelSize(8);
    font.setFeature(QFont::Tag("tnum"), 1);
    p.setFont(font);
    const QColor tick = QColor::fromRgbF(0.62, 0.62, 0.62), labels = QColor::fromRgbF(0.78, 0.78, 0.78);
    const QFontMetricsF metrics(font);
    for (double value = first; value <= last + 0.001; value += minor) {
        const double at = origin + value * scale;
        const double remainder = std::abs(std::remainder(value, step));
        const bool major = remainder < 0.001 || std::abs(remainder - step) < 0.001;
        const bool mid = !major && std::abs(std::remainder(value, step / 2)) < 0.001;
        const double len = major ? 8 : mid ? 5 : 3;
        if (vertical) p.fillRect(QRectF(kRulerThickness - len, at - hairline / 2, len, hairline), tick);
        else p.fillRect(QRectF(at - hairline / 2, kRulerThickness - len, hairline, len), tick);
        if (!major) continue;
        const double rounded = std::round(value);
        const QString text = rounded == 0 ? QStringLiteral("0") : QString::number(qint64(rounded));
        p.setPen(labels);
        if (vertical) {
            p.save();
            p.translate(1, at + 2);
            p.rotate(-90);
            p.drawText(QPointF(-metrics.horizontalAdvance(text), metrics.ascent()), text);
            p.restore();
        } else {
            p.drawText(QPointF(at + 2, metrics.ascent()), text);
        }
    }
    const QColor edge = QColor::fromRgbF(0.08, 0.08, 0.08);
    if (vertical) p.fillRect(QRectF(kRulerThickness - hairline, 0, hairline, ruler->height()), edge);
    else p.fillRect(QRectF(0, kRulerThickness - hairline, ruler->width(), hairline), edge);
}

/// Pressing a ruler starts a new guide there (the top ruler a horizontal one), following the pointer over the canvas;
/// released back on a ruler, it goes away.
void SessionWindow::rulerMousePress(QMouseEvent *event, QWidget *ruler, bool vertical) {
    if (event->button() != Qt::LeftButton || !m_canEditGuides || !m_canvasWidget) return;
    const QPointF at = m_canvasWidget->mapFrom(ruler, event->position().toPoint());
    const QPointF doc = documentPoint(at);
    const bool guideVertical = vertical;   // the left ruler makes vertical guides
    if (sendCommandQuiet({{"action", "guideCreate"}, {"kind", guideVertical ? "vertical" : "horizontal"},
                          {"value", guideVertical ? doc.x() : doc.y()}})) {
        m_guideDragging = true;
        m_guideDragVertical = guideVertical;
        syncCanvasChrome(sessionState());
    }
}

void SessionWindow::rulerMouseMove(QMouseEvent *event, QWidget *ruler) {
    if (!m_guideDragging || !m_canvasWidget) return;
    const QPointF doc = documentPoint(m_canvasWidget->mapFrom(ruler, event->position().toPoint()));
    sendCommandQuiet({{"action", "guideMove"}, {"value", m_guideDragVertical ? doc.x() : doc.y()}});
    syncCanvasChrome(sessionState());
}

void SessionWindow::rulerMouseRelease(QMouseEvent *event, QWidget *ruler) {
    if (!m_guideDragging || !m_canvasWidget) return;
    const QPointF at = m_canvasWidget->mapFrom(ruler, event->position().toPoint());
    // EditorCanvas.isOverRuler: released left of or above the canvas.
    sendCommandQuiet({{"action", "guideFinish"}, {"enabled", m_showsRulers && (at.x() < 0 || at.y() < 0)}});
    m_guideDragging = false;
    syncCanvasChrome(sessionState());
    refreshImage();
}

/// The session's canvas chrome: whether the rulers show (and so the canvas's size), the grid, guides and snap lines.
void SessionWindow::syncCanvasChrome(const QJsonObject &state) {
    const bool hasDocument = state.value("width").toInt() > 0;
    const bool rulers = state.value("showsRulers").toBool() && hasDocument;
    m_showsGrid = state.value("showsGrid").toBool();
    m_showsGuides = state.value("showsGuides").toBool();
    m_canEditGuides = state.value("canEditGuides").toBool();
    m_guides.clear();
    for (const QJsonValue &v : state.value("guides").toArray())
        m_guides.append({v.toObject().value("vertical").toBool(), v.toObject().value("position").toDouble()});
    const QJsonArray snap = state.value("snapLines").toArray();
    m_snapXs.clear(); m_snapYs.clear();
    for (const QJsonValue &v : snap.at(0).toArray()) m_snapXs << v.toDouble();
    for (const QJsonValue &v : snap.at(1).toArray()) m_snapYs << v.toDouble();
    if (rulers != m_showsRulers && m_rulerCorner) {
        m_showsRulers = rulers;
        for (QWidget *w : {m_rulerCorner, m_rulerH, m_rulerV}) w->setVisible(rulers);
    }
    if (m_rulerH && m_showsRulers) { m_rulerH->update(); m_rulerV->update(); }
    if (m_canvasWidget) m_canvasWidget->update();
}



/// Where the document sits on the canvas: upstream's CanvasViewport.documentRect (zoom 1 = one image pixel per device
/// pixel, centered, offset by the pan).
QRectF SessionWindow::canvasTargetRect() const {
    if (m_image.isNull() || m_sessionHandle == 0) return QRectF();
    double v[6] = {};
    if (compositor_session_viewport(m_sessionHandle, v) != 0) return QRectF();
    const QSize canvasSize = m_canvasWidget ? m_canvasWidget->size() : size();
    const double pointsPerPixel = v[0] / std::max(1.0, v[3]);
    const double displayW = docWidth() * pointsPerPixel, displayH = docHeight() * pointsPerPixel;
    return QRectF(canvasSize.width() / 2.0 - displayW / 2.0 + v[1], canvasSize.height() / 2.0 - displayH / 2.0 + v[2],
                  displayW, displayH);
}

/// EditorCanvas.syncGeometry: the viewport learns the canvas's size and backing scale (and refits while following fit).
void SessionWindow::syncViewportGeometry() {
    if (m_sessionHandle == 0 || !m_canvasWidget) return;
    compositor_session_viewport_update(m_sessionHandle, 0, m_canvasWidget->width(), m_canvasWidget->height(),
                                       m_canvasWidget->devicePixelRatioF());
    compositor_canvas_resize(m_sessionHandle, m_canvasWidget->width(), m_canvasWidget->height(), m_canvasWidget->devicePixelRatioF());
}

double SessionWindow::viewportZoom() const {
    double v[6] = {};
    if (m_sessionHandle == 0 || compositor_session_viewport(m_sessionHandle, v) != 0) return 1.0;
    return v[0];
}

/// EditorCanvas.scrollWheel: Ctrl (⌘) or Alt zooms about the pointer, otherwise the wheel pans.
void SessionWindow::canvasWheelEvent(QWheelEvent *event) {
    event->accept();
    if (m_sessionHandle == 0 || m_image.isNull() || m_painting) return;
    // Precise (touchpad) deltas are points already; a wheel notch is 120 eighths of a degree, taken as AppKit's line.
    const bool precise = !event->pixelDelta().isNull();
    const QPointF delta = precise ? QPointF(event->pixelDelta()) : QPointF(event->angleDelta()) / 120.0;
    if (event->modifiers() & (Qt::ControlModifier | Qt::AltModifier)) {
        // Alt turns a vertical wheel into a horizontal one under some platforms; take whichever axis moved.
        const double dy = delta.y() != 0 ? delta.y() : delta.x();
        changeViewport(2, viewportZoom() * std::exp(dy * (precise ? 0.015 : 0.15)), event->position().x(), event->position().y());
    } else {
        const double multiplier = precise ? 1.0 : 12.0 * 3;
        changeViewport(4, delta.x() * multiplier, delta.y() * multiplier);
    }
}

/// A viewport change (upstream session.fit / zoom / zoomKeyboard / viewport.translate), then the canvas, rulers and
/// status catch up; a zoomed-in huge document gets a sharper composite.
void SessionWindow::changeViewport(int op, double a, double b, double c) {
    if (m_sessionHandle == 0) return;
    syncViewportGeometry();
    compositor_session_viewport_update(m_sessionHandle, op, a, b, c);
    updateStatusTelemetry();
    if (m_canvasWidget) m_canvasWidget->update();
}

QPointF SessionWindow::documentToCanvasPoint(const QPointF &docPoint) const {
    const QRectF target = canvasTargetRect();
    if (m_image.isNull() || target.width() <= 0 || target.height() <= 0) return docPoint;
    return QPointF(target.left() + docPoint.x() * target.width() / docWidth(),
                   target.top() + docPoint.y() * target.height() / docHeight());
}

QPointF SessionWindow::documentPoint(const QPointF &windowPoint) const {
    if (m_image.isNull()) return QPointF();
    const QRectF target = canvasTargetRect();
    if (target.width() <= 0 || target.height() <= 0) return QPointF();
    const QPointF local = windowPoint - target.topLeft();
    return QPointF(local.x() * docWidth() / target.width(),
                   local.y() * docHeight() / target.height());
}

void SessionWindow::canvasPaintEvent(QPaintEvent *event, QWidget *canvas) {
    PERF_SCOPE("canvasPaintEvent");
    // Zoomed in past the detail the display image has: re-composite at the finer scale (after this paint).
    if (!m_image.isNull() && m_displayScale < 1.0 && desiredDisplayScale() > m_displayScale && !m_rescalePending) {
        m_rescalePending = true;
        QTimer::singleShot(0, this, [this] { m_rescalePending = false; refreshImage(); });
    }
    Q_UNUSED(event);
    QPainter p(canvas);
    // EditorCanvas.draw: the surround, then the document with its shadow, dark checkerboard and hairline.
    p.fillRect(canvas->rect(), QColor::fromRgbF(0.105, 0.105, 0.105));

    if (m_image.isNull()) return;

    const QRectF target = canvasTargetRect();
    const QRect targetI = target.toRect();

    // Shadow: offset (0, 3), blur 14, black at 35% (a cached blurred rounded rect, nine-sliced to the canvas size).
    {
        static QPixmap shadowTile;
        const int blur = 14, core = 8;
        if (shadowTile.isNull()) {
            QImage tile(QSize(core + blur * 4, core + blur * 4), QImage::Format_ARGB32_Premultiplied);
            tile.fill(Qt::transparent);
            QImage solid = tile;
            { QPainter sp(&solid); sp.fillRect(QRect(blur * 2, blur * 2, core, core), QColor(0, 0, 0, 89)); }
            // Three box blurs approximate the Gaussian Core Graphics uses.
            const int radius = blur / 3;
            for (int pass = 0; pass < 3; ++pass) {
                for (int axis = 0; axis < 2; ++axis) {
                    QImage out = solid;
                    for (int y = 0; y < solid.height(); ++y)
                        for (int x = 0; x < solid.width(); ++x) {
                            int sum = 0, n = 0;
                            for (int k = -radius; k <= radius; ++k) {
                                const int xx = axis ? x : x + k, yy = axis ? y + k : y;
                                if (xx < 0 || yy < 0 || xx >= solid.width() || yy >= solid.height()) { ++n; continue; }
                                sum += qAlpha(solid.pixel(xx, yy)); ++n;
                            }
                            out.setPixel(x, y, qRgba(0, 0, 0, sum / n));
                        }
                    solid = out;
                }
            }
            shadowTile = QPixmap::fromImage(solid);
        }
        const QRect shadowRect = targetI.translated(0, 3);
        const int m = blur * 2, c = core / 2, t = shadowTile.width();
        const int e = m + c;   // slice size: from the tile edge to the middle of the solid core
        auto slice = [&](const QRect &dst, const QRect &src) { if (dst.width() > 0 && dst.height() > 0) p.drawPixmap(dst, shadowTile, src); };
        const QRect r = shadowRect.adjusted(-m + c, -m + c, m - c, m - c);   // area the blurred edges cover
        slice(QRect(r.left(), r.top(), e, e), QRect(0, 0, e, e));
        slice(QRect(r.right() - e + 1, r.top(), e, e), QRect(t - e, 0, e, e));
        slice(QRect(r.left(), r.bottom() - e + 1, e, e), QRect(0, t - e, e, e));
        slice(QRect(r.right() - e + 1, r.bottom() - e + 1, e, e), QRect(t - e, t - e, e, e));
        slice(QRect(r.left() + e, r.top(), r.width() - 2 * e, e), QRect(e - 1, 0, 2, e));
        slice(QRect(r.left() + e, r.bottom() - e + 1, r.width() - 2 * e, e), QRect(e - 1, t - e, 2, e));
        slice(QRect(r.left(), r.top() + e, e, r.height() - 2 * e), QRect(0, e - 1, e, 2));
        slice(QRect(r.right() - e + 1, r.top() + e, e, r.height() - 2 * e), QRect(t - e, e - 1, e, 2));
    }

    // Transparency: 10-point tiles of white 0.30 and 0.35, anchored at the canvas's corner.
    p.fillRect(target, QColor::fromRgbF(0.30, 0.30, 0.30));
    {
        const QRectF visible = target.intersected(QRectF(canvas->rect()));
        const double tile = 10;
        const int minX = int(std::floor((visible.left() - target.left()) / tile)), maxX = int(std::ceil((visible.right() - target.left()) / tile));
        const int minY = int(std::floor((visible.top() - target.top()) / tile)), maxY = int(std::ceil((visible.bottom() - target.top()) / tile));
        p.save();
        p.setClipRect(target);
        const QColor light = QColor::fromRgbF(0.35, 0.35, 0.35);
        for (int row = minY; row < maxY; ++row)
            for (int column = minX; column < maxX; ++column)
                if (((row + column) & 1) == 0)
                    p.fillRect(QRectF(target.left() + column * tile, target.top() + row * tile, tile, tile), light);
        p.restore();
    }

    // From 200% (two screen pixels per document pixel) the pixels are hard-edged (EditorCanvas.crispZoom).
    p.setRenderHint(QPainter::SmoothPixmapTransform, viewportZoom() < 2.0);
    { PERF_SCOPE("canvas:image"); p.drawImage(target, m_image); }

    // Hairline: white at 13%, one device pixel.
    {
        QPen hairline(QColor(255, 255, 255, 33));
        hairline.setWidthF(1.0 / canvas->devicePixelRatioF());
        hairline.setCosmetic(false);
        p.setPen(hairline);
        p.setBrush(Qt::NoBrush);
        const double inset = 0.5 / canvas->devicePixelRatioF();
        p.drawRect(target.adjusted(inset, inset, -inset, -inset));
    }

    // Upstream's TransformOverlay, drawn by the hosted CanvasView: grid, guides, crop, gradient line, transform
    // handles, the selection's marching ants, the lasso or marquee being drawn, snap lines. Kept between paints: only
    // what its views invalidated is drawn again (AppKit's dirty rects), all of it when something else changed.
    {
        PERF_SCOPE("overlay");
        const int w = canvas->width(), h = canvas->height();
        std::array<double, 6> viewport{};
        compositor_session_viewport(m_sessionHandle, viewport.data());
        if (w > 0 && h > 0) {
            double dirty[4] = {};
            if (!m_overlayCacheValid || m_overlayCache.size() != QSize(w, h) || viewport != m_overlayViewport) {
                if (m_overlayCache.size() != QSize(w, h)) m_overlayCache = QImage(w, h, QImage::Format_RGBA8888_Premultiplied);
                const size_t capacity = size_t(w) * size_t(h) * 4;
                m_overlayCacheValid = compositor_canvas_overlay(m_sessionHandle, w, h, m_overlayCache.bits(), capacity) == int64_t(capacity);
                m_overlayViewport = viewport;
            } else if (compositor_canvas_overlay_invalid(m_sessionHandle, dirty)) {
                const QRect region = QRectF(dirty[0], dirty[1], dirty[2], dirty[3]).toAlignedRect() & QRect(0, 0, w, h);
                if (!region.isEmpty()) {
                    const size_t capacity = size_t(region.width()) * size_t(region.height()) * 4;
                    QImage patch(region.size(), QImage::Format_RGBA8888_Premultiplied);
                    if (compositor_canvas_overlay_region(m_sessionHandle, region.x(), region.y(), region.width(), region.height(),
                                                         patch.bits(), capacity) == int64_t(capacity)) {
                        QPainter cache(&m_overlayCache);
                        cache.setCompositionMode(QPainter::CompositionMode_Source);
                        cache.drawImage(region.topLeft(), patch);
                    } else {
                        m_overlayCacheValid = false;
                    }
                }
            }
            if (m_overlayCacheValid) p.drawImage(0, 0, m_overlayCache);
        }
    }
}

/// The overlay views that asked to be redrawn since the last paint (a brush circle following the pointer, marching
/// ants stepping): just that part of the canvas repaints.
void SessionWindow::updateInvalidOverlay() {
    if (!m_canvasWidget || m_sessionHandle == 0) return;
    double dirty[4] = {};
    if (!m_overlayCacheValid) return;   // whatever invalidated it asked for a full repaint already
    if (compositor_canvas_overlay_invalid(m_sessionHandle, dirty))
        m_canvasWidget->update(QRectF(dirty[0], dirty[1], dirty[2], dirty[3]).toAlignedRect().adjusted(-1, -1, 1, 1));
}

/// The tools upstream's CanvasView handles itself here (its EditorCanvas mouse code, unmodified); the rest are still
/// the shell's. Space held pans, as the shell does it.
bool SessionWindow::routesToUpstreamCanvas() const {
    if (m_spaceHandActive || m_colorPickerOpen || m_pixelSampler) return false;
    switch (m_tool) {
    case Tool::Move: case Tool::Marquee: case Tool::Lasso: case Tool::Magic: case Tool::Crop:
    case Tool::Brush: case Tool::SpotHealing: case Tool::CloneStamp: case Tool::Smear:
    case Tool::Gradient: case Tool::Eyedropper: case Tool::Zoom: case Tool::Hand: case Tool::Shape: case Tool::Type:
        return true;
    default: return false;
    }
}

/// A pointer event for the hosted CanvasView, then the shell catches up with what it changed.
void SessionWindow::sendUpstreamCanvasMouse(int kind, QMouseEvent *event, int clickCount) {
    PERF_SCOPE(kind == 3 ? "canvasMouse:hover" : kind == 1 ? "canvasMouse:drag" : "canvasMouse:press/release");
    syncViewportGeometry();
    const int cursor = compositor_canvas_mouse(m_sessionHandle, kind, event->position().x(), event->position().y(),
                                               chordBits(event->modifiers()), clickCount);
    // Upstream's cursor for what is under the pointer (a custom picture — a selection tool's — shows as a crosshair).
    static const Qt::CursorShape shapes[] = {Qt::ArrowCursor, Qt::IBeamCursor, Qt::CrossCursor, Qt::OpenHandCursor,
        Qt::ClosedHandCursor, Qt::PointingHandCursor, Qt::SizeHorCursor, Qt::SizeVerCursor, Qt::SizeFDiagCursor,
        Qt::SizeBDiagCursor, Qt::CrossCursor};
    bool pictured = false;
    if (m_canvasWidget && cursor == 10) {
        // A cursor of upstream's own (a selection tool's, the eyedropper, the zoom magnifier): its picture.
        int32_t w = 0, h = 0;
        double hx = 0, hy = 0;
        const int64_t size = compositor_canvas_cursor_image(&w, &h, &hx, &hy, nullptr, 0);
        if (size > 0 && size == int64_t(w) * h * 4) {
            QByteArray bytes(qsizetype(size), Qt::Uninitialized);
            compositor_canvas_cursor_image(&w, &h, &hx, &hy, reinterpret_cast<uint8_t *>(bytes.data()), bytes.size());
            if (bytes != m_cursorPicture) {
                m_cursorPicture = bytes;
                const QImage image(reinterpret_cast<const uchar *>(m_cursorPicture.constData()), w, h, w * 4, QImage::Format_RGBA8888_Premultiplied);
                m_canvasWidget->setCursor(QCursor(QPixmap::fromImage(image.copy()), qRound(hx), qRound(hy)));
            }
            pictured = true;
        }
    }
    if (!pictured) {
        m_cursorPicture.clear();
        if (m_canvasWidget && cursor >= 0 && cursor <= 10 && m_canvasWidget->cursor().shape() != shapes[cursor])
            m_canvasWidget->setCursor(shapes[cursor]);
    }
    if (kind == 3) { updateInvalidOverlay(); return; }
    invalidateOverlay();
    compositor_pump_main();
    // Mid-stroke, only the area the brush changed is re-rendered (as EditorCanvas redraws its dirty rect).
    const bool brush = m_tool == Tool::Brush || m_tool == Tool::SpotHealing || m_tool == Tool::CloneStamp || m_tool == Tool::Smear;
    if (brush && kind == 1) { scheduleStrokeRefresh(); if (m_canvasWidget) m_canvasWidget->update(); return; }
    refreshImage();
    if (kind == 2 || kind == 0) {
        syncToolFromSession();    // a double-click on live text switches to the Type tool, as on the Mac
        syncTextEditor();         // the shell's inline editor follows the session's text draft
        refreshLayers(); updateOptionsBar();   // refreshLayers() brings the Layers panel along
    }
    if (m_canvasWidget) m_canvasWidget->update();
}

void SessionWindow::canvasMousePressEvent(QMouseEvent *event, QWidget *canvas) {
    Q_UNUSED(canvas);
    if (event->button() == Qt::LeftButton && routesToUpstreamCanvas()) {
        m_upstreamCanvasDrag = true;
        sendUpstreamCanvasMouse(0, event, 1);
        return;
    }
    m_currentPoint = documentPoint(event->position());
    mousePressEvent(event);
    if (m_canvasWidget) m_canvasWidget->update();
}

void SessionWindow::canvasMouseMoveEvent(QMouseEvent *event, QWidget *canvas) {
    Q_UNUSED(canvas);
    if (m_upstreamCanvasDrag) { sendUpstreamCanvasMouse(1, event, 1); return; }
    if (!m_painting && routesToUpstreamCanvas()) { sendUpstreamCanvasMouse(3, event, 0); return; }
    m_currentPoint = documentPoint(event->position());
    mouseMoveEvent(event);
    // Mid-stroke, scheduleStrokeRefresh() repaints just the changed area; a whole-canvas repaint per mouse move
    // (the full document image rescaled) would cost more than the stroke itself.
    if (m_canvasWidget && !isBrushStrokeActive()) m_canvasWidget->update();
}

bool SessionWindow::isBrushStrokeActive() const {
    return m_painting && !m_spaceHandActive
        && (m_tool == Tool::Brush || m_tool == Tool::CloneStamp || m_tool == Tool::SpotHealing || m_tool == Tool::Smear);
}

void SessionWindow::canvasMouseReleaseEvent(QMouseEvent *event, QWidget *canvas) {
    Q_UNUSED(canvas);
    if (m_upstreamCanvasDrag && event->button() == Qt::LeftButton) {
        m_upstreamCanvasDrag = false;
        sendUpstreamCanvasMouse(2, event, 1);
        return;
    }
    m_currentPoint = documentPoint(event->position());
    mouseReleaseEvent(event);
    if (m_canvasWidget) m_canvasWidget->update();
}

void SessionWindow::canvasTabletEvent(QTabletEvent *event, QWidget *canvas) {
    Q_UNUSED(canvas);
    tabletEvent(event);
    if (m_canvasWidget && !(event->type() == QEvent::TabletMove && isBrushStrokeActive())) m_canvasWidget->update();
}

void SessionWindow::canvasDragEnterEvent(QDragEnterEvent *event, QWidget *canvas) {
    Q_UNUSED(canvas);
    dragEnterEvent(event);
}

void SessionWindow::canvasDropEvent(QDropEvent *event, QWidget *canvas) {
    Q_UNUSED(canvas);
    dropEvent(event);
}

void SessionWindow::paintEvent(QPaintEvent *event) {
    if (m_canvasWidget) {
        QMainWindow::paintEvent(event);
    } else {
        canvasPaintEvent(event, this);
    }
}

QJsonObject SessionWindow::sessionState() const {
    PERF_SCOPE("sessionState");
    const int64_t size = compositor_session_state(m_sessionHandle, nullptr, 0);
    if (size <= 0 || size > 4 * 1024 * 1024) return {};
    QByteArray bytes(static_cast<qsizetype>(size), Qt::Uninitialized);
    if (compositor_session_state(m_sessionHandle, reinterpret_cast<uint8_t *>(bytes.data()), bytes.size()) != size) return {};
    return QJsonDocument::fromJson(bytes).object();
}

bool SessionWindow::sendCommand(const QJsonObject &command) {
    PERF_SCOPE("sendCommand");
    if (m_sessionHandle == 0) return false;
    QJsonObject payload = command;
    payload.insert("version", 1);
    const QByteArray bytes = QJsonDocument(payload).toJson(QJsonDocument::Compact);
    ++m_commandDepth;
    const int result = compositor_session_command(m_sessionHandle,
        reinterpret_cast<const uint8_t *>(bytes.constData()), bytes.size());
    --m_commandDepth;
    endBusy();
    if (result != 0) statusBar()->showMessage(sessionState().value("error").toString(tr("Could not apply the operation.")), 5000);
    return result == 0;
}

/// While a command waits on background work: paint, animate the status line, take no input (a click can't start a
/// second command inside the first).
void SessionWindow::pumpWhileBusy() {
    if (!m_busy) {
        m_busy = true;
        QApplication::setOverrideCursor(Qt::BusyCursor);
        statusBar()->showMessage(tr("Working…"));
    }
    QCoreApplication::processEvents(QEventLoop::ExcludeUserInputEvents);
}

void SessionWindow::endBusy() {
    if (!m_busy || m_commandDepth > 0) return;
    m_busy = false;
    QApplication::restoreOverrideCursor();
    statusBar()->clearMessage();
}

int SessionWindow::docWidth() const { return m_docSize.isValid() ? m_docSize.width() : m_image.width(); }
int SessionWindow::docHeight() const { return m_docSize.isValid() ? m_docSize.height() : m_image.height(); }

/// The scale the canvas image is composited at: full resolution for documents up to 4 MP, otherwise the power of two
/// just above what the current zoom shows (so zooming doesn't re-render constantly) — what upstream's canvas gets from
/// drawing layers through its downsample cache.
double SessionWindow::desiredDisplayScale() const {
    const int w = docWidth(), h = docHeight();
    if (w <= 0 || h <= 0 || qint64(w) * h <= 4000000 || !m_canvasWidget) return 1.0;
    const double shown = canvasTargetRect().width() * m_canvasWidget->devicePixelRatioF() / w;
    if (shown <= 0) return 1.0;
    return std::clamp(std::pow(2.0, std::ceil(std::log2(shown))), 1.0 / 64, 1.0);
}

/// The document composited at `scale` (1: the full composite).
QImage SessionWindow::renderDisplayImage(double scale) {
    if (scale >= 1.0) return renderToQImage(m_sessionHandle, docWidth(), docHeight());
    int32_t w = 0, h = 0;
    const int64_t size = compositor_session_render_scaled(m_sessionHandle, scale, nullptr, 0, &w, &h);
    if (size <= 0 || w <= 0 || h <= 0) return QImage();
    std::vector<uint8_t> rgba(static_cast<size_t>(size));
    if (compositor_session_render_scaled(m_sessionHandle, scale, rgba.data(), rgba.size(), &w, &h) != size) return QImage();
    return straightRGBA(rgba, w, h);
}

/// Exports and copies need every pixel, whatever the canvas shows.
QImage SessionWindow::fullResolutionImage() {
    if (m_displayScale >= 1.0 || m_sessionHandle == 0) return m_image;
    QImage full = renderToQImage(m_sessionHandle, docWidth(), docHeight());
    if (!full.isNull()) { full.setDotsPerMeterX(m_image.dotsPerMeterX()); full.setDotsPerMeterY(m_image.dotsPerMeterY()); }
    return full.isNull() ? m_image : full;
}

void SessionWindow::refreshImage() {
    PERF_SCOPE("refreshImage");
    if (m_sessionHandle == 0) return;
    invalidateOverlay();   // the session changed: whatever the overlay shows may have too
    if (m_strokeRefreshTimer) m_strokeRefreshTimer->stop(); // this full refresh supersedes a pending stroke redraw
    const auto state = sessionState();
    const int width = state.value("width").toInt(), height = state.value("height").toInt();
    syncCanvasChrome(state);
    // ContentView's toolbar: Fit, 100% and the zoom buttons need a document.
    for (const char *name : {"fitCanvas", "actualPixels", "zoomIn", "zoomOut"})
        if (auto *button = m_headerToolBar ? m_headerToolBar->findChild<QPushButton *>(QLatin1String(name)) : nullptr)
            button->setEnabled(width > 0 && height > 0);
    // The tabs show the unsaved-changes dot: re-laid out when that changes, not on every refresh (a relayout repaints
    // the whole header).
    const int modified = state.value("modified").toBool() ? 1 : 0;
    if (m_documentTabBar && modified != m_shownTabModified) {
        m_shownTabModified = modified;
        m_documentTabBar->updateGeometry();
        m_documentTabBar->update();
    }
    // Menu items enable as the session changes, so their shortcuts work when they should (AppKit validates on use).
    // Not per event: once the session settles (a menu opening, or its item being chosen, validates it right then).
    if (!m_appMenus.isEmpty()) {
        if (!m_appMenusSyncTimer) {
            m_appMenusSyncTimer = new QTimer(this);
            m_appMenusSyncTimer->setSingleShot(true);
            m_appMenusSyncTimer->setInterval(120);
            connect(m_appMenusSyncTimer, &QTimer::timeout, this, [this] {
                if (m_upstreamCanvasDrag) { m_appMenusSyncTimer->start(); return; }
                syncAppMenus();
            });
        }
        m_appMenusSyncTimer->start();
    }
    if (width <= 0 || height <= 0) {
        // No document (a new tab, a closed project): nothing to draw but the welcome.
        if (!m_image.isNull() || !m_docSize.isEmpty()) {
            m_image = QImage();
            m_docSize = QSize();
            m_shownRenderRevision = -1;
            if (m_canvasWidget) m_canvasWidget->update();
        }
        updateWelcome();
        updateStatusTelemetry();
        updateOptionsBar();
        return;
    }
    if (qint64(width) * height > 200000000) return;   // upstream DocumentLimits.maxSurfacePixels
    syncViewportGeometry();
    if (m_welcomeContent) updateWelcome();
    // Same composite as the one on screen (a brush setting, a tool, a menu changed nothing visible): no render, no
    // conversion — only the chrome below is brought up to date.
    const int64_t revision = compositor_session_render_revision(m_sessionHandle);
    m_docSize = QSize(width, height);
    const double scale = desiredDisplayScale();
    const bool unchanged = revision >= 0 && revision == m_shownRenderRevision && m_shownRenderHandle == m_sessionHandle
        && !m_image.isNull() && m_displayScale == scale;
    if (unchanged) {
        refreshPanels();
        return;
    }
    QImage rendered = renderDisplayImage(scale);
    if (rendered.isNull()) return;
    m_displayScale = scale;
    m_shownRenderRevision = compositor_session_render_revision(m_sessionHandle);
    m_shownRenderHandle = m_sessionHandle;
    const int dpm = qRound(state.value("resolution").toDouble(72) / 0.0254);
    rendered.setDotsPerMeterX(dpm);
    rendered.setDotsPerMeterY(dpm);
    m_image = rendered;
    if (m_canvasWidget) m_canvasWidget->update(); else update();
    refreshPanels();
}

/// The panels that follow the session (status bar, tool options, layers). Mid-drag on the canvas they catch up at most
/// every 50 ms (the release brings them up to date), so a drag costs the canvas and not a rebuild of every panel.
void SessionWindow::refreshPanels() {
    if (m_upstreamCanvasDrag) {
        if (!m_panelThrottle) {
            m_panelThrottle = new QTimer(this);
            m_panelThrottle->setSingleShot(true);
            m_panelThrottle->setInterval(50);
            connect(m_panelThrottle, &QTimer::timeout, this, [this] { refreshPanels(); });
        }
        if (!m_panelThrottle->isActive()) m_panelThrottle->start();
        if (m_panelThrottleClock.isValid() && m_panelThrottleClock.elapsed() < 50) return;
    }
    if (!m_upstreamCanvasDrag && m_panelThrottle) m_panelThrottle->stop();
    m_panelThrottleClock.start();
    updateStatusTelemetry();
    updateOptionsBar();
    queueLayersRefresh();
}

/// Coalesced: many commands refresh the image, then the layers, in one turn; the layers panel rebuilds once (a direct
/// refreshLayers() in between takes the queued one's place).
void SessionWindow::queueLayersRefresh() {
    if (m_layersRefreshQueued) return;
    m_layersRefreshQueued = true;
    QMetaObject::invokeMethod(this, [this] { if (m_layersRefreshQueued) refreshLayers(); }, Qt::QueuedConnection);
}

// Mid-stroke, every brushMove still reaches the session (so the stroke stays continuous), but the canvas is
// redrawn at most once per frame, and only the composite: session state, options bar, telemetry and the layers
// panel are left for the full refreshImage() the stroke's end triggers.
void SessionWindow::scheduleStrokeRefresh() {
    if (!m_strokeRefreshTimer) {
        m_strokeRefreshTimer = new QTimer(this);
        m_strokeRefreshTimer->setSingleShot(true);
        connect(m_strokeRefreshTimer, &QTimer::timeout, this, [this] {
            m_strokeFrameClock.start();
            if (m_sessionHandle == 0 || m_image.isNull()) { refreshImage(); return; }
            // Brush strokes: re-render and repaint only the area the stroke changed (upstream's EditorCanvas redraws
            // just BrushStroke.dirtyDocumentRect). -3 = no region tracked (e.g. a Liquify warp): whole document below.
            std::vector<uint8_t> &region = m_strokeRegionBuffer;
            region.resize(static_cast<size_t>(m_image.width()) * m_image.height() * 4 + 16);
            // Document rect (x, y, w, h) and the pixel size of the patch, which is at the display scale.
            int32_t rect[6] = {0, 0, 0, 0, 0, 0};
            const int64_t n = compositor_session_render_dirty(m_sessionHandle, rect, region.data(), region.size());
            if (n == 0) return;
            if (n > 0 && n == int64_t(rect[4]) * rect[5] * 4 && m_image.format() == QImage::Format_RGBA8888) {
                const QImage patch = QImage(region.data(), rect[4], rect[5], rect[4] * 4, QImage::Format_RGBA8888_Premultiplied)
                    .convertToFormat(QImage::Format_RGBA8888);
                {
                    QPainter painter(&m_image);
                    painter.setCompositionMode(QPainter::CompositionMode_Source);
                    painter.drawImage(QPointF(rect[0] * m_displayScale, rect[1] * m_displayScale), patch);
                }
                if (m_canvasWidget) {
                    const QRectF target = canvasTargetRect();
                    const double sx = target.width() / docWidth(), sy = target.height() / docHeight();
                    m_canvasWidget->update(QRectF(target.left() + rect[0] * sx, target.top() + rect[1] * sy,
                                                  rect[2] * sx, rect[3] * sy).toAlignedRect().adjusted(-2, -2, 2, 2));
                }
                return;
            }
            QImage rendered = renderDisplayImage(m_displayScale);
            if (rendered.isNull()) { refreshImage(); return; } // size changed under us: take the full path
            rendered.setDotsPerMeterX(m_image.dotsPerMeterX());
            rendered.setDotsPerMeterY(m_image.dotsPerMeterY());
            m_image = rendered;
            if (m_canvasWidget) m_canvasWidget->update();
        });
    }
    if (m_strokeRefreshTimer->isActive()) return;
    // Frame pacing: the next frame is due 16 ms after the previous one *started*, not 16 ms after it finished —
    // otherwise the render time adds to the interval (a 20 ms render at a fixed 16 ms delay is ~27 fps).
    const qint64 sinceLast = m_strokeFrameClock.isValid() ? m_strokeFrameClock.elapsed() : 16;
    m_strokeRefreshTimer->start(static_cast<int>(std::max<qint64>(0, 16 - sinceLast)));
}

void SessionWindow::selectRegion(bool rectangle) {
    QJsonObject command{{"action", rectangle ? "selectRectangle" : "selectEllipse"},
                        {"x", 0}, {"y", 0}, {"width", docWidth()}, {"height", docHeight()}};
    if (sendCommand(command)) refreshImage();
}

bool SessionWindow::setLayerFlag(const char *action, bool on) {
    QJsonObject command{{"action", action}, {"enabled", on}};
    return sendCommand(command);
}

void SessionWindow::refreshLayers() {
    PERF_SCOPE("refreshLayers");
    m_layersRefreshQueued = false;
    if (!m_layersView || !m_layerModel || m_sessionHandle == 0) return;
    const int64_t size = compositor_session_state(m_sessionHandle, nullptr, 0);
    if (size <= 0 || size > 4 * 1024 * 1024) return;
    std::vector<uint8_t> bytes(static_cast<size_t>(size));
    if (compositor_session_state(m_sessionHandle, bytes.data(), bytes.size()) != size) return;
    const QJsonDocument state = QJsonDocument::fromJson(QByteArray(reinterpret_cast<char *>(bytes.data()), bytes.size()));
    if (!state.isObject()) return;
    const QJsonArray layers = state.object().value("layers").toArray();
    const QString active = state.object().value("activeLayerID").toString();

    m_layerGeometries.clear();
    m_activeGeometry = LayerGeometry();
    for (const QJsonValue &value : layers) {
        const QJsonObject layer = value.toObject();
        const QJsonObject t = layer.value("transform").toObject();
        LayerGeometry g;
        g.id = layer.value("id").toString();
        g.isGroup = layer.value("isGroup").toBool(false);
        g.visible = layer.value("visible").toBool(true);
        // Foundation encodes CGPoint/CGSize as [a, b]; accept keyed objects as well.
        auto pair = [](const QJsonValue &v, const char *k0, const char *k1) {
            if (v.isArray()) return QPointF(v.toArray().at(0).toDouble(), v.toArray().at(1).toDouble());
            return QPointF(v.toObject().value(k0).toDouble(), v.toObject().value(k1).toDouble());
        };
        const QPointF origin = pair(t.value("origin"), "x", "y");
        const QPointF extent = pair(t.value("size"), "width", "height");
        g.x = origin.x(); g.y = origin.y(); g.w = extent.x(); g.h = extent.y();
        g.rotation = t.value("rotation").toDouble();
        g.valid = !g.isGroup && g.w >= 1 && g.h >= 1;
        m_layerGeometries.push_back(g);
        if (g.id == active) m_activeGeometry = g;
    }
    syncTransformFields();

    // The list itself (not the layers' geometry, which a move drag changes on every step): unchanged, the model stays.
    QByteArray listKey = active.toUtf8();
    for (const QJsonValue &value : layers) {
        QJsonObject entry = value.toObject();
        entry.remove(QStringLiteral("transform"));
        listKey += QJsonDocument(entry).toJson(QJsonDocument::Compact);
    }
    if (listKey == m_shownLayerListKey && m_layerModel->rowCount() > 0) {
        refreshMenuTitles(state.object());
        updateLayersPanel();
        return;
    }
    m_shownLayerListKey = listKey;

    m_syncingLayers = true;
    m_layerModel->clear();
    m_layerModel->setHorizontalHeaderLabels({tr("Layer"), tr("Visible"), tr("Mask")});

    struct LayerNode {
        QList<QStandardItem *> items;
        QString id;
        QString parentId;
        bool isGroup = false;
        bool hasMask = false;
        bool maskEnabled = false;
        bool visible = true;
        double opacity = 1.0;
    };

    QMap<QString, LayerNode> nodeMap;
    QList<QString> order;

    for (int i = 0; i < layers.size(); ++i) {
        const QJsonObject layer = layers.at(i).toObject();
        const QString id = layer.value("id").toString();
        const QString name = layer.value("name").toString();
        const QString parentId = layer.value("parentID").toString();
        const bool isGroup = layer.value("isGroup").toBool(false);
        const bool visible = layer.value("visible").toBool(true);
        const bool hasMask = layer.value("hasMask").toBool(false);
        const bool maskEnabled = hasMask && layer.value("maskEnabled").toBool(true);
        const double opacity = layer.value("opacity").toDouble(1.0);

        auto *nameItem = new QStandardItem(name);
        nameItem->setEditable(true);
        nameItem->setData(id, Qt::UserRole);
        nameItem->setData(isGroup, Qt::UserRole + 1);
        nameItem->setData(hasMask, Qt::UserRole + 2);
        nameItem->setData(maskEnabled, Qt::UserRole + 3);
        nameItem->setData(parentId, Qt::UserRole + 4);

        if (isGroup) {
            nameItem->setData(tr("Folder"), LayerItemDelegate::SubtitleRole);
            nameItem->setToolTip(tr("Group / Folder"));
        } else {
            nameItem->setToolTip(tr("Raster Layer"));
            const QByteArray idBytes = id.toUtf8();
            size_t assetW = 0, assetH = 0;
            // Thumbnails copy each layer's full pixels: only worth it while this legacy list is the one on screen
            // (the SwiftUI Layers panel draws its own). Otherwise every refresh copied megabytes per layer for nothing.
            const bool legacyListShown = m_layersStack && m_layersStack->currentWidget() == m_legacyLayersPanel;
            const int64_t assetBytes = !legacyListShown ? 0 : compositor_session_export_layer(
                m_sessionHandle, reinterpret_cast<const uint8_t *>(idBytes.constData()), idBytes.size(), 0,
                nullptr, 0, &assetW, &assetH);
            if (assetBytes > 0 && assetW > 0 && assetH > 0 && layers.size() <= 64
                && static_cast<size_t>(assetBytes) == assetW * assetH * 4) {
                nameItem->setData(tr("%1 × %2 px").arg(assetW).arg(assetH), LayerItemDelegate::SubtitleRole);
                std::vector<uint8_t> pixels(static_cast<size_t>(assetBytes));
                if (compositor_session_export_layer(m_sessionHandle, reinterpret_cast<const uint8_t *>(idBytes.constData()),
                                                    idBytes.size(), 0, pixels.data(), pixels.size(), &assetW, &assetH) == assetBytes) {
                    const QImage full(pixels.data(), static_cast<int>(assetW), static_cast<int>(assetH),
                                      static_cast<qsizetype>(assetW * 4), QImage::Format_RGBA8888_Premultiplied);
                    nameItem->setData(QPixmap::fromImage(full.scaled(72, 72, Qt::KeepAspectRatio, Qt::FastTransformation)),
                                      LayerItemDelegate::ThumbnailRole);
                }
            } else {
                nameItem->setData(tr("%1 × %2 px").arg(state.object().value("width").toInt()).arg(state.object().value("height").toInt()),
                                  LayerItemDelegate::SubtitleRole);
            }
        }

        auto *visItem = new QStandardItem();
        visItem->setEditable(false);
        visItem->setCheckable(true);
        visItem->setCheckState(visible ? Qt::Checked : Qt::Unchecked);
        visItem->setText(visible ? tr("Visible") : tr("Hidden"));

        auto *maskItem = new QStandardItem();
        maskItem->setEditable(false);
        if (hasMask) {
            maskItem->setCheckable(true);
            maskItem->setCheckState(maskEnabled ? Qt::Checked : Qt::Unchecked);
            maskItem->setText(maskEnabled ? tr("Mask: On") : tr("Mask: Off"));
            maskItem->setToolTip(maskEnabled ? tr("Raster mask active") : tr("Raster mask disabled"));
        } else {
            maskItem->setCheckable(false);
            maskItem->setText(QStringLiteral("—"));
            maskItem->setEnabled(false);
        }

        LayerNode node;
        node.items = {nameItem, visItem, maskItem};
        node.id = id;
        node.parentId = parentId;
        node.isGroup = isGroup;
        node.hasMask = hasMask;
        node.maskEnabled = maskEnabled;
        node.visible = visible;
        node.opacity = opacity;

        nodeMap.insert(id, node);
        order.append(id);
    }

    QModelIndex selectedIndex;
    QJsonObject activeLayerObj;

    // The document array is bottom-first; the panel lists the top layer first.
    for (auto it = order.crbegin(); it != order.crend(); ++it) {
        const QString &id = *it;
        const LayerNode &node = nodeMap[id];
        if (!node.parentId.isEmpty() && nodeMap.contains(node.parentId)) {
            QStandardItem *parentItem = nodeMap[node.parentId].items.at(0);
            parentItem->appendRow(node.items);
        } else {
            m_layerModel->invisibleRootItem()->appendRow(node.items);
        }

        if (id == active) {
            selectedIndex = node.items.at(0)->index();
            activeLayerObj.insert("opacity", node.opacity);
            activeLayerObj.insert("visible", node.visible);
            activeLayerObj.insert("hasMask", node.hasMask);
            activeLayerObj.insert("maskEnabled", node.maskEnabled);
        }
    }

    m_layersView->expandAll();
    m_layersView->setColumnHidden(1, true);
    m_layersView->setColumnHidden(2, true);

    if (m_layerCountLabel) {
        m_layerCountLabel->setText(QString::number(order.size()));
    }

    if (selectedIndex.isValid()) {
        m_layersView->setCurrentIndex(selectedIndex);
        m_layersView->selectionModel()->select(selectedIndex, QItemSelectionModel::ClearAndSelect | QItemSelectionModel::Rows);
        m_layersView->scrollTo(selectedIndex);

        const int opVal = qRound(activeLayerObj.value("opacity").toDouble(1.0) * 100);
        m_opacity->setValue(opVal);
        if (m_opacityLabel) m_opacityLabel->setText(QString("%1 %").arg(opVal));
        m_visibleCheck->setChecked(activeLayerObj.value("visible").toBool(true));
        m_maskCheck->setEnabled(activeLayerObj.value("hasMask").toBool(false));
        m_maskCheck->setVisible(activeLayerObj.value("hasMask").toBool(false));
        m_maskCheck->setChecked(activeLayerObj.value("hasMask").toBool(false) && activeLayerObj.value("maskEnabled").toBool(true));
    }

    m_syncingLayers = false;
    refreshMenuTitles(state.object());
    updateLayersPanel();
}


void SessionWindow::setOpacityFromSlider(int value) {
    if (m_opacityLabel) m_opacityLabel->setText(QString("%1 %").arg(value));
    if (m_syncingLayers) return;
    const QByteArray json = QString(R"({"version":1,"action":"setOpacity","value":%1})").arg(value / 100.0, 0, 'f', 3).toUtf8();
    if (compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(json.constData()), json.size()) == 0) refreshImage();
}

QStringList SessionWindow::blendModes() const {
    return {QStringLiteral("Normal"), QStringLiteral("Multiply"), QStringLiteral("Screen"),
            QStringLiteral("Overlay"), QStringLiteral("Darken"), QStringLiteral("Lighten"),
            QStringLiteral("Color Dodge"), QStringLiteral("Color Burn"), QStringLiteral("Hard Light"),
            QStringLiteral("Soft Light"), QStringLiteral("Difference"), QStringLiteral("Exclusion"),
            QStringLiteral("Hue"), QStringLiteral("Saturation"), QStringLiteral("Color"), QStringLiteral("Luminosity")};
}

void SessionWindow::pickBrushColor() {
    const QColor color = m_platform.colors->pick(m_brushColor, tr("Brush color"));
    if (color.isValid()) setBrushColor(color);
}

void SessionWindow::setBrushColor(const QColor &color) { sendPaletteColor(color, false); }

// The brush options live in the session (upstream's options bar edits them there); the shell's controls and keys
// change them through it too, and every stroke start reads them back (syncBrushFromSession).
void SessionWindow::setBrushDiameter(int value) {
    m_brushDiameter = value;
    sendCommandQuiet({{"action", "setBrushSettings"}, {"parameters", QJsonObject{{"diameter", value}}}});
    updateOptionsBar();
}
void SessionWindow::setBrushHardness(int value) {
    m_brushHardness = value;
    sendCommandQuiet({{"action", "setBrushSettings"}, {"parameters", QJsonObject{{"hardness", value / 100.0}}}});
    updateOptionsBar();
}
void SessionWindow::setBrushOpacity(int value) {
    m_brushOpacity = value;
    sendCommandQuiet({{"action", "setBrushSettings"}, {"parameters", QJsonObject{{"opacity", value / 100.0}}}});
    updateOptionsBar();
}

/// Brush diameter / hardness / opacity as the session holds them, into the shell's copies (strokes, tablet, cursor) and
/// the legacy controls — signals blocked, so showing a value never writes it back (clamped to a slider's range).
void SessionWindow::syncBrushFromSession() {
    if (m_sessionHandle == 0) return;
    const QJsonObject state = sessionState();
    if (!state.contains("brushDiameter")) return;
    m_brushDiameter = std::max(1, int(std::lround(state.value("brushDiameter").toDouble())));
    m_brushHardness = int(std::lround(state.value("brushHardness").toDouble() * 100));
    m_brushOpacity = int(std::lround(state.value("brushOpacity").toDouble() * 100));
    auto show = [this](const char *name, int value) {
        if (auto *slider = findChild<QSlider *>(name)) { const QSignalBlocker block(slider); slider->setValue(value); }
        if (auto *spin = findChild<QSpinBox *>(QString(name) + "Spin")) { const QSignalBlocker block(spin); spin->setValue(value); }
    };
    show("brush.diameter", m_brushDiameter);
    show("brush.hardness", m_brushHardness);
    show("brush.opacity", m_brushOpacity);
}

void SessionWindow::setBlendModeFromCombo(int index) {
    if (m_syncingLayers || index < 0) return;
    const QJsonObject command{{"action", "setBlendMode"}, {"kind", blendModes().at(index)}};
    if (sendCommand(command)) refreshImage();
}

void SessionWindow::paintStroke(double x1, double y1, double x2, double y2) {
    const QByteArray begin = QString(
        R"({"version":1,"action":"brushBegin","x":%1,"y":%2,"parameters":{"diameter":%3,"hardness":%4,"opacity":%5,"red":%6,"green":%7,"blue":%8,"erasing":0,"mask":0}})")
        .arg(x1, 0, 'f', 4).arg(y1, 0, 'f', 4)
        .arg(m_brushDiameter).arg(m_brushHardness / 100.0, 0, 'f', 3).arg(m_brushOpacity / 100.0, 0, 'f', 3)
        .arg(m_brushColor.redF(), 0, 'f', 4).arg(m_brushColor.greenF(), 0, 'f', 4).arg(m_brushColor.blueF(), 0, 'f', 4).toUtf8();
    const QByteArray move = QString(R"({"version":1,"action":"brushMove","x":%1,"y":%2})")
        .arg(x2, 0, 'f', 4).arg(y2, 0, 'f', 4).toUtf8();
    if (compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(begin.constData()), begin.size()) != 0) return;
    if (compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(move.constData()), move.size()) != 0) return;
    if (compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(R"({"version":1,"action":"brushEnd"})"), std::strlen(R"({"version":1,"action":"brushEnd"})")) == 0) refreshImage();
}

// Same command mousePressEvent's CloneStamp branch sends for an Option-click.
void SessionWindow::setCloneSource(double x, double y) {
    const QByteArray bytes = QString(R"({"version":1,"action":"cloneSetSource","x":%1,"y":%2})")
        .arg(x, 0, 'f', 4).arg(y, 0, 'f', 4).toUtf8();
    if (compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(bytes.constData()), bytes.size()) == 0) m_hasCloneSource = true;
}

// Same commands mousePressEvent's CloneStamp branch sends for a stroke, plus the move/end paintStroke sends.
void SessionWindow::cloneStroke(double x1, double y1, double x2, double y2) {
    const QByteArray begin = QString(
        R"({"version":1,"action":"brushBegin","kind":"Clone","x":%1,"y":%2,"parameters":{"diameter":%3,"hardness":%4,"opacity":%5,"aligned":1,"sampleAllLayers":0}})")
        .arg(x1, 0, 'f', 4).arg(y1, 0, 'f', 4)
        .arg(m_brushDiameter).arg(m_brushHardness / 100.0, 0, 'f', 3).arg(m_brushOpacity / 100.0, 0, 'f', 3).toUtf8();
    const QByteArray move = QString(R"({"version":1,"action":"brushMove","x":%1,"y":%2})")
        .arg(x2, 0, 'f', 4).arg(y2, 0, 'f', 4).toUtf8();
    if (compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(begin.constData()), begin.size()) != 0) return;
    if (compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(move.constData()), move.size()) != 0) return;
    if (compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(R"({"version":1,"action":"brushEnd"})"), std::strlen(R"({"version":1,"action":"brushEnd"})")) == 0) refreshImage();
}

// Same commands mousePressEvent's SpotHealing branch sends for a stroke, plus the move/end paintStroke sends.
void SessionWindow::healStroke(double x1, double y1, double x2, double y2) {
    const QByteArray begin = QString(
        R"({"version":1,"action":"brushBegin","x":%1,"y":%2,"parameters":{"diameter":%3,"hardness":%4,"opacity":%5,"red":0,"green":0,"blue":0,"healing":1,"healingMode":0}})")
        .arg(x1, 0, 'f', 4).arg(y1, 0, 'f', 4)
        .arg(m_brushDiameter).arg(m_brushHardness / 100.0, 0, 'f', 3).arg(m_brushOpacity / 100.0, 0, 'f', 3).toUtf8();
    const QByteArray move = QString(R"({"version":1,"action":"brushMove","x":%1,"y":%2})")
        .arg(x2, 0, 'f', 4).arg(y2, 0, 'f', 4).toUtf8();
    if (compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(begin.constData()), begin.size()) != 0) return;
    if (compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(move.constData()), move.size()) != 0) return;
    if (compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(R"({"version":1,"action":"brushEnd"})"), std::strlen(R"({"version":1,"action":"brushEnd"})")) == 0) refreshImage();
}

void SessionWindow::setTool(Tool tool) {
    if (m_tool == Tool::Crop && tool != Tool::Crop) {
        cancelCrop();
    }
    if (m_tool == Tool::Type && tool != Tool::Type && m_textEditor && m_textEditor->isVisible()) {
        sendCommandQuiet({{"action", "textFinish"}});   // switching tools applies the text, as upstream does
        syncTextEditor();
        refreshImage();
    }
    m_tool = tool;
    if (m_toolActions.contains(tool) && !m_toolActions[tool]->isChecked()) {
        m_toolActions[tool]->setChecked(true);
    }
    if (m_tool == Tool::Crop && !m_image.isNull() && !m_hasPendingCrop) {
        m_pendingCropRect = QRectF(0, 0, docWidth(), docHeight());
        m_hasPendingCrop = true;
    }
    if (m_sessionHandle != 0) {
        const char *toolName = "move";
        switch (tool) {
        case Tool::Move: toolName = "move"; break;
        case Tool::Marquee: toolName = "marquee"; break;
        case Tool::Lasso: toolName = "lasso"; break;
        case Tool::Magic: toolName = "wand"; break;
        case Tool::Crop: toolName = "crop"; break;
        case Tool::Brush: toolName = "brush"; break;
        case Tool::SpotHealing: toolName = "spotHealing"; break;
        case Tool::CloneStamp: toolName = "cloneStamp"; break;
        case Tool::Smear: toolName = "blur"; break;
        case Tool::Gradient: toolName = "gradient"; break;
        case Tool::Shape: toolName = "shape"; break;
        case Tool::Type: toolName = "type"; break;
        case Tool::Eyedropper: toolName = "eyedropper"; break;
        case Tool::Hand: toolName = "hand"; break;
        case Tool::Zoom: toolName = "zoom"; break;
        case Tool::Idle: toolName = "idle"; break;
        }
        QJsonObject cmdObj;
        cmdObj["version"] = 1;
        cmdObj["action"] = "selectTool";
        cmdObj["kind"] = toolName;
        sendCommand(cmdObj);
    }
    updateOptionsBar();
    updateToolRail();
    updateStatusTelemetry();
    if (m_canvasWidget) m_canvasWidget->update();
}

/// What the canvas does itself (the tools are upstream's CanvasView, see canvasMousePressEvent): sampling into the
/// open color picker, a shell dialog's one-shot pixel sample, and the Space-held temporary hand.
void SessionWindow::mousePressEvent(QMouseEvent *event) {
    if (event->button() != Qt::LeftButton || m_painting) return;
    if (m_colorPickerOpen) {
        // EditorCanvas: with the picker up, a click or drag on the canvas samples the color under the pointer.
        const QPointF at = documentPoint(event->position());
        sendCommandQuiet({{"action", "sampleColorPicker"}, {"x", at.x()}, {"y", at.y()}});
        m_painting = true;
        m_samplingPicker = true;
        updateFloatingPanels();
        return;
    }
    if (m_pixelSampler) {
        auto sample = std::move(m_pixelSampler);
        m_pixelSampler = nullptr;
        if (m_canvasWidget) m_canvasWidget->unsetCursor();
        sample(documentPoint(event->position()));
        return;
    }
    if (m_spaceHandActive) {
        m_painting = true;
        m_panStart = event->position();
    }
}

bool SessionWindow::sendCommandQuiet(const QJsonObject &command) {
    if (m_sessionHandle == 0) return false;
    QJsonObject payload = command;
    payload.insert("version", 1);
    const QByteArray bytes = QJsonDocument(payload).toJson(QJsonDocument::Compact);
    return compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(bytes.constData()), bytes.size()) == 0;
}

/// Move tool: double-click live text to edit it without switching to Type first (upstream 1.2.9).
bool SessionWindow::canvasMouseDoubleClickEvent(QMouseEvent *event, QWidget *canvas) {
    Q_UNUSED(canvas);
    if (event->button() == Qt::LeftButton && routesToUpstreamCanvas()) {
        m_upstreamCanvasDrag = true;
        sendUpstreamCanvasMouse(0, event, 2);   // a double press (closes a polygonal lasso)
        return true;
    }
    if (event->button() != Qt::LeftButton || m_tool != Tool::Move) return false;
    const QPointF point = documentPoint(event->position());
    if (!sendCommandQuiet({{"action", "textEditAt"}, {"x", point.x()}, {"y", point.y()}})) return false;
    m_transformHandle = -1;
    m_painting = false;
    setTool(Tool::Type);
    syncTextEditor();
    refreshImage();
    return true;
}

/// Shows the inline text editor over the session's text draft (or hides it when there is none): the draft's font,
/// size (at the current zoom), colour and alignment, placed where the text will be, as upstream's InlineTextEditor.
void SessionWindow::syncTextEditor() {
    const QJsonObject draft = sessionState().value("textDraft").toObject();
    if (draft.isEmpty() || !m_canvasWidget || m_image.isNull()) {
        if (m_textEditor) m_textEditor->hide();
        return;
    }
    if (!m_textEditor) {
        m_textEditor = new QPlainTextEdit(m_canvasWidget);
        m_textEditor->setObjectName("canvas.textEditor");
        m_textEditor->setFrameShape(QFrame::NoFrame);
        m_textEditor->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
        m_textEditor->setVerticalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
        m_textEditor->setLineWrapMode(QPlainTextEdit::WidgetWidth);
        m_textEditor->installEventFilter(this);
        connect(m_textEditor, &QPlainTextEdit::textChanged, this, [this] {
            if (m_syncingText) return;
            sendCommandQuiet({{"action", "textSetContent"}, {"name", m_textEditor->toPlainText()}});
            layoutTextEditor();
        });
    }
    m_textDraft = draft;
    const QString content = draft.value("content").toString();
    if (m_textEditor->toPlainText() != content) {
        m_syncingText = true;
        m_textEditor->setPlainText(content);
        m_textEditor->moveCursor(QTextCursor::End);   // existing text opens with the cursor after it (1.2.9)
        m_syncingText = false;
    }
    layoutTextEditor();
    m_textEditor->show();
    m_textEditor->raise();
    m_textEditor->setFocus();
}

void SessionWindow::layoutTextEditor() {
    if (!m_textEditor || m_textDraft.isEmpty() || m_image.isNull()) return;
    const QRectF target = canvasTargetRect();
    const double scale = target.width() / docWidth();
    const QJsonArray origin = m_textDraft.value("origin").toArray(), color = m_textDraft.value("color").toArray();
    const double padding = m_textDraft.value("padding").toDouble(12) * scale;
    QFont font(m_textDraft.value("fontName").toString());
    font.setPixelSize(std::max(1, int(std::lround(m_textDraft.value("fontSize").toDouble(72) * scale))));
    m_textEditor->setFont(font);
    const QColor ink = QColor::fromRgbF(color.at(0).toDouble(), color.at(1).toDouble(), color.at(2).toDouble());
    m_textEditor->setStyleSheet(QString("QPlainTextEdit { background: transparent; color: %1; border: 1px dashed rgba(0,122,255,0.8); }").arg(ink.name()));
    const QString alignment = m_textDraft.value("alignment").toString();
    QTextOption option = m_textEditor->document()->defaultTextOption();
    option.setAlignment(alignment == "Center" ? Qt::AlignHCenter : alignment == "Right" ? Qt::AlignRight : Qt::AlignLeft);
    m_textEditor->document()->setDefaultTextOption(option);
    m_textEditor->document()->setDocumentMargin(0);
    const QPointF topLeft = documentToCanvasPoint(QPointF(origin.at(0).toDouble(), origin.at(1).toDouble()));
    const QFontMetricsF metrics(font);
    QSizeF size;
    const QJsonArray box = m_textDraft.value("boxSize").toArray();
    if (box.size() == 2) {
        size = QSizeF(box[0].toDouble() * scale - 2 * padding, box[1].toDouble() * scale - 2 * padding);
    } else {   // point text: as wide as its longest line, as tall as its lines
        double widest = metrics.horizontalAdvance(QStringLiteral("M"));
        const QStringList lines = m_textEditor->toPlainText().split('\n');
        for (const QString &line : lines) widest = std::max(widest, metrics.horizontalAdvance(line));
        size = QSizeF(widest + metrics.averageCharWidth() * 2, metrics.lineSpacing() * std::max<qsizetype>(1, lines.size()) + 4);
    }
    m_textEditor->setGeometry(QRectF(topLeft + QPointF(padding, padding), size).toAlignedRect());
}

/// The gradient line and shape draft the canvas overlays, read back from the session after each change.
void SessionWindow::syncCanvasDrafts() {
    const QJsonObject state = sessionState();
    auto numbers = [](const QJsonValue &v) {
        QVector<double> out;
        for (const QJsonValue &n : v.toArray()) out << n.toDouble();
        return out;
    };
    m_gradientLine = numbers(state.value("gradientLine"));
    const QVector<double> rect = numbers(state.value("shapeRect"));
    m_shapeRect = rect.size() == 4 ? QRectF(rect[0], rect[1], rect[2], rect[3]) : QRectF();
    m_shapeKind = state.value("shapeKind").toString();
    m_shapeLine = numbers(state.value("shapeLine"));
    if (m_canvasWidget) m_canvasWidget->update();
}

void SessionWindow::mouseMoveEvent(QMouseEvent *event) {
    if (!m_painting) return;
    if (m_samplingPicker) {
        const QPointF at = documentPoint(event->position());
        sendCommandQuiet({{"action", "sampleColorPicker"}, {"x", at.x()}, {"y", at.y()}});
        updateFloatingPanels();
        return;
    }
    if (m_spaceHandActive) {
        const QPointF delta = event->position() - m_panStart;
        m_panStart = event->position();
        changeViewport(4, delta.x(), delta.y());
    }
}


void SessionWindow::mouseReleaseEvent(QMouseEvent *event) {
    if (event->button() != Qt::LeftButton || !m_painting) return;
    m_painting = false;
    m_samplingPicker = false;
}

/// A pen is a mouse here, as on the Mac (upstream's canvas takes no pressure): ignored, Qt delivers it as mouse events.
void SessionWindow::tabletEvent(QTabletEvent *event) {
    event->ignore();
}

void SessionWindow::dragEnterEvent(QDragEnterEvent *event) {
    if (event->mimeData()->hasUrls() || event->mimeData()->hasImage()) {
        event->acceptProposedAction();
    }
}

void SessionWindow::dropEvent(QDropEvent *event) {
    if (event->mimeData()->hasUrls()) {
        for (const QUrl &url : event->mimeData()->urls()) {
            // ImageFileDrop.importProviders: dropped files come in as layers (an empty tab takes the first's size).
            if (url.isLocalFile() && importWithUpstream({url.toLocalFile()}, false)) {
                event->acceptProposedAction();
                return;
            }
        }
    } else if (event->mimeData()->hasImage()) {
        QImage img = qvariant_cast<QImage>(event->mimeData()->imageData());
        if (!img.isNull()) {
            QImage rgba = img.convertToFormat(QImage::Format_RGBA8888);
            std::vector<uint8_t> premul(rgba.width() * rgba.height() * 4);
            const uint8_t *src = rgba.constBits();
            for (size_t i = 0; i < premul.size(); i += 4) {
                uint8_t a = src[i + 3];
                premul[i] = (src[i] * a + 127) / 255;
                premul[i + 1] = (src[i + 1] * a + 127) / 255;
                premul[i + 2] = (src[i + 2] * a + 127) / 255;
                premul[i + 3] = a;
            }
            std::string name = "Dropped Layer";
            if (compositor_session_import_rgba(m_sessionHandle, premul.data(), premul.size(),
                                               rgba.width(), rgba.height(),
                                               reinterpret_cast<const uint8_t*>(name.data()), name.size(), 0) == 0) {
                refreshImage();
                refreshLayers();
                event->acceptProposedAction();
                return;
            }
        }
    }
    event->ignore();
}

// IO milestone: Export flattened canvas as PNG using Qt's QImageWriter
// (replaces macOS CGImageDestination/ImageIO).
// IO milestone: Export flattened canvas as PNG via IImageExporter interface (SOLID)
bool SessionWindow::exportPNG(const QString &path) {
    if (m_sessionHandle == 0 || m_image.isNull()) return false;
    auto exporter = ImageExporterRegistry::instance().exporterForFormat("png");
    return exporter && exporter->exportImage(fullResolutionImage(), path);
}

// IO milestone: Export flattened canvas as JPEG via IImageExporter interface (SOLID)
bool SessionWindow::exportJPEG(const QString &path, int quality) {
    if (m_sessionHandle == 0 || m_image.isNull()) return false;
    auto exporter = ImageExporterRegistry::instance().exporterForFormat("jpeg");
    return exporter && exporter->exportImage(fullResolutionImage(), path, quality);
}

// Parity milestone: Export flattened canvas as TIFF via IImageExporter interface (SOLID)
bool SessionWindow::exportTIFF(const QString &path) {
    if (m_sessionHandle == 0 || m_image.isNull()) return false;
    auto exporter = ImageExporterRegistry::instance().exporterForFormat("tiff");
    return exporter && exporter->exportImage(fullResolutionImage(), path);
}

// Parity milestone: Export flattened canvas as WebP via IImageExporter interface (SOLID)
bool SessionWindow::exportWebP(const QString &path, int quality) {
    if (m_sessionHandle == 0 || m_image.isNull()) return false;
    auto exporter = ImageExporterRegistry::instance().exporterForFormat("webp");
    return exporter && exporter->exportImage(fullResolutionImage(), path, quality);
}

// IO milestone: Import image using Qt's QImageReader
// (replaces macOS CGImageSource/CoreImage). Loads image, converts to
// premultiplied RGBA, and imports via compositor_session_import_rgba.
// Upstream's Photoshop import asks before converting what it can't keep (smart objects, unsupported blend modes,
// missing fonts, ...): the list comes here and is shown as upstream's sheet shows it.
static int32_t confirmPhotoshopConversions(const uint8_t *json, size_t length) {
    const QJsonArray rows = QJsonDocument::fromJson(QByteArray(reinterpret_cast<const char *>(json), qsizetype(length))).array();
    QStringList lines;
    for (const QJsonValue &row : rows) {
        const QJsonObject o = row.toObject();
        lines << QStringLiteral("• %1: %2").arg(o.value("layer").toString(), o.value("message").toString());
    }
    // Headless runs (smoke tests, screenshots) answer Import without a dialog, listing what was converted.
    if (qEnvironmentVariableIsSet("COMPOSITOR_AUTO_CONFIRM_IMPORT")) {
        for (const QString &line : lines) fprintf(stderr, "Import conversion: %s\n", qPrintable(line));
        return 1;
    }
    QMessageBox box(QApplication::activeWindow());
    box.setText(QObject::tr("Some parts of this Photoshop file will be converted"));
    box.setInformativeText(lines.join('\n'));
    QPushButton *import = box.addButton(QObject::tr("Import"), QMessageBox::AcceptRole);
    box.addButton(QObject::tr("Cancel"), QMessageBox::RejectRole);
    box.setDefaultButton(import);
    box.exec();
    return box.clickedButton() == import ? 1 : 0;
}

/// Files Qt's image readers don't handle — Photoshop documents, camera RAW, HEIC — go through upstream's importer,
/// which keeps a PSD's layers, masks and text rather than a flattened picture.
static bool needsUpstreamImporter(const QString &path) {
    static const QStringList upstreamOnly = {"psd", "psb", "heic", "heif", "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf",
                                             "sr2", "orf", "raf", "rw2", "rwl", "pef", "ptx", "srw", "x3f", "3fr", "fff", "iiq",
                                             "erf", "kdc", "dcr", "mos", "mef", "mrw", "raw", "gpr"};
    return upstreamOnly.contains(QFileInfo(path).suffix().toLower());
}

bool SessionWindow::importWithUpstream(const QStringList &paths, bool replace) {
    if (m_sessionHandle == 0 || paths.isEmpty()) return false;
    compositor_set_conversion_prompt(&confirmPhotoshopConversions);
    QJsonArray list;
    for (const QString &path : paths) list.append(QFileInfo(path).absoluteFilePath());
    const bool ok = sendCommand({{"action", "importFiles"}, {"paths", list}, {"enabled", replace}});
    refreshImage();
    refreshLayers();
    // Upstream's "Import couldn’t finish" alert, with its reasons (a cancelled import has nothing to report).
    const QString error = ok ? QString() : sessionState().value("error").toString();
    if (!error.isEmpty() && error != QLatin1String("nothing could be imported")) {
        statusBar()->clearMessage();
        QMessageBox box(this);
        box.setIcon(QMessageBox::Warning);
        box.setText(tr("Import couldn’t finish"));
        box.setInformativeText(error);
        box.addButton(tr("OK"), QMessageBox::AcceptRole);
        box.exec();
    }
    return ok;
}

/// Opening an image file (the command line, the desktop): upstream's workspace.receive — into this tab when it is
/// empty, else a new one — through the session's own importer, so the document takes the image's size.
bool SessionWindow::importImage(const QString &path) {
    if (m_sessionHandle == 0) return false;
    if (sessionState().value("width").toInt() > 0) newCanvasTab();
    const bool ok = importWithUpstream({path}, false);
    refreshTabTitle();
    return ok;
}

/// workspace.newCanvas(): a new, empty tab (the New Canvas sheet shows in it until a document is made).
void SessionWindow::newCanvasTab() {
    if (sessionState().value("busy").toBool()) return;
    sendCommandQuiet({{"action", "transformCommit"}});   // upstream commits a pending transform before switching
    const uint64_t handle = compositor_workspace_add_tab();
    addDocumentTab(handle, workspaceTabTitle(handle));
}

void SessionWindow::refreshTabTitle() {
    if (m_activeDocumentIndex < 0 || m_activeDocumentIndex >= static_cast<int>(m_documents.size())) return;
    DocumentTab &doc = m_documents[m_activeDocumentIndex];
    doc.title = workspaceTabTitle(doc.handle);
    if (m_documentTabBar) m_documentTabBar->setTabText(m_activeDocumentIndex, doc.title);
    setWindowTitle(doc.title.isEmpty() ? tr("Compositor") : tr("%1 — Compositor").arg(doc.title));
}

// IO milestone: Save project as .compositor package
// (replaces macOS ProjectStore.save with FileWrapper/NSFileCoordinator).
// Writes manifest.json + layer PNGs + mask PNGs into a directory.
bool SessionWindow::saveProject(const QString &path) {
    if (m_sessionHandle == 0) return false;

    // Export manifest JSON from Swift core
    int64_t manifestSize = compositor_session_export_manifest(m_sessionHandle, nullptr, 0);
    if (manifestSize <= 0) return false;

    std::vector<uint8_t> manifestBytes(static_cast<size_t>(manifestSize));
    int64_t n = compositor_session_export_manifest(m_sessionHandle, manifestBytes.data(), manifestBytes.size());
    if (n != manifestSize) return false;

    QByteArray manifestData(reinterpret_cast<char *>(manifestBytes.data()), manifestSize);
    if (manifestData.size() > 4 * 1024 * 1024) return false;
    QJsonDocument manifestDoc = QJsonDocument::fromJson(manifestData);
    if (manifestDoc.isNull() || !manifestDoc.isObject()) return false;

    const QJsonObject manifest = manifestDoc.object();
    const QString temporaryPath = path + ".tmp-" + QString::number(QCoreApplication::applicationPid());
    QDir temporary(temporaryPath);
    if (temporary.exists() && !temporary.removeRecursively()) return false;
    if (!temporary.mkpath("images")) return false;

    QFile manifestFile(temporary.filePath("manifest.json"));
    if (!manifestFile.open(QIODevice::WriteOnly | QIODevice::Truncate)) return false;
    const QByteArray encodedManifest = QJsonDocument(manifest).toJson(QJsonDocument::Indented);
    if (manifestFile.write(encodedManifest) != encodedManifest.size()) return false;
    manifestFile.close();

    for (const QJsonValue &value : manifest.value("layers").toArray()) {
        const QJsonObject layer = value.toObject();
        const QString idString = layer.value("id").toString();
        const QByteArray id = idString.toUtf8();
        if (id.isEmpty()) return false;
        for (const bool isMask : {false, true}) {
            const QString filename = layer.value(isMask ? "maskFile" : "imageFile").toString();
            if (filename.isEmpty()) continue;
            const QString expected = idString + (isMask ? ".mask.png" : ".png");
            if (filename != expected || QFileInfo(filename).fileName() != filename) return false;

            size_t width = 0, height = 0;
            const int64_t size = compositor_session_export_layer(m_sessionHandle,
                reinterpret_cast<const uint8_t *>(id.constData()), static_cast<size_t>(id.size()),
                isMask ? 1 : 0, nullptr, 0, &width, &height);
            if (size <= 0 || width == 0 || height == 0 || static_cast<uint64_t>(size) > 512ULL * 1024 * 1024) return false;
            std::vector<uint8_t> bytes(static_cast<size_t>(size));
            const int64_t copied = compositor_session_export_layer(m_sessionHandle,
                reinterpret_cast<const uint8_t *>(id.constData()), static_cast<size_t>(id.size()),
                isMask ? 1 : 0, bytes.data(), bytes.size(), &width, &height);
            if (copied != size) return false;

            QImage image;
            if (isMask) {
                image = QImage(static_cast<int>(width), static_cast<int>(height), QImage::Format_Grayscale8);
                for (size_t y = 0; y < height; ++y)
                    std::memcpy(image.scanLine(static_cast<int>(y)), bytes.data() + y * width, width);
            } else {
                image = straightRGBA(bytes, static_cast<int>(width), static_cast<int>(height));
            }
            QImageWriter writer(temporary.filePath("images/" + filename), "PNG");
            if (!writer.write(image)) return false;
        }
    }

    QDir destinationInfo = QFileInfo(path).dir();
    const QString backupPath = path + ".old-" + QString::number(QCoreApplication::applicationPid());
    QDir backup(backupPath);
    if (backup.exists() && !backup.removeRecursively()) return false;
    if (QFileInfo::exists(path) && !destinationInfo.rename(path, backupPath)) return false;
    if (!destinationInfo.rename(temporaryPath, path)) {
        if (QFileInfo::exists(backupPath)) destinationInfo.rename(backupPath, path);
        return false;
    }
    if (QFileInfo::exists(backupPath)) backup.removeRecursively();
    if (!path.endsWith("autosave.comp")) clearAutosave();
    return true;
}

// IO milestone: Load project from .compositor package
// (replaces macOS ProjectStore.load with FileWrapper/NSFileCoordinator).
bool SessionWindow::loadProject(const QString &path) {
    if (m_sessionHandle == 0) return false;

    QDir dir(path);
    const QFileInfo packageInfo(path);
    if (!packageInfo.isDir() || packageInfo.isSymLink()) return false;

    const QFileInfo manifestInfo(dir.filePath("manifest.json"));
    if (!manifestInfo.isFile() || manifestInfo.isSymLink() || manifestInfo.size() > 4 * 1024 * 1024) return false;
    QFile manifestFile(manifestInfo.filePath());
    if (!manifestFile.open(QIODevice::ReadOnly)) return false;
    QByteArray manifestData = manifestFile.readAll();
    manifestFile.close();

    QJsonDocument manifestDoc = QJsonDocument::fromJson(manifestData);
    if (manifestDoc.isNull() || !manifestDoc.isObject()) return false;

    const QJsonObject manifest = manifestDoc.object();
    const uint64_t replacement = compositor_workspace_add_tab();
    if (replacement == 0) return false;
    int32_t rc = compositor_session_import_manifest(replacement,
                                                    reinterpret_cast<const uint8_t *>(manifestData.constData()),
                                                    manifestData.size());
    if (rc != 0) {
        compositor_workspace_close_tab(replacement);
        return false;
    }
    const QFileInfo imagesInfo(dir.filePath("images"));
    if (!imagesInfo.isDir() || imagesInfo.isSymLink()) {
        compositor_workspace_close_tab(replacement);
        return false;
    }
    uint64_t imagePixels = 0, maskPixels = 0;

    for (const QJsonValue &value : manifest.value("layers").toArray()) {
        const QJsonObject layer = value.toObject();
        const QString idString = layer.value("id").toString();
        const QByteArray id = idString.toUtf8();
        if (id.isEmpty()) { compositor_workspace_close_tab(replacement); return false; }
        for (const bool isMask : {false, true}) {
            const QString filename = layer.value(isMask ? "maskFile" : "imageFile").toString();
            if (filename.isEmpty()) continue;
            const QString expected = idString + (isMask ? ".mask.png" : ".png");
            if (filename != expected || QFileInfo(filename).fileName() != filename) {
                compositor_workspace_close_tab(replacement);
                return false;
            }
            const QFileInfo assetInfo(QDir(imagesInfo.filePath()).filePath(filename));
            if (!assetInfo.isFile() || assetInfo.isSymLink() || assetInfo.size() > 512LL * 1024 * 1024) {
                compositor_workspace_close_tab(replacement);
                return false;
            }
            QImageReader reader(assetInfo.filePath());
            if (reader.format().toLower() != QByteArray("png")) {
                compositor_workspace_close_tab(replacement);
                return false;
            }
            const QSize decodedSize = reader.size();
            const uint64_t pixels = decodedSize.isValid()
                ? static_cast<uint64_t>(decodedSize.width()) * static_cast<uint64_t>(decodedSize.height()) : 0;
            uint64_t &usedPixels = isMask ? maskPixels : imagePixels;
            if (!decodedSize.isValid() || decodedSize.width() <= 0 || decodedSize.height() <= 0 ||
                decodedSize.width() > 30'000 || decodedSize.height() > 30'000 ||
                pixels > 100'000'000 || usedPixels > 100'000'000 - pixels) {
                compositor_workspace_close_tab(replacement);
                return false;
            }
            usedPixels += pixels;
            const QImage decoded = reader.read();
            if (decoded.isNull()) { compositor_workspace_close_tab(replacement); return false; }
            if (isMask) {
                const QImage gray = decoded.convertToFormat(QImage::Format_Grayscale8);
                std::vector<uint8_t> pixels(static_cast<size_t>(gray.width()) * gray.height());
                for (int y = 0; y < gray.height(); ++y)
                    std::memcpy(pixels.data() + static_cast<size_t>(y) * gray.width(), gray.constScanLine(y), gray.width());
                rc = compositor_session_import_layer(replacement,
                    reinterpret_cast<const uint8_t *>(id.constData()), static_cast<size_t>(id.size()), 1,
                    pixels.data(), pixels.size(), gray.width(), gray.height());
            } else {
                const QImage rgba = decoded.convertToFormat(QImage::Format_RGBA8888);
                std::vector<uint8_t> pixels(static_cast<size_t>(rgba.sizeInBytes()));
                for (int y = 0; y < rgba.height(); ++y) {
                    const uint8_t *source = rgba.constScanLine(y);
                    uint8_t *target = pixels.data() + static_cast<size_t>(y) * rgba.width() * 4;
                    for (int x = 0; x < rgba.width(); ++x) {
                        const uint8_t alpha = source[x * 4 + 3];
                        target[x * 4] = static_cast<uint8_t>((source[x * 4] * alpha + 127) / 255);
                        target[x * 4 + 1] = static_cast<uint8_t>((source[x * 4 + 1] * alpha + 127) / 255);
                        target[x * 4 + 2] = static_cast<uint8_t>((source[x * 4 + 2] * alpha + 127) / 255);
                        target[x * 4 + 3] = alpha;
                    }
                }
                rc = compositor_session_import_layer(replacement,
                    reinterpret_cast<const uint8_t *>(id.constData()), static_cast<size_t>(id.size()), 0,
                    pixels.data(), pixels.size(), rgba.width(), rgba.height());
            }
            if (rc != 0) { compositor_workspace_close_tab(replacement); return false; }
        }
    }

    // Render the loaded document
    int width = manifest["width"].toInt();
    int height = manifest["height"].toInt();
    if (width <= 0 || height <= 0) { compositor_workspace_close_tab(replacement); return false; }
    QImage rendered = renderToQImage(replacement, width, height);
    if (rendered.isNull()) { compositor_workspace_close_tab(replacement); return false; }
    // Opens as its own tab rather than replacing the current document, same as "New Canvas" / the "+" button.
    addDocumentTab(replacement, QFileInfo(path).completeBaseName(), path);
    sendCommand({{"action", "markSaved"}}); // freshly opened == saved, so closing it right away doesn't ask
    return true;
}

void SessionWindow::deleteSelectedLayers() {
    if (m_sessionHandle == 0 || !m_layersView || !m_layerModel) return;
    const QModelIndexList selectedRows = m_layersView->selectionModel()->selectedRows();
    if (selectedRows.isEmpty()) {
        sendCommand({{"action", "deleteLayer"}});
        refreshImage();
        refreshLayers();
        return;
    }

    QStringList ids;
    for (const QModelIndex &idx : selectedRows) {
        const QString id = idx.data(Qt::UserRole).toString();
        if (!id.isEmpty()) {
            ids.append(id);
        }
    }

    for (const QString &id : ids) {
        sendCommand({{"action", "selectLayer"}, {"layerID", id}});
        sendCommand({{"action", "deleteLayer"}});
    }
    refreshImage();
    refreshLayers();
}

QString SessionWindow::autosaveDirectory() const {
    return m_platform.storage->appDataDirectory() + "/recovery";
}

bool SessionWindow::hasAutosaveRecovery() const {
    const QString recoveryDir = autosaveDirectory();
    const QString manifestPath = recoveryDir + "/autosave.comp/manifest.json";
    return QFileInfo::exists(manifestPath);
}

bool SessionWindow::performAutosave() {
    if (m_commandDepth > 0) return false;   // mid-command (the window paints while a long one works): next time
    if (m_sessionHandle == 0) return false;
    const auto state = sessionState();
    if (!state.value("modified").toBool(false)) return false;

    const QString recoveryDir = autosaveDirectory();
    QDir dir(recoveryDir);
    if (!dir.exists() && !dir.mkpath(".")) return false;

    const QString packagePath = recoveryDir + "/autosave.comp";
    if (!saveProject(packagePath)) return false;

    QJsonObject infoObj{
        {"savedAt", QDateTime::currentDateTimeUtc().toString(Qt::ISODate)},
        {"width", state.value("width").toInt()},
        {"height", state.value("height").toInt()}
    };
    QFile infoFile(recoveryDir + "/autosave.info");
    if (infoFile.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        infoFile.write(QJsonDocument(infoObj).toJson(QJsonDocument::Indented));
        infoFile.close();
    }
    return true;
}

bool SessionWindow::recoverAutosave() {
    if (!hasAutosaveRecovery()) return false;
    const QString packagePath = autosaveDirectory() + "/autosave.comp";
    return loadProject(packagePath);
}

void SessionWindow::clearAutosave() {
    const QString recoveryDir = autosaveDirectory();
    QDir package(recoveryDir + "/autosave.comp");
    if (package.exists()) {
        package.removeRecursively();
    }
    QFile::remove(recoveryDir + "/autosave.info");
}

void SessionWindow::closeEvent(QCloseEvent *event) {
    // Upstream ProjectWorkspace.confirmQuit: ask about each unsaved tab, the one on screen first, then the rest left
    // to right; Cancel on any keeps the window open.
    std::vector<uint64_t> order;
    if (m_activeDocumentIndex >= 0 && m_activeDocumentIndex < static_cast<int>(m_documents.size()))
        order.push_back(m_documents[m_activeDocumentIndex].handle);
    for (const DocumentTab &doc : m_documents)
        if (order.empty() || doc.handle != order.front()) order.push_back(doc.handle);
    for (uint64_t handle : order) {
        const auto it = std::find_if(m_documents.begin(), m_documents.end(),
            [handle](const DocumentTab &doc) { return doc.handle == handle; });
        if (it != m_documents.end() && !confirmDocumentClose(static_cast<int>(it - m_documents.begin()))) {
            event->ignore();
            return;
        }
    }
    clearAutosave();
    QSettings().setValue(QStringLiteral("window/geometry"), saveGeometry());   // reopened where it was left, as macOS does
    QMainWindow::closeEvent(event);
}

/// CompositorApp's window placement: the first launch fills the screen (without going full screen); after that the
/// window reopens at the size and place it was left.
void SessionWindow::restoreWindowPlacement() {
    m_railFitChecked = true;   // the placement decides the size, not the rail
    const QByteArray saved = QSettings().value(QStringLiteral("window/geometry")).toByteArray();
    if (!saved.isEmpty() && restoreGeometry(saved)) return;
    if (const QScreen *display = screen()) {
        const QRect area = display->availableGeometry();
        setGeometry(area);
    }
}

// ---- Move / Transform tool ---------------------------------------------------


void SessionWindow::syncTransformFields() {
    if (!m_xSpin) return;
    const bool enabled = m_activeGeometry.valid;
    for (QSpinBox *spin : {m_xSpin, m_ySpin, m_wSpin, m_hSpin, m_angleSpin}) {
        const QSignalBlocker blocker(spin);
        spin->setEnabled(enabled);
    }
    if (!enabled) return;
    const QSignalBlocker bx(m_xSpin), by(m_ySpin), bw(m_wSpin), bh(m_hSpin), ba(m_angleSpin);
    m_xSpin->setValue(qRound(m_activeGeometry.x));
    m_ySpin->setValue(qRound(m_activeGeometry.y));
    m_wSpin->setValue(qRound(m_activeGeometry.w));
    m_hSpin->setValue(qRound(m_activeGeometry.h));
    m_angleSpin->setValue(qRound(m_activeGeometry.rotation));
}

void SessionWindow::applyTransformFields(int changedField) {
    if (m_syncingLayers || !m_activeGeometry.valid || m_sessionHandle == 0) return;
    LayerGeometry next = m_activeGeometry;
    next.x = m_xSpin->value();
    next.y = m_ySpin->value();
    next.rotation = m_angleSpin->value();
    if (changedField == 2 || changedField == 3) {
        const double aspect = m_activeGeometry.w / std::max(1.0, m_activeGeometry.h);
        if (m_linkCheck && m_linkCheck->isChecked()) {
            if (changedField == 2) { next.w = m_wSpin->value(); next.h = std::max(1.0, std::round(next.w / aspect)); }
            else { next.h = m_hSpin->value(); next.w = std::max(1.0, std::round(next.h * aspect)); }
        } else {
            next.w = m_wSpin->value();
            next.h = m_hSpin->value();
        }
    }
    const QJsonObject command{{"action", "transform"}, {"parameters", QJsonObject{
        {"x", next.x}, {"y", next.y}, {"width", next.w}, {"height", next.h}, {"rotation", next.rotation}}}};
    if (sendCommand(command)) { refreshImage(); refreshLayers(); }
}



void SessionWindow::syncDistortFromSession() {
    m_distortCorners.clear();
    for (const QJsonValue &v : sessionState().value("distortCorners").toArray()) {
        const QJsonArray xy = v.toArray();
        if (xy.size() == 2) m_distortCorners.push_back(QPointF(xy[0].toDouble(), xy[1].toDouble()));
    }
    if (m_distortCorners.size() != 4) m_distortCorners.clear();
}






void SessionWindow::applyDarkTheme() {
    QPalette darkPalette;
    darkPalette.setColor(QPalette::Window, QColor(0x1e, 0x1e, 0x20));
    darkPalette.setColor(QPalette::WindowText, QColor(0xf5, 0xf5, 0xf7));
    darkPalette.setColor(QPalette::Base, QColor(0x24, 0x24, 0x27));
    darkPalette.setColor(QPalette::AlternateBase, QColor(0x2a, 0x2a, 0x2d));
    darkPalette.setColor(QPalette::ToolTipBase, QColor(0x1e, 0x1e, 0x20));
    darkPalette.setColor(QPalette::ToolTipText, QColor(0xf5, 0xf5, 0xf7));
    darkPalette.setColor(QPalette::Text, QColor(0xf5, 0xf5, 0xf7));
    darkPalette.setColor(QPalette::Button, QColor(0x2a, 0x2a, 0x2d));
    darkPalette.setColor(QPalette::ButtonText, QColor(0xf5, 0xf5, 0xf7));
    darkPalette.setColor(QPalette::BrightText, Qt::white);
    darkPalette.setColor(QPalette::Link, QColor(0x00, 0x7a, 0xff));
    darkPalette.setColor(QPalette::Highlight, QColor(0x00, 0x7a, 0xff));
    darkPalette.setColor(QPalette::HighlightedText, Qt::white);
    darkPalette.setColor(QPalette::Disabled, QPalette::Text, QColor(0x6e, 0x6e, 0x73));
    darkPalette.setColor(QPalette::Disabled, QPalette::ButtonText, QColor(0x6e, 0x6e, 0x73));
    darkPalette.setColor(QPalette::Disabled, QPalette::WindowText, QColor(0x6e, 0x6e, 0x73));
    if (qApp) {
        qApp->setPalette(darkPalette);
    }

    const QString qss = QString::fromUtf8(R"(
        QMainWindow {
            background-color: #1e1e1e;
            color: #f5f5f7;
        }
        QWidget {
            color: #f5f5f7;
        }
        QMenuBar {
            background-color: #1e1e20;
            color: #f5f5f7;
            border-bottom: 1px solid #141416;
            padding: 2px 6px;
        }
        QMenuBar::item {
            background: transparent;
            color: #f5f5f7;
            padding: 4px 8px;
            border-radius: 4px;
        }
        QMenuBar::item:selected {
            background-color: #2c2c30;
            color: #ffffff;
        }
        QMenu {
            background-color: #242427;
            color: #f5f5f7;
            border: 1px solid #38383c;
            border-radius: 6px;
            padding: 4px;
        }
        QMenu::item {
            padding: 5px 28px 5px 24px;
            border-radius: 4px;
            color: #f5f5f7;
            background-color: transparent;
        }
        QMenu::item:selected {
            background-color: #007aff;
            color: #ffffff;
        }
        QMenu::item:disabled {
            color: #6e6e73;
            background-color: transparent;
        }
        QMenu::separator {
            height: 1px;
            background-color: #38383c;
            margin: 4px 8px;
        }
        QMenu::indicator {
            width: 14px;
            height: 14px;
            left: 6px;
        }
        QMenu::indicator:checked {
            image: url(CHECKMARK);
        }
        QMenu::right-arrow {
            margin: 5px;
        }
        QMainWindow::separator {
            background-color: #141416;
            width: 1px;
            height: 1px;
            border: none;
            image: none;
        }
        QMainWindow::separator:hover {
            background-color: #141416;
            image: none;
        }
        QToolBar {
            background-color: #1e1e20;
            border: none;
            spacing: 4px;
            padding: 2px;
        }
        QToolBar::extension {
            width: 0px;
            height: 0px;
            border: none;
            background: transparent;
        }
        QToolBar[objectName="toolbar.tools"] {
            background-color: #1e1e20;
            border-right: 1px solid #141416;
            spacing: 10px;
            padding-top: 16px;
            padding-bottom: 12px;
            width: 56px;
            min-width: 56px;
            max-width: 56px;
        }
        QToolBar[objectName="toolbar.tools"] QToolButton {
            background: transparent;
            color: #f5f5f7;
            border: 1px solid transparent;
            border-radius: 7px;
            padding: 0px;
            margin: 0px auto;
            width: 36px;
            height: 36px;
            min-width: 36px;
            min-height: 36px;
            max-width: 36px;
            max-height: 36px;
        }
        QToolBar[objectName="toolbar.tools"] QToolButton:hover {
            background-color: rgba(255, 255, 255, 0.08);
            color: #ffffff;
            border: 1px solid rgba(255, 255, 255, 0.10);
        }
        QToolBar[objectName="toolbar.tools"] QToolButton:checked {
            background-color: rgba(255, 255, 255, 0.15);
            color: #ffffff;
            border: 1px solid rgba(255, 255, 255, 0.18);
            border-radius: 7px;
        }
        QStatusBar {
            background-color: #1e1e20;
            color: #f5f5f7;
            min-height: 30px;
            max-height: 30px;
            padding: 0px 18px;
            border-top: 1px solid #141416;
        }
        QStatusBar QLabel {
            font-size: 11px;
            color: #e5e5e7;
            padding: 0px;
        }
        QToolBar::separator {
            background-color: #2d2d30;
            height: 1px;
            margin: 4px 4px;
        }
        QDockWidget {
            background-color: #1e1e20;
            color: #f5f5f7;
            border: none;
        }
        QDockWidget::title {
            background-color: #1e1e20;
            color: #ffffff;
            padding: 0px;
            height: 0px;
            max-height: 0px;
            border: none;
        }
        QDockWidget > QWidget {
            background-color: #1e1e20;
            border-left: 1px solid #141416;
            border-top: none;
            border-right: none;
            border-bottom: none;
        }
        QTreeView {
            background-color: #1a1a1c;
            alternate-background-color: #202023;
            color: #ffffff;
            border: none;
            outline: 0;
            selection-background-color: #3a3b3f;
            selection-color: #ffffff;
            show-decoration-selected: 1;
        }
        QHeaderView::section {
            background-color: #1e1e20;
            color: #d0d0d5;
            padding: 4px 8px;
            border: none;
            border-bottom: 1px solid #28282c;
            font-size: 11px;
            font-weight: 600;
        }
        QSlider::groove:horizontal {
            height: 4px;
            background: #333336;
            border-radius: 2px;
        }
        QSlider::sub-page:horizontal {
            background: #007aff;
            border-radius: 2px;
        }
        QSlider::handle:horizontal {
            background: #ffffff;
            border: 1px solid #b0b0b5;
            width: 12px;
            height: 12px;
            margin: -4px 0;
            border-radius: 6px;
        }
        QSlider::handle:horizontal:hover {
            background: #f0f0f5;
        }
        QComboBox {
            background-color: #28282b;
            color: #ffffff;
            border: 1px solid #444448;
            border-radius: 4px;
            padding: 3px 8px;
            min-height: 18px;
            font-size: 11px;
        }
        QComboBox:hover {
            border-color: #5a5a60;
        }
        QComboBox::drop-down {
            subcontrol-origin: padding;
            subcontrol-position: top right;
            width: 18px;
            border-left-width: 0px;
        }
        QComboBox QAbstractItemView {
            background-color: #242427;
            color: #ffffff;
            border: 1px solid #38383c;
            selection-background-color: #007aff;
            selection-color: #ffffff;
            padding: 4px;
        }
        QCheckBox {
            color: #f5f5f7;
            font-size: 11px;
            spacing: 6px;
        }
        QCheckBox::indicator {
            width: 14px;
            height: 14px;
            border: 1px solid #4a4a50;
            border-radius: 3px;
            background-color: #28282b;
        }
        QCheckBox::indicator:hover {
            border-color: #65656d;
        }
        QCheckBox::indicator:checked {
            background-color: #007aff;
            border-color: #007aff;
        }
        QSpinBox, QDoubleSpinBox, QLineEdit {
            background-color: #28282b;
            color: #ffffff;
            border: 1px solid #444448;
            border-radius: 4px;
            padding: 2px 4px;
            font-size: 11px;
        }
        QSpinBox:focus, QDoubleSpinBox:focus, QLineEdit:focus {
            border: 1px solid #007aff;
        }
        QPushButton {
            background-color: #2a2a2d;
            color: #ffffff;
            border: 1px solid #38383c;
            border-radius: 4px;
            padding: 4px 10px;
            font-size: 11px;
            font-weight: 500;
        }
        QPushButton:hover {
            background-color: #35353a;
            color: #ffffff;
            border-color: #55555c;
        }
        QPushButton:pressed {
            background-color: #1f1f22;
        }
        /* AppKit's disabled look (dark aqua): labels and control text drop to tertiary, control chrome fades. */
        QWidget:disabled, QLabel:disabled, QCheckBox:disabled {
            color: rgba(255, 255, 255, 0.25);
        }
        QPushButton:disabled {
            color: rgba(255, 255, 255, 0.25);
            background-color: rgba(255, 255, 255, 0.05);
            border-color: rgba(255, 255, 255, 0.06);
        }
        QSpinBox:disabled, QDoubleSpinBox:disabled, QLineEdit:disabled, QComboBox:disabled {
            color: rgba(255, 255, 255, 0.25);
            background-color: rgba(255, 255, 255, 0.03);
            border-color: rgba(255, 255, 255, 0.08);
        }
        QCheckBox::indicator:disabled {
            background-color: rgba(255, 255, 255, 0.04);
            border-color: rgba(255, 255, 255, 0.10);
        }
        QCheckBox::indicator:checked:disabled {
            background-color: rgba(0, 122, 255, 0.35);
            border-color: rgba(0, 122, 255, 0.35);
        }
        QSlider::sub-page:horizontal:disabled {
            background: rgba(255, 255, 255, 0.18);
        }
        QSlider::handle:horizontal:disabled {
            background: #8a8a8e;
            border-color: #6a6a6e;
        }
    )");
    // AppKit marks a checked menu item with a plain ✓.
    const QString styled = QString(qss).replace(QStringLiteral("CHECKMARK"), styleSheetImage(QStringLiteral("menu-check"),
        "<svg xmlns='http://www.w3.org/2000/svg' width='14' height='14' viewBox='0 0 14 14'><path fill='none' stroke='white' "
        "stroke-width='1.7' stroke-linecap='round' stroke-linejoin='round' d='M3 7.4 L5.8 10.2 L11 3.8'/></svg>"));
    if (qApp) {
        qApp->setStyleSheet(styled);
    }
    setStyleSheet(styled);
}

/// ProjectTabButton (ProjectTabs.swift), drawn: a 28-high capsule — white 12% fill and 22% line when active, 3.5% and
/// 8% otherwise — holding the title (12 pt, semibold when active, medium otherwise; 35...155 wide) 11 in from the left
/// and 8 before the close slot, then the 9-pt × (secondary) in a 16-wide slot 5 from the end. Tabs sit 6 apart.
class ProjectTabBar : public QTabBar {
public:
    using QTabBar::QTabBar;
    /// Whether tab `index` has unsaved changes (a 5-pt dot before its title, 5 from it).
    std::function<bool(int)> isModified;
protected:
    static QFont titleFont(const QFont &base, bool active) {
        QFont font = base;
        font.setPixelSize(12);
        font.setWeight(active ? QFont::DemiBold : QFont::Medium);
        return font;
    }
    int labelWidth(int index) const {
        const QFontMetricsF metrics(titleFont(font(), index == currentIndex()));
        const int dot = isModified && isModified(index) ? 10 : 0;
        return qBound(35, int(std::ceil(metrics.horizontalAdvance(tabText(index)))) + dot, 155);
    }
    QSize tabSizeHint(int index) const override { return QSize(labelWidth(index) + 40 + 6, 34); }
    QSize minimumTabSizeHint(int index) const override { return tabSizeHint(index); }
    QRect pillRect(int index) const { return tabRect(index).adjusted(0, 3, -6, -3); }
    QRect closeRect(int index) const { const QRect pill = pillRect(index); return QRect(pill.right() - 5 - 16 + 1, pill.top(), 16, 28); }
    void paintEvent(QPaintEvent *) override {
        QPainter p(this);
        p.setRenderHint(QPainter::Antialiasing, true);
        for (int i = 0; i < count(); ++i) {
            const bool active = i == currentIndex();
            const QRectF pill = QRectF(pillRect(i)).adjusted(0.5, 0.5, -0.5, -0.5);
            p.setPen(QPen(QColor(255, 255, 255, active ? 56 : 20), 1));
            p.setBrush(QColor(255, 255, 255, active ? 31 : 9));
            p.drawRoundedRect(pill, pill.height() / 2, pill.height() / 2);
            p.setFont(titleFont(font(), active));
            p.setPen(QColor(255, 255, 255, 217));
            QRect text(pillRect(i).left() + 11, pillRect(i).top(), labelWidth(i), 28);
            if (isModified && isModified(i)) {
                p.setPen(Qt::NoPen);
                p.setBrush(QColor(255, 255, 255, 217));
                p.drawEllipse(QRectF(text.left(), text.center().y() - 2.0, 5, 5));
                text.setLeft(text.left() + 10);
                p.setPen(QColor(255, 255, 255, 217));
            }
            p.drawText(text, Qt::AlignLeft | Qt::AlignVCenter,
                       QFontMetrics(p.font()).elidedText(tabText(i), Qt::ElideRight, text.width()));
            const QPointF c = QRectF(closeRect(i)).center();
            p.setPen(QPen(QColor(255, 255, 255, m_hoverClose == i ? 217 : 140), 1.5, Qt::SolidLine, Qt::RoundCap));
            p.drawLine(c + QPointF(-3, -3), c + QPointF(3, 3));
            p.drawLine(c + QPointF(3, -3), c + QPointF(-3, 3));
        }
    }
    void mousePressEvent(QMouseEvent *event) override {
        for (int i = 0; i < count(); ++i)
            if (closeRect(i).contains(event->position().toPoint())) { emit tabCloseRequested(i); return; }
        QTabBar::mousePressEvent(event);
    }
    void mouseMoveEvent(QMouseEvent *event) override {
        int hover = -1;
        for (int i = 0; i < count(); ++i) if (closeRect(i).contains(event->position().toPoint())) hover = i;
        if (hover != m_hoverClose) { m_hoverClose = hover; update(); }
        QTabBar::mouseMoveEvent(event);
    }
    void leaveEvent(QEvent *event) override { m_hoverClose = -1; update(); QTabBar::leaveEvent(event); }
private:
    int m_hoverClose = -1;
};

void SessionWindow::setupHeaderBar() {
    m_headerToolBar = addToolBar(tr("Header"));
    m_headerToolBar->setObjectName("toolbar.header");
    m_headerToolBar->setMovable(false);
    // The unified title bar + toolbar of the Mac window: 52 high, the tab strip's 34 centred in it.
    m_headerToolBar->setFixedHeight(52);
    m_headerToolBar->setStyleSheet("QToolBar { background: #1e1e20; border-bottom: 1px solid #141416; spacing: 8px; padding: 0px 10px; }");
    // The window has no native title bar (Qt::FramelessWindowHint, see the constructor) — dragging the header
    // bar's own empty background is the only way left to move the window. See eventFilter().
    m_headerToolBar->installEventFilter(this);

    // macOS Traffic Light dots
    auto *trafficContainer = new QWidget(m_headerToolBar);
    auto *trafficLayout = new QHBoxLayout(trafficContainer);
    trafficLayout->setContentsMargins(4, 0, 8, 0);   // AppKit's buttons: 12 wide, centres 20 apart from x = 20
    trafficLayout->setSpacing(8);

    auto makeDot = [this, trafficContainer](const QString &colorHex, const QString &tooltip, auto clickAction) {
        auto *dot = new QPushButton(trafficContainer);
        dot->setFixedSize(12, 12);
        dot->setToolTip(tooltip);
        dot->setCursor(Qt::PointingHandCursor);
        dot->setStyleSheet(QString(
            "QPushButton { background: %1; border: 1px solid rgba(0, 0, 0, 0.35); border-radius: 6px; padding: 0px; margin: 0px; } "
            "QPushButton:hover { border: 1px solid rgba(0, 0, 0, 0.6); }"
        ).arg(colorHex));
        connect(dot, &QPushButton::clicked, this, clickAction);
        return dot;
    };

    auto *dotClose = makeDot("#ff5f56", tr("Close Window"), [this] { close(); });
    auto *dotMin = makeDot("#ffbd2e", tr("Minimize Window"), [this] { showMinimized(); });
    auto *dotZoom = makeDot("#27c93f", tr("Zoom / Maximize Window"), [this] {
        if (isMaximized()) showNormal(); else showMaximized();
    });

    trafficLayout->addWidget(dotClose);
    trafficLayout->addWidget(dotMin);
    trafficLayout->addWidget(dotZoom);
    m_headerToolBar->addWidget(trafficContainer);

    // + (New document) button: pill shape
    auto *btnNew = new QPushButton(m_headerToolBar);
    btnNew->setObjectName("newCanvasToolbar");
    btnNew->setToolTip(tr("New canvas (Ctrl+N)"));
    btnNew->setFixedSize(28, 28);
    btnNew->setIcon(renderToolVectorIcon(QStringLiteral("plus"), 15, QColor(0xdd, 0xdd, 0xdf)));
    btnNew->setIconSize(QSize(15, 15));
    btnNew->setCursor(Qt::PointingHandCursor);
    btnNew->setStyleSheet(
        "QPushButton { background: rgba(255, 255, 255, 0.08); border: 1px solid rgba(255, 255, 255, 0.12); border-radius: 14px; padding: 0px; } "
        "QPushButton:hover { background: rgba(255, 255, 255, 0.16); } "
        "QPushButton:pressed { background: rgba(255, 255, 255, 0.22); }"
    );
    connect(btnNew, &QPushButton::clicked, this, [this] { newCanvasTab(); });
    m_headerToolBar->addWidget(btnNew);

    // Document Tabs: sleek macOS pills
    m_documentTabBar = new ProjectTabBar(m_headerToolBar);
    m_documentTabBar->setMouseTracking(true);
    static_cast<ProjectTabBar *>(m_documentTabBar)->isModified = [this](int index) {
        return index >= 0 && index < static_cast<int>(m_documents.size()) && isDocumentModified(m_documents[index].handle);
    };
    m_documentTabBar->setObjectName("header.documentTabs");
    m_documentTabBar->setDrawBase(false);
    m_documentTabBar->setExpanding(false);
    m_documentTabBar->setUsesScrollButtons(false);
    // No tabs yet: the document created before this window's UI existed is registered as tab 0 once the whole
    // constructor finishes (see the addDocumentTab call after updateStatusTelemetry()).
    connect(m_documentTabBar, &QTabBar::currentChanged, this, &SessionWindow::switchToDocumentTab);
    connect(m_documentTabBar, &QTabBar::tabCloseRequested, this, &SessionWindow::closeDocumentTab);
    m_headerToolBar->addWidget(m_documentTabBar);

    auto *spacer = new QWidget(m_headerToolBar);
    spacer->setObjectName("header.dragArea");
    spacer->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Preferred);
    // The spacer covers most of the header's empty background, so it needs the drag handler itself.
    spacer->installEventFilter(this);
    m_headerToolBar->addWidget(spacer);

    // Right zoom pill buttons: [Fit] [100%] [🔍-] [🔍+]
    auto makeZoomPill = [this](const QString &text, const QString &objName, const QString &tooltip, const QIcon &icon = QIcon()) {
        auto *btn = new QPushButton(m_headerToolBar);
        btn->setObjectName(objName);
        btn->setToolTip(tooltip);
        btn->setFixedHeight(28);
        btn->setCursor(Qt::PointingHandCursor);
        if (!icon.isNull()) {
            btn->setIcon(icon);
            btn->setIconSize(QSize(14, 14));
            btn->setFixedWidth(28);
            btn->setStyleSheet(
                "QPushButton { background: rgba(255, 255, 255, 0.08); color: #dddddf; border: 1px solid rgba(255, 255, 255, 0.12); border-radius: 14px; padding: 2px; } "
                "QPushButton:hover { background: rgba(255, 255, 255, 0.16); color: #ffffff; } "
                "QPushButton:pressed { background: rgba(255, 255, 255, 0.22); }"
            );
        } else {
            btn->setText(text);
            btn->setStyleSheet(
                "QPushButton { background: rgba(255, 255, 255, 0.08); color: #dddddf; border: 1px solid rgba(255, 255, 255, 0.12); border-radius: 14px; padding: 0px 12px; font-size: 13px; } "
                "QPushButton:hover { background: rgba(255, 255, 255, 0.16); color: #ffffff; } "
                "QPushButton:pressed { background: rgba(255, 255, 255, 0.22); } "
                "QPushButton:disabled { color: rgba(255, 255, 255, 0.25); background: rgba(255, 255, 255, 0.04); }"
            );
        }
        return btn;
    };

    auto *btnFit = makeZoomPill(tr("Fit"), "fitCanvas", tr("Fit canvas in window (Ctrl+0)"));
    connect(btnFit, &QPushButton::clicked, this, &SessionWindow::fitCanvas);
    m_headerToolBar->addWidget(btnFit);

    auto *btn100 = makeZoomPill(tr("100%"), "actualPixels", tr("Actual pixels (Ctrl+1)"));
    connect(btn100, &QPushButton::clicked, this, &SessionWindow::actualPixels);
    m_headerToolBar->addWidget(btn100);

    // Zoom in, then zoom out, as ContentView's toolbar has them: one toolbar item (an HStack), so one capsule.
    auto *zoomGroup = new QWidget(m_headerToolBar);
    zoomGroup->setObjectName("zoomGroup");
    zoomGroup->setAttribute(Qt::WA_StyledBackground, true);
    zoomGroup->setFixedHeight(28);
    zoomGroup->setStyleSheet(QStringLiteral(
        "QWidget#zoomGroup { background: rgba(255, 255, 255, 0.08); border: 1px solid rgba(255, 255, 255, 0.12); border-radius: 14px; } "
        "QPushButton { background: transparent; border: none; border-radius: 12px; padding: 0px; } "
        "QPushButton:hover { background: rgba(255, 255, 255, 0.10); } QPushButton:pressed { background: rgba(255, 255, 255, 0.18); } "
        ""));
    auto *zoomLayout = new QHBoxLayout(zoomGroup);
    zoomLayout->setContentsMargins(3, 1, 3, 1);
    zoomLayout->setSpacing(0);
    auto makeZoomButton = [&](const char *symbol, const char *name, const QString &tip, int step) {
        auto *button = new QPushButton(zoomGroup);
        button->setObjectName(name);
        button->setToolTip(tip);
        button->setFixedSize(30, 24);
        button->setCursor(Qt::PointingHandCursor);
        QIcon icon = renderToolVectorIcon(QString::fromLatin1(symbol), 15, QColor(0xdd, 0xdd, 0xdf));
        icon.addPixmap(renderToolVectorIcon(QString::fromLatin1(symbol), 15, QColor(255, 255, 255, 64)).pixmap(QSize(15, 15) * 2), QIcon::Disabled);
        button->setIcon(icon);
        button->setIconSize(QSize(15, 15));
        connect(button, &QPushButton::clicked, this, [this, step] { zoomStep(step); });
        zoomLayout->addWidget(button);
    };
    makeZoomButton("plus.magnifyingglass", "zoomIn", tr("Zoom in (Ctrl++)"), 1);
    makeZoomButton("minus.magnifyingglass", "zoomOut", tr("Zoom out (Ctrl+−)"), -1);
    m_headerToolBar->addWidget(zoomGroup);
}

void SessionWindow::setupOptionsBar() {
    addToolBarBreak(Qt::TopToolBarArea);
    m_optionsToolBar = addToolBar(tr("Options"));
    m_optionsToolBar->setObjectName("toolbar.options");
    m_optionsToolBar->setMovable(false);
    m_optionsToolBar->setFixedHeight(42);
    m_optionsToolBar->setStyleSheet("QToolBar { background: #1e1e20; border-bottom: 1px solid #141416; spacing: 0px; padding: 0px 8px; }");

    m_optionsStack = new QStackedWidget(m_optionsToolBar);
    m_optionsStack->setObjectName("optionsStack");
    m_optionsStack->setFixedHeight(38);

    const QString titleStyle = "color: #ffffff; font-weight: 600; font-size: 12px; margin-right: 6px;";
    const QString labelStyle = "color: #a0a0a5; font-size: 11px; margin-left: 4px; margin-right: 2px;";
    const QString spinStyle = "QSpinBox, QDoubleSpinBox { background: #28282b; color: #e0e0e0; border: 1px solid #3c3c40; border-radius: 4px; padding: 2px 4px; font-size: 11px; } "
                              "QSpinBox::up-button, QSpinBox::down-button { width: 0px; }";
    const QString btnStyle = "QPushButton { background: #2c2c2f; color: #d0d0d5; border: 1px solid #3c3c40; border-radius: 4px; padding: 3px 8px; font-size: 11px; } "
                             "QPushButton:hover { background: #38383c; color: #ffffff; } "
                             "QPushButton:pressed { background: #202022; }";
    const QString pillActive = "background: #007aff; color: #ffffff; border: 1px solid #0062cc; border-radius: 4px; padding: 2px 8px; font-size: 11px; font-weight: 500;";
    const QString pillInactive = "background: #28282b; color: #a0a0a5; border: 1px solid #38383c; border-radius: 4px; padding: 2px 8px; font-size: 11px;";

    // Page 0: Move (Tool::Move = 0)
    auto *pageMove = new QWidget(m_optionsStack);
    auto *layoutMove = new QHBoxLayout(pageMove);
    layoutMove->setContentsMargins(0, 0, 0, 0);
    layoutMove->setSpacing(8);

    auto *lblMoveTitle = new QLabel(tr("Move"), pageMove);
    lblMoveTitle->setStyleSheet(titleStyle);
    layoutMove->addWidget(lblMoveTitle);

    auto *chkAutoSelect = new QCheckBox(tr("Auto Select"), pageMove);
    chkAutoSelect->setObjectName("transformAutoSelect");
    chkAutoSelect->setChecked(true);
    m_autoSelectCheck = chkAutoSelect;
    layoutMove->addWidget(chkAutoSelect);

    auto *comboAutoSelectType = new QComboBox(pageMove);
    comboAutoSelectType->addItems({tr("Layer"), tr("Group")});
    layoutMove->addWidget(comboAutoSelectType);

    auto *chkShowControls = new QCheckBox(tr("Show Controls"), pageMove);
    chkShowControls->setChecked(true);
    chkShowControls->setObjectName("transformShowControls");
    m_showControlsCheck = chkShowControls;
    connect(chkShowControls, &QCheckBox::toggled, this, [this] { if (m_canvasWidget) m_canvasWidget->update(); });
    layoutMove->addWidget(chkShowControls);

    auto addCoordBox = [&](const QString &label, int defVal) {
        auto *lbl = new QLabel(label, pageMove);
        lbl->setStyleSheet(labelStyle);
        layoutMove->addWidget(lbl);
        auto *spin = new QSpinBox(pageMove);
        spin->setRange(-9999, 9999);
        spin->setValue(defVal);
        spin->setFixedWidth(56);
        spin->setStyleSheet(spinStyle);
        layoutMove->addWidget(spin);
        return spin;
    };
    m_xSpin = addCoordBox("X", 0);
    m_ySpin = addCoordBox("Y", 0);
    m_wSpin = addCoordBox("W", 512);
    m_hSpin = addCoordBox("H", 512);
    m_xSpin->setObjectName("transform.x");
    m_ySpin->setObjectName("transform.y");
    m_wSpin->setObjectName("transform.w");
    m_hSpin->setObjectName("transform.h");
    m_wSpin->setRange(1, 30000);
    m_hSpin->setRange(1, 30000);
    m_xSpin->setRange(-30000, 30000);
    m_ySpin->setRange(-30000, 30000);
    m_xSpin->setFixedWidth(64); m_ySpin->setFixedWidth(64); m_wSpin->setFixedWidth(64); m_hSpin->setFixedWidth(64);

    auto *chkLink = new QCheckBox(tr("Link"), pageMove);
    chkLink->setChecked(true);
    chkLink->setObjectName("transformLink");
    m_linkCheck = chkLink;
    layoutMove->addWidget(chkLink);

    auto *lblAngle = new QLabel(tr("Angle"), pageMove);
    lblAngle->setStyleSheet(labelStyle);
    layoutMove->addWidget(lblAngle);
    auto *spinAngle = new QSpinBox(pageMove);
    spinAngle->setObjectName("transform.angle");
    m_angleSpin = spinAngle;
    spinAngle->setRange(-360, 360);
    spinAngle->setValue(0);
    spinAngle->setSuffix(QString::fromUtf8("°"));
    spinAngle->setFixedWidth(50);
    spinAngle->setStyleSheet(spinStyle);
    layoutMove->addWidget(spinAngle);
    for (QSpinBox *spin : {m_xSpin, m_ySpin, m_wSpin, m_hSpin, m_angleSpin}) {
        const int field = spin == m_xSpin ? 0 : spin == m_ySpin ? 1 : spin == m_wSpin ? 2 : spin == m_hSpin ? 3 : 4;
        spin->setKeyboardTracking(false);
        connect(spin, &QSpinBox::valueChanged, this, [this, field] { applyTransformFields(field); });
    }
    layoutMove->addStretch();
    m_optionsStack->addWidget(pageMove);

    // Page 1: Marquee (Tool::Marquee = 1)
    auto *pageMarquee = new QWidget(m_optionsStack);
    auto *layoutMarquee = new QHBoxLayout(pageMarquee);
    layoutMarquee->setContentsMargins(0, 0, 0, 0);
    layoutMarquee->setSpacing(8);

    auto *lblMarqueeTitle = new QLabel(tr("Marquee"), pageMarquee);
    lblMarqueeTitle->setStyleSheet(titleStyle);
    layoutMarquee->addWidget(lblMarqueeTitle);

    auto *marqueeGroup = new QWidget(pageMarquee);
    marqueeGroup->setObjectName("select.marqueeGroup");
    auto *mqLayout = new QHBoxLayout(marqueeGroup);
    mqLayout->setContentsMargins(0, 0, 0, 0);
    mqLayout->setSpacing(4);
    auto *btnMqRect = new QPushButton(tr("Rectangle"), marqueeGroup);
    btnMqRect->setStyleSheet(m_marqueeMode == MarqueeMode::Rectangle ? pillActive : pillInactive);
    auto *btnMqEllipse = new QPushButton(tr("Ellipse"), marqueeGroup);
    btnMqEllipse->setStyleSheet(m_marqueeMode == MarqueeMode::Ellipse ? pillActive : pillInactive);
    connect(btnMqRect, &QPushButton::clicked, this, [this, btnMqRect, btnMqEllipse, pillActive, pillInactive] {
        btnMqRect->setStyleSheet(pillActive); btnMqEllipse->setStyleSheet(pillInactive);
        setMarqueeMode(MarqueeMode::Rectangle);
    });
    connect(btnMqEllipse, &QPushButton::clicked, this, [this, btnMqRect, btnMqEllipse, pillActive, pillInactive] {
        btnMqRect->setStyleSheet(pillInactive); btnMqEllipse->setStyleSheet(pillActive);
        setMarqueeMode(MarqueeMode::Ellipse);
    });
    mqLayout->addWidget(btnMqRect);
    mqLayout->addWidget(btnMqEllipse);
    layoutMarquee->addWidget(marqueeGroup);

    auto makeCombineButtons = [&](QWidget *parent, QHBoxLayout *layout) {
        auto *btnNew = new QPushButton(tr("New"), parent);
        btnNew->setStyleSheet(pillActive);
        auto *btnAdd = new QPushButton(tr("Add"), parent);
        btnAdd->setStyleSheet(pillInactive);
        auto *btnSub = new QPushButton(tr("Subtract"), parent);
        btnSub->setStyleSheet(pillInactive);
        connect(btnNew, &QPushButton::clicked, this, [this, btnNew, btnAdd, btnSub, pillActive, pillInactive] {
            m_selectionMode = "New";
            sendCommand({{"action", "setSelectionMode"}, {"kind", "New"}});
            btnNew->setStyleSheet(pillActive); btnAdd->setStyleSheet(pillInactive); btnSub->setStyleSheet(pillInactive);
        });
        connect(btnAdd, &QPushButton::clicked, this, [this, btnNew, btnAdd, btnSub, pillActive, pillInactive] {
            m_selectionMode = "Add";
            sendCommand({{"action", "setSelectionMode"}, {"kind", "Add"}});
            btnNew->setStyleSheet(pillInactive); btnAdd->setStyleSheet(pillActive); btnSub->setStyleSheet(pillInactive);
        });
        connect(btnSub, &QPushButton::clicked, this, [this, btnNew, btnAdd, btnSub, pillActive, pillInactive] {
            m_selectionMode = "Subtract";
            sendCommand({{"action", "setSelectionMode"}, {"kind", "Subtract"}});
            btnNew->setStyleSheet(pillInactive); btnAdd->setStyleSheet(pillInactive); btnSub->setStyleSheet(pillActive);
        });
        layout->addWidget(btnNew);
        layout->addWidget(btnAdd);
        layout->addWidget(btnSub);
    };
    makeCombineButtons(pageMarquee, layoutMarquee);

    auto *chkMqAA = new QCheckBox(tr("Anti-alias"), pageMarquee);
    chkMqAA->setChecked(true);
    layoutMarquee->addWidget(chkMqAA);

    auto *btnExpand = new QPushButton(tr("Expand"), pageMarquee);
    btnExpand->setStyleSheet(btnStyle);
    layoutMarquee->addWidget(btnExpand);
    auto *spinExpand = new QSpinBox(pageMarquee);
    spinExpand->setRange(1, 250);
    spinExpand->setValue(1);
    spinExpand->setSuffix(tr(" px"));
    spinExpand->setFixedWidth(54);
    spinExpand->setStyleSheet(spinStyle);
    layoutMarquee->addWidget(spinExpand);
    connect(spinExpand, QOverload<int>::of(&QSpinBox::valueChanged), this, [this](int val) {
        sendCommand({{"action", "setSelectionExpandAmount"}, {"parameters", QJsonObject{{"amount", val}}}});
    });
    connect(btnExpand, &QPushButton::clicked, this, [this, spinExpand] {
        if (sendCommand({{"action", "expandSelection"}, {"parameters", QJsonObject{{"amount", spinExpand->value()}}}})) refreshImage();
    });




    auto *btnContract = new QPushButton(tr("Contract"), pageMarquee);
    btnContract->setStyleSheet(btnStyle);
    layoutMarquee->addWidget(btnContract);
    auto *spinContract = new QSpinBox(pageMarquee);
    spinContract->setRange(1, 250);
    spinContract->setValue(1);
    spinContract->setSuffix(tr(" px"));
    spinContract->setFixedWidth(54);
    spinContract->setStyleSheet(spinStyle);
    layoutMarquee->addWidget(spinContract);
    connect(btnContract, &QPushButton::clicked, this, [this, spinContract] {
        if (sendCommand({{"action", "contractSelection"}, {"parameters", QJsonObject{{"amount", spinContract->value()}}}})) refreshImage();
    });

    auto *btnMqDeselect = new QPushButton(tr("Deselect"), pageMarquee);
    btnMqDeselect->setStyleSheet(btnStyle);
    connect(btnMqDeselect, &QPushButton::clicked, this, [this] {
        cmd(m_sessionHandle, R"({"version":1,"action":"deselect"})");
        refreshImage();
    });
    layoutMarquee->addWidget(btnMqDeselect);


    layoutMarquee->addStretch();
    m_optionsStack->addWidget(pageMarquee);

    // Page 2: Lasso (Tool::Lasso = 2)
    auto *pageLasso = new QWidget(m_optionsStack);
    auto *layoutLasso = new QHBoxLayout(pageLasso);
    layoutLasso->setContentsMargins(0, 0, 0, 0);
    layoutLasso->setSpacing(8);

    auto *lblLassoTitle = new QLabel(tr("Lasso"), pageLasso);
    lblLassoTitle->setStyleSheet(titleStyle);
    layoutLasso->addWidget(lblLassoTitle);

    auto *lassoGroup = new QWidget(pageLasso);
    lassoGroup->setObjectName("select.lassoGroup");
    auto *lsLayout = new QHBoxLayout(lassoGroup);
    lsLayout->setContentsMargins(0, 0, 0, 0);
    lsLayout->setSpacing(4);
    auto *btnFreehand = new QPushButton(tr("Freehand"), lassoGroup);
    btnFreehand->setObjectName("select.freehand");
    btnFreehand->setStyleSheet(pillActive);
    auto *btnPolygonal = new QPushButton(tr("Polygonal"), lassoGroup);
    btnPolygonal->setObjectName("select.polygonal");
    btnPolygonal->setStyleSheet(pillInactive);
    connect(btnFreehand, &QPushButton::clicked, this, [this, btnFreehand, btnPolygonal, pillActive, pillInactive] {
        m_polygonalLasso = false; m_polyActive = false; m_lassoPoints.clear();
        btnFreehand->setStyleSheet(pillActive); btnPolygonal->setStyleSheet(pillInactive);
        if (m_canvasWidget) m_canvasWidget->update();
    });
    connect(btnPolygonal, &QPushButton::clicked, this, [this, btnFreehand, btnPolygonal, pillActive, pillInactive] {
        m_polygonalLasso = true; m_polyActive = false; m_lassoPoints.clear();
        btnFreehand->setStyleSheet(pillInactive); btnPolygonal->setStyleSheet(pillActive);
        if (m_canvasWidget) m_canvasWidget->update();
    });
    lsLayout->addWidget(btnFreehand);
    lsLayout->addWidget(btnPolygonal);
    layoutLasso->addWidget(lassoGroup);

    makeCombineButtons(pageLasso, layoutLasso);

    auto *chkLassoAA = new QCheckBox(tr("Anti-alias"), pageLasso);
    chkLassoAA->setChecked(true);
    layoutLasso->addWidget(chkLassoAA);

    auto *btnLsDeselect = new QPushButton(tr("Deselect"), pageLasso);
    btnLsDeselect->setStyleSheet(btnStyle);
    connect(btnLsDeselect, &QPushButton::clicked, this, [this] {
        cmd(m_sessionHandle, R"({"version":1,"action":"deselect"})");
        refreshImage();
    });
    layoutLasso->addWidget(btnLsDeselect);

    layoutLasso->addStretch();
    m_optionsStack->addWidget(pageLasso);

    // Page 3: Magic (Tool::Magic = 3)
    auto *pageMagic = new QWidget(m_optionsStack);
    auto *layoutMagic = new QHBoxLayout(pageMagic);
    layoutMagic->setContentsMargins(0, 0, 0, 0);
    layoutMagic->setSpacing(8);

    auto *lblMagicTitle = new QLabel(tr("Magic"), pageMagic);
    lblMagicTitle->setStyleSheet(titleStyle);
    layoutMagic->addWidget(lblMagicTitle);

    auto *btnWand = new QPushButton(tr("Wand"), pageMagic);
    btnWand->setStyleSheet(m_magicMode == MagicMode::Wand ? pillActive : pillInactive);
    auto *btnObj = new QPushButton(tr("Object"), pageMagic);
    btnObj->setStyleSheet(m_magicMode == MagicMode::Object ? pillActive : pillInactive);
    connect(btnWand, &QPushButton::clicked, this, [this, btnWand, btnObj, pillActive, pillInactive] {
        btnWand->setStyleSheet(pillActive); btnObj->setStyleSheet(pillInactive);
        setMagicMode(MagicMode::Wand);
    });
    connect(btnObj, &QPushButton::clicked, this, [this, btnWand, btnObj, pillActive, pillInactive] {
        btnWand->setStyleSheet(pillInactive); btnObj->setStyleSheet(pillActive);
        setMagicMode(MagicMode::Object);
    });
    layoutMagic->addWidget(btnWand);
    layoutMagic->addWidget(btnObj);

    makeCombineButtons(pageMagic, layoutMagic);

    auto *lblTol = new QLabel(tr("Tolerance"), pageMagic);
    lblTol->setStyleSheet(labelStyle);
    layoutMagic->addWidget(lblTol);
    auto *spinTol = new QSpinBox(pageMagic);
    spinTol->setRange(0, 255);
    spinTol->setValue(m_magicTolerance);
    spinTol->setFixedWidth(50);
    spinTol->setStyleSheet(spinStyle);
    connect(spinTol, QOverload<int>::of(&QSpinBox::valueChanged), this, [this](int val) {
        m_magicTolerance = val;
    });
    layoutMagic->addWidget(spinTol);

    auto *chkWandContig = new QCheckBox(tr("Contiguous"), pageMagic);
    chkWandContig->setChecked(m_magicContiguous);
    connect(chkWandContig, &QCheckBox::toggled, this, [this](bool val) {
        m_magicContiguous = val;
    });
    layoutMagic->addWidget(chkWandContig);

    auto *chkWandSample = new QCheckBox(tr("Sample All Layers"), pageMagic);
    chkWandSample->setChecked(m_magicSampleAll);
    connect(chkWandSample, &QCheckBox::toggled, this, [this](bool val) {
        m_magicSampleAll = val;
    });
    layoutMagic->addWidget(chkWandSample);

    auto *btnMgDeselect = new QPushButton(tr("Deselect"), pageMagic);
    btnMgDeselect->setStyleSheet(btnStyle);
    connect(btnMgDeselect, &QPushButton::clicked, this, [this] {
        cmd(m_sessionHandle, R"({"version":1,"action":"deselect"})");
        refreshImage();
    });
    layoutMagic->addWidget(btnMgDeselect);

    layoutMagic->addStretch();
    m_optionsStack->addWidget(pageMagic);

    // Page 4: Crop (Tool::Crop = 4)
    auto *pageCrop = new QWidget(m_optionsStack);
    auto *layoutCrop = new QHBoxLayout(pageCrop);
    layoutCrop->setContentsMargins(0, 0, 0, 0);
    layoutCrop->setSpacing(8);

    auto *lblCropTitle = new QLabel(tr("Crop"), pageCrop);
    lblCropTitle->setStyleSheet(titleStyle);
    layoutCrop->addWidget(lblCropTitle);

    auto *lblRatio = new QLabel(tr("Ratio"), pageCrop);
    lblRatio->setStyleSheet(labelStyle);
    layoutCrop->addWidget(lblRatio);
    auto *comboRatio = new QComboBox(pageCrop);
    comboRatio->addItems({tr("Free"), tr("Original"), tr("1:1"), tr("4:3"), tr("16:9")});
    connect(comboRatio, &QComboBox::currentTextChanged, this, [this](const QString &ratio) {
        m_cropRatio = ratio;
    });
    layoutCrop->addWidget(comboRatio);

    auto *btnApplyCrop = new QPushButton(tr("Apply Crop"), pageCrop);
    btnApplyCrop->setStyleSheet(btnStyle);
    connect(btnApplyCrop, &QPushButton::clicked, this, &SessionWindow::applyCrop);
    auto *btnCancelCrop = new QPushButton(tr("Cancel"), pageCrop);
    btnCancelCrop->setStyleSheet(btnStyle);
    connect(btnCancelCrop, &QPushButton::clicked, this, &SessionWindow::cancelCrop);
    layoutCrop->addWidget(btnApplyCrop);
    layoutCrop->addWidget(btnCancelCrop);

    layoutCrop->addStretch();
    m_optionsStack->addWidget(pageCrop);

    // Page 5: Brush (Tool::Brush = 5)
    auto *pageBrush = new QWidget(m_optionsStack);
    auto *layoutBrush = new QHBoxLayout(pageBrush);
    layoutBrush->setContentsMargins(0, 0, 0, 0);
    layoutBrush->setSpacing(8);

    auto *lblBrushTitle = new QLabel(tr("Brush"), pageBrush);
    lblBrushTitle->setObjectName("options.brushTitle");
    lblBrushTitle->setStyleSheet(titleStyle);
    layoutBrush->addWidget(lblBrushTitle);

    auto *btnPaintMode = new QPushButton(tr("Paint"), pageBrush);
    btnPaintMode->setStyleSheet(pillActive);
    auto *btnEraseMode = new QPushButton(tr("Erase"), pageBrush);
    btnEraseMode->setStyleSheet(pillInactive);
    connect(btnPaintMode, &QPushButton::clicked, this, [this, btnPaintMode, btnEraseMode, pillActive, pillInactive] {
        btnPaintMode->setStyleSheet(pillActive); btnEraseMode->setStyleSheet(pillInactive);
        setBrushToolMode(BrushToolMode::Paint);
    });
    connect(btnEraseMode, &QPushButton::clicked, this, [this, btnPaintMode, btnEraseMode, pillActive, pillInactive] {
        btnPaintMode->setStyleSheet(pillInactive); btnEraseMode->setStyleSheet(pillActive);
        setBrushToolMode(BrushToolMode::Erase);
    });
    layoutBrush->addWidget(btnPaintMode);
    layoutBrush->addWidget(btnEraseMode);

    auto *lblSize = new QLabel(tr("Size"), pageBrush);
    lblSize->setStyleSheet(labelStyle);
    layoutBrush->addWidget(lblSize);

    m_brushDiameterSlider = new QSlider(Qt::Horizontal, pageBrush);
    m_brushDiameterSlider->setObjectName("brush.diameter");
    m_brushDiameterSlider->setRange(1, 256);
    m_brushDiameterSlider->setValue(m_brushDiameter);
    m_brushDiameterSlider->setFixedWidth(100);
    layoutBrush->addWidget(m_brushDiameterSlider);

    auto *spinSize = new QSpinBox(pageBrush);
    spinSize->setObjectName("brush.diameterSpin");
    spinSize->setRange(1, 2000);
    spinSize->setValue(m_brushDiameter);
    spinSize->setSuffix(tr(" px"));
    spinSize->setFixedWidth(64);
    spinSize->setStyleSheet(spinStyle);
    layoutBrush->addWidget(spinSize);

    connect(m_brushDiameterSlider, &QSlider::valueChanged, this, [this, spinSize](int val) {
        if (spinSize->value() != val) spinSize->setValue(val);
        setBrushDiameter(val);
    });
    connect(spinSize, QOverload<int>::of(&QSpinBox::valueChanged), this, [this](int val) {
        if (m_brushDiameterSlider->value() != std::min(val, 256)) m_brushDiameterSlider->setValue(std::min(val, 256));
        setBrushDiameter(val);
    });

    auto *lblHard = new QLabel(tr("Hardness"), pageBrush);
    lblHard->setStyleSheet(labelStyle);
    layoutBrush->addWidget(lblHard);

    m_brushHardnessSlider = new QSlider(Qt::Horizontal, pageBrush);
    m_brushHardnessSlider->setObjectName("brush.hardness");
    m_brushHardnessSlider->setRange(0, 100);
    m_brushHardnessSlider->setValue(m_brushHardness);
    m_brushHardnessSlider->setFixedWidth(80);
    layoutBrush->addWidget(m_brushHardnessSlider);

    auto *spinHard = new QSpinBox(pageBrush);
    spinHard->setObjectName("brush.hardnessSpin");
    spinHard->setRange(0, 100);
    spinHard->setValue(m_brushHardness);
    spinHard->setSuffix(tr(" %"));
    spinHard->setFixedWidth(54);
    spinHard->setStyleSheet(spinStyle);
    layoutBrush->addWidget(spinHard);

    connect(m_brushHardnessSlider, &QSlider::valueChanged, this, [this, spinHard](int val) {
        if (spinHard->value() != val) spinHard->setValue(val);
        setBrushHardness(val);
    });
    connect(spinHard, QOverload<int>::of(&QSpinBox::valueChanged), this, [this](int val) {
        if (m_brushHardnessSlider->value() != val) m_brushHardnessSlider->setValue(val);
        setBrushHardness(val);
    });

    auto *lblOpac = new QLabel(tr("Opacity"), pageBrush);
    lblOpac->setStyleSheet(labelStyle);
    layoutBrush->addWidget(lblOpac);

    m_brushOpacitySlider = new QSlider(Qt::Horizontal, pageBrush);
    m_brushOpacitySlider->setObjectName("brush.opacity");
    m_brushOpacitySlider->setRange(0, 100);
    m_brushOpacitySlider->setValue(m_brushOpacity);
    m_brushOpacitySlider->setFixedWidth(80);
    layoutBrush->addWidget(m_brushOpacitySlider);

    auto *spinOpac = new QSpinBox(pageBrush);
    spinOpac->setObjectName("brush.opacitySpin");
    spinOpac->setRange(0, 100);
    spinOpac->setValue(m_brushOpacity);
    spinOpac->setSuffix(tr(" %"));
    spinOpac->setFixedWidth(54);
    spinOpac->setStyleSheet(spinStyle);
    layoutBrush->addWidget(spinOpac);

    connect(m_brushOpacitySlider, &QSlider::valueChanged, this, [this, spinOpac](int val) {
        if (spinOpac->value() != val) spinOpac->setValue(val);
        setBrushOpacity(val);
    });
    connect(spinOpac, QOverload<int>::of(&QSpinBox::valueChanged), this, [this](int val) {
        if (m_brushOpacitySlider->value() != val) m_brushOpacitySlider->setValue(val);
        setBrushOpacity(val);
    });

    auto *lblColor = new QLabel(tr("Color"), pageBrush);
    lblColor->setStyleSheet(labelStyle);
    layoutBrush->addWidget(lblColor);

    m_brushColorButton = new QPushButton(pageBrush);
    m_brushColorButton->setObjectName("brush.color");
    m_brushColorButton->setFixedSize(36, 20);
    m_brushColorButton->setToolTip(tr("Foreground brush color"));
    m_brushColorButton->setStyleSheet(QString("background-color: %1; border: 1px solid #101012; border-radius: 3px;").arg(m_brushColor.name()));
    connect(m_brushColorButton, &QPushButton::clicked, this, &SessionWindow::pickBrushColor);
    layoutBrush->addWidget(m_brushColorButton);

    layoutBrush->addStretch();
    m_optionsStack->addWidget(pageBrush);

    // Page 6: Spot Healing (Tool::SpotHealing = 6)
    auto *pageSpot = new QWidget(m_optionsStack);
    auto *layoutSpot = new QHBoxLayout(pageSpot);
    layoutSpot->setContentsMargins(0, 0, 0, 0);
    layoutSpot->setSpacing(8);

    auto *lblSpotTitle = new QLabel(tr("Spot Healing"), pageSpot);
    lblSpotTitle->setStyleSheet(titleStyle);
    layoutSpot->addWidget(lblSpotTitle);

    auto *lblSpotMode = new QLabel(tr("Mode:"), pageSpot);
    lblSpotMode->setStyleSheet(labelStyle);
    layoutSpot->addWidget(lblSpotMode);
    auto *comboSpotMode = new QComboBox(pageSpot);
    comboSpotMode->addItems({tr("Content-Aware"), tr("Create Texture"), tr("Proximity Match")});
    connect(comboSpotMode, QOverload<int>::of(&QComboBox::currentIndexChanged), this, [this](int idx) {
        if (idx == 0) setSpotHealingMode(SpotHealingMode::ContentAware);
        else if (idx == 1) setSpotHealingMode(SpotHealingMode::CreateTexture);
        else setSpotHealingMode(SpotHealingMode::ProximityMatch);
    });
    layoutSpot->addWidget(comboSpotMode);

    auto *lblSpotSize = new QLabel(tr("Size"), pageSpot);
    lblSpotSize->setStyleSheet(labelStyle);
    layoutSpot->addWidget(lblSpotSize);
    auto *sliderSpotSize = new QSlider(Qt::Horizontal, pageSpot);
    sliderSpotSize->setRange(1, 256);
    sliderSpotSize->setValue(m_brushDiameter);
    sliderSpotSize->setFixedWidth(90);
    layoutSpot->addWidget(sliderSpotSize);
    auto *spinSpotSize = new QSpinBox(pageSpot);
    spinSpotSize->setRange(1, 2000);
    spinSpotSize->setValue(m_brushDiameter);
    spinSpotSize->setSuffix(tr(" px"));
    spinSpotSize->setFixedWidth(60);
    spinSpotSize->setStyleSheet(spinStyle);
    layoutSpot->addWidget(spinSpotSize);
    connect(sliderSpotSize, &QSlider::valueChanged, this, [this, spinSpotSize](int val) {
        spinSpotSize->setValue(val); setBrushDiameter(val);
    });
    connect(spinSpotSize, QOverload<int>::of(&QSpinBox::valueChanged), this, [this, sliderSpotSize](int val) {
        sliderSpotSize->setValue(std::min(val, 256)); setBrushDiameter(val);
    });

    layoutSpot->addStretch();
    m_optionsStack->addWidget(pageSpot);

    // Page 7: Clone Stamp (Tool::CloneStamp = 7)
    auto *pageClone = new QWidget(m_optionsStack);
    auto *layoutClone = new QHBoxLayout(pageClone);
    layoutClone->setContentsMargins(0, 0, 0, 0);
    layoutClone->setSpacing(8);

    auto *lblCloneTitle = new QLabel(tr("Clone Stamp"), pageClone);
    lblCloneTitle->setObjectName("options.cloneTitle");
    lblCloneTitle->setStyleSheet(titleStyle);
    layoutClone->addWidget(lblCloneTitle);

    auto *chkAligned = new QCheckBox(tr("Aligned"), pageClone);
    chkAligned->setChecked(m_cloneAligned);
    connect(chkAligned, &QCheckBox::toggled, this, [this](bool val) { m_cloneAligned = val; });
    layoutClone->addWidget(chkAligned);

    auto *lblSample = new QLabel(tr("Sample:"), pageClone);
    lblSample->setStyleSheet(labelStyle);
    layoutClone->addWidget(lblSample);
    auto *comboSample = new QComboBox(pageClone);
    comboSample->addItems({tr("Current Layer"), tr("All Layers")});
    connect(comboSample, QOverload<int>::of(&QComboBox::currentIndexChanged), this, [this](int idx) {
        m_cloneSampleAll = (idx == 1);
    });
    layoutClone->addWidget(comboSample);

    layoutClone->addStretch();
    m_optionsStack->addWidget(pageClone);

    // Page 8: Smear (Tool::Smear = 8)
    auto *pageSmear = new QWidget(m_optionsStack);
    auto *layoutSmear = new QHBoxLayout(pageSmear);
    layoutSmear->setContentsMargins(0, 0, 0, 0);
    layoutSmear->setSpacing(8);

    auto *lblSmearTitle = new QLabel(tr("Smear"), pageSmear);
    lblSmearTitle->setStyleSheet(titleStyle);
    layoutSmear->addWidget(lblSmearTitle);

    auto *lblSmearMode = new QLabel(tr("Mode:"), pageSmear);
    lblSmearMode->setStyleSheet(labelStyle);
    layoutSmear->addWidget(lblSmearMode);
    auto *comboSmearMode = new QComboBox(pageSmear);
    comboSmearMode->addItems({tr("Liquify"), tr("Blur"), tr("Smudge")});
    connect(comboSmearMode, QOverload<int>::of(&QComboBox::currentIndexChanged), this, [this](int idx) {
        if (idx == 0) setSmearMode(SmearMode::Liquify);
        else if (idx == 1) setSmearMode(SmearMode::Blur);
        else setSmearMode(SmearMode::Smudge);
    });
    layoutSmear->addWidget(comboSmearMode);

    auto *lblSmearSize = new QLabel(tr("Size"), pageSmear);
    lblSmearSize->setStyleSheet(labelStyle);
    layoutSmear->addWidget(lblSmearSize);
    auto *sliderSmearSize = new QSlider(Qt::Horizontal, pageSmear);
    sliderSmearSize->setRange(1, 256);
    sliderSmearSize->setValue(m_brushDiameter);
    sliderSmearSize->setFixedWidth(90);
    layoutSmear->addWidget(sliderSmearSize);
    connect(sliderSmearSize, &QSlider::valueChanged, this, [this](int val) { setBrushDiameter(val); });

    layoutSmear->addStretch();
    m_optionsStack->addWidget(pageSmear);

    // Page 9: Gradient (Tool::Gradient = 9)
    auto *pageGradient = new QWidget(m_optionsStack);
    auto *layoutGradient = new QHBoxLayout(pageGradient);
    layoutGradient->setContentsMargins(0, 0, 0, 0);
    layoutGradient->setSpacing(8);

    auto *lblGradTitle = new QLabel(tr("Gradient"), pageGradient);
    lblGradTitle->setStyleSheet(titleStyle);
    layoutGradient->addWidget(lblGradTitle);

    auto *comboGradType = new QComboBox(pageGradient);
    comboGradType->addItems({tr("Linear"), tr("Radial"), tr("Angle"), tr("Reflected"), tr("Diamond")});
    connect(comboGradType, &QComboBox::currentTextChanged, this, [this](const QString &t) { m_gradientType = t; });
    layoutGradient->addWidget(comboGradType);

    auto *lblGradBlend = new QLabel(tr("Blend:"), pageGradient);
    lblGradBlend->setStyleSheet(labelStyle);
    layoutGradient->addWidget(lblGradBlend);
    auto *comboGradBlend = new QComboBox(pageGradient);
    comboGradBlend->addItems(blendModes());
    layoutGradient->addWidget(comboGradBlend);

    auto *lblGradOpac = new QLabel(tr("Opacity:"), pageGradient);
    lblGradOpac->setStyleSheet(labelStyle);
    layoutGradient->addWidget(lblGradOpac);
    auto *spinGradOpac = new QSpinBox(pageGradient);
    spinGradOpac->setRange(0, 100);
    spinGradOpac->setValue(m_gradientOpacity);
    spinGradOpac->setSuffix(tr(" %"));
    spinGradOpac->setFixedWidth(54);
    spinGradOpac->setStyleSheet(spinStyle);
    connect(spinGradOpac, QOverload<int>::of(&QSpinBox::valueChanged), this, [this](int val) { m_gradientOpacity = val; });
    layoutGradient->addWidget(spinGradOpac);

    auto *chkGradReverse = new QCheckBox(tr("Reverse"), pageGradient);
    chkGradReverse->setChecked(m_gradientReverse);
    connect(chkGradReverse, &QCheckBox::toggled, this, [this](bool val) { m_gradientReverse = val; });
    layoutGradient->addWidget(chkGradReverse);

    layoutGradient->addStretch();
    m_optionsStack->addWidget(pageGradient);

    // Page 10: Shape (Tool::Shape = 10)
    auto *pageShape = new QWidget(m_optionsStack);
    auto *layoutShape = new QHBoxLayout(pageShape);
    layoutShape->setContentsMargins(0, 0, 0, 0);
    layoutShape->setSpacing(8);

    auto *lblShapeTitle = new QLabel(tr("Shape"), pageShape);
    lblShapeTitle->setStyleSheet(titleStyle);
    layoutShape->addWidget(lblShapeTitle);

    auto *comboShapeMode = new QComboBox(pageShape);
    comboShapeMode->addItems({tr("Rectangle"), tr("Ellipse"), tr("Line")});
    connect(comboShapeMode, QOverload<int>::of(&QComboBox::currentIndexChanged), this, [this](int idx) {
        if (idx == 0) setShapeMode(ShapeMode::Rectangle);
        else if (idx == 1) setShapeMode(ShapeMode::Ellipse);
        else setShapeMode(ShapeMode::Line);
    });
    layoutShape->addWidget(comboShapeMode);

    auto *lblStrokeW = new QLabel(tr("Stroke:"), pageShape);
    lblStrokeW->setStyleSheet(labelStyle);
    layoutShape->addWidget(lblStrokeW);
    auto *spinStrokeW = new QSpinBox(pageShape);
    spinStrokeW->setRange(0, 100);
    spinStrokeW->setValue(m_shapeStrokeWidth);
    spinStrokeW->setSuffix(tr(" px"));
    spinStrokeW->setFixedWidth(64);
    spinStrokeW->setStyleSheet(spinStyle);
    connect(spinStrokeW, QOverload<int>::of(&QSpinBox::valueChanged), this, [this](int val) { m_shapeStrokeWidth = val; });
    layoutShape->addWidget(spinStrokeW);

    auto *lblRadius = new QLabel(tr("Radius:"), pageShape);
    lblRadius->setStyleSheet(labelStyle);
    layoutShape->addWidget(lblRadius);
    auto *spinRadius = new QSpinBox(pageShape);
    spinRadius->setRange(0, 100);
    spinRadius->setValue(m_shapeRadius);
    spinRadius->setSuffix(tr(" px"));
    spinRadius->setFixedWidth(54);
    spinRadius->setStyleSheet(spinStyle);
    connect(spinRadius, QOverload<int>::of(&QSpinBox::valueChanged), this, [this](int val) { m_shapeRadius = val; });
    layoutShape->addWidget(spinRadius);

    layoutShape->addStretch();
    m_optionsStack->addWidget(pageShape);

    // Page 11: Type (Tool::Type = 11)
    auto *pageType = new QWidget(m_optionsStack);
    auto *layoutType = new QHBoxLayout(pageType);
    layoutType->setContentsMargins(0, 0, 0, 0);
    layoutType->setSpacing(8);

    auto *lblTypeTitle = new QLabel(tr("Type"), pageType);
    lblTypeTitle->setStyleSheet(titleStyle);
    layoutType->addWidget(lblTypeTitle);

    auto *comboFont = new QComboBox(pageType);
    comboFont->addItems({tr("System Default"), tr("Sans Serif"), tr("Serif"), tr("Monospace")});
    layoutType->addWidget(comboFont);

    auto *lblTypeSize = new QLabel(tr("Size:"), pageType);
    lblTypeSize->setStyleSheet(labelStyle);
    layoutType->addWidget(lblTypeSize);
    auto *spinTypeSize = new QSpinBox(pageType);
    spinTypeSize->setRange(6, 288);
    spinTypeSize->setValue(m_typeFontSize);
    spinTypeSize->setSuffix(tr(" pt"));
    spinTypeSize->setFixedWidth(58);
    spinTypeSize->setStyleSheet(spinStyle);
    connect(spinTypeSize, QOverload<int>::of(&QSpinBox::valueChanged), this, [this](int val) { m_typeFontSize = val; });
    layoutType->addWidget(spinTypeSize);

    auto *btnAlignLeft = new QPushButton(tr("Left"), pageType);
    btnAlignLeft->setStyleSheet(pillActive);
    auto *btnAlignCenter = new QPushButton(tr("Center"), pageType);
    btnAlignCenter->setStyleSheet(pillInactive);
    auto *btnAlignRight = new QPushButton(tr("Right"), pageType);
    btnAlignRight->setStyleSheet(pillInactive);
    connect(btnAlignLeft, &QPushButton::clicked, this, [this, btnAlignLeft, btnAlignCenter, btnAlignRight, pillActive, pillInactive] {
        m_typeAlignment = 0;
        btnAlignLeft->setStyleSheet(pillActive); btnAlignCenter->setStyleSheet(pillInactive); btnAlignRight->setStyleSheet(pillInactive);
    });
    connect(btnAlignCenter, &QPushButton::clicked, this, [this, btnAlignLeft, btnAlignCenter, btnAlignRight, pillActive, pillInactive] {
        m_typeAlignment = 1;
        btnAlignLeft->setStyleSheet(pillInactive); btnAlignCenter->setStyleSheet(pillActive); btnAlignRight->setStyleSheet(pillInactive);
    });
    connect(btnAlignRight, &QPushButton::clicked, this, [this, btnAlignLeft, btnAlignCenter, btnAlignRight, pillActive, pillInactive] {
        m_typeAlignment = 2;
        btnAlignLeft->setStyleSheet(pillInactive); btnAlignCenter->setStyleSheet(pillInactive); btnAlignRight->setStyleSheet(pillActive);
    });
    layoutType->addWidget(btnAlignLeft);
    layoutType->addWidget(btnAlignCenter);
    layoutType->addWidget(btnAlignRight);

    layoutType->addStretch();
    m_optionsStack->addWidget(pageType);

    // Page 12: Eyedropper (Tool::Eyedropper = 12)
    auto *pageEye = new QWidget(m_optionsStack);
    auto *layoutEye = new QHBoxLayout(pageEye);
    layoutEye->setContentsMargins(0, 0, 0, 0);
    layoutEye->setSpacing(8);

    auto *lblEyeTitle = new QLabel(tr("Eyedropper"), pageEye);
    lblEyeTitle->setStyleSheet(titleStyle);
    layoutEye->addWidget(lblEyeTitle);

    auto *lblSampleSz = new QLabel(tr("Sample Size:"), pageEye);
    lblSampleSz->setStyleSheet(labelStyle);
    layoutEye->addWidget(lblSampleSz);
    auto *comboEyeSz = new QComboBox(pageEye);
    comboEyeSz->addItems({tr("Point Sample"), tr("3 by 3 Average"), tr("5 by 5 Average")});
    connect(comboEyeSz, QOverload<int>::of(&QComboBox::currentIndexChanged), this, [this](int idx) {
        m_eyedropperSampleSize = idx;
    });
    layoutEye->addWidget(comboEyeSz);

    auto *lblEyeSample = new QLabel(tr("Sample:"), pageEye);
    lblEyeSample->setStyleSheet(labelStyle);
    layoutEye->addWidget(lblEyeSample);
    auto *comboEyeSample = new QComboBox(pageEye);
    comboEyeSample->addItems({tr("All Layers"), tr("Current Layer")});
    connect(comboEyeSample, QOverload<int>::of(&QComboBox::currentIndexChanged), this, [this](int idx) {
        m_eyedropperSampleAll = (idx == 0);
    });
    layoutEye->addWidget(comboEyeSample);

    layoutEye->addStretch();
    m_optionsStack->addWidget(pageEye);

    // Page 13: Hand (Tool::Hand = 13)
    auto *pageHand = new QWidget(m_optionsStack);
    auto *layoutHand = new QHBoxLayout(pageHand);
    layoutHand->setContentsMargins(0, 0, 0, 0);
    layoutHand->setSpacing(8);

    auto *lblHandTitle = new QLabel(tr("Hand"), pageHand);
    lblHandTitle->setStyleSheet(titleStyle);
    layoutHand->addWidget(lblHandTitle);

    auto *btnFit = new QPushButton(tr("Fit on Screen"), pageHand);
    btnFit->setStyleSheet(btnStyle);
    connect(btnFit, &QPushButton::clicked, this, &SessionWindow::fitCanvas);
    layoutHand->addWidget(btnFit);

    auto *btnActual = new QPushButton(tr("100%"), pageHand);
    btnActual->setStyleSheet(btnStyle);
    connect(btnActual, &QPushButton::clicked, this, &SessionWindow::actualPixels);
    layoutHand->addWidget(btnActual);

    auto *lblHandHint = new QLabel(tr("Drag canvas to pan · Hold Space to pan from any tool"), pageHand);
    lblHandHint->setStyleSheet(labelStyle);
    layoutHand->addWidget(lblHandHint);

    layoutHand->addStretch();
    m_optionsStack->addWidget(pageHand);

    // Page 14: Zoom (Tool::Zoom = 14)
    auto *pageZoom = new QWidget(m_optionsStack);
    auto *layoutZoom = new QHBoxLayout(pageZoom);
    layoutZoom->setContentsMargins(0, 0, 0, 0);
    layoutZoom->setSpacing(8);

    auto *lblZoomTitle = new QLabel(tr("Zoom"), pageZoom);
    lblZoomTitle->setStyleSheet(titleStyle);
    layoutZoom->addWidget(lblZoomTitle);

    auto *btnZoomInTool = new QPushButton(tr("(+) Zoom In"), pageZoom);
    btnZoomInTool->setStyleSheet(btnStyle);
    connect(btnZoomInTool, &QPushButton::clicked, this, [this] { zoomStep(1); });
    layoutZoom->addWidget(btnZoomInTool);

    auto *btnZoomOutTool = new QPushButton(tr("(-) Zoom Out"), pageZoom);
    btnZoomOutTool->setStyleSheet(btnStyle);
    connect(btnZoomOutTool, &QPushButton::clicked, this, [this] { zoomStep(-1); });
    layoutZoom->addWidget(btnZoomOutTool);

    auto *btnZoomFit = new QPushButton(tr("Fit on Screen"), pageZoom);
    btnZoomFit->setStyleSheet(btnStyle);
    connect(btnZoomFit, &QPushButton::clicked, this, &SessionWindow::fitCanvas);
    layoutZoom->addWidget(btnZoomFit);

    auto *btnZoom100 = new QPushButton(tr("100%"), pageZoom);
    btnZoom100->setStyleSheet(btnStyle);
    connect(btnZoom100, &QPushButton::clicked, this, &SessionWindow::actualPixels);
    layoutZoom->addWidget(btnZoom100);

    layoutZoom->addStretch();
    m_optionsStack->addWidget(pageZoom);

    // Page 15: Idle (Tool::Idle = 15)
    auto *pageIdle = new QWidget(m_optionsStack);
    auto *layoutIdle = new QHBoxLayout(pageIdle);
    layoutIdle->setContentsMargins(0, 0, 0, 0);
    layoutIdle->setSpacing(8);
    auto *lblIdle = new QLabel(tr("Ready · Select a tool from the tool rail"), pageIdle);
    lblIdle->setStyleSheet(labelStyle);
    layoutIdle->addWidget(lblIdle);
    layoutIdle->addStretch();
    m_optionsStack->addWidget(pageIdle);

    m_optionsStackAction = m_optionsToolBar->addWidget(m_optionsStack);

    m_swiftUIOptionsContainer = new QWidget(m_optionsToolBar);
    m_swiftUIOptionsContainer->setObjectName("swiftUIOptionsContainer");
    m_swiftUIOptionsContainer->setFixedHeight(38);
    auto *layoutSwiftUI = new QHBoxLayout(m_swiftUIOptionsContainer);
    layoutSwiftUI->setContentsMargins(0, 0, 0, 0);
    layoutSwiftUI->setSpacing(0);
    m_swiftUIOptionsAction = m_optionsToolBar->addWidget(m_swiftUIOptionsContainer);
    m_swiftUIOptionsContainer->hide();
    m_swiftUIOptionsAction->setVisible(false);
}

void SessionWindow::updateOptionsBar() {
    PERF_SCOPE("updateOptionsBar");
    if (!m_optionsStack) return;
    const int idx = static_cast<int>(m_tool);
    if (idx >= 0 && idx < m_optionsStack->count()) {
        m_optionsStack->setCurrentIndex(idx);
    }
    if (m_tool == Tool::Brush && m_optionsStack->count() > 5) {
        auto *lbl = m_optionsStack->widget(5)->findChild<QLabel *>("options.brushTitle");
        if (lbl) lbl->setText(m_brushToolMode == BrushToolMode::Erase ? tr("Eraser") : tr("Brush"));
    }
    if (m_brushColorButton) {
        m_brushColorButton->setStyleSheet(QString("background-color: %1; border: 1px solid #101012; border-radius: 3px;").arg(m_brushColor.name()));
    }

    if (m_sessionHandle != 0 && m_swiftUIOptionsContainer) {
        QWidget *rendered = swiftUIRenderPanelIfChanged(m_sessionHandle, QStringLiteral("ToolHeaders"), m_swiftUICurrentToolHeader);
        if (rendered && rendered == m_swiftUICurrentToolHeader) {
            // Unchanged tree: the panel on screen already shows it (repainted, not rebuilt).
        } else if (rendered) {
            if (m_swiftUICurrentToolHeader) {
                m_swiftUIOptionsContainer->layout()->removeWidget(m_swiftUICurrentToolHeader);
                retireRenderedPanel(m_swiftUICurrentToolHeader);
                m_swiftUICurrentToolHeader = nullptr;
            }
            m_swiftUICurrentToolHeader = rendered;
            m_swiftUIOptionsContainer->layout()->addWidget(rendered);
            rendered->show();
            m_swiftUIOptionsContainer->show();
            if (m_swiftUIOptionsAction) m_swiftUIOptionsAction->setVisible(true);
            if (m_optionsStackAction) m_optionsStackAction->setVisible(false);
            m_optionsStack->hide();
        } else {
            if (m_swiftUICurrentToolHeader) {
                m_swiftUIOptionsContainer->layout()->removeWidget(m_swiftUICurrentToolHeader);
                retireRenderedPanel(m_swiftUICurrentToolHeader);
                m_swiftUICurrentToolHeader = nullptr;
            }
            m_swiftUIOptionsContainer->hide();
            if (m_swiftUIOptionsAction) m_swiftUIOptionsAction->setVisible(false);
            if (m_optionsStackAction) m_optionsStackAction->setVisible(true);
            m_optionsStack->show();
        }
    }
}

// A re-rendered SwiftUI panel replaces the previous one, often from inside one of that panel's own button handlers
// (the click that changed the state). Deleting it there frees the widget whose signal is still running — a
// use-after-free — and deleteLater() alone leaves it visible, stacked over its replacement, until the event loop
// comes back round. So: take it out of sight now, free it later.
void SessionWindow::retireRenderedPanel(QWidget *panel) {
    if (!panel) return;
    panel->hide();
    panel->deleteLater();
}

void SessionWindow::updateToolRail() {
    PERF_SCOPE("updateToolRail");
    if (m_sessionHandle == 0 || !m_toolsBar) return;
    if (!m_swiftUIToolRailContainer) {
        m_swiftUIToolRailContainer = new QWidget(m_toolsBar);
        m_swiftUIToolRailContainer->setObjectName("swiftUIToolRailContainer");
        auto *layout = new QVBoxLayout(m_swiftUIToolRailContainer);
        layout->setContentsMargins(0, 0, 0, 0);
        layout->setSpacing(0);
        m_toolsBar->insertWidget(m_toolsBar->actions().isEmpty() ? nullptr : m_toolsBar->actions().first(), m_swiftUIToolRailContainer);
    }
    QWidget *rendered = swiftUIRenderPanelIfChanged(m_sessionHandle, QStringLiteral("ToolRail"), m_swiftUICurrentToolRail);
    if (rendered && rendered == m_swiftUICurrentToolRail) {
            // Unchanged tree: the panel on screen already shows it (repainted, not rebuilt).
        } else if (rendered) {
        // The rail is upstream's ScrollView (taller than the default 1180x780 window, as on macOS): a re-render
        // (every palette change, tool switch) must keep where it was scrolled, or the lower tools and the colour
        // swatches jump out of view right after being used.
        int scrolled = 0;
        if (m_swiftUICurrentToolRail) {
            if (auto *area = m_swiftUICurrentToolRail->findChild<QScrollArea *>()) scrolled = area->verticalScrollBar()->value();
            else if (auto *self = qobject_cast<QScrollArea *>(m_swiftUICurrentToolRail)) scrolled = self->verticalScrollBar()->value();
        }
        if (auto *area = qobject_cast<QScrollArea *>(rendered) ? qobject_cast<QScrollArea *>(rendered) : rendered->findChild<QScrollArea *>()) {
            QTimer::singleShot(0, area, [area, scrolled] { area->verticalScrollBar()->setValue(scrolled); });
            if (!m_railFitChecked) {
                m_railFitChecked = true;
                // Opening size: upstream's 1180x780, grown (never past the screen) just enough that the whole rail —
                // every tool plus the colour swatches — shows without scrolling when the screen has the room.
                QTimer::singleShot(0, this, [this, area] {
                    if (isMaximized() || isFullScreen() || !area->widget()) return;
                    const int missing = area->widget()->sizeHint().height() - area->viewport()->height();
                    if (missing <= 0) return;
                    const QScreen *display = screen();
                    const int limit = display ? display->availableGeometry().height() - (frameGeometry().height() - height()) : height();
                    resize(width(), std::min(limit, height() + missing));
                });
            }
        }
        if (m_swiftUICurrentToolRail) {
            m_swiftUIToolRailContainer->layout()->removeWidget(m_swiftUICurrentToolRail);
            retireRenderedPanel(m_swiftUICurrentToolRail);
            m_swiftUICurrentToolRail = nullptr;
        }
        m_swiftUICurrentToolRail = rendered;
        m_swiftUIToolRailContainer->layout()->addWidget(rendered);
        rendered->show();
        m_swiftUIToolRailContainer->show();
        for (auto *act : m_toolActions.values()) act->setVisible(false);
        if (m_paletteAction) m_paletteAction->setVisible(false);
        if (auto *pal = m_toolsBar->findChild<QWidget *>("palette.controls")) pal->hide();
    }
}

void SessionWindow::updateLayersPanel() {
    PERF_SCOPE("updateLayersPanel");
    if (m_sessionHandle == 0 || !m_layersDock || !m_layersStack) return;
    QWidget *rendered = swiftUIRenderPanelIfChanged(m_sessionHandle, QStringLiteral("LayersPanel"), m_swiftUICurrentLayersPanel);
    if (rendered && rendered == m_swiftUICurrentLayersPanel) {
            // Unchanged tree: the panel on screen already shows it (repainted, not rebuilt).
        } else if (rendered) {
        if (m_swiftUICurrentLayersPanel) {
            m_swiftUILayersContainer->layout()->removeWidget(m_swiftUICurrentLayersPanel);
            retireRenderedPanel(m_swiftUICurrentLayersPanel);
            m_swiftUICurrentLayersPanel = nullptr;
        }
        m_swiftUICurrentLayersPanel = rendered;
        m_swiftUILayersContainer->layout()->addWidget(rendered);
        rendered->show();
        m_layersStack->setCurrentWidget(m_swiftUILayersContainer);
    } else {
        m_layersStack->setCurrentWidget(m_legacyLayersPanel);
    }
}

void SessionWindow::syncToolFromSession() {
    PERF_SCOPE("syncToolFromSession");
    if (m_sessionHandle == 0) return;
    const auto state = sessionState();
    const QString toolStr = state.value("tool").toString();
    if (toolStr.isEmpty()) return;
    Tool t = m_tool;
    if (toolStr == "move") t = Tool::Move;
    else if (toolStr == "marquee") t = Tool::Marquee;
    else if (toolStr == "lasso") t = Tool::Lasso;
    else if (toolStr == "wand") t = Tool::Magic;
    else if (toolStr == "crop") t = Tool::Crop;
    else if (toolStr == "brush") t = Tool::Brush;
    else if (toolStr == "spotHealing") t = Tool::SpotHealing;
    else if (toolStr == "cloneStamp") t = Tool::CloneStamp;
    else if (toolStr == "blur") t = Tool::Smear;
    else if (toolStr == "gradient") t = Tool::Gradient;
    else if (toolStr == "shape") t = Tool::Shape;
    else if (toolStr == "type") t = Tool::Type;
    else if (toolStr == "eyedropper") t = Tool::Eyedropper;
    else if (toolStr == "hand") t = Tool::Hand;
    else if (toolStr == "zoom") t = Tool::Zoom;
    else if (toolStr == "idle") t = Tool::Idle;
    if (t != m_tool) {
        QMetaObject::invokeMethod(this, [this, t] { setTool(t); }, Qt::QueuedConnection);
    }
}

void SessionWindow::syncOptionsFromSession() {
    PERF_SCOPE("syncOptionsFromSession");
    if (m_sessionHandle == 0) return;
    syncBrushFromSession();
    const auto state = sessionState();
    const QString selMode = state.value("selectionMode").toString();
    if (!selMode.isEmpty()) {
        m_selectionMode = selMode;
    }
    const QString lasso = state.value("lassoKind").toString();
    if (lasso == "Polygonal") {
        m_polygonalLasso = true;
    } else if (lasso == "Freehand") {
        m_polygonalLasso = false;
    }
    const QString marquee = state.value("marqueeKind").toString();
    if (marquee == "Ellipse") {
        m_marqueeMode = MarqueeMode::Ellipse;
    } else if (marquee == "Rectangle") {
        m_marqueeMode = MarqueeMode::Rectangle;
    }
}

void SessionWindow::updateStatusTelemetry() {
    PERF_SCOPE("updateStatusTelemetry");
    if (!statusBar()) return;

    if (!m_statusZoomLabel) {
        m_statusZoomLabel = new QLabel(this);
        m_statusZoomLabel->setObjectName("status.zoom");
        m_statusZoomLabel->setStyleSheet("color: #88888c; font-size: 11px; padding: 0 8px;");
        statusBar()->addWidget(m_statusZoomLabel);
    }
    if (!m_statusDimsLabel) {
        m_statusDimsLabel = new QLabel(this);
        m_statusDimsLabel->setObjectName("status.dims");
        m_statusDimsLabel->setStyleSheet("color: #88888c; font-size: 11px; padding: 0 8px; border-left: 1px solid #28282b;");
        statusBar()->addWidget(m_statusDimsLabel);
    }
    if (!m_statusProfileLabel) {
        m_statusProfileLabel = new QLabel(this);
        m_statusProfileLabel->setObjectName("status.profile");
        m_statusProfileLabel->setStyleSheet("color: #88888c; font-size: 11px; padding: 0 8px; border-left: 1px solid #28282b;");
        statusBar()->addWidget(m_statusProfileLabel);
    }
    if (!m_statusHintsLabel) {
        m_statusHintsLabel = new QLabel(this);
        m_statusHintsLabel->setObjectName("status.hints");
        m_statusHintsLabel->setStyleSheet("color: #707074; font-size: 11px; padding: 0 8px;");
        statusBar()->addPermanentWidget(m_statusHintsLabel);
    }

    // Same rect the canvas draws into, so the readout always matches what is on screen.
    const double effectiveZoom = viewportZoom();
    m_statusZoomLabel->setText(QString("%1%").arg(effectiveZoom * 100.0, 0, 'f', 1));

    if (!m_image.isNull()) {
        m_statusDimsLabel->setText(QString("%1 × %2 px").arg(docWidth()).arg(docHeight()));
    } else {
        m_statusDimsLabel->setText(tr("No canvas"));
    }
    m_statusProfileLabel->setText(tr("sRGB · Transparent"));

    QString hint;
    switch (m_tool) {
    case Tool::Move:
        hint = tr("Click to select · Click outside to deselect · Drag to move · Handles to resize · Space to pan");
        break;
    case Tool::Brush:
        if (m_brushToolMode == BrushToolMode::Erase) {
            hint = tr("Drag on canvas to erase · [ and ] resize eraser · 1–9 opacity · Space to pan");
        } else {
            hint = tr("Drag on canvas to paint · [ and ] resize brush · 1–9 opacity · Space to pan");
        }
        break;
    case Tool::Marquee:
    case Tool::Lasso:
        hint = tr("Drag to select · Drag inside to move · Shift add · Option subtract · Ctrl+D deselect");
        break;
    case Tool::Magic:
        hint = tr("Click to select region · Shift add · Option subtract · Ctrl+D deselect");
        break;
    case Tool::CloneStamp:
        hint = tr("Alt-click to set source · Drag to clone from source point");
        break;
    case Tool::SpotHealing:
        hint = tr("Drag over blemishes to heal using surrounding texture");
        break;
    case Tool::Crop:
        hint = tr("Drag to define crop region · Apply to crop canvas · Esc to cancel");
        break;
    case Tool::Smear:
        hint = tr("Drag to smudge or liquify pixels");
        break;
    case Tool::Gradient:
        hint = tr("Drag to apply gradient");
        break;
    case Tool::Shape:
        hint = tr("Drag to draw shape");
        break;
    case Tool::Type:
        hint = tr("Click on canvas to add text layer");
        break;
    case Tool::Eyedropper:
        hint = tr("Click on canvas to sample color");
        break;
    case Tool::Hand:
        hint = tr("Drag to pan canvas");
        break;
    case Tool::Zoom:
        hint = tr("Click to zoom in · Option-click to zoom out");
        break;
    default:
        hint = tr("Ready");
        break;
    }
    m_statusHintsLabel->setText(hint);

    if (m_sessionHandle != 0) {
        if (!m_swiftUIStatusBarContainer) {
            m_swiftUIStatusBarContainer = new QWidget(this);
            m_swiftUIStatusBarContainer->setObjectName("swiftUIStatusBarContainer");
            auto *layout = new QHBoxLayout(m_swiftUIStatusBarContainer);
            layout->setContentsMargins(0, 0, 0, 0);
            layout->setSpacing(0);
            statusBar()->addWidget(m_swiftUIStatusBarContainer, 1);
        }
        QWidget *rendered = swiftUIRenderPanelIfChanged(m_sessionHandle, QStringLiteral("StatusBar"), m_swiftUICurrentStatusBar);
        if (rendered && rendered == m_swiftUICurrentStatusBar) {
            // Unchanged tree: the panel on screen already shows it (repainted, not rebuilt).
        } else if (rendered) {
            if (m_swiftUICurrentStatusBar) {
                m_swiftUIStatusBarContainer->layout()->removeWidget(m_swiftUICurrentStatusBar);
                retireRenderedPanel(m_swiftUICurrentStatusBar);
                m_swiftUICurrentStatusBar = nullptr;
            }
            m_swiftUICurrentStatusBar = rendered;
            m_swiftUIStatusBarContainer->layout()->addWidget(rendered);
            rendered->show();
            m_swiftUIStatusBarContainer->show();
            m_statusZoomLabel->hide();
            m_statusDimsLabel->hide();
            m_statusProfileLabel->hide();
            m_statusHintsLabel->hide();
        } else {
            if (m_swiftUICurrentStatusBar) {
                m_swiftUIStatusBarContainer->layout()->removeWidget(m_swiftUICurrentStatusBar);
                retireRenderedPanel(m_swiftUICurrentStatusBar);
                m_swiftUICurrentStatusBar = nullptr;
            }
            m_swiftUIStatusBarContainer->hide();
            m_statusZoomLabel->show();
            m_statusDimsLabel->show();
            m_statusProfileLabel->show();
            m_statusHintsLabel->show();
        }
    }
}

void SessionWindow::fitCanvas() { changeViewport(1); }

void SessionWindow::actualPixels() { changeViewport(2, 1.0, qQNaN(), qQNaN()); }

/// session.zoomKeyboard: the next of upstream's stable zoom levels, about the center.
void SessionWindow::zoomStep(int step) { changeViewport(3, step); }
