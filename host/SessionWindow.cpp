// SessionWindow — see SessionWindow.h. Drives the Swift core via compositor_session_*
// and paints the composited RGBA via QImage. Implements file operations using Qt
// codecs (IO milestone: file-map "IO / codec mapping" tier).

#include "SessionWindow.h"
#include "ImageExporters.h"
#include "TabletHandler.h"
#include "LayerItemDelegate.h"
#include "ColorPickerDialog.h"

#include <QPainter>
#include <QPainterPath>
#include <QPaintEvent>
#include <QMouseEvent>
#include <QTabletEvent>
#include <QDragEnterEvent>
#include <QDropEvent>
#include <QMimeData>
#include <QClipboard>
#include <QGuiApplication>
#include <QUrl>
#include <QFileDialog>
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
#include <QStandardPaths>
#include <QDateTime>
#include <QCloseEvent>
#include <QStackedWidget>
#include <QTabBar>
#include <QSpinBox>
#include <QDoubleSpinBox>
#include <QLineEdit>
#include <QButtonGroup>
#include <QFrame>
#include <QToolButton>
#include <QMenu>
#include <QPixmap>
#include <QWheelEvent>

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
}

static int32_t cmd(uint64_t h, const char *json) {
    return compositor_session_command(h, reinterpret_cast<const uint8_t *>(json),
                                      std::strlen(json));
}

static QImage straightRGBA(const std::vector<uint8_t> &premultiplied, int width, int height) {
    std::vector<uint8_t> straight = premultiplied;
    for (size_t i = 0; i + 3 < straight.size(); i += 4) {
        const uint8_t alpha = straight[i + 3];
        if (alpha == 0) {
            straight[i] = straight[i + 1] = straight[i + 2] = 0;
        } else if (alpha != 255) {
            straight[i] = static_cast<uint8_t>(std::min(255, (static_cast<int>(straight[i]) * 255 + alpha / 2) / alpha));
            straight[i + 1] = static_cast<uint8_t>(std::min(255, (static_cast<int>(straight[i + 1]) * 255 + alpha / 2) / alpha));
            straight[i + 2] = static_cast<uint8_t>(std::min(255, (static_cast<int>(straight[i + 2]) * 255 + alpha / 2) / alpha));
        }
    }
    return QImage(reinterpret_cast<const uchar *>(straight.data()), width, height, width * 4,
                  QImage::Format_RGBA8888).copy();
}

static QImage renderToQImage(uint64_t h, int width, int height) {
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
    void mousePressEvent(QMouseEvent *event) override {
        m_window->canvasMousePressEvent(event, this);
    }
    void mouseMoveEvent(QMouseEvent *event) override {
        m_window->canvasMouseMoveEvent(event, this);
    }
    void mouseReleaseEvent(QMouseEvent *event) override {
        m_window->canvasMouseReleaseEvent(event, this);
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
        if (event->modifiers() & Qt::ControlModifier) {
            if (event->angleDelta().y() > 0) {
                m_window->zoomBy(1.25);
            } else if (event->angleDelta().y() < 0) {
                m_window->zoomBy(1.0 / 1.25);
            }
            event->accept();
        } else {
            QWidget::wheelEvent(event);
        }
    }
private:
    SessionWindow *m_window;
};

static QIcon makeToolIcon(SessionWindow::Tool tool) {
    QPixmap pix(22, 22);
    pix.fill(Qt::transparent);
    QPainter p(&pix);
    p.setRenderHint(QPainter::Antialiasing, true);
    p.setPen(QPen(QColor(0xd0, 0xd0, 0xd5), 1.5, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));

    switch (tool) {
    case SessionWindow::Tool::Move:
        p.drawLine(11, 3, 11, 19);
        p.drawLine(3, 11, 19, 11);
        p.drawLine(11, 3, 8, 6);
        p.drawLine(11, 3, 14, 6);
        p.drawLine(11, 19, 8, 16);
        p.drawLine(11, 19, 14, 16);
        p.drawLine(3, 11, 6, 8);
        p.drawLine(3, 11, 6, 14);
        p.drawLine(19, 11, 16, 8);
        p.drawLine(19, 11, 16, 14);
        break;
    case SessionWindow::Tool::Brush:
        p.drawLine(15, 4, 19, 8);
        p.drawLine(15, 4, 10, 10);
        p.drawLine(19, 8, 13, 14);
        p.drawLine(10, 10, 7, 16);
        p.drawLine(13, 14, 7, 16);
        p.setBrush(QColor(0xd0, 0xd0, 0xd5));
        p.drawEllipse(4, 15, 4, 4);
        break;
    case SessionWindow::Tool::Eraser:
        p.drawRoundedRect(4, 7, 14, 9, 2, 2);
        p.drawLine(9, 7, 9, 16);
        break;
    case SessionWindow::Tool::RectSelect:
        p.setPen(QPen(QColor(0xd0, 0xd0, 0xd5), 1.5, Qt::DashLine));
        p.drawRect(4, 4, 14, 14);
        break;
    case SessionWindow::Tool::EllipseSelect:
        p.setPen(QPen(QColor(0xd0, 0xd0, 0xd5), 1.5, Qt::DashLine));
        p.drawEllipse(4, 4, 14, 14);
        break;
    case SessionWindow::Tool::Lasso: {
        QPainterPath path;
        path.moveTo(5, 8);
        path.cubicTo(5, 3, 17, 3, 17, 10);
        path.cubicTo(17, 16, 12, 18, 9, 16);
        path.lineTo(6, 19);
        p.drawPath(path);
        break;
    }
    case SessionWindow::Tool::MagicWand:
        p.drawLine(4, 18, 15, 7);
        p.drawLine(17, 3, 17, 7);
        p.drawLine(15, 5, 19, 5);
        p.drawLine(13, 3, 13, 4);
        p.drawLine(19, 9, 19, 10);
        break;
    case SessionWindow::Tool::CloneStamp:
        p.drawEllipse(9, 2, 4, 4);
        p.drawLine(11, 6, 11, 11);
        p.drawRoundedRect(6, 11, 10, 5, 1, 1);
        p.fillRect(4, 16, 14, 3, QColor(0xd0, 0xd0, 0xd5));
        break;
    case SessionWindow::Tool::SpotHealing:
        p.save();
        p.translate(11, 11);
        p.rotate(45);
        p.drawRoundedRect(-4, -8, 8, 16, 3, 3);
        p.drawPoint(-1, 0); p.drawPoint(1, 0);
        p.restore();
        break;
    case SessionWindow::Tool::Crop:
        p.drawLine(3, 7, 15, 7);
        p.drawLine(7, 3, 7, 15);
        p.drawLine(7, 15, 19, 15);
        p.drawLine(15, 7, 15, 19);
        break;
    }
    return QIcon(pix);
}

