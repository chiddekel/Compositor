// SessionWindow — see SessionWindow.h. Drives the Swift core via compositor_session_*
// and paints the composited RGBA via QImage. Implements file operations using Qt
// codecs (IO milestone: file-map "IO / codec mapping" tier).

#include "SessionWindow.h"
#include "ImageExporters.h"
#include "TabletHandler.h"

#include <QPainter>
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
private:
    SessionWindow *m_window;
};

SessionWindow::SessionWindow(QWidget *parent) : QMainWindow(parent) {
    setWindowTitle("Compositor");
    resize(1200, 800);
    setAcceptDrops(true);
    m_tabletHandler = std::make_unique<PressureModulatedTabletHandler>();

    // Central canvas widget:
    m_canvasWidget = new SessionCanvasWidget(this);
    setCentralWidget(m_canvasWidget);

    auto *toolsBar = addToolBar(tr("Tools"));
    toolsBar->setObjectName("toolbar.tools");
    toolsBar->setMovable(false);
    toolsBar->setOrientation(Qt::Vertical);
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

    m_layersView = new QTreeView(panel);
    m_layersView->setObjectName("layers.treeView");
    m_layerModel = new QStandardItemModel(this);
    m_layerModel->setHorizontalHeaderLabels({tr("Layer"), tr("Visible"), tr("Mask")});
    m_layersView->setModel(m_layerModel);
    m_layersView->setSelectionMode(QAbstractItemView::ExtendedSelection);
    m_layersView->setSelectionBehavior(QAbstractItemView::SelectRows);
    m_layersView->setUniformRowHeights(true);
    m_layersView->setAnimated(true);
    m_layersView->setAllColumnsShowFocus(true);
    m_layersView->setRootIsDecorated(true);
    m_layersView->header()->setStretchLastSection(false);
    m_layersView->header()->setSectionResizeMode(0, QHeaderView::Stretch);
    m_layersView->header()->setSectionResizeMode(1, QHeaderView::ResizeToContents);
    m_layersView->header()->setSectionResizeMode(2, QHeaderView::ResizeToContents);
    layout->addWidget(m_layersView);

    auto *btnLayout = new QHBoxLayout();
    auto *btnAddLayer = new QPushButton(tr("+ Layer"), panel);
    btnAddLayer->setObjectName("layer.add");
    btnAddLayer->setToolTip(tr("Add blank layer"));
    auto *btnAddGroup = new QPushButton(tr("+ Folder"), panel);
    btnAddGroup->setObjectName("layer.addGroup");
    btnAddGroup->setToolTip(tr("Add new group/folder"));
    auto *btnAddMask = new QPushButton(tr("+ Mask"), panel);
    btnAddMask->setObjectName("layer.addMask");
    btnAddMask->setToolTip(tr("Add reveal layer mask"));
    auto *btnDelete = new QPushButton(tr("Delete"), panel);
    btnDelete->setObjectName("layer.delete");
    btnDelete->setToolTip(tr("Delete active layer or group"));
    btnLayout->addWidget(btnAddLayer);
    btnLayout->addWidget(btnAddGroup);
    btnLayout->addWidget(btnAddMask);
    btnLayout->addWidget(btnDelete);
    layout->addLayout(btnLayout);

    connect(btnAddLayer, &QPushButton::clicked, this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"addLayer"})") == 0) { refreshImage(); refreshLayers(); }
    });
    connect(btnAddGroup, &QPushButton::clicked, this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"addGroup"})") == 0) { refreshImage(); refreshLayers(); }
    });
    connect(btnAddMask, &QPushButton::clicked, this, [this] {
        if (cmd(m_sessionHandle, R"({"version":1,"action":"addRevealMask"})") == 0) { refreshImage(); refreshLayers(); }
    });
    connect(btnDelete, &QPushButton::clicked, this, [this] {
        deleteSelectedLayers();
    });

    layout->addWidget(new QLabel(tr("Opacity"), panel));
    m_opacity = new QSlider(Qt::Horizontal, panel);
    m_opacity->setRange(0, 100);
    m_opacity->setValue(100);
    layout->addWidget(m_opacity);
    m_visibleCheck = new QCheckBox(tr("Visible"), panel);
    m_visibleCheck->setObjectName("layer.visible");
    m_maskCheck = new QCheckBox(tr("Mask enabled"), panel);
    m_maskCheck->setObjectName("layer.mask");
    layout->addWidget(m_visibleCheck);
    layout->addWidget(m_maskCheck);
    dock->setMinimumWidth(260);
    dock->setMaximumWidth(320);
    panel->setMinimumWidth(260);
    panel->setMaximumWidth(320);
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

    // Brush palette: diameter/hardness/opacity sliders, a color button, and the
    // active-layer blend mode. Shared by the mouse paint path and smokes.
    auto *brushDock = new QDockWidget(tr("Brush"), this);
    auto *brushPanel = new QWidget(brushDock);
    auto *brushLayout = new QVBoxLayout(brushPanel);
    m_brushColorButton = new QPushButton(tr("Red"), brushPanel);
    m_brushColorButton->setObjectName("brush.color");
    m_brushColorButton->setFixedHeight(28);
    m_brushColorButton->setStyleSheet("background-color: red;");
    brushLayout->addWidget(m_brushColorButton);
    brushLayout->addWidget(new QLabel(tr("Diameter"), brushPanel));
    m_brushDiameterSlider = new QSlider(Qt::Horizontal, brushPanel);
    m_brushDiameterSlider->setObjectName("brush.diameter");
    m_brushDiameterSlider->setRange(1, 256);
    m_brushDiameterSlider->setValue(m_brushDiameter);
    brushLayout->addWidget(m_brushDiameterSlider);
    brushLayout->addWidget(new QLabel(tr("Hardness"), brushPanel));
    m_brushHardnessSlider = new QSlider(Qt::Horizontal, brushPanel);
    m_brushHardnessSlider->setObjectName("brush.hardness");
    m_brushHardnessSlider->setRange(0, 100);
    m_brushHardnessSlider->setValue(m_brushHardness);
    brushLayout->addWidget(m_brushHardnessSlider);
    brushLayout->addWidget(new QLabel(tr("Opacity"), brushPanel));
    m_brushOpacitySlider = new QSlider(Qt::Horizontal, brushPanel);
    m_brushOpacitySlider->setObjectName("brush.opacity");
    m_brushOpacitySlider->setRange(0, 100);
    m_brushOpacitySlider->setValue(m_brushOpacity);
    brushLayout->addWidget(m_brushOpacitySlider);
    brushLayout->addWidget(new QLabel(tr("Blend"), brushPanel));
    m_blend = new QComboBox(brushPanel);
    m_blend->setObjectName("blend.mode");
    for (const QString &mode : blendModes()) m_blend->addItem(mode);
    brushLayout->addWidget(m_blend);
    brushDock->setMinimumWidth(260);
    brushDock->setMaximumWidth(320);
    brushPanel->setMinimumWidth(260);
    brushPanel->setMaximumWidth(320);
    brushDock->setWidget(brushPanel);
    addDockWidget(Qt::RightDockWidgetArea, brushDock);
    splitDockWidget(dock, brushDock, Qt::Vertical);
    connect(m_brushColorButton, &QPushButton::clicked, this, &SessionWindow::pickBrushColor);
    connect(m_brushDiameterSlider, &QSlider::valueChanged, this, &SessionWindow::setBrushDiameter);
    connect(m_brushHardnessSlider, &QSlider::valueChanged, this, &SessionWindow::setBrushHardness);
    connect(m_brushOpacitySlider, &QSlider::valueChanged, this, &SessionWindow::setBrushOpacity);
    connect(m_blend, &QComboBox::currentIndexChanged, this, &SessionWindow::setBlendModeFromCombo);

    statusBar()->showMessage(tr("Drag on canvas to paint."));

    m_autosaveTimer = new QTimer(this);
    m_autosaveTimer->setObjectName("autosaveTimer");
    m_autosaveTimer->setInterval(60000);
    connect(m_autosaveTimer, &QTimer::timeout, this, [this] { performAutosave(); });
    m_autosaveTimer->start();
}