SessionWindow::SessionWindow(QWidget *parent) : QMainWindow(parent) {
    setWindowTitle("Compositor");
    resize(1200, 800);
    setAcceptDrops(true);
    m_tabletHandler = std::make_unique<PressureModulatedTabletHandler>();
    applyDarkTheme();

    // Central canvas widget:
    m_canvasWidget = new SessionCanvasWidget(this);
    setCentralWidget(m_canvasWidget);

    auto *toolsBar = addToolBar(tr("Tools"));
    toolsBar->setObjectName("toolbar.tools");
    toolsBar->setMovable(false);
    toolsBar->setOrientation(Qt::Vertical);
    toolsBar->setToolButtonStyle(Qt::ToolButtonIconOnly);
    toolsBar->setIconSize(QSize(22, 22));
    addToolBar(Qt::LeftToolBarArea, toolsBar);
    auto *toolGroup = new QActionGroup(this);
    toolGroup->setExclusive(true);

    // Drive the Swift editor core through the C ABI: create a canvas, paint a red
    // stroke, render, and hold the composited RGBA as a QImage for paintEvent.
    m_sessionHandle = compositor_session_create();
    cmd(m_sessionHandle, R"({"version":1,"action":"new","width":64,"height":64})");
    cmd(m_sessionHandle, R"({"version":1,"action":"addLayer"})");
    cmd(m_sessionHandle, R"({"version":1,"action":"brushBegin","x":8,"y":8,"parameters":{"diameter":16,"hardness":1,"opacity":1,"red":1,"green":0,"blue":0,"erasing":0,"mask":0}})");
    cmd(m_sessionHandle, R"({"version":1,"action":"brushMove","x":48,"y":48})");
    cmd(m_sessionHandle, R"({"version":1,"action":"brushEnd"})");

    m_image = renderToQImage(m_sessionHandle, 64, 64);

    QMenu *file = menuBar()->addMenu(tr("&File"));
    file->addAction(tr("&New Canvas"), QKeySequence::New, this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"new","width":512,"height":512})") == 0) {
            m_image = renderToQImage(m_sessionHandle, 512, 512);
            refreshImage();
        }
    });
    file->addAction(tr("&Open Image..."), QKeySequence::Open, this, [this] {
        const QString path = QFileDialog::getOpenFileName(this, tr("Open Image"), QString(),
            tr("Images (*.png *.jpg *.jpeg *.bmp *.tiff *.webp);;All files (*)"));
        if (!path.isEmpty() && !importImage(path)) QMessageBox::warning(this, tr("Open failed"), tr("Could not open image."));
    });
    file->addAction(tr("Open &Project..."), this, [this] {
        const QString path = QFileDialog::getExistingDirectory(this, tr("Open Project"));
        if (!path.isEmpty() && !loadProject(path)) QMessageBox::warning(this, tr("Open failed"), tr("Could not open project."));
    });
    file->addAction(tr("Save Project &As..."), QKeySequence::Save, this, [this] {
        const QString path = QFileDialog::getSaveFileName(this, tr("Save Project"), QString(), tr("Compositor project (*.comp);;All files (*)"));
        if (!path.isEmpty() && !saveProject(path)) QMessageBox::warning(this, tr("Save failed"), tr("Could not save project."));
    });
    file->addAction(tr("Export &PNG..."), this, [this] {
        const QString path = QFileDialog::getSaveFileName(this, tr("Export PNG"), QString(), tr("PNG (*.png)"));
        if (!path.isEmpty() && !exportPNG(path)) QMessageBox::warning(this, tr("Export failed"), tr("Could not export PNG."));
    });
    file->addAction(tr("Export &JPEG..."), this, [this] {
        const QString path = QFileDialog::getSaveFileName(this, tr("Export JPEG"), QString(), tr("JPEG (*.jpg *.jpeg)"));
        if (!path.isEmpty() && !exportJPEG(path)) QMessageBox::warning(this, tr("Export failed"), tr("Could not export JPEG."));
    });
    file->addAction(tr("Export &TIFF..."), this, [this] {
        const QString path = QFileDialog::getSaveFileName(this, tr("Export TIFF"), QString(), tr("TIFF (*.tiff *.tif)"));
        if (!path.isEmpty() && !exportTIFF(path)) QMessageBox::warning(this, tr("Export failed"), tr("Could not export TIFF."));
    });
    file->addAction(tr("Export &WebP..."), this, [this] {
        const QString path = QFileDialog::getSaveFileName(this, tr("Export WebP"), QString(), tr("WebP (*.webp)"));
        if (!path.isEmpty() && !exportWebP(path)) QMessageBox::warning(this, tr("Export failed"), tr("Could not export WebP."));
    });
    file->addSeparator();
    file->addAction(tr("&Quit"), QKeySequence::Quit, this, &QWidget::close);

    QMenu *edit = menuBar()->addMenu(tr("&Edit"));
    edit->addAction(tr("&Undo"), QKeySequence::Undo, this, [this] {
        if (!m_painting && cmd(m_sessionHandle, R"({"version":1,"action":"undo"})") == 0) refreshImage();
    });
    edit->addAction(tr("&Redo"), QKeySequence::Redo, this, [this] {
        if (!m_painting && cmd(m_sessionHandle, R"({"version":1,"action":"redo"})") == 0) refreshImage();
    });
    edit->addSeparator();
    edit->addAction(tr("&Copy"), QKeySequence::Copy, this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"copy"})") == 0) {
            if (!m_image.isNull()) {
                QGuiApplication::clipboard()->setImage(m_image);
            }
            statusBar()->showMessage(tr("Copied to clipboard."), 1500);
        }
    });
    edit->addAction(tr("Copy &Merged"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"copyMerged"})") == 0) {
            if (!m_image.isNull()) {
                QGuiApplication::clipboard()->setImage(m_image);
            }
            statusBar()->showMessage(tr("Copied merged to clipboard."), 1500);
        }
    });
    edit->addAction(tr("Cu&t"), QKeySequence::Cut, this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"cut"})") == 0) refreshImage();
    });
    edit->addAction(tr("&Paste"), QKeySequence::Paste, this, [this] {
        const QClipboard *clipboard = QGuiApplication::clipboard();
        const QMimeData *mime = clipboard ? clipboard->mimeData() : nullptr;
        if (mime && mime->hasImage()) {
            QImage img = qvariant_cast<QImage>(mime->imageData());
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
                std::string name = "Pasted Layer";
                if (compositor_session_import_rgba(m_sessionHandle, premul.data(), premul.size(),
                                                   rgba.width(), rgba.height(),
                                                   reinterpret_cast<const uint8_t*>(name.data()), name.size(), 0) == 0) {
                    refreshImage();
                    refreshLayers();
                    return;
                }
            }
        }
        if (cmd(m_sessionHandle, R"({"version":1,"action":"paste"})") == 0) refreshImage();
    });
    edit->addAction(tr("Duplicate Layer"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"duplicateLayer"})") == 0) { refreshImage(); refreshLayers(); }
    });
    edit->addAction(tr("Content-Aware &Fill"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"contentFill"})") == 0) refreshImage();
    })->setObjectName("edit.contentFill");
    edit->addSeparator();
    auto *cmdPaletteAction = new QAction(tr("&Command Palette..."), this);
    cmdPaletteAction->setObjectName("commandPalette");
    cmdPaletteAction->setShortcuts({QKeySequence(Qt::CTRL | Qt::SHIFT | Qt::Key_P), QKeySequence(Qt::Key_F1)});
    connect(cmdPaletteAction, &QAction::triggered, this, [this] { showCommandPalette(); });
    addAction(cmdPaletteAction);
    edit->addAction(cmdPaletteAction);

    QMenu *viewMenu = menuBar()->addMenu(tr("&View"));
    viewMenu->addAction(tr("Fit on Screen"), QKeySequence(Qt::CTRL | Qt::Key_0), this, &SessionWindow::fitCanvas);
    viewMenu->addAction(tr("Actual Pixels (100%)"), QKeySequence(Qt::CTRL | Qt::Key_1), this, &SessionWindow::actualPixels);
    viewMenu->addAction(tr("Zoom &In"), QKeySequence::ZoomIn, this, [this] { zoomBy(1.25); });
    viewMenu->addAction(tr("Zoom &Out"), QKeySequence::ZoomOut, this, [this] { zoomBy(1.0 / 1.25); });

    QMenu *layer = menuBar()->addMenu(tr("&Layer"));
    layer->addAction(tr("&New Layer"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"addLayer"})") == 0) { refreshImage(); refreshLayers(); }
    });
    layer->addAction(tr("New &Folder / Group"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"addGroup"})") == 0) { refreshImage(); refreshLayers(); }
    })->setObjectName("layer.addGroup");
    layer->addAction(tr("&Delete Layer"), QKeySequence::Delete, this, [this] {
        deleteSelectedLayers();
    });
    layer->addAction(tr("Flip Layer &Horizontal"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"flipLayer","horizontally":true})") == 0) { refreshImage(); refreshLayers(); }
    });
    layer->addAction(tr("Flip Layer &Vertical"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"flipLayer","horizontally":false})") == 0) { refreshImage(); refreshLayers(); }
    });
    layer->addAction(tr("Add Rectangle"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"addShape","kind":"Rectangle","x":8,"y":8,"width":48,"height":32,"parameters":{"red":1,"green":1,"blue":1,"cornerRadius":0}})") == 0) { refreshImage(); refreshLayers(); }
    });
    layer->addAction(tr("Add Ellipse"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"addShape","kind":"Ellipse","x":8,"y":8,"width":48,"height":32,"parameters":{"red":1,"green":1,"blue":1}})") == 0) { refreshImage(); refreshLayers(); }
    });
    layer->addAction(tr("Add Reveal Mask"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"addRevealMask"})") == 0) { refreshImage(); refreshLayers(); }
    });
    layer->addAction(tr("Add Hide Mask"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"addHideMask"})") == 0) { refreshImage(); refreshLayers(); }
    });
    layer->addAction(tr("Invert Mask"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"invertMask"})") == 0) refreshImage();
    });
    layer->addAction(tr("Delete Mask"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"deleteMask"})") == 0) { refreshImage(); refreshLayers(); }
    });
    layer->addAction(tr("Remove &Background"), this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"removeBackground"})") == 0) { refreshImage(); refreshLayers(); }
    })->setObjectName("layer.removeBackground");
    QMenu *tool = menuBar()->addMenu(tr("&Tool"));
    auto addToolAct = [&](const QString &title, QKeySequence shortcut, Tool t, const char *objName) {
        auto *act = tool->addAction(title, shortcut, this, [this, t] { setTool(t); });
        act->setIcon(makeToolIcon(t));
        QString cleanTitle = title;
        cleanTitle.remove('&');
        act->setToolTip(QString("%1 (%2)").arg(cleanTitle).arg(shortcut.toString(QKeySequence::NativeText)));
        act->setObjectName(objName);
        act->setCheckable(true);
        toolGroup->addAction(act);
        toolsBar->addAction(act);
        m_toolActions[t] = act;
        if (t == Tool::Brush) act->setChecked(true);
        return act;
    };

    auto *actMove = addToolAct(tr("&Move Tool"), QKeySequence(Qt::Key_V), Tool::Move, "tool.move");
    auto *actBrush = addToolAct(tr("&Brush"), QKeySequence(Qt::Key_B), Tool::Brush, "tool.brush");
    auto *actEraser = addToolAct(tr("&Eraser"), QKeySequence(Qt::Key_E), Tool::Eraser, "tool.eraser");
    toolsBar->addSeparator();
    auto *actRect = addToolAct(tr("&Rectangular Marquee"), QKeySequence(Qt::Key_M), Tool::RectSelect, "tool.rectSelect");
    auto *actEllipse = addToolAct(tr("Elliptical &Marquee"), QKeySequence(Qt::SHIFT | Qt::Key_M), Tool::EllipseSelect, "tool.ellipseSelect");
    auto *actLasso = addToolAct(tr("&Lasso"), QKeySequence(Qt::Key_L), Tool::Lasso, "tool.lasso");
    auto *actWand = addToolAct(tr("Magic &Wand"), QKeySequence(Qt::Key_W), Tool::MagicWand, "tool.magicWand");
    toolsBar->addSeparator();
    auto *actClone = addToolAct(tr("&Clone Stamp"), QKeySequence(Qt::Key_S), Tool::CloneStamp, "tool.cloneStamp");
    auto *actHeal = addToolAct(tr("Spot &Healing"), QKeySequence(Qt::Key_J), Tool::SpotHealing, "tool.spotHealing");
    auto *actCrop = addToolAct(tr("&Crop"), QKeySequence(Qt::Key_C), Tool::Crop, "tool.crop");

    tool->addSeparator();
    tool->addAction(tr("Paint"), this, [this] { m_brushMode = "Paint"; setTool(Tool::Brush); });
    tool->addAction(tr("Smudge (Warp)"), this, [this] { m_brushMode = "Smudge"; setTool(Tool::Brush); });
    tool->addAction(tr("Liquify (Warp)"), this, [this] { m_brushMode = "Liquify"; setTool(Tool::Brush); });
    QMenu *filter = menuBar()->addMenu(tr("&Filter"));
    for (const QString &kind : {QString("Gaussian Blur"), QString("Motion Blur"), QString("Add Noise"),
                                QString("Lens Correction"), QString("Grain"), QString("Exposure")}) {
        auto *action = filter->addAction(kind, this, [this, kind] { showFilterDialog(kind); });
        action->setObjectName("filter." + kind);
    }
    QMenu *adjust = menuBar()->addMenu(tr("&Adjust"));
    for (const QString &kind : {QString("Levels"), QString("Hue/Saturation"), QString("Curves"),
                                QString("Exposure"), QString("Gradient Map"), QString("Grain")}) {
        auto *action = adjust->addAction(kind, this, [this, kind] { showAdjustDialog(kind); });
        action->setObjectName("adjust." + kind);
    }
    QMenu *imageMenu = menuBar()->addMenu(tr("&Image"));
    imageMenu->addAction(tr("Canvas Size…"), this, [this] { showSizeDialog(false); })->setObjectName("canvasSize");
    imageMenu->addAction(tr("Image Size…"), this, [this] { showSizeDialog(true); })->setObjectName("imageSize");

    auto *dock = new QDockWidget(tr("Layers"), this);
    dock->setObjectName("dock.layers");
    auto *panel = new QWidget(dock);
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

    dock->setMinimumWidth(252);
    dock->setMaximumWidth(352);
    panel->setMinimumWidth(252);
    panel->setMaximumWidth(352);
    dock->setWidget(panel);
    addDockWidget(Qt::RightDockWidgetArea, dock);

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
    refreshLayers();

    QMenu *select = menuBar()->addMenu(tr("&Select"));
    select->addAction(tr("Rectangle Selection"), this, [this] { selectRegion(true); })->setObjectName("select.rectangle");
    select->addAction(tr("Ellipse Selection"), this, [this] { selectRegion(false); })->setObjectName("select.ellipse");
    select->addAction(tr("Deselect"), this, [this] { if (cmd(m_sessionHandle, R"({"version":1,"action":"deselect"})") == 0) { refreshImage(); refreshLayers(); } })->setObjectName("select.deselect");

    imageMenu->addSeparator();
    imageMenu->addAction(tr("Fill Foreground"), this, [this] { if (cmd(m_sessionHandle, R"({"version":1,"action":"fillForeground"})") == 0) refreshImage(); })->setObjectName("fill.foreground");
    imageMenu->addAction(tr("Fill Background"), this, [this] { if (cmd(m_sessionHandle, R"({"version":1,"action":"fillBackground"})") == 0) refreshImage(); })->setObjectName("fill.background");
    imageMenu->addAction(tr("Clear Selection"), this, [this] { if (cmd(m_sessionHandle, R"({"version":1,"action":"clearSelection"})") == 0) refreshImage(); })->setObjectName("fill.clear");

    setupHeaderBar();
    setupOptionsBar();
    updateOptionsBar();
    updateStatusTelemetry();

    m_autosaveTimer = new QTimer(this);
    m_autosaveTimer->setObjectName("autosaveTimer");
    m_autosaveTimer->setInterval(60000);
    connect(m_autosaveTimer, &QTimer::timeout, this, [this] { performAutosave(); });
    m_autosaveTimer->start();
}

SessionWindow::~SessionWindow() {
    if (m_sessionHandle != 0) compositor_session_close(m_sessionHandle);
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

bool geometryContains(const SessionWindow::LayerGeometry &g, const QPointF &p) {
    const double r = g.rotation * kPi / 180.0;
    const double x = p.x() - (g.x + g.w / 2), y = p.y() - (g.y + g.h / 2);
    return std::abs(x * std::cos(r) + y * std::sin(r)) <= g.w / 2
        && std::abs(-x * std::sin(r) + y * std::cos(r)) <= g.h / 2;
}
}  // namespace

QRectF SessionWindow::canvasTargetRect() const {
    if (m_image.isNull()) return QRectF();
    const QSize canvasSize = m_canvasWidget ? m_canvasWidget->size() : size();
    const int pad = 24;
    const int maxW = std::max(10, canvasSize.width() - pad * 2);
    const int maxH = std::max(10, canvasSize.height() - pad * 2);
    double scale = 1.0;
    if (m_zoomLevel > 0.0) {
        scale = m_zoomLevel;
    } else {
        scale = std::min(static_cast<double>(maxW) / m_image.width(),
                         static_cast<double>(maxH) / m_image.height());
        if (m_image.width() <= 128 && m_image.height() <= 128) {
            int intScale = std::max(1, static_cast<int>(scale));
            scale = intScale;
        }
    }
    const double displayW = m_image.width() * scale;
    const double displayH = m_image.height() * scale;
    return QRectF((canvasSize.width() - displayW) / 2.0, (canvasSize.height() - displayH) / 2.0,
                  displayW, displayH);
}

QPointF SessionWindow::documentToCanvasPoint(const QPointF &docPoint) const {
    const QRectF target = canvasTargetRect();
    if (m_image.isNull() || target.width() <= 0 || target.height() <= 0) return docPoint;
    return QPointF(target.left() + docPoint.x() * target.width() / m_image.width(),
                   target.top() + docPoint.y() * target.height() / m_image.height());
}

QPointF SessionWindow::documentPoint(const QPointF &windowPoint) const {
    if (m_image.isNull()) return QPointF();
    const QRectF target = canvasTargetRect();
    if (target.width() <= 0 || target.height() <= 0) return QPointF();
    const QPointF local = windowPoint - target.topLeft();
    return QPointF(local.x() * m_image.width() / target.width(),
                   local.y() * m_image.height() / target.height());
}

void SessionWindow::canvasPaintEvent(QPaintEvent *event, QWidget *canvas) {
    Q_UNUSED(event);
    QPainter p(canvas);
    // Dark professional neutral workspace background
    p.fillRect(canvas->rect(), QColor(0x24, 0x25, 0x28));

    if (m_image.isNull()) return;

    const QRectF target = canvasTargetRect();
    const QRect targetI = target.toRect();

    // Subtle drop shadow around document canvas
    p.fillRect(targetI.adjusted(2, 2, 4, 4), QColor(0, 0, 0, 90));

    // Transparent checkerboard pattern
    static QPixmap checker;
    if (checker.isNull()) {
        QImage chk(16, 16, QImage::Format_RGB32);
        QPainter cp(&chk);
        cp.fillRect(0, 0, 8, 8, QColor(0xee, 0xee, 0xee));
        cp.fillRect(8, 8, 8, 8, QColor(0xee, 0xee, 0xee));
        cp.fillRect(8, 0, 8, 8, QColor(0xcc, 0xcc, 0xcc));
        cp.fillRect(0, 8, 8, 8, QColor(0xcc, 0xcc, 0xcc));
        checker = QPixmap::fromImage(chk);
    }
    p.drawTiledPixmap(targetI, checker);

    if (target.width() >= m_image.width()) {
        p.setRenderHint(QPainter::SmoothPixmapTransform, false);
    } else {
        p.setRenderHint(QPainter::SmoothPixmapTransform, true);
    }
    p.drawImage(target, m_image);

    // Canvas border outline
    p.setPen(QPen(QColor(0x10, 0x10, 0x10), 1));
    p.drawRect(targetI.adjusted(0, 0, -1, -1));

    drawTransformControls(p);

    // Interactive drag feedback (selection / crop marquee)
    if (m_painting && (m_tool == Tool::RectSelect || m_tool == Tool::EllipseSelect || m_tool == Tool::Crop)) {
        const QPointF startCanvas = documentToCanvasPoint(m_dragStart);
        const QPointF currentCanvas = documentToCanvasPoint(m_currentPoint);
        QRectF selRect(startCanvas, currentCanvas);
        selRect = selRect.normalized();
        p.setPen(QPen(Qt::white, 1, Qt::DashLine));
        if (m_tool == Tool::EllipseSelect) {
            p.drawEllipse(selRect);
        } else {
            p.drawRect(selRect);
        }
    }
}

void SessionWindow::canvasMousePressEvent(QMouseEvent *event, QWidget *canvas) {
    Q_UNUSED(canvas);
    m_currentPoint = documentPoint(event->position());
    mousePressEvent(event);
    if (m_canvasWidget) m_canvasWidget->update();
}

void SessionWindow::canvasMouseMoveEvent(QMouseEvent *event, QWidget *canvas) {
    Q_UNUSED(canvas);
    m_currentPoint = documentPoint(event->position());
    mouseMoveEvent(event);
    if (m_canvasWidget) m_canvasWidget->update();
}

void SessionWindow::canvasMouseReleaseEvent(QMouseEvent *event, QWidget *canvas) {
    Q_UNUSED(canvas);
    m_currentPoint = documentPoint(event->position());
    mouseReleaseEvent(event);
    if (m_canvasWidget) m_canvasWidget->update();
}

void SessionWindow::canvasTabletEvent(QTabletEvent *event, QWidget *canvas) {
    Q_UNUSED(canvas);
    tabletEvent(event);
    if (m_canvasWidget) m_canvasWidget->update();
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
    const int64_t size = compositor_session_state(m_sessionHandle, nullptr, 0);
    if (size <= 0 || size > 4 * 1024 * 1024) return {};
    QByteArray bytes(static_cast<qsizetype>(size), Qt::Uninitialized);
    if (compositor_session_state(m_sessionHandle, reinterpret_cast<uint8_t *>(bytes.data()), bytes.size()) != size) return {};
    return QJsonDocument::fromJson(bytes).object();
}

bool SessionWindow::sendCommand(const QJsonObject &command) {
    if (m_sessionHandle == 0) return false;
    QJsonObject payload = command;
    payload.insert("version", 1);
    const QByteArray bytes = QJsonDocument(payload).toJson(QJsonDocument::Compact);
    const int result = compositor_session_command(m_sessionHandle,
        reinterpret_cast<const uint8_t *>(bytes.constData()), bytes.size());
    if (result != 0) statusBar()->showMessage(sessionState().value("error").toString(tr("Could not apply the operation.")), 5000);
    return result == 0;
}

void SessionWindow::refreshImage() {
    if (m_sessionHandle == 0) return;
    const auto state = sessionState();
    const int width = state.value("width").toInt(), height = state.value("height").toInt();
    if (width <= 0 || height <= 0 || qint64(width) * height > 100000000) return;
    QImage rendered = renderToQImage(m_sessionHandle, width, height);
    if (rendered.isNull()) return;
    const int dpm = qRound(state.value("resolution").toDouble(72) / 0.0254);
    rendered.setDotsPerMeterX(dpm);
    rendered.setDotsPerMeterY(dpm);
    m_image = rendered;
    if (m_canvasWidget) m_canvasWidget->update();
    update();
    updateStatusTelemetry();
    QMetaObject::invokeMethod(this, [this] { refreshLayers(); }, Qt::QueuedConnection);
}