SessionWindow::~SessionWindow() {
    if (m_sessionHandle != 0) compositor_session_close(m_sessionHandle);
}

QRectF SessionWindow::canvasTargetRect() const {
    if (m_image.isNull()) return QRectF();
    const QSize canvasSize = m_canvasWidget ? m_canvasWidget->size() : size();
    const int pad = 24;
    const int maxW = std::max(10, canvasSize.width() - pad * 2);
    const int maxH = std::max(10, canvasSize.height() - pad * 2);
    double scale = std::min(static_cast<double>(maxW) / m_image.width(),
                            static_cast<double>(maxH) / m_image.height());
    if (m_image.width() <= 128 && m_image.height() <= 128) {
        int intScale = std::max(1, static_cast<int>(scale));
        scale = intScale;
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
            nameItem->setIcon(style()->standardIcon(QStyle::SP_DirIcon));
            nameItem->setToolTip(tr("Group / Folder"));
        } else {
            nameItem->setIcon(style()->standardIcon(QStyle::SP_FileIcon));
            nameItem->setToolTip(tr("Raster Layer"));
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

    for (const QString &id : order) {
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

    if (selectedIndex.isValid()) {
        m_layersView->setCurrentIndex(selectedIndex);
        m_layersView->selectionModel()->select(selectedIndex, QItemSelectionModel::ClearAndSelect | QItemSelectionModel::Rows);
        m_layersView->scrollTo(selectedIndex);

        m_opacity->setValue(qRound(activeLayerObj.value("opacity").toDouble(1.0) * 100));
        m_visibleCheck->setChecked(activeLayerObj.value("visible").toBool(true));
        m_maskCheck->setEnabled(activeLayerObj.value("hasMask").toBool(false));
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
    const QColor color = QColorDialog::getColor(m_brushColor, this, tr("Brush color"));
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
    const char *names[] = {
        "Brush", "Eraser", "Move", "Rect Marquee", "Ellipse Marquee",
        "Lasso", "Magic Wand", "Clone Stamp", "Spot Healing", "Crop"
    };
    if (statusBar()) {
        statusBar()->showMessage(tr("Tool: %1").arg(tr(names[static_cast<int>(tool)])), 2000);
    }
}

void SessionWindow::mousePressEvent(QMouseEvent *event) {
    if (event->button() != Qt::LeftButton || m_painting) return;
    const QPointF point = documentPoint(event->position());
    m_dragStart = point;

    switch (m_tool) {
    case Tool::Move:
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
    if (m_tool == Tool::Lasso) {
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
        const double dx = point.x() - m_dragStart.x();
        const double dy = point.y() - m_dragStart.y();
        if (std::abs(dx) >= 0.5 || std::abs(dy) >= 0.5) {
            const QString json = QString(R"({"version":1,"action":"moveLayer","x":%1,"y":%2})")
                .arg(dx, 0, 'f', 2).arg(dy, 0, 'f', 2);
            const QByteArray bytes = json.toUtf8();
            if (compositor_session_command(m_sessionHandle, reinterpret_cast<const uint8_t *>(bytes.constData()), bytes.size()) == 0) {
                refreshImage();
                refreshLayers();
            }
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