void SessionWindow::selectRegion(bool rectangle) {
    QJsonObject command{{"action", rectangle ? "selectRectangle" : "selectEllipse"},
                        {"x", 0}, {"y", 0}, {"width", m_image.width()}, {"height", m_image.height()}};
    if (sendCommand(command)) refreshImage();
}

bool SessionWindow::setLayerFlag(const char *action, bool on) {
    QJsonObject command{{"action", action}, {"enabled", on}};
    return sendCommand(command);
}

void SessionWindow::refreshLayers() {
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
            const int64_t assetBytes = compositor_session_export_layer(
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
}

void SessionWindow::selectLayerRow(int row) {
    if (m_syncingLayers || row < 0 || !m_layerModel || !m_layersView) return;
    if (row >= m_layerModel->rowCount()) return;
    const QModelIndex idx = m_layerModel->index(row, 0);
    if (!idx.isValid()) return;
    const QString id = idx.data(Qt::UserRole).toString();
    const QByteArray json = QString(R"({"version":1,"action":"selectLayer","layerID":"%1"})").arg(id).toUtf8();
    if (compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(json.constData()), json.size()) == 0) refreshImage();
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
    const QColor color = ColorPickerDialog::getColor(m_brushColor, this, tr("Brush color"));
    if (color.isValid()) setBrushColor(color);
}

void SessionWindow::setBrushColor(const QColor &color) {
    m_brushColor = color;
    const QString style = QString("background-color: rgb(%1, %2, %3);").arg(color.red()).arg(color.green()).arg(color.blue());
    m_brushColorButton->setStyleSheet(style);
    m_brushColorButton->setText(color.name());
}

void SessionWindow::setBrushDiameter(int value) { m_brushDiameter = value; }
void SessionWindow::setBrushHardness(int value) { m_brushHardness = value; }
void SessionWindow::setBrushOpacity(int value) { m_brushOpacity = value; }

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

void SessionWindow::setTool(Tool tool) {
    m_tool = tool;
    if (m_toolActions.contains(tool) && !m_toolActions[tool]->isChecked()) {
        m_toolActions[tool]->setChecked(true);
    }
    updateOptionsBar();
    updateStatusTelemetry();
}

void SessionWindow::mousePressEvent(QMouseEvent *event) {
    if (event->button() != Qt::LeftButton || m_painting) return;
    const QPointF point = documentPoint(event->position());
    m_dragStart = point;

    switch (m_tool) {
    case Tool::Move: {
        m_transformHandle = -1;
        m_transformDraft = LayerGeometry();
        // Auto Select: pick the topmost visible layer under the cursor unless a
        // handle of the current layer was grabbed.
        const int handle = hitTestTransformHandle(event->position());
        if (handle < 0 && m_autoSelectCheck && m_autoSelectCheck->isChecked()) {
            const bool insideActive = m_activeGeometry.valid && geometryContains(m_activeGeometry, point);
            for (auto it = m_layerGeometries.crbegin(); it != m_layerGeometries.crend(); ++it) {
                if (!it->valid || !it->visible || !geometryContains(*it, point)) continue;
                if (!insideActive || it->id != m_activeGeometry.id) {
                    if (!insideActive && sendCommand({{"action", "selectLayer"}, {"layerID", it->id}})) {
                        refreshImage();
                        refreshLayers();
                    }
                }
                break;
            }
        }
        if (m_activeGeometry.valid) {
            m_transformHandle = handle >= 0 ? handle : (geometryContains(m_activeGeometry, point) ? 9 : -1);
        }
        if (m_transformHandle >= 0) {
            m_transformStart = m_activeGeometry;
            sendCommand({{"action", "transformBegin"}});
        }
        m_painting = true;
        break;
    }
    case Tool::RectSelect:
    case Tool::EllipseSelect:
    case Tool::Crop:
        m_painting = true;
        break;
    case Tool::Lasso:
        m_lassoPoints.clear();
        m_lassoPoints.push_back(point);
        m_painting = true;
        break;
    case Tool::MagicWand: {
        const QString json = QString(R"({"version":1,"action":"magicWand","x":%1,"y":%2,"kind":"New","parameters":{"tolerance":32,"contiguous":1,"sampleAllLayers":0}})")
            .arg(point.x(), 0, 'f', 4).arg(point.y(), 0, 'f', 4);
        const QByteArray bytes = json.toUtf8();
        if (compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(bytes.constData()), bytes.size()) == 0) {
            refreshImage();
        }
        break;
    }
    case Tool::CloneStamp: {
        if (event->modifiers() & Qt::AltModifier) {
            m_cloneSource = point;
            m_hasCloneSource = true;
            statusBar()->showMessage(tr("Clone Stamp source set to (%1, %2)").arg(qRound(point.x())).arg(qRound(point.y())), 2000);
            return;
        }
        const double offX = m_hasCloneSource ? (m_cloneSource.x() - point.x()) : 0;
        const double offY = m_hasCloneSource ? (m_cloneSource.y() - point.y()) : 0;
        const QString json = QString(
            R"({"version":1,"action":"brushBegin","x":%1,"y":%2,"parameters":{"diameter":%3,"hardness":%4,"opacity":%5,"red":0,"green":0,"blue":0,"cloneOffsetX":%6,"cloneOffsetY":%7,"sampleAllLayers":0}})")
            .arg(point.x(), 0, 'f', 4).arg(point.y(), 0, 'f', 4)
            .arg(m_brushDiameter).arg(m_brushHardness / 100.0, 0, 'f', 3).arg(m_brushOpacity / 100.0, 0, 'f', 3)
            .arg(offX, 0, 'f', 4).arg(offY, 0, 'f', 4);
        const QByteArray bytes = json.toUtf8();
        if (compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(bytes.constData()), bytes.size()) == 0) {
            m_painting = true;
            refreshImage();
        }
        break;
    }
    case Tool::SpotHealing: {
        const QString json = QString(
            R"({"version":1,"action":"brushBegin","x":%1,"y":%2,"parameters":{"diameter":%3,"hardness":%4,"opacity":%5,"red":0,"green":0,"blue":0,"healing":1,"healingMode":0}})")
            .arg(point.x(), 0, 'f', 4).arg(point.y(), 0, 'f', 4)
            .arg(m_brushDiameter).arg(m_brushHardness / 100.0, 0, 'f', 3).arg(m_brushOpacity / 100.0, 0, 'f', 3);
        const QByteArray bytes = json.toUtf8();
        if (compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(bytes.constData()), bytes.size()) == 0) {
            m_painting = true;
            refreshImage();
        }
        break;
    }
    case Tool::Eraser:
    case Tool::Brush: {
        const bool warp = m_brushMode != "Paint";
        const int erasing = (m_tool == Tool::Eraser) ? 1 : 0;
        const QString json = warp
            ? QString(R"({"version":1,"action":"warpBegin","kind":"%1","x":%2,"y":%3,"parameters":{"diameter":%4,"hardness":%5,"opacity":1}})")
                .arg(m_brushMode).arg(point.x(), 0, 'f', 4).arg(point.y(), 0, 'f', 4).arg(m_brushDiameter).arg(m_brushHardness / 100.0, 0, 'f', 3)
            : QString(R"({"version":1,"action":"brushBegin","x":%1,"y":%2,"parameters":{"diameter":%3,"hardness":%4,"opacity":%5,"red":%6,"green":%7,"blue":%8,"erasing":%9,"mask":0}})")
                .arg(point.x(), 0, 'f', 4).arg(point.y(), 0, 'f', 4)
                .arg(m_brushDiameter).arg(m_brushHardness / 100.0, 0, 'f', 3).arg(m_brushOpacity / 100.0, 0, 'f', 3)
                .arg(m_brushColor.redF(), 0, 'f', 4).arg(m_brushColor.greenF(), 0, 'f', 4).arg(m_brushColor.blueF(), 0, 'f', 4).arg(erasing);
        const QByteArray bytes = json.toUtf8();
        if (compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(bytes.constData()), bytes.size()) == 0) {
            m_painting = true;
            refreshImage();
        }
        break;
    }
    }
}

void SessionWindow::mouseMoveEvent(QMouseEvent *event) {
    if (!m_painting) return;
    const QPointF point = documentPoint(event->position());
    if (m_tool == Tool::Move) {
        if (m_transformHandle >= 0) {
            m_transformDraft = draggedGeometry(point, event->modifiers());
            previewGeometry(m_transformDraft);
        }
    } else if (m_tool == Tool::Lasso) {
        m_lassoPoints.push_back(point);
    } else if (m_tool == Tool::Brush || m_tool == Tool::Eraser || m_tool == Tool::CloneStamp || m_tool == Tool::SpotHealing) {
        const QString json = QString(R"({"version":1,"action":"%1","x":%2,"y":%3})")
            .arg(m_brushMode == "Paint" ? "brushMove" : "warpMove")
            .arg(point.x(), 0, 'f', 4).arg(point.y(), 0, 'f', 4);
        const QByteArray bytes = json.toUtf8();
        if (compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(bytes.constData()), bytes.size()) == 0) refreshImage();
    }
}

void SessionWindow::mouseReleaseEvent(QMouseEvent *event) {
    if (event->button() != Qt::LeftButton || !m_painting) return;
    m_painting = false;
    const QPointF point = documentPoint(event->position());

    switch (m_tool) {
    case Tool::Move: {
        if (m_transformHandle >= 0) {
            if (m_transformDraft.valid) sendCommand({{"action", "transformCommit"}});
            else sendCommand({{"action", "transformCancel"}});
            m_transformHandle = -1;
            m_transformDraft = LayerGeometry();
            refreshImage();
            refreshLayers();
        }
        break;
    }
    case Tool::RectSelect:
    case Tool::EllipseSelect: {
        const double x = std::min(m_dragStart.x(), point.x());
        const double y = std::min(m_dragStart.y(), point.y());
        const int w = qRound(std::abs(point.x() - m_dragStart.x()));
        const int h = qRound(std::abs(point.y() - m_dragStart.y()));
        if (w > 0 && h > 0) {
            const char *action = (m_tool == Tool::RectSelect) ? "selectRectangle" : "selectEllipse";
            const QString json = QString(R"({"version":1,"action":"%1","x":%2,"y":%3,"width":%4,"height":%5})")
                .arg(action).arg(x, 0, 'f', 2).arg(y, 0, 'f', 2).arg(w).arg(h);
            const QByteArray bytes = json.toUtf8();
            if (compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(bytes.constData()), bytes.size()) == 0) {
                refreshImage();
            }
        }
        break;
    }
    case Tool::Crop: {
        const double x = std::max(0.0, std::min(m_dragStart.x(), point.x()));
        const double y = std::max(0.0, std::min(m_dragStart.y(), point.y()));
        const int w = qRound(std::abs(point.x() - m_dragStart.x()));
        const int h = qRound(std::abs(point.y() - m_dragStart.y()));
        if (w > 0 && h > 0) {
            const QString json = QString(R"({"version":1,"action":"cropCanvas","x":%1,"y":%2,"width":%3,"height":%4})")
                .arg(x, 0, 'f', 2).arg(y, 0, 'f', 2).arg(w).arg(h);
            const QByteArray bytes = json.toUtf8();
            if (compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(bytes.constData()), bytes.size()) == 0) {
                refreshImage();
            }
        }
        break;
    }
    case Tool::Lasso: {
        m_lassoPoints.push_back(point);
        if (m_lassoPoints.size() >= 3) {
            QString pts = "[";
            for (size_t i = 0; i < m_lassoPoints.size(); ++i) {
                if (i > 0) pts += ",";
                pts += QString("[%1,%2]").arg(m_lassoPoints[i].x(), 0, 'f', 2).arg(m_lassoPoints[i].y(), 0, 'f', 2);
            }
            pts += "]";
            const QString json = QString(R"({"version":1,"action":"selectLasso","points":%1})").arg(pts);
            const QByteArray bytes = json.toUtf8();
            if (compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(bytes.constData()), bytes.size()) == 0) {
                refreshImage();
            }
        }
        m_lassoPoints.clear();
        break;
    }
    case Tool::Brush:
    case Tool::Eraser:
    case Tool::CloneStamp:
    case Tool::SpotHealing: {
        const char *action = m_brushMode == "Paint" ? "brushEnd" : "warpEnd";
        const QByteArray json = QString(R"({"version":1,"action":"%1"})").arg(action).toUtf8();
        if (compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(json.constData()), json.size()) == 0) refreshImage();
        break;
    }
    case Tool::MagicWand:
        break;
    }
}

void SessionWindow::tabletEvent(QTabletEvent *event) {
    const QPointF point = documentPoint(event->position());
    if (m_tool == Tool::Brush || m_tool == Tool::Eraser) {
        switch (event->type()) {
        case QEvent::TabletPress:
            if (m_tabletHandler && m_tabletHandler->handleTabletPress(event, m_sessionHandle, point, m_brushDiameter,
                                                                      m_brushHardness, m_brushOpacity, m_brushColor,
                                                                      m_tool == Tool::Eraser)) {
                m_painting = true;
                refreshImage();
                event->accept();
                return;
            }
            break;
        case QEvent::TabletMove:
            if (m_tabletHandler && m_tabletHandler->handleTabletMove(event, m_sessionHandle, point, m_painting)) {
                refreshImage();
                event->accept();
                return;
            }
            break;
        case QEvent::TabletRelease:
            if (m_tabletHandler && m_tabletHandler->handleTabletRelease(event, m_sessionHandle, m_painting)) {
                m_painting = false;
                refreshImage();
                event->accept();
                return;
            }
            break;
        default:
            break;
        }
    }
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
            if (url.isLocalFile() && importImage(url.toLocalFile())) {
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
    return exporter && exporter->exportImage(m_image, path);
}

// IO milestone: Export flattened canvas as JPEG via IImageExporter interface (SOLID)
bool SessionWindow::exportJPEG(const QString &path, int quality) {
    if (m_sessionHandle == 0 || m_image.isNull()) return false;
    auto exporter = ImageExporterRegistry::instance().exporterForFormat("jpeg");
    return exporter && exporter->exportImage(m_image, path, quality);
}

// Parity milestone: Export flattened canvas as TIFF via IImageExporter interface (SOLID)
bool SessionWindow::exportTIFF(const QString &path) {
    if (m_sessionHandle == 0 || m_image.isNull()) return false;
    auto exporter = ImageExporterRegistry::instance().exporterForFormat("tiff");
    return exporter && exporter->exportImage(m_image, path);
}

// Parity milestone: Export flattened canvas as WebP via IImageExporter interface (SOLID)
bool SessionWindow::exportWebP(const QString &path, int quality) {
    if (m_sessionHandle == 0 || m_image.isNull()) return false;
    auto exporter = ImageExporterRegistry::instance().exporterForFormat("webp");
    return exporter && exporter->exportImage(m_image, path, quality);
}

// IO milestone: Import image using Qt's QImageReader
// (replaces macOS CGImageSource/CoreImage). Loads image, converts to
// premultiplied RGBA, and imports via compositor_session_import_rgba.
bool SessionWindow::importImage(const QString &path) {
    if (m_sessionHandle == 0) return false;

    QImageReader reader(path);
    reader.setAutoTransform(true); // Handle EXIF orientation
    QImage image = reader.read();
    if (image.isNull()) return false;

    // Convert to RGBA8888 (straight alpha) then premultiply for the core
    QImage rgba = image.convertToFormat(QImage::Format_RGBA8888);
    if (rgba.isNull()) return false;

    // Premultiply alpha (core expects premultiplied RGBA)
    for (int y = 0; y < rgba.height(); ++y) {
        uint8_t *scan = rgba.scanLine(y);
        for (int x = 0; x < rgba.width(); ++x) {
            uint8_t a = scan[x * 4 + 3];
            if (a != 255) {
                scan[x * 4] = (scan[x * 4] * a + 127) / 255;
                scan[x * 4 + 1] = (scan[x * 4 + 1] * a + 127) / 255;
                scan[x * 4 + 2] = (scan[x * 4 + 2] * a + 127) / 255;
            }
        }
    }

    QByteArray nameBytes = QFileInfo(path).baseName().toUtf8();
    int32_t rc = compositor_session_import_rgba(m_sessionHandle,
                                                rgba.constBits(), rgba.sizeInBytes(),
                                                rgba.width(), rgba.height(),
                                                reinterpret_cast<const uint8_t *>(nameBytes.constData()), nameBytes.size(),
                                                1); // replacing = true
    if (rc != 0) return false;

    // Update displayed image
    m_image = renderToQImage(m_sessionHandle, rgba.width(), rgba.height());
    update();
    return true;
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
    const uint64_t replacement = compositor_session_create();
    if (replacement == 0) return false;
    int32_t rc = compositor_session_import_manifest(replacement,
                                                    reinterpret_cast<const uint8_t *>(manifestData.constData()),
                                                    manifestData.size());
    if (rc != 0) {
        compositor_session_close(replacement);
        return false;
    }
    const QFileInfo imagesInfo(dir.filePath("images"));
    if (!imagesInfo.isDir() || imagesInfo.isSymLink()) {
        compositor_session_close(replacement);
        return false;
    }
    uint64_t imagePixels = 0, maskPixels = 0;

    for (const QJsonValue &value : manifest.value("layers").toArray()) {
        const QJsonObject layer = value.toObject();
        const QString idString = layer.value("id").toString();
        const QByteArray id = idString.toUtf8();
        if (id.isEmpty()) { compositor_session_close(replacement); return false; }
        for (const bool isMask : {false, true}) {
            const QString filename = layer.value(isMask ? "maskFile" : "imageFile").toString();
            if (filename.isEmpty()) continue;
            const QString expected = idString + (isMask ? ".mask.png" : ".png");
            if (filename != expected || QFileInfo(filename).fileName() != filename) {
                compositor_session_close(replacement);
                return false;
            }
            const QFileInfo assetInfo(QDir(imagesInfo.filePath()).filePath(filename));
            if (!assetInfo.isFile() || assetInfo.isSymLink() || assetInfo.size() > 512LL * 1024 * 1024) {
                compositor_session_close(replacement);
                return false;
            }
            QImageReader reader(assetInfo.filePath());
            if (reader.format().toLower() != QByteArray("png")) {
                compositor_session_close(replacement);
                return false;
            }
            const QSize decodedSize = reader.size();
            const uint64_t pixels = decodedSize.isValid()
                ? static_cast<uint64_t>(decodedSize.width()) * static_cast<uint64_t>(decodedSize.height()) : 0;
            uint64_t &usedPixels = isMask ? maskPixels : imagePixels;
            if (!decodedSize.isValid() || decodedSize.width() <= 0 || decodedSize.height() <= 0 ||
                decodedSize.width() > 30'000 || decodedSize.height() > 30'000 ||
                pixels > 100'000'000 || usedPixels > 100'000'000 - pixels) {
                compositor_session_close(replacement);
                return false;
            }
            usedPixels += pixels;
            const QImage decoded = reader.read();
            if (decoded.isNull()) { compositor_session_close(replacement); return false; }
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
            if (rc != 0) { compositor_session_close(replacement); return false; }
        }
    }

    // Render the loaded document
    int width = manifest["width"].toInt();
    int height = manifest["height"].toInt();
    if (width <= 0 || height <= 0) { compositor_session_close(replacement); return false; }
    QImage rendered = renderToQImage(replacement, width, height);
    if (rendered.isNull()) { compositor_session_close(replacement); return false; }
    compositor_session_close(m_sessionHandle);
    m_sessionHandle = replacement;
    m_image = rendered;
    refreshImage();
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
    QString dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    if (dir.isEmpty()) {
        dir = QDir::tempPath() + "/Compositor";
    }
    return dir + "/recovery";
}

bool SessionWindow::hasAutosaveRecovery() const {
    const QString recoveryDir = autosaveDirectory();
    const QString manifestPath = recoveryDir + "/autosave.comp/manifest.json";
    return QFileInfo::exists(manifestPath);
}

bool SessionWindow::performAutosave() {
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
    clearAutosave();
    QMainWindow::closeEvent(event);
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

int SessionWindow::hitTestTransformHandle(const QPointF &canvasPoint) const {
    if (!m_activeGeometry.valid) return -1;
    const LayerGeometry &g = m_activeGeometry;
    const double reach = 8.0;
    const QPointF top = documentToCanvasPoint(geometryPoint(g, QPointF(0.5, 0)));
    const QPointF center = documentToCanvasPoint(geometryPoint(g, QPointF(0.5, 0.5)));
    QPointF outward = top - center;
    const double length = std::hypot(outward.x(), outward.y());
    if (length > 0) outward /= length;
    if (QLineF(canvasPoint, top + outward * 26.0).length() <= reach) return 8;
    for (int i = 0; i < 8; ++i) {
        if (QLineF(canvasPoint, documentToCanvasPoint(geometryPoint(g, kHandleUnits[i]))).length() <= reach) return i;
    }
    return -1;
}

void SessionWindow::drawTransformControls(QPainter &p) const {
    if (m_tool != Tool::Move || !m_activeGeometry.valid || !m_showControlsCheck || !m_showControlsCheck->isChecked()) return;
    const LayerGeometry &g = (m_transformHandle >= 0 && m_transformDraft.valid) ? m_transformDraft : m_activeGeometry;
    p.save();
    p.setRenderHint(QPainter::Antialiasing, true);
    QPolygonF outline;
    for (const QPointF &corner : {QPointF(0, 0), QPointF(1, 0), QPointF(1, 1), QPointF(0, 1)}) {
        outline << documentToCanvasPoint(geometryPoint(g, corner));
    }
    p.setPen(QPen(QColor(0xf2, 0xf2, 0xf5), 1));
    p.setBrush(Qt::NoBrush);
    p.drawPolygon(outline);
    const QPointF top = documentToCanvasPoint(geometryPoint(g, QPointF(0.5, 0)));
    const QPointF center = documentToCanvasPoint(geometryPoint(g, QPointF(0.5, 0.5)));
    QPointF outward = top - center;
    const double length = std::hypot(outward.x(), outward.y());
    if (length > 0) outward /= length;
    const QPointF rotateHandle = top + outward * 26.0;
    p.drawLine(top, rotateHandle);
    p.setBrush(QColor(0xf2, 0xf2, 0xf5));
    p.drawEllipse(rotateHandle, 3.5, 3.5);
    p.setBrush(QColor(0xff, 0xff, 0xff));
    p.setPen(QPen(QColor(0x50, 0x50, 0x58), 1));
    for (const QPointF &unit : kHandleUnits) {
        const QPointF c = documentToCanvasPoint(geometryPoint(g, unit));
        p.drawRect(QRectF(c.x() - 4, c.y() - 4, 8, 8));
    }
    p.restore();
}

void SessionWindow::previewGeometry(const LayerGeometry &g) {
    const QJsonObject command{{"action", "transformPreview"}, {"parameters", QJsonObject{
        {"x", g.x}, {"y", g.y}, {"width", g.w}, {"height", g.h}, {"rotation", g.rotation}}}};
    if (sendCommand(command)) refreshImage();
}

SessionWindow::LayerGeometry SessionWindow::draggedGeometry(const QPointF &point, Qt::KeyboardModifiers modifiers) const {
    LayerGeometry g = m_transformStart;
    const double r = g.rotation * kPi / 180.0;
    if (m_transformHandle == 9) {
        g.x += point.x() - m_dragStart.x();
        g.y += point.y() - m_dragStart.y();
        return g;
    }
    const QPointF c0(g.x + g.w / 2, g.y + g.h / 2);
    if (m_transformHandle == 8) {
        double degrees = std::atan2(point.y() - c0.y(), point.x() - c0.x()) * 180.0 / kPi + 90.0;
        if (modifiers & Qt::ShiftModifier) degrees = std::round(degrees / 15.0) * 15.0;
        while (degrees > 180.0) degrees -= 360.0;
        while (degrees <= -180.0) degrees += 360.0;
        g.rotation = degrees;
        return g;
    }
    // Resize in the layer's own (rotated) frame around the opposite edge / corner.
    const QPointF unit = kHandleUnits[m_transformHandle];
    const double dx = point.x() - c0.x(), dy = point.y() - c0.y();
    const QPointF local(dx * std::cos(r) + dy * std::sin(r), -dx * std::sin(r) + dy * std::cos(r));
    const bool moveX = unit.x() != 0.5, moveY = unit.y() != 0.5;
    const double signX = unit.x() > 0.5 ? 1.0 : -1.0, signY = unit.y() > 0.5 ? 1.0 : -1.0;
    const double anchorX = moveX ? -signX * g.w / 2 : 0, anchorY = moveY ? -signY * g.h / 2 : 0;
    double newW = moveX ? std::max(1.0, signX * (local.x() - anchorX)) : g.w;
    double newH = moveY ? std::max(1.0, signY * (local.y() - anchorY)) : g.h;
    const bool corner = moveX && moveY;
    if (corner && ((m_linkCheck && m_linkCheck->isChecked()) != bool(modifiers & Qt::ShiftModifier))) {
        const double scale = std::max(newW / g.w, newH / g.h);
        newW = std::max(1.0, g.w * scale);
        newH = std::max(1.0, g.h * scale);
    }
    const double cx = moveX ? anchorX + signX * newW / 2 : 0;
    const double cy = moveY ? anchorY + signY * newH / 2 : 0;
    const QPointF center(c0.x() + cx * std::cos(r) - cy * std::sin(r), c0.y() + cx * std::sin(r) + cy * std::cos(r));
    g.w = std::round(newW);
    g.h = std::round(newH);
    g.x = center.x() - g.w / 2;
    g.y = center.y() - g.h / 2;
    return g;
}

void SessionWindow::applyDarkTheme() {
    const QString qss = QString::fromUtf8(R"(
        QMainWindow {
            background-color: #1c1d1f;
            color: #e5e5e7;
        }
        QWidget {
            color: #e5e5e7;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
            font-size: 12px;
        }
        QMenuBar {
            background-color: #1e1e20;
            color: #d0d0d5;
            border-bottom: 1px solid #141416;
            padding: 2px 6px;
        }
        QMenuBar::item {
            background: transparent;
            padding: 4px 8px;
            border-radius: 4px;
        }
        QMenuBar::item:selected {
            background-color: #2c2c30;
            color: #ffffff;
        }
        QMenu {
            background-color: #242427;
            color: #e0e0e5;
            border: 1px solid #38383c;
            border-radius: 6px;
            padding: 4px;
        }
        QMenu::item {
            padding: 5px 24px 5px 12px;
            border-radius: 4px;
        }
        QMenu::item:selected {
            background-color: #007aff;
            color: #ffffff;
        }
        QMenu::separator {
            height: 1px;
            background-color: #38383c;
            margin: 4px 8px;
        }
        QToolBar {
            background-color: #1e1e20;
            border: none;
            spacing: 4px;
            padding: 2px;
        }
        QToolBar#toolbar.tools {
            background-color: #1e1e20;
            border-right: 1px solid #141416;
            spacing: 2px;
            padding: 4px;
            width: 44px;
        }
        QToolBar#toolbar.tools QToolButton {
            background: transparent;
            color: #c0c0c5;
            border: 1px solid transparent;
            border-radius: 5px;
            padding: 5px;
            margin: 1px 2px;
            min-width: 28px;
            min-height: 28px;
            font-size: 11px;
        }
        QToolBar#toolbar.tools QToolButton:hover {
            background-color: #2c2c30;
            color: #ffffff;
        }
        QToolBar#toolbar.tools QToolButton:checked {
            background-color: #38393e;
            color: #ffffff;
            border: 1px solid #4a4b52;
        }
        QToolBar::separator {
            background-color: #2d2d30;
            height: 1px;
            margin: 4px 4px;
        }
        QDockWidget {
            background-color: #1e1e20;
            color: #e0e0e5;
            border: none;
        }
        QDockWidget::title {
            background-color: #1e1e20;
            color: #e0e0e5;
            padding: 8px 12px;
            border-bottom: 1px solid #141416;
            font-weight: 600;
            font-size: 12px;
        }
        QDockWidget > QWidget {
            background-color: #1e1e20;
            border-left: 1px solid #141416;
        }
        QTreeView {
            background-color: #1a1a1c;
            alternate-background-color: #202023;
            color: #dcdce0;
            border: none;
            outline: 0;
            selection-background-color: #3a3b3f;
            selection-color: #ffffff;
            show-decoration-selected: 1;
        }
        QHeaderView::section {
            background-color: #1e1e20;
            color: #88888c;
            padding: 4px 8px;
            border: none;
            border-bottom: 1px solid #28282c;
            font-size: 11px;
            font-weight: 600;
        }
        QStatusBar {
            background-color: #1e1e20;
            color: #88888c;
            border-top: 1px solid #141416;
            font-size: 11px;
            min-height: 24px;
        }
        QStatusBar QLabel {
            color: #88888c;
            font-size: 11px;
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
            color: #e0e0e5;
            border: 1px solid #38383c;
            border-radius: 4px;
            padding: 3px 8px;
            min-height: 18px;
            font-size: 11px;
        }
        QComboBox:hover {
            border-color: #4a4a50;
        }
        QComboBox::drop-down {
            subcontrol-origin: padding;
            subcontrol-position: top right;
            width: 18px;
            border-left-width: 0px;
        }
        QComboBox QAbstractItemView {
            background-color: #242427;
            color: #e0e0e5;
            border: 1px solid #38383c;
            selection-background-color: #007aff;
            selection-color: #ffffff;
            padding: 4px;
        }
        QCheckBox {
            color: #d0d0d5;
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
            color: #e0e0e5;
            border: 1px solid #38383c;
            border-radius: 4px;
            padding: 2px 4px;
            font-size: 11px;
        }
        QSpinBox:focus, QDoubleSpinBox:focus, QLineEdit:focus {
            border: 1px solid #007aff;
        }
        QPushButton {
            background-color: #2a2a2d;
            color: #d0d0d5;
            border: 1px solid #38383c;
            border-radius: 4px;
            padding: 4px 10px;
            font-size: 11px;
        }
        QPushButton:hover {
            background-color: #35353a;
            color: #ffffff;
            border-color: #48484f;
        }
        QPushButton:pressed {
            background-color: #1f1f22;
        }
    )");
    setStyleSheet(qss);
}

void SessionWindow::setupHeaderBar() {
    m_headerToolBar = addToolBar(tr("Header"));
    m_headerToolBar->setObjectName("toolbar.header");
    m_headerToolBar->setMovable(false);
    m_headerToolBar->setFixedHeight(36);
    m_headerToolBar->setStyleSheet("QToolBar { background: #1e1e20; border-bottom: 1px solid #141416; spacing: 6px; padding: 2px 8px; }");

    auto *btnNew = new QPushButton("+", m_headerToolBar);
    btnNew->setObjectName("newCanvasToolbar");
    btnNew->setToolTip(tr("New canvas (Ctrl+N)"));
    btnNew->setFixedSize(26, 26);
    btnNew->setStyleSheet(
        "QPushButton { background: #2a2a2d; color: #d0d0d0; border: 1px solid #3a3a3d; border-radius: 4px; font-size: 15px; font-weight: bold; } "
        "QPushButton:hover { background: #353539; color: #ffffff; } "
        "QPushButton:pressed { background: #202022; }"
    );
    connect(btnNew, &QPushButton::clicked, this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"new","width":512,"height":512})") == 0) {
            m_image = renderToQImage(m_sessionHandle, 512, 512);
            refreshImage();
        }
    });
    m_headerToolBar->addWidget(btnNew);

    m_documentTabBar = new QTabBar(m_headerToolBar);
    m_documentTabBar->setObjectName("header.documentTabs");
    m_documentTabBar->setDrawBase(false);
    m_documentTabBar->setExpanding(false);
    m_documentTabBar->setTabsClosable(true);
    m_documentTabBar->addTab(tr("Untitled 1"));
    m_documentTabBar->setStyleSheet(
        "QTabBar::tab { background: #252528; color: #9a9a9f; border: 1px solid #333336; border-radius: 5px; padding: 3px 12px; margin-right: 4px; font-size: 12px; } "
        "QTabBar::tab:selected { background: #38393e; color: #ffffff; border: 1px solid #4a4b52; } "
        "QTabBar::tab:hover:!selected { background: #2e2f33; color: #d0d0d5; } "
        "QTabBar::close-button { image: none; subcontrol-position: right; margin-left: 4px; } "
        "QTabBar::close-button:hover { background: #55555a; border-radius: 2px; }"
    );
    m_headerToolBar->addWidget(m_documentTabBar);

    auto *spacer = new QWidget(m_headerToolBar);
    spacer->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Preferred);
    m_headerToolBar->addWidget(spacer);

    auto makeZoomBtn = [this](const QString &text, const QString &objName, const QString &tooltip) {
        auto *btn = new QPushButton(text, m_headerToolBar);
        btn->setObjectName(objName);
        btn->setToolTip(tooltip);
        btn->setFixedHeight(24);
        btn->setStyleSheet(
            "QPushButton { background: #2a2a2d; color: #c8c8cd; border: 1px solid #38383c; border-radius: 4px; padding: 2px 8px; font-size: 11px; font-weight: 500; } "
            "QPushButton:hover { background: #35353a; color: #ffffff; border-color: #4a4a50; } "
            "QPushButton:pressed { background: #202022; }"
        );
        return btn;
    };

    auto *btnFit = makeZoomBtn(tr("Fit"), "fitCanvas", tr("Fit canvas in window (Ctrl+0)"));
    connect(btnFit, &QPushButton::clicked, this, &SessionWindow::fitCanvas);
    m_headerToolBar->addWidget(btnFit);

    auto *btn100 = makeZoomBtn(tr("100%"), "actualPixels", tr("Actual pixels (Ctrl+1)"));
    connect(btn100, &QPushButton::clicked, this, &SessionWindow::actualPixels);
    m_headerToolBar->addWidget(btn100);

    auto *btnZoomOut = makeZoomBtn(QString::fromUtf8("−"), "zoomOut", tr("Zoom out (Ctrl+−)"));
    connect(btnZoomOut, &QPushButton::clicked, this, [this] { zoomBy(1.0 / 1.25); });
    m_headerToolBar->addWidget(btnZoomOut);

    auto *btnZoomIn = makeZoomBtn("+", "zoomIn", tr("Zoom in (Ctrl++)"));
    connect(btnZoomIn, &QPushButton::clicked, this, [this] { zoomBy(1.25); });
    m_headerToolBar->addWidget(btnZoomIn);
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

    // Page 0: Move / Transform
    auto *pageMove = new QWidget(m_optionsStack);
    auto *layoutMove = new QHBoxLayout(pageMove);
    layoutMove->setContentsMargins(0, 0, 0, 0);
    layoutMove->setSpacing(8);

    auto *lblMoveTitle = new QLabel(tr("Move / Transform"), pageMove);
    lblMoveTitle->setStyleSheet(titleStyle);
    layoutMove->addWidget(lblMoveTitle);

    auto *chkAutoSelect = new QCheckBox(tr("Auto Select"), pageMove);
    chkAutoSelect->setObjectName("transformAutoSelect");
    chkAutoSelect->setChecked(true);
    m_autoSelectCheck = chkAutoSelect;
    layoutMove->addWidget(chkAutoSelect);

    auto *chkIgnoreTrans = new QCheckBox(tr("Ignore Transparent Pixels"), pageMove);
    layoutMove->addWidget(chkIgnoreTrans);

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

    // Page 1: Brush / Eraser
    auto *pageBrush = new QWidget(m_optionsStack);
    auto *layoutBrush = new QHBoxLayout(pageBrush);
    layoutBrush->setContentsMargins(0, 0, 0, 0);
    layoutBrush->setSpacing(8);

    auto *lblBrushTitle = new QLabel(tr("Brush"), pageBrush);
    lblBrushTitle->setObjectName("options.brushTitle");
    lblBrushTitle->setStyleSheet(titleStyle);
    layoutBrush->addWidget(lblBrushTitle);

    auto *btnPaintMode = new QPushButton(tr("Paint"), pageBrush);
    btnPaintMode->setCheckable(true);
    btnPaintMode->setChecked(true);
    btnPaintMode->setStyleSheet(pillActive);
    auto *btnEraseMode = new QPushButton(tr("Erase"), pageBrush);
    btnEraseMode->setCheckable(true);
    btnEraseMode->setChecked(false);
    btnEraseMode->setStyleSheet(pillInactive);

    connect(btnPaintMode, &QPushButton::clicked, this, [this, btnPaintMode, btnEraseMode, pillActive, pillInactive] {
        m_brushMode = "Paint";
        btnPaintMode->setChecked(true);
        btnEraseMode->setChecked(false);
        btnPaintMode->setStyleSheet(pillActive);
        btnEraseMode->setStyleSheet(pillInactive);
        setTool(Tool::Brush);
    });
    connect(btnEraseMode, &QPushButton::clicked, this, [this, btnPaintMode, btnEraseMode, pillActive, pillInactive] {
        m_brushMode = "Paint";
        btnPaintMode->setChecked(false);
        btnEraseMode->setChecked(true);
        btnPaintMode->setStyleSheet(pillInactive);
        btnEraseMode->setStyleSheet(pillActive);
        setTool(Tool::Eraser);
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

    // Page 2: Selection
    auto *pageSelect = new QWidget(m_optionsStack);
    auto *layoutSelect = new QHBoxLayout(pageSelect);
    layoutSelect->setContentsMargins(0, 0, 0, 0);
    layoutSelect->setSpacing(8);

    auto *lblSelectTitle = new QLabel(tr("Selection"), pageSelect);
    lblSelectTitle->setObjectName("options.selectTitle");
    lblSelectTitle->setStyleSheet(titleStyle);
    layoutSelect->addWidget(lblSelectTitle);

    auto *btnRect = new QPushButton(tr("Rectangle"), pageSelect);
    btnRect->setStyleSheet(pillActive);
    auto *btnEllipse = new QPushButton(tr("Ellipse"), pageSelect);
    btnEllipse->setStyleSheet(pillInactive);
    connect(btnRect, &QPushButton::clicked, this, [this, btnRect, btnEllipse, pillActive, pillInactive] {
        btnRect->setStyleSheet(pillActive);
        btnEllipse->setStyleSheet(pillInactive);
        setTool(Tool::RectSelect);
    });
    connect(btnEllipse, &QPushButton::clicked, this, [this, btnRect, btnEllipse, pillActive, pillInactive] {
        btnRect->setStyleSheet(pillInactive);
        btnEllipse->setStyleSheet(pillActive);
        setTool(Tool::EllipseSelect);
    });
    layoutSelect->addWidget(btnRect);
    layoutSelect->addWidget(btnEllipse);

    auto *btnNewSel = new QPushButton(tr("New"), pageSelect);
    btnNewSel->setStyleSheet(pillActive);
    auto *btnAddSel = new QPushButton(tr("Add"), pageSelect);
    btnAddSel->setStyleSheet(pillInactive);
    auto *btnSubSel = new QPushButton(tr("Subtract"), pageSelect);
    btnSubSel->setStyleSheet(pillInactive);
    connect(btnNewSel, &QPushButton::clicked, this, [btnNewSel, btnAddSel, btnSubSel, pillActive, pillInactive] {
        btnNewSel->setStyleSheet(pillActive); btnAddSel->setStyleSheet(pillInactive); btnSubSel->setStyleSheet(pillInactive);
    });
    connect(btnAddSel, &QPushButton::clicked, this, [btnNewSel, btnAddSel, btnSubSel, pillActive, pillInactive] {
        btnNewSel->setStyleSheet(pillInactive); btnAddSel->setStyleSheet(pillActive); btnSubSel->setStyleSheet(pillInactive);
    });
    connect(btnSubSel, &QPushButton::clicked, this, [btnNewSel, btnAddSel, btnSubSel, pillActive, pillInactive] {
        btnNewSel->setStyleSheet(pillInactive); btnAddSel->setStyleSheet(pillInactive); btnSubSel->setStyleSheet(pillActive);
    });
    layoutSelect->addWidget(btnNewSel);
    layoutSelect->addWidget(btnAddSel);
    layoutSelect->addWidget(btnSubSel);

    auto *chkAntiAlias = new QCheckBox(tr("Anti-alias"), pageSelect);
    chkAntiAlias->setChecked(true);
    layoutSelect->addWidget(chkAntiAlias);

    auto *btnExpand = new QPushButton(tr("Expand"), pageSelect);
    btnExpand->setStyleSheet(btnStyle);
    layoutSelect->addWidget(btnExpand);
    auto *spinExpand = new QSpinBox(pageSelect);
    spinExpand->setRange(1, 250);
    spinExpand->setValue(1);
    spinExpand->setSuffix(tr(" px"));
    spinExpand->setFixedWidth(54);
    spinExpand->setStyleSheet(spinStyle);
    layoutSelect->addWidget(spinExpand);
    connect(btnExpand, &QPushButton::clicked, this, [this, spinExpand] {
        cmd(m_sessionHandle, QString(R"({"version":1,"action":"expandSelection","amount":%1})").arg(spinExpand->value()).toUtf8().constData());
        refreshImage();
    });

    auto *btnContract = new QPushButton(tr("Contract"), pageSelect);
    btnContract->setStyleSheet(btnStyle);
    layoutSelect->addWidget(btnContract);
    auto *spinContract = new QSpinBox(pageSelect);
    spinContract->setRange(1, 250);
    spinContract->setValue(1);
    spinContract->setSuffix(tr(" px"));
    spinContract->setFixedWidth(54);
    spinContract->setStyleSheet(spinStyle);
    layoutSelect->addWidget(spinContract);
    connect(btnContract, &QPushButton::clicked, this, [this, spinContract] {
        cmd(m_sessionHandle, QString(R"({"version":1,"action":"contractSelection","amount":%1})").arg(spinContract->value()).toUtf8().constData());
        refreshImage();
    });

    auto *btnDeselect = new QPushButton(tr("Deselect"), pageSelect);
    btnDeselect->setStyleSheet(btnStyle);
    connect(btnDeselect, &QPushButton::clicked, this, [this] {
        cmd(m_sessionHandle, R"({"version":1,"action":"deselect"})");
        refreshImage();
    });
    layoutSelect->addWidget(btnDeselect);

    layoutSelect->addStretch();
    m_optionsStack->addWidget(pageSelect);

    // Page 3: Magic Wand
    auto *pageWand = new QWidget(m_optionsStack);
    auto *layoutWand = new QHBoxLayout(pageWand);
    layoutWand->setContentsMargins(0, 0, 0, 0);
    layoutWand->setSpacing(8);

    auto *lblWandTitle = new QLabel(tr("Magic Wand"), pageWand);
    lblWandTitle->setStyleSheet(titleStyle);
    layoutWand->addWidget(lblWandTitle);

    auto *lblTol = new QLabel(tr("Tolerance"), pageWand);
    lblTol->setStyleSheet(labelStyle);
    layoutWand->addWidget(lblTol);
    auto *spinTol = new QSpinBox(pageWand);
    spinTol->setRange(0, 255);
    spinTol->setValue(32);
    spinTol->setFixedWidth(50);
    spinTol->setStyleSheet(spinStyle);
    layoutWand->addWidget(spinTol);

    auto *chkWandContig = new QCheckBox(tr("Contiguous"), pageWand);
    chkWandContig->setChecked(true);
    layoutWand->addWidget(chkWandContig);

    auto *chkWandAA = new QCheckBox(tr("Anti-alias"), pageWand);
    chkWandAA->setChecked(true);
    layoutWand->addWidget(chkWandAA);

    auto *chkWandSample = new QCheckBox(tr("Sample All Layers"), pageWand);
    layoutWand->addWidget(chkWandSample);

    layoutWand->addStretch();
    m_optionsStack->addWidget(pageWand);

    // Page 4: Clone Stamp / Spot Healing
    auto *pageClone = new QWidget(m_optionsStack);
    auto *layoutClone = new QHBoxLayout(pageClone);
    layoutClone->setContentsMargins(0, 0, 0, 0);
    layoutClone->setSpacing(8);

    auto *lblCloneTitle = new QLabel(tr("Clone Stamp"), pageClone);
    lblCloneTitle->setObjectName("options.cloneTitle");
    lblCloneTitle->setStyleSheet(titleStyle);
    layoutClone->addWidget(lblCloneTitle);

    auto *chkAligned = new QCheckBox(tr("Aligned"), pageClone);
    chkAligned->setChecked(true);
    layoutClone->addWidget(chkAligned);

    auto *lblSample = new QLabel(tr("Sample:"), pageClone);
    lblSample->setStyleSheet(labelStyle);
    layoutClone->addWidget(lblSample);
    auto *comboSample = new QComboBox(pageClone);
    comboSample->addItems({tr("Current Layer"), tr("All Layers")});
    layoutClone->addWidget(comboSample);

    layoutClone->addStretch();
    m_optionsStack->addWidget(pageClone);

    // Page 5: Crop
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
    layoutCrop->addWidget(comboRatio);

    auto *btnApplyCrop = new QPushButton(tr("Apply Crop"), pageCrop);
    btnApplyCrop->setStyleSheet(btnStyle);
    auto *btnCancelCrop = new QPushButton(tr("Cancel"), pageCrop);
    btnCancelCrop->setStyleSheet(btnStyle);
    layoutCrop->addWidget(btnApplyCrop);
    layoutCrop->addWidget(btnCancelCrop);

    layoutCrop->addStretch();
    m_optionsStack->addWidget(pageCrop);

    // Page 6: Default / Idle
    auto *pageIdle = new QWidget(m_optionsStack);
    auto *layoutIdle = new QHBoxLayout(pageIdle);
    layoutIdle->setContentsMargins(0, 0, 0, 0);
    layoutIdle->setSpacing(8);
    auto *lblIdle = new QLabel(tr("Select a tool from the left toolbar"), pageIdle);
    lblIdle->setStyleSheet(labelStyle);
    layoutIdle->addWidget(lblIdle);
    layoutIdle->addStretch();
    m_optionsStack->addWidget(pageIdle);

    m_optionsToolBar->addWidget(m_optionsStack);
}

void SessionWindow::updateOptionsBar() {
    if (!m_optionsStack) return;
    switch (m_tool) {
    case Tool::Move:
        m_optionsStack->setCurrentIndex(0);
        break;
    case Tool::Brush:
    case Tool::Eraser: {
        m_optionsStack->setCurrentIndex(1);
        auto *lbl = m_optionsStack->widget(1)->findChild<QLabel *>("options.brushTitle");
        if (lbl) lbl->setText(m_tool == Tool::Eraser ? tr("Eraser") : tr("Brush"));
        break;
    }
    case Tool::RectSelect:
    case Tool::EllipseSelect:
    case Tool::Lasso:
        m_optionsStack->setCurrentIndex(2);
        break;
    case Tool::MagicWand:
        m_optionsStack->setCurrentIndex(3);
        break;
    case Tool::CloneStamp:
    case Tool::SpotHealing: {
        m_optionsStack->setCurrentIndex(4);
        auto *lbl = m_optionsStack->widget(4)->findChild<QLabel *>("options.cloneTitle");
        if (lbl) lbl->setText(m_tool == Tool::SpotHealing ? tr("Spot Healing") : tr("Clone Stamp"));
        break;
    }
    case Tool::Crop:
        m_optionsStack->setCurrentIndex(5);
        break;
    default:
        m_optionsStack->setCurrentIndex(6);
        break;
    }
}

void SessionWindow::updateStatusTelemetry() {
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
    double effectiveZoom = 1.0;
    if (!m_image.isNull() && m_canvasWidget) {
        effectiveZoom = canvasTargetRect().width() / m_image.width();
    } else if (m_zoomLevel > 0.0) {
        effectiveZoom = m_zoomLevel;
    }
    m_statusZoomLabel->setText(QString("%1%").arg(effectiveZoom * 100.0, 0, 'f', 1));

    if (!m_image.isNull()) {
        m_statusDimsLabel->setText(QString("%1 × %2 px").arg(m_image.width()).arg(m_image.height()));
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
        hint = tr("Drag on canvas to paint · [ and ] resize brush · 1–9 opacity · Space to pan");
        break;
    case Tool::Eraser:
        hint = tr("Drag on canvas to erase · [ and ] resize eraser · 1–9 opacity · Space to pan");
        break;
    case Tool::RectSelect:
    case Tool::EllipseSelect:
    case Tool::Lasso:
        hint = tr("Drag to select · Drag inside to move · Shift add · Option subtract · Ctrl+D deselect");
        break;
    case Tool::MagicWand:
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
    default:
        hint = tr("Ready");
        break;
    }
    m_statusHintsLabel->setText(hint);
}

void SessionWindow::fitCanvas() {
    m_zoomLevel = 0.0;
    updateStatusTelemetry();
    if (m_canvasWidget) m_canvasWidget->update();
}

void SessionWindow::actualPixels() {
    m_zoomLevel = 1.0;
    updateStatusTelemetry();
    if (m_canvasWidget) m_canvasWidget->update();
}

void SessionWindow::zoomBy(double factor) {
    double current = m_zoomLevel;
    if (current <= 0.0 && !m_image.isNull()) {
        const QSize canvasSize = m_canvasWidget ? m_canvasWidget->size() : size();
        const int pad = 24;
        const int maxW = std::max(10, canvasSize.width() - pad * 2);
        const int maxH = std::max(10, canvasSize.height() - pad * 2);
        current = std::min(static_cast<double>(maxW) / m_image.width(),
                           static_cast<double>(maxH) / m_image.height());
    }
    if (current <= 0.0) current = 1.0;
    m_zoomLevel = std::clamp(current * factor, 0.05, 32.0);
    updateStatusTelemetry();
    if (m_canvasWidget) m_canvasWidget->update();
}
